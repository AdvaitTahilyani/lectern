import Foundation
import LecternCore
import PDFKit
import Vision

/// PDFKit-based `SlideIngesting`: extracts page text, falls back to Vision OCR for image-only
/// pages, and derives a heuristic title per page.
nonisolated struct PDFSlideIngestor: SlideIngesting {
    nonisolated enum IngestError: LocalizedError {
        case unreadable, encrypted
        var errorDescription: String? {
            switch self {
            case .unreadable: "Couldn't read that PDF"
            case .encrypted: "That PDF is encrypted"
            }
        }
    }

    func ingest(pdfAt url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> SlideDeck {
        try await Task.detached(priority: .userInitiated) {
            guard let document = PDFDocument(url: url) else { throw IngestError.unreadable }
            if document.isLocked { throw IngestError.encrypted }
            let count = document.pageCount
            guard count > 0 else { throw IngestError.unreadable }
            var pages: [SlidePage] = []
            pages.reserveCapacity(count)
            for i in 0..<count {
                try Task.checkCancellation()
                guard let page = document.page(at: i) else { continue }
                var text = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if text.count < 4 { text = Self.ocr(page) }
                pages.append(SlidePage(number: i + 1, title: Self.title(from: text), text: text))
                progress(Double(i + 1) / Double(count))
            }
            let deckTitle = document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String
            let title = (deckTitle?.isEmpty == false ? deckTitle : nil) ?? pages.first?.title
            return SlideDeck(fileName: "slides.pdf", originalFileName: url.lastPathComponent, title: title, pages: pages)
        }.value
    }

    /// First substantial line of the page.
    private static func title(from text: String) -> String? {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.count >= 3 && $0.count <= 120 }
    }

    private static func ocr(_ page: PDFPage) -> String {
        let image = page.thumbnail(of: CGSize(width: 1600, height: 1200), for: .mediaBox)
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return "" }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: cg)
        guard (try? handler.perform([request])) != nil else { return "" }
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
}

// MARK: - Retrieval

/// Lightweight TF-IDF retrieval over a deck, adequate for slide following and Ask grounding
/// until the full retrieval module lands.
nonisolated final class SimpleSlideIndex: SlideSearching {
    private let pageTokens: [Int: [String: Double]]
    private let idf: [String: Double]
    private let pageOrder: [Int]

    init(deck: SlideDeck) {
        var tokens: [Int: [String: Double]] = [:]
        var df: [String: Int] = [:]
        for page in deck.pages {
            var counts: [String: Double] = [:]
            for t in Self.tokenize(page.text + " " + (page.title ?? "")) { counts[t, default: 0] += 1 }
            tokens[page.number] = counts
            for t in counts.keys { df[t, default: 0] += 1 }
        }
        let n = Double(max(1, deck.pages.count))
        idf = df.mapValues { log((n + 1) / (Double($0) + 0.5)) }
        pageTokens = tokens
        pageOrder = deck.pages.map(\.number)
    }

    func search(_ query: String, limit: Int) -> [SlideHit] {
        let q = Self.tokenize(query)
        guard !q.isEmpty else { return [] }
        return pageOrder.compactMap { page -> SlideHit? in
            let s = score(q, page: page)
            guard s > 0 else { return nil }
            return SlideHit(page: page, score: s, excerpt: "")
        }
        .sorted { $0.score > $1.score }
        .prefix(limit)
        .map { $0 }
    }

    /// The demo index never suggests going back; only the real `SlideIndex` does.
    func backtrackCandidate(forTranscript text: String, current: Int) -> Int? { nil }

    func likelySlide(forTranscript text: String, near: Int?) -> Int? {
        let q = Self.tokenize(text)
        guard q.count >= 4 else { return nil }
        var best: (page: Int, score: Double)?
        for page in pageOrder {
            var s = score(q, page: page)
            if let near {
                let d = page - near
                s *= (0...2).contains(d) ? 1.25 : (d < 0 ? 0.6 : 0.85)
            }
            if s > (best?.score ?? 0) { best = (page, s) }
        }
        guard let best, best.score >= 1.0 else { return nil }
        return best.page
    }

    private func score(_ q: [String], page: Int) -> Double {
        guard let counts = pageTokens[page] else { return 0 }
        var s = 0.0
        for t in Set(q) where counts[t] != nil { s += (idf[t] ?? 0) * min(2, counts[t] ?? 0) }
        return s
    }

    private static let stopwords: Set<String> = ["the", "a", "an", "of", "to", "and", "or", "in", "is", "it", "that", "this", "for", "on", "we", "you", "so", "if", "be", "as", "at", "by", "with", "are", "was", "can", "not", "then", "than", "into", "from", "which", "what", "have", "has", "our", "its", "like", "just", "okay", "uh", "um"]

    static func tokenize(_ s: String) -> [String] {
        s.lowercased()
            .split { !($0.isLetter || $0.isNumber || $0 == "'" ) }
            .map(String.init)
            .filter { $0.count > 1 && !stopwords.contains($0) }
    }
}
