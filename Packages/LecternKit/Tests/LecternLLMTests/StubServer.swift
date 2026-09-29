import Foundation

/// One canned HTTP response for `StubServer`.
struct StubResponse: Sendable {
    var status = 200
    var headers: [String: String] = [:]
    /// Body pieces, delivered one `didLoad` at a time (to exercise chunk boundaries).
    var chunks: [Data] = []
    /// Fail the request with this transport error instead of responding.
    var failure: URLError.Code?
    /// Respond with headers, then never finish (for cancellation tests).
    var hangs = false

    static func json(_ text: String, status: Int = 200, headers: [String: String] = [:]) -> StubResponse {
        StubResponse(status: status, headers: headers, chunks: [Data(text.utf8)])
    }

    static func sse(_ chunks: [String]) -> StubResponse {
        StubResponse(headers: ["Content-Type": "text/event-stream"], chunks: chunks.map { Data($0.utf8) })
    }
}

struct CapturedRequest: Sendable {
    var url: URL
    var method: String
    var headers: [String: String]
    var body: Data

    /// The JSON body as a dictionary.
    var json: [String: Any] {
        (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
    }
}

/// A fake HTTP server reachable only through `session`. Each instance owns a unique host, so tests
/// can run in parallel without sharing state.
final class StubServer: @unchecked Sendable {
    // @unchecked Sendable: all mutable state is guarded by `lock`.
    private let lock = NSLock()
    private var queue: [StubResponse] = []
    private var captured: [CapturedRequest] = []
    private var stopped = 0

    let host = "stub-\(UUID().uuidString.lowercased()).test"
    let session: URLSession

    var baseURL: URL { URL(string: "http://\(host)/v1")! }

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        session = URLSession(configuration: configuration)
        StubURLProtocol.register(self, host: host)
    }

    deinit { StubURLProtocol.unregister(host: host) }

    func enqueue(_ responses: StubResponse...) {
        lock.withLock { queue.append(contentsOf: responses) }
    }

    var requests: [CapturedRequest] { lock.withLock { captured } }
    var stoppedLoadingCount: Int { lock.withLock { stopped } }

    fileprivate func next(for request: CapturedRequest) -> StubResponse {
        lock.withLock {
            captured.append(request)
            return queue.isEmpty ? .json(#"{"error":{"message":"stub queue empty"}}"#, status: 500) : queue.removeFirst()
        }
    }

    fileprivate func didStop() { lock.withLock { stopped += 1 } }
}

final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var servers: [String: StubServer] = [:]

    static func register(_ server: StubServer, host: String) {
        registryLock.withLock { servers[host] = server }
    }

    static func unregister(host: String) {
        registryLock.withLock { servers[host] = nil }
    }

    private static func server(for host: String?) -> StubServer? {
        registryLock.withLock { host.flatMap { servers[$0] } }
    }

    private var server: StubServer?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let server = Self.server(for: url.host()) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        self.server = server
        let captured = CapturedRequest(
            url: url,
            method: request.httpMethod ?? "GET",
            headers: request.allHTTPHeaderFields ?? [:],
            body: Self.readBody(of: request)
        )
        let response = server.next(for: captured)
        if let code = response.failure {
            client?.urlProtocol(self, didFailWithError: URLError(code, userInfo: [NSURLErrorFailingURLErrorKey: url]))
            return
        }
        let http = HTTPURLResponse(url: url, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: response.headers)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        for chunk in response.chunks { client?.urlProtocol(self, didLoad: chunk) }
        if !response.hangs { client?.urlProtocolDidFinishLoading(self) }
    }

    override func stopLoading() { server?.didStop() }

    private static func readBody(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
