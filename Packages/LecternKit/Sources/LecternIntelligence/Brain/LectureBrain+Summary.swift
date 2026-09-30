import Foundation
import LecternCore

// MARK: - Lecture summary (Review)

extension LectureBrain {
    static let maxOverviewSentences = 5
    static let maxKeyConcepts = 8
    static let maxFlagged = 5
    static let maxSummarySlides = 6
    /// Detail bullets shown per topic when the budget has room.
    static let summaryBulletsPerTopic = 4

    /// One structured call over what the brain already holds — takeaways (with details), quiz
    /// records, flagged lines and the deck digest — so it works the same for a lecture reopened from
    /// its `BrainContext`. Model output is grounded in code: `reviewThese` exists only for concepts
    /// actually missed, `flagged` only when something in the lecture could have flagged it, and
    /// slides only when they exist in the deck.
    public func lectureSummary() async throws -> LectureSummary {
        let topics = timeline.takeaways
        guard !topics.isEmpty || !segments.isEmpty else { throw BrainError.nothingToSummarize }
        let misses = missedConcepts()
        let announcements = announcementLines(in: segments[...], budget: TokenBudget.summaryAnnouncements, strongFirst: true)
        let flags = recapFlags
        let input = Prompts.LectureSummaryInput(
            lecture: lecture,
            digest: digest,
            topics: topics.isEmpty ? nil : summaryTopics(topics, budget: TokenBudget.summaryTopics),
            transcript: topics.isEmpty ? TranscriptText.renderFitting(segments[...], maxTokens: TokenBudget.summaryTopics) : nil,
            announcements: announcements.isEmpty ? nil : announcements.joined(separator: "\n"),
            recapFlags: flags,
            quizMisses: Self.renderMisses(misses, budget: TokenBudget.summaryQuiz),
            hasDeck: !excerpts.validPages.isEmpty
        )
        let reply = try await withRole(.summaries, .summarizing, priority: .interactive) {
            try await StructuredGeneration.generate(
                LectureSummaryReply.self, provider: providers.summaries,
                messages: Prompts.lectureSummary(input), profile: .lectureSummary
            ) { reply in
                guard !Text.wholeSentences(PlainMath.clean(reply.overview), limit: Self.maxOverviewSentences).isEmpty else {
                    throw ReplyRejected(reason: "\"overview\" must be 3-5 whole sentences about the lecture.")
                }
                return reply
            }
        }
        return LectureSummary(
            overview: Text.wholeSentences(PlainMath.clean(reply.overview), limit: Self.maxOverviewSentences),
            keyConcepts: keyConcepts(from: reply.keyConcepts, topics: topics),
            reviewThese: Self.reviewItems(reply.reviewThese, misses: misses),
            flagged: announcements.isEmpty && flags.isEmpty ? [] : Self.flaggedItems(reply.flagged),
            slides: summarySlides(reply.slides, topics: topics)
        )
    }

    // MARK: Material

    /// "[m:ss–m:ss] Title [S2, S3]: summary" per topic, then each topic's detail (bullets and key
    /// terms) while the budget has room. Topic lines are never dropped for details; if even they
    /// don't fit, the middle of the lecture is elided.
    func summaryTopics(_ topics: [Takeaway], budget: Int) -> String {
        let heads = topics.map { t in
            let slides = t.slidePages.isEmpty ? "" : " [" + t.slidePages.map { "S\($0)" }.joined(separator: ", ") + "]"
            return "[\(TimeFormat.clock(t.start))–\(TimeFormat.clock(t.end))] \(Text.collapse(t.title))\(slides): \(Text.collapse(t.summary))"
        }
        let headCost = heads.reduce(0) { $0 + TokenBudget.estimate($1) + 1 }
        guard headCost <= budget else { return Self.fitLines(heads, budget: budget) }

        var remaining = budget - headCost
        var blocks = heads
        for (i, t) in topics.enumerated() {
            guard let detail = t.detail else { continue }
            var lines = detail.bullets.prefix(Self.summaryBulletsPerTopic).map { "  - " + Text.collapse($0) }
            if !detail.keyTerms.isEmpty {
                lines.append("  Key terms: " + detail.keyTerms.map { "\(Text.collapse($0.term)): \(Text.collapse($0.definition))" }.joined(separator: "; "))
            }
            let text = lines.joined(separator: "\n")
            let cost = TokenBudget.estimate(text) + 1
            guard !lines.isEmpty, cost <= remaining else { continue }
            blocks[i] += "\n" + text
            remaining -= cost
        }
        return blocks.joined(separator: "\n")
    }

    /// Lines within `budget`: the opening ~35% and closing ~65%, with "[…]" between.
    static func fitLines(_ lines: [String], budget: Int) -> String {
        var head: [String] = [], tail: [String] = []
        var used = 0
        for line in lines {
            let cost = TokenBudget.estimate(line) + 1
            if used + cost > budget * 35 / 100 { break }
            head.append(line); used += cost
        }
        used = 0
        for line in lines.dropFirst(head.count).reversed() {
            let cost = TokenBudget.estimate(line) + 1
            if used + cost > budget - budget * 35 / 100 { break }
            tail.insert(line, at: 0); used += cost
        }
        return (head + ["[…]"] + tail).joined(separator: "\n")
    }

