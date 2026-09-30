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
nonisolated enum PipelineSelfTest {
    struct Options {
        var audio: URL
        var slides: URL?
        var speed: Double = 4
        var minutes: Double?
        var report: URL

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
        }
    }

    /// Wall-clock record of one brain activity span.
    private struct Span { var activity: BrainActivity; var start: ContinuousClock.Instant; var seconds: Double; var atSessionTime: TimeInterval }

    private actor Recorder {
        var spans: [Span] = []
        var open: (BrainActivity, ContinuousClock.Instant, TimeInterval)?
        var takeaways: [Takeaway] = []
        var slideChanges: [(TimeInterval, Int?)] = []
        var backtracks: [(TimeInterval, Int?)] = []
        var errors: [String] = []
        var sessionTime: TimeInterval = 0
        var peakFootprint: UInt64 = 0

        func setTime(_ t: TimeInterval) { sessionTime = t; samplePeak() }

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
            case .quizReady: break
            }
            samplePeak()
        }

        func samplePeak() { peakFootprint = max(peakFootprint, PipelineSelfTest.physFootprint()) }
    }

    static func run(arguments: [String]) async -> Bool {
        guard let options = Options(arguments: arguments) else {
            print("[pipeline] usage: -selftest pipeline -audio <wav> [-slides <pdf>] [-speed 4] [-minutes N] [-report <md>]")
            return false
        }
        let settings = StoredSettings.current()
        let clock = ContinuousClock()
        let runStart = clock.now
        do {
            // Slides
            var deck: SlideDeck?
            var index: (any SlideSearching)?
            if let pdf = options.slides {
                deck = try await PDFSlideIngestor().ingest(pdfAt: pdf) { _ in }
                if let deck { index = SlideIndex(deck: deck) }
                print("[pipeline] slides: \(deck?.pages.count ?? 0) pages")
            }

            // Brain
            let context = BrainContext(sessionTitle: options.audio.deletingPathExtension().lastPathComponent, courseName: nil,
                                       deck: deck, transcript: [], takeaways: [], quizHistory: [])
            let brain = LectureBrain(context: context,
                                     providers: ProviderResolver.roleProviders(for: settings, keychain: .init()),
                                     slides: index, quiz: settings.quiz, summaryIntervalSeconds: settings.summaryIntervalSeconds)
            let recorder = Recorder()
            let consumer = Task { for await update in brain.updates { await recorder.record(update) } }

            // Speech → paced ingest
            let engine = TranscriptionEngines.make(.parakeet)
            if await engine.readiness() != .ready {
                print("[pipeline] preparing speech models…")
                try await engine.prepare { _ in }
            }
            let limit = options.minutes.map { $0 * 60 }
            var segments = 0, lastEnd: TimeInterval = 0
            let feedStart = clock.now
            for try await event in try await engine.transcribeFile(at: options.audio, options: TranscriptionOptions(diarize: true)) {
                switch event {
                case .final(let segment):
                    if let limit, segment.start > limit { break }
                    // Release the segment no earlier than its (sped-up) recorded end time.
                    let due = feedStart + .seconds(segment.end / options.speed)
                    if clock.now < due { try await clock.sleep(until: due) }
                    await recorder.setTime(segment.end)
                    await brain.tick(sessionTime: segment.end)
                    await brain.ingest(segment)
                    segments += 1
                    lastEnd = segment.end
                    if segments % 100 == 0 { print("[pipeline] \(TimeFormat.clock(segment.end)) · \(segments) segments") }
                case .speakers(let labels): await brain.applySpeakers(labels)
                case .warning(let w): print("[pipeline] warning: \(w)")
                case .volatile, .level: break
                }
                if let limit, lastEnd > limit { break }
            }
            await engine.stop()
            let feedDone = clock.now
            await brain.waitUntilIdle()
            let lag = (clock.now - feedDone) / .seconds(1)
            await brain.finish()

            // Interactive calls at the end, timed.
            var extras: [String] = []
            let t0 = clock.now
            var answer = ""
            for try await event in await brain.ask("What does genExpr return, and why does it allocate a new virtual register?", history: []) {
                if case .done(let message) = event { answer = message.text }
            }
            extras.append("Ask (\(String(format: "%.1f", (clock.now - t0) / .seconds(1))) s): \(answer)")
            let t1 = clock.now
            let question = try await brain.makeQuestion(followUpOf: nil)
            extras.append("Quiz (\(String(format: "%.1f", (clock.now - t1) / .seconds(1))) s): \(question.prompt) [\(question.concept)]")
            let t2 = clock.now
            let recap = try await brain.recap(from: 20 * 60, to: 27 * 60)
            extras.append("Recap 20:00–27:00 (\(String(format: "%.1f", (clock.now - t2) / .seconds(1))) s): \(recap.headline) — \(recap.bullets.joined(separator: " / "))")

            consumer.cancel()
            let total = (clock.now - runStart) / .seconds(1)
            try await writeReport(options: options, recorder: recorder, segments: segments, lastEnd: lastEnd,
                                  lag: lag, total: total, extras: extras, settings: settings)
            print("[pipeline] done: \(segments) segments to \(TimeFormat.clock(lastEnd)), catch-up lag \(String(format: "%.1f", lag)) s. Report: \(options.report.path)")
            return true
        } catch {
            print("[pipeline] FAILED: \(error)")
            return false
        }
    }

    private static func writeReport(options: Options, recorder: Recorder, segments: Int, lastEnd: TimeInterval,
                                    lag: Double, total: Double, extras: [String], settings: AppSettings) async throws {
        let spans = await recorder.spans
        let summaries = spans.filter { $0.activity == .summarizing }.map(\.seconds).sorted()
        func pct(_ p: Double) -> String {
            guard !summaries.isEmpty else { return "–" }
            return String(format: "%.1f s", summaries[min(summaries.count - 1, Int(Double(summaries.count) * p))])
        }
        var md = "# Pipeline self-test\n\n"
        md += "- audio: `\(options.audio.lastPathComponent)` to \(TimeFormat.clock(lastEnd)) at \(options.speed)× · \(segments) segments\n"
        md += "- providers: summaries=\(settings.provider(for: .summaries).model), ask=\(settings.provider(for: .ask).model)\n"
        md += "- summary calls: \(summaries.count), latency p50 \(pct(0.5)), p90 \(pct(0.9)), max \(summaries.last.map { String(format: "%.1f s", $0) } ?? "–")\n"
        md += "- catch-up lag after the last segment: \(String(format: "%.1f", lag)) s · total wall time \(String(format: "%.0f", total)) s\n"
        md += "- peak process footprint: \(await recorder.peakFootprint / 1_000_000) MB\n\n"
        md += "## Takeaways\n\n"
        for t in await recorder.takeaways {
            md += "- **[\(TimeFormat.clock(t.start))–\(TimeFormat.clock(t.end))] \(t.title)** — \(t.summary) (slides \(t.slidePages.map(String.init).joined(separator: ",")))\n"
        }
        md += "\n## Slide trajectory\n\n" + (await recorder.slideChanges).map { "\(TimeFormat.clock($0.0))=\($0.1.map(String.init) ?? "–")" }.joined(separator: ", ") + "\n"
        let backtracks = await recorder.backtracks
        md += "\nBacktrack suggestions: " + (backtracks.isEmpty ? "none" : backtracks.map { "\(TimeFormat.clock($0.0))→\($0.1.map(String.init) ?? "clear")" }.joined(separator: ", ")) + "\n"
        md += "\n## Interactive\n\n" + extras.map { "- \($0)" }.joined(separator: "\n") + "\n"
        let errors = await recorder.errors
        md += "\n## Errors (\(errors.count))\n\n" + errors.map { "- \($0)" }.joined(separator: "\n") + "\n"
        try md.write(to: options.report, atomically: true, encoding: .utf8)
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
