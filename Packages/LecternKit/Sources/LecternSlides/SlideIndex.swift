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

        // Evidence over time is counted in *observations* (calls), not seconds: callers check
        // every ~15–20 s of transcript time (LectureBrain uses 15 s), so the result is the same
        // whether the lecture is live, played back faster, or imported all at once.
        /// A leap ahead is taken once its target won `leapObservations` of the last `leapWindow`
        /// observations. Windows overlap (60 s of speech every 15 s), so this means the evidence
        /// held for over a minute, while tolerating the noisy observations of real speech.
        static let leapObservations = 5
        static let leapWindow = 8
        /// Before any slide is known, the first `openingPages` pages are taken at once; a later
        /// page needs `firstObservations` of the last `firstWindow` observations.
        static let openingPages = 3
        static let firstObservations = 3
        static let firstWindow = 5
        /// ...and before a return to an earlier slide is suggested (≈ 45–60 s).
        static let backtrackObservations = 4

        /// Speech whose content words are mostly absent from the deck (a recap of last lecture,
        /// Q&A, chat) never moves the slide.
        static let minInDeckShare = 0.42
        static let minTokensForDeckShare = 8

        /// Consecutive pages whose term sets overlap at least this much (Jaccard) form one "build"
        /// group: the same slide revealed step by step. Speech cannot tell them apart, so the
        /// tracker treats the group as one unit and steps through it with time.
        static let buildSimilarity = 0.55
        /// Supporting observations on a build page before stepping to the next one (≈ 3 min).
        static let buildStepObservations = 12
    }

    private let pages: [Page]
    private let idf: [String: Double]
    private let averageLength: Double
    private let embedder: SemanticEmbedder?
    private let pageVectors: [[Double]?]
    /// Shared by copies of the index; see `BacktrackTracker`.
    private let backtrack = SustainedEvidence()
    private let leap = SustainedEvidence()
    private let buildDwell = BuildDwell()
    /// Per page index: first and last index of its build group (itself when it has none).
    private let groupStart: [Int]
    private let groupEnd: [Int]
    private let vocabulary: Set<String>

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
        (groupStart, groupEnd) = Self.buildGroups(pages.map { Set($0.termCounts.keys) })
        vocabulary = Set(pages.flatMap(\.termCounts.keys))

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
    /// (hysteresis); a leap needs stronger evidence over `Tuning.leapObservations` calls. A run of
    /// near-identical build slides is one unit: distances are measured from its last page, it is
    /// entered at its first page, and it is stepped through as the lecturer dwells on it. Speech
    /// that is mostly off-deck (a recap, chat) never moves the slide. Returns nil when the speech
    /// does not single out a slide; callers should then keep showing `near`.
    ///
    /// Stateful across calls (leap confirmation, build stepping): call it every ~15–20 s of
    /// transcript with the trailing ~60 s of speech.
    public func likelySlide(forTranscript text: String, near: Int?) -> Int? {
        guard !pages.isEmpty else { return nil }
        let tokens = SlideTokenizer.tokens(text)
        let terms = queryTerms(tokens).filter { idf[$0.key] != nil }
        let queryMass = terms.keys.reduce(0.0) { $0 + (idf[$1] ?? 0) }
        guard queryMass > 0, !isOffDeck(tokens) else {
            leap.miss()
            return nil
        }

        let combined = score(terms: terms, text: text).combined
        let nearIndex = near.flatMap { number in pages.firstIndex { $0.number == number } }
        // Distances count from the end of the current build group.
        let anchor = nearIndex.map { groupEnd[$0] }
        let adjusted = combined.enumerated().map { index, score in
            guard let nearIndex, let anchor else { return score }
            if index < nearIndex { return 0 }
            return score * Tuning.prior(distance: index <= anchor ? 0 : index - anchor)
        }
        let ranked = adjusted.indices.sorted { adjusted[$0] != adjusted[$1] ? adjusted[$0] > adjusted[$1] : $0 < $1 }
        guard var best = ranked.first, adjusted[best] > 0 else {
            leap.miss()
            return nil
        }
        if let nearIndex, groupStart[best] == groupStart[nearIndex] {
            best = nearIndex                                   // still on the current build group
        } else if nearIndex.map({ groupStart[best] > $0 }) ?? true {
            best = groupStart[best]                            // a build group is entered at its start
        }
        let isJump = anchor.map { Tuning.isJump(distance: best - $0) } ?? false
        // With nothing known yet, a page past the opening ones must hold up over a few
        // observations: lectures often open with chatter or a recap that happens to match a page.
        let isUnconfirmedFirst = nearIndex == nil && best >= Tuning.openingPages
        guard isConfident(pageIndex: best, terms: terms, queryMass: queryMass, isJump: isJump) else {
            leap.miss()
            return nil
        }

        if let nearIndex, best == nearIndex {
            leap.miss()
            return pages[stepThroughBuild(from: nearIndex)].number
        }
        if let nearIndex, adjusted[nearIndex] > 0, adjusted[best] < adjusted[nearIndex] * Tuning.switchMargin {
            // Hysteresis: stay put unless the newcomer clearly wins.
            leap.miss()
            return pages[stepThroughBuild(from: nearIndex)].number
        }
        let rivals = ranked.filter { candidate in
            groupStart[candidate] != groupStart[best] && (nearIndex.map { groupStart[candidate] != groupStart[$0] } ?? true)
        }
        if let rival = rivals.first, adjusted[best] < adjusted[rival] * (isJump ? Tuning.minSeparationForJump : Tuning.minSeparation) {
            leap.miss()
            return nil
        }
        if isUnconfirmedFirst {
            let confirmed = leap.observe(candidate: best, context: -1, required: Tuning.firstObservations, window: Tuning.firstWindow,
                                         sameTarget: { self.groupStart[$0] == self.groupStart[$1] || abs($0 - $1) <= 2 }, strict: false)
            return confirmed.map { pages[$0].number }
        }
        guard isJump, let nearIndex else {
            leap.reset()
            return pages[best].number
        }
        // Lecture vocabulary recurs across a deck: when the speech matches an earlier page (or the
        // current one) best, a far page that merely wins among the pages ahead is not evidence of
        // a leap. The target must be the best match in the whole deck.
        if let globalBest = combined.indices.max(by: { combined[$0] < combined[$1] }),
           groupStart[globalBest] != groupStart[best], combined[best] < combined[globalBest] {
            leap.miss()
            return nil
        }
        // A leap ahead is only taken once the same target has held up for a few observations.
        let confirmed = leap.observe(candidate: best, context: nearIndex, required: Tuning.leapObservations, window: Tuning.leapWindow,
                                     sameTarget: { self.groupStart[$0] == self.groupStart[$1] || abs($0 - $1) <= 2 }, strict: false)
        return confirmed.map { pages[$0].number }
    }

    /// Convenience for live use: scores the final `window` seconds of `segments`.
    public func likelySlide(forSegments segments: [TranscriptSegment], near: Int?, window: TimeInterval = 60) -> Int? {
        likelySlide(forTranscript: Self.recentText(of: segments, window: window), near: near)
    }

    /// An earlier slide the lecture seems to have returned to, or nil.
    ///
    /// Deliberately hard to satisfy, because the answer is only ever offered as a suggestion: one
    /// earlier page must, in the same call, cover the speech far better than the current page
    /// and than every later page; and that must hold for `Tuning.backtrackObservations`
    /// consecutive calls (about a minute), so a passing digression ("as we said about separation
    /// of concerns...") does not qualify. Call it as often as `likelySlide`, with the same text.
    /// The suggestion disappears (nil) as soon as the evidence stops holding or `current` changes.
    public func backtrackCandidate(forTranscript text: String, current: Int) -> Int? {
        let candidate = strongEarlierPage(forTranscript: text, current: current)
        guard let currentIndex = pages.firstIndex(where: { $0.number == current }) else { return nil }
        let index = backtrack.observe(candidate: candidate.flatMap { page in pages.firstIndex { $0.number == page } },
                                      context: currentIndex, required: Tuning.backtrackObservations,
                                      sameTarget: { self.groupStart[$0] == self.groupStart[$1] || abs($0 - $1) <= 2 }, strict: true)
        return index.map { pages[$0].number }
    }

    /// `backtrackCandidate(forTranscript:current:)` for transcript segments.
    public func backtrackCandidate(forSegments segments: [TranscriptSegment], current: Int, window: TimeInterval = 60) -> Int? {
        backtrackCandidate(forTranscript: Self.recentText(of: segments, window: window), current: current)
    }

    // MARK: Build groups and off-deck speech

    /// Groups runs of consecutive near-duplicate pages.
    static func buildGroups(_ termSets: [Set<String>]) -> (start: [Int], end: [Int]) {
        var start = Array(termSets.indices)
        for i in termSets.indices.dropFirst() {
            let a = termSets[i - 1], b = termSets[i]
            let union = a.union(b).count
            if union > 0, Double(a.intersection(b).count) / Double(union) >= Tuning.buildSimilarity { start[i] = start[i - 1] }
        }
        var end = Array(termSets.indices)
        for i in termSets.indices.reversed() where i + 1 < termSets.count && start[i + 1] == start[i] { end[i] = end[i + 1] }
        return (start, end)
    }

    /// First and last page number of each build group with more than one page.
    var buildGroups: [ClosedRange<Int>] {
        pages.indices.filter { groupStart[$0] == $0 && groupEnd[$0] > $0 }.map { pages[$0].number...pages[groupEnd[$0]].number }
    }

    private func isOffDeck(_ tokens: [String]) -> Bool {
        guard tokens.count >= Tuning.minTokensForDeckShare else { return false }
        let inDeck = tokens.filter(vocabulary.contains).count
        return Double(inDeck) / Double(tokens.count) < Tuning.minInDeckShare
    }

    /// While the speech keeps supporting the current build group, advances one page per
    /// `Tuning.buildStepObservations` observations (builds are revealed as the lecturer talks).
    private func stepThroughBuild(from index: Int) -> Int {
        guard groupEnd[index] > index else { return index }
        return buildDwell.observe(index) ? index + 1 : index
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

/// How long (in observations) the tracker has dwelt on one build page. Reference type for the same
/// reason as `SustainedEvidence`.
private final class BuildDwell: Sendable {
    private let state = Mutex((page: -1, observations: 0))

    /// Records one supporting observation on `page`; true when it is time to step to the next page.
    func observe(_ page: Int) -> Bool {
        state.withLock { dwell in
            if dwell.page != page { dwell = (page, 0) }
            dwell.observations += 1
            guard dwell.observations >= SlideIndex.Tuning.buildStepObservations else { return false }
            dwell = (page + 1, 0)
            return true
        }
    }
}

/// Remembers which candidate page (an index) recent observations supported.
///
/// `SlideIndex` is a value type shared freely between actors, so the running evidence lives in
/// this small reference type. The mutex guards all access; the state is tiny.
private final class SustainedEvidence: Sendable {
    private struct State {
        var context: Int?
        /// Most recent last; nil = an observation without a candidate.
        var recent: [Int?] = []
    }

    private let state = Mutex(State())

    /// Feeds one observation. A `strict` tracker returns the candidate once the last `required`
    /// observations (under the same `context`, the current slide) all supported it; a lenient one
    /// once `required` of the last `window` did. `sameTarget` decides whether two candidates are
    /// the same target (e.g. pages of one build group).
    func observe(candidate: Int?, context: Int, required: Int, window: Int? = nil,
                 sameTarget: (Int, Int) -> Bool, strict: Bool) -> Int? {
        state.withLock { state in
            if state.context != context { state = State(context: context) }
            let span = strict ? required : max(required, window ?? required)
            state.recent.append(candidate)
            if state.recent.count > span { state.recent.removeFirst(state.recent.count - span) }
            guard let candidate else { return nil }
            let support = state.recent.suffix(span).filter { $0.map { sameTarget($0, candidate) } ?? false }.count
            if strict {
                return state.recent.count >= required && support >= required ? candidate : nil
            }
            return support >= required ? candidate : nil
        }
    }

    /// An observation without a candidate.
    func miss() {
        state.withLock { state in
            state.recent.append(nil)
            if state.recent.count > SlideIndex.Tuning.leapWindow { state.recent.removeFirst() }
        }
    }

    func reset() {
        state.withLock { $0.recent.removeAll() }
    }
}
