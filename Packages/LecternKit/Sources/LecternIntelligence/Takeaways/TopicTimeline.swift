import Foundation
import LecternCore

/// The takeaway list as a state machine: at most one live topic (always last), refined by
/// `continue` replies and split by `new_topic` replies at the boundary the model quotes.
struct TopicTimeline: Sendable {
    private(set) var takeaways: [Takeaway]
    /// A `new_topic` less than this far into the live topic re-titles it instead of splitting, so
    /// over-eager splits never leave a sliver of a card behind.
    var minTopicSeconds: TimeInterval

    static let maxSummaryChars = 220
    static let maxTitleChars = 64
    /// Announcements/Q&A cards (written by a dedicated call): never retitled by rolling updates.
    var asideCards: Set<UUID> = []

    /// Models tend to list whole slide ranges; a card links a handful.
    static let maxSlidesPerTopic = 6

    /// What one update did; `boundary` is the segment index the live topic now starts at.
    enum Outcome: Equatable, Sendable {
        /// No live topic yet and nothing substantive (greetings, admin).
        case ignored
        case opened(boundary: Int)
        case refined
        case split(boundary: Int)
    }

    /// The transcript the model saw for one update.
    struct Chunk: Sendable {
        var segments: [TranscriptSegment]
        /// Indices shown as the current topic's transcript (includes `new`).
        var window: Range<Int>
        /// Indices that were new in this update (may be empty for the final pass).
        var new: Range<Int>
        /// Pages the prompt showed as relevant (slides on screen, retrieval hits); preferred when a
        /// reply lists more slides than a card keeps.
        var relevantPages: Set<Int> = []
    }

    init(takeaways: [Takeaway], minTopicSeconds: TimeInterval = 60) {
        let sorted = takeaways.sorted { $0.start < $1.start }
        // Only the last takeaway may be live.
        self.takeaways = sorted.enumerated().map { index, t in
            var t = t
            if index < sorted.count - 1 { t.isLive = false }
            return t
        }
        self.minTopicSeconds = minTopicSeconds
    }

    var live: Takeaway? { takeaways.last.flatMap { $0.isLive ? $0 : nil } }

    /// Rejects replies that can't be applied, with a reason for the repair turn.
    static func check(_ reply: SegmentationReply, hasLiveTopic: Bool) throws -> SegmentationReply {
        let title = cleanTitle(reply.title), summary = Text.collapse(reply.summary)
        if reply.action == .newTopic, title.isEmpty || summary.isEmpty {
            throw ReplyRejected(reason: "For \"new_topic\", title and summary describe the new topic and must not be empty.")
        }
        // An admin stretch leaves the live card untouched, so it needs no summary.
        if hasLiveTopic, reply.action == .continueTopic, summary.isEmpty, reply.newLinesKind != .admin {
            throw ReplyRejected(reason: "\"summary\" must not be empty.")
        }
        if summary.count > maxSummaryChars + 80 {
            throw ReplyRejected(reason: "\"summary\" must be at most 220 characters (1-2 short sentences).")
        }
        if summary.range(of: #"^(the\s+)?(professor|instructor|lecturer|speaker|teacher)\b"#, options: [.regularExpression, .caseInsensitive]) != nil {
            throw ReplyRejected(reason: "Write the summary as the fact itself, not \"The instructor…\".")
        }
        if !hasLiveTopic, title.isEmpty != summary.isEmpty {
            throw ReplyRejected(reason: "Give both \"title\" and \"summary\", or leave both empty.")
        }
        return reply
    }

