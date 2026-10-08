import Foundation
import LecternCore
import SwiftUI

/// One in-flight recording import. Appears in the library as a staged progress row and opens
/// into Review when finished.
@Observable
@MainActor
final class ImportJob: Identifiable {
    enum State: Hashable {
        case running(ImportStage)
        case failed(String)
        case cancelled
        case finished
    }

    let id: UUID
    private(set) var session: LectureSession
    private(set) var state: State
    private var task: Task<Void, Never>?

    init(session: LectureSession) {
        id = session.id
        self.session = session
        // A local file has nothing to download: it starts at extracting its audio.
        if case .mediaSpace = session.source { state = .running(.downloading(fraction: 0)) } else { state = .running(.extractingAudio) }
    }

    var stage: ImportStage? { if case .running(let s) = state { s } else { nil } }

    /// Overall progress 0…1 across the three visible stages.
    var overallProgress: Double {
        switch state {
        case .running(let stage):
            switch stage {
            case .downloading(let f): return f * 0.25
            case .extractingAudio: return 0.27
            case .transcribing(let f): return 0.3 + f * 0.45
            case .summarizing(let f): return 0.75 + f * 0.25
            case .finished: return 1
            }
        case .finished: return 1
        default: return 0
        }
    }

    var stageLabel: String {
        switch state {
        case .running(let stage):
            switch stage {
            case .downloading(let f): return "Downloading \(Int(f * 100))%"
            case .extractingAudio: return "Extracting audio…"
            case .transcribing(let f): return "Transcribing \(Int(f * 100))%"
            case .summarizing(let f): return "Summarizing \(Int(f * 100))%"
            case .finished: return "Finishing…"
            }
        case .failed(let m): return m
        case .cancelled: return "Cancelled"
        case .finished: return "Done"
        }
    }

    /// Index of the current visible stage: 0 downloading (MediaSpace) or preparing audio (a file), 1 transcribing, 2 summarizing.
    var stageIndex: Int {
        guard case .running(let s) = state else { return state == .finished ? 3 : 0 }
        switch s {
        case .downloading, .extractingAudio: return 0
        case .transcribing: return 1
        case .summarizing: return 2
        case .finished: return 3
        }
    }

    /// Runs the whole import under this job's one task: first `prepare` (copying the deck and
    /// saving the draft), then `run` (the importer). Cancelling the job cancels both, and nothing
    /// that comes after a cancellation starts or saves: `prepare` must check for cancellation after
    /// each suspension and return nil if it sees one.
    ///
    /// - Parameters:
    ///   - draft: the session the import builds on (the job's session plus anything prepared since,
    ///     such as the ingested deck, which `prepare` adds).
    ///   - prepare: runs before the import; nil result means "cancelled, stop".
    ///   - run: the import itself: `RecordingImporting.importRecording` or `resumeImport`. Jargon
    ///     correction happens inside the importer, before summarizing, so takeaways are written from
    ///     the corrected transcript.
    func start(
        _ draft: LectureSession,
        prepare: (@MainActor (LectureSession) async -> LectureSession?)? = nil,
        run: @escaping @Sendable (LectureSession, @escaping @Sendable (ImportStage) -> Void) async throws -> LectureSession,
        onFinished: @escaping (LectureSession) -> Void,
        onFailed: @escaping (String) -> Void
    ) {
        session = draft
        task = Task { [weak self] in
            var current = draft
            if let prepare {
                guard let prepared = await prepare(current), !Task.isCancelled else { return }
                current = prepared
                self?.session = prepared
            }
            guard !Task.isCancelled else { return }
            do {
                let result = try await run(current) { stage in
                    Task { @MainActor in
                        guard let self, case .running = self.state else { return }
                        withAnimation(DS.Motion.numeric) { self.state = .running(stage) }
                    }
                }
                guard let self, !Task.isCancelled else { return }
                self.session = result
                self.state = .finished
                onFinished(result)
            } catch is CancellationError {
                self?.state = .cancelled
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.state = .failed(error.localizedDescription)
                onFailed(error.localizedDescription)
            }
        }
    }

