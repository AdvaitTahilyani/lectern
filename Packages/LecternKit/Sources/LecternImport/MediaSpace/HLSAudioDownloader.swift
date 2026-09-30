import Foundation

/// Downloads an HLS media playlist's segments concurrently and writes their audio, in order, as a
/// raw `.aac` / `.mp3` file (see `MPEGTSAudioDemuxer`).
struct HLSAudioDownloader: Sendable {
    var fetcher: HTTPFetcher
    /// Segments in flight at once.
    var concurrency = 6
    /// Retries per segment for transient network errors.
    var retries = 2

    /// - Parameters:
    ///   - destinationStem: output path without extension; the demuxed codec picks the extension.
    ///   - progress: 0...1 over segments written.
    /// - Returns: the file written.
    func download(_ playlist: HLSMediaPlaylist, toStem destinationStem: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let segments = playlist.segments
        var output: (handle: FileHandle, url: URL)?
        var codec: MPEGTSAudioDemuxer.Codec?
        defer { try? output?.handle.close() }

        var nextToStart = 0
        var nextToWrite = 0
        var ready: [Int: MPEGTSAudioDemuxer.Audio] = [:]
        var bytesWritten = 0

        try await withThrowingTaskGroup(of: (Int, MPEGTSAudioDemuxer.Audio).self) { group in
            func startMore() {
                while nextToStart < segments.count, nextToStart - nextToWrite < concurrency * 4, group.isEmpty || nextToStart - nextToWrite < concurrency {
                    let index = nextToStart
                    nextToStart += 1
                    group.addTask { (index, try await fetchAudio(of: segments[index])) }
                }
            }
            startMore()
            while let (index, audio) = try await group.next() {
                ready[index] = audio
                while let next = ready.removeValue(forKey: nextToWrite) {
                    if output == nil {
                        let url = destinationStem.appendingPathExtension(next.codec.fileExtension)
                        try? FileManager.default.removeItem(at: url)
                        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                            throw ImportError.unreadableMedia("cannot create \(url.lastPathComponent)")
                        }
                        output = (try FileHandle(forWritingTo: url), url)
                        codec = next.codec
                    } else if next.codec != codec {
                        throw ImportError.unsupportedStream("audio codec changes mid-stream")
                    }
                    try output?.handle.write(contentsOf: next.data)
                    bytesWritten += next.data.count
                    nextToWrite += 1
                    progress(Double(nextToWrite) / Double(segments.count))
                }
                startMore()
            }
        }
        guard let output, bytesWritten > 0 else { throw ImportError.unsupportedStream("no audio in the stream") }
        return output.url
    }

    private func fetchAudio(of segment: HLSSegment) async throws -> MPEGTSAudioDemuxer.Audio {
        var attempt = 0
        while true {
            do {
                return try MPEGTSAudioDemuxer.extractAudio(from: try await fetcher.data(from: segment.url))
            } catch where attempt < retries && Self.isTransient(error) {
                attempt += 1
                try await Task.sleep(for: .milliseconds(400 * attempt))
            }
        }
    }

    /// Network errors and CDN hiccups (5xx, throttling) that a retry can clear; a long lecture is
    /// hundreds of segments, so one of them failing once must not sink the import.
    private static func isTransient(_ error: Error) -> Bool {
        if let urlError = error as? URLError { return urlError.code != .cancelled }
        if case ImportError.downloadFailed(let status) = error { return status >= 500 || status == 429 }
        return false
    }
}
