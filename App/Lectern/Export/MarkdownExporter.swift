import Foundation
import LecternCore

/// Markdown notes per DESIGN.md §4.9 "Export formats".
nonisolated enum MarkdownExporter {
    static func document(session: LectureSession, course: Course?) -> String {
        var out = "# \(session.title)\n\n"
        let date = (session.startedAt ?? session.createdAt).formatted(date: .abbreviated, time: .shortened)
        var meta = [date, TimeFormat.clock(session.duration)]
        if let course { meta.insert("\(course.code) — \(course.name)", at: 0) }
        out += meta.joined(separator: " · ") + "\n\n"

        let summaryID = SessionConventions.summaryID(for: session.id)
        if let summary = session.takeaways.first(where: { $0.id == summaryID }) {
            out += "## Summary\n\n\(summary.summary)\n\n"
            if let terms = summary.detail?.keyTerms, !terms.isEmpty {
                out += terms.map { "- **\($0.term)** — \($0.definition)" }.joined(separator: "\n") + "\n\n"
            }
        }

        let takeaways = session.takeaways.filter { $0.id != summaryID && !$0.isLive }
        if !takeaways.isEmpty {
            out += "## Takeaways\n\n"
            for t in takeaways { out += markdown(for: t, sessionID: session.id, headingLevel: 3) + "\n" }
        }

        let quiz = session.quiz.filter { $0.outcome != nil }
        if !quiz.isEmpty {
            out += "## Quiz\n\n| Time | Concept | Result |\n|---|---|---|\n"
            for r in quiz {
                let result = switch r.outcome { case .correct: "Correct"; case .incorrect: "Not quite"; case .skipped: "Skipped"; case nil: "—" }
                out += "| \(TimeFormat.clock(r.askedAt)) | \(r.question.concept) | \(result) |\n"
            }
            out += "\n"
        }

        if !session.transcript.isEmpty {
            out += "## Transcript\n\n"
            for p in LiveSessionModel.paragraphs(from: session.transcript) where p.kind == .speech {
                out += "**\(TimeFormat.clock(p.start))** \(p.text)\n\n"
            }
        }
        return out
    }

    static func markdown(for t: Takeaway, sessionID: UUID, headingLevel: Int = 3) -> String {
        let h = String(repeating: "#", count: headingLevel)
        var out = "\(h) \(t.title) (\(TimeFormat.clock(t.start))–\(TimeFormat.clock(t.end)))\n\n\(t.summary)\n\n"
        if let d = t.detail {
            for b in d.bullets { out += "- \(b)\n" }
            if !d.bullets.isEmpty { out += "\n" }
            if !d.keyTerms.isEmpty {
                out += "Key terms: " + d.keyTerms.map { "**\($0.term)**" }.joined(separator: ", ") + "\n\n"
            }
            if let e = d.example { out += "_\(e)_\n\n" }
        }
        if !t.slidePages.isEmpty {
            out += "Slides: " + t.slidePages.map { "Slide \($0)" }.joined(separator: ", ") + "\n\n"
        }
        return out
    }
}
