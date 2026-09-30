import Foundation
import LecternCore

/// A scripted lecture used by the demo transcription engine and demo brain. The script is a list
/// of *beats*: each beat is spoken as several sentences, belongs to a slide, and yields one
/// takeaway whose title/summary are refined while the beat is in progress.
nonisolated struct DemoScript: Sendable {
    struct Beat: Sendable {
        var slide: Int
        var sentences: [String]
        /// Successive (title, summary) refinements shown in the Now card as the beat progresses.
        var refinements: [(title: String, summary: String)]
        /// Final settled takeaway.
        var title: String
        var summary: String
        var detail: TakeawayDetail
        var slidePages: [Int]
        /// Quiz question offered after this beat settles (if any), plus a follow-up on the same concept.
        var quiz: (question: QuizQuestion, followUp: QuizQuestion)?
    }

    struct Slide: Sendable {
        var title: String
        var bullets: [String]
    }

    var title: String
    var courseCode: String
    var courseName: String
    var slides: [Slide]
    var beats: [Beat]
    var summary: String
    var keyTerms: [KeyTerm]

    /// Prefix marking an audience (student) line in `Beat.sentences`.
    static let audienceMarker = "» "

    /// Sentences in speaking order with their beat index and speaker.
    var sentences: [(beat: Int, text: String, speaker: SpeakerRole)] {
        beats.enumerated().flatMap { i, b in
            b.sentences.map { line -> (Int, String, SpeakerRole) in
                if line.hasPrefix(Self.audienceMarker) { return (i, String(line.dropFirst(Self.audienceMarker.count)), .audience(index: 1)) }
                return (i, line, .lecturer)
            }
        }
    }

    /// Catch-up recap for a time window, built from the beats spoken in it (`sentenceTimes` maps
    /// the beat index to the session time its first sentence was finalized).
    func recap(from: TimeInterval, to: TimeInterval, beatTimes: [Int: TimeInterval]) -> Recap {
        let covered = beats.indices.filter { i in
            guard let t = beatTimes[i] else { return false }
            return t >= from - 20 && t <= to
        }
        let picked = covered.isEmpty ? [max(0, min(beats.count - 1, beatTimes.filter { $0.value <= to }.keys.max() ?? 0))] : covered
        let titles = picked.map { beats[$0].title }
        let headline = titles.count == 1 ? titles[0] : "\(titles.first!) → \(titles.last!.lowercasedFirstLetter)"
        let bullets = Array(picked.map { beats[$0].summary }.prefix(4))
        return Recap(from: from, to: to, headline: headline, bullets: bullets, flagged: flagged(inBeats: picked), slides: picked.flatMap { beats[$0].slidePages })
    }

    /// What the lecturer flagged (exam hints, deadlines, reading) in the given beats.
    func flagged(inBeats indices: [Int]) -> [String] {
        var flagged: [String] = []
        for i in indices {
            for line in beats[i].sentences where line.lowercased().contains("midterm") || line.lowercased().contains("exam") || line.lowercased().contains("due") {
                flagged.append(line.contains("midterm") ? "The LL(1) condition will be on the midterm" : line)
            }
            if beats[i].sentences.contains(where: { $0.contains("Dragon Book") }) { flagged.append("Reading: Dragon Book §4.4–4.5 before next lecture") }
        }
        return flagged
    }

    /// The Review summary for the whole scripted lecture; `quiz` supplies the missed concepts.
    func lectureSummary(quiz: [QuizRecord]) -> LectureSummary {
        var review: [String] = []
        for record in quiz where record.outcome == .incorrect && !review.contains(where: { $0.hasPrefix(record.question.concept) }) {
            let beat = beats.first { $0.quiz?.question.concept == record.question.concept || $0.quiz?.followUp.concept == record.question.concept }
            let why = beat.map { $0.summary.split(separator: ";").first.map(String.init) ?? $0.summary } ?? "revisit the definition and the worked example"
            review.append("\(record.question.concept) — \(why.trimmingCharacters(in: CharacterSet(charactersIn: ". ")))." )
        }
        return LectureSummary(overview: summary, keyConcepts: keyTerms, reviewThese: review,
                              flagged: flagged(inBeats: Array(beats.indices)), slides: [7, 9, 11, 12])
    }

    static let compilers = DemoScript(
        title: "Parsing II: LL(1) & Predictive Parsing",
        courseCode: "CS 421",
        courseName: "Programming Languages & Compilers",
        slides: [
            Slide(title: "Parsing II: Predictive Parsing", bullets: ["CS 421 · Lecture 8", "Top-down parsing, FIRST/FOLLOW, LL(1) tables"]),
            Slide(title: "Where we are", bullets: ["Lexer: characters → tokens ✓", "Parser: tokens → syntax tree ← today", "Grammar G = (N, Σ, P, S)"]),
            Slide(title: "Top-down parsing", bullets: ["Start at S, expand leftmost nonterminal", "Choose a production for each nonterminal", "Recursive descent: one function per nonterminal"]),
            Slide(title: "The choice problem", bullets: ["Which production of A do we pick?", "Look at the next input token (lookahead)", "k tokens of lookahead → LL(k)"]),
            Slide(title: "Left recursion", bullets: ["E → E + T | T", "Recursive descent loops forever on E", "Must eliminate before top-down parsing"]),
            Slide(title: "Eliminating left recursion", bullets: ["A → Aα | β  ⇒  A → βA′,  A′ → αA′ | ε", "E → T E′,  E′ → + T E′ | ε", "Same language, right-recursive"]),
            Slide(title: "FIRST sets", bullets: ["FIRST(α) = terminals that can begin a string derived from α", "If α ⇒* ε then ε ∈ FIRST(α)", "Computed by fixed-point iteration"]),
            Slide(title: "Computing FIRST", bullets: ["FIRST(a) = {a} for terminal a", "A → X1 X2 … Xn: add FIRST(X1); if ε ∈ FIRST(X1) continue with X2 …", "Repeat until nothing changes"]),
            Slide(title: "FOLLOW sets", bullets: ["FOLLOW(A) = terminals that can appear right after A", "$ ∈ FOLLOW(S) for the start symbol", "Needed when A can derive ε"]),
            Slide(title: "Computing FOLLOW", bullets: ["B → αAβ: add FIRST(β) − {ε} to FOLLOW(A)", "If ε ∈ FIRST(β) (or β empty): add FOLLOW(B) to FOLLOW(A)", "Iterate to a fixed point"]),
            Slide(title: "The LL(1) parse table", bullets: ["Rows: nonterminals · Columns: terminals + $", "For A → α: M[A, a] = α for each a ∈ FIRST(α)", "If ε ∈ FIRST(α): M[A, b] = α for each b ∈ FOLLOW(A)"]),
            Slide(title: "LL(1) condition", bullets: ["Grammar is LL(1) iff no table cell holds two productions", "Equivalently: for A → α | β, FIRST(α) ∩ FIRST(β) = ∅", "…and if ε ∈ FIRST(β): FIRST(α) ∩ FOLLOW(A) = ∅"]),
            Slide(title: "Table-driven parsing", bullets: ["Stack starts with S $", "Terminal on top: match & advance", "Nonterminal on top: replace with M[A, lookahead]"]),
            Slide(title: "Worked example: id + id * id", bullets: ["E → T E′, T → F T′, F → id", "Stack trace step by step", "Accept when stack and input are both $"]),
            Slide(title: "Left factoring", bullets: ["A → αβ1 | αβ2  ⇒  A → αA′,  A′ → β1 | β2", "Delays the decision until enough input is seen", "Needed for if/then/else"]),
            Slide(title: "Limits of LL(1)", bullets: ["Dangling else is inherently ambiguous", "Some languages are not LL(k) for any k", "Bottom-up (LR) parsers handle more"]),
            Slide(title: "Error recovery", bullets: ["Panic mode: skip to a synchronizing token", "Use FOLLOW(A) as the sync set for A", "Report once, keep parsing"]),
            Slide(title: "Next time", bullets: ["Bottom-up parsing: shift-reduce", "LR(0) items and SLR tables", "Reading: Dragon Book §4.4–4.5"]),
        ],
        beats: [
            Beat(
                slide: 2,
                sentences: [
                    "Okay, uh, let's get started. Before I begin, a small correction to last week's slides: on slide fourteen the identifier token should be id, not ident, so I'll post the corrected slides on the website tonight.",
                    "So last week we finished the lexer, right, so we can turn a stream of characters into a stream of tokens.",
                    "Today we start on the parser, which takes those tokens and builds a syntax tree according to a context-free grammar.",
                    "Remember a grammar has four parts: nonterminals, terminals, productions, and a start symbol. Any questions on that before I start today's lecture? Okay.",
                    "The specific technique we'll cover today is called predictive parsing, and by the end you'll be able to build an LL(1) parse table by hand.",
                ],
                refinements: [
                    ("Recap: lexer to parser", "The lexer produces tokens; the parser turns them into a syntax tree."),
                    ("From tokens to syntax trees", "The parser consumes the lexer's tokens and builds a syntax tree according to a context-free grammar."),
                ],
                title: "From tokens to syntax trees",
                summary: "The parser consumes the lexer's tokens and builds a syntax tree from a context-free grammar; today's goal is building an LL(1) parse table by hand.",
                detail: TakeawayDetail(
                    bullets: [
                        "A grammar G = (N, Σ, P, S): nonterminals, terminals, productions, start symbol.",
                        "Lexing and parsing are separate phases; the parser never sees raw characters.",
                        "Predictive parsing is the top-down technique covered in this lecture.",
                    ],
                    keyTerms: [
                        KeyTerm(term: "context-free grammar", definition: "A set of productions A → α where A is a single nonterminal and α is any string of terminals and nonterminals."),
                        KeyTerm(term: "predictive parsing", definition: "Top-down parsing that chooses each production from a bounded lookahead, without backtracking."),
                    ]
                ),
                slidePages: [1, 2],
                quiz: nil
            ),
            Beat(
                slide: 3,
                sentences: [
                    "Top-down parsing starts at the start symbol and repeatedly expands the leftmost nonterminal until the whole input is matched.",
                    "The simplest implementation is recursive descent: you write one function per nonterminal, and each function tries to match one of its productions.",
                    "The hard part is the choice. When a nonterminal has, like, several productions, which one do you expand? Anybody?",
                    "Predictive parsers answer that by peeking at the next input token, which we call the lookahead.",
                    "If one token of lookahead is always enough to decide, the grammar is LL(1): left to right scan, leftmost derivation, one token of lookahead. Is this clear? Okay.",
                ],
                refinements: [
                    ("Top-down parsing", "Start at the start symbol and expand the leftmost nonterminal."),
                    ("Recursive descent and the choice problem", "One function per nonterminal; the hard part is choosing which production to expand."),
                    ("Predictive parsing uses lookahead", "Choose the production by peeking at the next token; one token suffices for LL(1) grammars."),
                ],
                title: "Predictive parsing chooses productions by lookahead",
                summary: "Top-down parsers expand the leftmost nonterminal; recursive descent picks a production by peeking at the next token, and LL(1) means one token always suffices.",
                detail: TakeawayDetail(
                    bullets: [
                        "Recursive descent: one function per nonterminal, each matching one production.",
                        "LL(1) = Left-to-right scan, Leftmost derivation, 1 token of lookahead.",
                        "No backtracking: the lookahead must uniquely determine the production.",
                    ],
                    keyTerms: [
                        KeyTerm(term: "lookahead", definition: "The next unconsumed input token, used to choose a production without backtracking."),
                        KeyTerm(term: "recursive descent", definition: "A top-down parser written as mutually recursive functions, one per nonterminal."),
                    ]
                ),
                slidePages: [3, 4],
                quiz: (
                    QuizQuestion(
                        prompt: "In LL(1), what does the “1” stand for?",
                        kind: .multipleChoice(options: ["One token of lookahead", "One production per nonterminal", "One pass over the grammar", "One nonterminal on the stack"], correctIndex: 0),
                        concept: "LL(1) lookahead", sourceSlides: [4], sourceStart: 40, sourceEnd: 95
                    ),
                    QuizQuestion(
                        prompt: "Which derivation does an LL parser produce?",
                        kind: .multipleChoice(options: ["Leftmost", "Rightmost", "Either", "Bottom-up"], correctIndex: 0),
                        concept: "LL(1) lookahead", sourceSlides: [4], sourceStart: 40, sourceEnd: 95
                    )
                )
            ),
            Beat(
                slide: 5,
                sentences: [
                    "Before we can do any of this, we have to deal with left recursion.",
                    "Take E goes to E plus T, or T. So a recursive descent function for E would immediately call itself on E, without consuming any input, and it just loops forever, right.",
                    "So we rewrite. The general rule is: if A goes to A alpha or beta, replace it with A goes to beta A prime, and A prime goes to alpha A prime or epsilon.",
                    "For our expression grammar that gives E goes to T E prime, and E prime goes to, uh, plus T E prime, or epsilon. And wait, on the slide it says plus E prime, that should be plus T E prime, small mistake, I'll fix it.",
                    "Same language, but now every production consumes a token before recursing, so the parser terminates.",
                ],
                refinements: [
                    ("Left recursion", "A left-recursive production makes recursive descent loop forever."),
                    ("Eliminating left recursion", "Rewrite A → Aα | β as A → βA′, A′ → αA′ | ε so every production consumes input before recursing."),
                ],
                title: "Eliminate left recursion before parsing top-down",
                summary: "A → Aα | β loops forever in recursive descent; rewrite it as A → βA′, A′ → αA′ | ε, e.g. E → T E′, E′ → + T E′ | ε.",
                detail: TakeawayDetail(
                    bullets: [
                        "Left recursion: a nonterminal that derives a string starting with itself.",
                        "The rewrite preserves the language but produces right-recursive productions.",
                        "Indirect left recursion (A → Bx, B → Ay) must be handled by substitution first.",
                    ],
                    keyTerms: [
                        KeyTerm(term: "left recursion", definition: "A production A → Aα, which makes a top-down parser recurse without consuming input."),
                        KeyTerm(term: "epsilon production", definition: "A production whose right-hand side is the empty string, A → ε."),
                    ],
                    example: "E → E + T | T becomes E → T E′ and E′ → + T E′ | ε."
                ),
                slidePages: [5, 6],
                quiz: nil
            ),
            Beat(
                slide: 7,
                sentences: [
                    "Now the two sets that make prediction possible. FIRST of alpha is the set of terminals that can begin some string derived from alpha.",
                    "If alpha can derive the empty string, we also put epsilon into FIRST of alpha.",
                    "For a terminal, FIRST is just the terminal itself. For a production A goes to X one through X n, you add FIRST of X one, and if that contains epsilon, you continue with X two, and so on.",
                    "You compute this by iterating: apply the rules to every production, and repeat until no set changes. That's a fixed point. Is this clear so far? Any doubts?",
                    "For our grammar, FIRST of E prime is plus and epsilon, and FIRST of T is the same as FIRST of F, which is open paren and id.",
                ],
                refinements: [
                    ("FIRST sets", "FIRST(α) is the set of terminals that can begin a string derived from α."),
                    ("Computing FIRST sets", "Add FIRST of each symbol left to right while ε is present; iterate to a fixed point."),
                ],
                title: "FIRST sets: what a string can start with",
                summary: "FIRST(α) holds every terminal that can begin a string derived from α, plus ε if α can vanish; compute it by iterating the rules to a fixed point.",
                detail: TakeawayDetail(
                    bullets: [
                        "FIRST(a) = {a} for any terminal a.",
                        "For A → X1…Xn, add FIRST(X1); keep going to X2 only if ε ∈ FIRST(X1).",
                        "Iterate over all productions until no FIRST set changes.",
                        "Example: FIRST(E′) = {+, ε}; FIRST(T) = FIRST(F) = {(, id}.",
                    ],
                    keyTerms: [
                        KeyTerm(term: "FIRST set", definition: "FIRST(α): the terminals that can begin some string derived from α, plus ε if α ⇒* ε."),
                        KeyTerm(term: "fixed point", definition: "A state where reapplying the rules changes nothing; the iteration stops there."),
                    ]
                ),
                slidePages: [7, 8],
                quiz: (
                    QuizQuestion(
                        prompt: "With E′ → + T E′ | ε, what is FIRST(E′)?",
                        kind: .multipleChoice(options: ["{ +, ε }", "{ + }", "{ id, ( }", "{ ε }"], correctIndex: 0),
                        concept: "FIRST sets", sourceSlides: [7, 8], sourceStart: 180, sourceEnd: 250
                    ),
                    QuizQuestion(
                        prompt: "When computing FIRST(X1 X2 … Xn), when do you look at X2?",
                        kind: .multipleChoice(options: ["Only if ε ∈ FIRST(X1)", "Always", "Never", "Only if X1 is a terminal"], correctIndex: 0),
                        concept: "FIRST sets", sourceSlides: [8], sourceStart: 180, sourceEnd: 250
                    )
                )
            ),
            Beat(
                slide: 9,
                sentences: [
                    "FIRST tells us what a nonterminal can start with. FOLLOW tells us what can come immediately after it.",
                    "FOLLOW of A is the set of terminals that can appear right after A in some sentential form, and we add the end marker, dollar, to FOLLOW of the start symbol.",
                    "You need FOLLOW precisely when A can derive epsilon, because then the parser has to know whether it's okay to expand A to nothing.",
                    "» Sorry, quick question. Is FOLLOW of A just the FIRST set of whatever comes after A?",
                    "Good question. Almost. It's the union of FIRST of everything that can come after A in any production, minus epsilon, and if that can be empty you also pull in FOLLOW of the left-hand side. So it's bigger than any single FIRST set.",
                    "The rules: for B goes to alpha A beta, add FIRST of beta minus epsilon to FOLLOW of A. And if beta can be empty, or is empty, add FOLLOW of B to FOLLOW of A.",
                    "Again, iterate to a fixed point. For our grammar, FOLLOW of E is close paren and dollar, and FOLLOW of E prime is, uh, the same. People get this wrong on the exam every year, so please practice it.",
                ],
                refinements: [
                    ("FOLLOW sets", "FOLLOW(A) is the set of terminals that can appear immediately after A."),
                    ("FOLLOW sets and ε", "FOLLOW(A) matters when A can derive ε; $ is in FOLLOW of the start symbol."),
                ],
                title: "FOLLOW sets: what can come after a nonterminal",
                summary: "FOLLOW(A) is every terminal that can appear right after A ($ for the start symbol); it decides when expanding A to ε is safe.",
                detail: TakeawayDetail(
                    bullets: [
                        "B → αAβ: add FIRST(β) − {ε} to FOLLOW(A).",
                        "If β is empty or ε ∈ FIRST(β): add FOLLOW(B) to FOLLOW(A).",
                        "$ ∈ FOLLOW(S) marks end of input.",
                        "Example: FOLLOW(E) = FOLLOW(E′) = { ), $ }.",
                    ],
                    keyTerms: [
                        KeyTerm(term: "FOLLOW set", definition: "FOLLOW(A): the terminals that can appear immediately to the right of A in some sentential form."),
                        KeyTerm(term: "end marker $", definition: "A pseudo-terminal denoting end of input; always in FOLLOW of the start symbol."),
                    ]
                ),
                slidePages: [9, 10],
                quiz: nil
            ),
            Beat(
                slide: 11,
                sentences: [
                    "With FIRST and FOLLOW we can build the parse table. Rows are nonterminals, columns are terminals plus the end marker.",
                    "For each production A goes to alpha, put alpha in cell M of A comma a, for every terminal a in FIRST of alpha.",
                    "If epsilon is in FIRST of alpha, also put alpha in M of A comma b, for every b in FOLLOW of A.",
                    "Okay so here's the key definition, this is important, this will be on the midterm: a grammar is LL(1) if and only if no cell ends up with two productions.",
                    "Equivalently, for any two alternatives A goes to alpha or beta, their FIRST sets must be disjoint, and if beta can be empty, FIRST of alpha must not overlap FOLLOW of A.",
                ],
                refinements: [
                    ("Building the LL(1) table", "Rows are nonterminals, columns are terminals and $; fill M[A, a] from FIRST and FOLLOW."),
                    ("LL(1) means no table conflicts", "A grammar is LL(1) iff no table cell holds two productions."),
                ],
                title: "The LL(1) table and the LL(1) condition",
                summary: "M[A, a] = α for a ∈ FIRST(α), and for b ∈ FOLLOW(A) when ε ∈ FIRST(α); the grammar is LL(1) iff no cell holds two productions.",
                detail: TakeawayDetail(
                    bullets: [
                        "Table M is indexed by (nonterminal, terminal or $).",
                        "A conflict (two entries in one cell) means the grammar is not LL(1).",
                        "Disjointness test: FIRST(α) ∩ FIRST(β) = ∅, and FIRST(α) ∩ FOLLOW(A) = ∅ when β ⇒* ε.",
                    ],
                    keyTerms: [
                        KeyTerm(term: "parse table", definition: "A 2-D table M[A, a] that names the production to expand A with when the lookahead is a."),
                        KeyTerm(term: "LL(1) grammar", definition: "A grammar whose parse table has at most one production per cell."),
                    ]
                ),
                slidePages: [11, 12],
                quiz: (
                    QuizQuestion(
                        prompt: "A grammar is LL(1) exactly when…",
                        kind: .multipleChoice(options: ["No parse-table cell holds two productions", "It has no ε-productions", "Every nonterminal has one production", "It is unambiguous"], correctIndex: 0),
                        concept: "LL(1) condition", sourceSlides: [12], sourceStart: 330, sourceEnd: 400
                    ),
                    QuizQuestion(
                        prompt: "In one sentence: why does ε ∈ FIRST(α) make FOLLOW(A) matter when filling the table?",
                        kind: .shortAnswer(referenceAnswer: "Because expanding A to something empty is only correct when the next token can legally follow A."),
                        concept: "LL(1) condition", sourceSlides: [11], sourceStart: 330, sourceEnd: 400
                    )
                )
            ),
            Beat(
                slide: 13,
                sentences: [
                    "Once you have the table, the parser itself is trivial. You keep a stack that starts with the start symbol and the end marker.",
                    "If the top of the stack is a terminal, it must match the lookahead: pop it and advance the input.",
                    "If the top is a nonterminal A, look up M of A comma lookahead, pop A, and push the right-hand side in reverse.",
                    "If the cell is empty, that's a syntax error. If the stack and the input are both at dollar, you accept. Everybody with me? Okay.",
                    "Let's trace id plus id times id. Stack starts E dollar; lookahead is id, so we replace E with T E prime, then T with F T prime, then F with id, match, and keep going.",
                ],
                refinements: [
                    ("Table-driven parsing", "A stack of grammar symbols plus the table replaces recursion."),
                    ("Table-driven parsing with a stack", "Match terminals, expand nonterminals via M[A, lookahead], accept when both stack and input hit $."),
                ],
                title: "Table-driven LL(1) parsing with a stack",
                summary: "Start the stack with S $; match terminals against the lookahead, replace nonterminals with M[A, lookahead] reversed, accept when both hit $.",
                detail: TakeawayDetail(
                    bullets: [
                        "Terminal on top: must equal lookahead, else syntax error.",
                        "Nonterminal on top: consult the table; empty cell means error.",
                        "The stack contents are always the unmatched suffix of the current sentential form.",
                    ],
                    keyTerms: [
                        KeyTerm(term: "sentential form", definition: "Any string of terminals and nonterminals derivable from the start symbol."),
                    ],
                    example: "For id + id * id the stack goes E $ → T E′ $ → F T′ E′ $ → id T′ E′ $ → match id → …"
                ),
                slidePages: [13, 14],
                quiz: nil
            ),
            Beat(
                slide: 15,
                sentences: [
                    "Okay, one more transformation you'll need, uh, left factoring. Suppose A goes to alpha beta one, or alpha beta two, with the same prefix alpha.",
                    "One token of lookahead can't tell those apart, so we factor the prefix: A goes to alpha A prime, and A prime goes to beta one or beta two.",
                    "The classic example is if then else. Both productions start with if expr then stmt, so we factor that out and decide about the else later.",
                    "» So for the dangling else, does the factoring actually fix the ambiguity?",
                    "No, and that's exactly the point. Factoring only delays the decision. The dangling else is genuinely ambiguous, and no amount of factoring makes it LL(1), so most compilers resolve it by always matching the nearest if.",
                    "That's a general lesson. LL(1) is simple and fast, but some languages aren't LL(k) for any k, which is why we'll look at bottom-up parsing next.",
                ],
                refinements: [
                    ("Left factoring", "Factor a common prefix so one token of lookahead can decide."),
                    ("Left factoring and the dangling else", "Factor common prefixes; the dangling else stays ambiguous and is resolved by convention."),
                ],
                title: "Left factoring, and where LL(1) runs out",
                summary: "A → αβ1 | αβ2 becomes A → αA′, A′ → β1 | β2 so one token can decide; the dangling else stays ambiguous and some languages aren't LL(k) at all.",
                detail: TakeawayDetail(
                    bullets: [
                        "Left factoring delays the decision until enough input distinguishes the alternatives.",
                        "if/then/else needs factoring; the dangling else is resolved by matching the nearest if.",
                        "LL(1) is fast and simple but strictly weaker than LR parsing.",
                    ],
                    keyTerms: [
                        KeyTerm(term: "left factoring", definition: "Rewriting A → αβ1 | αβ2 as A → αA′, A′ → β1 | β2 to remove a shared prefix."),
                        KeyTerm(term: "dangling else", definition: "The ambiguity of which if an else belongs to in nested conditionals."),
                    ]
                ),
                slidePages: [15, 16],
                quiz: (
                    QuizQuestion(
                        prompt: "Which problem does left factoring fix?",
                        kind: .multipleChoice(options: ["Two alternatives share a common prefix", "A production is left-recursive", "A nonterminal derives ε", "The grammar is ambiguous"], correctIndex: 0),
                        concept: "left factoring", sourceSlides: [15], sourceStart: 470, sourceEnd: 540
                    ),
                    QuizQuestion(
                        prompt: "Left factor S → if E then S else S | if E then S. What does S′ become?",
                        kind: .multipleChoice(options: ["else S | ε", "if E then S", "S else S", "ε"], correctIndex: 0),
                        concept: "left factoring", sourceSlides: [15], sourceStart: 470, sourceEnd: 540
                    )
                )
            ),
            Beat(
                slide: 17,
                sentences: [
                    "Last thing, and then we're done: what happens when the table cell is empty and you hit an error. You don't want to stop at the first mistake, right.",
                    "The simplest strategy is panic mode: discard input tokens until you reach a synchronizing token, then pop the nonterminal and continue.",
                    "A good choice of synchronizing set for A is FOLLOW of A, because after skipping to something in FOLLOW of A you can pretend A was parsed and move on.",
                    "Report the error once, don't cascade, and keep parsing so the user sees more than one problem per compile.",
                    "Next time we'll do bottom-up parsing, shift-reduce, and LR tables. Read Dragon Book sections four point four and four point five.",
                ],
                refinements: [
                    ("Error recovery", "Don't stop at the first error; skip to a synchronizing token."),
                    ("Panic-mode error recovery", "Skip tokens until one in FOLLOW(A), pop A, report once and continue."),
                ],
                title: "Panic-mode error recovery uses FOLLOW as the sync set",
                summary: "On an empty table cell, skip input until a synchronizing token (FOLLOW(A) works well), pop A, report once and keep parsing; next lecture is bottom-up parsing.",
                detail: TakeawayDetail(
                    bullets: [
                        "Panic mode: discard tokens until a synchronizing token appears.",
                        "Using FOLLOW(A) lets the parser pretend A was completed.",
                        "Avoid cascading errors: report once per recovery.",
                        "Reading: Dragon Book §4.4–4.5 for LR parsing.",
                    ],
                    keyTerms: [
                        KeyTerm(term: "panic mode", definition: "An error-recovery strategy that skips input until a token from a synchronizing set is found."),
                        KeyTerm(term: "synchronizing token", definition: "A terminal at which the parser can safely resume after an error, typically from FOLLOW(A)."),
                    ]
                ),
                slidePages: [17, 18],
                quiz: nil
            ),
        ],
        summary: "Predictive (LL(1)) parsing expands the leftmost nonterminal using one token of lookahead. Left recursion must be eliminated and common prefixes left-factored first. FIRST sets say what a string can start with, FOLLOW sets what can come after a nonterminal; together they fill the LL(1) parse table, and a grammar is LL(1) exactly when no cell has two entries. A stack-driven parser then matches terminals and expands nonterminals from the table, recovering from errors in panic mode using FOLLOW as the synchronizing set.",
        keyTerms: [
            KeyTerm(term: "LL(1)", definition: "Left-to-right scan, leftmost derivation, one token of lookahead."),
            KeyTerm(term: "FIRST set", definition: "Terminals that can begin a string derived from a symbol string."),
            KeyTerm(term: "FOLLOW set", definition: "Terminals that can appear immediately after a nonterminal."),
            KeyTerm(term: "left recursion", definition: "A → Aα, which must be eliminated before top-down parsing."),
            KeyTerm(term: "left factoring", definition: "Removing a common prefix so lookahead can decide."),
            KeyTerm(term: "panic mode", definition: "Skip to a synchronizing token, then resume."),
        ]
    )
}

