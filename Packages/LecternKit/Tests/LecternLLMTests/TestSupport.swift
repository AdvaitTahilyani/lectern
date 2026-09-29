import Foundation
import LecternCore

/// Drains a provider stream into its concatenated deltas, the individual deltas, and the final usage.
func collect(_ stream: AsyncThrowingStream<LLMStreamEvent, Error>) async throws -> (text: String, deltas: [String], usage: LLMUsage?) {
    var deltas: [String] = []
    var usage: LLMUsage?
    var sawDone = false
    for try await event in stream {
        switch event {
        case .delta(let text): deltas.append(text)
        case .done(let u):
            usage = u
            sawDone = true
        }
    }
    precondition(sawDone, "stream ended without .done")
    return (deltas.joined(), deltas, usage)
}

/// The error a stream or call throws, or nil if it succeeds.
func llmError(_ body: () async throws -> Void) async -> LLMError? {
    do {
        try await body()
        return nil
    } catch {
        return error as? LLMError
    }
}

let simpleRequest = LLMRequest(messages: [.system("You are helpful."), .user("Hi")], maxTokens: 100, temperature: 0.3)

func sseData(_ json: String) -> String { "data: \(json)\n\n" }
