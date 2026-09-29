@preconcurrency import AVFoundation

/// Converts audio buffers of any format to the 16 kHz mono Float32 stream both speech engines
/// expect. One instance owns one persistent `AVAudioConverter`, so resampler state carries across
/// buffers (no clicks or drift at buffer seams). Not thread-safe: use from one place at a time.
final class MonoResampler {
    static let targetSampleRate: Double = 16_000

    private let converter: AVAudioConverter?
    /// Non-nil when the source must be mixed down to mono at its native rate before resampling.
    private let mixdownFormat: AVAudioFormat?
    private let ratio: Double

    /// - Throws: `TranscriptionError.audioEngineFailed` if no conversion path exists.
    init(from source: AVAudioFormat) throws {
        let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: Self.targetSampleRate, channels: 1, interleaved: false
        )!
        ratio = Self.targetSampleRate / source.sampleRate

        let canMixManually = source.commonFormat == .pcmFormatFloat32 && !source.isInterleaved
        var converterSource = source
        if canMixManually, source.channelCount > 1 {
            // Averaging (stereo) or taking the first channel (multi-channel interfaces) keeps
            // the result independent of channel layouts, which many input devices don't declare.
            let mono = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: source.sampleRate, channels: 1, interleaved: false
            )!
            mixdownFormat = mono
            converterSource = mono
        } else {
            mixdownFormat = nil
        }

        if converterSource.sampleRate == Self.targetSampleRate,
           converterSource.channelCount == 1, converterSource.commonFormat == .pcmFormatFloat32,
           !converterSource.isInterleaved
        {
            converter = nil
        } else {
            guard let made = AVAudioConverter(from: converterSource, to: target) else {
                throw TranscriptionError.audioEngineFailed("Cannot convert \(source) to 16 kHz mono")
            }
            made.sampleRateConverterQuality = AVAudioQuality.high.rawValue
            converter = made
        }
    }

    /// Converts one buffer, returning the 16 kHz mono samples it produced (possibly none while the
    /// resampler is priming).
    func convert(_ buffer: AVAudioPCMBuffer) throws -> [Float] {
        let input = mixdownFormat.map { mixDown(buffer, to: $0) } ?? buffer
        guard let converter else { return Self.samples(of: input) }
        let capacity = AVAudioFrameCount((Double(input.frameLength) * ratio).rounded(.up)) + 64
        return try run(converter, capacity: capacity) { supplied in
            if supplied { return (.noDataNow, nil) }
            return (.haveData, input)
        }
    }

    /// Drains the resampler at end of input.
    func flush() throws -> [Float] {
        guard let converter else { return [] }
        return try run(converter, capacity: 1024) { _ in (.endOfStream, nil) }
    }

    private func run(
        _ converter: AVAudioConverter,
        capacity: AVAudioFrameCount,
        supply: @escaping (_ alreadySupplied: Bool) -> (AVAudioConverterInputStatus, AVAudioBuffer?)
    ) throws -> [Float] {
        guard let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity) else {
            throw TranscriptionError.audioEngineFailed("Could not allocate a conversion buffer")
        }
        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            let (status, buffer) = supply(supplied)
            supplied = true
            inputStatus.pointee = status
            return buffer
        }
        if status == .error {
            throw TranscriptionError.audioEngineFailed(conversionError?.localizedDescription ?? "sample-rate conversion failed")
        }
        return Self.samples(of: output)
    }

    private func mixDown(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) -> AVAudioPCMBuffer {
        let frames = Int(buffer.frameLength)
        guard let mono = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buffer.frameLength),
              let source = buffer.floatChannelData, let destination = mono.floatChannelData?[0]
        else { return buffer }
        mono.frameLength = buffer.frameLength
        let channels = Int(buffer.format.channelCount)
        if channels == 2 {
            for frame in 0..<frames { destination[frame] = 0.5 * (source[0][frame] + source[1][frame]) }
        } else {
            destination.update(from: source[0], count: frames)
        }
        return mono
    }

    static func samples(of buffer: AVAudioPCMBuffer) -> [Float] {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return [] }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))
    }
}
