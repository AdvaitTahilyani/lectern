import SwiftUI
import LecternCore

/// The one session view, live or review (DESIGN.md §4.3–4.5, §4.9). Slides | Takeaways | inspector,
/// with responsive tiers driven by the detail column's width.
struct LiveSessionView: View {
    @Bindable var session: LiveSessionModel
    @Environment(AppModel.self) private var app
    @Environment(WindowNavigation.self) private var nav
    @Environment(\.dsAnimation) private var motion
    @State private var width: CGFloat = 0
    @State private var hasAppeared = false

    @State private var tier: LayoutTier = .three
    /// Inspector state to restore when leaving the single tier (which force-closes it).
    @State private var inspectorBeforeSingle = true
    /// Ignore split-view collapse callbacks for a moment after a programmatic change: AppKit reports
    /// intermediate collapsed states through the binding, which otherwise re-asserts the value
    /// (`_setCollapsed` ↔ `didChangeCollapsed` loop, QA H1).
    @State private var inspectorSettleUntil = Date.distantPast

    /// ⌘F in the single tier, where the transcript pane has no inspector to host its search bar.
    @State private var paneSearchShown = false

    @FocusState private var rootFocused: Bool

    var body: some View {
        SizeNeutral { content }
            // Session-wide keys (DESIGN §8): quiz 1–4 / S / Esc and Space to pause work whenever the
            // window has focus and no text field does; the root holds default focus so they never
            // depend on the quiz container itself being focused (QA F2).
            .focusable()
            .focusEffectDisabled()
            .focused($rootFocused)
            .onKeyPress(characters: .decimalDigits) { press in
                guard SessionShortcuts.singleKeysAllowed(textInputActive: TextInputFocus.isActive), let quiz = session.quiz, quiz.acceptsAnswers, let n = Int(press.characters), (1...4).contains(n) else { return .ignored }
                session.selectOption(n - 1)
                return .handled
            }
            .onKeyPress("s") { if session.quiz?.phase == .asking, SessionShortcuts.singleKeysAllowed(textInputActive: TextInputFocus.isActive) { session.snoozeQuiz(); return .handled }; return .ignored }
            .onKeyPress(.escape) { if session.quiz != nil, SessionShortcuts.singleKeysAllowed(textInputActive: TextInputFocus.isActive) { session.skipQuiz(); return .handled }; return .ignored }
            // ←/→ correct the current slide from anywhere in the lecture (the root holds focus).
            .onKeyPress(.leftArrow) {
                guard session.pageCount > 0, SessionShortcuts.singleKeysAllowed(textInputActive: TextInputFocus.isActive) else { return .ignored }
                session.stepSlide(-1)
                return .handled
            }
            .onKeyPress(.rightArrow) {
                guard session.pageCount > 0, SessionShortcuts.singleKeysAllowed(textInputActive: TextInputFocus.isActive) else { return .ignored }
                session.stepSlide(1)
                return .handled
            }
            .onKeyPress(.space) {
                guard SessionShortcuts.spacePausesRecording(isLive: session.isLive, textInputActive: TextInputFocus.isActive, rootFocused: rootFocused) else { return .ignored }
                session.togglePause()
                return .handled
            }
            .environment(\.openURL, OpenURLAction { url in session.open(url) ? .handled : .systemAction })
            .background(DS.Colors.canvas.ignoresSafeArea())
            // ⌘L is a second shortcut for Ask (⌘K in the Lecture menu).
            .background {
                Button("") { session.focusAsk() }.keyboardShortcut("l", modifiers: .command).opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
            }
            .navigationTitle(session.title)
            .navigationSubtitle(session.subtitle)
            .toolbar { SessionToolbar(session: session, tier: tier) }
            // Presentation is pure state (never derived from measured width) and is toggled with
            // animations disabled: an animated NSSplitViewItem collapse while AppKit-backed controls
            // inside stream updates exhausts AppKit's constraint-update budget and aborts.
            .inspector(isPresented: Binding(get: { session.isInspectorShown }, set: { v in
                guard v != session.isInspectorShown, Date.now >= inspectorSettleUntil else { return }
                setInspector(v)   // a user collapse/expand
            })) {
                SizeNeutral { InspectorView(session: session) }
                    .inspectorColumnWidth(min: DS.Layout.inspector.min, ideal: DS.Layout.inspector.ideal, max: DS.Layout.inspector.max)
            }
            // Tier is measured on the whole detail column (inspector included) so showing or
            // hiding the inspector can never feed back into the tier.
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { w in
                guard w > 100, w != width else { return }
                let first = width <= 100
                width = w
                let new = first ? LayoutTier.forWidth(w) : LayoutTier.forWidth(w, current: tier)
                guard new != tier else { return }
                let old = tier
                tier = new
                if !first, hasAppeared { tierChanged(from: old, to: new) }
            }
            .onChange(of: session.showSlides) { _, v in app.updatePreferences { $0.slidesVisible = v } }
            .onDisappear { Task { await session.flush() } }
            .onAppear {
                applyPendingNavigation()
                Task { @MainActor in await Task.yield(); rootFocused = true }
                Task { try? await Task.sleep(for: .seconds(1)); hasAppeared = true }
            }
            // A search hit or citation into the lecture already on screen (QA Q3-8).
            .onChange(of: nav.pendingNavigation) { _, _ in applyPendingNavigation() }
            // Session-wide keys need the root focused again once a text field lets go (QA F2).
            .onChange(of: session.isTypingInAsk) { _, typing in
                if !typing { Task { @MainActor in try? await Task.sleep(for: .milliseconds(80)); rootFocused = true } }
            }
            .onChange(of: session.focusRootRequest) { _, _ in
                Task { @MainActor in try? await Task.sleep(for: .milliseconds(80)); rootFocused = true }
            }
            .onChange(of: tier) { _, t in session.layoutTier = t }
            // The title editor lives in the Takeaways header; bring that pane up in the compact tier.
            .onChange(of: session.isEditingTitle) { _, editing in if editing, tier == .single { session.pane = .takeaways } }
            .onChange(of: session.pane) { _, pane in if pane != .transcript { paneSearchShown = false } }
            .onWindowCommand(.lecternFind) {
                guard tier == .single else { return }   // the inspector's transcript handles it otherwise
                session.pane = .transcript
                // The pane is created by the switch; its search field takes focus when shown on the next turn.
                Task { @MainActor in await Task.yield(); paneSearchShown = true }
            }
            .onWindowCommand(.lecternExport) {
                guard !session.isLive else { return }
                ExportCoordinator.exportMarkdown(session: session.session, course: session.course)
            }
            .focusedSceneValue(\.liveSession, session)
    }

