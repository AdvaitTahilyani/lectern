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
    private(set) var state: State = .running(.downloading(fraction: 0))
    private var task: Task<Void, Never>?

    init(session: LectureSession) {
        id = session.id
        self.session = session
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

    /// Index of the current visible stage: 0 downloading, 1 transcribing, 2 summarizing.
    var stageIndex: Int {
        guard case .running(let s) = state else { return state == .finished ? 3 : 0 }
        switch s {
        case .downloading, .extractingAudio: return 0
        case .transcribing: return 1
        case .summarizing: return 2
        case .finished: return 3
        }
    }

    /// Runs the import of `draft` (the job's session plus anything prepared since the job was
    /// created, such as the ingested deck). Jargon correction happens inside the importer, before
    /// summarizing, so takeaways are written from the corrected transcript.
    func start(_ draft: LectureSession, source: RecordingSource, services: AppServices, onFinished: @escaping (LectureSession) -> Void, onFailed: @escaping (String) -> Void) {
        session = draft
        task = Task { [weak self] in
            do {
                let result = try await services.recordingImporter.importRecording(source, into: draft) { stage in
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

    func cancel() {
        task?.cancel()
        state = .cancelled
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

    func setFile(_ url: URL) {
        source = .file(url)
        if title.isEmpty { title = suggestedTitle }
    }

    func setMediaSpace(_ s: MediaSpaceSource) {
        source = .mediaSpace(s)
        if title.isEmpty { title = suggestedTitle }
    }

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
