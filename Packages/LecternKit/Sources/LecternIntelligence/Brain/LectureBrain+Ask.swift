import Foundation
import LecternCore

// MARK: - Ask

extension LectureBrain {
    static let historyMessages = 6
    /// Transcript always included for "what's happening now" questions (compact design).
    static let defaultRecentSeconds: TimeInterval = 90
    static let maxRecentSeconds: TimeInterval = 15 * 60

    /// The transcript in Ask's cached system prefix grows in steps of this much lecture time...
    static let askSnapshotStep: TimeInterval = 5 * 60
    /// ...and only up to this far behind the newest segment, so late speaker labels (which
    /// change a line's text) never rewrite it.
    static let askSnapshotSettle: TimeInterval = 30

    public func ask(_ question: String, history: [ChatMessage]) -> AsyncThrowingStream<AskEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { await self.answer(question, history: history, into: continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Replaces how Ask builds its prompts; for the evaluation harness.
    @_spi(Evaluation) public func useAskDesign(_ design: AskDesign) {
        askDesign = design
    }

    private func answer(_ question: String, history: [ChatMessage], into continuation: AsyncThrowingStream<AskEvent, Error>.Continuation) async {
        let messages = Prompts.ask(askContext(for: question, history: history), history: historyMessages(history))
        let request = askDesign.profile.request(messages)
        let provider = providers.ask
        do {
            let text = try await withRole(.ask, .answering, priority: .interactive) {
                var full = ""
                for try await event in provider.stream(request) {
                    guard case .delta(let delta) = event else { continue }
                    full += delta
                    continuation.yield(.delta(delta))
                }
                // The final message supersedes the streamed deltas, so it can be cleaned up.
                return CitationNormalizer.normalize(PlainMath.clean(full, preservingLines: true))
            }
            guard !text.isEmpty else { throw BrainError.unusableReply("empty answer") }
            continuation.yield(.done(ChatMessage(role: .assistant, text: text, citations: validCitations(in: text))))
            continuation.finish()
        } catch {
            continuation.finish(throwing: error)
        }
    }

    /// The material for one question. The standard design sends the transcript up to
    /// `askSnapshotCount()` in the system prefix and everything after it with the question; the
    /// compact design retrieves transcript windows instead.
    func askContext(for question: String, history: [ChatMessage]) -> Prompts.AskContext {
        // Follow-ups like "why?" need the previous question's terms to retrieve anything useful.
        let previous = history.last { $0.role == .user }?.text ?? ""
        let query = question + " " + previous

        var pages = question.matches(of: /(?i)slides?\s*#?\s*(\d+)/).compactMap { Int($0.1) }
        if question.range(of: #"(?i)\b(this|current)\s+slide\b"#, options: .regularExpression) != nil, let currentSlide {
            pages.insert(currentSlide, at: 0)
        }
        switch askDesign.context {
        case .transcript:
            return transcriptAskContext(question: question, query: query, pages: pages)
        case .retrieval:
            return retrievalAskContext(question: question, query: query, pages: pages)
        }
    }

    private func transcriptAskContext(question: String, query: String, pages: [Int]) -> Prompts.AskContext {
        let count = askSnapshotCount()
        let rest = segments[count...]
        var context = Prompts.AskContext(
            instructions: askDesign.instructions,
            lecture: lecture,
            digest: digest,
            transcript: TranscriptText.render(segments[..<count]),
            topics: topicList(budget: TokenBudget.askTopics),
            slides: excerpts.render(pages: pages, query: query, hits: 4, budgetTokens: TokenBudget.askSlides,
                                    maxChars: TokenBudget.askSlideChars),
            excerpts: nil,
            recent: nil,
            now: segments.last?.end,
            question: question,
            unshownSlides: unshownSlidesLabel
        )
        guard let first = rest.first else { return context }
        if TranscriptText.tokens(rest) <= TokenBudget.askRetrieved + TokenBudget.askLatest {
            context.recent = TranscriptText.render(rest)
            context.continuesFrom = first.start
            return context
        }
        // Past the prefix cap (a very long lecture): the newest part, plus matching windows from
        // between the prefix and it.
        var latestStart = rest.endIndex
        var used = 0
        while latestStart > rest.startIndex {
            let cost = TokenBudget.estimate(TranscriptText.line(rest[latestStart - 1])) + 1
            if used + cost > TokenBudget.askLatest { break }
            used += cost
            latestStart -= 1
        }
        context.recent = TranscriptText.render(rest[latestStart...])
        let from = first.start
        let to = latestStart < rest.endIndex ? rest[latestStart].start : .infinity
        context.excerpts = retrievedWindows(query, from: from, before: to, budget: TokenBudget.askRetrieved)
        return context
    }

    /// The compact design: explicitly mentioned slides, slide search hits, BM25 transcript
    /// windows, the most recent transcript, and the takeaway list, each in a small budget.
    private func retrievalAskContext(question: String, query: String, pages: [Int]) -> Prompts.AskContext {
        let slidesText = excerpts.render(pages: pages, query: query, hits: 4, budgetTokens: TokenBudget.compactAskSlides)

        let recentSeconds = Self.recentSeconds(in: question)
        let latest = segments.last?.end ?? 0
        let recentSegments = segments.filter { $0.end >= latest - recentSeconds }
        let recentBudget = recentSeconds > Self.defaultRecentSeconds ? TokenBudget.compactAskTranscript * 4 / 5 : TokenBudget.compactAskTranscript / 4
        let recent = recentSegments.isEmpty ? nil : TranscriptText.renderFitting(recentSegments[...], maxTokens: recentBudget)
        let excerptText = retrievedWindows(query, from: -.infinity, before: recentSegments.first?.start ?? .infinity,
                                           budget: TokenBudget.compactAskTranscript - recentBudget)
        return Prompts.AskContext(
            instructions: askDesign.instructions,
            lecture: lecture,
            digest: digest,
            topics: topicList(budget: TokenBudget.compactAskTakeaways),
            slides: slidesText,
            excerpts: excerptText,
            recent: recent,
            question: question,
            unshownSlides: unshownSlidesLabel
        )
    }

    /// Up to five BM25 transcript windows for `query` inside `from..<before`, in time order, within
    /// `budget` tokens; nil when none match.
    private func retrievedWindows(_ query: String, from: TimeInterval, before: TimeInterval, budget: Int) -> String? {
        // Filter before taking the top five: on a long lecture the best hits are often in the
        // prefix or the newest transcript, which the prompt already holds.
        let windows = transcriptRetriever().search(query, limit: .max)
            .filter { $0.start >= from && $0.end < before }
            .prefix(5)
            .sorted { $0.start < $1.start }
        var lines: [String] = []
        var used = 0
        for window in windows {
            let text = TranscriptText.render(window.segments)
            let cost = TokenBudget.estimate(text)
            if used + cost > budget { continue }
            lines.append(text)
            used += cost
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n[…]\n")
    }

    /// Number of leading segments in Ask's system prefix: those ending by the last
    /// `askSnapshotStep` boundary that is at least `askSnapshotSettle` behind the newest segment,
    /// cut back to a step boundary once they pass `TokenBudget.askTranscriptPrefix`. The count
    /// only grows, in steps, so consecutive questions share the prefix (and its cache) and a step
    /// only appends to it.
    func askSnapshotCount() -> Int {
        guard let latest = segments.last?.end else { return 0 }
        let boundary = ((latest - Self.askSnapshotSettle) / Self.askSnapshotStep).rounded(.down) * Self.askSnapshotStep
        guard boundary > 0 else { return 0 }
        var count = 0
        var used = 0
        var countAtStep = 0
        var stepEnd = Self.askSnapshotStep
        for segment in segments {
            guard segment.end <= boundary else { break }
            while segment.end > stepEnd {
                countAtStep = count
                stepEnd += Self.askSnapshotStep
            }
            used += TokenBudget.estimate(TranscriptText.line(segment)) + 1
            if used > TokenBudget.askTranscriptPrefix { return countAtStep }
            count += 1
        }
        return count
    }

    /// On-device only: once the Ask prefix has grown by a step, prefill it in the background so
    /// the next question pays only for its own part. Without this the first question after each
    /// step would prefill the whole transcript (~40 s for an hour of lecture on an M2 Max).
    /// One warm-up runs at a time; a step reached meanwhile is warmed when it finishes.
    func warmAskPrefixIfNeeded() {
        guard askWarmTask == nil, askDesign.context == .transcript, providers.ask.kind == .onDevice else { return }
        let count = askSnapshotCount()
        guard count > askWarmedCount else { return }
        askWarmedCount = count
        askWarmTask = Task {
            await self.runAskWarmUp(count)
            self.askWarmTask = nil
            self.warmAskPrefixIfNeeded()
        }
    }

    /// Prefills the system prefix holding the first `count` segments with a one-token request.
    private func runAskWarmUp(_ count: Int) async {
        let context = Prompts.AskContext(instructions: askDesign.instructions, lecture: lecture, digest: digest,
                                         transcript: TranscriptText.render(segments[..<count]),
                                         topics: nil, slides: nil, excerpts: nil, recent: nil, question: "")
        let request = LLMRequest(messages: Prompts.askWarmUp(context), maxTokens: 1, temperature: 0,
                                 reasoning: askDesign.profile.reasoning, priority: .background)
        // A failed warm-up costs nothing but speed: the next question prefills the prefix itself.
        _ = try? await providers.ask.complete(request)
    }

    /// Number of transcript segments in Ask's system prefix now; for the evaluation harness.
    @_spi(Evaluation) public func askSnapshotLength() -> Int { askSnapshotCount() }

    /// Prefills Ask's current system prefix and returns when done, whatever the provider; for
    /// the evaluation harness, which measures questions asked after the background warm-up.
    @_spi(Evaluation) public func warmAskPrefix() async {
        await askWarmTask?.value
        let count = askSnapshotCount()
        askWarmedCount = max(askWarmedCount, count)
        await runAskWarmUp(count)
    }

    /// "[8:10–16:55] Title: summary" lines for takeaways overlapping `from...to` (all by default),
    /// newest kept when over budget.
    func topicList(from: TimeInterval = -.infinity, to: TimeInterval = .infinity, budget: Int) -> String? {
        var lines: [String] = []
        var used = 0
        for t in timeline.takeaways.reversed() where t.end > from && t.start < to {
            let line = "[\(TimeFormat.clock(t.start))–\(TimeFormat.clock(t.end))] \(t.title)\(t.isLive ? " (now)" : ""): \(t.summary)"
            let cost = TokenBudget.estimate(line) + 1
            if used + cost > budget { break }
            lines.insert(line, at: 0)
            used += cost
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// Prior turns as chat messages (most recent last), trimmed to the design's history budget.
    func historyMessages(_ history: [ChatMessage]) -> [LLMMessage] {
        let compact = askDesign.context == .retrieval
        return Self.historyMessages(history, budget: compact ? TokenBudget.askHistory : TokenBudget.askConversation,
                                    maxChars: compact ? 1_500 : 3_000)
    }

    static func historyMessages(_ history: [ChatMessage], budget: Int, maxChars: Int) -> [LLMMessage] {
        var result: [LLMMessage] = []
        var used = 0
        for message in history.suffix(historyMessages).reversed() {
            let text = Text.truncate(message.text, maxChars: maxChars)
            let cost = TokenBudget.estimate(text)
            if used + cost > budget { break }
            result.insert(message.role == .user ? .user(text) : .assistant(text), at: 0)
            used += cost
        }
        // Chat templates expect the conversation to start with a user turn.
        while result.first?.role == .assistant { result.removeFirst() }
        return result
    }

    /// "the last 5 minutes" → 300 s; otherwise the default recent window (compact design).
    static func recentSeconds(in question: String) -> TimeInterval {
        if let match = question.firstMatch(of: /(?i)last\s+(\d+)\s*(min|minute|minutes|m)\b/), let minutes = Double(match.1) {
            return min(maxRecentSeconds, max(defaultRecentSeconds, minutes * 60))
        }
        if question.range(of: #"(?i)\b(what did i miss|catch me up|just said|right now)\b"#, options: .regularExpression) != nil {
            return 5 * 60
        }
        return defaultRecentSeconds
    }

    /// The transcript index, rebuilt only when segments were added since the last question.
    func transcriptRetriever() -> TranscriptRetriever {
        if let cached = retrieverCache, cached.count == segments.count { return cached.retriever }
        let retriever = TranscriptRetriever(segments: segments)
        retrieverCache = (segments.count, retriever)
        return retriever
    }
}
