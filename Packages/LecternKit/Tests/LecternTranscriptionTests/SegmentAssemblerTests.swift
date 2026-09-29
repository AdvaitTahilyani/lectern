import Foundation
import LecternCore
import Testing
@testable import LecternTranscription

@Suite("SegmentAssembler")
struct SegmentAssemblerTests {
    @Test func growingTextEmitsVolatileWithStableID() {
        var driver = StreamDriver()
        driver.stream(Script.words("an LL(1) grammar lets the parser choose"), step: 2)
        #expect(driver.finals.isEmpty)
        let volatiles = driver.volatiles
        #expect(volatiles.count == 4)
        #expect(Set(volatiles.map(\.id)).count == 1)
        #expect(volatiles.map(\.text) == ["an LL(1)", "an LL(1) grammar lets", "an LL(1) grammar lets the parser", "an LL(1) grammar lets the parser choose"])
        #expect(volatiles.allSatisfy { !$0.isFinal })
        #expect(volatiles.last?.start == 0)
    }

    @Test func identicalUpdatesDoNotRepeatVolatile() {
        var driver = StreamDriver()
        let words = Script.words("hello there everyone")
        driver.push(words)
        driver.advance(to: 1.0)
        driver.advance(to: 1.1)
        #expect(driver.volatiles.count == 1)
    }

    @Test func sentenceEndFollowedByPauseFinalizes() {
        var driver = StreamDriver()
        let first = Script.words("we compute the FIRST set.")
        let second = Script.words("Then the FOLLOW set", start: Script.resume(after: first, pause: 0.6))
        driver.push(first)
        #expect(driver.finals.isEmpty)               // no pause seen yet
        driver.push(second)
        #expect(driver.finals.map(\.text) == ["we compute the FIRST set."])
        #expect(driver.volatiles.last?.text == "Then the FOLLOW set")
    }

    @Test func finalReusesVolatileIDAndTailGetsNewOne() {
        var driver = StreamDriver()
        let first = Script.words("one two three.")
        driver.push(first)
        let volatileID = driver.volatiles.last?.id
        driver.push(Script.words("four five", start: Script.resume(after: first, pause: 0.7)))
        let final = try! #require(driver.finals.first)
        #expect(final.id == volatileID)
        #expect(final.isFinal)
        let tail = try! #require(driver.volatiles.last)
        #expect(tail.id != final.id)
        #expect(tail.text == "four five")
    }

    @Test func sentenceEndWithoutPauseKeepsRunning() {
        var driver = StreamDriver()
        // Speaker barely pauses between sentences: one segment until it grows long.
        driver.stream(Script.words("first sentence here. second sentence follows immediately.", gap: 0.05))
        #expect(driver.finals.isEmpty)
        #expect(driver.volatiles.last?.text == "first sentence here. second sentence follows immediately.")
    }

    @Test func longSegmentBreaksAtSentenceEndWithoutPause() {
        var driver = StreamDriver()
        let sentence = "this is a fairly long explanatory sentence about the parse table construction that keeps going for a while longer than usual."
        let words = Script.words(sentence + " " + sentence)
        driver.stream(words)
        #expect(!driver.finals.isEmpty)
        #expect(driver.finals[0].text.hasSuffix("usual."))
    }

    @Test func silenceGapWithoutPunctuationFinalizes() {
        var driver = StreamDriver()
        let first = Script.words("so if the nonterminal derives epsilon")
        driver.push(first)
        driver.push(Script.words("then we look at follow", start: Script.resume(after: first, pause: 0.9)))
        #expect(driver.finals.map(\.text) == ["so if the nonterminal derives epsilon"])
    }

    @Test func gapShorterThanThresholdDoesNotSplit() {
        var driver = StreamDriver()
        let first = Script.words("so if the nonterminal derives epsilon")
        driver.push(first)
        driver.push(Script.words("then we look at follow", start: Script.resume(after: first, pause: 0.5)))
        #expect(driver.finals.isEmpty)
    }

    @Test func trailingSilenceFinalizesViaDecodeClock() {
        var driver = StreamDriver()
        let words = Script.words("thanks everyone see you next week")
        driver.push(words)
        driver.advance(to: words.last!.end + 0.5)
        #expect(driver.finals.isEmpty)
        driver.advance(to: words.last!.end + 0.9)
        #expect(driver.finals.map(\.text) == ["thanks everyone see you next week"])
    }

