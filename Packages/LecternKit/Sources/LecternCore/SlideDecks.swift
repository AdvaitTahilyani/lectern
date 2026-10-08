import Foundation

// A lecture can have several slide decks (`LectureSession.decks`). Everything outside the deck UI
// works on one combined deck (`LectureSession.deck`) whose pages are numbered 1…N across the decks
// in order; each combined page remembers which stored PDF it comes from and its page there, so
// rendering resolves a combined page number to (file, local page).

/// Where a combined slide number lives: a stored PDF in the session folder and a 1-based page in it.
public struct SlideLocation: Sendable, Hashable {
    public var fileName: String
    public var page: Int

    public init(fileName: String, page: Int) {
        self.fileName = fileName
        self.page = page
    }
}

/// One deck's stretch of the combined page numbers, for showing deck boundaries.
public struct DeckSpan: Sendable, Hashable, Identifiable {
    /// Position of the deck in `LectureSession.decks`.
    public var index: Int
    public var deck: SlideDeck
    /// Combined page number of the deck's first page.
    public var firstPage: Int
    public var pageCount: Int

    public var id: String { deck.fileName }
    /// Combined page numbers of the deck's pages.
    public var pages: ClosedRange<Int> { firstPage...(firstPage + max(pageCount, 1) - 1) }
    /// Display name: the deck's title, else its original file name without the extension.
    public var displayName: String {
        if let title = deck.title, !title.isEmpty { return title }
        return (deck.originalFileName as NSString).deletingPathExtension
    }

    public func contains(_ page: Int) -> Bool { pageCount > 0 && pages.contains(page) }
}

public extension SlideDeck {
    /// The decks as one deck (see the file comment); nil for none, the deck itself for one.
    static func combining(_ decks: [SlideDeck]) -> SlideDeck? {
        guard let first = decks.first else { return nil }
        guard decks.count > 1 else { return first }
        var pages: [SlidePage] = []
        pages.reserveCapacity(decks.reduce(0) { $0 + $1.pages.count })
        for deck in decks {
            for page in deck.pages {
                var combined = page
                combined.number = pages.count + 1
                combined.sourceFile = deck.fileName
                combined.sourcePage = page.number
                pages.append(combined)
            }
        }
        return SlideDeck(
            fileName: first.fileName,
            originalFileName: decks.map(\.originalFileName).joined(separator: " + "),
            title: first.title,
            pages: pages
        )
    }

    /// The inverse of `combining`: a combined deck split back into its decks by `sourceFile`, with
    /// local page numbers restored. Deck names and titles come from the matching deck in
    /// `previous` (by file name). A deck whose pages carry no source is a single deck, as is.
    static func splitting(_ combined: SlideDeck?, previous: [SlideDeck]) -> [SlideDeck] {
        guard let combined else { return [] }
        guard combined.pages.contains(where: { $0.sourceFile != nil }) else { return [combined] }
        var result: [SlideDeck] = []
        for page in combined.pages {
            let file = page.sourceFile ?? combined.fileName
            var local = page
            local.sourceFile = nil
            local.sourcePage = nil
            if result.last?.fileName == file {
                local.number = page.sourcePage ?? result[result.count - 1].pages.count + 1
                result[result.count - 1].pages.append(local)
            } else {
                local.number = page.sourcePage ?? 1
                let known = previous.first { $0.fileName == file }
                let isFirst = result.isEmpty && file == combined.fileName
                result.append(SlideDeck(
                    fileName: file,
                    originalFileName: known?.originalFileName ?? file,
                    title: known?.title ?? (isFirst ? combined.title : nil),
                    pages: [local]
                ))
            }
        }
        return result
    }

    /// Decks read from a saved session: `decks` when the file has them, else the single legacy
    /// `deck` (which, written by a build with several decks, may itself be a combined deck).
    static func migrating(decks: [SlideDeck]?, legacy: SlideDeck?) -> [SlideDeck] {
        if let decks, !decks.isEmpty { return decks }
        return splitting(legacy, previous: [])
    }

    /// The stored PDF and page a (combined) page number shows. A deck without page metadata
    /// (seeded demo lectures) resolves every number to its own file.
    func location(ofPage number: Int) -> SlideLocation? {
        guard number >= 1 else { return nil }
        guard !pages.isEmpty else { return SlideLocation(fileName: fileName, page: number) }
        guard let page = page(number) else { return nil }
        return SlideLocation(fileName: page.sourceFile ?? fileName, page: page.sourcePage ?? page.number)
    }

    /// Pages whose text recognition failed (see `SlidePage.textRecognitionFailed`).
    var pagesMissingText: [Int] {
        pages.filter { $0.textRecognitionFailed == true }.map(\.number)
    }
}

