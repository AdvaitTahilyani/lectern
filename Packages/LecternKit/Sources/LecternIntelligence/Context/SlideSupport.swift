import Foundation
import LecternCore

/// Keeps a card's slide list honest: a slide is cited only when its text actually supports what
/// the card says. Models tend to echo whatever slide was on screen (or listed as relevant), and a
/// stuck or wrong slide tracker would otherwise stamp every card with the same page.
struct SlideSupport: Sendable {
    private let pages: [Int]
    private let terms: [Set<String>]
    private let index: BM25Index

    /// A page must score at least this share of the best-supported page in the deck.
    static let minShareOfBest = 0.5
    /// ...and share at least `minSharedTerms` distinct terms with the card, and a quarter of the
    /// card's terms for longer cards (up to 5), so a couple of generic words ("instruction",
    /// "optimization") are not support.
    static let minSharedTerms = 3
    static let minSharedShare = 0.25
    static let maxSharedRequirement = 5

    init(deck: SlideDeck?) {
        let sorted = (deck?.pages ?? []).sorted { $0.number < $1.number }
        pages = sorted.map(\.number)
        let documents = sorted.map { TranscriptRetriever.terms(($0.title ?? "") + " " + $0.text) }
        terms = documents.map(Set.init)
        index = BM25Index(documents: documents)
    }

    /// The subset of `cited` that `text` (the card's title and summary) supports, in order. If
    /// none qualifies, the best-supported page among `fallback` (slides shown or retrieved for the
    /// stretch), when it supports the text at all.
    func supported(_ cited: [Int], by text: String, fallback: Set<Int>) -> [Int] {
        let query = TranscriptRetriever.terms(text)
        let cardTerms = Set(query)
        let required = max(Self.minSharedTerms, min(Self.maxSharedRequirement, Int((Double(cardTerms.count) * Self.minSharedShare).rounded(.up))))
        let hits = index.search(query).filter { terms[$0.index].intersection(cardTerms).count >= required }
        guard let best = hits.first?.score, best > 0 else { return [] }
        var scores: [Int: Double] = [:]
        for hit in hits { scores[pages[hit.index]] = hit.score }
        let kept = cited.filter { (scores[$0] ?? 0) >= best * Self.minShareOfBest }
        if !kept.isEmpty { return kept }
        return hits.first { fallback.contains(pages[$0.index]) && $0.score >= best * Self.minShareOfBest }.map { [pages[$0.index]] } ?? []
    }
}
