import Foundation
import XCTest
@testable import UnifiedAgentCore

final class FailureDetailTests: XCTestCase {
    private let read = #"; source_read={"route":"compact","observer":"compact","endpoint_version":2,"excluded_attributes":[],"deadline_ms":30000,"elapsed_ms":812,"after_source_failure":false,"wda_requests":2,"screenshot":false}"#

    private func json(_ stage: String, _ detail: String) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: ["stage": stage, "detail": detail]), as: UTF8.self)
    }

    private func make(_ detail: String, stage: String = "wda_compact_bad_answer") -> FailureDetail {
        FailureDetail.from(code: 7, json: json(stage, detail), operation: "observe", nowMs: 1_700_000_000_000)
    }

    func testV1RunnerSchemaMismatch() {
        let f = make(#"bound observation schema Some("hermes-observation/1"), expected hermes-observation/2"# + read)
        XCTAssertEqual(f.stage, "wda_compact_bad_answer")
        XCTAssertEqual(f.reason, "bound_schema_mismatch")
        XCTAssertEqual(f.expected, "hermes-observation/2")
        XCTAssertEqual(f.actual, "hermes-observation/1")
        XCTAssertEqual(f.sourceRead["elapsed_ms"], "812")
        XCTAssertEqual(f.sourceRead["after_source_failure"], "false")
        XCTAssertEqual(f.sourceRead["endpoint_version"], "2")
        XCTAssertNil(f.sourceRead["excluded_attributes"])
        XCTAssertTrue(f.text.contains("ffi.7.wda_compact_bad_answer"))
    }

    func testEndpointVersionAndMissingField() {
        let v = make("runner endpoint_version None, this app needs 2" + read)
        XCTAssertEqual(v.reason, "endpoint_version_mismatch")
        XCTAssertEqual(v.expected, "2")
        XCTAssertEqual(v.actual, "none")
        let i = make("identity.after without orientation" + read)
        XCTAssertEqual(i.reason, "identity_field_missing")
        XCTAssertEqual(i.actual, "after.orientation absent")
        XCTAssertEqual(make("no identity.before").reason, "identity_missing")
        XCTAssertEqual(make("bound observation without nodes").reason, "nodes_empty")
    }

    func testRunnerErrorKeepsStatusNotMessage() {
        let secret = #"source answer unusable: WDA error (status=500): "snapshot_nil http://127.0.0.1:8100/session/ABCDEF?k=sk-secret Bearer tok Hola Mundo""#
        let f = make(secret + read)
        XCTAssertEqual(f.httpStatus, 500)
        XCTAssertEqual(f.reason, "runner_http_error")
        for leak in ["sk-secret", "http://", "8100", "Bearer", "ABCDEF", "Hola", "snapshot_nil", "127.0.0.1"] {
            XCTAssertFalse(f.text.contains(leak), leak)
            XCTAssertFalse(String(decoding: try! JSONEncoder().encode(f), as: UTF8.self).contains(leak), leak)
        }
    }

    func testUnexpectedSchemaTokenIsNotCopied() {
        let f = make(#"bound observation schema Some("Mi contraseña 1234"), expected hermes-observation/2"#)
        XCTAssertEqual(f.actual, "other")
        XCTAssertFalse(f.text.contains("contraseña"))
    }

    func testIdentityRefusalKeepsTokenAndSafeStates() {
        let f = FailureDetail.from(code: -12, json: json("target_not_foreground_before",
            "identity_refused reason=target_not_foreground_before expected=running_foreground actual=running_background"),
            operation: "observe", nowMs: 0)
        XCTAssertEqual(f.stage, "target_not_foreground_before")
        XCTAssertEqual(f.reason, "target_not_foreground_before")
        XCTAssertEqual(f.expected, "running_foreground")
        XCTAssertEqual(f.actual, "running_background")
        XCTAssertTrue(f.text.contains("ffi.-12.target_not_foreground_before"))
        let o = make("identity_refused reason=orientation_changed_during_observation expected=portrait actual=landscape",
                     stage: "orientation_changed_during_observation")
        XCTAssertEqual([o.reason, o.expected, o.actual], ["orientation_changed_during_observation", "portrait", "landscape"])
        // anything else in that shape (an app name, a bundle id) is not copied
        let leak = make("identity_refused reason=foreground_mismatch expected=com.example.app actual=Mi App")
        XCTAssertNil(leak.expected)
        XCTAssertFalse(leak.text.contains("example"))
        XCTAssertEqual(make("runner did not mark the identity stable").reason, "identity_not_stable")
    }

    func testMalformedEnvelopes() {
        let garbage = FailureDetail.from(code: 7, json: "not json", operation: "observe", nowMs: 0)
        XCTAssertEqual(garbage.stage, "unknown")
        XCTAssertEqual(garbage.reason, "unclassified")
        XCTAssertTrue(garbage.sourceRead.isEmpty)
        XCTAssertEqual(make("x", stage: "Bad Stage! secret").stage, "unknown")
        XCTAssertTrue(make("x; source_read={not json").sourceRead.isEmpty)
        let hostile = make(#"x; source_read={"route":"Hola secret text","label":"private","elapsed_ms":{"a":1},"deadline_ms":1e300}"#)
        XCTAssertTrue(hostile.sourceRead.isEmpty, "\(hostile.sourceRead)")
        XCTAssertEqual(FailureDetail.from(code: 7, json: "[]", operation: "Op With Spaces", nowMs: 0).operation, "unknown")
    }

    func testRetrievalAfterDropAndClear() {
        let suite = "FailureDetailTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        var f = make(#"bound observation schema Some("hermes-observation/1"), expected hermes-observation/2"# + read)
        FailureDetailStore(d).save(f)
        f.sessionDropped = true
        FailureDetailStore(d).save(f)
        let loaded = FailureDetailStore(UserDefaults(suiteName: suite)!).load()
        XCTAssertEqual(loaded, f)
        XCTAssertTrue(loaded!.text.contains("dropped/closed"))
        FailureDetailStore(d).clear()
        XCTAssertNil(FailureDetailStore(d).load())
        d.set(Data("{broken".utf8), forKey: FailureDetailStore.key)
        XCTAssertNil(FailureDetailStore(d).load())
    }
}
