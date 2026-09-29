import Foundation
import Testing
import LecternCore
@testable import LecternLLM

/// Property order in a schema steers what the model writes first, so it must reach the wire as written.
@Suite struct SchemaVerbatimTests {
    let schema = #"{"type":"object","properties":{"action":{"type":"string"},"title":{"type":"string"},"summary":{"type":"string"},"boundary_quote":{"type":"string"}},"required":["action","title","summary"]}"#

    private func wireBody(_ body: [String: Any]) throws -> String {
        let request = try URLRequest.json(url: URL(string: "http://localhost/v1/x")!, body: body, timeout: 5)
        return String(decoding: try #require(request.httpBody), as: UTF8.self)
    }

    @Test func openAICompatibleSendsSchemaVerbatim() throws {
        let provider = OpenAICompatibleProvider.localServer(baseURL: URL(string: "http://localhost:11434")!, model: "m")
        let request = LLMRequest(messages: [.user("hi")], responseFormat: .json(schema: schema))
        let wire = try wireBody(try provider.makeBody(request, stream: false))
        #expect(wire.contains(schema))
        #expect(!wire.contains("__lectern_verbatim_json__"))
        #expect((try JSONSerialization.jsonObject(with: Data(wire.utf8))) is [String: Any])
    }

    @Test func anthropicSendsSchemaVerbatim() throws {
        let provider = AnthropicProvider(apiKey: "k", model: "claude-haiku-4-5")
        let request = LLMRequest(messages: [.system("s"), .user("hi")], responseFormat: .json(schema: schema))
        let wire = try wireBody(try provider.makeBody(request, stream: false))
        #expect(wire.contains(schema))
    }

    @Test func schemaWithSlashesAndUnicodeSurvives() throws {
        let tricky = #"{"type":"object","description":"a/b → ε","properties":{"z":{"type":"string"},"a":{"type":"string"}}}"#
        let placeholder = try #require(try ResponseFormat.json(schema: tricky).schemaObject())
        let body: [String: Any] = ["response_format": placeholder]
        #expect(try wireBody(body).contains(tricky))
    }
}

/// Serializes a request body exactly as it goes on the wire and parses it back, so tests assert
/// what's actually sent (including verbatim-spliced schemas).
func wireJSON(_ body: [String: Any]) throws -> [String: Any] {
    let request = try URLRequest.json(url: URL(string: "http://localhost/v1/x")!, body: body, timeout: 5)
    let data = try #require(request.httpBody)
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}
