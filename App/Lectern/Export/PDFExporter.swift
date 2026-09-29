import AppKit
import CoreText
import Foundation
import LecternCore

/// Print-styled PDF export: US Letter, 48 pt margins, body 11 pt, mono timestamps in the margin.
/// Paginates with CoreText framesetting so long transcripts flow across pages.
nonisolated enum PDFExporter {
    private static let page = CGRect(x: 0, y: 0, width: 612, height: 792)
    private static let margin: CGFloat = 48

    static func write(session: LectureSession, course: Course?, to url: URL) throws {
        let content = attributedDocument(session: session, course: course)
        var mediaBox = page
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, [kCGPDFContextTitle: session.title] as CFDictionary) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let framesetter = CTFramesetterCreateWithAttributedString(content)
        let textRect = page.insetBy(dx: margin, dy: margin)
        var location = 0
        var pageNumber = 1
        while location < content.length {
            ctx.beginPDFPage(nil)
            let path = CGPath(rect: textRect, transform: nil)
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: location, length: 0), path, nil)
            CTFrameDraw(frame, ctx)
            let visible = CTFrameGetVisibleStringRange(frame)
            drawFooter(ctx, page: pageNumber, title: session.title)
            ctx.endPDFPage()
            if visible.length == 0 { break }
            location += visible.length
            pageNumber += 1
        }
        ctx.closePDF()
    }

    private static func drawFooter(_ ctx: CGContext, page: Int, title: String) {
        let s = NSAttributedString(string: "\(title)  ·  \(page)", attributes: [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor.gray])
        let line = CTLineCreateWithAttributedString(s)
        ctx.textPosition = CGPoint(x: margin, y: margin / 2)
        CTLineDraw(line, ctx)
    }

    static func attributedDocument(session: LectureSession, course: Course?) -> NSAttributedString {
        let doc = NSMutableAttributedString()
        let body = NSFont.systemFont(ofSize: 11)
        let mono = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)
        let gray = NSColor(white: 0.45, alpha: 1)
        func para(_ spacing: CGFloat, indent: CGFloat = 0, headIndent: CGFloat = 0) -> NSParagraphStyle {
            let p = NSMutableParagraphStyle()
            p.paragraphSpacing = spacing
            p.firstLineHeadIndent = indent
            p.headIndent = headIndent
            p.lineSpacing = 2
            return p
        }
        func add(_ text: String, font: NSFont, color: NSColor = .black, style: NSParagraphStyle) {
            doc.append(NSAttributedString(string: text + "\n", attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style]))
        }
        add(session.title, font: .systemFont(ofSize: 22, weight: .bold), style: para(4))
        var meta = [(session.startedAt ?? session.createdAt).formatted(date: .abbreviated, time: .shortened), TimeFormat.clock(session.duration)]
        if let course { meta.insert("\(course.code) — \(course.name)", at: 0) }
        add(meta.joined(separator: "  ·  "), font: body, color: gray, style: para(18))

        let summaryID = SessionConventions.summaryID(for: session.id)
        if let summary = session.takeaways.first(where: { $0.id == summaryID }) {
            add("Summary", font: .systemFont(ofSize: 15, weight: .semibold), style: para(6))
            add(summary.summary, font: body, style: para(8))
            if let terms = summary.detail?.keyTerms, !terms.isEmpty {
                add("Key terms: " + terms.map(\.term).joined(separator: ", "), font: body, color: gray, style: para(16))
            }
        }
        let takeaways = session.takeaways.filter { $0.id != summaryID && !$0.isLive }
        if !takeaways.isEmpty {
            add("Takeaways", font: .systemFont(ofSize: 15, weight: .semibold), style: para(6))
            for t in takeaways {
                add("\(TimeFormat.clock(t.start))–\(TimeFormat.clock(t.end))  \(t.title)", font: .systemFont(ofSize: 12, weight: .semibold), style: para(2))
                add(t.summary, font: body, style: para(4))
                for b in t.detail?.bullets ?? [] { add("•  \(b)", font: body, style: para(1, indent: 12, headIndent: 24)) }
                if !t.slidePages.isEmpty { add("Slides " + t.slidePages.map(String.init).joined(separator: ", "), font: mono, color: gray, style: para(10)) } else { add("", font: body, style: para(6)) }
            }
        }
        let quiz = session.quiz.filter { $0.outcome != nil }
        if !quiz.isEmpty {
            add("Quiz", font: .systemFont(ofSize: 15, weight: .semibold), style: para(6))
            for r in quiz {
                let result = switch r.outcome { case .correct: "Correct"; case .incorrect: "Not quite"; case .skipped: "Skipped"; case nil: "—" }
                add("\(TimeFormat.clock(r.askedAt))  \(result) — \(r.question.prompt)", font: body, style: para(2))
            }
            add("", font: body, style: para(8))
        }
        if !session.transcript.isEmpty {
            add("Transcript", font: .systemFont(ofSize: 15, weight: .semibold), style: para(6))
            for p in LiveSessionModel.paragraphs(from: session.transcript) where p.kind == .speech {
                let line = NSMutableAttributedString(string: TimeFormat.clock(p.start) + "  ", attributes: [.font: mono, .foregroundColor: gray])
                line.append(NSAttributedString(string: p.text + "\n", attributes: [.font: body, .foregroundColor: NSColor.black, .paragraphStyle: para(6, headIndent: 0)]))
                doc.append(line)
            }
        }
        return doc
    }
}
