import Foundation
import LecternCore

/// Applies the deck-based jargon corrector ("gen expression" → `genExpr`) to final transcript
/// segments before they reach the brain and the store. The corrector is rebuilt only when the
/// deck changes (a deck added or removed mid-session, or a different session's deck).
@MainActor
final class JargonFixer {
    static let shared = JargonFixer()

    /// The deck the cached corrector was built from. Compared by value, so any change to any
    /// page's text, notes or title (even an equal-length one, audit B22) builds a new corrector.
    /// The comparison is cheap in the common case: a session hands over the same deck storage
    /// every time, and arrays and strings that share storage compare equal without reading it.
    private var cachedDeck: SlideDeck?
    private var cachedCorrector: (any TranscriptCorrecting)?

    /// `segment`, corrected when the setting is on, the segment is final and there is a deck.
    func fix(_ segment: TranscriptSegment, deck: SlideDeck?, settings: AppSettings, services: AppServices) -> TranscriptSegment {
        guard settings.fixesJargonFromSlides, segment.isFinal, let deck else { return segment }
        return corrector(for: deck, services: services)?.correct(segment) ?? segment
    }

    private func corrector(for deck: SlideDeck, services: AppServices) -> (any TranscriptCorrecting)? {
        if cachedDeck != deck {
            cachedCorrector = services.makeTranscriptCorrector(deck)
            cachedDeck = deck
        }
        return cachedCorrector
    }
}
