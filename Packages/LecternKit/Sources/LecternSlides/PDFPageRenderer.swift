import CoreGraphics
import Foundation

/// A thin wrapper over `CGPDFDocument` that renders pages to bitmaps, to feed image-only slides
/// to OCR and to draw slide images (`SlideRasterizer`).
///
/// `CGPDFDocument` is not annotated `Sendable`; a renderer is only ever used from one isolation
/// domain (an actor or a single ingest task) and is never shared.
struct PDFPageRenderer {
    private let document: CGPDFDocument

    /// Opens `url`. Throws `SlideRenderError` when the file is missing/corrupt or locked.
    init(url: URL, password: String? = nil) throws {
        guard let document = CGPDFDocument(url as CFURL) else { throw SlideRenderError.unreadable(url) }
        if document.isEncrypted, !document.isUnlocked {
            guard document.unlockWithPassword(password ?? "") else { throw SlideRenderError.passwordProtected(url) }
        }
        self.document = document
    }

    var pageCount: Int { document.numberOfPages }

    /// Renders the 1-based `pageNumber` at `scale` pixels per point (e.g. 2 for OCR), clamping the
    /// longest edge to `maxDimension` pixels to bound memory on poster-sized pages.
    func render(page pageNumber: Int, scale: CGFloat, maxDimension: CGFloat = 3200) throws -> CGImage {
        guard pageNumber >= 1, pageNumber <= pageCount else {
            throw SlideRenderError.pageOutOfRange(page: pageNumber, pageCount: pageCount)
        }
        guard let page = document.page(at: pageNumber) else { throw SlideRenderError.renderFailed(page: pageNumber) }
        let size = Self.displaySize(of: page)
        guard size.width > 0, size.height > 0 else { throw SlideRenderError.renderFailed(page: pageNumber) }
        let clamped = min(scale, maxDimension / max(size.width, size.height))
        return try draw(page, size: size, scale: clamped, pageNumber: pageNumber)
    }

    /// Renders the 1-based `pageNumber` `pixelWidth` pixels wide (height from the page's aspect).
    func render(page pageNumber: Int, pixelWidth: Int) throws -> CGImage {
        guard pageNumber >= 1, pageNumber <= pageCount else {
            throw SlideRenderError.pageOutOfRange(page: pageNumber, pageCount: pageCount)
        }
        guard let page = document.page(at: pageNumber) else { throw SlideRenderError.renderFailed(page: pageNumber) }
        let size = Self.displaySize(of: page)
        guard size.width > 0, size.height > 0 else { throw SlideRenderError.renderFailed(page: pageNumber) }
        return try render(page: pageNumber, scale: CGFloat(max(pixelWidth, 1)) / size.width)
    }

    /// Height / width of the 1-based page as displayed, or nil when it has no area.
    func aspect(ofPage pageNumber: Int) -> Double? {
        guard pageNumber >= 1, pageNumber <= pageCount, let page = document.page(at: pageNumber) else { return nil }
        let size = Self.displaySize(of: page)
        return size.width > 0 && size.height > 0 ? Double(size.height / size.width) : nil
    }

    /// Size of the page as displayed (crop box, rotation applied), in points.
    private static func displaySize(of page: CGPDFPage) -> CGSize {
        let box = page.getBoxRect(.cropBox)
        return page.rotationAngle % 180 == 0 ? box.size : CGSize(width: box.height, height: box.width)
    }

    private func draw(_ page: CGPDFPage, size: CGSize, scale: CGFloat, pageNumber: Int) throws -> CGImage {
        let width = max(1, Int((size.width * scale).rounded()))
        let height = max(1, Int((size.height * scale).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { throw SlideRenderError.renderFailed(page: pageNumber) }

        let target = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(target)
        context.interpolationQuality = .high
        context.concatenate(page.getDrawingTransform(.cropBox, rect: target, rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(page)
        guard let image = context.makeImage() else { throw SlideRenderError.renderFailed(page: pageNumber) }
        return image
    }
}
