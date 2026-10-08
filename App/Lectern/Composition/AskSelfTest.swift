import Foundation
import LecternCore
@_spi(Evaluation) import LecternIntelligence
import LecternMLX
import LecternSlides
import LecternStore

/// Ask evaluation: answers a fixed question set about a recorded lecture with the real brain and
/// model, and records each answer with its latency and token counts for grading.
///
///     Lectern -selftest ask -questions <questions.json>
///             (-session <session.json> | -transcript <lines.txt> [-slides <deck.pdf>])
///             [-design standard|compact] [-reasoning off|low|medium] [-model <hf repo>|settings]
///             [-warm] [-dry] [-warmsteps N] [-report <md>] [-json <out.json>]
///
/// - `-session` reads a lecture saved by Lectern (transcript, takeaways, deck); `-transcript` reads
///   "[m:ss] text" lines (no takeaways) with the slides from `-slides`.
/// - questions.json: `{"title"?, "course"?, "questions": [{"id", "question", "askedAt"?,
///   "history"?: [{"role": "user"|"assistant", "text"}], "reference", "keyPoints"}]}`. A question
///   with `askedAt` (seconds) sees only the lecture up to then, as if asked live.
/// - `-model` defaults to the default on-device model (never downloaded here); `settings` uses the
///   Ask provider configured in Settings, e.g. a cloud model with its API key.
/// - `-warm` prefills the Ask prefix before each question that starts a new transcript step, as
///   the live app does in the background; without it the first question of a step is cold.
/// - `-dry` uses no model: it writes the prompts' sizes (estimated tokens) per question.
/// - `-warmsteps N` answers nothing: it times the background warm-up of the last N transcript
///   steps in a row, as during a live lecture (each one only adds the new five minutes).
nonisolated enum AskSelfTest {
    struct Options {
        var questions: URL
        var session: URL?
        var transcript: URL?
        var slides: URL?
        var design = AskDesign.standard
        var designName = "standard"
        var model = AppSettings.defaultOnDeviceModel
        var warm = false
        var dry = false
        var warmSteps = 0
        var report: URL
        var json: URL?

        init?(arguments args: [String]) {
            func value(_ flag: String) -> String? {
                guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
                return args[i + 1]
            }
            guard let questions = value("-questions") else { return nil }
            self.questions = URL(fileURLWithPath: questions)
            session = value("-session").map { URL(fileURLWithPath: $0) }
            transcript = value("-transcript").map { URL(fileURLWithPath: $0) }
            slides = value("-slides").map { URL(fileURLWithPath: $0) }
            guard (session == nil) != (transcript == nil) else { return nil }
            switch value("-design") ?? "standard" {
            case "standard": break
            case "compact": design = .compact; designName = "compact"
            default: return nil
            }
            if let effort = value("-reasoning") {
                guard let parsed = ReasoningEffort(rawValue: effort) else { return nil }
                design = design.reasoning(parsed)
            }
            model = value("-model") ?? model
            warm = args.contains("-warm")
            dry = args.contains("-dry")
            warmSteps = max(0, value("-warmsteps").flatMap(Int.init) ?? 0)
            report = URL(fileURLWithPath: value("-report") ?? NSTemporaryDirectory() + "lectern-ask.md")
            json = value("-json").map { URL(fileURLWithPath: $0) }
        }
    }

    struct QuestionSet: Decodable {
        struct Turn: Decodable { var role: String; var text: String }
        struct Question: Decodable {
            var id: String
            var question: String
            var askedAt: TimeInterval?
            var history: [Turn]?
            var reference: String?
            var keyPoints: [String]?
        }
        var title: String?
        var course: String?
        var questions: [Question]
    }

    /// One answered question, as written to the JSON output.
    struct Result: Encodable {
        var id: String
        var question: String
        var answer: String
        var citations: [String]
        var citationsInText: [String]
        var firstTokenSeconds: Double?
        var totalSeconds: Double
        var warmUpSeconds: Double?
        var inputTokens: Int?
        var outputTokens: Int?
        var estimatedSystemTokens: Int
        var estimatedQuestionTokens: Int
        var estimatedHistoryTokens: Int
        var error: String?
    }

    /// The lecture as the brain would get it from the library.
    struct Lecture {
        var title: String
        var course: String?
        var deck: SlideDeck?
        var transcript: [TranscriptSegment]
        var takeaways: [Takeaway]
        var quiz: [QuizRecord]
        var currentSlide: Int?
    }

    // MARK: - Run

    static func run(arguments: [String]) async -> Bool {
        guard let options = Options(arguments: arguments) else {
            print("[ask] usage: -selftest ask -questions <json> (-session <session.json> | -transcript <txt> [-slides <pdf>]) [-design standard|compact] [-reasoning off|low|medium] [-model <repo>|settings] [-warm] [-dry] [-report <md>] [-json <out.json>]")
            return false
        }
        do {
            let set = try JSONDecoder().decode(QuestionSet.self, from: Data(contentsOf: options.questions))
            var lecture = try await load(options)
            if let title = set.title { lecture.title = title }
            if let course = set.course { lecture.course = course }
            let slides = lecture.deck.map { SlideIndex(deck: $0) as any SlideSearching }

            let recorder = CallRecorder()
            let base: any LLMProvider
            let modelLabel: String
            if options.dry {
                base = DryProvider()
                modelLabel = "none (dry run)"
            } else if options.model == "settings" {
                base = ProviderResolver.roleProviders(for: StoredSettings.current(), keychain: .init()).ask
                modelLabel = "\(base.kind.rawValue) \(base.model) (from Settings)"
            } else {
                guard MLXModelHost.shared.modelManager.isDownloaded(options.model) else {
                    print("[ask] \(options.model) is not downloaded; this harness never downloads models.")
                    return false
                }
                let mlx = MLXProvider(model: options.model, role: .ask)
                let t0 = ContinuousClock.now
                try await mlx.warmUp()
                print("[ask] loaded \(options.model) in \(t0.duration(to: .now))")
                base = mlx
                modelLabel = options.model
            }
            let provider = RecordingProvider(inner: base, recorder: recorder)
            let providers = RoleProviders(summaries: provider, quizzes: provider, ask: provider)

            if options.warmSteps > 0, !options.dry {
                await timeWarmSteps(options.warmSteps, lecture: lecture, slides: slides, providers: providers, design: options.design)
                return true
            }

            var results: [Result] = []
            var lastSnapshot: Int?
            for question in set.questions {
                let context = context(for: lecture, at: question.askedAt)
                let brain = LectureBrain(context: context, providers: providers, slides: slides, quiz: QuizSettings(enabled: false),
                                         summaryIntervalSeconds: 60)
                await brain.useAskDesign(options.design)
                var warmUp: Double?
                let snapshot = await brain.askSnapshotLength()
                if options.warm, !options.dry, snapshot != lastSnapshot {
                    let t0 = ContinuousClock.now
                    await brain.warmAskPrefix()
                    warmUp = t0.duration(to: .now) / .seconds(1)
                }
                lastSnapshot = snapshot
                let history = (question.history ?? []).map { ChatMessage(role: $0.role == "user" ? .user : .assistant, text: $0.text) }
                await recorder.reset()
                var result = await ask(question, history: history, brain: brain)
                result.warmUpSeconds = warmUp
                if let call = await recorder.last {
                    result.inputTokens = call.usage?.inputTokens
                    result.outputTokens = call.usage?.outputTokens
                    let system = call.request.messages.first { $0.role == .system }?.content ?? ""
                    let user = call.request.messages.last { $0.role == .user }?.content ?? ""
                    let all = call.request.messages.map(\.content).joined()
                    result.estimatedSystemTokens = estimate(system)
                    result.estimatedQuestionTokens = estimate(user)
                    result.estimatedHistoryTokens = max(0, estimate(all) - estimate(system) - estimate(user))
                }
                print("[ask] \(question.id): \(result.firstTokenSeconds.map { String(format: "%.1f", $0) } ?? "–") s to first token, \(String(format: "%.1f", result.totalSeconds)) s total, \(result.inputTokens ?? result.estimatedSystemTokens + result.estimatedQuestionTokens) prompt tokens")
                results.append(result)
            }
            try write(results, set: set, lecture: lecture, options: options, modelLabel: modelLabel)
            print("[ask] done: \(results.count) questions, \(results.filter { $0.error != nil }.count) errors. Report: \(options.report.path)")
            return results.allSatisfy { $0.error == nil }
        } catch {
            print("[ask] FAILED: \(error)")
            return false
        }
    }

    /// Warm-ups at consecutive 5-minute steps ending at the lecture's end, nothing asked between.
    private static func timeWarmSteps(_ steps: Int, lecture: Lecture, slides: (any SlideSearching)?, providers: RoleProviders, design: AskDesign) async {
        let end = lecture.transcript.last?.end ?? 0
        for k in stride(from: steps, through: 0, by: -1) {
            let at = end - Double(k) * 300
            let brain = LectureBrain(context: context(for: lecture, at: at), providers: providers, slides: slides,
                                     quiz: QuizSettings(enabled: false), summaryIntervalSeconds: 60)
            await brain.useAskDesign(design)
            let t0 = ContinuousClock.now
            await brain.warmAskPrefix()
            print("[ask] warm-up at \(TimeFormat.clock(at)): \(await brain.askSnapshotLength()) segments in the prefix, \(String(format: "%.1f", t0.duration(to: .now) / .seconds(1))) s")
        }
    }

    private static func ask(_ question: QuestionSet.Question, history: [ChatMessage], brain: LectureBrain) async -> Result {
        let clock = ContinuousClock()
        let t0 = clock.now
        var first: Double?
        var result = Result(id: question.id, question: question.question, answer: "", citations: [], citationsInText: [],
                            totalSeconds: 0, estimatedSystemTokens: 0, estimatedQuestionTokens: 0, estimatedHistoryTokens: 0)
        do {
            for try await event in await brain.ask(question.question, history: history) {
                switch event {
                case .delta: if first == nil { first = (clock.now - t0) / .seconds(1) }
                case .done(let message):
                    result.answer = message.text
                    result.citations = message.citations.map(label)
                    result.citationsInText = CitationParser.citations(in: message.text).map(label)
                }
            }
        } catch {
            result.error = "\(error)"
        }
        result.firstTokenSeconds = first
        result.totalSeconds = (clock.now - t0) / .seconds(1)
        return result
    }

    // MARK: - Input

    private static func load(_ options: Options) async throws -> Lecture {
        if let url = options.session {
            let session = try await loadSession(url)
            return Lecture(title: session.title, course: nil, deck: session.deck, transcript: session.transcript,
                           takeaways: session.takeaways, quiz: session.quiz, currentSlide: session.currentSlide)
        }
        let text = try String(contentsOf: options.transcript!, encoding: .utf8)
        var segments: [TranscriptSegment] = []
        for line in text.split(separator: "\n") {
            guard let match = line.firstMatch(of: /^\[(\d+(?::\d+){1,2})\]\s*(.*)$/), let start = seconds(String(match.1)) else { continue }
            let body = String(match.2).trimmingCharacters(in: .whitespaces)
            guard !body.isEmpty else { continue }
            if let last = segments.indices.last { segments[last].end = max(segments[last].start, start) }
            segments.append(TranscriptSegment(text: body, start: start, end: start + 3, isFinal: true))
        }
        var deck: SlideDeck?
        if let pdf = options.slides { deck = try await PDFSlideIngestor().ingest(pdfAt: pdf) { _ in } }
        return Lecture(title: options.transcript!.deletingPathExtension().lastPathComponent, course: nil, deck: deck,
                       transcript: segments, takeaways: [], quiz: [], currentSlide: nil)
    }

    /// Reads a session.json through the library's own decoder, from a temporary copy.
    private static func loadSession(_ url: URL) async throws -> LectureSession {
        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let session = object["session"] as? [String: Any], let idString = session["id"] as? String,
              let id = UUID(uuidString: idString) else { throw CocoaError(.fileReadCorruptFile) }
        let root = FileManager.default.temporaryDirectory.appending(path: "lectern-ask-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appending(path: "Sessions/\(id.uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: folder.appending(path: "session.json"))
        return try await FileSessionStore(root: root).loadSession(id: id)
    }

    /// "1:02:03" or "62:03" → seconds.
    private static func seconds(_ clock: String) -> TimeInterval? {
        let parts = clock.split(separator: ":").compactMap { Double($0) }
        return parts.isEmpty ? nil : parts.reduce(0) { $0 * 60 + $1 }
    }

    /// The lecture as it was at `askedAt` (all of it when nil): later transcript dropped, the
    /// takeaway in progress then marked live.
    private static func context(for lecture: Lecture, at askedAt: TimeInterval?) -> BrainContext {
        guard let askedAt else {
            return BrainContext(sessionTitle: lecture.title, courseName: lecture.course, deck: lecture.deck, transcript: lecture.transcript,
                                takeaways: lecture.takeaways, quizHistory: lecture.quiz, currentSlide: lecture.currentSlide)
        }
        let transcript = lecture.transcript.filter { $0.end <= askedAt }
        var takeaways = lecture.takeaways.filter { $0.start < askedAt }
        if let last = takeaways.indices.last {
            takeaways[last].end = min(takeaways[last].end, askedAt)
            takeaways[last].isLive = true
        }
        return BrainContext(sessionTitle: lecture.title, courseName: lecture.course, deck: lecture.deck, transcript: transcript,
                            takeaways: takeaways, quizHistory: lecture.quiz.filter { $0.askedAt <= askedAt })
    }

    // MARK: - Output

    private static func estimate(_ text: String) -> Int { Int((Double(text.unicodeScalars.count) / 3.4).rounded(.up)) }

    private static func label(_ c: Citation) -> String {
        switch c {
        case .slide(let n): "S\(n)"
        case .time(let t): "T\(TimeFormat.clock(t))"
        }
    }

    private static func fmt(_ value: Double?) -> String { value.map { String(format: "%.1f", $0) } ?? "–" }

    private static func write(_ results: [Result], set: QuestionSet, lecture: Lecture, options: Options, modelLabel: String) throws {
        var md = "# Ask evaluation\n\n"
        md += "- lecture: \(lecture.title)\(lecture.course.map { " (\($0))" } ?? ""), transcript to \(TimeFormat.clock(lecture.transcript.last?.end ?? 0)), \(lecture.takeaways.count) takeaways, \(lecture.deck?.pages.count ?? 0) slides\n"
        md += "- design: \(options.designName), reasoning \(options.design.reasoningEffort.rawValue), maxTokens \(options.design.maxTokens)\(options.warm ? ", prefix warmed before each new step" : "")\n"
        md += "- model: \(modelLabel)\n\n"
        md += "| id | first token s | total s | warm-up s | prompt tok | output tok | est. system | est. question | est. history |\n|---|---|---|---|---|---|---|---|---|\n"
        for r in results {
            md += "| \(r.id) | \(fmt(r.firstTokenSeconds)) | \(fmt(r.totalSeconds)) | \(fmt(r.warmUpSeconds)) | \(r.inputTokens.map(String.init) ?? "–") | \(r.outputTokens.map(String.init) ?? "–") | \(r.estimatedSystemTokens) | \(r.estimatedQuestionTokens) | \(r.estimatedHistoryTokens) |\n"
        }
        for (r, q) in zip(results, set.questions) {
            md += "\n## \(r.id): \(r.question)\n\n"
            if let e = r.error { md += "**ERROR**: \(e)\n\n" }
            md += r.answer + "\n\n"
            md += "- citations kept: \(r.citations.joined(separator: ", ")) (in text: \(r.citationsInText.joined(separator: ", ")))\n"
            if let points = q.keyPoints { md += "- key points:\n" + points.map { "  - \($0)\n" }.joined() }
        }
        try md.write(to: options.report, atomically: true, encoding: .utf8)
        if let json = options.json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(results).write(to: json)
        }
    }
}

