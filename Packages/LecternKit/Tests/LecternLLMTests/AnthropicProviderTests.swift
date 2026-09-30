import Foundation
import LecternCore
import Testing
@testable import LecternLLM

@Suite struct AnthropicProviderTests {
    private let schema = #"{"type":"object","properties":{"a":{"type":"string"}},"required":["a"],"additionalProperties":false}"#

    private func provider(_ server: StubServer, model: String = AnthropicProvider.haiku, key: String = "sk-ant-test") -> AnthropicProvider {
        AnthropicProvider(apiKey: key, model: model, baseURL: server.baseURL, session: server.session, retryDelay: 0.01)
    }

    private func body(_ model: String, _ request: LLMRequest = simpleRequest, stream: Bool = false) throws -> [String: Any] {
        try wireJSON(provider(StubServer(), model: model).makeBody(request, stream: stream))
    }

    private func withReasoning(_ level: ReasoningEffort) -> LLMRequest {
        var request = simpleRequest
        request.reasoning = level
        return request
    }

    // MARK: Request bodies

    @Test func systemPromptIsTopLevelCachedBlock() throws {
        let json = try body(AnthropicProvider.haiku)
        let system = try #require(json["system"] as? [[String: Any]])
        #expect(system.count == 1)
        #expect(system[0]["text"] as? String == "You are helpful.")
        #expect((system[0]["cache_control"] as? [String: String])?["type"] == "ephemeral")
        let messages = try #require(json["messages"] as? [[String: String]])
        #expect(messages == [["role": "user", "content": "Hi"]])
        #expect(json["max_tokens"] as? Int == 100)
    }

    @Test func multipleSystemMessagesJoinAndConsecutiveTurnsMerge() throws {
        let request = LLMRequest(messages: [
            .system("A"), .user("one"), .user("two"), .assistant("reply"), .system("B"), .user("three"),
        ])
        let json = try body(AnthropicProvider.haiku, request)
        #expect((json["system"] as? [[String: Any]])?.first?["text"] as? String == "A\n\nB")
        let messages = try #require(json["messages"] as? [[String: String]])
        #expect(messages.map { $0["role"]! } == ["user", "assistant", "user"])
        #expect(messages[0]["content"] == "one\n\ntwo")
    }

    @Test func conversationMustStartAndEndWithUser() {
        let noUser = LLMRequest(messages: [.system("A")])
        #expect(throws: LLMError.self) { try body(AnthropicProvider.haiku, noUser) }
        let prefill = LLMRequest(messages: [.user("q"), .assistant("The answer is")])
        #expect(throws: LLMError.self) { try body(AnthropicProvider.haiku, prefill) }
    }

    @Test func haikuOffSendsTemperatureAndNoThinking() throws {
        let json = try body(AnthropicProvider.haiku)
        #expect(json["thinking"] == nil)
        #expect(json["temperature"] as? Double == 0.3)
        #expect(json["output_config"] == nil)
    }

    @Test func haikuThinkingUsesBudgetAndRaisesMaxTokens() throws {
        let json = try body(AnthropicProvider.haiku, withReasoning(.medium))
        let thinking = try #require(json["thinking"] as? [String: Any])
        #expect(thinking["type"] as? String == "enabled")
        #expect(thinking["budget_tokens"] as? Int == 4096)
        #expect(json["max_tokens"] as? Int == 100 + 4096)
        #expect(json["temperature"] == nil)
        let low = try body(AnthropicProvider.haiku, withReasoning(.low))
        #expect((low["thinking"] as? [String: Any])?["budget_tokens"] as? Int == 1024)
    }

    @Test func sonnet55OffUsesBetweenToolsAndNoSampling() throws {
        let json = try body(AnthropicProvider.sonnet)
        #expect((json["thinking"] as? [String: String])?["type"] == "between_tools")
        #expect(json["temperature"] == nil)
    }

    @Test func sonnet55ThinkingIsAdaptiveWithEffort() throws {
        let json = try body(AnthropicProvider.sonnet, withReasoning(.low))
        #expect((json["thinking"] as? [String: String])?["type"] == "adaptive")
        #expect((json["output_config"] as? [String: Any])?["effort"] as? String == "low")
    }

