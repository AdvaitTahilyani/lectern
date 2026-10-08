import Foundation

/// Thin wrapper over `URLSession` that maps HTTP failures to `ImportError` and reports download
/// progress.
struct HTTPFetcher: Sendable {
    var session: URLSession

    /// - Parameter byteRange: when set, only that slice of the resource is requested. A server
    ///   that ignores the header and sends the whole file is cut down to the slice here.
    func data(from url: URL, byteRange: Range<Int>? = nil) async throws -> Data {
        guard let byteRange else {
            let (data, response) = try await session.data(from: url)
            try Self.validate(response)
            return data
        }
        var request = URLRequest(url: url)
        request.setValue("bytes=\(byteRange.lowerBound)-\(byteRange.upperBound - 1)", forHTTPHeaderField: "Range")
        let (data, response) = try await session.data(for: request)
        try Self.validate(response)
        if (response as? HTTPURLResponse)?.statusCode == 200, data.count >= byteRange.upperBound {
            return data.subdata(in: byteRange)   // the server sent the whole file
        }
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
