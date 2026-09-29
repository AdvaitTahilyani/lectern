import SwiftUI
import LecternCore
import UniformTypeIdentifiers

/// Pre-lecture setup: course & title, deck drop zone, mic + models, Start (DESIGN.md §4.2).
struct SetupView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openSettings) private var openSettings
    @Namespace private var namespace
    @State private var showChooser = false
    @State private var creatingCourse = false
    @State private var isStarting = false

    var body: some View {
        @Bindable var setup = app.setup
        ScrollView {
            VStack(spacing: DS.Space.xl) {
                courseAndTitle
                DeckDropZone(setup: setup, namespace: namespace) { showChooser = true }
                if setup.deck == nil, setup.indexing == nil {
                    Text("No deck — slide following and slide citations will be off")
                        .font(DS.Typo.footnote).foregroundStyle(.secondary)
                }
                inputAndModels
                startButton
            }
            .frame(maxWidth: 720)
            .padding(DS.Space.xxxl)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 560)
        }
        .background(DS.Colors.canvas)
        .navigationTitle("New Lecture")
        .toolbarTitleDisplayMode(.inline)
        .onAppear { setup.beginMonitoring() }
        .onDisappear { if !isStarting { setup.endMonitoring() } }
        .fileImporter(isPresented: $showChooser, allowedContentTypes: allowedTypes) { result in
            if case .success(let url) = result { setup.loadDeck(url: url) }
        }
        .sheet(isPresented: $creatingCourse) { CourseEditorSheet(course: nil) }
        .onChange(of: app.courses.count) { old, new in
            if new > old, let last = app.courses.last { setup.courseID = last.id }
        }
    }

    private var allowedTypes: [UTType] {
        app.setup.acceptedExtensions.compactMap { $0 == "pdf" ? .pdf : UTType(filenameExtension: $0) }
    }

    // MARK: Sections

    private var courseAndTitle: some View {
        @Bindable var setup = app.setup
        return VStack(spacing: DS.Space.m) {
            LabeledContent {
                Picker("Course", selection: Binding(get: { setup.courseID ?? UUID(uuid: UUID_NULL) }, set: { id in
                    if id == UUID(uuid: UUID_NULL) { creatingCourse = true } else { setup.courseID = id }
                })) {
                    ForEach(app.courses) { c in
                        Text("\(c.code) — \(c.name)").tag(c.id)
                    }
                    Divider()
                    Text("New Course…").tag(UUID(uuid: UUID_NULL))
                }
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Text("Course").frame(width: 60, alignment: .leading)
            }
            LabeledContent {
                TextField("Lecture title", text: $setup.title, prompt: Text(setup.resolvedTitle))
                    .textFieldStyle(.roundedBorder)
                    .font(DS.Typo.title3)
                    .contentTransition(.opacity)
                    .onChange(of: setup.title) { _, _ in if !setup.showSuggestedGlint { setup.userEditedTitle() } }
                    .overlay(alignment: .trailing) {
                        if setup.showSuggestedGlint {
                            Image(systemName: "sparkles").foregroundStyle(DS.Colors.accent).font(DS.Typo.caption)
                                .padding(.trailing, DS.Space.s)
                                .help("Suggested from the slide deck")
                                .transition(.opacity)
                        }
                    }
            } label: {
                Text("Title").frame(width: 60, alignment: .leading)
            }
        }
        .padding(DS.Space.l)
        .surfaceCard()
    }

    private var inputAndModels: some View {
        @Bindable var setup = app.setup
        return VStack(spacing: DS.Space.m) {
            if setup.microphonePermission == .granted {
                HStack(spacing: DS.Space.m) {
                    Image(systemName: "mic.fill").foregroundStyle(.secondary)
                    Picker("Microphone", selection: Binding(get: { setup.inputDeviceID ?? "" }, set: { setup.changeInputDevice($0) })) {
                        ForEach(setup.inputDevices) { d in Text(d.name).tag(d.id) }
                    }
                    .labelsHidden()
                    Spacer()
                    LevelMeter(level: setup.level, peak: setup.peak)
                }
            } else {
                HStack(spacing: DS.Space.m) {
                    Image(systemName: "mic.slash").foregroundStyle(DS.Colors.warning)
                    Text("Lectern needs microphone access").font(DS.Typo.subheadline)
                    Spacer()
                    if setup.microphonePermission == .denied {
                        Button("Open System Settings") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!) }
                    } else {
                        Button("Allow…") { setup.requestMicrophoneAccess() }
                    }
                }
                .padding(DS.Space.s)
                .background(DS.Colors.warning.opacity(0.12), in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
            }
            Divider()
            ModelStatusBadge(status: app.modelStatus, style: .expanded, detail: modelDetail, onDetails: { openSettings() })
        }
        .padding(DS.Space.l)
        .surfaceCard()
    }

    private var modelDetail: String {
        let summaries = app.settings.provider(for: .summaries)
        let ask = app.settings.provider(for: .ask)
        var parts = ["Summaries: \(summaries.kind == .onDevice ? app.shortModelName(summaries.model) : summaries.kind.displayName)"]
        if ask.kind != summaries.kind || ask.model != summaries.model { parts.append("Ask: \(ask.kind == .onDevice ? app.shortModelName(ask.model) : ask.kind.displayName)") }
        return parts.joined(separator: " · ")
    }

    private var startButton: some View {
        Button {
            isStarting = true
            app.startLecture()
        } label: {
            HStack(spacing: DS.Space.s) {
                LiveDot(state: isStarting ? .recording : .idle, size: DS.Size.liveDot)
                    .overlay(Circle().fill(DS.Colors.recording).frame(width: DS.Size.liveDot, height: DS.Size.liveDot).opacity(isStarting ? 0 : 1))
                Text("Start Lecture")
                Text("⌘↩").font(DS.Typo.caption).foregroundStyle(.secondary).padding(.leading, DS.Space.xs)
            }
            .padding(.horizontal, DS.Space.m)
        }
        .lecternProminent()
        .controlSize(.extraLarge)
        .keyboardShortcut(.defaultAction)
        .disabled(!app.setup.canStart || app.liveSession != nil)
        .help(app.liveSession != nil ? "A lecture is already recording" : "Start Lecture (⌘↩)")
        .padding(.top, DS.Space.s)
    }
}
