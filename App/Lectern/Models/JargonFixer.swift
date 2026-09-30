import Foundation
import LecternCore

/// Applies the deck-based jargon corrector ("gen expression" → `genExpr`) to final transcript
/// segments before they reach the brain and the store. The corrector is rebuilt only when the
/// deck changes (a deck added mid-session, or a different session's deck).
@MainActor
final class JargonFixer {
    static let shared = JargonFixer()

    /// Cheap stand-in for hashing the deck: this runs for every final segment, and
    /// `SlideDeck.hashValue` would hash every page's text each time. Names, page count and total
    /// text length tell two decks apart (stored decks all share the file name `slides.pdf`).
    private struct DeckKey: Equatable {
        var originalFileName: String
        var title: String?
        var pageCount: Int
        var textBytes: Int

        init(_ deck: SlideDeck) {
            originalFileName = deck.originalFileName
            title = deck.title
            pageCount = deck.pages.count
            textBytes = deck.pages.reduce(0) { $0 + $1.text.utf8.count }
        }
    }

    private var cachedDeck: DeckKey?
    private var cachedCorrector: (any TranscriptCorrecting)?

    /// `segment`, corrected when the setting is on, the segment is final and there is a deck.
    func fix(_ segment: TranscriptSegment, deck: SlideDeck?, settings: AppSettings, services: AppServices) -> TranscriptSegment {
        guard settings.fixesJargonFromSlides, segment.isFinal, let deck else { return segment }
        return corrector(for: deck, services: services)?.correct(segment) ?? segment
    }

    private func corrector(for deck: SlideDeck, services: AppServices) -> (any TranscriptCorrecting)? {
        let fingerprint = DeckKey(deck)
        if cachedDeck != fingerprint {
            cachedCorrector = services.makeTranscriptCorrector(deck)
            cachedDeck = fingerprint
        }
        return cachedCorrector
    }
}
