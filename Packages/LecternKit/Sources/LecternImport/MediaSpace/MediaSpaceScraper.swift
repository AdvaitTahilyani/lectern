import Foundation
import LecternCore

/// Finds the Kaltura identifiers of a MediaSpace lecture in a page. Pure: takes HTML (typically
/// the fully rendered DOM after the player has started) and returns the page's *own* entry, not
/// the related-media thumbnails that share the same JSON keys.
public enum MediaSpaceScraper {
    /// - Parameters:
    ///   - html: the page's HTML (rendered DOM or original source).
    ///   - pageURL: the page address; a `/media/…/<entryId>` path is the most reliable entry hint.
    /// - Throws: `ImportError.notAMediaSpacePage` if no partner or entry can be found.
    public static func scrape(html: String, pageURL: URL? = nil) throws -> MediaSpaceSource {
        // JSON embedded in scripts escapes slashes ("https:\/\/…"); undo that so URL patterns match.
        let text = html.contains("\\/") ? html.replacingOccurrences(of: "\\/", with: "/") : html
        let page = Page(text)

        guard let partnerID = page.first(#""partnerId":"?(\d+)"#) ?? page.first(#"partnerId=(\d+)"#) ?? page.first(#"/p/(\d+)/"#) else {
            throw ImportError.notAMediaSpacePage
        }
        guard let entryID = entryID(in: page, pageURL: pageURL) else { throw ImportError.notAMediaSpacePage }
        return MediaSpaceSource(
            partnerID: partnerID,
            entryID: entryID,
            ks: sessionToken(in: page, partnerID: partnerID, entryID: entryID) ?? "",
            title: title(in: page),
            pageURL: pageURL
        )
    }

    /// The entry ID a MediaSpace page address points at: `…/media/t/1_abcd1234/…`,
    /// `…/media/Title/1_abcd1234`, or `?entry_id=1_abcd1234`.
    public static func entryID(in url: URL) -> String? {
        if let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
           let value = items.first(where: { $0.name == "entry_id" || $0.name == "entryId" })?.value,
           isEntryID(value) {
            return value
        }
        return url.pathComponents.first(where: isEntryID)
    }

    static func isEntryID(_ candidate: String) -> Bool {
        candidate.range(of: #"^[0-9]_[a-z0-9]{8}$"#, options: .regularExpression) != nil
    }

    // MARK: - Entry

    private static func entryID(in page: Page, pageURL: URL?) -> String? {
        if let pageURL, let id = entryID(in: pageURL) { return id }
        // MediaSpace tags the analytics context of the entry page with its own entry.
        if let id = page.first(#""pageType":"Entry View[^"]*","entryId":"([^"]+)""#) { return id }
        return page.mostFrequent(#""entryId":"([01]_[a-z0-9]{8})""#) ?? page.mostFrequent(#"playManifest/entryId/([01]_[a-z0-9]{8})"#)
    }

    // MARK: - Session token

    private static func sessionToken(in page: Page, partnerID: String, entryID: String) -> String? {
        // 1. The token the page's player itself used to request this entry's stream.
        let pattern = "playManifest/entryId/\(NSRegularExpression.escapedPattern(for: entryID))/[^\"'\\s<>]*?/ks/([^/\"'\\s<>]+)/"
        if let ks = page.first(pattern) { return ks }
        // 2. The player configuration's provider block.
        if let block = page.snippet(after: "\"provider\":{\"partnerId\":\"\(partnerID)\"", length: 4000),
           let ks = Page(block).first(#""ks":"([^"]+)""#) {
            return ks
        }
        // 3. Any token that isn't the in-app-messaging one (a different service's session).
        if let ks = page.first(#"(?<!"inAppMessaging":\{)"ks":"(djJ8[^"]+)""#) { return ks }
        // 4. Tokens passed as URL parameters.
        return page.first(#"[?&]ks=(djJ8[A-Za-z0-9_=-]+)"#)
    }

    // MARK: - Title

    private static func title(in page: Page) -> String? {
        page.first(#"<title[^>]*>([^<]*)</title>"#).flatMap(cleanTitle)
    }

    /// A page title without the site suffix (" - Illinois Media Space"), or nil if nothing is left.
    public static func cleanTitle(_ raw: String) -> String? {
        var title = WebVTT.cleanText(raw)
        if let suffix = title.range(of: #"\s*[-–|]\s*(Illinois\s+)?Media\s?Space\s*$"#, options: [.regularExpression, .caseInsensitive]) {
            title.removeSubrange(suffix)
        }
        title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }
}

/// Regex helpers over a (possibly multi-megabyte) string, using `NSString` offsets to stay linear.
private struct Page {
    private let string: NSString

    init(_ text: String) { string = text as NSString }

    private func regex(_ pattern: String) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
    }

    /// First capture group of the first match.
    func first(_ pattern: String) -> String? {
        guard let regex = regex(pattern),
              let match = regex.firstMatch(in: string as String, range: NSRange(location: 0, length: string.length)),
              match.numberOfRanges > 1, match.range(at: 1).location != NSNotFound else { return nil }
        return string.substring(with: match.range(at: 1))
    }

    /// The capture group value that occurs most often (ties go to the first seen).
    func mostFrequent(_ pattern: String) -> String? {
        guard let regex = regex(pattern) else { return nil }
        var counts: [String: Int] = [:]
        var order: [String] = []
        regex.enumerateMatches(in: string as String, range: NSRange(location: 0, length: string.length)) { match, _, _ in
            guard let match, match.numberOfRanges > 1 else { return }
            let value = string.substring(with: match.range(at: 1))
            if counts[value] == nil { order.append(value) }
            counts[value, default: 0] += 1
        }
        var best: String?
        for value in order where best == nil || counts[value]! > counts[best!]! { best = value }
        return best
    }

    /// Up to `length` characters following the first occurrence of `marker`.
    func snippet(after marker: String, length: Int) -> String? {
        let found = string.range(of: marker)
        guard found.location != NSNotFound else { return nil }
        let start = found.location + found.length
        return string.substring(with: NSRange(location: start, length: min(length, string.length - start)))
    }
}
