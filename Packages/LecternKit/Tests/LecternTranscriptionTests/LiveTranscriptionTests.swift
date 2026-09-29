import Darwin
import Foundation
import LecternCore
import Testing
@testable import LecternTranscription

/// End-to-end checks against real models and audio. Skipped unless `LECTERN_LIVE_TESTS=1`.
///
///     LECTERN_LIVE_TESTS=1 LECTERN_LIVE_ENGINE=parakeet|apple LECTERN_LIVE_FILE=/path/audio.wav \
///     [LECTERN_LIVE_REFERENCE=/path/reference.txt] [LECTERN_LIVE_VOCAB="LL(1),FIRST set"] \
///     [LECTERN_LIVE_SECONDS=600] [LECTERN_LIVE_OUT=/path/dir] \
///         swift test --skip-build --test-product LecternTranscriptionTests --filter LiveTranscriptionTests
///
/// Engines run in separate invocations so peak memory is attributable to one engine.
@Suite("Live transcription", .serialized)
struct LiveTranscriptionTests {
    private static let environment = ProcessInfo.processInfo.environment
    private static var isEnabled: Bool { environment["LECTERN_LIVE_TESTS"] == "1" }

    @Test(.enabled(if: LiveTranscriptionTests.isEnabled), .timeLimit(.minutes(60)))
    func transcribeFile() async throws {
        let env = Self.environment
        let engineID = try #require(TranscriptionEngineID(rawValue: env["LECTERN_LIVE_ENGINE"] ?? "parakeet"))
        let file = try #require(env["LECTERN_LIVE_FILE"], "set LECTERN_LIVE_FILE")
        let url = URL(fileURLWithPath: file)
        let vocabulary = (env["LECTERN_LIVE_VOCAB"] ?? "").split(separator: ",").map(String.init)
        let outDirectory = URL(fileURLWithPath: env["LECTERN_LIVE_OUT"] ?? NSTemporaryDirectory())
        let diarize = env["LECTERN_LIVE_DIARIZE"] != "0"
        let label = "\(engineID.rawValue)-\(url.deletingPathExtension().lastPathComponent)\(vocabulary.isEmpty ? "" : "-vocab")\(diarize ? "" : "-nodiar")"

        let engine = TranscriptionEngines.make(engineID)
        print("=== LIVE \(label): readiness before prepare = \(await engine.readiness())")
        let prepareStart = ContinuousClock.now
        let lastReport = Locked(-1.0)
        try await engine.prepare { fraction in
            if fraction - lastReport.value >= 0.1 || fraction >= 1 {
                lastReport.value = fraction
                print("=== LIVE prepare \(Int(fraction * 100))%")
            }
        }
        print("=== LIVE prepare took \(Self.seconds(ContinuousClock.now - prepareStart)) s; readiness = \(await engine.readiness())")

        let duration = try AudioFileSource(url: url).duration
        let start = ContinuousClock.now
        let stream = try await engine.transcribeFile(at: url, options: TranscriptionOptions(vocabulary: vocabulary, diarize: diarize))
        var finals: [TranscriptSegment] = []
        var volatileCount = 0
        var volatileIDs = Set<UUID>()
        var warnings: [String] = []
        var firstFinalLatency: Double?
        var labels: [UUID: SpeakerRole] = [:]
        var labelEvents = 0
        let cpuBefore = Self.cpuSeconds()
        for try await event in stream {
            switch event {
            case .final(let segment):
                finals.append(segment)
                firstFinalLatency = firstFinalLatency ?? Self.seconds(ContinuousClock.now - start)
            case .volatile(let segment):
                volatileCount += 1
                volatileIDs.insert(segment.id)
            case .warning(let text): warnings.append(text)
            case .level: break
            case .speakers(let update):
                labelEvents += 1
                labels.merge(update) { _, new in new }
            }
        }
        let wall = Self.seconds(ContinuousClock.now - start)
        let cpu = Self.cpuSeconds() - cpuBefore

        // Invariants of the event stream.
        #expect(!finals.isEmpty)
        #expect(Set(finals.map(\.id)).count == finals.count, "final ids are unique")
        #expect(zip(finals, finals.dropFirst()).allSatisfy { $0.start <= $1.start + 1e-6 }, "finals are chronological")
        #expect(finals.allSatisfy { $0.isFinal && $0.end >= $0.start })

        // Report.
        let transcript = finals.map(\.text).joined(separator: "\n")
        try transcript.write(to: outDirectory.appendingPathComponent("\(label).txt"), atomically: true, encoding: .utf8)
        let words = finals.map { $0.text.split(separator: " ").count }.sorted()
        let spans = finals.map { $0.end - $0.start }.sorted()
        print("=== LIVE \(label) RESULT")
        print("audio \(String(format: "%.1f", duration)) s, wall \(String(format: "%.1f", wall)) s, real-time factor \(String(format: "%.1f", duration / wall))x")
        print("CPU time \(String(format: "%.1f", cpu)) s (\(String(format: "%.0f", cpu / wall * 100))% of one core over the run, \(String(format: "%.2f", cpu / (duration / 60))) CPU-s per audio minute)")
        print("peak memory footprint \(Self.peakMemoryMB()) MB, first final after \(String(format: "%.1f", firstFinalLatency ?? 0)) s wall")
        print("\(finals.count) finals (\(words.reduce(0, +)) words), \(volatileCount) volatile updates over \(volatileIDs.count) ids, \(warnings.count) warnings \(warnings)")
        print("segment words  min/p10/median/p90/max = \(Self.quantiles(words.map(Double.init)))")
        print("segment seconds min/p10/median/p90/max = \(Self.quantiles(spans))")
        if diarize { try Self.reportSpeakers(finals: finals, labels: labels, labelEvents: labelEvents, label: label, out: outDirectory) }
        if duration <= 120 { print("TRANSCRIPT:\n\(transcript)") }

        if let referencePath = env["LECTERN_LIVE_REFERENCE"] {
            let span = Double(env["LECTERN_LIVE_SECONDS"] ?? "") ?? duration
            try Self.reportWER(finals: finals, referencePath: referencePath, span: span, label: label, out: outDirectory)
        }
    }

