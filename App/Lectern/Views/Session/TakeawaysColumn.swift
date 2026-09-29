import SwiftUI
import LecternCore

/// Center column: takeaway list with the docked glass Now card, quiz ping, recap card and
/// "Jump to live" pill (DESIGN.md §4.4, §4.6, §4.9, §4.12).
struct TakeawaysColumn: View {
    @Bindable var session: LiveSessionModel
    var tier: LayoutTier
    @Environment(AppModel.self) private var app
    @Environment(\.dsAnimation) private var motion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var namespace
    /// Whether the list should keep revealing new content (the user is "at the bottom").
    /// Only a user scroll changes it; content or dock growth never does.
    @State private var followLive = true
    @State private var newSinceUnpinned = 0
    @State private var programmaticScrollUntil = Date.distantPast
    @State private var lastSeenSettled = 0
    @State private var focusedID: UUID?
    @State private var scrollTarget: UUID?
    @State private var firstMinuteHint = false
    @FocusState private var listFocused: Bool

    var body: some View {
        if let flow = session.reviewFlow {
            ReviewMissedView(session: session, flow: flow)
        } else {
            column
        }
    }

    private var column: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: DS.Space.m) {
                    if let notice = session.notice(for: .takeaways) {
                        NoticeBanner(notice: notice, action: notice.id == "focus-tip" ? { app.toggleFocusPanel(); session.dismissNotice(notice.id) } : nil, onClose: { session.dismissNotice(notice.id) })
                    }
                    if let recap = session.recap { RecapCard(state: recap, session: session, thumbnail: { session.slideImages?.image(page: $0, width: 64) }) }
                    if !session.isLive { summaryCard }
                    ForEach(session.settledTakeaways) { t in
                        TakeawayCard(
                            takeaway: t, state: .settled,
                            isExpanded: session.expandedTakeawayID == t.id,
                            isFocused: focusedID == t.id && listFocused,
                            quizMarker: session.quizMarker(for: t),
                            thumbnail: { session.slideImages?.image(page: $0, width: DS.Size.cardThumb.width) },
                            onToggleExpand: { toggle(t) },
                            onShowSlide: { session.showSlide($0) },
                            onSeek: { session.seekTranscript(to: $0) },
                            onAsk: { session.focusAsk(seed: "Explain: \(t.title)") },
                            onCopy: { session.copyMarkdown(for: t) },
                            onFindTerm: { term in session.seekTranscript(to: session.transcript.first { $0.text.localizedCaseInsensitiveContains(term) }?.start ?? t.start) }
                        )
                        .matchedGeometryEffect(id: t.id, in: namespace)
                        .id(t.id)
                    }
                    if session.isLive, session.settledTakeaways.isEmpty, firstMinuteHint {
                        Text("Still listening — first takeaway usually appears after a couple of minutes.")
                            .font(DS.Typo.footnote).foregroundStyle(.secondary).padding(.top, DS.Space.xl)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .frame(maxWidth: DS.Layout.readingMaxWidth + 2 * DS.Space.l)
                .padding(.horizontal, DS.Space.l)
                .padding(.vertical, DS.Space.m)
                .frame(maxWidth: .infinity)
                .animation(motion.settle, value: session.settledTakeaways.map(\.id))
            }
            .defaultScrollAnchor(.bottom)
            .onScrollGeometryChange(for: ScrollSnapshot.self) { ScrollSnapshot($0) } action: { old, new in
                if new.contentHeight == old.contentHeight, new.bottomInset == old.bottomInset {
                    // Offsets caused by our own scrollTo (within the last 0.6 s) are not user intent.
                    if Date.now < programmaticScrollUntil { if new.isAtBottom { newSinceUnpinned = 0 }; return }
                    // Only the offset moved: the user scrolled.
                    followLive = new.isAtBottom
                    if followLive { newSinceUnpinned = 0 }
                } else if followLive {
                    scrollToBottomSoon(proxy)
                }
            }
            .onChange(of: session.settledCount) { _, count in
                if followLive { scrollToBottomSoon(proxy) } else { newSinceUnpinned += count - lastSeenSettled }
                lastSeenSettled = count
            }
            .onChange(of: scrollTarget) { _, id in if let id { proxy.scrollSoon(to: id, anchor: .center, animation: motion.settle) } }
            // The dock grows/shrinks with the quiz card and the recap card appears at the top;
            // keep the newest card visible when the user was already at the bottom.
            .onChange(of: session.quiz?.question.id) { _, _ in if followLive { scrollToBottomSoon(proxy) } }
            .onChange(of: session.recap == nil) { _, _ in if followLive { scrollToBottomSoon(proxy) } }
            .onAppear { lastSeenSettled = session.settledCount; scrollToBottomSoon(proxy) }
            .onReceive(NotificationCenter.default.publisher(for: .lecternJumpToLive)) { _ in jumpToLive(proxy) }
            .safeAreaInset(edge: .top, spacing: 0) { header }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if session.isLive { dock }
            }
            // The pill floats over the scroll content so showing/hiding it never changes the
            // scroll insets (a layout feedback loop otherwise: geometry → pinned → inset → geometry).
            .overlay(alignment: .bottom) {
                if !followLive, newSinceUnpinned > 0 {
                    JumpToLivePill(newCount: newSinceUnpinned) { jumpToLive(proxy) }
                        .padding(.bottom, DS.Space.m)
                        .animation(motion.quick, value: newSinceUnpinned)
                }
            }
        }
        .focusable()
        .focused($listFocused)
        .focusSection()
        .onKeyPress(.downArrow) { moveFocus(1); return .handled }
        .onKeyPress(.upArrow) { moveFocus(-1); return .handled }
        .onKeyPress(.return) { if let t = focusedTakeaway { toggle(t); return .handled }; return .ignored }
        .onKeyPress(.space) { if let t = focusedTakeaway { toggle(t); return .handled }; if session.isLive { session.togglePause(); return .handled }; return .ignored }
        .onKeyPress(.escape) {
            if session.quiz != nil { session.skipQuiz(); return .handled }
            if session.expandedTakeawayID != nil { session.expandTakeaway(nil); return .handled }
            return .ignored
        }
        .onKeyPress(characters: .decimalDigits) { press in
            guard let quiz = session.quiz, quiz.acceptsAnswers, let n = Int(press.characters), (1...4).contains(n), !session.isTypingInAsk else { return .ignored }
            session.selectOption(n - 1)
            return .handled
        }
        .onKeyPress("s") { if session.quiz?.phase == .asking, !session.isTypingInAsk { session.snoozeQuiz(); return .handled }; return .ignored }
        .task {
            try? await Task.sleep(for: .seconds(45))
            if session.settledTakeaways.isEmpty { withAnimation(motion.morph) { firstMinuteHint = true } }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: DS.Space.s) {
            Text("Takeaways").columnHeaderStyle()
            if !session.settledTakeaways.isEmpty {
                Text("\(session.settledTakeaways.count)").font(DS.Typo.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, DS.Space.xs).background(.quaternary, in: Capsule()).contentTransition(.numericText())
            }
            if tier == .two, session.pageCount > 0 { CurrentSlideChip(session: session) }
            Spacer()
            if session.isFocusPanelOpen {
                Image(systemName: "rectangle.inset.topright.filled").font(.caption).foregroundStyle(.secondary).help("Focus panel open")
            }
            if session.isLive || session.isBusy {
                HStack(spacing: DS.Space.xs) {
                    Image(systemName: "waveform").symbolEffect(.variableColor.iterative.reversing, isActive: session.isBusy && !reduceMotion)
                    Text(session.activityLabel).lineLimit(1).fixedSize()
                }
                .font(DS.Typo.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, DS.Space.l)
        .frame(height: 36)
        .background(DS.Colors.canvas)
    }

    // MARK: Dock (Now card + quiz)

    private var dock: some View {
        VStack(spacing: DS.Space.m) {
            LecternGlassContainer(spacing: DS.Space.m) {
                VStack(spacing: DS.Space.m) {
                    if let quiz = session.quiz {
                        QuizCard(
                            quiz: quiz, streak: session.streak, showStreak: app.preferences.showStreaks, sessionID: session.id,
                            thumbnail: { session.slideImages?.image(page: $0, width: 32) },
                            onSelect: { session.selectOption($0) },
                            onShortAnswerChange: { session.updateShortAnswer($0) },
                            onSubmitShort: { session.submitShortAnswer() },
                            onSnooze: { session.snoozeQuiz() }, onSkip: { session.skipQuiz() }, onDismiss: { session.dismissQuiz() },
                            onHover: { session.setQuizHovered($0) },
                            onOpenURL: { _ = session.open($0) },
                            compactWidth: tier == .single
                        )
                        .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                    }
                    nowCard
                        .lecternGlass(.regular, in: .rect(cornerRadius: DS.Radius.float))
                }
            }
            .frame(maxWidth: DS.Layout.readingMaxWidth + 2 * DS.Space.l)
        }
        .padding(.horizontal, DS.Space.floatInset)
        .padding(.bottom, DS.Space.floatInset)
        .frame(maxWidth: .infinity)
        .animation(motion.float, value: session.quiz?.question.id)
    }

    @ViewBuilder private var nowCard: some View {
        if let live = session.liveTakeaway {
            TakeawayCard(takeaway: live, state: .live(elapsed: max(0, session.elapsed - live.start)), compact: session.quiz != nil)
                .matchedGeometryEffect(id: live.id, in: namespace)
        } else if session.settledTakeaways.isEmpty {
            HStack(spacing: DS.Space.m) {
                LiveDot(state: session.recordingState == .paused ? .paused : .recording, size: DS.Size.liveDotSmall)
                Text(session.recordingState == .paused ? "Paused" : "Listening…").font(DS.Typo.subheadline).foregroundStyle(.secondary)
                Spacer()
                LevelMeter(level: session.level, peak: session.level, width: 80)
            }
            .padding(.horizontal, DS.Space.l).padding(.vertical, DS.Space.m)
        } else {
            TakeawayCard(takeaway: nil, state: .placeholder)
        }
    }

    // MARK: Summary (review)

    @ViewBuilder private var summaryCard: some View {
        switch session.summaryState {
        case .writing:
            VStack(alignment: .leading, spacing: DS.Space.s) {
                HStack(spacing: DS.Space.s) {
                    Image(systemName: "waveform").symbolEffect(.variableColor.iterative.reversing, isActive: !reduceMotion).foregroundStyle(.secondary)
                    Text("Writing summary…").font(DS.Typo.footnote).foregroundStyle(.secondary)
                }
                Text("Placeholder summary text that reserves the card's height while the model writes the real overview of the lecture.")
                    .font(DS.Typo.subheadline).lineLimit(3).redacted(reason: .placeholder)
            }
            .padding(.horizontal, DS.Space.l).padding(.vertical, DS.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .surfaceCard()
        case .ready:
            if let s = session.summary {
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    HStack(spacing: DS.Space.s) {
                        Image(systemName: "sparkles").foregroundStyle(DS.Colors.accent)
                        Text("Lecture summary").font(DS.Typo.headline)
                        Spacer()
                        Button { session.copySummary() } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless).controlSize(.small).help("Copy summary (⌘⇧C)")
                    }
                    Text(s.summary).font(DS.Typo.body).lineSpacing(DS.Typo.summaryLineSpacing).fixedSize(horizontal: false, vertical: true)
                    if let terms = s.detail?.keyTerms, !terms.isEmpty {
                        HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
                            Text("Key terms").font(DS.Typo.caption).foregroundStyle(.secondary)
                            FlowLayout(spacing: DS.Space.xs) {
                                ForEach(terms) { k in
                                    TermChip(term: k) {
                                        if let t = session.takeaways.first(where: { $0.detail?.keyTerms.contains(where: { $0.term == k.term }) == true || $0.summary.localizedCaseInsensitiveContains(k.term) }) { scrollTarget = t.id }
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, DS.Space.l).padding(.vertical, DS.Space.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .surfaceCard()
                .transition(.opacity)
            }
        case .failed(let message):
            HStack(spacing: DS.Space.s) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(DS.Colors.warning)
                Text("Couldn't write the summary — \(message)").font(DS.Typo.subheadline)
                Spacer()
                Button("Try again") { session.retrySummary() }.controlSize(.small)
            }
            .padding(.horizontal, DS.Space.l).padding(.vertical, DS.Space.m)
            .surfaceCard()
        case .none:
            EmptyView()
        }
    }

    // MARK: Helpers

    private var focusedTakeaway: Takeaway? { session.settledTakeaways.first { $0.id == focusedID } }

    private func toggle(_ t: Takeaway) {
        focusedID = t.id
        session.expandTakeaway(session.expandedTakeawayID == t.id ? nil : t.id)
    }

    private func moveFocus(_ delta: Int) {
        let list = session.settledTakeaways
        guard !list.isEmpty else { return }
        let i = list.firstIndex { $0.id == focusedID } ?? (delta > 0 ? -1 : list.count)
        let next = min(max(0, i + delta), list.count - 1)
        focusedID = list[next].id
        scrollTarget = focusedID
    }

    private func scrollToBottomSoon(_ proxy: ScrollViewProxy) {
        programmaticScrollUntil = Date.now.addingTimeInterval(0.6)
        proxy.scrollSoon(to: "bottom", anchor: .bottom, animation: reduceMotion ? nil : motion.settle)
    }

    private func jumpToLive(_ proxy: ScrollViewProxy) {
        followLive = true
        newSinceUnpinned = 0
        scrollToBottomSoon(proxy)
    }
}

// MARK: - Recap card ("While you were away")

struct RecapCard: View {
    var state: LiveSessionModel.RecapState
    var session: LiveSessionModel
    var thumbnail: (Int) -> NSImage?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(spacing: DS.Space.s) {
                Image(systemName: "clock.arrow.circlepath").foregroundStyle(DS.Colors.accent)
                Text("While you were away").font(DS.Typo.caption).fontWeight(.semibold).tracking(0.5).foregroundStyle(.secondary).textCase(.uppercase)
                Spacer()
                Text(rangeLabel).font(DS.Typo.mono).foregroundStyle(.secondary)
                Button { session.dismissRecap() } label: { Image(systemName: "xmark").font(.caption2) }.buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Dismiss")
            }
            switch state {
            case .loading:
                Text("Catching you up on what the lecture covered while you were away.").font(DS.Typo.headline).redacted(reason: .placeholder)
                Text("Two or three bullets summarizing the missed stretch will appear here in a moment.").font(DS.Typo.subheadline).redacted(reason: .placeholder)
                    .shimmering(active: !reduceMotion)
            case .ready(let r):
                Text(r.headline).font(DS.Typo.headline).fixedSize(horizontal: false, vertical: true)
                ForEach(Array(r.bullets.enumerated()), id: \.offset) { _, b in
                    HStack(alignment: .firstTextBaseline, spacing: DS.Space.xs) {
                        Text("•").frame(width: 10, alignment: .leading)
                        Text(b).fixedSize(horizontal: false, vertical: true)
                    }
                    .font(DS.Typo.subheadline).foregroundStyle(.secondary)
                }
                ForEach(Array(r.flagged.enumerated()), id: \.offset) { _, f in
                    HStack(alignment: .firstTextBaseline, spacing: DS.Space.xs) {
                        Image(systemName: "flag.fill").font(.caption2).foregroundStyle(DS.Colors.warning)
                        Text(f).font(DS.Typo.subheadline).fontWeight(.medium).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, DS.Space.s).padding(.vertical, DS.Space.xs)
                    .background(DS.Colors.warning.opacity(0.12), in: RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous))
                }
                HStack(spacing: DS.Space.s) {
                    if let first = r.slides.first { SlideChip(page: first, endPage: r.slides.last) { session.showSlide(first) } }
                    Spacer()
                    Button("Show in transcript") { session.seekTranscript(to: r.from) }.buttonStyle(.link).font(DS.Typo.footnote)
                    Button("Dismiss") { session.dismissRecap() }.buttonStyle(.link).font(DS.Typo.footnote)
                }
            case .failed(let message):
                Text("Couldn't build a recap — \(message)").font(DS.Typo.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(DS.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .lecternGlass(.regular, in: .rect(cornerRadius: DS.Radius.float))
        .transition(.move(edge: .top).combined(with: .opacity))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("While you were away")
    }

    private var rangeLabel: String {
        let range: (TimeInterval, TimeInterval)?
        switch state {
        case .loading(let from, let to): range = (from, to)
        case .ready(let r): range = (r.from, r.to)
        case .failed: range = nil
        }
        guard let (f, t) = range else { return "" }
        let minutes = max(1, Int(((t - f) / 60).rounded()))
        return "Away \(minutes) min · \(TimeFormat.clock(f))–\(TimeFormat.clock(t))"
    }
}

/// Subtle horizontal shimmer for redacted placeholders.
struct Shimmering: ViewModifier {
    var active: Bool
    @State private var phase: CGFloat = -1
    func body(content: Content) -> some View {
        content.overlay {
            if active {
                LinearGradient(colors: [.clear, .white.opacity(0.35), .clear], startPoint: .leading, endPoint: .trailing)
                    .offset(x: phase * 300)
                    .blendMode(.plusLighter)
                    .animation(.linear(duration: 1.4).repeatForever(autoreverses: false), value: phase)
                    .onAppear { phase = 1 }
                    .allowsHitTesting(false)
            }
        }
        .clipped()
    }
}

extension View {
    func shimmering(active: Bool) -> some View { modifier(Shimmering(active: active)) }
}
