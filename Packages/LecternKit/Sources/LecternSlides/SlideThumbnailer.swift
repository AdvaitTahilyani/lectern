import CoreGraphics
import Foundation

/// Renders slide page images from a PDF, cached in memory.
///
/// An actor: all rendering happens on its (background) executor, never on the main thread, and
/// concurrent requests for the same image are served from the cache once the first finishes.
public actor SlideThumbnailer {
    private let renderer: PDFPageRenderer
    private let cache = NSCache<NSString, CGImage>()

    /// - Parameters:
    ///   - pdfURL: the deck's PDF.
    ///   - password: only needed for encrypted decks.
    ///   - cacheCostLimit: approximate cache budget in bytes (default 128 MB).
    public init(pdfURL: URL, password: String? = nil, cacheCostLimit: Int = 128 * 1_024 * 1_024) throws {
        renderer = try PDFPageRenderer(url: pdfURL, password: password)
        cache.totalCostLimit = cacheCostLimit
    }

    /// Number of pages in the PDF.
    public var pageCount: Int { renderer.pageCount }

    /// Returns the 1-based `page` scaled to fit inside `maxPixelSize` (in pixels — multiply points
    /// by the screen's backing scale for Retina). Aspect ratio is preserved.
    public func thumbnail(page: Int, maxPixelSize: CGSize) throws -> CGImage {
        let key = "\(page)@\(Int(maxPixelSize.width))x\(Int(maxPixelSize.height))" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let image = try renderer.render(page: page, fitting: maxPixelSize)
        cache.setObject(image, forKey: key, cost: image.bytesPerRow * image.height)
        return image
    }

    /// Warms the cache for `pages`, ignoring pages that fail to render (they surface their error
    /// when requested individually via `thumbnail(page:maxPixelSize:)`).
    public func prefetch(pages: some Sequence<Int>, maxPixelSize: CGSize) {
        for page in pages where !Task.isCancelled {
            _ = try? thumbnail(page: page, maxPixelSize: maxPixelSize)
        }
    }

    /// Drops every cached image (e.g. on memory pressure).
    public func removeAllCachedImages() {
        cache.removeAllObjects()
    }
}
