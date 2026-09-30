import AVFoundation
import Foundation
import LecternCore

/// Scripted transcription engine for `transcribeFile`.
final class FakeEngine: TranscriptionEngine, @unchecked Sendable {
    let engineID = TranscriptionEngineID.parakeet
    private let lock = NSLock()   // guards the recorded state below
    private var _files: [URL] = []
    private var _formats: [AVAudioFormat] = []
    private var _stopCalls = 0
    private var _options: [TranscriptionOptions] = []

    var script: @Sendable () -> [TranscriptionEvent]
    var readinessValue: EngineReadiness = .ready
    /// When true the stream never yields or finishes (until the consumer is cancelled).
    var hangs = false

    init(script: @escaping @Sendable () -> [TranscriptionEvent] = { [] }) { self.script = script }

    var files: [URL] { lock.withLock { _files } }
    var formats: [AVAudioFormat] { lock.withLock { _formats } }
    var stopCalls: Int { lock.withLock { _stopCalls } }
    var options: [TranscriptionOptions] { lock.withLock { _options } }

    func readiness() async -> EngineReadiness { readinessValue }
    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws { progress(1) }
    func start(options: TranscriptionOptions) async throws -> AsyncThrowingStream<TranscriptionEvent, Error> {
        throw CocoaError(.featureUnsupported)
    }
    func stop() async { lock.withLock { _stopCalls += 1 } }

    func transcribeFile(at url: URL, options: TranscriptionOptions) async throws -> AsyncThrowingStream<TranscriptionEvent, Error> {
        let format = try AVAudioFile(forReading: url).processingFormat   // the file must exist and be readable audio
        lock.withLock { _files.append(url); _formats.append(format); _options.append(options) }
        if hangs { return AsyncThrowingStream { _ in } }
        let events = script()
        return AsyncThrowingStream { continuation in
            events.forEach { continuation.yield($0) }
            continuation.finish()
        }
    }
}

/// Deterministic stand-in for the lecture brain: one takeaway per three ingested segments.
actor FakeBrain: LectureIntelligence {
    nonisolated let updates: AsyncStream<BrainUpdate>
    private let continuation: AsyncStream<BrainUpdate>.Continuation
    private(set) var ingested: [TranscriptSegment] = []
    private(set) var speakerLabels: [UUID: SpeakerRole] = [:]
    private(set) var idleWaits = 0
    private(set) var finished = false
    var context: BrainContext?

    init() { (updates, continuation) = AsyncStream.makeStream() }

    func ingest(_ segment: TranscriptSegment) { ingested.append(segment) }
    func applySpeakers(_ labels: [UUID: SpeakerRole]) { speakerLabels.merge(labels) { _, new in new } }
    func waitUntilIdle() async { idleWaits += 1 }

    func finish() async {
        finished = true
        continuation.yield(.error("a summary pass failed once"))
        let takeaways = stride(from: 0, to: ingested.count, by: 3).map { start -> Takeaway in
            let group = ingested[start..<min(start + 3, ingested.count)]
            return Takeaway(title: "Topic \(start / 3 + 1)", summary: group.map(\.text).joined(separator: " "), start: group.first!.start, end: group.last!.end, isLive: false)
        }
        continuation.yield(.takeaways(Array(takeaways.prefix(1))))   // an earlier, partial list…
        continuation.yield(.takeaways(takeaways))                     // …then the settled one
    }

    func expand(takeawayID: UUID) async throws -> TakeawayDetail { throw LLMError.invalidResponse("unused") }
    func makeQuestion(followUpOf: QuizQuestion?) async throws -> QuizQuestion { throw LLMError.invalidResponse("unused") }
    func grade(_ question: QuizQuestion, answer: String) async throws -> QuizGrade { throw LLMError.invalidResponse("unused") }
    func record(_ record: QuizRecord) {}
    nonisolated func ask(_ question: String, history: [ChatMessage]) -> AsyncThrowingStream<AskEvent, Error> { AsyncThrowingStream { $0.finish() } }
    func update(quiz: QuizSettings, summaryIntervalSeconds: Double) {}
    func tick(sessionTime: TimeInterval) {}
    func recap(from: TimeInterval, to: TimeInterval) async throws -> Recap { throw LLMError.invalidResponse("unused") }
    func lectureSummary() async throws -> LectureSummary { throw LLMError.invalidResponse("unused") }
    func setCurrentSlide(_ page: Int) {}
}

final class Box<Value>: @unchecked Sendable {
    private let lock = NSLock()   // guards `stored`
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
