@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import LecternCore
import Speech

/// Apple's on-device `SpeechAnalyzer` + `SpeechTranscriber` (macOS 26+).
///
/// Tuned by Apple for long-form and distant speech, needs no bundled model, and runs outside the
/// app's memory. `SpeechTranscriber` ignores contextual strings, so `TranscriptionOptions.vocabulary`
/// has no effect on this engine.
public final class AppleSpeechEngine: TranscriptionEngine {
    public let engineID = TranscriptionEngineID.apple
    private let core: AppleSpeechCore

    /// - Parameter locale: recognition language; English (US) by default, matching the Parakeet engine.
    public init(locale: Locale = Locale(identifier: "en-US")) {
        core = AppleSpeechCore(locale: locale)
    }

    public func readiness() async -> EngineReadiness {
        await core.readiness()
    }

    public func prepare(progress: @escaping @Sendable (Double) -> Void) async throws {
        try await core.prepare(progress: progress)
    }

    public func start(options: TranscriptionOptions) async throws -> AsyncThrowingStream<TranscriptionEvent, Error> {
        try await core.startLive(options: options)
    }

    public func stop() async {
        await core.stopLive()
    }

    public func transcribeFile(at url: URL, options: TranscriptionOptions) async throws -> AsyncThrowingStream<TranscriptionEvent, Error> {
        try await core.transcribeFile(at: url, options: options)
    }
}

/// A running analyzer plus the input it is fed from.
///
/// `@unchecked Sendable`: every member is thread-safe except `factory`, which holds a converter
/// and is only ever used by the single task that feeds this session.
private struct AnalyzerSession: SessionRecognizer, @unchecked Sendable {
    let analyzer: SpeechAnalyzer
    let inputs: AsyncStream<AnalyzerInput>.Continuation
    let factory: AnalyzerInputFactory
    let results: Task<Void, Never>

    func feed(_ samples: [Float]) async throws {
        if let input = try factory.input(for: samples) { inputs.yield(input) }
    }

    /// Ends input, lets the analyzer finalize everything it has, and waits for the last result.
    func finish() async throws {
        inputs.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        await results.value
    }

    func cancel() async {
        inputs.finish()
        await analyzer.cancelAndFinishNow()
        await results.value
    }
}

