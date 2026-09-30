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
    var draft = ""
    /// Ordinal → session id, for rendering citations.
    private(set) var ordinals: [Int: UUID] = [:]
    private(set) var lectures: [CourseLecture] = []
    /// Starter questions drawn from the course's own takeaways.
    private(set) var suggestions: [String] = []

    private let services: AppServices
    private var assistant: (any CourseAssisting)?
    private var task: Task<Void, Never>?
    private var lastQuestion: String?

    init(courseID: UUID, services: AppServices) {
        self.courseID = courseID
        self.services = services
    }

    /// What the assistant was built from. A lecture that gains its final takeaway or summary after
    /// it finished (the last live topic settles, the summary is written) must rebuild it.
    private struct LectureKey: Equatable {
        var id: UUID
        var title: String
        var takeaways: Int
        var transcriptSegments: Int
        var hasSummary: Bool
        /// A deck added in Review must reach the course assistant too.
        var deckFile: String?

        init(_ session: LectureSession) {
            id = session.id
            title = session.title
            takeaways = session.takeaways.count
            transcriptSegments = session.transcript.count
            hasSummary = session.summary != nil
            deckFile = session.deck?.fileName
        }
    }

    private var preparedKey: [LectureKey]?
    private var didRequestHistory = false
    private var prepareTask: Task<Void, Never>?

    /// (Re)builds the assistant over the course's current lectures. No-op when the lectures are
    /// unchanged, so it's safe to call often (but never from a view body). Slide indexes are built
    /// asynchronously (each one embeds every page of its deck); `ask` waits for them.
    func prepare(sessions: [LectureSession]) {
        let ordered = sessions.filter { $0.courseID == courseID && $0.status == .finished }
            .sorted { ($0.startedAt ?? $0.createdAt) < ($1.startedAt ?? $1.createdAt) }
        let key = ordered.map(LectureKey.init)
        guard key != preparedKey else { return }
        preparedKey = key
        prepareTask?.cancel()
        prepareTask = Task { [services] in
            var built: [CourseLecture] = []
            for (i, session) in ordered.enumerated() {
                guard !Task.isCancelled else { return }
                let slides = if let deck = session.deck { await services.makeSlideIndex(deck) } else { nil as (any SlideSearching)? }
                built.append(CourseLecture(session: session, ordinal: i + 1, slides: slides))
            }
            guard !Task.isCancelled else { return }
            lectures = built
            ordinals = Dictionary(uniqueKeysWithValues: built.map { ($0.ordinal, $0.session.id) })
            suggestions = Self.suggestions(for: built)
            assistant = services.makeCourseAssistant(built)
        }
        guard !didRequestHistory else { return }
        didRequestHistory = true
        Task { [services, courseID] in
            answers = (try? await services.store.loadCourseChat(courseID: courseID)) ?? []
        }
    }

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

    func lectureTitle(ordinal: Int) -> String {
        lectures.first { $0.ordinal == ordinal }?.session.title ?? "Lecture \(ordinal)"
    }

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
        let history = answers
        task?.cancel()
        task = Task { [weak self] in
            // A big course's slide indexes may still be building; the answer starts when they're done.
            await self?.prepareTask?.value
            guard let self, !Task.isCancelled else { return }
            guard let assistant = self.assistant else {
                self.error = "Couldn't get this course's lectures ready."
                self.streaming = nil
                self.pendingQuestion = nil
                self.isAnswering = false
                return
            }
            do {
                for try await event in assistant.ask(question, history: history) {
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
        persist()
    }

    private func persist() {
        let snapshot = answers
        Task { [services, courseID] in try? await services.store.saveCourseChat(snapshot, courseID: courseID) }
    }
}
