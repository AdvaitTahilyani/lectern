import Darwin
import Foundation
import LecternCore
import LecternIntelligence
import LecternSlides
import LecternTranscription

/// End-to-end run of the real stack without the UI: an audio file → Parakeet (+ diarization) →
/// LectureBrain on the configured providers → SlideIndex tracking. Segments are released at
/// `speed`× their recorded time so the brain sees a live-like (or faster) stream.
///
///     Lectern -selftest pipeline -audio <wav> -slides <pdf> [-speed 4] [-minutes 30] [-report <md>]
///             [-quizzes N] [-asks "q1|q2|…"] [-recaps "0-8,30-40"]
///
/// Beyond the takeaway report it records process memory every 60 s of session time, a timed list of
/// every LLM call, and (after the lecture) graded quizzes, Ask answers and recaps. A transcript
/// sidecar (`<report>.transcript.txt`) holds what the recognizer produced, for judging the report.
nonisolated enum PipelineSelfTest {
    struct Options {
        var audio: URL
        var slides: URL?
        var speed: Double = 4
        var minutes: Double?
        var report: URL
        /// Number of quiz questions to generate at the end and answer wrongly then correctly.
        var quizzes = 0
        var asks: [String] = []
        /// Recap windows in minutes. Empty → one default window (20–27 min).
        var recaps: [ClosedRange<Double>] = []

        init?(arguments args: [String]) {
            func value(_ flag: String) -> String? {
                guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
                return args[i + 1]
            }
            guard let audio = value("-audio") else { return nil }
            self.audio = URL(fileURLWithPath: audio)
            slides = value("-slides").map { URL(fileURLWithPath: $0) }
            if let s = value("-speed").flatMap(Double.init), s > 0 { speed = s }
            minutes = value("-minutes").flatMap(Double.init)
            report = URL(fileURLWithPath: value("-report") ?? NSTemporaryDirectory() + "lectern-pipeline.md")
            quizzes = max(0, value("-quizzes").flatMap(Int.init) ?? 0)
            asks = (value("-asks") ?? "").split(separator: "|").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            recaps = (value("-recaps") ?? "").split(separator: ",").compactMap { part in
                let bounds = part.split(separator: "-").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                return bounds.count == 2 && bounds[0] < bounds[1] ? bounds[0]...bounds[1] : nil
            }
        }
    }

    // MARK: - Recording

    /// Wall-clock record of one brain activity span.
    private struct Span { var activity: BrainActivity; var start: ContinuousClock.Instant; var seconds: Double; var atSessionTime: TimeInterval }

    /// One provider call, measured at the provider boundary (so retries show up as separate calls).
    private struct LLMCall {
        var role: LLMRole
        var phase: String
        var sessionTime: TimeInterval
        var wallStart: Double
        var seconds: Double
        var firstToken: Double?
        var usage: LLMUsage?
        var promptChars: Int
        var json: Bool
        var failed: Bool
    }

    private struct MemorySample { var label: String?; var sessionTime: TimeInterval; var wall: Double; var bytes: UInt64; var coverageLag: TimeInterval }

    private actor Recorder {
        let runStart = ContinuousClock.now
        var spans: [Span] = []
        var open: (BrainActivity, ContinuousClock.Instant, TimeInterval)?
        var takeaways: [Takeaway] = []
        var slideChanges: [(TimeInterval, Int?)] = []
        var backtracks: [(TimeInterval, Int?)] = []
        var errors: [String] = []
        var quizPings: [(TimeInterval, QuizQuestion)] = []
        var sessionTime: TimeInterval = 0
        var peakFootprint: UInt64 = 0
        var phase = "feed"
        var calls: [LLMCall] = []
        var memory: [MemorySample] = []
        var nextSampleAt: TimeInterval = 60
        var segments: [TranscriptSegment] = []
        var speakers: [UUID: SpeakerRole] = [:]

        var wall: Double { (ContinuousClock.now - runStart) / .seconds(1) }

        func setPhase(_ name: String) { phase = name }

        func setTime(_ t: TimeInterval) {
            sessionTime = t
            samplePeak()
            if t >= nextSampleAt {
                sample(label: nil)
                nextSampleAt = (t / 60).rounded(.down) * 60 + 60
            }
        }

        /// A memory reading now; `label` marks phase boundaries (after the feed, after quizzes, …).
        func sample(label: String?) {
            let bytes = PipelineSelfTest.physFootprint()
            peakFootprint = max(peakFootprint, bytes)
            memory.append(MemorySample(label: label, sessionTime: sessionTime, wall: wall, bytes: bytes,
                                       coverageLag: sessionTime - (takeaways.last?.end ?? 0)))
        }

        func note(_ segment: TranscriptSegment) { segments.append(segment) }
        func note(speakers labels: [UUID: SpeakerRole]) { speakers.merge(labels) { _, new in new } }

        func beginCall() -> (session: TimeInterval, phase: String, wall: Double) { (sessionTime, phase, wall) }
        func endCall(_ call: LLMCall) { calls.append(call) }

        func record(_ update: BrainUpdate) {
            let now = ContinuousClock.now
            switch update {
            case .activity(let activity):
                if let (a, start, t) = open {
                    spans.append(Span(activity: a, start: start, seconds: (now - start) / .seconds(1), atSessionTime: t))
                    open = nil
                }
                if activity != .idle { open = (activity, now, sessionTime) }
            case .takeaways(let list): takeaways = list
            case .currentSlide(let page): slideChanges.append((sessionTime, page))
            case .backtrackSuggestion(let page): backtracks.append((sessionTime, page))
            case .error(let message): errors.append("[\(TimeFormat.clock(sessionTime))] \(message)")
            case .quizReady(let question): quizPings.append((sessionTime, question))
            }
            samplePeak()
        }

        func samplePeak() { peakFootprint = max(peakFootprint, PipelineSelfTest.physFootprint()) }
    }

    /// Wraps a provider to time every call, tagged with the run phase and session clock.
    private struct TimingProvider: LLMProvider {
        let inner: any LLMProvider
        let role: LLMRole
        let recorder: Recorder

        var kind: ProviderKind { inner.kind }
        var model: String { inner.model }

        private func call(_ begin: (session: TimeInterval, phase: String, wall: Double), _ request: LLMRequest, start: ContinuousClock.Instant,
                          firstToken: Double?, usage: LLMUsage?, failed: Bool) -> LLMCall {
            var json = false
            if case .json = request.responseFormat { json = true }
            return LLMCall(role: role, phase: begin.phase, sessionTime: begin.session, wallStart: begin.wall,
                           seconds: (ContinuousClock.now - start) / .seconds(1), firstToken: firstToken, usage: usage,
                           promptChars: request.messages.reduce(0) { $0 + $1.content.count }, json: json, failed: failed)
        }

        func complete(_ request: LLMRequest) async throws -> LLMResponse {
            let begin = await recorder.beginCall()
            let start = ContinuousClock.now
            do {
                let response = try await inner.complete(request)
                await recorder.endCall(call(begin, request, start: start, firstToken: nil, usage: response.usage, failed: false))
                Self.trace(request, response.text, at: begin.session)
                return response
            } catch {
                await recorder.endCall(call(begin, request, start: start, firstToken: nil, usage: nil, failed: true))
                throw error
            }
        }

        func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
            AsyncThrowingStream { continuation in
                let task = Task {
                    let begin = await recorder.beginCall()
                    let start = ContinuousClock.now
                    var first: Double?
                    var usage: LLMUsage?
                    do {
                        for try await event in inner.stream(request) {
                            switch event {
                            case .delta: if first == nil { first = (ContinuousClock.now - start) / .seconds(1) }
                            case .done(let u): usage = u
                            }
                            continuation.yield(event)
                        }
                        await recorder.endCall(call(begin, request, start: start, firstToken: first, usage: usage, failed: false))
                        continuation.finish()
                    } catch {
                        await recorder.endCall(call(begin, request, start: start, firstToken: first, usage: usage, failed: true))
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }

        func healthCheck() async throws { try await inner.healthCheck() }

        /// With LECTERN_PIPELINE_TRACE=<file>, appends each call's task (the prompt after its
        /// transcript) and reply, for diagnosing a run.
        private static func trace(_ request: LLMRequest, _ reply: String, at session: TimeInterval) {
            guard let path = ProcessInfo.processInfo.environment["LECTERN_PIPELINE_TRACE"],
                  let user = request.messages.last(where: { $0.role == .user })?.content else { return }
            let transcript = user.components(separatedBy: "=====").first ?? ""
            let lines = transcript.split(separator: "\n")
            let entry = "### \(TimeFormat.clock(session)) window \(lines.dropFirst().first ?? "")…\(lines.last ?? "")\n"
                + (user.components(separatedBy: "=====").dropFirst().joined(separator: "=====")) + "\nREPLY: \(reply)\n\n"
            guard let data = entry.data(using: .utf8) else { return }
            if let handle = FileHandle(forWritingAtPath: path) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                FileManager.default.createFile(atPath: path, contents: data)
            }
        }
    }

    // MARK: - Interactive trials

    private struct QuizAttempt { var label: String; var answer: String; var grade: QuizGrade?; var seconds: Double; var error: String? }
    private struct QuizTrial {
        var target: Takeaway
        var question: QuizQuestion?
        var genSeconds: Double
        var attempts: [QuizAttempt]
        var error: String?
    }
    private struct AskTrial { var question: String; var text: String; var citations: [Citation]; var seconds: Double; var firstToken: Double?; var error: String? }
    private struct RecapTrial { var from: TimeInterval; var to: TimeInterval; var recap: Recap?; var seconds: Double; var error: String? }
    private struct Interactive {
        var quizzes: [QuizTrial] = []
        var asks: [AskTrial] = []
        var recaps: [RecapTrial] = []
    }

    // MARK: - Run

    static func run(arguments: [String]) async -> Bool {
        guard let options = Options(arguments: arguments) else {
            print("[pipeline] usage: -selftest pipeline -audio <wav> [-slides <pdf>] [-speed 4] [-minutes N] [-report <md>] [-quizzes N] [-asks \"q1|q2\"] [-recaps \"0-8,30-40\"]")
            return false
        }
        let settings = StoredSettings.current()
        let clock = ContinuousClock()
        let runStart = clock.now
        let recorder = Recorder()
        var deck: SlideDeck?
        var segments = 0, lastEnd: TimeInterval = 0
        var lag = 0.0
        var interactive = Interactive()
        var failure: String?
        do {
            // Slides
            var index: (any SlideSearching)?
            if let pdf = options.slides {
                deck = try await PDFSlideIngestor().ingest(pdfAt: pdf) { _ in }
                if let deck { index = SlideIndex(deck: deck) }
                print("[pipeline] slides: \(deck?.pages.count ?? 0) pages")
            }

            // Brain
            let context = BrainContext(sessionTitle: options.audio.deletingPathExtension().lastPathComponent, courseName: nil,
                                       deck: deck, transcript: [], takeaways: [], quizHistory: [])
            let base = ProviderResolver.roleProviders(for: settings, keychain: .init())
            let timed = RoleProviders(summaries: TimingProvider(inner: base.summaries, role: .summaries, recorder: recorder),
                                      quizzes: TimingProvider(inner: base.quizzes, role: .quizzes, recorder: recorder),
                                      ask: TimingProvider(inner: base.ask, role: .ask, recorder: recorder))
            let brain = LectureBrain(context: context, providers: timed, slides: index, quiz: settings.quiz,
                                     summaryIntervalSeconds: settings.summaryIntervalSeconds)
            let consumer = Task { for await update in brain.updates { await recorder.record(update) } }
            await recorder.sample(label: "start")

            // Speech → paced ingest
            let engine = TranscriptionEngines.make(.parakeet)
            if await engine.readiness() != .ready {
                print("[pipeline] preparing speech models…")
                try await engine.prepare { _ in }
            }
            let limit = options.minutes.map { $0 * 60 }
            let feedStart = clock.now
            // `-minutes`: stop reading the file at the limit (a plain `break` would only leave the
            // switch, and the recognizer would transcribe the rest of the file).
            feed: for try await event in try await engine.transcribeFile(at: options.audio, options: TranscriptionOptions(diarize: true)) {
                switch event {
                case .final(let segment):
                    if let limit, segment.start > limit { break feed }
                    // Release the segment no earlier than its (sped-up) recorded end time.
                    let due = feedStart + .seconds(segment.end / options.speed)
                    if clock.now < due { try await clock.sleep(until: due) }
                    await recorder.setTime(segment.end)
                    await recorder.note(segment)
                    await brain.tick(sessionTime: segment.end)
                    await brain.ingest(segment)
                    segments += 1
                    lastEnd = segment.end
                    if segments % 100 == 0 { print("[pipeline] \(TimeFormat.clock(segment.end)) · \(segments) segments") }
                case .speakers(let labels):
                    await recorder.note(speakers: labels)
                    await brain.applySpeakers(labels)
                case .warning(let w): print("[pipeline] warning: \(w)")
                case .volatile, .level: break
                }
            }
            await engine.stop()
            let feedDone = clock.now
            await recorder.sample(label: "feed done")
            await recorder.setPhase("drain")
            await brain.waitUntilIdle()
            lag = (clock.now - feedDone) / .seconds(1)
            await recorder.setPhase("finish")
            await brain.finish()
            await recorder.sample(label: "finished")

            // Interactive calls at the end, timed. Each step is isolated so one failure doesn't lose the run.
            await recorder.setPhase("quiz")
            // The final `.takeaways` update reaches the recorder through the consumer task; let it land
            // so the last (just settled) card is a quiz candidate and shows as settled here.
            try await clock.sleep(for: .seconds(2))
            let settled = await recorder.takeaways
            if options.quizzes > 0 {
                interactive.quizzes = await runQuizzes(count: options.quizzes, takeaways: settled, brain: brain, settings: settings,
                                                       raw: base.quizzes, clock: clock)
            } else {
                interactive.quizzes = await runQuizzes(count: 1, takeaways: settled, brain: brain, settings: settings,
                                                       raw: base.quizzes, clock: clock, gradeAnswers: false)
            }
            await recorder.sample(label: "after quizzes")

            await recorder.setPhase("ask")
            let asks = options.asks.isEmpty ? ["What does genExpr return, and why does it allocate a new virtual register?"] : options.asks
            for question in asks {
                interactive.asks.append(await runAsk(question, brain: brain, clock: clock))
            }
            await recorder.sample(label: "after asks")

            await recorder.setPhase("recap")
            let windows = options.recaps.isEmpty ? [20.0...27.0] : options.recaps
            for window in windows {
                let from = window.lowerBound * 60, to = min(window.upperBound * 60, max(lastEnd, from + 1))
                let t0 = clock.now
                do {
                    let recap = try await brain.recap(from: from, to: to)
                    interactive.recaps.append(RecapTrial(from: from, to: to, recap: recap, seconds: (clock.now - t0) / .seconds(1), error: nil))
                } catch {
                    interactive.recaps.append(RecapTrial(from: from, to: to, recap: nil, seconds: (clock.now - t0) / .seconds(1), error: "\(error)"))
                }
            }
            await recorder.sample(label: "after recaps")
            consumer.cancel()
        } catch {
            failure = "\(error)"
            print("[pipeline] FAILED: \(error)")
        }

        // Write whatever was gathered, even after a failure.
        do {
            let total = (clock.now - runStart) / .seconds(1)
            try await writeReport(options: options, recorder: recorder, deck: deck, segments: segments, lastEnd: lastEnd, lag: lag,
                                  total: total, interactive: interactive, settings: settings, failure: failure)
            print("[pipeline] done: \(segments) segments to \(TimeFormat.clock(lastEnd)), catch-up lag \(String(format: "%.1f", lag)) s. Report: \(options.report.path)")
            return failure == nil
        } catch {
            print("[pipeline] could not write report: \(error)")
            return false
        }
    }

    // MARK: - Quizzes

    /// Generates `count` questions spread evenly across the settled takeaways. Each is answered
    /// wrongly first, then correctly (short answers: a model-written plausible wrong answer, then the
    /// question's own reference answer). Formats alternate multiple choice / short answer.
    private static func runQuizzes(count: Int, takeaways: [Takeaway], brain: LectureBrain, settings: AppSettings,
                                   raw: any LLMProvider, clock: ContinuousClock, gradeAnswers: Bool = true) async -> [QuizTrial] {
        let candidates = takeaways.filter { !$0.isLive && $0.end - $0.start >= 45 }
        guard !candidates.isEmpty else { return [] }
        let n = min(count, candidates.count)
        let chosen = Set((0..<n).map { candidates[Int((Double($0) + 0.5) * Double(candidates.count) / Double(n))].id })
        // The planner takes "the most recent never-quizzed topic", so mark every unchosen topic as skipped.
        for t in candidates where !chosen.contains(t.id) {
            let placeholder = QuizQuestion(prompt: "(placeholder)", kind: .shortAnswer(referenceAnswer: ""), concept: "", sourceStart: t.start, sourceEnd: t.end)
            await brain.record(QuizRecord(question: placeholder, outcome: .skipped, askedAt: -1))
        }
        var trials: [QuizTrial] = []
        for k in 0..<n {
            var quiz = settings.quiz
            quiz.enabled = false
            quiz.allowMultipleChoice = k % 2 == 0
            quiz.allowShortAnswer = k % 2 == 1
            await brain.update(quiz: quiz, summaryIntervalSeconds: settings.summaryIntervalSeconds)
            let t0 = clock.now
            let question: QuizQuestion
            do { question = try await brain.makeQuestion(followUpOf: nil) } catch {
                trials.append(QuizTrial(target: candidates[0], question: nil, genSeconds: (clock.now - t0) / .seconds(1), attempts: [], error: "\(error)"))
                continue
            }
            let gen = (clock.now - t0) / .seconds(1)
            let mid = ((question.sourceStart ?? 0) + (question.sourceEnd ?? 0)) / 2
            let target = candidates.first { $0.start <= mid && mid <= $0.end } ?? candidates[0]
            var trial = QuizTrial(target: target, question: question, genSeconds: gen, attempts: [], error: nil)
            guard gradeAnswers else { trials.append(trial); continue }

            var wrong: (shown: String, submitted: String)
            var right: (shown: String, submitted: String)
            switch question.kind {
            case let .multipleChoice(options, correct):
                // A wrong option needs at least two options (and a valid key).
                guard options.count >= 2, options.indices.contains(correct) else {
                    trial.error = "multiple choice with \(options.count) option(s) and answer index \(correct): not graded"
                    trials.append(trial)
                    continue
                }
                let bad = (correct + 1 + (k / 2) % (options.count - 1)) % options.count
                func letter(_ i: Int) -> String { optionLabel(i) + ") " + options[i] }
                wrong = (letter(bad), String(bad))
                right = (letter(correct), String(correct))
            case let .shortAnswer(reference):
                let text = await plausibleWrongAnswer(to: question, reference: reference, provider: raw)
                wrong = (text, text)
                right = (reference, reference)
            }
            for (label, answer) in [("wrong", wrong), ("correct", right)] {
                let t1 = clock.now
                do {
                    let grade = try await brain.grade(question, answer: answer.submitted)
                    trial.attempts.append(QuizAttempt(label: label, answer: answer.shown, grade: grade, seconds: (clock.now - t1) / .seconds(1), error: nil))
                } catch {
                    trial.attempts.append(QuizAttempt(label: label, answer: answer.shown, grade: nil, seconds: (clock.now - t1) / .seconds(1), error: "\(error)"))
                }
            }
            await brain.record(QuizRecord(question: question, answer: right.submitted, grade: trial.attempts.last?.grade,
                                          outcome: trial.attempts.last?.grade?.isCorrect == true ? .correct : .incorrect, askedAt: question.sourceEnd ?? 0))
            trials.append(trial)
        }
        return trials
    }

    /// A confident, wrong-but-plausible student answer, written by the model (not measured).
    private static func plausibleWrongAnswer(to question: QuizQuestion, reference: String, provider: any LLMProvider) async -> String {
        let request = LLMRequest(messages: [
            .system("You role-play a student who studied but holds a typical misconception. Write a short answer (one or two sentences) that sounds plausible and confident but is factually WRONG for the question. It must contradict the reference answer's key idea. Output only the answer text."),
            .user("Question: \(question.prompt)\nReference (correct) answer: \(reference)\nWrong student answer:"),
        ], maxTokens: 120, temperature: 0.8)
        let text = (try? await provider.complete(request).text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""
        return text.isEmpty ? "It is not something the compiler needs to track; it happens only at run time." : text
    }

    // MARK: - Ask

    private static func runAsk(_ question: String, brain: LectureBrain, clock: ContinuousClock) async -> AskTrial {
        let t0 = clock.now
        var first: Double?
        var text = ""
        var citations: [Citation] = []
        do {
            for try await event in await brain.ask(question, history: []) {
                switch event {
                case .delta: if first == nil { first = (clock.now - t0) / .seconds(1) }
                case .done(let message): text = message.text; citations = message.citations
                }
            }
            return AskTrial(question: question, text: text, citations: citations, seconds: (clock.now - t0) / .seconds(1), firstToken: first, error: nil)
        } catch {
            return AskTrial(question: question, text: text, citations: citations, seconds: (clock.now - t0) / .seconds(1), firstToken: first, error: "\(error)")
        }
    }

    // MARK: - Report

    private static func cell(_ text: String, limit: Int = 400) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "|", with: "\\|")
        return flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
    }

    /// "A", "B", … for the first 26 options, then "27", "28", ….
    private static func optionLabel(_ i: Int) -> String {
        i < 26 ? String(Character(UnicodeScalar(UInt8(65 + i)))) : String(i + 1)
    }

    private static func fmt(_ seconds: Double) -> String { String(format: "%.1f", seconds) }

    private static func percentile(_ sorted: [Double], _ p: Double) -> String {
        guard !sorted.isEmpty else { return "–" }
        return fmt(sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))]) + " s"
    }

    private static func stats(_ values: [Double]) -> String {
        let s = values.sorted()
        return "n=\(s.count), p50 \(percentile(s, 0.5)), p90 \(percentile(s, 0.9)), max \(s.last.map { fmt($0) + " s" } ?? "–")"
    }

    /// What a citation points at: the recognized transcript around a time, or a slide's title and text.
    private static func evidence(for citation: Citation, segments: [TranscriptSegment], deck: SlideDeck?) -> String {
        switch citation {
        case .slide(let n):
            guard let page = deck?.page(n) else { return "S\(n): no such slide" }
            return "S\(n) “\(page.title ?? "–")”: \(cell(page.text, limit: 160))"
        case .time(let t):
            let near = segments.filter { $0.end >= t - 6 && $0.start <= t + 6 }
            let body = near.isEmpty ? "no transcript there" : near.map(\.text).joined(separator: " ")
            return "T\(TimeFormat.clock(t)): \(cell(body, limit: 220))"
        }
    }

    private static func label(_ c: Citation) -> String {
        switch c {
        case .slide(let n): "S\(n)"
        case .time(let t): "T\(TimeFormat.clock(t))"
        }
    }

    private static func writeReport(options: Options, recorder: Recorder, deck: SlideDeck?, segments: Int, lastEnd: TimeInterval, lag: Double,
                                    total: Double, interactive: Interactive, settings: AppSettings, failure: String?) async throws {
        let spans = await recorder.spans
        let summaries = spans.filter { $0.activity == .summarizing }.map(\.seconds).sorted()
        let calls = await recorder.calls
        let transcript = await recorder.segments
        let memory = await recorder.memory
        var md = "# Pipeline self-test\n\n"
        if let failure { md += "**RUN FAILED**: \(failure) (partial results below)\n\n" }
        md += "- audio: `\(options.audio.lastPathComponent)` to \(TimeFormat.clock(lastEnd)) at \(options.speed)× · \(segments) segments\n"
        md += "- providers: summaries=\(settings.provider(for: .summaries).model), ask=\(settings.provider(for: .ask).model)\n"
        md += "- summary calls: \(summaries.count), latency p50 \(percentile(summaries, 0.5)), p90 \(percentile(summaries, 0.9)), max \(summaries.last.map { fmt($0) + " s" } ?? "–")\n"
        md += "- catch-up lag after the last segment: \(fmt(lag)) s · total wall time \(String(format: "%.0f", total)) s\n"
        md += "- peak process footprint: \(await recorder.peakFootprint / 1_000_000) MB\n\n"
        md += "## Takeaways\n\n"
        let takeaways = await recorder.takeaways
        for t in takeaways {
            md += "- **[\(TimeFormat.clock(t.start))–\(TimeFormat.clock(t.end))] \(t.title)** — \(t.summary) (slides \(t.slidePages.map(String.init).joined(separator: ",")))\n"
        }
        md += "\nTakeaway count: \(takeaways.count)\n"
        md += "\n## Slide trajectory\n\n" + (await recorder.slideChanges).map { "\(TimeFormat.clock($0.0))=\($0.1.map(String.init) ?? "–")" }.joined(separator: ", ") + "\n"
        let backtracks = await recorder.backtracks
        md += "\nBacktrack suggestions: " + (backtracks.isEmpty ? "none" : backtracks.map { "\(TimeFormat.clock($0.0))→\($0.1.map(String.init) ?? "clear")" }.joined(separator: ", ")) + "\n"

        // Memory
        md += "\n## Memory over time\n\nSampled every 60 s of session time (plus phase boundaries). `coverage lag` = session time minus the end of the newest takeaway.\n\n"
        md += "| session | wall s | footprint MB | coverage lag | note |\n|---|---|---|---|---|\n"
        for m in memory {
            md += "| \(TimeFormat.clock(m.sessionTime)) | \(String(format: "%.0f", m.wall)) | \(m.bytes / 1_000_000) | \(TimeFormat.clock(max(0, m.coverageLag))) | \(m.label ?? "") |\n"
        }

        // LLM calls
        md += "\n## LLM calls\n\n"
        for role in LLMRole.allCases {
            let mine = calls.filter { $0.role == role }
            if mine.isEmpty { continue }
            md += "- \(role.rawValue): \(stats(mine.map(\.seconds))); failed \(mine.filter(\.failed).count)\n"
        }
        for phase in ["feed", "drain", "finish", "quiz", "ask", "recap"] {
            let mine = calls.filter { $0.phase == phase }
            if !mine.isEmpty { md += "- phase `\(phase)`: \(stats(mine.map(\.seconds)))\n" }
        }
        md += "\n| # | session | wall s | phase | role | secs | first tok | in tok | out tok | prompt chars | json | failed |\n|---|---|---|---|---|---|---|---|---|---|---|---|\n"
        for (i, c) in calls.sorted(by: { $0.wallStart < $1.wallStart }).enumerated() {
            md += "| \(i + 1) | \(TimeFormat.clock(c.sessionTime)) | \(String(format: "%.0f", c.wallStart)) | \(c.phase) | \(c.role.rawValue) | \(fmt(c.seconds)) | \(c.firstToken.map(fmt) ?? "–") | \(c.usage.map { String($0.inputTokens) } ?? "–") | \(c.usage.map { String($0.outputTokens) } ?? "–") | \(c.promptChars) | \(c.json ? "y" : "") | \(c.failed ? "FAIL" : "") |\n"
        }

        let pings = await recorder.quizPings
        md += "\n## Timed quiz pings during the feed (\(pings.count))\n\n"
        for (t, q) in pings { md += "- [\(TimeFormat.clock(t))] \(q.prompt) — concept “\(q.concept)”, source \(TimeFormat.clock(q.sourceStart ?? 0))–\(TimeFormat.clock(q.sourceEnd ?? 0))\n" }

        // Quizzes
        md += "\n## Quizzes (\(interactive.quizzes.count))\n\n"
        for (i, trial) in interactive.quizzes.enumerated() {
            guard let q = trial.question else {
                md += "### Q\(i + 1) FAILED to generate (\(fmt(trial.genSeconds)) s): \(trial.error ?? "")\n\n"
                continue
            }
            md += "### Q\(i + 1) — \(q.concept) (generated in \(fmt(trial.genSeconds)) s)\n\n"
            md += "- target takeaway: [\(TimeFormat.clock(trial.target.start))–\(TimeFormat.clock(trial.target.end))] \(trial.target.title) · source \(TimeFormat.clock(q.sourceStart ?? 0))–\(TimeFormat.clock(q.sourceEnd ?? 0)) · slides \(q.sourceSlides.map(String.init).joined(separator: ","))\n"
            md += "- question: \(q.prompt)\n"
            switch q.kind {
            case let .multipleChoice(options, correct):
                for (j, o) in options.enumerated() { md += "  - \(optionLabel(j)). \(o)\(j == correct ? "  ← marked correct" : "")\n" }
            case let .shortAnswer(reference):
                md += "- reference answer: \(reference)\n"
            }
            for a in trial.attempts {
                let verdict = a.grade.map { $0.isCorrect ? "graded CORRECT" : "graded WRONG" } ?? "no grade"
                md += "- **\(a.label) answer** (\(fmt(a.seconds)) s → \(verdict)): \(a.answer)\n"
                if let g = a.grade {
                    md += "  - feedback: \(g.feedback)\n"
                    for c in g.citations { md += "  - cites \(evidence(for: c, segments: transcript, deck: deck))\n" }
                }
                if let e = a.error { md += "  - error: \(e)\n" }
            }
            md += "\n"
        }

        // Asks
        md += "## Ask (\(interactive.asks.count))\n\n"
        for (i, a) in interactive.asks.enumerated() {
            md += "### A\(i + 1) (\(fmt(a.seconds)) s, first token \(a.firstToken.map(fmt) ?? "–") s): \(a.question)\n\n\(a.text)\n\n"
            let raw = CitationParser.citations(in: a.text)
            md += "- citations kept: \(a.citations.map(label).joined(separator: ", ")) (in text: \(raw.map(label).joined(separator: ", ")))\n"
            for c in a.citations { md += "  - \(evidence(for: c, segments: transcript, deck: deck))\n" }
            if let e = a.error { md += "- error: \(e)\n" }
            md += "\n"
        }

        // Recaps
        md += "## Recaps (\(interactive.recaps.count))\n\n"
        for r in interactive.recaps {
            md += "### \(TimeFormat.clock(r.from))–\(TimeFormat.clock(r.to)) (\(fmt(r.seconds)) s)\n\n"
            if let recap = r.recap {
                md += "- headline: \(recap.headline)\n"
                for b in recap.bullets { md += "  - \(b)\n" }
                md += "- flagged: \(recap.flagged.isEmpty ? "none" : recap.flagged.joined(separator: " / "))\n- slides: \(recap.slides.map(String.init).joined(separator: ","))\n"
            }
            if let e = r.error { md += "- error: \(e)\n" }
            md += "\n"
        }

        let errors = await recorder.errors
        md += "## Errors (\(errors.count))\n\n" + errors.map { "- \($0)" }.joined(separator: "\n") + "\n"
        try md.write(to: options.report, atomically: true, encoding: .utf8)

        // Transcript sidecar, for judging the report against the reference captions.
        let speakers = await recorder.speakers
        let lines = transcript.map { s -> String in
            let who = speakers[s.id].map { $0.isLecturer ? "L" : "A" } ?? "?"
            return "[\(TimeFormat.clock(s.start))] (\(who)) \(s.text)"
        }
        try lines.joined(separator: "\n").write(to: options.report.deletingPathExtension().appendingPathExtension("transcript.txt"), atomically: true, encoding: .utf8)
    }

    /// The process's physical footprint (what Activity Monitor calls Memory), including GPU buffers.
    static func physFootprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }
}
