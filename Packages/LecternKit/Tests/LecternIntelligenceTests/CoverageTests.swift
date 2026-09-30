import Foundation
import LecternCore
import Testing
@testable import LecternIntelligence

/// Nothing a student needs may fall outside every card: the opening recap, announcements, Q&A
/// after class, and the end of the lecture. Small talk may vanish.
@Suite struct CoverageTests {
    /// A 23-minute lecture shaped like the real one: correction, quiz chatter, two topics,
    /// announcements, class end, technical Q&A, small talk.
    static let script: [(seconds: TimeInterval, lines: [String])] = [
        (60, ["a correction from last lecture: the phi function goes at the first node where the paths from B to B prime converge, not at Z, so the dominance frontier decides where the phi node is placed"]),
        (240, ["okay take your time with the mini quiz", "anybody still working on it okay", "just a few more minutes"]),
        (300, ["genExpr walks the AST: for a NUM node it emits loadI into a new virtual register", "for an ID node genExpr loads the base and offset from the symbol table and emits loadAO"]),
        (120, ["the exam is written, not multiple choice, you will draw the CFG and the dominator tree", "MP2 is due Friday at midnight and the MP1 viva is scheduled next week"]),
        (300, ["mixed type expressions use a conversion table to find the result type", "both operands are converted to the result type before the operation, int plus float becomes a float add"]),
        (30, ["okay I think we can end the class for today"]),
        (200, ["Student: is there a convention for casting when the language manual is silent?", "if the manual is silent the behavior is undefined, and a verified compiler like CompCert proves the generated code simulates the semantics", "Student: so is CompCert bug free?", "it is formally verified, the proof covers the whole compiler pipeline and the register allocation"]),
        (150, ["my advisor wants the paper done", "yeah the rubik's cube thing is fun", "see you guys"]),
    ]

    static func segments() -> [TranscriptSegment] {
        var result: [TranscriptSegment] = []
        var t: TimeInterval = 0
        for (seconds, lines) in script {
            let count = Int(seconds / 10)
            for i in 0..<count {
                var text = lines[i % lines.count]
                var speaker: SpeakerRole = .lecturer
                if text.hasPrefix("Student: ") { text.removeFirst(9); speaker = .audience(index: 1) }
                result.append(TranscriptSegment(text: text, start: t, end: t + 10, isFinal: true, speaker: speaker))
                t += 10
            }
        }
        return result
    }

