import AppKit
import Foundation
import LecternCore
import LecternSlides
import Testing
@testable import Lectern

// MARK: - Keyboard shortcuts must not fire while typing

@MainActor
struct SessionShortcutTests {
    @Test func textInputResponders() {
        #expect(TextInputFocus.isTextInput(NSTextView()))
        #expect(!TextInputFocus.isTextInput(NSView()))
        #expect(!TextInputFocus.isTextInput(NSButton()))
        #expect(!TextInputFocus.isTextInput(nil))
    }

    @Test func singleKeysNeverActWhileTyping() {
        #expect(!SessionShortcuts.singleKeysAllowed(textInputActive: true))
        #expect(SessionShortcuts.singleKeysAllowed(textInputActive: false))
    }

    @Test func spacePausesOnlyALiveRecordingFromTheSessionView() {
        // A space typed into the quiz's short-answer field (or any field) must be text, not a pause.
        #expect(!SessionShortcuts.spacePausesRecording(isLive: true, textInputActive: true, rootFocused: true))
        #expect(!SessionShortcuts.spacePausesRecording(isLive: true, textInputActive: true, rootFocused: false))
        // Focus somewhere else (a list, a button) gives Space its own meaning there.
        #expect(!SessionShortcuts.spacePausesRecording(isLive: true, textInputActive: false, rootFocused: false))
        #expect(!SessionShortcuts.spacePausesRecording(isLive: false, textInputActive: false, rootFocused: true))
        #expect(SessionShortcuts.spacePausesRecording(isLive: true, textInputActive: false, rootFocused: true))
    }
}

// MARK: - Answer rendering (B24, B31, mixed brackets)

struct AnswerRenderingTests {
    private static let sessionID = UUID()

    private func links(_ text: AttributedString) -> [URL] { text.runs.compactMap(\.link) }

    @Test func mixedSlideAndTimeBracketBecomesTwoLinks() {
        let resolver = CitationResolver.lecture(sessionID: Self.sessionID, citations: [.slide(13), .time(3614)])
        let text = AnswerRendering.attributed("Covered here [S13, T1:00:14].", resolver: resolver)
        #expect(links(text) == [LecternURL.slide(session: Self.sessionID, page: 13), LecternURL.time(session: Self.sessionID, seconds: 3614)])
        #expect(!String(text.characters).contains("["), "no literal bracket text remains")
        #expect(String(text.characters).contains("Slide 13"))
    }

    @Test func markersOutsideTheValidatedListAreNotLinks() {
        let resolver = CitationResolver.lecture(sessionID: Self.sessionID, citations: [.slide(3)])
        let text = AnswerRendering.attributed("See [S3] and [S99] and [T9:59:59].", resolver: resolver)
        #expect(links(text) == [LecternURL.slide(session: Self.sessionID, page: 3)])
        #expect(String(text.characters).contains("Slide 99"), "the invented marker stays visible as plain text")
    }

    @Test func nearbyTimesShareTheValidatedSource() {
        let resolver = CitationResolver.lecture(sessionID: Self.sessionID, citations: [.time(100)])
        let text = AnswerRendering.attributed("[T1:44] and [T3:00]", resolver: resolver)
        #expect(links(text) == [LecternURL.time(session: Self.sessionID, seconds: 104)])
    }

    @Test func streamingAnswersLinkNothing() {
        let text = AnswerRendering.attributed("[S3] and [S4, T0:10]", resolver: .unlinked)
        #expect(links(text).isEmpty)
        #expect(String(text.characters).contains("Slide 3"))
    }

    @Test func courseLinksFollowThePersistedLectureNotTheCurrentOrdinals() {
        // The answer was written when "Lecture 2" was `old`; later `new` took ordinal 2 (a lecture was inserted).
        let old = UUID(), new = UUID()
        let persisted = [CourseCitation(sessionID: old, ordinal: 2, citation: .slide(5))]
        let text = AnswerRendering.attributed("It is in [L2 S5, S9] and [L3 S1].", resolver: .course(citations: persisted))
        #expect(links(text) == [CourseCitationURL.url(for: persisted[0])])
        #expect(CourseCitationURL.parse(links(text)[0])?.sessionID == old)
        #expect(CourseCitationURL.parse(links(text)[0])?.sessionID != new)
    }

