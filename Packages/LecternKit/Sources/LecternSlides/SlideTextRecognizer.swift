import CoreGraphics
import Foundation
import Vision

/// Text recognized on a rendered page.
struct RecognizedPageText: Sendable {
    /// Recognized lines in reading order (top to bottom, then left to right), joined by newlines.
    var text: String
    /// The tallest line in the top part of the page, the best guess at a slide title.
    var title: String?
}

/// Vision OCR for image-only slides, using the Swift `RecognizeTextRequest` API.
enum SlideTextRecognizer {
    /// A line whose vertical center is above this fraction of the page height is title-eligible.
    private static let titleZone: CGFloat = 0.55

    static func recognize(_ image: CGImage) async throws -> RecognizedPageText {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let observations = try await request.perform(on: image)

        struct Line { var text: String; var box: CGRect }
        var lines: [Line] = []
        for observation in observations {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { lines.append(Line(text: text, box: observation.boundingBox.cgRect)) }
        }
        // Vision boxes are normalized with a bottom-left origin: larger midY is higher on the page.
        // Lines within a small band of each other count as the same row.
        lines.sort { a, b in
            if abs(a.box.midY - b.box.midY) > 0.012 { return a.box.midY > b.box.midY }
            return a.box.minX < b.box.minX
        }
        let title = lines
            .filter { $0.box.midY >= 1 - titleZone }
            .max { $0.box.height < $1.box.height }?
            .text
        return RecognizedPageText(text: lines.map(\.text).joined(separator: "\n"), title: title)
    }
}
