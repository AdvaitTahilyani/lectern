import AudioToolbox
import AVFoundation
import Foundation

/// Decodes a raw AAC (ADTS) or MP3 file with `ExtAudioFile`, which scans the whole stream rather
/// than trusting an estimated duration, converting to the extractor's 16 kHz mono Float32 as it goes.
final class ElementaryStreamPass: ExtractionPass, @unchecked Sendable {
    private let source: URL
    private let destination: URL
    private let progress: @Sendable (Double) -> Void
    private let queue = DispatchQueue(label: "lectern.import.stream-extract", qos: .userInitiated)
    private let cancelled = CancellationFlag()

    /// Frames read per `ExtAudioFileRead` call (at the output rate).
    private static let chunkFrames: UInt32 = 16_384

    init(source: URL, destination: URL, progress: @escaping @Sendable (Double) -> Void) {
        self.source = source
        self.destination = destination
        self.progress = progress
    }

    func run() async throws -> TimeInterval {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<TimeInterval, Error>) in
            queue.async { continuation.resume(with: Result { try self.transcode() }) }
        }
    }

    func cancel() { cancelled.set() }

    private func transcode() throws -> TimeInterval {
        if cancelled.isSet { throw CancellationError() }
        var opened: ExtAudioFileRef?
        guard ExtAudioFileOpenURL(source as CFURL, &opened) == noErr, let input = opened else {
            throw ImportError.unreadableMedia("\(source.lastPathComponent) isn't a readable audio stream")
        }
        defer { ExtAudioFileDispose(input) }

        var clientFormat = ExtractedAudioFormat.format.streamDescription.pointee
        guard ExtAudioFileSetProperty(input, kExtAudioFileProperty_ClientDataFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &clientFormat) == noErr else {
            throw ImportError.unreadableMedia("unsupported audio format")
        }
        let estimatedFrames = Self.estimatedLength(of: input)

        var framesWritten: AVAudioFramePosition = 0
        do {
            let file = try ExtractedAudioFormat.makeFile(at: destination)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: ExtractedAudioFormat.format, frameCapacity: Self.chunkFrames) else {
                throw ImportError.unreadableMedia("out of memory")
            }
            while true {
                if cancelled.isSet { throw CancellationError() }
                var frames = Self.chunkFrames
                let list = buffer.mutableAudioBufferList
                list.pointee.mBuffers.mDataByteSize = frames * UInt32(MemoryLayout<Float>.size)
                let status = ExtAudioFileRead(input, &frames, list)
                guard status == noErr else { throw ImportError.unreadableMedia("decoding failed (\(status))") }
                if frames == 0 { break }
                buffer.frameLength = frames
                try file.write(from: buffer)
                framesWritten += AVAudioFramePosition(frames)
                if estimatedFrames > 0 { progress(min(0.99, Double(framesWritten) / Double(estimatedFrames))) }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ImportError {
            throw error
        } catch {
            throw ImportError.unreadableMedia(error.localizedDescription)
        }
        guard framesWritten > 0 else { throw ImportError.noAudioTrack }
        return Double(framesWritten) / AudioExtractor.sampleRate
    }

    /// Length in output frames as the file reports it (an estimate for unindexed streams; used
    /// for progress only).
    private static func estimatedLength(of file: ExtAudioFileRef) -> Int64 {
        var length: Int64 = 0
        var size = UInt32(MemoryLayout<Int64>.size)
        guard ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileLengthFrames, &size, &length) == noErr else { return 0 }
        var format = AudioStreamBasicDescription()
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileDataFormat, &formatSize, &format) == noErr, format.mSampleRate > 0 else { return 0 }
        return Int64(Double(length) * AudioExtractor.sampleRate / format.mSampleRate)
    }
}
