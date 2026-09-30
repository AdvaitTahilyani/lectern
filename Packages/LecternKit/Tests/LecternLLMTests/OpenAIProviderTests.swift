import Foundation
import LecternCore
import Testing
@testable import LecternLLM

@Suite struct OpenAIProviderTests {
    private let schema = #"{"type":"object","properties":{"a":{"type":"string"}},"required":["a"],"additionalProperties":false}"#

    private func openAI(_ server: StubServer, model: String = "gpt-6-luna", key: String = "sk-test") -> OpenAICompatibleProvider {
        OpenAICompatibleProvider(
            flavor: .openAI, baseURL: server.baseURL, model: model, apiKey: key, session: server.session, retryDelay: 0.01
        )
    }

    private func local(_ server: StubServer, model: String = "gemma4:12b") -> OpenAICompatibleProvider {
        OpenAICompatibleProvider(flavor: .localServer, baseURL: server.baseURL, model: model, session: server.session, retryDelay: 0.01)
    }

    private func body(_ provider: OpenAICompatibleProvider, _ request: LLMRequest, stream: Bool = false) throws -> [String: Any] {
        try wireJSON(provider.makeBody(request, stream: stream))
    }

    // MARK: Request bodies

    @Test func openAIBodyUsesMaxCompletionTokensAndStreamOptions() throws {
        let server = StubServer()
        let json = try body(openAI(server), simpleRequest, stream: true)
        #expect(json["max_completion_tokens"] as? Int == 100)
        #expect(json["max_tokens"] == nil)
        #expect((json["stream_options"] as? [String: Bool])?["include_usage"] == true)
        #expect(json["stream"] as? Bool == true)
    }

    @Test func gpt6ReasoningOffSendsNoneAndKeepsTemperature() throws {
        let json = try body(openAI(StubServer()), simpleRequest)
        #expect(json["reasoning_effort"] as? String == "none")
        #expect(json["temperature"] as? Double == 0.3)
    }

    @Test func reasoningOnDropsTemperature() throws {
        var request = simpleRequest
        request.reasoning = .medium
        let json = try body(openAI(StubServer()), request)
        #expect(json["reasoning_effort"] as? String == "medium")
        #expect(json["temperature"] == nil)
    }

    @Test func legacyReasoningFamiliesUseTheirLowestEffort() throws {
        let gpt5 = try body(openAI(StubServer(), model: "gpt-5-mini"), simpleRequest)
        #expect(gpt5["reasoning_effort"] as? String == "minimal")
        #expect(gpt5["temperature"] == nil)
        let o3 = try body(openAI(StubServer(), model: "o3-mini"), simpleRequest)
        #expect(o3["reasoning_effort"] as? String == "low")
        let astra = try body(openAI(StubServer(), model: "gpt-6-astra"), simpleRequest)
        #expect(astra["reasoning_effort"] as? String == "low")
    }

    @Test func chatSnapshotsAreNotTreatedAsReasoningModels() throws {
        for model in ["gpt-5-chat-latest", "gpt-5.1-chat-latest"] {
            let json = try body(openAI(StubServer(), model: model), simpleRequest)
            #expect(json["reasoning_effort"] == nil, "\(model)")
            #expect(json["temperature"] != nil, "\(model)")
        }
    }

    @Test func modelsWithoutAnEffortParameterGetNoneAndNoTemperature() throws {
        for model in ["o1-mini", "o1-preview", "gpt-5-pro", "o3-pro"] {
            let json = try body(openAI(StubServer(), model: model), simpleRequest)
            #expect(json["reasoning_effort"] == nil, "\(model)")
            #expect(json["temperature"] == nil, "\(model)")
        }
    }

    @Test func nonReasoningModelGetsTemperatureButNoEffort() throws {
        let json = try body(openAI(StubServer(), model: "gpt-4.1-mini"), simpleRequest)
        #expect(json["reasoning_effort"] == nil)
        #expect(json["temperature"] as? Double == 0.3)
    }

    @Test func openAIJSONWithSchemaUsesStrictJSONSchema() throws {
        var request = simpleRequest
        request.responseFormat = .json(schema: schema)
        let format = try #require(try body(openAI(StubServer()), request)["response_format"] as? [String: Any])
        #expect(format["type"] as? String == "json_schema")
        let inner = try #require(format["json_schema"] as? [String: Any])
        #expect(inner["strict"] as? Bool == true)
        #expect(inner["name"] as? String == "response")
        #expect((inner["schema"] as? [String: Any])?["type"] as? String == "object")
    }

