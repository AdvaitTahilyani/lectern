import Foundation

/// Thin wrapper over `URLSession` that maps HTTP failures to `ImportError` and reports download
/// progress.
struct HTTPFetcher: Sendable {
    var session: URLSession

    func data(from url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        try Self.validate(response)
        return data
    }

    func string(from url: URL) async throws -> String {
        let data = try await data(from: url)
        guard let text = String(data: data, encoding: .utf8) else {
            throw ImportError.malformedResponse("response is not text")
        }
        return text
    }

    /// Downloads `url` to `destination` (replacing it), following redirects.
    func download(_ url: URL, to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let (temporary, response) = try await session.download(from: url, delegate: ProgressDelegate(progress))
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Self.validate(response)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
    }

    static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        switch http.statusCode {
        case 200..<300: return
        case 401, 403: throw ImportError.sessionExpired
        case 404: throw ImportError.mediaUnavailable("not found")
        default: throw ImportError.downloadFailed(status: http.statusCode)
        }
    }

    private final class ProgressDelegate: NSObject, URLSessionDownloadDelegate, Sendable {
        private let progress: @Sendable (Double) -> Void

        init(_ progress: @escaping @Sendable (Double) -> Void) { self.progress = progress }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            guard totalBytesExpectedToWrite > 0 else { return }
            progress(min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    }
}
