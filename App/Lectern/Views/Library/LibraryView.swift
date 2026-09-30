import SwiftUI
import LecternCore
import UniformTypeIdentifiers

/// Home: grid of lectures grouped by course, searchable (DESIGN.md §4.1).
struct LibraryView: View {
    @Environment(AppModel.self) private var app
    @State private var selectedSession: UUID?
    @State private var isDropTargeted = false
    @State private var thumbnails = ThumbnailCache()
    @State private var showNoResults = false
    @FocusState private var searchFocused: Bool
    @State private var noResultsTask: Task<Void, Never>?

    private let columns = [GridItem(.adaptive(minimum: 240, maximum: 300), spacing: DS.Space.l)]

    var body: some View {
        @Bindable var app = app
        Group {
            if let error = app.libraryError, app.sessions.isEmpty {
                EmptyStateView(symbol: "externaldrive.badge.exclamationmark", title: "Can't read the library", message: error, action: ("Choose a different location", { NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory())) }))
            } else if !app.searchText.trimmingCharacters(in: .whitespaces).isEmpty, app.searchText.count >= 2 {
                searchResults
            } else if visibleSessions.isEmpty, app.isLibraryLoaded {
                emptyState
            } else {
                grid
            }
        }
        .background(DS.Colors.canvas)
        .overlay {
            RoundedRectangle(cornerRadius: DS.Radius.float, style: .continuous)
                .strokeBorder(DS.Colors.accent, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                .padding(DS.Space.m)
                .opacity(isDropTargeted ? 1 : 0)
                .allowsHitTesting(false)
                .animation(DS.Motion.quick, value: isDropTargeted)
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in handleDrop(providers) }
        .navigationTitle(navigationTitle)
        .navigationSubtitle(navigationSubtitle)
        // Course Ask is this view's inspector (inside the NavigationStack), never a second inspector
        // on the split view: two inspector items in one window loop AppKit's constraint pass once
        // a session view (which has its own inspector) is pushed.
        .inspector(isPresented: $app.showCourseAsk) {
            if let courseID = app.contextCourseID {
                SizeNeutral { CourseAskView(model: app.courseAsk(for: courseID), course: app.course(id: courseID)) }
                    .inspectorColumnWidth(min: DS.Layout.inspector.min, ideal: DS.Layout.inspector.ideal, max: DS.Layout.inspector.max)
            }
        }
        .searchable(text: $app.searchText, placement: .toolbar, prompt: "Search lectures, transcripts…")
        .searchFocused($searchFocused)
        .onReceive(NotificationCenter.default.publisher(for: .lecternFind)) { _ in
            guard app.path.isEmpty else { return }
            Task { @MainActor in await Task.yield(); searchFocused = true }
        }
        .searchScopes($app.searchScope, activation: .onSearchPresentation) {
            ForEach(LibrarySearchScope.allCases) { Text($0.label).tag($0) }
        }
        .onChange(of: app.searchText) { _, _ in app.searchTextChanged(); scheduleNoResults() }
        .onChange(of: app.searchScope) { _, _ in app.searchTextChanged() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Import Recording…") { app.showImport() }.keyboardShortcut("i", modifiers: [.command, .shift])
                } label: {
                    Label("New Lecture", systemImage: "plus")
                } primaryAction: {
                    app.showSetup()
                }
                .lecternProminent()
                .labelStyle(.titleAndIcon)
                .help("New Lecture (⌘N)")
            }
            ToolbarItem(placement: .secondaryAction) {
                Button { app.toggleCourseAsk() } label: { Label("Ask Course", systemImage: "sparkle.magnifyingglass") }
                    .help("Ask about this course (⌘⌥K)")
                    .disabled(app.contextCourseID == nil)
            }
        }
    }

    // MARK: Data

    private var selectedCourse: Course? {
        if case .course(let id) = app.sidebarSelection { return app.course(id: id) }
        return nil
    }

    private var visibleSessions: [LectureSession] {
        if let c = selectedCourse { return app.sessions(in: c.id) }
        return app.sessions
    }

    private var navigationTitle: String { selectedCourse?.code ?? "Lectern" }
    private var navigationSubtitle: String { selectedCourse?.name ?? "" }

    private var recent: [LectureSession] {
        guard selectedCourse == nil, app.courses.count >= 2 else { return [] }
        return Array(app.sessions.prefix(6))
    }

    private var courseSections: [(course: Course?, sessions: [LectureSession])] {
        if let c = selectedCourse { return [(c, app.sessions(in: c.id))] }
        var result: [(Course?, [LectureSession])] = app.courses.map { ($0, app.sessions(in: $0.id)) }.filter { !$0.1.isEmpty }
        let orphans = app.sessions.filter { s in s.courseID == nil || !app.courses.contains { $0.id == s.courseID } }
        if !orphans.isEmpty { result.append((nil, orphans)) }
        return result
    }

    // MARK: Grid

    private var grid: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: DS.Space.xxl) {
                if !app.interruptedSessions.isEmpty { interruptedBanner }
                if !recent.isEmpty {
                    section(title: "Recent", subtitle: nil, count: nil, sessions: recent, collapsible: nil)
                }
                ForEach(courseSections, id: \.course?.id) { entry in
                    section(title: entry.course?.code ?? "Uncategorized", subtitle: entry.course?.name, count: entry.sessions.count, sessions: entry.sessions, collapsible: entry.course?.id)
                }
            }
            .padding(DS.Space.xxl)
        }
    }

    @ViewBuilder
    private func section(title: String, subtitle: String?, count: Int?, sessions: [LectureSession], collapsible: UUID?) -> some View {
        let collapsed = collapsible.map { app.preferences.collapsedCourses.contains($0) } ?? false
        VStack(alignment: .leading, spacing: DS.Space.m) {
            Button {
                guard let id = collapsible else { return }
                withAnimation(DS.Motion.settle) {
                    app.updatePreferences { if $0.collapsedCourses.contains(id) { $0.collapsedCourses.remove(id) } else { $0.collapsedCourses.insert(id) } }
                }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
                    Text(title).font(DS.Typo.title3).fontWeight(.semibold)
                    if let subtitle, !subtitle.isEmpty { Text("— \(subtitle)").font(DS.Typo.title3).foregroundStyle(.secondary).lineLimit(1) }
                    Spacer()
                    if let count { Text("\(count)").font(DS.Typo.subheadline).foregroundStyle(.secondary) }
                    if collapsible != nil {
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(collapsed ? 0 : 90))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(collapsible == nil)
            if !collapsed {
                LazyVGrid(columns: columns, spacing: DS.Space.l) {
                    ForEach(sessions) { s in card(for: s) }
                }
            }
        }
    }

    private func card(for s: LectureSession) -> some View {
        let isLive = app.liveSession?.id == s.id
        let job = app.imports[s.id]
        return Group {
            if let job {
                ImportProgressCard(session: s, job: job, course: app.course(id: s.courseID), onCancel: { app.cancelImport(s.id) }, onDismiss: { app.dismissFailedImport(s.id) })
            } else if app.isInterrupted(s.id) {
                InterruptedCard(session: s, course: app.course(id: s.courseID), courseColor: app.courseColor(app.course(id: s.courseID)), thumbnail: thumbnail(for: s),
                                onResume: { app.resumeInterrupted(s.id) }, onFinish: { app.finishInterrupted(s.id) }, onDiscard: { app.discardInterrupted(s.id) })
            } else {
                LectureCard(session: s, course: app.course(id: s.courseID), courseColor: app.courseColor(app.course(id: s.courseID)), thumbnail: thumbnail(for: s), isSelected: selectedSession == s.id, isLive: isLive, liveElapsed: app.liveSession?.elapsed ?? 0)
                    .onTapGesture(count: 2) { app.openSession(s.id) }
                    .onTapGesture { selectedSession = s.id }
                    .focusable()
                    .onKeyPress(.return) { app.openSession(s.id); return .handled }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction(named: "Open") { app.openSession(s.id) }
                    .accessibilityAction(named: "Select") { selectedSession = s.id }
                    .contextMenu {
                        Button("Open") { app.openSession(s.id) }
                        Menu("Export") {
                            Button("Markdown Notes…") { ExportCoordinator.exportMarkdown(session: s, course: app.course(id: s.courseID)) }
                            Button("PDF…") { ExportCoordinator.exportPDF(session: s, course: app.course(id: s.courseID)) }
                        }
                        Menu("Move to Course") {
                            ForEach(app.courses) { c in Button(c.code) { app.moveSession(s.id, to: c.id) }.disabled(c.id == s.courseID) }
                        }
                        Divider()
                        Button("Delete…", role: .destructive) { app.deleteSession(s.id) }
                    }
            }
        }
    }

    private func thumbnail(for s: LectureSession) -> NSImage? {
        guard let deck = s.deck else { return nil }
        if let store = thumbnails.stores[s.id] { return store.image(page: 1, width: 300) }
        thumbnails.load(sessionID: s.id, fileName: deck.fileName, store: app.services.store)
        return nil
    }

    private var interruptedBanner: some View {
        HStack(spacing: DS.Space.s) {
            Image(systemName: "exclamationmark.arrow.circlepath").foregroundStyle(DS.Colors.warning)
            Text(app.interruptedSessions.count == 1 ? "A lecture was interrupted — resume it or finish it below." : "\(app.interruptedSessions.count) lectures were interrupted — resume or finish them below.")
                .font(DS.Typo.subheadline)
            Spacer()
        }
        .padding(.horizontal, DS.Space.m)
        .frame(height: 36)
        .lecternGlass(.regular, in: .rect(cornerRadius: DS.Radius.float))
    }

    // MARK: Empty & search

    private var emptyState: some View {
        Group {
            if let c = selectedCourse {
                EmptyStateView(symbol: "text.book.closed", title: "Nothing in \(c.code) yet", message: "Start a lecture, or drop a slide deck here to set one up.", action: ("New Lecture in \(c.code)", { app.showSetup() }), useLecternGlyph: true)
            } else {
                EmptyStateView(symbol: "text.book.closed", title: "No lectures yet", message: "Start a lecture, or drop a slide deck here to set one up.", action: ("New Lecture", { app.showSetup() }), useLecternGlyph: true)
            }
        }
    }

    private var searchResults: some View {
        Group {
            if app.searchResults.isEmpty {
                if showNoResults && !app.isSearching {
                    EmptyStateView(symbol: "magnifyingglass", title: "No matches", message: "No matches for “\(app.searchText)”")
                } else {
                    Color.clear
                }
            } else {
                List(app.searchResults) { hit in
                    SearchHitRow(hit: hit, session: app.sessions.first { $0.id == hit.sessionID }, course: app.course(id: app.sessions.first { $0.id == hit.sessionID }?.courseID))
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { app.openSession(hit.sessionID, at: hit.time) }
                        .focusable()
                        .onKeyPress(.return) { app.openSession(hit.sessionID, at: hit.time); return .handled }
                }
                .listStyle(.inset)
            }
        }
    }

    private func scheduleNoResults() {
        showNoResults = false
        noResultsTask?.cancel()
        noResultsTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            if !Task.isCancelled { showNoResults = true }
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
            var url: URL?
            if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
            if let u = item as? URL { url = u }
            guard let url else { return }
            Task { @MainActor in
                let ext = url.pathExtension.lowercased()
                if app.setup.acceptedExtensions.contains(ext) { app.showSetup(droppedPDF: url) }
                else if let type = UTType(filenameExtension: ext), type.conforms(to: .audiovisualContent) { app.showImport(droppedMedia: url) }
            }
        }
        return true
    }
}

