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
        if hasLiveTopic, reply.action == .continueTopic, summary.isEmpty {
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
        let summary = Text.clampSentences(PlainMath.clean(reply.summary), maxChars: Self.maxSummaryChars)
        let listed = reply.slides.filter(validPages.contains)
        let slides = Array((listed.filter(chunk.relevantPages.contains) + listed.filter { !chunk.relevantPages.contains($0) })
            .prefix(Self.maxSlidesPerTopic))
        let latestEnd = chunk.new.isEmpty ? (live?.end ?? 0) : chunk.segments[chunk.new.upperBound - 1].end
        let chunkStart = chunk.new.isEmpty ? chunk.window.lowerBound : chunk.new.lowerBound

        guard var current = live else {
            guard reply.newLinesKind != .admin, !title.isEmpty, !summary.isEmpty, !chunk.new.isEmpty else { return .ignored }
            let match = reply.action == .newTopic ? locate(reply.boundaryQuote, chunk, preferFrom: chunk.new.lowerBound, within: chunk.new) : nil
            let boundary = match?.segmentIndex ?? chunkStart
            let start = match?.time ?? chunk.segments[chunkStart].start
            takeaways.append(Takeaway(title: title, summary: summary, start: start, end: max(start, latestEnd),
                                      slidePages: Self.merge([], slides), isLive: true, updatedAt: now))
            return .opened(boundary: boundary)
        }

        let isSameTitle = title.caseInsensitiveCompare(current.title) == .orderedSame
        if reply.action == .continueTopic || isSameTitle || reply.newLinesKind == .admin {
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
        guard boundaryTime - current.start >= minTopicSeconds else {
            // The live topic has barely started; splitting now would leave a sliver of a card (small
            // models over-split). Keep one card, described by the newer title and summary.
            refine(&current, title: title, summary: summary, slides: slides, end: latestEnd, now: now)
            return .refined
        }

        let closed = Text.clampSentences(PlainMath.clean(reply.closedSummary), maxChars: Self.maxSummaryChars)
        current.isLive = false
        current.end = boundaryTime
        if !closed.isEmpty { current.summary = closed }
        current.detail = nil
        current.updatedAt = now
        replaceLive(current)
        takeaways.append(Takeaway(title: title, summary: summary, start: boundaryTime, end: max(boundaryTime, latestEnd),
                                  slidePages: Self.merge([], slides), isLive: true, updatedAt: now))
        return .split(boundary: match?.segmentIndex ?? chunkStart)
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

    static func cleanTitle(_ raw: String) -> String {
        var t = PlainMath.clean(Text.collapse(raw)).trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’*#").union(.whitespaces))
        if t.hasSuffix(".") { t.removeLast() }
        return Text.truncate(t, maxChars: maxTitleChars)
    }

    private static func merge(_ a: [Int], _ b: [Int]) -> [Int] { Array(Set(a + b)).sorted() }
}
