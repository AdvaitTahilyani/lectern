import SwiftUI
import LecternCore

/// Renders committed transcript text plus an optional volatile tail (`.secondary`). Streamed answers use
/// `StreamingAnswerBody` (AnswerText.swift).
struct StreamingText: View {
    var committed: AttributedString
    var volatile: String?

    var body: some View {
        if let volatile, !volatile.isEmpty {
            // Volatile text is plain `.secondary` (the DESIGN.md §12 fallback). A 30 Hz per-glyph
            // shimmer re-rendered the transcript column continuously and, combined with window
            // resizes, exhausted AppKit's constraint-update budget for the hosting view.
            (Text(committed) + Text(" ") + Text(volatile).foregroundStyle(DS.Colors.volatileText))
                .accessibilityLabel(accessibilityText)
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
