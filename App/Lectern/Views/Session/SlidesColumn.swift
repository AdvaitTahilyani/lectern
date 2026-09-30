import SwiftUI
import LecternCore
import UniformTypeIdentifiers

/// Left column: current slide, thumbnail list, follow toggle, backtrack suggestion (DESIGN.md §4.4).
struct SlidesColumn: View {
    @Bindable var session: LiveSessionModel
    @Environment(\.dsAnimation) private var motion
    @Namespace private var ring
    @State private var showViewer = false
    @State private var scrolled: Int?

    var body: some View {
        VStack(spacing: 0) {
            header
            if session.pageCount > 0, let images = session.slideImages {
                currentSlide(images)
                Divider().padding(.vertical, DS.Space.m)
                thumbnails(images)
            } else {
                EmptyStateView(symbol: "doc.badge.plus", title: "No slides", message: nil, action: ("Add Deck…", { session.showDeckChooser = true }), style: .compact)
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: DS.Space.s) {
                if let page = session.backtrackSuggestion { BacktrackPill(page: page, thumbnail: session.slideImages?.image(page: page, width: 48), onJump: { session.acceptBacktrack() }, onDismiss: { session.dismissBacktrack() }) }
                if !session.followSlides, session.isLive {
                    // ⌘⇧A is the "Resume Slide Following" menu command.
                    JumpToLivePill(newCount: 0, label: "Resume following", symbol: "arrow.clockwise") { session.resumeFollowing() }
                }
            }
            .padding(.bottom, DS.Space.floatInset)
            .animation(motion.quick, value: session.followSlides)
            .animation(motion.quick, value: session.backtrackSuggestion)
        }
        .focusSection()
        .onKeyPress(.leftArrow) { session.stepSlide(-1); return .handled }
        .onKeyPress(.rightArrow) { session.stepSlide(1); return .handled }
        .onChange(of: session.displayedSlide) { _, page in
            guard session.followSlides, let page else { return }
            scrollSoon(to: page)
        }
        .onChange(of: session.highlightedSlide) { _, page in
            guard let page else { return }
            scrollSoon(to: page)
        }
    }

    /// Scroll-position writes are deferred out of the current update (see `ScrollViewProxy.scrollSoon`).
    private func scrollSoon(to page: Int) {
        Task { @MainActor in
            await Task.yield()
            withAnimation(motion.settle) { scrolled = page }
        }
    }

    private var header: some View {
        HStack {
            Text("Slides").columnHeaderStyle()
            Spacer()
            if session.isLive {
                Toggle(isOn: Binding(get: { session.followSlides }, set: { if $0 { session.resumeFollowing() } else { session.selectSlide(session.displayedSlide ?? 1) } })) {
                    Label("Auto", systemImage: "scope")
                }
                .toggleStyle(.button)
                .buttonStyle(.accessoryBar)
                .controlSize(.small)
                .help("Follow the lecture's slides automatically")
            }
        }
        .padding(.horizontal, DS.Space.l)
        .frame(height: 28)
    }

    private func currentSlide(_ images: SlideImageStore) -> some View {
        let page = session.displayedSlide ?? 1
        return VStack(spacing: DS.Space.xs) {
            let width = DS.Layout.slidesColumn.ideal - 2 * DS.Space.l
            let height = min(160, width * images.aspect)
            Button { showViewer = true } label: {
                SlideImage(image: images.image(page: page, width: width), page: page, isCurrent: true)
                    .frame(width: min(width, height / images.aspect), height: height)
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                            .strokeBorder(DS.Colors.accent, lineWidth: 2)
                            .opacity(session.followSlides && session.isLive ? 1 : 0)
                    )
            }
            .buttonStyle(.plain)
            .help("Open full size")
            .popover(isPresented: $showViewer, arrowEdge: .trailing) { SlideViewer(session: session, images: images) }
            Text("\(page) of \(session.pageCount)").font(DS.Typo.mono).foregroundStyle(.secondary).contentTransition(.numericText())
        }
        .padding(.horizontal, DS.Space.l)
        .padding(.top, DS.Space.xs)
    }

    private func thumbnails(_ images: SlideImageStore) -> some View {
        ScrollView {
            LazyVStack(spacing: DS.Space.s) {
                ForEach(1...max(1, session.pageCount), id: \.self) { page in
                    thumbnailRow(page, images: images)
                }
            }
            .scrollTargetLayout()
            .padding(.horizontal, DS.Space.l)
            .padding(.bottom, DS.Space.l)
        }
        .scrollPosition(id: $scrolled, anchor: .center)
    }

    private func thumbnailRow(_ page: Int, images: SlideImageStore) -> some View {
        let isCurrent = page == session.displayedSlide
        let highlighted = page == session.highlightedSlide
        // Compact list rows (DESIGN §4.4): 96×54 thumbnail, page number right-aligned, so ~10 rows
        // fit; the hero image above shows the current slide at full column width.
        let thumbWidth = DS.Size.slideThumb.width
        return Button { session.selectSlide(page) } label: {
            HStack(spacing: DS.Space.s) {
                Rectangle().fill(.quaternary).frame(width: 1, height: thumbWidth * images.aspect - 8).opacity(session.visitedSlides.contains(page) && !isCurrent ? 1 : 0)
                SlideImage(image: images.image(page: page, width: thumbWidth), page: page, isCurrent: isCurrent)
                    .frame(width: thumbWidth, height: thumbWidth * images.aspect)
                    .overlay {
                        if isCurrent || highlighted {
                            RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                                .strokeBorder(DS.Colors.accent, lineWidth: 2)
                                .matchedGeometryEffect(id: "slideRing", in: ring, isSource: isCurrent)
                        }
                    }
                Spacer(minLength: DS.Space.s)
                Text("\(page)")
                    .font(DS.Typo.mono)
                    .fontWeight(isCurrent ? .semibold : .regular)
                    .foregroundStyle(isCurrent ? AnyShapeStyle(DS.Colors.accent) : AnyShapeStyle(.secondary))
            }
            .padding(.trailing, DS.Space.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id(page)
        .accessibilityLabel("Slide \(page)\(isCurrent ? ", current" : "")")
    }
}

/// Calm, non-modal "Back on slide N?" suggestion (DESIGN.md §4.18).
struct BacktrackPill: View {
    var page: Int
    var thumbnail: NSImage?
    var onJump: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        HStack(spacing: DS.Space.s) {
            SlideImage(image: thumbnail, page: page, radius: 3).frame(width: 32, height: 18)
            Text("Back on slide \(page)?").font(DS.Typo.subheadline)
            Button("Jump", action: onJump).buttonStyle(.link).font(DS.Typo.subheadline.weight(.semibold)).keyboardShortcut("[", modifiers: .command)
            Button(action: onDismiss) { Image(systemName: "xmark").font(.caption2) }.buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, DS.Space.m)
        .frame(height: 30)
        .lecternGlass(.regular.interactive(), in: .capsule)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("The lecture may be back on slide \(page). Jump?")
    }
}

