import SwiftUI
import LecternCore

/// Ask tab: streaming answers with inline citations, suggested prompts, and a scope toggle
/// between this lecture and the whole course (DESIGN.md §4.4, §4.14).
struct AskView: View {
    @Bindable var session: LiveSessionModel
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var composerFocused: Bool
    @State private var scope: AskScope = .lecture
    @State private var placeholder = AskView.placeholders.randomElement() ?? "Ask about this lecture…"

    enum AskScope: String, CaseIterable, Identifiable { case lecture, course; var id: String { rawValue } }
    static let placeholders = ["Ask about this lecture…", "What did I miss in the last 5 minutes?", "Explain slide 12 simply"]

    var body: some View {
        VStack(spacing: 0) {
            if let courseID = session.course?.id {
                Picker("Scope", selection: $scope) {
                    Text("This lecture").tag(AskScope.lecture)
                    Text("Whole course").tag(AskScope.course)
                }
                .pickerStyle(.segmented).controlSize(.small).labelsHidden()
                .padding(.horizontal, DS.Space.m).padding(.vertical, DS.Space.s)
                if scope == .course {
                    let model = app.courseAsk(for: courseID)
                    CourseAskThread(model: model, onOpen: { app.open(courseCitation: $0) })
                        .task { model.prepare(sessions: app.sessions) }
                    Divider()
                    AskComposer(text: Binding(get: { model.draft }, set: { model.draft = $0 }), isAnswering: model.isAnswering, placeholder: "Ask about \(session.courseLabel)…", focused: $composerFocused, onSend: { model.ask(model.draft) }, onCancel: { model.cancel() })
                        .padding(DS.Space.m)
                    Text("Answers cite lectures across the course").font(DS.Typo.footnote).foregroundStyle(.secondary).padding(.bottom, DS.Space.s)
                }
            }
            if scope == .lecture || session.course == nil {
                thread
                Divider()
                AskComposer(text: $session.askDraft, isAnswering: session.isAnswering, placeholder: placeholder, focused: $composerFocused, onSend: { session.ask(session.askDraft) }, onCancel: { session.cancelAsk() })
                    .padding(DS.Space.m)
                Text(footer).font(DS.Typo.footnote).foregroundStyle(.secondary).padding(.bottom, DS.Space.s)
            }
        }
        .onChange(of: composerFocused) { _, f in session.isTypingInAsk = f }
        .onChange(of: session.focusAskRequest) { _, _ in focusComposerSoon() }
        .onAppear { if session.focusAskRequest > 0 { focusComposerSoon() } }
        .onDisappear { session.isTypingInAsk = false }
    }

    /// The composer may not be in the hierarchy yet when the tab switches; focus on the next turn.
    private func focusComposerSoon() {
        Task { @MainActor in
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(60))
            composerFocused = true
        }
    }

    private var footer: String {
        let ask = app.settings.provider(for: .ask)
        return ask.kind == .onDevice ? "On-device · answers cite slides" : "\(ask.kind.displayName) · answers cite slides"
    }

    private var thread: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DS.Space.l) {
                    if session.chat.isEmpty, session.streamingAnswer == nil { suggestions }
                    ForEach(Array(session.chat.enumerated()), id: \.element.id) { i, m in
                        if m.role == .user {
                            UserBubble(text: m.text)
                        } else {
                            AnswerView(message: m, sessionID: session.id, isLast: i == session.chat.count - 1, isLive: session.isLive,
                                       thumbnail: { session.slideImages?.image(page: $0, width: 32) },
                                       onOpen: { _ = session.open($0) }, onRegenerate: { session.regenerateLastAnswer() })
                        }
                    }
                    if let streaming = session.streamingAnswer {
                        StreamingText(committed: AnswerFormatter.attributed(streaming, sessionID: session.id), volatile: nil, isStreaming: true, style: .answer)
                            .font(DS.Typo.body).lineSpacing(DS.Typo.summaryLineSpacing)
                            .id("streaming")
                    }
                    if let error = session.askError {
                        VStack(alignment: .leading, spacing: DS.Space.xs) {
                            Label(error, systemImage: "exclamationmark.triangle").font(DS.Typo.footnote).foregroundStyle(DS.Colors.warning)
                            HStack(spacing: DS.Space.m) {
                                Button("Open Settings") { NotificationCenter.default.post(name: .lecternOpenSettings, object: nil) }
                                Button("Retry") { session.retryAsk() }
                            }
                            .buttonStyle(.link).font(DS.Typo.footnote)
                        }
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(DS.Space.l)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: session.streamingAnswer?.count) { _, _ in proxy.scrollSoon(to: "bottom", anchor: .bottom) }
            .onChange(of: session.chat.count) { _, _ in proxy.scrollSoon(to: "bottom", anchor: .bottom, animation: reduceMotion ? nil : DS.Motion.settle) }
        }
    }

    private var suggestions: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            ForEach(["Catch me up (last 5 min)", "Explain the current slide", "What's important so far?"], id: \.self) { s in
                Button(s) { session.ask(s) }
                    .buttonStyle(.plain)
                    .font(DS.Typo.subheadline)
                    .padding(.horizontal, DS.Space.m).padding(.vertical, DS.Space.xs)
                    .lecternGlass(.regular.interactive(), in: .capsule)
            }
        }
        .padding(.top, DS.Space.s)
    }
}