/// Lazily opens each session's deck for card thumbnails; requests are deduplicated so view
/// bodies can ask repeatedly without spawning extra work.
@Observable
@MainActor
final class ThumbnailCache {
    private(set) var stores: [UUID: SlideImageStore] = [:]
    @ObservationIgnored private var requested: Set<UUID> = []

    func load(sessionID: UUID, fileName: String, store: any SessionStoring) {
        guard requested.insert(sessionID).inserted else { return }
        Task {
            if let folder = try? await store.folder(for: sessionID) {
                stores[sessionID] = SlideImageStore(url: folder.appendingPathComponent(fileName))
            }
        }
    }
}

// MARK: - Rows & cards

struct SearchHitRow: View {
    var hit: LibrarySearchHit
    var session: LectureSession?
    var course: Course?

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Text(session?.title ?? "Lecture").font(DS.Typo.headline)
            Text(highlighted).font(DS.Typo.body).lineLimit(2)
            HStack(spacing: DS.Space.s) {
                if let t = hit.time { TimestampChip(time: t, style: .inline) {} .allowsHitTesting(false) }
                if let s = hit.slide { SlideChip(page: s) {} .allowsHitTesting(false) }
                if let course { Text(course.code).font(DS.Typo.caption).foregroundStyle(.secondary) }
                Text(fieldLabel).font(DS.Typo.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, DS.Space.xs)
    }

