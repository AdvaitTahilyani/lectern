import Foundation

/// One citation inside a bracketed marker such as "[S13, T1:00:14]" or "[L9 S12, L9 T14:32]".
public struct MarkerToken: Sendable, Hashable {
    /// The course lecture ordinal ("L9"), when the token names one. A token without its own "L#"
    /// inherits the previous token's lecture ("[L3 S4, S5]").
    public var lecture: Int?
    public var citation: Citation
    /// The token as written ("S13", "L9 T14:32"), trimmed.
    public var raw: String

    public init(lecture: Int?, citation: Citation, raw: String) {
        self.lecture = lecture
        self.citation = citation
        self.raw = raw
    }
}

/// A run of answer text: plain Markdown, or one bracketed marker made only of valid citation tokens.
public enum InlineSegment: Sendable, Hashable {
    case text(String)
    case citations(raw: String, tokens: [MarkerToken])
}

/// One block of a model answer, after light Markdown parsing.
public enum AnswerBlock: Sendable, Hashable {
    case heading(level: Int, text: String)
    case paragraph(String)
    /// A list row. `level` is the nesting depth (0 = top); `number` is nil for a bullet.
    case item(level: Int, number: Int?, text: String)
    case code(String)
}

/// Pure parsing of model answers: block structure (headings, bullet and numbered lists with nesting,
/// paragraphs, code fences) and the citation markers inside a line. Rendering lives in the app, so the
/// grammar is testable without UI. Nothing here can trap on malformed input.
public enum AnswerMarkup {
    // MARK: Blocks

