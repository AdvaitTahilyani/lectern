import SwiftUI
import LecternCore

/// Course-wide Ask panel (DESIGN.md §4.14): questions across every lecture of a course, with
/// "Lecture 8 · Slide 12" citations that open the cited lecture.
struct CourseAskView: View {
    var model: CourseAskModel
    var course: Course?
    @Environment(AppModel.self) private var app
    @FocusState private var composerFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: DS.Space.s) {
                Image(systemName: "sparkle.magnifyingglass").foregroundStyle(DS.Colors.accent)
                Text("Ask \(course?.code ?? "course")").font(DS.Typo.headline)
                Spacer()
                Text("\(model.lectures.count) lecture\(model.lectures.count == 1 ? "" : "s")").font(DS.Typo.footnote).foregroundStyle(.secondary)
                if !model.answers.isEmpty {
                    Button { model.clearHistory() } label: { Image(systemName: "trash") }.buttonStyle(.plain).foregroundStyle(.secondary).help("Clear history").accessibilityLabel("Clear history")
                }
            }
            .padding(DS.Space.l)
            Divider()
            CourseAskThread(model: model, onOpen: { app.open(courseCitation: $0) })
            Divider()
            AskComposer(text: Binding(get: { model.draft }, set: { model.draft = $0 }), isAnswering: model.isAnswering, placeholder: "Ask about \(course?.code ?? "this course")…", focused: $composerFocused, onSend: { model.ask(model.draft) }, onCancel: { model.cancel() })
                .padding(DS.Space.m)
            Text("Answers cite lectures, slides and timestamps across the course").font(DS.Typo.footnote).foregroundStyle(.secondary).padding(.bottom, DS.Space.s)
        }
        .onAppear { Task { @MainActor in await Task.yield(); try? await Task.sleep(for: .milliseconds(60)); composerFocused = true } }
        .task(id: app.sessions.count) { model.prepare(sessions: app.sessions) }
    }
}

struct CourseAskThread: View {
    var model: CourseAskModel
    var onOpen: (CourseCitation) -> Void
    /// A streamed token changes the answer's length; scrolling follows at most every ~100 ms (P10).
    @State private var scrollCoalescer = ScrollCoalescer()

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DS.Space.l) {
                    if model.answers.isEmpty, model.pendingQuestion == nil {
                        suggestions
                    }
                    ForEach(model.answers) { a in
                        UserBubble(text: a.question)
                        answerView(text: a.text, citations: a.citations, streaming: false)
                    }
                    if let q = model.pendingQuestion {
                        UserBubble(text: q)
                        answerView(text: model.streaming ?? "", citations: [], streaming: true).id("streaming")
                    }
                    if let error = model.error {
                        HStack(spacing: DS.Space.s) {
                            Image(systemName: "exclamationmark.triangle").foregroundStyle(DS.Colors.warning)
                            Text(error).font(DS.Typo.footnote)
                            Button("Retry") { model.retry() }.buttonStyle(.link).font(DS.Typo.footnote)
                        }
                    }
                    if let historyError = model.historyError {
                        HStack(spacing: DS.Space.s) {
                            Image(systemName: "exclamationmark.triangle").foregroundStyle(DS.Colors.warning)
                            Text(historyError).font(DS.Typo.footnote)
                            Button("Retry") { model.retryHistory() }.buttonStyle(.link).font(DS.Typo.footnote)
                        }
                    }
                }
                .padding(DS.Space.l)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: model.streaming?.count) { _, _ in scrollCoalescer.request { proxy.scrollSoon(to: "streaming", anchor: .bottom) } }
        }
    }

    @ViewBuilder private var suggestions: some View {
        if !model.suggestions.isEmpty {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                Text("Try").font(DS.Typo.caption).foregroundStyle(.secondary)
                ForEach(model.suggestions, id: \.self) { s in
                    Button(s) { model.ask(s) }
                        .buttonStyle(.plain)
                        .font(DS.Typo.subheadline)
                        .padding(.horizontal, DS.Space.m).padding(.vertical, DS.Space.xs)
                        .lecternGlass(.regular.interactive(), in: .capsule)
                }
            }
        }
    }

    private func answerView(text: String, citations: [CourseCitation], streaming: Bool) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            if streaming {
                StreamingAnswerBody(text: text)
            } else {
                AnswerBody(text: text, resolver: .course(citations: citations)).equatable()
            }
            if !citations.isEmpty {
                Divider()
                FlowLayout(spacing: DS.Space.s) {
                    ForEach(Array(citations.enumerated()), id: \.offset) { _, c in
                        CourseCitationChip(citation: c, title: model.lectureTitle(of: c)) { onOpen(c) }
                    }
                }
            }
        }
        .font(DS.Typo.body)
        .lineSpacing(DS.Typo.summaryLineSpacing)
        .environment(\.openURL, OpenURLAction { url in
            guard let c = CourseCitationURL.parse(url) else { return .systemAction }
            onOpen(c)
            return .handled
        })
    }
}

struct CourseCitationChip: View {
    var citation: CourseCitation
    var title: String
    var action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.Space.xs) {
                Text("Lecture \(citation.ordinal)").fontWeight(.medium)
                Text("·").foregroundStyle(.secondary)
                switch citation.citation {
                case .slide(let n): Text("Slide \(n)")
                case .time(let t): Text(TimeFormat.clock(t)).font(DS.Typo.mono)
                }
            }
            .font(DS.Typo.caption)
            .padding(.horizontal, DS.Space.s)
            .frame(height: 22)
            .foregroundStyle(DS.Colors.accent)
            .background(DS.Colors.accent.opacity(hovered ? 0.2 : 0.12), in: RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(title)
        .accessibilityLabel("Lecture \(citation.ordinal), \(locator), \(title)")
    }

    private var locator: String {
        switch citation.citation {
        case .slide(let n): "slide \(n)"
        case .time(let t): "at \(TimeFormat.clock(t))"
        }
    }
}

/// `lectern://course/<session>/<ordinal>/slide/<n>` and `/t/<s>` links inside course answers.
nonisolated enum CourseCitationURL {
    static func url(for c: CourseCitation) -> URL {
        switch c.citation {
        case .slide(let n): URL(string: "lectern://course/\(c.sessionID.uuidString)/\(c.ordinal)/slide/\(n)")!
        case .time(let t): URL(string: "lectern://course/\(c.sessionID.uuidString)/\(c.ordinal)/t/\(TimeFormat.wholeSeconds(t))")!
        }
    }

    static func parse(_ url: URL) -> CourseCitation? {
        guard url.scheme == "lectern", url.host == "course" else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count == 4, let id = UUID(uuidString: parts[0]), let ordinal = Int(parts[1]) else { return nil }
        switch parts[2] {
        case "slide": return Int(parts[3]).map { CourseCitation(sessionID: id, ordinal: ordinal, citation: .slide($0)) }
        case "t": return Double(parts[3]).map { CourseCitation(sessionID: id, ordinal: ordinal, citation: .time($0)) }
        default: return nil
        }
    }
}
