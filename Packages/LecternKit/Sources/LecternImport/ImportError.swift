import Foundation

/// Everything that can go wrong while importing a recording or converting a presentation.
/// Descriptions are written for end users.
public enum ImportError: LocalizedError, Sendable, Equatable {
    // Recordings
    case unreadableMedia(String)
    case noAudioTrack
    case emptyTranscript
    // MediaSpace / Kaltura
    case notAMediaSpacePage
    case sessionExpired
    case mediaUnavailable(String)
    case unsupportedStream(String)
    case downloadFailed(status: Int)
    case malformedResponse(String)
    // Presentations
    case unsupportedFileType(String)
    case invalidPresentation(String)
    case noPresentationApp
    case automationDenied(app: String)
    case conversionFailed(app: String, message: String)
    case conversionTimedOut(app: String)

    public var errorDescription: String? {
        switch self {
        case .unreadableMedia(let detail):
            "This file can't be read as audio or video (\(detail))."
        case .noAudioTrack:
            "This recording doesn't contain an audio track."
        case .emptyTranscript:
            "No speech was found in this recording."
        case .notAMediaSpacePage:
            "This page doesn't contain a MediaSpace lecture. Open a recording, then try again."
        case .sessionExpired:
            "Your MediaSpace session has expired. Sign in again and reopen the recording."
        case .mediaUnavailable(let detail):
            "MediaSpace didn't provide the recording (\(detail))."
        case .unsupportedStream(let detail):
            "This MediaSpace stream can't be imported (\(detail))."
        case .downloadFailed(let status):
            "The download failed (HTTP \(status))."
        case .malformedResponse(let detail):
            "MediaSpace returned something unexpected (\(detail))."
        case .unsupportedFileType(let ext):
            "Lectern can't convert \".\(ext)\" files."
        case .invalidPresentation(let detail):
            "The presentation file is damaged or unreadable (\(detail))."
        case .noPresentationApp:
            "Converting slides needs Keynote or Microsoft PowerPoint, and neither is installed. Export the deck to PDF and import that instead."
        case .automationDenied(let app):
            "Lectern isn't allowed to control \(app). Open System Settings > Privacy & Security > Automation, enable \(app) under Lectern, and try again."
        case .conversionFailed(let app, let message):
            "\(app) couldn't export the presentation: \(message)"
        case .conversionTimedOut(let app):
            "\(app) didn't finish exporting within 60 seconds. It may be waiting on a dialog (for example missing fonts); close it and try again."
        }
    }
}
