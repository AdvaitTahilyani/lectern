import Foundation
import LecternCore

/// Scripted `LectureIntelligence`: follows `DemoScript` beats to emit evolving takeaways, slide
/// changes, quiz questions and streamed answers with citations, with realistic latencies.
actor DemoBrain: LectureIntelligence {
    nonisolated let updates: AsyncStream<BrainUpdate>
    private let continuation: AsyncStream<BrainUpdate>.Continuation

    private let script: DemoScript
    private let speed: Double
    private var quizSettings: QuizSettings
    private var takeaways: [Takeaway]
    private var quizHistory: [QuizRecord]
    private var sentenceLookup: [String: (beat: Int, sentenceIndex: Int)] = [:]
    private var ingestedInBeat: [Int: Int] = [:]
    private var settledBeats: Set<Int> = []
    private var liveBeat: Int?
    private var sessionTime: TimeInterval = 0
    private var lastQuizAt: TimeInterval = -.infinity
    private var pendingQuizBeat: Int?
    private var activity: BrainActivity = .idle
    private var beatTimes: [Int: TimeInterval] = [:]
    private var backtrackOffered = false
    private var speakers: [UUID: SpeakerRole] = [:]

    init(context: BrainContext, settings: AppSettings, speed: Double = 1) {
        let (stream, continuation) = AsyncStream<BrainUpdate>.makeStream()
        updates = stream
        self.continuation = continuation
        self.script = .compilers
        self.speed = max(0.1, speed)
        quizSettings = settings.quiz
        takeaways = context.takeaways
        quizHistory = context.quizHistory
        let beats = script.beats
        var lookup: [String: (beat: Int, sentenceIndex: Int)] = [:]
        for (b, beat) in beats.enumerated() {
            for (s, line) in beat.sentences.enumerated() {
                let text = line.hasPrefix(DemoScript.audienceMarker) ? String(line.dropFirst(DemoScript.audienceMarker.count)) : line
                lookup[text] = (b, s)
            }
        }
        sentenceLookup = lookup
        settledBeats = Set(context.takeaways.filter { !$0.isLive }.compactMap { t in beats.firstIndex { $0.title == t.title } })
    }

    // MARK: LectureIntelligence

    nonisolated func ingest(_ segment: TranscriptSegment) {
        Task { await self.handle(segment) }
    }

    func finish() async {
        setActivity(.summarizing)
        try? await Task.sleep(for: .seconds(1.2 / speed))
        if let live = liveBeat { settle(beat: live, at: sessionTime) }
        setActivity(.idle)
    }

    func expand(takeawayID: UUID) async throws -> TakeawayDetail {
        setActivity(.expanding(takeawayID: takeawayID))
        defer { setActivity(.idle) }
        try await Task.sleep(for: .seconds(0.9 / speed))
        guard let t = takeaways.first(where: { $0.id == takeawayID }),
              let beat = script.beats.first(where: { $0.title == t.title }) else {
            throw LLMError.invalidResponse("Unknown takeaway")
        }
        return beat.detail
    }

    func makeQuestion(followUpOf: QuizQuestion?) async throws -> QuizQuestion {
        setActivity(.writingQuestion)
        defer { setActivity(.idle) }
        try await Task.sleep(for: .seconds(1.4 / speed))
        if let followUpOf, let beat = script.beats.first(where: { $0.quiz?.question.concept == followUpOf.concept }), let quiz = beat.quiz {
            var q = quiz.followUp
            q.id = UUID()
            q.followUpOf = followUpOf.id
            return q
        }
        let asked = Set(quizHistory.map(\.question.prompt))
        let candidates = script.beats.enumerated()
            .filter { settledBeats.contains($0.offset) }
            .compactMap { $0.element.quiz?.question }
            .filter { !asked.contains($0.prompt) }
        guard var q = candidates.first ?? script.beats.compactMap({ $0.quiz?.question }).first else {
            throw LLMError.invalidResponse("No question available yet")
        }
        q.id = UUID()
        return q
    }

    func grade(_ question: QuizQuestion, answer: String) async throws -> QuizGrade {
        setActivity(.grading)
        defer { setActivity(.idle) }
        try await Task.sleep(for: .seconds(0.7 / speed))
        let beat = script.beats.first { $0.quiz?.question.prompt == question.prompt || $0.quiz?.followUp.prompt == question.prompt }
        let slides = question.sourceSlides.map(Citation.slide)
        let timeCitation: [Citation] = question.sourceStart.map { [Citation.time($0)] } ?? []
        switch question.kind {
        case .multipleChoice(let options, let correctIndex):
            let chosen = Int(answer) ?? -1
            if chosen == correctIndex {
                return QuizGrade(isCorrect: true, feedback: "Nice — \(options[correctIndex].lowercasedFirst) is exactly it.", citations: slides)
            }
            let explanation = beat?.summary ?? "The correct answer is “\(options[correctIndex])”."
            return QuizGrade(isCorrect: false, feedback: "Not quite. \(explanation)", citations: slides + timeCitation)
        case .shortAnswer(let reference):
            let a = answer.lowercased()
            let keywords = ["follow", "legal", "after", "empty", "next token", "ε", "epsilon"]
            let hits = keywords.filter { a.contains($0) }.count
            if hits >= 2 {
                return QuizGrade(isCorrect: true, feedback: "That's the idea — \(reference.lowercasedFirst)", citations: slides)
            }
            return QuizGrade(isCorrect: false, feedback: reference + " The parser can only expand A to ε when the lookahead is in FOLLOW(A).", citations: slides + timeCitation)
        }
    }

    nonisolated func record(_ record: QuizRecord) {
        Task { await self.store(record) }
    }

    nonisolated func ask(_ question: String, history: [ChatMessage]) -> AsyncThrowingStream<AskEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream<AskEvent, Error>.makeStream()
        let task = Task {
            await self.answer(question, into: continuation)
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    nonisolated func update(quiz: QuizSettings, summaryIntervalSeconds: Double) {
        Task { await self.apply(quiz: quiz) }
    }

    nonisolated func tick(sessionTime: TimeInterval) {
        Task { await self.advanceClock(sessionTime) }
    }

    func recap(from: TimeInterval, to: TimeInterval) async throws -> Recap {
        setActivity(.recapping)
        defer { setActivity(.idle) }
        try await Task.sleep(for: .seconds(1.6 / speed))
        try Task.checkCancellation()
        return script.recap(from: from, to: to, beatTimes: beatTimes)
    }

    func lectureSummary() async throws -> LectureSummary {
        setActivity(.summarizing)
        defer { setActivity(.idle) }
        try await Task.sleep(for: .seconds(2.4 / speed))
        guard !takeaways.isEmpty else { throw LLMError.invalidResponse("Nothing to summarize yet") }
        return script.lectureSummary(quiz: quizHistory)
    }

    func waitUntilIdle() async {
        while activity != .idle { try? await Task.sleep(for: .milliseconds(100)) }
    }

    nonisolated func setCurrentSlide(_ page: Int) {
        Task { await self.userChoseSlide(page) }
    }

    /// The demo script already follows its own deck; a deck added mid-demo changes nothing.
    func attachDeck(_ deck: SlideDeck, slides: (any SlideSearching)?) async {}

    private func userChoseSlide(_ page: Int) {
        if backtrackOffered { continuation.yield(.backtrackSuggestion(nil)) }
    }

    nonisolated func applySpeakers(_ labels: [UUID: SpeakerRole]) {
        Task { await self.merge(speakers: labels) }
    }

    private func merge(speakers labels: [UUID: SpeakerRole]) {
        speakers.merge(labels) { $1 }
    }

    // MARK: - Internals

    private func store(_ record: QuizRecord) {
        if let i = quizHistory.firstIndex(where: { $0.id == record.id }) { quizHistory[i] = record } else { quizHistory.append(record) }
    }

    private func apply(quiz: QuizSettings) { quizSettings = quiz }

    private func advanceClock(_ t: TimeInterval) {
        sessionTime = t
        offerQuizIfDue()
    }

    private func setActivity(_ a: BrainActivity) {
        guard activity != a else { return }
        activity = a
        continuation.yield(.activity(a))
    }

    private func handle(_ segment: TranscriptSegment) async {
        guard let (beatIndex, sentenceIndex) = sentenceLookup[segment.text] else { return }
        let beat = script.beats[beatIndex]
        // Slide detection follows the beat's slide, one sentence in (the professor advances first).
        if sentenceIndex == 0 {
            beatTimes[beatIndex] = segment.start
            continuation.yield(.currentSlide(beat.slide))
            if let previous = liveBeat, previous != beatIndex { settle(beat: previous, at: segment.start) }
        } else if sentenceIndex == beat.sentences.count / 2, beat.slidePages.count > 1 {
            continuation.yield(.currentSlide(beat.slidePages.last ?? beat.slide))
        }
        // The lecturer refers back to FIRST sets while on FOLLOW: offer (never force) a jump back.
        if beatIndex == 4, sentenceIndex == 3, !backtrackOffered {
            backtrackOffered = true
            continuation.yield(.backtrackSuggestion(8))
        } else if beatIndex == 5, sentenceIndex == 0, backtrackOffered {
            continuation.yield(.backtrackSuggestion(nil))
        }
        ingestedInBeat[beatIndex, default: 0] += 1
        let count = ingestedInBeat[beatIndex] ?? 0
        guard !settledBeats.contains(beatIndex) else { return }

        // Refine the live takeaway on the 1st sentence, then every second sentence.
        let refinementIndex = (count - 1) / 2
        guard count == 1 || count % 2 == 1 else { return }
        setActivity(.summarizing)
        try? await Task.sleep(for: .seconds(Double.random(in: 1.4...2.4) / speed))
        let refinement = beat.refinements[min(refinementIndex, beat.refinements.count - 1)]
        let start = takeaways.first(where: { $0.isLive })?.start ?? segment.start
        var live = Takeaway(title: refinement.title, summary: refinement.summary, start: start, end: segment.end, slidePages: [beat.slide], isLive: true)
        if let existing = takeaways.first(where: { $0.isLive }) { live.id = existing.id }
        upsertLive(live)
        liveBeat = beatIndex
        setActivity(.idle)
    }

    private func upsertLive(_ live: Takeaway) {
        if let i = takeaways.firstIndex(where: { $0.isLive }) { takeaways[i] = live } else { takeaways.append(live) }
        continuation.yield(.takeaways(takeaways))
    }

    private func settle(beat index: Int, at time: TimeInterval) {
        guard !settledBeats.contains(index) else { return }
        let beat = script.beats[index]
        settledBeats.insert(index)
        var settled = Takeaway(title: beat.title, summary: beat.summary, detail: beat.detail, start: 0, end: time, slidePages: beat.slidePages, isLive: false)
        if let i = takeaways.firstIndex(where: { $0.isLive }) {
            settled.id = takeaways[i].id
            settled.start = takeaways[i].start
            takeaways[i] = settled
        } else {
            settled.start = max(0, time - 40)
            takeaways.append(settled)
        }
        if liveBeat == index { liveBeat = nil }
        continuation.yield(.takeaways(takeaways))
        if beat.quiz != nil { pendingQuizBeat = index }
        offerQuizIfDue()
    }

    /// Quiz gating: a question is offered only after a beat with a question settles, at least 60 s
    /// (scaled) after the previous one, and while quizzes are enabled.
    private func offerQuizIfDue() {
        guard quizSettings.enabled, let beatIndex = pendingQuizBeat, let quiz = script.beats[beatIndex].quiz else { return }
        let minGap = 60.0 / speed
        guard sessionTime - lastQuizAt >= minGap else { return }
        let kindAllowed: Bool
        switch quiz.question.kind {
        case .multipleChoice: kindAllowed = quizSettings.allowMultipleChoice
        case .shortAnswer: kindAllowed = quizSettings.allowShortAnswer
        }
        guard kindAllowed else { pendingQuizBeat = nil; return }
        pendingQuizBeat = nil
        lastQuizAt = sessionTime
        var q = quiz.question
        q.id = UUID()
        if let t = takeaways.first(where: { $0.title == script.beats[beatIndex].title }) {
            q.sourceStart = t.start
            q.sourceEnd = t.end
        }
        Task {
            setActivity(.writingQuestion)
            try? await Task.sleep(for: .seconds(1.8 / speed))
            setActivity(.idle)
            continuation.yield(.quizReady(q))
        }
    }

    private func answer(_ question: String, into continuation: AsyncThrowingStream<AskEvent, Error>.Continuation) async {
        setActivity(.answering)
        defer { setActivity(.idle) }
        let currentSlide = takeaways.last?.slidePages.last
        let text = script.answer(for: question, sessionTime: sessionTime, currentSlide: currentSlide)
        do {
            try await Task.sleep(for: .seconds(0.8 / speed))
            var emitted = ""
            for token in Self.tokens(of: text) {
                try Task.checkCancellation()
                emitted += token
                continuation.yield(.delta(token))
                try await Task.sleep(for: .milliseconds(Int(Double.random(in: 18...55) / speed)))
            }
            let message = ChatMessage(role: .assistant, text: emitted, citations: CitationParser.citations(in: emitted))
            continuation.yield(.done(message))
            continuation.finish()
        } catch {
            continuation.finish(throwing: LLMError.cancelled)
        }
    }

    /// Splits text into word-ish tokens, keeping whitespace attached so re-joining is lossless.
    private static func tokens(of text: String) -> [String] {
        var result: [String] = []
        var current = ""
        for ch in text {
            current.append(ch)
            if ch == " " || ch == "\n" {
                result.append(current)
                current = ""
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}

nonisolated private extension String {
    var lowercasedFirst: String {
        guard let f = first else { return self }
        return f.lowercased() + dropFirst()
    }
}
