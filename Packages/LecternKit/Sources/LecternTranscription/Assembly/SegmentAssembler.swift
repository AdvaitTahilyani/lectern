import Foundation
import LecternCore

/// Tunables for `SegmentAssembler`. Defaults follow the lecture use case: sentence-sized
/// segments, cut early when the speaker pauses, and never longer than ~25 s / 60 words.
struct AssemblerConfig: Sendable, Hashable {
    /// A sentence-ending word is final once followed by at least this much silence.
    var sentencePause: TimeInterval = 0.4
    /// Any word followed by at least this much silence ends a segment, punctuation or not.
    var gapBreak: TimeInterval = 0.8
    /// Longest a segment may run before it is force-cut.
    var maxDuration: TimeInterval = 25
    /// Most words a segment may hold before it is force-cut.
    var maxWords = 60
    /// Once a segment holds this many words, a sentence end finalizes it even without a pause.
    var softSentenceWords = 30
    /// A forced cut at a pause never leaves fewer than this many words in the first segment.
    var minForcedCutWords = 8
    /// A stretch of another speaker must last this long to split a segment (shorter ones are
    /// treated as diarizer noise or back-channel remarks).
    var minSpeakerRun: TimeInterval = 1.0
    /// While diarization is running, a segment is held back until the diarizer has passed its
    /// end, but never longer than this beyond the recognizer's own decode time.
    var maxSpeakerWait: TimeInterval = 6

    static let `default` = AssemblerConfig()
}

/// Turns the cumulative, append-only output of a streaming recognizer (full text so far plus
/// timed tokens, no final/volatile flag) into Lectern's `.volatile` / `.final` events.
///
/// - The not-yet-finalized tail is always reported as one `.volatile` segment whose id stays
///   stable until that text is finalized (the `.final` reuses the id, so the UI replaces in place).
/// - Finalization rules are described on `AssemblerConfig`. All timestamps are stream seconds
///   plus `timeOffset`.
/// - `text` may be revised, but only in ways the assembler can absorb: the un-finalized tail may
///   change freely (vocabulary boosting rewrites words); a revision that reaches into already
///   finalized text cannot retract that segment and is only re-synchronized so later segments stay
///   correct.
struct SegmentAssembler {
    private let config: AssemblerConfig
    private let timeOffset: TimeInterval
    private let makeID: @Sendable () -> UUID

    private var builder = WordBuilder()
    /// Index into `builder.words` of the first token word that is not yet finalized.
    private var tokenCursor = 0
    /// Number of leading words of the cumulative text that are already finalized.
    private var textCursor = 0
    /// Normalized last few finalized words, used to re-find the cursor after a text revision.
    private var recentFinalized: [String] = []
    private var lastFinalizedEnd: TimeInterval = 0
    private var volatileID: UUID
    private var lastVolatile: (text: String, end: TimeInterval)?

    init(
        config: AssemblerConfig = .default,
        timeOffset: TimeInterval = 0,
        makeID: @escaping @Sendable () -> UUID = { UUID() }
    ) {
        self.config = config
        self.timeOffset = timeOffset
        self.makeID = makeID
        self.volatileID = makeID()
    }

    /// Feeds one recognizer update.
    /// - Parameters:
    ///   - text: the full cumulative transcript so far.
    ///   - tokens: tokens decoded since the previous call.
    ///   - decodedThrough: stream time up to which the recognizer has finished decoding. Silence
    ///     after the last word is measured against it, so it must not run ahead of the model.
    ///   - speakers: current diarizer output, if any. Segments are then also cut where the speaker
    ///     changes, so a student's question does not end up inside the lecturer's segment.
    mutating func update(
        text: String, tokens: [RecognizedToken], decodedThrough: TimeInterval, speakers: SpeakerActivity? = nil
    ) -> [TranscriptionEvent] {
        process(text: text, tokens: tokens, clock: decodedThrough, flush: false, speakers: speakers)
    }

    /// Feeds the last update and finalizes everything that is left.
    mutating func finish(text: String, tokens: [RecognizedToken], speakers: SpeakerActivity? = nil) -> [TranscriptionEvent] {
        process(text: text, tokens: tokens, clock: .infinity, flush: true, speakers: speakers)
    }

    /// Stream time from which words are still un-finalized; diarizer output before it is not needed.
    var pendingStart: TimeInterval { lastFinalizedEnd }

    // MARK: - Pipeline

    private mutating func process(
        text: String, tokens: [RecognizedToken], clock: TimeInterval, flush: Bool, speakers: SpeakerActivity?
    ) -> [TranscriptionEvent] {
        builder.append(tokens)
        let textWords = text.split(whereSeparator: \.isWhitespace).map(String.init)
        resynchronize(with: textWords)

        var events: [TranscriptionEvent] = []
        while true {
            let pending = pendingWords(textWords)
            guard !pending.isEmpty else { break }
            guard let cut = boundary(in: pending, clock: clock, flush: flush, speakers: speakers) else {
                emitVolatile(pending, into: &events)
                break
            }
            events.append(.final(segment(pending[..<cut], id: volatileID, isFinal: true)))
            advance(past: cut, of: pending, textWords: textWords)
            volatileID = makeID()
            lastVolatile = nil
        }
        return events
    }

