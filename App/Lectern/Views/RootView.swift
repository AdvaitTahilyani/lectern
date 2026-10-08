import SwiftUI
import LecternCore
import UniformTypeIdentifiers

/// Main window: sidebar + detail navigation stack (Library → Setup / Session).
struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(\.controlActiveState) private var controlActiveState
    @State private var didCheckOnboarding = false
    /// This window's own navigation (sidebar, screen, search); other windows have theirs (B32).
    @State private var nav = WindowNavigation(columnVisibility: AppModelActivation.shared.map { $0.preferences.sidebarVisible ? .all : .detailOnly } ?? .all)

    var body: some View {
        @Bindable var app = app
        @Bindable var nav = nav
        NavigationSplitView(columnVisibility: $nav.columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: DS.Layout.sidebar.min, ideal: DS.Layout.sidebar.ideal, max: DS.Layout.sidebar.max)
        } detail: {
            // Exactly one of Library / Setup / Session is in the hierarchy (a NavigationStack kept
            // the Library rendered underneath a session and it bled through — QA V1).
            ZStack {
                switch nav.path.last {
                case nil:
                    LibraryView().transition(.opacity)
                case .setup:
                    SetupView().backToLibrary(app).transition(.opacity)
                case .session(let id):
                    if let model = app.session(for: id) {
                        LiveSessionView(session: model).backToLibrary(app).transition(.opacity)
                    } else {
                        EmptyStateView(symbol: "questionmark.folder", title: "Lecture not found", style: .full).backToLibrary(app)
                    }
                }
            }
            .animation(DS.Motion.reduced, value: nav.path.last)
        }
        .navigationSplitViewStyle(.balanced)
        .environment(nav)
        .task { await app.loadLibraryOnce() }
        .onAppear {
            app.register(nav)
            app.openMainWindow = { openWindow(id: "main") }
            checkOnboarding()
        }
        .onDisappear { app.unregister(nav) }
        .onChange(of: controlActiveState, initial: true) { _, state in if state == .key { app.windowBecameKey(nav) } }
        // The window hosting a recording hides its sidebar itself; that is not the user's preference.
        .onChange(of: nav.columnVisibility) { _, v in if nav !== app.liveWindow, nav.isKey || nav === app.activeNavigation { app.updatePreferences { $0.sidebarVisible = v != .detailOnly } } }
        .onReceive(NotificationCenter.default.publisher(for: .lecternOpenOnboarding)) { _ in openWindow(id: "onboarding") }
        .onReceive(NotificationCenter.default.publisher(for: .lecternOpenSettings)) { _ in openSettings() }
        // The import flow belongs to the window that started it.
        .sheet(isPresented: Binding(get: { app.showImportSheet && app.importPresenter === nav }, set: { app.showImportSheet = $0 })) { ImportSheet().environment(app) }
        .sheet(isPresented: Binding(get: { app.importDraft.showMediaSpace && app.importPresenter === nav }, set: { if !$0 { app.mediaSpaceBrowserDidFinish(nil) } })) {
            MediaSpaceSheet { source in app.mediaSpaceBrowserDidFinish(source) }.environment(app)
        }
    }

    private func checkOnboarding() {
        guard !didCheckOnboarding else { return }
        didCheckOnboarding = true
        if !app.settings.hasCompletedOnboarding {
            openWindow(id: "onboarding")
            dismissWindow(id: "main")
        }
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @Environment(AppModel.self) private var app
    @Environment(WindowNavigation.self) private var nav
    @Environment(\.openSettings) private var openSettings
    @State private var editingCourse: Course?
    @State private var creatingCourse = false
    @State private var deletingCourse: Course?

    var body: some View {
        @Bindable var nav = nav
        List(selection: $nav.sidebarSelection) {
            Label("All Lectures", systemImage: "books.vertical").tag(SidebarItem.all)
            Section("Courses") {
                ForEach(app.courses) { course in
                    HStack(spacing: DS.Space.s) {
                        Circle().fill(app.courseColor(course)).frame(width: 8, height: 8)
                        Text(course.code).font(DS.Typo.headline)
                    }
                    .help(course.name)
                    .badge(app.lectureCount(in: course.id))
                    .tag(SidebarItem.course(course.id))
                    .contextMenu {
                        Button("Ask \(course.code)…") { nav.sidebarSelection = .course(course.id); nav.showCourseAsk = true }
                        Divider()
                        Button("Rename…") { editingCourse = course }
                        Button("Slides folder…") { app.chooseSlidesFolder(for: course.id) }
                            .help(course.slidesFolder.map { SlidesFolderPanel.displayPath($0) } ?? "Choose where this course's slide decks live")
                        Menu("Change Color") {
                            ForEach(Array(DS.Colors.course.enumerated()), id: \.offset) { i, color in
                                Button { app.recolorCourse(course.id, hex: Self.hex(for: i)) } label: {
                                    Label(Self.colorNames[i], systemImage: "circle.fill")
                                }
                                .tint(color)
                            }
                        }
                        Divider()
                        Button("Delete Course…", role: .destructive) { deletingCourse = course }
                    }
                }
                Button { creatingCourse = true } label: {
                    Label("New Course…", systemImage: "plus").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            Button { openSettings() } label: {
                ModelStatusBadge(status: app.modelStatus, style: .compact)
                    .padding(.horizontal, DS.Space.l)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .help("Model status — opens Settings › Models")
            .padding(.vertical, DS.Space.xs)
        }
        .sheet(item: $editingCourse) { course in CourseEditorSheet(course: course) }
        .sheet(isPresented: $creatingCourse) { CourseEditorSheet(course: nil) }
        .confirmationDialog(deletingCourse.map { "Delete \($0.code)?" } ?? "", isPresented: Binding(get: { deletingCourse != nil }, set: { if !$0 { deletingCourse = nil } }), titleVisibility: .visible) {
            // A recording or import in the course would be orphaned by deleting it, so the
            // destructive button is withheld until that work is finished or cancelled.
            if deletingCourse.flatMap({ app.courseDeletionBlocker($0.id) }) == nil {
                Button(Self.deleteCourseTitle(lectures: deletingCourse.map { app.lectureCount(in: $0.id) } ?? 0), role: .destructive) {
                    if let c = deletingCourse { app.deleteCourse(c.id) }
                    deletingCourse = nil
                }
            }
            Button("Cancel", role: .cancel) { deletingCourse = nil }
        } message: {
            Text(deletingCourse.flatMap { app.courseDeletionBlocker($0.id) } ?? "This moves the course's lectures to the Trash and removes the course, including transcripts and takeaways.")
        }
    }

    static func deleteCourseTitle(lectures: Int) -> String {
        "Delete Course and \(lectures) Lecture\(lectures == 1 ? "" : "s")"
    }

    static let colorNames = ["Indigo", "Teal", "Orange", "Pink", "Green", "Purple", "Brown", "Cyan"]
    static func hex(for index: Int) -> String {
        ["#5B5FEF", "#1A8C8C", "#E5731A", "#E0457B", "#2FA84F", "#8E44AD", "#8B5E3C", "#1FA7C9"][index % 8]
    }
}

/// Inline sheet for creating/renaming a course.
struct CourseEditorSheet: View {
    var course: Course?
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var name = ""
    @State private var colorIndex = 0
    @State private var slidesFolder: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.l) {
            Text(course == nil ? "New Course" : "Edit Course").font(DS.Typo.title3)
            Form {
                TextField("Code", text: $code, prompt: Text("CS 421"))
                TextField("Name", text: $name, prompt: Text("Programming Languages & Compilers"))
                LabeledContent("Slides folder") {
                    HStack(spacing: DS.Space.s) {
                        if let slidesFolder {
                            Label(slidesFolder.lastPathComponent, systemImage: "folder")
                                .lineLimit(1).truncationMode(.middle)
                                .help(SlidesFolderPanel.displayPath(slidesFolder))
                            Button { self.slidesFolder = nil } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.plain).foregroundStyle(.tertiary)
                                .help("Stop suggesting decks from this folder").accessibilityLabel("Clear slides folder")
                        } else {
                            Text("None").foregroundStyle(.secondary)
                        }
                        Button("Choose…") { chooseFolder() }.controlSize(.small)
                    }
                }
                if course == nil {
                    LabeledContent("Color") {
                        HStack(spacing: DS.Space.s) {
                            ForEach(Array(DS.Colors.course.enumerated()), id: \.offset) { i, color in
                                Button { colorIndex = i } label: {
                                    Circle().fill(color).frame(width: 18, height: 18)
                                        .overlay(Circle().strokeBorder(.primary, lineWidth: colorIndex == i ? 2 : 0).padding(-3))
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(SidebarView.colorNames[i])
                            }
                        }
                    }
                }
            }
            .formStyle(.columns)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(course == nil ? "Create" : "Save") {
                    if let course {
                        app.renameCourse(course.id, code: code, name: name)
                        app.setSlidesFolder(slidesFolder, for: course.id)
                    } else {
                        app.addCourse(code: code, name: name, colorHex: SidebarView.hex(for: colorIndex), slidesFolder: slidesFolder)
                    }
                    dismiss()
                }
                .lecternProminent()
                .keyboardShortcut(.defaultAction)
                .disabled(code.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(DS.Space.xxl)
        .frame(width: 420)
        .onAppear { code = course?.code ?? ""; name = course?.name ?? ""; slidesFolder = course?.slidesFolder }
    }

    private func chooseFolder() {
        let draft = Course(code: code.isEmpty ? "this course" : code, name: name, slidesFolder: slidesFolder)
        if let folder = SlidesFolderPanel.choose(for: draft) { slidesFolder = folder }
    }
}

private extension View {
    /// Our own back affordance (there is no NavigationStack under the detail column).
    func backToLibrary(_ app: AppModel) -> some View {
        toolbar {
            ToolbarItem(placement: .navigation) {
                Button { app.goBack() } label: { Label("Back to Library", systemImage: "chevron.left") }
                    .help("Back to Library")
            }
        }
    }
}
