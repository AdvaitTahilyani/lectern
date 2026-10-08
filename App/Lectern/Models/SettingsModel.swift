import Foundation
import LecternCore
import LecternLLM

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
    /// The running "Test connection" per provider, and a counter that tells a result whether it is
    /// still the latest request (an older test finishing late must not overwrite a newer one).
    private var testTasks: [ProviderKind: Task<Void, Never>] = [:]
    private var testGeneration: [ProviderKind: Int] = [:]
    var localServerURL: String
    var localServerModel: String
    private(set) var inputDevices: [AudioInputDevice] = []
    private(set) var level: Float = 0
    private(set) var peak: Float = 0
    var newVocabularyTerm = ""
    var selectedVocabulary: String?

    private var levelMonitor: (any AudioLevelMonitoring)?
    private var levelTask: Task<Void, Never>?

    /// This month's cloud spending (Settings › Models).
    private(set) var usage: UsageMonthSummary = .empty
    private var usageTask: Task<Void, Never>?
    /// The last cap the user set, restored when the cap is switched back on.
    private var lastCap: Double = 10

    init(app: AppModel) {
        self.app = app
        let local = app.settings.providers.values.first { $0.kind == .localServer }
        localServerURL = local?.baseURL?.absoluteString ?? "http://localhost:11434/v1"
        localServerModel = local?.model ?? "gemma4:12b"
        for kind in [ProviderKind.openAI, .anthropic] {
            let stored = ((try? app.services.keychain.apiKey(for: kind)) ?? nil) != nil
            keyStored[kind] = stored
            app.noteKeyStored(stored, for: kind)
        }
        inputDevices = app.services.inputDevices()
    }

    /// The microphone the Input picker shows: the chosen one, else the system default, which is what a
    /// lecture records from when none is chosen.
    var selectedInputDeviceID: String {
        settings.inputDeviceID ?? inputDevices.first { $0.isDefault }?.id ?? inputDevices.first?.id ?? ""
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
                config = ProviderConfig(kind: kind, model: defaultModel(for: kind), baseURL: kind == .localServer ? Self.serverURL(from: localServerURL) ?? Self.defaultServerURL : nil)
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
        case .openAI, .anthropic: return ProviderCatalog.defaultModel(for: kind)
        }
    }

    func models(for kind: ProviderKind) -> [String] {
        switch kind {
        case .onDevice: return catalog.filter { $0.purpose == .language }.map(\.id)
        case .localServer: return [localServerModel]
        case .openAI, .anthropic: return ProviderCatalog.suggestedModels(for: kind).map(\.id)
        }
    }

    /// True when a role points at an on-device model that isn't installed.
    func roleNeedsDownload(_ role: LLMRole) -> Bool {
        let c = settings.provider(for: role)
        return c.kind == .onDevice && !modelState(c.model).isInstalled
    }

    /// Where a local server is expected when none is configured.
    nonisolated static let defaultServerURL = URL(string: "http://localhost:11434/v1")!

    /// `text` as an http(s) URL with a host, or nil. `URL(string: "localhost")` and similar partial
    /// drafts parse fine but aren't addresses a request can go to.
    nonisolated static func serverURL(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
            let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
            let host = components.host, !host.isEmpty
        else { return nil }
        return components.url
    }

    /// Saves the local-server URL and model into every role that uses a local server. A draft that
    /// isn't a usable address or model is rejected (and shown as an error), not saved.
    func commitLocalServer() {
        switch localServerDraft() {
        case .failure(let problem):
            testStates[.localServer] = .failed(problem.message)
        case .success(let draft):
            invalidateTest(.localServer)
            testStates[.localServer] = .idle
            app.updateSettings { s in
                for role in LLMRole.allCases where s.provider(for: role).kind == .localServer {
                    s.providers[role] = ProviderConfig(kind: .localServer, model: draft.model, baseURL: draft.url)
                }
            }
        }
    }

    private struct DraftProblem: Error { var message: String }

    private func localServerDraft() -> Result<(url: URL, model: String), DraftProblem> {
        guard let url = Self.serverURL(from: localServerURL) else {
            return .failure(DraftProblem(message: "Enter the server address, like http://localhost:11434/v1"))
        }
        let model = localServerModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { return .failure(DraftProblem(message: "Enter a model name")) }
        return .success((url, model))
    }

    // MARK: Keys

    func keyDraft(_ kind: ProviderKind) -> String { keyDrafts[kind] ?? "" }
    func setKeyDraft(_ value: String, for kind: ProviderKind) { keyDrafts[kind] = value }

    /// True when the user has typed a replacement key that isn't saved yet.
    func hasKeyDraft(_ kind: ProviderKind) -> Bool {
        !keyDraft(kind).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Saves the typed replacement key. An empty draft means "unchanged": it never deletes the
    /// stored key (use ``removeKey(_:)`` for that).
    func commitKey(_ kind: ProviderKind) {
        let value = keyDraft(kind).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        store(key: value, for: kind)
    }

    /// Deletes the stored key (the explicit "Remove key" action).
    func removeKey(_ kind: ProviderKind) {
        store(key: nil, for: kind)
    }

    private func store(key: String?, for kind: ProviderKind) {
        invalidateTest(kind)
        do {
            try app.services.keychain.setAPIKey(key, for: kind)
            keyDrafts[kind] = nil
            keyStored[kind] = key != nil
            app.noteKeyStored(key != nil, for: kind)
            testStates[kind] = .idle
        } catch {
            testStates[kind] = .failed(error.localizedDescription)
        }
    }

    func isKeyStored(_ kind: ProviderKind) -> Bool { keyStored[kind] ?? false }

    // MARK: Test connection

    /// What one "Test connection" press will check: nothing here is saved.
    private struct TestPlan {
        var configs: [ProviderConfig]
        var key: String?
    }

    /// Checks `kind` with what is on screen (a typed key, the server address in the field) without
    /// saving any of it. Cloud providers are tested with every model a role selected.
    func test(_ kind: ProviderKind) {
        invalidateTest(kind)
        let plan: TestPlan
        switch testPlan(for: kind) {
        case .failure(let problem):
            testStates[kind] = .failed(problem.message)
            return
        case .success(let value):
            plan = value
        }
        let generation = testGeneration[kind] ?? 0
        testStates[kind] = .testing
        let check = app.services.providerHealthCheck
        testTasks[kind] = Task { [weak self] in
            let result: TestState
            var testing: String?
            do {
                var slowest = 0
                var details: [String] = []
                for config in plan.configs {
                    testing = config.model
                    let health = try await Self.timeBoxed { try await check(config, plan.key) }
                    slowest = max(slowest, health.latencyMilliseconds)
                    if let detail = health.detail { details.append(detail) }
                }
                let detail = plan.configs.count > 1 ? "\(plan.configs.count) models" : details.first
                result = .ok(latencyMs: slowest, detail: detail)
            } catch is CancellationError {
                return
            } catch {
                result = .failed(Self.message(for: error, model: plan.configs.count > 1 ? testing : nil))
            }
            guard let self, self.testGeneration[kind] == generation else { return }
            self.testStates[kind] = result
            self.testTasks[kind] = nil
        }
    }

    /// Ends any test in flight for `kind`, so its result is dropped when it arrives.
    private func invalidateTest(_ kind: ProviderKind) {
        testGeneration[kind, default: 0] += 1
        testTasks.removeValue(forKey: kind)?.cancel()
    }

    private func testPlan(for kind: ProviderKind) -> Result<TestPlan, DraftProblem> {
        switch kind {
        case .localServer:
            return localServerDraft().map { TestPlan(configs: [ProviderConfig(kind: .localServer, model: $0.model, baseURL: $0.url)], key: nil) }
        case .onDevice:
            return .success(TestPlan(configs: [ProviderConfig(kind: kind, model: defaultModel(for: kind))], key: nil))
        case .openAI, .anthropic:
            let typed = keyDraft(kind).trimmingCharacters(in: .whitespacesAndNewlines)
            let key: String?
            if typed.isEmpty {
                do { key = try app.services.keychain.apiKey(for: kind) } catch { return .failure(DraftProblem(message: error.localizedDescription)) }
            } else {
                key = typed
            }
            guard let key, !key.isEmpty else { return .failure(DraftProblem(message: "No API key. Paste one first.")) }
            var models: [String] = []
            for role in LLMRole.allCases {
                let config = settings.provider(for: role)
                if config.kind == kind, !models.contains(config.model) { models.append(config.model) }
            }
            if models.isEmpty { models = [defaultModel(for: kind)] }
            return .success(TestPlan(configs: models.map { ProviderConfig(kind: kind, model: $0) }, key: key))
        }
    }

    /// Runs `operation`, failing after 8 s.
    private nonisolated static func timeBoxed(_ operation: @escaping @Sendable () async throws -> ProviderHealth) async throws -> ProviderHealth {
        try await withThrowingTaskGroup(of: ProviderHealth.self) { group in
            group.addTask { try await operation() }
            group.addTask { try await Task.sleep(for: .seconds(8)); throw LLMError.network("Timed out after 8 s") }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
    }

    /// One line for the status label; with several models it names the one that failed.
    private nonisolated static func message(for error: Error, model: String?) -> String {
        var text: String
        if let e = error as? LLMError, case .http(let s, let m) = e { text = "\(s) \(m)" } else { text = error.localizedDescription.split(separator: "\n").first.map(String.init) ?? "Failed" }
        if let model { text = "\(model): \(text)" }
        return text
    }

    func testState(_ kind: ProviderKind) -> TestState { testStates[kind] ?? .idle }

    // MARK: API cost

    /// False in the demo, which has no cloud calls to meter.
    var isMeteringUsage: Bool { app.services.usage != nil }
    var monthlyCap: Double? { settings.monthlyCloudCapUSD }

    func setMonthlyCap(_ cap: Double?) {
        let value = cap.map { max(0.01, ($0 * 100).rounded() / 100) }
        if let value { lastCap = value }
        app.updateSettings { $0.monthlyCloudCapUSD = value }
    }

    func setCapEnabled(_ on: Bool) {
        if !on, let cap = monthlyCap { lastCap = cap }
        setMonthlyCap(on ? (monthlyCap ?? lastCap) : nil)
    }

    var isCapReached: Bool {
        guard let cap = monthlyCap, cap > 0 else { return false }
        return usage.totalUSD >= cap
    }

    /// Whether an on-device language model is downloaded for cloud roles to fall back to.
    var hasOnDeviceFallback: Bool { catalog.contains { $0.purpose == .language && modelState($0.id).isInstalled } }

    /// Keeps `usage` current while the Models tab is visible.
    func startUsageUpdates() {
        guard usageTask == nil, let reporter = app.services.usage else { return }
        usageTask = Task { [weak self] in
            for await _ in await reporter.changes() {
                let month = await reporter.currentMonth()
                guard let self, !Task.isCancelled else { return }
                self.usage = month
            }
        }
    }

    func stopUsageUpdates() {
        usageTask?.cancel()
        usageTask = nil
    }

    // MARK: Downloads

    func download(_ id: String) { app.services.onDeviceModels.download(id: id) }
    func pause(_ id: String) { app.services.onDeviceModels.pause(id: id) }
    func resume(_ id: String) { app.services.onDeviceModels.resume(id: id) }
    func remove(_ id: String) { app.services.onDeviceModels.remove(id: id) }

    // MARK: Transcription

    func setEngine(_ engine: TranscriptionEngineID) { app.updateSettings { $0.transcriptionEngine = engine } }
    func setFixesJargon(_ on: Bool) { app.updateSettings { $0.fixesJargonFromSlides = on } }
    func setInputDevice(_ id: String?) {
        app.updateSettings { $0.inputDeviceID = id }
        stopLevel()
        startLevel()
    }

    /// A lecture is recording: it owns the microphone, so the meter shows its level instead of opening a second capture.
    var isMicrophoneInUse: Bool { app.liveSession != nil }
    var recordingLevel: Float { app.liveSession?.level ?? 0 }

    func startLevel() {
        guard levelTask == nil, !isMicrophoneInUse else { return }
        inputDevices = app.services.inputDevices()   // microphones plugged in since Settings was first opened
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
        peak = 0
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

    /// Size of the lecture library on disk; nil until `refreshStorage()` has measured it.
    private(set) var libraryBytes: Int64?

    /// Measures the library folder off the main actor (a library with slide decks and kept audio
    /// runs to gigabytes).
    func refreshStorage() async {
        let location = storageLocation
        libraryBytes = await Task.detached(priority: .utility) { Self.size(of: location) }.value
    }

    var storageSummary: String {
        let lectures = app.sessions.count
        let models = catalog.filter { modelState($0.id).isInstalled }
        let library = libraryBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "Measuring…"
        var parts = ["\(library) · \(lectures) \(lectures == 1 ? "lecture" : "lectures")"]
        if !models.isEmpty {
            let modelBytes = models.reduce(Int64(0)) { $0 + $1.sizeBytes }
            parts.append("\(ByteCountFormatter.string(fromByteCount: modelBytes, countStyle: .file)) in \(models.count) \(models.count == 1 ? "model" : "models")")
        }
        return parts.joined(separator: " · ")
    }

    nonisolated private static func size(of folder: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in files {
            let values = try? url.resourceValues(forKeys: Set(keys))
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
        }
        return total
    }

    var storageLocation: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("Lectern")
    }
}
