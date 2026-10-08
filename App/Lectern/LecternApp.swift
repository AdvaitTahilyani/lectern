import SwiftUI
import LecternCore

@main
struct LecternApp: App {
    @State private var app: AppModel
    @State private var demoDriver: DemoDriver?
    @NSApplicationDelegateAdaptor private var delegate: LecternAppDelegate

    init() {
        let demo = DemoConfiguration.current.isEnabled
        let services: AppServices = demo ? .demo : .live
        let model = AppModel(services: services, isDemo: demo)
        _app = State(initialValue: model)
        _demoDriver = State(initialValue: demo ? DemoDriver(app: model) : nil)
    }

    var body: some Scene {
        WindowGroup("Lectern", id: "main") {
            RootView()
                .environment(app)
                .environment(\.flatGlass, DemoConfiguration.current.flatGlass)
                .resolvingMotion()
                .preferredColorScheme(colorScheme)
                .frame(minWidth: DS.Layout.windowMin.width, minHeight: DS.Layout.windowMin.height)
        }
        .defaultSize(DS.Layout.windowDefault)
        .commands { LecternCommands(app: app) }

        Window("Welcome to Lectern", id: "onboarding") {
            OnboardingView()
                .environment(app)
                .environment(\.flatGlass, DemoConfiguration.current.flatGlass)
                .resolvingMotion()
                .preferredColorScheme(colorScheme)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .restorationBehavior(.disabled)
        .defaultPosition(.center)

        Settings {
            SettingsView()
                .environment(app)
                .environment(\.flatGlass, DemoConfiguration.current.flatGlass)
                .resolvingMotion()
                .preferredColorScheme(colorScheme)
        }

        MenuBarExtra(isInserted: Binding(get: { app.liveSession != nil && app.preferences.showMenuBarWhileRecording }, set: { _ in })) {
            MenuBarContent().environment(app)
        } label: {
            MenuBarLabel().environment(app)
        }
        .menuBarExtraStyle(.menu)
    }

    private var colorScheme: ColorScheme? {
        switch app.preferences.appearance {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

final class LecternAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// 0: not asked to quit yet, 1: cleaning up, 2: cleaned up (the next request quits).
    private var quitStage = 0

    /// Quitting stops the recording, waits for the recognizer's last words and writes open
    /// lectures, so the last seconds of a recording survive; then it stops on-device model work
    /// (exiting while the GPU is busy crashes in MLX's teardown). The first request is cancelled
    /// and the cleanup runs normally, then quits again: replying `.terminateLater` would park the
    /// main thread in AppKit's modal wait, where main-actor work (the cleanup itself) can't run.
    /// A hung disk write or generation delays quitting by at most 10 s.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        switch quitStage {
        case 2: return .terminateNow
        case 1: return .terminateCancel
        default: break
        }
        quitStage = 1
        Task {
            let (done, signal) = AsyncStream.makeStream(of: Void.self)
            Task {
                if let app = AppModelActivation.shared, !app.openSessions.isEmpty { await app.prepareForQuit() }
                if !DemoConfiguration.current.isEnabled { await OnDeviceStack.shutdownModels() }
                signal.yield()
            }
            let limit = Task { try? await Task.sleep(for: .seconds(10)); signal.yield() }
            for await _ in done { break }
            limit.cancel()
            quitStage = 2
            NSApp.terminate(nil)
        }
        return .terminateCancel
    }
}

// MARK: - Menu bar extra

private struct MenuBarLabel: View {
    @Environment(AppModel.self) private var app
    private static let glyph = LecternGlyph.templateImage(size: 18, recordingDot: nil)
    var body: some View {
        let paused = app.liveSession?.recordingState == .paused
        Image(nsImage: Self.glyph)
            .overlay(alignment: .bottomTrailing) {
                Circle().fill(paused ? Color.gray : DS.Colors.recording).frame(width: 5, height: 5)
            }
    }
}

private struct MenuBarContent: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        if let live = app.liveSession {
            Text("\(live.recordingState == .paused ? "Paused" : "Recording") — \(live.title) · \(TimeFormat.clock(live.elapsed))")
            if let now = live.liveTakeaway?.title ?? live.settledTakeaways.last?.title {
                Text("Now: \(String(now.prefix(40)))\(now.count > 40 ? "…" : "")")
            }
            Divider()
            Button(live.recordingState == .paused ? "Resume" : "Pause") { live.togglePause() }.keyboardShortcut("p", modifiers: [.command, .shift])
            Button("Finish Lecture…") {
                showMainWindow { openWindow(id: "main") }
                app.confirmFinish(live)
            }.keyboardShortcut(".", modifiers: .command)
            Divider()
            Button(live.isFocusPanelOpen ? "Hide Focus Panel" : "Show Focus Panel") { app.toggleFocusPanel() }.keyboardShortcut("f", modifiers: [.command, .shift])
            Button("Open Lectern") { showMainWindow { openWindow(id: "main") } }
            Divider()
            Button("Settings…") { openSettings() }.keyboardShortcut(",", modifiers: .command)
        }
    }
}

// MARK: - Commands (every shortcut appears in a menu — DESIGN.md §8)

