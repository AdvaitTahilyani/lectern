import Foundation
import LecternCore

/// UI state for the Settings window: provider test results, API key drafts, level meter.
@Observable
@MainActor
final class SettingsModel {
    enum TestState: Hashable {
        case idle
        case testing
        case ok(latencyMs: Int, detail: String?)
        case failed(String)
    }

    private let app: AppModel
    private(set) var testStates: [ProviderKind: TestState] = [:]
    private(set) var keyDrafts: [ProviderKind: String] = [:]
    private(set) var keyStored: [ProviderKind: Bool] = [:]
    var localServerURL: String
    var localServerModel: String
    private(set) var inputDevices: [AudioInputDevice] = []
    private(set) var level: Float = 0
    private(set) var peak: Float = 0
    var newVocabularyTerm = ""
    var selectedVocabulary: String?

    private var levelMonitor: (any AudioLevelMonitoring)?
    private var levelTask: Task<Void, Never>?

    /// Model choices per provider shown in the pickers.
    static let cloudModels: [ProviderKind: [String]] = [
        .openAI: ["gpt-4.1-mini", "gpt-4.1", "gpt-5-mini"],
        .anthropic: ["claude-haiku-4-5", "claude-sonnet-4-5"],
    ]

    init(app: AppModel) {
        self.app = app
        let local = app.settings.providers.values.first { $0.kind == .localServer }
        localServerURL = local?.baseURL?.absoluteString ?? "http://localhost:11434/v1"
        localServerModel = local?.model ?? "gemma4:12b"
        for kind in [ProviderKind.openAI, .anthropic] {
            keyStored[kind] = ((try? app.services.keychain.apiKey(for: kind)) ?? nil) != nil
        }
        inputDevices = app.services.inputDevices()
    }

    var settings: AppSettings { app.settings }
    var preferences: UIPreferences { app.preferences }
    var catalog: [OnDeviceModelInfo] { app.services.onDeviceModels.catalog }
    var freeSpace: Int64 { app.services.onDeviceModels.freeSpaceBytes() }

    func modelState(_ id: String) -> OnDeviceModelState { app.modelState(id) }

    // MARK: Roles

    func setProvider(_ kind: ProviderKind, for role: LLMRole) {
        app.updateSettings { s in
            var config = s.provider(for: role)
            if config.kind != kind {
                config = ProviderConfig(kind: kind, model: defaultModel(for: kind), baseURL: kind == .localServer ? URL(string: localServerURL) : nil)
            }
            s.providers[role] = config
        }
    }

    func setModel(_ model: String, for role: LLMRole) {
        app.updateSettings { s in
            var config = s.provider(for: role)
            config.model = model
            s.providers[role] = config
        }
    }

    func defaultModel(for kind: ProviderKind) -> String {
        switch kind {
        case .onDevice: return catalog.first { $0.purpose == .language && modelState($0.id).isInstalled }?.id ?? AppSettings.defaultOnDeviceModel
        case .localServer: return localServerModel
        case .openAI: return Self.cloudModels[.openAI]?.first ?? "gpt-4.1-mini"
        case .anthropic: return Self.cloudModels[.anthropic]?.first ?? "claude-haiku-4-5"
        }
    }

    func models(for kind: ProviderKind) -> [String] {
        switch kind {
        case .onDevice: return catalog.filter { $0.purpose == .language }.map(\.id)
        case .localServer: return [localServerModel]
        case .openAI, .anthropic: return Self.cloudModels[kind] ?? []
        }
    }

    /// True when a role points at an on-device model that isn't installed.
    func roleNeedsDownload(_ role: LLMRole) -> Bool {
        let c = settings.provider(for: role)
        return c.kind == .onDevice && !modelState(c.model).isInstalled
    }

    func commitLocalServer() {
        app.updateSettings { s in
            for role in LLMRole.allCases where s.provider(for: role).kind == .localServer {
                s.providers[role] = ProviderConfig(kind: .localServer, model: localServerModel, baseURL: URL(string: localServerURL))
            }
        }
    }

    // MARK: Keys

    func keyDraft(_ kind: ProviderKind) -> String { keyDrafts[kind] ?? "" }
    func setKeyDraft(_ value: String, for kind: ProviderKind) { keyDrafts[kind] = value }

