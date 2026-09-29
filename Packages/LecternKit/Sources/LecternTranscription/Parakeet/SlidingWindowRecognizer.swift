@preconcurrency import AVFoundation
import FluidAudio
import Foundation

/// Fallback `StreamingRecognizer` over FluidAudio's sliding-window manager (Parakeet TDT, 11 s
/// windows). Slower to react than the unified streamer, but the longest-tested FluidAudio path.
actor SlidingWindowRecognizer: StreamingRecognizer {
    private let manager: SlidingWindowAsrManager
    private var pumpTask: Task<Void, Never>?
    private var pendingTokens: [RecognizedToken] = []
    private var lastTokenEnd: TimeInterval = 0

    /// - Parameter manager: a manager with loaded models, not yet streaming.
    init(manager: SlidingWindowAsrManager) async throws {
        self.manager = manager
        try await manager.reset()
        try await manager.startStreaming(source: .microphone)
        let updates = await manager.transcriptionUpdates
        pumpTask = Task { [weak self] in
            for await update in updates {
                await self?.receive(update)
            }
        }
    }

    private func receive(_ update: SlidingWindowTranscriptionUpdate) {
        let tokens = update.tokenTimings.map { RecognizedToken(text: $0.token, start: $0.startTime, end: $0.endTime) }
        pendingTokens.append(contentsOf: tokens)
        lastTokenEnd = max(lastTokenEnd, tokens.last?.end ?? 0)
    }

    func append(_ samples: [Float]) async throws -> RecognizerUpdate? {
        guard !samples.isEmpty else { return nil }
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: MonoResampler.targetSampleRate, channels: 1, interleaved: false
        )!
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0]
        else { throw TranscriptionError.audioEngineFailed("Could not allocate an audio buffer") }
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        await manager.streamAudio(buffer)

        guard !pendingTokens.isEmpty else { return nil }
        let tokens = pendingTokens
        pendingTokens.removeAll()
        let confirmed = await manager.confirmedTranscript
        let volatile = await manager.volatileTranscript
        let text = [confirmed, volatile].filter { !$0.isEmpty }.joined(separator: " ")
        return RecognizerUpdate(text: text, tokens: tokens, decodedThrough: lastTokenEnd)
    }

    func cancel() async {
        await manager.cancel()
        pumpTask?.cancel()
        pumpTask = nil
    }

    func finish() async throws -> RecognizerUpdate {
        let text = try await manager.finish()
        await manager.cancel()      // ends the update stream so the pump task drains and exits
        await pumpTask?.value
        pumpTask = nil
        let tokens = pendingTokens
        pendingTokens.removeAll()
        return RecognizerUpdate(text: text, tokens: tokens, decodedThrough: .infinity)
    }
}
