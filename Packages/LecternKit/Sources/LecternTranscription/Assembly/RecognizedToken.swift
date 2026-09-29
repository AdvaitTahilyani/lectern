import Foundation

/// One decoded sub-word token with its position on the recognizer's stream clock.
///
/// Word starts are marked the SentencePiece way: the token text begins with a space or `▁`.
/// Punctuation tokens carry no marker and therefore attach to the preceding word.
struct RecognizedToken: Sendable, Hashable {
    var text: String
    var start: TimeInterval
    var end: TimeInterval
}

/// A whole word (punctuation attached) with its time span.
struct TimedWord: Sendable, Hashable {
    var text: String
    var start: TimeInterval
    var end: TimeInterval
}

/// Groups a token stream into words. The last word stays open until a token with a word-start
/// marker arrives, so a word split across two decode steps is stitched back together.
struct WordBuilder: Sendable {
    private(set) var words: [TimedWord] = []

    static func startsWord(_ token: String) -> Bool {
        token.hasPrefix(" ") || token.hasPrefix("\u{2581}")
    }

    static func isSpecial(_ token: String) -> Bool {
        token.isEmpty || (token.hasPrefix("<") && token.hasSuffix(">") && token.count > 2)
    }

    mutating func append(_ tokens: [RecognizedToken]) {
        for token in tokens where !Self.isSpecial(token.text) {
            let piece = token.text
                .replacingOccurrences(of: "\u{2581}", with: " ")
                .trimmingCharacters(in: .whitespaces)
            guard !piece.isEmpty else { continue }
            if Self.startsWord(token.text) || words.isEmpty {
                words.append(TimedWord(text: piece, start: token.start, end: token.end))
            } else {
                words[words.count - 1].text += piece
                words[words.count - 1].end = max(words[words.count - 1].end, token.end)
            }
        }
    }
}
