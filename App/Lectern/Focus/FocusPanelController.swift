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
    private var saveOriginTask: Task<Void, Never>?

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
        // The saved position is the panel's top-left corner: its height changes with the quiz
        // strip (and `resize` keeps the top fixed), so a bottom-left origin would reopen offset.
        if let topLeft = app.preferences.focusPanelOrigin, NSScreen.screens.contains(where: { $0.frame.contains(CGPoint(x: topLeft.x + 20, y: topLeft.y - 20)) }) {
            panel.setFrameTopLeftPoint(topLeft)
        } else if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameTopLeftPoint(NSPoint(x: frame.maxX - DS.Layout.focusPanel.width - 20, y: frame.maxY - 20))
        }
        // didMove fires for every drag step; persist the resting position once the drag settles.
        moveObserver = NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { [weak self, weak panel] _ in
            MainActor.assumeIsolated {
                guard let self, let frame = panel?.frame else { return }
                let topLeft = CGPoint(x: frame.minX, y: frame.maxY)
                self.saveOriginTask?.cancel()
                self.saveOriginTask = Task {
                    try? await Task.sleep(for: .milliseconds(400))
                    guard !Task.isCancelled else { return }
                    app.updatePreferences { $0.focusPanelOrigin = topLeft }
                }
            }
        }
        // Assigned before the panel is shown: the hosted view asks for its size as soon as it appears.
        self.panel = panel
        self.session = session
        panel.orderFrontRegardless()
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
        .onChange(of: panelSize, initial: true) { _, size in onResize(size) }
        .lecternGlass(.regular, in: .rect(cornerRadius: DS.Radius.panel))
        .opacity(idle && !hovered && session.quiz == nil && app.preferences.focusPanelDimWhenIdle ? 0.85 : 1)
        .animation(DS.Motion.quick, value: idle)
        .onHover { h in
            hovered = h
            if h { idle = false; idleTask?.cancel() } else { scheduleIdle() }
        }
        .onAppear { scheduleIdle() }
        .onKeyPress(characters: .decimalDigits) { press in
            guard SessionShortcuts.singleKeysAllowed(textInputActive: TextInputFocus.isActive), let quiz = session.quiz, quiz.phase == .asking, let n = Int(press.characters), (1...4).contains(n) else { return .ignored }
            session.selectOption(n - 1)
            return .handled
        }
        .onKeyPress(.escape) { guard SessionShortcuts.singleKeysAllowed(textInputActive: TextInputFocus.isActive), session.quiz != nil else { return .ignored }; session.skipQuiz(); return .handled }
        .onKeyPress("s") { guard SessionShortcuts.singleKeysAllowed(textInputActive: TextInputFocus.isActive), session.quiz?.phase == .asking else { return .ignored }; session.snoozeQuiz(); return .handled }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Focus panel")
    }

    /// The base panel, plus the quiz strip (and its divider) while a question is waiting for an answer.
    /// The strip's height is computed from the question (fixed-height rows), never measured: the panel is
    /// resized explicitly, and a measured size feeding the panel's own frame is the loop the controller avoids.
    private var panelSize: CGSize {
        guard let quiz = session.quiz, quiz.phase == .asking else { return DS.Layout.focusPanel }
        return CGSize(width: DS.Layout.focusPanel.width, height: DS.Layout.focusPanel.height + Self.quizStripHeight(for: quiz.question) + DS.Space.s * 2 + 1)
    }

    private static let stripHeaderHeight: CGFloat = 20
    private static let stripPromptHeight: CGFloat = 34
    private static let optionRowHeight: CGFloat = 34
    private static let maxOptionRows = 6

    /// Header, prompt (two lines) and one fixed-height row per option, with the strip's spacing.
    static func quizStripHeight(for question: QuizQuestion) -> CGFloat {
        let gap = DS.Space.xs
        let head = stripHeaderHeight + gap + stripPromptHeight + gap
        switch question.kind {
        case .multipleChoice(let options, _):
            let rows = CGFloat(min(options.count, maxOptionRows))
            return head + rows * optionRowHeight + max(0, rows - 1) * (DS.Space.xxs + 2)
        case .shortAnswer:
            return head + 16
        }
    }

    private var header: some View {
        HStack(spacing: DS.Space.s) {
            LiveDot(state: session.recordingState == .paused ? .paused : .recording, size: DS.Size.liveDotSmall).accessibilityHidden(true)
            Text(TimeFormat.clock(session.elapsed)).font(DS.Typo.mono).contentTransition(.numericText())
            Text(session.courseLabel).font(DS.Typo.caption).foregroundStyle(.secondary)
            Spacer()
            HStack(spacing: DS.Space.xs) {
                Button { session.togglePause() } label: { Image(systemName: session.recordingState == .paused ? "play.fill" : "pause.fill") }
                    .help(session.recordingState == .paused ? "Resume" : "Pause")
                Button {
                    showMainWindow { app.openMainWindow?() }
                    if app.activeNavigation.visibleSessionID != session.id { app.openSession(session.id) }
                } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
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
                Text("Quick check").font(DS.Typo.caption).fontWeight(.semibold).foregroundStyle(.secondary)
                if !session.queuedQuizzes.isEmpty {
                    Text("+\(session.queuedQuizzes.count) more").font(DS.Typo.footnote).foregroundStyle(.tertiary)
                }
                Spacer()
                Button("Snooze") { session.snoozeQuiz() }.help("Ask again in 5 minutes (S)")
                Button("Skip") { session.skipQuiz() }.help("Skip this question (Esc)")
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.mini)
            .frame(height: Self.stripHeaderHeight)
            Text(quiz.question.prompt).font(DS.Typo.subheadline).lineLimit(2)
                .frame(maxWidth: .infinity, minHeight: Self.stripPromptHeight, maxHeight: Self.stripPromptHeight, alignment: .topLeading)
            if case .multipleChoice(let options, _) = quiz.question.kind {
                VStack(spacing: DS.Space.xxs + 2) {
                    ForEach(Array(options.prefix(Self.maxOptionRows).enumerated()), id: \.offset) { i, option in
                        Button { session.selectOption(i) } label: {
                            HStack(alignment: .firstTextBaseline, spacing: DS.Space.xs) {
                                KeyCap(text: "\(i + 1)").foregroundStyle(quiz.selectedOption == i ? .white : .primary)
                                Text(option).font(DS.Typo.caption).lineLimit(2).multilineTextAlignment(.leading)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, DS.Space.xs)
                            .frame(height: Self.optionRowHeight)
                            .foregroundStyle(quiz.selectedOption == i ? .white : .primary)
                            .background(quiz.selectedOption == i ? AnyShapeStyle(DS.Colors.accent) : AnyShapeStyle(.quaternary), in: RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .help(option)
                        .accessibilityLabel("Option \(i + 1): \(option)")
                    }
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
