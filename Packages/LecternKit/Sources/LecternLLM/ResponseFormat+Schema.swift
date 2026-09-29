import Foundation
import LecternCore

extension ResponseFormat {
    /// True for `.json`.
    var isJSON: Bool {
        if case .json = self { return true }
        return false
    }

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
    static func splice(into data: Data) -> Data {
        guard var text = String(data: data, encoding: .utf8), text.contains(prefix) else { return data }
        let pattern = try! Regex(#""__lectern_verbatim_json__:([A-Za-z0-9_\-=]+)""#)
        text.replace(pattern) { match in
            let encoded = String(match.output[1].substring ?? "")
                .replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/")
            guard let raw = Data(base64Encoded: encoded), let json = String(data: raw, encoding: .utf8) else {
                return String(match.output[0].substring ?? "")
            }
            return json
        }
        return Data(text.utf8)
    }
}