struct LecternCommands: Commands {
    var app: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Lecture") { app.showSetup() }.keyboardShortcut("n", modifiers: .command)
            Button("Import Recording…") { app.showImport() }.keyboardShortcut("i", modifiers: [.command, .shift])
            Button("New Window") { openWindow(id: "main") }.keyboardShortcut("n", modifiers: [.command, .shift])
        }
        CommandGroup(after: .textEditing) {
            Button("Find") { NotificationCenter.default.post(name: .lecternFind, object: nil) }.keyboardShortcut("f", modifiers: .command)
        }
        CommandGroup(replacing: .help) {
            Button("Welcome to Lectern") { NotificationCenter.default.post(name: .lecternOpenOnboarding, object: nil) }
        }
        CommandMenu("Lecture") {
            let live = app.liveSession
            Button(live?.recordingState == .paused ? "Resume" : "Pause") { live?.togglePause() }
                .keyboardShortcut("p", modifiers: [.command, .shift]).disabled(live == nil)
            Button("Stop…") { if let live { app.confirmFinish(live) } }.keyboardShortcut(".", modifiers: .command).disabled(live == nil)
            Divider()
            Button("Ask") { currentSession?.focusAsk() }.keyboardShortcut("k", modifiers: .command).disabled(currentSession == nil)
            Button("Catch Me Up (Last 5 Min)") {
                // `ask` alone leaves the answer in a closed inspector (or a pane that isn't showing).
                currentSession?.focusAsk()
                currentSession?.ask("Catch me up (last 5 min)")
            }.keyboardShortcut("k", modifiers: [.command, .shift]).disabled(currentSession?.isLive != true)
            Button("Ask This Course…") { app.toggleCourseAsk() }.keyboardShortcut("k", modifiers: [.command, .option])
            Divider()
            Button("Toggle Focus Panel") { app.toggleFocusPanel() }.keyboardShortcut("f", modifiers: [.command, .shift]).disabled(live == nil)
            Button("Toggle Inspector") { currentSession?.toggleInspector() }.keyboardShortcut("i", modifiers: [.command, .option]).disabled(currentSession == nil || currentSession?.layoutTier == .single)
            Button("Toggle Slides") { currentSession?.showSlides.toggle() }.keyboardShortcut("s", modifiers: [.command, .option]).disabled(currentSession == nil)
            Button("Resume Slide Following") { currentSession?.resumeFollowing() }.keyboardShortcut("a", modifiers: [.command, .shift]).disabled(currentSession == nil)
            Button("Add Slide Deck…") { currentSession?.chooseDecks() }.keyboardShortcut("d", modifiers: [.command, .shift]).disabled(currentSession == nil)
            Divider()
            Button("Takeaways") { currentSession?.selectPane(.takeaways) }.keyboardShortcut("1", modifiers: .command).disabled(currentSession == nil)
            Button("Transcript") { currentSession?.selectPane(.transcript) }.keyboardShortcut("2", modifiers: .command).disabled(currentSession == nil)
            Button("Slides") { currentSession?.selectPane(.slides) }.keyboardShortcut("3", modifiers: .command).disabled(currentSession == nil)
            Button("Ask Tab") { currentSession?.selectPane(.ask) }.keyboardShortcut("4", modifiers: .command).disabled(currentSession == nil)
            Button("Jump to Live") { NotificationCenter.default.post(name: .lecternJumpToLive, object: nil) }.keyboardShortcut(.downArrow, modifiers: .command).disabled(currentSession == nil)
            Divider()
            Button("Export…") { NotificationCenter.default.post(name: .lecternExport, object: nil) }.keyboardShortcut("e", modifiers: .command).disabled(currentSession?.isLive != false)
            Button("Copy Summary") { currentSession?.copySummary() }.keyboardShortcut("c", modifiers: [.command, .shift]).disabled(currentSession?.isLive != false)
            Button("Edit Title") { currentSession?.isEditingTitle = true }.keyboardShortcut("t", modifiers: [.command, .shift]).disabled(currentSession?.isLive != false)
        }
        if app.isDemo {
            CommandMenu("Debug") {
                Button("Simulate Being Away (3 min)") { app.liveSession?.simulateAway(seconds: 180) }.disabled(app.liveSession == nil)
                Button("Finish Lecture Now") { app.liveSession?.finish() }.disabled(app.liveSession == nil)
                Text("Demo mode · speed \(DemoConfiguration.current.speed, format: .number)×")
            }
        }
    }

    private var currentSession: LiveSessionModel? {
        app.activeNavigation.visibleSessionID.flatMap { app.session(for: $0) }
    }
}

extension AppModel {
    /// Brings the live lecture on screen and asks whether to finish it: the confirmation is a
    /// popover on that lecture's toolbar, so it shows nothing while another screen is up.
    func confirmFinish(_ live: LiveSessionModel) {
        if activeNavigation.visibleSessionID != live.id { openSession(live.id) }
        live.showStopConfirmation = true
    }
}

/// Brings the main window forward, opening one only when none is on screen (`openWindow` always
/// creates a new window, so calling it with one already open piles up duplicates).
@MainActor
func showMainWindow(openIfNeeded open: () -> Void) {
    NSApp.activate()
    if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true && ($0.isVisible || $0.isMiniaturized) }) {
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
    } else {
        open()
    }
}

extension Notification.Name {
    static let lecternJumpToLive = Notification.Name("lectern.jumpToLive")
    static let lecternExport = Notification.Name("lectern.export")
    static let lecternOpenOnboarding = Notification.Name("lectern.openOnboarding")
    static let lecternOpenSettings = Notification.Name("lectern.openSettings")
    /// ⌘F: focus the library search field or the transcript search.
    static let lecternFind = Notification.Name("lectern.find")
}