    private mutating func emitVolatile(_ pending: [TimedWord], into events: inout [TranscriptionEvent]) {
        let segment = segment(pending[...], id: volatileID, isFinal: false)
        if let last = lastVolatile, last.text == segment.text, last.end == segment.end { return }
        lastVolatile = (segment.text, segment.end)
        events.append(.volatile(segment))
    }

    private func segment(_ words: ArraySlice<TimedWord>, id: UUID, isFinal: Bool) -> TranscriptSegment {
        let start = (words.first?.start ?? 0) + timeOffset
        let end = max(start, (words.last?.end ?? 0) + timeOffset)
        return TranscriptSegment(
            id: id,
            text: words.map(\.text).joined(separator: " "),
            start: start,
            end: end,
            isFinal: isFinal
        )
    }

    // MARK: - Boundaries

    /// How many leading words of `pending` should be finalized now, or nil to keep waiting.
    private func boundary(in pending: [TimedWord], clock: TimeInterval, flush: Bool, speakers: SpeakerActivity?) -> Int? {
        guard let cut = timingBoundary(in: pending, clock: clock, flush: flush) else { return nil }
        guard let speakers else { return cut }
        // Wait for the diarizer to see the whole segment, unless it has fallen far behind.
        if !flush, speakers.through < pending[cut - 1].end, clock - pending[cut - 1].end < config.maxSpeakerWait {
            return nil
        }
        return speakerChange(in: pending[..<cut], speakers: speakers) ?? cut
    }

    /// The first word index at which a different speaker takes over for a sustained stretch.
    private func speakerChange(in words: ArraySlice<TimedWord>, speakers: SpeakerActivity) -> Int? {
        struct Run {
            var speaker: Int?
            var first: Int
            var start: TimeInterval
            var end: TimeInterval
        }
        var runs: [Run] = []
        for (offset, word) in words.enumerated() {
            let speaker = speakers.dominantSpeaker(in: word.start...max(word.start, word.end))
            if var last = runs.last, speaker == nil || speaker == last.speaker {
                last.end = word.end
                runs[runs.count - 1] = last
            } else {
                runs.append(Run(speaker: speaker, first: offset, start: word.start, end: word.end))
            }
        }
        // Fold runs too short to be a real turn into a neighbor, then merge equal neighbors.
        var settled: [Run] = []
        for run in runs {
            guard var last = settled.last else {
                settled.append(run)
                continue
            }
            if last.speaker == nil {
                last.speaker = run.speaker      // words before any diarized speech join the next speaker
                last.end = run.end
                settled[settled.count - 1] = last
            } else if run.speaker == nil || run.speaker == last.speaker || run.end - run.start < config.minSpeakerRun {
                last.end = run.end
                settled[settled.count - 1] = last
            } else {
                settled.append(run)
            }
        }
        while settled.count > 1, settled[0].end - settled[0].start < config.minSpeakerRun {
            settled[1].first = settled[0].first
            settled[1].start = settled[0].start
            settled.removeFirst()
        }
        guard settled.count > 1 else { return nil }
        return settled[1].first
    }

    /// Pause / punctuation / length rules only.
    private func timingBoundary(in pending: [TimedWord], clock: TimeInterval, flush: Bool) -> Int? {
        var sentenceCut: Int?
        for index in pending.indices {
            let word = pending[index]
            let count = index + 1
            let gap: TimeInterval
            if count < pending.count {
                gap = pending[count].start - word.end
            } else {
                gap = flush ? .infinity : clock - word.end
            }
            if gap >= config.gapBreak { return count }
            if Self.endsSentence(word.text) {
                if gap >= config.sentencePause || count >= config.softSentenceWords { return count }
                sentenceCut = count
            }
            if count >= config.maxWords || word.end - pending[0].start > config.maxDuration {
                return forcedCut(in: pending, upTo: count, sentenceCut: sentenceCut)
            }
        }
        return flush ? pending.count : nil
    }

    /// Where to cut an over-long segment: a sentence end if one was seen, else the longest pause,
    /// else right here.
    private func forcedCut(in pending: [TimedWord], upTo count: Int, sentenceCut: Int?) -> Int {
        if let sentenceCut, sentenceCut >= config.minForcedCutWords { return sentenceCut }
        var best: (cut: Int, gap: TimeInterval)?
        let lowest = min(config.minForcedCutWords, count)
        for cut in lowest..<count {
            let gap = pending[cut].start - pending[cut - 1].end
            if gap > 0, best == nil || gap >= best!.gap { best = (cut, gap) }
        }
        return best?.cut ?? count
    }