nonisolated private extension String {
    var lowercasedFirstLetter: String {
        guard let f = first else { return self }
        return f.lowercased() + dropFirst()
    }
}

// MARK: - Canned Ask answers

nonisolated extension DemoScript {
    /// Picks a grounded answer for a question. Citations use the `[S#]` / `[Tmm:ss]` markers from
    /// `CitationParser` so the real and demo paths render identically.
    func answer(for question: String, sessionTime: TimeInterval, currentSlide: Int?) -> String {
        let q = question.lowercased()
        if q.contains("catch me up") || q.contains("miss") || q.contains("last 5") {
            let t = max(0, sessionTime - 300)
            return "In the last few minutes the lecture moved from **FIRST sets** to **FOLLOW sets**. FIRST(α) is the set of terminals that can begin a string derived from α, plus ε if α can vanish [S7]. FOLLOW(A) is the set of terminals that can appear immediately after A, with $ added for the start symbol [S9] [T\(TimeFormat.clock(t))]. Both are computed by iterating the rules until nothing changes, and you need FOLLOW exactly when a nonterminal can derive ε [S10]."
        }
        if q.contains("current slide") || q.contains("this slide") || q.contains("explain slide") {
            let n = currentSlide ?? 7
            let s = slides[min(max(n - 1, 0), slides.count - 1)]
            return "Slide \(n) is **\(s.title)** [S\(n)]. " + s.bullets.map { "• \($0)" }.joined(separator: "\n") + "\n\nThe professor's point here: \(beats.first { $0.slidePages.contains(n) }?.summary ?? summary)"
        }
        if q.contains("important") || q.contains("so far") || q.contains("summar") {
            return "Three things matter so far:\n\n1. **Predictive parsing** picks a production from one token of lookahead — that's what LL(1) means [S4].\n2. You must **eliminate left recursion** first, rewriting A → Aα | β as A → βA′, A′ → αA′ | ε [S6].\n3. **FIRST and FOLLOW sets** are what make the choice mechanical; they fill the parse table [S7] [S9].\n\nIf you remember one line: a grammar is LL(1) iff no parse-table cell holds two productions [S12]."
        }
        if q.contains("follow") {
            return "FOLLOW(A) is the set of terminals that can appear immediately to the right of A in some sentential form [S9]. Two rules fill it: for B → αAβ add FIRST(β) − {ε} to FOLLOW(A), and if β can be empty add FOLLOW(B) to FOLLOW(A) [S10]. The end marker $ always belongs to FOLLOW of the start symbol. You need it when A can derive ε, because then the parser must know whether expanding A to nothing is legal [T\(TimeFormat.clock(max(0, sessionTime - 60)))]."
        }
        if q.contains("first") {
            return "FIRST(α) is every terminal that can begin a string derived from α, plus ε if α ⇒* ε [S7]. For A → X1 X2 … Xn you add FIRST(X1) and only continue to X2 if ε ∈ FIRST(X1) [S8]. Iterate over all productions until no set changes. In the expression grammar FIRST(E′) = {+, ε} and FIRST(T) = FIRST(F) = {(, id}."
        }
        if q.contains("left recursion") || q.contains("recursion") {
            return "Left recursion (A → Aα) makes recursive descent call itself without consuming input, so it never terminates [S5]. The fix: rewrite A → Aα | β as A → βA′ and A′ → αA′ | ε [S6]. For expressions, E → E + T | T becomes E → T E′, E′ → + T E′ | ε — same language, right-recursive."
        }
        if q.contains("factor") || q.contains("else") {
            return "Left factoring handles two alternatives with a common prefix: A → αβ1 | αβ2 becomes A → αA′, A′ → β1 | β2, so the decision is delayed until the parser has seen α [S15]. It's what makes if/then/else parseable, though the dangling else remains ambiguous and is resolved by matching the nearest if [S16]."
        }
        if q.contains("table") || q.contains("ll(1)") || q.contains("ll1") {
            return "The LL(1) table M has a row per nonterminal and a column per terminal plus $ [S11]. For each production A → α, set M[A, a] = α for every a ∈ FIRST(α); if ε ∈ FIRST(α), also set M[A, b] = α for every b ∈ FOLLOW(A). The grammar is LL(1) exactly when no cell receives two productions [S12]. Parsing is then a stack loop: match terminals, expand nonterminals from the table, accept at $ [S13]."
        }
        if q.contains("error") || q.contains("panic") {
            return "When the table cell is empty the parser is in an error state. Panic mode skips input tokens until it reaches a synchronizing token, pops the nonterminal, and continues [S17]. FOLLOW(A) is a good synchronizing set for A because after skipping to it the parser can pretend A was parsed. Report the error once so you don't cascade."
        }
        return "Based on the lecture so far: \(beats.prefix(max(1, min(beats.count, Int(sessionTime / 40) + 1))).last?.summary ?? summary) [S\(currentSlide ?? 1)]. Ask about FIRST sets, FOLLOW sets, the parse table, left recursion or left factoring for a more specific answer."
    }
}
