import Foundation
import LecternCore
@testable import LecternTranscription

/// A scripted word with stream-clock timing.
struct ScriptWord {
    var text: String
    var start: TimeInterval
    var end: TimeInterval
}

enum Script {
    /// Words at a steady pace (`wordDuration` each, `gap` between), starting at `start`.
    static func words(_ text: String, start: TimeInterval = 0, wordDuration: TimeInterval = 0.3, gap: TimeInterval = 0.05) -> [ScriptWord] {
        var time = start
        return text.split(separator: " ").map { word in
            defer { time += wordDuration + gap }
            return ScriptWord(text: String(word), start: time, end: time + wordDuration)
        }
    }

    /// The end time of the last word plus `pause`, for chaining scripts.
    static func resume(after words: [ScriptWord], pause: TimeInterval) -> TimeInterval {
        (words.last?.end ?? 0) + pause
    }

    /// SentencePiece-style tokens: the first piece of each word carries the leading space.
    /// With `split`, every word longer than 3 characters is cut into two pieces.
    static func tokens(_ words: [ScriptWord], split: Bool = false) -> [RecognizedToken] {
        words.flatMap { word -> [RecognizedToken] in
            guard split, word.text.count > 3 else {
                return [RecognizedToken(text: " " + word.text, start: word.start, end: word.end)]
            }
            let cut = word.text.index(word.text.startIndex, offsetBy: word.text.count / 2)
            let middle = word.start + (word.end - word.start) / 2
            return [
                RecognizedToken(text: " " + word.text[..<cut], start: word.start, end: middle),
                RecognizedToken(text: String(word.text[cut...]), start: middle, end: word.end),
            ]
        }
    }
}

/// Drives an assembler the way a streaming recognizer would: `step` words per update, cumulative
/// text, and a decode clock that trails the newest word by `lag` seconds.
struct StreamDriver {
    var assembler: SegmentAssembler
    private(set) var events: [TranscriptionEvent] = []
    private var spoken: [String] = []
    private let lag: TimeInterval

    init(assembler: SegmentAssembler = SegmentAssembler(makeID: { UUID() }), lag: TimeInterval = 0) {
        self.assembler = assembler
        self.lag = lag
    }

    var cumulativeText: String { spoken.joined(separator: " ") }

    mutating func push(_ words: [ScriptWord], split: Bool = false, clock: TimeInterval? = nil) {
        spoken.append(contentsOf: words.map(\.text))
        let decoded = clock ?? ((words.last?.end ?? 0) + lag)
        events += assembler.update(text: cumulativeText, tokens: Script.tokens(words, split: split), decodedThrough: decoded)
    }

    /// Advances the clock without new words (silence).
    mutating func advance(to clock: TimeInterval) {
        events += assembler.update(text: cumulativeText, tokens: [], decodedThrough: clock)
    }

    mutating func stream(_ words: [ScriptWord], step: Int = 3, split: Bool = false) {
        var index = 0
        while index < words.count {
            push(Array(words[index..<min(index + step, words.count)]), split: split)
            index += step
        }
    }

    mutating func finish() {
        events += assembler.finish(text: cumulativeText, tokens: [])
    }

    var finals: [TranscriptSegment] {
        events.compactMap { if case .final(let s) = $0 { s } else { nil } }
    }

    var volatiles: [TranscriptSegment] {
        events.compactMap { if case .volatile(let s) = $0 { s } else { nil } }
    }
}
