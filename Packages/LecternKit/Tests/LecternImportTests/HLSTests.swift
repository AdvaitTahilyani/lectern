import Foundation
import Testing
@testable import LecternImport

@Suite struct HLSTests {
    static let base = URL(string: "https://cdn.example.com/a/b/master.m3u8")!

    static let master = """
    #EXTM3U
    #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="English, US",DEFAULT=YES,AUTOSELECT=YES,FORCED=NO,LANGUAGE="en",URI="https://cdn.example.com/subs/a.m3u8"
    #EXT-X-STREAM-INF:PROGRAM-ID=1,BANDWIDTH=567890,RESOLUTION=1920x1080,CODECS="avc1.640032,mp4a.40.2",SUBTITLES="subs"
    https://cdn.example.com/flavor/1_big/index.m3u8?Policy=abc&Signature=def
    #EXT-X-STREAM-INF:PROGRAM-ID=1,BANDWIDTH=201699,RESOLUTION=640x360,CODECS="avc1.42c01e,mp4a.40.2",SUBTITLES="subs"
    ../flavor/flavorId/1_small/index.m3u8
    """

    @Test func parsesMasterPlaylistAndPicksTheCheapestStream() throws {
        let playlist = try HLSParser.parseMaster(Self.master, baseURL: Self.base)
        #expect(playlist.variants.count == 2)
        #expect(playlist.variants[0].resolution == "1920x1080")
        #expect(playlist.cheapestAudioStream?.absoluteString == "https://cdn.example.com/a/flavor/flavorId/1_small/index.m3u8")
        #expect(KalturaURLs.flavorID(in: playlist.cheapestAudioStream!) == "1_small")
        // Quoted commas stay inside the attribute.
        #expect(playlist.renditions.first?.name == "English, US")
        #expect(playlist.subtitlePlaylist?.absoluteString == "https://cdn.example.com/subs/a.m3u8")
    }

    @Test func prefersAudioOnlyVariants() throws {
        let text = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=100000,RESOLUTION=320x180,CODECS="avc1.42c01e,mp4a.40.2"
        video.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=128000,CODECS="mp4a.40.2"
        audio.m3u8
        """
        #expect(try HLSParser.parseMaster(text, baseURL: Self.base).cheapestAudioStream?.lastPathComponent == "audio.m3u8")
    }

    @Test func prefersAnAlternateAudioRendition() throws {
        let text = """
        #EXTM3U
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a",NAME="en",URI="rendition/audio.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=100000,AUDIO="a"
        video.m3u8
        """
        #expect(try HLSParser.parseMaster(text, baseURL: Self.base).cheapestAudioStream?.path == "/a/b/rendition/audio.m3u8")
    }

    @Test func parsesMediaPlaylist() throws {
        let text = """
        #EXTM3U
        #EXT-X-TARGETDURATION:10
        #EXT-X-PLAYLIST-TYPE:VOD
        #EXTINF:2.000,
        seg-1.ts?Policy=x
        #EXTINF:9.467,
        https://other.example.com/seg-2.ts
        #EXT-X-ENDLIST
        """
        let playlist = try HLSParser.parseMedia(text, baseURL: Self.base)
        #expect(playlist.segments.map(\.url.absoluteString) == ["https://cdn.example.com/a/b/seg-1.ts?Policy=x", "https://other.example.com/seg-2.ts"])
        #expect(abs(playlist.totalDuration - 11.467) < 0.001)
    }

    @Test func rejectsEncryptedAndFragmentedStreams() {
        #expect(throws: ImportError.self) {
            try HLSParser.parseMedia("#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI=\"k\"\n#EXTINF:1,\ns.ts", baseURL: Self.base)
        }
        #expect(throws: ImportError.self) {
            try HLSParser.parseMedia("#EXTM3U\n#EXT-X-MAP:URI=\"init.mp4\"\n#EXTINF:1,\ns.m4s", baseURL: Self.base)
        }
        #expect(throws: ImportError.self) { try HLSParser.parseMedia("#EXTM3U\n", baseURL: Self.base) }
        #expect(throws: ImportError.self) { try HLSParser.parseMaster("#EXTM3U\n", baseURL: Self.base) }
    }

    @Test func attributeListsHandleQuotesAndEquals() {
        let attrs = HLSParser.attributes(of: #"#X:A=1,B="x,y=z",C=ABC"#, after: "#X:")
        #expect(attrs == ["A": "1", "B": "x,y=z", "C": "ABC"])
    }

    // MARK: Segment download

    private static func downloadFixture() throws -> (playlist: HLSMediaPlaylist, segment: Data, directory: URL) {
        let audio = MPEGTSAudioDemuxerTests.frames(3).reduce(Data(), +)
        let playlist = try HLSParser.parseMedia(
            "#EXTM3U\n#EXTINF:1,\nseg-1.ts\n#EXTINF:1,\nseg-2.ts\n#EXTINF:1,\nseg-3.ts\n#EXT-X-ENDLIST",
            baseURL: URL(string: "https://cdn.test/a/index.m3u8")!
        )
        return (playlist, TSBuilder.segment(audioChunks: [audio]), try makeTemporaryDirectory("hls"))
    }

    @Test func retriesTransientServerErrorsOnASegment() async throws {
        let (playlist, segment, directory) = try Self.downloadFixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let attempts = Box(0)
        let server = StubServer { url in
            if url.lastPathComponent == "seg-2.ts" {
                attempts.value += 1
                if attempts.value == 1 { return StubResponse(status: 503) }
            }
            return .data(segment)
        }
        let file = try await HLSAudioDownloader(fetcher: HTTPFetcher(session: server.session))
            .download(playlist, toStem: directory.appendingPathComponent("out")) { _ in }
        #expect(attempts.value == 2)
        #expect(try Data(contentsOf: file).count == 3 * MPEGTSAudioDemuxerTests.frames(3).reduce(0) { $0 + $1.count })
    }

    @Test func clientErrorsOnASegmentAreNotRetried() async throws {
        let (playlist, segment, directory) = try Self.downloadFixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = StubServer { url in url.lastPathComponent == "seg-2.ts" ? .notFound : .data(segment) }
        await #expect(throws: ImportError.mediaUnavailable("not found")) {
            try await HLSAudioDownloader(fetcher: HTTPFetcher(session: server.session))
                .download(playlist, toStem: directory.appendingPathComponent("out")) { _ in }
        }
        #expect(server.requests.filter { $0.lastPathComponent == "seg-2.ts" }.count == 1)
    }
}
