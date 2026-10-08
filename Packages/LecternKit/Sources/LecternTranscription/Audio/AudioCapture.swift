@preconcurrency import AVFoundation
import CoreAudio
import Foundation
import Synchronization

/// What `AudioCapture` delivers.
public enum AudioCaptureEvent: Sendable {
    /// A chunk of 16 kHz mono Float32 audio, contiguous with the previous chunk.
    case samples([Float])
    /// Smoothed input level 0...1, ~20 times per second.
    case level(Float)
    /// A recoverable problem (device change, restart) worth showing subtly.
    case warning(String)
}

/// Microphone capture with a selectable input device.
///
/// Audio is converted on the audio thread by one persistent converter to 16 kHz mono Float32 and
/// published as `AudioCaptureEvent`s. Device or configuration changes (USB mic unplugged, default
/// device switched, sample-rate change) restart the engine, pad the gap with silence so the
/// session timeline stays continuous, and emit a `.warning`. If the engine cannot be restarted the
/// stream ends with an error.
public actor AudioCapture {
    private var engine: AVAudioEngine?
    private var processor: TapProcessor?
    private var continuation: AsyncThrowingStream<AudioCaptureEvent, Error>.Continuation?
    private var configurationObserver: NSObjectProtocol?
    private var requestedDeviceUID: String?
    private var isStarting = false
    private var isRestarting = false
    /// Bumped by every `start` and `stop`, so a restart that outlives its session (it sleeps
    /// between attempts) can tell that the session it was repairing is gone.
    private var generation = 0
    private let requestAccess: @Sendable () async throws -> Void

    public init() {
        requestAccess = { try await AudioCapture.ensureMicrophoneAccess() }
    }

    /// For tests: replaces the microphone permission check.
    init(requestAccess: @escaping @Sendable () async throws -> Void) {
        self.requestAccess = requestAccess
    }

    /// Starts capturing. `deviceID` is a CoreAudio device UID; nil follows the system default.
    /// A `stop()` while this is still waiting for microphone permission cancels it.
    /// - Throws: `TranscriptionError.microphoneAccessDenied`, `.inputDeviceNotFound`,
    ///   `.audioEngineFailed`, or `CancellationError` when stopped before capture began.
    public func start(deviceID: String?) async throws -> AsyncThrowingStream<AudioCaptureEvent, Error> {
        guard continuation == nil, !isStarting else { throw TranscriptionError.alreadyRunning }
        isStarting = true      // the permission prompt below suspends this actor; block a second start
        defer { isStarting = false }
        generation += 1
        let attempt = generation
        try await requestAccess()
        // `stop()` bumps the generation: a stop that arrived during the prompt wins.
        guard generation == attempt else { throw CancellationError() }

        let (stream, continuation) = AsyncThrowingStream<AudioCaptureEvent, Error>.makeStream(bufferingPolicy: .unbounded)
        requestedDeviceUID = deviceID
        do {
            try startEngine(deviceUID: deviceID, continuation: continuation)
        } catch {
            teardownEngine()
            throw error
        }
        self.continuation = continuation
        // A consumer that stops listening (cancelled task, dropped stream) must not leave the
        // engine running: an orphaned engine keeps reacting to device changes after its session.
        let started = generation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.stopIfStill(started) }
        }
        // The notification is posted per engine; only our own engine's changes matter.
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: nil, queue: nil
        ) { [weak self] notification in
            guard let source = notification.object else { return }
            let engine = ObjectIdentifier(source as AnyObject)
            Task { await self?.handleConfigurationChange(of: engine) }
        }
        return stream
    }

    /// Stops capturing and finishes the event stream.
    public func stop() {
        generation += 1
        if let observer = configurationObserver { NotificationCenter.default.removeObserver(observer) }
        configurationObserver = nil
        teardownEngine()
        continuation?.finish()
        continuation = nil
    }

    /// Stops only if no newer `start`/`stop` has happened since `session` began.
    private func stopIfStill(_ session: Int) {
        guard generation == session, continuation != nil else { return }
        stop()
    }

    // MARK: - Engine lifecycle

    private func startEngine(
        deviceUID: String?, continuation: AsyncThrowingStream<AudioCaptureEvent, Error>.Continuation
    ) throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if let deviceUID {
            guard let device = CoreAudioDevices.deviceID(forUID: deviceUID) else {
                throw TranscriptionError.inputDeviceNotFound(deviceUID)
            }
            try Self.select(device, on: input)
        }
        // Read the format only after the device is set: it follows the device's hardware format.
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw TranscriptionError.audioEngineFailed("The input device reports no usable audio format.")
        }
        // Mid device-change the node's output format can lag the hardware's. Installing a tap with
        // a mismatched format raises an Objective-C exception (an uncatchable abort), so treat it
        // as a retryable failure instead.
        let hardware = input.inputFormat(forBus: 0)
        guard hardware.sampleRate == format.sampleRate, hardware.channelCount >= 1 else {
            throw TranscriptionError.audioEngineFailed("The input device is still changing format.")
        }
        let processor = try TapProcessor(format: format, continuation: continuation)
        Self.installTap(on: input, format: format, processor: processor)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw TranscriptionError.audioEngineFailed(error.localizedDescription)
        }
        self.engine = engine
        self.processor = processor
    }

    private func teardownEngine() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        processor = nil
    }

    /// Nonisolated on purpose: the tap block runs on the realtime audio thread and must not
    /// inherit this actor's isolation.
    private nonisolated static func installTap(on node: AVAudioInputNode, format: AVAudioFormat, processor: TapProcessor) {
        node.installTap(onBus: 0, bufferSize: 2048, format: format) { @Sendable buffer, _ in
            processor.process(buffer)
        }
    }

    static func select(_ device: AudioDeviceID, on node: AVAudioInputNode) throws {
        guard let unit = node.audioUnit else {
            throw TranscriptionError.audioEngineFailed("The input node has no audio unit.")
        }
        var deviceID = device
        let status = AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
            &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            throw TranscriptionError.audioEngineFailed("Could not select the input device (OSStatus \(status)).")
        }
    }

    static func ensureMicrophoneAccess() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .audio) else { throw TranscriptionError.microphoneAccessDenied }
        default:
            throw TranscriptionError.microphoneAccessDenied
        }
    }

    // MARK: - Configuration changes

    /// The engine stopped itself (device unplugged, default input or sample rate changed).
    /// Rebuild it, falling back to the system default input if the chosen device is gone.
    private func handleConfigurationChange(of changed: ObjectIdentifier) async {
        guard let continuation, !isRestarting, let engine, changed == ObjectIdentifier(engine) else { return }
        isRestarting = true
        defer { isRestarting = false }
        let session = generation

        let gapStart = ContinuousClock.now
        teardownEngine()
        // Device switches post several changes in a row; rebuilding immediately races them.
        try? await Task.sleep(for: .milliseconds(300))

        var deviceUID = requestedDeviceUID
        var lastError: Error = TranscriptionError.audioEngineFailed("The audio engine could not be restarted.")
        for attempt in 1...4 {
            guard generation == session else { return }   // stopped (or restarted) while waiting to retry
            do {
                try startEngine(deviceUID: deviceUID, continuation: continuation)
                let gap = ContinuousClock.now - gapStart
                padSilence(for: gap, into: continuation)
                let fellBack = deviceUID != requestedDeviceUID
                continuation.yield(.warning(fellBack
                    ? "Selected microphone disconnected; using the system default input."
                    : "Audio input changed; capture restarted."))
                return
            } catch TranscriptionError.inputDeviceNotFound {
                deviceUID = nil   // the chosen device is gone: follow the system default instead
                lastError = TranscriptionError.inputDeviceNotFound(requestedDeviceUID ?? "")
            } catch {
                lastError = error
                try? await Task.sleep(for: .milliseconds(250 * attempt))
            }
        }
        guard generation == session else { return }
        continuation.finish(throwing: lastError)
        stop()
    }

    /// Keeps the session clock honest across a restart by inserting silence for the lost time.
    private func padSilence(for gap: Duration, into continuation: AsyncThrowingStream<AudioCaptureEvent, Error>.Continuation) {
        let seconds = Double(gap.components.seconds) + Double(gap.components.attoseconds) / 1e18
        guard seconds >= 0.25 else { return }
        let count = Int(min(seconds, 30) * MonoResampler.targetSampleRate)
        continuation.yield(.samples([Float](repeating: 0, count: count)))
    }
}

