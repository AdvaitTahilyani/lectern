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
    private(set) var isLoaded = false
    var draft = ""
    /// Ordinal → session id, for rendering citations.
    private(set) var ordinals: [Int: UUID] = [:]
    private(set) var lectures: [CourseLecture] = []

    private let services: AppServices
    private var assistant: (any CourseAssisting)?
    private var task: Task<Void, Never>?
    private var lastQuestion: String?

    init(courseID: UUID, services: AppServices) {
        self.courseID = courseID
        self.services = services
    }

    private var preparedKey: [UUID] = []

    /// (Re)builds the assistant over the course's current lectures. No-op when the lecture set is
    /// unchanged, so it's safe to call often (but never from a view body).
    func prepare(sessions: [LectureSession]) {
        let ordered = sessions.filter { $0.courseID == courseID && $0.status == .finished }
            .sorted { ($0.startedAt ?? $0.createdAt) < ($1.startedAt ?? $1.createdAt) }
        let key = ordered.map(\.id)
        guard key != preparedKey || assistant == nil else { return }
        preparedKey = key
        lectures = ordered.enumerated().map { i, s in CourseLecture(session: s, ordinal: i + 1, slides: s.deck.flatMap { services.makeSlideIndex($0) }) }
        ordinals = Dictionary(uniqueKeysWithValues: lectures.map { ($0.ordinal, $0.session.id) })
        assistant = services.makeCourseAssistant(lectures)
        guard !isLoaded else { return }
        Task { [services, courseID] in
            answers = (try? await services.store.loadCourseChat(courseID: courseID)) ?? []
            isLoaded = true
        }
    }

    func lectureTitle(ordinal: Int) -> String {
        lectures.first { $0.ordinal == ordinal }?.session.title ?? "Lecture \(ordinal)"
    }

    func ask(_ text: String) {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isAnswering, let assistant else { return }
        draft = ""
        error = nil
        lastQuestion = question
        pendingQuestion = question
        streaming = ""
        isAnswering = true
        let history = answers
        task?.cancel()
        task = Task { [weak self] in
            do {
                for try await event in assistant.ask(question, history: history) {
                    guard let self, !Task.isCancelled else { return }
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
                guard let self, !Task.isCancelled else { return }
                self.error = error.localizedDescription
                self.streaming = nil
                self.pendingQuestion = nil
            }
            self?.isAnswering = false
        }
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
