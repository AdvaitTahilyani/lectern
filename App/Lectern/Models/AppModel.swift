import AppKit
import Foundation
import LecternCore
import SwiftUI

/// Weak hook so NotificationCenter closures can reach the app model without retain cycles.
@MainActor
enum AppModelActivation {
    weak static var shared: AppModel?
}

/// Top-level navigation targets inside the detail column.
nonisolated enum Route: Hashable, Sendable {
    case setup
    case session(UUID)
}

nonisolated enum SidebarItem: Hashable, Sendable {
    case all
    case course(UUID)
}

/// Root state: settings, the library, navigation, model status and the (single) live session.
@Observable
@MainActor
final class AppModel {
    let services: AppServices
    let isDemo: Bool

    // MARK: Settings & preferences
    private(set) var settings: AppSettings
    private(set) var preferences: UIPreferences

    // MARK: Library
    private(set) var courses: [Course] = []
    private(set) var sessions: [LectureSession] = []
    private(set) var isLibraryLoaded = false
    var libraryError: String?

    // MARK: Navigation
    var sidebarSelection: SidebarItem? = .all
    var columnVisibility: NavigationSplitViewVisibility = .all
    var path: [Route] = []
    var searchText = ""
    var searchScope: LibrarySearchScope = .all
    private(set) var searchResults: [LibrarySearchHit] = []
    private(set) var isSearching = false
    /// Set when opening a lecture at a specific timestamp (from search).
    var pendingSeek: (sessionID: UUID, time: TimeInterval)?

    // MARK: Sessions
    /// The one live session, if recording.
    private(set) var liveSession: LiveSessionModel?
    /// Sessions currently open in review (or live), keyed by id.
    private(set) var openSessions: [UUID: LiveSessionModel] = [:]
    let setup: SetupModel

    // MARK: Imports & course Ask
    private(set) var imports: [UUID: ImportJob] = [:]
    let importDraft = ImportDraft()
    var showImportSheet = false
    /// Course Ask models are created lazily from view bodies, so they must not be observed.
    @ObservationIgnored private var courseAsks: [UUID: CourseAskModel] = [:]
    @ObservationIgnored private var settingsModelStorage: SettingsModel?
    /// Settings window state, created on first use (lookup only; safe from a view body).
    var settingsModel: SettingsModel {
        if let existing = settingsModelStorage { return existing }
        let model = SettingsModel(app: self)
        settingsModelStorage = model
        return model
    }
    var showCourseAsk = false
    /// Selected Settings tab (raw name), so commands and deep links can open a specific pane.
    var settingsTab = "general"
    /// Slide to reveal once a session opened from a course citation has loaded.
    var pendingSlide: (sessionID: UUID, page: Int)?

    // MARK: Models
    private(set) var modelStates: [String: OnDeviceModelState] = [:]
    var modelStatus: ModelStatus { computeModelStatus() }

    // MARK: Focus panel
    let focusPanel = FocusPanelController()

    private var searchTask: Task<Void, Never>?
    private var modelTask: Task<Void, Never>?
    private var restoredVisibility: NavigationSplitViewVisibility = .all

    private static let settingsKey = "LecternSettings"
    private static let preferencesKey = "LecternPreferences"

    init(services: AppServices, isDemo: Bool) {
        self.services = services
        self.isDemo = isDemo
        var loadedSettings = Self.load(AppSettings.self, key: Self.settingsKey) ?? AppSettings()
        let loadedPreferences = Self.load(UIPreferences.self, key: Self.preferencesKey) ?? UIPreferences()
        if isDemo {
            // Demo sessions are ephemeral; onboarding is opt-in via Help › Welcome to Lectern.
            loadedSettings.hasCompletedOnboarding = true
        }
        settings = loadedSettings
        preferences = loadedPreferences
        setup = SetupModel(services: services)
        columnVisibility = loadedPreferences.sidebarVisible ? .all : .detailOnly
        observeModels()
        observeActivation()
    }

    // MARK: - App activation (for "While you were away")

    private var activationObservers: [Any] = []

