import Foundation
import LecternCore

/// Decodable shapes for the parts of the Messages API Lectern reads.
enum AnthropicWire {
    struct Usage: Decodable {
        var inputTokens: Int?
        var outputTokens: Int?
        var cacheCreationInputTokens: Int?
        var cacheReadInputTokens: Int?

        /// `input_tokens` excludes cached tokens on this API, so the prompt size is the sum.
        var totalInput: Int? {
            guard inputTokens != nil || cacheReadInputTokens != nil || cacheCreationInputTokens != nil else { return nil }
            return (inputTokens ?? 0) + (cacheReadInputTokens ?? 0) + (cacheCreationInputTokens ?? 0)
        }
    }

    struct ErrorBody: Decodable {
        var type: String?
        var message: String?

        /// The HTTP status this error type corresponds to (for errors delivered inside a 200 stream).
        var status: Int {
            switch type {
            case "overloaded_error": 529
            case "rate_limit_error": 429
            case "api_error": 500
            case "authentication_error": 401
            case "permission_error": 403
            case "not_found_error": 404
            default: 400
            }
        }
    }

    struct Message: Decodable {
        struct Block: Decodable {
            var type: String
            var text: String?
        }
        var content: [Block]?
        var stopReason: String?
        var usage: Usage?
    }

    /// One SSE `data:` payload; which fields are present depends on `type`.
    struct StreamEvent: Decodable {
        struct Delta: Decodable {
            var type: String?
            var text: String?
            var stopReason: String?
        }
        var type: String
        var message: Message?
        var delta: Delta?
        var usage: Usage?
        var error: ErrorBody?
    }

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()
}

/// Turns Messages API SSE events into visible-text deltas. Thinking deltas are ignored.
struct AnthropicStreamDecoder: SSEDecoder {
    private var inputTokens: Int?
    private var outputTokens: Int?
    private var stopReason: String?
    private var emittedText = false
    private var finished = false

    init() {}

    mutating func consume(_ event: SSEEvent) throws -> [LLMStreamEvent] {
        guard let data = event.data.data(using: .utf8) else { return [] }
        let parsed: AnthropicWire.StreamEvent
        do {
            parsed = try AnthropicWire.decoder.decode(AnthropicWire.StreamEvent.self, from: data)
        } catch {
            throw LLMError.invalidResponse("Couldn't decode a streamed event: \(event.data.prefix(200))")
        }
        switch parsed.type {
        case "message_start":
            if let usage = parsed.message?.usage {
                inputTokens = usage.totalInput ?? inputTokens
                outputTokens = usage.outputTokens ?? outputTokens
            }
            return []
        case "content_block_delta":
            guard parsed.delta?.type == "text_delta", var text = parsed.delta?.text else { return [] }
            if !emittedText { text = String(text.drop(while: \.isWhitespace)) }
            guard !text.isEmpty else { return [] }
            emittedText = true
            return [.delta(text)]
        case "message_delta":
            if let usage = parsed.usage {
                inputTokens = usage.totalInput ?? inputTokens
                outputTokens = usage.outputTokens ?? outputTokens
            }
            stopReason = parsed.delta?.stopReason ?? stopReason
            return []
        case "message_stop":
            return try finishStream()
        case "error":
            let error = parsed.error
            throw LLMError.http(status: error?.status ?? 500, message: error?.message ?? "The server reported an error mid-stream.")
        default:
            return []  // ping, content_block_start/stop, and event types added in future
        }
    }

    mutating func finish() throws -> [LLMStreamEvent] {
        guard finished else {
            throw LLMError.invalidResponse("The stream ended before the message was complete.")
        }
        return []
    }

    private mutating func finishStream() throws -> [LLMStreamEvent] {
        guard !finished else { return [] }
        finished = true
        if !emittedText && stopReason == "max_tokens" {
            throw LLMError.invalidResponse(AnthropicProvider.truncatedMessage)
        }
        let usage = inputTokens.flatMap { input in outputTokens.map { LLMUsage(inputTokens: input, outputTokens: $0) } }
        return [.done(usage)]
    }
}
