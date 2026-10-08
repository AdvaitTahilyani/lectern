import Foundation
import LecternCore

/// Sampling settings for one kind of call. Values follow docs/research/local-llm.md §5 (Gemma 4
/// 26B-A4B, thinking off for all live calls; grading compares against a stored reference answer, so
/// it doesn't need thinking and stays fast enough for the quiz card).
struct GenerationProfile: Sendable, Hashable {
    var maxTokens: Int
    var temperature: Double
    var reasoning: ReasoningEffort = .off
    /// Background work (rolling takeaways, quiz questions) yields a shared device to calls
    /// someone is waiting on.
    var priority: RequestPriority = .interactive

    static let segmentation = GenerationProfile(maxTokens: 320, temperature: 0.3, priority: .background)
    static let detail = GenerationProfile(maxTokens: 700, temperature: 0.5)
    static let recap = GenerationProfile(maxTokens: 350, temperature: 0.3)
    static let lectureSummary = GenerationProfile(maxTokens: 800, temperature: 0.3)
    static let quizQuestion = GenerationProfile(maxTokens: 450, temperature: 0.7, priority: .background)
    static let feedback = GenerationProfile(maxTokens: 200, temperature: 0.3)
    static let grading = GenerationProfile(maxTokens: 300, temperature: 0.2)
    /// Course-wide Ask (and the compact lecture Ask design kept for evaluation).
    static let answer = GenerationProfile(maxTokens: 800, temperature: 0.5)
    /// Lecture Ask: room for a complete explanation (~250 words plus Markdown and citations).
    /// `AskDesign.reasoning(_:)` adds the thinking budget on top.
    static let lectureAnswer = GenerationProfile(maxTokens: 1_500, temperature: 0.4)

    /// The request for `messages` with these settings.
    func request(_ messages: [LLMMessage], format: ResponseFormat = .text) -> LLMRequest {
        LLMRequest(messages: messages, maxTokens: maxTokens, temperature: temperature,
                   responseFormat: format, reasoning: reasoning, priority: priority)
    }
}

/// A reply that parsed but doesn't make sense (e.g. an empty summary). `reason` is fed back to the
/// model in the repair turn.
struct ReplyRejected: Error, Sendable {
    var reason: String
}

enum StructuredGeneration {
    /// Calls `provider` for a JSON reply of type `R`, extracts and decodes it tolerantly, then runs
    /// `validate`. On a parse or validation failure it retries once with a short repair turn that
    /// keeps the original prompt (so a prefix cache still hits). Provider errors are rethrown as is.
    static func generate<R: ModelReply, Output>(
        _ type: R.Type,
        provider: any LLMProvider,
        messages: [LLMMessage],
        profile: GenerationProfile,
        validate: (R) throws -> Output
    ) async throws -> Output {
        let first = try await complete(provider, messages, profile, schema: R.schema)
        let failure: String
        do {
            // A cut-off reply is repaired only as a last resort: first ask for a complete one.
            return try parse(R.self, first, rejectingTruncated: true, validate)
        } catch let rejected as ReplyRejected {
            failure = rejected.reason
        } catch JSONExtractionError.truncated {
            failure = "It was cut off. Reply with a complete, shorter JSON object."
        } catch {
            failure = "It was not valid JSON."
        }

        let repair = messages + [.assistant(first), .user(Prompts.repair(shape: R.shape, problem: failure))]
        let second = try await complete(provider, repair, profile, schema: R.schema)
        do {
            return try parse(R.self, second, rejectingTruncated: false, validate)
        } catch let rejected as ReplyRejected {
            throw BrainError.unusableReply(rejected.reason)
        } catch {
            throw BrainError.unusableReply(error.localizedDescription)
        }
    }

    private static func parse<R: ModelReply, Output>(_ type: R.Type, _ text: String, rejectingTruncated: Bool,
                                                     _ validate: (R) throws -> Output) throws -> Output {
        try validate(try JSONExtractor.decode(R.self, from: text, rejectingTruncated: rejectingTruncated))
    }

    private static func complete(_ provider: any LLMProvider, _ messages: [LLMMessage], _ profile: GenerationProfile, schema: String) async throws -> String {
        let request = profile.request(messages, format: .json(schema: schema))
        return try await provider.complete(request).text
    }
}
