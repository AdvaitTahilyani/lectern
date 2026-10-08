import Foundation
import LecternCore
import Testing
@testable import LecternImport

@Suite struct KalturaClientTests {
    static let source = MediaSpaceSource(partnerID: "1329972", entryID: "1_oj3ppr67", ks: "djJ8KS-token_==", title: "T", pageURL: nil)

    // MARK: URLs

    @Test func buildsKalturaURLs() {
        let s = Self.source
        #expect(KalturaURLs.hlsManifest(for: s).absoluteString ==
                "https://www.kaltura.com/p/1329972/sp/132997200/playManifest/entryId/1_oj3ppr67/protocol/https/format/applehttp/ks/djJ8KS-token_==/a.m3u8")
        #expect(KalturaURLs.progressiveDownload(for: s, flavorID: "1_bs2lvjxg").absoluteString ==
                "https://www.kaltura.com/p/1329972/sp/132997200/playManifest/entryId/1_oj3ppr67/protocol/https/format/url/flavorIds/1_bs2lvjxg/ks/djJ8KS-token_==/a.mp4")
        #expect(KalturaURLs.progressiveDownload(for: s, flavorID: nil).path.hasSuffix("/format/url/ks/djJ8KS-token_==/a.mp4"))
        let list = KalturaURLs.captionAssetList(for: s)
        #expect(list.path == "/api_v3/service/caption_captionasset/action/list")
        #expect(URLComponents(url: list, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "filter[entryIdEqual]" }?.value == "1_oj3ppr67")
    }

    @Test func omitsTheTokenSegmentWhenThereIsNone() {
        var s = Self.source
        s.ks = ""
        #expect(!KalturaURLs.hlsManifest(for: s).absoluteString.contains("/ks/"))
        #expect(!KalturaURLs.captionAssetList(for: s).absoluteString.contains("ks="))
    }

    // MARK: Captions

    static let captionList = #"{"totalCount":2,"objects":[{"id":"1_old","languageCode":"es","isDefault":false,"status":2},{"id":"1_lcpfdkgk","languageCode":"en","isDefault":true,"status":2}]}"#
    static let captionTrack = #"{"objects":[{"startTime":7160,"endTime":10680,"content":[{"text":"So I want to correct\nsomething wrong in the"}]},{"startTime":10680,"endTime":14680,"content":[{"text":"slides."}]}]}"#

    @Test func fetchesCaptionsThroughTheAPI() async throws {
        let server = StubServer { url in
            if url.path.hasSuffix("/action/list") { return .text(Self.captionList) }
            if url.path.hasSuffix("/action/serveAsJson"), url.query?.contains("captionAssetId=1_lcpfdkgk") == true { return .text(Self.captionTrack) }
            return .notFound
        }
        let segments = try await KalturaClient(session: server.session).captions(for: Self.source)
        #expect(segments.count == 1)
        #expect(segments[0].text == "So I want to correct something wrong in the slides.")
        #expect(segments[0].start == 7.16 && segments[0].end == 14.68)
        #expect(server.requests.count == 2)
    }

    @Test func fallsBackToTheHLSSubtitleRendition() async throws {
        let server = StubServer { url in
            switch url.path {
            case let p where p.hasSuffix("/action/list"): return StubResponse(status: 500)
            case let p where p.hasSuffix("/a.m3u8") && p.contains("playManifest"):
                return .text("#EXTM3U\n#EXT-X-MEDIA:TYPE=SUBTITLES,NAME=\"English\",DEFAULT=YES,URI=\"https://cdn.test/subs/a.m3u8\"\n#EXT-X-STREAM-INF:BANDWIDTH=1\nhttps://cdn.test/v.m3u8")
            case "/subs/a.m3u8": return .text("#EXTM3U\n#EXTINF:300.0,\nsegmentIndex/1.vtt\n#EXTINF:300.0,\nsegmentIndex/2.vtt\n#EXT-X-ENDLIST")
            case "/subs/segmentIndex/1.vtt": return .text("WEBVTT\n\n00:00:01.000 --> 00:00:03.000\nfirst chunk.\n")
            case "/subs/segmentIndex/2.vtt": return .text("WEBVTT\n\n00:05:01.000 --> 00:05:03.000\nsecond chunk.\n")
            default: return .notFound
            }
        }
        let segments = try await KalturaClient(session: server.session).captions(for: Self.source)
        #expect(segments.map(\.text) == ["first chunk.", "second chunk."])
    }

    @Test func anAPIResponseThatDoesNotDecodeFallsBackToHLSToo() async throws {
        let server = StubServer { url in
            switch url.path {
            case let p where p.hasSuffix("/action/list"): return .text(#"{"objectType":"KalturaAPIException","message":"nope"}"#)
            case let p where p.hasSuffix("/a.m3u8") && p.contains("playManifest"):
                return .text("#EXTM3U\n#EXT-X-MEDIA:TYPE=SUBTITLES,NAME=\"English\",DEFAULT=YES,URI=\"https://cdn.test/subs/a.m3u8\"\n#EXT-X-STREAM-INF:BANDWIDTH=1\nhttps://cdn.test/v.m3u8")
            case "/subs/a.m3u8": return .text("#EXTM3U\n#EXTINF:300.0,\nsegmentIndex/1.vtt\n#EXT-X-ENDLIST")
            case "/subs/segmentIndex/1.vtt": return .text("WEBVTT\n\n00:00:01.000 --> 00:00:03.000\nfirst chunk.\n")
            default: return .notFound
            }
        }
        let segments = try await KalturaClient(session: server.session).captions(for: Self.source)
        #expect(segments.map(\.text) == ["first chunk."])
    }

    @Test func entriesWithoutCaptionsYieldNothing() async throws {
        let server = StubServer { url in
            if url.path.hasSuffix("/action/list") { return .text(#"{"totalCount":0,"objects":[]}"#) }
            return .text("#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\nhttps://cdn.test/v.m3u8")
        }
        #expect(try await KalturaClient(session: server.session).captions(for: Self.source).isEmpty)
    }

    @Test func expiredSessionsAreReportedNotHidden() async {
        let server = StubServer { _ in StubResponse(status: 403) }
        await #expect(throws: ImportError.sessionExpired) {
            try await KalturaClient(session: server.session).captions(for: Self.source)
        }
    }

    // MARK: Media

    static func fakeMP4() -> Data {
        Data([0, 0, 0, 24]) + Data("ftypisom".utf8) + Data(repeating: 0, count: 2000)
    }

    static let masterPlaylist = """
    #EXTM3U
    #EXT-X-STREAM-INF:BANDWIDTH=567890,RESOLUTION=1920x1080,CODECS="avc1.640032,mp4a.40.2"
    https://cdn.test/hls/flavorId/1_big/index.m3u8
    #EXT-X-STREAM-INF:BANDWIDTH=201699,RESOLUTION=640x360,CODECS="avc1.42c01e,mp4a.40.2"
    https://cdn.test/hls/flavorId/1_small/index.m3u8
    """

    @Test func downloadsTheSmallestFlavorProgressively() async throws {
        let server = StubServer { url in
            if url.path.contains("playManifest"), url.path.hasSuffix("/a.m3u8") { return .text(Self.masterPlaylist) }
            if url.path.hasSuffix("/a.mp4"), url.path.contains("/flavorIds/1_small/") { return .data(Self.fakeMP4()) }
            return .notFound
        }
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try await KalturaClient(session: server.session).downloadMedia(for: Self.source, into: directory) { _ in }
        #expect(file.lastPathComponent == "1_oj3ppr67.mp4")
        #expect(try Data(contentsOf: file) == Self.fakeMP4())
    }

    @Test func fallsBackToTheDefaultFlavorThenToHLSSegments() async throws {
        let frames = MPEGTSAudioDemuxerTests.frames(20)
        let segmentOne = TSBuilder.segment(audioChunks: [frames[0..<10].reduce(Data(), +)])
        let segmentTwo = TSBuilder.segment(audioChunks: [frames[10...].reduce(Data(), +)])
        let server = StubServer { url in
            switch url.path {
            case let p where p.contains("playManifest") && p.hasSuffix("/a.m3u8"): return .text(Self.masterPlaylist)
            case let p where p.contains("playManifest"): return .text("<html>nope</html>")      // progressive URLs return a 200 HTML page
            case "/hls/flavorId/1_small/index.m3u8": return .text("#EXTM3U\n#EXTINF:5,\nseg-1.ts\n#EXTINF:5,\nseg-2.ts\n#EXT-X-ENDLIST")
            case "/hls/flavorId/1_small/seg-1.ts": return .data(segmentOne)
            case "/hls/flavorId/1_small/seg-2.ts": return .data(segmentTwo)
            default: return .notFound
            }
        }
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let progress = ProgressLog()
        let file = try await KalturaClient(session: server.session).downloadMedia(for: Self.source, into: directory) { progress.append($0) }
        #expect(file.pathExtension == "aac")
        #expect(try Data(contentsOf: file) == frames.reduce(Data(), +))
        #expect(progress.values.last == 1)
        // Both progressive attempts were made before falling back.
        let progressiveTries = server.requests.filter { $0.path.hasSuffix("/a.mp4") }
        #expect(progressiveTries.count == 2)
    }

    @Test func aFailedSegmentFailsTheImport() async throws {
        let server = StubServer { url in
            switch url.path {
            case let p where p.contains("playManifest") && p.hasSuffix("/a.m3u8"): return .text(Self.masterPlaylist)
            case let p where p.contains("playManifest"): return StubResponse(status: 404)
            case "/hls/flavorId/1_small/index.m3u8": return .text("#EXTM3U\n#EXTINF:5,\nseg-1.ts\n#EXT-X-ENDLIST")
            default: return StubResponse(status: 500)
            }
        }
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        await #expect(throws: ImportError.downloadFailed(status: 500)) {
            try await KalturaClient(session: server.session).downloadMedia(for: Self.source, into: directory) { _ in }
        }
    }
}

final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()   // guards `stored`
    private var stored: [Double] = []
    var values: [Double] { lock.lock(); defer { lock.unlock() }; return stored }
    func append(_ value: Double) { lock.lock(); stored.append(value); lock.unlock() }
}
