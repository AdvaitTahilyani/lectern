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
                NSApp.activate()
                live.showStopConfirmation = true
            }.keyboardShortcut(".", modifiers: .command)
            Divider()
            Button(live.isFocusPanelOpen ? "Hide Focus Panel" : "Show Focus Panel") { app.toggleFocusPanel() }.keyboardShortcut("f", modifiers: [.command, .shift])
            Button("Open Lectern") { NSApp.activate(); openWindow(id: "main") }
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
            Button("Stop…") { live?.showStopConfirmation = true }.keyboardShortcut(".", modifiers: .command).disabled(live == nil)
            Divider()
            Button("Ask") { currentSession?.focusAsk() }.keyboardShortcut("k", modifiers: .command).disabled(currentSession == nil)
            Button("Ask (Alternate)") { currentSession?.focusAsk() }.keyboardShortcut("l", modifiers: .command).disabled(currentSession == nil)
            Button("Catch Me Up (Last 5 Min)") { live?.ask("Catch me up (last 5 min)") }.keyboardShortcut("k", modifiers: [.command, .shift]).disabled(live == nil)
            Button("Ask This Course…") { app.toggleCourseAsk() }.keyboardShortcut("k", modifiers: [.command, .option])
            Divider()
            Button("Toggle Focus Panel") { app.toggleFocusPanel() }.keyboardShortcut("f", modifiers: [.command, .shift]).disabled(live == nil)
            Button("Toggle Inspector") { currentSession?.toggleInspector() }.keyboardShortcut("i", modifiers: [.command, .option]).disabled(currentSession == nil)
            Button("Toggle Slides") { currentSession?.showSlides.toggle() }.keyboardShortcut("s", modifiers: [.command, .option]).disabled(currentSession == nil)
            Button("Resume Slide Following") { currentSession?.resumeFollowing() }.keyboardShortcut("a", modifiers: [.command, .shift]).disabled(currentSession == nil)
            Divider()
            Button("Takeaways") { currentSession?.pane = .takeaways }.keyboardShortcut("1", modifiers: .command).disabled(currentSession == nil)
            Button("Transcript") { currentSession?.pane = .transcript; currentSession?.inspectorTab = .transcript; currentSession?.isInspectorShown = true }.keyboardShortcut("2", modifiers: .command).disabled(currentSession == nil)
            Button("Slides") { currentSession?.pane = .slides }.keyboardShortcut("3", modifiers: .command).disabled(currentSession == nil)
            Button("Ask Tab") { currentSession?.focusAsk() }.keyboardShortcut("4", modifiers: .command).disabled(currentSession == nil)
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
        if case .session(let id) = app.path.last { return app.session(for: id) }
        return nil
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
