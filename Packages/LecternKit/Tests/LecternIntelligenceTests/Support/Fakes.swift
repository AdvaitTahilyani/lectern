import Foundation
import LecternCore
import Synchronization
@testable import LecternIntelligence

/// An `LLMProvider` that replays scripted replies (or computes them from the request) and records
/// every request it receives.
final class ScriptedProvider: LLMProvider {
    enum Reply: Sendable {
        case text(String)
        case failure(LLMError)
    }

    let kind = ProviderKind.localServer
    let model = "scripted"

    private struct State {
        var queue: [Reply] = []
        var requests: [LLMRequest] = []
        var inFlight = 0
        var maxInFlight = 0
    }

    private let state = Mutex(State())
    private let responder: (@Sendable (LLMRequest) -> Reply?)?
    private let delay: Duration

    /// - Parameters:
    ///   - replies: returned in order; when exhausted, `responder` is asked, else a failure.
    ///   - delay: simulated generation time (lets tests overlap calls).
    init(_ replies: [Reply] = [], delay: Duration = .zero, responder: (@Sendable (LLMRequest) -> Reply?)? = nil) {
        state.withLock { $0.queue = replies }
        self.delay = delay
        self.responder = responder
    }

    convenience init(texts: [String], delay: Duration = .zero) {
        self.init(texts.map(Reply.text), delay: delay)
    }

    var requests: [LLMRequest] { state.withLock { $0.requests } }
    var maxInFlight: Int { state.withLock { $0.maxInFlight } }

    func enqueue(_ replies: Reply...) {
        state.withLock { $0.queue.append(contentsOf: replies) }
    }

    func complete(_ request: LLMRequest) async throws -> LLMResponse {
        let reply = state.withLock { s -> Reply in
            s.requests.append(request)
            s.inFlight += 1
            s.maxInFlight = max(s.maxInFlight, s.inFlight)
            if !s.queue.isEmpty { return s.queue.removeFirst() }
            return responder?(request) ?? .failure(.invalidResponse("script exhausted"))
        }
        defer { state.withLock { $0.inFlight -= 1 } }
        if delay > .zero { try await Task.sleep(for: delay) }
        switch reply {
        case .text(let text): return LLMResponse(text: text)
        case .failure(let error): throw error
        }
    }

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let text = try await self.complete(request).text
                    var rest = Substring(text)
                    while !rest.isEmpty {
                        let piece = rest.prefix(7)
                        continuation.yield(.delta(String(piece)))
                        rest = rest.dropFirst(piece.count)
                    }
                    continuation.yield(.done(nil))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func healthCheck() async throws {}
}

/// `SlideSearching` over a fixed deck: keyword overlap for `search`, and a scripted or keyword
/// guess for `likelySlide`.
struct FakeSlides: SlideSearching {
    var deck: SlideDeck
    var likely: (@Sendable (String, Int?) -> Int?)?
    var backtrack: (@Sendable (String, Int) -> Int?)?

    init(deck: SlideDeck, likely: (@Sendable (String, Int?) -> Int?)? = nil, backtrack: (@Sendable (String, Int) -> Int?)? = nil) {
        self.deck = deck
        self.likely = likely
        self.backtrack = backtrack
    }

    func search(_ query: String, limit: Int) -> [SlideHit] {
        let q = Set(TranscriptRetriever.terms(query))
        return deck.pages.compactMap { page -> SlideHit? in
            let overlap = Set(TranscriptRetriever.terms((page.title ?? "") + " " + page.text)).intersection(q).count
            return overlap > 0 ? SlideHit(page: page.number, score: Double(overlap), excerpt: String(page.text.prefix(120))) : nil
        }
        .sorted { $0.score > $1.score }
        .prefix(limit)
        .map { $0 }
    }

    func likelySlide(forTranscript text: String, near: Int?) -> Int? {
        if let likely { return likely(text, near) }
        return search(text, limit: 1).first?.page
    }

    func backtrackCandidate(forTranscript text: String, current: Int) -> Int? {
        backtrack?(text, current)
    }
}

