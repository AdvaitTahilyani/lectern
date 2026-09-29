import AppKit
import SwiftUI
import LecternCore

/// Floating, non-activating glass mini panel (DESIGN.md §4.7, §12). An `NSPanel` hosting SwiftUI
/// so it can join all Spaces and never steal focus from the app in front.
@MainActor
final class FocusPanelController {
    private var panel: NSPanel?
    private weak var session: LiveSessionModel?
    private var moveObserver: (any NSObjectProtocol)?

    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle(session: LiveSessionModel, app: AppModel) {
        if isVisible { hide() } else { show(session: session, app: app) }
    }

    func show(session: LiveSessionModel, app: AppModel) {
        let view = FocusPanelView(session: session, app: app, onClose: { [weak self] in self?.hide() }, onResize: { [weak self] size in self?.resize(to: size) })
            .environment(\.flatGlass, DemoConfiguration.current.flatGlass)
        let hosting = NSHostingView(rootView: view)
        // The panel has a fixed size per state; the window is resized explicitly (below) instead
        // of letting intrinsic-size constraints drive it, which can loop while text streams.
        hosting.sizingOptions = []
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: DS.Layout.focusPanel),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hosting
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.collectionBehavior = app.preferences.focusPanelAllSpaces ? [.canJoinAllSpaces, .fullScreenAuxiliary] : [.fullScreenAuxiliary]
        panel.identifier = NSUserInterfaceItemIdentifier("focus")
        if let origin = app.preferences.focusPanelOrigin {
            panel.setFrameOrigin(origin)
        } else if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.maxX - DS.Layout.focusPanel.width - 20, y: frame.maxY - DS.Layout.focusPanel.height - 20))
        }
        moveObserver = NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { [weak panel] _ in
            MainActor.assumeIsolated {
                guard let origin = panel?.frame.origin else { return }
                app.updatePreferences { $0.focusPanelOrigin = origin }
            }
        }
        panel.orderFrontRegardless()
        self.panel = panel
        self.session = session
        session.isFocusPanelOpen = true
    }

    /// Grows/shrinks the panel (160 ⇄ 248 pt) keeping its top-right corner anchored.
    private func resize(to size: CGSize) {
        guard let panel, panel.frame.size != size else { return }
        var frame = panel.frame
        frame.origin.y += frame.height - size.height
        frame.size = size
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        panel.setFrame(frame, display: true, animate: !reduceMotion)
    }

    func hide() {
        if let moveObserver { NotificationCenter.default.removeObserver(moveObserver) }
        moveObserver = nil
        panel?.orderOut(nil)
        panel = nil
        session?.isFocusPanelOpen = false
        session = nil
    }
}

