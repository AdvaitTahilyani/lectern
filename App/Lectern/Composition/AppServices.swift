import Foundation
import LecternCore
import LecternSlides

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
    /// The per-role providers `settings` select, for an existing brain whose session is `UUID`
    /// (usage is attributed to it) when the user changes a provider or model. Nil when brains
    /// have no providers to switch (demo).
    var makeRoleProviders: (@Sendable (AppSettings, UUID?) -> RoleProviders)? = nil

    // MARK: Slides

    var slideIngestor: any SlideIngesting
    /// Builds retrieval over an ingested deck. Returns nil when retrieval is unavailable. Async
    /// because indexing embeds every page (seconds for a long deck): never call it on the main actor
    /// synchronously.
    var makeSlideIndex: @Sendable (SlideDeck) async -> (any SlideSearching)?

    // MARK: Persistence

    var store: any SessionStoring
    /// Reads the library and reports the session files that had to be skipped. Nil falls back to
    /// `store.loadSessions()` (no report).
    var readLibrary: (@Sendable () async throws -> LibraryLoad)? = nil

    // MARK: Providers & models

    /// "Test connection" for a provider config. `apiKey` is the key being tested (typed, not necessarily saved yet; nil for local).
    var providerHealthCheck: @Sendable (ProviderConfig, String?) async throws -> ProviderHealth
    /// On-device model catalog + download manager (Parakeet, MLX LLMs).
    var onDeviceModels: any OnDeviceModelManaging
    /// API keys, keyed by provider.
    var keychain: any APIKeyStoring

    // MARK: Search

    /// Full-text search over the given lectures (the app's in-memory library; nothing is re-read
    /// from disk per query).
    var search: @Sendable (String, LibrarySearchScope, [LectureSession]) async throws -> [LibrarySearchHit]

    /// Optional sample deck offered in Setup (demo only; nil in production).
    var sampleDeckURL: @Sendable () async throws -> URL? = { nil }

    // MARK: Import & course-wide Ask

    /// Builds finished sessions from audio/video files or MediaSpace recordings.
    var recordingImporter: any RecordingImporting
    /// Embedded MediaSpace browser (LecternImport's `MediaSpaceBrowserView`).
    var mediaSpaceBrowser: any MediaSpaceBrowserProviding
    /// Converts .pptx / .key decks to PDF (+ presenter notes). Nil disables those formats.
    var presentationConverter: (any PresentationConverting)?
    /// Creates the course-wide assistant over a course's lectures, given the course's display name.
    var makeCourseAssistant: @Sendable ([CourseLecture], String?) -> any CourseAssisting

    // MARK: Slides folder, jargon correction, API cost

    /// Ranks the decks in a course's slides folder for the next lecture: `(folder, deck file names
    /// used by earlier sessions of the course, accepted extensions)`. Throws when the folder can't
    /// be read. The demo has no folder support.
    var suggestDecks: @Sendable (URL, Set<String>, Set<String>) throws -> SuggestedDecks = { _, _, _ in .none }
    /// Builds a corrector that fixes misheard course jargon from an ingested deck. Nil disables it.
    var makeTranscriptCorrector: @Sendable (SlideDeck) -> (any TranscriptCorrecting)? = { _ in nil }
    /// Cloud API spending (this month, per lecture). Nil when nothing is metered (demo).
    var usage: (any UsageReporting)? = nil
}

// MARK: - App-side contracts (small, defined here so the lead can implement them in modules)

/// The sessions found on disk, plus the session files that were damaged.
nonisolated struct LibraryLoad: Sendable {
    var sessions: [LectureSession]
    var issues: [LibraryIssue] = []
}

/// A damaged session file found while loading the library.
nonisolated struct LibraryIssue: Sendable, Hashable {
    enum Kind: Sendable, Hashable {
        /// Left out of the library; the file is untouched.
        case skipped
        /// Restored from its last good copy; the latest changes may be missing.
        case restored
        /// Loaded without some damaged parts; the original was kept.
        case partiallyRecovered
    }
    var file: URL
    var kind: Kind
}

