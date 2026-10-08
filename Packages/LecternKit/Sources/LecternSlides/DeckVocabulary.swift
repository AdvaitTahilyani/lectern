import Foundation
import LecternCore

/// One piece of course jargon found in a slide deck, with the ways it can be said.
public struct DeckTerm: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        /// camelCase or snake_case: `genExpr`, `new_reg_name`, `loadAO`.
        case identifier
        /// All capitals, vowel-less, or letters with a small number: `ILOC`, `LR`, `CFG`, `MP2`, `LL(1)`, `llvm`.
        case acronym
        /// A proper multi-word term from a slide title: "Hindley–Milner".
        case phrase
    }

    /// The deck's spelling; what a matching transcript span is replaced with.
    public var text: String
    public var kind: Kind
    /// How often the deck uses it (text, notes and titles).
    public var occurrences: Int
    /// Phonetic keys of its spoken forms (`SpokenKey`): `genExpr` → "genekspr", "genekspression".
    public var spokenKeys: Set<String>
    /// Most transcript words one spoken form can take ("I L O C" is four).
    public var maxWords: Int
    /// Lower-cased parts: ["gen", "expr"], ["iloc"], or a phrase's words ["hindley", "milner"].
    public var components: [String]
}

/// The jargon of one slide deck: identifiers, acronyms, Greek letters and proper title phrases,
/// each with its spoken forms. Built once per deck; `TranscriptCorrector` matches against it.
public struct DeckVocabulary: Sendable {
    public let terms: [DeckTerm]
    /// Greek letters the deck uses, by name, with the words that follow them there
    /// ("phi" → ["function", "node"]), so "fee function" can become "phi function".
    public let greekCollocations: [String: Set<String>]

    public var isEmpty: Bool { terms.isEmpty && greekCollocations.isEmpty }

    public init(deck: SlideDeck) {
        self.init(
            pageTexts: deck.pages.flatMap { [$0.text, $0.notes ?? ""] },
            titles: deck.pages.compactMap(\.title) + [deck.title].compactMap { $0 }
        )
    }

    public init(pageTexts: [String], titles: [String]) {
        var found: [String: (kind: DeckTerm.Kind, components: [String], count: Int)] = [:]
        for text in pageTexts + titles {
            for token in Self.identifierTokens(in: text) {
                guard let (kind, components) = Self.classify(token) else { continue }
                found[token, default: (kind, components, 0)].count += 1
            }
        }
        for title in titles {
            for (display, words) in Self.titlePhrases(in: title) where found[display] == nil {
                found[display] = (.phrase, words, 1)
            }
        }
        terms = found.map { text, entry in
            DeckTerm(
                text: text, kind: entry.kind, occurrences: entry.count,
                spokenKeys: Self.spokenKeys(entry.components),
                maxWords: min(6, entry.kind == .acronym ? entry.components.joined().count : entry.components.count),
                components: entry.components.map { $0.lowercased().filter { ($0.isLetter || $0.isNumber) && $0.isASCII } }
            )
        }
        .sorted { $0.text < $1.text }
        greekCollocations = Self.greekCollocations(in: pageTexts + titles)
    }

    // MARK: - Identifier tokens

    /// URLs and e-mail addresses are skipped: "cs426" in a course URL isn't jargon.
    nonisolated(unsafe) private static let urlPattern = /(?:https?:\/\/|www\.)\S+|\S+@\S+\.\S+/
    // Regex isn't Sendable, but these literals are immutable and matching doesn't mutate them.
    nonisolated(unsafe) private static let tokenPattern = /[A-Za-z_][A-Za-z0-9_]*(?:\([A-Za-z0-9]{1,3}\))?/

    /// Identifier-shaped tokens; a match glued to a preceding letter or digit ("xff" in "0xff")
    /// is not a token of its own. A short parenthesized group stays attached only in notation like
    /// `LL(1)`; after anything else it is a call's argument, and the name alone is the token
    /// (`genExpr(e)` → `genExpr`).
    static func identifierTokens(in text: String) -> [String] {
        let cleaned = text.replacing(urlPattern, with: " ")
        return cleaned.matches(of: tokenPattern).compactMap { match in
            let start = match.range.lowerBound
            if start > cleaned.startIndex {
                let before = cleaned[cleaned.index(before: start)]
                if before.isLetter || before.isNumber { return nil }
            }
            let token = String(match.output)
            if let open = token.firstIndex(of: "("), classify(token) == nil { return String(token[..<open]) }
            return token
        }
    }

