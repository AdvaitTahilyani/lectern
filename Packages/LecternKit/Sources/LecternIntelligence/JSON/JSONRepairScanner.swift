import Foundation

/// Rewrites a loosely JSON-shaped run of text, starting at a `{`, into strict JSON.
///
/// Repairs, in one pass:
/// - smart (“ ” „) and single (' ‘ ’) quotes used as string delimiters → `"`
/// - unescaped `"` inside a string (a quote only closes a string when the next non-space character
///   is `,` `}` `]` `:` or the end of input)
/// - raw newlines / tabs / control characters inside strings → escapes
/// - invalid escapes such as `\alpha` → a literal backslash
/// - trailing commas before `}` / `]`, and mismatched closers
/// - Python / bare literals (`True`, `None`) and unquoted keys or values (`action: new_topic`)
/// - `//` line comments
/// - truncated output: open strings, a dangling `"key":`, and open containers are closed
enum JSONRepairScanner {
    private enum Delimiter { case straight, smart, single }

    /// Repaired text of the object starting at `start` (which must be `{`), or nil if the scan
    /// never produced a closed top-level object. The result may still be invalid JSON; callers
    /// validate it.
    static func repairObject(_ s: [Unicode.Scalar], from start: Int) -> String? {
        var out = String.UnicodeScalarView()
        var stack: [Unicode.Scalar] = []
        var i = start
        var string: Delimiter?

        func emit(_ text: String) { out.append(contentsOf: text.unicodeScalars) }

        func nextNonSpace(after index: Int) -> Int? {
            var j = index + 1
            while j < s.count, s[j].properties.isWhitespace { j += 1 }
            return j < s.count ? j : nil
        }

        /// A quote ends the string only if what follows is JSON structure: `}` `]` `:`, or a comma
        /// followed by the start of a value or key (so `"naive", unoptimized IR` stays one string).
        func closesString(at index: Int) -> Bool {
            guard let j = nextNonSpace(after: index) else { return true }
            if ["}", "]", ":"].contains(s[j]) { return true }
            guard s[j] == "," else { return false }
            guard let k = nextNonSpace(after: j) else { return true }
            let c = s[k]
            if "\"'\u{201C}\u{201D}\u{2018}\u{2019}{[-".unicodeScalars.contains(c) || ("0"..."9").contains(c) { return true }
            guard isBareWordScalar(c) else { return false }
            var end = k
            var word = ""
            while end < s.count, isBareWordScalar(s[end]) { word.unicodeScalars.append(s[end]); end += 1 }
            if ["true", "false", "null", "none"].contains(word.lowercased()) { return true }
            guard let after = end < s.count ? (s[end].properties.isWhitespace ? nextNonSpace(after: end) : end) : nil else { return false }
            return s[after] == ":"
        }

        func dropTrailingComma() {
            while let last = out.last, last.properties.isWhitespace { out.removeLast() }
            if out.last == "," { out.removeLast() }
        }

        while i < s.count {
            let c = s[i]
            if let delimiter = string {
                if c == "\\" {
                    let next: Unicode.Scalar? = i + 1 < s.count ? s[i + 1] : nil
                    if let next, next == "'" {
                        emit("'")
                    } else if let next, "bfnrt".unicodeScalars.contains(next), PlainMath.commandNames.contains(word(in: s, from: i + 1)) {
                        // "\text", "\to", "\beta": LaTeX, not a JSON escape.
                        emit("\\\\"); out.append(next)
                    } else if let next, "\"\\/bfnrtu".unicodeScalars.contains(next) {
                        emit("\\"); out.append(next)
                    } else {
                        emit("\\\\")
                        if let next { appendStringContent(next, into: &out) }
                    }
                    i += 2
                    continue
                }
                if isClosingQuote(c, for: delimiter), closesString(at: i) {
                    emit("\"")
                    string = nil
                } else if c == "\"" {
                    emit("\\\"")
                } else {
                    appendStringContent(c, into: &out)
                }
                i += 1
                continue
            }

            switch c {
            case "\"":
                string = .straight; emit("\"")
            case "\u{201C}", "\u{201D}", "\u{201E}":
                string = .smart; emit("\"")
            case "'", "\u{2018}", "\u{2019}":
                string = .single; emit("\"")
            case "{", "[":
                stack.append(c); out.append(c)
            case "}", "]":
                dropTrailingComma()
                // Close any containers left open inside this one (e.g. `[1, 2}`).
                let opener: Unicode.Scalar = c == "}" ? "{" : "["
                guard stack.contains(opener) else { break }
                while let top = stack.popLast() {
                    out.append(top == "{" ? "}" : "]")
                    if top == opener { break }
                }
                if stack.isEmpty { return String(out) }
            case ",", ":":
                out.append(c)
            case "/" where i + 1 < s.count && s[i + 1] == "/":
                while i < s.count, s[i] != "\n", s[i] != "\r" { i += 1 }
                continue
            default:
                if c.properties.isWhitespace {
                    out.append(c)
                } else if isBareWordScalar(c) {
                    var j = i
                    var word = ""
                    while j < s.count, isBareWordScalar(s[j]) { word.unicodeScalars.append(s[j]); j += 1 }
                    emit(bareWordJSON(word))
                    i = j
                    continue
                }
                // Anything else outside a string (stray prose, bullets) is dropped.
            }
            i += 1
        }

        // Truncated output: close whatever is still open.
        if string != nil { emit("\"") }
        dropTrailingComma()
        if out.last == ":" { emit("null") }
        while let top = stack.popLast() { out.append(top == "{" ? "}" : "]") }
        return out.isEmpty ? nil : String(out)
    }

    /// The run of ASCII letters starting at `index`.
    private static func word(in s: [Unicode.Scalar], from index: Int) -> String {
        var j = index
        var w = String.UnicodeScalarView()
        while j < s.count, s[j].isASCII, s[j].properties.isAlphabetic { w.append(s[j]); j += 1 }
        return String(w)
    }

    private static func isClosingQuote(_ c: Unicode.Scalar, for delimiter: Delimiter) -> Bool {
        switch delimiter {
        case .straight: c == "\""
        case .smart: c == "\u{201C}" || c == "\u{201D}" || c == "\""
        case .single: c == "'" || c == "\u{2019}" || c == "\u{2018}"
        }
    }

    private static func appendStringContent(_ c: Unicode.Scalar, into out: inout String.UnicodeScalarView) {
        switch c {
        case "\n": out.append(contentsOf: "\\n".unicodeScalars)
        case "\r": break
        case "\t": out.append(contentsOf: "\\t".unicodeScalars)
        case "\"": out.append(contentsOf: "\\\"".unicodeScalars)
        default:
            if c.value < 0x20 {
                out.append(contentsOf: String(format: "\\u%04X", c.value).unicodeScalars)
            } else {
                out.append(c)
            }
        }
    }

    private static func isBareWordScalar(_ c: Unicode.Scalar) -> Bool {
        CharacterSet.alphanumerics.contains(c) || c == "_" || c == "-" || c == "." || c == "+"
    }

    /// JSON for an unquoted token: numbers and literals pass through, anything else is quoted.
    private static func bareWordJSON(_ word: String) -> String {
        switch word.lowercased() {
        case "true": return "true"
        case "false": return "false"
        case "null", "none", "nil", "undefined": return "null"
        default:
            if let first = word.first, first.isNumber || first == "-", Double(word) != nil { return word }
            return "\"\(word)\""
        }
    }
}