    mutating func apply(_ reply: SegmentationReply, chunk: Chunk, validPages: Set<Int>, now: Date = .now) -> Outcome {
        let title = Self.cleanTitle(reply.title)
        let summary = Text.fitSentences(PlainMath.clean(reply.summary), maxChars: Self.maxSummaryChars)
        let listed = reply.slides.filter(validPages.contains)
        let slides = Array((listed.filter(chunk.relevantPages.contains) + listed.filter { !chunk.relevantPages.contains($0) })
            .prefix(Self.maxSlidesPerTopic))
        let latestEnd = chunk.new.isEmpty ? (live?.end ?? 0) : chunk.segments[chunk.new.upperBound - 1].end
        let chunkStart = chunk.new.isEmpty ? chunk.window.lowerBound : chunk.new.lowerBound

        guard var current = live else {
            guard reply.newLinesKind != .admin, !title.isEmpty, !summary.isEmpty, !chunk.new.isEmpty else { return .ignored }
            // The first card claims the whole window, including earlier lines that were skipped as
            // admin, unless the model quotes where the topic actually begins.
            let match = reply.action == .newTopic ? locate(reply.boundaryQuote, chunk, preferFrom: chunk.window.lowerBound, within: chunk.window) : nil
            let boundary = match?.segmentIndex ?? chunk.window.lowerBound
            let start = match?.time ?? chunk.segments[chunk.window.lowerBound].start
            takeaways.append(Takeaway(title: title, summary: summary, start: start, end: max(start, latestEnd),
                                      slidePages: Self.merge([], slides), isLive: true, updatedAt: now))
            return .opened(boundary: boundary)
        }

        // Lecture content after an announcements/Q&A card always starts a new card: the aside card
        // keeps its own text, however short it is.
        let isAside = asideCards.contains(current.id)
        // Past a card's length a "same concept" reply is taken as the lecture having resumed, so a
        // model that never says new_topic cannot swallow the lecture into the aside card.
        let resumesAfterAside = isAside && reply.newLinesKind != .admin
            && (reply.action == .newTopic || reply.newLinesKind == .newConcept || latestEnd - current.start >= AsideStretch.maxCardSeconds)
            && !title.isEmpty && !summary.isEmpty
        // Otherwise lines after an aside card still belong to it (going over the quiz): it grows
        // and keeps its own text (the brain rewrites it when it closes).
        if isAside, !resumesAfterAside {
            current.end = max(current.end, latestEnd)
            current.updatedAt = now
            replaceLive(current)
            return .refined
        }
        let isSameTitle = !resumesAfterAside && (title.caseInsensitiveCompare(current.title) == .orderedSame
            || Self.isNearDuplicate(title: title, summary: summary, of: current))
        if !resumesAfterAside, reply.action == .continueTopic || isSameTitle || reply.newLinesKind == .admin {
            if reply.newLinesKind == .admin {
                // An admin stretch is not a topic: extend the live one, keep its title and summary.
                current.end = max(current.end, latestEnd)
                current.updatedAt = now
                replaceLive(current)
                return .refined
            }
            refine(&current, title: title, summary: summary, slides: slides, end: latestEnd, now: now)
            return .refined
        }

        let searchable = chunk.window.lowerBound..<(chunk.new.isEmpty ? chunk.window.upperBound : chunk.new.upperBound)
        let match = locate(reply.boundaryQuote, chunk, preferFrom: chunkStart, within: searchable)
        let boundaryTime = match?.time ?? chunk.segments[chunkStart].start
        guard resumesAfterAside || boundaryTime - current.start >= minTopicSeconds else {
            // The live topic has barely started; splitting now would leave a sliver of a card (small
            // models over-split). When the model quoted where the new topic starts and the sliver
            // reads like the card before it (going over a quiz after a correction), the sliver goes
            // back to that card and the new topic starts at the quote, instead of the new topic's
            // title being stretched back over lines that are not about it.
            if let match, let i = takeaways.lastIndex(where: { $0.id == current.id }), i > 0,
               !takeaways[i - 1].isLive, !asideCards.contains(takeaways[i - 1].id),
               Self.leansToPrevious(sliver: reply.closedSummary.isEmpty ? current.title + " " + current.summary : current.title + " " + reply.closedSummary,
                                    previous: takeaways[i - 1], next: title + " " + summary) {
                takeaways[i - 1].end = boundaryTime
                takeaways[i - 1].detail = nil
                takeaways[i - 1].updatedAt = now
                current.start = boundaryTime
                current.slidePages = []
                refine(&current, title: title, summary: summary, slides: slides, end: latestEnd, now: now)
                return .split(boundary: match.segmentIndex)
            }
            refine(&current, title: title, summary: summary, slides: slides, end: latestEnd, now: now)
            return .refined
        }

        let closed = Text.fitSentences(PlainMath.clean(reply.closedSummary), maxChars: Self.maxSummaryChars)
        current.isLive = false
        current.end = boundaryTime
        if !closed.isEmpty, !asideCards.contains(current.id) { current.summary = closed }
        current.detail = nil
        current.updatedAt = now
        replaceLive(current)
        takeaways.append(Takeaway(title: title, summary: summary, start: boundaryTime, end: max(boundaryTime, latestEnd),
                                  slidePages: Self.merge([], slides), isLive: true, updatedAt: now))
        return .split(boundary: match?.segmentIndex ?? chunkStart)
    }

