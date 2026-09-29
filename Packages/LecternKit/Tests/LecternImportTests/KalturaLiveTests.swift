import AVFoundation
import Foundation
import LecternCore
import Testing
@testable import LecternImport

/// Talks to the real Kaltura using the session token in the saved MediaSpace page.
/// Run with `LECTERN_LIVE_TESTS=1`; fails with `sessionExpired` once the saved token has lapsed.
@Suite(.enabled(if: TestData.live && TestData.exists(TestData.savedPage)), .serialized) struct KalturaLiveTests {
    static func source() throws -> MediaSpaceSource {
        let html = try String(contentsOf: TestData.savedPage, encoding: .utf8)
        return try MediaSpaceScraper.scrape(html: html, pageURL: URL(string: "https://mediaspace.illinois.edu/media/t/1_oj3ppr67/414259392"))
    }

    static func normalized(_ segments: [TranscriptSegment]) -> String {
        segments.map(\.text).joined(separator: " ")
    }

    @Test func apiAndHLSCaptionsMatchTheSavedVTT() async throws {
        let source = try Self.source()
        let client = KalturaClient()

        let viaAPI = try await client.captions(for: source)
        let viaHLS = CaptionMerger().merge(try await client.hlsCaptionCues(for: source))
        let saved = CaptionMerger().merge(WebVTT.parse(try String(contentsOf: TestData.captions, encoding: .utf8)))

        #expect(viaAPI.count > 100)
        #expect(Self.normalized(viaAPI) == Self.normalized(saved))
        #expect(Self.normalized(viaHLS) == Self.normalized(saved))
        #expect(viaAPI.map(\.start) == saved.map(\.start))
    }

    @Test func importsCaptionsIntoASession() async throws {
        let source = try Self.source()
        let importer = RecordingImporter(makeEngine: { FakeEngine() }, makeBrain: { _ in FakeBrain() })
        let result = try await importer.importRecording(.mediaSpace(source, preferCaptions: true), into: LectureSession(title: ""), progress: { _ in })
        #expect(result.title == "Compiler Construction (CS 426 NG) (CS 426 NU) Fall 2026")
        #expect(result.source == .mediaSpace(entryID: "1_oj3ppr67", pageURL: source.pageURL, usedCaptions: true))
        #expect(result.duration > 5000)
        #expect(result.takeaways.count > 10)
    }

    @Test func hlsSegmentsBecomePlayableAudio() async throws {
        let source = try Self.source()
        let fetcher = HTTPFetcher(session: URLSession(configuration: .ephemeral))
        let manifest = KalturaURLs.hlsManifest(for: source)
        let master = try HLSParser.parseMaster(try await fetcher.string(from: manifest), baseURL: manifest)
        let stream = try #require(master.cheapestAudioStream)
        let full = try HLSParser.parseMedia(try await fetcher.string(from: stream), baseURL: stream)
        let head = HLSMediaPlaylist(segments: Array(full.segments.prefix(30)))

        let directory = try makeTemporaryDirectory("live")
        defer { try? FileManager.default.removeItem(at: directory) }
        let progress = ProgressLog()
        let aac = try await HLSAudioDownloader(fetcher: fetcher).download(head, toStem: directory.appendingPathComponent("hls")) { progress.append($0) }
        #expect(aac.pathExtension == "aac")
        #expect(progress.values.last == 1)

        let wav = directory.appendingPathComponent("hls.wav")
        let seconds = try await AudioExtractor().extract(from: aac, to: wav)
        #expect(abs(seconds - head.totalDuration) < 0.1, "\(seconds)s of audio for \(head.totalDuration)s of segments")
    }

    @Test func progressiveDownloadOfTheSmallestFlavorMatchesTheReferenceAudio() async throws {
        let source = try Self.source()
        let directory = try makeTemporaryDirectory("live")
        defer { try? FileManager.default.removeItem(at: directory) }
        let progress = ProgressLog()
        let media = try await KalturaClient().downloadMedia(for: source, into: directory) { progress.append($0) }
        #expect(media.pathExtension == "mp4")
        #expect(progress.values.last == 1)

        let wav = directory.appendingPathComponent("lecture.wav")
        let seconds = try await AudioExtractor().extract(from: media, to: wav)
        // TestData/cs426-lecture.wav is the same lecture (16 kHz mono s16).
        if TestData.exists(TestData.directory.appendingPathComponent("cs426-lecture.wav")) {
            let reference = try AVAudioFile(forReading: TestData.directory.appendingPathComponent("cs426-lecture.wav"))
            let referenceSeconds = Double(reference.length) / reference.processingFormat.sampleRate
            #expect(abs(seconds - referenceSeconds) < 2, "\(seconds)s vs reference \(referenceSeconds)s")
        }
        #expect(seconds > 5000)
    }
}
