import Foundation
import LecternCore

/// Combines the partial observations the browser's injected script reports (a stream URL here, a
/// player config there) into one `MediaSpaceSource` for the page the user is on. Pure state
/// machine, so it can be tested without a web view.
struct MediaSpaceDetector: Sendable {
    /// One observation from a frame; any field may be missing.
    struct Signal: Sendable, Equatable {
        var partnerID: String?
        var entryID: String?
        var ks: String?
    }

    private(set) var pageURL: URL?
    private(set) var title: String?
    private var partnerID: String?
    /// Latest session token seen per entry, and the latest overall (for signals without an entry).
    private var tokens: [String: String] = [:]
    private var anyToken: String?
    /// Entries named by signals, most recent last.
    private var reportedEntries: [String] = []
    private var lastEmitted: MediaSpaceSource?

    /// Whether `url` looks like a MediaSpace lecture page (as opposed to sign-in or browse pages).
    static func isMediaPage(_ url: URL?) -> Bool {
        guard let url, let host = url.host?.lowercased(), host.hasSuffix("mediaspace.illinois.edu") || host.hasSuffix("kaltura.com") else { return false }
        return MediaSpaceScraper.entryID(in: url) != nil
    }

    /// Call when the main frame commits a new page; clears everything learned about the old one.
    mutating func pageChanged(to url: URL?) {
        if url != pageURL {
            self = MediaSpaceDetector(pageURL: url, title: nil)
        }
    }

    /// Records the page title; returns the source again (now titled) if the lecture was already complete.
    mutating func titleChanged(_ title: String?) -> MediaSpaceSource? {
        let cleaned = title.flatMap(MediaSpaceScraper.cleanTitle)
        guard cleaned != self.title else { return nil }
        self.title = cleaned
        return resolve()
    }

    /// Records a signal; returns the source when it is complete and differs from the last one returned.
    mutating func ingest(_ signal: Signal) -> MediaSpaceSource? {
        if let id = signal.partnerID, Self.isPartnerID(id) { partnerID = id }
        var entry = signal.entryID.flatMap { MediaSpaceScraper.isEntryID($0) ? $0 : nil }
        if let entry {
            reportedEntries.removeAll { $0 == entry }
            reportedEntries.append(entry)
        }
        if let ks = signal.ks, Self.isToken(ks) {
            anyToken = ks
            entry = entry ?? reportedEntries.last
            if let entry { tokens[entry] = ks }
        }
        return resolve()
    }

    private mutating func resolve() -> MediaSpaceSource? {
        // The address bar is the most reliable statement of which lecture this is.
        guard let entry = pageURL.flatMap(MediaSpaceScraper.entryID(in:)) ?? reportedEntries.last,
              let partnerID, let ks = tokens[entry] ?? anyToken else { return nil }
        let source = MediaSpaceSource(partnerID: partnerID, entryID: entry, ks: ks, title: title, pageURL: pageURL)
        guard source != lastEmitted else { return nil }
        lastEmitted = source
        return source
    }

    init(pageURL: URL? = nil, title: String? = nil) {
        self.pageURL = pageURL
        self.title = title
    }

    static func isPartnerID(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 12 && value.allSatisfy(\.isNumber)
    }

    static func isToken(_ value: String) -> Bool {
        value.count >= 20 && value.count <= 2048 && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "_-=".contains($0)) }
    }
}