    /// Extends the live card to `end` without changing its text (lines that couldn't be summarized).
    mutating func extendLive(to end: TimeInterval, now: Date = .now) {
        guard var current = live, end > current.end else { return }
        current.end = end
        current.updatedAt = now
        replaceLive(current)
    }

    /// Ends the live topic (recording stopped).
    mutating func settleLive(now: Date = .now) {
        guard var current = live else { return }
        current.isLive = false
        current.updatedAt = now
        replaceLive(current)
    }

    mutating func setDetail(_ detail: TakeawayDetail, for id: UUID) {
        guard let i = takeaways.firstIndex(where: { $0.id == id }) else { return }
        takeaways[i].detail = detail
    }

    // MARK: - Helpers

    private mutating func refine(_ t: inout Takeaway, title: String, summary: String, slides: [Int], end: TimeInterval, now: Date) {
        if !title.isEmpty { t.title = title }
        if !summary.isEmpty { t.summary = summary }
        // Each reply lists the slides of the whole topic so far, so it replaces the list.
        if !slides.isEmpty { t.slidePages = Self.merge([], slides) }
        t.end = max(t.end, end)
        t.detail = nil
        t.updatedAt = now
        replaceLive(t)
    }

    private mutating func replaceLive(_ t: Takeaway) {
        guard let i = takeaways.lastIndex(where: { $0.id == t.id }) else { return }
        takeaways[i] = t
    }

    private func locate(_ quote: String, _ chunk: Chunk, preferFrom: Int, within range: Range<Int>) -> BoundaryMatcher.Match? {
        // Never split before the live topic's own first segment.
        let floor = live.flatMap { live in chunk.segments.firstIndex { $0.end > live.start + 0.01 } } ?? range.lowerBound
        let clipped = max(range.lowerBound, floor)..<max(max(range.lowerBound, floor), range.upperBound)
        return BoundaryMatcher.locate(quote: quote, in: chunk.segments, range: clipped, preferFrom: preferFrom)
    }

    /// Adds a settled card for a stretch the rolling updates skipped (see `OpeningStretch`), in
    /// time order before any later card.
    mutating func insertSettled(title: String, summary: String, start: TimeInterval, end: TimeInterval, now: Date = .now) {
        let card = Takeaway(title: Self.cleanTitle(title), summary: Text.fitSentences(PlainMath.clean(summary), maxChars: Self.maxSummaryChars),
                            start: start, end: end, isLive: false, updatedAt: now)
        let index = takeaways.firstIndex { $0.start >= start } ?? takeaways.endIndex
        takeaways.insert(card, at: index)
    }

    /// A `new_topic` that names the live topic again ("AST to three-address code conversion" →
    /// "Mapping AST to 3-address code") refines the live card instead of splitting it: titles
    /// nearly the same, or fairly similar with overlapping summaries.
    static let duplicateTitleSimilarity = 0.6
    static let similarTitleSimilarity = 0.5
    static let similarSummarySimilarity = 0.3

    /// A new summary whose content words are nearly all already in the card's summary restates it.
    static let restatedSummaryContainment = 0.8
    static let minTermsForContainment = 4

    /// Summaries that open with essentially the same sentence describe the same topic.
    static let sameOpeningSimilarity = 0.6

    static func isNearDuplicate(title: String, summary: String, of card: Takeaway) -> Bool {
        let titles = similarity(title, card.title)
        return titles >= duplicateTitleSimilarity
            || (titles >= similarTitleSimilarity && similarity(summary, card.summary) >= similarSummarySimilarity)
            || containment(of: summary, in: card.summary) >= restatedSummaryContainment
            || (terms(firstSentence(summary)).count >= minTermsForContainment
                && similarity(firstSentence(summary), firstSentence(card.summary)) >= sameOpeningSimilarity)
    }

    private static func firstSentence(_ s: String) -> String {
        let text = Text.collapse(s)
        guard let end = text.firstIndex(where: { ".!?".contains($0) }) else { return text }
        return String(text[...end])
    }

