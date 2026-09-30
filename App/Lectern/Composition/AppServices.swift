import Foundation
import LecternCore

/// Composition root. Views and models depend only on `LecternCore` contracts plus the small
/// app-side protocols declared in this folder; concrete backends are injected here.
///
/// `AppServices.demo` is fully self-contained (scripted lecture, in-memory store).
/// `AppServices.live` is where the lead wires the real modules (LecternTranscription, LecternLLM,
/// LecternMLX, LecternSlides, LecternStore, LecternIntelligence).
nonisolated struct AppServices: Sendable {

    // MARK: Transcription

    /// Creates a transcription engine for the given backend. Called once per session start.
    var makeTranscriptionEngine: @Sendable (TranscriptionEngineID) -> any TranscriptionEngine

    /// Lists microphone inputs (`AudioDeviceProviding`).
    var inputDevices: @Sendable () -> [AudioInputDevice]

    /// Live input level for the Setup meter, before a session starts.
    var makeLevelMonitor: @Sendable () -> any AudioLevelMonitoring

    /// Microphone permission status / request.
    var microphonePermission: @Sendable () -> MicrophonePermission
    var requestMicrophoneAccess: @Sendable () async -> Bool

    // MARK: Intelligence

    /// Creates the lecture brain for a session. `slides` is nil when the session has no deck.
    var makeBrain: @Sendable (BrainContext, AppSettings, (any SlideSearching)?) -> any LectureIntelligence

    // MARK: Slides

    var slideIngestor: any SlideIngesting
    /// Builds retrieval over an ingested deck. Returns nil when retrieval is unavailable.
    var makeSlideIndex: @Sendable (SlideDeck) -> (any SlideSearching)?

    // MARK: Persistence

    var store: any SessionStoring

    // MARK: Providers & models

    /// "Test connection" for a provider config; `apiKey` comes from the Keychain (nil for local).
    var providerHealthCheck: @Sendable (ProviderConfig, String?) async throws -> ProviderHealth
    /// On-device model catalog + download manager (Parakeet, MLX LLMs).
    var onDeviceModels: any OnDeviceModelManaging
    /// API keys, keyed by provider.
    var keychain: any APIKeyStoring

    // MARK: Search

    /// Full-text search over stored lectures. Implementations may back this with FTS5.
    var search: @Sendable (String, LibrarySearchScope) async throws -> [LibrarySearchHit]

    /// Optional sample deck offered in Setup (demo only; nil in production).
    var sampleDeckURL: @Sendable () async throws -> URL? = { nil }

    // MARK: Import & course-wide Ask

    /// Builds finished sessions from audio/video files or MediaSpace recordings.
    var recordingImporter: any RecordingImporting
    /// Embedded MediaSpace browser (LecternImport's `MediaSpaceBrowserView`).
    var mediaSpaceBrowser: any MediaSpaceBrowserProviding
    /// Converts .pptx / .key decks to PDF (+ presenter notes). Nil disables those formats.
    var presentationConverter: (any PresentationConverting)?
    /// Creates the course-wide assistant over a course's lectures.
    var makeCourseAssistant: @Sendable ([CourseLecture]) -> any CourseAssisting
}

// MARK: - App-side contracts (small, defined here so the lead can implement them in modules)

/// Streams smoothed RMS input level 0…1 (≈20 Hz) for level meters outside a transcription session.
nonisolated protocol AudioLevelMonitoring: AnyObject, Sendable {
    func start(deviceID: String?) -> AsyncStream<Float>
    func stop()
}

nonisolated enum MicrophonePermission: Sendable, Hashable {
    case granted, denied, notDetermined
}

/// Result of a provider "Test connection".
nonisolated struct ProviderHealth: Sendable, Hashable {
    var latencyMilliseconds: Int
    /// Optional detail, e.g. the model that answered or the number of models listed.
    var detail: String?
}

/// Which persistent API-key store to use. Real implementation: Security framework, service
/// `com.lectern.apikeys`, account = provider id.
nonisolated protocol APIKeyStoring: Sendable {
    func apiKey(for provider: ProviderKind) throws -> String?
    func setAPIKey(_ key: String?, for provider: ProviderKind) throws
}

/// One downloadable on-device model (speech or language).
nonisolated struct OnDeviceModelInfo: Sendable, Hashable, Identifiable {
    enum Purpose: String, Sendable, Hashable { case speech, language }
    /// Stable identifier: the HF repo id, or an engine id for speech models.
    var id: String
    var displayName: String
    var purpose: Purpose
    var sizeBytes: Int64
}

nonisolated enum OnDeviceModelState: Sendable, Hashable {
    case notInstalled
    case downloading(progress: Double, bytesPerSecond: Double?)
    case paused(progress: Double)
    case installed
    case failed(String)

    var isInstalled: Bool { self == .installed }
    var progress: Double? {
        switch self {
        case .downloading(let p, _), .paused(let p): p
        case .installed: 1
        default: nil
        }
    }
}

