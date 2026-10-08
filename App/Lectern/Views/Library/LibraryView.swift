import SwiftUI
import LecternCore
import UniformTypeIdentifiers

/// Home: grid of lectures grouped by course, searchable (DESIGN.md §4.1).
struct LibraryView: View {
    @Environment(AppModel.self) private var app
    @Environment(WindowNavigation.self) private var nav
    @State private var selectedSession: UUID?
    @State private var isDropTargeted = false
    @State private var thumbnails = ThumbnailCache()
    @State private var showNoResults = false
    @FocusState private var searchFocused: Bool
    @State private var noResultsTask: Task<Void, Never>?
    /// The lecture a Delete/Discard is waiting on the user's confirmation for.
    @State private var pendingRemoval: PendingRemoval?

    private struct PendingRemoval: Identifiable {
        var session: LectureSession
        var verb: String
        /// Cancelling an in-flight import (its partial session goes to the Trash).
        var isImport = false
        var id: UUID { session.id }
    }

    private let columns = [GridItem(.adaptive(minimum: 240, maximum: 300), spacing: DS.Space.l)]

    var body: some View {
        @Bindable var nav = nav
        Group {
            if let error = app.libraryError, app.sessions.isEmpty {
                EmptyStateView(symbol: "externaldrive.badge.exclamationmark", title: "Can't read the library", message: error, action: ("Try Again", { Task { await app.loadLibrary() } }))
            } else if nav.searchText.trimmingCharacters(in: .whitespaces).count >= 2 {
                searchResults
            } else if visibleSessions.isEmpty, app.isLibraryLoaded {
                emptyState
            } else {
                grid
            }
        }
        .background(DS.Colors.canvas)
        .safeAreaInset(edge: .top, spacing: 0) { notices }
        // A standard dialog (the Library is not a live session). Lectures go to the Trash, so
        // they can be put back from there.
        .confirmationDialog(
            pendingRemoval.map { "\($0.verb) “\($0.session.title)”?" } ?? "",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            titleVisibility: .visible,
            presenting: pendingRemoval
        ) { removal in
            if removal.isImport {
                Button("Cancel Import", role: .destructive) { app.cancelImport(removal.session.id) }
                Button("Keep Importing", role: .cancel) {}
            } else {
                Button("Move to Trash", role: .destructive) { app.deleteSession(removal.session.id) }
                Button("Cancel", role: .cancel) {}
            }
        } message: { removal in
            if removal.isImport {
                Text("The import stops and what was processed so far is moved to the Trash.")
            } else {
                Text("\(removal.verb == "Discard" ? "Its transcript, takeaways and slides" : "The lecture, with its transcript, takeaways and slides,") will be moved to the Trash.")
            }
        }
        // The Trash refused a lecture: nothing was deleted. Erasing it for good is a separate,
        // explicit choice, offered only here.
        .confirmationDialog(
            app.permanentDeletionOffer.map { "Couldn't move “\($0.title)” to the Trash" } ?? "",
            isPresented: Binding(get: { app.permanentDeletionOffer != nil }, set: { if !$0 { app.declinePermanentDeletion() } }),
            titleVisibility: .visible,
            presenting: app.permanentDeletionOffer
        ) { _ in
            Button("Delete Permanently", role: .destructive) { app.confirmPermanentDeletion() }
            Button("Keep Lecture", role: .cancel) { app.declinePermanentDeletion() }
        } message: { offer in
            Text("\(offer.reason) You can keep the lecture, or delete it permanently, which can't be undone.")
        }
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
        .inspector(isPresented: $nav.showCourseAsk) {
            if let courseID = app.contextCourseID(for: nav) {
                SizeNeutral { CourseAskView(model: app.courseAsk(for: courseID), course: app.course(id: courseID)) }
                    .inspectorColumnWidth(min: DS.Layout.inspector.min, ideal: DS.Layout.inspector.ideal, max: DS.Layout.inspector.max)
            }
        }
        .searchable(text: $nav.searchText, placement: .toolbar, prompt: "Search lectures, transcripts…")
        .searchFocused($searchFocused)
        .onWindowCommand(.lecternFind) {
            guard nav.path.isEmpty else { return }
            Task { @MainActor in await Task.yield(); searchFocused = true }
        }
        .searchScopes($nav.searchScope, activation: .onSearchPresentation) {
            ForEach(LibrarySearchScope.allCases) { Text($0.label).tag($0) }
        }
        .onChange(of: nav.searchText) { _, _ in runSearch(); scheduleNoResults() }
        .onChange(of: nav.searchScope) { _, _ in runSearch() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Import Recording…") { app.showImport() }
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

    // MARK: Notices

    /// Non-modal banners: a failed save/delete (the error state covers an empty library) and
    /// session files that could not be read.
    /// One sentence per kind of damage, e.g. "1 lecture was restored from its last good copy; its
    /// latest changes may be missing. 1 lecture file couldn't be read and is left out."
    static func issueMessage(_ issues: [LibraryIssue]) -> String? {
        func count(_ kind: LibraryIssue.Kind) -> Int { issues.filter { $0.kind == kind }.count }
        func lectures(_ n: Int) -> String { n == 1 ? "1 lecture" : "\(n) lectures" }
        var parts: [String] = []
        let restored = count(.restored), partial = count(.partiallyRecovered), skipped = count(.skipped)
        if restored > 0 { parts.append("\(lectures(restored)) \(restored == 1 ? "was" : "were") restored from the last good copy; the latest changes may be missing.") }
        if partial > 0 { parts.append("\(lectures(partial)) had damaged parts that were left out; the original file was kept.") }
        if skipped > 0 { parts.append("\(skipped == 1 ? "1 lecture file" : "\(skipped) lecture files") couldn't be read and \(skipped == 1 ? "is" : "are") left out; the \(skipped == 1 ? "file is" : "files are") untouched.") }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    @ViewBuilder private var notices: some View {
        let failure = app.sessions.isEmpty ? nil : app.libraryError
        let issues = app.libraryIssues
        if failure != nil || !issues.isEmpty {
            VStack(spacing: DS.Space.s) {
                if let failure {
                    NoticeBanner(notice: Notice(id: "library-error", kind: .warning, symbol: "exclamationmark.triangle", title: failure, placement: .takeaways, actionLabel: nil), onClose: { app.libraryError = nil })
                }
                if let message = Self.issueMessage(issues) {
                    NoticeBanner(notice: Notice(id: "library-issues", kind: .warning, symbol: "exclamationmark.triangle", title: message, placement: .takeaways, actionLabel: nil), onClose: { app.libraryIssues = [] })
                }
            }
            .padding(.horizontal, DS.Space.xxl)
            .padding(.top, DS.Space.m)
        }
    }

    // MARK: Data

    private var selectedCourse: Course? {
        if case .course(let id) = nav.sidebarSelection { return app.course(id: id) }
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

    private func section(title: String, subtitle: String?, count: Int?, sessions: [LectureSession], collapsible: UUID?) -> some View {
        let collapsed = collapsible.map { app.preferences.collapsedCourses.contains($0) } ?? false
        let header = HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
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
        return VStack(alignment: .leading, spacing: DS.Space.m) {
            // Only a course section collapses; a disabled button would grey the other titles out.
            if let id = collapsible {
                Button {
                    withAnimation(DS.Motion.settle) {
                        app.updatePreferences { if $0.collapsedCourses.contains(id) { $0.collapsedCourses.remove(id) } else { $0.collapsedCourses.insert(id) } }
                    }
                } label: { header }
                .buttonStyle(.plain)
            } else {
                header
            }
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
                ImportProgressCard(session: s, job: job, course: app.course(id: s.courseID), onCancel: { pendingRemoval = PendingRemoval(session: s, verb: "Cancel the import of", isImport: true) }, onDismiss: { app.dismissFailedImport(s.id) })
            } else if app.isInterrupted(s) {
                InterruptedCard(session: s, course: app.course(id: s.courseID), courseColor: app.courseColor(app.course(id: s.courseID)), thumbnail: thumbnail(for: s),
                                canFinish: s.status != .importing || app.canFinishInterruptedImport(s),
                                onResume: { app.resumeInterrupted(s.id) }, onFinish: { app.finishInterrupted(s.id) }, onDiscard: { pendingRemoval = PendingRemoval(session: s, verb: "Discard") })
            } else {
                LectureCard(session: s, course: app.course(id: s.courseID), courseColor: app.courseColor(app.course(id: s.courseID)), thumbnail: thumbnail(for: s), isSelected: selectedSession == s.id, isLive: isLive, liveElapsed: isLive ? app.liveSession?.elapsed ?? 0 : 0)
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
                        Button("Delete…", role: .destructive) { pendingRemoval = PendingRemoval(session: s, verb: "Delete") }
                    }
            }
        }
    }

    private func thumbnail(for s: LectureSession) -> NSImage? {
        guard let deck = s.decks.first else { return nil }
        return thumbnails.thumbnail(sessionID: s.id, fileName: deck.fileName, store: app.services.store)
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

    private func runSearch() {
        nav.searchTextChanged(search: app.services.search, library: app.sessions)
    }

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
            if nav.searchResults.isEmpty {
                if showNoResults && !nav.isSearching {
                    EmptyStateView(symbol: "magnifyingglass", title: "No matches", message: "No matches for “\(nav.searchText)”")
                } else {
                    Color.clear
                }
            } else {
                List(nav.searchResults) { hit in
                    SearchHitRow(hit: hit, session: app.sessions.first { $0.id == hit.sessionID }, course: app.course(id: app.sessions.first { $0.id == hit.sessionID }?.courseID))
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { app.openSession(hit.sessionID, at: hit.time, slide: hit.slide) }
                        .focusable()
                        .onKeyPress(.return) { app.openSession(hit.sessionID, at: hit.time, slide: hit.slide); return .handled }
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { app.openSession(hit.sessionID, at: hit.time, slide: hit.slide) }
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
        // The chips here are inert (the row opens on double-click or ↩): one element, not three buttons.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenSummary)
    }

    private var spokenSummary: String {
        var parts = [session?.title ?? "Lecture", hit.snippet]
        if let t = hit.time { parts.append("at \(TimeFormat.clock(t))") }
        if let s = hit.slide { parts.append("slide \(s)") }
        if let course { parts.append(course.code) }
        parts.append(fieldLabel)
        return parts.joined(separator: ", ")
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

/// Library card for a session being imported: staged progress (Downloading, or Preparing audio for a local file → Transcribing → Summarizing).
struct ImportProgressCard: View {
    var session: LectureSession
    var job: ImportJob
    var course: Course?
    var onCancel: () -> Void
    var onDismiss: () -> Void

    private var stages: [String] {
        if case .mediaSpace = session.source { ["Downloading", "Transcribing", "Summarizing"] } else { ["Preparing audio", "Transcribing", "Summarizing"] }
    }

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
                        .accessibilityLabel("Cancel import")
                }
                Text(job.stageLabel).font(DS.Typo.footnote).foregroundStyle(.secondary).contentTransition(.numericText())
            }
        }
        .padding(DS.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surfaceCard(radius: DS.Radius.card)
        // A group, not one combined element: combining folded the Cancel link into the card's
        // default action, so "activating the progress" cancelled the import (QA Q3-2).
        .accessibilityElement(children: .contain)
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
    /// False for an import interrupted before any transcript was saved: there is nothing to finish.
    var canFinish = true
    var onResume: () -> Void
    var onFinish: () -> Void
    var onDiscard: () -> Void

    private var interruptedLabel: String {
        if session.status == .importing {
            return canFinish ? "Import was interrupted; its transcript was saved" : "Import was interrupted before anything was transcribed"
        }
        return "Interrupted at \(TimeFormat.clock(session.transcript.last?.end ?? session.duration))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            LectureCard(session: session, course: course, courseColor: courseColor, thumbnail: thumbnail, isSelected: false, isLive: false)
            HStack(spacing: DS.Space.s) {
                Image(systemName: "exclamationmark.arrow.circlepath").foregroundStyle(DS.Colors.warning)
                Text(interruptedLabel)
                    .font(DS.Typo.footnote).foregroundStyle(.secondary)
                Spacer()
                if session.status != .importing { Button("Resume", action: onResume).controlSize(.small) }
                if canFinish { Button(session.status == .importing ? "Finish Import" : "Finish", action: onFinish).controlSize(.small) }
                else { Button("Discard", role: .destructive, action: onDiscard).controlSize(.small) }
            }
            .padding(.horizontal, DS.Space.xs)
        }
        .contextMenu {
            if session.status != .importing { Button("Resume Recording", action: onResume) }
            if canFinish { Button("Finish and Summarize", action: onFinish) }
            Divider()
            Button("Discard…", role: .destructive, action: onDiscard)
        }
    }
}

/// Save panels for exports. Rendering runs off the main actor (a long lecture's PDF takes seconds)
/// and a failed write is reported through the app model, never dropped.
@MainActor
enum ExportCoordinator {
    static func exportMarkdown(session: LectureSession, course: Course?) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = "\(session.title).md"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            write(kind: "Markdown notes") { try MarkdownExporter.document(session: session, course: course).write(to: url, atomically: true, encoding: .utf8) }
        }
    }

    static func exportPDF(session: LectureSession, course: Course?) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "\(session.title).pdf"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            write(kind: "PDF") { try PDFExporter.write(session: session, course: course, to: url) }
        }
    }

    private static func write(kind: String, _ work: @escaping @Sendable () throws -> Void) {
        Task {
            do {
                try await Task.detached(priority: .userInitiated, operation: work).value
            } catch {
                AppModelActivation.shared?.exportFailed(kind, error: error)
            }
        }
    }
}
