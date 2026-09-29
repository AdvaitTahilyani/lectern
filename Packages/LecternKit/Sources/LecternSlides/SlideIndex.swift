import Foundation
import LecternCore

/// Hybrid retrieval over one deck: BM25 on page text and title, blended with on-device sentence
/// embeddings when the model is available.
///
/// Build once per session (`SlideIndex.build(deck:)` does the embedding work off the caller's
/// actor); queries are cheap and thread-safe.
public struct SlideIndex: SlideSearching {
    private struct Page: Sendable {
        let number: Int
        let text: String
        let termCounts: [String: Int]
        let length: Int
    }

    /// Ranking and confidence knobs, tuned against scripted lectures (`LikelySlideTests`) and a
    /// real 85-minute lecture replayed with auto-captions (`RealLectureTests`).
    enum Tuning {
        static let k1 = 1.2
        static let b = 0.5
        /// A term in a unique title counts as if it appeared this many extra times. Titles shared
        /// by several pages ("Code Generation for Expression Trees" x7) tell pages apart not at all.
        static let titleBoost = 2
        static let lexicalWeight = 0.88
        static let semanticWeight = 0.12
        /// The English sentence model is weak on technical vocabulary: cosines below `semanticFloor`
        /// are noise and `semanticCeiling` counts as a full match.
        static let semanticFloor = 0.30
        static let semanticCeiling = 0.70
        /// A page with no term in common with the query is returned only when its semantic
        /// contribution to the blended score reaches this level.
        static let semanticOnlyMinimum = 0.06
        /// Share of the query's (in-deck) term weight a page must match to be a confident pick.
        static let minCoverage = 0.12
        /// Distinct query terms a page must match, and their summed IDF, to move the current slide
        /// (a single shared word such as "register" is not evidence of anything).
        static let minMatchedTerms = 3
        static let minMatchedWeight = 2.5
        /// A jump backwards or more than a few slides ahead needs proportionally more evidence:
        /// speakers digress ("as we saw in the IR lecture...") far more often than they skip.
        static let minMatchedTermsForJump = 5
        static let minMatchedWeightForJump = 4.0
        static let minCoverageForJump = 0.2
        static let minSeparationForJump = 1.3
        static func isJump(distance: Int) -> Bool { distance < -1 || distance > 3 }
        /// Best adjusted score must exceed the runner-up by this factor.
        static let minSeparation = 1.1
        /// To leave `near`, a candidate must beat it by this factor (hysteresis).
        static let switchMargin = 1.25
        /// Multipliers by distance from the previous slide: lectures mostly move forward, a page or
        /// two at a time, so far jumps and going back need proportionally stronger evidence.
        static func prior(distance: Int) -> Double {
            switch distance {
            case 0, 1: 1.10
            case 2: 1.00
            case 3: 0.95
            case 4...: max(0.45, 0.80 - 0.05 * Double(distance - 4))
            case -1: 0.75
            case -2: 0.60
            default: 0.40
            }
        }
    }

    private let pages: [Page]
    private let idf: [String: Double]
    private let averageLength: Double
    private let embedder: SemanticEmbedder?
    private let pageVectors: [[Double]?]

    /// Number of indexed pages.
    public var pageCount: Int { pages.count }
    /// Whether semantic similarity is active (false when the on-device model is unavailable or disabled).
    public var usesSemanticSimilarity: Bool { embedder != nil }