    public static func blocks(_ text: String) -> [AnswerBlock] {
        var blocks: [AnswerBlock] = []
        var paragraph: [String] = []
        var fence: [String]?
        /// Indent widths of the open list levels, outermost first.
        var indents: [Int] = []
        var lastWasItem = false

        func flushParagraph() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))) }
            paragraph = []
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine).replacingOccurrences(of: "\t", with: "    ").replacingOccurrences(of: "\r", with: "")
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if fence != nil {
                if trimmed.hasPrefix("```") {
                    blocks.append(.code((fence ?? []).joined(separator: "\n")))
                    fence = nil
                } else {
                    fence?.append(line)
                }
                continue
            }
            if trimmed.hasPrefix("```") {
                flushParagraph()
                fence = []
                lastWasItem = false
                continue
            }
            if trimmed.isEmpty {
                flushParagraph()
                lastWasItem = false
                // A blank line does not end a list: models separate loose items with one.
                continue
            }
            if let heading = heading(trimmed) {
                flushParagraph()
                indents = []
                lastWasItem = false
                blocks.append(heading)
                continue
            }
            if isRule(trimmed) {
                flushParagraph()
                lastWasItem = false
                continue
            }
            if let item = listItem(line) {
                flushParagraph()
                while let last = indents.last, last > item.indent { indents.removeLast() }
                if indents.last.map({ item.indent > $0 }) ?? true { indents.append(item.indent) }
                blocks.append(.item(level: indents.count - 1, number: item.number, text: item.text))
                lastWasItem = true
                continue
            }
            // An indented line right after an item continues that item.
            if lastWasItem, line.hasPrefix(" "), case .item(let level, let number, let existing)? = blocks.last {
                blocks[blocks.count - 1] = .item(level: level, number: number, text: existing.isEmpty ? trimmed : existing + " " + trimmed)
                continue
            }
            indents = []
            lastWasItem = false
            paragraph.append(trimmed)
        }
        if let open = fence { blocks.append(.code(open.joined(separator: "\n"))) }
        flushParagraph()
        return blocks
    }

    private static func heading(_ line: String) -> AnswerBlock? {
        guard line.hasPrefix("#") else { return nil }
        let hashes = line.prefix { $0 == "#" }
        guard (1...6).contains(hashes.count) else { return nil }
        let rest = line.dropFirst(hashes.count)
        guard rest.first == " " else { return nil }
        return .heading(level: hashes.count, text: rest.trimmingCharacters(in: .whitespaces))
    }

    private static func isRule(_ line: String) -> Bool {
        guard line.count >= 3, let first = line.first, "-*_".contains(first) else { return false }
        return line.allSatisfy { $0 == first || $0 == " " } && line.filter({ $0 == first }).count >= 3
    }

    /// "*   item", "- item", "+ item", "1. item", "2) item", with any indentation.
    private static func listItem(_ line: String) -> (indent: Int, number: Int?, text: String)? {
        let indent = line.prefix { $0 == " " }.count
        let rest = line.dropFirst(indent)
        guard let first = rest.first else { return nil }
        if "*-+".contains(first) {
            let after = rest.dropFirst()
            guard after.isEmpty || after.first == " " else { return nil }
            return (indent, nil, after.trimmingCharacters(in: .whitespaces))
        }
        let digits = rest.prefix { $0.isASCII && $0.isNumber }
        guard (1...9).contains(digits.count), let n = Int(digits) else { return nil }
        let after = rest.dropFirst(digits.count)
        guard let mark = after.first, mark == "." || mark == ")" else { return nil }
        let body = after.dropFirst()
        guard body.isEmpty || body.first == " " else { return nil }
        return (indent, n, body.trimmingCharacters(in: .whitespaces))
    }

    // MARK: Inline citation markers

    /// Splits a line of answer text into Markdown runs and citation markers. A bracket is a marker only when
    /// every comma- or semicolon-separated token in it is a well-formed citation, so "[S13, T1:00:14]",
    /// "[S3, S4]" and "[L9 S12, T14:32]" each become their own tokens while "[see above]" or "[S0]" stay text.
    public static func inline(_ text: String) -> [InlineSegment] {
        var segments: [InlineSegment] = []
        var cursor = text.startIndex
        let bracket = /\[([^\[\]]{1,80})\]/
        for match in text.matches(of: bracket) {
            guard let tokens = tokens(in: String(match.1)) else { continue }
            if match.range.lowerBound > cursor { segments.append(.text(String(text[cursor..<match.range.lowerBound]))) }
            segments.append(.citations(raw: String(text[match.range]), tokens: tokens))
            cursor = match.range.upperBound
        }
        if cursor < text.endIndex { segments.append(.text(String(text[cursor...]))) }
        return segments
    }

    /// The tokens of a bracket body, or nil unless all of them parse.
    static func tokens(in body: String) -> [MarkerToken]? {
        var result: [MarkerToken] = []
        var lecture: Int?
        for piece in body.split(whereSeparator: { $0 == "," || $0 == ";" }) {
            guard let token = token(String(piece), inheriting: lecture) else { return nil }
            lecture = token.lecture
            result.append(token)
        }
        return result.isEmpty ? nil : result
    }

    private static func token(_ piece: String, inheriting inherited: Int?) -> MarkerToken? {
        var rest = Substring(piece.trimmingCharacters(in: .whitespaces))
        let raw = String(rest)
        var lecture = inherited
        if let first = rest.first, first == "L" || first == "l" {
            let digits = rest.dropFirst().prefix { $0.isASCII && $0.isNumber }
            guard (1...4).contains(digits.count), let n = Int(digits) else { return nil }
            lecture = n
            rest = rest.dropFirst(1 + digits.count).drop { $0 == " " }
        }
        guard let kind = rest.first, let citation = CitationParser.citation(kind: kind, value: String(rest.dropFirst())) else { return nil }
        return MarkerToken(lecture: lecture, citation: citation, raw: raw)
    }

    // MARK: Plain text

    /// Words for assistive technology and copying: "Slide 12", "14:32", "Lecture 9 slide 12".
    public static func spoken(_ token: MarkerToken) -> String {
        let what: String
        switch token.citation {
        case .slide(let n): what = token.lecture == nil ? "Slide \(n)" : "slide \(n)"
        case .time(let t): what = TimeFormat.clock(t)
        }
        return token.lecture.map { "Lecture \($0) \(what)" } ?? what
    }

    /// The answer as plain text: list items as "• item" / "1. item", Markdown emphasis removed, and citation
    /// markers spelled out. One string, so a view can expose a single accessibility label.
    public static func plainText(_ text: String) -> String {
        blocks(text).map { block -> String in
            switch block {
            case .heading(_, let t), .paragraph(let t): plainInline(t)
            case .item(let level, let number, let t):
                String(repeating: "  ", count: level) + (number.map { "\($0). " } ?? "• ") + plainInline(t)
            case .code(let c): c
            }
        }.joined(separator: "\n")
    }

    /// One line of text with Markdown emphasis removed and citation markers spelled out.
    public static func plainInline(_ text: String) -> String {
        inline(text).map { segment -> String in
            switch segment {
            case .text(let t): stripEmphasis(t)
            case .citations(_, let tokens): " " + tokens.map(spoken).joined(separator: ", ")
            }
        }.joined().replacingOccurrences(of: "  ", with: " ").trimmingCharacters(in: .whitespaces)
    }

    private static func stripEmphasis(_ text: String) -> String {
        guard let parsed = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else {
            return text.replacingOccurrences(of: "*", with: "")
        }
        return String(parsed.characters)
    }
}
