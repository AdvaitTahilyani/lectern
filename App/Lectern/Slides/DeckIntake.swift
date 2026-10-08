import AppKit
import Foundation
import LecternCore
import UniformTypeIdentifiers

/// A slide file the user chose, made ready to attach to a lecture: converted to PDF when it was a
/// PowerPoint/Keynote file, and ingested (with that file's presenter notes on its pages).
nonisolated struct PreparedDeck: Sendable {
    /// The PDF to copy into the lecture's folder.
    var pdf: URL
    /// The ingested deck; `originalFileName` is the file the user chose.
    var deck: SlideDeck
    /// A conversion's temporary output, owned by this value: delete it with `dispose()` once the
    /// PDF has been copied (or the deck abandoned).
    var conversion: ConvertedPresentation?

    func dispose() { conversion?.dispose() }
}

/// The PDF a `PresentationConverting` produced and the temporary folder it lives in (audit B28:
/// the converter hands that folder to its caller, who must remove it).
nonisolated struct ConvertedPresentation: Sendable, Hashable {
    var pdf: URL
    var notes: [Int: String]

    /// The converter's private output folder, or nil when the PDF lives somewhere it doesn't own
    /// (the demo converter returns the sample deck itself, which must never be deleted).
    var temporaryFolder: URL? {
        let folder = pdf.deletingLastPathComponent().standardizedFileURL
        let temporary = FileManager.default.temporaryDirectory.standardizedFileURL
        guard folder.lastPathComponent.hasPrefix("lectern-slides-"),
              folder.deletingLastPathComponent().path == temporary.path else { return nil }
        return folder
    }

    func dispose() {
        guard let temporaryFolder else { return }
        try? FileManager.default.removeItem(at: temporaryFolder)
    }
}

/// Choosing, dropping and preparing slide decks, shared by Setup, Import and a lecture's Slides
/// column.
enum DeckIntake {
    /// File extensions accepted: PDF plus whatever the presentation converter handles.
    static func acceptedExtensions(_ services: AppServices) -> Set<String> {
        Set(["pdf"]).union(services.presentationConverter?.supportedExtensions ?? [])
    }

    static func contentTypes(for extensions: Set<String>) -> [UTType] {
        extensions.sorted().compactMap { $0 == "pdf" ? .pdf : UTType(filenameExtension: $0) }
    }

    /// Shows an open panel for slide files, attached to the key window when there is one, and
    /// calls `completion` with the chosen files (nothing when cancelled). An AppKit panel rather
    /// than SwiftUI's `fileImporter`, whose presentation from the lecture view never appeared.
    static func choose(extensions: Set<String>, multiple: Bool, message: String, completion: @escaping ([URL]) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = multiple
        panel.allowedContentTypes = contentTypes(for: extensions)
        panel.prompt = multiple ? "Add" : "Choose"
        panel.message = message
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            completion(response == .OK ? panel.urls : [])
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            panel.begin(completionHandler: finish)
        }
    }

    /// File URLs carried by dropped items, in drop order. Returns false when no item is a file URL
    /// (so the drop is refused). Files of an unsupported type are left for `prepare` to reject.
    static func loadFileURLs(from providers: [NSItemProvider], completion: @escaping @MainActor ([URL]) -> Void) -> Bool {
        let files = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !files.isEmpty else { return false }
        Task { @MainActor in
            var urls: [URL] = []
            for provider in files {
                if let url = await fileURL(from: provider) { urls.append(url) }
            }
            completion(urls)
        }
        return true
    }

    nonisolated private static func fileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                if let data = item as? Data { continuation.resume(returning: URL(dataRepresentation: data, relativeTo: nil)) }
                else { continuation.resume(returning: item as? URL) }
            }
        }
    }

    /// Converts (when needed) and ingests `url`. On failure or cancellation nothing temporary is
    /// left behind; on success the caller owns `PreparedDeck.conversion`.
    nonisolated static func prepare(_ url: URL, services: AppServices, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> PreparedDeck {
        let ext = url.pathExtension.lowercased()
        var conversion: ConvertedPresentation?
        let pdf: URL
        if ext == "pdf" {
            pdf = url
        } else if let converter = services.presentationConverter, converter.supportedExtensions.contains(ext) {
            let result = try await converter.convertToPDF(url)
            conversion = ConvertedPresentation(pdf: result.pdf, notes: result.notes)
            pdf = result.pdf
        } else {
            throw DeckIntakeError.unsupported(url.lastPathComponent)
        }
        do {
            try Task.checkCancellation()
            var deck = try await services.slideIngestor.ingest(pdfAt: pdf, progress: progress)
            try Task.checkCancellation()
            // Notes travel with this conversion's result, never from an earlier selection (B27).
            for (page, note) in conversion?.notes ?? [:] {
                if let i = deck.pages.firstIndex(where: { $0.number == page }) { deck.pages[i].notes = note }
            }
            deck.originalFileName = url.lastPathComponent
            return PreparedDeck(pdf: pdf, deck: deck, conversion: conversion)
        } catch {
            conversion?.dispose()
            throw error
        }
    }
}

nonisolated enum DeckIntakeError: LocalizedError {
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .unsupported(let name): "“\(name)” isn't a slide deck Lectern can read (PDF, PowerPoint or Keynote)."
        }
    }
}