    /// The kind and spoken components of a deck token, or nil when it's an ordinary word.
    static func classify(_ token: String) -> (DeckTerm.Kind, [String])? {
        // LL(1), LR(0), SLR(1): capitals followed by a short parenthesized number.
        if let open = token.firstIndex(of: "(") {
            let base = String(token[..<open])
            let inner = token[token.index(after: open)..<token.index(before: token.endIndex)]
            guard (1...4).contains(base.count), base.allSatisfy(\.isUppercase), inner.count <= 2, inner.allSatisfy(\.isNumber) else { return nil }
            return (.acronym, base.map { String($0) } + [String(inner)])
        }
        let core = token.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        let letters = core.filter(\.isLetter)
        guard letters.count >= 2 else { return nil }
        let digits = core.filter(\.isNumber)

        if core.contains("_") {
            let parts = core.split(separator: "_").flatMap { camelComponents(String($0)) }
            guard parts.count >= 2, parts.contains(where: { $0.count >= 2 }) else { return nil }
            return (.identifier, parts)
        }
        let parts = camelComponents(core)
        if parts.count >= 2, core.first?.isLetter == true, isCamelCase(core) {
            return (.identifier, parts)
        }
        // Capitals (optionally with a one- or two-digit number): ILOC, CFG, LR, MP2.
        if letters.allSatisfy(\.isUppercase), (2...6).contains(letters.count), digits.count <= 2 {
            let isRomanNumeral = core.allSatisfy { "IVX".contains($0) }
            guard !isRomanNumeral, !(digits.isEmpty && CommonWords.contains(core)) else { return nil }
            return (.acronym, parts)
        }
        // Lower-case vowel-less abbreviations: llvm, cfg, jmp.
        if digits.isEmpty, letters.allSatisfy(\.isLowercase), (3...6).contains(letters.count),
           !letters.contains(where: { "aeiouy".contains($0) }), !CommonWords.contains(core) {
            return (.acronym, [core])
        }
        return nil
    }

    /// True for a lower→upper transition inside the token ("genExpr", "loadAO", "RegisterHandle").
    private static func isCamelCase(_ s: String) -> Bool {
        zip(s, s.dropFirst()).contains { $0.isLowercase && $1.isUppercase }
    }