/// Full-size slide popover with ←/→ paging.
struct SlideViewer: View {
    var session: LiveSessionModel
    var images: SlideImageStore
    @State private var page: Int = 1

    var body: some View {
        VStack(spacing: DS.Space.m) {
            SlideImage(image: images.image(page: page, width: 900), page: page, isCurrent: true, radius: DS.Radius.card)
                .frame(maxWidth: 900, maxHeight: 560)
            HStack(spacing: DS.Space.l) {
                Button { step(-1) } label: { Image(systemName: "chevron.left") }.keyboardShortcut(.leftArrow, modifiers: [])
                Text("\(page) of \(images.pageCount)").font(DS.Typo.mono).foregroundStyle(.secondary).contentTransition(.numericText())
                Button { step(1) } label: { Image(systemName: "chevron.right") }.keyboardShortcut(.rightArrow, modifiers: [])
                if page != session.displayedSlide {
                    Button("Show in column") { session.selectSlide(page) }.buttonStyle(.link)
                }
            }
            .buttonStyle(.borderless)
        }
        .padding(DS.Space.l)
        .onAppear { page = session.displayedSlide ?? 1 }
    }

    private func step(_ d: Int) { page = min(max(1, page + d), max(1, images.pageCount)) }
}

/// Two-column tier: a chip in the Takeaways header that opens the slide popover + strip.
struct CurrentSlideChip: View {
    @Bindable var session: LiveSessionModel
    @State private var open = false

    var body: some View {
        let page = session.displayedSlide ?? 1
        Button { open = true } label: {
            HStack(spacing: DS.Space.xs) {
                SlideImage(image: session.slideImages?.image(page: page, width: 32), page: page, radius: 3).frame(width: 32, height: 18)
                Text("Slide \(page)").font(DS.Typo.footnote).fontWeight(.medium)
                Image(systemName: "chevron.down").font(.caption2)
            }
            .padding(.horizontal, DS.Space.s)
            .frame(height: 24)
            .foregroundStyle(DS.Colors.accent)
            .background(DS.Colors.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous))
        }
        .buttonStyle(.plain)
        // ⌘3 ("Slides" in the Lecture menu) opens this popover in the two-column tier.
        .onChange(of: session.slideViewerRequest) { _, _ in open = true }
        .popover(isPresented: $open, arrowEdge: .bottom) {
            if let images = session.slideImages {
                VStack(spacing: DS.Space.m) {
                    SlideViewer(session: session, images: images)
                    ScrollView(.horizontal) {
                        HStack(spacing: DS.Space.s) {
                            ForEach(1...max(1, images.pageCount), id: \.self) { p in
                                Button { session.selectSlide(p) } label: {
                                    SlideImage(image: images.image(page: p, width: DS.Size.slideThumb.width), page: p, isCurrent: p == session.displayedSlide)
                                        .frame(width: DS.Size.slideThumb.width, height: DS.Size.slideThumb.width * images.aspect)
                                        .overlay(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous).strokeBorder(DS.Colors.accent, lineWidth: p == session.displayedSlide ? 2 : 0))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, DS.Space.l)
                    }
                    .frame(height: 70)
                    if session.isLive {
                        Toggle("Auto", isOn: Binding(get: { session.followSlides }, set: { if $0 { session.resumeFollowing() } else { session.selectSlide(session.displayedSlide ?? 1) } })).toggleStyle(.switch).controlSize(.small)
                    }
                }
                .frame(width: 660)
                .padding(.bottom, DS.Space.m)
            }
        }
        .accessibilityLabel("Slide \(page), opens slide viewer")
    }
}
