import XCTest
@testable import UnifiedAgentCore

final class SourceCompareTests: XCTestCase {
    private func answer(_ samples: String, void: String = "null") -> String {
        #"{"stage":"compare_source","foreground_bundle_id":"net.whatsapp.WhatsApp","order":["json","xml"],"route":"direct","excluded_attributes":["accessible","index","traits","placeholderValue"],"deadline_ms":30000,"after_source_failure":false,"void":\#(void),"samples":[\#(samples)]}"#
    }
    private let jsonOK = #"{"format":"json","outcome":"ok","http_status":200,"duration_ms":9100,"response_bytes":812345,"value_kind":"object","wda_error":null,"foreground_stable":true}"#
    private let xml500 = #"{"format":"xml","outcome":"http_error","http_status":500,"duration_ms":22588,"response_bytes":140,"value_kind":"object","wda_error":"cannot_get_source","foreground_stable":true}"#

    func testJsonOkXml500IsSerializationEvidenceNotProof() throws {
        let c = try WDASourceComparison(json: answer(jsonOK + "," + xml500))
        XCTAssertEqual(c.samples.map(\.format), ["json", "xml"])
        XCTAssertEqual(c.sample("xml")?.httpStatus, 500)
        XCTAssertEqual(c.deadlineMs, 30000)
        XCTAssertTrue(c.verdict.contains("serialización XML"))
        XCTAssertTrue(c.verdict.contains("no es prueba"))
        XCTAssertEqual(c.lines, ["json: ok HTTP 200 9100 ms 812345 B", "xml: http_error HTTP 500 22588 ms 140 B [cannot_get_source]"])
        XCTAssertFalse(c.sessionLost)
    }

    func testBothFailAndVoid() throws {
        let jsonDeadline = #"{"format":"json","outcome":"deadline","duration_ms":30001,"foreground_stable":true}"#
        XCTAssertTrue(try WDASourceComparison(json: answer(jsonDeadline + "," + xml500)).verdict.contains("compartido"))
        let c = try WDASourceComparison(json: answer(jsonOK, void: #""foreground_changed_during_sample""#))
        XCTAssertEqual(c.void, "foreground_changed_during_sample")
        XCTAssertTrue(c.verdict.hasPrefix("Anulada"))
        XCTAssertEqual(c.diagFields.first { $0.0 == "void" }?.1, .token("foreground_changed_during_sample"))
    }

    func testNonTokenTextIsDroppedFromLinesAndDiag() throws {
        let leak = #"{"format":"json","outcome":"Mamá: hola 🙂","http_status":500,"duration_ms":5,"wda_error":"Session does not exist","foreground_stable":false}"#
        let c = try WDASourceComparison(json: answer(leak))
        let all = c.lines.joined() + c.diagFields.map { "\($0.0)\($0.1)" }.joined()
        XCTAssertFalse(all.contains("Mam"))
        XCTAssertFalse(all.contains("Session"))
        XCTAssertTrue(c.lines[0].contains("(primer plano cambió)"))
        XCTAssertEqual(try WDASourceComparison(json: answer(#"{"format":"xml","outcome":"http_error","wda_error":"invalid_session","duration_ms":3,"foreground_stable":true}"#)).sessionLost, true)
    }

    func testRejectsOtherAnswers() {
        XCTAssertThrowsError(try WDASourceComparison(json: #"{"stage":"observe"}"#))
        XCTAssertThrowsError(try WDASourceComparison(json: "nope"))
    }
}