/// Collects a brain's updates so tests can wait for a condition.
actor UpdateLog {
    private(set) var updates: [BrainUpdate] = []
    private var consumer: Task<Void, Never>?

    init(_ stream: AsyncStream<BrainUpdate>) {
        Task { await self.start(stream) }
    }

    private func start(_ stream: AsyncStream<BrainUpdate>) {
        consumer = Task { for await u in stream { self.append(u) } }
    }

    private func append(_ u: BrainUpdate) { updates.append(u) }

    var takeawayLists: [[Takeaway]] {
        updates.compactMap { if case .takeaways(let t) = $0 { t } else { nil } }
    }

    var latestTakeaways: [Takeaway] { takeawayLists.last ?? [] }

    var errors: [String] {
        updates.compactMap { if case .error(let e) = $0 { e } else { nil } }
    }

    var quizzes: [QuizQuestion] {
        updates.compactMap { if case .quizReady(let q) = $0 { q } else { nil } }
    }

    var slides: [Int?] {
        updates.compactMap { if case .currentSlide(let s) = $0 { s } else { nil } }
    }

    var backtracks: [Int?] {
        updates.compactMap { if case .backtrackSuggestion(let s) = $0 { s } else { nil } }
    }

    /// Polls until `condition` holds (or fails the wait after `timeout`).
    @discardableResult
    func wait(timeout: Duration = .seconds(3), until condition: ([BrainUpdate]) -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition(updates) { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition(updates)
    }
}

// MARK: - Builders

enum Fixtures {
    static let deck = SlideDeck(
        fileName: "slides.pdf", originalFileName: "parsing.pdf", title: "Top-down parsing",
        pages: [
            SlidePage(number: 1, title: "Top-down parsing", text: "Top-down parsing CS 421"),
            SlidePage(number: 2, title: "LL(1) parsing", text: "LL(1) parsing: left-to-right scan, leftmost derivation, 1 token lookahead. Predictive parse table M[A, a]."),
            SlidePage(number: 3, title: "FIRST sets", text: "FIRST(α) = terminals that begin strings derived from α. If α ⇒* ε then ε ∈ FIRST(α)."),
            SlidePage(number: 4, title: "FOLLOW sets", text: "FOLLOW(A) = terminals that can appear immediately after A. $ ∈ FOLLOW(S)."),
            SlidePage(number: 5, title: "Left recursion", text: "A → A α | β becomes A → β A', A' → α A' | ε."),
        ]
    )

    /// Segments of ~`seconds` each, starting at `start`, with the given texts.
    static func segments(_ texts: [String], start: TimeInterval = 0, seconds: TimeInterval = 10) -> [TranscriptSegment] {
        texts.enumerated().map { i, text in
            TranscriptSegment(text: text, start: start + Double(i) * seconds, end: start + Double(i + 1) * seconds, isFinal: true)
        }
    }

    static func context(deck: SlideDeck? = Fixtures.deck, transcript: [TranscriptSegment] = [], takeaways: [Takeaway] = [], quiz: [QuizRecord] = []) -> BrainContext {
        BrainContext(sessionTitle: "Top-down parsing", courseName: "CS 421", deck: deck, transcript: transcript, takeaways: takeaways, quizHistory: quiz)
    }

    static func brain(
        _ provider: ScriptedProvider,
        context: BrainContext = Fixtures.context(),
        slides: (any SlideSearching)? = FakeSlides(deck: Fixtures.deck),
        quiz: QuizSettings = QuizSettings(enabled: false),
        interval: Double = 120,
        tuning: BrainTuning = BrainTuning(),
        seed: UInt64 = 42
    ) -> LectureBrain {
        LectureBrain(context: context, providers: RoleProviders(summaries: provider, quizzes: provider, ask: provider),
                     slides: slides, quiz: quiz, summaryIntervalSeconds: interval, tuning: tuning, seed: seed)
    }

    static func segmentation(_ action: String, quote: String = "", closed: String = "", title: String, summary: String, slides: [Int] = []) -> String {
        let payload: [String: Any] = ["action": action, "boundary_quote": quote, "closed_summary": closed, "title": title, "summary": summary, "slides": slides]
        let data = try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}

extension LLMRequest {
    var system: String { messages.first { $0.role == .system }?.content ?? "" }
    var lastUser: String { messages.last { $0.role == .user }?.content ?? "" }
}
