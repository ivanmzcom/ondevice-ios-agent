import Combine
import CryptoKit
import Foundation
import Security

// EXPERIMENTAL (Debug builds only). Ported and reviewed from the uncommitted draft in esp32-iphone-agent-original
// (ios/IPhoneAgent/Services/ChatGPTSignIn.swift); not a vendored copy. See CHATGPT_AUTH_GATE.md: the on-device
// 127.0.0.1 redirect is the documented loopback contract applied to the phone itself, never verified on a device.

/// Sign in with ChatGPT with ChatGPT plan usage, as documented for open-source, locally run clients:
/// https://developers.openai.com/siwc/token-sharing-open-source/sign-in
/// A public client (PKCE, no secret, no partner key) that registers itself on first sign-in through
/// `dynamic_agent_client`, receives its own issued client ID, and gets the code on a 127.0.0.1 callback.
public enum ChatGPTAuth {
    public static let issuer = "https://auth.openai.com"
    static let authorizeURL = URL(string: "https://auth.openai.com/api/accounts/authorize")!
    static let tokenURL = URL(string: "https://auth.openai.com/api/accounts/oauth/token")!
    static let revokeURL = URL(string: "https://auth.openai.com/api/accounts/oauth/revoke")!
    static let jwksURL = URL(string: "https://auth.openai.com/.well-known/jwks.json")!
    public static let resource = "https://api.openai.com/v1"
    /// The first-time registration entry point; never saved or used for a token exchange.
    static let registrationClient = "dynamic_agent_client"
    static let planScope = "chatgpt.tokens.use.direct"
    static let scopes = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
    /// `agent_name_hint`: the app's actual name, the same on every install.
    static let agentName = "Unified Agent (spike)"
    public static let usageURL = URL(string: "https://chatgpt.com/settings/usage")!
    /// This app's own scheme, only for the hop that closes the sign-in sheet after the loopback callback.
    public static let sheetCloseScheme = "dev.spike.unifiedagent"
    static var sheetCloseURL: String { sheetCloseScheme + "://chatgpt-signed-in" }
    /// Refresh tokens that can never work again (repeat OAuth with the saved client ID).
    static let unusableRefresh: Set<String> = ["invalid_grant", "invalid_refresh_token", "token_expired",
                                               "refresh_token_expired", "refresh_token_invalidated", "refresh_token_reused"]

    /// One authorization attempt: fresh state, nonce and PKCE verifier, kept until its callback.
    struct Attempt {
        let url: URL
        let clientID: String
        let redirectURI: String
        let state: String
        let nonce: String
        let verifier: String
        var isRegistration: Bool { clientID == ChatGPTAuth.registrationClient }
    }

