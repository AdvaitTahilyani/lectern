@preconcurrency import AVFoundation
import Speech

/// Converts 16 kHz mono Float32 samples into `AnalyzerInput` buffers in the format the speech
/// analyzer asked for. Holds one persistent converter; single-consumer.
final class AnalyzerInputFactory {
    private let format: AVAudioFormat
    private let source = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: MonoResampler.targetSampleRate, channels: 1, interleaved: false
    )!
    private let converter: AVAudioConverter?

    /// - Parameter format: the analyzer's preferred input format.
    init(format: AVAudioFormat) throws {
        self.format = format
        if format == source {
            converter = nil
        } else {
            guard let converter = AVAudioConverter(from: source, to: format) else {
                throw TranscriptionError.audioEngineFailed("Cannot convert audio to the speech analyzer format \(format)")
            }
            self.converter = converter
        }
    }

    func input(for samples: [Float]) throws -> AnalyzerInput? {
        guard !samples.isEmpty else { return nil }
        guard let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = input.floatChannelData?[0]
        else { throw TranscriptionError.audioEngineFailed("Could not allocate an audio buffer") }
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        input.frameLength = AVAudioFrameCount(samples.count)
        guard let converter else { return AnalyzerInput(buffer: input) }

        let ratio = format.sampleRate / source.sampleRate
        let capacity = AVAudioFrameCount((Double(samples.count) * ratio).rounded(.up)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw TranscriptionError.audioEngineFailed("Could not allocate a conversion buffer")
        }
        var supplied = false
        var failure: NSError?
        let status = converter.convert(to: output, error: &failure) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return input
        }
        if status == .error {
            throw TranscriptionError.audioEngineFailed(failure?.localizedDescription ?? "audio conversion failed")
        }
        return output.frameLength > 0 ? AnalyzerInput(buffer: output) : nil
    }
}