    @Test func openAIJSONWithoutSchemaUsesJSONObjectAndMentionsJSON() throws {
        var request = LLMRequest(messages: [.user("Give me data")], responseFormat: .json(schema: nil))
        var json = try body(openAI(StubServer()), request)
        #expect((json["response_format"] as? [String: String])?["type"] == "json_object")
        let messages = try #require(json["messages"] as? [[String: String]])
        #expect(messages.first?["content"]?.contains("JSON") == true)

        request.messages = [.user("Return JSON please")]
        json = try body(openAI(StubServer()), request)
        #expect((json["messages"] as? [[String: String]])?.count == 1)
    }

    @Test func invalidSchemaTextIsRejected() {
        var request = simpleRequest
        request.responseFormat = .json(schema: "not json")
        #expect(throws: LLMError.self) { try body(openAI(StubServer()), request) }
    }

    @Test func localServerBodyUsesMaxTokensAndDisablesThinking() throws {
        let json = try body(local(StubServer()), simpleRequest)
        #expect(json["max_tokens"] as? Int == 100)
        #expect(json["max_completion_tokens"] == nil)
        #expect(json["reasoning_effort"] as? String == "none")
        #expect(json["temperature"] as? Double == 0.3)
    }

    @Test func localServerMapsLowAndMedium() throws {
        var request = simpleRequest
        request.reasoning = .low
        #expect(try body(local(StubServer()), request)["reasoning_effort"] as? String == "low")
        request.reasoning = .medium
        #expect(try body(local(StubServer()), request)["reasoning_effort"] as? String == "medium")
    }

    @Test func localServerJSONAlwaysUsesJSONSchema() throws {
        var request = simpleRequest
        request.responseFormat = .json(schema: nil)
        var format = try #require(try body(local(StubServer()), request)["response_format"] as? [String: Any])
        #expect(format["type"] as? String == "json_schema")
        #expect(((format["json_schema"] as? [String: Any])?["schema"] as? [String: String])?["type"] == "object")

        request.responseFormat = .json(schema: schema)
        format = try #require(try body(local(StubServer()), request)["response_format"] as? [String: Any])
        let inner = try #require(format["json_schema"] as? [String: Any])
        #expect(inner["strict"] == nil)
        #expect((inner["schema"] as? [String: Any])?["required"] as? [String] == ["a"])
    }

    @Test func bareHostGetsV1Appended() {
        #expect(OpenAICompatibleProvider.normalized(URL(string: "http://localhost:11434")!).absoluteString == "http://localhost:11434/v1")
        #expect(OpenAICompatibleProvider.normalized(URL(string: "http://localhost:1234/v1/")!).absoluteString == "http://localhost:1234/v1")
    }

    // MARK: complete

