import SwiftUI
import LecternCore

/// Transcript tab: paragraphs with timestamp gutters, volatile shimmer, speaker treatment,
/// search, auto-scroll and "Jump to live" (DESIGN.md §4.4, §4.15).
struct TranscriptView: View {
    @Bindable var session: LiveSessionModel
    var showSearch: Binding<Bool>? = nil
    @Environment(\.dsAnimation) private var motion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var followLive = true
    @State private var newSinceUnpinned = 0
    @State private var programmaticScrollUntil = Date.distantPast
    @State private var lastParagraphCount = 0
    @State private var query = ""
    @State private var hitIndex = 0
    @State private var flashID: UUID?
    @State private var popoverTime: TimeInterval?
    @FocusState private var searchFocused: Bool

    private var searchShown: Bool { showSearch?.wrappedValue ?? false }

    var body: some View {
        VStack(spacing: 0) {
            if searchShown { searchField }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: DS.Space.l) {
                        if let notice = session.notice(for: .transcript) {
                            NoticeBanner(notice: notice, action: { session.dismissNotice(notice.id) }, onClose: { session.dismissNotice(notice.id) })
                        }
                        if session.paragraphs.isEmpty, session.volatile == nil {
                            HStack(spacing: DS.Space.m) {
                                Text(session.isLive ? "Listening…" : "No transcript").font(DS.Typo.subheadline).foregroundStyle(.secondary)
                                if session.isLive { LevelMeter(level: session.level, peak: session.level, width: 80) }
                            }
                            .padding(.top, DS.Space.xl)
                        }
                        ForEach(Array(session.paragraphs.enumerated()), id: \.element.id) { i, p in
                            paragraphView(p, previous: i > 0 ? session.paragraphs[i - 1] : nil, isLast: i == session.paragraphs.count - 1)
                                .id(p.id)
                        }
                        if let v = session.volatile, session.paragraphs.last.map({ !Self.volatileContinues($0, v) }) ?? true {
                            row(time: v.start, wallClock: LiveSessionModel.wallClock(session.startedAt, offset: v.start)) {
                                StreamingText(committed: AttributedString(""), volatile: v.text, isStreaming: true, style: .transcript)
                            }
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .frame(maxWidth: DS.Layout.readingMaxWidth, alignment: .leading)
                    .padding(DS.Space.l)
                }
                .defaultScrollAnchor(.bottom)
                .onScrollGeometryChange(for: ScrollSnapshot.self) { ScrollSnapshot($0) } action: { old, new in
                    if new.contentHeight == old.contentHeight, new.bottomInset == old.bottomInset {
                        // Offsets caused by our own scrollTo (within the last 0.6 s) are not user intent.
                        if Date.now < programmaticScrollUntil { if new.isAtBottom { newSinceUnpinned = 0 }; return }
                        followLive = new.isAtBottom
                        if followLive { newSinceUnpinned = 0 }
                    } else if followLive {
                        scrollToBottomSoon(proxy)
                    }
                }
                .onChange(of: session.paragraphs.count) { _, count in
                    if followLive { scrollToBottomSoon(proxy) } else { newSinceUnpinned += max(0, count - lastParagraphCount) }
                    lastParagraphCount = count
                }
                .onChange(of: session.volatile?.text) { _, _ in if followLive { scrollToBottomSoon(proxy) } }
                .onChange(of: session.transcriptSeek) { _, seek in
                    guard let seek, let p = session.paragraph(at: seek.time) else { return }
                    followLive = false
                    programmaticScrollUntil = Date.now.addingTimeInterval(0.6)
                    proxy.scrollSoon(to: p.id, anchor: .center, animation: reduceMotion ? nil : motion.settle)
                    flash(p.id)
                }
                .onChange(of: hitIndex) { _, _ in
                    guard let id = currentHitID else { return }
                    proxy.scrollSoon(to: id, anchor: .center, animation: motion.settle)
                }
                .onReceive(NotificationCenter.default.publisher(for: .lecternJumpToLive)) { _ in jump(proxy) }
                .overlay(alignment: .bottom) {
                    if !followLive, newSinceUnpinned > 0 {
                        JumpToLivePill(newCount: newSinceUnpinned) { jump(proxy) }.padding(.bottom, DS.Space.m)
                    }
                }
                .onAppear {
                    lastParagraphCount = session.paragraphs.count
                    if let seek = session.transcriptSeek, let p = session.paragraph(at: seek.time) {
                        proxy.scrollSoon(to: p.id, anchor: .center)
                        flash(p.id)
                    } else {
                        scrollToBottomSoon(proxy)
                    }
                }
            }
        }
        .focusSection()
        .onChange(of: searchShown) { _, shown in
            if shown { searchFocused = true } else { query = ""; hitIndex = 0 }
        }
        .onKeyPress(.escape) {
            guard searchShown else { return .ignored }
            showSearch?.wrappedValue = false
            return .handled
        }
    }

    /// The in-progress hypothesis continues the last paragraph only when it is close in time and
    /// the paragraph is the lecturer's (an unlabeled hypothesis must never extend a student turn).
    private static func volatileContinues(_ p: TranscriptParagraph, _ v: TranscriptSegment) -> Bool {
        p.kind == .speech && v.start - p.end < TranscriptParagraph.breakGap && (p.segments.last?.speaker ?? .lecturer).isLecturer
    }

    // MARK: Search

    private var hits: [UUID] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { return [] }
        return session.paragraphs.filter { $0.kind == .speech && $0.text.localizedCaseInsensitiveContains(q) }.map(\.id)
    }

    private var currentHitID: UUID? { hits.indices.contains(hitIndex) ? hits[hitIndex] : nil }

    private var searchField: some View {
        HStack(spacing: DS.Space.s) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Find in transcript", text: $query)
                .textFieldStyle(.plain)
                .frame(height: 20)
                .focused($searchFocused)
                .onSubmit { step(1) }
                .onChange(of: query) { _, _ in hitIndex = 0 }
                .onKeyPress(.upArrow) { step(-1); return .handled }
                .onKeyPress(.downArrow) { step(1); return .handled }
            if !hits.isEmpty {
                Text("\(hitIndex + 1) of \(hits.count)").font(DS.Typo.mono).foregroundStyle(.secondary).contentTransition(.numericText())
            } else if query.count >= 2 {
                Text("0").font(DS.Typo.mono).foregroundStyle(.tertiary)
            }
            Button { step(-1) } label: { Image(systemName: "chevron.up") }.keyboardShortcut(.return, modifiers: .shift)
            Button { step(1) } label: { Image(systemName: "chevron.down") }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, DS.Space.m).padding(.vertical, DS.Space.s)
        .background(.quaternary.opacity(0.5))
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private func step(_ d: Int) {
        guard !hits.isEmpty else { return }
        hitIndex = (hitIndex + d + hits.count) % hits.count
    }

    // MARK: Paragraphs

    @ViewBuilder
    private func paragraphView(_ p: TranscriptParagraph, previous: TranscriptParagraph?, isLast: Bool) -> some View {
        switch p.kind {
        case .pause:
            Text("— Paused at \(TimeFormat.clock(p.start)) —")
                .font(DS.Typo.footnote).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
        case .speech:
            let speaker = p.segments.first?.speaker ?? .lecturer
            let afterAudience = previous?.segments.first?.speaker?.isLecturer == false
            let volatile = isLast ? session.volatile.flatMap { v in Self.volatileContinues(p, v) ? v.text : nil } : nil
            row(time: p.start, wallClock: LiveSessionModel.wallClock(session.startedAt, offset: p.start)) {
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    if !speaker.isLecturer {
                        speakerLabel("Student", symbol: "person.fill")
                    } else if afterAudience {
                        speakerLabel("Lecturer", symbol: "person.wave.2.fill")
                    }
                    Group {
                        if volatile == nil {
                            Text(highlighted(p)).textSelection(.enabled)
                        } else {
                            StreamingText(committed: highlighted(p), volatile: volatile, isStreaming: true, style: .transcript)
                        }
                    }
                    .font(DS.Typo.body)
                    .lineSpacing(DS.Typo.transcriptLineSpacing)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(speaker.isLecturer ? 0 : DS.Space.m)
                .background {
                    if !speaker.isLecturer {
                        RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).fill(DS.Colors.accent.opacity(0.07))
                    }
                }
                .padding(.leading, speaker.isLecturer ? 0 : DS.Space.m)
            }
            .background(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous).fill(DS.Colors.accent.opacity(flashID == p.id ? 0.10 : 0)))
            .animation(.easeOut(duration: 0.8), value: flashID)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(Int(p.start) / 60) minutes \(Int(p.start) % 60) seconds\(speaker.isLecturer ? "" : ", student"): \(p.text)")
        }
    }

    private func speakerLabel(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol).font(DS.Typo.caption).fontWeight(.semibold).foregroundStyle(.secondary)
    }

    private func row<Content: View>(time: TimeInterval, wallClock: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.m) {
            // Only the active row carries a popover modifier: hundreds of live popover
            // presentations inside a streaming, re-laying-out list are a layout-loop risk.
            let chip = TimestampChip(time: time, style: .gutter, tooltip: wallClock) { popoverTime = time }
            if popoverTime == time {
                chip.popover(isPresented: Binding(get: { popoverTime == time }, set: { if !$0 { popoverTime = nil } }), arrowEdge: .trailing) {
                    TimestampPopover(session: session, time: time)
                }
            } else {
                chip
            }
            content()
        }
    }

    private func highlighted(_ p: TranscriptParagraph) -> AttributedString {
        var a = AttributedString(p.text)
        a.foregroundColor = Color(nsColor: .labelColor)
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { return a }
        var searchStart = p.text.startIndex
        while let r = p.text.range(of: q, options: .caseInsensitive, range: searchStart..<p.text.endIndex) {
            if let lo = AttributedString.Index(r.lowerBound, within: a), let hi = AttributedString.Index(r.upperBound, within: a) {
                a[lo..<hi].backgroundColor = DS.Colors.searchHit
                if currentHitID == p.id { a[lo..<hi].underlineStyle = .single; a[lo..<hi].underlineColor = NSColor.controlAccentColor }
            }
            searchStart = r.upperBound
        }
        return a
    }

    private func flash(_ id: UUID) {
        flashID = id
        Task { try? await Task.sleep(for: .milliseconds(150)); withAnimation(.easeOut(duration: 0.8)) { flashID = nil } }
    }

    private func scrollToBottomSoon(_ proxy: ScrollViewProxy) {
        programmaticScrollUntil = Date.now.addingTimeInterval(0.6)
        proxy.scrollSoon(to: "bottom", anchor: .bottom)
    }

    private func jump(_ proxy: ScrollViewProxy) {
        followLive = true
        newSinceUnpinned = 0
        programmaticScrollUntil = Date.now.addingTimeInterval(0.6)
        proxy.scrollSoon(to: "bottom", anchor: .bottom, animation: motion.settle)
    }
}

