import AppKit
import Foundation
import LecternCore
import ScreenCaptureKit
import SwiftUI

/// Demo-mode automation hook: listens for `com.advait.Lectern.demo` distributed notifications whose
/// `object` is a command string, so screenshots and flows can be driven from a script without
/// Accessibility or Screen Recording permissions (an app may capture its own windows).
///
/// Commands: `screenshot:<dir>`, `open-setup`, `sample-deck`, `start`, `finish`, `open-review:<n>`,
/// `open-library`, `tab:<transcript|ask|quiz>`, `pane:<takeaways|transcript|slides>`, `ask:<text>`,
/// `answer:<1-4>`, `resize:<w>x<h>`, `appearance:<system|light|dark>`, `focus-panel`, `away:<sec>`,
/// `settings`, `import`, `course-ask`, `ask-course:<text>`, `select-course:<n>`,
/// `sidebar:<show|hide>`, `inspector:<show|hide>`, `expand:<n>`, `quit`.
@MainActor
final class DemoDriver {
    static let notificationName = Notification.Name("com.advait.Lectern.demo")
    private let app: AppModel
    private var observer: (any NSObjectProtocol)?
    /// Captures run one after another so a burst of commands can't interleave.
    private var captureChain: Task<Void, Never>?

    init(app: AppModel) {
        self.app = app
        let token = DemoConfiguration.current.driverToken
        observer = DistributedNotificationCenter.default().addObserver(forName: Self.notificationName, object: nil, queue: .main) { note in
            // Commands are "<token>|<command>"; only the instance launched with that token acts.
            let raw = note.object as? String ?? ""
            let parts = raw.split(separator: "|", maxSplits: 1).map(String.init)
            guard let token, parts.count == 2, parts[0] == token else { return }
            Task { @MainActor in DemoDriverCommands.shared?.handle(parts[1]) }
        }
        DemoDriverCommands.shared = self
    }

    func handle(_ command: String) {
        let parts = command.split(separator: ":", maxSplits: 1).map(String.init)
        let name = parts.first ?? ""
        let arg = parts.count > 1 ? parts[1] : ""
        switch name {
        case "screenshot": capture(to: arg)
        case "open-setup": app.showSetup()
        case "sample-deck": app.setup.loadSampleDeck()
        case "start": app.startLecture()
        case "finish": app.liveSession?.finish()
        case "open-review":
            let index = Int(arg) ?? 0
            let finished = app.sessions.filter { $0.status == .finished }
            if finished.indices.contains(index) { app.openSession(finished[index].id) }
        case "open-library": app.activeNavigation.path = []
        case "tab":
            if let tab = InspectorTab(rawValue: arg) { currentSession?.inspectorTab = tab; currentSession?.isInspectorShown = true }
        case "pane":
            if let pane = SessionPane(rawValue: arg) { currentSession?.pane = pane }
        case "ask": currentSession?.ask(arg)
        case "answer": if let n = Int(arg) { currentSession?.selectOption(n - 1) }
        case "resize":
            let dims = arg.split(separator: "x").compactMap { Double($0) }
            if dims.count == 2, let window = mainWindow {
                var frame = window.frame
                frame.size = CGSize(width: dims[0], height: dims[1])
                window.setFrame(frame, display: true, animate: false)
            }
        case "appearance":
            if let a = UIPreferences.Appearance(rawValue: arg) { app.updatePreferences { $0.appearance = a } }
        case "focus-panel": app.toggleFocusPanel()
        case "away": app.liveSession?.simulateAway(seconds: Double(arg) ?? 180)
        case "settings": NotificationCenter.default.post(name: .lecternOpenSettings, object: nil)
        case "import": app.showImport()
        case "course-ask": if !app.activeNavigation.showCourseAsk { app.toggleCourseAsk() }
        case "ask-course":
            if let id = app.contextCourseID { let m = app.courseAsk(for: id); m.prepare(sessions: app.sessions); m.ask(arg) }
        case "select-course":
            let i = Int(arg) ?? 0
            if app.courses.indices.contains(i) { app.activeNavigation.sidebarSelection = .course(app.courses[i].id) }
        case "sidebar": app.activeNavigation.columnVisibility = arg == "show" ? .all : .detailOnly
        case "inspector": if (currentSession?.isInspectorShown ?? false) != (arg == "show") { currentSession?.toggleInspector() }
        case "expand":
            if let s = currentSession, let t = s.settledTakeaways.dropFirst(Int(arg) ?? 0).first { s.expandTakeaway(t.id) }
        case "quit": NSApp.terminate(nil)
        default: break
        }
    }