    @Test func hugeMarkersDoNotCrashLinkBuilding() {
        let resolver = CitationResolver.lecture(sessionID: Self.sessionID, citations: [])
        let text = AnswerRendering.attributed("[T999999999999999999:00] [S99999999999999999999] [T1e9]", resolver: resolver)
        #expect(links(text).isEmpty)
        #expect(CourseCitationURL.url(for: CourseCitation(sessionID: Self.sessionID, ordinal: 1, citation: .time(.infinity))).absoluteString.hasSuffix("/t/0"))
        #expect(LecternURL.time(session: Self.sessionID, seconds: 1e30).absoluteString.hasSuffix("/t/359999"))
    }

    @Test func listsRenderAsBlocksNotLiteralMarkers() {
        let blocks = AnswerMarkup.blocks("*   **Reduction of Penalty:** shorter [S4]\n*   Second")
        #expect(blocks.count == 2)
        if case .item(let level, let number, let line) = blocks[0] {
            #expect(level == 0 && number == nil)
            let text = AnswerRendering.attributed(line, resolver: .lecture(sessionID: Self.sessionID, citations: [.slide(4)]))
            #expect(!String(text.characters).contains("*"))
            #expect(links(text).count == 1)
        } else {
            Issue.record("first block is not a list item")
        }
    }
}

// MARK: - Transcript search (B30)

@MainActor
struct TranscriptSearchTests {
    private func paragraph(_ text: String, id: UUID = UUID()) -> TranscriptParagraph {
        TranscriptParagraph(id: id, kind: .speech, start: 0, end: 1, segments: [TranscriptSegment(text: text, start: 0, end: 1, isFinal: true)])
    }

    @Test func aTextEditThatKeepsTheShapeInvalidatesTheCache() {
        let id = UUID()
        let cache = TranscriptHitCache()
        let before = [paragraph("the parser reads tokens", id: id)]
        #expect(cache.hits(query: "parser", revision: 1, paragraphs: before) == [id])
        // Same paragraph count and segment count, different words, new revision.
        let after = [paragraph("the lexer reads tokens", id: id)]
        #expect(cache.hits(query: "parser", revision: 2, paragraphs: after).isEmpty)
        #expect(cache.hits(query: "lexer", revision: 2, paragraphs: after) == [id])
        let computations = cache.computations
        _ = cache.hits(query: "lexer", revision: 2, paragraphs: after)
        #expect(cache.computations == computations, "an unchanged query and revision is served from the cache")
    }

    @Test func hitsAreOrderedAndShortQueriesFindNothing() {
        let a = UUID(), b = UUID()
        let paragraphs = [paragraph("Alpha beta", id: a), paragraph("no match", id: UUID()), paragraph("ALPHA again", id: b)]
        #expect(TranscriptSearch.hitIDs(in: paragraphs, query: "alpha") == [a, b])
        #expect(TranscriptSearch.hitIDs(in: paragraphs, query: "a").isEmpty)
        #expect(TranscriptSearch.hitIDs(in: paragraphs, query: "  ").isEmpty)
    }

    @Test func aNewQueryChangesTheFocusEvenWhenTheIndexIsAlreadyZero() {
        let id = UUID()
        let first = TranscriptSearch.Focus(query: "al", index: 0, hitID: nil)
        let second = TranscriptSearch.Focus(query: "alpha", index: 0, hitID: id)
        #expect(first != second, "the view scrolls to the first hit as soon as the query has one")
    }
}

// MARK: - Course Ask (B23, B25, P03)

