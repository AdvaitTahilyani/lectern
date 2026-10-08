import AVFoundation
import Foundation
import SwiftUI
import Synchronization
import LecternCore
import LecternImport
import LecternIntelligence
import LecternLLM
import LecternSlides
import LecternStore
import LecternTranscription

// The real modules behind `AppServices`. Each closure only adapts types; behavior lives in the
// packages.

extension AppServices {
    static func makeLive() -> AppServices {
        SelfTest.runIfRequested()
        let store = FileSessionStore(movesDeletedToTrash: true)
        let keychain = KeychainStore()
        let engines = EngineCache.shared
        let onDevice = OnDeviceStack.shared

        return AppServices(
            makeTranscriptionEngine: { engines.engine(for: $0) },
            inputDevices: { CoreAudioDeviceProvider().inputDevices() },
            makeLevelMonitor: { CaptureLevelMonitor() },
            microphonePermission: {
                switch AVCaptureDevice.authorizationStatus(for: .audio) {
                case .authorized: .granted
                case .notDetermined: .notDetermined
                default: .denied
                }
            },
            requestMicrophoneAccess: { await AVCaptureDevice.requestAccess(for: .audio) },
            makeBrain: { context, settings, slides in
                OnDeviceStack.shared.warmUp(for: settings)
                return LectureBrain(
                    context: context,
                    providers: ProviderResolver.roleProviders(for: settings, keychain: keychain, sessionID: context.sessionID),
                    slides: slides,
                    quiz: settings.quiz,
                    summaryIntervalSeconds: settings.summaryIntervalSeconds
                )
            },
            makeRoleProviders: { settings, sessionID in
                // A role moved to the on-device model: load it before the next call needs it.
                OnDeviceStack.shared.warmUp(for: settings)
                return ProviderResolver.roleProviders(for: settings, keychain: keychain, sessionID: sessionID)
            },
            slideIngestor: PDFSlideIngestor(),
            makeSlideIndex: { await SlideIndex.build(deck: $0) },
            store: store,
            readLibrary: {
                let library = try await store.loadLibrary()
                let issues = library.issues.map { issue -> LibraryIssue in
                    let kind: LibraryIssue.Kind = switch issue.kind {
                    case .skipped: .skipped
                    case .restored: .restored
                    case .partiallyRecovered: .partiallyRecovered
                    }
                    return LibraryIssue(file: issue.url, kind: kind)
                }
                return LibraryLoad(sessions: library.sessions, issues: issues)
            },
            providerHealthCheck: { config, apiKey in
                let provider = try HealthCheckProvider.make(config, apiKey: apiKey, keychain: keychain)
                let start = ContinuousClock.now
                try await provider.healthCheck()
                let ms = Int((ContinuousClock.now - start) / .milliseconds(1))
                return ProviderHealth(latencyMilliseconds: ms, detail: config.model)
            },
            onDeviceModels: onDevice.modelManager,
            keychain: KeychainKeyStore(keychain: keychain),
            search: { query, scope, sessions in
                // The scope selects which fields are searched, before the result limit applies (B29).
                LibrarySearch.search(query, in: sessions, kinds: scope.kinds).map { LibrarySearchHit(hit: $0, query: query) }
            },
            recordingImporter: RecordingImporter(
                makeEngine: { TranscriptionEngines.make(StoredSettings.current().transcriptionEngine) },
                makeBrain: { context in
                    let settings = StoredSettings.current()
                    let slides = context.deck.map { SlideIndex(deck: $0) }
                    return LectureBrain(
                        context: context,
                        providers: ProviderResolver.roleProviders(for: settings, keychain: keychain, sessionID: context.sessionID),
                        slides: slides,
                        quiz: settings.quiz,
                        summaryIntervalSeconds: settings.summaryIntervalSeconds
                    )
                },
                correctTranscript: { transcript, deck in
                    guard StoredSettings.current().fixesJargonFromSlides, let deck else { return transcript }
                    let vocabulary = DeckVocabulary(deck: deck)
                    guard !vocabulary.isEmpty else { return transcript }
                    let corrector = TranscriptCorrector(vocabulary: vocabulary)
                    return transcript.map(corrector.correct)
                },
                // An import saves its transcript and takeaways as it goes, so an interruption leaves
                // a lecture that can be finished.
                checkpoint: { try await store.save($0) }
            ),
            mediaSpaceBrowser: LiveMediaSpaceBrowser(),
            presentationConverter: PresentationConverter(),
            makeCourseAssistant: { lectures, courseName in
                let settings = StoredSettings.current()
                return CourseAssistant(
                    lectures: lectures,
                    courseName: courseName,
                    provider: ProviderResolver.resolvedProvider(for: settings.provider(for: .ask), role: .ask, keychain: keychain)
                )
            },
            suggestDecks: { folder, used, accepted in
                let candidates = try DeckSuggester.scan(folder: folder, extensions: DeckSuggester.deckExtensions.intersection(accepted))
                let suggestion = DeckSuggester.suggest(candidates, usedFileNames: used)
                return SuggestedDecks(primary: suggestion.primary?.url, others: suggestion.others.map(\.url))
            },
            makeTranscriptCorrector: { deck in
                let vocabulary = DeckVocabulary(deck: deck)
                guard !vocabulary.isEmpty else { return nil }
                Task.detached(priority: .utility) { TranscriptCorrector.preloadWordList() }
                return TranscriptCorrector(vocabulary: vocabulary)
            },
            usage: LedgerUsageReporter(ledger: UsageMeter.ledger)
        )
    }
}

