import Foundation

/// A variant stream of an HLS master playlist.
struct HLSVariant: Sendable, Hashable {
    var url: URL
    var bandwidth: Int
    var resolution: String?
    var codecs: String?
    /// True when the codec list names only audio codecs.
    var isAudioOnly: Bool {
        guard let codecs else { return resolution == nil }
        return !codecs.split(separator: ",").contains { $0.contains("avc") || $0.contains("hvc") || $0.contains("hev") || $0.contains("vp0") || $0.contains("av01") }
    }
}

/// An `#EXT-X-MEDIA` rendition (alternate audio, subtitles…).
struct HLSRendition: Sendable, Hashable {
    var type: String
    var name: String?
    var language: String?
    var isDefault: Bool
    var url: URL?
}

struct HLSMasterPlaylist: Sendable {
    var variants: [HLSVariant]
    var renditions: [HLSRendition]

    /// The stream to download when only the sound matters: an audio-only rendition or variant if
    /// the server offers one, otherwise the lowest-bandwidth variant.
    var cheapestAudioStream: URL? {
        if let audio = renditions.first(where: { $0.type == "AUDIO" && $0.url != nil })?.url { return audio }
        if let audioOnly = variants.filter(\.isAudioOnly).min(by: { $0.bandwidth < $1.bandwidth }) { return audioOnly.url }
        return variants.min { $0.bandwidth < $1.bandwidth }?.url
    }

    var subtitlePlaylist: URL? {
        let subtitles = renditions.filter { $0.type == "SUBTITLES" && $0.url != nil }
        return (subtitles.first { $0.isDefault } ?? subtitles.first)?.url
    }
}

struct HLSSegment: Sendable, Hashable {
    var url: URL
    var duration: TimeInterval
}

struct HLSMediaPlaylist: Sendable {
    var segments: [HLSSegment]
    var totalDuration: TimeInterval { segments.reduce(0) { $0 + $1.duration } }
}

/// Parser for the subset of HLS (RFC 8216) that Kaltura serves.
enum HLSParser {
    static func parseMaster(_ text: String, baseURL: URL) throws -> HLSMasterPlaylist {
        var variants: [HLSVariant] = []
        var renditions: [HLSRendition] = []
        var pending: [String: String]?

        for line in lines(of: text) {
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                pending = attributes(of: line, after: "#EXT-X-STREAM-INF:")
            } else if line.hasPrefix("#EXT-X-MEDIA:") {
                let attrs = attributes(of: line, after: "#EXT-X-MEDIA:")
                renditions.append(HLSRendition(
                    type: attrs["TYPE"] ?? "",
                    name: attrs["NAME"],
                    language: attrs["LANGUAGE"],
                    isDefault: attrs["DEFAULT"] == "YES",
                    url: attrs["URI"].flatMap { URL(string: $0, relativeTo: baseURL)?.absoluteURL }
                ))
            } else if !line.hasPrefix("#"), let attrs = pending {
                pending = nil
                guard let url = URL(string: line, relativeTo: baseURL)?.absoluteURL else {
                    throw ImportError.malformedResponse("bad variant URL in playlist")
                }
                variants.append(HLSVariant(url: url, bandwidth: Int(attrs["BANDWIDTH"] ?? "") ?? Int.max, resolution: attrs["RESOLUTION"], codecs: attrs["CODECS"]))
            }
        }
        guard !variants.isEmpty || renditions.contains(where: { $0.url != nil }) else {
            throw ImportError.malformedResponse("playlist has no streams")
        }
        return HLSMasterPlaylist(variants: variants, renditions: renditions)
    }

    static func parseMedia(_ text: String, baseURL: URL) throws -> HLSMediaPlaylist {
        var segments: [HLSSegment] = []
        var nextDuration: TimeInterval?
        for line in lines(of: text) {
            if line.hasPrefix("#EXT-X-KEY:") {
                if attributes(of: line, after: "#EXT-X-KEY:")["METHOD"] != "NONE" {
                    throw ImportError.unsupportedStream("the stream is encrypted")
                }
            } else if line.hasPrefix("#EXT-X-MAP:") {
                throw ImportError.unsupportedStream("fragmented MP4 HLS segments")
            } else if line.hasPrefix("#EXTINF:") {
                nextDuration = Double(line.dropFirst("#EXTINF:".count).prefix { $0 != "," })
            } else if !line.hasPrefix("#") {
                guard let url = URL(string: line, relativeTo: baseURL)?.absoluteURL else {
                    throw ImportError.malformedResponse("bad segment URL in playlist")
                }
                segments.append(HLSSegment(url: url, duration: nextDuration ?? 0))
                nextDuration = nil
            }
        }
        guard !segments.isEmpty else { throw ImportError.malformedResponse("playlist has no segments") }
        return HLSMediaPlaylist(segments: segments)
    }

    private static func lines(of text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// `KEY=value,KEY2="quoted, value"` → dictionary (quotes removed).
    static func attributes(of line: String, after prefix: String) -> [String: String] {
        var result: [String: String] = [:]
        var key = ""
        var value = ""
        var readingKey = true
        var inQuotes = false
        func commit() {
            if !key.isEmpty { result[key] = value }
            key = ""
            value = ""
            readingKey = true
        }
        for character in line.dropFirst(prefix.count) {
            if readingKey {
                if character == "=" { readingKey = false } else { key.append(character) }
            } else if character == "\"" {
                inQuotes.toggle()
            } else if character == ",", !inQuotes {
                commit()
            } else {
                value.append(character)
            }
        }
        commit()
        return result
    }
}
