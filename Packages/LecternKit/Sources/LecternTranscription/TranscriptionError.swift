import Foundation

/// Errors surfaced by the transcription engines and audio capture.
public enum TranscriptionError: Error, LocalizedError, Sendable {
    case microphoneAccessDenied
    case inputDeviceNotFound(String)
    case audioEngineFailed(String)
    case modelsNotInstalled(engine: String)
    case alreadyRunning
    case fileUnreadable(URL, String)
    case recognitionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .microphoneAccessDenied:
            "Microphone access is denied. Allow it in System Settings > Privacy & Security > Microphone."
        case .inputDeviceNotFound(let id):
            "The selected input device (\(id)) is not connected."
        case .audioEngineFailed(let reason):
            "Audio capture failed: \(reason)"
        case .modelsNotInstalled(let engine):
            "\(engine) speech models are not installed yet. Download them first."
        case .alreadyRunning:
            "Transcription is already running."
        case .fileUnreadable(let url, let reason):
            "Could not read \(url.lastPathComponent): \(reason)"
        case .recognitionFailed(let reason):
            "Speech recognition failed: \(reason)"
        }
    }
}