/// Ordered, throttled saving of one session (`LecternStore.SessionAutosaver`).
nonisolated protocol SessionAutosaving: Sendable {
    /// Records the newest state; it is written at most once per interval, never out of order.
    func update(_ session: LectureSession) async
    /// Writes the newest state now and waits for every write in flight.
    func flush() async throws
    /// Drops pending work and waits for a running write, so a delete can't be undone by a late save.
    func discard() async
}

extension AppServices {
    /// The library from disk, with the damaged session files when the store reports them.
    func loadLibrary() async throws -> LibraryLoad {
        if let readLibrary { return try await readLibrary() }
        return LibraryLoad(sessions: try await store.loadSessions())
    }
}

/// The deck Setup offers for the next lecture of a course, plus the rest of its slides folder.
nonisolated struct SuggestedDecks: Sendable, Hashable {
    /// The one prominent suggestion ("Use lec9-ir-gen.pdf").
    var primary: URL?
    /// Every other deck in the folder, in lecture order.
    var others: [URL]

    static let none = SuggestedDecks(primary: nil, others: [])
    var isEmpty: Bool { primary == nil && others.isEmpty }
}

/// Cloud API spending, from the usage ledger (Settings › Models and Review).
nonisolated protocol UsageReporting: Sendable {
    /// This calendar month's spending, per provider and model.
    func currentMonth() async -> UsageMonthSummary
    /// Total API cost attributed to one lecture, in US dollars.
    func cost(forSession id: UUID) async -> Double
    /// Emits whenever a call is recorded (and once immediately), so views can refresh.
    func changes() async -> AsyncStream<Void>
    /// Emits when the monthly cap first stops cloud calls this month (at most once per month).
    func capNotices() async -> AsyncStream<UsageCapNotice>
}

nonisolated struct UsageMonthSummary: Sendable, Hashable {
    struct Line: Sendable, Hashable, Identifiable {
        var id: String { "\(provider.rawValue)/\(model)" }
        var provider: ProviderKind
        var model: String
        var calls: Int
        var inputTokens: Int
        var outputTokens: Int
        var cachedInputTokens: Int
        var costUSD: Double
        /// Some of this cost was worked out locally (cancelled streams, unpriced models), not reported.
        var isEstimate: Bool = false
    }
    /// e.g. "September 2026".
    var monthName: String
    var totalUSD: Double
    var lines: [Line]
    /// Set when the usage history couldn't be read or saved, so the totals may be incomplete.
    var storageProblem: String? = nil

    static let empty = UsageMonthSummary(monthName: "", totalUSD: 0, lines: [])
}

/// The monthly cap was reached: cloud calls now run on-device (`fellBack`) or fail.
nonisolated struct UsageCapNotice: Sendable, Hashable {
    var capUSD: Double
    var fellBack: Bool
}

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
            makeSlideIndex: { deck in await SlideIndex.build(deck: deck, useSemanticSimilarity: false) },
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
            search: { query, scope, _ in await demoStore.search(query, scope: scope) },
            sampleDeckURL: { try await demoStore.sampleDeckURL() },
            recordingImporter: DemoRecordingImporter(speed: DemoConfiguration.current.speed),
            mediaSpaceBrowser: DemoMediaSpaceBrowser(),
            presentationConverter: DemoPresentationConverter(samplePDF: { try await demoStore.sampleDeckURL() }),
            makeCourseAssistant: { lectures, _ in DemoCourseAssistant(lectures: lectures, speed: DemoConfiguration.current.speed) }
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

extension UserDefaults {
    /// Where settings and UI preferences persist. Demo mode gets its own suite so scripted runs
    /// never change the real app's settings (e.g. marking onboarding as completed).
    // `UserDefaults` is documented as thread-safe but isn't marked Sendable in the SDK.
    nonisolated(unsafe) static let lectern: UserDefaults =
        DemoConfiguration.current.isEnabled ? UserDefaults(suiteName: "com.advait.Lectern.demo") ?? .standard : .standard
}
