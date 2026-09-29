import Foundation
import LecternCore

/// Decodable shapes for the parts of the Chat Completions API Lectern reads.
enum OpenAIWire {
    struct Usage: Decodable {
        var promptTokens: Int?
        var completionTokens: Int?

        var llmUsage: LLMUsage? {
            guard let promptTokens, let completionTokens else { return nil }
            return LLMUsage(inputTokens: promptTokens, outputTokens: completionTokens)
        }
    }

    struct ErrorBody: Decodable {
        var message: String?
    }

    /// Non-streaming response.
    struct Completion: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { var content: String? }
            var message: Message?
            var finishReason: String?
        }
        var choices: [Choice]?
        var usage: Usage?
    }

    /// One SSE `data:` payload of a streaming response.
    struct Chunk: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable { var content: String? }
            var delta: Delta?
            var finishReason: String?
        }
        var choices: [Choice]?
        var usage: Usage?
        var error: ErrorBody?
    }

    struct ModelList: Decodable {
        struct Entry: Decodable { var id: String }
        var data: [Entry]?
    }

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()
}

/// Turns Chat Completions SSE events into visible-text deltas, hiding `<think>` reasoning.
struct OpenAIStreamDecoder: SSEDecoder {
    private var filter = StreamingThinkFilter()
    private var usage: LLMUsage?
    private var finishReason: String?
    private var emittedText = false
    private var finished = false

    init() {}

    mutating func consume(_ event: SSEEvent) throws -> [LLMStreamEvent] {
        let payload = event.data.trimmingCharacters(in: .whitespacesAndNewlines)
        if payload == "[DONE]" { return try finishStream() }
        guard let data = payload.data(using: .utf8) else { return [] }
        let chunk: OpenAIWire.Chunk
        do {
            chunk = try OpenAIWire.decoder.decode(OpenAIWire.Chunk.self, from: data)
        } catch {
            throw LLMError.invalidResponse("Couldn't decode a streamed chunk: \(payload.prefix(200))")
        }
        if let error = chunk.error {
            throw LLMError.http(status: 500, message: error.message ?? "The server reported an error mid-stream.")
        }
        if let usage = chunk.usage?.llmUsage { self.usage = usage }
        var out: [LLMStreamEvent] = []
        for choice in chunk.choices ?? [] {
            if let reason = choice.finishReason { finishReason = reason }
            if let content = choice.delta?.content, !content.isEmpty {
                append(filter.consume(content), to: &out)
            }
        }
        return out
    }

    mutating func finish() throws -> [LLMStreamEvent] { try finishStream() }

    private mutating func finishStream() throws -> [LLMStreamEvent] {
        guard !finished else { return [] }
        finished = true
        var out: [LLMStreamEvent] = []
        append(filter.finish(), to: &out)
        if !emittedText && finishReason == "length" {
            throw LLMError.invalidResponse(OpenAICompatibleProvider.truncatedMessage)
        }
        out.append(.done(usage))
        return out
    }

    /// Emits `text` as a delta, dropping whitespace before the first visible character
    /// (models often emit "\n\n" after a reasoning block).
    private mutating func append(_ text: String, to out: inout [LLMStreamEvent]) {
        var text = Substring(text)
        if !emittedText { text = text.drop(while: \.isWhitespace) }
        guard !text.isEmpty else { return }
        emittedText = true
        out.append(.delta(String(text)))
    }
}
