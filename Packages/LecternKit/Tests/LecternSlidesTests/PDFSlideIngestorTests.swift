import Foundation
import LecternCore
import Testing
@testable import LecternSlides

@Suite struct PDFSlideIngestorTests {
    @Test func ingestsEveryPageWithTitles() async throws {
        let loaded = try await FixtureDeck.load()
        let deck = loaded.deck
        #expect(deck.pages.count == 10)
        #expect(deck.pages.map(\.number) == Array(1...10))
        for (page, slide) in zip(deck.pages, CompilerDeckFixture.slides) where !slide.imageOnly {
            #expect(page.title == slide.title, "slide \(page.number)")
            #expect(page.text.contains(slide.bullets[0]), "slide \(page.number) keeps its body text")
        }
    }

    @Test func removesRepeatedFootersAndPageNumbers() async throws {
        let deck = try await FixtureDeck.load().deck
        for page in deck.pages {
            #expect(!page.text.contains("Programming Languages"), "footer left on slide \(page.number)")
            #expect(!page.text.contains("Fall 2026"), "footer left on slide \(page.number)")
            let lines = page.text.split(separator: "\n").map(String.init)
            #expect(!lines.contains(String(page.number)), "page number left on slide \(page.number)")
        }
    }

    @Test func readsImageOnlySlideWithOCR() async throws {
        let deck = try await FixtureDeck.load().deck
        let page = try #require(deck.page(CompilerDeckFixture.ocrPageNumber))
        let text = page.text.lowercased()
        #expect(text.contains("left recursion"))
        #expect(text.contains("eliminating"))
        #expect(text.contains("loop forever"))
        #expect(page.title?.lowercased().contains("left recursion") == true)
    }

    @Test func deckTitleComesFromMetadataThenFirstPage() async throws {
        let loaded = try await FixtureDeck.load()
        #expect(loaded.deck.title == "Lecture 9: Top-Down Parsing")
        #expect(loaded.deck.fileName == loaded.url.lastPathComponent)

        let untitled = FixtureDeck.temporaryURL()
        try CompilerDeckFixture.write(to: untitled, title: nil)
        defer { try? FileManager.default.removeItem(at: untitled) }
        let deck = try await PDFSlideIngestor().ingest(pdfAt: untitled) { _ in }
        #expect(deck.title == "Top-Down Parsing and LL(1) Grammars")
    }

    @Test func progressIsMonotonicAndCompletes() async throws {
        let progress = try await FixtureDeck.load().progress
        #expect(progress.first == 0)
        #expect(progress.last == 1)
        #expect(zip(progress, progress.dropFirst()).allSatisfy { $0 <= $1 })
    }

    @Test func metadataTitleCleanup() {
        #expect(PDFSlideIngestor.usableMetadataTitle("Microsoft PowerPoint - Lecture 9.pptx") == "Lecture 9")
        #expect(PDFSlideIngestor.usableMetadataTitle("  Untitled ") == nil)
        #expect(PDFSlideIngestor.usableMetadataTitle("PowerPoint Presentation") == nil)
        #expect(PDFSlideIngestor.usableMetadataTitle("Parsing") == "Parsing")
    }

    // MARK: Errors

    @Test func missingFileThrows() async {
        let url = FixtureDeck.temporaryURL()
        await #expect(throws: SlideIngestError.fileNotFound(url)) {
            try await PDFSlideIngestor().ingest(pdfAt: url) { _ in }
        }
    }

    @Test func corruptFileThrowsUnreadable() async throws {
        let url = FixtureDeck.temporaryURL()
        try Data("this is definitely not a pdf".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        await #expect(throws: SlideIngestError.unreadable(url)) {
            try await PDFSlideIngestor().ingest(pdfAt: url) { _ in }
        }
    }

    @Test func passwordProtectedDeckNeedsThePassword() async throws {
        let url = FixtureDeck.temporaryURL()
        try CompilerDeckFixture.write(to: url, password: "hunter2")
        defer { try? FileManager.default.removeItem(at: url) }

        await #expect(throws: SlideIngestError.passwordProtected(url)) {
            try await PDFSlideIngestor().ingest(pdfAt: url) { _ in }
        }
        await #expect(throws: SlideIngestError.passwordProtected(url)) {
            try await PDFSlideIngestor(password: "wrong").ingest(pdfAt: url) { _ in }
        }
        let deck = try await PDFSlideIngestor(password: "hunter2").ingest(pdfAt: url) { _ in }
        #expect(deck.pages.count == 10)
        #expect(deck.pages[1].title == "Recursive Descent Parsing")
    }

    @Test func errorsHaveReadableDescriptions() {
        let url = URL(fileURLWithPath: "/tmp/slides.pdf")
        #expect(SlideIngestError.passwordProtected(url).errorDescription?.contains("password") == true)
        #expect(SlideIngestError.unreadable(url).errorDescription?.contains("slides.pdf") == true)
    }
}
