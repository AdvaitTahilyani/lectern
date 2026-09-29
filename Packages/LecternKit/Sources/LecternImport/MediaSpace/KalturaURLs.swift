import Foundation
import LecternCore

/// URL construction for the Kaltura endpoints MediaSpace uses. All URLs carry the page's session
/// token (`ks`); it is used for the request only and never persisted.
public enum KalturaURLs {
    static let host = "https://www.kaltura.com"

    /// Kaltura derives the "service partner" segment from the partner ID: `partnerId × 100`.
    private static func playManifestBase(_ source: MediaSpaceSource) -> String {
        "\(host)/p/\(source.partnerID)/sp/\(source.partnerID)00/playManifest/entryId/\(source.entryID)"
    }

    private static func ksSegment(_ source: MediaSpaceSource) -> String {
        source.ks.isEmpty ? "" : "/ks/\(source.ks)"
    }

    /// HLS master playlist (flavors plus the WebVTT subtitle rendition).
    public static func hlsManifest(for source: MediaSpaceSource) -> URL {
        url("\(playManifestBase(source))/protocol/https/format/applehttp\(ksSegment(source))/a.m3u8")
    }

    /// Progressive MP4 download (a 302 to the CDN). With `flavorID` nil Kaltura picks its default
    /// flavor; pass the ID of the smallest flavor to avoid downloading the source file.
    public static func progressiveDownload(for source: MediaSpaceSource, flavorID: String?) -> URL {
        let flavor = flavorID.map { "/flavorIds/\($0)" } ?? ""
        return url("\(playManifestBase(source))/protocol/https/format/url\(flavor)\(ksSegment(source))/a.mp4")
    }

    /// API call listing an entry's caption assets (JSON).
    public static func captionAssetList(for source: MediaSpaceSource) -> URL {
        var components = URLComponents(string: "\(host)/api_v3/service/caption_captionasset/action/list")!
        components.queryItems = [URLQueryItem(name: "format", value: "1"), URLQueryItem(name: "filter[entryIdEqual]", value: source.entryID)]
            + (source.ks.isEmpty ? [] : [URLQueryItem(name: "ks", value: source.ks)])
        return components.url!
    }

    /// The whole caption track as timed JSON (`{"objects":[{"startTime":ms,"endTime":ms,"content":[{"text":…}]}]}`).
    public static func captionJSON(assetID: String, for source: MediaSpaceSource) -> URL {
        var components = URLComponents(string: "\(host)/api_v3/service/caption_captionasset/action/serveAsJson")!
        components.queryItems = [URLQueryItem(name: "format", value: "1"), URLQueryItem(name: "captionAssetId", value: assetID)]
            + (source.ks.isEmpty ? [] : [URLQueryItem(name: "ks", value: source.ks)])
        return components.url!
    }

    /// The Kaltura flavor ID embedded in a variant or segment URL (`…/flavorId/1_bs2lvjxg/…`).
    static func flavorID(in url: URL) -> String? {
        let parts = url.pathComponents
        guard let index = parts.firstIndex(of: "flavorId"), index + 1 < parts.count else { return nil }
        return parts[index + 1]
    }

    private static func url(_ string: String) -> URL {
        // Inputs are validated IDs and a base64url token, so this can only fail on a corrupt source.
        URL(string: string) ?? URL(string: host)!
    }
}
