import Foundation
import LecternCore

// MARK: - Rolling takeaways

extension LectureBrain {
    public func finish() async {
        // A second call while one is running waits for it instead of interleaving with it.
        if let running = finishTask {
            await running.value
            return
        }
        let task = Task { await self.performFinish() }
        finishTask = task
        await task.value
        finishTask = nil
    }

    private func performFinish() async {
        isFinishing = true
        quizTask?.cancel()
        await summaryTask?.value
        if summarizedCount < segments.count || timeline.live != nil {
            // Drain everything that's left (in budget-sized chunks), then a final refinement. A
            // failing chunk is retried a few times: there's no later update to catch up.
            var failures = 0
            repeat {
                if await summarize(final: true) { failures = 0 } else { failures += 1 }
            } while failures < Self.finishAttempts && summarizedCount < segments.count && !Task.isCancelled
        }
        // Whatever still couldn't be summarized belongs to the last card rather than to no card.
        if summarizedCount < segments.count, let last = segments.last {
            // Said once, so the lecture isn't presented as fully summarized.
            let from = segments[summarizedCount].start
            let range = "\(TimeFormat.clock(from))–\(TimeFormat.clock(last.end))"
            emit(.error(timeline.live == nil
                ? "Takeaways: \(range) couldn't be summarized and has no card."
                : "Takeaways: \(range) couldn't be summarized; the last card covers it without describing it."))
            timeline.extendLive(to: last.end)
            summarizedCount = segments.count
        }
        if let live = timeline.live { try? await withRole(.summaries, .summarizing) { await rewriteAsideIfGrown(live.id) } }
        timeline.settleLive()
        emit(.takeaways(timeline.takeaways))
        isFinishing = false
    }

    /// Attempts per remaining chunk in `finish()`.
    static let finishAttempts = 3

    /// Whether enough new transcript has accumulated for a rolling update.
    func shouldSummarize() -> Bool {
        guard !isFinishing, summarizedCount < segments.count, !summaryBackoff.isBlocked(at: sessionTime) else { return false }
        let pending = segments[summarizedCount...]
        if TranscriptText.wordCount(pending) >= tuning.wordsPerUpdate { return true }
        return sessionTime - pending.first!.start >= updateInterval
    }

    /// Transcript seconds until the next rolling update is due by the interval (the word threshold
    /// can bring it forward); a full interval when nothing is waiting.
    func secondsUntilNextSummary() -> TimeInterval {
        guard summarizedCount < segments.count else { return updateInterval }
        return updateInterval - (sessionTime - segments[summarizedCount].start)
    }

    /// Seconds of new transcript per rolling update (shorter until the first card exists).
    var updateInterval: TimeInterval {
        timeline.takeaways.isEmpty ? min(summaryInterval, tuning.firstUpdateSeconds) : summaryInterval
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
        (try? await withRole(.summaries, .summarizing) {
            let newEnd = chunkEnd()
            let newRange = summarizedCount..<newEnd
            let live = timeline.live
            let windowStart = windowStart(for: newRange)
            var chunk = TopicTimeline.Chunk(segments: segments, window: windowStart..<newEnd, new: newRange)
            let isLastChunk = final && newEnd == segments.count
            let newStart = newRange.isEmpty ? (live?.end ?? 0) : segments[newRange.lowerBound].start
            let newLast = newRange.isEmpty ? newStart : segments[newEnd - 1].end
            let query = segments[newRange].suffix(12).map(\.text).joined(separator: " ")
            let onScreen = slidesShown(from: newLast, to: newLast).last
            chunk.relevantPages = Set((slidesShown(from: live?.start ?? newStart, to: newLast)
                + excerpts.neighbourhood(of: onScreen)
                + (slideSearch?.search(query, limit: 3).map(\.page) ?? [])).filter { isPresented($0, at: newLast) })
            let input = Prompts.SegmentationInput(
                lecture: lecture,
                digest: digest,
                transcript: TranscriptText.render(segments[chunk.window]),
                newLinesFrom: newRange.isEmpty ? nil : segments[newRange.lowerBound].start,
                liveTitle: live?.title,
                liveSummary: live?.summary,
                liveDuration: live.map { (newRange.isEmpty ? $0.end : segments[newEnd - 1].end) - $0.start },
                unopenedMinutes: live == nil && OpeningStretch.needsNudge(segments[chunk.window])
                    ? max(1, Int(((newLast - segments[chunk.window.lowerBound].start) / 60).rounded())) : nil,
                earlierTitles: timeline.takeaways.filter { !$0.isLive }.suffix(6).map(\.title),
                slidesInTopic: live.map { excerpts.titles(slidesShown(from: $0.start, to: newStart)) } ?? nil,
                slidesInNewLines: newRange.isEmpty ? nil : excerpts.titles(slidesShown(from: newStart, to: newLast)),
                slides: excerpts.render(pages: excerpts.neighbourhood(of: onScreen), query: query, hits: 3,
                                        budgetTokens: TokenBudget.segmentationSlides, allowed: { self.isPresented($0, at: newLast) }),
                isFinal: isLastChunk,
                unshownSlides: unshownSlidesLabel(at: newLast),
                classEndedAt: classEndedAt.flatMap { $0 <= newLast ? $0 : nil },
                liveIsAside: live.map { timeline.asideCards.contains($0.id) } ?? false
            )
            do {
                let hasLive = live != nil
                var reply = try await StructuredGeneration.generate(
                    SegmentationReply.self, provider: providers.summaries,
                    messages: Prompts.segmentation(input), profile: .segmentation
                ) { try TopicTimeline.check($0, hasLiveTopic: hasLive) }
                if newRange.isEmpty { reply.action = .continueTopic }
                reply.slides = slideSupport.supported(reply.slides.filter { isPresented($0, at: newLast) }, by: reply.title + " " + reply.summary,
                                                      fallback: chunk.relevantPages).filter { isPresented($0, at: newLast) }

                let previousLive = timeline.live
                let outcome = timeline.apply(reply, chunk: chunk, validPages: excerpts.validPages)
                // The live card is shown as soon as it is known; coverage work below (recap,
                // announcements and Q&A cards) may need further model calls.
                var shown: [Takeaway]?
                switch outcome {
                case .refined, .split:
                    shown = timeline.takeaways
                    emit(.takeaways(timeline.takeaways))
                case .ignored, .opened: break
                }
                switch outcome {
                // Nothing opened yet: keep the skipped lines in the window so the first card can
                // still claim them. A lecture often opens with something that reads like admin
                // ("let me correct last week's slides…") but carries real content; if the model
                // keeps declining a long technical stretch, it becomes a Recap card anyway.
                case .ignored:
                    topicWindowStart = windowStart
                    if await addOpeningRecap(chunk.window) { topicWindowStart = newEnd }
                case .opened(let boundary):
                    topicWindowStart = boundary
                    // The first card starts at its quoted boundary; the stretch before it must
                    // still land on a card (a recap card, or the recap card written earlier).
                    await coverBeforeFirstCard(chunk.window.lowerBound..<boundary)
                    // Opening right after a recap card on the same subject continues that card.
                    if timeline.mergeLiveIntoPreviousIfDuplicate(), let merged = timeline.live {
                        topicWindowStart = segments.firstIndex { $0.end > merged.start } ?? boundary
                    }
                case .split(let boundary):
                    topicWindowStart = boundary
                    if let previousLive { await rewriteAsideIfGrown(previousLive.id) }
                case .refined: topicWindowStart = windowStart
                }
                await trackAdminRun(kind: reply.newLinesKind, newRange: newRange)
                summarizedCount = max(summarizedCount, newEnd)
                summaryBackoff.succeeded()
                if shown != timeline.takeaways { emit(.takeaways(timeline.takeaways)) }
                return true
            } catch where error.isCancellation {
                return false
            } catch {
                summaryBackoff.failed(at: sessionTime)
                emit(.error("Takeaways paused: \(error.brainMessage)"))
                return false
            }
        }) ?? false
    }

