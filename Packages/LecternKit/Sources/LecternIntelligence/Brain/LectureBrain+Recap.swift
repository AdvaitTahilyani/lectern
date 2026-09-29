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
        let announcements = window.filter { $0.text.range(of: Self.announcementPattern, options: .regularExpression) != nil }
        var announcementLines: [String] = []
        var used = 0
        for segment in announcements {
            let line = TranscriptText.line(segment)
            let cost = TokenBudget.estimate(line) + 1
            if used + cost > TokenBudget.recapAnnouncements { break }
            announcementLines.append(line)
            used += cost
        }
        let input = Prompts.RecapInput(
            lecture: lecture,
            digest: digest,
            from: from,
            to: to,
            transcript: TranscriptText.renderFitting(window, maxTokens: TokenBudget.recapTranscript),
            topics: topicList(from: from, to: to, budget: TokenBudget.recapTopics),
            announcements: announcementLines.isEmpty ? nil : announcementLines.joined(separator: "\n")
        )
        let topicSlides = timeline.takeaways.filter { $0.end > from && $0.start < to }.flatMap(\.slidePages)
        let reply = try await withRole(.summaries, .summarizing) {
            try await StructuredGeneration.generate(RecapReply.self, provider: providers.summaries,
                                                    messages: Prompts.recap(input), profile: .recap) { reply in
                guard !reply.headline.isEmpty, !reply.bullets.isEmpty else {
                    throw ReplyRejected(reason: "Give a \"headline\" and 2-4 \"bullets\".")
                }
                return reply
            }
        }
        let cited = excerpts.sanitize(reply.slides)
        return Recap(
            from: from,
            to: to,
            headline: Text.clampSentences(PlainMath.clean(reply.headline), maxChars: 200),
            bullets: reply.bullets.map { PlainMath.clean($0) }.prefix(4).map { $0 },
            flagged: reply.flagged.map { PlainMath.clean($0) }.filter { !$0.isEmpty }.prefix(4).map { $0 },
            slides: cited.isEmpty ? excerpts.sanitize(topicSlides) : cited
        )
    }
}
