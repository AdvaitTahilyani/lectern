import Foundation
import LecternCore
import Testing
@testable import Lectern

/// Opening a lecture at a time or slide must land there even when the lecture is already open
/// and on screen (QA Q3-8).
struct PendingNavigationTests {
    private static let course = Course(code: "CS 421", name: "Programming Languages & Compilers")
    private static let seeded = DemoLibrarySeed.scripted(script: .compilers, course: course, startedAt: Date(timeIntervalSince1970: 1_758_700_000))

    private func makeReviewModel() -> LiveSessionModel {
        LiveSessionModel(session: Self.seeded, course: Self.course, mode: .review, services: .demo, settings: AppSettings(), preferences: UIPreferences())
    }

    /// The demo deck, loaded synchronously (review otherwise loads it after the view appears).
    private func sampleDeck() async throws -> SlideImageStore {
        let url = try #require(try await AppServices.demo.sampleDeckURL())
        let store = SlideImageStore(url: url)
        #expect(store.pageCount > 7)
        return store
    }

    @Test func openSessionRecordsWhereToLandAndHandsItOverOnce() {
        let app = AppModel(services: .demo, isDemo: true)
        let id = Self.seeded.id
        app.openSession(id, at: 426, slide: 7)
        #expect(app.pendingNavigation?.time == 426)
        #expect(app.pendingNavigation?.slide == 7)
        #expect(app.takePendingNavigation(for: UUID()) == nil, "another lecture's view never consumes it")
        let nav = app.takePendingNavigation(for: id)
        #expect(nav?.sessionID == id)
        #expect(app.pendingNavigation == nil)
        app.openSession(id)
        #expect(app.pendingNavigation == nil, "a plain open has nothing to apply")
    }

    @Test func repeatedRequestsToTheSamePlaceStayDistinct() {
        let id = UUID()
        #expect(PendingNavigation(sessionID: id, time: 10, slide: nil) != PendingNavigation(sessionID: id, time: 10, slide: nil))
    }

    @Test func navigatingAnOpenLectureSeeksAndShowsTheSlide() async throws {
        let model = makeReviewModel()
        model.slideImages = try await sampleDeck()
        model.navigate(to: PendingNavigation(sessionID: model.id, time: 426, slide: 7))
        #expect(model.transcriptSeek?.time == 426, "the explicit time wins over the slide's first-shown time")
        #expect(model.displayedSlide == 7)
        #expect(model.followSlides == false)
        #expect(model.inspectorTab == .transcript)
        #expect(model.isInspectorShown)

        model.navigate(to: PendingNavigation(sessionID: model.id, time: 900, slide: nil))
        #expect(model.transcriptSeek?.time == 900)
        #expect(model.displayedSlide == 7, "a time-only request leaves the slide alone")

        model.navigate(to: PendingNavigation(sessionID: UUID(), time: 5, slide: 2))
        #expect(model.transcriptSeek?.time == 900, "requests for other lectures are ignored")
    }

    @Test func compactTierLandsOnTheTranscriptPane() async throws {
        let model = makeReviewModel()
        model.slideImages = try await sampleDeck()
        model.layoutTier = .single
        model.navigate(to: PendingNavigation(sessionID: model.id, time: 426, slide: 7))
        #expect(model.pane == .transcript)
        #expect(model.displayedSlide == 7)
    }

    /// A seeded review knows its page count only once the deck images load (QA Q3-8: the hero
    /// stayed on slide 1); the slide request waits for them.
    @Test func slideRequestWaitsForTheDeckImagesAndKeepsItsTime() async throws {
        let model = makeReviewModel()
        #expect(model.pageCount == 0)
        model.navigate(to: PendingNavigation(sessionID: model.id, time: 426, slide: 7))
        #expect(model.displayedSlide != 7)
        model.slideImages = try await sampleDeck()
        #expect(model.displayedSlide == 7)
        #expect(model.followSlides == false)
        #expect(model.transcriptSeek?.time == 426, "the hit's time is not replaced by the slide's first-shown time")
    }

    @Test func deferredRequestStillLandsOnTheTranscriptPaneInTheCompactTier() async throws {
        let model = makeReviewModel()
        model.layoutTier = .single
        model.navigate(to: PendingNavigation(sessionID: model.id, time: 426, slide: 7))
        model.slideImages = try await sampleDeck()
        #expect(model.pane == .transcript)
        #expect(model.displayedSlide == 7)
        #expect(model.transcriptSeek?.time == 426)
    }
}