/// A store whose course chat can be held back or made to fail.
private actor ChatStore: SessionStoring {
    var saved: [CourseAnswer] = []
    var saveCalls = 0
    var failSaves = false
    var failLoads = false
    var holdLoad: Bool
    var stored: [CourseAnswer]
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(stored: [CourseAnswer] = [], holdLoad: Bool = false) { self.stored = stored; self.holdLoad = holdLoad }

    func releaseLoad() { holdLoad = false; waiting.forEach { $0.resume() }; waiting = [] }
    func setFailSaves(_ fail: Bool) { failSaves = fail }
    func setFailLoads(_ fail: Bool) { failLoads = fail }

    func loadCourseChat(courseID: UUID) async throws -> [CourseAnswer] {
        if holdLoad { await withCheckedContinuation { waiting.append($0) } }
        if failLoads { throw CocoaError(.fileReadCorruptFile) }
        return stored
    }
    func saveCourseChat(_ answers: [CourseAnswer], courseID: UUID) async throws {
        saveCalls += 1
        if failSaves { throw CocoaError(.fileWriteOutOfSpace) }
        saved = answers
    }

    func loadCourses() async throws -> [Course] { [] }
    func saveCourses(_ courses: [Course]) async throws {}
    func loadSessions() async throws -> [LectureSession] { [] }
    func loadSession(id: UUID) async throws -> LectureSession { throw CocoaError(.fileNoSuchFile) }
    func save(_ session: LectureSession) async throws {}
    func delete(sessionID: UUID) async throws {}
    func folder(for sessionID: UUID) async throws -> URL { throw CocoaError(.fileNoSuchFile) }
    func importSlides(from url: URL, into sessionID: UUID) async throws -> String { throw CocoaError(.fileNoSuchFile) }
}

/// Records what each assistant was built from and answers every question with a fixed text.
private nonisolated final class AssistantLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _builds: [[CourseLecture]] = []
    private var _indexBuilds = 0
    var builds: [[CourseLecture]] { lock.withLock { _builds } }
    var indexBuilds: Int { lock.withLock { _indexBuilds } }
    func built(_ l: [CourseLecture]) { lock.withLock { _builds.append(l) } }
    func indexed() { lock.withLock { _indexBuilds += 1 } }
}

private nonisolated struct FixedAssistant: CourseAssisting {
    var reply: String
    func ask(_ question: String, history: [CourseAnswer]) -> AsyncThrowingStream<CourseAskEvent, Error> {
        AsyncThrowingStream { c in
            c.yield(.done(CourseAnswer(question: question, text: reply, citations: [])))
            c.finish()
        }
    }
}

@MainActor
struct CourseAskModelTests {
    private let courseID = UUID()

    private func services(store: ChatStore, log: AssistantLog) -> AppServices {
        var s = AppServices.demo
        s.store = store
        s.makeSlideIndex = { deck in log.indexed(); return SlideIndex(deck: deck) }
        s.makeCourseAssistant = { lectures, _ in log.built(lectures); return FixedAssistant(reply: "ok") }
        return s
    }

