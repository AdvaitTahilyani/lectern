import Foundation
import LecternCore

// MARK: - Coverage: no substantive stretch of the lecture is left without a card

extension LectureBrain {
    /// A stretch before the first card at least this long is folded into the recap card before it.
    static let minResidualSeconds: TimeInterval = 60

    /// The lines before the first topic card: a Recap card when they deserve one and none exists
    /// yet; otherwise, when a recap card was already written for the start of the lecture, that
    /// card is extended over them and rewritten (quiz answers or a second correction often follow
    /// the first one).
    func coverBeforeFirstCard(_ range: Range<Int>) async {
        guard !range.isEmpty else { return }
        let settled = timeline.takeaways.filter { !$0.isLive }
        guard let recap = settled.last else {
            await addOpeningRecap(range)
            return
        }
        let stretch = segments[range]
        guard let last = stretch.last, let first = stretch.first, last.end - first.start >= Self.minResidualSeconds,
              let live = timeline.live, recap.end < live.start else { return }
        let whole = TranscriptText.segments(in: segments, from: recap.start, to: live.start)
        let card = await writeRecapCard(whole)
        timeline.rewrite(recap.id, title: card?.title ?? recap.title, summary: card?.summary ?? recap.summary, end: live.start)
    }

    /// Follows runs of lines the model filed as admin while a card is live. A run that turns out
    /// to hold announcements or real Q&A (`AsideStretch`) becomes its own card instead of silently
    /// extending the live one; small talk keeps extending it.
    func trackAdminRun(kind: SegmentationReply.LinesKind, newRange: Range<Int>) async {
        guard let live = timeline.live, !newRange.isEmpty else {
            if timeline.live == nil { adminRunStart = nil }
            return
        }
        guard kind == .admin else {
            adminRunStart = nil
            return
        }
        // A growing announcements/Q&A card takes further admin lines, up to a card's length.
        if asideCards[live.id] != nil, live.end - live.start < AsideStretch.maxCardSeconds {
            adminRunStart = nil
            return
        }
        let start = adminRunStart ?? newRange.lowerBound
        adminRunStart = start
        guard let aside = AsideStretch.classify(segments[start..<newRange.upperBound], technical: openingStretch) else { return }
        let cardStart = AsideStretch.cardStart(segments[start..<newRange.upperBound], kind: aside)
        await openAsideCard(aside, range: cardStart..<newRange.upperBound)
    }

    /// Splits the live card where `range` begins and opens an announcements/Q&A card for it.
    private func openAsideCard(_ kind: AsideStretch.Kind, range: Range<Int>) async {
        let stretch = segments[range]
        guard let first = stretch.first, let last = stretch.last, let live = timeline.live, first.start > live.start else { return }
        guard let card = await writeAsideCard(kind, stretch) else {
            // Declined (only small talk): these lines stay with the live card; later admin lines
            // start a fresh run.
            adminRunStart = nil
            return
        }
        let closing = live.id
        guard let id = timeline.splitLive(at: first.start, title: card.title, summary: card.summary, end: last.end) else { return }
        asideCards[id] = last.end
        timeline.asideCards.insert(id)
        adminRunStart = nil
        topicWindowStart = range.lowerBound
        // The card just closed may itself be an aside card that grew since it was written.
        await rewriteAsideIfGrown(closing)
    }

    /// Rewrites an announcements/Q&A card over its whole range when it has grown since it was
    /// written (admin lines kept extending it).
    func rewriteAsideIfGrown(_ id: UUID) async {
        guard let writtenThrough = asideCards[id], let card = timeline.takeaways.first(where: { $0.id == id }),
              card.end - writtenThrough >= Self.minResidualSeconds else { return }
        let stretch = TranscriptText.segments(in: segments, from: card.start, to: card.end)
        let kind: AsideStretch.Kind = card.title.lowercased().hasPrefix("q&a") ? .questions : .announcements
        guard let text = await writeAsideCard(kind, stretch) else { return }
        timeline.rewrite(id, title: text.title, summary: text.summary)
        asideCards[id] = card.end
    }

    private func writeAsideCard(_ kind: AsideStretch.Kind, _ stretch: ArraySlice<TranscriptSegment>) async -> (title: String, summary: String)? {
        let questions = kind == .questions
        return await writeCard(Prompts.asideCard(lecture: lecture, digest: digest,
                                                 transcript: TranscriptText.renderFitting(stretch, maxTokens: TokenBudget.topicWindow),
                                                 questions: questions),
                               prefix: questions ? "Q&A: " : "Announcements: ", what: questions ? "a Q&A card" : "an announcements card",
                               mayDecline: true)
    }
}