    private var currentSession: LiveSessionModel? {
        if let id = app.activeNavigation.visibleSessionID { return app.session(for: id) }
        return nil
    }

    private var mainWindow: NSWindow? {
        NSApp.windows.first { $0.isVisible && !($0 is NSPanel) && $0.title != "Welcome to Lectern" && !$0.title.hasPrefix("Settings") } ?? NSApp.mainWindow
    }

    /// Writes one PNG per visible window into `dir` (`<index>-<title>.png`). Uses ScreenCaptureKit
    /// for the app's own windows, falling back to an offscreen view render if capture is refused.
    private func capture(to dir: String) {
        let base = URL(fileURLWithPath: dir)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let windows = NSApp.windows.filter { $0.isVisible && $0.frame.width > 10 }
        let previous = captureChain
        captureChain = Task { @MainActor in
            await previous?.value
            let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            for (i, window) in windows.enumerated() {
                let title = window.title.isEmpty ? (window is NSPanel ? "panel" : "window") : window.title
                let safe = title.replacingOccurrences(of: "[^A-Za-z0-9]+", with: "-", options: .regularExpression).lowercased()
                let url = base.appendingPathComponent("\(i)-\(safe).png")
                var image: CGImage?
                if let sc = content?.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) {
                    let config = SCStreamConfiguration()
                    config.width = Int(window.frame.width * (window.backingScaleFactor))
                    config.height = Int(window.frame.height * (window.backingScaleFactor))
                    config.showsCursor = false
                    config.captureResolution = .best
                    // Prefer a display-region capture (keeps vibrancy/glass compositing intact);
                    // fall back to the bare window image.
                    if let screen = window.screen, let display = content?.displays.first(where: { $0.displayID == (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) }) {
                        // Full-screen filter: vibrant/glass content only composites correctly against the real
                        // backdrop, so capture the display region under the window rather than the window alone.
                        let filter = SCContentFilter(display: display, excludingWindows: [])
                        let frame = window.frame
                        config.sourceRect = CGRect(x: frame.minX - screen.frame.minX, y: screen.frame.maxY - frame.maxY, width: frame.width, height: frame.height)
                        image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                    }
                    if image == nil {
                        image = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: sc), configuration: config)
                    }
                }
                if image == nil, let view = window.contentView?.superview ?? window.contentView,
                   let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    image = rep.cgImage
                }
                guard let image else { continue }
                // Glass regions are transparent in a window-only capture; flatten onto the window
                // background so screenshots approximate what sits over a plain desktop.
                let size = NSSize(width: image.width, height: image.height)
                let flattened = NSImage(size: size, flipped: false) { rect in
                    (window.backgroundColor ?? .windowBackgroundColor).setFill()
                    rect.fill()
                    NSImage(cgImage: image, size: size).draw(in: rect)
                    return true
                }
                if let tiff = flattened.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let data = rep.representation(using: .png, properties: [:]) {
                    try? data.write(to: url)
                }
            }
            try? "done".write(to: base.appendingPathComponent(".done"), atomically: true, encoding: .utf8)
        }
    }
}

@MainActor
enum DemoDriverCommands {
    weak static var shared: DemoDriver?
}