// MARK: - Autosave

extension SessionAutosaver: SessionAutosaving {}

extension AppServices {
    /// A saver for one session's writes to `store`. `onError` reports a failed background save
    /// (it is retried after the next interval).
    func makeAutosaver(onError: @escaping @Sendable (any Error) -> Void) -> any SessionAutosaving {
        SessionAutosaver(store: store, interval: .seconds(1), onError: onError)
    }
}

// MARK: - Providers

/// Turns `ProviderConfig`s into providers. On-device configs go to the in-process MLX host; the
/// rest to LecternLLM. Construction failures (e.g. a missing API key) become a provider that fails
/// on use, so the brain surfaces the error through its normal `.error` path instead of the app
/// failing to start a session.
nonisolated enum ProviderResolver {
    static func provider(for config: ProviderConfig, role: LLMRole? = nil, keychain: KeychainStore) throws -> any LLMProvider {
        switch config.kind {
        case .onDevice: try OnDeviceStack.shared.provider(model: config.model, role: role)
        default: try LLMProviderFactory.make(config, keychain: keychain)
        }
    }

    /// Cloud providers come back metered (usage and cost go to `UsageMeter.ledger`, attributed to
    /// `sessionID`) and guarded by the monthly cap.
    static func resolvedProvider(for config: ProviderConfig, role: LLMRole? = nil, keychain: KeychainStore, sessionID: UUID? = nil) -> any LLMProvider {
        do {
            let provider = try provider(for: config, role: role, keychain: keychain)
            return config.kind.isCloud ? UsageMeter.guarded(provider, role: role, sessionID: sessionID) : provider
        } catch {
            return UnavailableProvider(kind: config.kind, model: config.model, error: error)
        }
    }

    /// One provider per role. On-device roles still share the host's single loaded model and
    /// prompt cache; the role sets queue priority.
    static func roleProviders(for settings: AppSettings, keychain: KeychainStore, sessionID: UUID? = nil) -> RoleProviders {
        func resolve(_ role: LLMRole) -> any LLMProvider {
            resolvedProvider(for: settings.provider(for: role), role: role, keychain: keychain, sessionID: sessionID)
        }
        return RoleProviders(summaries: resolve(.summaries), quizzes: resolve(.quizzes), ask: resolve(.ask))
    }
}

/// The provider "Test connection" runs. A cloud provider is built from the key being tested (typed
/// in Settings or Onboarding, not saved yet), never from the Keychain.
nonisolated enum HealthCheckProvider {
    static func make(_ config: ProviderConfig, apiKey: String?, keychain: KeychainStore) throws -> any LLMProvider {
        switch config.kind {
        case .openAI, .anthropic:
            guard let apiKey, !apiKey.isEmpty else { throw LLMError.missingAPIKey(config.kind) }
            if config.kind == .openAI {
                return OpenAICompatibleProvider.openAI(apiKey: apiKey, model: config.model, baseURL: config.baseURL ?? OpenAICompatibleProvider.openAIBaseURL)
            }
            return AnthropicProvider(apiKey: apiKey, model: config.model, baseURL: config.baseURL ?? AnthropicProvider.baseURL)
        case .onDevice, .localServer:
            return try ProviderResolver.provider(for: config, keychain: keychain)
        }
    }
}

// MARK: - API cost

/// The usage ledger behind every cloud call, and the monthly cap around it.
nonisolated enum UsageMeter {
    /// Application Support/Lectern/usage.json.
    static let ledger = UsageLedger()

    /// `provider` metered into the ledger and capped: over this month's cap it falls back to the
    /// on-device model when one is downloaded, else fails with `MonthlyCapReached`.
    static func guarded(_ provider: any LLMProvider, role: LLMRole?, sessionID: UUID?) -> any LLMProvider {
        CappedProvider(
            MeteredProvider(provider, ledger: ledger, sessionID: sessionID),
            ledger: ledger,
            cap: { StoredSettings.current().monthlyCloudCapUSD },
            fallback: { OnDeviceStack.shared.fallbackProvider(role: role) }
        )
    }
}