    /// - Parameter useSemanticSimilarity: pass `false` to force pure BM25 (e.g. in tests).
    public init(deck: SlideDeck, useSemanticSimilarity: Bool = true) {
        var titleCounts: [String: Int] = [:]
        for page in deck.pages { titleCounts[SlideTextCleaner.furnitureKey(page.title ?? ""), default: 0] += 1 }
        let pages = deck.pages.map { page -> Page in
            var counts: [String: Int] = [:]
            for token in SlideTokenizer.tokens(page.text) { counts[token, default: 0] += 1 }
            let titleKey = SlideTextCleaner.furnitureKey(page.title ?? "")
            if titleCounts[titleKey] == 1 {
                for token in SlideTokenizer.tokens(page.title ?? "") { counts[token, default: 0] += Tuning.titleBoost }
            }
            return Page(number: page.number, text: page.text, termCounts: counts, length: counts.values.reduce(0, +))
        }
        self.pages = pages

        var documentFrequency: [String: Int] = [:]
        for page in pages { for term in page.termCounts.keys { documentFrequency[term, default: 0] += 1 } }
        let total = Double(pages.count)
        idf = documentFrequency.mapValues { log(1 + (total - Double($0) + 0.5) / (Double($0) + 0.5)) }
        averageLength = pages.isEmpty ? 0 : Double(pages.reduce(0) { $0 + $1.length }) / total

        let embedder = useSemanticSimilarity ? SemanticEmbedder() : nil
        self.embedder = embedder
        pageVectors = deck.pages.map { page in
            embedder?.vector(for: [page.title, page.text].compactMap { $0 }.joined(separator: ". "))
        }
    }

    /// Builds the index on a background executor (embedding a long deck takes a moment).
    public static func build(deck: SlideDeck, useSemanticSimilarity: Bool = true) async -> SlideIndex {
        await Task.detached(priority: .userInitiated) {
            SlideIndex(deck: deck, useSemanticSimilarity: useSemanticSimilarity)
        }.value
    }

    // MARK: SlideSearching

    /// Hybrid BM25 + semantic search. Each hit carries the best-matching passage of the page.
    public func search(_ query: String, limit: Int) -> [SlideHit] {
        guard limit > 0, !pages.isEmpty else { return [] }
        let terms = queryTerms(SlideTokenizer.tokens(query))
        let scores = score(terms: terms, text: query)
        let weights = Dictionary(uniqueKeysWithValues: terms.keys.compactMap { term in idf[term].map { (term, $0) } })
        return pages.indices
            .filter { scores.lexical[$0] > 0 || Tuning.semanticWeight * scores.semantic[$0] >= Tuning.semanticOnlyMinimum }
            .sorted { scores.combined[$0] != scores.combined[$1] ? scores.combined[$0] > scores.combined[$1] : $0 < $1 }
            .prefix(limit)
            .map { SlideHit(page: pages[$0].number, score: scores.combined[$0], excerpt: SlideExcerpt.best(in: pages[$0].text, queryWeights: weights)) }
    }

    /// Which slide the speaker is on, given roughly the last minute of speech.
    ///
    /// Pages are scored like a search, then reweighted by a prior around `near` (the current
    /// slide: staying or advancing a page or two is likely, going back or leaping ahead is not).
    /// The result changes only when the new page clearly beats `near` (hysteresis), and jumps need
    /// extra evidence because speakers digress more often than they skip. Returns nil when the
    /// speech does not single out a slide; callers should then keep showing `near`.
    public func likelySlide(forTranscript text: String, near: Int?) -> Int? {
        guard !pages.isEmpty else { return nil }
        let terms = queryTerms(SlideTokenizer.tokens(text)).filter { idf[$0.key] != nil }
        let queryMass = terms.keys.reduce(0.0) { $0 + (idf[$1] ?? 0) }
        guard queryMass > 0 else { return nil }

        let combined = score(terms: terms, text: text).combined
        let nearIndex = near.flatMap { number in pages.firstIndex { $0.number == number } }
        let adjusted = combined.enumerated().map { index, score in
            guard let nearIndex else { return score }
            return score * Tuning.prior(distance: index - nearIndex)
        }
        let ranked = adjusted.indices.sorted { adjusted[$0] != adjusted[$1] ? adjusted[$0] > adjusted[$1] : $0 < $1 }
        guard let best = ranked.first, adjusted[best] > 0 else { return nil }
        let isJump = nearIndex.map { Tuning.isJump(distance: best - $0) } ?? false
        guard isConfident(pageIndex: best, terms: terms, queryMass: queryMass, isJump: isJump) else { return nil }

        guard best != nearIndex else { return pages[best].number }
        if let nearIndex, adjusted[nearIndex] > 0, adjusted[best] < adjusted[nearIndex] * Tuning.switchMargin {
            // Hysteresis: stay put unless the newcomer clearly wins.
            return pages[nearIndex].number
        }
        if let rival = ranked.first(where: { $0 != best && $0 != nearIndex }),
           adjusted[best] < adjusted[rival] * (isJump ? Tuning.minSeparationForJump : Tuning.minSeparation) {
            return nil
        }
        return pages[best].number
    }

