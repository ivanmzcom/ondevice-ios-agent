// SYNTHETIC tests for the EXPERIMENTAL ChatGPT plan Fast mode (service_tier). URLProtocol stubs (RouteStub) and a
// private UserDefaults suite only; no network, no account, no live model.
import XCTest
@testable import UnifiedAgentCore

@MainActor final class ChatGPTFastTests: XCTestCase {
    var defaults: UserDefaults!
    let suite = "ChatGPTFastTests"

    override func setUp() {
        RouteStub.seen = []
        RouteStub.routes = [:]
        UserDefaults().removePersistentDomain(forName: suite)
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() { UserDefaults().removePersistentDomain(forName: suite) }

    func sse(_ events: [[String: Any]]) -> String {
        events.map { e in
            "event: \(e["type"] as? String ?? "")\ndata: " + String(decoding: try! JSONSerialization.data(withJSONObject: e), as: UTF8.self) + "\n\n"
        }.joined()
    }

    func completed(tier: String?) -> [String: Any] {
        var response: [String: Any] = ["status": "completed", "usage": ["input_tokens": 10, "output_tokens": 3]]
        if let tier { response["service_tier"] = tier }
        return ["type": "response.completed", "response": response]
    }

    let delta: [String: Any] = ["type": "response.output_text.delta", "delta": "DO: tap 1"]

    func client() -> ResponsesClient {
        ResponsesClient(model: "gpt-test", token: { "at_live" }, session: RouteStub.session(), defaults: defaults)
    }

    func run(_ c: ResponsesClient) async throws -> ChatResult {
        try await c.chat(system: "SYS", text: "task", image: nil, maxTokens: 600, temperature: 0)
    }

    func body(_ i: Int) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: RouteStub.seen[i].body) as? [String: Any])
    }

    func testDisabledByDefaultOmitsServiceTier() async throws {
        RouteStub.routes["/v1/responses"] = { [self] _ in (200, "text/event-stream", sse([delta, completed(tier: "default")])) }
        let c = client()
        _ = try await run(c)
        let b = try body(0)
        XCTAssertEqual(Set(b.keys), ["model", "instructions", "input", "store", "stream"])
        XCTAssertNil(b["service_tier"])
        XCTAssertNil(c.lastRequestedServiceTier)
        XCTAssertEqual(c.lastServiceTier, "default")
        XCTAssertNil(defaults.string(forKey: ResponsesClient.lastRequestedTierKey))
    }

    func testEnabledSendsFastOnTheSameModelEndpointAndToken() async throws {
        defaults.set(true, forKey: ResponsesClient.fastPreferenceKey)
        RouteStub.routes["/v1/responses"] = { [self] _ in (200, "text/event-stream", sse([delta, completed(tier: "fast")])) }
        let c = client()
        let result = try await run(c)
        XCTAssertEqual(result.text, "DO: tap 1")
        let seen = try XCTUnwrap(RouteStub.seen.first)
        XCTAssertEqual(seen.url.absoluteString, "https://api.openai.com/v1/responses")
        XCTAssertEqual(seen.headers["Authorization"], "Bearer at_live")
        let b = try body(0)
        XCTAssertEqual(Set(b.keys), ["model", "instructions", "input", "store", "stream", "service_tier"])
        XCTAssertEqual(b["service_tier"] as? String, "fast")
        XCTAssertEqual(b["model"] as? String, "gpt-test")
        XCTAssertEqual(c.lastRequestedServiceTier, "fast")
        XCTAssertEqual(defaults.string(forKey: ResponsesClient.lastRequestedTierKey), "fast")
    }

    func testPreferenceIsSampledPerRequest() async throws {
        RouteStub.routes["/v1/responses"] = { [self] _ in (200, "text/event-stream", sse([delta, completed(tier: nil)])) }
        let c = client()
        _ = try await run(c)
        defaults.set(true, forKey: ResponsesClient.fastPreferenceKey)
        _ = try await run(c)
        defaults.set(false, forKey: ResponsesClient.fastPreferenceKey)
        _ = try await run(c)
        XCTAssertEqual(try (0..<3).map { try body($0)["service_tier"] as? String }, [nil, "fast", nil])
        XCTAssertEqual(try (0..<3).map { try body($0)["model"] as? String }, ["gpt-test", "gpt-test", "gpt-test"])
    }

    func testConfirmedTierIsWhatResponseCompletedReportsNeverTheFlag() async throws {
        defaults.set(true, forKey: ResponsesClient.fastPreferenceKey)
        for returned in ["fast", "default", "priority", nil] as [String?] {
            RouteStub.routes["/v1/responses"] = { [self] _ in (200, "text/event-stream", sse([delta, completed(tier: returned)])) }
            let c = client()
            _ = try await run(c)
            XCTAssertEqual(c.lastRequestedServiceTier, "fast")
            XCTAssertEqual(c.lastServiceTier, returned, "\(returned ?? "absent")")
            XCTAssertEqual(defaults.string(forKey: ResponsesClient.lastConfirmedTierKey), returned)
        }
    }

    func testFailureAfterStreamStartsIsThrownOnceWithoutRetryOrConfirmation() async throws {
        defaults.set(true, forKey: ResponsesClient.fastPreferenceKey)
        defaults.set("fast", forKey: ResponsesClient.lastConfirmedTierKey)  // a stale earlier confirmation
        RouteStub.routes["/v1/responses"] = { [self] _ in
            (200, "text/event-stream", sse([delta, ["type": "response.failed",
                                                    "response": ["service_tier": "fast", "error": ["code": "server_error", "message": "boom"]]]]))
        }
        let c = client()
        do { _ = try await run(c); XCTFail("must throw") } catch {
            XCTAssertTrue(error.localizedDescription.contains("server_error"), error.localizedDescription)
        }
        XCTAssertEqual(RouteStub.seen.count, 1)
        XCTAssertNil(c.lastServiceTier)
        XCTAssertNil(defaults.string(forKey: ResponsesClient.lastConfirmedTierKey))
        XCTAssertEqual(c.lastRequestedServiceTier, "fast")
    }

    func testTierRejectionIsNotResubmittedWithoutTierOrElsewhere() async throws {
        defaults.set(true, forKey: ResponsesClient.fastPreferenceKey)
        RouteStub.routes["/v1/responses"] = { _ in
            (400, "application/json", "{\"error\":{\"code\":\"unsupported_parameter\",\"message\":\"service_tier\"}}")
        }
        do { _ = try await run(client()); XCTFail("must throw") } catch {
            let m = error.localizedDescription
            XCTAssertTrue(m.contains("HTTP 400") && m.contains("unsupported_parameter") && m.contains("req_test"), m)
        }
        XCTAssertEqual(RouteStub.seen.count, 1)
        XCTAssertEqual(RouteStub.seen.map(\.url.path), ["/v1/responses"])
        XCTAssertEqual(try body(0)["service_tier"] as? String, "fast")
    }

    func testBodyHelper() {
        XCTAssertNil(ResponsesClient.body(model: "m", system: "", text: "t", images: [])["service_tier"])
        XCTAssertEqual(ResponsesClient.body(model: "m", system: "", text: "t", images: [], serviceTier: "fast")["service_tier"] as? String, "fast")
    }
}
