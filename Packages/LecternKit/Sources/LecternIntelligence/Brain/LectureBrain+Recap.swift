import Foundation
import LecternCore

// MARK: - "While you were away"

extension LectureBrain {
    /// Lines that sound like announcements or emphasis, surfaced to the recap's `flagged` list.
    static let announcementPattern = #"(?i)\b(exams?|midterms?|finals?|quiz(zes)?|homework|hw\s?\d*|mp\s?\d+|assignments?|due|deadlines?|office hours|important|remember|will be on|projects?|submit|next (week|class|lecture|time))\b"#

    public func recap(from: TimeInterval, to: TimeInterval) async throws -> Recap {
        let window = TranscriptText.segments(in: segments, from: from, to: to)
        guard !window.isEmpty else {
            return Recap(from: from, to: to, headline: "Nothing new was said in that stretch.", bullets: [])
        }
        let announcements = announcementLines(in: window, budget: TokenBudget.recapAnnouncements)
        let input = Prompts.RecapInput(
            lecture: lecture,
            digest: digest,
            from: from,
            to: to,
            transcript: TranscriptText.renderFitting(window, maxTokens: TokenBudget.recapTranscript),
            topics: topicList(from: from, to: to, budget: TokenBudget.recapTopics),
            announcements: announcements.isEmpty ? nil : announcements.joined(separator: "\n"),
            slidesShown: excerpts.titles(slidesShown(from: from, to: to))
        )
        let topicSlides = timeline.takeaways.filter { $0.end > from && $0.start < to }.flatMap(\.slidePages)
        let reply = try await withRole(.summaries, .recapping, priority: .interactive) {
            try await StructuredGeneration.generate(RecapReply.self, provider: providers.summaries,
                                                    messages: Prompts.recap(input), profile: .recap) { reply in
                guard !reply.headline.isEmpty, !reply.bullets.isEmpty else {
                    throw ReplyRejected(reason: "Give a \"headline\" and 2-4 \"bullets\".")
                }
                return reply
            }
        }
        let cited = recapSlides(reply.slides, from: from, to: to)
        let flagged = reply.flagged.map { PlainMath.clean($0) }.filter { !$0.isEmpty }.prefix(4).map { $0 }
        for item in flagged where !recapFlags.contains(where: { Text.similarity($0, item) >= 0.8 }) {
            recapFlags.append(item)
        }
        return Recap(
            from: from,
            to: to,
            headline: Text.clampSentences(PlainMath.clean(reply.headline), maxChars: 200),
            bullets: reply.bullets.map { PlainMath.clean($0) }.prefix(4).map { $0 },
            flagged: flagged,
            slides: cited.isEmpty ? excerpts.sanitize(topicSlides).filter { isPresented($0, at: to) } : cited
        )
    }

    /// A recap cites only slides on screen during its window (±1 for tracking lag), never pages
    /// the lecture had not reached by then. Without slide tracking, any valid page.
    func recapSlides(_ cited: [Int], from: TimeInterval, to: TimeInterval) -> [Int] {
        let valid = excerpts.sanitize(cited)
        let shown = slidesShown(from: from, to: to)
        // Without tracking (or no record of the window), only the lecture's reach limits them.
        guard slideSearch != nil, !shown.isEmpty else { return valid.filter { isPresented($0, at: to) } }
        return valid.filter { page in shown.contains { abs($0 - page) <= 1 } }
    }

    /// Words that almost always mark something to act on or study, preferred when the budget is tight.
    static let strongAnnouncementPattern = #"(?i)\b(exams?|midterms?|finals?|quiz(zes)?|homework|hw\s?\d*|mp\s?\d+|assignments?|due|deadlines?|important|will be on|submit)\b"#

    /// "[m:ss] text" lines from `window` that sound like announcements or emphasis, in order,
    /// within `budget` tokens. With `strongFirst`, lines with a strong marker (exam, due, …) are
    /// kept before weaker ones ("remember", "next week") when not all fit.
    func announcementLines(in window: ArraySlice<TranscriptSegment>, budget: Int, strongFirst: Bool = false) -> [String] {
        let matches = window.filter { $0.text.range(of: Self.announcementPattern, options: .regularExpression) != nil }
        let ranked = strongFirst
            ? matches.filter { Self.isStrongAnnouncement($0) } + matches.filter { !Self.isStrongAnnouncement($0) }
            : matches
        var picked: [TranscriptSegment] = []
        var used = 0
        for segment in ranked {
            let cost = TokenBudget.estimate(TranscriptText.line(segment)) + 1
            if used + cost > budget {
                if strongFirst { continue }
                break
            }
            picked.append(segment)
            used += cost
        }
        return picked.sorted { $0.start < $1.start }.map(TranscriptText.line)
    }

    private static func isStrongAnnouncement(_ segment: TranscriptSegment) -> Bool {
        segment.text.range(of: strongAnnouncementPattern, options: .regularExpression) != nil
    }
}
