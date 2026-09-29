import Foundation
import LecternCore

// MARK: - Ask

extension LectureBrain {
    static let historyMessages = 6
    static let historyMessageChars = 1_500
    /// Transcript always included for "what's happening now" questions.
    static let defaultRecentSeconds: TimeInterval = 90
    static let maxRecentSeconds: TimeInterval = 15 * 60

    public func ask(_ question: String, history: [ChatMessage]) -> AsyncThrowingStream<AskEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { await self.answer(question, history: history, into: continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func answer(_ question: String, history: [ChatMessage], into continuation: AsyncThrowingStream<AskEvent, Error>.Continuation) async {
        let messages = Prompts.ask(askContext(for: question, history: history), history: Self.historyMessages(history))
        let request = LLMRequest(messages: messages, maxTokens: GenerationProfile.answer.maxTokens,
                                 temperature: GenerationProfile.answer.temperature, responseFormat: .text,
                                 reasoning: GenerationProfile.answer.reasoning)
        let provider = providers.ask
        do {
            let text = try await withRole(.ask, .answering) {
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

    /// Retrieval for one question: explicitly mentioned slides, slide search hits, BM25 transcript
    /// windows, the most recent transcript, and the takeaway list.
    func askContext(for question: String, history: [ChatMessage]) -> Prompts.AskContext {
        // Follow-ups like "why?" need the previous question's terms to retrieve anything useful.
        let previous = history.last { $0.role == .user }?.text ?? ""
        let query = question + " " + previous

        var pages = question.matches(of: /(?i)slides?\s*#?\s*(\d+)/).compactMap { Int($0.1) }
        if question.range(of: #"(?i)\b(this|current)\s+slide\b"#, options: .regularExpression) != nil, let currentSlide {
            pages.insert(currentSlide, at: 0)
        }
        let slidesText = excerpts.render(pages: pages, query: query, hits: 4, budgetTokens: TokenBudget.askSlides)

        let recentSeconds = Self.recentSeconds(in: question)
        let latest = segments.last?.end ?? 0
        let recentSegments = segments.filter { $0.end >= latest - recentSeconds }
        let recentBudget = recentSeconds > Self.defaultRecentSeconds ? TokenBudget.askTranscript * 4 / 5 : TokenBudget.askTranscript / 4
        let recent = recentSegments.isEmpty ? nil : TranscriptText.renderFitting(recentSegments[...], maxTokens: recentBudget)

        let recentStart = recentSegments.first?.start ?? .infinity
        let windows = TranscriptRetriever(segments: segments).search(query, limit: 5)
            .filter { $0.end < recentStart }
            .sorted { $0.start < $1.start }
        var excerptLines: [String] = []
        var used = 0
        for window in windows {
            let text = TranscriptText.render(window.segments)
            let cost = TokenBudget.estimate(text)
            if used + cost > TokenBudget.askTranscript - recentBudget { continue }
            excerptLines.append(text)
            used += cost
        }

        return Prompts.AskContext(
            lecture: lecture,
            digest: digest,
            topics: topicList(),
            slides: slidesText,
            excerpts: excerptLines.isEmpty ? nil : excerptLines.joined(separator: "\n[…]\n"),
            recent: recent,
            question: question
        )
    }

    /// "[8:10–16:55] Title: summary" lines for takeaways overlapping `from...to` (all by default),
    /// newest kept when over budget.
    func topicList(from: TimeInterval = -.infinity, to: TimeInterval = .infinity, budget: Int = TokenBudget.askTakeaways) -> String? {
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

    /// Prior turns as chat messages (most recent last), trimmed to the history budget.
    static func historyMessages(_ history: [ChatMessage]) -> [LLMMessage] {
        var result: [LLMMessage] = []
        var used = 0
        for message in history.suffix(historyMessages).reversed() {
            let text = Text.truncate(message.text, maxChars: historyMessageChars)
            let cost = TokenBudget.estimate(text)
            if used + cost > TokenBudget.askHistory { break }
            result.insert(message.role == .user ? .user(text) : .assistant(text), at: 0)
            used += cost
        }
        // Chat templates expect the conversation to start with a user turn.
        while result.first?.role == .assistant { result.removeFirst() }
        return result
    }

    /// "the last 5 minutes" → 300 s; otherwise the default recent window.
    static func recentSeconds(in question: String) -> TimeInterval {
        if let match = question.firstMatch(of: /(?i)last\s+(\d+)\s*(min|minute|minutes|m)\b/), let minutes = Double(match.1) {
            return min(maxRecentSeconds, max(defaultRecentSeconds, minutes * 60))
        }
        if question.range(of: #"(?i)\b(what did i miss|catch me up|just said|right now)\b"#, options: .regularExpression) != nil {
            return 5 * 60
        }
        return defaultRecentSeconds
    }
}
