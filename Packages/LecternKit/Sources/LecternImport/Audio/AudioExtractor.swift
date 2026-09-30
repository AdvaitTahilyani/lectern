import AVFoundation
import Foundation

/// Decodes the audio of any AVFoundation-readable audio or video file (mp4, mov, m4a, mp3, wav,
/// aac…) into a 16 kHz mono Float32 WAV, the format the speech engines consume.
///
/// Raw `.aac` (ADTS) and `.mp3` streams have no index, so AVFoundation *estimates* their length and
/// stops reading there, silently dropping the tail of long files. Those are decoded with
/// AudioToolbox instead, which reads to the last frame.
public struct AudioExtractor: Sendable {
    /// Sample rate of the extracted WAV.
    public static let sampleRate: Double = 16_000

    /// Extensions of elementary streams that must not go through AVFoundation.
    private static let unindexedStreamExtensions: Set<String> = ["aac", "mp3"]

    public init() {}

    /// Writes the mixed-down audio of `source` to `destination` (replacing any existing file).
    /// - Parameter progress: 0...1 over the decoded audio.
    /// - Returns: the duration of the extracted audio in seconds.
    /// - Throws: `ImportError.noAudioTrack`, `ImportError.unreadableMedia`, or `CancellationError`
    ///   (the partial file is removed in every failure case).
    @discardableResult
    public func extract(
        from source: URL,
        to destination: URL,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> TimeInterval {
        try? FileManager.default.removeItem(at: destination)
        let pass: any ExtractionPass
        if Self.unindexedStreamExtensions.contains(source.pathExtension.lowercased()) {
            pass = ElementaryStreamPass(source: source, destination: destination, progress: progress)
        } else {
            pass = try await AssetReaderPass(source: source, destination: destination, progress: progress)
        }
        do {
            let written = try await withTaskCancellationHandler {
                try await pass.run()
            } onCancel: {
                pass.cancel()
            }
            progress(1)
            return written
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }
}

/// One decode of a source file into the WAV at `destination`.
protocol ExtractionPass: Sendable {
    /// Returns the seconds of audio written.
    func run() async throws -> TimeInterval
    /// Makes a running `run()` throw `CancellationError` promptly; callable from any thread.
    func cancel()
}

/// The WAV every pass writes: 16 kHz, mono, Float32.
enum ExtractedAudioFormat {
    static var settings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: AudioExtractor.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
    }

    static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioExtractor.sampleRate, channels: 1, interleaved: false)!

    static func makeFile(at url: URL) throws -> AVAudioFile {
        try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    }
}

/// Thread-safe cancellation flag shared by the passes.
final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()   // guards `value`
    private var value = false

    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

// MARK: - AVAssetReader pass

/// `AVAssetReader` produces 16 kHz mono Float32 buffers (it resamples and mixes down), which are
/// appended to the WAV. Runs on a private queue.
private final class AssetReaderPass: ExtractionPass, @unchecked Sendable {
    private let reader: AVAssetReader
    private let output: AVAssetReaderAudioMixOutput
    private let destination: URL
    private let duration: TimeInterval
    private let progress: @Sendable (Double) -> Void
    private let queue = DispatchQueue(label: "lectern.import.audio-extract", qos: .userInitiated)
    private let cancelled = CancellationFlag()

    /// Opens `source` and validates that it has readable audio.
    init(source: URL, destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let asset = AVURLAsset(url: source)
        let tracks: [AVAssetTrack]
        do {
            guard try await asset.load(.isReadable) else { throw ImportError.unreadableMedia(source.lastPathComponent) }
            tracks = try await asset.loadTracks(withMediaType: .audio)
            let seconds = try await asset.load(.duration).seconds
            duration = seconds.isFinite ? seconds : 0
        } catch let error as ImportError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ImportError.unreadableMedia(error.localizedDescription)
        }
        guard !tracks.isEmpty else { throw ImportError.noAudioTrack }
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw ImportError.unreadableMedia(error.localizedDescription)
        }
        output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: ExtractedAudioFormat.settings)
        guard reader.canAdd(output) else { throw ImportError.unreadableMedia("unsupported audio format") }
        reader.add(output)
        self.destination = destination
        self.progress = progress
    }

    func run() async throws -> TimeInterval {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<TimeInterval, Error>) in
            queue.async { continuation.resume(with: Result { try self.transcode() }) }
        }
    }

    func cancel() {
        cancelled.set()
        reader.cancelReading()
    }

    private func transcode() throws -> TimeInterval {
        if cancelled.isSet { throw CancellationError() }
        guard reader.startReading() else {
            throw ImportError.unreadableMedia(reader.error?.localizedDescription ?? "cannot start reading")
        }
        var framesWritten: AVAudioFramePosition = 0
        do {
            let file = try ExtractedAudioFormat.makeFile(at: destination)
            while let sample = output.copyNextSampleBuffer() {
                if cancelled.isSet { throw CancellationError() }
                let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sample))
                guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: ExtractedAudioFormat.format, frameCapacity: frames) else { continue }
                buffer.frameLength = frames
                let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
                guard status == noErr else { throw ImportError.unreadableMedia("decoding failed (\(status))") }
                try file.write(from: buffer)
                framesWritten += AVAudioFramePosition(frames)
                if duration > 0 { progress(min(1, Double(framesWritten) / AudioExtractor.sampleRate / duration)) }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ImportError {
            throw error
        } catch {
            throw ImportError.unreadableMedia(error.localizedDescription)
        }
        if cancelled.isSet { throw CancellationError() }
        guard reader.status == .completed else {
            throw ImportError.unreadableMedia(reader.error?.localizedDescription ?? "decoding failed")
        }
        return Double(framesWritten) / AudioExtractor.sampleRate
    }
}
