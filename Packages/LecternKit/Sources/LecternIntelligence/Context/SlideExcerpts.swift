import Foundation
import LecternCore

/// Slide text for the variable part of a prompt: specific pages (current slide ± neighbours, a
/// takeaway's slides) plus retrieval hits, deduplicated and fitted to a token budget.
struct SlideExcerpts: Sendable {
    let deck: SlideDeck?
    let search: (any SlideSearching)?

    static let maxCharsPerSlide = 450

    /// Valid 1-based page numbers of the deck.
    var validPages: Set<Int> { Set(deck?.pages.map(\.number) ?? []) }

    /// `pages` first (in order), then up to `hits` search results for `query`.
    func render(pages: [Int], query: String?, hits: Int, budgetTokens: Int) -> String? {
        var entries: [(page: Int, text: String)] = []
        var seen = Set<Int>()
        for number in pages where !seen.contains(number) {
            guard let page = deck?.page(number) else { continue }
            seen.insert(number)
            entries.append((number, DeckDigest.pageText(page)))
        }
        if let query, !query.isEmpty, hits > 0, let search {
            for hit in search.search(query, limit: hits) where !seen.contains(hit.page) {
                seen.insert(hit.page)
                let text = deck?.page(hit.page).map(DeckDigest.pageText) ?? Text.collapse(hit.excerpt)
                entries.append((hit.page, text))
            }
        }
        guard !entries.isEmpty else { return nil }

        var lines: [String] = []
        var used = 0
        for entry in entries {
            let line = "[S\(entry.page)] " + Text.truncate(entry.text, maxChars: Self.maxCharsPerSlide)
            let cost = TokenBudget.estimate(line) + 1
            if used + cost > budgetTokens, !lines.isEmpty { break }
            lines.append(line); used += cost
        }
        return lines.joined(separator: "\n")
    }

    /// "[S9] Title; [S10] Title" for `pages`, or nil when empty.
    func titles(_ pages: [Int]) -> String? {
        let parts = pages.compactMap { n in deck?.page(n).map { "[S\(n)] " + Text.truncate(Text.collapse($0.title ?? DeckDigest.pageText($0)), maxChars: 60) } }
        return parts.isEmpty ? nil : parts.joined(separator: "; ")
    }

    /// `current` and its neighbours, clipped to the deck.
    func neighbourhood(of current: Int?, radius: Int = 1) -> [Int] {
        guard let current else { return [] }
        return [current] + (1...max(1, radius)).flatMap { [current + $0, current - $0] }.filter(validPages.contains)
    }

    /// Keeps only pages that exist in the deck, sorted and unique.
    func sanitize(_ pages: [Int]) -> [Int] {
        let valid = validPages
        return Array(Set(pages.filter(valid.contains))).sorted()
    }
}
