import SwiftUI
import LecternCore

// Rendering of model-written text: Markdown blocks (headings, bullet and numbered lists with nesting,
// code) and citation markers as inline links. Parsing is the pure `AnswerMarkup` in LecternCore.

/// Decides which citation markers in an answer become links. An inline marker links only when it matches
/// the answer's validated citation list (the same list that fills the chips under it), so a slide or time
/// the model invented can never be clickable (B31), and a saved course answer keeps opening the lecture it
/// was written about however the course is reordered later (B24).
nonisolated enum CitationResolver: Hashable, Sendable {
    /// Nothing links: a streaming answer, whose list is not validated yet, and text with no citations.
    case unlinked
    /// An answer in one lecture's Ask thread: `citations` is the message's validated list.
    case lecture(sessionID: UUID, citations: [Citation])
    /// A course answer: `citations` is the answer's persisted list, each with the lecture it points into.
    case course(citations: [CourseCitation])

    /// Transcript citations this close to a validated one are the same source (the brain merges them).
    private static let sameSourceSeconds: TimeInterval = 10

    func url(for token: MarkerToken) -> URL? {
        switch self {
        case .unlinked:
            return nil
        case .lecture(let sessionID, let citations):
            guard token.lecture == nil else { return nil }
            switch token.citation {
            case .slide(let n):
                return citations.contains(.slide(n)) ? LecternURL.slide(session: sessionID, page: n) : nil
            case .time(let t):
                let known = citations.contains { if case .time(let k) = $0 { abs(k - t) < Self.sameSourceSeconds } else { false } }
                return known ? LecternURL.time(session: sessionID, seconds: t) : nil
            }
        case .course(let citations):
            guard let ordinal = token.lecture,
                  let match = citations.first(where: { $0.ordinal == ordinal && $0.citation == token.citation }) else { return nil }
            return CourseCitationURL.url(for: match)
        }
    }

    /// Link text: "Slide 12", "14:32", or in a course "Lecture 9 · Slide 12".
    static func label(for token: MarkerToken) -> String {
        let what: String
        switch token.citation {
        case .slide(let n): what = "Slide \(n)"
        case .time(let t): what = TimeFormat.clock(t)
        }
        return token.lecture.map { "Lecture \($0) · \(what)" } ?? what
    }
}

nonisolated enum AnswerRendering {
    /// One line of answer text as styled text: Markdown emphasis and `code`, plus each citation in a bracket
    /// as its own link (or, when the resolver does not vouch for it, as plain secondary text).
    static func attributed(_ line: String, resolver: CitationResolver, monoFont: Font = DS.Typo.mono) -> AttributedString {
        var result = AttributedString()
        for segment in AnswerMarkup.inline(line) {
            switch segment {
            case .text(let text):
                result.append(markdown(text))
            case .citations(_, let tokens):
                if let last = result.characters.last, !last.isWhitespace { result.append(AttributedString(" ")) }
                for (i, token) in tokens.enumerated() {
                    if i > 0 { result.append(AttributedString(", ")) }
                    var part = AttributedString(CitationResolver.label(for: token))
                    if let url = resolver.url(for: token) {
                        part.link = url
                        part.foregroundColor = .accentColor
                        part.underlineStyle = nil
                        if case .time = token.citation { part.font = monoFont }
                    } else {
                        part.foregroundColor = .secondary
                    }
                    result.append(part)
                }
            }
        }
        return result
    }

    /// Inline Markdown. Code spans get the monospaced font explicitly (the text view otherwise draws them
    /// in the surrounding font).
    private static func markdown(_ text: String) -> AttributedString {
        guard var parsed = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else {
            return AttributedString(text)
        }
        for run in parsed.runs where run.inlinePresentationIntent?.contains(.code) == true {
            parsed[run.range].font = DS.Typo.monoBody
        }
        return parsed
    }
}

/// A model answer (or any model-written text) as blocks. Re-parsed only when its text or resolver
/// changes. The whole body is one accessibility element with a plain-string label: resolving labels
/// through link runs recurses in AppKit (C1 stack overflow), and list structure reads well as lines.
struct AnswerBody: View, Equatable {
    var text: String
    var resolver: CitationResolver = .unlinked
    var isStreaming = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static func == (a: AnswerBody, b: AnswerBody) -> Bool { a.text == b.text && a.resolver == b.resolver && a.isStreaming == b.isStreaming }

