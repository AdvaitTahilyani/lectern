import MLXGuidedGeneration
import MLXLMCommon

/// Compiles and caches JSON grammars for one tokenizer.
///
/// Compiling a schema builds xgrammar's token masks (tens to hundreds of milliseconds), so each
/// distinct schema is compiled once. The bundled xgrammar (v0.1.30) cannot fork matchers, so a
/// cached matcher is lent to one request at a time and rolled back to its initial state when
/// returned. Used only on the owning engine's executor.
final class GrammarLibrary {
    /// Any single JSON object, used for `.json(schema: nil)`.
    static let anyJSONObject = #"""
        root ::= object
        value ::= object | array | string | number | "true" | "false" | "null"
        object ::= "{" ws ( member ( ws "," ws member )* )? ws "}"
        member ::= string ws ":" ws value
        array ::= "[" ws ( value ( ws "," ws value )* )? ws "]"
        string ::= "\"" char* "\""
        char ::= [^"\\\x00-\x1F] | "\\" ( ["\\/bfnrt] | "u" [0-9a-fA-F] [0-9a-fA-F] [0-9a-fA-F] [0-9a-fA-F] )
        number ::= "-"? ( "0" | [1-9] [0-9]* ) ( "." [0-9]+ )? ( [eE] [+-]? [0-9]+ )?
        ws ::= [ \t\n]*
        """#

    private let tokenizer: GrammarTokenizer
    /// Idle matchers in their initial state, by schema ("" = any JSON object).
    private var idle: [String: GrammarConstraint] = [:]
    private let capacity = 16

    /// Size of the grammar vocabulary (may differ from the model's logit dimension).
    var vocabularySize: Int { tokenizer.vocabSize }

    init(tokenizer: any Tokenizer, stopTokenID: Int) throws {
        let vocab = TokenizerVocabExtractor.extractForGrammar(from: tokenizer)
        self.tokenizer = try GrammarTokenizer(
            vocab: vocab.vocab, vocabType: vocab.vocabType, eosTokenId: Int32(stopTokenID))
    }

    /// Borrows a matcher in its initial state for `schema` (a JSON Schema string), or for any
    /// JSON object when nil. Hand it back with ``giveBack(_:schema:acceptedTokens:)``.
    func borrow(schema: String?) throws -> GrammarConstraint {
        let key = schema ?? ""
        if let matcher = idle.removeValue(forKey: key) { return matcher }
        if let schema {
            return try GrammarConstraint(tokenizer: tokenizer, jsonSchema: schema)
        }
        return try GrammarConstraint(tokenizer: tokenizer, grammar: Self.anyJSONObject)
    }

    /// Returns a borrowed matcher after rewinding the `acceptedTokens` it consumed. A matcher
    /// that cannot be rewound is dropped (the schema is recompiled next time).
    func giveBack(_ matcher: GrammarConstraint, schema: String?, acceptedTokens: Int) {
        do {
            if acceptedTokens > 0 { try matcher.rollback(Int32(acceptedTokens)) }
        } catch {
            return
        }
        if idle.count >= capacity { idle.removeAll() }
        idle[schema ?? ""] = matcher
    }
}
