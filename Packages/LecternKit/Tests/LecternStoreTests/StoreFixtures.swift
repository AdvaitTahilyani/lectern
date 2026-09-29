import Foundation
import LecternCore
@testable import LecternStore

enum Fixtures {
    /// Whole-second dates so equality survives the millisecond ISO 8601 encoding.
    static func date(_ offset: TimeInterval = 0) -> Date {
        Date(timeIntervalSince1970: 1_790_000_000 + offset)
    }

    static let courseID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

    static func course() -> Course {
        Course(id: courseID, code: "CS 421", name: "Programming Languages & Compilers", colorHex: "#5E5CE6", createdAt: date(-86_400))
    }

    /// A session exercising every persisted field.
    static func session(
        id: UUID = UUID(),
        title: String = "Top-Down Parsing",
        startedAt: TimeInterval = 0
    ) -> LectureSession {
        let mcq = QuizQuestion(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            prompt: "Which set is used to fill M[A, a]?",
            kind: .multipleChoice(options: ["FOLLOW", "FIRST", "LAST"], correctIndex: 1),
            concept: "Parse table construction",
            sourceSlides: [7], sourceStart: 600, sourceEnd: 720, createdAt: date(700)
        )
        let short = QuizQuestion(
            id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            prompt: "Define FIRST(X).",
            kind: .shortAnswer(referenceAnswer: "Terminals that can begin strings derived from X."),
            concept: "FIRST sets", sourceSlides: [4], createdAt: date(400)
        )
        return LectureSession(
            id: id,
            courseID: courseID,
            title: title,
            createdAt: date(startedAt - 60),
            startedAt: date(startedAt),
            endedAt: date(startedAt + 3_130),
            duration: 3_130,
            status: .finished,
            deck: SlideDeck(
                fileName: "slides.pdf", originalFileName: "lecture9.pdf", title: "Lecture 9: Top-Down Parsing",
                pages: [
                    SlidePage(number: 1, title: "Top-Down Parsing", text: "Top-Down Parsing\nLL(1) grammars"),
                    SlidePage(number: 2, title: "Recursive Descent", text: "One procedure per nonterminal", notes: "Mention backtracking cost;\nshow the call stack."),
                ]
            ),
            transcript: [
                TranscriptSegment(text: "Welcome back, today is top-down parsing.", start: 2, end: 6, isFinal: true, speaker: .lecturer),
                TranscriptSegment(text: "The FIRST set of a nonterminal is the set of terminals that can begin its strings.", start: 395, end: 402, isFinal: true),
                TranscriptSegment(text: "Does FIRST include epsilon?", start: 403, end: 405, isFinal: true, speaker: .audience(index: 1)),
                TranscriptSegment(text: "still being revised", start: 402, end: 404, isFinal: false),
                TranscriptSegment(text: "We put the end marker in FOLLOW of the start symbol.", start: 3_725, end: 3_731, isFinal: true),
            ],
            takeaways: [
                Takeaway(
                    id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
                    title: "FIRST sets", summary: "FIRST(X) collects the terminals that can start a string derived from X.",
                    detail: TakeawayDetail(
                        bullets: ["Terminals map to themselves.", "Add ε when X can vanish."],
                        keyTerms: [KeyTerm(term: "nullable", definition: "Can derive the empty string.")],
                        example: "FIRST(E') = { +, ε }", generatedAt: date(500)
                    ),
                    start: 390, end: 520, slidePages: [4, 5, 6, 9], isLive: false, updatedAt: date(520)
                ),
                Takeaway(
                    id: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!,
                    title: "Recursive descent", summary: "One procedure per nonterminal.",
                    start: 30, end: 200, slidePages: [2], isLive: false, updatedAt: date(200)
                ),
            ],
            quiz: [
                QuizRecord(
                    question: short, answer: "Terminals in the follow position",
                    grade: QuizGrade(isCorrect: false, feedback: "FIRST is about what a string can begin with, not what comes after.", citations: [.slide(4), .time(395)]),
                    outcome: .incorrect, askedAt: 400, answeredAt: date(420)
                ),
                QuizRecord(question: mcq, answer: "1", grade: QuizGrade(isCorrect: true, feedback: "Right."), outcome: .correct, askedAt: 700, answeredAt: date(710)),
                QuizRecord(question: QuizQuestion(prompt: "Skipped one", kind: .shortAnswer(referenceAnswer: "x"), concept: "Other", createdAt: date(900)), outcome: .skipped, askedAt: 900),
            ],
            chat: [
                ChatMessage(id: UUID(uuidString: "66666666-6666-6666-6666-666666666666")!, role: .user, text: "What is FIRST?", createdAt: date(800)),
                ChatMessage(id: UUID(uuidString: "77777777-7777-7777-7777-777777777777")!, role: .assistant, text: "The set of ... [S4]", citations: [.slide(4)], createdAt: date(801)),
            ],
            currentSlide: 9,
            vocabulary: ["FOLLOW", "nullable"],
            source: .mediaSpace(entryID: "1_abc", pageURL: URL(string: "https://mediaspace.illinois.edu/media/1_abc"), usedCaptions: true)
        )
    }

    /// A fresh empty root directory, removed when the returned value is discarded by the caller.
    static func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "lectern-store-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    /// A small PDF-looking file for import tests.
    static func makePDF(named name: String = "deck.pdf", contents: String = "%PDF-1.4 test") throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString)-\(name)")
        try Data(contents.utf8).write(to: url)
        return url
    }
}

/// A `SessionStoring` that records saves, for autosaver tests.
actor RecordingStore: SessionStoring {
    struct Failure: Error {}

    private(set) var saved: [LectureSession] = []
    /// Number of upcoming saves that should throw.
    var failuresRemaining = 0
    var saveDelay: Duration = .zero
    private(set) var concurrentSaves = 0
    private(set) var maxConcurrentSaves = 0

    func failNext(_ count: Int) { failuresRemaining = count }
    func setSaveDelay(_ delay: Duration) { saveDelay = delay }

    func save(_ session: LectureSession) async throws {
        concurrentSaves += 1
        maxConcurrentSaves = max(maxConcurrentSaves, concurrentSaves)
        defer { concurrentSaves -= 1 }
        if saveDelay > .zero { try await Task.sleep(for: saveDelay) }
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw Failure()
        }
        saved.append(session)
    }

    func loadCourses() async throws -> [Course] { [] }
    func saveCourses(_ courses: [Course]) async throws {}
    func loadSessions() async throws -> [LectureSession] { saved }
    func loadSession(id: UUID) async throws -> LectureSession { throw StoreError.sessionNotFound(id) }
    func delete(sessionID: UUID) async throws {}
    func folder(for sessionID: UUID) async throws -> URL { FileManager.default.temporaryDirectory }
    func importSlides(from url: URL, into sessionID: UUID) async throws -> String { "slides.pdf" }
}

/// Polls until `condition` holds or `timeout` passes.
func eventually(timeout: Duration = .seconds(3), _ condition: () async -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}
