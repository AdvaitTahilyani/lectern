import AppKit

/// Whether a text field is being edited. The session's single-key shortcuts (Space, 1–4, S, Esc, arrows)
/// are `onKeyPress` handlers on views that sit above the text fields, so they see the keys typed into a
/// field too, unless they check this first. It reads the window's first responder rather than a flag
/// each field would have to remember to set: while any `TextField`, `TextEditor`, search field or the
/// title editor is being edited, the first responder is its field editor (an `NSText`), whatever view
/// owns it, and any future field is covered without further code.
@MainActor
enum TextInputFocus {
    /// True when `responder` is a field editor, text view or other text-input client.
    nonisolated static func isTextInput(_ responder: NSResponder?) -> Bool {
        responder is NSText || responder is NSTextInputClient
    }

    /// True when the key window is editing text.
    static var isActive: Bool { isTextInput(NSApp.keyWindow?.firstResponder) }
}

/// Which session-wide keys act. Pure so the rules can be tested.
nonisolated enum SessionShortcuts {
    /// Quiz answers (1–4), Snooze (S), Skip (Esc) and slide arrows: never while typing.
    static func singleKeysAllowed(textInputActive: Bool) -> Bool { !textInputActive }

    /// Space pauses or resumes a live recording only when the session view itself holds focus and nothing
    /// is being typed. Requiring the focus (rather than "any key while the window is up") keeps a stray
    /// Space from stopping the recording while focus is in a field, a button or another pane's list,
    /// each of which gives Space its own meaning.
    static func spacePausesRecording(isLive: Bool, textInputActive: Bool, rootFocused: Bool) -> Bool {
        isLive && rootFocused && !textInputActive
    }
}
