import Foundation
import LecternCore
import SwiftUI

/// Course-wide Ask thread for one course. History persists via the store.
@Observable
@MainActor
final class CourseAskModel {
    let courseID: UUID
    private(set) var answers: [CourseAnswer] = []
    private(set) var pendingQuestion: String?
    private(set) var streaming: String?
    private(set) var isAnswering = false
    private(set) var error: String?
    /// The saved thread could not be read or written. The thread on screen is intact; Retry tries again.
    private(set) var historyError: String?
    var draft = ""
    private(set) var lectures: [CourseLecture] = []
    /// Starter questions drawn from the course's own takeaways.
    private(set) var suggestions: [String] = []

    private let services: AppServices
    /// The model the Ask role uses right now; part of the assistant's identity.
    private let askProvider: @MainActor () -> ProviderConfig?
    /// The course's "code — name", given to the assistant; part of its identity.
    private let courseName: @MainActor () -> String?
    private var assistant: (any CourseAssisting)?
    private var task: Task<Void, Never>?
    private var lastQuestion: String?

    init(courseID: UUID, services: AppServices, askProvider: @escaping @MainActor () -> ProviderConfig? = { nil }, courseName: @escaping @MainActor () -> String? = { nil }) {
        self.courseID = courseID
        self.services = services
        self.askProvider = askProvider
        self.courseName = courseName
    }

    // MARK: Assistant identity

    /// What the assistant was built from. Each lecture contributes a fingerprint of everything the
    /// assistant reads (title, transcript, takeaways, summary, deck text) and its ordinal in the course, so
    /// an edit that keeps every count the same (a replaced deck, a corrected transcript word, rewritten
    /// takeaway text) still rebuilds it, and so does a change of Ask model.
    struct Key: Equatable {
        var lectures: [LectureKey]
        var provider: ProviderConfig?
        var courseName: String?
    }

    struct LectureKey: Equatable {
        var id: UUID
        var ordinal: Int
        var content: Int
        var deck: Int?

        init(_ session: LectureSession, ordinal: Int) {
            id = session.id
            self.ordinal = ordinal
            content = Self.contentFingerprint(session)
            deck = session.decks.isEmpty ? nil : { var h = Hasher(); h.combine(session.decks); return h.finalize() }()
        }

        /// A hash of the text the assistant can see. Process-local (Hasher is seeded per launch), which
        /// is all an in-memory cache needs.
        static func contentFingerprint(_ s: LectureSession) -> Int {
            var h = Hasher()
            h.combine(s.title)
            h.combine(s.duration)
            h.combine(s.startedAt ?? s.createdAt)
            for segment in s.transcript where segment.isFinal { h.combine(segment) }
            h.combine(s.takeaways)
            h.combine(s.summary)
            return h.finalize()
        }
    }

    private var preparedKey: Key?
    private var prepareTask: Task<Void, Never>?
    /// Slide indexes already built, by lecture, for the deck revision they were built from. Each one embeds
    /// every page, so an unchanged deck must never be re-indexed when another lecture changes.
    private var slideIndexes: [UUID: (deck: Int, index: any SlideSearching)] = [:]

    /// (Re)builds the assistant over the course's current lectures. No-op when nothing the assistant reads
    /// has changed, so it's safe to call often (but never from a view body). Slide indexes are built
    /// asynchronously and reused per deck revision; `ask` waits for them.
    func prepare(sessions: [LectureSession]) {
        let ordered = sessions.filter { $0.courseID == courseID && $0.status == .finished }
            .sorted { ($0.startedAt ?? $0.createdAt) < ($1.startedAt ?? $1.createdAt) }
        let keys = ordered.enumerated().map { LectureKey($1, ordinal: $0 + 1) }
        let key = Key(lectures: keys, provider: askProvider(), courseName: courseName())
        loadHistoryIfNeeded()
        guard key != preparedKey else { return }
        preparedKey = key
        prepareTask?.cancel()
        let known = slideIndexes
        let name = key.courseName
        prepareTask = Task { [services] in
            var built: [CourseLecture] = []
            var indexes: [UUID: (deck: Int, index: any SlideSearching)] = [:]
            for (i, session) in ordered.enumerated() {
                guard !Task.isCancelled else { return }
                var slides: (any SlideSearching)?
                if let deckRevision = keys[i].deck, let deck = session.deck {
                    if let cached = known[session.id], cached.deck == deckRevision {
                        slides = cached.index
                    } else {
                        slides = await services.makeSlideIndex(deck)
                    }
                    if let slides { indexes[session.id] = (deckRevision, slides) }
                }
                built.append(CourseLecture(session: session, ordinal: i + 1, slides: slides))
            }
            guard !Task.isCancelled else { return }
            slideIndexes = indexes
            lectures = built
            suggestions = Self.suggestions(for: built)
            assistant = services.makeCourseAssistant(built, name)
        }
    }

    /// Completes when the assistant for the latest `prepare` is built (asking waits on the same task).
    func finishPreparing() async { await prepareTask?.value }

