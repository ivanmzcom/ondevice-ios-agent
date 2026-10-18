import Foundation

// EXPERIMENTAL (Debug builds only). The Responses wire format for ChatGPT plan usage, per
// https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference and /preview-limitations.
// Separate from the vendored LLMClient (Chat Completions + API key), which stays byte-identical to upstream.

/// ChatGPT plan inference: `POST https://api.openai.com/v1/responses` with the signed-in account's access token,
/// `store: false`, `stream: true`, the system prompt as `instructions`, and none of the parameters the preview
/// rejects (`temperature`, `max_output_tokens`, `metadata`, `user`, `top_p`, `truncation`, `previous_response_id`).
/// Success is only a `response.completed` event. There is no API key here and no fallback to one.
@MainActor public final class ResponsesClient: ChatModel {
    public static let baseURL = URL(string: ChatGPTAuth.resource)!
    public let model: String
    /// Token usage of the last completed response (input_tokens, output_tokens, …), for the account row.
    public private(set) var lastUsage: [String: Int] = [:]
    /// EXPERIMENTAL Fast mode (https://developers.openai.com/api/docs/guides/fast-mode). Opt-in, default off, read
    /// from `defaults` on every request. Whether a ChatGPT plan may use it is UNVERIFIED (FAST_MODE_REPORT.md).
    public static let fastPreferenceKey = "chatgpt.fastMode.experimental"
    /// What the last request asked for (`"fast"` or nil = omitted) and the `service_tier` its `response.completed`
    /// reported (nil = not confirmed: failed, or the server sent none). Mirrored to `defaults` for the settings row.
    public static let lastRequestedTierKey = "chatgpt.fastMode.lastRequestedTier"
    public static let lastConfirmedTierKey = "chatgpt.fastMode.lastConfirmedTier"
    public private(set) var lastRequestedServiceTier: String?
    public private(set) var lastServiceTier: String?
    private let token: @MainActor () async throws -> String
    private let session: URLSession
    private let defaults: UserDefaults

    public convenience init(model: String, token: @escaping @MainActor () async throws -> String) {
        self.init(model: model, token: token, session: nil)
    }

    init(model: String, token: @escaping @MainActor () async throws -> String, session: URLSession?,
         defaults: UserDefaults = .standard) {
        self.model = model
        self.token = token
        self.defaults = defaults
        self.session = session ?? {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 30  // no byte for this long = hung; the agent retries
            config.timeoutIntervalForResource = 90
            return URLSession(configuration: config)
        }()
    }

