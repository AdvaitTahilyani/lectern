import CoreGraphics
import Foundation
import LecternCore
import OSLog
import PDFKit

/// Parses a slide PDF into a `SlideDeck`.
///
/// Text comes from PDFKit. Footers and page numbers repeated on most pages are removed, words
/// broken across lines are rejoined, and each page gets a title guessed from font sizes. Pages
/// with (almost) no extractable text, i.e. image-only slides, are rendered at 2x and read with
/// Vision OCR.
///
/// The returned deck's `fileName` and `originalFileName` are both the URL's last path component;
/// callers that import the PDF under a different stored name should overwrite `fileName`.
public struct PDFSlideIngestor: SlideIngesting {
    /// Password for encrypted PDFs. Decks that open with the empty password need none.
    public var password: String?
    /// Pages with fewer letters/digits than this are treated as image-only: they are OCR'd and
    /// the recognized text replaces the extracted text.
    public var minimumTextCharacters: Int
    /// Pages that contain an embedded image and fewer letters/digits than this (a title over a
    /// screenshot or table) are OCR'd too, and the recognized text is added to the extracted text.
    public var sparseTextCharacters: Int
    /// Upper bound on pages recognized simultaneously.
    public var maxConcurrentOCR: Int
    /// Reads the text of one rendered page (Vision). Replaceable so tests can make pages fail.
    var recognizeText: @Sendable (CGImage) async throws -> RecognizedPageText = { try await SlideTextRecognizer.recognize($0) }

    private static let logger = Logger(subsystem: "app.lectern", category: "slides.ingest")

    public init(password: String? = nil, minimumTextCharacters: Int = 20, sparseTextCharacters: Int = 150, maxConcurrentOCR: Int = 3) {
        self.password = password
        self.minimumTextCharacters = minimumTextCharacters
        self.sparseTextCharacters = sparseTextCharacters
        self.maxConcurrentOCR = max(1, maxConcurrentOCR)
    }

    public func ingest(pdfAt url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> SlideDeck {
        guard FileManager.default.fileExists(atPath: url.path) else { throw SlideIngestError.fileNotFound(url) }
        guard let document = PDFDocument(url: url) else { throw SlideIngestError.unreadable(url) }
        if document.isLocked, !document.unlock(withPassword: password ?? "") {
            throw SlideIngestError.passwordProtected(url)
        }
        let pageCount = document.pageCount
        guard pageCount > 0 else { throw SlideIngestError.noPages(url) }
        progress(0)

        // 1. Raw text per page.
        var pageLines: [[String]] = []
        var hasImage: [Bool] = []
        var pages: [PDFPage] = []
        for index in 0..<pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: index) else { throw SlideIngestError.unreadable(url) }
            pages.append(page)
            let raw = page.string ?? ""
            hasImage.append(raw.contains(SlideTextCleaner.imageMarker))
            pageLines.append(SlideTextCleaner.lines(from: raw))
        }

        // 2. Furniture removal, then work out which pages still lack text.
        let footerKeys = SlideTextCleaner.repeatedFooterKeys(in: pageLines)
        var cleaned = pageLines.map { SlideTextCleaner.removingFurniture(from: $0, footerKeys: footerKeys) }
        var titles: [String?] = (0..<pageCount).map {
            SlideTitleExtractor.title(of: pages[$0], lines: cleaned[$0], footerKeys: footerKeys)
        }
        let characterCounts = cleaned.map(SlideTextCleaner.alphanumericCount)
        let ocrPages = (0..<pageCount).filter {
            characterCounts[$0] < minimumTextCharacters || (hasImage[$0] && characterCounts[$0] < sparseTextCharacters)
        }
        let extractionShare = ocrPages.isEmpty ? 0.95 : 0.4
        progress(extractionShare)

        // 3. OCR image-only pages. Pages it fails on are flagged on the deck, so the app can say
        // which slides have no searchable text instead of reporting a fully indexed deck.
        var unrecognized: Set<Int> = []
        if !ocrPages.isEmpty {
            let (results, failed) = try await recognize(pages: ocrPages, url: url) { done in
                progress(extractionShare + (0.95 - extractionShare) * Double(done) / Double(ocrPages.count))
            }
            unrecognized = failed
            for (index, recognized) in results {
                let lines = SlideTextCleaner.removingFurniture(
                    from: SlideTextCleaner.lines(from: recognized.text), footerKeys: footerKeys
                )
                if characterCounts[index] < minimumTextCharacters {
                    cleaned[index] = lines
                    if let ocrTitle = recognized.title.flatMap({ SlideTextCleaner.lines(from: $0).first }),
                       lines.contains(ocrTitle) {
                        titles[index] = ocrTitle
                    } else {
                        titles[index] = SlideTitleExtractor.firstLineTitle(lines)
                    }
                } else {
                    cleaned[index] = SlideTextCleaner.merging(ocrLines: lines, into: cleaned[index])
                }
            }
        }

