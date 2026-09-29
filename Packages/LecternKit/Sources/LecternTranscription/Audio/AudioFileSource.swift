@preconcurrency import AVFoundation

/// Reads an audio file sequentially as 16 kHz mono Float32 samples.
///
/// `@unchecked Sendable`: it is created on one task and then handed to exactly one reading task;
/// its mutable state (file position, converter) is never touched concurrently.
final class AudioFileSource: @unchecked Sendable {
    private let file: AVAudioFile
    private let resampler: MonoResampler
    private var finished = false

    /// Duration of the file's audio in seconds.
    let duration: TimeInterval

    init(url: URL) throws {
        do {
            file = try AVAudioFile(forReading: url)
            resampler = try MonoResampler(from: file.processingFormat)
        } catch let error as TranscriptionError {
            throw error
        } catch {
            throw TranscriptionError.fileUnreadable(url, error.localizedDescription)
        }
        duration = Double(file.length) / file.processingFormat.sampleRate
    }

    /// The next `seconds` of audio, or nil at end of file.
    func read(seconds: TimeInterval) throws -> [Float]? {
        guard !finished else { return nil }
        guard file.framePosition < file.length else {
            finished = true
            let tail = try resampler.flush()
            return tail.isEmpty ? nil : tail
        }
        let format = file.processingFormat
        let frames = AVAudioFrameCount(seconds * format.sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            throw TranscriptionError.audioEngineFailed("Could not allocate a read buffer")
        }
        try file.read(into: buffer)
        return try resampler.convert(buffer)
    }
}
