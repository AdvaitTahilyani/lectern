import Foundation

/// Failures surfaced by `PDFSlideIngestor`.
public enum SlideIngestError: LocalizedError, Equatable {
    /// There is no file at the given URL.
    case fileNotFound(URL)
    /// The file exists but is not a readable PDF (corrupt or a different format).
    case unreadable(URL)
    /// The PDF is encrypted and the supplied password (or the empty password) did not unlock it.
    case passwordProtected(URL)
    /// The PDF opened but contains no pages.
    case noPages(URL)
    /// Every page that needed OCR failed to be recognized.
    case ocrFailed(pages: [Int], reason: String)

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let url):
            "The slide file \"\(url.lastPathComponent)\" could not be found."
        case .unreadable(let url):
            "\"\(url.lastPathComponent)\" is not a readable PDF. The file may be damaged."
        case .passwordProtected(let url):
            "\"\(url.lastPathComponent)\" is password protected. Remove the password and try again."
        case .noPages(let url):
            "\"\(url.lastPathComponent)\" does not contain any pages."
        case .ocrFailed(let pages, let reason):
            "Text recognition failed for \(pages.count) image-only slide(s): \(reason)"
        }
    }
}

/// Failures surfaced by `SlideThumbnailer`.
public enum SlideRenderError: LocalizedError, Equatable {
    case unreadable(URL)
    case passwordProtected(URL)
    case pageOutOfRange(page: Int, pageCount: Int)
    case renderFailed(page: Int)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let url): "\"\(url.lastPathComponent)\" is not a readable PDF."
        case .passwordProtected(let url): "\"\(url.lastPathComponent)\" is password protected."
        case .pageOutOfRange(let page, let count): "Slide \(page) does not exist (the deck has \(count) pages)."
        case .renderFailed(let page): "Slide \(page) could not be rendered."
        }
    }
}