    @Test func trailingSentenceEndFinalizesAfterShortSilence() {
        var driver = StreamDriver()
        let words = Script.words("that is the whole algorithm.")
        driver.push(words)
        driver.advance(to: words.last!.end + 0.2)
        #expect(driver.finals.isEmpty)
        driver.advance(to: words.last!.end + 0.45)
        #expect(driver.finals.count == 1)
        #expect(driver.volatiles.last?.text == "that is the whole algorithm.")   // last volatile before it finalized
    }

    @Test func finishFlushesTailAsFinal() {
        var driver = StreamDriver()
        driver.stream(Script.words("and that is why lookahead matters"))
        driver.finish()
        #expect(driver.finals.map(\.text) == ["and that is why lookahead matters"])
        #expect(driver.finals[0].id == driver.volatiles.last?.id)
    }

    @Test func finishWithNothingPendingEmitsNothing() {
        var driver = StreamDriver()
        driver.finish()
        #expect(driver.events.isEmpty)
    }

    @Test func runOnSpeechIsCutAtWordLimit() {
        var driver = StreamDriver()
        let words = Script.words(Array(repeating: "and then", count: 75).joined(separator: " "), wordDuration: 0.12, gap: 0.02)
        driver.stream(words, step: 4)
        driver.finish()
        let finals = driver.finals
        #expect(finals.count >= 3)
        #expect(finals.allSatisfy { $0.text.split(separator: " ").count <= 60 })
        #expect(finals.map(\.text).joined(separator: " ") == driver.cumulativeText)
    }

