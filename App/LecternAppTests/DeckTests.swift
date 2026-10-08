import Foundation
import LecternCore
import Synchronization
import Testing
@testable import Lectern

/// Slide decks in a lecture: adding (live and in Review), several decks, removing and reordering,
/// manual slide correction, Setup's deck selection, and the deck caches (audit B06, B21, B22, B26,
/// B27, B28, B43).
@Suite(.serialized) @MainActor struct DeckTests {
    // MARK: Fixtures

    private func pages(_ n: Int, _ tag: String) -> [SlidePage] {
        (1...n).map { SlidePage(number: $0, title: "\(tag) \($0)", text: "\(tag) slide \($0) text") }
    }

    private func deck(_ file: String, pages n: Int) -> SlideDeck {
        SlideDeck(fileName: file, originalFileName: file, title: file, pages: pages(n, file))
    }

    private func services(store: DeckStore, ingestor: DeckIngestor = DeckIngestor()) -> AppServices {
        var services = AppServices.demo
        services.store = store
        services.slideIngestor = ingestor
        return services
    }

    private func model(_ session: LectureSession, mode: LiveSessionModel.Mode, services: AppServices) -> LiveSessionModel {
        LiveSessionModel(session: session, course: nil, mode: mode, services: services, settings: AppSettings(), preferences: UIPreferences())
    }

    // MARK: Adding

    /// Audit B06 (ported fixture): a deck attached in Review is saved without leaving Review.
    @Test func reviewDeckAttachmentIsSavedWithoutClosingReview() async throws {
        let store = DeckStore()
        let session = LectureSession(title: "Review", status: .finished)
        try await store.save(session)
        let model = model(session, mode: .review, services: services(store: store))
        model.addDecks(urls: [URL(fileURLWithPath: "/tmp/audit-deck.pdf")])
        #expect(await poll { await store.saved(session.id)?.deck != nil })
        await model.close()
    }

    @Test func addingDecksLiveCombinesThemInOrder() async throws {
        let store = DeckStore()
        // The demo converter turns any Keynote file into its sample deck.
        let ingestor = DeckIngestor(pageCounts: ["first.pdf": 3, "sample-deck.pdf": 2])
        let session = LectureSession(title: "Live", status: .live)
        let model = model(session, mode: .live, services: services(store: store, ingestor: ingestor))
        model.addDecks(urls: [URL(fileURLWithPath: "/tmp/first.pdf"), URL(fileURLWithPath: "/tmp/notes.txt")])
        #expect(await poll { model.session.decks.count == 1 })
        model.addDecks(urls: [URL(fileURLWithPath: "/tmp/second.key")])   // converted by the demo converter
        #expect(await poll { model.session.decks.count == 2 })
        #expect(model.pageCount == 5)
        #expect(model.deckSpans.map(\.firstPage) == [1, 4])
        #expect(model.session.decks.map(\.originalFileName) == ["first.pdf", "second.key"])
        #expect(Set(model.session.decks.map(\.fileName)).count == 2, "every deck has its own stored file")
        #expect(model.deck?.location(ofPage: 4) == SlideLocation(fileName: model.session.decks[1].fileName, page: 1))
        // The images and the "Adding…" row follow the commit within a moment.
        #expect(await poll { model.slideImages?.pageCount == 5 && model.decksBeingAdded.isEmpty })
        #expect(await poll { await store.saved(session.id)?.decks.count == 2 })
        await model.close()
    }

    // MARK: Removing and reordering

    @Test func removingADeckRenumbersTheLectureAndDeletesItsFile() async throws {
        let store = DeckStore()
        var session = LectureSession(title: "Two decks", status: .live)
        session.decks = [deck("slides-a.pdf", pages: 3), deck("slides-b.pdf", pages: 2)]
        session.takeaways = [Takeaway(title: "T", summary: "S", start: 0, end: 5, slidePages: [2, 4], isLive: false)]
        let model = model(session, mode: .live, services: services(store: store))
        model.selectSlide(5)
        model.removeDeck(at: 0)
        #expect(await poll { model.session.decks.count == 1 })
        #expect(model.pageCount == 2)
        #expect(model.detectedSlide == 2 && model.displayedSlide == 2)
        #expect(model.session.currentSlide == 2)
        #expect(model.session.takeaways[0].slidePages == [1])
        #expect(await poll { await store.removed == ["slides-a.pdf"] })
        await model.close()
    }