    @ViewBuilder private var content: some View {
        switch tier {
        case .three:
            HStack(spacing: 0) {
                if session.showSlides {
                    SlidesColumn(session: session)
                        .frame(width: DS.Layout.slidesColumn.ideal)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                    Divider()
                }
                TakeawaysColumn(session: session, tier: tier)
                    .frame(minWidth: DS.Layout.takeawaysMin)
            }
        case .two:
            TakeawaysColumn(session: session, tier: tier)
        case .single:
            singlePane
        }
    }

    /// Ask stays mounted behind the other panes so ⌘K can focus its composer in the same update
    /// (a pane created on demand dropped the first keystrokes, QA F1).
    private var singlePane: some View {
        ZStack {
            switch session.pane {
            case .takeaways: TakeawaysColumn(session: session, tier: tier)
            case .transcript: TranscriptView(session: session, showSearch: $paneSearchShown)
            case .slides: SlidesColumn(session: session)
            case .ask: Color.clear
            }
            AskView(session: session, isActive: session.pane == .ask)
                .paneVisible(session.pane == .ask)
        }
    }

    private func tierChanged(from old: LayoutTier, to new: LayoutTier) {
        if new == .single {
            inspectorBeforeSingle = session.isInspectorShown
            setInspector(false, persist: false)
            if session.isLive, !app.preferences.hasSeenSinglePaneTip {
                app.updatePreferences { $0.hasSeenSinglePaneTip = true }
                session.showFocusPanelTip()
            }
        } else if old == .single {
            setInspector(inspectorBeforeSingle, persist: false)
        }
    }

    /// Shows/hides the inspector without the split-view animation (see the `.inspector` note).
    private func setInspector(_ shown: Bool, persist: Bool = true) {
        guard session.isInspectorShown != shown else { return }
        inspectorSettleUntil = Date.now.addingTimeInterval(0.8)
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { session.isInspectorShown = shown }
        if persist { app.updatePreferences { $0.inspectorVisible = shown } }
    }

    private func applyPendingNavigation() {
        if let landing = nav.takePendingNavigation(for: session.id) { session.navigate(to: landing) }
    }
}

// MARK: - Focused value for commands

extension FocusedValues {
    @Entry var liveSession: LiveSessionModel?
}