    // MARK: Speaker labels

    private static func reportSpeakers(finals: [TranscriptSegment], labels: [UUID: SpeakerRole], labelEvents: Int, label: String, out: URL) throws {
        func name(_ role: SpeakerRole?) -> String {
            switch role {
            case .lecturer: "LECTURER"
            case .audience(let index): "AUDIENCE-\(index)"
            case nil: "unlabeled"
            }
        }
        var seconds: [String: Double] = [:]
        var counts: [String: Int] = [:]
        for segment in finals {
            let key = name(labels[segment.id])
            seconds[key, default: 0] += segment.end - segment.start
            counts[key, default: 0] += 1
        }
        print("SPEAKERS: \(labelEvents) .speakers events, \(labels.count)/\(finals.count) finals labeled")
        for key in seconds.keys.sorted() {
            print("  \(key): \(counts[key]!) segments, \(String(format: "%.0f", seconds[key]!)) s")
        }
        // Audience runs: consecutive non-lecturer segments merged, to compare with the captions by eye.
        var runs: [(start: Double, end: Double, text: String, who: String)] = []
        for segment in finals {
            let who = name(labels[segment.id])
            guard who.hasPrefix("AUDIENCE") else { continue }
            if let last = runs.last, last.who == who, segment.start - last.end < 3 {
                runs[runs.count - 1].end = segment.end
                runs[runs.count - 1].text += " " + segment.text
            } else {
                runs.append((segment.start, segment.end, segment.text, who))
            }
        }
        func clock(_ t: Double) -> String { String(format: "%d:%02d", Int(t) / 60, Int(t) % 60) }
        print("AUDIENCE RUNS (\(runs.count)):")
        var listing = ""
        for run in runs {
            let line = "[\(clock(run.start))-\(clock(run.end))] \(run.who): \(run.text)"
            listing += line + "\n"
        }
        for line in listing.split(separator: "\n").prefix(Int(environment["LECTERN_LIVE_RUNS"] ?? "40") ?? 40) { print("  " + line.prefix(150)) }
        let labeled = finals.map { "[\(clock($0.start))] \(name(labels[$0.id])): \($0.text)" }.joined(separator: "\n")
        try labeled.write(to: out.appendingPathComponent("\(label)-labeled.txt"), atomically: true, encoding: .utf8)
        try listing.write(to: out.appendingPathComponent("\(label)-audience-runs.txt"), atomically: true, encoding: .utf8)
    }

