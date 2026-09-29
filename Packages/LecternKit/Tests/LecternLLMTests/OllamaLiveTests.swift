import Foundation
import LecternCore
import Testing
@testable import LecternLLM

/// Talks to a real Ollama at http://localhost:11434 with `gemma4:12b`. Run with `LECTERN_LIVE_TESTS=1`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["LECTERN_LIVE_TESTS"] == "1"), .serialized)
struct OllamaLiveTests {
    private let provider = OpenAICompatibleProvider.localServer(
        baseURL: OpenAICompatibleProvider.ollamaBaseURL, model: "gemma4:12b"
    )

    private let schema = #"""
    {"type":"object","properties":{"decision":{"type":"string","enum":["continue","new_topic"]},"title":{"type":"string"},"slides":{"type":"array","items":{"type":"integer"}}},"required":["decision","title","slides"],"additionalProperties":false}
    """#

    private func report(_ label: String, _ seconds: Double, _ extra: String = "") {
        print("[live] \(label): \(String(format: "%.2f", seconds)) s \(extra)")
    }

    @Test func healthCheckFindsTheModel() async throws {
        try await provider.healthCheck()
        let models = try await ProviderCatalog.fetchLocalServerModels(baseURL: OpenAICompatibleProvider.ollamaBaseURL)
        #expect(models.contains("gemma4:12b"))
    }

    @Test func jsonModeReturnsParseableJSONWithThinkingOff() async throws {
        let request = LLMRequest(
            messages: [
                .system("You segment lecture transcripts. Reply only with the requested JSON."),
                .user("Transcript: 'Now that we have covered FIRST sets, let us compute FOLLOW sets for the same grammar.' Slides 12-14 are on FOLLOW sets."),
            ],
            maxTokens: 200,
            temperature: 0.3,
            responseFormat: .json(schema: schema),
            reasoning: .off
        )
        let clock = ContinuousClock()
        var response: LLMResponse?
        let elapsed = try await clock.measure { response = try await provider.complete(request) }
        let text = try #require(response?.text)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(["continue", "new_topic"].contains(object["decision"] as? String ?? ""))
        #expect(object["title"] is String)
        #expect(object["slides"] is [Int])
        #expect(!text.contains("<think>"))
        report("json complete", elapsed.seconds, "output tokens: \(response?.usage?.outputTokens ?? -1)")
        // Thinking off means a short, direct completion (a thinking pass would add hundreds of tokens).
        #expect((response?.usage?.outputTokens ?? 0) < 120)
    }

    @Test func schemalessJSONModeAlsoWorks() async throws {
        let request = LLMRequest(
            messages: [.user("Return a JSON object with keys \"a\" and \"b\" holding small integers.")],
            maxTokens: 100,
            responseFormat: .json(schema: nil)
        )
        let response = try await provider.complete(request)
        #expect(try JSONSerialization.jsonObject(with: Data(response.text.utf8)) is [String: Any])
    }

    @Test func streamingDeliversIncrementalDeltasAndUsage() async throws {
        let request = LLMRequest(
            messages: [.user("Count from 1 to 12 separated by spaces, nothing else.")], maxTokens: 100
        )
        let clock = ContinuousClock()
        let start = clock.now
        var firstDelta: Double?
        var deltas = 0
        var text = ""
        var usage: LLMUsage?
        for try await event in provider.stream(request) {
            switch event {
            case .delta(let piece):
                if firstDelta == nil { firstDelta = (clock.now - start).seconds }
                deltas += 1
                text += piece
            case .done(let u): usage = u
            }
        }
        let total = (clock.now - start).seconds
        #expect(deltas > 3)
        #expect(text.contains("12"))
        #expect(usage != nil)
        report("stream", total, "first delta: \(String(format: "%.2f", firstDelta ?? -1)) s, deltas: \(deltas), usage: \(String(describing: usage))")
    }

    @Test func reasoningLowStillReturnsCleanAnswer() async throws {
        let request = LLMRequest(
            messages: [.user("What is 17 * 23? Answer with just the number.")], maxTokens: 800, reasoning: .low
        )
        let response = try await provider.complete(request)
        #expect(response.text.contains("391"))
        #expect(!response.text.contains("<think>"))
    }
}

private extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