struct UserBubble: View {
    var text: String
    var body: some View {
        HStack {
            Spacer(minLength: DS.Space.xxxl)
            Text(text)
                .font(DS.Typo.body)
                .padding(.horizontal, DS.Space.m).padding(.vertical, DS.Space.s)
                .background(DS.Colors.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
                .textSelection(.enabled)
        }
    }
}

struct AnswerView: View {
    var message: ChatMessage
    var sessionID: UUID
    var isLast: Bool
    var isLive: Bool
    var thumbnail: (Int) -> NSImage?
    var onOpen: (URL) -> Void
    var onRegenerate: () -> Void
    @State private var hovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            AnswerText(text: message.text, sessionID: sessionID).equatable()
            if !message.citations.isEmpty {
                Divider()
                CitationRow(citations: message.citations, sessionID: sessionID, thumbnail: thumbnail, onOpen: onOpen)
            }
            HStack(spacing: DS.Space.s) {
                Spacer()
                Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(message.text, forType: .string) } label: { Image(systemName: "doc.on.doc") }.help("Copy")
                if !isLive, isLast { Button(action: onRegenerate) { Image(systemName: "arrow.clockwise") }.help("Regenerate") }
            }
            .buttonStyle(.borderless).controlSize(.small).foregroundStyle(.secondary)
            .opacity(hovered ? 1 : 0)
        }
        .onHover { hovered = $0 }
        .animation(DS.Motion.hover, value: hovered)
    }
}

/// One finished answer. Equatable so it is re-parsed only when its text changes: the Ask thread
/// re-renders on every streamed token, and hovering an answer re-renders `AnswerView`.
private struct AnswerText: View, Equatable {
    var text: String
    var sessionID: UUID

    var body: some View {
        // Selectable, link-bearing text is exposed as ONE plain-string element: resolving
        // accessibility labels through its link runs recurses in AppKit (C1 stack overflow).
        Text(AnswerFormatter.attributed(text, sessionID: sessionID))
            .font(DS.Typo.body).lineSpacing(DS.Typo.summaryLineSpacing)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(AnswerFormatter.plainText(text))
    }
}

/// Glass composer: capsule for one line, rounded rect when it grows. ↩ sends, ⇧↩ newline, Esc clears.
struct AskComposer: View {
    @Binding var text: String
    var isAnswering: Bool
    var placeholder: String
    var focused: FocusState<Bool>.Binding
    var onSend: () -> Void
    var onCancel: () -> Void

    private var lines: Int { min(4, max(1, text.split(separator: "\n", omittingEmptySubsequences: false).count)) }
    private var multiline: Bool { lines > 1 }

    var body: some View {
        HStack(alignment: .bottom, spacing: DS.Space.s) {
            // Height is derived from the line count, not measured from the width: an AppKit-backed
            // field whose intrinsic height depends on its width can loop AppKit's constraint pass.
            TextField(placeholder, text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .font(DS.Typo.body)
                .frame(height: CGFloat(lines) * 20)
                .focused(focused)
                .onSubmit { onSend() }
                .onKeyPress(.escape) { text = ""; return .handled }
            Button(action: isAnswering ? onCancel : onSend) {
                Image(systemName: isAnswering ? "stop.circle.fill" : "arrow.up.circle.fill").font(.title2)
            }
            .buttonStyle(.plain)
            .foregroundStyle(text.trimmingCharacters(in: .whitespaces).isEmpty && !isAnswering ? AnyShapeStyle(.tertiary) : AnyShapeStyle(DS.Colors.accent))
            .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty && !isAnswering)
            .keyboardShortcut(.return, modifiers: .command)
            .accessibilityLabel(isAnswering ? "Stop answering" : "Send")
        }
        .padding(.horizontal, DS.Space.m).padding(.vertical, DS.Space.s)
        .lecternGlass(.regular.interactive(), in: multiline ? AnyShape(RoundedRectangle(cornerRadius: DS.Radius.float, style: .continuous)) : AnyShape(Capsule()))
        .animation(DS.Motion.quick, value: multiline)
    }
}
