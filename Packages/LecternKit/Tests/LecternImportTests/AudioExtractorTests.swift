import AVFoundation
import Foundation
import Testing
@testable import LecternImport

@Suite(.enabled(if: SpeechFixture.isAvailable)) struct AudioExtractorTests {
    static let sentence = "Welcome to compilers. Today we will talk about parsing, first sets, and follow sets. Please open your notes."

    static func sourceDuration(_ url: URL) async throws -> TimeInterval {
        try await AVURLAsset(url: url).load(.duration).seconds
    }

    static func assertSpeechWAV(_ wav: URL, expectedDuration: TimeInterval, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let file = try AVAudioFile(forReading: wav)
        #expect(file.processingFormat.sampleRate == 16_000, sourceLocation: sourceLocation)
        #expect(file.processingFormat.channelCount == 1, sourceLocation: sourceLocation)
        #expect(file.processingFormat.commonFormat == .pcmFormatFloat32, sourceLocation: sourceLocation)
        let seconds = Double(file.length) / file.processingFormat.sampleRate
        #expect(abs(seconds - expectedDuration) < 0.35, "WAV is \(seconds)s, source is \(expectedDuration)s", sourceLocation: sourceLocation)

        // Real audio, not silence.
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        let samples = UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
        let peak = samples.reduce(0) { max($0, abs($1)) }
        #expect(peak > 0.05, sourceLocation: sourceLocation)
    }

    @Test(arguments: ["m4a", "mp4", "wav", "aiff", "adts"])
    func extractsSixteenKilohertzMonoFloatWAV(format: String) async throws {
        let directory = try makeTemporaryDirectory("audio")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try SpeechFixture.make(Self.sentence, format: format, in: directory)
        let destination = directory.appendingPathComponent("out.wav")

        let progress = ProgressLog()
        let duration = try await AudioExtractor().extract(from: source, to: destination) { progress.append($0) }

        let expected = try await Self.sourceDuration(source)
        try Self.assertSpeechWAV(destination, expectedDuration: expected)
        #expect(abs(duration - expected) < 0.35)
        #expect(progress.values.last == 1)
        #expect(zip(progress.values, progress.values.dropFirst()).allSatisfy { $0 <= $1 })
    }

    @Test func replacesAnExistingDestination() async throws {
        let directory = try makeTemporaryDirectory("audio")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try SpeechFixture.make("Hello there.", format: "m4a", in: directory)
        let destination = directory.appendingPathComponent("out.wav")
        try Data("stale".utf8).write(to: destination)
        try await AudioExtractor().extract(from: source, to: destination)
        #expect(try AVAudioFile(forReading: destination).length > 0)
    }

    @Test func rejectsFilesThatAreNotMedia() async throws {
        let directory = try makeTemporaryDirectory("audio")
        defer { try? FileManager.default.removeItem(at: directory) }
        let text = directory.appendingPathComponent("notes.m4a")
        try "definitely not audio".write(to: text, atomically: true, encoding: .utf8)
        let destination = directory.appendingPathComponent("out.wav")
        await #expect(throws: ImportError.self) { try await AudioExtractor().extract(from: text, to: destination) }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/ffmpeg")))
    func reportsVideosWithoutAudio() async throws {
        let directory = try makeTemporaryDirectory("audio")
        defer { try? FileManager.default.removeItem(at: directory) }
        let silent = directory.appendingPathComponent("silent.mp4")
        try SpeechFixture.run("/opt/homebrew/bin/ffmpeg", ["-loglevel", "error", "-f", "lavfi", "-i", "color=c=black:s=64x64:d=1", "-pix_fmt", "yuv420p", silent.path])
        await #expect(throws: ImportError.noAudioTrack) {
            try await AudioExtractor().extract(from: silent, to: directory.appendingPathComponent("out.wav"))
        }
    }

    @Test func cancellationRemovesThePartialFile() async throws {
        let directory = try makeTemporaryDirectory("audio")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try SpeechFixture.make(Self.sentence, format: "m4a", in: directory)
        let destination = directory.appendingPathComponent("out.wav")
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            return try await AudioExtractor().extract(from: source, to: destination)
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    /// AVFoundation estimates the length of raw ADTS streams from the first frames and stops there:
    /// this 240 s variable-bitrate stream reads as ~102 s through `AVAssetReader`.
    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/ffmpeg")))
    func longVariableBitrateADTSIsNotTruncated() async throws {
        let directory = try makeTemporaryDirectory("audio")
        defer { try? FileManager.default.removeItem(at: directory) }
        let wav = directory.appendingPathComponent("long.wav")
        try SpeechFixture.run("/opt/homebrew/bin/ffmpeg", [
            "-loglevel", "error", "-f", "lavfi", "-i", "anoisesrc=d=20:c=pink:a=0.3,volume='if(lt(mod(t,4),1),1,0.02)':eval=frame",
            "-f", "lavfi", "-i", "sine=f=300:d=220", "-filter_complex", "[0][1]concat=n=2:v=0:a=1", "-ar", "44100", "-ac", "2", wav.path,
        ])
        let adts = directory.appendingPathComponent("long.aac")
        try SpeechFixture.run("/usr/bin/afconvert", ["-f", "adts", "-d", "aac", "-s", "3", "-b", "48000", wav.path, adts.path])

        let progress = ProgressLog()
        let out = directory.appendingPathComponent("out.wav")
        let seconds = try await AudioExtractor().extract(from: adts, to: out) { progress.append($0) }
        #expect(abs(seconds - 240) < 0.2, "decoded \(seconds)s of a 240 s stream")
        let file = try AVAudioFile(forReading: out)
        #expect(abs(Double(file.length) / 16_000 - 240) < 0.2)
        #expect(progress.values.last == 1)
    }
}
