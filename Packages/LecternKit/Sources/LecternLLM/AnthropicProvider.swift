import Foundation
import LecternCore

/// Claude via the Messages API with SSE streaming.
///
/// - The system prompt (which for Lectern holds the slide deck and is reused all lecture) is sent
///   as a top-level `system` block marked `cache_control: ephemeral`, so repeat calls read it from
///   the prompt cache. Cache hits need the prefix to be byte-identical between calls; the cache
///   applies once the prompt passes the model's minimum cacheable length.
/// - JSON mode uses structured outputs (`output_config.format`, GA, no beta header) when a schema
///   is given, and a trailing instruction otherwise.
/// - Reasoning: `.off` never enables thinking (on models where thinking is always on it maps to the
///   lowest setting). `.low` / `.medium` use a token budget on Claude 4.5-and-earlier models
///   (Haiku 4.5) and adaptive thinking with `output_config.effort` on newer ones.
/// - `LLMUsage.inputTokens` is the whole prompt, i.e. fresh plus cache-read plus cache-write tokens;
///   `cachedInputTokens` / `cacheWriteTokens` are the cache-read / cache-write parts of it.
public struct AnthropicProvider: LLMProvider {
    public static let baseURL = URL(string: "https://api.anthropic.com/v1")!
    public static let apiVersion = "2023-06-01"
    /// Cheapest current Claude; the default for frequent calls.
    public static let haiku = "claude-haiku-4-5"
    /// Stronger model for quizzes and Ask.
    public static let sonnet = "claude-sonnet-5-5"

    static let truncatedMessage =
        "The model ran out of output tokens before producing an answer (thinking may have used the budget)."
    /// Newer models decline some requests with HTTP 200 and `stop_reason: "refusal"`.
    static let refusedMessage = "The model declined to answer this request."
    static let jsonInstruction = "Respond with a single valid JSON object and nothing else: no prose, no code fences."

    public let model: String
    public let baseURL: URL
    private let apiKey: String
    private let transport: HTTPTransport

    public var kind: ProviderKind { .anthropic }

    /// - Parameters:
    ///   - apiKey: The Anthropic API key (`x-api-key`).
    ///   - session: Override for tests.
    ///   - retryDelay: Backoff before the single automatic retry of `complete`.
    public init(
        apiKey: String,
        model: String = AnthropicProvider.haiku,
        baseURL: URL = AnthropicProvider.baseURL,
        session: URLSession = LLMSession.default,
        retryDelay: TimeInterval = 0.75
    ) {
        self.apiKey = apiKey
        self.model = model
        self.baseURL = baseURL
        self.transport = HTTPTransport(session: session, kind: .anthropic, model: model, retryDelay: retryDelay)
    }

    // MARK: LLMProvider

    public func complete(_ request: LLMRequest) async throws -> LLMResponse {
        let urlRequest = try makeURLRequest(path: "messages", body: makeBody(request, stream: false))
        let data = try await transport.send(urlRequest)
        let message: AnthropicWire.Message
        do {
            message = try AnthropicWire.decoder.decode(AnthropicWire.Message.self, from: data)
        } catch {
            throw LLMError.invalidResponse("Couldn't decode the message: \(String(decoding: data.prefix(200), as: UTF8.self))")
        }
        let text = ThinkStripper.strip((message.content ?? []).filter { $0.type == "text" }.compactMap(\.text).joined())
        if message.stopReason == "refusal" {
            throw LLMError.invalidResponse(Self.refusedMessage)
        }
        if text.isEmpty && message.stopReason == "max_tokens" {
            throw LLMError.invalidResponse(Self.truncatedMessage)
        }
        return LLMResponse(text: text, usage: message.usage?.llmUsage)
    }