/// `UsageReporting` over the ledger, for Settings › Models and Review.
nonisolated struct LedgerUsageReporter: UsageReporting {
    let ledger: UsageLedger

    func currentMonth() async -> UsageMonthSummary {
        let month = await ledger.month()
        return UsageMonthSummary(
            monthName: Self.displayName(month: month.month),
            totalUSD: month.totalUSD,
            lines: month.breakdown.map { m in
                UsageMonthSummary.Line(
                    provider: m.provider, model: m.model, calls: m.totals.calls, inputTokens: m.totals.inputTokens,
                    outputTokens: m.totals.outputTokens, cachedInputTokens: m.totals.cachedInputTokens, costUSD: m.totals.costUSD,
                    isEstimate: m.isEstimate
                )
            },
            storageProblem: await ledger.storageProblem()
        )
    }

    func cost(forSession id: UUID) async -> Double { await ledger.cost(forSession: id) }

    func changes() async -> AsyncStream<Void> { await ledger.changes() }

    func capNotices() async -> AsyncStream<UsageCapNotice> {
        let source = await ledger.capNotices()
        return AsyncStream { continuation in
            let task = Task {
                for await notice in source { continuation.yield(UsageCapNotice(capUSD: notice.capUSD, fellBack: notice.fellBack)) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// "2026-09" → "September 2026".
    static func displayName(month key: String) -> String {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 2, let date = Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1])) else { return key }
        return date.formatted(.dateTime.month(.wide).year())
    }
}

/// A provider that could not be constructed; every call rethrows the construction error.
nonisolated struct UnavailableProvider: LLMProvider {
    let kind: ProviderKind
    let model: String
    let error: any Error

    func complete(_ request: LLMRequest) async throws -> LLMResponse { throw error }
    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: error) }
    }
    func healthCheck() async throws { throw error }
}

// MARK: - Settings outside the main actor

/// Reads the settings `AppModel` persists, for services created outside a session (imports,
/// course Ask) that aren't handed `AppSettings` directly.
nonisolated enum StoredSettings {
    static let key = "LecternSettings"

    static func current() -> AppSettings {
        guard let data = UserDefaults.lectern.data(forKey: key),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else { return AppSettings() }
        return settings
    }
}

// MARK: - Transcription

/// Engines hold loaded CoreML models, so live sessions reuse one instance per engine kind.
nonisolated final class EngineCache: Sendable {
    static let shared = EngineCache()

    private let engines = Mutex<[TranscriptionEngineID: any TranscriptionEngine]>([:])

    func engine(for id: TranscriptionEngineID) -> any TranscriptionEngine {
        engines.withLock { cache in
            if let engine = cache[id] { return engine }
            let engine = TranscriptionEngines.make(id)
            cache[id] = engine
            return engine
        }
    }
}

/// Setup's level meter, backed by the same capture pipeline transcription uses.
///
/// The reader task owns the capture for its whole life: it stops the capture when it ends, so a
/// `stop()` that arrives while `start` is still awaiting the microphone can't orphan the engine.
nonisolated final class CaptureLevelMonitor: AudioLevelMonitoring {
    private let task = Mutex<Task<Void, Never>?>(nil)

    func start(deviceID: String?) -> AsyncStream<Float> {
        let (stream, continuation) = AsyncStream.makeStream(of: Float.self, bufferingPolicy: .bufferingNewest(1))
        let reader = Task {
            let capture = AudioCapture()
            do {
                let events = try await capture.start(deviceID: deviceID)
                for try await event in events {
                    if Task.isCancelled { break }
                    if case .level(let level) = event { continuation.yield(level) }
                }
            } catch {}
            await capture.stop()
            continuation.finish()
        }
        task.withLock { $0?.cancel(); $0 = reader }
        continuation.onTermination = { _ in reader.cancel() }
        return stream
    }

    func stop() {
        task.withLock { $0?.cancel(); $0 = nil }
    }
}

// MARK: - Keychain, search, MediaSpace

nonisolated struct KeychainKeyStore: APIKeyStoring {
    let keychain: KeychainStore

    func apiKey(for provider: ProviderKind) throws -> String? { try keychain.load(for: provider) }

    func setAPIKey(_ key: String?, for provider: ProviderKind) throws {
        if let key, !key.isEmpty { try keychain.save(key, for: provider) } else { try keychain.delete(for: provider) }
    }
}

nonisolated extension LibrarySearchScope {
    /// The store's kinds of match this scope shows.
    var kinds: Set<SearchHit.Kind> {
        switch self {
        case .all: Set(SearchHit.Kind.allCases)
        case .titles: [.title]
        case .transcripts: [.transcript]
        case .takeaways: [.takeaway, .slideNotes]
        }
    }
}

nonisolated extension LibrarySearchHit {
    /// Maps a store hit into the UI's shape; the first of the query's words found in the snippet is highlighted.
    init(hit: SearchHit, query: String) {
        let field: Field
        switch hit.kind {
        case .title: field = .title
        case .takeaway, .slideNotes: field = .takeaway
        case .transcript: field = .transcript
        }
        let match = query.split(whereSeparator: \.isWhitespace)
            .compactMap { hit.snippet.range(of: String($0), options: [.caseInsensitive, .diacriticInsensitive]) }
            .min { $0.lowerBound < $1.lowerBound }
        self.init(sessionID: hit.sessionID, field: field, snippet: hit.snippet, matchRange: match, time: hit.time, slide: hit.slide)
    }
}

nonisolated struct LiveMediaSpaceBrowser: MediaSpaceBrowserProviding {
    @MainActor
    func makeBrowser(state: MediaSpaceBrowserState, onFound: @escaping (MediaSpaceSource) -> Void) -> AnyView {
        AnyView(MediaSpaceBrowserView(state: state, onFound: onFound))
    }
}