// MARK: - Toolbar

struct SessionToolbar: ToolbarContent {
    @Bindable var session: LiveSessionModel
    var tier: LayoutTier
    @Environment(AppModel.self) private var app

    var body: some ToolbarContent {
        if tier == .single {
            ToolbarItem(placement: .principal) {
                Picker("Pane", selection: $session.pane) {
                    ForEach(SessionPane.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
                .frame(width: 270)
            }
        }
        ToolbarSpacer(.flexible)
        ToolbarItemGroup(placement: .primaryAction) {
            if session.isLive {
                LiveSessionClock(session: session)
                Button { session.togglePause() } label: {
                    Label(session.recordingState == .paused ? "Resume" : "Pause", systemImage: session.recordingState == .paused ? "play.fill" : "pause.fill")
                }
                .help(session.recordingState == .paused ? "Resume (⌘⇧P)" : "Pause (⌘⇧P)")
                .disabled(session.recordingState == .finishing)
                Button { session.showStopConfirmation = true } label: {
                    Label("Stop", systemImage: "stop.fill").foregroundStyle(DS.Colors.recording)
                }
                .help("Stop… (⌘.)")
                .popover(isPresented: $session.showStopConfirmation, arrowEdge: .bottom) { StopPopover(session: session) }
            } else {
                StatsCapsule(duration: session.session.duration, takeaways: session.settledTakeaways.count, score: session.quizScore, sessionID: session.id)
            }
        }
        ToolbarSpacer(.fixed)
        ToolbarItemGroup(placement: .primaryAction) {
            Button { session.focusAsk() } label: { Label("Ask", systemImage: "sparkle.magnifyingglass") }
                .help("Ask (⌘K)")
            if session.isLive {
                Button { app.toggleFocusPanel() } label: { Label("Focus panel", systemImage: "rectangle.inset.topright.filled") }
                    .help("Toggle Focus panel (⌘⇧F)")
                    .background(session.isFocusPanelOpen ? DS.Colors.accent.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous))
            } else {
                Menu {
                    Button("Markdown Notes…") { ExportCoordinator.exportMarkdown(session: session.session, course: session.course) }
                    Button("PDF…") { ExportCoordinator.exportPDF(session: session.session, course: session.course) }
                    Divider()
                    Button("Copy Summary") { session.copySummary() }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .help("Export (⌘E)")
            }
            if session.quiz == nil, !session.queuedQuizzes.isEmpty {
                Button { session.openPendingQuiz() } label: { Label("Quiz", systemImage: "questionmark.circle") }
                    .badge(session.queuedQuizzes.count)
                    .help(session.queuedQuizzes.count == 1 ? "A quick check is waiting" : "\(session.queuedQuizzes.count) quick checks are waiting")
            }
            Button { session.toggleInspector() } label: { Label("Inspector", systemImage: "sidebar.trailing") }
                .help("Toggle inspector (⌘⌥I)")
                .disabled(tier == .single)
            Menu {
                Button(session.showSlides ? "Hide Slides" : "Show Slides") { withAnimation(DS.Motion.settle) { session.showSlides.toggle() } }
                if session.isLive {
                    Toggle("Follow Slides", isOn: Binding(get: { session.followSlides }, set: { if $0 { session.resumeFollowing() } else { session.selectSlide(session.displayedSlide ?? 1) } }))
                    Menu("Quiz Frequency") {
                        ForEach([0.0, 5, 10, 15, 20], id: \.self) { m in
                            Button(m == 0 ? "Off" : "\(Int(m)) min") {
                                app.updateSettings { $0.quiz.enabled = m > 0; if m > 0 { $0.quiz.intervalMinutes = m } }
                            }
                        }
                    }
                }
                if !session.isLive {
                    // The title editor only exists in review (it is in the Takeaways header there).
                    Divider()
                    Button("Edit Title") { session.isEditingTitle = true }
                }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
        }
    }
}

/// The toolbar clock, split out so the once-a-second `elapsed` tick re-renders only the clock
/// and not the whole toolbar.
private struct LiveSessionClock: View {
    var session: LiveSessionModel
    var body: some View {
        SessionClock(elapsed: session.elapsed, state: session.recordingState) { session.togglePause() }
    }
}

/// "Finish this lecture?" — a popover, never an alert.
struct StopPopover: View {
    var session: LiveSessionModel
    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            Text("Finish this lecture?").font(DS.Typo.headline)
            Text("Recording stops and Lectern writes the final summary.").font(DS.Typo.subheadline).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Keep Going") { session.showStopConfirmation = false }.keyboardShortcut(.cancelAction)
                Button("Finish & Summarize") { session.finish() }.lecternProminent().keyboardShortcut(.defaultAction)
            }
        }
        .padding(DS.Space.l)
        .frame(width: 320)
        .background {
            // ⌘↩ also finishes (DESIGN §8); a button can carry only one shortcut.
            Button("") { session.finish() }.keyboardShortcut(.return, modifiers: .command).opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
        }
    }
}

