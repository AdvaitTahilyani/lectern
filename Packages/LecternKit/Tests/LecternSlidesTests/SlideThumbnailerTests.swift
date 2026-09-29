import CoreGraphics
import Foundation
import Testing
@testable import LecternSlides

@Suite struct SlideThumbnailerTests {
    @Test func rendersAspectFitThumbnails() async throws {
        let url = try await FixtureDeck.load().url
        let thumbnailer = try SlideThumbnailer(pdfURL: url)
        #expect(await thumbnailer.pageCount == 10)

        let image = try await thumbnailer.thumbnail(page: 1, maxPixelSize: CGSize(width: 320, height: 320))
        // 960x540 slide: width-bound, 16:9.
        #expect(image.width == 320)
        #expect(image.height == 180)

        let tall = try await thumbnailer.thumbnail(page: 2, maxPixelSize: CGSize(width: 1000, height: 90))
        #expect(tall.height == 90)
        #expect(tall.width == 160)
    }

    @Test func thumbnailsAreNotBlank() async throws {
        let url = try await FixtureDeck.load().url
        let thumbnailer = try SlideThumbnailer(pdfURL: url)
        for page in [1, CompilerDeckFixture.ocrPageNumber] {
            let image = try await thumbnailer.thumbnail(page: page, maxPixelSize: CGSize(width: 480, height: 270))
            #expect(darkPixelFraction(of: image) > 0.005, "slide \(page) rendered blank")
        }
    }

    @Test func servesRepeatedRequestsFromCache() async throws {
        let url = try await FixtureDeck.load().url
        let thumbnailer = try SlideThumbnailer(pdfURL: url)
        let size = CGSize(width: 200, height: 200)
        let first = try await thumbnailer.thumbnail(page: 3, maxPixelSize: size)
        let second = try await thumbnailer.thumbnail(page: 3, maxPixelSize: size)
        #expect(first === second)
        await thumbnailer.removeAllCachedImages()
        let third = try await thumbnailer.thumbnail(page: 3, maxPixelSize: size)
        #expect(first !== third)
    }

    @Test func rejectsBadPagesAndFiles() async throws {
        let url = try await FixtureDeck.load().url
        let thumbnailer = try SlideThumbnailer(pdfURL: url)
        await #expect(throws: SlideRenderError.pageOutOfRange(page: 11, pageCount: 10)) {
            try await thumbnailer.thumbnail(page: 11, maxPixelSize: CGSize(width: 100, height: 100))
        }
        await #expect(throws: SlideRenderError.pageOutOfRange(page: 0, pageCount: 10)) {
            try await thumbnailer.thumbnail(page: 0, maxPixelSize: CGSize(width: 100, height: 100))
        }
        let missing = FixtureDeck.temporaryURL()
        #expect(throws: SlideRenderError.unreadable(missing)) { try SlideThumbnailer(pdfURL: missing) }
    }

    @Test func prefetchWarmsTheCache() async throws {
        let url = try await FixtureDeck.load().url
        let thumbnailer = try SlideThumbnailer(pdfURL: url)
        let size = CGSize(width: 120, height: 120)
        await thumbnailer.prefetch(pages: 1...10, maxPixelSize: size)
        let a = try await thumbnailer.thumbnail(page: 5, maxPixelSize: size)
        let b = try await thumbnailer.thumbnail(page: 5, maxPixelSize: size)
        #expect(a === b)
    }

    /// Share of pixels that are not near-white.
    private func darkPixelFraction(of image: CGImage) -> Double {
        guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return 0 }
        let pixelCount = image.width * image.height
        var dark = 0
        for row in 0..<image.height {
            for column in 0..<image.width {
                let offset = row * image.bytesPerRow + column * (image.bitsPerPixel / 8)
                if bytes[offset] < 200 { dark += 1 }
            }
        }
        return Double(dark) / Double(pixelCount)
    }
}