    @Test func movingADeckRenumbersEveryReference() async throws {
        let store = DeckStore()
        var session = LectureSession(title: "Two decks", status: .finished)
        session.decks = [deck("slides-a.pdf", pages: 3), deck("slides-b.pdf", pages: 2)]
        session.takeaways = [Takeaway(title: "T", summary: "See [S1] and [S4].", start: 0, end: 5, slidePages: [1, 4], isLive: false)]
        let model = model(session, mode: .review, services: services(store: store))
        model.moveDeck(at: 1, by: -1)
        #expect(await poll { model.session.decks.first?.fileName == "slides-b.pdf" })
        #expect(model.session.takeaways[0].slidePages == [1, 3])
        #expect(model.session.takeaways[0].summary == "See [S3] and [S1].")
        #expect(model.deckSpans.map(\.firstPage) == [1, 3])
        #expect(await poll { await store.saved(session.id)?.decks.first?.fileName == "slides-b.pdf" })
        await model.close()
    }

    // MARK: Manual correction

    @Test func pickingASlideCorrectsTrackingAndResumeKeepsIt() {
        var session = LectureSession(title: "Live", status: .live)
        session.decks = [deck("slides-a.pdf", pages: 6)]
        let model = model(session, mode: .live, services: services(store: DeckStore()))
        model.selectSlide(4)
        #expect(!model.followSlides)
        #expect(model.displayedSlide == 4 && model.detectedSlide == 4 && model.session.currentSlide == 4)
        model.stepSlide(-1)
        #expect(model.displayedSlide == 3 && model.session.currentSlide == 3, "corrections can go backwards")
        model.resumeFollowing()
        #expect(model.followSlides)
        #expect(model.displayedSlide == 3, "resuming doesn't snap back to the old tracked slide")
        model.stepSlide(10)
        #expect(model.displayedSlide == 6, "stepping stops at the last slide")
    }

    // MARK: Jargon corrector identity

    /// Audit B22 (ported fixture): an equal-length text change builds a new corrector.
    @Test func equalLengthDeckReplacementInvalidatesJargonCorrector() {
        var services = AppServices.demo
        services.makeTranscriptCorrector = { deck in ReplacingCorrector(replacement: deck.pages.first?.text ?? "") }
        let fixer = JargonFixer()
        var deck = SlideDeck(fileName: "slides.pdf", originalFileName: "lecture.pdf", title: "Same", pages: [SlidePage(number: 1, title: nil, text: "Alpha")])
        let segment = TranscriptSegment(text: "Heard", start: 0, end: 1, isFinal: true)
        _ = fixer.fix(segment, deck: deck, settings: AppSettings(), services: services)
        deck.pages[0].text = "Gamma"
        #expect(fixer.fix(segment, deck: deck, settings: AppSettings(), services: services).text == "Gamma")
    }

    // MARK: Setup

    /// Audit B27: a conversion still running when another deck is chosen never replaces it, and
    /// its presenter notes never land on the other deck.
    @Test func anOlderConversionNeverWinsInSetup() async throws {
        let sample = try #require(try await AppServices.demo.sampleDeckURL())
        let setup = SetupModel(services: .demo)
        setup.loadDeck(url: URL(fileURLWithPath: "/tmp/old-lecture.pptx"))   // demo converter: 2 s
        setup.loadDeck(url: sample)
        #expect(await poll(timeout: .seconds(10)) { setup.deck != nil })
        try await Task.sleep(for: .milliseconds(2500))
        #expect(setup.deckURL == sample)
        #expect(setup.deckDisplayName == sample.lastPathComponent)
        #expect(setup.deck?.pages.allSatisfy { $0.notes == nil } == true)
        let taken = try #require(setup.takeStartingDeck())
        #expect(taken.url == sample && taken.conversion == nil)
    }

    /// Audit B28: a conversion's temporary folder is deleted; a PDF the converter doesn't own isn't.
    @Test func convertedPresentationsCleanUpOnlyTheirOwnFolder() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lectern-slides-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let pdf = folder.appendingPathComponent("deck.pdf")
        try Data("%PDF".utf8).write(to: pdf)
        ConvertedPresentation(pdf: pdf, notes: [:]).dispose()
        #expect(!FileManager.default.fileExists(atPath: folder.path))

