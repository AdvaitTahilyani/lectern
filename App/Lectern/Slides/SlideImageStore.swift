import AppKit
import Foundation
import LecternCore
import LecternSlides

/// Slide images for a lecture's decks, addressed by combined page number (pages numbered across
/// the decks in order, as in `LectureSession.deck`).
///
/// Rendering never happens on the main actor: `image(page:width:)` returns what is cached (or the
/// same page at another size while the new one renders) and asks a `SlideRasterizer` for the rest;
/// views re-read when renders land. Every store shares one bounded image cache, so memory stays
/// bounded however many decks are open (Setup, a lecture, the library).
@Observable
@MainActor
final class SlideImageStore {
    /// One deck's PDF and how many combined page numbers it covers.
    struct Source: Hashable {
        var url: URL
        var pageCount: Int
    }

    /// Aspect ratio (height / width) of the first page, or 9/16 when unknown.
    private(set) var aspect: CGFloat = 9 / 16
    private(set) var pageCount: Int = 0
    /// The PDFs, in deck order.
    let sources: [Source]
    var hasDeck: Bool { !sources.isEmpty }

    /// Bumped (coalesced) when renders land, so views showing images re-read them.
    private var renderGeneration = 0
    @ObservationIgnored private var bumpScheduled = false
    @ObservationIgnored private var inFlight: Set<String> = []
    @ObservationIgnored private var failed: Set<String> = []
    /// Per page, the size bucket last rendered: shown while another size renders.
    @ObservationIgnored private var lastBucket: [Int: Int] = [:]
    @ObservationIgnored private let rasterizer = SlideRasterizer()

    /// Shared by every store: hero, thumbnail and library sizes of every open deck.
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.totalCostLimit = 160 * 1024 * 1024
        return cache
    }()

    /// One PDF (Setup's or Import's chosen file).
    convenience init(url: URL?) {
        self.init(urls: url.map { [$0] } ?? [])
    }

    /// Several PDFs, each counted by its own page count.
    convenience init(urls: [URL]) {
        self.init(sources: urls.compactMap { url in
            SlideRasterizer.info(for: url).map { Source(url: url, pageCount: $0.pageCount) }
        })
    }

    /// A lecture's decks stored in `folder`. Each deck covers as many combined numbers as it has
    /// pages, so images line up with `LectureSession.deck`; a deck saved without page metadata
    /// (seeded demo lectures) counts its PDF's pages.
    convenience init(decks: [SlideDeck], folder: URL) {
        self.init(sources: decks.compactMap { deck in
            let url = folder.appendingPathComponent(deck.fileName)
            if !deck.pages.isEmpty { return Source(url: url, pageCount: deck.pages.count) }
            return SlideRasterizer.info(for: url).map { Source(url: url, pageCount: $0.pageCount) }
        })
    }

    init(sources: [Source]) {
        self.sources = sources
        pageCount = sources.reduce(0) { $0 + $1.pageCount }
        if let first = sources.first, let info = SlideRasterizer.info(for: first.url) { aspect = info.aspect }
    }

    /// The PDF and local page a combined page number shows.
    func location(of page: Int) -> (url: URL, page: Int)? {
        guard page >= 1 else { return nil }
        var first = 1
        for source in sources {
            if page < first + source.pageCount { return (source.url, page - first + 1) }
            first += source.pageCount
        }
        return nil
    }

    /// Image for a 1-based combined page at roughly `width` points (rendered at 2× for Retina).
    /// Nil until the first render of the page lands; the view updates when it does.
    func image(page: Int, width: CGFloat) -> NSImage? {
        _ = renderGeneration
        guard let location = location(of: page) else { return nil }
        let bucket = max(1, Int((width / 64).rounded(.up))) * 64
        let key = "\(location.url.path)|\(location.page)@\(bucket)"
        if let cached = Self.cache.object(forKey: key as NSString) { return cached }
        render(page: page, location: location, bucket: bucket, key: key)
        guard let previous = lastBucket[page] else { return nil }
        return Self.cache.object(forKey: cacheKey(page: page, bucket: previous) as NSString)
    }

    /// Starts rendering the given pages so they appear without a placeholder.
    func prewarm(pages: Range<Int>, width: CGFloat) {
        for p in pages { _ = image(page: p, width: width) }
    }

    /// Images are cached by file, not by store: a lecture's PDFs are stored under unique names and
    /// never rewritten, so a new store for the same files (a deck added, the lecture reopened)
    /// reuses every image, and a different deck can never be shown from a stale entry.
    private func cacheKey(page: Int, bucket: Int) -> String {
        guard let location = location(of: page) else { return "" }
        return "\(location.url.path)|\(location.page)@\(bucket)"
    }

    private func render(page: Int, location: (url: URL, page: Int), bucket: Int, key: String) {
        guard !failed.contains(key), inFlight.insert(key).inserted else { return }
        let rasterizer = rasterizer
        Task { [weak self] in
            let image = try? await rasterizer.render(location.url, page: location.page, pixelWidth: bucket * 2)
            self?.finish(key: key, page: page, bucket: bucket, image: image)
        }
    }

    private func finish(key: String, page: Int, bucket: Int, image: CGImage?) {
        inFlight.remove(key)
        guard let image else {
            failed.insert(key)
            return
        }
        let size = NSSize(width: CGFloat(bucket), height: CGFloat(bucket) * CGFloat(image.height) / CGFloat(max(image.width, 1)))
        Self.cache.setObject(NSImage(cgImage: image, size: size), forKey: key as NSString, cost: image.width * image.height * 4)
        lastBucket[page] = bucket
        scheduleRefresh()
    }

    /// Renders land one at a time; views refresh once per short batch rather than per image.
    private func scheduleRefresh() {
        guard !bumpScheduled else { return }
        bumpScheduled = true
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(16))
            guard let self else { return }
            bumpScheduled = false
            renderGeneration &+= 1
        }
    }
}