// MARK: - Providers

/// The last request each question sent and its reported usage.
private actor CallRecorder {
    struct Call { var request: LLMRequest; var usage: LLMUsage? }
    private(set) var last: Call?
    func reset() { last = nil }
    func record(_ request: LLMRequest, usage: LLMUsage?) {
        // Warm-ups (one token) are not the question's call.
        if request.maxTokens > 1 { last = Call(request: request, usage: usage) }
    }
}

private struct RecordingProvider: LLMProvider {
    let inner: any LLMProvider
    let recorder: CallRecorder
    var kind: ProviderKind { inner.kind }
    var model: String { inner.model }

    func complete(_ request: LLMRequest) async throws -> LLMResponse {
        let response = try await inner.complete(request)
        await recorder.record(request, usage: response.usage)
        return response
    }

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var usage: LLMUsage?
                do {
                    for try await event in inner.stream(request) {
                        if case .done(let u) = event { usage = u }
                        continuation.yield(event)
                    }
                    await recorder.record(request, usage: usage)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func healthCheck() async throws { try await inner.healthCheck() }
}

/// No model: every answer is a placeholder (for measuring prompt sizes).
private struct DryProvider: LLMProvider {
    var kind: ProviderKind { .localServer }
    var model: String { "dry-run" }
    func complete(_ request: LLMRequest) async throws -> LLMResponse { LLMResponse(text: "(dry run)") }
    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.delta("(dry run)"))
            continuation.yield(.done(nil))
            continuation.finish()
        }
    }
    func healthCheck() async throws {}
}