    /// Stops the import. Everything it was doing stops at its next cancellation check; use
    /// `waitUntilStopped()` before touching what it was writing.
    func cancel() {
        task?.cancel()
        state = .cancelled
    }

    /// Returns once the import's task has ended, so no write of it can still be in flight.
    func waitUntilStopped() async {
        await task?.value
    }

    /// Adds what the app learned after the failure (e.g. that the transcript was kept) to the
    /// message shown on the failed card.
    func amendFailure(_ message: String) {
        if case .failed = state { state = .failed(message) }
    }
}

/// Draft for the Import Recording sheet.
@Observable
@MainActor
final class ImportDraft {
    enum Source: Hashable {
        case none
        case file(URL)
        case mediaSpace(MediaSpaceSource)
    }

    var source: Source = .none
    var preferCaptions = true
    var courseID: UUID?
    var title = ""
    var deckURL: URL?
    var deckImages: SlideImageStore?
    var isDragTargeted = false
    var showMediaSpace = false
    /// Decks in the course's slides folder, ranked for this lecture (QA Q3-5).
    private(set) var deckSuggestions: SuggestedDecks = .none
    /// Set when the course has a slides folder that couldn't be read.
    private(set) var deckSuggestionsError: String?
    private var suggestTask: Task<Void, Never>?

    var hasSource: Bool { source != .none }

    /// Every suggested deck, the best first.
    var suggestedDeckURLs: [URL] { [deckSuggestions.primary].compactMap { $0 } + deckSuggestions.others }

    /// Re-scans `folder` (the course's slides folder, or nil). `usedFileNames` are the decks of
    /// the course's earlier lectures, which rank after the unused ones.
    func refreshDeckSuggestions(folder: URL?, usedFileNames: Set<String>, services: AppServices) {
        suggestTask?.cancel()
        guard let folder else {
            deckSuggestions = .none
            deckSuggestionsError = nil
            return
        }
        suggestTask = Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try services.suggestDecks(folder, usedFileNames, ["pdf"]) }
            }.value
            guard !Task.isCancelled else { return }
            switch result {
            case .success(let suggestions):
                deckSuggestions = suggestions
                deckSuggestionsError = nil
            case .failure:
                deckSuggestions = .none
                deckSuggestionsError = "Couldn't open the slides folder “\(folder.lastPathComponent)”"
            }
        }
    }

    var sourceLabel: String? {
        switch source {
        case .none: nil
        case .file(let url): url.lastPathComponent
        case .mediaSpace(let s): s.title ?? s.entryID
        }
    }

    var suggestedTitle: String {
        switch source {
        case .none: ""
        case .file(let url): url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "[-_]", with: " ", options: .regularExpression)
        case .mediaSpace(let s): s.title?.split(separator: "—").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? s.title ?? "Imported lecture"
        }
    }

    // The title field shows `suggestedTitle` as its placeholder and an empty title falls back to it, so
    // choosing a source never fills the field: a later "Change" would otherwise keep the first one's name.
    func setFile(_ url: URL) { source = .file(url) }

    func setMediaSpace(_ s: MediaSpaceSource) { source = .mediaSpace(s) }

    func setDeck(_ url: URL?) {
        deckURL = url
        deckImages = url.map { SlideImageStore(url: $0) }
    }

    func recordingSource() -> RecordingSource? {
        switch source {
        case .none: nil
        case .file(let url): .file(url)
        case .mediaSpace(let s): .mediaSpace(s, preferCaptions: preferCaptions)
        }
    }

    func reset() {
        source = .none
        title = ""
        deckURL = nil
        deckImages = nil
        preferCaptions = true
        suggestTask?.cancel()
        deckSuggestions = .none
        deckSuggestionsError = nil
    }
}
