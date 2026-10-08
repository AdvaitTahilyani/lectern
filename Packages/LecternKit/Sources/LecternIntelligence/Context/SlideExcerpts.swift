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
    /// - Parameters:
    ///   - allowed: pages that may be shown (e.g. only those the lecture has reached).
    ///   - maxChars: text kept per slide.
    func render(pages: [Int], query: String?, hits: Int, budgetTokens: Int, maxChars: Int = Self.maxCharsPerSlide,
                allowed: (Int) -> Bool = { _ in true }) -> String? {
        var entries: [(page: Int, text: String)] = []
        var seen = Set<Int>()
        for number in pages where !seen.contains(number) && allowed(number) {
            guard let page = deck?.page(number) else { continue }
            seen.insert(number)
            entries.append((number, DeckDigest.pageText(page)))
        }
        if let query, !query.isEmpty, hits > 0, let search {
            for hit in search.search(query, limit: hits) where !seen.contains(hit.page) && allowed(hit.page) {
                seen.insert(hit.page)
                let text = deck?.page(hit.page).map(DeckDigest.pageText) ?? Text.collapse(hit.excerpt)
                entries.append((hit.page, text))
            }
        }
        guard !entries.isEmpty else { return nil }

        var lines: [String] = []
        var used = 0
        for entry in entries {
            let line = "[S\(entry.page)] " + Text.truncate(entry.text, maxChars: maxChars)
            let cost = TokenBudget.estimate(line) + 1
            if used + cost > budgetTokens, !lines.isEmpty { break }
            lines.append(line); used += cost
        }
        return lines.joined(separator: "\n")
    }

    /// "[S9] Title; [S14–S17] Title" for `pages`, or nil when empty. Consecutive pages with the
    /// same title (build slides) collapse into one range.
    func titles(_ pages: [Int]) -> String? {
        var runs: [(first: Int, last: Int, title: String)] = []
        for n in pages {
            guard let page = deck?.page(n) else { continue }
            let title = Text.truncate(Text.collapse(page.title ?? DeckDigest.pageText(page)), maxChars: 60)
            if let last = runs.last, last.title == title, n > last.last {
                runs[runs.count - 1].last = n
            } else {
                runs.append((n, n, title))
            }
        }
        let parts = runs.map { $0.first == $0.last ? "[S\($0.first)] \($0.title)" : "[S\($0.first)–S\($0.last)] \($0.title)" }
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
