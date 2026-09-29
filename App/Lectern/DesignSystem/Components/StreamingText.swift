import SwiftUI
import LecternCore

/// Renders committed text plus an optional volatile tail (transcript, `.secondary`) or a streaming
/// answer with a caret. Citations in answers become `lectern://` links handled via `openURL`.
struct StreamingText: View {
    enum Style { case transcript, answer }
    var committed: AttributedString
    var volatile: String?
    var isStreaming: Bool
    var style: Style
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let volatile, !volatile.isEmpty, style == .transcript {
            // Volatile text is plain `.secondary` (the DESIGN.md §12 fallback). A 30 Hz per-glyph
            // shimmer re-rendered the transcript column continuously and, combined with window
            // resizes, exhausted AppKit's constraint-update budget for the hosting view.
            (Text(committed) + Text(" ") + Text(volatile).foregroundStyle(DS.Colors.volatileText))
                .accessibilityLabel(accessibilityText)
        } else if style == .answer, isStreaming {
            HStack(alignment: .lastTextBaseline, spacing: 0) {
                Text(committed)
                Caret(animating: !reduceMotion)
            }
        } else {
            Text(committed)
                .contentTransition(.opacity)
        }
    }

    private var accessibilityText: String {
        var s = String(committed.characters)
        if let volatile, !volatile.isEmpty { s += " In progress: \(volatile)" }
        return s
    }
}

/// 6 pt accent caret blinking at 1 Hz (static under Reduce Motion).
struct Caret: View {
    var animating: Bool
    @State private var visible = true
    var body: some View {
        Text("▍")
            .foregroundStyle(DS.Colors.accent)
            .opacity(visible ? 1 : 0)
            .animation(animating ? .easeInOut(duration: 0.5).repeatForever(autoreverses: true) : nil, value: visible)
            .onAppear { if animating { visible = false } }
            .accessibilityHidden(true)
    }
}

/// Builds an `AttributedString` from model output: light Markdown (bold/italic/lists) plus
/// `[S12]` / `[T14:32]` citation tokens rendered as inline `lectern://` links.
nonisolated enum AnswerFormatter {
    static func attributed(_ text: String, sessionID: UUID, monoFont: Font = DS.Typo.mono) -> AttributedString {
        var result = AttributedString()
        let pattern = /\[([SsTt])\s*([^\[\]]{1,12})\]/
        var cursor = text.startIndex
        for match in text.matches(of: pattern) {
            result.append(markdown(String(text[cursor..<match.range.lowerBound])))
            let kind = match.1.lowercased()
            let value = String(match.2).trimmingCharacters(in: .whitespaces)
            var link = AttributedString()
            if kind == "s", let n = Int(value) {
                link = AttributedString("Slide \(n)")
                link.link = LecternURL.slide(session: sessionID, page: n)
            } else if kind == "t", let secs = TimeFormat.parse(value) {
                link = AttributedString(TimeFormat.clock(secs))
                link.link = LecternURL.time(session: sessionID, seconds: secs)
                link.font = monoFont
            } else {
                link = AttributedString(String(text[match.range]))
            }
            link.foregroundColor = .accentColor
            link.underlineStyle = nil
            // Avoid doubled spaces around a citation glued to punctuation.
            result.append(AttributedString(" "))
            result.append(link)
            cursor = match.range.upperBound
        }
        result.append(markdown(String(text[cursor...])))
        return result
    }

    private static func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}
