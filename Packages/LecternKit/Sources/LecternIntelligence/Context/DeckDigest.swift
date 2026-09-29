import Foundation
import LecternCore

/// A compact, byte-stable rendering of the whole slide deck that sits right after each role's
/// system prompt, so every call for a role shares the same cacheable prefix.
///
/// Slides are "water-filled": short slides keep all their text and the remaining budget is shared
/// evenly among the long ones.
enum DeckDigest {
    /// Enough for a slide title; below this, later slides are omitted instead.
    static let minimumPerSlide = 24
    private static let omissionNote = "(later slides omitted)"

    static func render(_ deck: SlideDeck?, budgetTokens: Int = TokenBudget.deckDigest) -> String {
        guard let deck, !deck.pages.isEmpty else {
            return "SLIDES: none (no deck attached). Do not cite slides."
        }
        let header = "SLIDES" + (deck.title.map { " — \(Text.collapse($0))" } ?? "") + " (cite as [S#]):"
        let bodies = deck.pages.sorted { $0.number < $1.number }.map { (number: $0.number, text: pageText($0)) }
        let budget = budgetTokens * 4 - header.count - omissionNote.count - 2
        let cap = perSlideCap(lengths: bodies.map { $0.text.count + 8 }, budget: budget)

        var lines = [header]
        var used = 0
        for body in bodies {
            let line = "[S\(body.number)] " + Text.truncate(body.text, maxChars: max(minimumPerSlide, cap))
            if used + line.count + 1 > budget, lines.count > 1 {
                lines.append(omissionNote)
                break
            }
            lines.append(line)
            used += line.count + 1
        }
        return lines.joined(separator: "\n")
    }

    /// "Title | body" with whitespace collapsed and the title not repeated.
    static func pageText(_ page: SlidePage) -> String {
        let body = Text.collapse(page.text)
        guard let rawTitle = page.title, case let title = Text.collapse(rawTitle), !title.isEmpty else {
            return body.isEmpty ? "(no text)" : body
        }
        var rest = body
        if rest.lowercased().hasPrefix(title.lowercased()) { rest = String(rest.dropFirst(title.count)) }
        rest = rest.trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? title : "\(title) | \(rest)"
    }

    /// Largest per-slide character cap such that the capped lengths fit `budget`.
    private static func perSlideCap(lengths: [Int], budget: Int) -> Int {
        guard lengths.reduce(0, +) > budget else { return lengths.max() ?? 0 }
        var low = 0, high = lengths.max() ?? 0
        while low < high {
            let mid = (low + high + 1) / 2
            if lengths.reduce(0, { $0 + min($1, mid) }) <= budget { low = mid } else { high = mid - 1 }
        }
        return low
    }
}
