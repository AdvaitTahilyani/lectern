import Foundation
import Testing
@testable import LecternCore

/// Several decks per lecture: the combined deck, page resolution, and renumbering on add/remove/move.
@Suite struct SlideDecksTests {
    private func deck(_ file: String, pages: Int, notes: [Int: String] = [:]) -> SlideDeck {
        SlideDeck(fileName: file, originalFileName: file.replacingOccurrences(of: "slides-", with: ""), title: "Deck \(file)",
                  pages: (1...pages).map { SlidePage(number: $0, title: "\(file) p\($0)", text: "text \(file) \($0)", notes: notes[$0]) })
    }

    @Test func combinedDeckNumbersPagesAcrossDecks() throws {
        let a = deck("slides-a.pdf", pages: 3), b = deck("slides-b.pdf", pages: 2)
        let combined = try #require(SlideDeck.combining([a, b]))
        #expect(combined.pages.map(\.number) == [1, 2, 3, 4, 5])
        #expect(combined.pages.map(\.title) == ["slides-a.pdf p1", "slides-a.pdf p2", "slides-a.pdf p3", "slides-b.pdf p1", "slides-b.pdf p2"])
        #expect(combined.location(ofPage: 2) == SlideLocation(fileName: "slides-a.pdf", page: 2))
        #expect(combined.location(ofPage: 4) == SlideLocation(fileName: "slides-b.pdf", page: 1))
        #expect(combined.location(ofPage: 6) == nil)
        #expect(combined.fileName == "slides-a.pdf", "the library's page-1 thumbnail comes from the first deck")
        // One deck is itself, unchanged.
        #expect(SlideDeck.combining([a]) == a)
        #expect(SlideDeck.combining([]) == nil)
    }

    @Test func splittingUndoesCombining() throws {
        let a = deck("slides-a.pdf", pages: 3, notes: [2: "say this"]), b = deck("slides-b.pdf", pages: 2)
        var combined = try #require(SlideDeck.combining([a, b]))
        #expect(SlideDeck.splitting(combined, previous: [a, b]) == [a, b])
        // An edit through the combined deck reaches the right deck.
        combined.pages[3].text = "edited"
        let split = SlideDeck.splitting(combined, previous: [a, b])
        #expect(split[1].pages[0].text == "edited")
        #expect(split[0] == a)
    }

    @Test func sessionDeckSetterKeepsWorkingForOneDeck() {
        var session = LectureSession(title: "L", deck: deck("slides.pdf", pages: 2))
        #expect(session.decks.count == 1)
        session.deck?.fileName = "slides-new.pdf"
        #expect(session.decks.map(\.fileName) == ["slides-new.pdf"])
        session.deck = nil
        #expect(session.decks.isEmpty)
    }

    @Test func seededDeckWithoutPagesResolvesToItsFile() {
        let seeded = SlideDeck(fileName: "slides.pdf", originalFileName: "x.pdf", title: nil, pages: [])
        #expect(seeded.location(ofPage: 7) == SlideLocation(fileName: "slides.pdf", page: 7))
    }

    @Test func spansShowDeckBoundaries() {
        let session = LectureSession(title: "L", decks: [deck("slides-a.pdf", pages: 3), deck("slides-b.pdf", pages: 2)])
        #expect(session.deckSpans.map(\.firstPage) == [1, 4])
        #expect(session.deckSpans.map(\.pages) == [1...3, 4...5])
        #expect(session.deckSpans[1].contains(4) && !session.deckSpans[1].contains(3))
    }

    // MARK: Renumbering

    private func referencingSession() -> LectureSession {
        var s = LectureSession(title: "L", decks: [deck("slides-a.pdf", pages: 3), deck("slides-b.pdf", pages: 2)])
        s.takeaways = [Takeaway(title: "T", summary: "See [S2] and [S5].", start: 0, end: 10, slidePages: [2, 5], isLive: false)]
        let q = QuizQuestion(prompt: "Q", kind: .shortAnswer(referenceAnswer: "A"), concept: "C", sourceSlides: [4], grounding: QuizGrounding(topic: "t", summary: "s", slides: [4, 1]))
        s.quiz = [QuizRecord(question: q, grade: QuizGrade(isCorrect: false, feedback: "Look at [S4].", citations: [.slide(4), .time(30)]), askedAt: 5)]
        s.chat = [ChatMessage(role: .assistant, text: "It's on [S1, S4] at [T0:30].", citations: [.slide(1), .slide(4), .time(30)])]
        s.summary = LectureSummary(overview: "Overview [S5].", slides: [1, 5])
        s.currentSlide = 4
        return s
    }

    @Test func addingADeckAfterTheOthersChangesNoNumbers() {
        var s = referencingSession()
        let before = s
        s.replaceDecks(with: s.decks + [deck("slides-c.pdf", pages: 4)])
        #expect(s.deck?.pages.count == 9)
        #expect(s.takeaways == before.takeaways && s.quiz == before.quiz && s.chat == before.chat && s.currentSlide == 4)
    }

    @Test func movingADeckRenumbersEveryReference() {
        var s = referencingSession()
        // B (2 pages) first, then A (3): A's p1–3 → 3–5, B's p1–2 (old 4–5) → 1–2.
        let map = s.replaceDecks(with: [s.decks[1], s.decks[0]])
        #expect(map == [1: 3, 2: 4, 3: 5, 4: 1, 5: 2])
        #expect(s.takeaways[0].slidePages == [2, 4])
        #expect(s.takeaways[0].summary == "See [S4] and [S2].")
        #expect(s.quiz[0].question.sourceSlides == [1])
        #expect(s.quiz[0].question.grounding?.slides == [1, 3])
        #expect(s.quiz[0].grade?.citations == [.slide(1), .time(30)])
        #expect(s.quiz[0].grade?.feedback == "Look at [S1].")
        #expect(s.chat[0].citations == [.slide(3), .slide(1), .time(30)])
        #expect(s.chat[0].text == "It's on [S3, S1] at [T0:30].")
        #expect(s.summary?.slides == [2, 3])
        #expect(s.summary?.overview == "Overview [S2].")
        #expect(s.currentSlide == 1)
    }

    @Test func removingADeckDropsItsReferences() {
        var s = referencingSession()
        let map = s.replaceDecks(with: [s.decks[1]])   // A removed
        #expect(map == [4: 1, 5: 2])
        #expect(s.takeaways[0].slidePages == [2])
        #expect(s.takeaways[0].summary == "See  and [S2].")
        #expect(s.chat[0].citations == [.slide(1), .time(30)])
        #expect(s.chat[0].text == "It's on [S1] at [T0:30].")
        #expect(s.quiz[0].question.grounding?.slides == [1])
        #expect(s.currentSlide == 1)

        var gone = referencingSession()
        gone.currentSlide = 2
        gone.replaceDecks(with: [gone.decks[1]])
        #expect(gone.currentSlide == nil, "the current slide was in the removed deck")
    }

    @Test func markersThatAreNotSlidesAreLeftAlone() {
        #expect(LectureSession.remapSlideMarkers(in: "[T1:02] [note] [S9]", [9: 2]) == "[T1:02] [note] [S2]")
        #expect(LectureSession.remapSlideMarkers(in: "no markers", [1: 2]) == "no markers")
        // Semicolons separate tokens too, as `AnswerMarkup` and `CitationParser` read them.
        #expect(LectureSession.remapSlideMarkers(in: "[S1; S2]", [1: 3, 2: 4]) == "[S3, S4]")
        #expect(CitationParser.citations(in: "[S3; T0:10]") == [.slide(3), .time(10)])
    }
}
