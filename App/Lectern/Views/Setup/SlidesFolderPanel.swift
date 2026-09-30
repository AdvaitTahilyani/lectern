import AppKit
import LecternCore

/// Open panel for picking a course's slides folder (directories only).
enum SlidesFolderPanel {
    /// Runs the panel and returns the chosen folder, or nil if the user cancelled.
    static func choose(for course: Course) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "Use Folder"
        panel.message = "Choose the folder where you keep the slide decks for \(course.code)."
        panel.directoryURL = course.slidesFolder
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// "~/Documents/CS 426 Lecture Slides" for display.
    static func displayPath(_ url: URL) -> String {
        url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }
}
