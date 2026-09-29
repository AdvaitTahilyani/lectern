import SwiftUI
import LecternCore
import UniformTypeIdentifiers

/// "Import Recording…": a file or a MediaSpace lecture, plus course/title/deck (DESIGN.md §4.13).
struct ImportSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var showFileChooser = false
    @State private var showDeckChooser = false

    var body: some View {
        @Bindable var draft = app.importDraft
        VStack(alignment: .leading, spacing: DS.Space.l) {
            Text("Import Recording").font(DS.Typo.title2)
            sourceZone
            if draft.hasSource {
                details
            }
            HStack {
                Text("Importing runs in the background; the lecture appears in the library while it's processed.")
                    .font(DS.Typo.footnote).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Import") { app.startImport() }
                    .lecternProminent()
                    .keyboardShortcut(.defaultAction)
                    .disabled(!draft.hasSource)
            }
        }
        .padding(DS.Space.xxl)
        .frame(width: 560)
        .fileImporter(isPresented: $showFileChooser, allowedContentTypes: [.audiovisualContent]) { r in
            if case .success(let url) = r { draft.setFile(url) }
        }
        .fileImporter(isPresented: $showDeckChooser, allowedContentTypes: [.pdf]) { r in
            if case .success(let url) = r { draft.setDeck(url) }
        }
    }

    private var sourceZone: some View {
        @Bindable var draft = app.importDraft
        return VStack(spacing: DS.Space.m) {
            if let label = draft.sourceLabel {
                HStack(spacing: DS.Space.s) {
                    Image(systemName: sourceSymbol).foregroundStyle(DS.Colors.accent)
                    VStack(alignment: .leading, spacing: DS.Space.xxs) {
                        Text("Found: \(label)").font(DS.Typo.headline).lineLimit(1)
                        if case .mediaSpace(let s) = draft.source, let page = s.pageURL {
                            Text(page.host ?? "MediaSpace").font(DS.Typo.footnote).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("Change") { draft.source = .none }.controlSize(.small)
                }
                if case .mediaSpace = draft.source {
                    Picker("Transcript", selection: $draft.preferCaptions) {
                        Text("Use MediaSpace captions (faster)").tag(true)
                        Text("Transcribe on-device (more accurate)").tag(false)
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                }
            } else {
                VStack(spacing: DS.Space.s) {
                    Image(systemName: "waveform.badge.plus").font(.system(size: 32)).foregroundStyle(.secondary)
                    Text("Drop an audio or video file").font(DS.Typo.title3)
                    HStack(spacing: DS.Space.xs) {
                        Button("Choose…") { showFileChooser = true }.buttonStyle(.link)
                        Text("·").foregroundStyle(.secondary)
                        Button("From MediaSpace…") { app.showMediaSpaceBrowser() }.buttonStyle(.link)
                    }
                    .font(DS.Typo.subheadline)
                }
                .padding(.vertical, DS.Space.l)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(DS.Space.l)
        .background(RoundedRectangle(cornerRadius: DS.Radius.float, style: .continuous).fill(draft.isDragTargeted ? DS.Colors.accent.opacity(0.06) : .clear))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.float, style: .continuous).strokeBorder(draft.isDragTargeted ? AnyShapeStyle(DS.Colors.accent) : AnyShapeStyle(.quaternary), style: StrokeStyle(lineWidth: 2, dash: draft.hasSource ? [] : [6, 6])))
        .onDrop(of: [.fileURL], isTargeted: $draft.isDragTargeted) { providers in
            guard let p = providers.first else { return false }
            let model = app.importDraft
            p.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                var url: URL?
                if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                if let u = item as? URL { url = u }
                guard let url else { return }
                Task { @MainActor in model.setFile(url) }
            }
            return true
        }
    }

    private var sourceSymbol: String {
        if case .mediaSpace = app.importDraft.source { return "play.rectangle.fill" }
        return "waveform"
    }

    private var details: some View {
        @Bindable var draft = app.importDraft
        return VStack(spacing: DS.Space.m) {
            LabeledContent {
                Picker("Course", selection: Binding(get: { draft.courseID ?? app.courses.first?.id ?? UUID() }, set: { draft.courseID = $0 })) {
                    ForEach(app.courses) { c in Text("\(c.code) — \(c.name)").tag(c.id) }
                }
                .labelsHidden()
            } label: { Text("Course").frame(width: 60, alignment: .leading) }
            LabeledContent {
                TextField("Title", text: $draft.title, prompt: Text(draft.suggestedTitle)).textFieldStyle(.roundedBorder)
            } label: { Text("Title").frame(width: 60, alignment: .leading) }
            LabeledContent {
                HStack(spacing: DS.Space.s) {
                    if let images = draft.deckImages, let url = draft.deckURL {
                        SlideImage(image: images.image(page: 1, width: 64), page: 1, radius: DS.Radius.chip).frame(width: 64, height: 36)
                        Text("\(url.lastPathComponent) · \(images.pageCount) slides").font(DS.Typo.footnote).foregroundStyle(.secondary).lineLimit(1)
                        Button { draft.setDeck(nil) } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.tertiary)
                    } else {
                        Button("Choose Slide Deck…") { showDeckChooser = true }.controlSize(.small)
                        Text("Optional").font(DS.Typo.footnote).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            } label: { Text("Slides").frame(width: 60, alignment: .leading) }
        }
        .padding(DS.Space.l)
        .surfaceCard()
    }
}

/// Sheet with the embedded MediaSpace browser.
struct MediaSpaceSheet: View {
    var onFound: (MediaSpaceSource) -> Void
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Illinois MediaSpace").font(DS.Typo.headline)
                Spacer()
                Text("Sign in, then open the lecture you want to import.").font(DS.Typo.footnote).foregroundStyle(.secondary)
                Button("Cancel") { app.mediaSpaceBrowserDidFinish(nil) }.keyboardShortcut(.cancelAction)
            }
            .padding(DS.Space.l)
            Divider()
            app.services.mediaSpaceBrowser.makeBrowser { source in onFound(source) }
        }
        .frame(width: 860, height: 620)
    }
}
