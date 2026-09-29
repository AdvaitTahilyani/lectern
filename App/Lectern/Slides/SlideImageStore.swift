import AppKit
import Foundation
import PDFKit
import LecternCore

/// Renders and caches slide images for a session's deck. PDFKit isn't thread-safe per document, so
/// rendering happens on the main actor; sizes are small and `PDFPage.thumbnail` is fast.
@Observable
@MainActor
final class SlideImageStore {
    // Rendering happens lazily from view bodies, so the cache must not be observed.
    @ObservationIgnored private var document: PDFDocument?
    @ObservationIgnored private var cache: [String: NSImage] = [:]
    /// Aspect ratio (height / width) of the first page, or 9/16 when unknown.
    private(set) var aspect: CGFloat = 9 / 16
    private(set) var pageCount: Int = 0
    let url: URL?

    init(url: URL?) {
        self.url = url
        if let url, let doc = PDFDocument(url: url) {
            document = doc
            pageCount = doc.pageCount
            if let first = doc.page(at: 0) {
                let bounds = first.bounds(for: .mediaBox)
                if bounds.width > 0 { aspect = bounds.height / bounds.width }
            }
        }
    }

    var hasDeck: Bool { document != nil }

    /// Image for a 1-based page number at roughly `width` points (rendered at 2× for Retina).
    func image(page: Int, width: CGFloat) -> NSImage? {
        guard let document, page >= 1, page <= document.pageCount else { return nil }
        let bucket = Int((width / 64).rounded(.up)) * 64
        let key = "\(page)@\(bucket)"
        if let cached = cache[key] { return cached }
        guard let pdfPage = document.page(at: page - 1) else { return nil }
        let size = CGSize(width: CGFloat(bucket) * 2, height: CGFloat(bucket) * 2 * aspect)
        let image = pdfPage.thumbnail(of: size, for: .mediaBox)
        cache[key] = image
        return image
    }

    /// Pre-renders the first few thumbnails so the deck fan appears without a hitch.
    func prewarm(pages: Range<Int>, width: CGFloat) {
        for p in pages { _ = image(page: p, width: width) }
    }
}