    private var fieldLabel: String {
        switch hit.field { case .title: "Title"; case .transcript: "Transcript"; case .takeaway: "Takeaway" }
    }

    private var highlighted: AttributedString {
        var a = AttributedString(hit.snippet)
        if let r = hit.matchRange, let lower = AttributedString.Index(r.lowerBound, within: a), let upper = AttributedString.Index(r.upperBound, within: a) {
            a[lower..<upper].backgroundColor = DS.Colors.searchHit
        }
        return a
    }
}

/// Library card for a session being imported: staged progress (Downloading → Transcribing → Summarizing).
struct ImportProgressCard: View {
    var session: LectureSession
    var job: ImportJob
    var course: Course?
    var onCancel: () -> Void
    var onDismiss: () -> Void

    private let stages = ["Downloading", "Transcribing", "Summarizing"]

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            ZStack {
                Rectangle().fill(.quaternary)
                Image(systemName: sourceSymbol).font(.title2).foregroundStyle(.secondary)
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
            Text(session.title).font(DS.Typo.headline).lineLimit(1).padding(.top, DS.Space.xxs)
            Text([course?.code, "Importing"].compactMap { $0 }.joined(separator: " · ")).font(DS.Typo.subheadline).foregroundStyle(.secondary)
            if case .failed(let message) = job.state {
                Label(message, systemImage: "exclamationmark.triangle").font(DS.Typo.footnote).foregroundStyle(DS.Colors.warning).lineLimit(2)
                Button("Dismiss", action: onDismiss).buttonStyle(.link).font(DS.Typo.footnote)
            } else {
                ProgressView(value: job.overallProgress).progressViewStyle(.linear).controlSize(.small).tint(DS.Colors.accent)
                HStack(spacing: DS.Space.xs) {
                    ForEach(Array(stages.enumerated()), id: \.offset) { i, name in
                        HStack(spacing: DS.Space.xxs) {
                            Image(systemName: i < job.stageIndex ? "checkmark.circle.fill" : (i == job.stageIndex ? "circle.dotted" : "circle"))
                                .foregroundStyle(i < job.stageIndex ? AnyShapeStyle(DS.Colors.correct) : (i == job.stageIndex ? AnyShapeStyle(DS.Colors.accent) : AnyShapeStyle(.quaternary)))
                            Text(name)
                        }
                        .font(DS.Typo.caption)
                        .foregroundStyle(i == job.stageIndex ? .primary : .secondary)
                        if i < stages.count - 1 { Text("→").font(DS.Typo.caption).foregroundStyle(.quaternary) }
                    }
                    Spacer()
                    Button("Cancel", action: onCancel).buttonStyle(.link).font(DS.Typo.caption)
                }
                Text(job.stageLabel).font(DS.Typo.footnote).foregroundStyle(.secondary).contentTransition(.numericText())
            }
        }
        .padding(DS.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surfaceCard(radius: DS.Radius.card)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(session.title), importing, \(job.stageLabel)")
    }

