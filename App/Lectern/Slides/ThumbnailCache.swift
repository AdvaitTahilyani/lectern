import AppKit
import Foundation
import LecternCore
import LecternSlides

/// Library card thumbnails: page 1 of each lecture's first deck, rendered off the main actor.
///
/// Entries are keyed by lecture *and* deck file, and stored deck files are never rewritten, so a
/// lecture whose deck changed shows the new deck at once (audit B26). A load that fails (the PDF
/// not there yet) is tried again after a pause, a few times, instead of never. Memory is bounded
/// for the whole library: images live in one size-limited cache, and only the PDF being rendered
/// is open (B47).
@Observable
@MainActor
final class ThumbnailCache {
    /// Bumped when an image lands or a retry is due, so cards ask again.
    private var generation = 0
    @ObservationIgnored private let images: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()
    @ObservationIgnored private var inFlight: Set<String> = []
    /// Failed attempts per key.
    @ObservationIgnored private var failures: [String: Int] = [:]
    @ObservationIgnored private let rasterizer = SlideRasterizer(maxOpenDocuments: 1)

    static let retryDelay: Duration = .seconds(5)
    static let maxAttempts = 3
    /// Pixel width rendered for a card (cards are ~300 pt wide, drawn at 2×).
    static let pixelWidth = 600

    /// The card image for `sessionID`'s deck stored as `fileName`, or nil while it loads.
    func thumbnail(sessionID: UUID, fileName: String, store: any SessionStoring) -> NSImage? {
        _ = generation
        let key = "\(sessionID.uuidString)|\(fileName)"
        if let image = images.object(forKey: key as NSString) { return image }
        if failures[key, default: 0] >= Self.maxAttempts { return nil }
        guard inFlight.insert(key).inserted else { return nil }
        let rasterizer = rasterizer
        Task { [weak self] in
            var image: CGImage?
            if let folder = try? await store.folder(for: sessionID) {
                let url = folder.appendingPathComponent(fileName)
                image = try? await rasterizer.render(url, page: 1, pixelWidth: Self.pixelWidth)
                await rasterizer.close(url)
            }
            self?.finish(key: key, image: image)
        }
        return nil
    }

    private func finish(key: String, image: CGImage?) {
        guard let image else {
            let count = failures[key, default: 0] + 1
            failures[key] = count
            guard count < Self.maxAttempts else { inFlight.remove(key); return }
            // The key stays in flight through the pause, so re-renders can't retry before it ends.
            Task { [weak self] in
                try? await Task.sleep(for: Self.retryDelay)
                self?.inFlight.remove(key)
                self?.generation &+= 1
            }
            return
        }
        inFlight.remove(key)
        failures[key] = nil
        let size = NSSize(width: CGFloat(Self.pixelWidth) / 2, height: CGFloat(Self.pixelWidth) / 2 * CGFloat(image.height) / CGFloat(max(image.width, 1)))
        images.setObject(NSImage(cgImage: image, size: size), forKey: key as NSString, cost: image.width * image.height * 4)
        generation &+= 1
    }
}
