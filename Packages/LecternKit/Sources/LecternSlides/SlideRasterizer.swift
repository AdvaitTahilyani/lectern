import CoreGraphics
import Foundation

/// Renders slide pages to bitmaps off the main actor, for thumbnails and the slide viewer.
///
/// PDF documents are not safe to share across threads, so a rasterizer owns its own documents (a
/// few, most recently used first) and renders one page at a time. Rendered `CGImage`s are
/// immutable and handed back to the caller's actor.
public actor SlideRasterizer {
    /// What a view needs to lay a deck out before any page is drawn.
    public struct DocumentInfo: Sendable, Hashable {
        public var pageCount: Int
        /// Height / width of the first page as displayed.
        public var aspect: Double
    }

    private var renderers: [URL: PDFPageRenderer] = [:]
    /// Open documents, least recently used first.
    private var recent: [URL] = []
    private let maxOpenDocuments: Int

    public init(maxOpenDocuments: Int = 4) {
        self.maxOpenDocuments = max(1, maxOpenDocuments)
    }

    /// Page count and aspect of the PDF at `url`, read synchronously (opening a PDF only reads
    /// its page tree; nothing is drawn). Nil when the file is missing, unreadable or locked.
    public nonisolated static func info(for url: URL) -> DocumentInfo? {
        guard let renderer = try? PDFPageRenderer(url: url), renderer.pageCount > 0 else { return nil }
        return DocumentInfo(pageCount: renderer.pageCount, aspect: renderer.aspect(ofPage: 1) ?? 9 / 16)
    }

    /// The 1-based `page` of the PDF at `url`, `pixelWidth` pixels wide.
    public func render(_ url: URL, page: Int, pixelWidth: Int) throws -> CGImage {
        try Task.checkCancellation()
        return try renderer(for: url).render(page: page, pixelWidth: pixelWidth)
    }

    /// Closes the document at `url` (a deck was removed, or its owner went away).
    public func close(_ url: URL) {
        renderers[url] = nil
        recent.removeAll { $0 == url }
    }

    private func renderer(for url: URL) throws -> PDFPageRenderer {
        if let open = renderers[url] {
            recent.removeAll { $0 == url }
            recent.append(url)
            return open
        }
        let renderer = try PDFPageRenderer(url: url)
        renderers[url] = renderer
        recent.append(url)
        while recent.count > maxOpenDocuments { renderers[recent.removeFirst()] = nil }
        return renderer
    }
}