    var body: some View {
        let blocks = AnswerMarkup.blocks(text)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { i, block in
                row(block, isLast: i == blocks.count - 1)
                    .padding(.top, i == 0 ? 0 : spacing(after: blocks[i - 1], before: block))
            }
            if blocks.isEmpty, isStreaming { Caret(animating: !reduceMotion) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(AnswerSelection(enabled: !isStreaming))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(AnswerMarkup.plainText(text))
    }

    private func spacing(after previous: AnswerBlock, before block: AnswerBlock) -> CGFloat {
        if case .item = previous, case .item = block { return DS.Space.xs }
        if case .heading = block { return DS.Space.m }
        return DS.Space.s
    }

    @ViewBuilder private func row(_ block: AnswerBlock, isLast: Bool) -> some View {
        switch block {
        case .heading(let level, let line):
            styled(line, isLast: isLast)
                .font(level <= 2 ? DS.Typo.headline : DS.Typo.subheadline.weight(.semibold))
        case .paragraph(let line):
            styled(line, isLast: isLast)
        case .item(let level, let number, let line):
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.xs) {
                Text(number.map { "\($0)." } ?? "•")
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 14, alignment: .trailing)
                styled(line, isLast: isLast)
            }
            .padding(.leading, CGFloat(level) * DS.Space.l)
        case .code(let code):
            HStack(alignment: .lastTextBaseline, spacing: 0) {
                Text(code).font(DS.Typo.monoBody).fixedSize(horizontal: false, vertical: true)
                if isLast, isStreaming { Caret(animating: !reduceMotion) }
            }
            .padding(DS.Space.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
        }
    }

    private func styled(_ line: String, isLast: Bool) -> some View {
        HStack(alignment: .lastTextBaseline, spacing: 0) {
            Text(AnswerRendering.attributed(line, resolver: resolver)).fixedSize(horizontal: false, vertical: true)
            if isLast, isStreaming { Caret(animating: !reduceMotion) }
        }
    }
}

/// The streaming answer: re-parses at most about ten times a second however fast tokens arrive (P10).
/// The latest text is always shown within one interval, including the final tokens.
struct StreamingAnswerBody: View {
    var text: String
    @State private var shown = ""
    @State private var throttle = Throttle()

    var body: some View {
        AnswerBody(text: shown, resolver: .unlinked, isStreaming: true)
            .equatable()
            .onChange(of: text, initial: true) { _, new in
                throttle.latest = new
                throttle.schedule { shown = $0 }
            }
            .onDisappear { throttle.cancel() }
    }

    /// Leading-edge, then at most one more update per interval.
    @MainActor final class Throttle {
        var latest = ""
        private var task: Task<Void, Never>?
        private let interval: Duration = .milliseconds(100)

        func schedule(_ apply: @escaping @MainActor (String) -> Void) {
            guard task == nil else { return }
            apply(latest)
            task = Task { [weak self] in
                try? await Task.sleep(for: self?.interval ?? .milliseconds(100))
                guard let self, !Task.isCancelled else { return }
                task = nil
                apply(latest)
            }
        }

        func cancel() { task?.cancel(); task = nil }
    }
}

/// Collapses a burst of "scroll to the end" requests (one per streamed token) into one per interval.
@MainActor
final class ScrollCoalescer {
    private var pending = false
    private let interval: Duration = .milliseconds(120)

    func request(_ action: @escaping @MainActor () -> Void) {
        guard !pending else { return }
        pending = true
        Task { [weak self] in
            try? await Task.sleep(for: self?.interval ?? .milliseconds(120))
            self?.pending = false
            action()
        }
    }
}

/// Selectable once the answer is complete (a streaming answer is rebuilt several times a second).
private struct AnswerSelection: ViewModifier {
    var enabled: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if enabled { content.textSelection(.enabled) } else { content.textSelection(.disabled) }
    }
}