    static func random() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        precondition(SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess)
        return base64url(Data(bytes))
    }

    static func challenge(_ verifier: String) -> String { base64url(Data(SHA256.hash(data: Data(verifier.utf8)))) }

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// clientID nil = first registration. Hints only for reauthorization of the same account.
    static func attempt(clientID: String?, hostID: String, redirectURI: String, idTokenHint: String? = nil,
                        loginHint: String? = nil, consent: Bool = false) -> Attempt {
        let state = random(), nonce = random(), verifier = random()
        let client = clientID ?? registrationClient
        var items = [URLQueryItem(name: "client_id", value: client)]
        if clientID == nil { items.append(URLQueryItem(name: "agent_name_hint", value: agentName)) }
        items.append(URLQueryItem(name: "ext_agent_host_id", value: hostID))
        if clientID != nil {
            if let idTokenHint { items.append(URLQueryItem(name: "id_token_hint", value: idTokenHint)) }
            if let loginHint { items.append(URLQueryItem(name: "login_hint", value: loginHint)) }
        }
        items += [URLQueryItem(name: "response_type", value: "code"),
                  URLQueryItem(name: "redirect_uri", value: redirectURI),
                  URLQueryItem(name: "scope", value: scopes),
                  URLQueryItem(name: "resource", value: resource),
                  URLQueryItem(name: "state", value: state),
                  URLQueryItem(name: "nonce", value: nonce),
                  URLQueryItem(name: "code_challenge_method", value: "S256"),
                  URLQueryItem(name: "code_challenge", value: challenge(verifier))]
        if consent { items.append(URLQueryItem(name: "prompt", value: "consent")) }  // re-ask after a decline
        var components = URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false)!
        components.percentEncodedQuery = items.map { "\($0.name)=\(formEncode($0.value ?? ""))" }.joined(separator: "&")
        return Attempt(url: components.url!, clientID: client, redirectURI: redirectURI, state: state, nonce: nonce,
                       verifier: verifier)
    }

    /// The code and the client ID to exchange it with, after checking state, errors and the issued ID.
    static func callback(_ url: URL, for attempt: Attempt) throws -> (code: String, clientID: String) {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard value("state") == attempt.state else { throw ChatGPTAuthError.stateMismatch }
        if let error = value("error") {
            throw error == "access_denied" ? ChatGPTAuthError.declined
                : ChatGPTAuthError.server(error, value("error_description"))
        }
        guard let code = value("code"), !code.isEmpty else { throw ChatGPTAuthError.incomplete }
        let issued = value("client_id")
        if attempt.isRegistration {
            guard let issued, !issued.isEmpty, issued != registrationClient else { throw ChatGPTAuthError.incomplete }
            return (code, issued)
        }
        if let issued, issued != attempt.clientID { throw ChatGPTAuthError.clientMismatch }
        return (code, attempt.clientID)
    }

    static func form(_ fields: [(String, String)]) -> Data {
        Data(fields.map { "\($0.0)=\(formEncode($0.1))" }.joined(separator: "&").utf8)
    }

    private static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

public enum ChatGPTAuthError: LocalizedError, Equatable {
    case cancelled, declined, stateMismatch, incomplete, clientMismatch, accountMismatch, notSignedIn, signInAgain
    case server(String, String?)
    case idToken(String)

    public var errorDescription: String? {
        switch self {
        case .cancelled: return "Sign-in was cancelled."
        case .declined: return "ChatGPT plan use wasn't allowed. Sign in again and allow it, or use the API-key endpoint."
        case .stateMismatch: return "Sign-in could not be verified (state mismatch). Try again."
        case .incomplete: return "Sign-in did not complete. Try again."
        case .clientMismatch: return "Sign-in returned a different app registration and was rejected."
        case .accountMismatch: return "You signed in with a different ChatGPT account. Use Forget account to switch."
        case .notSignedIn: return "Not signed in with ChatGPT."
        case .signInAgain: return "Your ChatGPT session ended. Sign in with ChatGPT again."
        case .server(let code, let message): return "ChatGPT sign-in: \(code)" + (message.map { " – \($0)" } ?? "")
        case .idToken(let why): return "ChatGPT sign-in: ID token \(why)"
        }
    }
}

/// The token endpoint's reply (authorization code or refresh).
struct ChatGPTTokens: Decodable {
    let access_token: String
    let refresh_token: String?
    let id_token: String?
    let expires_in: Double?
    let scope: String?
}

/// One registration's credential record (the documented local record), kept in the Keychain.
public struct ChatGPTCredential: Codable, Equatable {
    public var email: String?
    public var issuer = ChatGPTAuth.issuer
    public var subject: String
    public var clientID: String
    public var hostID: String
    var idToken: String?
    var accessToken: String?
    var refreshToken: String?
    var expiresAt: Date?
    public var scopes: [String]
    public var savedAt: Date

    init(email: String?, subject: String, clientID: String, hostID: String, idToken: String? = nil,
         accessToken: String? = nil, refreshToken: String? = nil, expiresAt: Date? = nil, scopes: [String], savedAt: Date) {
        (self.email, self.subject, self.clientID, self.hostID) = (email, subject, clientID, hostID)
        (self.idToken, self.accessToken, self.refreshToken, self.expiresAt) = (idToken, accessToken, refreshToken, expiresAt)
        (self.scopes, self.savedAt) = (scopes, savedAt)
    }

