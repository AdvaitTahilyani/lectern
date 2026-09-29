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
    var acceptedExtensions: Set<String> { Set(["pdf"]).union(services.presentationConverter?.supportedExtensions ?? []) }

    /// Presenter notes extracted from a converted deck, keyed by 1-based slide.
    private(set) var presenterNotes: [Int: String] = [:]
    private var convertTask: Task<Void, Never>?

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
        if inputDeviceID == nil { inputDeviceID = inputDevices.first { $0.isDefault }?.id ?? inputDevices.first?.id }
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
    func loadDeck(url: URL) {
        let ext = url.pathExtension.lowercased()
        if ext != "pdf", let converter = services.presentationConverter, converter.supportedExtensions.contains(ext) {
            convert(url: url, with: converter)
            return
        }
        guard ext == "pdf" else { failDeck("Couldn't read that file"); return }
        loadPDF(url: url)
    }

    private func convert(url: URL, with converter: any PresentationConverting) {
        convertTask?.cancel()
        indexTask?.cancel()
        deckError = nil
        deck = nil
        deckURL = url
        slideImages = nil
        indexing = .converting
        convertTask = Task { [weak self] in
            do {
                let result = try await converter.convertToPDF(url)
                guard let self, !Task.isCancelled else { return }
                self.presenterNotes = result.notes
                self.loadPDF(url: result.pdf, displayName: url.lastPathComponent)
            } catch is CancellationError {
            } catch {
                self?.failDeck(error.localizedDescription)
            }
        }
    }

    private func loadPDF(url: URL, displayName: String? = nil) {
        indexTask?.cancel()
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
                        if case .indexing(_, let total) = self.indexing { self.indexing = .indexing(done: Int((p * Double(total)).rounded()), total: total) }
                    }
                }
                guard !Task.isCancelled else { return }
                var deck = ingested
                for (page, note) in self.presenterNotes {
                    if let i = deck.pages.firstIndex(where: { $0.number == page }) { deck.pages[i].notes = note }
                }
                if let name = self.deckDisplayName { deck.originalFileName = name }
                self.deck = deck
                self.indexing = .done(count: deck.pages.count)
                self.suggestTitle(from: deck)
            } catch is CancellationError {
            } catch {
                self.failDeck(error.localizedDescription)
            }
        }
    }

    func loadSampleDeck() {
        Task {
            if let url = try? await services.sampleDeckURL() { loadDeck(url: url) }
        }
    }

    private func failDeck(_ message: String) {
        convertTask?.cancel()
        deckURL = nil
        deckDisplayName = nil
        presenterNotes = [:]
        deck = nil
        slideImages = nil
        indexing = nil
        deckError = message
        deckErrorShakeCount += 1
    }

    func removeDeck() {
        indexTask?.cancel()
        convertTask?.cancel()
        presenterNotes = [:]
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

    /// Clears the draft after a session starts (course is kept as the default for next time).
    func reset() {
        endMonitoring()
        title = ""
        titleIsSuggested = false
        deckURL = nil
        deckDisplayName = nil
        presenterNotes = [:]
        deck = nil
        slideImages = nil
        indexing = nil
        deckError = nil
    }
}