    private func lecture(_ title: String, deckText: String, transcript: String = "alpha beta", day: Int = 0) -> LectureSession {
        let deck = SlideDeck(fileName: "slides.pdf", originalFileName: "slides.pdf", title: nil, pages: [SlidePage(number: 1, title: "T", text: deckText)])
        var s = LectureSession(courseID: courseID, title: title, createdAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(day) * 86_400), status: .finished, deck: deck)
        s.transcript = [TranscriptSegment(text: transcript, start: 0, end: 5, isFinal: true)]
        return s
    }

    private func deckText(of built: [CourseLecture]) -> String? { built.first?.session.deck?.pages.first?.text }

    /// Ported from the audit: replace a deck under the same file name (same counts), prepare again.
    @Test func courseAssistantSeesReplacedDeckContents() async {
        let log = AssistantLog()
        let model = CourseAskModel(courseID: courseID, services: services(store: ChatStore(), log: log))
        var session = lecture("L1", deckText: "Alpha")
        model.prepare(sessions: [session])
        await model.finishPreparing()
        #expect(deckText(of: log.builds.last ?? []) == "Alpha")

        session.decks[0].pages[0].text = "Gamma"
        model.prepare(sessions: [session])
        await model.finishPreparing()
        #expect(log.builds.count == 2)
        #expect(deckText(of: log.builds.last ?? []) == "Gamma")
    }

    @Test func sameShapedTranscriptAndTakeawayEditsRebuildTheAssistant() async {
        let log = AssistantLog()
        let model = CourseAskModel(courseID: courseID, services: services(store: ChatStore(), log: log))
        var session = lecture("L1", deckText: "Alpha")
        session.takeaways = [Takeaway(title: "Parsing", summary: "first", start: 0, end: 5, isLive: false, updatedAt: .now)]
        model.prepare(sessions: [session]); await model.finishPreparing()
        session.transcript[0].text = "alpha gamma"   // same segment count
        model.prepare(sessions: [session]); await model.finishPreparing()
        session.takeaways[0].summary = "second"      // same takeaway count
        model.prepare(sessions: [session]); await model.finishPreparing()
        #expect(log.builds.count == 3)
        #expect(log.builds.last?.first?.session.takeaways.first?.summary == "second")
    }

    @Test func unchangedLecturesAndDecksAreNotRebuiltOrReindexed() async {
        let log = AssistantLog()
        let model = CourseAskModel(courseID: courseID, services: services(store: ChatStore(), log: log))
        let first = lecture("L1", deckText: "Alpha", day: 0)
        var second = lecture("L2", deckText: "Beta", day: 1)
        model.prepare(sessions: [first, second]); await model.finishPreparing()
        #expect(log.builds.count == 1 && log.indexBuilds == 2)
        model.prepare(sessions: [first, second]); await model.finishPreparing()
        #expect(log.builds.count == 1, "nothing changed")
        second.transcript[0].text = "different words"
        model.prepare(sessions: [first, second]); await model.finishPreparing()
        #expect(log.builds.count == 2)
        #expect(log.indexBuilds == 2, "no deck changed, so no slide index was rebuilt")
        second.decks[0].pages[0].text = "Beta changed"
        model.prepare(sessions: [first, second]); await model.finishPreparing()
        #expect(log.indexBuilds == 3, "only the changed deck was re-indexed")
    }

    @Test func changingTheAskModelRebuildsTheAssistant() async {
        let log = AssistantLog()
        var provider = ProviderConfig(kind: .onDevice, model: "a")
        let model = CourseAskModel(courseID: courseID, services: services(store: ChatStore(), log: log), askProvider: { provider })
        let session = lecture("L1", deckText: "Alpha")
        model.prepare(sessions: [session]); await model.finishPreparing()
        provider = ProviderConfig(kind: .onDevice, model: "b")
        model.prepare(sessions: [session]); await model.finishPreparing()
        #expect(log.builds.count == 2)
        #expect(log.indexBuilds == 1)
    }

    @Test func slowHistoryDoesNotEraseANewAnswerOrResurrectAClearedThread() async {
        let old = CourseAnswer(question: "old?", text: "old", citations: [])
        let store = ChatStore(stored: [old], holdLoad: true)
        let log = AssistantLog()
        let model = CourseAskModel(courseID: courseID, services: services(store: store, log: log))
        model.prepare(sessions: [lecture("L1", deckText: "Alpha")])
        await model.finishPreparing()
        model.ask("new?")                       // waits for the held history load
        await Task.yield()
        await store.releaseLoad()
        await model.flush()
        #expect(model.answers.map(\.question) == ["old?", "new?"], "saved history first, then the new answer; nothing replaced")

        // Cleared while the load is still pending: the saved thread must not come back.
        let held = ChatStore(stored: [old], holdLoad: true)
        let cleared = CourseAskModel(courseID: courseID, services: services(store: held, log: log))
        cleared.prepare(sessions: [lecture("L1", deckText: "Alpha")])
        cleared.clearHistory()
        await held.releaseLoad()
        await cleared.flush()
        #expect(cleared.answers.isEmpty)
        #expect(await held.saved.isEmpty)
    }

    @Test func retryingAFailedHistoryReadKeepsAnswersAskedMeanwhile() async {
        let old = CourseAnswer(question: "old?", text: "old", citations: [])
        let store = ChatStore(stored: [old])
        await store.setFailLoads(true)
        let model = CourseAskModel(courseID: courseID, services: services(store: store, log: AssistantLog()))
        model.prepare(sessions: [lecture("L1", deckText: "Alpha")])
        model.ask("new?")
        await model.flush()
        #expect(model.answers.map(\.question) == ["new?"])
        #expect(await store.saved.isEmpty, "the unreadable saved thread is never overwritten")

        await store.setFailLoads(false)
        model.retryHistory()
        await model.flush()
        #expect(model.answers.map(\.question) == ["old?", "new?"])
        #expect(await store.saved.map(\.question) == ["old?", "new?"])
        #expect(model.historyError == nil)
    }

    @Test func aFailedSaveIsShownKeptAndRetried() async {
        let store = ChatStore()
        await store.setFailSaves(true)
        let model = CourseAskModel(courseID: courseID, services: services(store: store, log: AssistantLog()))
        model.prepare(sessions: [lecture("L1", deckText: "Alpha")])
        model.ask("q?")
        await model.flush()
        #expect(model.answers.count == 1, "the answer stays on screen")
        #expect(model.historyError?.contains("save") == true)

        await store.setFailSaves(false)
        model.retryHistory()
        await model.flush()
        #expect(model.historyError == nil)
        #expect(await store.saved.map(\.question) == ["q?"])
    }
}

