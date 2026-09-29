import Foundation
import LecternCore

/// Downloads a MediaSpace lecture's media and captions from Kaltura using the session scraped from
/// the signed-in page.
public struct KalturaClient: Sendable {
    private let fetcher: HTTPFetcher

    /// - Parameter session: injectable for tests; defaults to a fresh ephemeral session with no
    ///   cookie storage, so nothing from the app's other web traffic leaks in or persists.
    public init(session: URLSession? = nil) {
        fetcher = HTTPFetcher(session: session ?? URLSession(configuration: .ephemeral))
    }

    // MARK: - Media

    /// Downloads the cheapest playable audio-carrying stream of the lecture into `directory` and
    /// returns its file (an `.mp4`, or `.aac`/`.mp3` when it had to be assembled from HLS
    /// segments). Tries, in order: a progressive download of the smallest flavor, Kaltura's default
    /// flavor, then HLS segments.
    /// - Parameter progress: 0...1 (reset when a fallback strategy starts).
    public func downloadMedia(
        for source: MediaSpaceSource,
        into directory: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let master = try await masterPlaylist(for: source)
        let cheapest = master?.cheapestAudioStream

        var progressive = [KalturaURLs.progressiveDownload(for: source, flavorID: cheapest.flatMap(KalturaURLs.flavorID))]
        if cheapest.flatMap(KalturaURLs.flavorID) != nil { progressive.append(KalturaURLs.progressiveDownload(for: source, flavorID: nil)) }

        var lastError: Error?
        for url in progressive {
            do {
                let file = directory.appendingPathComponent("\(source.entryID).mp4")
                try await fetcher.download(url, to: file, progress: progress)
                try Self.requireMP4(file)
                progress(1)
                return file
            } catch let error where Self.isRecoverable(error) {
                lastError = error
                progress(0)
            }
        }

        guard let cheapest else { throw lastError ?? ImportError.mediaUnavailable("no playable stream") }
        let playlist = try HLSParser.parseMedia(try await fetcher.string(from: cheapest), baseURL: cheapest)
        return try await HLSAudioDownloader(fetcher: fetcher)
            .download(playlist, toStem: directory.appendingPathComponent(source.entryID), progress: progress)
    }

    /// `nil` when the manifest itself isn't available (the progressive URL may still work).
    func masterPlaylist(for source: MediaSpaceSource) async throws -> HLSMasterPlaylist? {
        let url = KalturaURLs.hlsManifest(for: source)
        do {
            return try HLSParser.parseMaster(try await fetcher.string(from: url), baseURL: url)
        } catch let error where Self.isRecoverable(error) {
            if case ImportError.sessionExpired = error { throw error }
            return nil
        }
    }

    private static func isRecoverable(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        if let urlError = error as? URLError { return urlError.code != .cancelled }
        guard let importError = error as? ImportError else { return false }
        switch importError {
        case .mediaUnavailable, .downloadFailed, .malformedResponse, .unsupportedStream: return true
        default: return false
        }
    }

    /// Guards against an HTML/JSON error body served with a 200 status.
    private static func requireMP4(_ file: URL) throws {
        let head = try FileHandle(forReadingFrom: file)
        defer { try? head.close() }
        let bytes = try head.read(upToCount: 12) ?? Data()
        guard bytes.count >= 12, bytes[4..<8] == Data("ftyp".utf8) else {
            throw ImportError.mediaUnavailable("the server didn't return a video file")
        }
    }

    // MARK: - Captions

    /// The lecture's caption track merged into transcript segments, or an empty array when the
    /// entry has no captions. Prefers the Kaltura API (one request); falls back to the HLS
    /// WebVTT rendition.
    public func captions(for source: MediaSpaceSource) async throws -> [TranscriptSegment] {
        var cues: [CaptionCue] = []
        do {
            cues = try await apiCaptionCues(for: source)
        } catch let error where Self.isRecoverable(error) {
            // Fall through to the HLS rendition.
        }
        if cues.isEmpty { cues = try await hlsCaptionCues(for: source) }
        return CaptionMerger().merge(cues)
    }

    private func apiCaptionCues(for source: MediaSpaceSource) async throws -> [CaptionCue] {
        let list = try JSONDecoder().decode(CaptionAssetList.self, from: try await fetcher.data(from: KalturaURLs.captionAssetList(for: source)))
        let ready = list.objects.filter { $0.status == 2 }
        guard let asset = ready.first(where: { $0.isDefault }) ?? ready.first(where: { $0.languageCode == "en" }) ?? ready.first else { return [] }
        let track = try JSONDecoder().decode(CaptionTrack.self, from: try await fetcher.data(from: KalturaURLs.captionJSON(assetID: asset.id, for: source)))
        return track.objects.compactMap { entry in
            let text = WebVTT.cleanText(entry.content.map(\.text).joined(separator: " "))
            return text.isEmpty ? nil : CaptionCue(start: entry.startTime / 1000, end: entry.endTime / 1000, text: text)
        }
    }

    func hlsCaptionCues(for source: MediaSpaceSource) async throws -> [CaptionCue] {
        guard let subtitles = try await masterPlaylist(for: source)?.subtitlePlaylist else { return [] }
        let playlist = try HLSParser.parseMedia(try await fetcher.string(from: subtitles), baseURL: subtitles)
        var cues: [CaptionCue] = []
        for segment in playlist.segments {
            cues += WebVTT.parse(try await fetcher.string(from: segment.url))
        }
        return cues
    }

    private struct CaptionAssetList: Decodable {
        struct Asset: Decodable {
            var id: String
            var languageCode: String?
            var isDefault: Bool
            var status: Int
        }
        var objects: [Asset]
    }

    private struct CaptionTrack: Decodable {
        struct Entry: Decodable {
            struct Content: Decodable { var text: String }
            var startTime: Double
            var endTime: Double
            var content: [Content]
        }
        var objects: [Entry]
    }
}
