import Foundation
import LecternCore

/// A synthetic compilers lecture (slides + timestamped transcript) for live model tests.
enum LectureFixture {
    static let slides = """
        [S1] Syntax analysis: from tokens to parse trees.
        [S2] Context-free grammars: terminals, nonterminals, productions, start symbol.
        [S3] Derivations and ambiguity. Leftmost vs rightmost derivations.
        [S4] Top-down parsing and predictive parsers; why left recursion breaks them.
        [S5] FIRST sets: the terminals that can begin strings derived from a symbol.
        [S6] FOLLOW sets: the terminals that can appear immediately after a nonterminal.
        [S7] Building the LL(1) parse table from FIRST and FOLLOW.
        [S8] LL(1) conflicts and how to fix them: left factoring, removing left recursion.
        [S9] Bottom-up parsing preview: shift-reduce and handles.
        """

    private static let paragraphs = [
        "Okay, so let's pick up where we left off last time. We had the scanner producing a stream of tokens, and today the question is what we do with that stream. The parser's job is to figure out whether the token sequence is a sentence of the language, and if it is, to build a structure, a parse tree or more usually an abstract syntax tree, that the later phases can walk over.",
        "To describe the language we use a context-free grammar. Remember the four parts: a set of terminals, which are exactly the token kinds from the scanner, a set of nonterminals, a set of productions that say how a nonterminal can be rewritten, and a start symbol. When I write E goes to E plus T, the E on the left is the head and everything on the right is the body.",
        "A derivation is just a sequence of rewriting steps from the start symbol to a string of terminals. If we always rewrite the leftmost nonterminal we get a leftmost derivation, and that is the order a top-down parser discovers things. A grammar is ambiguous if some sentence has two different parse trees, and the classic example is the dangling else, where an else could attach to either of two ifs.",
        "Now, a predictive parser looks at the next token, just one token of lookahead, and has to decide which production to use for the current nonterminal. That only works if the choice is determined by that single token. If you have left recursion, like E goes to E plus T, a recursive descent parser for E would immediately call itself for E again without consuming anything, and you loop forever.",
        "This is where FIRST sets come in. FIRST of a string alpha is the set of terminals that can begin some string derived from alpha, plus epsilon if alpha can derive the empty string. For a terminal, FIRST is just that terminal. For a nonterminal, you take the union over all its productions, and when the first symbol of a body can vanish you keep going to the next symbol, and so on. You iterate until nothing changes, it's a fixed point computation.",
        "FOLLOW is the other half. FOLLOW of a nonterminal A is the set of terminals that can appear immediately to the right of A in some sentential form. We put the end marker, dollar, into FOLLOW of the start symbol. Then for every production B goes to alpha A beta, everything in FIRST of beta except epsilon goes into FOLLOW of A, and if beta can vanish, FOLLOW of B goes into FOLLOW of A as well. Students often mix these up, so on the exam, write out the rules before you start.",
        "With both sets we can fill in the LL(1) table. For each production A goes to alpha, for each terminal a in FIRST of alpha, put the production in the table at row A, column a. If epsilon is in FIRST of alpha, then for each terminal b in FOLLOW of A, put it at row A, column b too. If any cell ends up with two productions, the grammar is not LL(1), and that's a conflict you have to resolve.",
        "The usual fixes are left factoring and eliminating left recursion. Left factoring pulls out a common prefix, so if two productions both start with if expression then, you make one production and push the difference into a new nonterminal. Eliminating immediate left recursion rewrites E goes to E plus T or T into E goes to T E prime, and E prime goes to plus T E prime or epsilon. Same language, but now it's right recursive and a predictive parser is happy.",
        "Let's do an example on the board with the expression grammar. FIRST of T is the same as FIRST of F, which is left paren and id. FIRST of E prime is plus and epsilon. FOLLOW of E is right paren and dollar, and FOLLOW of E prime is the same as FOLLOW of E because E prime is at the end of E's body. If you get these right the table has no conflicts, which tells you the transformed grammar is LL(1).",
        "Next time we'll flip the direction and talk about bottom-up parsing. Instead of guessing productions from the top, a shift-reduce parser pushes tokens onto a stack and reduces when the top of the stack matches the body of a production, what we call a handle. It handles a much bigger class of grammars, including left recursive ones, and it's what tools like yacc and bison generate.",
    ]

    /// About `approximateTokens` tokens of transcript (roughly 1.3 tokens per word).
    static func transcript(approximateTokens: Int) -> String {
        var lines: [String] = []
        var seconds = 60
        var words = 0
        var round = 0
        while Double(words) * 1.3 < Double(approximateTokens) {
            for paragraph in paragraphs {
                let prefix = round == 0 ? "" : "Just to repeat that point, since a few people asked: "
                lines.append("[\(TimeFormat.clock(TimeInterval(seconds)))] \(prefix)\(paragraph)")
                words += paragraph.split(separator: " ").count
                seconds += 47
                if Double(words) * 1.3 >= Double(approximateTokens) { break }
            }
            round += 1
        }
        return lines.joined(separator: "\n")
    }

    static let system = """
        You are Lectern, a study companion that follows a live university lecture. You receive the \
        slide deck and the transcript so far. Be faithful to what was actually said; never invent \
        content. Cite slides as [S#].

        SLIDES
        \(slides)
        """

    static let segmentationSchema = #"""
        {"type":"object","properties":{"decision":{"type":"string","enum":["continue","new_topic"]},"title":{"type":"string"},"summary":{"type":"string"},"slides":{"type":"array","items":{"type":"integer"}}},"required":["decision","title","summary","slides"],"additionalProperties":false}
        """#

    /// A segmentation request whose cacheable prefix is system + transcript.
    static func segmentationRequest(transcript: String, instruction: String) -> LLMRequest {
        LLMRequest(
            messages: [
                .system(system),
                .user("TRANSCRIPT SO FAR\n\(transcript)\n\nTASK\n\(instruction)"),
            ],
            maxTokens: 256,
            temperature: 0.3,
            responseFormat: .json(schema: segmentationSchema))
    }
}
