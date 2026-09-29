import AppKit
import Foundation
import LecternCore
import PDFKit

/// Converts PPTX / PPT / Keynote files to PDF by scripting Keynote (preferred) or Microsoft
/// PowerPoint, and reads presenter notes (from the PPTX package directly; from Keynote for other
/// formats).
///
/// Scripting an app needs the user's approval under System Settings > Privacy & Security >
/// Automation; when it is missing the thrown `ImportError.automationDenied` says so. The exported
/// PDF is placed in a fresh temporary directory owned by the caller.
public struct PresentationConverter: PresentationConverting {
    public var supportedExtensions: Set<String> { ["pptx", "ppt", "ppsx", "key"] }

    private let runner: any AppleScriptRunning
    private let isInstalled: @Sendable (String) -> Bool
    private let timeout: TimeInterval

    /// - Parameter timeout: seconds to wait for the presentation app before giving up.
    public init(timeout: TimeInterval = 60) {
        self.init(runner: OsaScriptRunner(), isInstalled: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }, timeout: timeout)
    }

    init(runner: any AppleScriptRunning, isInstalled: @escaping @Sendable (String) -> Bool, timeout: TimeInterval = 60) {
        self.runner = runner
        self.isInstalled = isInstalled
        self.timeout = timeout
    }

    static let keynoteBundleID = "com.apple.iWork.Keynote"
    static let powerPointBundleID = "com.microsoft.Powerpoint"

    public func convertToPDF(_ url: URL) async throws -> (pdf: URL, notes: [Int: String]) {
        let ext = url.pathExtension.lowercased()
        guard supportedExtensions.contains(ext) else { throw ImportError.unsupportedFileType(ext) }
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw ImportError.invalidPresentation("\(url.lastPathComponent) can't be read")
        }

        let isOOXML = ["pptx", "ppsx"].contains(ext)
        // Notes are read from the package itself when possible: exact, and no app involved.
        let package = isOOXML ? try PPTXNotesParser.parse(url) : nil

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lectern-slides-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let pdf = directory.appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".pdf")

        do {
            let scriptNotes = try await export(url, to: pdf, wantNotes: package == nil, allowPowerPoint: ext != "key")
            try Task.checkCancellation()
            guard let document = PDFDocument(url: pdf), document.pageCount > 0 else {
                throw ImportError.conversionFailed(app: "The presentation app", message: "the exported PDF is empty")
            }
            let notes = package.map { Self.notesByPage($0, pageCount: document.pageCount) } ?? Self.notes(fromScriptOutput: scriptNotes)
            return (pdf, notes)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    // MARK: - Export

    /// Tries Keynote, then PowerPoint, keeping the first error if both fail. Returns Keynote's raw
    /// notes output ("" from PowerPoint).
    private func export(_ input: URL, to pdf: URL, wantNotes: Bool, allowPowerPoint: Bool) async throws -> String {
        var firstError: Error?
        if isInstalled(Self.keynoteBundleID) {
            do {
                return try await runner.run(PresentationScripts.keynote, arguments: [input.path, pdf.path, wantNotes ? "yes" : "no"], application: "Keynote", timeout: timeout)
            } catch let error as ImportError {
                firstError = error
            }
        }
        if allowPowerPoint, isInstalled(Self.powerPointBundleID) {
            do {
                return try await runner.run(PresentationScripts.powerPoint, arguments: [input.path, pdf.path], application: "Microsoft PowerPoint", timeout: timeout)
            } catch let error as ImportError {
                firstError = firstError ?? error
            }
        }
        throw firstError ?? ImportError.noPresentationApp
    }

    // MARK: - Notes

    /// Maps notes from slide order to PDF page numbers. Exporters normally include every slide;
    /// when the PDF has exactly as many pages as there are visible slides, hidden slides are skipped.
    static func notesByPage(_ package: PPTXContents, pageCount: Int) -> [Int: String] {
        guard !package.hiddenSlides.isEmpty, pageCount == package.slideCount - package.hiddenSlides.count else { return package.notes }
        var result: [Int: String] = [:]
        var page = 0
        for slide in 1...max(package.slideCount, 1) where !package.hiddenSlides.contains(slide) {
            page += 1
            if let note = package.notes[slide] { result[page] = note }
        }
        return result
    }

    static func notes(fromScriptOutput output: String) -> [Int: String] {
        guard !output.isEmpty else { return [:] }
        var result: [Int: String] = [:]
        for (index, note) in output.components(separatedBy: PresentationScripts.noteSeparator).enumerated() {
            let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { result[index + 1] = trimmed }
        }
        return result
    }
}