/// Runs on the realtime audio thread: resamples, meters, and publishes each tap buffer.
private final class TapProcessor: Sendable {
    private struct State {
        var resampler: MonoResampler
        var meter = LevelMeter()
        var reportedFailure = false
    }

    private let state: Mutex<State>
    private let continuation: AsyncThrowingStream<AudioCaptureEvent, Error>.Continuation

    init(format: AVAudioFormat, continuation: AsyncThrowingStream<AudioCaptureEvent, Error>.Continuation) throws {
        self.state = Mutex(State(resampler: try MonoResampler(from: format)))
        self.continuation = continuation
    }

    func process(_ buffer: AVAudioPCMBuffer) {
        let outcome: Result<(samples: [Float], levels: [Float]), Error> = state.withLock { state in
            do {
                let samples = try state.resampler.convert(buffer)
                return .success((samples, state.meter.feed(samples)))
            } catch {
                return .failure(error)
            }
        }
        switch outcome {
        case .success(let (samples, levels)):
            if !samples.isEmpty { continuation.yield(.samples(samples)) }
            for level in levels { continuation.yield(.level(level)) }
        case .failure(let error):
            let firstFailure = state.withLock { state -> Bool in
                defer { state.reportedFailure = true }
                return !state.reportedFailure
            }
            if firstFailure { continuation.yield(.warning("Audio conversion problem: \(error.localizedDescription)")) }
        }
    }
}
