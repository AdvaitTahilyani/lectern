import SwiftUI
import LecternCore
import UniformTypeIdentifiers

/// Left column: current slide, thumbnail list, follow toggle, backtrack suggestion (DESIGN.md §4.4).
/// Decks are added with "Add Deck…" or by dropping PDF / PowerPoint / Keynote files anywhere on the
/// column; with several decks the list shows where each one starts.
struct SlidesColumn: View {
    @Bindable var session: LiveSessionModel
    @Environment(\.dsAnimation) private var motion
    @Namespace private var ring
    @State private var showViewer = false
    @State private var scrolled: Int?
    @State private var isDropTargeted = false
    @State private var removingDeck: DeckSpan?

    var body: some View {
        VStack(spacing: 0) {
            header
            if session.pageCount > 0, let images = session.slideImages {
                currentSlide(images)
                Divider().padding(.vertical, DS.Space.m)
                thumbnails(images)
            } else if !session.decksBeingAdded.isEmpty {
                VStack(spacing: DS.Space.s) {
                    ProgressView().controlSize(.small)
                    Text(addingLabel).font(DS.Typo.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(DS.Space.l)
            } else {
                EmptyStateView(symbol: "doc.badge.plus", title: "No slides", message: "Drop a PDF, PowerPoint or Keynote file here", action: ("Add Deck…", { session.chooseDecks() }), style: .compact)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                .strokeBorder(DS.Colors.accent, lineWidth: 2)
                .background(DS.Colors.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
                .padding(DS.Space.xs)
                .opacity(isDropTargeted ? 1 : 0)
                .allowsHitTesting(false)
        }
        .animation(motion.quick, value: isDropTargeted)
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            DeckIntake.loadFileURLs(from: providers) { session.addDecks(urls: $0) }
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
        .confirmationDialog(removingDeck.map { "Remove “\($0.displayName)”?" } ?? "", isPresented: Binding(get: { removingDeck != nil }, set: { if !$0 { removingDeck = nil } }), titleVisibility: .visible) {
            Button("Remove Deck", role: .destructive) {
                if let span = removingDeck { session.removeDeck(at: span.index) }
                removingDeck = nil
            }
            Button("Cancel", role: .cancel) { removingDeck = nil }
        } message: {
            Text("Its slides leave this lecture, and takeaways, quiz questions and answers stop citing them.")
        }
        .focusSection()
        .onKeyPress(.leftArrow) { guard SessionShortcuts.singleKeysAllowed(textInputActive: TextInputFocus.isActive) else { return .ignored }; session.stepSlide(-1); return .handled }
        .onKeyPress(.rightArrow) { guard SessionShortcuts.singleKeysAllowed(textInputActive: TextInputFocus.isActive) else { return .ignored }; session.stepSlide(1); return .handled }
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

    private var addingLabel: String {
        let names = session.decksBeingAdded
        return names.count == 1 ? "Adding “\(names[0])”…" : "Adding \(names.count) decks…"
    }

    /// Deck boundaries are shown only when the decks' page counts are known (seeded demo decks
    /// without page metadata show as one list).
    private var sections: [DeckSpan]? {
        let spans = session.deckSpans
        return spans.count > 1 && spans.allSatisfy({ $0.pageCount > 0 }) ? spans : nil
    }

    private var header: some View {
        HStack(spacing: DS.Space.s) {
            Text("Slides").columnHeaderStyle()
            Spacer()
            if session.pageCount > 0 { decksMenu }
            if session.isLive {
                Toggle(isOn: Binding(get: { session.followSlides }, set: { if $0 { session.resumeFollowing() } else { session.selectSlide(session.displayedSlide ?? 1) } })) {
                    Label("Auto", systemImage: "scope")
                }
                .toggleStyle(.button)
                .buttonStyle(.accessoryBar)
                .controlSize(.small)
                .help("Follow the lecture's slides automatically. Picking a slide yourself pauses it.")
            }
        }
        .padding(.horizontal, DS.Space.l)
        .frame(height: 28)
    }

    /// Add Deck… plus, per deck, reorder and remove.
    private var decksMenu: some View {
        let spans = session.deckSpans
        return Menu {
            Button("Add Deck…", systemImage: "plus") { session.chooseDecks() }
            if !spans.isEmpty { Divider() }
            ForEach(spans) { span in
                if spans.count == 1 {
                    Button("Remove “\(span.displayName)”…", systemImage: "trash") { removingDeck = span }
                } else {
                    Menu(span.displayName) { deckActions(span, count: spans.count) }
                }
            }
        } label: {
            Label("Decks", systemImage: "rectangle.stack.badge.plus")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .labelStyle(.iconOnly)
        .help("Add, reorder or remove slide decks")
        .accessibilityLabel("Slide decks")
    }

    @ViewBuilder private func deckActions(_ span: DeckSpan, count: Int) -> some View {
        Button("Move Up", systemImage: "arrow.up") { session.moveDeck(at: span.index, by: -1) }.disabled(span.index == 0)
        Button("Move Down", systemImage: "arrow.down") { session.moveDeck(at: span.index, by: 1) }.disabled(span.index == count - 1)
        Divider()
        Button("Remove…", systemImage: "trash") { removingDeck = span }
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
            // Prev/next set the current slide (a correction when tracking is off); ←/→ do the same.
            HStack(spacing: DS.Space.s) {
                Button { session.stepSlide(-1) } label: { Image(systemName: "chevron.left") }
                    .disabled(page <= 1)
                    .help("Previous slide (←)")
                    .accessibilityLabel("Previous slide")
                VStack(spacing: 0) {
                    Text("\(page) of \(session.pageCount)").font(DS.Typo.mono).foregroundStyle(.secondary).contentTransition(.numericText())
                    if let span = sections?.first(where: { $0.contains(page) }) {
                        Text("\(span.displayName) · \(page - span.firstPage + 1)").font(DS.Typo.caption).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                    }
                }
                Button { session.stepSlide(1) } label: { Image(systemName: "chevron.right") }
                    .disabled(page >= session.pageCount)
                    .help("Next slide (→)")
                    .accessibilityLabel("Next slide")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
        .padding(.horizontal, DS.Space.l)
        .padding(.top, DS.Space.xs)
    }

    private func thumbnails(_ images: SlideImageStore) -> some View {
        ScrollView {
            LazyVStack(spacing: DS.Space.s) {
                if !session.decksBeingAdded.isEmpty {
                    HStack(spacing: DS.Space.s) {
                        ProgressView().controlSize(.mini)
                        Text(addingLabel).font(DS.Typo.footnote).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 0)
                    }
                }
                if let sections {
                    ForEach(sections) { span in
                        deckHeader(span, count: sections.count)
                        ForEach(Array(span.pages), id: \.self) { page in
                            thumbnailRow(page, images: images, deck: (span, page - span.firstPage + 1))
                        }
                    }
                } else {
                    ForEach(1...max(1, session.pageCount), id: \.self) { page in
                        thumbnailRow(page, images: images, deck: nil)
                    }
                }
            }
            .scrollTargetLayout()
            .padding(.horizontal, DS.Space.l)
            .padding(.bottom, DS.Space.l)
        }
        .scrollPosition(id: $scrolled, anchor: .center)
    }

    /// Where a deck starts in the list: its name, size and actions.
    private func deckHeader(_ span: DeckSpan, count: Int) -> some View {
        HStack(spacing: DS.Space.xs) {
            Image(systemName: "doc.richtext").foregroundStyle(.secondary).font(.caption)
            Text(span.displayName).font(DS.Typo.footnote.weight(.semibold)).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: DS.Space.xs)
            Text("\(span.pageCount)").font(DS.Typo.caption).foregroundStyle(.tertiary)
            Menu { deckActions(span, count: count) } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("Actions for \(span.displayName)")
        }
        .padding(.top, span.index == 0 ? 0 : DS.Space.s)
        .contextMenu { deckActions(span, count: count) }
        .help(span.deck.originalFileName)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Deck \(span.displayName), slides \(span.firstPage) to \(span.firstPage + span.pageCount - 1)")
    }

    /// `deck`: the row's deck and its page number there, when deck boundaries are shown.
    private func thumbnailRow(_ page: Int, images: SlideImageStore, deck: (span: DeckSpan, local: Int)?) -> some View {
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
                Text("\(deck?.local ?? page)")
                    .font(DS.Typo.mono)
                    .fontWeight(isCurrent ? .semibold : .regular)
                    .foregroundStyle(isCurrent ? AnyShapeStyle(DS.Colors.accent) : AnyShapeStyle(.secondary))
            }
            .padding(.trailing, DS.Space.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id(page)
        .help(session.isLive ? "Make this the current slide" : "Show this slide")
        .accessibilityLabel("Slide \(page)\(deck.map { ", \($0.span.displayName) page \($0.local)" } ?? "")\(isCurrent ? ", current" : "")")
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
        // A group, not one combined element: combining folded Dismiss into Jump's default action.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("The lecture may be back on slide \(page)")
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
