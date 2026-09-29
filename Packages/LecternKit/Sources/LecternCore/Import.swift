import Foundation

// MARK: - Importing recordings & presentations (implemented in LecternImport)

/// A lecture found on an Illinois MediaSpace (Kaltura) page, with the signed session that lets
/// us fetch its media. Obtained from the in-app MediaSpace browser after the user signs in.
public struct MediaSpaceSource: Codable, Sendable, Hashable {
    public var partnerID: String
    public var entryID: String
    /// Kaltura session token scraped from the page (expires after a few hours).
    public var ks: String
    public var title: String?
    public var pageURL: URL?

    public init(partnerID: String, entryID: String, ks: String, title: String?, pageURL: URL?) {
        self.partnerID = partnerID
        self.entryID = entryID
        self.ks = ks
        self.title = title
        self.pageURL = pageURL
    }
}

public enum RecordingSource: Sendable, Hashable {
    /// Any audio or video file AVFoundation can read (m4a, mp3, wav, mp4, mov…).
    case file(URL)
    case mediaSpace(MediaSpaceSource, preferCaptions: Bool)
}

public enum ImportStage: Sendable, Hashable {
    case downloading(fraction: Double)
    case extractingAudio
    case transcribing(fraction: Double)
    case summarizing(fraction: Double)
    case finished
}

/// Produces a finished `LectureSession` from a recording: transcript (on-device ASR or the
/// MediaSpace caption track), speaker labels, then takeaways via the intelligence layer.
public protocol RecordingImporting: Sendable {
    func importRecording(
        _ source: RecordingSource,
        into session: LectureSession,
        progress: @escaping @Sendable (ImportStage) -> Void
    ) async throws -> LectureSession
}

/// Converts presentation files the ingestor can't read directly (PPTX, Keynote) into a PDF, and
/// extracts presenter notes keyed by 1-based slide number.
public protocol PresentationConverting: Sendable {
    /// File extensions this converter handles (lowercased, e.g. ["pptx", "key"]).
    var supportedExtensions: Set<String> { get }
    func convertToPDF(_ url: URL) async throws -> (pdf: URL, notes: [Int: String])
}