// MARK: - Inspector

struct InspectorView: View {
    @Bindable var session: LiveSessionModel
    @State private var showSearch = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: DS.Space.s) {
                SegmentedTabs(selection: $session.inspectorTab, tabs: session.isLive ? [.transcript, .ask] : [.transcript, .ask, .quiz])
                Button { withAnimation(DS.Motion.quick) { showSearch.toggle() } } label: { Image(systemName: "magnifyingglass") }
                    .buttonStyle(.borderless)
                    .help("Find in transcript (⌘F)")
                    .disabled(session.inspectorTab != .transcript)
            }
            .padding(.horizontal, DS.Space.m)
            .padding(.vertical, DS.Space.s)
            Divider()
            // Transcript and Ask stay mounted (hidden, not removed) so ⌘F / ⌘K can focus their
            // fields in the same update the tab switches; a tab created on demand could only focus
            // on a later turn and dropped the first keystrokes (QA F1).
            ZStack {
                TranscriptView(session: session, showSearch: $showSearch)
                    .paneVisible(session.inspectorTab == .transcript)
                AskView(session: session, isActive: session.inspectorTab == .ask)
                    .paneVisible(session.inspectorTab == .ask)
                if session.inspectorTab == .quiz { QuizTabView(session: session) }
            }
        }
        .onChange(of: session.inspectorTab) { _, tab in if tab != .transcript { showSearch = false } }
        .onWindowCommand(.lecternFind) {
            session.inspectorTab = .transcript
            showSearch = true
        }
        .onChange(of: session.isLive) { _, live in if live, session.inspectorTab == .quiz { session.inspectorTab = .transcript } }
    }
}

extension View {
    /// Shows or hides a pane that stays in the hierarchy: invisible, untouchable and out of the
    /// accessibility tree while hidden (never `.hidden()`, which AppKit refuses focus into).
    func paneVisible(_ shown: Bool) -> some View {
        opacity(shown ? 1 : 0)
            .allowsHitTesting(shown)
            .accessibilityHidden(!shown)
    }
}

/// SwiftUI-drawn segmented control for the inspector header. (An `NSSegmentedControl` inside the
/// inspector column re-runs AppKit two-pass constraint updates while the column animates.)
struct SegmentedTabs: View {
    @Binding var selection: InspectorTab
    var tabs: [InspectorTab]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(tabs) { tab in
                Button { withAnimation(DS.Motion.quick) { selection = tab } } label: {
                    Text(tab.label)
                        .font(DS.Typo.subheadline.weight(selection == tab ? .semibold : .regular))
                        .padding(.horizontal, DS.Space.m)
                        .frame(height: 22)
                        .background(selection == tab ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == tab ? [.isSelected] : [])
            }
        }
        .padding(2)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Inspector tab")
    }
}

/// Inline title editor in the Takeaways header (⌘⇧T in review). It is always mounted; `isActive`
/// shows it and moves focus into it synchronously. Return saves, Escape cancels, and focus leaving
/// the field saves too.
struct TitleEditor: View {
    var session: LiveSessionModel
    var isActive: Bool
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Lecture title", text: $draft)
            .textFieldStyle(.roundedBorder)
            .frame(width: 340, height: 22)
            .focused($focused)
            .onSubmit { commit() }
            .onKeyPress(.escape) { session.isEditingTitle = false; return .handled }
            .onChange(of: isActive) { _, active in
                if active {
                    draft = session.title
                    focused = true
                } else {
                    focused = false
                }
            }
            .onChange(of: focused) { _, f in if !f, isActive { commit() } }
            // Created already active (⌘⇧T brought the Takeaways pane up in the compact tier): the
            // field exists on the next turn.
            .onAppear {
                guard isActive else { return }
                draft = session.title
                Task { @MainActor in await Task.yield(); focused = true }
            }
            .accessibilityLabel("Lecture title")
    }

    private func commit() {
        session.setTitle(draft)
        session.isEditingTitle = false
    }
}