    /// Writes a settled "Recap" card for skipped opening lines when they deserve one (see
    /// `OpeningStretch`). Returns whether a card was added. Failures are reported, not thrown:
    /// the rolling update itself succeeded.
    @discardableResult
    func addOpeningRecap(_ range: Range<Int>) async -> Bool {
        let stretch = segments[range]
        guard timeline.takeaways.filter({ !$0.isLive }).isEmpty, openingStretch.deservesRecap(stretch),
              let first = stretch.first, let last = stretch.last,
              let card = await writeRecapCard(stretch) else { return false }
        timeline.insertSettled(title: card.title, summary: card.summary, start: first.start, end: last.end)
        return true
    }

    /// Title and summary for opening lines that recap or correct earlier material, or nil (reported).
    func writeRecapCard(_ stretch: ArraySlice<TranscriptSegment>) async -> (title: String, summary: String)? {
        await writeCard(Prompts.openingRecap(lecture: lecture, digest: digest,
                                             transcript: TranscriptText.renderFitting(stretch, maxTokens: TokenBudget.topicWindow)),
                        prefix: "Recap: ", what: "the opening recap")
    }

    /// One `CardReply` call; the title gets `prefix` unless it already starts with its first word.
    /// With `mayDecline`, an empty reply means "no card" (nil, not an error).
    func writeCard(_ messages: [LLMMessage], prefix: String, what: String, mayDecline: Bool = false) async -> (title: String, summary: String)? {
        do {
            let card: (String, String)? = try await StructuredGeneration.generate(CardReply.self, provider: providers.summaries,
                                                                                  messages: messages, profile: .segmentation) { reply in
                let title = TopicTimeline.cleanTitle(reply.title)
                if mayDecline, title.isEmpty, Text.collapse(reply.summary).isEmpty { return nil }
                guard !title.isEmpty, !reply.summary.isEmpty else { throw ReplyRejected(reason: "Give a \"title\" and a \"summary\".") }
                let word = prefix.prefix { $0.isLetter || $0 == "&" }.lowercased()
                return (title.lowercased().hasPrefix(word) ? title : prefix + title, reply.summary)
            }
            return card.map { (title: $0.0, summary: $0.1) }
        } catch where error.isCancellation {
            return nil
        } catch {
            emit(.error("Takeaways: couldn't write \(what): \(error.brainMessage)"))
            return nil
        }
    }

    /// End (exclusive) of the next chunk of new transcript. A chunk is what one live update would
    /// see (up to the update interval or word threshold, within the token budget), so a backlog —
    /// after a failure, or an imported recording fed all at once — is processed in the same
    /// granularity as a live lecture, in order.
    private func chunkEnd() -> Int {
        guard summarizedCount < segments.count else { return summarizedCount }
        let first = segments[summarizedCount]
        let interval = updateInterval
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
    private func windowStart(for newRange: Range<Int>) -> Int {
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
