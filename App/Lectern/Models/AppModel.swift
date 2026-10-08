import AppKit
import Foundation
import LecternCore
import LecternStore
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
    /// A lecture the Trash refused to take. Nothing was deleted; the Library asks whether to erase
    /// it for good. Set only by a failed Move to Trash, never by the user's first request.
    var permanentDeletionOffer: PermanentDeletionOffer?
    /// Damaged session files seen since launch (kept on disk untouched; shown as a notice). A file is repaired on its first load, so a later
    /// reload reports nothing: issues accumulate until the user dismisses the notice.
    var libraryIssues: [LibraryIssue] = []

    // MARK: Navigation
    /// One per open window (see `WindowNavigation`). Navigation commands act on `activeNavigation`.
    @ObservationIgnored private var windows: [WindowNavigation] = []
    @ObservationIgnored private weak var lastActiveWindow: WindowNavigation?
    /// Stands in before the first window registers (and in tests).
    @ObservationIgnored private let fallbackNavigation: WindowNavigation
    /// The window that is hosting the live recording, so the sidebar returns there when it ends.
    @ObservationIgnored private(set) weak var liveWindow: WindowNavigation?
    /// Opens a main window (the scene's `openWindow`), for the Focus panel, which has no SwiftUI
    /// environment of its own; set by `RootView`.
    @ObservationIgnored var openMainWindow: (() -> Void)?
    /// The window that opened the import sheet; only it presents the sheet.
    @ObservationIgnored private(set) weak var importPresenter: WindowNavigation?

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
    /// Selected Settings tab (raw name), so commands and deep links can open a specific pane.
    var settingsTab = "general"

    // MARK: Models
    private(set) var modelStates: [String: OnDeviceModelState] = [:]
    /// False until the download manager has reported its first snapshot.
    private(set) var modelStatesKnown = false
    /// Which cloud providers have an API key, as far as Settings has looked (it reads the Keychain).
    private(set) var cloudKeyStored: [ProviderKind: Bool] = [:]
    var modelStatus: ModelStatus { computeModelStatus() }

    func noteKeyStored(_ stored: Bool, for kind: ProviderKind) { cloudKeyStored[kind] = stored }

    // MARK: Focus panel
    let focusPanel = FocusPanelController()

    private var modelTask: Task<Void, Never>?
    private var usageTask: Task<Void, Never>?
    private var libraryLoad: Task<Void, Never>?

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
        fallbackNavigation = WindowNavigation(columnVisibility: loadedPreferences.sidebarVisible ? .all : .detailOnly)
        observeModels()
        observeActivation()
        observeUsageCap()
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

    /// Every window asks for the library as it opens; it is read once and shared, so a second window
    /// never replaces the first one's in-memory library (and the lectures open in it) with a re-read.
    func loadLibraryOnce() async {
        if libraryLoad == nil { libraryLoad = Task { await loadLibrary() } }
        await libraryLoad?.value
    }

    func loadLibrary() async {
        do {
            async let c = services.store.loadCourses()
            async let l = services.loadLibrary()
            courses = try await c
            let library = try await l
            sessions = library.sessions
            for issue in library.issues where !libraryIssues.contains(where: { $0.file == issue.file }) {
                libraryIssues.append(issue)
            }
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
                self.modelStatesKnown = true
            }
        }
    }

    // MARK: - API cost cap

    /// Shows the monthly-cap notice (posted at most once a month) in the lecture on screen.
    private func observeUsageCap() {
        guard let usage = services.usage else { return }
        usageTask = Task { [weak self] in
            for await notice in await usage.capNotices() {
                self?.showCapNotice(notice)
            }
        }
    }

    private func showCapNotice(_ notice: UsageCapNotice) {
        let cap = notice.capUSD.formatted(.currency(code: "USD"))
        let title = notice.fellBack
            ? "This month's \(cap) API cap is reached. Cloud roles now use the on-device model."
            : "This month's \(cap) API cap is reached. Cloud roles are paused; raise the cap in Settings › Models."
        let visible = activeNavigation.visibleSessionID.flatMap { openSessions[$0] }
        (liveSession ?? visible)?.showNotice(Notice(id: "usage-cap", kind: .info, symbol: "dollarsign.circle", title: title, placement: .takeaways, actionLabel: nil))
    }

    /// An export failed: shown as a banner in the lecture on screen, or in the Library.
    func exportFailed(_ kind: String, error: Error) {
        let message = "Couldn't export the \(kind): \(error.localizedDescription)"
        let visible = activeNavigation.visibleSessionID.flatMap { openSessions[$0] }
        if let target = visible ?? liveSession {
            target.showNotice(Notice(id: "export", kind: .warning, symbol: "exclamationmark.triangle", title: message, placement: .takeaways, actionLabel: nil))
        } else {
            libraryError = message
        }
    }

    // MARK: - Settings

    func updateSettings(_ change: (inout AppSettings) -> Void) {
        change(&settings)
        Self.save(settings, key: Self.settingsKey)
        // Review lectures have brains too: a provider change must reach them all (B17).
        for session in openSessions.values { session.applySettings(settings) }
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
        guard let data = UserDefaults.lectern.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private static func save<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) { UserDefaults.lectern.set(data, forKey: key) }
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
    func addCourse(code: String, name: String, colorHex: String?, slidesFolder: URL? = nil) -> Course {
        let course = Course(code: code, name: name, colorHex: colorHex, slidesFolder: slidesFolder)
        courses.append(course)
        persistCourses()
        return course
    }

    /// Sets (or clears) the folder where the course's slide decks live; Setup suggests from it.
    func setSlidesFolder(_ folder: URL?, for id: UUID) {
        guard let i = courses.firstIndex(where: { $0.id == id }), courses[i].slidesFolder != folder else { return }
        courses[i].slidesFolder = folder
        persistCourses()
        if setup.courseID == id { refreshDeckSuggestions() }
    }

    /// Asks for the course's slides folder with an open panel.
    func chooseSlidesFolder(for id: UUID) {
        guard let course = course(id: id), let folder = SlidesFolderPanel.choose(for: course) else { return }
        setSlidesFolder(folder, for: id)
    }

    /// Re-scans the Setup course's slides folder. Decks of the course's earlier lectures count as
    /// used, so the suggestion moves on to the next one.
    func refreshDeckSuggestions() {
        let course = course(id: setup.courseID)
        let used = Set(sessions.filter { $0.courseID != nil && $0.courseID == course?.id }.flatMap { $0.decks.map(\.originalFileName) })
        setup.refreshDeckSuggestions(folder: course?.slidesFolder, usedFileNames: used)
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

    /// Why the course can't be deleted right now: a lecture in it is being recorded or imported.
    /// Deleting would orphan that work (a capture with no lecture to land in, an import into a
    /// course that is gone), so the user finishes or cancels it first.
    func courseDeletionBlocker(_ id: UUID) -> String? {
        let busy = sessions.filter { $0.courseID == id && (liveSession?.id == $0.id || imports[$0.id] != nil) }
        guard let first = busy.first else { return nil }
        let what = liveSession?.id == first.id ? "is being recorded" : "is being imported"
        let rest = busy.count > 1 ? " (and \(busy.count - 1) more)" : ""
        return "“\(first.title)”\(rest) \(what). Finish or cancel it before deleting the course."
    }

    func deleteCourse(_ id: UUID) {
        Task { await removeCourse(id) }
    }

    /// Deletes the course's lectures one by one, then the course. If any lecture can't be deleted
    /// it stays (as does the course), so nothing is left pointing at a course that is gone.
    @discardableResult
    func removeCourse(_ id: UUID) async -> Bool {
        if let blocker = courseDeletionBlocker(id) {
            libraryError = blocker
            return false
        }
        var failed = 0
        for victim in sessions.filter({ $0.courseID == id }) {
            if await !removeSession(victim.id) { failed += 1 }
        }
        guard failed == 0 else {
            libraryError = "Couldn't delete \(failed == 1 ? "1 lecture" : "\(failed) lectures") of this course, so the course was kept. \(libraryError ?? "")"
            return false
        }
        courses.removeAll { $0.id == id }
        for window in allWindows where window.sidebarSelection == .course(id) { window.sidebarSelection = .all }
        persistCourses()
        return true
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
        if case .course(let id) = activeNavigation.sidebarSelection { return id }
        return sessions.first?.courseID ?? courses.first?.id
    }

    // MARK: - Sessions

    func deleteSession(_ id: UUID) {
        Task { await removeSession(id) }
    }

    /// Moves the lecture to the Trash. It leaves the Library at once, but only for good once the
    /// store says it is gone: on any failure it comes back, with the error shown. A Trash that
    /// refuses the lecture is offered a permanent deletion (`permanentDeletionOffer`), never done
    /// unasked. A lecture being recorded or imported is refused (stop or cancel it first).
    @discardableResult
    func removeSession(_ id: UUID, permanently: Bool = false) async -> Bool {
        if liveSession?.id == id {
            libraryError = "This lecture is being recorded. Finish it before deleting it."
            return false
        }
        if imports[id] != nil {
            libraryError = "This lecture is being imported. Cancel the import instead."
            return false
        }
        let index = sessions.firstIndex { $0.id == id }
        let snapshot = index.map { sessions[$0] }
        sessions.removeAll { $0.id == id }
        let model = openSessions.removeValue(forKey: id)
        do {
            // A save still in flight must finish (and pending ones be dropped) before the folder
            // goes, or it would write the lecture back.
            await model?.discardPendingSave()
            if permanently { try await services.store.deletePermanently(sessionID: id) } else { try await services.store.delete(sessionID: id) }
            return true
        } catch {
            if let snapshot, !sessions.contains(where: { $0.id == id }) { sessions.insert(snapshot, at: min(index ?? 0, sessions.count)) }
            // The model's unsaved changes were dropped for the deletion; the library copy is as new
            // as the last update, so write it back.
            if let snapshot, model != nil { try? await services.store.save(snapshot) }
            let title = snapshot?.title ?? "the lecture"
            if case StoreError.trashFailed = error {
                permanentDeletionOffer = PermanentDeletionOffer(id: id, title: title, reason: error.localizedDescription)
            } else {
                libraryError = "Couldn't delete “\(title)”: \(error.localizedDescription)"
            }
            return false
        }
    }

    /// The user agreed to erase a lecture the Trash would not take, knowing it can't be recovered.
    func confirmPermanentDeletion() {
        guard let offer = permanentDeletionOffer else { return }
        permanentDeletionOffer = nil
        Task { await removeSession(offer.id, permanently: true) }
    }

    func declinePermanentDeletion() { permanentDeletionOffer = nil }

    /// Closes review lectures that have left the screen and have nothing running. Each open
    /// lecture keeps a brain (holding its transcript) and a set of tasks alive, so without this
    /// every lecture ever opened stays in memory until quit.
    private func closeIdleSessions(except keep: UUID?) {
        // A lecture on screen in any window stays open, whichever window did the navigating.
        let onScreen = Set(allWindows.compactMap(\.visibleSessionID))
        for (id, model) in openSessions where id != keep && !onScreen.contains(id) && model.isIdle {
            openSessions[id] = nil
            Task { await model.close() }
        }
    }

    /// Writes every open lecture's newest state (quit, or before the app goes away).
    func flushSessions() async {
        for model in Array(openSessions.values) { await model.flush() }
    }

    /// Quit: stops the live recording and waits (up to `drainLimit`) for the recognizer to flush
    /// its last words, then writes every open lecture. The save happens even if the recognizer
    /// doesn't finish in time; the lecture is then offered as interrupted on the next launch.
    func prepareForQuit(drainLimit: Duration = .seconds(6)) async {
        if let live = liveSession {
            // Whichever ends first wins. A task group can't race them: it would still wait for the
            // drain after the limit, since awaiting a task's value ignores cancellation.
            let (finished, signal) = AsyncStream.makeStream(of: Void.self)
            Task { await live.stopForQuit(); signal.yield() }
            let limit = Task { try? await Task.sleep(for: drainLimit); signal.yield() }
            for await _ in finished { break }
            limit.cancel()
        }
        await flushSessions()
    }

    func moveSession(_ id: UUID, to courseID: UUID) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[i].courseID = courseID
        let snapshot = sessions[i]
        openSessions[id]?.setCourse(course(id: courseID))
        Task { [services] in
            do { try await services.store.save(snapshot) } catch { self.libraryError = error.localizedDescription }
        }
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

    private var allWindows: [WindowNavigation] { windows.isEmpty ? [fallbackNavigation] : windows }

    /// The window navigation commands act on: the key window, else the one used last.
    var activeNavigation: WindowNavigation {
        windows.first(where: \.isKey) ?? lastActiveWindow ?? windows.last ?? fallbackNavigation
    }

    /// A window's navigation, registered while the window is open. The first window takes over the
    /// placeholder's state (anything done before any window existed).
    func register(_ navigation: WindowNavigation) {
        guard !windows.contains(where: { $0 === navigation }) else { return }
        windows.append(navigation)
        lastActiveWindow = navigation
    }

    func unregister(_ navigation: WindowNavigation) {
        windows.removeAll { $0 === navigation }
        if lastActiveWindow === navigation { lastActiveWindow = windows.last }
        closeIdleSessions(except: nil)
    }

    func windowBecameKey(_ navigation: WindowNavigation) {
        for window in windows { window.isKey = window === navigation }
        lastActiveWindow = navigation
    }

    func showSetup() {
        let nav = activeNavigation
        if setup.courseID == nil { setup.courseID = defaultCourseID() }
        if case .course(let id) = nav.sidebarSelection, setup.deck == nil, setup.title.isEmpty { setup.courseID = id }
        if setup.inputDeviceID == nil { setup.inputDeviceID = settings.inputDeviceID }
        setup.beginMonitoring()
        refreshDeckSuggestions()
        if nav.path.last != .setup { nav.path.append(.setup) }
        closeIdleSessions(except: nil)
    }

    /// Returns to the Library (the detail column shows one screen at a time).
    func goBack() {
        let nav = activeNavigation
        withAnimation(DS.Motion.reduced) { nav.path = [] }
        closeIdleSessions(except: nil)
    }

    func showSetup(droppedPDF url: URL) {
        showSetup()
        setup.loadDeck(url: url)
    }

    /// Opens a finished lecture in review, or resumes the live one, landing on `time` and/or
    /// `slide` when given (also when the lecture is already on screen).
    func openSession(_ id: UUID, at time: TimeInterval? = nil, slide: Int? = nil) {
        let nav = activeNavigation
        if time != nil || slide != nil { nav.requestLanding(PendingNavigation(sessionID: id, time: time, slide: slide)) }
        if openSessions[id] == nil, let stored = sessions.first(where: { $0.id == id }) {
            let model = LiveSessionModel(session: stored, course: course(id: stored.courseID), mode: .review, services: services, settings: settings, preferences: preferences)
            model.onSessionChanged = { [weak self] s in self?.libraryDidUpdate(s) }
            if let notice = Self.importNotice(for: stored) { model.showNotice(notice) }
            openSessions[id] = model
        }
        nav.path = [.session(id)]
        closeIdleSessions(except: id)
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
        // The live session takes over Setup's deck file (and its conversion's temporary PDF)
        // before `setup.reset()` would dispose of it.
        let deck = setup.takeStartingDeck()
        let microphone = setup.inputDeviceID   // the one Setup's meter was showing
        openSessions[draft.id] = model
        liveSession = model
        libraryDidUpdate(draft)
        showLive(draft.id)
        setup.reset()
        model.start(deckURL: deck?.url, inputDeviceID: microphone, conversion: deck?.conversion)
    }

    /// Puts the recording on screen in the active window with the sidebar out of the way.
    private func showLive(_ id: UUID) {
        let nav = activeNavigation
        liveWindow = nav
        nav.restoredVisibility = nav.columnVisibility
        withAnimation(DS.Motion.settle) {
            nav.columnVisibility = .detailOnly
            nav.path = [.session(id)]
        }
    }

    private func sessionDidFinish() {
        liveSession = nil
        focusPanel.hide()
        if let window = liveWindow { withAnimation(DS.Motion.settle) { window.columnVisibility = window.restoredVisibility } }
        liveWindow = nil
    }

    func toggleFocusPanel() {
        guard let live = liveSession else { return }
        focusPanel.toggle(session: live, app: self)
    }

    // MARK: - Interrupted sessions (crash recovery)

    /// Sessions left `.live`/`.paused`/`.importing` by a previous run and not active now.
    var interruptedSessions: [LectureSession] { sessions.filter(isInterrupted) }

    func isInterrupted(_ s: LectureSession) -> Bool {
        (s.status == .live || s.status == .paused || s.status == .importing) && liveSession?.id != s.id && imports[s.id] == nil
    }

    /// Picks recording back up on a session that was live when the app last quit.
    func resumeInterrupted(_ id: UUID) {
        guard liveSession == nil, let stored = sessions.first(where: { $0.id == id }) else { return }
        let model = LiveSessionModel(session: stored, course: course(id: stored.courseID), mode: .live, services: services, settings: settings, preferences: preferences)
        model.onSessionChanged = { [weak self] s in self?.libraryDidUpdate(s) }
        model.onFinished = { [weak self] in self?.sessionDidFinish() }
        openSessions[id] = model
        liveSession = model
        showLive(id)
        model.start(deckURL: nil, inputDeviceID: settings.inputDeviceID)
    }

    /// Marks an interrupted session finished (writing the summary) and opens it in review.
    func finishInterrupted(_ id: UUID) {
        guard let stored = sessions.first(where: { $0.id == id }) else { return }
        if stored.status == .importing {
            // An import is finished from the transcript it saved, which needs no recording. One
            // that never got that far has nothing to finish (the card offers only Discard).
            guard canFinishInterruptedImport(stored), imports[id] == nil else { return }
            let job = ImportJob(session: stored)
            imports[id] = job
            let importer = services.recordingImporter
            launch(job, session: stored, prepare: nil) { draft, progress in try await importer.resumeImport(draft, progress: progress) }
            return
        }
        let model = LiveSessionModel(session: stored, course: course(id: stored.courseID), mode: .live, services: services, settings: settings, preferences: preferences)
        model.onSessionChanged = { [weak self] s in self?.libraryDidUpdate(s) }
        openSessions[id] = model
        model.finishWithoutRecording()
        activeNavigation.path = [.session(id)]
    }

    // MARK: - Import a recording

    func showImport() {
        if importDraft.courseID == nil { importDraft.courseID = defaultCourseID() }
        refreshImportDeckSuggestions()
        importPresenter = activeNavigation
        showImportSheet = true
    }

    /// Re-scans the import's course slides folder so the sheet can offer its decks (QA Q3-5).
    func refreshImportDeckSuggestions() {
        let course = course(id: importDraft.courseID ?? courses.first?.id)
        let used = Set(sessions.filter { $0.courseID != nil && $0.courseID == course?.id }.flatMap { $0.decks.map(\.originalFileName) })
        importDraft.refreshDeckSuggestions(folder: course?.slidesFolder, usedFileNames: used, services: services)
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
        let importer = services.recordingImporter
        launch(job, session: session, prepare: { [weak self] draft in await self?.prepareImportDraft(draft, deckURL: deckURL) }) { draft, progress in
            try await importer.importRecording(source, into: draft, progress: progress)
        }
    }

    /// Hands `job` its work and wires what happens when it ends. A job that was cancelled (it is no
    /// longer `imports[id]`) never reports back.
    private func launch(
        _ job: ImportJob,
        session: LectureSession,
        prepare: (@MainActor (LectureSession) async -> LectureSession?)?,
        run: @escaping @Sendable (LectureSession, @escaping @Sendable (ImportStage) -> Void) async throws -> LectureSession
    ) {
        job.start(session, prepare: prepare, run: run) { [weak self, weak job] result in
            guard let self, let job, self.imports[result.id] === job else { return }
            self.libraryDidUpdate(result)
            Task {
                do { try await self.services.store.save(result) } catch { self.libraryError = error.localizedDescription }
                guard self.imports[result.id] === job else { return }
                self.imports[result.id] = nil
                self.openSession(result.id)
            }
        } onFailed: { [weak self, weak job] message in
            guard let self, let job, self.imports[session.id] === job else { return }
            Task { await self.keepRecoverableWork(of: job, failure: message) }
        }
    }

    /// Copies and reads the import's slide deck, then saves the draft, so an interrupted import has
    /// a lecture on disk. Checks for cancellation after every suspension and returns nil if the
    /// import was cancelled: a cancelled import must leave nothing behind.
    private func prepareImportDraft(_ draft: LectureSession, deckURL: URL?) async -> LectureSession? {
        var draft = draft
        if let deckURL {
            do {
                var stored = try await services.slideIngestor.ingest(pdfAt: deckURL, progress: { _ in })
                guard !Task.isCancelled else { return nil }
                do {
                    stored.fileName = try await services.store.importSlides(from: deckURL, into: draft.id)
                } catch {
                    libraryError = "Couldn't copy the slide deck for “\(draft.title)” into the library: \(error.localizedDescription)"
                }
                guard !Task.isCancelled else { return nil }
                draft.deck = stored
            } catch {
                guard !Task.isCancelled else { return nil }
                libraryError = "Couldn't read the slide deck for “\(draft.title)”: \(error.localizedDescription) It is being imported without slides."
            }
        }
        guard !Task.isCancelled else { return nil }
        do { try await services.store.save(draft) } catch { libraryError = error.localizedDescription }
        return Task.isCancelled ? nil : draft
    }

    /// A failed import keeps its card (with the reason) in the Library. When it had saved a
    /// transcript, that stays on disk and in the list so the lecture can be finished from it.
    private func keepRecoverableWork(of job: ImportJob, failure: String) async {
        guard let stored = try? await services.store.loadSession(id: job.id), canFinishInterruptedImport(stored) else { return }
        guard imports[job.id] === job else { return }
        if let i = sessions.firstIndex(where: { $0.id == job.id }) { sessions[i] = stored }
        job.amendFailure("\(failure) The transcript so far was kept; dismiss this to finish the lecture from it.")
    }

    /// Cancels an import and removes everything it made. The row leaves the Library at once; the
    /// draft goes to the Trash only after the import's task has really stopped, so no late write of
    /// it can bring the lecture back.
    func cancelImport(_ id: UUID) {
        guard let job = imports[id] else { return }
        job.cancel()
        imports[id] = nil
        Task {
            await job.waitUntilStopped()
            await removeSession(id)
        }
    }

    /// Dismisses a failed import's card. A draft with nothing worth keeping is deleted from disk
    /// too; one with a saved transcript stays in the Library as an interrupted import.
    func dismissFailedImport(_ id: UUID) {
        guard imports[id] != nil else { return }
        imports[id] = nil
        if let row = sessions.first(where: { $0.id == id }), canFinishInterruptedImport(row) { return }
        Task { await removeSession(id) }
    }

    /// An import interrupted or failed after it had saved some transcript can be finished from it.
    func canFinishInterruptedImport(_ session: LectureSession) -> Bool {
        session.status == .importing && !session.transcript.isEmpty
    }

    /// The banner a lecture with import problems opens with (nil when the import was clean).
    static func importNotice(for session: LectureSession) -> Notice? {
        guard session.status == .finished, let record = session.importRecord, !record.warnings.isEmpty else { return nil }
        let shown = record.warnings.prefix(2).joined(separator: " ")
        let more = record.warnings.count > 2 ? " (+\(record.warnings.count - 2) more)" : ""
        return Notice(id: "import-warnings", kind: .warning, symbol: "exclamationmark.triangle", title: "This import is incomplete. \(shown)\(more)", placement: .takeaways, actionLabel: nil)
    }

    // MARK: - Course-wide Ask

    /// Lookup-or-create only (safe to call from a view body); views call `prepare` from `.task`.
    func courseAsk(for courseID: UUID) -> CourseAskModel {
        if let existing = courseAsks[courseID] { return existing }
        let model = CourseAskModel(
            courseID: courseID, services: services,
            askProvider: { [weak self] in self?.settings.provider(for: .ask) },
            courseName: { [weak self] in self?.courses.first { $0.id == courseID }.map { "\($0.code) — \($0.name)" } }
        )
        courseAsks[courseID] = model
        return model
    }

    /// The course to ask about in the active window.
    var contextCourseID: UUID? { contextCourseID(for: activeNavigation) }

    /// The course to ask about in `nav`'s window: the sidebar's course, or the open session's course.
    func contextCourseID(for nav: WindowNavigation) -> UUID? {
        if case .course(let id) = nav.sidebarSelection { return id }
        if let sid = nav.visibleSessionID, let s = openSessions[sid] { return s.course?.id }
        return courses.first?.id
    }

    func toggleCourseAsk() {
        guard contextCourseID != nil else { return }
        let nav = activeNavigation
        if let id = nav.visibleSessionID, let session = openSessions[id] {
            session.focusAsk()   // the session Ask tab has the "Whole course" scope
            return
        }
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { nav.showCourseAsk.toggle() }
    }

    /// Opens the cited lecture at a slide or time.
    func open(courseCitation c: CourseCitation) {
        switch c.citation {
        case .time(let t): openSession(c.sessionID, at: t)
        case .slide(let n): openSession(c.sessionID, slide: n)
        }
    }

    // MARK: - Model status

    private func computeModelStatus() -> ModelStatus {
        ModelReadiness.status(
            settings: settings, states: modelStates, statesKnown: modelStatesKnown,
            keyStored: { cloudKeyStored[$0] }, modelName: shortModelName)
    }

    func shortModelName(_ id: String) -> String {
        services.onDeviceModels.catalog.first { $0.id == id }?.displayName ?? id.split(separator: "/").last.map(String.init) ?? id
    }

    func modelState(_ id: String) -> OnDeviceModelState { modelStates[id] ?? .notInstalled }
}

/// A lecture whose Move to Trash failed, waiting for the user to decide about erasing it for good.
struct PermanentDeletionOffer: Identifiable, Equatable {
    var id: UUID
    var title: String
    /// Why the Trash refused, for the dialog.
    var reason: String
}
