import Foundation

// MARK: - LLM contract
//
// Every model backend (in-process MLX, a local OpenAI-compatible server such as Ollama or
// LM Studio, OpenAI, Anthropic) implements `LLMProvider`. `LecternIntelligence` only ever sees
// this protocol, so backends can be swapped per role in Settings.

public enum LLMRole: String, Codable, Sendable, CaseIterable, Hashable, Identifiable {
    case summaries   // rolling takeaways + expanded summaries
    case quizzes     // question generation + grading
    case ask         // chat Q&A over slides + transcript

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .summaries: "Summaries"
        case .quizzes: "Quizzes"
        case .ask: "Ask"
        }
    }
}

public enum ProviderKind: String, Codable, Sendable, CaseIterable, Hashable, Identifiable {
    case onDevice      // MLX Swift, in-process
    case localServer   // any OpenAI-compatible server (Ollama, LM Studio, mlx_lm.server)
    case openAI
    case anthropic

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .onDevice: "On-device (MLX)"
        case .localServer: "Local server"
        case .openAI: "OpenAI"
        case .anthropic: "Anthropic"
        }
    }

    public var isCloud: Bool { self == .openAI || self == .anthropic }
}

/// Which backend + model a role uses. API keys are NOT stored here; they live in the Keychain,
/// keyed by `ProviderKind`.
public struct ProviderConfig: Codable, Sendable, Hashable {
    public var kind: ProviderKind
    /// Model identifier: an HF repo id for `.onDevice` (e.g. "mlx-community/…"), a model name for
    /// servers/APIs (e.g. "qwen3:30b-a3b", "claude-haiku-4-5").
    public var model: String
    /// Base URL for `.localServer` (e.g. http://localhost:11434/v1). Ignored otherwise unless set to
    /// override the default API endpoint.
    public var baseURL: URL?

    public init(kind: ProviderKind, model: String, baseURL: URL? = nil) {
        self.kind = kind
        self.model = model
        self.baseURL = baseURL
    }
}

public struct LLMMessage: Codable, Sendable, Hashable {
    public enum Role: String, Codable, Sendable, Hashable { case system, user, assistant }
    public var role: Role
    public var content: String

    public init(role: Role, content: String) {
        self.role = role
        self.content = content
    }

    public static func system(_ s: String) -> LLMMessage { .init(role: .system, content: s) }
    public static func user(_ s: String) -> LLMMessage { .init(role: .user, content: s) }
    public static func assistant(_ s: String) -> LLMMessage { .init(role: .assistant, content: s) }
}

public enum ResponseFormat: Sendable, Hashable {
    case text
    /// Ask for a single JSON object. `schema` is a JSON Schema (as a JSON string) that providers
    /// may enforce natively (OpenAI structured outputs, Ollama `format`) or pass as instructions.
    /// Callers must still validate/repair the output.
    case json(schema: String?)
}

public enum ReasoningEffort: String, Codable, Sendable, Hashable {
    /// No thinking: fastest. Used for frequent calls (rolling summaries).
    case off
    case low
    case medium
}

public struct LLMRequest: Sendable, Hashable {
    public var messages: [LLMMessage]
    public var maxTokens: Int
    public var temperature: Double
    public var responseFormat: ResponseFormat
    public var reasoning: ReasoningEffort

    public init(
        messages: [LLMMessage],
        maxTokens: Int = 512,
        temperature: Double = 0.3,
        responseFormat: ResponseFormat = .text,
        reasoning: ReasoningEffort = .off
    ) {
        self.messages = messages
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.responseFormat = responseFormat
        self.reasoning = reasoning
    }
}

public struct LLMUsage: Codable, Sendable, Hashable {
    public var inputTokens: Int
    public var outputTokens: Int
    public init(inputTokens: Int, outputTokens: Int) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }
}

public struct LLMResponse: Sendable, Hashable {
    /// Final visible text, with any <think>…</think> reasoning stripped.
    public var text: String
    public var usage: LLMUsage?
    public init(text: String, usage: LLMUsage? = nil) {
        self.text = text
        self.usage = usage
    }
}

public enum LLMStreamEvent: Sendable, Hashable {
    /// Incremental visible text (reasoning tokens are never emitted).
    case delta(String)
    case done(LLMUsage?)
}

public enum LLMError: Error, LocalizedError, Sendable, Hashable {
    case missingAPIKey(ProviderKind)
    case modelNotDownloaded(String)
    case http(status: Int, message: String)
    case network(String)
    case invalidResponse(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey(let k): "No API key set for \(k.displayName)."
        case .modelNotDownloaded(let m): "The model \(m) hasn't been downloaded yet."
        case .http(let s, let m): "Server error \(s): \(m)"
        case .network(let m): "Network error: \(m)"
        case .invalidResponse(let m): "Unexpected response: \(m)"
        case .cancelled: "Cancelled."
        }
    }
}

public protocol LLMProvider: Sendable {
    var kind: ProviderKind { get }
    var model: String { get }

    func complete(_ request: LLMRequest) async throws -> LLMResponse

    /// Streams visible text deltas, then `.done`. Cancelling the consuming task cancels generation.
    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error>

    /// Cheap check that the provider is reachable/configured (for "Test connection").
    func healthCheck() async throws
}

/// Per-role providers handed to the intelligence layer.
public struct RoleProviders: Sendable {
    public var summaries: any LLMProvider
    public var quizzes: any LLMProvider
    public var ask: any LLMProvider

    public init(summaries: any LLMProvider, quizzes: any LLMProvider, ask: any LLMProvider) {
        self.summaries = summaries
        self.quizzes = quizzes
        self.ask = ask
    }

    public func provider(for role: LLMRole) -> any LLMProvider {
        switch role {
        case .summaries: summaries
        case .quizzes: quizzes
        case .ask: ask
        }
    }
}
