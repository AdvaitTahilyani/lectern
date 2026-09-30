import SwiftUI
import LecternCore
import UniformTypeIdentifiers

// MARK: - DeckFan

/// The first five pages fanned into a stack (rotation −8°…8°, 12 pt offsets), staggered 40 ms.
struct DeckFan: View {
    var images: SlideImageStore
    var namespace: Namespace.ID
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown: Set<Int> = []

    private let rotations: [Double] = [-8, -4, 0, 4, 8]

    var body: some View {
        let count = min(5, images.pageCount)
        ZStack {
            ForEach(0..<count, id: \.self) { i in
                let page = i + 1
                SlideImage(image: images.image(page: page, width: DS.Size.slideThumbLarge.width), page: page, isCurrent: i == count - 1)
                    .frame(width: DS.Size.slideThumbLarge.width, height: DS.Size.slideThumbLarge.width * images.aspect)
                    .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
                    .rotationEffect(.degrees(shown.contains(i) ? rotations[i] : 0))
                    .offset(x: shown.contains(i) ? CGFloat(i - count / 2) * 12 : 0, y: shown.contains(i) ? 0 : 24)
                    .opacity(shown.contains(i) ? 1 : 0)
            }
        }
        .frame(height: DS.Size.slideThumbLarge.width * images.aspect + 24)
        .matchedGeometryEffect(id: "deck", in: namespace)
        .onAppear {
            if reduceMotion {
                shown = Set(0..<count)
            } else {
                for i in 0..<count {
                    Task {
                        try? await Task.sleep(for: .milliseconds(40 * i))
                        withAnimation(DS.Motion.float) { _ = shown.insert(i) }
                    }
                }
            }
        }
        .accessibilityLabel("Slide deck, \(images.pageCount) pages")
    }
}

// MARK: - DeckDropZone

struct DeckDropZone: View {
    @Bindable var setup: SetupModel
    var namespace: Namespace.ID
    var onChoose: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showPreview = false

    var body: some View {
        VStack(spacing: DS.Space.m) {
            if let images = setup.slideImages, setup.deckURL != nil {
                loaded(images)
            } else if setup.indexing == .converting {
                converting
            } else {
                empty
            }
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 200)
        .padding(DS.Space.l)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.float, style: .continuous)
                .fill(setup.isDragTargeted ? DS.Colors.accent.opacity(0.06) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.float, style: .continuous)
                .strokeBorder(setup.isDragTargeted ? AnyShapeStyle(DS.Colors.accent) : AnyShapeStyle(.quaternary), style: StrokeStyle(lineWidth: 2, dash: setup.isDragTargeted || setup.deckURL != nil ? [] : [6, 6]))
        )
        .animation(DS.Motion.quick, value: setup.isDragTargeted)
        .onDrop(of: [.fileURL], isTargeted: Binding(get: { setup.isDragTargeted }, set: { setup.setDragTargeted($0) })) { providers in
            handleDrop(providers)
        }
    }

    private var converting: some View {
        VStack(spacing: DS.Space.s) {
            Image(systemName: "doc.badge.gearshape").font(.system(size: 36)).foregroundStyle(.secondary)
            Text("Converting with Keynote…").font(DS.Typo.title3)
            Text(setup.deckDisplayName ?? setup.deckURL?.lastPathComponent ?? "").font(DS.Typo.subheadline).foregroundStyle(.secondary)
            ProgressView().controlSize(.small).padding(.top, DS.Space.xs)
        }
        .padding(.vertical, DS.Space.xl)
    }

    private var empty: some View {
        VStack(spacing: DS.Space.s) {
            Image(systemName: "doc.richtext")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
                .symbolEffect(.bounce, options: .nonRepeating, value: setup.isDragTargeted)
                .symbolEffect(.wiggle, options: .nonRepeating, value: setup.deckErrorShakeCount)
            Text(setup.deckError ?? "Drop the slide deck here").font(DS.Typo.title3).multilineTextAlignment(.center).frame(maxWidth: 420)
            HStack(spacing: DS.Space.xs) {
                Text(setup.deckError == nil ? "\(formatsLabel) · or" : "Try another file ·").font(DS.Typo.subheadline).foregroundStyle(.secondary)
                Button("Choose…", action: onChoose).buttonStyle(.link).font(DS.Typo.subheadline)
                if setup.sampleDeckAvailable {
                    Text("·").font(DS.Typo.subheadline).foregroundStyle(.secondary)
                    Button("Use sample deck") { setup.loadSampleDeck() }.buttonStyle(.link).font(DS.Typo.subheadline)
                }
            }
        }
        .padding(.vertical, DS.Space.xl)
    }

    private func loaded(_ images: SlideImageStore) -> some View {
        VStack(spacing: DS.Space.m) {
            Button { showPreview = true } label: { DeckFan(images: images, namespace: namespace) }
                .buttonStyle(.plain)
                .popover(isPresented: $showPreview, arrowEdge: .bottom) { DeckPreviewGrid(images: images) }
                .help("Preview all pages")
                .accessibilityLabel("Preview slide deck, \(images.pageCount) pages")
            VStack(spacing: DS.Space.xs) {
                Text(fileLine).font(DS.Typo.footnote).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                indexingLine
            }
            HStack(spacing: DS.Space.m) {
                Button("Replace…", action: onChoose).buttonStyle(.bordered).controlSize(.small)
                Button { setup.removeDeck() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.tertiary).help("Remove deck").accessibilityLabel("Remove deck")
            }
        }
    }

    private var formatsLabel: String {
        setup.acceptedExtensions.contains("pptx") ? "PDF, PowerPoint or Keynote" : "PDF"
    }

    private var fileLine: String {
        var parts = [setup.deckDisplayName ?? setup.deckURL?.lastPathComponent ?? ""]
        parts.append("\(setup.slideImages?.pageCount ?? 0) slides")
        if setup.deckFileSize > 0 { parts.append(ByteCountFormatter.string(fromByteCount: setup.deckFileSize, countStyle: .file)) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var indexingLine: some View {
        switch setup.indexing {
        case .converting:
            HStack(spacing: DS.Space.s) {
                ProgressView().controlSize(.small)
                Text("Converting with Keynote…").font(DS.Typo.footnote).foregroundStyle(.secondary)
            }
        case .indexing(let done, let total):
            VStack(spacing: DS.Space.xs) {
                ProgressView(value: Double(done), total: Double(max(total, 1))).progressViewStyle(.linear).controlSize(.small).tint(DS.Colors.accent)
                Text("Indexing slides… \(done) of \(total)").font(DS.Typo.footnote).foregroundStyle(.secondary).contentTransition(.numericText())
            }
            .frame(maxWidth: 320)
        case .done(let count):
            HStack(spacing: DS.Space.xs) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(DS.Colors.correct)
                    .symbolEffect(.bounce, options: .nonRepeating, isActive: !reduceMotion)
                Text("Indexed \(count) slides").font(DS.Typo.footnote).foregroundStyle(.secondary)
                if count > 300 { Text("· Large deck — indexing may take a minute").font(DS.Typo.footnote).foregroundStyle(.secondary) }
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle").font(DS.Typo.footnote).foregroundStyle(DS.Colors.warning)
        case nil:
            EmptyView()
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) || $0.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) }) else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
            var url: URL?
            if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
            if let u = item as? URL { url = u }
            guard let url else { return }
            Task { @MainActor in
                guard setup.acceptedExtensions.contains(url.pathExtension.lowercased()) else { return }
                setup.loadDeck(url: url)
            }
        }
        return true
    }
}

