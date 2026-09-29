import Foundation
import Testing
@testable import LecternImport

@Suite struct MPEGTSAudioDemuxerTests {
    static func frames(_ count: Int, size: Int = 90) -> [Data] {
        (0..<count).map { index in TSBuilder.adtsFrame(payload: (0..<size).map { UInt8(truncatingIfNeeded: index &+ $0) & 0x7F }) }
    }

    @Test func extractsAudioFramesAcrossPESPacketsAndIgnoresVideo() throws {
        let frames = Self.frames(12)
        // Two PES packets, each spanning several 188-byte transport packets.
        let chunks = [frames[0..<7].reduce(Data(), +), frames[7...].reduce(Data(), +)]
        let audio = try MPEGTSAudioDemuxer.extractAudio(from: TSBuilder.segment(audioChunks: chunks))
        #expect(audio.codec == .aacADTS)
        #expect(audio.data == frames.reduce(Data(), +))
    }

    @Test func dropsFramesTruncatedAtSegmentBoundaries() throws {
        let frames = Self.frames(6)
        var stream = frames.reduce(Data(), +)
        stream.removeFirst(30)                 // segment starts mid-frame
        stream.removeLast(20)                  // and ends mid-frame
        let audio = try MPEGTSAudioDemuxer.extractAudio(from: TSBuilder.segment(audioChunks: [stream]))
        #expect(audio.data == frames[1..<5].reduce(Data(), +))
    }

    @Test func resynchronizesAfterGarbage() {
        let frames = Self.frames(4)
        let stream = Data([0x12, 0x34, 0xFF, 0x00]) + frames[0] + frames[1] + frames[2]
        #expect(MPEGTSAudioDemuxer.adtsFrames(in: stream) == frames[0] + frames[1] + frames[2])
    }

    @Test func reportsMp3AsPassThrough() throws {
        let payload = Data(repeating: 0x55, count: 500)
        let audio = try MPEGTSAudioDemuxer.extractAudio(from: TSBuilder.segment(audioChunks: [payload], streamType: 0x03))
        #expect(audio.codec == .mp3)
        #expect(audio.data == payload)
    }

    @Test func rejectsUnsupportedCodecsAndNonTransportData() {
        let ac3 = TSBuilder.segment(audioChunks: [Data(repeating: 1, count: 100)], streamType: 0x81)
        #expect(throws: ImportError.self) { try MPEGTSAudioDemuxer.extractAudio(from: ac3) }
        #expect(throws: ImportError.self) { try MPEGTSAudioDemuxer.extractAudio(from: Data("<html>error</html>".utf8)) }
    }
}