    public var signedIn: Bool { accessToken != nil && refreshToken != nil }
    public var planEnabled: Bool { scopes.contains(ChatGPTAuth.planScope) }

    /// After sign-out: no tokens or ID-token hint, but the account/client mapping stays for the next sign-in.
    var signedOut: ChatGPTCredential {
        var c = self
        (c.idToken, c.accessToken, c.refreshToken, c.expiresAt) = (nil, nil, nil, nil)
        return c
    }
}

/// Where the credential and this install's host ID live (the app's own Keychain items; memory in tests).
public protocol ChatGPTStore: AnyObject {
    func load() -> ChatGPTCredential?
    func save(_ credential: ChatGPTCredential?)
    /// The stable `ext_agent_host_id` of this install, created once.
    func hostID() -> String
}

/// ID-token checks: RS256 signature against OpenAI's JWKS, issuer, audience (the issued client ID), expiry, nonce.
enum IDToken {
    struct Claims { let subject: String; let email: String? }

    static func verify(_ token: String, jwks: Data, clientID: String, nonce: String, now: Date = Date()) throws -> Claims {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, let headerData = decode(parts[0]), let payloadData = decode(parts[1]),
              let signature = decode(parts[2]),
              let header = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              let claims = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
            throw ChatGPTAuthError.idToken("is malformed")
        }
        guard header["alg"] as? String == "RS256" else { throw ChatGPTAuthError.idToken("uses an unexpected algorithm") }
        let keys = ((try? JSONSerialization.jsonObject(with: jwks) as? [String: Any])?["keys"] as? [[String: Any]]) ?? []
        let kid = header["kid"] as? String
        guard let jwk = keys.first(where: { $0["kty"] as? String == "RSA" && (kid == nil || $0["kid"] as? String == kid) }),
              let key = rsaKey(jwk) else { throw ChatGPTAuthError.idToken("has no matching signing key") }
        var error: Unmanaged<CFError>?
        guard SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA256, Data((parts[0] + "." + parts[1]).utf8) as CFData,
                                    signature as CFData, &error) else {
            throw ChatGPTAuthError.idToken("signature is invalid")
        }
        guard claims["iss"] as? String == ChatGPTAuth.issuer else { throw ChatGPTAuthError.idToken("issuer is wrong") }
        let audience = (claims["aud"] as? String).map { [$0] } ?? (claims["aud"] as? [String]) ?? []
        guard audience.contains(clientID) else { throw ChatGPTAuthError.idToken("audience is wrong") }
        guard let exp = (claims["exp"] as? NSNumber)?.doubleValue, Date(timeIntervalSince1970: exp + 60) > now else {
            throw ChatGPTAuthError.idToken("has expired")
        }
        guard claims["nonce"] as? String == nonce else { throw ChatGPTAuthError.idToken("nonce is wrong") }
        guard let sub = claims["sub"] as? String, !sub.isEmpty else { throw ChatGPTAuthError.idToken("has no subject") }
        return Claims(subject: sub, email: claims["email"] as? String)
    }

    static func decode(_ part: String) -> Data? {
        var s = part.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        return Data(base64Encoded: s)
    }

    /// A public key from a JWK's n and e (PKCS#1 RSAPublicKey DER, which SecKeyCreateWithData takes).
    static func rsaKey(_ jwk: [String: Any]) -> SecKey? {
        guard let n = (jwk["n"] as? String).flatMap(decode), let e = (jwk["e"] as? String).flatMap(decode) else { return nil }
        func integer(_ bytes: Data) -> Data {
            var b = Data(bytes.drop { $0 == 0 })
            if let first = b.first, first & 0x80 != 0 { b.insert(0, at: 0) }
            return Data([0x02]) + length(b.count) + b
        }
        func length(_ count: Int) -> Data {
            if count < 0x80 { return Data([UInt8(count)]) }
            var bytes = withUnsafeBytes(of: count.bigEndian) { Data($0) }.drop { $0 == 0 }
            bytes.insert(0x80 | UInt8(bytes.count), at: bytes.startIndex)
            return Data(bytes)
        }
        let body = integer(n) + integer(e)
        let der = Data([0x30]) + length(body.count) + body
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic]
        return SecKeyCreateWithData(der as CFData, attributes as CFDictionary, nil)
    }
}

