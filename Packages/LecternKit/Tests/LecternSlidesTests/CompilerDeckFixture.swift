import CoreGraphics
import CoreText
import Foundation

/// Builds a realistic 10-slide compilers lecture PDF (CS 421, LL(1) parsing) with CoreGraphics:
/// real text with a big title font, a repeated course/date footer and page numbers, plus one
/// image-only slide (text rasterized into a bitmap) that only OCR can read.
enum CompilerDeckFixture {
    struct Slide {
        var title: String
        var bullets: [String]
        var imageOnly = false
    }

    static let footer = "CS 421 · Programming Languages & Compilers · Fall 2026"
    static let ocrPageNumber = 8

    static let slides: [Slide] = [
        Slide(title: "Top-Down Parsing and LL(1) Grammars", bullets: ["Lecture 9", "Predictive parsers without backtracking"]),
        Slide(title: "Recursive Descent Parsing", bullets: [
            "One procedure per nonterminal",
            "Procedures call each other to mirror the grammar",
            "Backtracking is expensive when a choice is wrong",
        ]),
        Slide(title: "Predictive Parsing and LL(1)", bullets: [
            "LL(1): scan Left to right, Leftmost derivation, 1 token of lookahead",
            "The next input token decides which production to apply",
            "A grammar is LL(1) if its parse table has no conflicts",
        ]),
        Slide(title: "FIRST Sets", bullets: [
            "FIRST(X) is the set of terminals that can begin strings derived from X",
            "If X is a terminal then FIRST(X) = { X }",
            "If X -> ε is a production then add ε to FIRST(X)",
            "For X -> Y1 Y2 ... add FIRST(Y1) minus ε to FIRST(X)",
        ]),
        Slide(title: "Computing FIRST: Worked Example", bullets: [
            "Grammar: E -> T E', E' -> + T E' | ε, T -> F T'",
            "FIRST(F) = { (, id } so FIRST(T) = { (, id } and FIRST(E) = { (, id }",
            "FIRST(E') = { +, ε } because E' can derive the empty string",
        ]),
        Slide(title: "FOLLOW Sets", bullets: [
            "FOLLOW(A) is the set of terminals that can appear immediately after A",
            "Put $, the end marker, in FOLLOW of the start symbol",
            "For B -> α A β add FIRST(β) minus ε to FOLLOW(A)",
            "If β can derive ε add FOLLOW(B) to FOLLOW(A)",
        ]),
        Slide(title: "Constructing the LL(1) Parse Table", bullets: [
            "For each production A -> α and each terminal a in FIRST(α), set M[A, a] = A -> α",
            "If ε is in FIRST(α), set M[A, b] = A -> α for every b in FOLLOW(A)",
            "Any cell with two entries is a conflict, so the grammar is not LL(1)",
        ]),
        Slide(title: "Eliminating Left Recursion", bullets: [
            "Left recursive rule: A -> A a | b",
            "Rewrite as A -> b A' and A' -> a A' | epsilon",
            "Top-down parsers loop forever on left recursion",
        ], imageOnly: true),
        Slide(title: "Left Factoring", bullets: [
            "Two productions share a common prefix: A -> a b | a c",
            "Factor the prefix out: A -> a A' and A' -> b | c",
            "Left factoring removes FIRST/FIRST conflicts",
        ]),
        Slide(title: "Summary and Next Time", bullets: [
            "LL(1) parsers use FIRST and FOLLOW sets to fill the parse table",
            "Remove left recursion and left factor before building the table",
            "Next lecture: bottom-up LR parsing and shift-reduce conflicts",
        ]),
    ]

    /// Writes the PDF to `url`. Set `password` for an encrypted copy; set `title` for metadata.
    static func write(to url: URL, title: String? = "Lecture 9: Top-Down Parsing", password: String? = nil) throws {
        var info: [CFString: Any] = [:]
        if let title { info[kCGPDFContextTitle] = title }
        if let password {
            info[kCGPDFContextUserPassword] = password
            info[kCGPDFContextOwnerPassword] = password + "-owner"
        }
        var box = CGRect(x: 0, y: 0, width: 960, height: 540)
        guard let context = CGContext(url as CFURL, mediaBox: &box, info as CFDictionary) else {
            throw FixtureError.cannotCreatePDF
        }
        for (index, slide) in slides.enumerated() {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(box)
            context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            if slide.imageOnly {
                guard let bitmap = rasterize(slide, size: CGSize(width: 1920, height: 1080)) else { throw FixtureError.cannotRasterize }
                context.draw(bitmap, in: box)
            } else {
                draw(slide.title, in: context, at: CGPoint(x: 48, y: 460), fontSize: 40, bold: true)
                for (line, bullet) in slide.bullets.enumerated() {
                    draw("•  " + bullet, in: context, at: CGPoint(x: 64, y: 380 - CGFloat(line) * 52), fontSize: 22, bold: false)
                }
            }
            draw(footer, in: context, at: CGPoint(x: 48, y: 24), fontSize: 12, bold: false)
            draw("\(index + 1)", in: context, at: CGPoint(x: 900, y: 24), fontSize: 12, bold: false)
            context.endPDFPage()
        }
        context.closePDF()
    }

    private static func draw(_ text: String, in context: CGContext, at point: CGPoint, fontSize: CGFloat, bold: Bool) {
        let font = CTFontCreateWithName((bold ? "Helvetica-Bold" : "Helvetica") as CFString, fontSize, nil)
        let attributed = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ])
        context.textPosition = point
        CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
    }

    /// Draws the slide's text into a bitmap so the resulting PDF page has no text layer.
    private static func rasterize(_ slide: Slide, size: CGSize) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let bitmap = CGContext(
                  data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                  bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        bitmap.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        bitmap.fill(CGRect(origin: .zero, size: size))
        bitmap.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        draw(slide.title, in: bitmap, at: CGPoint(x: 96, y: 920), fontSize: 84, bold: true)
        for (line, bullet) in slide.bullets.enumerated() {
            draw(bullet, in: bitmap, at: CGPoint(x: 128, y: 740 - CGFloat(line) * 110), fontSize: 48, bold: false)
        }
        return bitmap.makeImage()
    }

    enum FixtureError: Error { case cannotCreatePDF, cannotRasterize }
}
