import Foundation
import LecternCore

/// Markdown notes per DESIGN.md §4.9 "Export formats".
nonisolated enum MarkdownExporter {
    /// Collapses line breaks so model and user text (titles, bullets, quotes) cannot break the
    /// surrounding Markdown structure.
    private static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func document(session: LectureSession, course: Course?) -> String {
        var out = "# \(oneLine(session.title))\n\n"
        let date = (session.startedAt ?? session.createdAt).formatted(date: .abbreviated, time: .shortened)
        var meta = [date, TimeFormat.clock(session.duration)]
        if let course { meta.insert(oneLine("\(course.code) — \(course.name)"), at: 0) }
        out += meta.joined(separator: " · ") + "\n\n"

        if let summary = session.summary, !summary.isEmpty { out += markdown(for: summary) }

        let takeaways = session.takeaways.filter { !$0.isLive }
        if !takeaways.isEmpty {
            out += "## Takeaways\n\n"
            for t in takeaways { out += markdown(for: t, headingLevel: 3, deck: session.deck) + "\n" }
        }

        let quiz = session.quiz.filter { $0.outcome != nil }
        if !quiz.isEmpty {
            out += "## Quiz\n\n| Time | Concept | Result |\n|---|---|---|\n"
            for r in quiz {
                let result = switch r.outcome { case .correct: "Correct"; case .incorrect: "Not quite"; case .skipped: "Skipped"; case nil: "—" }
                out += "| \(TimeFormat.clock(r.askedAt)) | \(oneLine(r.question.concept).replacingOccurrences(of: "|", with: "\\|")) | \(result) |\n"
            }
            out += "\n"
        }

        if !session.transcript.isEmpty {
            out += "## Transcript\n\n"
            for p in LiveSessionModel.paragraphs(from: session.transcript) where p.kind == .speech {
                let student = p.segments.first?.speaker?.isLecturer == false ? " **Student:**" : ""
                out += "**\(TimeFormat.clock(p.start))**\(student) \(oneLine(p.text))\n\n"
            }
        }
        return out
    }

    /// "## Summary": overview, key concepts, what to review, what was flagged, slides to revisit.
    static func markdown(for summary: LectureSummary) -> String {
        var out = "## Summary\n\n"
        if !summary.overview.isEmpty { out += oneLine(summary.overview) + "\n\n" }
        if !summary.keyConcepts.isEmpty {
            out += "**Key concepts**\n\n" + summary.keyConcepts.map { "- **\(oneLine($0.term))** — \(oneLine($0.definition))" }.joined(separator: "\n") + "\n\n"
        }
        if !summary.reviewThese.isEmpty {
            out += "**Review these**\n\n" + summary.reviewThese.map { "- " + oneLine($0) }.joined(separator: "\n") + "\n\n"
        }
        if !summary.flagged.isEmpty {
            out += "**Flagged in the lecture**\n\n" + summary.flagged.map { "- " + oneLine($0) }.joined(separator: "\n") + "\n\n"
        }
        if !summary.slides.isEmpty {
            out += "Worth revisiting: " + summary.slides.map { "Slide \($0)" }.joined(separator: ", ") + "\n\n"
        }
        return out
    }

    /// One takeaway. With the session's `deck`, the presenter notes of the slides it covered follow it.
    static func markdown(for t: Takeaway, headingLevel: Int = 3, deck: SlideDeck? = nil) -> String {
        let h = String(repeating: "#", count: headingLevel)
        var out = "\(h) \(oneLine(t.title)) (\(TimeFormat.clock(t.start))–\(TimeFormat.clock(t.end)))\n\n\(oneLine(t.summary))\n\n"
        if let d = t.detail {
            for b in d.bullets { out += "- \(oneLine(b))\n" }
            if !d.bullets.isEmpty { out += "\n" }
            if !d.keyTerms.isEmpty {
                out += "Key terms: " + d.keyTerms.map { "**\(oneLine($0.term))**" }.joined(separator: ", ") + "\n\n"
            }
            if let e = d.example { out += "_\(oneLine(e))_\n\n" }
        }
        if !t.slidePages.isEmpty {
            out += "Slides: " + t.slidePages.map { "Slide \($0)" }.joined(separator: ", ") + "\n\n"
        }
        let notes = Array(Set(t.slidePages)).sorted().compactMap { number -> String? in
            guard let text = deck?.page(number)?.notes.map(oneLine), !text.isEmpty else { return nil }
            return "- Slide \(number): \(text)"
        }
        if !notes.isEmpty { out += "**Slide notes**\n\n" + notes.joined(separator: "\n") + "\n\n" }
        return out
    }
}
