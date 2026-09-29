import Foundation

// MARK: - Transcription contract
//
// Implemented in `LecternTranscription` (Parakeet via FluidAudio, Apple SpeechAnalyzer).
// The app only talks to `TranscriptionEngine`, so engines are swappable.

public enum TranscriptionEngineID: String, Codable, Sendable, CaseIterable, Hashable {
    case parakeet   // NVIDIA Parakeet TDT on the Neural Engine (FluidAudio / CoreML)
    case apple      // Apple SpeechAnalyzer / SpeechTranscriber (macOS 26+)

    public var displayName: String {
        switch self {
        case .parakeet: "Parakeet (Neural Engine)"
        case .apple: "Apple Speech"
        }
    }
}

public struct AudioInputDevice: Codable, Sendable, Hashable, Identifiable {
    /// CoreAudio device UID (stable across launches).
    public var id: String
    public var name: String
    public var isDefault: Bool

    public init(id: String, name: String, isDefault: Bool) {
        self.id = id
        self.name = name
        self.isDefault = isDefault
    }
}

public enum EngineReadiness: Sendable, Hashable {
    case ready
    /// Models must be downloaded first; `bytes` is the approximate download size if known.
    case needsDownload(bytes: Int64?)
    case unavailable(reason: String)
}

public enum TranscriptionEvent: Sendable, Hashable {
    /// The current in-progress hypothesis. Replaces any previous volatile text.
    case volatile(TranscriptSegment)
    /// A finalized segment. Clears the volatile text it covered.
    case final(TranscriptSegment)
    /// Normalized input level 0...1 (RMS, smoothed), emitted ~20×/s for the level meter.
    case level(Float)
    /// Non-fatal problem worth surfacing subtly (e.g. "Input device disconnected").
    case warning(String)
}

public struct TranscriptionOptions: Sendable, Hashable {
    /// `nil` = system default input.
    public var inputDeviceID: String?
    /// Jargon to bias recognition towards, when the engine supports it.
    public var vocabulary: [String]
    /// Session time offset to add to emitted timestamps (used when resuming after a pause).
    public var timeOffset: TimeInterval

    public init(inputDeviceID: String? = nil, vocabulary: [String] = [], timeOffset: TimeInterval = 0) {
        self.inputDeviceID = inputDeviceID
        self.vocabulary = vocabulary
        self.timeOffset = timeOffset
    }
}

public protocol TranscriptionEngine: AnyObject, Sendable {
    var engineID: TranscriptionEngineID { get }

    func readiness() async -> EngineReadiness

    /// Downloads / compiles models. Safe to call when already ready. `progress` is 0...1.
    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws

    /// Starts capturing from the microphone and transcribing. The stream finishes after `stop()`
    /// (after flushing a last `.final`) or throws on a fatal error.
    func start(options: TranscriptionOptions) async throws -> AsyncThrowingStream<TranscriptionEvent, Error>

    /// Stops capture, flushes pending audio as a final segment, and finishes the stream.
    func stop() async

    /// Offline transcription of an audio file (for importing a recording / testing).
    func transcribeFile(at url: URL, options: TranscriptionOptions) async throws -> AsyncThrowingStream<TranscriptionEvent, Error>
}

public protocol AudioDeviceProviding: Sendable {
    func inputDevices() -> [AudioInputDevice]
}