    /// Convenience for live use: scores the final `window` seconds of `segments`.
    public func likelySlide(forSegments segments: [TranscriptSegment], near: Int?, window: TimeInterval = 60) -> Int? {
        guard let last = segments.map(\.end).max() else { return nil }
        let recent = segments.filter { $0.end >= last - window }.sorted { $0.start < $1.start }
        return likelySlide(forTranscript: recent.map(\.text).joined(separator: " "), near: near)
    }

    // MARK: Scoring

    /// Unique query terms with a sub-linear weight for repeated terms.
    private func queryTerms(_ tokens: [String]) -> [String: Double] {
        var counts: [String: Int] = [:]
        for token in tokens { counts[token, default: 0] += 1 }
        return counts.mapValues { 1 + log(Double($0)) }
    }

    private func bm25(terms: [String: Double]) -> [Double] {
        pages.map { page in
            guard page.length > 0, averageLength > 0 else { return 0 }
            let norm = Tuning.k1 * (1 - Tuning.b + Tuning.b * Double(page.length) / averageLength)
            return terms.reduce(0.0) { sum, entry in
                guard let tf = page.termCounts[entry.key].map(Double.init), let idf = idf[entry.key] else { return sum }
                return sum + entry.value * idf * (tf * (Tuning.k1 + 1)) / (tf + norm)
            }
        }
    }

    /// Cosine similarity per page mapped from `semanticFloor...semanticCeiling` to 0...1.
    private func semanticScores(for text: String) -> [Double] {
        guard let embedder, let query = embedder.vector(for: text) else { return Array(repeating: 0, count: pages.count) }
        return pageVectors.map { vector in
            guard let vector else { return 0 }
            let cosine = SemanticEmbedder.similarity(query, vector)
            return min(1, max(0, (cosine - Tuning.semanticFloor) / (Tuning.semanticCeiling - Tuning.semanticFloor)))
        }
    }

    private struct Scores {
        /// Raw BM25 per page.
        var lexical: [Double]
        /// 0...1 semantic similarity per page.
        var semantic: [Double]
        /// Blend of max-normalized BM25 and semantic similarity.
        var combined: [Double]
    }

    private func score(terms: [String: Double], text: String) -> Scores {
        let lexical = bm25(terms: terms)
        let semantic = semanticScores(for: text)
        let maxLexical = lexical.max() ?? 0
        let combined = pages.indices.map { index in
            let lex = maxLexical > 0 ? lexical[index] / maxLexical : 0
            return Tuning.lexicalWeight * lex + Tuning.semanticWeight * semantic[index]
        }
        return Scores(lexical: lexical, semantic: semantic, combined: combined)
    }

    /// A page is a confident match when it shares enough distinct, informative terms with what
    /// was said, and those terms cover a meaningful part of what the deck could have matched.
    private func isConfident(pageIndex: Int, terms: [String: Double], queryMass: Double, isJump: Bool) -> Bool {
        let page = pages[pageIndex]
        let matched = terms.keys.filter { page.termCounts[$0] != nil }
        let mass = matched.reduce(0.0) { $0 + (idf[$1] ?? 0) }
        return matched.count >= (isJump ? Tuning.minMatchedTermsForJump : Tuning.minMatchedTerms)
            && mass >= (isJump ? Tuning.minMatchedWeightForJump : Tuning.minMatchedWeight)
            && mass / queryMass >= (isJump ? Tuning.minCoverageForJump : Tuning.minCoverage)
    }
}