    @Test func slowSpeechIsCutAtDurationLimit() {
        var driver = StreamDriver()
        // 1 word / 1.2 s: 30 words = 36 s, never a pause and no punctuation.
        let words = Script.words(Array(repeating: "well", count: 30).joined(separator: " "), wordDuration: 1.0, gap: 0.2)
        driver.stream(words, step: 2)
        driver.finish()
        #expect(driver.finals.count >= 2)
        for segment in driver.finals { #expect(segment.end - segment.start <= 26) }
        #expect(driver.finals.map(\.text).joined(separator: " ") == driver.cumulativeText)
    }

    @Test func forcedCutPrefersLongestPause() {
        var driver = StreamDriver()
        var words = Script.words(Array(repeating: "alpha", count: 70).joined(separator: " "), wordDuration: 0.1, gap: 0.03)
        // Insert a 0.6 s (sub-threshold) hesitation after word 40.
        for index in 40..<words.count {
            words[index].start += 0.6
            words[index].end += 0.6
        }
        driver.stream(words, step: 5)
        #expect(driver.finals.first?.text.split(separator: " ").count == 40)
    }

    @Test func splitSubwordTokensAreStitched() {
        var driver = StreamDriver()
        driver.stream(Script.words("Parakeet transcribes lectures nonterminal epsilon"), step: 2, split: true)
        #expect(driver.volatiles.last?.text == "Parakeet transcribes lectures nonterminal epsilon")
        #expect(driver.volatiles.last?.start == 0)
    }

    @Test func wordSplitAcrossUpdatesIsStitched() {
        var driver = StreamDriver()
        // "Parakeet" arrives as " Para" in one update and "keet" in the next.
        let assembler = driver.assembler
        var copy = assembler
        _ = copy.update(text: "Para", tokens: [RecognizedToken(text: " Para", start: 0, end: 0.2)], decodedThrough: 0.3)
        let events = copy.update(text: "Parakeet works", tokens: [
            RecognizedToken(text: "keet", start: 0.2, end: 0.4),
            RecognizedToken(text: " works", start: 0.5, end: 0.8),
        ], decodedThrough: 0.9)
        guard case .volatile(let segment) = try! #require(events.first) else { Issue.record("expected volatile"); return }
        #expect(segment.text == "Parakeet works")
        #expect(segment.start == 0)
        #expect(segment.end == 0.8)
        driver.assembler = copy
    }

    @Test func timeOffsetShiftsAllTimestamps() {
        var driver = StreamDriver(assembler: SegmentAssembler(timeOffset: 100))
        let first = Script.words("hello world.", start: 2)
        driver.push(first)
        driver.push(Script.words("next", start: Script.resume(after: first, pause: 1)))
        let final = try! #require(driver.finals.first)
        #expect(final.start == 102)
        #expect(abs(final.end - 102.65) < 1e-9)
    }

    @Test func timestampsFollowWordTimes() {
        var driver = StreamDriver()
        let words = Script.words("alpha beta gamma delta.", start: 5, wordDuration: 0.5, gap: 0.1)
        driver.push(words)
        driver.finish()
        let final = try! #require(driver.finals.first)
        #expect(final.start == 5)
        #expect(abs(final.end - (5 + 3 * 0.6 + 0.5)) < 1e-9)
    }

    @Test func abbreviationsAreNotSentenceEnds() {
        for word in ["e.g.", "i.e.", "U.S.", "Dr.", "vs.", "3.", "fig."] {
            #expect(!SegmentAssembler.endsSentence(word), "\(word) should not end a sentence")
        }
        for word in ["done.", "really?", "wow!", "(finished.)", "\"quoted.\"", "x.", "ok\u{2026}"] {
            #expect(SegmentAssembler.endsSentence(word), "\(word) should end a sentence")
        }
    }

    // MARK: Revisions (vocabulary boosting rewrites text that is not yet finalized)

    @Test func tailRewriteWithDifferentWordCountKeepsTimesAligned() {
        var assembler = SegmentAssembler()
        let words = Script.words("the parser needs one token of look ahead to decide")
        _ = assembler.update(
            text: words.map(\.text).joined(separator: " "), tokens: Script.tokens(words), decodedThrough: words.last!.end
        )
        // Boosting merges "look ahead" into "lookahead": one word fewer than the token stream.
        let events = assembler.update(
            text: "the parser needs one token of lookahead to decide", tokens: [], decodedThrough: words.last!.end
        )
        guard case .volatile(let segment) = try! #require(events.first) else { Issue.record("expected volatile"); return }
        #expect(segment.text == "the parser needs one token of lookahead to decide")
        #expect(segment.start == words.first!.start)
        #expect(abs(segment.end - words.last!.end) < 1e-9)
    }

    @Test func revisionInsideFinalizedTextDoesNotDuplicateOrDropLaterWords() {
        var assembler = SegmentAssembler()
        let first = Script.words("we call this an L L one grammar.")
        let second = Script.words("Next we build the table", start: Script.resume(after: first, pause: 0.8))
        let all = first + second
        var text = all.map(\.text).joined(separator: " ")
        var events = assembler.update(text: text, tokens: Script.tokens(all), decodedThrough: second.last!.end)
        // Boosting later rewrites the already-finalized "L L one" as "LL(1)" (two words fewer).
        text = "we call this an LL(1) grammar. Next we build the table"
        let more = Script.words("today", start: second.last!.end + 0.05)
        text += " today"
        events += assembler.update(text: text, tokens: Script.tokens(more), decodedThrough: more.last!.end)

        let finals = events.compactMap { if case .final(let s) = $0 { s } else { nil } }
        #expect(finals.map(\.text) == ["we call this an L L one grammar."])   // history is not retracted
        guard case .volatile(let tail)? = events.last else { Issue.record("expected volatile"); return }
        #expect(tail.text == "Next we build the table today")
    }

    @Test func noTimingsFallsBackToLastKnownTime() {
        var assembler = SegmentAssembler()
        let events = assembler.finish(text: "text without timings", tokens: [])
        guard case .final(let segment)? = events.first else { Issue.record("expected final"); return }
        #expect(segment.text == "text without timings")
        #expect(segment.start == 0)
        #expect(segment.end == 0)
    }

    @Test func alignmentMatchesByContentAndInterpolatesTheRest() {
        let timed = Script.words("a b c d e f").map { TimedWord(text: $0.text, start: $0.start, end: $0.end) }[...]
        let spans = SegmentAssembler.align(["a", "b", "XX", "e", "f"], to: timed, fallback: 0)
        #expect(spans.count == 5)
        #expect(spans[0].start == timed[0].start)
        #expect(spans[3].start == timed[4].start)   // "e"
        #expect(spans[2].start >= spans[1].end - 1e-9 && spans[2].end <= spans[3].start + 1e-9)
    }

    // MARK: Whole-lecture behavior

    @Test func minutesOfSpeechProduceBoundedSegmentsInOrder() {
        var driver = StreamDriver(lag: 1.1)
        var time = 0.0
        var spokenSentences: [String] = []
        for index in 0..<120 {
            let sentence = "sentence number \(index) explains how the parser uses lookahead to decide."
            spokenSentences.append(sentence)
            let words = Script.words(sentence, start: time)
            driver.stream(words, step: 3)
            time = Script.resume(after: words, pause: index % 4 == 0 ? 0.7 : 0.15)
        }
        driver.finish()
        let finals = driver.finals
        #expect(finals.map(\.text).joined(separator: " ") == spokenSentences.joined(separator: " "))
        #expect(finals.allSatisfy { $0.end - $0.start <= 26 && $0.text.split(separator: " ").count <= 60 })
        #expect(zip(finals, finals.dropFirst()).allSatisfy { $0.end <= $1.start + 1e-9 })
        #expect(Set(finals.map(\.id)).count == finals.count)
    }
}