    /// A concept the student answered wrong at least once.
    struct MissedConcept: Sendable, Equatable {
        var concept: String
        var records: [QuizRecord]
        /// A later question on the same concept was answered correctly.
        var recovered: Bool
    }

    /// Incorrect quiz answers grouped by concept, in the order they were asked. Skipped questions
    /// aren't misses: the student never attempted them.
    func missedConcepts() -> [MissedConcept] {
        var result: [MissedConcept] = []
        for record in planner.records where record.outcome == .incorrect {
            let concept = Text.collapse(record.question.concept)
            if let i = result.firstIndex(where: { $0.concept.caseInsensitiveCompare(concept) == .orderedSame }) {
                result[i].records.append(record)
            } else {
                result.append(MissedConcept(concept: concept, records: [record], recovered: false))
            }
        }
        for i in result.indices {
            let lastMiss = result[i].records.map(\.askedAt).max() ?? 0
            result[i].recovered = planner.records.contains { r in
                r.outcome == .correct && r.askedAt >= lastMiss
                    && r.question.concept.caseInsensitiveCompare(result[i].concept) == .orderedSame
            }
        }
        return result
    }

    static func renderMisses(_ misses: [MissedConcept], budget: Int) -> String? {
        var blocks: [String] = []
        var used = 0
        for miss in misses {
            var lines = ["- Concept: \(miss.concept)" + (miss.recovered ? " (later answered a follow-up correctly)" : "")]
            for record in miss.records.prefix(2) {
                lines.append("  Question: \(Text.collapse(record.question.prompt))")
                lines.append("  Correct answer: \(correctAnswer(record.question))")
                if let given = givenAnswer(record) { lines.append("  Student answered: \(given)") }
            }
            let block = lines.joined(separator: "\n")
            let cost = TokenBudget.estimate(block) + 1
            if used + cost > budget, !blocks.isEmpty { break }
            blocks.append(block)
            used += cost
        }
        return blocks.isEmpty ? nil : blocks.joined(separator: "\n")
    }

    private static func correctAnswer(_ question: QuizQuestion) -> String {
        switch question.kind {
        case let .multipleChoice(options, correct): options.indices.contains(correct) ? Text.collapse(options[correct]) : "?"
        case let .shortAnswer(reference): Text.collapse(reference)
        }
    }

    private static func givenAnswer(_ record: QuizRecord) -> String? {
        guard let answer = record.answer.map(Text.collapse), !answer.isEmpty else { return nil }
        if case let .multipleChoice(options, _) = record.question.kind {
            return QuizPlanner.choiceIndex(answer, options: options).map { Text.collapse(options[$0]) }
        }
        return answer
    }

    // MARK: Grounding the reply

    /// The model's items, one per missed concept at most; for a concept the model left out, a
    /// line built from the question itself. Always empty when nothing was missed.
    static func reviewItems(_ items: [String], misses: [MissedConcept]) -> [String] {
        guard !misses.isEmpty else { return [] }
        var result: [String] = []
        for item in items.map({ PlainMath.clean(Text.collapse($0)) }) where !isPlaceholder(item) {
            guard result.count < misses.count, !result.contains(where: { Text.similarity($0, item) >= 0.8 }) else { continue }
            result.append(Text.clampSentences(item, maxChars: 220))
        }
        for miss in misses where result.count < misses.count {
            let named = result.contains { $0.range(of: miss.concept, options: .caseInsensitive) != nil }
            guard !named, let first = miss.records.first else { continue }
            result.append("\(miss.concept) — the answer to \"\(Text.truncate(Text.collapse(first.question.prompt), maxChars: 90))\" is \(Text.truncate(correctAnswer(first.question), maxChars: 90)).")
        }
        return result
    }

    static func flaggedItems(_ items: [String]) -> [String] {
        var result: [String] = []
        for item in items.map({ PlainMath.clean(Text.collapse($0)) }) where !isPlaceholder(item) {
            guard !result.contains(where: { Text.similarity($0, item) >= 0.8 }) else { continue }
            result.append(Text.clampSentences(item, maxChars: 160))
            if result.count == maxFlagged { break }
        }
        return result
    }

    /// Empty, or a model's way of saying "nothing" when it writes a string instead of [].
    static func isPlaceholder(_ item: String) -> Bool {
        ["", "-", "none", "n/a", "na", "null", "nothing", "[]"].contains(item.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". ")))
    }

    /// The model's concepts, deduplicated; the takeaways' own key terms when it gave none.
    func keyConcepts(from reply: [LenientKeyTerm], topics: [Takeaway]) -> [KeyTerm] {
        let written = reply.filter(\.isUsable).map { KeyTerm(term: PlainMath.clean($0.term), definition: PlainMath.clean($0.definition)) }
        let candidates = written.isEmpty ? topics.flatMap { $0.detail?.keyTerms ?? [] } : written
        var seen = Set<String>()
        return Array(candidates.filter { seen.insert($0.term.lowercased()).inserted }.prefix(Self.maxKeyConcepts))
    }

    /// Cited slides that exist; otherwise the first slide of each topic.
    func summarySlides(_ cited: [Int], topics: [Takeaway]) -> [Int] {
        let valid = excerpts.sanitize(cited)
        let pages = valid.isEmpty ? excerpts.sanitize(topics.compactMap(\.slidePages.first)) : valid
        return Array(pages.prefix(Self.maxSummarySlides))
    }
}