    // MARK: WER against timestamped captions

    private static func reportWER(finals: [TranscriptSegment], referencePath: String, span: TimeInterval, label: String, out: URL) throws {
        let lines = try parseReference(at: referencePath).filter { $0.time < span }
        let reference = lines.flatMap { WordErrorRate.words($0.text) }

        // Captions have long holes (silent quiz time, missing lines). A second figure drops
        // hypothesis segments that start inside a hole of 20 s or more.
        var holes: [(from: TimeInterval, to: TimeInterval)] = []
        for (line, next) in zip(lines, lines.dropFirst() + [Line(time: span, text: "")]) where next.time - line.time >= 20 {
            holes.append((line.time + 6, next.time))
        }
        let inHole: (TranscriptSegment) -> Bool = { segment in holes.contains { segment.start >= $0.from && segment.start < $0.to } }
        let hypothesisAll = finals.filter { $0.start < span }.flatMap { WordErrorRate.words($0.text) }
        let hypothesisCovered = finals.filter { $0.start < span && !inHole($0) }.flatMap { WordErrorRate.words($0.text) }

        let all = WordErrorRate.compare(reference: reference, hypothesis: hypothesisAll)
        let covered = WordErrorRate.compare(reference: reference, hypothesis: hypothesisCovered)
        // Human/ASR captions usually omit disfluencies that a verbatim recognizer keeps.
        let fillers: Set<String> = ["uh", "um", "uhm", "umm", "hmm", "mm", "ah", "er", "erm"]
        let withoutFillers = WordErrorRate.compare(
            reference: reference.filter { !fillers.contains($0) }, hypothesis: hypothesisCovered.filter { !fillers.contains($0) }
        )
        print("WER vs captions (first \(Int(span)) s): reference \(reference.count) words, hypothesis \(hypothesisAll.count) words")
        print("  all speech:            \(pct(all.rate))  (sub \(all.substitutions), del \(all.deletions), ins \(all.insertions))")
        print("  excluding caption holes (\(holes.count) holes, \(hypothesisAll.count - hypothesisCovered.count) hyp words dropped): \(pct(covered.rate))  (sub \(covered.substitutions), del \(covered.deletions), ins \(covered.insertions))")
        print("  excluding holes and filler words (uh/um): \(pct(withoutFillers.rate))  (sub \(withoutFillers.substitutions), del \(withoutFillers.deletions), ins \(withoutFillers.insertions))")
        try (reference.joined(separator: " ") + "\n").write(to: out.appendingPathComponent("\(label)-reference-normalized.txt"), atomically: true, encoding: .utf8)
    }

    private struct Line { var time: TimeInterval; var text: String }

    /// Lines look like `[1:12] text` or `[1:02:03] text`.
    private static func parseReference(at path: String) throws -> [Line] {
        try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n").compactMap { raw in
            guard raw.hasPrefix("["), let close = raw.firstIndex(of: "]") else { return nil }
            let parts = raw[raw.index(after: raw.startIndex)..<close].split(separator: ":").compactMap { Double($0) }
            let time = parts.reduce(0) { $0 * 60 + $1 }
            return Line(time: time, text: String(raw[raw.index(after: close)...]))
        }
    }

    // MARK: Helpers

    private static func pct(_ value: Double) -> String { String(format: "%.1f%%", value * 100) }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    private static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func seconds(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    /// Peak physical footprint of the process (includes CoreML model memory, unlike max RSS).
    private static func peakMemoryMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? Int(info.ledger_phys_footprint_peak / 1_048_576) : -1
    }

    private static func quantiles(_ sorted: [Double]) -> String {
        guard !sorted.isEmpty else { return "n/a" }
        func at(_ q: Double) -> Double { sorted[min(sorted.count - 1, Int(q * Double(sorted.count)))] }
        return [sorted[0], at(0.1), at(0.5), at(0.9), sorted[sorted.count - 1]].map { String(format: "%.1f", $0) }.joined(separator: " / ")
    }
}

/// Minimal lock-protected box for progress callbacks.
private final class Locked<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