    /// Up to two topics from the most recent lectures, then whole-course questions.
    private static func suggestions(for lectures: [CourseLecture]) -> [String] {
        var seen = Set<String>()
        let topics = lectures.reversed()
            .flatMap { $0.session.takeaways.filter { !$0.isLive }.map(\.title) }
            .filter { seen.insert($0.lowercased()).inserted }
            .prefix(2)
            .map { "What did we cover about \($0)?" }
        guard !lectures.isEmpty else { return [] }
        var result = Array(topics)
        result.append("What are the most important ideas so far?")
        if lectures.count >= 2 { result.append("Catch me up on the last two lectures") }
        return result
    }

    /// The lecture's current title; falls back to the ordinal the answer was written with.
    func lectureTitle(of citation: CourseCitation) -> String {
        lectures.first { $0.session.id == citation.sessionID }?.session.title ?? "Lecture \(citation.ordinal)"
    }

    // MARK: History

    private var historyTask: Task<Void, Never>?
    private var didRequestHistory = false
    /// The user changed the thread (asked, cleared) after the saved one was requested.
    private var threadChangedSinceLoad = false
    private var clearedSinceLoad = false
    private var historyLoadFailed = false

    private func loadHistoryIfNeeded() {
        guard !didRequestHistory else { return }
        didRequestHistory = true
        loadHistory()
    }

    /// Reads the saved thread once. If the user already asked or cleared by the time it arrives, the saved
    /// answers are merged under the new ones (or dropped, after a clear) rather than replacing them.
    private func loadHistory() {
        historyTask = Task { [services, courseID] in
            do {
                let saved = try await services.store.loadCourseChat(courseID: courseID)
                historyLoadFailed = false
                if clearedSinceLoad { return }
                if threadChangedSinceLoad {
                    let known = Set(answers.map(\.id))
                    answers = saved.filter { !known.contains($0.id) } + answers
                } else {
                    answers = saved
                }
                if historyError != nil, !isDirty { historyError = nil }
            } catch {
                historyLoadFailed = true
                historyError = "Couldn't read this course's earlier answers: \(error.localizedDescription)"
            }
        }
    }

    // MARK: Asking

    func ask(_ text: String) {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isAnswering else { return }
        lastQuestion = question
        guard preparedKey != nil else {
            error = "Still getting this course's lectures ready. Try again in a moment."
            return
        }
        draft = ""
        error = nil
        pendingQuestion = question
        streaming = ""
        isAnswering = true
        threadChangedSinceLoad = true
        task?.cancel()
        task = Task { [weak self] in
            // The saved thread and a big course's slide indexes may still be loading; the answer starts
            // when both are done (the follow-up context must include the saved answers).
            await self?.historyTask?.value
            await self?.finishPreparing()
            guard let self, !Task.isCancelled else { return }
            guard let assistant = self.assistant else {
                self.error = "Couldn't get this course's lectures ready."
                self.streaming = nil
                self.pendingQuestion = nil
                self.isAnswering = false
                return
            }
            do {
                for try await event in assistant.ask(question, history: self.answers) {
                    guard !Task.isCancelled else { return }
                    switch event {
                    case .delta(let d): self.streaming = (self.streaming ?? "") + d
                    case .done(let answer):
                        self.answers.append(answer)
                        self.streaming = nil
                        self.pendingQuestion = nil
                        self.persist()
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
                self.streaming = nil
                self.pendingQuestion = nil
            }
            self.isAnswering = false
        }
    }

    /// Stops the answer being written; the partial text is dropped.
    func cancel() {
        task?.cancel()
        isAnswering = false
        streaming = nil
        pendingQuestion = nil
    }

    func retry() {
        guard let q = lastQuestion else { return }
        ask(q)
    }

    func clearHistory() {
        answers = []
        threadChangedSinceLoad = true
        clearedSinceLoad = true
        persist()
    }

    // MARK: Saving

    private var saveTask: Task<Void, Never>?
    /// The thread on screen has changes the store has not accepted yet.
    private var isDirty = false

    /// Writes the thread. Writes are chained so they reach the store in order and the last one wins; a
    /// failure keeps the thread marked unsaved and is shown with a Retry.
    private func persist() {
        isDirty = true
        let previous = saveTask
        saveTask = Task { [weak self] in
            await previous?.value
            await self?.writeIfDirty()
        }
    }

    private func writeIfDirty() async {
        guard isDirty else { return }
        // Never overwrite a saved thread that could not be read with only the new answers.
        if historyLoadFailed {
            historyError = "Couldn't read this course's earlier answers, so new ones aren't being saved yet."
            return
        }
        let snapshot = answers
        isDirty = false
        do {
            try await services.store.saveCourseChat(snapshot, courseID: courseID)
            historyError = nil
        } catch {
            isDirty = true
            historyError = "Couldn't save this course's answers: \(error.localizedDescription)"
        }
    }

    /// Retry for `historyError`: re-reads the saved thread if it never loaded, then writes any unsaved changes.
    func retryHistory() {
        if historyLoadFailed {
            historyError = nil
            loadHistory()
            let loading = historyTask
            saveTask = Task { [weak self] in
                await loading?.value
                await self?.writeIfDirty()
            }
        } else {
            persist()
        }
    }

    /// Waits for the answer in flight, the saved thread to load, and the writes started so far (quit, tests).
    func flush() async {
        await task?.value
        await historyTask?.value
        await saveTask?.value
    }
}