    private func observeActivation() {
        let center = NotificationCenter.default
        activationObservers = [
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { AppModelActivation.shared?.liveSession?.appDidResignActive() }
            },
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { AppModelActivation.shared?.liveSession?.appDidBecomeActive() }
            },
            center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    // Only the main document window matters; panels (Focus) never count as "away".
                    guard let window = NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible && !($0 is NSPanel) }) else { return }
                    if window.occlusionState.contains(.visible) { AppModelActivation.shared?.liveSession?.appDidBecomeActive() } else { AppModelActivation.shared?.liveSession?.appDidResignActive() }
                }
            },
        ]
        AppModelActivation.shared = self
    }

    // MARK: - Loading

    func loadLibrary() async {
        do {
            async let c = services.store.loadCourses()
            async let s = services.store.loadSessions()
            courses = try await c
            sessions = try await s
            isLibraryLoaded = true
            libraryError = nil
            if setup.courseID == nil { setup.courseID = defaultCourseID() }
        } catch {
            libraryError = error.localizedDescription
            isLibraryLoaded = true
        }
    }

    private func observeModels() {
        modelTask = Task { [weak self] in
            guard let manager = self?.services.onDeviceModels else { return }
            for await states in manager.states() {
                guard let self else { return }
                self.modelStates = states
            }
        }
    }

    // MARK: - Settings

    func updateSettings(_ change: (inout AppSettings) -> Void) {
        change(&settings)
        Self.save(settings, key: Self.settingsKey)
        liveSession?.applySettings(settings)
    }

    func updatePreferences(_ change: (inout UIPreferences) -> Void) {
        change(&preferences)
        Self.save(preferences, key: Self.preferencesKey)
        for session in openSessions.values { session.applyPreferences(preferences) }
    }

    func completeOnboarding() {
        updateSettings { $0.hasCompletedOnboarding = true }
    }

    private static func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private static func save<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: key) }
    }

    // MARK: - Courses

    func course(id: UUID?) -> Course? {
        guard let id else { return nil }
        return courses.first { $0.id == id }
    }

    func colorIndex(for course: Course) -> Int {
        courses.firstIndex(of: course) ?? 0
    }

    func courseColor(_ course: Course?) -> Color {
        guard let course else { return .secondary }
        return DS.Colors.course(course.colorHex, fallbackIndex: colorIndex(for: course))
    }

    @discardableResult
    func addCourse(code: String, name: String, colorHex: String?) -> Course {
        let course = Course(code: code, name: name, colorHex: colorHex)
        courses.append(course)
        persistCourses()
        return course
    }

    func renameCourse(_ id: UUID, code: String, name: String) {
        guard let i = courses.firstIndex(where: { $0.id == id }) else { return }
        courses[i].code = code
        courses[i].name = name
        persistCourses()
    }

    func recolorCourse(_ id: UUID, hex: String) {
        guard let i = courses.firstIndex(where: { $0.id == id }) else { return }
        courses[i].colorHex = hex
        persistCourses()
    }

    func deleteCourse(_ id: UUID) {
        let victims = sessions.filter { $0.courseID == id }
        for s in victims { deleteSession(s.id) }
        courses.removeAll { $0.id == id }
        if sidebarSelection == .course(id) { sidebarSelection = .all }
        persistCourses()
    }

    private func persistCourses() {
        let snapshot = courses
        Task { [services] in
            do { try await services.store.saveCourses(snapshot) } catch { self.libraryError = error.localizedDescription }
        }
    }

    func sessions(in courseID: UUID) -> [LectureSession] {
        sessions.filter { $0.courseID == courseID }
    }

    func lectureCount(in courseID: UUID) -> Int { sessions(in: courseID).count }

    private func defaultCourseID() -> UUID? {
        if case .course(let id) = sidebarSelection { return id }
        return sessions.first?.courseID ?? courses.first?.id
    }

    // MARK: - Sessions

    func deleteSession(_ id: UUID) {
        sessions.removeAll { $0.id == id }
        openSessions[id] = nil
        Task { [services] in
            do { try await services.store.delete(sessionID: id) } catch { self.libraryError = error.localizedDescription }
        }
    }

    func moveSession(_ id: UUID, to courseID: UUID) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[i].courseID = courseID
        let snapshot = sessions[i]
        openSessions[id]?.setCourse(course(id: courseID))
        Task { [services] in try? await services.store.save(snapshot) }
    }

    /// Reflects a session model's changes into the library list (called by autosave).
    func libraryDidUpdate(_ session: LectureSession) {
        if let i = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[i] = session
        } else {
            sessions.insert(session, at: 0)
        }
        if session.status == .finished, let courseID = session.courseID { courseAsks[courseID]?.prepare(sessions: sessions) }
    }

    // MARK: - Navigation

    func showSetup() {
        if setup.courseID == nil { setup.courseID = defaultCourseID() }
        if case .course(let id) = sidebarSelection, setup.deck == nil, setup.title.isEmpty { setup.courseID = id }
        setup.beginMonitoring()
        if path.last != .setup { path.append(.setup) }
    }

    func showSetup(droppedPDF url: URL) {
        showSetup()
        setup.loadDeck(url: url)
    }

    /// Opens a finished lecture in review, or resumes the live one.
    func openSession(_ id: UUID, at time: TimeInterval? = nil) {
        if let time { pendingSeek = (id, time) }
        if openSessions[id] == nil, let stored = sessions.first(where: { $0.id == id }) {
            let model = LiveSessionModel(session: stored, course: course(id: stored.courseID), mode: .review, services: services, settings: settings, preferences: preferences)
            model.onSessionChanged = { [weak self] s in self?.libraryDidUpdate(s) }
            openSessions[id] = model
        }
        path = [.session(id)]
    }

    func session(for id: UUID) -> LiveSessionModel? { openSessions[id] }

    /// Starts recording with the current Setup draft; the detail column swaps to the live view.
    func startLecture() {
        guard liveSession == nil else { return }
        let draft = setup.makeSession()
        let model = LiveSessionModel(session: draft, course: course(id: draft.courseID), mode: .live, services: services, settings: settings, preferences: preferences)
        model.onSessionChanged = { [weak self] s in self?.libraryDidUpdate(s) }
        model.onFinished = { [weak self] in self?.sessionDidFinish() }
        model.slideImages = setup.slideImages
        let deckURL = setup.deckURL
        openSessions[draft.id] = model
        liveSession = model
        libraryDidUpdate(draft)
        restoredVisibility = columnVisibility
        withAnimation(DS.Motion.settle) {
            columnVisibility = .detailOnly
            path = [.session(draft.id)]
        }
        setup.reset()
        model.start(deckURL: deckURL)
    }

    private func sessionDidFinish() {
        liveSession = nil
        focusPanel.hide()
        withAnimation(DS.Motion.settle) { columnVisibility = restoredVisibility }
    }

    func toggleFocusPanel() {
        guard let live = liveSession else { return }
        focusPanel.toggle(session: live, app: self)
    }

    // MARK: - Search

    func searchTextChanged() {
        searchTask?.cancel()
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard query.count >= 2 else {
            searchResults = []
            isSearching = false
            return
        }
        isSearching = true
        let scope = searchScope
        searchTask = Task { [services] in
            do {
                let hits = try await services.search(query, scope)
                guard !Task.isCancelled else { return }
                self.searchResults = hits
            } catch {
                guard !Task.isCancelled else { return }
                self.searchResults = []
            }
            self.isSearching = false
        }
    }

    // MARK: - Interrupted sessions (crash recovery)

    /// Sessions left `.live`/`.paused`/`.importing` by a previous run and not active now.
    var interruptedSessions: [LectureSession] {
        sessions.filter { s in
            (s.status == .live || s.status == .paused || s.status == .importing) && liveSession?.id != s.id && imports[s.id] == nil
        }
    }

    func isInterrupted(_ id: UUID) -> Bool { interruptedSessions.contains { $0.id == id } }

    /// Picks recording back up on a session that was live when the app last quit.
    func resumeInterrupted(_ id: UUID) {
        guard liveSession == nil, let stored = sessions.first(where: { $0.id == id }) else { return }
        let model = LiveSessionModel(session: stored, course: course(id: stored.courseID), mode: .live, services: services, settings: settings, preferences: preferences)
        model.onSessionChanged = { [weak self] s in self?.libraryDidUpdate(s) }
        model.onFinished = { [weak self] in self?.sessionDidFinish() }
        openSessions[id] = model
        liveSession = model
        restoredVisibility = columnVisibility
        withAnimation(DS.Motion.settle) {
            columnVisibility = .detailOnly
            path = [.session(id)]
        }
        model.start(deckURL: nil)
    }

    /// Marks an interrupted session finished (writing the summary) and opens it in review.
    func finishInterrupted(_ id: UUID) {
        guard let stored = sessions.first(where: { $0.id == id }) else { return }
        if stored.status == .importing {
            var s = stored
            s.status = .finished
            s.endedAt = .now
            libraryDidUpdate(s)
            Task { [services] in try? await services.store.save(s) }
            return
        }
        let model = LiveSessionModel(session: stored, course: course(id: stored.courseID), mode: .live, services: services, settings: settings, preferences: preferences)
        model.onSessionChanged = { [weak self] s in self?.libraryDidUpdate(s) }
        openSessions[id] = model
        model.finishWithoutRecording()
        path = [.session(id)]
    }

    func discardInterrupted(_ id: UUID) { deleteSession(id) }

    // MARK: - Import a recording

    func showImport() {
        if importDraft.courseID == nil { importDraft.courseID = defaultCourseID() }
        showImportSheet = true
    }

    /// The MediaSpace browser is a sibling sheet of the import sheet (never nested inside it):
    /// the import sheet closes, the browser opens, and on a result the import sheet returns.
    func showMediaSpaceBrowser() {
        showImportSheet = false
        importDraft.showMediaSpace = true
    }

    func mediaSpaceBrowserDidFinish(_ source: MediaSpaceSource?) {
        importDraft.showMediaSpace = false
        if let source { importDraft.setMediaSpace(source) }
        showImportSheet = true
    }

    func showImport(droppedMedia url: URL) {
        showImport()
        importDraft.setFile(url)
    }

    /// Starts the import described by the draft; the session appears in the library immediately.
    func startImport() {
        guard let source = importDraft.recordingSource() else { return }
        let title = importDraft.title.trimmingCharacters(in: .whitespaces)
        var session = LectureSession(courseID: importDraft.courseID, title: title.isEmpty ? importDraft.suggestedTitle : title, status: .importing)
        switch source {
        case .file(let url): session.source = .audioFile(originalFileName: url.lastPathComponent)
        case .mediaSpace(let ms, let captions): session.source = .mediaSpace(entryID: ms.entryID, pageURL: ms.pageURL, usedCaptions: captions)
        }
        let deckURL = importDraft.deckURL
        let job = ImportJob(session: session)
        imports[session.id] = job
        libraryDidUpdate(session)
        showImportSheet = false
        importDraft.reset()
        Task { [services] in
            var draft = session
            if let deckURL {
                if let deck = try? await services.slideIngestor.ingest(pdfAt: deckURL, progress: { _ in }) {
                    var stored = deck
                    stored.fileName = (try? await services.store.importSlides(from: deckURL, into: session.id)) ?? deck.fileName
                    draft.deck = stored
                }
            }
            try? await services.store.save(draft)
            job.start(source: source, services: services) { [weak self] result in
                guard let self else { return }
                self.libraryDidUpdate(result)
                Task { try? await services.store.save(result) }
                self.imports[result.id] = nil
                self.openSession(result.id)
            } onFailed: { [weak self] _ in
                self?.sessions.removeAll { $0.id == session.id }
            }
        }
    }

    func cancelImport(_ id: UUID) {
        imports[id]?.cancel()
        imports[id] = nil
        deleteSession(id)
    }

    func dismissFailedImport(_ id: UUID) {
        imports[id] = nil
        sessions.removeAll { $0.id == id }
    }

    // MARK: - Course-wide Ask

    /// Lookup-or-create only (safe to call from a view body); views call `prepare` from `.task`.
    func courseAsk(for courseID: UUID) -> CourseAskModel {
        if let existing = courseAsks[courseID] { return existing }
        let model = CourseAskModel(courseID: courseID, services: services)
        courseAsks[courseID] = model
        return model
    }

    /// The course to ask about: the sidebar's course, or the open session's course.
    var contextCourseID: UUID? {
        if case .course(let id) = sidebarSelection { return id }
        if case .session(let sid) = path.last, let s = openSessions[sid] { return s.course?.id }
        return courses.first?.id
    }

    func toggleCourseAsk() {
        guard contextCourseID != nil else { return }
        if case .session(let id) = path.last, let session = openSessions[id] {
            session.focusAsk()   // the session Ask tab has the "Whole course" scope
            return
        }
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { showCourseAsk.toggle() }
    }

    /// Opens the cited lecture at a slide or time.
    func open(courseCitation c: CourseCitation) {
        switch c.citation {
        case .time(let t): openSession(c.sessionID, at: t)
        case .slide(let n):
            pendingSlide = (c.sessionID, n)
            openSession(c.sessionID)
            openSessions[c.sessionID]?.showSlide(n)
        }
    }

    // MARK: - Model status

    private func computeModelStatus() -> ModelStatus {
        let summaries = settings.provider(for: .summaries)
        let speechID = settings.transcriptionEngine.rawValue
        if settings.transcriptionEngine == .parakeet {
            switch modelStates[speechID] {
            case .downloading(let p, _): return .downloading(progress: p)
            case .paused(let p): return .downloading(progress: p)
            case .failed(let reason): return .unavailable(reason: reason)
            case .notInstalled: return .unavailable(reason: "Parakeet not downloaded")
            default: break
            }
        }
        switch summaries.kind {
        case .onDevice:
            switch modelStates[summaries.model] {
            case .installed, .none: return .ready(engine: settings.transcriptionEngine == .parakeet ? "Parakeet" : "Apple Speech")
            case .downloading(let p, _), .paused(let p): return .downloading(progress: p)
            case .failed(let reason): return .unavailable(reason: reason)
            case .notInstalled: return .unavailable(reason: "\(shortModelName(summaries.model)) not downloaded")
            }
        case .localServer: return .ready(engine: "Local server")
        case .openAI, .anthropic: return .cloud(provider: summaries.kind.displayName)
        }
    }

    func shortModelName(_ id: String) -> String {
        services.onDeviceModels.catalog.first { $0.id == id }?.displayName ?? id.split(separator: "/").last.map(String.init) ?? id
    }

    func modelState(_ id: String) -> OnDeviceModelState { modelStates[id] ?? .notInstalled }
}