/// Opens the authorization page in the system browser; `onEnd` runs when the sheet closes for any reason.
/// The app supplies ASWebAuthenticationSession; tests play the redirect.
@MainActor public protocol ChatGPTBrowser: AnyObject {
    func open(_ url: URL, onEnd: @escaping @MainActor @Sendable () -> Void) throws
    func close()
}

/// The signed-in ChatGPT account: sign-in, serialized token refresh, sign-out with revocation.
/// Tokens never reach DebugLog, UserDefaults or the API-key store.
@MainActor public final class ChatGPTAccount: ObservableObject {
    @Published public private(set) var credential: ChatGPTCredential?
    @Published public private(set) var busy = false
    @Published public var error: String?

    private let store: ChatGPTStore
    private let session: URLSession
    private let makeBrowser: @MainActor () -> ChatGPTBrowser
    private let ports: [UInt16]
    private var refreshing: Task<String, Error>?

    public convenience init(store: ChatGPTStore, browser: @escaping @MainActor () -> ChatGPTBrowser) {
        self.init(store: store, session: .shared, browser: browser)
    }

    init(store: ChatGPTStore, session: URLSession, browser: @escaping @MainActor () -> ChatGPTBrowser,
         ports: [UInt16] = [1455, 0]) {
        self.store = store
        self.session = session
        self.makeBrowser = browser
        self.ports = ports
        credential = store.load()
    }

    /// Requests can use the ChatGPT plan.
    public var ready: Bool { credential.map { $0.signedIn && $0.planEnabled } ?? false }

    private func update(_ c: ChatGPTCredential?) {
        credential = c
        store.save(c)
    }

    /// The whole browser flow; errors end up in `error`. consent: ask again for plan use after a decline.
    public func signIn(consent: Bool = false) async {
        guard !busy else { return }
        busy = true
        error = nil
        defer { busy = false }
        do {
            try await authorize(consent: consent)
            DebugLog.write("chatgpt: signed in, plan use \(credential?.planEnabled == true ? "allowed" : "not allowed")")
        } catch {
            if (error as? ChatGPTAuthError) != .cancelled { self.error = error.localizedDescription }
            DebugLog.write("chatgpt: sign-in failed: \(error.localizedDescription)")
        }
    }

    private func authorize(consent: Bool) async throws {
        let saved = credential
        let server = try await LoopbackCallback.start(ports: ports, doneURL: ChatGPTAuth.sheetCloseURL)
        defer { server.stop() }
        let hostID = store.hostID()  // one per install, chosen before the first sign-in and kept
        let attempt = ChatGPTAuth.attempt(clientID: saved?.clientID, hostID: hostID,
                                          redirectURI: server.redirectURI, idTokenHint: saved?.idToken,
                                          loginHint: saved?.email, consent: consent)
        let browser = makeBrowser()
        try browser.open(attempt.url) { server.fail(ChatGPTAuthError.cancelled) }
        defer { browser.close() }
        let url = try await server.callback()
        let (code, clientID) = try ChatGPTAuth.callback(url, for: attempt)
        let tokens = try await token([("grant_type", "authorization_code"), ("client_id", clientID), ("code", code),
                                      ("code_verifier", attempt.verifier), ("redirect_uri", attempt.redirectURI),
                                      ("resource", ChatGPTAuth.resource)])
        guard let idToken = tokens.id_token else { throw ChatGPTAuthError.idToken("is missing") }
        let (jwks, _) = try await session.data(from: ChatGPTAuth.jwksURL)
        let claims = try IDToken.verify(idToken, jwks: jwks, clientID: clientID, nonce: attempt.nonce)
        if let saved, saved.clientID == clientID, saved.subject != claims.subject { throw ChatGPTAuthError.accountMismatch }
        let scopes = (tokens.scope ?? "").split(separator: " ").map(String.init).sorted()
        update(ChatGPTCredential(email: claims.email, subject: claims.subject, clientID: clientID, hostID: hostID,
                                 idToken: idToken, accessToken: tokens.access_token, refreshToken: tokens.refresh_token,
                                 expiresAt: tokens.expires_in.map { Date().addingTimeInterval($0) }, scopes: scopes,
                                 savedAt: Date()))
    }

