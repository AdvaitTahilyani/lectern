import LecternCore

/// Factory for the available speech-to-text engines.
public enum TranscriptionEngines {
    /// Creates an engine. Engines hold loaded models, so create one per app run and reuse it.
    public static func make(_ id: TranscriptionEngineID) -> any TranscriptionEngine {
        switch id {
        case .parakeet: ParakeetEngine()
        case .apple: AppleSpeechEngine()
        }
    }
}