    static func endsSentence(_ word: String) -> Bool {
        var core = Substring(word)
        while let last = core.last, "\"'\u{201D}\u{2019})]}".contains(last) { core = core.dropLast() }
        guard let last = core.last, ".?!\u{2026}".contains(last) else { return false }
        if last != "." { return true }
        let stem = core.dropLast().lowercased()
        if stem.isEmpty { return true }
        if stem.allSatisfy(\.isNumber) { return false }                       // list numbering: "3."
        let parts = stem.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count > 1, parts.allSatisfy({ $0.count == 1 }) { return false }  // "e.g." "U.S."
        return !Self.abbreviations.contains(stem + ".")
    }

    private static let abbreviations: Set<String> = [
        "dr.", "mr.", "mrs.", "ms.", "prof.", "vs.", "fig.", "eq.", "cf.", "approx.", "no.", "st.", "sec.", "ch.",
    ]

    // MARK: - Alignment of text words with timed tokens

    /// The un-finalized words of `textWords` with times. Text is authoritative for content; tokens
    /// supply time. Both lists agree word-for-word unless vocabulary boosting rewrote text.
    private func pendingWords(_ textWords: [String]) -> [TimedWord] {
        guard textCursor < textWords.count else { return [] }
        let texts = Array(textWords[textCursor...])
        let timed = builder.words[min(tokenCursor, builder.words.count)...]
        let spans = Self.align(texts, to: timed, fallback: lastFinalizedEnd)
        return zip(texts, spans).map { TimedWord(text: $0, start: $1.start, end: $1.end) }
    }

    private static func normalized(_ word: String) -> String {
        word.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    static func align(
        _ texts: [String], to timed: ArraySlice<TimedWord>, fallback: TimeInterval
    ) -> [(start: TimeInterval, end: TimeInterval)] {
        guard !timed.isEmpty else { return texts.map { _ in (fallback, fallback) } }
        let words = Array(timed)
        if texts.count == words.count { return words.map { ($0.start, $0.end) } }

        // Greedy monotone matching: each text word claims the next token word with the same letters
        // within a small look-ahead. Unmatched words are interpolated between their neighbors.
        var matched = [Int?](repeating: nil, count: texts.count)
        var next = 0
        for (index, text) in texts.enumerated() {
            let key = normalized(text)
            guard !key.isEmpty else { continue }
            let limit = min(next + 6, words.count)
            if let hit = (next..<limit).first(where: { normalized(words[$0].text) == key }) {
                matched[index] = hit
                next = hit + 1
            }
        }

        var spans = [(start: TimeInterval, end: TimeInterval)](repeating: (0, 0), count: texts.count)
        var index = 0
        while index < texts.count {
            if let hit = matched[index] {
                spans[index] = (words[hit].start, words[hit].end)
                index += 1
                continue
            }
            var runEnd = index
            while runEnd < texts.count, matched[runEnd] == nil { runEnd += 1 }
            let lower = index > 0 ? spans[index - 1].end : words[0].start
            let upper = runEnd < texts.count ? words[matched[runEnd]!].start : max(lower, words[words.count - 1].end)
            let step = (upper - lower) / Double(runEnd - index)
            for slot in index..<runEnd {
                let start = lower + step * Double(slot - index)
                spans[slot] = (start, start + step)
            }
            index = runEnd
        }
        return spans
    }

    // MARK: - Cursors

    private mutating func advance(past cut: Int, of pending: [TimedWord], textWords: [String]) {
        lastFinalizedEnd = pending[cut - 1].end
        if cut < pending.count {
            let boundary = pending[cut].start - 1e-6
            while tokenCursor < builder.words.count, builder.words[tokenCursor].start < boundary { tokenCursor += 1 }
        } else {
            tokenCursor = builder.words.count
        }
        textCursor += cut
        recentFinalized = textWords[..<textCursor].suffix(Self.tailLength).map(Self.normalized)
    }

    private static let tailLength = 4

    /// After a text revision that reached into finalized text, find where the finalized part now
    /// ends by matching its last words (falling back to fewer words when the revision touched them
    /// too); the segments already emitted stay as they are.
    private mutating func resynchronize(with textWords: [String]) {
        guard textCursor > 0 else { return }
        func tailMatches(at position: Int, length: Int) -> Bool {
            guard position >= length, position <= textWords.count else { return false }
            return textWords[(position - length)..<position].map(Self.normalized) == recentFinalized.suffix(length)
        }
        if tailMatches(at: textCursor, length: recentFinalized.count) { return }
        let window = max(1, textCursor - Self.resyncRadius)...(textCursor + Self.resyncRadius)
        for length in stride(from: recentFinalized.count, through: 1, by: -1) {
            let candidates = window.filter { tailMatches(at: $0, length: length) }
            if let best = candidates.min(by: { abs($0 - textCursor) < abs($1 - textCursor) }) {
                textCursor = best
                return
            }
        }
        textCursor = min(textCursor, textWords.count)
    }

    private static let resyncRadius = 20
}
