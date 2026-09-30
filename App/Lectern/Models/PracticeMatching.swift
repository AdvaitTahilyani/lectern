import Foundation
import LecternCore

/// Pairs a quiz question with the takeaway it was written from: the material shown when a missed
/// concept is practised, and the quiz marker on a takeaway card.
nonisolated enum PracticeMatching {
    /// The takeaway `question` is about, out of `settled` (finished cards in lecture order).
    ///
    /// Priority: the writer's grounding (its topic title, then its slides), the question's own
    /// slides, its transcript range, and finally the concept text. Slides outrank the time range
    /// because a range can straddle two cards while a slide pins one; `askedAt` is never used
    /// because a ping is offered after the *next* topic has started (QA N2).
    static func takeaway(for question: QuizQuestion, in settled: [Takeaway]) -> Takeaway? {
        if let g = question.grounding {
            if let t = settled.first(where: { $0.title.caseInsensitiveCompare(g.topic) == .orderedSame }) { return t }
            if let t = bestSlideOverlap(g.slides, in: settled) { return t }
        }
        if let t = bestSlideOverlap(question.sourceSlides, in: settled) { return t }
        if let s = question.sourceStart, let t = settled.first(where: { $0.start <= s && s < $0.end }) { return t }
        let concept = question.concept.lowercased().trimmingCharacters(in: .whitespaces)
        guard !concept.isEmpty else { return nil }
        return settled.first { $0.title.lowercased().contains(concept) || $0.summary.lowercased().contains(concept) }
    }

    /// The card sharing the most slides with `slides`; ties go to the earlier card.
    private static func bestSlideOverlap(_ slides: [Int], in settled: [Takeaway]) -> Takeaway? {
        let wanted = Set(slides)
        guard !wanted.isEmpty else { return nil }
        var best: (takeaway: Takeaway, overlap: Int)?
        for t in settled {
            let overlap = wanted.intersection(t.slidePages).count
            if overlap > (best?.overlap ?? 0) { best = (t, overlap) }
        }
        return best?.takeaway
    }
}
