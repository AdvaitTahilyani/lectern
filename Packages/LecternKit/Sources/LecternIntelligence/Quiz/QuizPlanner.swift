import Foundation
import LecternCore

/// Decides what to quiz on and in which format, and tracks concept mastery from recorded outcomes.
/// A "concept" is a takeaway (its time range); question records map back to takeaways by their
/// source time.
struct QuizPlanner: Sendable {
    enum Format: Sendable, Equatable { case multipleChoice, shortAnswer }

    /// What a question should be about.
    struct Target: Sendable, Equatable {
        var title: String
        var summary: String
        var start: TimeInterval
        var end: TimeInterval
        var slides: [Int]
        /// Earlier question prompts on this concept, which must not be repeated.
        var avoid: [String]
        /// For follow-ups: the question being followed up and the student's answer to it.
        var followUp: QuizQuestion?
        var previousAnswer: String?
    }

    private(set) var records: [QuizRecord]

    /// A live topic becomes quizzable once it has run this long.
    static let minimumLiveTopicSeconds: TimeInterval = 180
    /// Topics shorter than this are too thin to quiz.
    static let minimumTopicSeconds: TimeInterval = 45

    init(records: [QuizRecord]) {
        self.records = records.sorted { $0.askedAt < $1.askedAt }
    }

    mutating func record(_ record: QuizRecord) {
        if let i = records.firstIndex(where: { $0.id == record.id }) {
            records[i] = record
        } else {
            records.append(record)
            records.sort { $0.askedAt < $1.askedAt }
        }
    }

    /// Records whose question was drawn from `takeaway`'s time range.
    func attempts(on takeaway: Takeaway) -> [QuizRecord] {
        records.filter { record in
            guard let start = record.question.sourceStart else { return false }
            let end = record.question.sourceEnd ?? start
            let mid = (start + end) / 2
            return mid >= takeaway.start - 0.5 && mid <= takeaway.end + 0.5
        }
    }

    /// Picks the next concept: the most recent never-quizzed topic, else a missed topic that wasn't
    /// the very last question (so a miss is revisited later, not immediately), else the least-quizzed.
    func chooseTakeaway(from takeaways: [Takeaway]) -> Takeaway? {
        let candidates = takeaways.filter { t in
            let length = t.end - t.start
            return t.isLive ? length >= Self.minimumLiveTopicSeconds : length >= Self.minimumTopicSeconds
        }
        guard !candidates.isEmpty else { return nil }
        let history = candidates.map { (takeaway: $0, attempts: attempts(on: $0)) }

        if let fresh = history.last(where: { $0.attempts.isEmpty }) { return fresh.takeaway }

        let lastQuestionTopic = records.last.flatMap { last in history.first { $0.attempts.contains { $0.id == last.id } }?.takeaway.id }
        if let missed = history.first(where: { $0.attempts.last?.outcome == .incorrect && $0.takeaway.id != lastQuestionTopic }) {
            return missed.takeaway
        }
        return history.min { a, b in
            if a.attempts.count != b.attempts.count { return a.attempts.count < b.attempts.count }
            return (a.attempts.last?.askedAt ?? 0) < (b.attempts.last?.askedAt ?? 0)
        }?.takeaway
    }

    func target(for takeaway: Takeaway) -> Target {
        Target(title: takeaway.title, summary: takeaway.summary, start: takeaway.start, end: takeaway.end,
               slides: takeaway.slidePages, avoid: attempts(on: takeaway).map(\.question.prompt))
    }

    /// Same concept and source as `question`, avoiding every earlier question on it.
    func followUpTarget(for question: QuizQuestion, takeaways: [Takeaway]) -> Target {
        let start = question.sourceStart ?? 0
        let end = question.sourceEnd ?? start
        let source = takeaways.first { $0.start <= (start + end) / 2 && (start + end) / 2 <= $0.end }
        var avoid = records.filter { $0.question.concept.caseInsensitiveCompare(question.concept) == .orderedSame }.map(\.question.prompt)
        if !avoid.contains(question.prompt) { avoid.append(question.prompt) }
        return Target(title: question.concept, summary: source?.summary ?? "", start: start, end: end,
                      slides: question.sourceSlides, avoid: avoid, followUp: question,
                      previousAnswer: records.first { $0.id == question.id }?.answer)
    }

    /// Multiple choice is more likely at gentle difficulty and for follow-ups (fast to answer in the
    /// quiz card); short answer more likely when challenging.
    static func chooseFormat(_ settings: QuizSettings, isFollowUp: Bool, using rng: inout some RandomNumberGenerator) -> Format {
        switch (settings.allowMultipleChoice, settings.allowShortAnswer) {
        case (true, false), (false, false): return .multipleChoice
        case (false, true): return .shortAnswer
        case (true, true):
            if isFollowUp { return .multipleChoice }
            let mcqShare: Double = switch settings.difficulty {
            case .gentle: 0.8
            case .standard: 0.6
            case .challenging: 0.4
            }
            return Double.random(in: 0..<1, using: &rng) < mcqShare ? .multipleChoice : .shortAnswer
        }
    }

    /// The first three distractors that differ from the answer and from each other, or nil if
    /// there aren't three.
    static func distinctDistractors(correct: String, distractors: [String]) -> [String]? {
        let answer = Text.collapse(correct)
        guard !answer.isEmpty else { return nil }
        var seen: Set<String> = [answer.lowercased()]
        var wrong: [String] = []
        for d in distractors.map(Text.collapse) where !d.isEmpty && seen.insert(d.lowercased()).inserted {
            wrong.append(d)
        }
        return wrong.count >= 3 ? Array(wrong.prefix(3)) : nil
    }

    /// Four options (the correct one plus three distinct distractors) shuffled in code, so the
    /// correct position is uniform no matter where the model tends to put it.
    static func assembleOptions(correct: String, distractors: [String], using rng: inout some RandomNumberGenerator) -> (options: [String], correctIndex: Int)? {
        guard let wrong = distinctDistractors(correct: correct, distractors: distractors) else { return nil }
        let answer = Text.collapse(correct)
        let options = ([answer] + wrong).shuffled(using: &rng)
        return (options, options.firstIndex(of: answer)!)
    }

    /// Resolves an MCQ answer given as a 0-based index ("2"), a letter ("C"), or the option text.
    static func choiceIndex(_ answer: String, options: [String]) -> Int? {
        let a = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        if let i = Int(a), options.indices.contains(i) { return i }
        if a.count == 1, let scalar = a.uppercased().unicodeScalars.first, ("A"..."Z").contains(Character(scalar)) {
            let i = Int(scalar.value) - 65
            if options.indices.contains(i) { return i }
        }
        return options.firstIndex { $0.caseInsensitiveCompare(a) == .orderedSame }
    }

    /// True when `prompt` is essentially one of `earlier` (same words).
    static func isRepeat(_ prompt: String, of earlier: [String]) -> Bool {
        earlier.contains { Text.similarity($0, prompt) >= 0.8 }
    }
}
