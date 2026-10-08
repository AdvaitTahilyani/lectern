import Foundation
import LecternCore
import SwiftUI

/// Pre-lecture draft: course, title, deck (with indexing), mic and level meter. Retained in
/// memory until the app quits so an accidental Back doesn't lose the deck.
@Observable
@MainActor
final class SetupModel {
    enum Indexing: Hashable {
        case converting
        case indexing(done: Int, total: Int)
        case done(count: Int)
        case failed(String)
    }

    private let services: AppServices

    var courseID: UUID?
    var title = ""
    /// True while the title is the auto-suggested one (so a later deck may overwrite it).
    private(set) var titleIsSuggested = false
    private(set) var showSuggestedGlint = false

    private(set) var deckURL: URL?
    /// Name shown for the deck (the original .pptx/.key name after conversion).
    private(set) var deckDisplayName: String?
    private(set) var deck: SlideDeck?
    private(set) var indexing: Indexing?
    private(set) var slideImages: SlideImageStore?
    private(set) var deckError: String?
    private(set) var deckErrorShakeCount = 0
    /// Approximate file size of the dropped PDF, in bytes.
    private(set) var deckFileSize: Int64 = 0
    private(set) var isDragTargeted = false

    var inputDeviceID: String?
    private(set) var inputDevices: [AudioInputDevice] = []
    private(set) var level: Float = 0
    private(set) var peak: Float = 0
    private(set) var microphonePermission: MicrophonePermission = .notDetermined
    private(set) var sampleDeckAvailable = false

    private var levelMonitor: (any AudioLevelMonitoring)?
    private var levelTask: Task<Void, Never>?
    private var indexTask: Task<Void, Never>?
    private var glintTask: Task<Void, Never>?
    private var peakDecayTask: Task<Void, Never>?

    init(services: AppServices) {
        self.services = services
        Task { self.sampleDeckAvailable = (try? await services.sampleDeckURL()) != nil }
    }

    var canStart: Bool {
        guard microphonePermission == .granted else { return false }
        switch indexing {
        case .indexing, .converting: return false
        default: return true
        }
    }

    /// File extensions accepted by the drop zone / chooser (PDF plus whatever the converter handles).
    var acceptedExtensions: Set<String> { DeckIntake.acceptedExtensions(services) }

    private var convertTask: Task<Void, Never>?
    /// Bumped by every deck selection (and removal): results of an older one's conversion or
    /// indexing are dropped, never applied to the newer deck (audit B27).
    private var selection = 0
    /// The converted PDF of the selected PowerPoint/Keynote deck, owned here until the deck is
    /// replaced, removed or handed to the lecture (audit B28).
    private var conversion: ConvertedPresentation?
    /// Slides of the indexed deck whose text OCR couldn't read (audit B43).
    private(set) var pagesMissingText: [Int] = []

    /// Decks offered from the chosen course's slides folder (re-scanned whenever Setup opens or
    /// the course changes; no folder watching).
    private(set) var deckSuggestions: SuggestedDecks = .none
    /// Set when the course has a slides folder that couldn't be read.
    private(set) var deckSuggestionsError: String?
    private var suggestTask: Task<Void, Never>?

    var resolvedTitle: String {
        let t = title.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? "Lecture \(Self.dateFormatter.string(from: .now))" : t
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()

    // MARK: - Monitoring

    /// Warms up the audio path so Start is instant.
    func beginMonitoring() {
        microphonePermission = services.microphonePermission()
        inputDevices = services.inputDevices()
        // The meter shows, and Start records from, this device; an unplugged choice falls back to the default.
        if inputDeviceID == nil || !inputDevices.contains(where: { $0.id == inputDeviceID }) {
            inputDeviceID = inputDevices.first { $0.isDefault }?.id ?? inputDevices.first?.id
        }
        guard levelTask == nil, microphonePermission == .granted else { return }
        let monitor = services.makeLevelMonitor()
        levelMonitor = monitor
        let stream = monitor.start(deviceID: inputDeviceID)
        levelTask = Task { [weak self] in
            for await v in stream {
                guard let self else { return }
                self.level = v
                if v >= self.peak { self.peak = v; self.schedulePeakDecay() }
            }
        }
    }

    func endMonitoring() {
        levelTask?.cancel()
        levelTask = nil
        levelMonitor?.stop()
        levelMonitor = nil
        level = 0
        peak = 0
    }

    func changeInputDevice(_ id: String?) {
        inputDeviceID = id
        endMonitoring()
        beginMonitoring()
    }

    func requestMicrophoneAccess() {
        Task {
            let granted = await services.requestMicrophoneAccess()
            microphonePermission = granted ? .granted : .denied
            if granted { beginMonitoring() }
        }
    }

    private func schedulePeakDecay() {
        peakDecayTask?.cancel()
        peakDecayTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled, let self else { return }
            self.peak = self.level
        }
    }

    // MARK: - Deck

    func setDragTargeted(_ on: Bool) { isDragTargeted = on }

    /// Entry point for any accepted file: PDFs index directly; PPTX/Keynote are converted first.
    /// Each call starts a fresh selection: whatever an earlier one was still doing is cancelled
    /// and its results are ignored.
    func loadDeck(url: URL) {
        let generation = beginSelection()
        let ext = url.pathExtension.lowercased()
        if ext != "pdf", let converter = services.presentationConverter, converter.supportedExtensions.contains(ext) {
            convert(url: url, with: converter, generation: generation)
            return
        }
        guard ext == "pdf" else { failDeck("Couldn't read that file"); return }
        loadPDF(url: url, displayName: nil, notes: [:], generation: generation)
    }