    /// Ends the live card at `time` and opens a new live card for `title`/`summary` from there to
    /// `end` (an announcements or Q&A stretch the model filed as admin). Returns the new card's id.
    @discardableResult
    mutating func splitLive(at time: TimeInterval, title: String, summary: String, end: TimeInterval, now: Date = .now) -> UUID? {
        guard var current = live, time > current.start else { return nil }
        current.isLive = false
        current.end = time
        current.detail = nil
        current.updatedAt = now
        replaceLive(current)
        let card = Takeaway(title: Self.cleanTitle(title), summary: Text.fitSentences(PlainMath.clean(summary), maxChars: Self.maxSummaryChars),
                            start: time, end: max(time, end), isLive: true, updatedAt: now)
        takeaways.append(card)
        return card.id
    }

    /// Replaces a card's title and summary (and optionally extends it to `end`), e.g. when a
    /// card written by a dedicated call is rewritten over its final range.
    mutating func rewrite(_ id: UUID, title: String, summary: String, end: TimeInterval? = nil, now: Date = .now) {
        guard let i = takeaways.firstIndex(where: { $0.id == id }) else { return }
        let cleaned = Self.cleanTitle(title)
        if !cleaned.isEmpty { takeaways[i].title = cleaned }
        let text = Text.fitSentences(PlainMath.clean(summary), maxChars: Self.maxSummaryChars)
        if !text.isEmpty { takeaways[i].summary = text }
        if let end { takeaways[i].end = max(takeaways[i].end, end) }
        takeaways[i].detail = nil
        takeaways[i].updatedAt = now
    }

    /// Share of `a`'s content words that also occur in `b` (0 when `a` is too short to judge).
    private static func containment(of a: String, in b: String) -> Double {
        let x = terms(a), y = terms(b)
        guard x.count >= minTermsForContainment else { return 0 }
        return Double(x.intersection(y).count) / Double(x.count)
    }

    /// Merges the live card into the settled card before it when they are the same topic (e.g.
    /// the model opens "Recap: phi placement" right after the brain wrote a recap card for the
    /// same lines). The earlier card becomes live again, spanning both. Returns whether it merged.
    @discardableResult
    mutating func mergeLiveIntoPreviousIfDuplicate(now: Date = .now) -> Bool {
        guard takeaways.count >= 2, let live, !takeaways[takeaways.count - 2].isLive,
              Self.isNearDuplicate(title: live.title, summary: live.summary, of: takeaways[takeaways.count - 2]) else { return false }
        var previous = takeaways[takeaways.count - 2]
        previous.end = max(previous.end, live.end)
        previous.slidePages = Self.merge(previous.slidePages, live.slidePages)
        previous.isLive = true
        previous.detail = nil
        previous.updatedAt = now
        takeaways.removeLast(2)
        takeaways.append(previous)
        return true
    }

    /// Stemmed content words, with number words and digits unified.
    private static func terms(_ s: String) -> Set<String> {
        Set(Text.words(s).map { numberWords[$0] ?? $0 }.compactMap { word -> String? in
            if word.allSatisfy(\.isNumber) { return word }
            return TranscriptRetriever.terms(word).first
        })
    }

    /// Jaccard similarity of `terms`.
    /// Whether a short card's text shares more with the card before it than with the topic after it.
    static func leansToPrevious(sliver: String, previous: Takeaway, next: String) -> Bool {
        let before = similarity(sliver, previous.title + " " + previous.summary)
        return before > 0 && before > similarity(sliver, next)
    }

    private static func similarity(_ a: String, _ b: String) -> Double {
        let x = terms(a), y = terms(b)
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        return Double(x.intersection(y).count) / Double(x.union(y).count)
    }

    private static let numberWords = ["one": "1", "two": "2", "three": "3", "four": "4", "five": "5"]

    static func cleanTitle(_ raw: String) -> String {
        var t = PlainMath.clean(Text.collapse(raw)).trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’*#").union(.whitespaces))
        if t.hasSuffix(".") { t.removeLast() }
        return Text.truncate(t, maxChars: maxTitleChars)
    }

    private static func merge(_ a: [Int], _ b: [Int]) -> [Int] { Array(Set(a + b)).sorted() }
}
