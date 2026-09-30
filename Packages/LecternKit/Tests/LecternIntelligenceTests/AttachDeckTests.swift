import Foundation
import LecternCore
import Testing
@testable import LecternIntelligence

/// A deck added to a lecture that already has a brain (Add Deck during Live or in Review).
@Suite struct AttachDeckTests {
    let transcript = Fixtures.segments((0..<30).map { i in
        "FOLLOW of A holds the terminals right after A and the end marker dollar is in FOLLOW of S part \(i)"
    })

    func collect(_ stream: AsyncThrowingStream<AskEvent, Error>) async throws -> ChatMessage? {
        var done: ChatMessage?
        for try await event in stream { if case .done(let m) = event { done = m } }
        return done
    }

    @Test func askUsesADeckAttachedInReview() async throws {
        let answer = "FOLLOW(A) holds the terminals right after A [S4] [T1:00]."
        let provider = ScriptedProvider(texts: [answer, answer])
        let brain = Fixtures.brain(provider, context: Fixtures.context(deck: nil, transcript: transcript), slides: nil)

        let before = try await collect(await brain.ask("What is in FOLLOW of the start symbol?", history: []))
        #expect(before?.citations == [.time(60)])            // no deck: the slide citation is dropped
        #expect(!provider.requests[0].system.contains("[S4] FOLLOW sets"))

        await brain.attachDeck(Fixtures.deck, slides: FakeSlides(deck: Fixtures.deck))
        let after = try await collect(await brain.ask("What is in FOLLOW of the start symbol?", history: []))
        #expect(after?.citations == [.slide(4), .time(60)])
        let request = provider.requests[1]
        #expect(request.system.contains("[S4] FOLLOW sets"))  // the deck digest joins the prefix
        #expect(request.lastUser.contains("[S4] FOLLOW sets"))  // and its excerpts the question
        // A lecture in review never learns which slides were shown: nothing is held back.
        #expect(await brain.presentedLimit == nil)
        #expect(!request.lastUser.contains("SLIDES NOT YET SHOWN"))
    }

    @Test func aDeckAttachedMidLiveGroundsLaterSummariesAndTracksFromThere() async throws {
        let before = Fixtures.segments((0..<30).map { "LL one parsing with a parse table part \($0)" })
        let after = Fixtures.segments((0..<12).map { "FIRST sets of terminals that begin strings part \($0)" }, start: 300)
        let slides = FakeSlides(deck: Fixtures.deck, likely: { text, _ in text.contains("FIRST") ? 3 : nil })
        let provider = ScriptedProvider(responder: { request in
            request.lastUser.contains("FIRST sets of terminals")
                ? .text(Fixtures.segmentation("new_topic", quote: "FIRST sets of terminals that begin strings part 0", closed: "A parse table drives LL one parsing.",
                                              title: "FIRST sets", summary: "FIRST holds the terminals that begin derived strings.", slides: [3, 5]))
                : .text(Fixtures.segmentation("continue", title: "LL(1) parsing", summary: "A parse table drives LL one parsing."))
        })
        let brain = Fixtures.brain(provider, context: Fixtures.context(deck: nil), slides: nil, interval: 60,
                                   tuning: BrainTuning(wordsPerUpdate: 10_000, firstUpdateSeconds: 60, slideCheckSeconds: 10, slideWindowSeconds: 5))
        for s in before { await brain.ingest(s) }
        await brain.waitUntilIdle()
        let prefixBefore = try #require(provider.requests.last?.system)
        #expect(!prefixBefore.contains("[S4] FOLLOW sets"))

        await brain.attachDeck(Fixtures.deck, slides: slides)
        #expect(await brain.presentedLimit == nil)            // nothing known yet: nothing restricted
        for s in after { await brain.ingest(s) }
        await brain.waitUntilIdle()

        let later = provider.requests.filter { $0.lastUser.contains("FIRST sets of terminals") }
        #expect(!later.isEmpty)
        // The prefix changed once and stays byte-stable from then on.
        #expect(Set(later.map(\.system)).count == 1)
        #expect(later[0].system != prefixBefore && later[0].system.contains("[S4] FOLLOW sets"))
        // Tracking placed S3; slides past it (and the margin) are held back and never cited.
        #expect(await brain.currentSlide == 3)
        #expect(later.last?.lastUser.contains("SLIDES NOT YET SHOWN: S5") == true)
        let card = try #require(await brain.timeline.takeaways.first { $0.title == "FIRST sets" })
        #expect(card.slidePages == [3])
        let earlier = try #require(await brain.timeline.takeaways.first { $0.title == "LL(1) parsing" })
        #expect(earlier.slidePages.isEmpty)
    }
}