    private var sourceSymbol: String {
        switch session.source {
        case .mediaSpace: "play.rectangle"
        case .audioFile: "waveform"
        default: "doc.text"
        }
    }
}

/// Card for a session left live/importing by a previous run: a gentle "Resume or finish" affordance.
struct InterruptedCard: View {
    var session: LectureSession
    var course: Course?
    var courseColor: Color
    var thumbnail: NSImage?
    var onResume: () -> Void
    var onFinish: () -> Void
    var onDiscard: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            LectureCard(session: session, course: course, courseColor: courseColor, thumbnail: thumbnail, isSelected: false, isLive: false)
            HStack(spacing: DS.Space.s) {
                Image(systemName: "exclamationmark.arrow.circlepath").foregroundStyle(DS.Colors.warning)
                Text(session.status == .importing ? "Import was interrupted" : "Interrupted at \(TimeFormat.clock(session.transcript.last?.end ?? session.duration))")
                    .font(DS.Typo.footnote).foregroundStyle(.secondary)
                Spacer()
                if session.status != .importing { Button("Resume", action: onResume).controlSize(.small) }
                Button("Finish", action: onFinish).controlSize(.small)
            }
            .padding(.horizontal, DS.Space.xs)
        }
        .contextMenu {
            if session.status != .importing { Button("Resume Recording", action: onResume) }
            Button("Finish and Summarize", action: onFinish)
            Divider()
            Button("Discard…", role: .destructive, action: onDiscard)
        }
    }
}

/// Save panels for exports.
@MainActor
enum ExportCoordinator {
    static func exportMarkdown(session: LectureSession, course: Course?) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = "\(session.title).md"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? MarkdownExporter.document(session: session, course: course).write(to: url, atomically: true, encoding: .utf8)
        }
    }

    static func exportPDF(session: LectureSession, course: Course?) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "\(session.title).pdf"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? PDFExporter.write(session: session, course: course, to: url)
        }
    }
}