    /// Cancels the current selection's work and releases what it owns.
    private func beginSelection() -> Int {
        selection += 1
        convertTask?.cancel()
        indexTask?.cancel()
        conversion?.dispose()
        conversion = nil
        pagesMissingText = []
        return selection
    }

    private func convert(url: URL, with converter: any PresentationConverting, generation: Int) {
        deckError = nil
        deck = nil
        deckURL = url
        deckDisplayName = url.lastPathComponent
        slideImages = nil
        indexing = .converting
        convertTask = Task { [weak self] in
            do {
                let result = try await converter.convertToPDF(url)
                let converted = ConvertedPresentation(pdf: result.pdf, notes: result.notes)
                guard let self, generation == self.selection, !Task.isCancelled else {
                    converted.dispose()
                    return
                }
                self.conversion = converted
                // The notes travel with this conversion, never onto a later PDF.
                self.loadPDF(url: converted.pdf, displayName: url.lastPathComponent, notes: converted.notes, generation: generation)
            } catch is CancellationError {
            } catch {
                guard let self, generation == self.selection else { return }
                self.failDeck(error.localizedDescription)
            }
        }
    }

    private func loadPDF(url: URL, displayName: String?, notes: [Int: String], generation: Int) {
        deckError = nil
        deckDisplayName = displayName ?? url.lastPathComponent
        deckURL = url
        deck = nil
        deckFileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        slideImages = SlideImageStore(url: url)
        let total = slideImages?.pageCount ?? 0
        guard slideImages?.hasDeck == true, total > 0 else {
            failDeck("Couldn't read that PDF")
            return
        }
        slideImages?.prewarm(pages: 1..<min(6, total + 1), width: DS.Size.slideThumbLarge.width)
        indexing = .indexing(done: 0, total: total)
        indexTask = Task { [services] in
            do {
                let ingested = try await services.slideIngestor.ingest(pdfAt: url) { p in
                    Task { @MainActor in
                        guard generation == self.selection, case .indexing(_, let total) = self.indexing else { return }
                        self.indexing = .indexing(done: Int((p * Double(total)).rounded()), total: total)
                    }
                }
                guard !Task.isCancelled, generation == self.selection else { return }
                var deck = ingested
                for (page, note) in notes {
                    if let i = deck.pages.firstIndex(where: { $0.number == page }) { deck.pages[i].notes = note }
                }
                if let name = self.deckDisplayName { deck.originalFileName = name }
                self.deck = deck
                self.pagesMissingText = deck.pagesMissingText
                self.indexing = .done(count: deck.pages.count)
                self.suggestTitle(from: deck)
            } catch is CancellationError {
            } catch {
                guard generation == self.selection else { return }
                self.failDeck(error.localizedDescription)
            }
        }
    }

    /// Re-scans `folder` (the course's slides folder, or nil) and ranks its decks for the next
    /// lecture. `usedFileNames` are the decks of the course's earlier sessions.
    func refreshDeckSuggestions(folder: URL?, usedFileNames: Set<String>) {
        suggestTask?.cancel()
        guard let folder else {
            deckSuggestions = .none
            deckSuggestionsError = nil
            return
        }
        let accepted = acceptedExtensions
        suggestTask = Task { [services] in
            let result = await Task.detached(priority: .userInitiated) {
                Result { try services.suggestDecks(folder, usedFileNames, accepted) }
            }.value
            guard !Task.isCancelled else { return }
            switch result {
            case .success(let suggestions):
                self.deckSuggestions = suggestions
                self.deckSuggestionsError = nil
            case .failure:
                self.deckSuggestions = .none
                self.deckSuggestionsError = "Couldn't open the slides folder “\(folder.lastPathComponent)”"
            }
        }
    }

    func loadSampleDeck() {
        Task {
            if let url = try? await services.sampleDeckURL() { loadDeck(url: url) }
        }
    }

    private func failDeck(_ message: String) {
        _ = beginSelection()
        deckURL = nil
        deckDisplayName = nil
        deck = nil
        slideImages = nil
        indexing = nil
        deckError = message
        deckErrorShakeCount += 1
    }

    func removeDeck() {
        _ = beginSelection()
        deckDisplayName = nil
        deckURL = nil
        deck = nil
        slideImages = nil
        indexing = nil
        deckError = nil
        if titleIsSuggested { title = ""; titleIsSuggested = false }
    }

    private func suggestTitle(from deck: SlideDeck) {
        let candidate = deck.title ?? deck.pages.first?.title
        guard let candidate, !candidate.isEmpty else { return }
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard trimmed.isEmpty || titleIsSuggested else { return }
        withAnimation(DS.Motion.morph) { title = candidate }
        titleIsSuggested = true
        showSuggestedGlint = true
        glintTask?.cancel()
        glintTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            withAnimation(DS.Motion.quick) { self?.showSuggestedGlint = false }
        }
    }

    func userEditedTitle() { titleIsSuggested = false }

    // MARK: - Session

    func makeSession() -> LectureSession {
        LectureSession(courseID: courseID, title: resolvedTitle, status: .live, deck: deck)
    }

    /// The deck file a starting lecture takes over, with its conversion (whose temporary PDF the
    /// lecture deletes once it has copied it). Setup no longer owns either afterwards.
    func takeStartingDeck() -> (url: URL, conversion: ConvertedPresentation?)? {
        guard let deckURL, deck != nil else { return nil }
        let taken = (deckURL, conversion)
        conversion = nil
        return taken
    }

    /// Clears the draft after a session starts (course is kept as the default for next time).
    func reset() {
        endMonitoring()
        title = ""
        titleIsSuggested = false
        _ = beginSelection()
        deckURL = nil
        deckDisplayName = nil
        deck = nil
        slideImages = nil
        indexing = nil
        deckError = nil
    }
}