    @Test func completeParsesTextUsageAndSendsAuth() async throws {
        let server = StubServer()
        server.enqueue(.json(#"{"choices":[{"message":{"content":"<think>hmm</think>\n\nHello!"},"finish_reason":"stop"}],"usage":{"prompt_tokens":12,"completion_tokens":5}}"#))
        let response = try await openAI(server).complete(simpleRequest)
        #expect(response.text == "Hello!")
        #expect(response.usage == LLMUsage(inputTokens: 12, outputTokens: 5))
        let sent = try #require(server.requests.first)
        #expect(sent.url.path == "/v1/chat/completions")
        #expect(sent.headers["Authorization"] == "Bearer sk-test")
        #expect((sent.json["messages"] as? [[String: String]])?.first?["role"] == "system")
    }

    @Test func localServerSendsNoAuthHeader() async throws {
        let server = StubServer()
        server.enqueue(.json(#"{"choices":[{"message":{"content":"ok"}}]}"#))
        _ = try await local(server).complete(simpleRequest)
        #expect(server.requests.first?.headers["Authorization"] == nil)
    }

    @Test func missingKeyFailsBeforeAnyRequest() async {
        let server = StubServer()
        let error = await llmError { _ = try await openAI(server, key: "").complete(simpleRequest) }
        #expect(error == .missingAPIKey(.openAI))
        #expect(server.requests.isEmpty)
    }

    @Test func emptyAnswerAfterLengthStopIsAnError() async {
        let server = StubServer()
        server.enqueue(.json(#"{"choices":[{"message":{"content":""},"finish_reason":"length"}]}"#))
        let error = await llmError { _ = try await local(server).complete(simpleRequest) }
        guard case .invalidResponse = error else { Issue.record("expected invalidResponse, got \(String(describing: error))"); return }
    }

    // MARK: errors and retry

    @Test func unauthorizedMapsToKeyRejectedMessage() async {
        let server = StubServer()
        server.enqueue(.json(#"{"error":{"message":"Incorrect API key"}}"#, status: 401))
        let error = await llmError { _ = try await openAI(server).complete(simpleRequest) }
        guard case .http(let status, let message) = error else { Issue.record("got \(String(describing: error))"); return }
        #expect(status == 401)
        #expect(message.contains("API key"))
        #expect(message.contains("Incorrect API key"))
        #expect(server.requests.count == 1)  // 401 is not retried
    }

    @Test func rateLimitRetriesOnceThenSucceeds() async throws {
        let server = StubServer()
        server.enqueue(
            .json(#"{"error":{"message":"slow down"}}"#, status: 429, headers: ["Retry-After": "0"]),
            .json(#"{"choices":[{"message":{"content":"ok"}}]}"#)
        )
        let response = try await openAI(server).complete(simpleRequest)
        #expect(response.text == "ok")
        #expect(server.requests.count == 2)
    }

    @Test func serverErrorRetriesOnceThenSurfaces() async {
        let server = StubServer()
        server.enqueue(.json("{}", status: 503), .json(#"{"error":{"message":"down"}}"#, status: 503))
        let error = await llmError { _ = try await openAI(server).complete(simpleRequest) }
        guard case .http(let status, let message) = error else { Issue.record("got \(String(describing: error))"); return }
        #expect(status == 503)
        #expect(message.contains("down"))
        #expect(server.requests.count == 2)
    }

    @Test func rateLimitMessageIncludesRetryAfter() async {
        let server = StubServer()
        let limited = StubResponse.json(#"{"error":{"message":"quota"}}"#, status: 429, headers: ["Retry-After": "1"])
        server.enqueue(limited, limited)
        let error = await llmError { _ = try await openAI(server).complete(simpleRequest) }
        guard case .http(429, let message) = error else { Issue.record("got \(String(describing: error))"); return }
        #expect(message.contains("Retry in 1 s"))
    }

    @Test func connectionLossRetriesButBadRequestDoesNot() async throws {
        let server = StubServer()
        server.enqueue(StubResponse(failure: .networkConnectionLost), .json(#"{"choices":[{"message":{"content":"ok"}}]}"#))
        #expect(try await local(server).complete(simpleRequest).text == "ok")

        let other = StubServer()
        other.enqueue(.json(#"{"error":{"message":"bad"}}"#, status: 400))
        _ = await llmError { _ = try await local(other).complete(simpleRequest) }
        #expect(other.requests.count == 1)
    }

    @Test func unreachableLocalServerReportsNetworkError() async {
        let server = StubServer()
        server.enqueue(StubResponse(failure: .cannotConnectToHost), StubResponse(failure: .cannotConnectToHost))
        let error = await llmError { _ = try await local(server).complete(simpleRequest) }
        guard case .network(let message) = error else { Issue.record("got \(String(describing: error))"); return }
        #expect(message.contains("Is it running"))
    }

    @Test func missingLocalModelMapsToModelNotDownloaded() async {
        let server = StubServer()
        server.enqueue(.json(#"{"error":{"message":"model 'x' not found"}}"#, status: 404))
        let error = await llmError { _ = try await local(server, model: "x").complete(simpleRequest) }
        #expect(error == .modelNotDownloaded("x"))
    }

    // MARK: streaming

    @Test func streamYieldsDeltasStripsThinkingAndReportsUsage() async throws {
        let server = StubServer()
        // The <think> tags are split across chunk boundaries on purpose.
        server.enqueue(.sse([
            sseData(#"{"choices":[{"delta":{"role":"assistant","content":"<thi"}}]}"#),
            sseData(#"{"choices":[{"delta":{"content":"nk>secret</th"}}]}"#),
            sseData(#"{"choices":[{"delta":{"content":"ink>\n\nHel"}}]}"#),
            sseData(#"{"choices":[{"delta":{"reasoning":"ignored"}}]}"#),
            sseData(#"{"choices":[{"delta":{"content":"lo, world"},"finish_reason":null}]}"#),
            sseData(#"{"choices":[{"delta":{},"finish_reason":"stop"}]}"#),
            sseData(#"{"choices":[],"usage":{"prompt_tokens":20,"completion_tokens":9}}"#),
            "data: [DONE]\n\n",
        ]))
        let result = try await collect(openAI(server).stream(simpleRequest))
        #expect(result.text == "Hello, world")
        #expect(!result.text.contains("secret"))
        #expect(result.usage == LLMUsage(inputTokens: 20, outputTokens: 9))
        #expect((server.requests.first?.json["stream"] as? Bool) == true)
    }

    @Test func streamWithoutDoneMarkerStillCompletes() async throws {
        let server = StubServer()
        server.enqueue(.sse([sseData(#"{"choices":[{"delta":{"content":"partial"}}]}"#)]))
        let result = try await collect(local(server).stream(simpleRequest))
        #expect(result.text == "partial")
        #expect(result.usage == nil)
    }

    @Test func streamHTTPErrorIsMapped() async {
        let server = StubServer()
        server.enqueue(.json(#"{"error":{"message":"Incorrect API key"}}"#, status: 401))
        let error = await llmError { _ = try await collect(openAI(server).stream(simpleRequest)) }
        guard case .http(401, _) = error else { Issue.record("got \(String(describing: error))"); return }
        #expect(server.requests.count == 1)  // streams are never retried
    }

    @Test func midStreamErrorObjectThrows() async {
        let server = StubServer()
        server.enqueue(.sse([
            sseData(#"{"choices":[{"delta":{"content":"a"}}]}"#),
            sseData(#"{"error":{"message":"context length exceeded"}}"#),
        ]))
        let error = await llmError { _ = try await collect(local(server).stream(simpleRequest)) }
        guard case .http(_, let message) = error else { Issue.record("got \(String(describing: error))"); return }
        #expect(message.contains("context length"))
    }

    @Test func streamThatOnlyReasonedThenHitLengthIsAnError() async {
        let server = StubServer()
        server.enqueue(.sse([
            sseData(#"{"choices":[{"delta":{"reasoning":"thinking..."},"finish_reason":null}]}"#),
            sseData(#"{"choices":[{"delta":{},"finish_reason":"length"}]}"#),
            "data: [DONE]\n\n",
        ]))
        let error = await llmError { _ = try await collect(local(server).stream(simpleRequest)) }
        guard case .invalidResponse = error else { Issue.record("got \(String(describing: error))"); return }
    }

    @Test func cancellingTheConsumerCancelsTheURLSessionTask() async throws {
        let server = StubServer()
        var response = StubResponse.sse([sseData(#"{"choices":[{"delta":{"content":"first"}}]}"#)])
        response.hangs = true
        server.enqueue(response)
        let provider = local(server)
        let task = Task { for try await _ in provider.stream(simpleRequest) {} }
        // Wait until the request has reached the server, then cancel mid-flight.
        for _ in 0..<100 where server.requests.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!server.requests.isEmpty)
        task.cancel()
        _ = await task.result
        // stopLoading is called asynchronously after cancellation.
        for _ in 0..<100 where server.stoppedLoadingCount == 0 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(server.stoppedLoadingCount >= 1)
    }

    // MARK: health check and model list

    @Test func healthCheckVerifiesLocalModelIsInstalled() async throws {
        let server = StubServer()
        let models = #"{"object":"list","data":[{"id":"gemma4:12b"},{"id":"other:latest"}]}"#
        server.enqueue(.json(models), .json(models), .json(models))
        try await local(server).healthCheck()
        try await local(server, model: "other").healthCheck()
        let error = await llmError { try await local(server, model: "missing").healthCheck() }
        #expect(error == .modelNotDownloaded("missing"))
        #expect(server.requests.first?.method == "GET")
        #expect(server.requests.first?.url.path == "/v1/models")
    }

    @Test func fetchLocalServerModelsReturnsSortedIDs() async throws {
        let server = StubServer()
        server.enqueue(.json(#"{"data":[{"id":"b"},{"id":"a"}]}"#))
        let ids = try await ProviderCatalog.fetchLocalServerModels(baseURL: server.baseURL, session: server.session)
        #expect(ids == ["a", "b"])
    }
}