private actor AppleSpeechCore {
    private struct LiveSession {
        let capture: AudioCapture
        let task: Task<Void, Never>
    }

    private let requestedLocale: Locale
    private var live: LiveSession?
    /// Set while a session is being opened; opening suspends the actor, so this blocks a second start.
    private var isStarting = false

    init(locale: Locale) {
        requestedLocale = locale
    }

    // MARK: Readiness & preparation

    private func makeTranscriber() async throws -> SpeechTranscriber {
        guard SpeechTranscriber.isAvailable else {
            throw TranscriptionError.recognitionFailed("Speech recognition is not available on this Mac.")
        }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale) else {
            throw TranscriptionError.recognitionFailed("Apple Speech does not support \(requestedLocale.identifier).")
        }
        return SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange]
        )
    }

    func readiness() async -> EngineReadiness {
        do {
            let transcriber = try await makeTranscriber()
            switch await AssetInventory.status(forModules: [transcriber]) {
            case .installed: return EngineReadiness.combining(missingBytes: 0, diarization: true)
            case .supported, .downloading: return .needsDownload(bytes: nil)
            case .unsupported: return .unavailable(reason: "Apple Speech does not support \(requestedLocale.identifier).")
            @unknown default: return .unavailable(reason: "Unknown Apple Speech asset status.")
            }
        } catch {
            return .unavailable(reason: error.localizedDescription)
        }
    }

    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws {
        progress(0)
        let transcriber = try await makeTranscriber()
        // Progress budget: speech assets 0...0.5, speaker model 0.5...1.
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            let poller = Task {
                while !Task.isCancelled {
                    progress(request.progress.fractionCompleted * 0.5)
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
            defer { poller.cancel() }
            try await request.downloadAndInstall()
        }
        progress(0.5)
        try await SpeakerDiarizer.prepare { progress(0.5 + $0 * 0.5) }
        progress(1)
    }

    // MARK: Sessions

    private func openAnalyzer(sink: EventSink, timeOffset: TimeInterval) async throws -> AnalyzerSession {
        let transcriber = try await makeTranscriber()
        guard await AssetInventory.status(forModules: [transcriber]) == .installed else {
            throw TranscriptionError.modelsNotInstalled(engine: "Apple Speech")
        }
        let natural = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: MonoResampler.targetSampleRate, channels: 1, interleaved: false
        )
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber], considering: natural) else {
            throw TranscriptionError.recognitionFailed("Apple Speech offers no compatible audio format.")
        }
        let factory = try AnalyzerInputFactory(format: format)

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        try await analyzer.prepareToAnalyze(in: format)

        let results = Task {
            var mapper = SpeechResultMapper(timeOffset: timeOffset)
            do {
                for try await result in transcriber.results {
                    let event = mapper.map(
                        text: String(result.text.characters),
                        start: result.range.start.seconds,
                        end: result.range.end.seconds,
                        isFinal: result.isFinal
                    )
                    if let event { sink.send(event) }
                }
            } catch {
                sink.finish(throwing: error)
            }
        }
        let (inputs, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .unbounded)
        do {
            try await analyzer.start(inputSequence: inputs)
        } catch {
            results.cancel()
            throw error
        }
        return AnalyzerSession(analyzer: analyzer, inputs: continuation, factory: factory, results: results)
    }

    // MARK: Live capture

    private func openSession(
        options: TranscriptionOptions
    ) async throws -> (stream: AsyncThrowingStream<TranscriptionEvent, Error>, sink: EventSink, analyzer: AnalyzerSession, diarization: DiarizationFeed?) {
        let (stream, continuation) = AsyncThrowingStream<TranscriptionEvent, Error>.makeStream(bufferingPolicy: .unbounded)
        let sink = EventSink(continuation: continuation, timeOffset: options.timeOffset, labelSpeakers: options.diarize)
        let diarization = options.diarize ? await DiarizationFeed.start(sink: sink) : nil
        if diarization == nil { sink.stopLabeling() }
        do {
            let analyzer = try await openAnalyzer(sink: sink, timeOffset: options.timeOffset)
            return (stream, sink, analyzer, diarization)
        } catch {
            diarization?.cancel()
            throw error
        }
    }

    func startLive(options: TranscriptionOptions) async throws -> AsyncThrowingStream<TranscriptionEvent, Error> {
        guard live == nil, !isStarting else { throw TranscriptionError.alreadyRunning }
        isStarting = true
        defer { isStarting = false }
        let session = try await openSession(options: options)
        let capture = AudioCapture()
        let audio: AsyncThrowingStream<AudioCaptureEvent, Error>
        do {
            audio = try await capture.start(deviceID: options.inputDeviceID)
        } catch {
            session.diarization?.cancel()
            await session.analyzer.cancel()
            throw error
        }
        let task = Task {
            await SessionRunner.runLive(audio: audio, recognizer: session.analyzer, diarization: session.diarization, sink: session.sink)
            await capture.stop()
        }
        live = LiveSession(capture: capture, task: task)
        session.sink.onTermination { [weak self] in
            Task { await self?.stopLive() }
        }
        return session.stream
    }

    func stopLive() async {
        guard let session = live else { return }
        live = nil
        await session.capture.stop()
        await session.task.value
    }

    // MARK: File transcription

    func transcribeFile(at url: URL, options: TranscriptionOptions) async throws -> AsyncThrowingStream<TranscriptionEvent, Error> {
        let source = try AudioFileSource(url: url)
        let session = try await openSession(options: options)
        let task = Task {
            await SessionRunner.runFile(source: source, recognizer: session.analyzer, diarization: session.diarization, sink: session.sink)
        }
        session.sink.onTermination { task.cancel() }
        return session.stream
    }
}
