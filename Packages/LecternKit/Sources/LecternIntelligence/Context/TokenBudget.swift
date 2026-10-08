import Foundation

/// Rough token accounting (≈ 3.4 characters per token for lecture prose and code on Gemma) plus the per-role
/// prompt budgets. Budgets keep every live call in the fast zone of a local model's context
/// (docs/research/local-llm.md §4) and bound cold prefill time.
///
/// | Role / call | System + deck digest | Variable part | Output | Total |
/// |---|---|---|---|---|
/// | Rolling takeaways | ~450 + ≤ 1,800 | topic transcript ≤ 2,200 (incl. ≤ 1,500 new) + slides ≤ 450 + ~250 | 320 | ≤ ~5.5k |
/// | Expand | ~300 + ≤ 1,800 | topic transcript ≤ 2,400 + slides ≤ 700 | 700 | ≤ ~6k |
/// | Quiz question / grade | ~450 + ≤ 1,800 | topic transcript ≤ 2,000 + slides ≤ 600 | ≤ 450 | ≤ ~5.5k |
/// | Recap | ~500 + ≤ 1,800 | transcript ≤ 1,600 + topics ≤ 300 + announcements ≤ 200 | 350 | ≤ ~5k |
/// | Lecture summary | ~500 + ≤ 1,800 | topics ≤ 2,000 + quiz ≤ 500 + flagged ≤ 300 + ~250 | 800 | ≤ ~6k |
/// | Ask | ~650 + ≤ 1,800 + transcript ≤ 20,000 | history ≤ 2,000 + topics ≤ 1,200 + slides ≤ 1,500 + newest transcript (≤ ~5.5 min) | 1,500 (+ 1,100 thinking) | ≤ ~29k, ~2-4k of it new per question |
/// | Course Ask | ~450 + lecture index ≤ 800 | history ≤ 1,200 + retrieved context ≤ 3,200 | 800 | ≤ ~6.5k |
enum TokenBudget {
    /// Measured on Gemma 4 over 76 real lecture calls: ≈ 3.4 characters per token.
    static func estimate(_ text: String) -> Int { Int((Double(text.unicodeScalars.count) / charactersPerToken).rounded(.up)) }
    static let charactersPerToken = 3.4

    static let deckDigest = 1_800

    static let topicWindow = 2_200
    static let newTranscriptPerUpdate = 1_500
    static let segmentationSlides = 450

    static let detailTranscript = 2_400
    static let detailSlides = 700

    static let quizTranscript = 2_000
    static let quizSlides = 600

    static let recapTranscript = 1_600
    static let recapTopics = 300
    static let recapAnnouncements = 200

    /// Takeaways (with their details when there's room), or the transcript when there are none.
    static let summaryTopics = 2_000
    static let summaryQuiz = 500
    static let summaryAnnouncements = 300

    /// Course Ask's prior turns.
    static let askHistory = 1_200

    /// Lecture Ask: the transcript in the cached system prefix. 20k tokens is about 80-90 minutes
    /// of lecture; a longer lecture keeps its first 20k there and retrieves from the rest.
    static let askTranscriptPrefix = 20_000
    static let askConversation = 2_000
    static let askTopics = 1_200
    static let askSlides = 1_500
    static let askSlideChars = 1_200
    /// Only past `askTranscriptPrefix`: retrieved windows, then the newest transcript.
    static let askRetrieved = 2_400
    static let askLatest = 1_600

    /// The October 2026 Ask design (`AskDesign.compact`), kept for comparison in the evaluation.
    static let compactAskTranscript = 1_600
    static let compactAskSlides = 800
    static let compactAskTakeaways = 400

    static let courseIndex = 800
    static let courseTranscript = 1_800
    static let courseTakeaways = 600
    static let courseSlides = 800
}