/// Timestamp click → slide + takeaway context.
struct TimestampPopover: View {
    var session: LiveSessionModel
    var time: TimeInterval

    var body: some View {
        let takeaway = session.takeaway(covering: time)
        let page = takeaway?.slidePages.first ?? session.displayedSlide
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(spacing: DS.Space.m) {
                if let page {
                    SlideImage(image: session.slideImages?.image(page: page, width: DS.Size.slideThumbLarge.width), page: page)
                        .frame(width: DS.Size.slideThumbLarge.width, height: DS.Size.slideThumbLarge.height)
                }
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    if let page { Text("Slide \(page)\(session.deck?.page(page)?.title.map { " · \($0)" } ?? "")").font(DS.Typo.headline).lineLimit(1) }
                    if let takeaway { Text(takeaway.title).font(DS.Typo.subheadline).foregroundStyle(.secondary).lineLimit(2) }
                    Text(LiveSessionModel.wallClock(session.startedAt, offset: time)).font(DS.Typo.mono).foregroundStyle(.tertiary)
                }
            }
            HStack {
                if let page { Button("Show slide") { session.showSlide(page) }.controlSize(.small) }
                if let takeaway { Button("Show takeaway") { session.expandTakeaway(takeaway.id) }.controlSize(.small) }
            }
        }
        .padding(DS.Space.l)
        .frame(maxWidth: 360, alignment: .leading)
    }
}
