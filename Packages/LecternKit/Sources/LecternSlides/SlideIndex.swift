import Foundation
import LecternCore
import Synchronization

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
        /// A leap of more than a few slides ahead needs proportionally more evidence, and must hold
        /// for `sustain` seconds: tracking cannot go back on its own, so a wrong leap would stick.
        static let minMatchedTermsForJump = 5
        static let minMatchedWeightForJump = 4.0
        static let minCoverageForJump = 0.2
        static let minSeparationForJump = 1.3
        static func isJump(distance: Int) -> Bool { distance > 3 }
        /// Best adjusted score must exceed the runner-up by this factor.
        static let minSeparation = 1.1
        /// To leave `near`, a candidate must beat it by this factor (hysteresis).
        static let switchMargin = 1.25
        /// Multipliers by distance ahead of the previous slide: lectures move forward a page or
        /// two at a time, so far leaps need proportionally stronger evidence.
        static func prior(distance: Int) -> Double {
            switch distance {
            case 0, 1: 1.10
            case 2: 1.00
            case 3: 0.95
            default: 0.85   // leaps are additionally held back by the `sustain` requirement
            }
        }

        // Suggesting a return to an earlier slide (`backtrackCandidate`).
        /// The earlier page must beat the current page by this factor...
        static let backtrackMarginOverCurrent = 2.5
        /// ...and every other page by this factor.
        static let backtrackMarginOverOthers = 1.5
        static let backtrackMinMatchedTerms = 6
        static let backtrackMinMatchedWeight = 5.0
        static let backtrackMinCoverage = 0.3

        /// Evidence for a leap ahead or a step back must hold continuously for this long
        /// (seconds), i.e. across two independent ~60 s transcript windows.
        static let sustain: TimeInterval = 60
        /// Observations further apart than this do not count as continuous.
        static let maxGap: TimeInterval = 45
    }

    private let pages: [Page]
    private let idf: [String: Double]
    private let averageLength: Double
    private let embedder: SemanticEmbedder?
    private let pageVectors: [[Double]?]
    /// Shared by copies of the index; see `BacktrackTracker`.
    private let backtrack = SustainedEvidence()
    private let leap = SustainedEvidence()

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
    /// Only `near` or later pages are ever returned: slide tracking never moves backwards on its
    /// own (see `backtrackCandidate` for suggesting a return). Pages are scored like a search,
    /// then reweighted by a prior around `near` (staying or advancing a page or two is likely, a
    /// leap ahead is not). The result changes only when the new page clearly beats `near`
    /// (hysteresis), and leaps need extra evidence. Returns nil when the speech does not single
    /// out a slide; callers should then keep showing `near`.
    public func likelySlide(forTranscript text: String, near: Int?) -> Int? {
        likelySlide(forTranscript: text, near: near, at: ProcessInfo.processInfo.systemUptime)
    }

    /// `at` is a monotonic time in seconds; tests supply their own clock.
    func likelySlide(forTranscript text: String, near: Int?, at time: TimeInterval) -> Int? {
        guard !pages.isEmpty else { return nil }
        let terms = queryTerms(SlideTokenizer.tokens(text)).filter { idf[$0.key] != nil }
        let queryMass = terms.keys.reduce(0.0) { $0 + (idf[$1] ?? 0) }
        guard queryMass > 0 else { return nil }

        let combined = score(terms: terms, text: text).combined
        let nearIndex = near.flatMap { number in pages.firstIndex { $0.number == number } }
        let adjusted = combined.enumerated().map { index, score in
            guard let nearIndex else { return score }
            return index < nearIndex ? 0 : score * Tuning.prior(distance: index - nearIndex)
        }
        let ranked = adjusted.indices.sorted { adjusted[$0] != adjusted[$1] ? adjusted[$0] > adjusted[$1] : $0 < $1 }
        guard let best = ranked.first, adjusted[best] > 0 else { return nil }
        let isJump = nearIndex.map { Tuning.isJump(distance: best - $0) } ?? false
        guard isConfident(pageIndex: best, terms: terms, queryMass: queryMass, isJump: isJump) else { return nil }

        guard best != nearIndex else {
            leap.reset()
            return pages[best].number
        }
        if let nearIndex, adjusted[nearIndex] > 0, adjusted[best] < adjusted[nearIndex] * Tuning.switchMargin {
            // Hysteresis: stay put unless the newcomer clearly wins.
            leap.reset()
            return pages[nearIndex].number
        }
        if let rival = ranked.first(where: { $0 != best && $0 != nearIndex }),
           adjusted[best] < adjusted[rival] * (isJump ? Tuning.minSeparationForJump : Tuning.minSeparation) {
            return nil
        }
        guard isJump, let nearIndex else {
            leap.reset()
            return pages[best].number
        }
        // A leap ahead is only taken once the same target has held up for a while.
        return leap.observe(candidate: pages[best].number, context: pages[nearIndex].number, at: time, strict: false) == nil
            ? nil : pages[best].number
    }

    /// Convenience for live use: scores the final `window` seconds of `segments`.
    public func likelySlide(forSegments segments: [TranscriptSegment], near: Int?, window: TimeInterval = 60) -> Int? {
        likelySlide(forTranscript: Self.recentText(of: segments, window: window), near: near)
    }

    /// An earlier slide the lecture seems to have returned to, or nil.
    ///
    /// Deliberately hard to satisfy, because the answer is only ever offered as a suggestion: one
    /// earlier page must, in the same call, cover the speech far better than the current page
    /// and than every later page; and that must hold continuously for a minute or more (across
    /// two independent windows), so a passing digression ("as we said about separation of
    /// concerns...") does not qualify. Call it as often as `likelySlide`, with the same text.
    /// The suggestion disappears (nil) as soon as the evidence stops holding or `current` changes.
    public func backtrackCandidate(forTranscript text: String, current: Int) -> Int? {
        backtrackCandidate(forTranscript: text, current: current, at: ProcessInfo.processInfo.systemUptime)
    }

    /// `backtrackCandidate(forTranscript:current:)` for transcript segments.
    public func backtrackCandidate(forSegments segments: [TranscriptSegment], current: Int, window: TimeInterval = 60) -> Int? {
        backtrackCandidate(forTranscript: Self.recentText(of: segments, window: window), current: current)
    }

    /// `at` is a monotonic time in seconds; tests supply their own clock.
    func backtrackCandidate(forTranscript text: String, current: Int, at time: TimeInterval) -> Int? {
        let candidate = strongEarlierPage(forTranscript: text, current: current)
        return backtrack.observe(candidate: candidate, context: current, at: time, strict: true)
    }

    private func strongEarlierPage(forTranscript text: String, current: Int) -> Int? {
        guard let currentIndex = pages.firstIndex(where: { $0.number == current }), currentIndex > 0 else { return nil }
        let terms = queryTerms(SlideTokenizer.tokens(text)).filter { idf[$0.key] != nil }
        let queryMass = terms.keys.reduce(0.0) { $0 + (idf[$1] ?? 0) }
        guard queryMass > 0 else { return nil }

        let combined = score(terms: terms, text: text).combined
        guard let best = combined.indices.max(by: { combined[$0] < combined[$1] }), best < currentIndex else { return nil }
        let page = pages[best]
        let matched = terms.keys.filter { page.termCounts[$0] != nil }
        let mass = matched.reduce(0.0) { $0 + (idf[$1] ?? 0) }
        guard matched.count >= Tuning.backtrackMinMatchedTerms,
              mass >= Tuning.backtrackMinMatchedWeight,
              mass / queryMass >= Tuning.backtrackMinCoverage,
              combined[best] >= combined[currentIndex] * Tuning.backtrackMarginOverCurrent
        else { return nil }
        // Any other page that matches nearly as well makes the topic, not the slide, the evidence.
        for other in combined.indices where other != best && combined[best] < combined[other] * Tuning.backtrackMarginOverOthers {
            // Duplicate build slides right next to the best page do not count as rivals.
            if abs(other - best) > 1 || pages[other].text != page.text { return nil }
        }
        return page.number
    }

    private static func recentText(of segments: [TranscriptSegment], window: TimeInterval) -> String {
        guard let last = segments.map(\.end).max() else { return "" }
        return segments.filter { $0.end >= last - window }.sorted { $0.start < $1.start }.map(\.text).joined(separator: " ")
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

/// Remembers how long one candidate page has been supported by the evidence.
///
/// `SlideIndex` is a value type shared freely between actors, so the running evidence lives in
/// this small reference type. The mutex guards all access; the state is tiny.
private final class SustainedEvidence: Sendable {
    private struct State {
        var context: Int?
        var candidate: Int?
        var since: TimeInterval = 0
        var lastSeen: TimeInterval = 0
    }

    private let state = Mutex(State())

    /// Feeds one observation; returns the candidate once it has held under the same `context` (the
    /// current slide) for `Tuning.sustain` seconds. Candidates within two pages of the first one
    /// count as the same (a run of near-identical build slides). A `strict` tracker forgets the
    /// candidate as soon as one observation lacks support; a lenient one only when no supporting
    /// observation arrives for `Tuning.maxGap` seconds.
    func observe(candidate: Int?, context: Int, at time: TimeInterval, strict: Bool) -> Int? {
        state.withLock { state in
            defer { state.context = context }
            guard let candidate else {
                if strict { state.candidate = nil }
                return nil
            }
            let continuing = state.context == context
                && state.candidate.map { abs($0 - candidate) <= 2 } == true
                && time - state.lastSeen <= SlideIndex.Tuning.maxGap
            if !continuing { state.candidate = candidate; state.since = time }
            state.lastSeen = time
            return time - state.since >= SlideIndex.Tuning.sustain ? candidate : nil
        }
    }

    func reset() {
        state.withLock { $0.candidate = nil }
    }
}
