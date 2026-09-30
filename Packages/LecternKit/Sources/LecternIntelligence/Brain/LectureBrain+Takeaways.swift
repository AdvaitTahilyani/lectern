import Foundation
import LecternCore

// MARK: - Rolling takeaways

extension LectureBrain {
    public func finish() async {
        isFinishing = true
        quizTask?.cancel()
        await summaryTask?.value
        if summarizedCount < segments.count || timeline.live != nil {
            // Drain everything that's left (in budget-sized chunks), then a final refinement.
            var ok = true
            repeat {
                ok = await summarize(final: true)
            } while ok && summarizedCount < segments.count
        }
        timeline.settleLive()
        emit(.takeaways(timeline.takeaways))
        isFinishing = false
    }

    /// Whether enough new transcript has accumulated for a rolling update.
    func shouldSummarize() -> Bool {
        guard !isFinishing, summarizedCount < segments.count, !summaryBackoff.isBlocked(at: sessionTime) else { return false }
        let pending = segments[summarizedCount...]
        if TranscriptText.wordCount(pending) >= tuning.wordsPerUpdate { return true }
        let interval = timeline.takeaways.isEmpty ? min(summaryInterval, tuning.firstUpdateSeconds) : summaryInterval
        return sessionTime - pending.first!.start >= interval
    }

    func scheduleSummaryIfNeeded() {
        guard summaryTask == nil, shouldSummarize() else { return }
        summaryTask = Task { await self.runSummaryLoop() }
    }

    private func runSummaryLoop() async {
        // Text that arrived during a call is picked up by the next iteration.
        while shouldSummarize(), !Task.isCancelled {
            guard await summarize(final: false) else { break }
        }
        summaryTask = nil
    }

    /// One rolling update over the next chunk of unsummarized transcript. Returns false on failure
    /// (already reported and backed off).
    @discardableResult
    func summarize(final: Bool) async -> Bool {
        await withRole(.summaries, .summarizing) {
            let newEnd = chunkEnd()
            let newRange = summarizedCount..<newEnd
            let live = timeline.live
            let windowStart = windowStart(for: newRange, hasLive: live != nil)
            var chunk = TopicTimeline.Chunk(segments: segments, window: windowStart..<newEnd, new: newRange)
            let isLastChunk = final && newEnd == segments.count
            let newStart = newRange.isEmpty ? (live?.end ?? 0) : segments[newRange.lowerBound].start
            let newLast = newRange.isEmpty ? newStart : segments[newEnd - 1].end
            let query = segments[newRange].suffix(12).map(\.text).joined(separator: " ")
            let onScreen = slidesShown(from: newLast, to: newLast).last
            chunk.relevantPages = Set(slidesShown(from: live?.start ?? newStart, to: newLast)
                + excerpts.neighbourhood(of: onScreen)
                + (slideSearch?.search(query, limit: 3).map(\.page) ?? []))
            let input = Prompts.SegmentationInput(
                lecture: lecture,
                digest: digest,
                transcript: TranscriptText.render(segments[chunk.window]),
                newLinesFrom: newRange.isEmpty ? nil : segments[newRange.lowerBound].start,
                liveTitle: live?.title,
                liveSummary: live?.summary,
                liveDuration: live.map { (newRange.isEmpty ? $0.end : segments[newEnd - 1].end) - $0.start },
                earlierTitles: timeline.takeaways.filter { !$0.isLive }.suffix(6).map(\.title),
                slidesInTopic: live.map { excerpts.titles(slidesShown(from: $0.start, to: newStart)) } ?? nil,
                slidesInNewLines: newRange.isEmpty ? nil : excerpts.titles(slidesShown(from: newStart, to: newLast)),
                slides: excerpts.render(pages: excerpts.neighbourhood(of: onScreen), query: query, hits: 3,
                                        budgetTokens: TokenBudget.segmentationSlides),
                isFinal: isLastChunk
            )
            do {
                let hasLive = live != nil
                var reply = try await StructuredGeneration.generate(
                    SegmentationReply.self, provider: providers.summaries,
                    messages: Prompts.segmentation(input), profile: .segmentation
                ) { try TopicTimeline.check($0, hasLiveTopic: hasLive) }
                if newRange.isEmpty { reply.action = .continueTopic }

                switch timeline.apply(reply, chunk: chunk, validPages: excerpts.validPages) {
                // Nothing opened yet: keep the skipped lines in the window so the first card can
                // still claim them. A lecture often opens with something that reads like admin
                // ("let me correct last week's slides…") but carries real content.
                case .ignored: topicWindowStart = windowStart
                case .opened(let boundary), .split(let boundary): topicWindowStart = boundary
                case .refined: topicWindowStart = windowStart
                }
                summarizedCount = max(summarizedCount, newEnd)
                summaryBackoff.succeeded()
                emit(.takeaways(timeline.takeaways))
                return true
            } catch {
                summaryBackoff.failed(at: sessionTime)
                emit(.error("Takeaways paused: \(error.brainMessage)"))
                return false
            }
        }
    }

    /// End (exclusive) of the next chunk of new transcript. A chunk is what one live update would
    /// see (up to the update interval or word threshold, within the token budget), so a backlog —
    /// after a failure, or an imported recording fed all at once — is processed in the same
    /// granularity as a live lecture, in order.
    private func chunkEnd() -> Int {
        guard summarizedCount < segments.count else { return summarizedCount }
        let first = segments[summarizedCount]
        let interval = timeline.takeaways.isEmpty ? min(summaryInterval, tuning.firstUpdateSeconds) : summaryInterval
        var end = summarizedCount
        var tokens = 0
        var words = 0
        while end < segments.count {
            let cost = TranscriptText.tokens(segments[end...end])
            if end > summarizedCount, tokens + cost > TokenBudget.newTranscriptPerUpdate { break }
            tokens += cost
            words += TranscriptText.wordCount(segments[end...end])
            end += 1
            if words >= tuning.wordsPerUpdate || segments[end - 1].end - first.start >= interval { break }
        }
        return end
    }

    /// Start of the live topic's transcript window. When the window outgrows its budget the anchor
    /// jumps forward in one step, keeping about half the budget of older context, so the next
    /// several prompts again share an identical transcript prefix.
    private func windowStart(for newRange: Range<Int>, hasLive: Bool) -> Int {
        var start = min(topicWindowStart, newRange.lowerBound)
        let total = TranscriptText.tokens(segments[start..<newRange.upperBound])
        if total > TokenBudget.topicWindow {
            let newTokens = TranscriptText.tokens(segments[newRange])
            let keepOld = max(0, min(TokenBudget.topicWindow / 2, TokenBudget.topicWindow - newTokens))
            var used = 0
            start = newRange.lowerBound
            while start > 0, start - 1 >= topicWindowStart {
                let cost = TranscriptText.tokens(segments[(start - 1)...(start - 1)])
                if used + cost > keepOld { break }
                used += cost
                start -= 1
            }
            topicWindowStart = start
        }
        return start
    }
}
