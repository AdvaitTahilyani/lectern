@preconcurrency import AVFoundation
import FluidAudio
import Foundation

/// `StreamingRecognizer` over FluidAudio's Parakeet Unified streaming manager.
///
/// The manager's text is cumulative and append-only, except that vocabulary boosting may rewrite
/// words that have not yet been rescored. It reports no final flag; `SegmentAssembler` derives
/// segments from the text and token timings.
actor UnifiedRecognizer: StreamingRecognizer {
    private let manager: StreamingUnifiedAsrManager
    private let latency: TimeInterval
    private var fedSamples = 0
    private var lastTokenEnd: TimeInterval = 0

    /// - Parameter manager: a manager with loaded models; its stream is reset here.
    init(manager: StreamingUnifiedAsrManager, latency: TimeInterval) async throws {
        self.manager = manager
        self.latency = latency
        try await manager.reset()
    }

    func append(_ samples: [Float]) async throws -> RecognizerUpdate? {
        guard !samples.isEmpty else { return nil }
        try await manager.appendAudio(Self.buffer(from: samples))
        fedSamples += samples.count
        try await manager.processBufferedAudio()
        return await snapshot()
    }

    func finish() async throws -> RecognizerUpdate {
        _ = try await manager.finish()
        return await snapshot()
    }

    func cancel() {}

    private func snapshot() async -> RecognizerUpdate {
        let tokens = await manager.consumeTokenTimings().map {
            RecognizedToken(text: $0.token, start: $0.startTime, end: $0.endTime)
        }
        lastTokenEnd = max(lastTokenEnd, tokens.last?.end ?? 0)
        // Everything before (fed audio - look-ahead) has been decoded; tokens can only lag that.
        let decoded = max(lastTokenEnd, Double(fedSamples) / MonoResampler.targetSampleRate - latency)
        return RecognizerUpdate(text: await manager.getPartialTranscript(), tokens: tokens, decodedThrough: decoded)
    }

    private static func buffer(from samples: [Float]) throws -> AVAudioPCMBuffer {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: MonoResampler.targetSampleRate, channels: 1, interleaved: false
        )!
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0]
        else { throw TranscriptionError.audioEngineFailed("Could not allocate an audio buffer") }
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        return buffer
    }
}
