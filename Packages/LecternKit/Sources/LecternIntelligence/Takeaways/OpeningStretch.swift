import Foundation
import LecternCore

/// Guards the start of a lecture, where small and large models alike tend to file a recap or a
/// correction of last lecture as "admin" and silently drop minutes of content.
///
/// While no card exists yet, the lines the model skipped stay in the prompt window. Once that
/// stretch is long, the prompt says so explicitly (`nudge`), and if the model still declines
/// while the stretch is clearly technical, the brain writes a "Recap" card for it anyway.
struct OpeningStretch: Sendable {
    /// After this much skipped speech the prompt asks the model to open a topic.
    static let nudgeSeconds: TimeInterval = 150
    static let nudgeWords = 300
    /// Backstop: a skipped stretch this long that is mostly technical becomes a Recap card.
    static let backstopSeconds: TimeInterval = 240
    /// Share of content words that are technical (deck vocabulary or common CS terms).
    static let minTechnicalShare = 0.3

    private let deckTerms: Set<String>

    init(deck: SlideDeck?) {
        // Decks carry housekeeping slides ("MP2 released…"): their words are not technical.
        deckTerms = Set((deck?.pages ?? []).flatMap { TranscriptRetriever.terms(($0.title ?? "") + " " + $0.text) })
            .subtracting(Self.logistics)
    }

    /// Whether the prompt should push the model to open a topic for `segments`.
    static func needsNudge(_ segments: ArraySlice<TranscriptSegment>) -> Bool {
        guard let first = segments.first, let last = segments.last else { return false }
        return last.end - first.start >= nudgeSeconds || TranscriptText.wordCount(segments) >= nudgeWords
    }

    /// Whether `segments` (skipped as admin) are long and technical enough to deserve a card.
    func deservesRecap(_ segments: ArraySlice<TranscriptSegment>) -> Bool {
        guard let first = segments.first, let last = segments.last, last.end - first.start >= Self.backstopSeconds else { return false }
        return technicalShare(segments) >= Self.minTechnicalShare
    }

    /// Fraction of the stretch's content words that are technical.
    func technicalShare(_ segments: ArraySlice<TranscriptSegment>) -> Double {
        let terms = segments.flatMap { TranscriptRetriever.terms($0.text) }
        guard !terms.isEmpty else { return 0 }
        return Double(terms.filter { deckTerms.contains($0) || Self.lexicon.contains($0) }.count) / Double(terms.count)
    }

    /// Course-logistics words, never counted as technical even when a slide contains them.
    static let logistics: Set<String> = Set([
        "announcement", "assignment", "career", "class", "conflict", "course", "deadline", "due", "email", "exam",
        "fair", "final", "friday", "grade", "homework", "hour", "hw", "lab", "midnight", "midterm", "monday", "mp",
        "mp1", "mp2", "mp3", "office", "piazza", "post", "quiz", "release", "room", "saturday", "section", "semester",
        "slide", "slides", "submit", "sunday", "survey", "ta", "thursday", "today", "tomorrow", "tuesday", "wednesday",
        "website", "week", "welcome",
    ].flatMap(TranscriptRetriever.terms))

    /// Common computer-science vocabulary, stemmed like transcript terms. Deliberately excludes
    /// words that are just as common in logistics ("time", "question", "due", "exam", "grade").
    static let lexicon: Set<String> = Set([
        "algorithm", "address", "allocation", "array", "assembly", "ast", "backend", "binary", "bit",
        "block", "boolean", "branch", "buffer", "byte", "cache", "call", "cast", "cfg", "child", "closure", "code",
        "compile", "compiler", "complexity", "concurrency", "condition", "constant", "constraint", "control", "converge",
        "cycle", "data", "declaration", "definition", "derivation", "dfa", "dominance", "dominate", "dominator", "edge",
        "element", "evaluate", "expression", "field", "flow", "float", "frontier", "function", "grammar", "graph", "hash",
        "heap", "hierarchy", "identifier", "inference", "instruction", "integer", "interface", "intermediate", "ir",
        "iteration", "jump", "kernel", "label", "lambda", "language", "latency", "lexer", "linear", "linked", "list",
        "literal", "liveness", "load", "lock", "loop", "matrix", "memory", "merge", "method", "module", "network",
        "nfa", "node", "nonterminal", "object", "offset", "operand", "operator", "optimization", "optimize", "parse",
        "parser", "path", "phi", "pipeline", "pointer", "polymorphism", "precedence", "predecessor", "procedure",
        "process", "production", "program", "proof", "protocol", "queue", "recursion", "recursive", "reduce", "reference",
        "register", "regular", "return", "root", "runtime", "scope", "semantics", "sequence", "set", "shift", "ssa",
        "stack", "statement", "store", "string", "struct", "subtree", "successor", "symbol", "syntax", "table",
        "terminal", "thread", "token", "traversal", "tree", "tuple", "type", "undefined", "value", "variable", "vector", "verified",
        "verify", "vertex", "virtual",
    ].flatMap(TranscriptRetriever.terms))
}