/// Popover grid of every page (just a preview).
struct DeckPreviewGrid: View {
    var images: SlideImageStore
    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: DS.Size.slideThumb.width), spacing: DS.Space.s)], spacing: DS.Space.s) {
                ForEach(1...max(1, images.pageCount), id: \.self) { p in
                    VStack(spacing: DS.Space.xxs) {
                        SlideImage(image: images.image(page: p, width: DS.Size.slideThumb.width), page: p)
                            .frame(width: DS.Size.slideThumb.width, height: DS.Size.slideThumb.width * images.aspect)
                        Text("\(p)").font(DS.Typo.mono).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(DS.Space.l)
        }
        .frame(width: 460, height: 360)
    }
}

// MARK: - LectureCard

struct LectureCard: View {
    var session: LectureSession
    var course: Course?
    var courseColor: Color
    var thumbnail: NSImage?
    var isSelected: Bool
    var isLive: Bool
    var liveElapsed: TimeInterval = 0
    @Environment(\.colorScheme) private var colorScheme
    @State private var hovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            ZStack {
                if let thumbnail {
                    Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fill)
                        .brightness(colorScheme == .dark ? -0.08 : 0)
                } else {
                    Rectangle().fill(.quaternary)
                    Image(systemName: "doc.text").font(.title2).foregroundStyle(.secondary)
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous).strokeBorder(DS.Colors.hairline))
            HStack(spacing: DS.Space.xs) {
                if isLive { LiveDot(state: .recording, size: DS.Size.liveDotSmall) }
                Text(session.title).font(DS.Typo.headline).lineLimit(1).truncationMode(.middle)
            }
            .padding(.top, DS.Space.xxs)
            HStack(spacing: DS.Space.xs) {
                Circle().fill(courseColor).frame(width: 6, height: 6)
                Text(metaLine1).font(DS.Typo.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Text(metaLine2).font(DS.Typo.footnote).foregroundStyle(.secondary).lineLimit(1).contentTransition(.numericText())
        }
        .padding(DS.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        .surfaceCard(radius: DS.Radius.card, raised: hovered, strokeColor: hovered ? DS.Colors.accent.opacity(0.4) : nil)
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.card + 4, style: .continuous)
                .strokeBorder(DS.Colors.accent, lineWidth: 2)
                .padding(-4)
                .opacity(isSelected ? 1 : 0)
        )
        .onHover { hovered = $0 }
        .animation(DS.Motion.hover, value: hovered)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(session.title), \(metaLine1), \(metaLine2)")
    }

    private var metaLine1: String {
        [course?.code, LiveSessionModel.relativeDate(session.startedAt ?? session.createdAt)].compactMap { $0 }.joined(separator: " · ")
    }

    private var metaLine2: String {
        if isLive { return "Recording · \(TimeFormat.clock(liveElapsed))" }
        let minutes = Int((session.duration / 60).rounded())
        let summaryID = SessionConventions.summaryID(for: session.id)
        let takeaways = session.takeaways.filter { $0.id != summaryID }.count
        var parts = ["\(minutes) min", "\(takeaways) takeaway\(takeaways == 1 ? "" : "s")"]
        let answered = session.quiz.filter { $0.outcome != nil && $0.question.followUpOf == nil }
        if !answered.isEmpty { parts.append("\(answered.filter { $0.outcome == .correct }.count)/\(answered.count) correct") }
        return parts.joined(separator: " · ")
    }
}