/// Download manager for on-device models. States are pushed as a whole-map snapshot so the UI can
/// mirror progress in the sidebar footer, Setup, Settings and Onboarding at once.
nonisolated protocol OnDeviceModelManaging: AnyObject, Sendable {
    var catalog: [OnDeviceModelInfo] { get }
    /// Emits the current states immediately, then on every change. Multiple consumers allowed.
    func states() -> AsyncStream<[String: OnDeviceModelState]>
    func download(id: String)
    func pause(id: String)
    func resume(id: String)
    func remove(id: String)
    /// Free space at the models location, in bytes.
    func freeSpaceBytes() -> Int64
}

nonisolated enum LibrarySearchScope: String, CaseIterable, Sendable, Hashable, Identifiable {
    case all, titles, transcripts, takeaways
    var id: String { rawValue }
    var label: String {
        switch self {
        case .all: "All"
        case .titles: "Titles"
        case .transcripts: "Transcripts"
        case .takeaways: "Takeaways"
        }
    }
}

nonisolated struct LibrarySearchHit: Sendable, Hashable, Identifiable {
    enum Field: Sendable, Hashable { case title, transcript, takeaway }
    var id: String { "\(sessionID)-\(field)-\(time ?? -1)-\(snippet.hashValue)" }
    var sessionID: UUID
    var field: Field
    /// Text around the match; `matchRange` is the character range of the match inside it.
    var snippet: String
    var matchRange: Range<String.Index>?
    var time: TimeInterval?
    var slide: Int?
}

// MARK: - Wiring

extension AppServices {
    /// Real modules (see LiveServices.swift).
    static var live: AppServices { makeLive() }

    /// In-app demo stack: scripted compilers lecture, simulated brain, in-memory store.
    static var demo: AppServices {
        let demoStore = DemoStore()
        let models = DemoModelManager()
        return AppServices(
            makeTranscriptionEngine: { _ in DemoTranscriptionEngine(script: .compilers, speed: DemoConfiguration.current.speed) },
            inputDevices: {
                [
                    AudioInputDevice(id: "builtin", name: "MacBook Pro Microphone", isDefault: true),
                    AudioInputDevice(id: "usb", name: "Yeti Nano", isDefault: false),
                ]
            },
            makeLevelMonitor: { DemoLevelMonitor() },
            microphonePermission: { .granted },
            requestMicrophoneAccess: { true },
            makeBrain: { context, settings, _ in DemoBrain(context: context, settings: settings, speed: DemoConfiguration.current.speed) },
            slideIngestor: PDFSlideIngestor(),
            makeSlideIndex: { deck in SimpleSlideIndex(deck: deck) },
            store: demoStore,
            providerHealthCheck: { config, key in
                try await Task.sleep(for: .milliseconds(650))
                switch config.kind {
                case .onDevice: return ProviderHealth(latencyMilliseconds: 12, detail: nil)
                case .localServer: return ProviderHealth(latencyMilliseconds: 41, detail: "3 models")
                case .openAI, .anthropic:
                    guard let key, !key.isEmpty else { throw LLMError.missingAPIKey(config.kind) }
                    guard key.count >= 8 else { throw LLMError.http(status: 401, message: "Unauthorized") }
                    return ProviderHealth(latencyMilliseconds: 412, detail: config.model)
                }
            },
            onDeviceModels: models,
            keychain: InMemoryAPIKeyStore(),
            search: { query, scope in await demoStore.search(query, scope: scope) },
            sampleDeckURL: { try await demoStore.sampleDeckURL() },
            recordingImporter: DemoRecordingImporter(speed: DemoConfiguration.current.speed),
            mediaSpaceBrowser: DemoMediaSpaceBrowser(),
            presentationConverter: DemoPresentationConverter(samplePDF: { try await demoStore.sampleDeckURL() }),
            makeCourseAssistant: { lectures in DemoCourseAssistant(lectures: lectures, speed: DemoConfiguration.current.speed) }
        )
    }
}

/// Launch-time demo switches. `-demo` forces the demo stack; `-demoSpeed 3` runs the scripted
/// lecture 3× faster (useful for screenshots).
nonisolated struct DemoConfiguration: Sendable {
    var isEnabled: Bool
    var speed: Double
    /// `-flatGlass`: opaque stand-ins for Liquid Glass (screenshot automation / Reduce Transparency check).
    var flatGlass: Bool
    /// `-demoToken <t>`: required prefix for `DemoDriver` commands; without it the driver ignores everything.
    var driverToken: String?

    static let current: DemoConfiguration = {
        let args = CommandLine.arguments
        let enabled = args.contains("-demo") || ProcessInfo.processInfo.environment["LECTERN_DEMO"] == "1"
        var speed = 1.0
        if let i = args.firstIndex(of: "-demoSpeed"), i + 1 < args.count, let s = Double(args[i + 1]), s > 0 {
            speed = s
        }
        var token: String?
        if let i = args.firstIndex(of: "-demoToken"), i + 1 < args.count { token = args[i + 1] }
        return DemoConfiguration(isEnabled: enabled, speed: speed, flatGlass: args.contains("-flatGlass"), driverToken: token)
    }()
}
