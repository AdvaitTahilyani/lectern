import Foundation

/// Splits text after sentence-ending punctuation followed by whitespace ("LL(1) parsing. Next..."
/// splits, "e.g.x" does not).
enum SentenceSplitter {
    static func sentences(in text: String) -> [String] {
        var result: [String] = []
        var current = ""
        var previous: Character?
        for character in text {
            if character.isWhitespace, let previous, ".!?".contains(previous) {
                if !current.isEmpty { result.append(current) }
                current = ""
            } else {
                current.append(character)
            }
            previous = character
        }
        if !current.isEmpty { result.append(current) }
        return result.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}
