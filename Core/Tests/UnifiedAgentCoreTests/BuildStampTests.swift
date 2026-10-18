import XCTest
@testable import UnifiedAgentCore

final class BuildStampTests: XCTestCase {
    func testStampShowsRevisionAndDefaultCombinedConfig() {
        let s = BuildStamp.line(bundleVersion: "1", executableDate: Date(timeIntervalSince1970: 0), libVersion: "unified_ffi 0.1.0",
                                storedSourceConfig: nil, openSessionConfig: nil)
        XCTAssertTrue(s.contains("build \(BuildStamp.uiRevision)"))
        XCTAssertTrue(BuildStamp.uiRevision.contains("source-fix"))
        XCTAssertTrue(s.contains("v1 · bin 1970-01-01T00:00:00Z · unified_ffi 0.1.0"))
        XCTAssertTrue(s.contains("/source próxima: combined \(WDASourcePreset.combined.configJSON)"))
        XCTAssertTrue(s.hasSuffix("abierta: sin sesión"))
    }

    func testStampShowsExplicitBaselineAndConfirmedSessionConfig() {
        let s = BuildStamp.line(bundleVersion: nil, executableDate: nil, libVersion: "lib",
                                storedSourceConfig: "{}", openSessionConfig: WDASourcePreset.combined.configJSON)
        XCTAssertTrue(s.contains("v? · bin ? · lib"))
        XCTAssertTrue(s.contains("/source próxima: baseline {}"))
        XCTAssertTrue(s.hasSuffix("abierta: combined \(WDASourcePreset.combined.configJSON)"))
        let custom = BuildStamp.line(bundleVersion: nil, executableDate: nil, libVersion: "lib",
                                     storedSourceConfig: #"{"source_deadline_s":12}"#, openSessionConfig: nil)
        XCTAssertTrue(custom.contains(#"/source próxima: custom {"source_deadline_s":12}"#))
    }

    func testStampHasNoLegacyHardwareWording() {
        let s = BuildStamp.line(bundleVersion: "1", executableDate: nil, libVersion: "lib", storedSourceConfig: nil, openSessionConfig: nil)
        for banned in ["esp32", "placa", "board", "bluetooth"] { XCTAssertFalse(s.lowercased().contains(banned), banned) }
    }
}
