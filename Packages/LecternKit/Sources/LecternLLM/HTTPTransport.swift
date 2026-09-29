import Foundation
import LecternCore

/// A non-2xx response, before it is mapped to a user-facing `LLMError`.
struct HTTPStatusError: Error, Sendable {
    var status: Int
    var message: String
    /// Parsed `Retry-After` header, in seconds.
    var retryAfter: TimeInterval?
}

/// Incrementally turns SSE events into `LLMStreamEvent`s. One value per stream (it holds state).
protocol SSEDecoder: Sendable {
    /// Handles one event; returns zero or more stream events. Throws to abort the stream.
    mutating func consume(_ event: SSEEvent) throws -> [LLMStreamEvent]
    /// Called once when the connection closes; flushes held-back text and emits `.done` if the
    /// terminal event never arrived (or throws if the stream was cut short).
    mutating func finish() throws -> [LLMStreamEvent]
}

/// Shared URLSession plumbing for the HTTP providers: status/error mapping, one automatic retry for
/// non-streaming calls, and cancellation-aware SSE streaming.
struct HTTPTransport: Sendable {
    let session: URLSession
    let kind: ProviderKind
    let model: String
    /// Delay before the automatic retry when the server gives no `Retry-After`.
    let retryDelay: TimeInterval

    static let maxRetryAfter: TimeInterval = 10

    /// Performs the request and returns the 2xx body. Retries once on 429 / 5xx / connection loss.
    func send(_ request: URLRequest, retries: Int = 1) async throws -> Data {
        var attempt = 0
        while true {
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw LLMError.invalidResponse("Not an HTTP response.")
                }
                guard (200..<300).contains(http.statusCode) else {
                    throw Self.statusError(http, body: data)
                }
                return data
            } catch {
                guard attempt < retries, let delay = retryDelay(for: error) else {
                    throw mapError(error)
                }
                attempt += 1
                do {
                    try await Task.sleep(for: .seconds(delay))
                } catch {
                    throw mapError(error)
                }
            }
        }
    }

    /// Opens an SSE stream. Not retried: once bytes may have been delivered, replaying would
    /// duplicate text. Cancelling the consumer cancels the underlying URLSession task.
    func stream<D: SSEDecoder>(_ request: URLRequest, decoder: D) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var decoder = decoder
                do {
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        throw LLMError.invalidResponse("Not an HTTP response.")
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        var body = Data()
                        for try await byte in bytes {
                            body.append(byte)
                            if body.count >= 16_384 { break }
                        }
                        throw Self.statusError(http, body: body)
                    }
                    var parser = SSEParser()
                    var splitter = SSELineSplitter()
                    for try await byte in bytes {
                        guard let line = splitter.push(byte), let event = parser.feed(line: line) else { continue }
                        for out in try decoder.consume(event) { continuation.yield(out) }
                    }
                    if let line = splitter.finish(), let event = parser.feed(line: line) {
                        for out in try decoder.consume(event) { continuation.yield(out) }
                    }
                    if let event = parser.finish() {
                        for out in try decoder.consume(event) { continuation.yield(out) }
                    }
                    for out in try decoder.finish() { continuation.yield(out) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: mapError(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Errors

    /// Builds a `HTTPStatusError` from a response and its (possibly partial) body.
    static func statusError(_ response: HTTPURLResponse, body: Data) -> HTTPStatusError {
        let retryAfter = response.value(forHTTPHeaderField: "retry-after").flatMap(TimeInterval.init)
        return HTTPStatusError(status: response.statusCode, message: errorMessage(in: body), retryAfter: retryAfter)
    }

    /// Pulls the human-readable message out of an OpenAI / Anthropic / Ollama error body.
    static func errorMessage(in body: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            if let error = object["error"] as? [String: Any], let message = error["message"] as? String {
                return message
            }
            if let error = object["error"] as? String { return error }
            if let message = object["message"] as? String { return message }
        }
        let text = String(decoding: body.prefix(300), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "No details provided." : text
    }

    /// Maps any error thrown while talking to the server onto `LLMError`.
    func mapError(_ error: Error) -> LLMError {
        switch error {
        case let error as LLMError:
            return error
        case is CancellationError:
            return .cancelled
        case let error as URLError:
            if error.code == .cancelled { return .cancelled }
            return .network(networkDescription(error))
        case let error as HTTPStatusError:
            return mapStatus(error)
        default:
            return .network(error.localizedDescription)
        }
    }

    func mapStatus(_ error: HTTPStatusError) -> LLMError {
        let name = kind.displayName
        switch error.status {
        case 401, 403:
            return .http(
                status: error.status,
                message: "\(name) rejected the API key. Check it in Settings. (\(error.message))"
            )
        case 404 where kind == .localServer && error.message.localizedCaseInsensitiveContains("not found"):
            return .modelNotDownloaded(model)
        case 429:
            let wait = error.retryAfter.map { " Retry in \(Int($0.rounded(.up))) s." } ?? ""
            return .http(status: 429, message: "\(name) is rate limiting requests.\(wait) (\(error.message))")
        case 500...599:
            return .http(status: error.status, message: "\(name) had a server problem. (\(error.message))")
        default:
            return .http(status: error.status, message: error.message)
        }
    }

    private func networkDescription(_ error: URLError) -> String {
        switch error.code {
        case .cannotConnectToHost, .cannotFindHost:
            let host = error.failingURL?.host() ?? "the server"
            return "Couldn't connect to \(host). Is it running?"
        case .timedOut:
            return "The request to \(kind.displayName) timed out."
        case .notConnectedToInternet:
            return "No internet connection."
        default:
            return error.localizedDescription
        }
    }

    // MARK: Retry

    /// The delay before retrying `error`, or nil when it is not transient.
    private func retryDelay(for error: Error) -> TimeInterval? {
        switch error {
        case let error as HTTPStatusError where error.status == 429 || (500...599).contains(error.status):
            return min(error.retryAfter ?? retryDelay, Self.maxRetryAfter)
        case let error as URLError:
            let transient: Set<URLError.Code> = [
                .networkConnectionLost, .cannotConnectToHost, .cannotFindHost,
                .dnsLookupFailed, .notConnectedToInternet,
            ]
            return transient.contains(error.code) ? retryDelay : nil
        default:
            return nil
        }
    }
}
