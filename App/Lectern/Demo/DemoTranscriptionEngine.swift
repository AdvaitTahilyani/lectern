import Foundation
import LecternCore

/// "Speaks" a scripted lecture: emits volatile hypotheses word by word at a realistic pace,
/// finalizes each sentence, and produces a plausible input level for the meter.
nonisolated final class DemoTranscriptionEngine: TranscriptionEngine, @unchecked Sendable {
    // `state` is only mutated inside the single speaking task or under `lock`.
    let engineID: TranscriptionEngineID = .parakeet
    private let script: DemoScript
    private let speed: Double
    private let lock = NSLock()
    private var speakingTask: Task<Void, Never>?
    private var continuation: AsyncThrowingStream<TranscriptionEvent, Error>.Continuation?
    /// Sentence index to resume from after a pause.
    private var resumeIndex = 0

    init(script: DemoScript, speed: Double = 1) {
        self.script = script
        self.speed = max(0.1, speed)
    }

    func readiness() async -> EngineReadiness { .ready }

    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws { progress(1) }

    func start(options: TranscriptionOptions) async throws -> AsyncThrowingStream<TranscriptionEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream<TranscriptionEvent, Error>.makeStream()
        let startIndex = lock.withLock { () -> Int in
            self.continuation = continuation
            return resumeIndex
        }
        let engine = self
        let task = Task.detached(priority: .userInitiated) { [script, speed] in
            await Self.speak(script: script, speed: speed, from: startIndex, offset: options.timeOffset, continuation: continuation) { index in
                engine.lock.withLock { engine.resumeIndex = index }
            }
        }
        lock.withLock { speakingTask = task }
        return stream
    }

    func stop() async {
        let (task, continuation) = lock.withLock { (speakingTask, self.continuation) }
        task?.cancel()
        continuation?.finish()
        lock.withLock { speakingTask = nil; self.continuation = nil }
    }

    func transcribeFile(at url: URL, options: TranscriptionOptions) async throws -> AsyncThrowingStream<TranscriptionEvent, Error> {
        try await start(options: options)
    }

    // MARK: - Speaking loop

    private static func speak(
        script: DemoScript,
        speed: Double,
        from startIndex: Int,
        offset: TimeInterval,
        continuation: AsyncThrowingStream<TranscriptionEvent, Error>.Continuation,
        progress: @escaping @Sendable (Int) -> Void
    ) async {
        let sentences = script.sentences
        var clock = offset
        var generator = SystemRandomNumberGenerator()
        continuation.yield(.level(0.05))

        func sleep(_ seconds: Double) async -> Bool {
            let ns = UInt64(max(0, seconds / speed) * 1_000_000_000)
            do { try await Task.sleep(nanoseconds: ns); return true } catch { return false }
        }

        for index in startIndex..<sentences.count {
            if Task.isCancelled { break }
            let sentence = sentences[index].text
            let speaker = sentences[index].speaker
            let words = sentence.split(separator: " ").map(String.init)
            let segmentID = UUID()
            let start = clock
            var spoken: [String] = []
            for (w, word) in words.enumerated() {
                // ~2.6 words/s with natural jitter; slightly longer after punctuation.
                let base = 0.34 + Double.random(in: -0.08...0.12, using: &generator)
                let pause = word.hasSuffix(",") ? 0.18 : (word.hasSuffix(".") ? 0.35 : 0)
                let dt = base + pause
                // Level pulses while a word is spoken.
                for tick in 0..<4 {
                    let level = Float(0.35 + Double.random(in: 0...0.35, using: &generator)) * (tick == 3 ? 0.4 : 1)
                    continuation.yield(.level(level))
                    guard await sleep(dt / 4) else { return }
                }
                clock += dt
                spoken.append(word)
                // ASR-style revision: occasionally show a lower-cased/partial word that gets corrected.
                var hypothesis = spoken.joined(separator: " ")
                if w < words.count - 1, Double.random(in: 0...1, using: &generator) < 0.12 {
                    hypothesis += " " + String(words[w + 1].prefix(max(1, words[w + 1].count / 2)))
                }
                continuation.yield(.volatile(TranscriptSegment(id: segmentID, text: hypothesis, start: start, end: clock, isFinal: false)))
            }
            continuation.yield(.final(TranscriptSegment(id: segmentID, text: sentence, start: start, end: clock, isFinal: true)))
            progress(index + 1)
            // Breath between sentences; longer between beats.
            let isBeatEnd = index + 1 < sentences.count && sentences[index + 1].beat != sentences[index].beat
            let gap = isBeatEnd ? 1.6 : 0.7
            for tick in 0..<Int(gap / 0.1) {
                continuation.yield(.level(Float(Double.random(in: 0.02...0.08, using: &generator))))
                guard await sleep(0.1) else { return }
                // Diarization lags the text by a moment.
                if tick == 4 { continuation.yield(.speakers([segmentID: speaker])) }
            }
            clock += gap
        }
        // Script exhausted: keep the mic "open" with room noise until stopped.
        while !Task.isCancelled {
            continuation.yield(.level(Float(Double.random(in: 0.02...0.06, using: &generator))))
            guard await sleep(0.2) else { return }
        }
    }
}

/// Synthetic input level for the Setup meter in demo mode.
nonisolated final class DemoLevelMonitor: AudioLevelMonitoring, @unchecked Sendable {
    // `task` is only touched from start()/stop(), which the model calls on the main actor.
    private var task: Task<Void, Never>?

    func start(deviceID: String?) -> AsyncStream<Float> {
        let (stream, continuation) = AsyncStream<Float>.makeStream()
        task = Task.detached {
            var g = SystemRandomNumberGenerator()
            var phase = 0.0
            while !Task.isCancelled {
                phase += 0.15
                let envelope = max(0, sin(phase) * 0.5 + 0.2)
                continuation.yield(Float(envelope * Double.random(in: 0.6...1.0, using: &g)))
                try? await Task.sleep(for: .milliseconds(80))
            }
            continuation.finish()
        }
        return stream
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}