    /// A current access token, refreshed a few minutes before expiry; one refresh at a time (tokens rotate).
    public func accessToken() async throws -> String {
        if let refreshing { return try await refreshing.value }
        guard let c = credential, c.signedIn, let access = c.accessToken else { throw ChatGPTAuthError.notSignedIn }
        guard c.planEnabled else { throw ChatGPTAuthError.declined }
        if let expires = c.expiresAt, expires.timeIntervalSinceNow > 300 { return access }
        let task = Task { try await refresh(c) }
        refreshing = task
        defer { refreshing = nil }
        return try await task.value
    }

    private func refresh(_ c: ChatGPTCredential) async throws -> String {
        guard let refreshToken = c.refreshToken else { throw ChatGPTAuthError.notSignedIn }
        do {
            let tokens = try await token([("grant_type", "refresh_token"), ("client_id", c.clientID),
                                          ("refresh_token", refreshToken), ("resource", ChatGPTAuth.resource)])
            // Signed out (or signed in again) while the refresh was in flight: do not bring old tokens back.
            guard credential?.refreshToken == refreshToken else { throw ChatGPTAuthError.notSignedIn }
            var next = c
            next.accessToken = tokens.access_token
            next.refreshToken = tokens.refresh_token ?? refreshToken
            next.expiresAt = tokens.expires_in.map { Date().addingTimeInterval($0) }
            if let scope = tokens.scope { next.scopes = scope.split(separator: " ").map(String.init).sorted() }
            next.savedAt = Date()
            update(next)
            DebugLog.write("chatgpt: access token refreshed")
            return tokens.access_token
        } catch ChatGPTAuthError.server(let code, _) where ChatGPTAuth.unusableRefresh.contains(code) {
            if credential?.refreshToken == refreshToken { update(c.signedOut) }  // keep the client mapping and host ID
            throw ChatGPTAuthError.signInAgain
        }
    }

    /// Revokes the refresh token, then clears tokens. Returns false if revocation could not be confirmed.
    @discardableResult public func signOut() async -> Bool {
        guard let c = credential else { return true }
        update(c.signedOut)  // tokens leave this device's store first, whatever the network does
        var revoked = c.refreshToken == nil
        for attempt in 0..<3 where !revoked {
            var request = URLRequest(url: ChatGPTAuth.revokeURL, timeoutInterval: 20)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = ChatGPTAuth.form([("token", c.refreshToken ?? ""), ("token_type_hint", "refresh_token"),
                                                 ("client_id", c.clientID)])
            let status = ((try? await session.data(for: request))?.1 as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200 { revoked = true } else if (400..<500).contains(status) { break }
            else { try? await Task.sleep(nanoseconds: UInt64(attempt + 1) * 1_000_000_000) }
        }
        error = revoked ? nil : "Signed out on this iPhone, but OpenAI did not confirm the revocation. You can disconnect the app in ChatGPT settings."
        DebugLog.write("chatgpt: signed out, revocation \(revoked ? "confirmed" : "not confirmed")")
        return revoked
    }

    /// Forget the saved registration so the next sign-in registers again (another account or workspace).
    public func forget() async {
        await signOut()
        update(nil)
    }

    private func token(_ fields: [(String, String)]) async throws -> ChatGPTTokens {
        var request = URLRequest(url: ChatGPTAuth.tokenURL, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = ChatGPTAuth.form(fields)
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let nested = json?["error"] as? [String: Any]
            let code = json?["error"] as? String ?? nested?["code"] as? String ?? "HTTP \(status)"
            throw ChatGPTAuthError.server(code, json?["error_description"] as? String ?? nested?["message"] as? String)
        }
        do { return try JSONDecoder().decode(ChatGPTTokens.self, from: data) } catch { throw ChatGPTAuthError.incomplete }
    }
}
