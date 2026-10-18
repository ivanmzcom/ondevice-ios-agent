import Foundation
import UIKit

/// Swift wrapper over libunified_ffi (Rust, idevice v0.1.68).
enum UniRunner {
    struct Failure: Error {
        let code: Int32
        let json: String
    }

    static var version: String { String(cString: uni_version()) }

    static func probe(pairing: Data, deviceIP: String) async -> Result<String, Failure> {
        await call { j, e in
            pairing.withUnsafeBytes { p in
                uni_probe(p.bindMemory(to: UInt8.self).baseAddress, p.count, deviceIP, 15, j, e)
            }
        }
    }

    /// State-preserving observation of `target` (see unified-ffi/src/lib.rs).
    static func observe(pairing: Data, deviceIP: String, runner: String, target: String,
                        heartbeat: Bool) async -> Result<String, Failure> {
        await call { j, e in
            pairing.withUnsafeBytes { p in
                uni_observe(p.bindMemory(to: UInt8.self).baseAddress, p.count, deviceIP, runner, target,
                            heartbeat ? 1 : 0, 90, j, e)
            }
        }
    }

    /// Blocking FFI off the main actor, with background time: activating the
    /// target app backgrounds this one mid-call.
    static func call(
        _ body: @escaping @Sendable (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>,
                                     UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32
    ) async -> Result<String, Failure> {
        let task = await MainActor.run { UIApplication.shared.beginBackgroundTask(withName: "uni-call") }
        let result = await Task.detached(priority: .userInitiated) { () -> Result<String, Failure> in
            var j: UnsafeMutablePointer<CChar>?
            var e: UnsafeMutablePointer<CChar>?
            let code = body(&j, &e)
            defer { uni_string_free(j); uni_string_free(e) }
            if code == ODR_OK, let j { return .success(String(cString: j)) }
            return .failure(Failure(code: code, json: e.map { String(cString: $0) } ?? "{}"))
        }.value
        await MainActor.run { UIApplication.shared.endBackgroundTask(task) }
        return result
    }
}
