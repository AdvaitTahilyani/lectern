import AppKit
import Foundation
import LecternCore

/// Draws a clean, realistic-looking slide deck PDF for demo sessions so thumbnails, the slide
/// column and the setup fan have something real to show.
nonisolated enum DemoDeckRenderer {
    nonisolated struct Theme: Sendable {
        var accent: NSColor
        var dark: Bool
        static let indigo = Theme(accent: NSColor(srgbRed: 0x5B/255, green: 0x5F/255, blue: 0xEF/255, alpha: 1), dark: false)
        static let teal = Theme(accent: NSColor(srgbRed: 0.10, green: 0.55, blue: 0.55, alpha: 1), dark: false)
        static let orange = Theme(accent: NSColor(srgbRed: 0.90, green: 0.45, blue: 0.10, alpha: 1), dark: true)
    }

    /// Renders `slides` into a 16:9 PDF at `url`. Returns the `SlideDeck` describing it.
    @discardableResult
    static func render(slides: [DemoScript.Slide], deckTitle: String, theme: Theme, to url: URL) throws -> SlideDeck {
        let pageRect = CGRect(x: 0, y: 0, width: 960, height: 540)
        var mediaBox = pageRect
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, [kCGPDFContextTitle: deckTitle] as CFDictionary) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let bg = theme.dark ? NSColor(white: 0.12, alpha: 1) : .white
        let fg = theme.dark ? NSColor.white : NSColor(white: 0.12, alpha: 1)
        let secondary = theme.dark ? NSColor(white: 0.75, alpha: 1) : NSColor(white: 0.40, alpha: 1)

        for (i, slide) in slides.enumerated() {
            ctx.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState()
            let gc = NSGraphicsContext(cgContext: ctx, flipped: false)
            NSGraphicsContext.current = gc
            bg.setFill(); pageRect.fill()
            // Accent bar and page number.
            theme.accent.setFill()
            CGRect(x: 0, y: pageRect.height - 10, width: pageRect.width, height: 10).fill()
            let isTitle = i == 0
            let titleFont = NSFont.systemFont(ofSize: isTitle ? 44 : 34, weight: .bold)
            let title = NSAttributedString(string: slide.title, attributes: [.font: titleFont, .foregroundColor: fg])
            let titleRect = isTitle
                ? CGRect(x: 72, y: 250, width: 816, height: 120)
                : CGRect(x: 60, y: 400, width: 840, height: 90)
            title.draw(with: titleRect, options: [.usesLineFragmentOrigin])
            if !isTitle {
                theme.accent.setFill()
                CGRect(x: 60, y: 392, width: 56, height: 4).fill()
            }
            let bodyFont = NSFont.systemFont(ofSize: isTitle ? 22 : 24, weight: .regular)
            var y: CGFloat = isTitle ? 220 : 330
            for bullet in slide.bullets {
                let para = NSMutableParagraphStyle()
                para.lineBreakMode = .byWordWrapping
                let prefix = isTitle ? "" : "•  "
                let s = NSAttributedString(string: prefix + bullet, attributes: [.font: bodyFont, .foregroundColor: isTitle ? secondary : fg, .paragraphStyle: para])
                let rect = CGRect(x: isTitle ? 72 : 80, y: y - 40, width: 800, height: 60)
                s.draw(with: rect, options: [.usesLineFragmentOrigin])
                y -= isTitle ? 36 : 58
            }
            let footer = NSAttributedString(string: "\(deckTitle)   ·   \(i + 1) / \(slides.count)", attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: secondary])
            footer.draw(at: CGPoint(x: 60, y: 28))
            NSGraphicsContext.restoreGraphicsState()
            ctx.endPDFPage()
        }
        ctx.closePDF()
        let pages = slides.enumerated().map { SlidePage(number: $0.offset + 1, title: $0.element.title, text: ([$0.element.title] + $0.element.bullets).joined(separator: "\n")) }
        return SlideDeck(fileName: url.lastPathComponent, originalFileName: url.lastPathComponent, title: deckTitle, pages: pages)
    }
}
