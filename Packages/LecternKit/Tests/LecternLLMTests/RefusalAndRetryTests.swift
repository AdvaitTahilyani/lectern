import Foundation
import LecternCore
import Testing
@testable import LecternLLM

/// Declined requests and `Retry-After` handling, shared by both providers.
@Suite struct RefusalAndRetryTests {
    private func openAI(_ server: StubServer) -> OpenAICompatibleProvider {
        OpenAICompatibleProvider(
            flavor: .openAI, baseURL: server.baseURL, model: "gpt-6-luna", apiKey: "k", session: server.session, retryDelay: 0.01)
    }

    private func anthropic(_ server: StubServer) -> AnthropicProvider {
        AnthropicProvider(apiKey: "k", baseURL: server.baseURL, session: server.session, retryDelay: 0.01)
    }

    private func isInvalidResponse(_ error: LLMError?, containing text: String) -> Bool {
        if case .invalidResponse(let message) = error { return message.contains(text) }
        return false
    }

    @Test func openAIRefusalIsAnError() async {
        let server = StubServer()
        server.enqueue(.json(#"{"choices":[{"message":{"content":null,"refusal":"I can't help with that."},"finish_reason":"stop"}]}"#))
        let error = await llmError { _ = try await openAI(server).complete(simpleRequest) }
        #expect(isInvalidResponse(error, containing: "I can't help with that."))
    }

    @Test func openAIStreamedRefusalIsAnError() async {
        let server = StubServer()
        server.enqueue(.sse([
            sseData(#"{"choices":[{"delta":{"refusal":"I can't "}}]}"#),
            sseData(#"{"choices":[{"delta":{"refusal":"help."},"finish_reason":"stop"}]}"#),
            "data: [DONE]\n\n",
        ]))
        let error = await llmError { _ = try await collect(openAI(server).stream(simpleRequest)) }
        #expect(isInvalidResponse(error, containing: "I can't help."))
    }

    @Test func anthropicRefusalIsAnError() async {
        let server = StubServer()
        server.enqueue(.json(#"{"content":[],"stop_reason":"refusal","usage":{"input_tokens":5,"output_tokens":0}}"#))
        let error = await llmError { _ = try await anthropic(server).complete(simpleRequest) }
        #expect(isInvalidResponse(error, containing: "declined"))
    }

    @Test func anthropicStreamedRefusalIsAnError() async {
        let server = StubServer()
        server.enqueue(.sse([
            "event: message_start\n" + sseData(#"{"type":"message_start","message":{"content":[],"usage":{"input_tokens":5,"output_tokens":0}}}"#),
            "event: message_delta\n" + sseData(#"{"type":"message_delta","delta":{"stop_reason":"refusal"},"usage":{"output_tokens":0}}"#),
            "event: message_stop\n" + sseData(#"{"type":"message_stop"}"#),
        ]))
        let error = await llmError { _ = try await collect(anthropic(server).stream(simpleRequest)) }
        #expect(isInvalidResponse(error, containing: "declined"))
    }

    @Test func aLongRetryAfterIsSurfacedInsteadOfRetriedTooEarly() async {
        let server = StubServer()
        let limited = StubResponse.json(#"{"error":{"message":"quota"}}"#, status: 429, headers: ["Retry-After": "60"])
        server.enqueue(limited, limited)
        let error = await llmError { _ = try await openAI(server).complete(simpleRequest) }
        guard case .http(429, let message) = error else { Issue.record("got \(String(describing: error))"); return }
        #expect(message.contains("Retry in 60 s"))
        #expect(server.requests.count == 1)
    }

    @Test func garbledRetryAfterValuesAreIgnored() async {
        for value in ["nan", "inf", "-5", "soon", "1e30"] {
            let server = StubServer()
            let limited = StubResponse.json(#"{"error":{"message":"quota"}}"#, status: 429, headers: ["Retry-After": value])
            server.enqueue(limited, limited)
            let error = await llmError { _ = try await openAI(server).complete(simpleRequest) }
            guard case .http(429, _) = error else { Issue.record("\(value): got \(String(describing: error))"); continue }
            // "1e30" is finite but capped to a day, so it is surfaced rather than waited out;
            // the others fall back to the short default delay and retry once.
            #expect(server.requests.count == (value == "1e30" ? 1 : 2), "\(value)")
        }
    }
}