    func commitKey(_ kind: ProviderKind) {
        let value = keyDraft(kind).trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try app.services.keychain.setAPIKey(value.isEmpty ? nil : value, for: kind)
            keyStored[kind] = !value.isEmpty
            testStates[kind] = .idle
        } catch {
            testStates[kind] = .failed(error.localizedDescription)
        }
    }

    func isKeyStored(_ kind: ProviderKind) -> Bool { keyStored[kind] ?? false }

    // MARK: Test connection

    func test(_ kind: ProviderKind) {
        testStates[kind] = .testing
        if kind == .localServer { commitLocalServer() }
        if kind.isCloud { commitKey(kind); testStates[kind] = .testing }
        let config = ProviderConfig(kind: kind, model: kind == .localServer ? localServerModel : defaultModel(for: kind), baseURL: kind == .localServer ? URL(string: localServerURL) : nil)
        let key = kind.isCloud ? ((try? app.services.keychain.apiKey(for: kind)) ?? nil) : nil
        Task { [app] in
            do {
                let health = try await withThrowingTaskGroup(of: ProviderHealth.self) { group in
                    group.addTask { try await app.services.providerHealthCheck(config, key) }
                    group.addTask { try await Task.sleep(for: .seconds(8)); throw LLMError.network("Timed out after 8 s") }
                    let first = try await group.next()!
                    group.cancelAll()
                    return first
                }
                testStates[kind] = .ok(latencyMs: health.latencyMilliseconds, detail: health.detail)
            } catch {
                let message: String
                if let e = error as? LLMError, case .http(let s, let m) = e { message = "\(s) \(m)" } else { message = error.localizedDescription.split(separator: "\n").first.map(String.init) ?? "Failed" }
                testStates[kind] = .failed(message)
            }
        }
    }

    func testState(_ kind: ProviderKind) -> TestState { testStates[kind] ?? .idle }

    // MARK: Downloads

    func download(_ id: String) { app.services.onDeviceModels.download(id: id) }
    func pause(_ id: String) { app.services.onDeviceModels.pause(id: id) }
    func resume(_ id: String) { app.services.onDeviceModels.resume(id: id) }
    func remove(_ id: String) { app.services.onDeviceModels.remove(id: id) }

    // MARK: Transcription

    func setEngine(_ engine: TranscriptionEngineID) { app.updateSettings { $0.transcriptionEngine = engine } }
    func setInputDevice(_ id: String?) {
        app.updateSettings { $0.inputDeviceID = id }
        stopLevel()
        startLevel()
    }

    func startLevel() {
        guard levelTask == nil else { return }
        let monitor = app.services.makeLevelMonitor()
        levelMonitor = monitor
        let stream = monitor.start(deviceID: settings.inputDeviceID)
        levelTask = Task { [weak self] in
            for await v in stream {
                guard let self else { return }
                self.level = v
                self.peak = max(v, self.peak * 0.97)
            }
        }
    }

    func stopLevel() {
        levelTask?.cancel()
        levelTask = nil
        levelMonitor?.stop()
        levelMonitor = nil
        level = 0
    }

    func addVocabulary() {
        let term = newVocabularyTerm.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { return }
        app.updateSettings { if !$0.vocabulary.contains(term) { $0.vocabulary.append(term) } }
        newVocabularyTerm = ""
    }

    func removeSelectedVocabulary() {
        guard let term = selectedVocabulary else { return }
        app.updateSettings { $0.vocabulary.removeAll { $0 == term } }
        selectedVocabulary = nil
    }

    func removeVocabulary(at offsets: IndexSet) {
        app.updateSettings { $0.vocabulary.remove(atOffsets: offsets) }
    }

    /// Pulls capitalized / rare terms from indexed decks in the library.
    func importVocabularyFromDecks() {
        var counts: [String: Int] = [:]
        for s in app.sessions {
            for page in s.deck?.pages ?? [] {
                for token in page.text.split(whereSeparator: { !$0.isLetter && $0 != "-" && $0 != "'" }) {
                    let t = String(token)
                    guard t.count >= 5, t.first?.isUppercase == true, t != t.uppercased() else { continue }
                    counts[t, default: 0] += 1
                }
            }
        }
        let terms = counts.filter { $0.value >= 2 }.keys.sorted().prefix(40)
        app.updateSettings { s in for t in terms where !s.vocabulary.contains(t) { s.vocabulary.append(t) } }
    }

    // MARK: Quiz & general

    func updateQuiz(_ change: (inout QuizSettings) -> Void) { app.updateSettings { change(&$0.quiz) } }
    func updatePreferences(_ change: (inout UIPreferences) -> Void) { app.updatePreferences(change) }

    var storageSummary: String {
        let lectures = app.sessions.count
        let models = catalog.filter { modelState($0.id).isInstalled }
        let bytes = models.reduce(Int64(0)) { $0 + $1.sizeBytes } + Int64(lectures) * 12_000_000
        return "\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) · \(lectures) lectures · \(models.count) models"
    }

    var storageLocation: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("Lectern")
    }
}