        let other = FileManager.default.temporaryDirectory.appendingPathComponent("keep-\(UUID().uuidString).pdf")
        try Data("%PDF".utf8).write(to: other)
        let foreign = ConvertedPresentation(pdf: other, notes: [:])
        #expect(foreign.temporaryFolder == nil)
        foreign.dispose()
        #expect(FileManager.default.fileExists(atPath: other.path))
        try? FileManager.default.removeItem(at: other)
    }

    // MARK: Images

    @Test func imagesResolveCombinedPagesAcrossFiles() async throws {
        let sample = try #require(try await AppServices.demo.sampleDeckURL())
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("lectern-second-\(UUID().uuidString).pdf")
        try FileManager.default.copyItem(at: sample, to: copy)
        defer { try? FileManager.default.removeItem(at: copy) }
        let one = SlideImageStore(url: sample).pageCount
        let store = SlideImageStore(urls: [sample, copy])
        #expect(store.pageCount == 2 * one)
        #expect(store.location(of: one)?.url == sample)
        #expect(store.location(of: one + 1)?.url == copy && store.location(of: one + 1)?.page == 1)
        #expect(store.location(of: 2 * one + 1) == nil)
        // Rendering happens off the main actor; the image arrives shortly after the first ask.
        #expect(await poll { store.image(page: one + 1, width: 96) != nil })
    }

    /// Audit B26: a lecture whose deck file changed shows the new deck's thumbnail; a missing PDF
    /// is retried rather than given up on for good.
    @Test func libraryThumbnailsFollowTheDeckFileAndRetry() async throws {
        let sample = try #require(try await AppServices.demo.sampleDeckURL())
        let store = DeckStore()
        let id = UUID()
        let folder = try await store.folder(for: id)
        let cache = ThumbnailCache()
        #expect(cache.thumbnail(sessionID: id, fileName: "slides-late.pdf", store: store) == nil)
        try await Task.sleep(for: .milliseconds(300))
        try FileManager.default.copyItem(at: sample, to: folder.appendingPathComponent("slides-late.pdf"))
        #expect(await poll(timeout: .seconds(12)) { cache.thumbnail(sessionID: id, fileName: "slides-late.pdf", store: store) != nil })
        #expect(cache.thumbnail(sessionID: id, fileName: "slides-other.pdf", store: store) == nil, "a different deck file is a different thumbnail")
    }
}

// MARK: - Helpers

/// Polls `condition` until it holds or `timeout` passes.
@MainActor private func poll(timeout: Duration = .seconds(5), _ condition: () async -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return await condition()
}

/// Returns a deck of `pageCounts[file name]` pages (1 by default) for any URL, without reading it.
nonisolated private struct DeckIngestor: SlideIngesting {
    var pageCounts: [String: Int] = [:]

    func ingest(pdfAt url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> SlideDeck {
        let name = url.lastPathComponent
        let count = pageCounts[name] ?? 1
        return SlideDeck(fileName: name, originalFileName: name, title: name,
                         pages: (1...count).map { SlidePage(number: $0, title: "\(name) \($0)", text: "\(name) slide \($0)") })
    }
}

/// In-memory store with a real folder per session; deck files get unique names like the real one.
private actor DeckStore: SessionStoring {
    private var sessions: [UUID: LectureSession] = [:]
    private(set) var removed: [String] = []
    private var imported = 0
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent("lectern-deck-tests-\(UUID().uuidString)")

    func loadCourses() async throws -> [Course] { [] }
    func saveCourses(_ courses: [Course]) async throws {}
    func loadSessions() async throws -> [LectureSession] { Array(sessions.values) }
    func loadSession(id: UUID) async throws -> LectureSession {
        guard let session = sessions[id] else { throw CocoaError(.fileNoSuchFile) }
        return session
    }
    func save(_ session: LectureSession) async throws { sessions[session.id] = session }
    func delete(sessionID: UUID) async throws { sessions[sessionID] = nil }
    func folder(for sessionID: UUID) async throws -> URL {
        let folder = root.appendingPathComponent(sessionID.uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
    func importSlides(from url: URL, into sessionID: UUID) async throws -> String {
        imported += 1
        return "slides-\(imported).pdf"
    }
    func removeSlides(named fileName: String, from sessionID: UUID) async throws { removed.append(fileName) }
    func loadCourseChat(courseID: UUID) async throws -> [CourseAnswer] { [] }
    func saveCourseChat(_ answers: [CourseAnswer], courseID: UUID) async throws {}
    func saved(_ id: UUID) -> LectureSession? { sessions[id] }
}

nonisolated private struct ReplacingCorrector: TranscriptCorrecting {
    let replacement: String
    func correct(_ segment: TranscriptSegment) -> TranscriptSegment {
        var result = segment
        result.text = replacement
        return result
    }
}
