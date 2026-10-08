import Foundation

/// What an import has achieved so far and what went wrong on the way. It is saved with the
/// session at every checkpoint (so an interrupted or failed import keeps its transcript and can be
/// finished from it) and stays on the finished lecture (so an incomplete result says so).
public struct ImportRecord: Codable, Sendable, Hashable {
    public enum Phase: String, Codable, Sendable, Hashable {
        /// Part of the recording is transcribed; `LectureSession.transcript` holds that part.
        case transcribing
        /// The whole transcript is saved; takeaways are not written yet.
        case transcribed
        /// Takeaways are being written; the saved ones cover the transcript up to some point.
        case summarizing
        /// The import ran to the end.
        case complete
    }

    public var phase: Phase
    /// Non-fatal problems met on the way: captions that fell back to transcription, engine
    /// warnings, failed summary passes, a checkpoint that could not be saved.
    public var warnings: [String]

    public init(phase: Phase, warnings: [String] = []) {
        self.phase = phase
        self.warnings = warnings
    }
}
