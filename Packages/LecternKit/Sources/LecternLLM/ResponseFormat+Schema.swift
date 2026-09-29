import Foundation
import LecternCore

extension ResponseFormat {
    /// True for `.json`.
    var isJSON: Bool {
        if case .json = self { return true }
        return false
    }

    /// The JSON Schema object for `.json(schema:)`, or nil when no schema was given.
    /// Throws `LLMError.invalidResponse` when the schema text isn't a JSON object.
    func schemaObject() throws -> [String: Any]? {
        guard case .json(let schema?) = self else { return nil }
        guard
            let data = schema.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw LLMError.invalidResponse("The JSON schema for this request is not a valid JSON object.")
        }
        return object
    }
}
