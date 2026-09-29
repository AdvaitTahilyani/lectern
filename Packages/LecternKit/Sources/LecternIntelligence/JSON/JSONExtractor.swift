import Foundation
import LecternCore

/// Pulls the first usable JSON object out of messy model output and decodes it.
///
/// Small local models wrap JSON in code fences or prose, leave trailing commas, use smart or
/// single quotes, put raw newlines or unescaped quotes inside strings, write Python literals, or get
/// cut off by the token limit. `JSONExtractor` scans for each `{`, rewrites what follows into strict
/// JSON with `JSONRepairScanner`, and returns the first candidate that `JSONSerialization` accepts.
enum JSONExtractor {
    /// How many `{` positions to try before giving up (prose may contain stray braces).
    private static let maxCandidates = 12

    /// The first balanced (or repairable) JSON object in `text`, as strict JSON, or nil.
    static func extractObject(from text: String) -> String? {
        let cleaned = ThinkStripper.strip(text)
        let scalars = Array(cleaned.unicodeScalars)
        var tried = 0
        var index = 0
        while index < scalars.count, tried < maxCandidates {
            guard scalars[index] == "{" else { index += 1; continue }
            tried += 1
            if let candidate = JSONRepairScanner.repairObject(scalars, from: index), isValidObject(candidate) {
                return candidate
            }
            index += 1
        }
        return nil
    }

    /// Extracts and decodes `T`. Keys are matched case-, underscore- and hyphen-insensitively
    /// (`boundary_quote`, `boundaryQuote` and `Boundary-Quote` are the same key).
    static func decode<T: Decodable>(_ type: T.Type, from text: String) throws -> T {
        guard let json = extractObject(from: text) else {
            throw JSONExtractionError.noObject(preview: String(text.prefix(160)))
        }
        do {
            return try makeDecoder().decode(T.self, from: Data(json.utf8))
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

    var errorDescription: String? {
        switch self {
        case .noObject(let preview): "No JSON object in the model output: \(preview)"
        case .decoding(let detail): "The JSON didn't match the expected shape: \(detail)"
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
