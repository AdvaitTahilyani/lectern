import Foundation
import LecternCore

/// Chat Completions provider for OpenAI and for OpenAI-compatible local servers (Ollama, LM Studio,
/// `mlx_lm.server`). Supports SSE streaming, JSON mode and reasoning control.
///
/// Reasoning: OpenAI reasoning models get `reasoning_effort`; local servers get
/// `reasoning_effort: "none"` for `.off`, which Ollama honours (verified with `gemma4:12b`; its
/// `think` flag is not part of the OpenAI-compatible endpoint). Any inline `<think>` text is
/// stripped from the output.
public struct OpenAICompatibleProvider: LLMProvider {
    /// Which dialect of the API to speak.
    public enum Flavor: Sendable, Hashable {
        /// api.openai.com: `max_completion_tokens`, strict structured outputs, key required.
        case openAI
        /// Ollama / LM Studio / vLLM-style servers: `max_tokens`, no key by default.
        case localServer
    }

    public static let openAIBaseURL = URL(string: "https://api.openai.com/v1")!
    public static let ollamaBaseURL = URL(string: "http://localhost:11434/v1")!
    public static let lmStudioBaseURL = URL(string: "http://localhost:1234/v1")!

    static let truncatedMessage =
        "The model ran out of output tokens before producing an answer (reasoning may have used the budget)."

    static func refusedMessage(_ reason: String) -> String { "The model declined to answer: \(reason)" }

    public let flavor: Flavor
    public let baseURL: URL
    public let model: String
    private let apiKey: String?
    private let transport: HTTPTransport

    public var kind: ProviderKind { flavor == .openAI ? .openAI : .localServer }

    /// - Parameters:
    ///   - baseURL: Root of the API, e.g. `https://api.openai.com/v1`. A bare host such as
    ///     `http://localhost:11434` gets `/v1` appended.
    ///   - apiKey: Sent as a bearer token when non-empty. Required for `.openAI`.
    ///   - session: Override for tests.
    ///   - retryDelay: Backoff before the single automatic retry of `complete`.
    public init(
        flavor: Flavor,
        baseURL: URL,
        model: String,
        apiKey: String? = nil,
        session: URLSession = LLMSession.default,
        retryDelay: TimeInterval = 0.75
    ) {
        self.flavor = flavor
        self.baseURL = Self.normalized(baseURL)
        self.model = model
        self.apiKey = apiKey.flatMap { $0.isEmpty ? nil : $0 }
        self.transport = HTTPTransport(
            session: session,
            kind: flavor == .openAI ? .openAI : .localServer,
            model: model,
            retryDelay: retryDelay
        )
    }

    /// OpenAI preset (base `https://api.openai.com/v1`).
    public static func openAI(
        apiKey: String,
        model: String,
        baseURL: URL = openAIBaseURL,
        session: URLSession = LLMSession.default
    ) -> OpenAICompatibleProvider {
        OpenAICompatibleProvider(flavor: .openAI, baseURL: baseURL, model: model, apiKey: apiKey, session: session)
    }

    /// Local-server preset, e.g. Ollama `http://localhost:11434/v1` or LM Studio `http://localhost:1234/v1`.
    public static func localServer(
        baseURL: URL,
        model: String,
        apiKey: String? = nil,
        session: URLSession = LLMSession.default
    ) -> OpenAICompatibleProvider {
        OpenAICompatibleProvider(flavor: .localServer, baseURL: baseURL, model: model, apiKey: apiKey, session: session)
    }

    // MARK: LLMProvider

    public func complete(_ request: LLMRequest) async throws -> LLMResponse {
        let urlRequest = try makeURLRequest(path: "chat/completions", body: makeBody(request, stream: false))
        let data = try await transport.send(urlRequest)
        let completion: OpenAIWire.Completion
        do {
            completion = try OpenAIWire.decoder.decode(OpenAIWire.Completion.self, from: data)
        } catch {
            throw LLMError.invalidResponse("Couldn't decode the completion: \(String(decoding: data.prefix(200), as: UTF8.self))")
        }
        guard let choice = completion.choices?.first else {
            throw LLMError.invalidResponse("The response contained no choices.")
        }
        let text = ThinkStripper.strip(choice.message?.content ?? "")
        if text.isEmpty, let refusal = choice.message?.refusal, !refusal.isEmpty {
            throw LLMError.invalidResponse(Self.refusedMessage(refusal))
        }
        if text.isEmpty && choice.finishReason == "length" {
            throw LLMError.invalidResponse(Self.truncatedMessage)
        }
        return LLMResponse(text: text, usage: completion.usage?.llmUsage)
    }