    /// Replies like the 26B model did in the evaluation: topics for lecture content, "admin" for
    /// everything else (including the recap and the Q&A).
    static func responder(_ request: LLMRequest) -> ScriptedProvider.Reply? {
        let user = request.lastUser
        func card(_ title: String, _ summary: String) -> ScriptedProvider.Reply {
            .text(#"{"title":"\#(title)","summary":"\#(summary)"}"#)
        }
        if user.contains("These opening lines of the lecture") { return card("Phi placement correction", "A phi function goes at the first node where paths from B converge, not at Z.") }
        if user.contains("announcements and course logistics") { return card("Exam format and MP2", "The exam is written, not multiple choice: draw CFGs and dominator trees. MP2 is due Friday.") }
        if user.contains("questions and answers") { return card("Casting and CompCert", "If the manual is silent, behavior is undefined; CompCert is formally verified to preserve semantics.") }
        guard let from = user.firstMatch(of: /NEW LINES: everything from \[([\d:]+)\]/).flatMap({ TimeFormat.parse(String($0.1)) }) else {
            return .text(Fixtures.segmentation("continue", title: "", summary: ""))
        }
        let newLines = user.split(separator: "\n").filter { line in
            guard let m = line.firstMatch(of: /^\[([\d:]+)\]/), let t = TimeFormat.parse(String(m.1)) else { return false }
            return t >= from
        }.joined(separator: "\n")
        let current = user.firstMatch(of: /CURRENT TOPIC[^:]*: "([^"]+)"/).map { String($0.1) }
        // Like the model: the new lines are about whatever most of them are about.
        let lines = newLines.split(separator: "\n")
        let genExpr = lines.filter { $0.contains("genExpr") }.count, mixed = lines.filter { $0.contains("conversion") || $0.contains("operands") }.count
        func admin() -> ScriptedProvider.Reply {
            .text(#"{"new_lines_about":"logistics","new_lines_kind":"admin_or_chat","action":"continue","boundary_quote":"","closed_summary":"","title":"","summary":"","slides":[]}"#)
        }
        if genExpr * 2 > lines.count {
            return current == "genExpr"
                ? .text(Fixtures.segmentation("continue", title: "genExpr", summary: "genExpr emits loadI for NUM and loadAO for ID nodes."))
                : .text(Fixtures.segmentation("new_topic", quote: "genExpr walks the AST", title: "genExpr", summary: "genExpr emits loadI for NUM and loadAO for ID nodes."))
        }
        if mixed * 2 > lines.count {
            return current == "Mixed type expressions"
                ? .text(Fixtures.segmentation("continue", title: "Mixed type expressions", summary: "A conversion table gives the result type; operands are converted first."))
                : .text(Fixtures.segmentation("new_topic", quote: "mixed type expressions use a conversion table", closed: "genExpr emits loadI for NUM and loadAO for ID nodes.",
                                              title: "Mixed type expressions", summary: "A conversion table gives the result type; operands are converted first."))
        }
        return admin()
    }

    /// Stretches of at least a minute outside every card that hold lecture content or announcements.
    static func gaps(_ brain: LectureBrain) async -> [ClosedRange<TimeInterval>] {
        let cards = await brain.timeline.takeaways.sorted { $0.start < $1.start }
        let segments = await brain.segments
        let stretch = await brain.openingStretch
        var gaps: [ClosedRange<TimeInterval>] = []
        var cursor = segments.first?.start ?? 0
        for boundary in cards.map({ ($0.start, $0.end) }) + [(segments.last!.end, segments.last!.end)] {
            if boundary.0 - cursor >= 60 {
                let uncovered = TranscriptText.segments(in: segments, from: cursor, to: boundary.0)
                let announces = uncovered.contains { $0.text.range(of: AsideStretch.announcementPattern, options: .regularExpression) != nil }
                if announces || stretch.technicalShare(uncovered) >= OpeningStretch.minTechnicalShare { gaps.append(cursor...boundary.0) }
            }
            cursor = max(cursor, boundary.1)
        }
        return gaps
    }

    @Test func everySubstantiveMinuteLandsOnACard() async throws {
        let provider = ScriptedProvider(responder: Self.responder)
        let brain = Fixtures.brain(provider, interval: 150, tuning: BrainTuning(firstUpdateSeconds: 60))
        for s in Self.segments() { await brain.ingest(s) }
        await brain.waitUntilIdle()
        await brain.finish()
        let cards = await brain.timeline.takeaways
        let titles = cards.map(\.title)
        #expect(titles.contains { $0.hasPrefix("Recap:") }, "\(titles)")
        #expect(titles.contains("genExpr"))
        #expect(titles.contains { $0.hasPrefix("Announcements:") }, "\(titles)")
        #expect(titles.contains("Mixed type expressions"))
        #expect(titles.contains { $0.hasPrefix("Q&A:") }, "\(titles)")
        let gaps = await Self.gaps(brain)
        #expect(gaps.isEmpty, "uncovered: \(gaps.map { "\(TimeFormat.clock($0.lowerBound))–\(TimeFormat.clock($0.upperBound))" })")
        // Cards are chronological and don't overlap; the last card reaches the end of the lecture.
        #expect(zip(cards, cards.dropFirst()).allSatisfy { $0.end <= $1.start + 0.5 })
        #expect(cards.last?.end == Self.segments().last?.end)
        #expect(cards.allSatisfy { !$0.isLive })
        let announcements = try #require(cards.first { $0.title.hasPrefix("Announcements:") })
        #expect(announcements.summary.contains("not multiple choice"))
        // The quiz chatter doesn't become a card of its own, and neither does the small talk.
        #expect(!titles.contains { $0.localizedCaseInsensitiveContains("rubik") || $0.localizedCaseInsensitiveContains("advisor") })
    }

    @Test func classEndIsHeardAndNamedInThePrompt() async throws {
        let provider = ScriptedProvider(responder: Self.responder)
        let brain = Fixtures.brain(provider, interval: 150, tuning: BrainTuning(firstUpdateSeconds: 60))
        for s in Self.segments() { await brain.ingest(s) }
        await brain.waitUntilIdle()
        #expect(await brain.classEndedAt == 1030)
        #expect(provider.requests.contains { $0.lastUser.contains("CLASS ENDED at [17:10]") })
        #expect(!provider.requests.filter { $0.lastUser.contains("TASK:") }.first!.lastUser.contains("CLASS ENDED"))
    }

    @Test func pureLogisticsAndSmallTalkStayOffTheCards() {
        let stretch = OpeningStretch(deck: Fixtures.deck)
        let small = Fixtures.segments(Array(repeating: "my advisor wants the paper done, the rubik's cube thing is fun", count: 15))
        #expect(AsideStretch.classify(small[...], technical: stretch) == nil)
        let logistics = Fixtures.segments(["MP2 is due Friday at midnight", "office hours move to Thursday", "okay"])
        #expect(AsideStretch.classify(logistics[...], technical: stretch) == .announcements)
        let lone = Fixtures.segments(["homework is due Friday"])
        #expect(AsideStretch.classify(lone[...], technical: stretch) == nil, "10 s is not a stretch")
        #expect(AsideStretch.endsClass(TranscriptSegment(text: "I think we can end the class for today.", start: 0, end: 1, isFinal: true)))
        #expect(!AsideStretch.endsClass(TranscriptSegment(text: "we end the loop when the stack is empty", start: 0, end: 1, isFinal: true)))
        // "due to" is not a deadline.
        #expect(Fixtures.segments(["this is due to precedence in the front end"]).allSatisfy { $0.text.range(of: AsideStretch.announcementPattern, options: .regularExpression) == nil })
    }

    @Test func finishRetriesThenGivesTheRestToTheLastCard() async throws {
        let lines = (0..<40).map { "genExpr emits loadI and loadAO part \($0)" }
        let segments = Fixtures.segments(lines)
        // First update opens the card; every later call fails.
        let provider = ScriptedProvider([.text(Fixtures.segmentation("new_topic", title: "genExpr", summary: "genExpr emits loadI."))],
                                        responder: { _ in .failure(.network("offline")) })
        let brain = Fixtures.brain(provider, interval: 60, tuning: BrainTuning(firstUpdateSeconds: 60))
        for s in segments { await brain.ingest(s) }
        await brain.waitUntilIdle()
        let before = provider.requests.count
        await brain.finish()
        #expect(provider.requests.count - before >= LectureBrain.finishAttempts)
        let cards = await brain.timeline.takeaways
        #expect(cards.count == 1 && cards[0].end == segments.last!.end && !cards[0].isLive)
    }

    @Test func concurrentFinishCallsDoNotInterleave() async throws {
        let provider = ScriptedProvider(delay: .milliseconds(20), responder: { _ in .text(Fixtures.segmentation("new_topic", title: "genExpr", summary: "s")) })
        let brain = Fixtures.brain(provider, interval: 60, tuning: BrainTuning(firstUpdateSeconds: 60))
        for s in Fixtures.segments((0..<20).map { "genExpr part \($0)" }) { await brain.ingest(s) }
        async let a: Void = brain.finish()
        async let b: Void = brain.finish()
        _ = await (a, b)
        #expect(provider.maxInFlight == 1)
        #expect(await brain.timeline.takeaways.allSatisfy { !$0.isLive })
    }

    @Test func linesAfterAnEarlyRecapCardJoinItWhenTheFirstTopicOpens() async throws {
        // The evaluation's 4:37–8:11 hole: the backstop writes the recap card while lines are still
        // being skipped; more skipped lines follow; then the first topic opens at its quote.
        let opening = Fixtures.segments(Array(repeating: "a correction from last lecture: the phi function goes at the first node where the paths from B converge, and the dominance frontier decides", count: 36))
        let answers = Fixtures.segments(Array(repeating: "for the quiz, a diamond CFG needs no phi node because the value reaching the join is the same", count: 12), start: 360)
        let lecture = Fixtures.segments(["okay so today we start LR parsing with item sets"] + Array(repeating: "an LR item is a production with a dot in it", count: 20), start: 480)
        let provider = ScriptedProvider(responder: { request in
            let user = request.lastUser
            if user.contains("These opening lines of the lecture") {
                return .text(#"{"title":"Phi placement","summary":"A phi goes at the first node where paths from B converge; a diamond CFG needs no phi."}"#)
            }
            if user.contains("we start LR parsing") && !user.contains("CURRENT TOPIC (") {
                return .text(Fixtures.segmentation("new_topic", quote: "okay so today we start LR parsing", title: "LR parsing", summary: "LR items mark progress with a dot."))
            }
            if user.contains("CURRENT TOPIC (") { return .text(Fixtures.segmentation("continue", title: "LR parsing", summary: "LR items mark progress with a dot.")) }
            return .text(#"{"new_lines_about":"quiz","new_lines_kind":"admin_or_chat","action":"continue","boundary_quote":"","closed_summary":"","title":"","summary":"","slides":[]}"#)
        })
        let brain = Fixtures.brain(provider, interval: 150, tuning: BrainTuning(firstUpdateSeconds: 60))
        for s in opening + answers + lecture { await brain.ingest(s) }
        await brain.waitUntilIdle()
        await brain.finish()
        let cards = await brain.timeline.takeaways
        #expect(cards.map(\.title) == ["Recap: Phi placement", "LR parsing"])
        #expect(cards[0].end == 480 && cards[1].start == 480, "the recap reaches the first topic: \(cards.map { ($0.start, $0.end) })")
        #expect(await Self.gaps(brain).isEmpty)
    }

    @Test func announcementCardsAreNotQuizzed() async throws {
        let brain = Fixtures.brain(ScriptedProvider(), context: Fixtures.context(transcript: Self.segments(), takeaways: [
            Takeaway(title: "genExpr", summary: "s", start: 300, end: 600, isLive: false),
            Takeaway(title: "Announcements: Exam format", summary: "s", start: 600, end: 720, isLive: false),
        ]))
        #expect(await brain.quizzableTakeaways.map(\.title) == ["genExpr"])
    }

    @Test func smallTalkTheWriterDeclinesMakesNoCard() async throws {
        // Q&A-shaped chat (questions, some technical words) that the card writer declines.
        let provider = ScriptedProvider(responder: { request in
            let user = request.lastUser
            if user.contains("questions and answers") || user.contains("announcements and course logistics") { return .text(#"{"title":"","summary":""}"#) }
            if user.contains("CURRENT TOPIC (") {
                return .text(#"{"new_lines_about":"chat","new_lines_kind":"admin_or_chat","action":"continue","boundary_quote":"","closed_summary":"","title":"","summary":"","slides":[]}"#)
            }
            return .text(Fixtures.segmentation("new_topic", title: "genExpr", summary: "genExpr emits loadI."))
        })
        let brain = Fixtures.brain(provider, interval: 150, tuning: BrainTuning(firstUpdateSeconds: 60))
        let log = UpdateLog(brain.updates)
        let lecture = Fixtures.segments((0..<30).map { "genExpr emits loadI for constants part \($0)" })
        let chat = Fixtures.segments((0..<24).map { i in i % 2 == 0 ? "did you register for the compiler class next semester?" : "yeah the virtual register thing, the parse tree, whatever" }, start: 300)
        for s in lecture + chat { await brain.ingest(s) }
        await brain.waitUntilIdle()
        await brain.finish()
        let cards = await brain.timeline.takeaways
        #expect(provider.requests.contains { $0.lastUser.contains("questions and answers") }, "the chat looked like Q&A and was offered to the writer")
        #expect(cards.map(\.title) == ["genExpr"])
        #expect(cards[0].end == chat.last!.end, "the chat stays with the last card")
        #expect(await log.errors.isEmpty)
    }
}