        let slidePages = (0..<pageCount).map {
            SlidePage(number: $0 + 1, title: titles[$0], text: cleaned[$0].joined(separator: "\n"),
                      textRecognitionFailed: unrecognized.contains($0) ? true : nil)
        }
        let deck = SlideDeck(
            fileName: url.lastPathComponent,
            originalFileName: url.lastPathComponent,
            title: deckTitle(for: document, url: url, firstPage: slidePages.first),
            pages: slidePages
        )
        progress(1)
        return deck
    }

    // MARK: OCR

    /// Recognizes `pages` (0-based indices) with at most `maxConcurrentOCR` in flight. Rendering
    /// uses its own `CGPDFDocument` and happens serially; only recognition runs concurrently.
    /// Individual page failures are logged and returned (0-based) as `failed`, leaving that page's
    /// text as PDFKit extracted it; if every page fails, the error is thrown.
    private func recognize(
        pages: [Int], url: URL, onPageDone: @Sendable (Int) -> Void
    ) async throws -> (results: [Int: RecognizedPageText], failed: Set<Int>) {
        let renderer = try PDFPageRenderer(url: url, password: password)
        var results: [Int: RecognizedPageText] = [:]
        var failures: [(page: Int, error: any Error)] = []
        var done = 0

        try await withThrowingTaskGroup(of: (Int, Result<RecognizedPageText, any Error>).self) { group in
            var iterator = pages.makeIterator()
            func enqueueNext() throws {
                guard let index = iterator.next() else { return }
                try Task.checkCancellation()
                let image: CGImage
                do {
                    image = try renderer.render(page: index + 1, scale: 2)
                } catch {
                    failures.append((index + 1, error))
                    done += 1
                    onPageDone(done)
                    try enqueueNext()
                    return
                }
                let recognizeText = recognizeText
                group.addTask {
                    do { return (index, .success(try await recognizeText(image))) } catch {
                        return (index, .failure(error))
                    }
                }
            }
            for _ in 0..<min(maxConcurrentOCR, pages.count) { try enqueueNext() }
            while let (index, result) = try await group.next() {
                switch result {
                case .success(let recognized): results[index] = recognized
                case .failure(let error): failures.append((index + 1, error))
                }
                done += 1
                onPageDone(done)
                try enqueueNext()
            }
        }

        for failure in failures {
            Self.logger.error("OCR failed for slide \(failure.page): \(failure.error.localizedDescription, privacy: .public)")
        }
        if results.isEmpty, let first = failures.first {
            throw SlideIngestError.ocrFailed(
                pages: failures.map(\.page).sorted(), reason: first.error.localizedDescription
            )
        }
        return (results, Set(failures.map { $0.page - 1 }))
    }

    // MARK: Deck title

    private func deckTitle(for document: PDFDocument, url: URL, firstPage: SlidePage?) -> String? {
        if let metadata = document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String,
           let title = Self.usableMetadataTitle(metadata) {
            return title
        }
        return firstPage?.title
    }

    /// Strips exporter noise ("Microsoft PowerPoint - deck.pptx") and rejects placeholder titles.
    static func usableMetadataTitle(_ raw: String) -> String? {
        var title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["Microsoft PowerPoint - ", "Microsoft Word - ", "PowerPoint Presentation - "] where title.hasPrefix(prefix) {
            title = String(title.dropFirst(prefix.count))
        }
        for suffix in [".pptx", ".ppt", ".key", ".pdf", ".docx", ".tex"] where title.lowercased().hasSuffix(suffix) {
            title = String(title.dropLast(suffix.count))
        }
        title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let placeholders: Set<String> = ["", "untitled", "powerpoint presentation", "slide 1", "presentation", "document"]
        return placeholders.contains(title.lowercased()) ? nil : title
    }
}