    public func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        do {
            let urlRequest = try makeURLRequest(path: "chat/completions", body: makeBody(request, stream: true))
            return transport.stream(urlRequest, decoder: OpenAIStreamDecoder())
        } catch {
            let mapped = transport.mapError(error)
            return AsyncThrowingStream { $0.finish(throwing: mapped) }
        }
    }

    public func healthCheck() async throws {
        let ids = try await Self.listModels(
            baseURL: baseURL, apiKey: try requireKey(), kind: kind, session: transport.session, timeout: 15
        )
        if flavor == .localServer, !ids.contains(where: { $0 == model || $0 == model + ":latest" }) {
            throw LLMError.modelNotDownloaded(model)
        }
    }

    // MARK: Model listing

    /// `GET {base}/models`: the model ids the server offers.
    static func listModels(
        baseURL: URL, apiKey: String?, kind: ProviderKind, session: URLSession, timeout: TimeInterval
    ) async throws -> [String] {
        let base = normalized(baseURL)
        var headers: [String: String] = [:]
        if let apiKey, !apiKey.isEmpty { headers["Authorization"] = "Bearer \(apiKey)" }
        let request = try URLRequest.json(
            url: base.appending(path: "models"), method: "GET", headers: headers, timeout: timeout
        )
        let transport = HTTPTransport(session: session, kind: kind, model: "", retryDelay: 0.5)
        let data = try await transport.send(request)
        do {
            return try OpenAIWire.decoder.decode(OpenAIWire.ModelList.self, from: data).data.map { $0.map(\.id) } ?? []
        } catch {
            throw LLMError.invalidResponse("Couldn't decode the model list.")
        }
    }

    // MARK: Request building

    /// Appends `/v1` to a bare host URL so users can paste `http://localhost:11434`.
    static func normalized(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = path.isEmpty ? "/v1" : "/" + path
        return components.url ?? url
    }

    private func requireKey() throws -> String? {
        if flavor == .openAI && apiKey == nil { throw LLMError.missingAPIKey(.openAI) }
        return apiKey
    }

    private func makeURLRequest(path: String, body: [String: Any]) throws -> URLRequest {
        var headers: [String: String] = [:]
        if let key = try requireKey() { headers["Authorization"] = "Bearer \(key)" }
        return try URLRequest.json(
            url: baseURL.appending(path: path),
            body: body,
            headers: headers,
            timeout: flavor == .openAI ? 120 : 300  // cold local prefill can take 30 s+ before the first byte
        )
    }

    /// The JSON body for `request`. Internal so tests can assert on it.
    func makeBody(_ request: LLMRequest, stream: Bool) throws -> [String: Any] {
        var messages = request.messages.map { ["role": $0.role.rawValue, "content": $0.content] }
        var body: [String: Any] = ["model": model, "stream": stream]
        if stream { body["stream_options"] = ["include_usage": true] }

        switch flavor {
        case .openAI:
            let traits = OpenAIModelTraits(model: model)
            body["max_completion_tokens"] = request.maxTokens
            if traits.acceptsEffort { body["reasoning_effort"] = traits.effort(for: request.reasoning) }
            if traits.acceptsTemperature(at: request.reasoning) { body["temperature"] = request.temperature }
        case .localServer:
            body["max_tokens"] = request.maxTokens
            body["temperature"] = request.temperature
            body["reasoning_effort"] = request.reasoning == .off ? "none" : request.reasoning.rawValue
        }

        if case .json = request.responseFormat {
            let schema = try request.responseFormat.schemaObject()
            switch (flavor, schema) {
            case (.openAI, let schema?):
                body["response_format"] = [
                    "type": "json_schema",
                    "json_schema": ["name": "response", "strict": true, "schema": schema] as [String: Any],
                ] as [String: Any]
            case (.openAI, nil):
                body["response_format"] = ["type": "json_object"]
                // OpenAI rejects json_object unless the word "JSON" appears in the messages.
                if !messages.contains(where: { $0["content"]?.localizedCaseInsensitiveContains("json") == true }) {
                    messages.insert(["role": "system", "content": "Respond with a single JSON object."], at: 0)
                }
            case (.localServer, _):
                // json_schema is the one structured mode Ollama and LM Studio both implement;
                // LM Studio rejects json_object.
                body["response_format"] = [
                    "type": "json_schema",
                    "json_schema": ["name": "response", "schema": schema ?? VerbatimJSON.placeholder(for: #"{"type":"object"}"#)] as [String: Any],
                ] as [String: Any]
            }
        }
        body["messages"] = messages
        return body
    }
}
