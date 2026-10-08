import Foundation
import LecternCore

/// How lecture Ask builds its prompt and samples its answer.
///
/// `standard` is what the app uses: TA-style instructions, the whole transcript so far in the
/// cached system prefix (see `LectureBrain.askSnapshotCount()`), and room for a full explanation.
/// `compact` is the design before October 2026 (terse lecture-only instructions, a few retrieved
/// transcript windows, 800 output tokens). It exists only so the Ask evaluation harness
/// (`Lectern -selftest ask`) can compare the two on the same build; delete it with the harness
/// option once the comparison is no longer needed.
@_spi(Evaluation) public struct AskDesign: Sendable, Hashable {
    enum Context: Sendable, Hashable {
        /// The transcript in the system prefix, with what came after its boundary in the question.
        case transcript
        /// BM25 windows and the most recent transcript in the question (the compact design).
        case retrieval
    }

    var context: Context
    var instructions: String
    var profile: GenerationProfile

    @_spi(Evaluation) public static let standard = AskDesign(
        context: .transcript, instructions: Prompts.askInstructions, profile: .lectureAnswer)

    @_spi(Evaluation) public static let compact = AskDesign(
        context: .retrieval, instructions: Prompts.compactAskInstructions, profile: .answer)

    /// Answer tokens kept free when thinking is on: the reasoning budget is taken out of
    /// `maxTokens` (`low` ≤ 1,024 tokens, `medium` ≤ 4,096).
    static func thinkingTokens(_ effort: ReasoningEffort) -> Int {
        switch effort {
        case .off: 0
        case .low: 1_100
        case .medium: 4_200
        }
    }

    /// This design with `effort` thinking, its output budget grown so the answer keeps its room.
    @_spi(Evaluation) public func reasoning(_ effort: ReasoningEffort) -> AskDesign {
        var design = self
        design.profile.maxTokens = profile.maxTokens - Self.thinkingTokens(profile.reasoning) + Self.thinkingTokens(effort)
        design.profile.reasoning = effort
        return design
    }

    @_spi(Evaluation) public var reasoningEffort: ReasoningEffort { profile.reasoning }
    @_spi(Evaluation) public var maxTokens: Int { profile.maxTokens }
}
