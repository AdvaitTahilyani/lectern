import Foundation
import LecternCore

/// Renders a finished lecture as study notes in Markdown.
///
/// Sections, in order: header (course, date, duration), Takeaways (with the presenter notes of the
/// slides each one covered), Quiz results, Transcript (audience voices marked "Student").
/// Empty sections are omitted. Output is deterministic for a given locale and time zone.
public struct MarkdownExporter: Sendable {
    public var locale: Locale
    public var timeZone: TimeZone
    /// Set to `false` for a summary without the (long) transcript.
    public var includesTranscript: Bool

    public init(locale: Locale = .current, timeZone: TimeZone = .current, includesTranscript: Bool = true) {
        self.locale = locale
        self.timeZone = timeZone
        self.includesTranscript = includesTranscript
    }

    /// A file name for the export, e.g. "CS 421 - Top-Down Parsing - 2026-09-29.md".
    public func suggestedFileName(for session: LectureSession, course: Course? = nil) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: session.startedAt ?? session.createdAt)
        let date = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters).union(.newlines)
        let name = [course?.code, session.title, date].compactMap { $0 }.joined(separator: " - ")
        let cleaned = name.components(separatedBy: forbidden).joined(separator: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return cleaned + ".md"
    }

    /// The notes for `session`. `course` supplies the course line when the session belongs to one.
    public func markdown(for session: LectureSession, course: Course? = nil) -> String {
        var blocks: [String] = ["# " + oneLine(session.title)]
        blocks.append(header(for: session, course: course))
        if let takeaways = takeawaysSection(session.takeaways, deck: session.deck) { blocks.append(takeaways) }
        if let quiz = quizSection(session.quiz) { blocks.append(quiz) }
        if includesTranscript, let transcript = transcriptSection(session.transcript) { blocks.append(transcript) }
        return blocks.joined(separator: "\n\n") + "\n"
    }

    /// Library-wide search; see `LibrarySearch`.
    public func search(_ query: String, in sessions: [LectureSession]) -> [SearchHit] {
        LibrarySearch.search(query, in: sessions)
    }

    // MARK: Header

    private func header(for session: LectureSession, course: Course?) -> String {
        var lines: [String] = []
        if let course {
            let name = course.name.isEmpty ? course.code : "\(course.code) \u{2014} \(course.name)"
            lines.append("- **Course:** \(oneLine(name))")
        }
        lines.append("- **Date:** \(formatted(session.startedAt ?? session.createdAt))")
        if session.duration > 0 { lines.append("- **Duration:** \(TimeFormat.clock(session.duration))") }
        if let deck = session.deck {
            let count = deck.pages.count
            lines.append("- **Slides:** \(oneLine(deck.title ?? deck.originalFileName)) (\(count) \(count == 1 ? "slide" : "slides"))")
        }
        return lines.joined(separator: "\n")
    }

    private func formatted(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .long, time: .omitted, locale: locale, calendar: .init(identifier: .gregorian), timeZone: timeZone))
    }

    // MARK: Takeaways

    private func takeawaysSection(_ takeaways: [Takeaway], deck: SlideDeck?) -> String? {
        guard !takeaways.isEmpty else { return nil }
        let entries = takeaways.sorted { $0.start < $1.start }.enumerated().map { index, takeaway in
            takeawayBlock(takeaway, number: index + 1, deck: deck)
        }
        return "## Takeaways\n\n" + entries.joined(separator: "\n\n")
    }

    private func takeawayBlock(_ takeaway: Takeaway, number: Int, deck: SlideDeck?) -> String {
        var lines = ["### \(number). \(oneLine(takeaway.title))"]
        var meta = "\(TimeFormat.clock(takeaway.start))\u{2013}\(TimeFormat.clock(takeaway.end))"
        if !takeaway.slidePages.isEmpty { meta += " \u{00B7} " + slideReference(takeaway.slidePages) }
        lines.append("*\(meta)*")
        if !takeaway.summary.isEmpty { lines.append("\n" + takeaway.summary) }
        if let detail = takeaway.detail {
            if !detail.bullets.isEmpty { lines.append("\n" + detail.bullets.map { "- " + oneLine($0) }.joined(separator: "\n")) }
            if !detail.keyTerms.isEmpty {
                let terms = detail.keyTerms.map { "- **\(oneLine($0.term))**: \(oneLine($0.definition))" }
                lines.append("\n**Key terms**\n\n" + terms.joined(separator: "\n"))
            }
            if let example = detail.example, !example.isEmpty { lines.append("\n**Example.** " + example) }
        }
        let notes = Array(Set(takeaway.slidePages)).sorted().compactMap { number -> String? in
            guard let text = deck?.page(number)?.notes.map(oneLine), !text.isEmpty else { return nil }
            return "- Slide \(number): \(text)"
        }
        if !notes.isEmpty { lines.append("\n**Slide notes**\n\n" + notes.joined(separator: "\n")) }
        return lines.joined(separator: "\n")
    }

    /// "Slide 4", "Slides 3\u{2013}5, 9".
    private func slideReference(_ pages: [Int]) -> String {
        let sorted = Array(Set(pages)).sorted()
        var ranges: [String] = []
        var start = sorted[0], previous = sorted[0]
        for page in sorted.dropFirst() + [Int.max] {
            if page == previous + 1 { previous = page; continue }
            ranges.append(start == previous ? "\(start)" : "\(start)\u{2013}\(previous)")
            start = page; previous = page
        }
        return (sorted.count == 1 ? "Slide " : "Slides ") + ranges.joined(separator: ", ")
    }

    // MARK: Quiz

    private func quizSection(_ records: [QuizRecord]) -> String? {
        let answered = records.filter { $0.outcome == .correct || $0.outcome == .incorrect }
        let skipped = records.filter { $0.outcome == .skipped }.count
        guard !answered.isEmpty || skipped > 0 else { return nil }

        let correct = answered.filter { $0.outcome == .correct }.count
        var score = "**Score:** \(correct) of \(answered.count) correct"
        if !answered.isEmpty { score += " (\(Int((Double(correct) / Double(answered.count) * 100).rounded()))%)" }
        if skipped > 0 { score += " \u{00B7} \(skipped) skipped" }

        var blocks = ["## Quiz results", score]
        let missed = answered.filter { $0.outcome == .incorrect }.sorted { $0.askedAt < $1.askedAt }
        if !missed.isEmpty {
            var byConcept: [(concept: String, records: [QuizRecord])] = []
            for record in missed {
                let concept = oneLine(record.question.concept)
                if let index = byConcept.firstIndex(where: { $0.concept.caseInsensitiveCompare(concept) == .orderedSame }) {
                    byConcept[index].records.append(record)
                } else {
                    byConcept.append((concept, [record]))
                }
            }
            blocks.append("### Missed concepts")
            blocks += byConcept.map(missedBlock)
        }
        return blocks.joined(separator: "\n\n")
    }

    private func missedBlock(_ group: (concept: String, records: [QuizRecord])) -> String {
        var lines = ["#### " + (group.concept.isEmpty ? "Question" : group.concept)]
        for record in group.records {
            lines.append("\n**Q:** " + oneLine(record.question.prompt))
            if let given = givenAnswer(record) { lines.append("**Your answer:** " + given) }
            lines.append("**Correct answer:** " + correctAnswer(record.question))
            if let feedback = record.grade?.feedback, !feedback.isEmpty { lines.append("**Explanation:** " + oneLine(feedback)) }
        }
        return lines.joined(separator: "\n")
    }

    private func givenAnswer(_ record: QuizRecord) -> String? {
        guard let answer = record.answer, !answer.isEmpty else { return nil }
        if case .multipleChoice(let options, _) = record.question.kind, let index = Int(answer), options.indices.contains(index) {
            return optionLabel(options, index)
        }
        return oneLine(answer)
    }

    private func correctAnswer(_ question: QuizQuestion) -> String {
        switch question.kind {
        case .multipleChoice(let options, let correctIndex):
            options.indices.contains(correctIndex) ? optionLabel(options, correctIndex) : "\u{2014}"
        case .shortAnswer(let reference):
            oneLine(reference)
        }
    }

    private func optionLabel(_ options: [String], _ index: Int) -> String {
        let letter = Character(UnicodeScalar(UInt8(ascii: "A") + UInt8(min(index, 25))))
        return "\(letter). \(oneLine(options[index]))"
    }

    // MARK: Transcript

    private func transcriptSection(_ segments: [TranscriptSegment]) -> String? {
        let lines = segments.filter(\.isFinal).sorted { $0.start < $1.start }.compactMap { segment -> String? in
            let text = oneLine(segment.text)
            guard !text.isEmpty else { return nil }
            let speaker: String
            if case .audience = segment.speaker { speaker = " **Student:**" } else { speaker = "" }
            return "**[\(timestamp(segment.start))]**\(speaker) \(text)"
        }
        guard !lines.isEmpty else { return nil }
        return "## Transcript\n\n" + lines.joined(separator: "\n\n")
    }

    /// "[mm:ss]", or "[h:mm:ss]" past the first hour.
    private func timestamp(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let (h, m, s) = (total / 3600, (total % 3600) / 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    /// Collapses line breaks so model/user text cannot break the surrounding Markdown structure.
    private func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