    /// `maxTokens` and `temperature` are deliberately not sent: the plan-usage preview rejects them.
    func chat(system: String, text: String, image: Data?, maxTokens: Int, temperature: Double) async throws -> ChatResult {
        let started = now()
        // Sampled per request; the same model, endpoint and token either way. A rejection of the tier is thrown
        // like any other failure: never resent without it or at another tier.
        let tier: String? = defaults.bool(forKey: Self.fastPreferenceKey) ? "fast" : nil
        record(requested: tier, confirmed: nil)
        let body = Self.body(model: model, system: system, text: text, images: image.map { [$0] } ?? [], serviceTier: tier)
        var request = URLRequest(url: Self.baseURL.appendingPathComponent("responses"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        // A token failure (not signed in, refresh refused) ends the call here: nothing is sent anywhere else.
        request.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        DebugLog.write("chatgpt-plan → \(model): \(image == nil ? 0 : 1) image(s), \(text.count) chars, service_tier \(tier ?? "omitted")")

        let (bytes, response) = try await session.bytes(for: request)
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            var raw = Data()
            for try await b in bytes { raw.append(b) }
            let message = Self.failure(status: status, body: raw, requestID: http?.value(forHTTPHeaderField: "x-request-id"))
            DebugLog.write("chatgpt-plan ✗ \(message)")
            throw LLMError(message: message)
        }
        var (result, confirmed) = try await Self.readCompleted(bytes.lines, started: started)
        result.total = now() - started
        lastUsage = result.usage
        record(requested: tier, confirmed: confirmed)
        DebugLog.write(String(format: "chatgpt-plan ← completed, %.1f s, %d chars, service_tier %@", result.total,
                              result.text.count, confirmed ?? "not confirmed"))
        return result
    }

    private func record(requested: String?, confirmed: String?) {
        lastRequestedServiceTier = requested
        lastServiceTier = confirmed
        defaults.set(requested, forKey: Self.lastRequestedTierKey)
        defaults.set(confirmed, forKey: Self.lastConfirmedTierKey)
    }

    static func body(model: String, system: String, text: String, images: [Data], serviceTier: String? = nil) -> [String: Any] {
        var content: [[String: Any]] = images.map {
            ["type": "input_image", "image_url": "data:image/jpeg;base64," + $0.base64EncodedString()]
        }
        content.append(["type": "input_text", "text": text])
        var body: [String: Any] = ["model": model, "instructions": system, "input": [["role": "user", "content": content]],
                                   "store": false, "stream": true]
        if let serviceTier { body["service_tier"] = serviceTier }
        return body
    }

    /// Reads a Responses SSE stream through its terminal event. Only `response.completed` is a success;
    /// `response.failed`, `response.incomplete`, `error` and a stream that just ends are all failures.
    static func read(_ lines: AsyncLineSequence<URLSession.AsyncBytes>, started: Double) async throws -> ChatResult {
        try await readCompleted(lines, started: started).result
    }

    /// `read`, plus the `service_tier` that `response.completed` reports as the tier that actually processed it.
    static func readCompleted(_ lines: AsyncLineSequence<URLSession.AsyncBytes>, started: Double) async throws
        -> (result: ChatResult, serviceTier: String?) {
        var result = ChatResult(text: "", firstToken: nil, total: 0)
        for try await line in lines {
            guard line.hasPrefix("data:") else { continue }  // `event:` lines repeat the JSON `type`
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let json = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any] else { continue }
            let response = json["response"] as? [String: Any]
            switch json["type"] as? String ?? "" {
            case "response.output_text.delta":
                guard let piece = json["delta"] as? String, !piece.isEmpty else { continue }
                if result.firstToken == nil { result.firstToken = now() - started }
                result.text += piece
            case "response.reasoning_summary_text.delta", "response.reasoning_text.delta":
                result.reasoningChars += (json["delta"] as? String ?? "").count
            case "response.completed":
                result.finishReason = "completed"
                if let usage = response?["usage"] as? [String: Any] { result.usage = Self.usage(usage) }
                result.rawChars = result.text.count
                let tier = (response?["service_tier"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                return (result, tier)
            case "response.incomplete":
                let reason = (response?["incomplete_details"] as? [String: Any])?["reason"] as? String ?? "unknown"
                throw LLMError(message: "ChatGPT plan: response incomplete (\(reason))")
            case "response.failed", "error":
                let error = response?["error"] as? [String: Any] ?? json["error"] as? [String: Any] ?? json
                throw LLMError(message: describe(code: error["code"] as? String, message: error["message"] as? String,
                                                 status: nil, requestID: nil))
            default: continue
            }
        }
        throw LLMError(message: "ChatGPT plan: stream ended without response.completed")
    }

    /// Top-level counters plus the nested ones the server reports (`output_tokens_details.reasoning_tokens`,
    /// `input_tokens_details.cached_tokens`), flattened for timings. Reported values only, never estimated.
    nonisolated static func usage(_ usage: [String: Any]) -> [String: Int] {
        var flat = usage.compactMapValues { $0 as? Int }
        if let n = (usage["output_tokens_details"] as? [String: Any])?["reasoning_tokens"] as? Int { flat["reasoning_tokens"] = n }
        if let n = (usage["input_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int { flat["cached_input_tokens"] = n }
        return flat
    }

    /// An error before the stream opened: a Responses `error` object or a `{"detail": …}` reply.
    static func failure(status: Int, body: Data, requestID: String?) -> String {
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let error = json?["error"] as? [String: Any]
        let message = error?["message"] as? String ?? json?["detail"] as? String
            ?? String(decoding: body.prefix(200), as: UTF8.self)
        return describe(code: error?["code"] as? String, message: message, status: status, requestID: requestID)
    }

    /// The exact code (verbatim, e.g. `subscription_sharing_usage_limit_exceeded`), status and request ID.
    static func describe(code: String?, message: String?, status: Int?, requestID: String?) -> String {
        var parts = [status.map { "HTTP \($0)" }, code].compactMap { $0 }
        if let message, !message.isEmpty { parts.append(String(message.prefix(300))) }
        if let requestID { parts.append("request \(requestID)") }
        var text = "ChatGPT plan: " + parts.joined(separator: " · ")
        if code == "subscription_sharing_usage_limit_exceeded" { text += " (plan usage limit; see Manage usage. Not retried on another billing path.)" }
        return text
    }

    /// The model ids from GET /v1/models with the plan token (`data[].id`, or `models[].slug` shown as "list").
    public static func models(token: String, session: URLSession = .shared) async throws -> [String] {
        var request = URLRequest(url: baseURL.appendingPathComponent("models"), timeoutInterval: 20)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        guard let status = http?.statusCode, (200..<300).contains(status) else {
            throw LLMError(message: failure(status: http?.statusCode ?? 0, body: data,
                                            requestID: http?.value(forHTTPHeaderField: "x-request-id")))
        }
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let list = (json?["data"] as? [[String: Any]]) ?? (json?["models"] as? [[String: Any]]) ?? []
        var seen = Set<String>()
        return list.filter { ($0["visibility"] as? String).map { $0 == "list" } ?? true }
            .compactMap { ($0["id"] ?? $0["slug"]) as? String }.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}
