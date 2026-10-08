import Foundation
import LecternCore

extension ResponseFormat {
    /// The JSON Schema for `.json(schema:)` as a request-body value, or nil when no schema was given.
    /// The value is a `VerbatimJSON` placeholder: property order in a schema steers what the model
    /// generates first, and re-serializing it (especially with `.sortedKeys`) would reorder it, so
    /// `URLRequest.json` splices the caller's text back in unchanged.
    /// Throws `LLMError.invalidResponse` when the schema text isn't a JSON object.
    func schemaObject() throws -> String? {
        guard case .json(let schema?) = self else { return nil }
        guard
            let data = schema.data(using: .utf8),
            (try? JSONSerialization.jsonObject(with: data)) is [String: Any]
        else {
            throw LLMError.invalidResponse("The JSON schema for this request is not a valid JSON object.")
        }
        return VerbatimJSON.placeholder(for: schema)
    }
}

/// Embeds raw JSON text in a `[String: Any]` request body without `JSONSerialization` touching it.
enum VerbatimJSON {
    private static let prefix = "__lectern_verbatim_json__:"

    /// A string value to put in the body where `json` should appear verbatim.
    static func placeholder(for json: String) -> String {
        let base64url = Data(json.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
        return prefix + base64url
    }

    /// Replaces every serialized placeholder (a quoted string) in `data` with its original JSON text.
    ///
    /// Works on bytes: request bodies carry the whole prompt (hundreds of KB), and scanning that
    /// as a `String` with a regex is far slower than a byte search. A placeholder is only
    /// recognised in value position (after `:`, `[` or `,`), so message text that merely contains
    /// a quoted lookalike (its quotes are escaped on the wire) is never rewritten.
    static func splice(into data: Data) -> Data {
        let marker = Data(("\"" + prefix).utf8)
        guard data.range(of: marker) != nil else { return data }
        let structural: Set<UInt8> = [UInt8(ascii: ":"), UInt8(ascii: "["), UInt8(ascii: ",")]

        var out = Data()
        out.reserveCapacity(data.count)
        var cursor = data.startIndex
        while let match = data.range(of: marker, in: cursor ..< data.endIndex) {
            var end = match.upperBound
            while end < data.endIndex, isBase64URL(data[end]) { end += 1 }
            let atValue = match.lowerBound > data.startIndex && structural.contains(data[match.lowerBound - 1])
            let decoded =
                atValue && end < data.endIndex && data[end] == UInt8(ascii: "\"")
                ? decode(data[match.upperBound ..< end]) : nil
            if let decoded {
                out.append(data[cursor ..< match.lowerBound])
                out.append(decoded)
                cursor = end + 1
            } else {
                out.append(data[cursor ..< match.upperBound])
                cursor = match.upperBound
            }
        }
        out.append(data[cursor...])
        return out
    }

    private static func isBase64URL(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "A") ... UInt8(ascii: "Z"), UInt8(ascii: "a") ... UInt8(ascii: "z"),
            UInt8(ascii: "0") ... UInt8(ascii: "9"), UInt8(ascii: "-"), UInt8(ascii: "_"), UInt8(ascii: "="):
            true
        default:
            false
        }
    }

    private static func decode(_ base64url: Data) -> Data? {
        guard
            let encoded = String(data: base64url, encoding: .ascii)?
                .replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/"),
            let raw = Data(base64Encoded: encoded), String(data: raw, encoding: .utf8) != nil
        else { return nil }
        return raw
    }
}
