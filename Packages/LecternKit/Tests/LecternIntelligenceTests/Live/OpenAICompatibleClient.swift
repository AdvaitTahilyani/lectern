import Foundation
import LecternCore
import Synchronization

/// Minimal OpenAI-compatible chat client for live evaluation against a local server (Ollama).
/// Test-only; the production providers live in LecternLLM.
final class OpenAICompatibleClient: LLMProvider {
    let kind = ProviderKind.localServer
    let model: String
    let baseURL: URL
    private let session: URLSession
    private let stats = Mutex((calls: 0, promptTokens: 0, cachedTokens: 0, completionTokens: 0, seconds: 0.0))

    init(model: String = ProcessInfo.processInfo.environment["LECTERN_LIVE_MODEL"] ?? "gemma4:12b",
         baseURL: URL = URL(string: ProcessInfo.processInfo.environment["LECTERN_LIVE_URL"] ?? "http://localhost:11434/v1")!) {
        self.model = model
        self.baseURL = baseURL
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 600
        session = URLSession(configuration: config)
    }

    var summary: String {
        let s = stats.withLock { $0 }
        return "\(s.calls) calls, \(s.promptTokens) prompt tokens (\(s.cachedTokens) cached), \(s.completionTokens) completion tokens, \(String(format: "%.0f", s.seconds)) s"
    }

    private func body(_ request: LLMRequest, stream: Bool) throws -> Data {
        var body: [String: Any] = [
            "model": model,
            "messages": request.messages.map { ["role": $0.role.rawValue, "content": $0.content] },
            "max_tokens": request.maxTokens,
            "temperature": request.temperature,
            "stream": stream,
            "reasoning_effort": request.reasoning == .off ? "none" : request.reasoning.rawValue,
        ]
        guard case .json(let schema) = request.responseFormat else { return try JSONSerialization.data(withJSONObject: body) }
        guard let schema else {
            body["response_format"] = ["type": "json_object"]
            return try JSONSerialization.data(withJSONObject: body)
        }
        // Splice the schema in verbatim: property order steers generation order, and a
        // JSONSerialization round trip would scramble it.
        var json = String(decoding: try JSONSerialization.data(withJSONObject: body), as: UTF8.self)
        json.removeLast()
        json += #","response_format":{"type":"json_schema","json_schema":{"name":"reply","schema":"# + schema + "}}}"
        return Data(json.utf8)
    }

    private func urlRequest(_ request: LLMRequest, stream: Bool) throws -> URLRequest {
        var r = URLRequest(url: baseURL.appending(path: "chat/completions"))
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try body(request, stream: stream)
        return r
    }

    func complete(_ request: LLMRequest) async throws -> LLMResponse {
        let started = ContinuousClock.now
        let (data, response) = try await session.data(for: try urlRequest(request, stream: false))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw LLMError.http(status: (response as? HTTPURLResponse)?.statusCode ?? 0, message: String(decoding: data, as: UTF8.self))
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choice = (json["choices"] as? [[String: Any]])?.first,
              let message = choice["message"] as? [String: Any] else {
            throw LLMError.invalidResponse(String(decoding: data.prefix(300), as: UTF8.self))
        }
        let usage = json["usage"] as? [String: Any]
        let prompt = usage?["prompt_tokens"] as? Int ?? 0
        let completion = usage?["completion_tokens"] as? Int ?? 0
        let cached = (usage?["prompt_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int ?? 0
        let elapsed = ContinuousClock.now - started
        stats.withLock {
            $0.calls += 1; $0.promptTokens += prompt; $0.cachedTokens += cached; $0.completionTokens += completion
            $0.seconds += Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        }
        let text = ThinkStripper.strip(message["content"] as? String ?? "")
        trace(request, text, prompt: prompt, cached: cached)
        return LLMResponse(text: text, usage: LLMUsage(inputTokens: prompt, outputTokens: completion))
    }

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: try urlRequest(request, stream: true))
                    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                        throw LLMError.http(status: (response as? HTTPURLResponse)?.statusCode ?? 0, message: "stream failed")
                    }
                    var filter = StreamingThinkFilter()
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let payload = line.dropFirst(6)
                        if payload == "[DONE]" { break }
                        guard let json = try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
                              let delta = ((json["choices"] as? [[String: Any]])?.first?["delta"] as? [String: Any])?["content"] as? String else { continue }
                        let visible = filter.consume(delta)
                        if !visible.isEmpty { continuation.yield(.delta(visible)) }
                    }
                    let rest = filter.finish()
                    if !rest.isEmpty { continuation.yield(.delta(rest)) }
                    stats.withLock { $0.calls += 1 }
                    continuation.yield(.done(nil))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// With `LECTERN_LIVE_TRACE=<path>`, appends each call's task (the part after the last
    /// "=====") and the reply, for prompt iteration.
    private func trace(_ request: LLMRequest, _ reply: String, prompt: Int, cached: Int) {
        guard let path = ProcessInfo.processInfo.environment["LECTERN_LIVE_TRACE"] else { return }
        let user = request.messages.last { $0.role == .user }?.content ?? ""
        let task = user.components(separatedBy: "=====").last ?? user
        let transcriptHead = user.hasPrefix("TRANSCRIPT") ? String(user.prefix(160)) + "…\n" : ""
        let entry = "\n######## prompt \(prompt) tok (\(cached) cached)\n\(transcriptHead)\(task.suffix(1500))\n>>>> \(reply)\n"
        let url = URL(fileURLWithPath: path)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile(); handle.write(Data(entry.utf8)); try? handle.close()
        } else {
            try? Data(entry.utf8).write(to: url)
        }
    }

    func healthCheck() async throws {
        _ = try await complete(LLMRequest(messages: [.user("Say OK.")], maxTokens: 5))
    }
}