    @Test func otherGenerationsFollowTheirThinkingTable() throws {
        #expect((try body("claude-sonnet-5")["thinking"] as? [String: String])?["type"] == "disabled")
        #expect(try body("claude-opus-4-8")["thinking"] == nil)
        #expect(try body("claude-sonnet-4-6")["temperature"] as? Double == 0.3)
        // Always-on models cannot skip thinking; effort is the only lever.
        let opus = try body("claude-opus-5-5")
        #expect(opus["thinking"] == nil)
        #expect((opus["output_config"] as? [String: Any])?["effort"] as? String == "low")
    }

    @Test func schemaUsesStructuredOutputsWithoutBetaHeader() async throws {
        var request = simpleRequest
        request.responseFormat = .json(schema: schema)
        let json = try body(AnthropicProvider.haiku, request)
        let format = try #require((json["output_config"] as? [String: Any])?["format"] as? [String: Any])
        #expect(format["type"] as? String == "json_schema")
        #expect((format["schema"] as? [String: Any])?["additionalProperties"] as? Bool == false)
        #expect((json["system"] as? [[String: Any]])?.count == 1)

        let server = StubServer()
        server.enqueue(.json(#"{"content":[{"type":"text","text":"{}"}],"usage":{"input_tokens":1,"output_tokens":1}}"#))
        _ = try await provider(server).complete(request)
        #expect(server.requests.first?.headers["anthropic-beta"] == nil)
    }

    @Test func jsonWithoutSchemaAddsUncachedInstructionBlockAfterCachedPrompt() throws {
        var request = simpleRequest
        request.responseFormat = .json(schema: nil)
        let system = try #require(try body(AnthropicProvider.haiku, request)["system"] as? [[String: Any]])
        #expect(system.count == 2)
        #expect(system[0]["cache_control"] != nil)
        #expect(system[1]["cache_control"] == nil)
        #expect((system[1]["text"] as? String)?.contains("JSON") == true)
    }

    @Test func effortAndFormatMergeIntoOneOutputConfig() throws {
        var request = withReasoning(.medium)
        request.responseFormat = .json(schema: schema)
        let config = try #require(try body(AnthropicProvider.sonnet, request)["output_config"] as? [String: Any])
        #expect(config["effort"] as? String == "medium")
        #expect(config["format"] != nil)
    }

    // MARK: complete

    @Test func completeSendsHeadersAndParsesUsageIncludingCache() async throws {
        let server = StubServer()
        server.enqueue(.json(#"""
        {"content":[{"type":"thinking","thinking":""},{"type":"text","text":"Hello "},{"type":"text","text":"there"}],
         "stop_reason":"end_turn",
         "usage":{"input_tokens":10,"cache_creation_input_tokens":0,"cache_read_input_tokens":2000,"output_tokens":7}}
        """#))
        let response = try await provider(server).complete(simpleRequest)
        #expect(response.text == "Hello there")
        #expect(response.usage == LLMUsage(inputTokens: 2010, outputTokens: 7, cachedInputTokens: 2000, cacheWriteTokens: 0))
        let sent = try #require(server.requests.first)
        #expect(sent.url.path == "/v1/messages")
        #expect(sent.headers["x-api-key"] == "sk-ant-test")
        #expect(sent.headers["anthropic-version"] == "2023-06-01")
        #expect(sent.json["stream"] as? Bool == false)
    }

    @Test func emptyKeyFailsBeforeAnyRequest() async {
        let server = StubServer()
        let error = await llmError { _ = try await provider(server, key: "").complete(simpleRequest) }
        #expect(error == .missingAPIKey(.anthropic))
        #expect(server.requests.isEmpty)
    }

    @Test func maxTokensStopWithNoTextIsAnError() async {
        let server = StubServer()
        server.enqueue(.json(#"{"content":[{"type":"thinking","thinking":""}],"stop_reason":"max_tokens","usage":{"input_tokens":1,"output_tokens":100}}"#))
        let error = await llmError { _ = try await provider(server).complete(simpleRequest) }
        guard case .invalidResponse = error else { Issue.record("got \(String(describing: error))"); return }
    }

    @Test func errorsAreMappedAndOverloadRetriesOnce() async throws {
        let unauthorized = StubServer()
        unauthorized.enqueue(.json(#"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#, status: 401))
        let error = await llmError { _ = try await provider(unauthorized).complete(simpleRequest) }
        guard case .http(401, let message) = error else { Issue.record("got \(String(describing: error))"); return }
        #expect(message.contains("invalid x-api-key"))

        let overloaded = StubServer()
        overloaded.enqueue(
            .json(#"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#, status: 529),
            .json(#"{"content":[{"type":"text","text":"ok"}],"usage":{"input_tokens":1,"output_tokens":1}}"#)
        )
        #expect(try await provider(overloaded).complete(simpleRequest).text == "ok")
        #expect(overloaded.requests.count == 2)
    }

    // MARK: streaming

    private func event(_ name: String, _ json: String) -> String { "event: \(name)\ndata: \(json)\n\n" }

    @Test func streamYieldsTextDeltasIgnoresThinkingAndReportsCumulativeUsage() async throws {
        let server = StubServer()
        server.enqueue(.sse([
            event("message_start", #"{"type":"message_start","message":{"id":"m","content":[],"usage":{"input_tokens":25,"cache_read_input_tokens":1000,"cache_creation_input_tokens":0,"output_tokens":1}}}"#),
            event("content_block_start", #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#),
            event("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"hmm"}}"#),
            event("content_block_stop", #"{"type":"content_block_stop","index":0}"#),
            event("content_block_start", #"{"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}"#),
            event("ping", #"{"type":"ping"}"#),
            event("content_block_delta", #"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"\n"}}"#),
            event("content_block_delta", #"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Hel"}}"#),
            event("content_block_delta", #"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"lo"}}"#),
            event("content_block_stop", #"{"type":"content_block_stop","index":1}"#),
            event("message_delta", #"{"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"output_tokens":15}}"#),
            event("message_stop", #"{"type":"message_stop"}"#),
        ]))
        let result = try await collect(provider(server).stream(simpleRequest))
        #expect(result.deltas == ["Hel", "lo"])
        #expect(result.usage == LLMUsage(inputTokens: 1025, outputTokens: 15, cachedInputTokens: 1000, cacheWriteTokens: 0))
        #expect(server.requests.first?.json["stream"] as? Bool == true)
    }

    @Test func streamErrorEventThrowsMappedStatus() async {
        let server = StubServer()
        server.enqueue(.sse([
            event("message_start", #"{"type":"message_start","message":{"content":[],"usage":{"input_tokens":5,"output_tokens":1}}}"#),
            event("error", #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#),
        ]))
        let error = await llmError { _ = try await collect(provider(server).stream(simpleRequest)) }
        #expect(error == .http(status: 529, message: "Overloaded"))
    }

    @Test func truncatedStreamIsAnError() async {
        let server = StubServer()
        server.enqueue(.sse([
            event("message_start", #"{"type":"message_start","message":{"content":[],"usage":{"input_tokens":5,"output_tokens":1}}}"#),
            event("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"partial"}}"#),
        ]))
        let error = await llmError { _ = try await collect(provider(server).stream(simpleRequest)) }
        guard case .invalidResponse = error else { Issue.record("got \(String(describing: error))"); return }
    }

    @Test func streamHTTPErrorIsMappedAndNotRetried() async {
        let server = StubServer()
        server.enqueue(.json(#"{"type":"error","error":{"type":"rate_limit_error","message":"slow"}}"#, status: 429, headers: ["retry-after": "3"]))
        let error = await llmError { _ = try await collect(provider(server).stream(simpleRequest)) }
        guard case .http(429, let message) = error else { Issue.record("got \(String(describing: error))"); return }
        #expect(message.contains("Retry in 3 s"))
        #expect(server.requests.count == 1)
    }

    @Test func cancellingTheConsumerCancelsTheURLSessionTask() async throws {
        let server = StubServer()
        var response = StubResponse.sse([
            event("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"first"}}"#),
        ])
        response.hangs = true
        server.enqueue(response)
        let anthropic = provider(server)
        let task = Task { for try await _ in anthropic.stream(simpleRequest) {} }
        // Wait until the request has reached the server, then cancel mid-flight.
        for _ in 0..<100 where server.requests.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!server.requests.isEmpty)
        task.cancel()
        _ = await task.result
        for _ in 0..<100 where server.stoppedLoadingCount == 0 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(server.stoppedLoadingCount >= 1)
    }

    @Test func healthCheckListsModelsWithAuthHeaders() async throws {
        let server = StubServer()
        server.enqueue(.json(#"{"data":[]}"#))
        try await provider(server).healthCheck()
        let sent = try #require(server.requests.first)
        #expect(sent.method == "GET")
        #expect(sent.headers["x-api-key"] == "sk-ant-test")
    }
}
