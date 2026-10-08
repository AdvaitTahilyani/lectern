import CoreGraphics
import Foundation
import LecternCore
import Synchronization
import Testing
@testable import LecternSlides

@Suite struct SlideRasterizerAndOCRTests {
    /// A PDF of `count` blank pages: no text layer, so every page goes to OCR.
    private func blankPDF(pages count: Int) throws -> URL {
        let url = FixtureDeck.temporaryURL()
        var box = CGRect(x: 0, y: 0, width: 800, height: 600)
        let context = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
        for _ in 0..<count {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(box)
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }

    /// Audit B43: a page whose OCR fails is flagged on the deck, not hidden behind a successful import.
    @Test func partialOCRFailureIsReportedPerPage() async throws {
        let url = try blankPDF(pages: 3)
        let calls = Mutex(0)
        var ingestor = PDFSlideIngestor(maxConcurrentOCR: 1)   // one at a time: pages in order
        ingestor.recognizeText = { _ in
            let call = calls.withLock { $0 += 1; return $0 }
            if call == 2 { throw SlideRenderError.renderFailed(page: 2) }
            return RecognizedPageText(text: "Recognized slide text here", title: "Recognized")
        }
        let deck = try await ingestor.ingest(pdfAt: url) { _ in }
        #expect(deck.pages.map(\.textRecognitionFailed) == [nil, true, nil])
        #expect(deck.pagesMissingText == [2])
        #expect(deck.pages[0].text.contains("Recognized slide text"))
    }

    @Test func everyPageFailingStillThrows() async throws {
        let url = try blankPDF(pages: 2)
        var ingestor = PDFSlideIngestor()
        ingestor.recognizeText = { _ in throw SlideRenderError.renderFailed(page: 1) }
        await #expect(throws: SlideIngestError.self) { try await ingestor.ingest(pdfAt: url) { _ in } }
    }

    @Test func rasterizerRendersAtTheRequestedWidth() async throws {
        let url = try blankPDF(pages: 2)
        let info = try #require(SlideRasterizer.info(for: url))
        #expect(info.pageCount == 2)
        #expect(abs(info.aspect - 0.75) < 0.001)
        let rasterizer = SlideRasterizer(maxOpenDocuments: 1)
        let image = try await rasterizer.render(url, page: 2, pixelWidth: 400)
        #expect(image.width == 400 && image.height == 300)
        await #expect(throws: SlideRenderError.self) { try await rasterizer.render(url, page: 3, pixelWidth: 100) }
        #expect(SlideRasterizer.info(for: FixtureDeck.temporaryURL()) == nil)
    }
}