    public func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        do {
            let urlRequest = try makeURLRequest(path: "messages", body: makeBody(request, stream: true))
            return transport.stream(urlRequest, decoder: AnthropicStreamDecoder())
        } catch {
            let mapped = transport.mapError(error)
            return AsyncThrowingStream { $0.finish(throwing: mapped) }
        }
    }

    public func healthCheck() async throws {
        let request = try URLRequest.json(
            url: baseURL.appending(path: "models"), method: "GET", headers: try headers(), timeout: 15
        )
        _ = try await transport.send(request)
    }

    // MARK: Request building

    private func headers() throws -> [String: String] {
        guard !apiKey.isEmpty else { throw LLMError.missingAPIKey(.anthropic) }
        return ["x-api-key": apiKey, "anthropic-version": Self.apiVersion]
    }

    private func makeURLRequest(path: String, body: [String: Any]) throws -> URLRequest {
        try URLRequest.json(url: baseURL.appending(path: path), body: body, headers: headers(), timeout: 120)
    }

    /// The JSON body for `request`. Internal so tests can assert on it.
    func makeBody(_ request: LLMRequest, stream: Bool) throws -> [String: Any] {
        let traits = AnthropicModelTraits(model: model)
        var body: [String: Any] = ["model": model, "stream": stream]

        // System prompt: the caller's text is the cached prefix; the JSON instruction, if any,
        // follows in its own uncached block.
        let systemText = request.messages.filter { $0.role == .system }.map(\.content).joined(separator: "\n\n")
        var system: [[String: Any]] = []
        if !systemText.isEmpty {
            system.append(["type": "text", "text": systemText, "cache_control": ["type": "ephemeral"]])
        }
        if case .json(let schema) = request.responseFormat, schema == nil {
            system.append(["type": "text", "text": Self.jsonInstruction])
        }
        if !system.isEmpty { body["system"] = system }
        body["messages"] = try conversation(from: request.messages)

        var maxTokens = request.maxTokens
        var outputConfig: [String: Any] = [:]
        var thinkingActive = false

        switch (traits.thinking, request.reasoning) {
        case (.budget, .off), (.optionalAdaptive, .off), (.alwaysOn, .off):
            break
        case (.budget, let level):
            if let budget = AnthropicModelTraits.budgetTokens(for: level) {
                body["thinking"] = ["type": "enabled", "budget_tokens": budget]
                maxTokens += budget  // thinking tokens count against max_tokens
                thinkingActive = true
            }
        case (.disableable, .off):
            body["thinking"] = ["type": "disabled"]
        case (.betweenTools, .off):
            body["thinking"] = ["type": "between_tools"]
        case (.optionalAdaptive, let level), (.disableable, let level), (.betweenTools, let level):
            body["thinking"] = ["type": "adaptive"]
            outputConfig["effort"] = level.rawValue
            thinkingActive = true
        case (.alwaysOn, let level):
            outputConfig["effort"] = level.rawValue
            thinkingActive = true
        }
        // Always-on models can't skip thinking; keep it as light as the API allows.
        if traits.thinking == .alwaysOn, request.reasoning == .off { outputConfig["effort"] = "low" }

        body["max_tokens"] = maxTokens
        if traits.acceptsSampling && !thinkingActive { body["temperature"] = request.temperature }

        if let schema = try request.responseFormat.schemaObject() {
            outputConfig["format"] = ["type": "json_schema", "schema": schema] as [String: Any]
        }
        if !outputConfig.isEmpty { body["output_config"] = outputConfig }
        return body
    }

    /// Converts non-system messages to the API's strictly alternating user/assistant list.
    private func conversation(from messages: [LLMMessage]) throws -> [[String: Any]] {
        var merged: [(role: String, text: String)] = []
        for message in messages where message.role != .system {
            if let last = merged.last, last.role == message.role.rawValue {
                merged[merged.count - 1].text += "\n\n" + message.content
            } else {
                merged.append((message.role.rawValue, message.content))
            }
        }
        guard merged.first?.role == "user" else {
            throw LLMError.invalidResponse("An Anthropic request must start with a user message.")
        }
        guard merged.last?.role == "user" else {
            throw LLMError.invalidResponse("An Anthropic request must end with a user message (assistant prefill is not supported).")
        }
        return merged.map { ["role": $0.role, "content": $0.text] }
    }
}
