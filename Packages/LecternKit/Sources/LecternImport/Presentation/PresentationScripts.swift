/// AppleScript sources for exporting presentations to PDF. Paths arrive through `argv`, so no
/// string escaping is needed.
enum PresentationScripts {
    /// Separates presenter notes in the script result.
    static let noteSeparator = "\u{1E}"

    /// argv: input path, output PDF path, "yes"/"no" (return presenter notes).
    /// Result: one presenter-notes string per slide joined by `noteSeparator`, or empty.
    static let keynote = """
    on run argv
      set inPath to item 1 of argv
      set outPath to item 2 of argv
      set wantNotes to (item 3 of argv) is "yes"
      set notesText to ""
      tell application "Keynote"
        set theDoc to open (POSIX file inPath)
        try
          if wantNotes then
            set noteList to {}
            repeat with theSlide in slides of theDoc
              set end of noteList to (presenter notes of theSlide) as text
            end repeat
            set AppleScript's text item delimiters to "\(noteSeparator)"
            set notesText to noteList as text
            set AppleScript's text item delimiters to ""
          end if
          export theDoc to (POSIX file outPath) as PDF
        on error errMsg number errNum
          try
            close theDoc saving no
          end try
          error errMsg number errNum
        end try
        close theDoc saving no
      end tell
      return notesText
    end run
    """

    /// argv: input path, output PDF path.
    static let powerPoint = """
    on run argv
      set inPath to item 1 of argv
      set outPath to item 2 of argv
      tell application "Microsoft PowerPoint"
        open (POSIX file inPath)
        set thePresentation to active presentation
        try
          save thePresentation in (POSIX file outPath) as save as PDF
        on error errMsg number errNum
          try
            close thePresentation saving no
          end try
          error errMsg number errNum
        end try
        close thePresentation saving no
      end tell
      return ""
    end run
    """
}
