import Foundation
import LecternCore

/// Pulls the usable JSON object out of messy model output and decodes it.
///
/// Small local models wrap JSON in code fences or prose, leave trailing commas, use smart or
/// single quotes, put raw newlines or unescaped quotes inside strings, write Python literals, or get
/// cut off by the token limit. `JSONExtractor` scans for each `{`, rewrites what follows into strict
/// JSON with `JSONRepairScanner`, and keeps the *last* candidate that `JSONSerialization` accepts
/// (a reply that echoes an example or starts with `{}` puts its real answer last).
enum JSONExtractor {
    /// How many `{` positions to try before giving up (prose may contain stray braces).
    private static let maxCandidates = 12

    /// The object found: strict JSON, and whether it had to be closed because the output was cut off.
    struct Extracted {
        var json: String
        var truncated: Bool
    }

    /// The last balanced (or repairable) top-level JSON object in `text`, or nil.
    static func extract(from text: String) -> Extracted? {
        let cleaned = ThinkStripper.strip(text)
        let scalars = Array(cleaned.unicodeScalars)
        var tried = 0
        var index = 0
        var found: Extracted?
        while index < scalars.count, tried < maxCandidates {
            guard scalars[index] == "{" else { index += 1; continue }
            tried += 1
            if let candidate = JSONRepairScanner.repairObject(scalars, from: index), isValidObject(candidate.json) {
                found = Extracted(json: candidate.json, truncated: candidate.truncated)
                index = candidate.end    // nested objects belong to this one
            } else {
                index += 1
            }
        }
        return found
    }

    /// The object's strict JSON (see `extract(from:)`), or nil.
    static func extractObject(from text: String) -> String? {
        extract(from: text)?.json
    }

    /// Extracts and decodes `T`. Keys are matched case-, underscore- and hyphen-insensitively
    /// (`boundary_quote`, `boundaryQuote` and `Boundary-Quote` are the same key).
    static func decode<T: Decodable>(_ type: T.Type, from text: String, rejectingTruncated: Bool = false) throws -> T {
        guard let extracted = extract(from: text) else {
            throw JSONExtractionError.noObject(preview: String(text.prefix(160)))
        }
        if rejectingTruncated, extracted.truncated { throw JSONExtractionError.truncated }
        do {
            return try makeDecoder().decode(T.self, from: Data(extracted.json.utf8))
        } catch {
            throw JSONExtractionError.decoding(String(describing: error))
        }
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .custom { path in
            NormalizedKey(stringValue: NormalizedKey.normalize(path.last?.stringValue ?? ""))
        }
        return decoder
    }

    private static func isValidObject(_ json: String) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) else { return false }
        return object is [String: Any]
    }
}

enum JSONExtractionError: Error, LocalizedError, Equatable {
    case noObject(preview: String)
    case decoding(String)
    /// The reply was cut off before the object closed.
    case truncated

    var errorDescription: String? {
        switch self {
        case .noObject(let preview): "No JSON object in the model output: \(preview)"
        case .decoding(let detail): "The JSON didn't match the expected shape: \(detail)"
        case .truncated: "The reply was cut off before the JSON object ended."
        }
    }
}

/// A coding key whose string value has been lowercased with `_`, `-` and spaces removed. DTOs
/// declare their `CodingKeys` raw values in this normalized form.
struct NormalizedKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }

    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }

    static func normalize(_ key: String) -> String {
        String(key.lowercased().unicodeScalars.filter { $0 != "_" && $0 != "-" && $0 != " " })
    }
}
