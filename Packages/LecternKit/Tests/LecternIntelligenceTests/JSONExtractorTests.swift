import Foundation
import LecternCore
import Testing
@testable import LecternIntelligence

@Suite struct JSONExtractorTests {
    private func object(_ text: String) -> [String: Any]? {
        guard let json = JSONExtractor.extractObject(from: text) else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
    }

    @Test func plainObject() {
        #expect(object(#"{"a": 1, "b": "x"}"#)?["b"] as? String == "x")
    }

    @Test func codeFenceAndProse() {
        let text = """
        Sure! Here is the JSON you asked for:
        ```json
        {"action": "continue", "title": "FIRST sets"}
        ```
        Let me know if you need anything else.
        """
        #expect(object(text)?["title"] as? String == "FIRST sets")
    }

    @Test func skipsStrayBracesInProse() {
        let text = #"The set {a, b} is FIRST(A). Result: {"title": "FIRST sets", "slides": [3]}"#
        #expect(object(text)?["title"] as? String == "FIRST sets")
    }

    @Test func trailingCommas() {
        let o = object(#"{"slides": [1, 2,], "title": "x",}"#)
        #expect(o?["slides"] as? [Int] == [1, 2])
    }

    @Test func smartQuotesAsDelimiters() {
        let o = object("{“action”: “new_topic”, “title”: “FOLLOW sets”}")
        #expect(o?["action"] as? String == "new_topic")
        #expect(o?["title"] as? String == "FOLLOW sets")
    }

    @Test func smartQuotesInsideStringsAreKept() {
        let o = object(#"{"summary": "Called “lookahead” in LL(1)."}"#)
        #expect(o?["summary"] as? String == "Called “lookahead” in LL(1).")
    }

    @Test func singleQuotedPythonStyle() {
        let o = object("{'correct': True, 'feedback': 'Nice', 'extra': None}")
        #expect(o?["correct"] as? Bool == true)
        #expect(o?["feedback"] as? String == "Nice")
        #expect(o?["extra"] is NSNull)
    }

    @Test func apostropheInsideSingleQuotedString() {
        let o = object("{'feedback': 'it doesn't derive ε'}")
        #expect(o?["feedback"] as? String == "it doesn't derive ε")
    }

    @Test func rawNewlinesAndTabsInStrings() {
        let o = object("{\"summary\": \"line one\nline\ttwo\"}")
        #expect(o?["summary"] as? String == "line one\nline\ttwo")
    }

    @Test func unescapedInnerQuotes() {
        let o = object(#"{"summary": "The "FIRST" set of A is {a}.", "title": "t"}"#)
        #expect(o?["summary"] as? String == #"The "FIRST" set of A is {a}."#)
        #expect(o?["title"] as? String == "t")
    }

    @Test func innerQuoteBeforeCommaStaysInString() {
        let o = object(#"{"question": "Why generate "naive", unoptimized IR first?", "slides": [3]}"#)
        #expect(o?["question"] as? String == #"Why generate "naive", unoptimized IR first?"#)
        #expect(o?["slides"] as? [Int] == [3])
        // A real closing quote followed by an unquoted key still closes.
        #expect(object(#"{"a": "x", b: 2}"#)?["b"] as? Int == 2)
    }

    @Test func bareTimestampsBecomeCitations() {
        let text = CitationNormalizer.normalize("placed at b' [0:46, 7:10] and later [1:02:05]; slide [S4] stays")
        #expect(text == "placed at b' [T0:46, T7:10] and later [T1:02:05]; slide [S4] stays")
        #expect(CitationParser.citations(in: text) == [.time(46), .time(430), .time(3725), .slide(4)])
    }

    @Test func invalidEscapesBecomeLiteralBackslashes() {
        let o = object(#"{"summary": "use \alpha and \n"}"#)
        #expect(o?["summary"] as? String == "use \\alpha and \n")
    }

    @Test func unquotedKeysAndBareValues() {
        let o = object("{action: new_topic, slides: [4, 5], score: -1.5}")
        #expect(o?["action"] as? String == "new_topic")
        #expect(o?["slides"] as? [Int] == [4, 5])
        #expect(o?["score"] as? Double == -1.5)
    }

    @Test func truncatedOutputIsClosed() {
        let o = object(#"{"action": "continue", "title": "LL(1) parsing", "summary": "An LL(1) parser uses one tok"#)
        #expect(o?["summary"] as? String == "An LL(1) parser uses one tok")
        #expect(object(#"{"a": [1, 2"#)?["a"] as? [Int] == [1, 2])
        #expect(object(#"{"a": 1, "b":"#)?["b"] is NSNull)
    }

    @Test func mismatchedCloser() {
        #expect(object(#"{"slides": [1, 2}"#)?["slides"] as? [Int] == [1, 2])
    }

    @Test func thinkBlockIsIgnored() {
        let text = #"<think>maybe {"title": "wrong"}</think>{"title": "right"}"#
        #expect(object(text)?["title"] as? String == "right")
    }

    @Test func lineComments() {
        #expect(object("{\"a\": 1, // the count\n \"b\": 2}")?["b"] as? Int == 2)
    }

    @Test func nestedObjectsPreserved() {
        let o = object(#"{"key_terms": [{"term": "FIRST", "definition": "starts"}], "bullets": ["a"]}"#)
        #expect((o?["key_terms"] as? [[String: String]])?.first?["term"] == "FIRST")
    }

    @Test func nothingToExtract() {
        #expect(JSONExtractor.extractObject(from: "I can't help with that.") == nil)
        #expect(JSONExtractor.extractObject(from: "") == nil)
        #expect(throws: JSONExtractionError.self) { try JSONExtractor.decode(GradeReply.self, from: "no json") }
    }

    // MARK: Tolerant decoding

    @Test func segmentationDecodesCamelCaseAndLooseTypes() throws {
        let reply = try JSONExtractor.decode(SegmentationReply.self, from: #"""
        {"Action": "NEW TOPIC", "boundaryQuote": "now FOLLOW sets", "closedSummary": "done", "title": "FOLLOW sets", "summary": "s", "slides": ["S4", "5-6", 7.0]}
        """#)
        #expect(reply.action == .newTopic)
        #expect(reply.newLinesKind == .newConcept)
        #expect(reply.boundaryQuote == "now FOLLOW sets")
        #expect(reply.closedSummary == "done")
        #expect(reply.slides == [4, 5, 6, 7])
    }

    @Test func segmentationKinds() throws {
        #expect(try JSONExtractor.decode(SegmentationReply.self, from: #"{"new_lines_kind": "admin_or_chat", "action": "new_topic"}"#).newLinesKind == .admin)
        #expect(try JSONExtractor.decode(SegmentationReply.self, from: #"{"new_lines_kind": "same_concept", "action": "continue"}"#).newLinesKind == .sameConcept)
    }

    @Test func segmentationDefaultsMissingFields() throws {
        let reply = try JSONExtractor.decode(SegmentationReply.self, from: #"{"title": "x", "summary": "y", "slides": "4, 5"}"#)
        #expect(reply.action == .continueTopic)
        #expect(reply.boundaryQuote.isEmpty)
        #expect(reply.slides == [4, 5])
    }

    @Test func detailAcceptsVariantShapes() throws {
        let a = try JSONExtractor.decode(DetailReply.self, from: #"{"bullets": "- one\n- two", "keyTerms": {"FIRST": "starts", "FOLLOW": "after"}, "example": "none"}"#)
        #expect(a.bullets == ["one", "two"])
        #expect(a.keyTerms.map(\.term) == ["FIRST", "FOLLOW"])
        #expect(a.example == nil)

        let b = try JSONExtractor.decode(DetailReply.self, from: #"{"bullets": [{"text": "one"}, "two"], "key_terms": ["FIRST: starts", "ε — empty"], "example": "e"}"#)
        #expect(b.bullets == ["one", "two"])
        #expect(b.keyTerms == [LenientKeyTerm(term: "FIRST", definition: "starts"), LenientKeyTerm(term: "ε", definition: "empty")])
        #expect(b.example == "e")
    }

    @Test func gradeAcceptsStringBooleans() throws {
        #expect(try JSONExtractor.decode(GradeReply.self, from: #"{"correct": "yes", "feedback": "ok"}"#).correct == true)
        #expect(try JSONExtractor.decode(GradeReply.self, from: #"{"is_correct": 0, "feedback": "no"}"#).correct == false)
        #expect(try JSONExtractor.decode(GradeReply.self, from: #"{"feedback": "?"}"#).correct == nil)
    }

    @Test func multipleChoiceAlternateKeys() throws {
        let r = try JSONExtractor.decode(MultipleChoiceReply.self, from: #"{"question": "q", "answer": "a", "wrong_answers": ["b", "c", "d"]}"#)
        #expect(r.answer == "a")
        #expect(r.distractors == ["b", "c", "d"])
    }

    static let allSchemas = [SegmentationReply.schema, DetailReply.schema, RecapReply.schema,
                             MultipleChoiceReply.schema, ShortAnswerReply.schema, GradeReply.schema]

    @Test func schemasAreValidJSON() throws {
        for schema in Self.allSchemas {
            let object = try JSONSerialization.jsonObject(with: Data(schema.utf8)) as? [String: Any]
            #expect(object?["type"] as? String == "object")
        }
    }

    /// OpenAI `strict: true` and Anthropic structured outputs reject a schema unless every object
    /// forbids extra keys and requires all of its properties, and both only support a subset of
    /// keywords. Ollama accepts anything, so only this test catches a violation before a paid call.
    @Test func schemasSatisfyStrictStructuredOutputs() throws {
        let unsupported: Set<String> = ["minItems", "maxItems", "minLength", "maxLength", "pattern", "format",
                                        "minimum", "maximum", "oneOf", "allOf", "not", "if", "then", "else"]
        func check(_ node: Any, path: String) {
            if let object = node as? [String: Any] {
                for key in object.keys where unsupported.contains(key) {
                    Issue.record("\(path): unsupported keyword \"\(key)\"")
                }
                if object["type"] as? String == "object" {
                    let properties = object["properties"] as? [String: Any] ?? [:]
                    #expect(object["additionalProperties"] as? Bool == false, "\(path) must set additionalProperties:false")
                    #expect(Set(object["required"] as? [String] ?? []) == Set(properties.keys), "\(path) must require every property")
                }
                for (key, value) in object { check(value, path: "\(path)/\(key)") }
            } else if let array = node as? [Any] {
                for (i, value) in array.enumerated() { check(value, path: "\(path)[\(i)]") }
            }
        }
        for schema in Self.allSchemas {
            check(try JSONSerialization.jsonObject(with: Data(schema.utf8)), path: "#")
        }
    }

    // MARK: Repair turn

    @Test func repairTurnRecoversFromGarbage() async throws {
        let provider = ScriptedProvider(texts: ["I think the topic continues.", #"{"correct": true, "feedback": "Right."}"#])
        let reply = try await StructuredGeneration.generate(GradeReply.self, provider: provider, messages: [.user("grade")], profile: .grading) { $0 }
        #expect(reply.feedback == "Right.")
        let requests = provider.requests
        #expect(requests.count == 2)
        #expect(requests[1].messages.count == 3)
        #expect(requests[1].messages[1] == .assistant("I think the topic continues."))
        #expect(requests[1].lastUser.contains("only one valid JSON object"))
        #expect(requests[0].responseFormat == .json(schema: GradeReply.schema))
    }

    @Test func repairTurnCarriesValidationReason() async throws {
        let provider = ScriptedProvider(texts: [#"{"feedback": ""}"#, #"{"correct": false, "feedback": "No."}"#])
        _ = try await StructuredGeneration.generate(GradeReply.self, provider: provider, messages: [.user("grade")], profile: .grading) { reply in
            guard reply.correct != nil else { throw ReplyRejected(reason: "correct is missing") }
            return reply
        }
        #expect(provider.requests[1].lastUser.contains("correct is missing"))
    }

    @Test func secondFailureThrows() async {
        let provider = ScriptedProvider(texts: ["nope", "still nope"])
        await #expect(throws: BrainError.self) {
            try await StructuredGeneration.generate(GradeReply.self, provider: provider, messages: [.user("g")], profile: .grading) { $0 }
        }
        #expect(provider.requests.count == 2)
    }

    @Test func providerErrorsAreNotRetried() async {
        let provider = ScriptedProvider([.failure(.network("offline"))])
        await #expect(throws: LLMError.network("offline")) {
            try await StructuredGeneration.generate(GradeReply.self, provider: provider, messages: [.user("g")], profile: .grading) { $0 }
        }
        #expect(provider.requests.count == 1)
    }
}

@Suite struct PlainMathTests {
    @Test func latexEscapesSurviveJSON() {
        // "\text" would otherwise decode as a tab followed by "ext".
        let o = try? JSONExtractor.decode(SegmentationReply.self, from: #"{"summary": "FIRST($\text{alpha}$) \to $\beta$\nnext", "title": "t"}"#)
        #expect(o?.summary.contains("\t") == false)
        #expect(o?.summary.contains("\n") == true)
        #expect(PlainMath.clean(o!.summary) == "FIRST(alpha) → β next")
    }

    @Test func cleansCommonLatex() {
        #expect(PlainMath.clean(#"FIRST($\alpha$) contains $\varepsilon$ if $\alpha \Rightarrow^{*} \epsilon$"#) == "FIRST(α) contains ε if α ⇒^* ε")
        #expect(PlainMath.clean(#"$A \to \beta A'$ and $Y_{1} \in N$"#) == "A → β A' and Y1 ∈ N")
        #expect(PlainMath.clean(#"\{ a, b \} \cup \emptyset"#) == "{ a, b } ∪ ∅")
    }

    @Test func endMarkerDollarIsKept() {
        #expect(PlainMath.clean("FOLLOW(E) = { ), $ } and $ ∈ FOLLOW(S)") == "FOLLOW(E) = { ), $ } and $ ∈ FOLLOW(S)")
        #expect(PlainMath.clean("FOLLOW(E) = {), $} and FOLLOW(T) = {+, ), $}") == "FOLLOW(E) = {), $} and FOLLOW(T) = {+, ), $}")
    }
}
