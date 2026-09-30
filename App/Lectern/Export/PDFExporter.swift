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
        let blocks = attributedBlocks(session: session, course: course)
        var mediaBox = page
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, [kCGPDFContextTitle: session.title] as CFDictionary) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let textRect = page.insetBy(dx: margin, dy: margin)
        var pageNumber = 1
        var y = textRect.maxY          // next block's top edge (CG coordinates, y up)
        var pageOpen = false
        func openPage() { ctx.beginPDFPage(nil); pageOpen = true; y = textRect.maxY }
        func closePage() { drawFooter(ctx, page: pageNumber, title: session.title); ctx.endPDFPage(); pageOpen = false; pageNumber += 1 }

        // Blocks (a takeaway's title + summary + bullets is one block) are kept together when they
        // fit on a page; only blocks taller than a page are split (QA V8).
        for block in blocks {
            let setter = CTFramesetterCreateWithAttributedString(block)
            let needed = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(), nil, CGSize(width: textRect.width, height: .greatestFiniteMagnitude), nil).height
            if !pageOpen { openPage() }
            if needed > y - textRect.minY, needed <= textRect.height { closePage(); openPage() }
            var location = 0
            while location < block.length {
                if !pageOpen { openPage() }
                let available = y - textRect.minY
                let rect = CGRect(x: textRect.minX, y: textRect.minY, width: textRect.width, height: available)
                let frame = CTFramesetterCreateFrame(setter, CFRange(location: location, length: 0), CGPath(rect: rect, transform: nil), nil)
                let visible = CTFrameGetVisibleStringRange(frame)
                if visible.length == 0 { closePage(); continue }
                CTFrameDraw(frame, ctx)
                let drawn = CTFramesetterSuggestFrameSizeWithConstraints(setter, visible, nil, CGSize(width: textRect.width, height: .greatestFiniteMagnitude), nil).height
                y -= drawn
                location += visible.length
                if location < block.length { closePage() }
            }
        }
        if pageOpen { closePage() }
        ctx.closePDF()
    }

    private static func drawFooter(_ ctx: CGContext, page: Int, title: String) {
        let s = NSAttributedString(string: "\(title)  ·  \(page)", attributes: [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor.gray])
        let line = CTLineCreateWithAttributedString(s)
        ctx.textPosition = CGPoint(x: margin, y: margin / 2)
        CTLineDraw(line, ctx)
    }

    /// The document as blocks that should not be split across pages when avoidable.
    static func attributedBlocks(session: LectureSession, course: Course?) -> [NSAttributedString] {
        var blocks: [NSAttributedString] = []
        var doc = NSMutableAttributedString()
        func flush() { if doc.length > 0 { blocks.append(doc); doc = NSMutableAttributedString() } }
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
        flush()

        if let summary = session.summary, !summary.isEmpty {
            add("Summary", font: .systemFont(ofSize: 15, weight: .semibold), style: para(6))
            add(summary.overview, font: body, style: para(8))
            func list(_ title: String, _ items: [String]) {
                guard !items.isEmpty else { return }
                add(title, font: .systemFont(ofSize: 11, weight: .semibold), style: para(2))
                for item in items { add("•  \(item)", font: body, style: para(1, indent: 12, headIndent: 24)) }
                add("", font: body, style: para(4))
            }
            list("Key concepts", summary.keyConcepts.map { "\($0.term) — \($0.definition)" })
            list("Review these", summary.reviewThese)
            list("Flagged in the lecture", summary.flagged)
            if !summary.slides.isEmpty {
                add("Worth revisiting: slides " + summary.slides.map(String.init).joined(separator: ", "), font: mono, color: gray, style: para(16))
            }
            flush()
        }
        let takeaways = session.takeaways.filter { !$0.isLive }
        if !takeaways.isEmpty {
            add("Takeaways", font: .systemFont(ofSize: 15, weight: .semibold), style: para(6))
            for t in takeaways {
                flush()
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
            flush()
        }
        if !session.transcript.isEmpty {
            add("Transcript", font: .systemFont(ofSize: 15, weight: .semibold), style: para(6))
            for p in LiveSessionModel.paragraphs(from: session.transcript) where p.kind == .speech {
                let line = NSMutableAttributedString(string: TimeFormat.clock(p.start) + "  ", attributes: [.font: mono, .foregroundColor: gray])
                line.append(NSAttributedString(string: p.text + "\n", attributes: [.font: body, .foregroundColor: NSColor.black, .paragraphStyle: para(6, headIndent: 0)]))
                doc.append(line)
                flush()
            }
        }
        flush()
        return blocks
    }
}
