// SYNTHETIC tests for the experimental ChatGPT plan Responses transport and for the API-key path staying as it was
// (URLProtocol stubs only; no network, no account).
import XCTest
@testable import UnifiedAgentCore

@MainActor final class ResponsesClientTests: XCTestCase {
    override func setUp() {
        RouteStub.seen = []
        RouteStub.routes = [:]
    }

    func sse(_ events: [[String: Any]]) -> String {
        events.map { e in
            "event: \(e["type"] as? String ?? "")\ndata: " + String(decoding: try! JSONSerialization.data(withJSONObject: e), as: UTF8.self) + "\n\n"
        }.joined()
    }

    func client(_ token: @escaping @MainActor () async throws -> String = { "at_live" }) -> ResponsesClient {
        ResponsesClient(model: "gpt-test", token: token, session: RouteStub.session())
    }

    let completed: [String: Any] = ["type": "response.completed",
                                    "response": ["status": "completed", "usage": ["input_tokens": 10, "output_tokens": 3]]]

    func testRequestFollowsThePlanUsageContract() async throws {
        RouteStub.routes["/v1/responses"] = { [self] _ in
            (200, "text/event-stream", sse([["type": "response.created"],
                                            ["type": "response.output_text.delta", "delta": "DO: "],
                                            ["type": "response.output_text.delta", "delta": "tap 1"], completed]))
        }
        let c = client()
        let result = try await c.chat(system: "SYS", text: "task", image: Data([1, 2, 3]), maxTokens: 600, temperature: 0)
        XCTAssertEqual(result.text, "DO: tap 1")
        XCTAssertEqual(c.lastUsage["output_tokens"], 3)
        let seen = try XCTUnwrap(RouteStub.seen.first)
        XCTAssertEqual(seen.url.absoluteString, "https://api.openai.com/v1/responses")
        XCTAssertEqual(seen.headers["Authorization"], "Bearer at_live")
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: seen.body) as? [String: Any])
        XCTAssertEqual(Set(body.keys), ["model", "instructions", "input", "store", "stream"])
        XCTAssertEqual(body["store"] as? Bool, false)
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual(body["instructions"] as? String, "SYS")
        for forbidden in ["temperature", "max_output_tokens", "max_tokens", "metadata", "user", "top_p", "truncation",
                          "previous_response_id", "messages"] { XCTAssertNil(body[forbidden], forbidden) }
        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        XCTAssertEqual(input.count, 1)
        XCTAssertEqual(input[0]["role"] as? String, "user")  // no system-role item
        let content = try XCTUnwrap(input[0]["content"] as? [[String: Any]])
        XCTAssertEqual(content.map { $0["type"] as? String }, ["input_image", "input_text"])
        XCTAssertEqual(content[0]["image_url"] as? String, "data:image/jpeg;base64,AQID")
    }

    func testOnlyResponseCompletedIsASuccess() async throws {
        let delta: [String: Any] = ["type": "response.output_text.delta", "delta": "DO: tap 1"]
        let failures: [([[String: Any]], String)] = [
            ([delta], "without response.completed"),  // stream just ends after text
            ([delta, ["type": "response.incomplete", "response": ["incomplete_details": ["reason": "max_output_tokens"]]]],
             "incomplete (max_output_tokens)"),
            ([delta, ["type": "response.failed", "response": ["error": ["code": "subscription_sharing_usage_limit_exceeded",
                                                                         "message": "limit"]]]],
             "subscription_sharing_usage_limit_exceeded"),
            ([["type": "error", "error": ["code": "server_error", "message": "boom"]]], "server_error"),
        ]
        for (events, expected) in failures {
            RouteStub.routes["/v1/responses"] = { [self] _ in (200, "text/event-stream", sse(events)) }
            do { _ = try await client().chat(system: "", text: "t", image: nil, maxTokens: 1, temperature: 0); XCTFail(expected) }
            catch { XCTAssertTrue(error.localizedDescription.contains(expected), "\(expected): \(error.localizedDescription)") }
        }
        RouteStub.routes["/v1/responses"] = { [self] _ in (200, "text/event-stream", sse([delta, completed]) + "data: [DONE]\n\n") }
        let ok = try await client().chat(system: "", text: "t", image: nil, maxTokens: 1, temperature: 0)
        XCTAssertEqual(ok.finishReason, "completed")
    }

    func testHTTPErrorsKeepTheCodeAndRequestID() async {
        RouteStub.routes["/v1/responses"] = { _ in
            (429, "application/json", "{\"error\":{\"code\":\"subscription_sharing_usage_limit_exceeded\",\"message\":\"over\"}}")
        }
        do { _ = try await client().chat(system: "", text: "t", image: nil, maxTokens: 1, temperature: 0); XCTFail() } catch {
            let m = error.localizedDescription
            XCTAssertTrue(m.contains("HTTP 429") && m.contains("subscription_sharing_usage_limit_exceeded") && m.contains("req_test"), m)
        }
        XCTAssertEqual(RouteStub.seen.count, 1)  // never retried, never sent elsewhere
    }

    func testNoTokenMeansNoRequestAndNoFallback() async {
        do {
            _ = try await client({ throw ChatGPTAuthError.notSignedIn }).chat(system: "", text: "t", image: nil, maxTokens: 1, temperature: 0)
            XCTFail("expected not signed in")
        } catch { XCTAssertEqual(error as? ChatGPTAuthError, .notSignedIn) }
        XCTAssertTrue(RouteStub.seen.isEmpty)
    }

    func testModelCatalog() async throws {
        RouteStub.routes["/v1/models"] = { _ in
            (200, "application/json", "{\"data\":[{\"id\":\"gpt-a\"},{\"id\":\"gpt-b\"},{\"id\":\"gpt-a\"}]}")
        }
        let ids = try await ResponsesClient.models(token: "at_live", session: RouteStub.session())
        XCTAssertEqual(ids, ["gpt-a", "gpt-b"])
        XCTAssertEqual(RouteStub.seen.first?.headers["Authorization"], "Bearer at_live")
        RouteStub.routes["/v1/models"] = { _ in
            (200, "application/json", "{\"models\":[{\"slug\":\"m1\",\"visibility\":\"list\"},{\"slug\":\"m2\",\"visibility\":\"hide\"}]}")
        }
        let slugs = try await ResponsesClient.models(token: "at_live", session: RouteStub.session())
        XCTAssertEqual(slugs, ["m1"])
    }

    // MARK: provider regression: the API-key path is unchanged and separate

    func testAPIKeyEndpointStillUsesChatCompletionsWithItsOwnKey() async throws {
        RouteStub.routes["/v1/chat/completions"] = { _ in
            (200, "application/json", "{\"choices\":[{\"message\":{\"content\":\"DONE: ok\"},\"finish_reason\":\"stop\"}]}")
        }
        let llm = LLMClient(baseURL: "https://example.test/v1", model: "m", apiKey: "sk-test", session: RouteStub.session())
        let r = try await llm.chat(system: "S", text: "t", image: nil, maxTokens: 10, temperature: 0)
        XCTAssertEqual(r.text, "DONE: ok")
        XCTAssertEqual(RouteStub.seen.map(\.url.path), ["/v1/chat/completions"])
        XCTAssertEqual(RouteStub.seen.first?.headers["Authorization"], "Bearer sk-test")
    }

    func testTaskAgentBackendsAreSeparate() {
        let endpoint = ModelEndpoint(baseURL: "https://example.test/v1", model: "m", apiKey: "sk-test")
        let keyed = TaskAgent(provider: FakeProvider([]), endpoint: endpoint, tapper: FakeTapper(), policy: GatePolicy())
        XCTAssertTrue(keyed.model is LLMClient)
        XCTAssertEqual((keyed.model as? LLMClient)?.baseURL.absoluteString, "https://example.test/v1")
        let plan = TaskAgent(provider: FakeProvider([]), chatGPT: client(), tapper: FakeTapper(), policy: GatePolicy())
        XCTAssertTrue(plan.model is ResponsesClient)
        XCTAssertEqual(ModelProvider.allCases.count, 7)  // presets untouched; ChatGPT is not an API-key preset
    }
}