    /// Splits camelCase keeping capital runs whole: "loadAO" → ["load", "AO"], "XMLParser" →
    /// ["XML", "Parser"], "genExpr" → ["gen", "Expr"]; digits form their own component.
    static func camelComponents(_ s: String) -> [String] {
        let chars = Array(s)
        var parts: [String] = []
        var current = ""
        for (i, c) in chars.enumerated() {
            let prev = i > 0 ? chars[i - 1] : nil
            let next = i + 1 < chars.count ? chars[i + 1] : nil
            var boundary = false
            if let prev {
                if c.isNumber != prev.isNumber { boundary = true }
                else if c.isUppercase, prev.isLowercase { boundary = true }
                else if c.isUppercase, prev.isUppercase, next?.isLowercase == true { boundary = true }
            }
            if boundary, !current.isEmpty { parts.append(current); current = "" }
            current.append(c)
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }

    // MARK: - Spoken forms

    /// Abbreviations lecturers expand when reading code aloud ("genExpr" → "gen expression").
    static let expansions: [String: [String]] = [
        "expr": ["expression"], "reg": ["register"], "idx": ["index"], "num": ["number"],
        "val": ["value"], "str": ["string"], "cond": ["condition"], "br": ["branch"],
        "ptr": ["pointer"], "addr": ["address"], "init": ["initialize"], "alloc": ["allocate"],
        "decl": ["declaration"], "stmt": ["statement"], "var": ["variable"], "func": ["function"],
        "fn": ["function"], "arg": ["argument"], "args": ["arguments"], "param": ["parameter"],
        "tmp": ["temp", "temporary"], "temp": ["temporary"], "len": ["length"], "def": ["define"],
        "ref": ["reference"], "op": ["operation"], "eval": ["evaluate"], "calc": ["calculate"],
    ]

    /// Every combination of each component's spoken alternatives, as phonetic keys.
    static func spokenKeys(_ components: [String]) -> Set<String> {
        var forms = [""]
        for component in components {
            let lower = component.lowercased()
            let alternatives = [lower] + (expansions[lower] ?? [])
            forms = forms.flatMap { prefix in alternatives.map { prefix + $0 } }
            if forms.count > 32 { break }
        }
        return Set(forms.map(SpokenKey.phonetic))
    }

    // MARK: - Title phrases

    /// Proper multi-word terms in a title: hyphenated compounds ("Hindley–Milner") and pairs of
    /// capitalized words where one isn't an everyday word ("Hindley Milner").
    static func titlePhrases(in title: String) -> [(display: String, words: [String])] {
        let words = title.split(whereSeparator: \.isWhitespace).map { $0.trimmingCharacters(in: .punctuationCharacters.subtracting(CharacterSet(charactersIn: "-–"))) }
        var result: [(String, [String])] = []
        func isProper(_ w: String) -> Bool { w.count >= 4 && w.allSatisfy(\.isLetter) && !CommonWords.contains(w) }
        for word in words {
            let parts = word.split(whereSeparator: { $0 == "-" || $0 == "–" }).map(String.init)
            if parts.count >= 2, parts.allSatisfy({ $0.allSatisfy(\.isLetter) && !$0.isEmpty }), parts.contains(where: isProper) {
                result.append((word, parts))
            }
        }
        for (a, b) in zip(words, words.dropFirst()) {
            guard a.first?.isUppercase == true, b.first?.isUppercase == true,
                  a.allSatisfy(\.isLetter), b.allSatisfy(\.isLetter),
                  !a.allSatisfy(\.isUppercase), !b.allSatisfy(\.isUppercase),
                  isProper(a) || isProper(b) else { continue }
            result.append(("\(a) \(b)", [a, b]))
        }
        return result
    }

    // MARK: - Greek letters

    static let greekNames: [Character: String] = [
        "α": "alpha", "β": "beta", "γ": "gamma", "δ": "delta", "ε": "epsilon", "ϵ": "epsilon",
        "θ": "theta", "κ": "kappa", "λ": "lambda", "μ": "mu", "π": "pi", "ρ": "rho", "σ": "sigma",
        "τ": "tau", "φ": "phi", "ϕ": "phi", "χ": "chi", "ψ": "psi", "ω": "omega",
    ]

    /// What a recognizer writes when it hears a Greek letter's name.
    static let greekHomophones: [String: Set<String>] = [
        "phi": ["fee", "fie", "fi", "fy", "phee", "fai"], "psi": ["sigh", "sai"], "chi": ["kai", "kye"],
        "pi": ["pie", "pye"], "mu": ["mew", "moo"], "tau": ["tao", "taw"], "rho": ["roe", "row"],
        "epsilon": ["upsilon"], "lambda": ["lamda", "lambada"], "theta": ["thayta"], "beta": ["bayta"],
    ]

    /// Words following each Greek letter (symbol or spelled-out name) anywhere in the deck.
    static func greekCollocations(in texts: [String]) -> [String: Set<String>] {
        var result: [String: Set<String>] = [:]
        let names = Set(greekHomophones.keys)
        for text in texts {
            let chars = Array(text)
            var i = 0
            while i < chars.count {
                var name: String?
                var end = i + 1
                if let n = greekNames[chars[i]] {
                    name = n
                } else if chars[i].isLetter, i == 0 || !chars[i - 1].isLetter {
                    var j = i
                    while j < chars.count, chars[j].isLetter { j += 1 }
                    let word = String(chars[i..<j]).lowercased()
                    if names.contains(word) { name = word }
                    end = j
                }
                if let name, greekHomophones[name] != nil {
                    var j = end
                    while j < chars.count, chars[j] == "-" || chars[j] == "–" || chars[j] == " " { j += 1 }
                    var k = j
                    while k < chars.count, chars[k].isLetter { k += 1 }
                    if k - j >= 3 {
                        result[name, default: []].insert(SpokenKey.singular(String(chars[j..<k]).lowercased()))
                    }
                }
                i = max(end, i + 1)
            }
        }
        return result
    }
}

/// Normalization shared by deck terms and transcript spans, so "I lock" and "ILOC" (or
/// "gen expression" and `genExpr`) produce the same key.
enum SpokenKey {
    private static let digitWords = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine"]

    /// Lower-cased letters and digit words with common spelling-for-sound substitutions
    /// (ph→f, ck/c/q→k, x→ks, z→s).
    static func phonetic(_ s: String) -> String {
        var out = ""
        for c in s.lowercased() {
            if let d = c.wholeNumberValue, c.isASCII { out += digitWords[d] }
            else if c.isLetter, c.isASCII { out.append(c) }
        }
        out = out.replacingOccurrences(of: "ph", with: "f")
            .replacingOccurrences(of: "ck", with: "k")
            .replacingOccurrences(of: "c", with: "k")
            .replacingOccurrences(of: "q", with: "k")
            .replacingOccurrences(of: "x", with: "ks")
            .replacingOccurrences(of: "z", with: "s")
        return out
    }

    /// "functions" → "function", "nodes" → "node" (for collocations only).
    static func singular(_ w: String) -> String {
        if w.hasSuffix("ies"), w.count > 4 { return String(w.dropLast(3)) + "y" }
        if w.hasSuffix("s"), !w.hasSuffix("ss"), w.count > 3 { return String(w.dropLast()) }
        return w
    }
}