public extension LectureSession {
    /// Each deck's stretch of the combined page numbers, in order.
    var deckSpans: [DeckSpan] {
        var first = 1
        return decks.enumerated().map { index, deck in
            defer { first += deck.pages.count }
            return DeckSpan(index: index, deck: deck, firstPage: first, pageCount: deck.pages.count)
        }
    }

    /// Replaces the decks (a deck added, removed or moved) and renumbers every stored slide
    /// reference to match: takeaway pages, quiz sources and grades, chat citations (including the
    /// inline "[S12]" markers), the summary's slides and the current slide. References to pages of
    /// a removed deck are dropped. Returns the old → new combined number map (absent: removed).
    @discardableResult
    mutating func replaceDecks(with newDecks: [SlideDeck]) -> [Int: Int] {
        let map = Self.slideRemap(from: decks, to: newDecks)
        let oldPageCount = decks.reduce(0) { $0 + $1.pages.count }
        decks = newDecks
        // Adding a deck after the others leaves every existing number where it was.
        let unchanged = map.count == oldPageCount && map.allSatisfy { $0.key == $0.value }
        if !unchanged { remapSlideReferences(map) }
        return map
    }

    /// Old → new combined page numbers when `old` decks become `new` ones, matching pages by
    /// (stored file, local page). Pages whose deck is gone are absent.
    static func slideRemap(from old: [SlideDeck], to new: [SlideDeck]) -> [Int: Int] {
        var newNumbers: [SlideLocation: Int] = [:]
        var n = 0
        for deck in new {
            for page in deck.pages {
                n += 1
                newNumbers[SlideLocation(fileName: deck.fileName, page: page.number)] = n
            }
        }
        var map: [Int: Int] = [:]
        var o = 0
        for deck in old {
            for page in deck.pages {
                o += 1
                if let target = newNumbers[SlideLocation(fileName: deck.fileName, page: page.number)] { map[o] = target }
            }
        }
        return map
    }

    /// Rewrites every stored slide reference through `map` (see `replaceDecks(with:)`).
    mutating func remapSlideReferences(_ map: [Int: Int]) {
        func pages(_ list: [Int]) -> [Int] {
            var seen = Set<Int>()
            return list.compactMap { map[$0] }.filter { seen.insert($0).inserted }
        }
        func citations(_ list: [Citation]) -> [Citation] {
            list.compactMap { c in
                if case .slide(let n) = c { return map[n].map(Citation.slide) }
                return c
            }
        }
        for i in takeaways.indices {
            takeaways[i].slidePages = pages(takeaways[i].slidePages).sorted()
            takeaways[i].summary = Self.remapSlideMarkers(in: takeaways[i].summary, map)
        }
        for i in quiz.indices {
            quiz[i].question.sourceSlides = pages(quiz[i].question.sourceSlides)
            if let grounding = quiz[i].question.grounding {
                quiz[i].question.grounding?.slides = pages(grounding.slides)
            }
            if let grade = quiz[i].grade {
                quiz[i].grade?.citations = citations(grade.citations)
                quiz[i].grade?.feedback = Self.remapSlideMarkers(in: grade.feedback, map)
            }
        }
        for i in chat.indices {
            chat[i].citations = citations(chat[i].citations)
            chat[i].text = Self.remapSlideMarkers(in: chat[i].text, map)
        }
        if let summary {
            self.summary?.slides = pages(summary.slides).sorted()
            self.summary?.overview = Self.remapSlideMarkers(in: summary.overview, map)
        }
        currentSlide = currentSlide.flatMap { map[$0] }
    }

    /// Rewrites slide tokens in citation markers ("[S12]", "[S3, T4:10]") through `map`; tokens for
    /// removed slides are dropped, and a marker left empty disappears.
    static func remapSlideMarkers(in text: String, _ map: [Int: Int]) -> String {
        guard text.contains("[") else { return text }
        return text.replacing(/\[([^\[\]]{1,80})\]/) { match in
            let tokens = match.1.split(whereSeparator: { $0 == "," || $0 == ";" }).map { $0.trimmingCharacters(in: .whitespaces) }
            var changed = false
            var kept: [String] = []
            for token in tokens {
                guard let first = token.first, case .slide(let n)? = CitationParser.citation(kind: first, value: String(token.dropFirst())) else {
                    kept.append(token)
                    continue
                }
                changed = true
                if let target = map[n] { kept.append("\(first)\(target)") }
            }
            guard changed else { return String(match.0) }
            return kept.isEmpty ? "" : "[" + kept.joined(separator: ", ") + "]"
        }
    }
}
