import CoreGraphics
import Foundation
import Testing
@testable import LecternSlides

@Suite struct PDFPageRendererTests {
    @Test func rendersAtTheRequestedScaleOverWhite() async throws {
        let renderer = try PDFPageRenderer(url: try await FixtureDeck.load().url)
        #expect(renderer.pageCount == 10)
        let image = try renderer.render(page: 1, scale: 0.5)
        // 960x540 pt slide at half scale.
        #expect(image.width == 480)
        #expect(image.height == 270)
        #expect(darkPixelFraction(of: image) > 0.005, "slide 1 rendered blank")
    }

    @Test func longEdgeIsClamped() async throws {
        let renderer = try PDFPageRenderer(url: try await FixtureDeck.load().url)
        let image = try renderer.render(page: 1, scale: 4, maxDimension: 800)
        #expect(max(image.width, image.height) <= 800)
        #expect(image.width * 9 == image.height * 16 || abs(image.width * 9 - image.height * 16) <= 16)
    }

    @Test func rejectsBadPagesAndFiles() async throws {
        let renderer = try PDFPageRenderer(url: try await FixtureDeck.load().url)
        #expect(throws: SlideRenderError.pageOutOfRange(page: 11, pageCount: 10)) { try renderer.render(page: 11, scale: 1) }
        #expect(throws: SlideRenderError.pageOutOfRange(page: 0, pageCount: 10)) { try renderer.render(page: 0, scale: 1) }
        let missing = FixtureDeck.temporaryURL()
        #expect(throws: SlideRenderError.unreadable(missing)) { try PDFPageRenderer(url: missing) }
    }

    /// Share of pixels that are not near-white.
    private func darkPixelFraction(of image: CGImage) -> Double {
        guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return 0 }
        var dark = 0
        for row in 0..<image.height {
            for column in 0..<image.width {
                let offset = row * image.bytesPerRow + column * (image.bitsPerPixel / 8)
                if bytes[offset] < 200 { dark += 1 }
            }
        }
        return Double(dark) / Double(image.width * image.height)
    }
}
