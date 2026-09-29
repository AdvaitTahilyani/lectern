import Foundation
import LecternCore

/// The lecture's "brain": turns finalized transcript segments into rolling takeaways, tracks the
/// current slide, schedules quiz pings, grades answers and answers questions grounded in slides +
/// transcript. Depends only on `LLMProvider` (per role) and an optional `SlideSearching`.
///
/// Background work is reported through `updates`: rolling takeaways and slide tracking are driven by
/// `ingest(_:)` (keyed off transcript time and word counts, so an import fed all at once is
/// processed chunk by chunk exactly like a live lecture), timed quiz pings by `tick(sessionTime:)`.
/// Background failures become `.error` updates and back off; they never throw. At most one model
/// call per role is in flight at a time.
///
/// Wiring: one brain per open session. Create it with the session snapshot, per-role providers and
/// the deck's `SlideSearching`; consume `updates` on the main actor; forward final transcript
/// segments, speaker labels and session-clock ticks; call `finish()` when recording stops. For an
/// import, ingest everything (don't tick), then `waitUntilIdle()` and `finish()`.
public actor LectureBrain: LectureIntelligence {
    public nonisolated let updates: AsyncStream<BrainUpdate>
    let continuation: AsyncStream<BrainUpdate>.Continuation

    let providers: RoleProviders
    let slideSearch: (any SlideSearching)?
    let excerpts: SlideExcerpts
    let lecture: Prompts.Lecture
    /// Rendered once: part of every role's byte-stable prompt prefix.
    let digest: String
    let tuning: BrainTuning

    var quizSettings: QuizSettings
    var summaryInterval: TimeInterval
    var rng: SplitMix64

    // Transcript and takeaways
    var segments: [TranscriptSegment]
    /// Segments before this index have been through a rolling update.
    var summarizedCount: Int
    /// First segment of the live topic's transcript window (moves in coarse jumps, see
    /// `windowStart(for:)`, so consecutive prompts share their prefix).
    var topicWindowStart: Int
    var timeline: TopicTimeline
    var sessionTime: TimeInterval
    var summaryTask: Task<Void, Never>?
    var summaryBackoff = Backoff()
    var isFinishing = false
    var detailCache: [UUID: CachedDetail] = [:]
    var pendingSpeakers: [UUID: SpeakerRole] = [:]

    // Slides
    var currentSlide: Int?
    var lastSlideCheck: TimeInterval = -.infinity
    var backtrackSuggestion: Int?
    /// When each slide became current (transcript time), so updates processed after the fact (an
    /// import, a backlog) see the slide that was on screen for *their* stretch of transcript.
    var slideHistory: [(time: TimeInterval, page: Int)] = []

    // Quizzes
    var planner: QuizPlanner
    var quizTask: Task<Void, Never>?
    var pendingQuiz: (question: QuizQuestion, askedAt: TimeInterval)?
    var lastQuizAt: TimeInterval
    var quizMaterialMark: TimeInterval
    var quizRetryAt: TimeInterval = -.infinity
    /// Material and the writer's explanation for each question generated this session, so grading
    /// and follow-ups reuse the exact same prompt prefix.
    var questionContexts: [UUID: QuestionContext] = [:]

    let gates: [LLMRole: SerialGate]
    var activities = ActivityTracker()

    /// - Parameters:
    ///   - context: session snapshot; pass the persisted transcript/takeaways/quiz history when
    ///     reopening a session.
    ///   - slides: retrieval over the deck, or nil when no deck is attached.
    ///   - summaryIntervalSeconds: seconds of new transcript between rolling updates (an update also
    ///     runs after ~350 new words).
    public init(context: BrainContext, providers: RoleProviders, slides: (any SlideSearching)?, quiz: QuizSettings, summaryIntervalSeconds: Double) {
        self.init(context: context, providers: providers, slides: slides, quiz: quiz,
                  summaryIntervalSeconds: summaryIntervalSeconds, tuning: BrainTuning(),
                  seed: UInt64.random(in: .min ... .max))
    }

    init(context: BrainContext, providers: RoleProviders, slides: (any SlideSearching)?, quiz: QuizSettings,
         summaryIntervalSeconds: Double, tuning: BrainTuning, seed: UInt64) {
        (updates, continuation) = AsyncStream.makeStream(of: BrainUpdate.self)
        self.providers = providers
        slideSearch = slides
        excerpts = SlideExcerpts(deck: context.deck, search: slides)
        lecture = Prompts.Lecture(title: context.sessionTitle, course: context.courseName)
        digest = DeckDigest.render(context.deck)
        self.tuning = tuning
        quizSettings = quiz
        summaryInterval = max(15, summaryIntervalSeconds)
        rng = SplitMix64(seed: seed)

        let transcript = context.transcript.filter(\.isFinal)
        segments = transcript
        timeline = TopicTimeline(takeaways: context.takeaways, minTopicSeconds: tuning.minTopicSeconds)
        let covered = timeline.takeaways.last?.end
        summarizedCount = covered.map { end in transcript.firstIndex { $0.start >= end - 0.01 } ?? transcript.count } ?? 0
        let summarized = summarizedCount
        topicWindowStart = timeline.live.flatMap { live in transcript.firstIndex { $0.end > live.start } } ?? summarized
        sessionTime = transcript.last?.end ?? 0

        planner = QuizPlanner(records: context.quizHistory)
        lastQuizAt = context.quizHistory.map(\.askedAt).max() ?? 0
        quizMaterialMark = context.quizHistory.compactMap(\.question.sourceEnd).max() ?? 0

        gates = Dictionary(uniqueKeysWithValues: LLMRole.allCases.map { ($0, SerialGate()) })
        for t in timeline.takeaways where !t.isLive {
            if let detail = t.detail { detailCache[t.id] = CachedDetail(fingerprint: .init(t), detail: detail) }
        }
    }

    deinit {
        continuation.finish()
    }

    // MARK: - LectureIntelligence

    public func ingest(_ segment: TranscriptSegment) {
        guard segment.isFinal, !Text.collapse(segment.text).isEmpty,
              !segments.suffix(8).contains(where: { $0.id == segment.id }) else { return }
        var segment = segment
        if let label = pendingSpeakers.removeValue(forKey: segment.id) { segment.speaker = label }
        segments.append(segment)
        sessionTime = max(sessionTime, segment.end)
        trackSlide()
        scheduleSummaryIfNeeded()
    }

    /// Quiz pings are scheduled only from the app's session clock, so an import (which never ticks)
    /// doesn't generate questions.
    public func tick(sessionTime time: TimeInterval) {
        sessionTime = max(sessionTime, time)
        scheduleSummaryIfNeeded()
        scheduleQuizIfDue()
    }

    public func applySpeakers(_ labels: [UUID: SpeakerRole]) {
        var remaining = labels
        // Labels arrive a few seconds late, so they're almost always for the newest segments.
        for i in segments.indices.reversed() where !remaining.isEmpty {
            if let label = remaining.removeValue(forKey: segments[i].id) { segments[i].speaker = label }
        }
        // Labels for segments not ingested yet (a race with `ingest`) are applied on arrival.
        pendingSpeakers.merge(remaining) { _, new in new }
    }

    public func waitUntilIdle() async {
        while let task = summaryTask {
            await task.value
        }
    }

    public func update(quiz: QuizSettings, summaryIntervalSeconds: Double) {
        quizSettings = quiz
        summaryInterval = max(15, summaryIntervalSeconds)
        scheduleSummaryIfNeeded()
        scheduleQuizIfDue()
    }

    // MARK: - Plumbing shared by the feature extensions

    func emit(_ update: BrainUpdate) {
        continuation.yield(update)
    }

    /// Runs `body` holding the role's gate, with `activity` reported while it runs.
    func withRole<T>(_ role: LLMRole, _ activity: BrainActivity, _ body: () async throws -> T) async rethrows -> T {
        let gate = gates[role]!
        await gate.acquire()
        let token = activities.begin(activity)
        emit(.activity(activity))
        func finish() async {
            activities.end(token)
            emit(.activity(activities.current))
            await gate.release()
        }
        do {
            let result = try await body()
            await finish()
            return result
        } catch {
            await finish()
            throw error
        }
    }

    /// Citations in `text` that point at real slides and at transcript that exists.
    func validCitations(in text: String) -> [Citation] {
        let pages = excerpts.validPages
        let latest = (segments.last?.end ?? 0) + 5
        return CitationParser.citations(in: text).filter { citation in
            switch citation {
            case .slide(let n): pages.contains(n)
            case .time(let t): t <= latest
            }
        }
    }

    // MARK: - Slide tracking

    public func setCurrentSlide(_ page: Int) {
        currentSlide = page
        slideHistory.append((sessionTime, page))
        suggestBacktrack(nil)
    }

    /// Throttled (by transcript time) slide check. Automatic tracking only ever moves forward; an
    /// apparent return to an earlier slide is only offered as a suggestion.
    private func trackSlide() {
        guard let slideSearch, let last = segments.last, last.end - lastSlideCheck >= tuning.slideCheckSeconds else { return }
        lastSlideCheck = last.end
        let recent = segments.reversed().prefix { $0.end >= last.end - tuning.slideWindowSeconds }
        let text = recent.reversed().map(\.text).joined(separator: " ")
        if let page = slideSearch.likelySlide(forTranscript: text, near: currentSlide), page > (currentSlide ?? 0) {
            currentSlide = page
            slideHistory.append((last.start, page))
            emit(.currentSlide(page))
            suggestBacktrack(nil)
        }
        if let current = currentSlide {
            suggestBacktrack(slideSearch.backtrackCandidate(forTranscript: text, current: current).flatMap { $0 < current ? $0 : nil })
        }
    }

    /// Slides on screen during `from...to`, in order (the one current at `from` first).
    func slidesShown(from: TimeInterval, to: TimeInterval) -> [Int] {
        var pages: [Int] = []
        if let atStart = slideHistory.last(where: { $0.time <= from })?.page { pages.append(atStart) }
        for entry in slideHistory where entry.time > from && entry.time < to && pages.last != entry.page {
            pages.append(entry.page)
        }
        return pages
    }

    private func suggestBacktrack(_ page: Int?) {
        guard page != backtrackSuggestion else { return }
        backtrackSuggestion = page
        emit(.backtrackSuggestion(page))
    }
}

/// What a generated question was written from.
struct QuestionContext: Sendable {
    var material: Prompts.QuizMaterial
    var explanation: String?
}

/// An expanded detail and the takeaway state it was written for.
struct CachedDetail: Sendable {
    struct Fingerprint: Sendable, Equatable {
        var title: String
        var summary: String
        var end: TimeInterval
        var updatedAt: Date

        init(_ t: Takeaway) {
            title = t.title
            summary = t.summary
            end = t.end
            updatedAt = t.updatedAt
        }
    }

    var fingerprint: Fingerprint
    var detail: TakeawayDetail
}
