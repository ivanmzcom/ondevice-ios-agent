import Foundation
import Network
import os

// EXPERIMENTAL (Debug builds only). Ported and reviewed from the uncommitted draft in esp32-iphone-agent-original
// (ios/IPhoneAgent/Services/LoopbackCallback.swift). Whether the iOS sign-in sheet follows a redirect to this
// listener, and whether it stays alive while the sheet is up, is unverified on a device (CHATGPT_AUTH_GATE.md U1).

/// The OAuth redirect target for Sign in with ChatGPT: an HTTP listener on 127.0.0.1 only, alive while the
/// sign-in sheet is open. It takes the first GET of `path`, answers with a redirect to `doneURL` (so the
/// system sign-in sheet closes itself) and hands the full callback URL to `callback()`.
final class LoopbackCallback: @unchecked Sendable {
    let port: UInt16
    let path: String
    private let listener: NWListener
    private let doneURL: String
    private let queue = DispatchQueue(label: "loopback-callback")
    private var result: Result<URL, Error>?
    private var waiter: CheckedContinuation<URL, Error>?

    var redirectURI: String { "http://127.0.0.1:\(port)\(path)" }

    private init(listener: NWListener, port: UInt16, path: String, doneURL: String) {
        self.listener = listener
        self.port = port
        self.path = path
        self.doneURL = doneURL
    }

    /// The first free port of `ports` (0 = any); OpenAI allows only the port to vary between sign-ins.
    static func start(ports: [UInt16] = [1455, 0], path: String = "/auth/callback",
                      doneURL: String) async throws -> LoopbackCallback {
        var last: Error = URLError(.cannotConnectToHost)
        for port in ports {
            do { return try await start(port: port, path: path, doneURL: doneURL) } catch { last = error }
        }
        throw last
    }

    private static func start(port: UInt16, path: String, doneURL: String) async throws -> LoopbackCallback {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port) ?? .any)
        params.allowLocalEndpointReuse = false
        let listener = try NWListener(using: params)
        let ready: UInt16 = try await withCheckedThrowingContinuation { continuation in
            // Resume exactly once; the lock makes that explicit instead of relying on the handler queue being serial.
            let resumed = OSAllocatedUnfairLock(initialState: false)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard resumed.withLock({ let first = !$0; $0 = true; return first }) else { return }
                    continuation.resume(returning: listener.port?.rawValue ?? port)
                case .failed(let error), .waiting(let error):
                    guard resumed.withLock({ let first = !$0; $0 = true; return first }) else { return }
                    listener.cancel()
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.newConnectionHandler = { $0.cancel() }  // replaced once ready
            listener.start(queue: DispatchQueue(label: "loopback-listener"))
        }
        let server = LoopbackCallback(listener: listener, port: ready, path: path, doneURL: doneURL)
        listener.stateUpdateHandler = nil
        listener.newConnectionHandler = { [weak server] connection in server?.accept(connection) }
        return server
    }

    /// Waits for the browser's redirect (or `fail`, e.g. the user closed the sheet).
    func callback() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                if let result = self.result { continuation.resume(with: result) } else { self.waiter = continuation }
            }
        }
    }

    /// Ends the wait unless a callback already arrived.
    func fail(_ error: Error) { queue.async { self.finish(.failure(error)) } }

    func stop() {
        listener.cancel()
        fail(CancellationError())
    }

    private func finish(_ outcome: Result<URL, Error>) {
        guard result == nil else { return }
        result = outcome
        waiter?.resume(with: outcome)
        waiter = nil
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, _, _ in
            guard let self else { return connection.cancel() }
            let head = String(decoding: data ?? Data(), as: UTF8.self).split(separator: "\r\n").first ?? ""
            let parts = head.split(separator: " ")
            let target = parts.count >= 2 && parts[0] == "GET" ? String(parts[1]) : ""
            let url = URL(string: "http://127.0.0.1:\(self.port)" + target)
            let response: String
            // Only the exact callback path, once; the code itself is checked against state by ChatGPTAuth.callback.
            if let url, url.path == self.path, self.result == nil {
                self.finish(.success(url))
                response = "HTTP/1.1 302 Found\r\nLocation: \(self.doneURL)\r\nContent-Type: text/html; charset=utf-8\r\n"
                    + "Cache-Control: no-store\r\nConnection: close\r\n\r\n"
                    + "<p>Signed in. You can return to Unified Agent.</p>"
            } else {
                response = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            }
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}