// MARK: - Windows (B32)

@MainActor
struct WindowNavigationTests {
    @Test func eachWindowKeepsItsOwnNavigation() async {
        let app = AppModel(services: .demo, isDemo: true)
        await app.loadLibrary()
        let ids = app.sessions.filter { $0.status == .finished }.prefix(2).map(\.id)
        #expect(ids.count == 2)
        let one = WindowNavigation(), two = WindowNavigation()
        app.register(one); app.register(two)

        app.windowBecameKey(one)
        app.openSession(ids[0])
        app.windowBecameKey(two)
        app.openSession(ids[1])
        #expect(one.path == [.session(ids[0])])
        #expect(two.path == [.session(ids[1])])
        #expect(app.session(for: ids[0]) != nil, "opening a lecture in window 2 must not close window 1's")

        app.goBack()   // window 2 is key
        #expect(two.path.isEmpty)
        #expect(one.path == [.session(ids[0])], "Back to Library in one window leaves the other where it was")
        #expect(app.session(for: ids[0]) != nil)

        two.sidebarSelection = .course(UUID())
        #expect(one.sidebarSelection == .all)
        one.searchText = "needle"
        #expect(two.searchText.isEmpty)
    }

    @Test func pendingNavigationLandsInTheWindowThatOpenedIt() async {
        let app = AppModel(services: .demo, isDemo: true)
        await app.loadLibrary()
        let id = app.sessions.first { $0.status == .finished }!.id
        let one = WindowNavigation(), two = WindowNavigation()
        app.register(one); app.register(two)
        app.windowBecameKey(two)
        app.openSession(id, at: 30)
        #expect(two.pendingNavigation?.time == 30)
        #expect(one.pendingNavigation == nil)
    }

    @Test func theLibraryIsLoadedOnceForAllWindows() async throws {
        let services = AppServices.demo
        let app = AppModel(services: services, isDemo: true)
        await app.loadLibraryOnce()
        let first = app.sessions
        // A lecture that appears in the store afterwards would show up in any re-read.
        try await services.store.save(LectureSession(title: "Added after the first read", status: .finished))
        await app.loadLibraryOnce()
        #expect(app.sessions == first, "a second window must not re-read the library")
    }
}