/// Contents of the Focus panel: live dot + time + course, current takeaway, quiz strip.
struct FocusPanelView: View {
    var session: LiveSessionModel
    var app: AppModel
    var onClose: () -> Void
    var onResize: (CGSize) -> Void
    @State private var hovered = false
    @State private var idle = false
    @State private var idleTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            header
            if let live = session.liveTakeaway {
                Text(live.title).font(DS.Typo.headline).lineLimit(1).contentTransition(.opacity)
                Text(live.summary).font(DS.Typo.subheadline).foregroundStyle(.secondary).lineLimit(2).contentTransition(.opacity)
            } else if let last = session.settledTakeaways.last {
                Text(last.title).font(DS.Typo.headline).lineLimit(1)
                Text(last.summary).font(DS.Typo.subheadline).foregroundStyle(.secondary).lineLimit(2)
            } else {
                Text("Listening…").font(DS.Typo.headline).foregroundStyle(.secondary)
                Text("The first takeaway usually appears after a couple of minutes.").font(DS.Typo.subheadline).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
            if let quiz = session.quiz, quiz.phase == .asking {
                Divider()
                quizStrip(quiz)
            }
        }
        .animation(DS.Motion.morph, value: session.liveTakeaway?.title)
        .padding(DS.Space.l)
        .frame(width: panelSize.width, height: panelSize.height, alignment: .top)
        .onChange(of: session.quiz?.phase == .asking, initial: true) { _, _ in onResize(panelSize) }
        .lecternGlass(.regular, in: .rect(cornerRadius: DS.Radius.panel))
        .opacity(idle && !hovered && session.quiz == nil && app.preferences.focusPanelDimWhenIdle ? 0.85 : 1)
        .animation(DS.Motion.quick, value: idle)
        .onHover { h in
            hovered = h
            if h { idle = false; idleTask?.cancel() } else { scheduleIdle() }
        }
        .onAppear { scheduleIdle() }
        .onKeyPress(characters: .decimalDigits) { press in
            guard let quiz = session.quiz, quiz.phase == .asking, let n = Int(press.characters), (1...4).contains(n) else { return .ignored }
            session.selectOption(n - 1)
            return .handled
        }
        .onKeyPress(.escape) { session.skipQuiz(); return .handled }
        .onKeyPress("s") { session.snoozeQuiz(); return .handled }
        .accessibilityLabel("Focus panel")
    }

    private var panelSize: CGSize { session.quiz?.phase == .asking ? DS.Layout.focusPanelWithQuiz : DS.Layout.focusPanel }

    private var header: some View {
        HStack(spacing: DS.Space.s) {
            LiveDot(state: session.recordingState == .paused ? .paused : .recording, size: DS.Size.liveDotSmall).accessibilityHidden(true)
            Text(TimeFormat.clock(session.elapsed)).font(DS.Typo.mono).contentTransition(.numericText())
            Text(session.courseLabel).font(DS.Typo.caption).foregroundStyle(.secondary)
            Spacer()
            HStack(spacing: DS.Space.xs) {
                Button { session.togglePause() } label: { Image(systemName: session.recordingState == .paused ? "play.fill" : "pause.fill") }
                    .help(session.recordingState == .paused ? "Resume" : "Pause")
                Button { NSApp.activate(); NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true || $0.isMainWindow }?.makeKeyAndOrderFront(nil) } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                    .help("Open Lectern")
                Button(action: onClose) { Image(systemName: "xmark") }.help("Close").keyboardShortcut("w", modifiers: .command)
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.secondary)
            .opacity(hovered ? 1 : 0)
        }
        .frame(height: 28)
    }

    private func quizStrip(_ quiz: LiveSessionModel.ActiveQuiz) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            HStack(spacing: DS.Space.xs) {
                DeadlineRing(deadline: quiz.deadline, paused: false)
                Text(quiz.question.prompt).font(DS.Typo.subheadline).lineLimit(1)
            }
            if case .multipleChoice(let options, _) = quiz.question.kind {
                HStack(spacing: DS.Space.xs) {
                    ForEach(Array(options.enumerated()), id: \.offset) { i, option in
                        Button { session.selectOption(i) } label: {
                            HStack(spacing: DS.Space.xxs) {
                                KeyCap(text: "\(i + 1)")
                                if i == 0 { Text(option).font(DS.Typo.caption).lineLimit(1) }
                            }
                            .padding(.horizontal, DS.Space.xs)
                            .frame(height: 24)
                            .background(quiz.selectedOption == i ? AnyShapeStyle(DS.Colors.accent) : AnyShapeStyle(.quaternary), in: RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .help(option)
                    }
                    Spacer()
                    Button("snooze") { session.snoozeQuiz() }.buttonStyle(.link).font(DS.Typo.footnote)
                    Button("skip") { session.skipQuiz() }.buttonStyle(.link).font(DS.Typo.footnote)
                }
            } else {
                Text("Answer in Lectern").font(DS.Typo.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func scheduleIdle() {
        idleTask?.cancel()
        idleTask = Task {
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled { idle = true }
        }
    }
}
