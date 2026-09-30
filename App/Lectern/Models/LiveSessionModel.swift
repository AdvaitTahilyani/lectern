import AppKit
import Foundation
import LecternCore
import SwiftUI

/// Owns one `LectureSession` (live or review): consumes transcription events and brain updates,
/// drives the clock, the quiz ping state machine, the Ask thread and autosave.
@Observable
@MainActor
final class LiveSessionModel {
    enum Mode: Hashable { case live, review }
    enum RecordingState: Hashable { case recording, paused, finishing, finished }
    enum SummaryState: Hashable { case none, writing, ready, failed(String) }

    // MARK: Quiz

    struct ActiveQuiz: Hashable {
        enum Phase: Hashable {
            case asking
            case grading
            case correct(QuizGrade)
            /// Explanation plus an optional follow-up question on the same concept.
            case wrong(QuizGrade, followUp: QuizQuestion?, followUpPending: Bool)
            /// The follow-up is being graded.
            case gradingFollowUp(QuizGrade, followUp: QuizQuestion)
            case followUpResult(QuizGrade, followUp: QuizQuestion, result: QuizGrade)
        }
        var question: QuizQuestion
        var phase: Phase = .asking
        var deadline: Date
        var selectedOption: Int?
        var isHovered = false
        var shortAnswer = ""

        var activeQuestion: QuizQuestion {
            switch phase {
            case .wrong(_, let f?, _): f
            case .gradingFollowUp(_, let f), .followUpResult(_, let f, _): f
            default: question
            }
        }
        var acceptsAnswers: Bool {
            switch phase {
            case .asking: true
            case .wrong(_, let f, _): f != nil
            default: false
            }
        }
        var isResult: Bool {
            switch phase {
            case .correct, .followUpResult: true
            case .wrong(_, let f, let pending): f == nil && !pending
            default: false
            }
        }
    }

    // MARK: Review missed concepts

    struct MissedConcept: Identifiable, Hashable {
        var id: UUID { record.id }
        var record: QuizRecord
        var takeaway: Takeaway?
    }

    struct ReviewFlow: Hashable {
        var concepts: [MissedConcept]
        var index = 0
        var freshQuestion: QuizQuestion?
        var freshSelected: Int?
        var freshGrade: QuizGrade?
        var isGrading = false
        var isFinished = false
        var current: MissedConcept? { index < concepts.count ? concepts[index] : nil }
    }

    // MARK: State

    let id: UUID
    private(set) var mode: Mode
    private(set) var session: LectureSession
    private(set) var course: Course?
    private(set) var recordingState: RecordingState
    private(set) var elapsed: TimeInterval
    private(set) var level: Float = 0
    private(set) var volatile: TranscriptSegment?
    private(set) var paragraphs: [TranscriptParagraph] = []
    private(set) var activity: BrainActivity = .idle
    private(set) var detectedSlide: Int?
    var followSlides = true
    private(set) var manualSlide: Int?
    private(set) var visitedSlides: Set<Int> = []
    private(set) var highlightedSlide: Int?
    /// The brain thinks the lecture went back to this slide; the user decides (DESIGN.md §4.18).
    private(set) var backtrackSuggestion: Int?
    private(set) var notices: [Notice] = []
    private(set) var summaryState: SummaryState = .none
    /// Incremented whenever a takeaway settles; views use it for "N new" counts.
    private(set) var settledCount = 0
    private(set) var quiz: ActiveQuiz?
    private(set) var pendingQuizBadge: QuizQuestion?
    private(set) var streak = 0
    private(set) var streamingAnswer: String?
    private(set) var isAnswering = false
    private(set) var askError: String?
    private(set) var reviewFlow: ReviewFlow?
    var slideImages: SlideImageStore?

    /// "While you were away" recap (DESIGN.md §4.12).
    enum RecapState: Hashable {
        case loading(from: TimeInterval, to: TimeInterval)
        case ready(Recap)
        case failed(String)
    }
    private(set) var recap: RecapState?
    private var awaySince: (date: Date, time: TimeInterval)?
    private var recapTask: Task<Void, Never>?
    private var pauseMarkers: [TimeInterval] = []

    // UI state that must survive view re-creation.
    var isTypingInAsk = false
    var askDraft = ""
    var inspectorTab: InspectorTab = .transcript
    var isInspectorShown: Bool
    var showSlides: Bool
    var pane: SessionPane = .takeaways
    var expandedTakeawayID: UUID?
    var transcriptSeek: TranscriptSeek?
    var isFocusPanelOpen = false
    var isEditingTitle = false
    var showStopConfirmation = false
    /// "Add Deck…" chooser; presented from the session root so tier changes never remove it.
    var showDeckChooser = false
    var focusAskRequest = 0
    /// Bumped when the session root should take keyboard focus back (after leaving Ask, citations).
    var focusRootRequest = 0
    /// Bumped to open the slide viewer popover in the two-column tier (⌘3).
    var slideViewerRequest = 0
    /// Current responsive tier, mirrored from the view so pane/inspector commands can respect it.
    var layoutTier: LayoutTier = .three

    var onSessionChanged: ((LectureSession) -> Void)?
    var onFinished: (() -> Void)?

    private let services: AppServices
    private var settings: AppSettings
    private var preferences: UIPreferences
    private var engine: (any TranscriptionEngine)?
    private var brain: (any LectureIntelligence)?
    private var slideIndex: (any SlideSearching)?
    private var engineTask: Task<Void, Never>?
    private var engineStop: Task<Void, Never>?
    private var updatesTask: Task<Void, Never>?
    private var clockTask: Task<Void, Never>?
    private var askTask: Task<Void, Never>?
    private var quizTimerTask: Task<Void, Never>?
    private var quizDismissTask: Task<Void, Never>?
    private var snoozedTask: Task<Void, Never>?
    private var deferredQuizTask: Task<Void, Never>?
    private var highlightTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    /// Set while the deck's slide index is being built: the brain is created when it finishes.
    private var brainStartTask: Task<Void, Never>?
    /// Hand-offs to the autosaver are chained so it always sees snapshots in order.
    private var handoff: Task<Void, Never>?
    private var libraryPublishTask: Task<Void, Never>?
    /// The lecture was deleted: nothing may be saved or reported to the library any more.
    private var isDiscarded = false
    @ObservationIgnored private lazy var autosaver: any SessionAutosaving = services.makeAutosaver { [weak self] error in
        Task { @MainActor in self?.saveFailed(error) }
    }
    private var accumulated: TimeInterval
    private var resumedAt: Date?
    private var lastAudioAt = Date.now
    private var lastSaveTick = 0
    private var lastQuestionAsked: String?
    private var dirty = false

    init(session: LectureSession, course: Course?, mode: Mode, services: AppServices, settings: AppSettings, preferences: UIPreferences) {
        id = session.id
        self.session = session
        self.course = course
        self.mode = mode
        self.services = services
        self.settings = settings
        self.preferences = preferences
        recordingState = mode == .live ? .recording : .finished
        accumulated = session.duration
        elapsed = session.duration
        isInspectorShown = preferences.inspectorVisible
        showSlides = preferences.slidesVisible
        paragraphs = Self.paragraphs(from: session.transcript)
        if mode == .live, let t = session.transcript.last?.end, t > accumulated {
            // Resuming an interrupted session: duration was last saved before the crash.
            accumulated = t
            elapsed = t
        }
        visitedSlides = Set(session.takeaways.flatMap(\.slidePages))
        detectedSlide = mode == .review ? (session.deck?.pages.first?.number) : session.currentSlide
        streak = 0
        if mode == .review {
            summaryState = summary == nil ? .none : .ready
            Task { await self.loadSlideImages() }
            writeMissingSummary()
        }
    }

    // MARK: - Derived

    var title: String { session.title }
    var transcript: [TranscriptSegment] { session.transcript }
    var takeaways: [Takeaway] { session.takeaways }
    var settledTakeaways: [Takeaway] { takeaways.filter { !$0.isLive } }
    var liveTakeaway: Takeaway? { takeaways.first { $0.isLive } }
    var summary: LectureSummary? { session.summary }
    var deck: SlideDeck? { session.deck }
    var pageCount: Int { session.deck?.pages.count ?? slideImages?.pageCount ?? 0 }
    var displayedSlide: Int? { followSlides ? detectedSlide : (manualSlide ?? detectedSlide) }
    var chat: [ChatMessage] { session.chat }
    var quizRecords: [QuizRecord] { session.quiz }
    var isLive: Bool { mode == .live }
    var courseLabel: String { course?.code ?? "No course" }
    var startedAt: Date { session.startedAt ?? session.createdAt }
    var quizScore: (correct: Int, total: Int) {
        let answered = session.quiz.filter { $0.outcome != nil && $0.question.followUpOf == nil }
        return (answered.filter { $0.outcome == .correct }.count, answered.count)
    }
    var missedConcepts: [MissedConcept] {
        session.quiz.filter { ($0.outcome == .incorrect || $0.outcome == .skipped) && $0.question.followUpOf == nil }.map { r in
            MissedConcept(record: r, takeaway: takeaway(for: r.question))
        }
    }

    /// The takeaway a question is about. `askedAt` is deliberately not used: a ping is offered
    /// after the *next* topic has started, which mapped every concept to the wrong card (QA N2).
    func takeaway(for question: QuizQuestion) -> Takeaway? {
        let settled = settledTakeaways
        if let g = question.grounding {
            if let t = settled.first(where: { $0.title.caseInsensitiveCompare(g.topic) == .orderedSame }) { return t }
            if !g.slides.isEmpty, let t = settled.max(by: { Set($0.slidePages).intersection(g.slides).count < Set($1.slidePages).intersection(g.slides).count }),
               !Set(t.slidePages).isDisjoint(with: g.slides) { return t }
        }
        if let s = question.sourceStart, let t = settled.first(where: { $0.start <= s && s < $0.end }) { return t }
        if !question.sourceSlides.isEmpty, let t = settled.max(by: { Set($0.slidePages).intersection(question.sourceSlides).count < Set($1.slidePages).intersection(question.sourceSlides).count }),
           !Set(t.slidePages).isDisjoint(with: question.sourceSlides) { return t }
        let concept = question.concept.lowercased()
        return settled.first { $0.title.lowercased().contains(concept) || $0.summary.lowercased().contains(concept) }
    }
    var subtitle: String {
        "\(courseLabel) · \(Self.relativeDate(startedAt))"
    }
    var activityLabel: String {
        if recordingState == .paused { return "Paused" }
        switch activity {
        case .idle: return isLive ? "Listening" : ""
        case .summarizing: return "Summarizing…"
        case .recapping: return "Catching up…"
        case .expanding: return "Expanding…"
        case .writingQuestion: return "Writing quiz…"
        case .grading: return "Grading…"
        case .answering: return "Answering…"
        }
    }
    var isBusy: Bool { activity != .idle }

    func takeaway(covering time: TimeInterval) -> Takeaway? {
        takeaways.first { $0.start <= time && time <= $0.end }
    }

    /// The quiz that a takeaway spawned: matched by the question's source range, falling back to
    /// "asked while this topic was live".
    func quizMarker(for takeaway: Takeaway) -> QuizOutcome?? {
        let records = session.quiz.filter { r in
            guard r.question.followUpOf == nil else { return false }
            if let s = r.question.sourceStart { return s >= takeaway.start && s < takeaway.end }
            return r.askedAt >= takeaway.start && r.askedAt <= takeaway.end
        }
        guard let last = records.last else { return nil }
        return .some(last.outcome)
    }

    static func relativeDate(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        let f = DateFormatter()
        f.dateFormat = cal.isDate(date, equalTo: .now, toGranularity: .year) ? "EEE MMM d" : "MMM d, yyyy"
        return f.string(from: date)
    }

    static func wallClock(_ base: Date, offset: TimeInterval) -> String {
        base.addingTimeInterval(offset).formatted(date: .omitted, time: .shortened)
    }

    // MARK: - Lifecycle (live)

    func start(deckURL: URL?) {
        if session.startedAt == nil { session.startedAt = .now }
        session.status = .live
        resumedAt = .now
        markDirty()
        if let deckURL {
            Task { [services, id] in
                do {
                    let name = try await services.store.importSlides(from: deckURL, into: id)
                    self.session.deck?.fileName = name
                    self.markDirty()
                } catch {
                    self.push(Notice(id: "deck-copy", kind: .warning, symbol: "exclamationmark.triangle", title: "Couldn't copy the deck into the library", placement: .takeaways, actionLabel: nil))
                }
            }
        }
        if slideImages == nil, deckURL != nil { slideImages = SlideImageStore(url: deckURL) }
        startBrain()
        startEngine(offset: elapsed)
        startClock()
    }

    /// Starts the brain. With a deck, its slide index is built first (embedding every page takes
    /// seconds, so never on the main actor); the brain appears when it is ready, seeded with the
    /// transcript so far. Use `readyBrain()` to wait for it.
    private func startBrain() {
        guard brain == nil, brainStartTask == nil else { return }
        guard slideIndex == nil, let deck = session.deck else {
            createBrain()
            return
        }
        brainStartTask = Task { [services] in
            slideIndex = await services.makeSlideIndex(deck)
            brainStartTask = nil
            createBrain()
        }
    }

    /// The brain, once it exists (starting it if needed).
    private func readyBrain() async -> (any LectureIntelligence)? {
        startBrain()
        await brainStartTask?.value
        return brain
    }

    private func createBrain() {
        guard brain == nil else { return }
        let context = BrainContext(sessionTitle: session.title, courseName: course?.name, deck: session.deck, transcript: session.transcript, takeaways: takeaways, quizHistory: session.quiz, sessionID: id, currentSlide: session.currentSlide)
        let brain = services.makeBrain(context, settings, slideIndex)
        self.brain = brain
        updatesTask = Task { [weak self] in
            for await update in brain.updates {
                guard let self else { return }
                self.apply(update)
            }
        }
    }

    private func startEngine(offset: TimeInterval) {
        let engine = services.makeTranscriptionEngine(settings.transcriptionEngine)
        self.engine = engine
        let options = TranscriptionOptions(inputDeviceID: settings.inputDeviceID, vocabulary: settings.vocabulary + session.vocabulary, timeOffset: offset)
        lastAudioAt = .now
        // Engines are shared per kind, so a start right after a pause must wait for its stop.
        let stopping = engineStop
        engineTask = Task { [weak self] in
            await stopping?.value
            do {
                let stream = try await engine.start(options: options)
                for try await event in stream {
                    guard let self else { return }
                    self.handle(event)
                }
            } catch {
                guard let self else { return }
                self.push(Notice(id: "engine", kind: .warning, symbol: "mic.slash", title: "Transcription stopped: \(error.localizedDescription)", placement: .transcript, actionLabel: "Choose mic"))
            }
        }
    }

    private func startClock() {
        clockTask?.cancel()
        clockTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                tick += 1
                self.tickClock(tick)
            }
        }
    }

    private func tickClock(_ tick: Int) {
        guard recordingState == .recording, let resumedAt else { return }
        let now = Date.now
        withAnimation(DS.Motion.numeric) { elapsed = accumulated + now.timeIntervalSince(resumedAt) }
        let t = elapsed; withBrain { await $0.tick(sessionTime: t) }
        if now.timeIntervalSince(lastAudioAt) > 20, !notices.contains(where: { $0.id == "silence" }) {
            push(Notice(id: "silence", kind: .warning, symbol: "mic.slash", title: "No audio detected", placement: .transcript, actionLabel: "Choose mic"))
        }
        if tick - lastSaveTick >= 5 {
            lastSaveTick = tick
            saveIfDirty()
        }
    }

    func togglePause() {
        switch recordingState {
        case .recording: pause()
        case .paused: resume()
        default: break
        }
    }

    func pause() {
        guard recordingState == .recording, let resumedAt else { return }
        accumulated += Date.now.timeIntervalSince(resumedAt)
        elapsed = accumulated
        self.resumedAt = nil
        recordingState = .paused
        session.status = .paused
        appendPauseMarker(at: elapsed)
        let engine = engine
        engineTask?.cancel()
        engineStop = Task { await engine?.stop() }
        self.engine = nil
        volatile = nil
        level = 0
        announce("Recording paused")
        markDirty()
    }

    func resume() {
        guard recordingState == .paused else { return }
        resumedAt = .now
        recordingState = .recording
        session.status = .live
        startEngine(offset: elapsed)
        announce("Recording resumed")
        markDirty()
    }

    /// Stops recording and transitions the same view into review mode.
    func finish() {
        guard recordingState == .recording || recordingState == .paused else { return }
        if recordingState == .recording, let resumedAt { accumulated += Date.now.timeIntervalSince(resumedAt) }
        resumedAt = nil
        elapsed = accumulated
        recordingState = .finishing
        showStopConfirmation = false
        clockTask?.cancel()
        dismissQuiz()
        let engine = engine
        engineTask?.cancel()
        self.engine = nil
        volatile = nil
        session.endedAt = .now
        session.duration = accumulated
        session.status = .finished
        session.currentSlide = detectedSlide
        withAnimation(DS.Motion.settle) {
            mode = .review
            summaryState = .writing
        }
        markDirty()
        Task {
            await flush()
            await engine?.stop()
            await readyBrain()?.finish()
            await writeSummary()
            recordingState = .finished
            onFinished?()
            await flush()
            announce("Finished — summary ready")
        }
    }

    /// Finishes a session that was interrupted by a crash: no engine, just close + summarize.
    func finishWithoutRecording() {
        recordingState = .finishing
        session.endedAt = .now
        session.duration = accumulated
        session.status = .finished
        if let i = session.takeaways.firstIndex(where: { $0.isLive }) { session.takeaways[i].isLive = false }
        mode = .review
        summaryState = .writing
        markDirty()
        Task {
            await readyBrain()?.finish()
            await writeSummary()
            recordingState = .finished
            await flush()
        }
    }

    /// Asks the brain for the lecture summary. Settled takeaways without details are expanded
    /// first (a few), since details ground the summary's key concepts and are kept for the cards.
    private func writeSummary() async {
        guard let brain = await readyBrain() else { summaryState = .failed("No model"); return }
        for t in settledTakeaways.prefix(8) where t.detail == nil {
            if let detail = try? await brain.expand(takeawayID: t.id), let i = session.takeaways.firstIndex(where: { $0.id == t.id }) {
                session.takeaways[i].detail = detail
            }
        }
        do {
            let summary = try await brain.lectureSummary()
            withAnimation(DS.Motion.morph) {
                session.summary = summary
                summaryState = .ready
            }
            markDirty()
        } catch {
            withAnimation(DS.Motion.morph) { summaryState = .failed(error.localizedDescription) }
        }
    }

    /// Review of a finished lecture that has no summary (an import, or one saved before
    /// summaries were stored separately): write it now, once.
    private func writeMissingSummary() {
        guard session.summary == nil, session.status == .finished, !session.takeaways.isEmpty || !session.transcript.isEmpty else { return }
        summaryState = .writing
        Task {
            await writeSummary()
            await flush()
        }
    }

    func retrySummary() {
        summaryState = .writing
        Task {
            await writeSummary()
            await flush()
        }
    }

    func applySettings(_ new: AppSettings) {
        settings = new
        withBrain { await $0.update(quiz: new.quiz, summaryIntervalSeconds: new.summaryIntervalSeconds) }
    }

    func applyPreferences(_ new: UIPreferences) { preferences = new }

    func setCourse(_ course: Course?) {
        self.course = course
        session.courseID = course?.id
        markDirty()
    }

    func setTitle(_ title: String) {
        let t = title.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, t != session.title else { return }
        session.title = t
        markDirty()
        saveSoon()
    }

    /// Fire-and-forget call into the brain actor (its ingest/tick-style methods are isolated).
    private func withBrain(_ op: @escaping @Sendable (any LectureIntelligence) async -> Void) {
        guard let brain else { return }
        Task { await op(brain) }
    }

    // MARK: - Events

    private func handle(_ event: TranscriptionEvent) {
        switch event {
        case .volatile(let seg):
            volatile = seg
            lastAudioAt = .now
        case .final(let heard):
            // Course jargon misheard by the recognizer is fixed from the deck before anyone sees it.
            let seg = JargonFixer.shared.fix(heard, deck: session.deck, settings: settings, services: services)
            volatile = nil
            lastAudioAt = .now
            session.transcript.append(seg)
            append(seg)
            withBrain { await $0.ingest(seg) }
            markDirty()
        case .level(let l):
            level = l
            if l > 0.03 {
                lastAudioAt = .now
                if notices.contains(where: { $0.id == "silence" }) { dismissNotice("silence") }
            }
        case .warning(let message):
            push(Notice(id: "engine-warning", kind: .warning, symbol: "exclamationmark.triangle", title: message, placement: .transcript, actionLabel: nil))
        case .speakers(let labels):
            applySpeakers(labels)
        }
    }

    /// Diarization labels arrive a few seconds after the text; later labels for an id win.
    private func applySpeakers(_ labels: [UUID: SpeakerRole]) {
        var changed = false
        for (id, role) in labels {
            // Labels are almost always for the newest segments, so look from the end.
            if let i = session.transcript.lastIndex(where: { $0.id == id }), session.transcript[i].speaker != role {
                session.transcript[i].speaker = role
                changed = true
            }
        }
        guard changed else { return }
        rebuildParagraphs()
        withBrain { await $0.applySpeakers(labels) }
        markDirty()
    }

    private func apply(_ update: BrainUpdate) {
        switch update {
        case .takeaways(let list):
            let previousLiveID = liveTakeaway?.id
            withAnimation(DS.Motion.settle) {
                // A range never ends before it starts, whatever timeline the brain used (QA F3).
                session.takeaways = list.map { t in var t = t; t.end = max(t.end, t.start); return t }
            }
            if let previousLiveID, let now = list.first(where: { $0.id == previousLiveID }), !now.isLive {
                settledCount += 1
                if preferences.announceNewTakeaways { announce("New takeaway: \(now.title)") }
            }
            markDirty()
        case .currentSlide(let n):
            guard n != detectedSlide else { return }
            // Automatic following never moves backwards; only the user (or an accepted suggestion) can.
            if let n, let current = detectedSlide, n < current { return }
            withAnimation(DS.Motion.settle) { detectedSlide = n }
            if let n { visitedSlides.insert(n) }
            session.currentSlide = n
            markDirty()
        case .backtrackSuggestion(let n):
            withAnimation(DS.Motion.quick) { backtrackSuggestion = (n != nil && n != detectedSlide) ? n : nil }
        case .quizReady(let q):
            offer(q)
        case .activity(let a):
            withAnimation(DS.Motion.morph) { activity = a }
        case .error(let message):
            push(Notice(id: "brain-error", kind: .warning, symbol: "exclamationmark.triangle", title: message, placement: .takeaways, actionLabel: nil))
        }
    }

    // MARK: - Transcript paragraphs

    private func append(_ seg: TranscriptSegment) {
        if var last = paragraphs.last, Self.canJoin(seg, to: last) {
            last.segments.append(seg)
            last.end = seg.end
            paragraphs[paragraphs.count - 1] = last
        } else {
            paragraphs.append(TranscriptParagraph(id: seg.id, kind: .speech, start: seg.start, end: seg.end, segments: [seg]))
        }
    }

    private func appendPauseMarker(at time: TimeInterval) {
        pauseMarkers.append(time)
        paragraphs.append(TranscriptParagraph(id: TranscriptParagraph.pauseID(at: time), kind: .pause, start: time, end: time, segments: []))
    }

    private func rebuildParagraphs() {
        paragraphs = Self.paragraphs(from: session.transcript, pauses: pauseMarkers)
    }

    /// Join rule: same speaker, gap < 1.5 s, and under ~6 lines of text.
    nonisolated private static func canJoin(_ seg: TranscriptSegment, to paragraph: TranscriptParagraph) -> Bool {
        guard paragraph.kind == .speech, let last = paragraph.segments.last else { return false }
        let sameSpeaker = (last.speaker ?? .lecturer) == (seg.speaker ?? .lecturer)
        return sameSpeaker && seg.start - paragraph.end < TranscriptParagraph.breakGap && paragraph.text.count + seg.text.count < TranscriptParagraph.maxCharacters
    }

    nonisolated static func paragraphs(from segments: [TranscriptSegment], pauses: [TimeInterval] = []) -> [TranscriptParagraph] {
        var result: [TranscriptParagraph] = []
        var pending = pauses.sorted()
        for seg in segments {
            while let p = pending.first, p <= seg.start {
                result.append(TranscriptParagraph(id: TranscriptParagraph.pauseID(at: p), kind: .pause, start: p, end: p, segments: []))
                pending.removeFirst()
            }
            if var last = result.last, canJoin(seg, to: last) {
                last.segments.append(seg)
                last.end = seg.end
                result[result.count - 1] = last
            } else {
                result.append(TranscriptParagraph(id: seg.id, kind: .speech, start: seg.start, end: seg.end, segments: [seg]))
            }
        }
        for p in pending { result.append(TranscriptParagraph(id: TranscriptParagraph.pauseID(at: p), kind: .pause, start: p, end: p, segments: [])) }
        return result
    }

    func paragraph(at time: TimeInterval) -> TranscriptParagraph? {
        paragraphs.last { $0.kind == .speech && $0.start <= time } ?? paragraphs.first { $0.kind == .speech }
    }

    // MARK: - Slides

    func selectSlide(_ page: Int) {
        guard page >= 1, page <= max(pageCount, 1) else { return }
        withAnimation(DS.Motion.quick) {
            manualSlide = page
            followSlides = false
            if backtrackSuggestion == page { backtrackSuggestion = nil }
        }
        if mode == .live { withBrain { await $0.setCurrentSlide(page) } }
        if mode == .review { seekTranscript(to: firstTime(forSlide: page)) }
    }

    /// Accepts the brain's "back on slide N?" suggestion: tracking resumes from there.
    func acceptBacktrack() {
        guard let page = backtrackSuggestion else { return }
        withAnimation(DS.Motion.settle) {
            backtrackSuggestion = nil
            detectedSlide = page
            manualSlide = nil
            followSlides = true
        }
        visitedSlides.insert(page)
        session.currentSlide = page
        withBrain { await $0.setCurrentSlide(page) }
        markDirty()
    }

    func dismissBacktrack() {
        withAnimation(DS.Motion.quick) { backtrackSuggestion = nil }
    }

    func stepSlide(_ delta: Int) {
        let current = displayedSlide ?? 1
        selectSlide(min(max(1, current + delta), max(pageCount, 1)))
    }

    func resumeFollowing() {
        withAnimation(DS.Motion.quick) {
            followSlides = true
            manualSlide = nil
        }
    }

    func highlightSlide(_ page: Int) {
        withAnimation(DS.Motion.quick) { highlightedSlide = page }
        highlightTask?.cancel()
        highlightTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            withAnimation(DS.Motion.quick) { self?.highlightedSlide = nil }
        }
    }

    private func firstTime(forSlide page: Int) -> TimeInterval {
        takeaways.first { $0.slidePages.contains(page) }?.start ?? 0
    }

    /// Adds a deck mid-session (or in review) and indexes it in the background.
    func addDeck(url: URL) {
        slideImages = SlideImageStore(url: url)
        Task { [services, id] in
            do {
                let deck = try await services.slideIngestor.ingest(pdfAt: url) { _ in }
                var stored = deck
                stored.fileName = try await services.store.importSlides(from: url, into: id)
                self.session.deck = stored
                self.slideIndex = nil   // rebuilt from the new deck when a brain is next started
                if self.detectedSlide == nil { self.detectedSlide = 1 }
                self.markDirty()
            } catch {
                self.push(Notice(id: "deck", kind: .warning, symbol: "exclamationmark.triangle", title: error.localizedDescription, placement: .takeaways, actionLabel: nil))
            }
        }
    }

    private func loadSlideImages() async {
        guard slideImages == nil, let deck = session.deck else { return }
        if let folder = try? await services.store.folder(for: id) {
            slideImages = SlideImageStore(url: folder.appendingPathComponent(deck.fileName))
        }
    }

    // MARK: - Citations & navigation

    /// Handles `lectern://` links from takeaways, answers and chips.
    func open(_ url: URL) -> Bool {
        guard let parsed = LecternURL.parse(url), parsed.session == id else { return false }
        switch parsed.target {
        case .slide(let n): showSlide(n)
        case .time(let t): seekTranscript(to: t)
        }
        return true
    }

    /// A slide citation is a manual override (DESIGN §4.4): the hero shows the cited slide, Auto
    /// follow turns off ("Resume following" brings it back) and the brain is told (QA N1).
    func showSlide(_ n: Int) {
        selectSlide(n)
        highlightSlide(n)
        if layoutTier == .single { pane = .slides }
        focusRootRequest += 1
    }

    func seekTranscript(to time: TimeInterval) {
        if layoutTier == .single {
            pane = .transcript
        } else {
            inspectorTab = .transcript
            if !isInspectorShown { toggleInspector() }
        }
        transcriptSeek = TranscriptSeek(time: time)
        focusRootRequest += 1
    }

    /// ⌘1–4: in the single-region tier these pick the pane and never open the inspector (QA N3).
    func selectPane(_ p: SessionPane) {
        if layoutTier == .single {
            pane = p
            if p == .ask { focusAskRequest += 1 }
            return
        }
        switch p {
        case .takeaways: pane = .takeaways; focusRootRequest += 1
        case .slides:
            if layoutTier == .two { slideViewerRequest += 1 } else { withAnimation(DS.Motion.settle) { showSlides = true } }
        case .transcript: inspectorTab = .transcript; if !isInspectorShown { toggleInspector() }
        case .ask: focusAsk()
        }
    }

    /// Inspector toggles never animate (see `LiveSessionView`'s `.inspector` note).
    func toggleInspector() {
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { isInspectorShown.toggle() }
    }

    func focusAsk(seed: String? = nil) {
        if layoutTier == .single {
            pane = .ask
            if let seed { askDraft = seed }
            focusAskRequest += 1
            return
        }
        if !isInspectorShown { toggleInspector() }
        inspectorTab = .ask
        if let seed { askDraft = seed }
        focusAskRequest += 1
    }

    // MARK: - Takeaways

    func expandTakeaway(_ takeawayID: UUID?) {
        withAnimation(DS.Motion.settle) { expandedTakeawayID = takeawayID }
        guard let takeawayID, let t = takeaways.first(where: { $0.id == takeawayID }), t.detail == nil else { return }
        Task {
            do {
                guard let detail = try await readyBrain()?.expand(takeawayID: takeawayID) else { return }
                if let i = session.takeaways.firstIndex(where: { $0.id == takeawayID }) {
                    withAnimation(DS.Motion.settle) { session.takeaways[i].detail = detail }
                    markDirty()
                    saveSoon()
                }
            } catch {
                push(Notice(id: "expand", kind: .warning, symbol: "exclamationmark.triangle", title: "Couldn't expand: \(error.localizedDescription)", placement: .takeaways, actionLabel: nil))
            }
        }
    }

    func markdown(for takeaway: Takeaway) -> String {
        MarkdownExporter.markdown(for: takeaway, deck: session.deck)
    }

    func copyMarkdown(for takeaway: Takeaway) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(markdown(for: takeaway), forType: .string)
    }

    // MARK: - Quiz pings

    private func offer(_ q: QuizQuestion) {
        guard mode == .live, settings.quiz.enabled else { return }
        if quiz != nil || isTypingInAsk || recordingState != .recording {
            deferredQuizTask?.cancel()
            deferredQuizTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { return }
                self?.offer(q)
            }
            return
        }
        let quietTier = pane != .takeaways
        if preferences.quizStyle == .badge || quietTier {
            withAnimation(DS.Motion.quick) { pendingQuizBadge = q }
            return
        }
        present(q)
    }

    /// Opens the badge's pending question (Quiet style / narrow tier).
    func openPendingQuiz() {
        guard let q = pendingQuizBadge else { return }
        pendingQuizBadge = nil
        present(q)
    }

    private func present(_ q: QuizQuestion) {
        let deadline = Date.now.addingTimeInterval(preferences.quizTimeToAnswer)
        withAnimation(DS.Motion.float) {
            quiz = ActiveQuiz(question: q, deadline: deadline)
        }
        if !session.quiz.contains(where: { $0.id == q.id }) {
            session.quiz.append(QuizRecord(question: q, askedAt: elapsed))
        }
        announce("Quick check: \(q.prompt)")
        quizTimerTask?.cancel()
        quizTimerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(1, deadline.timeIntervalSinceNow)))
            guard !Task.isCancelled, let self, let active = self.quiz, active.question.id == q.id, active.phase == .asking else { return }
            self.skipQuiz()
        }
        markDirty()
    }

    func selectOption(_ index: Int) {
        guard var active = quiz, active.acceptsAnswers else { return }
        active.selectedOption = index
        quiz = active
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            self?.submitAnswer("\(index)")
        }
    }

    func submitShortAnswer() {
        guard let active = quiz, active.acceptsAnswers else { return }
        let text = active.shortAnswer.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        submitAnswer(text)
    }

    func updateShortAnswer(_ text: String) {
        quiz?.shortAnswer = text
    }

    private func submitAnswer(_ answer: String) {
        guard var active = quiz, active.acceptsAnswers, let brain else { return }
        quizTimerTask?.cancel()
        let question = active.activeQuestion
        let isFollowUp = question.id != active.question.id
        if case .wrong(let grade, let f?, _) = active.phase, isFollowUp {
            active.phase = .gradingFollowUp(grade, followUp: f)
        } else {
            active.phase = .grading
        }
        active.shortAnswer = ""
        quiz = active
        let wantsFollowUp = !isFollowUp && preferences.followUpWhenWrong
        Task { [weak self] in
            // The follow-up is generated *before* the explanation is shown so there is no wait.
            async let followUp: QuizQuestion? = wantsFollowUp ? (try? await brain.makeQuestion(followUpOf: question)) : nil
            do {
                let grade = try await brain.grade(question, answer: answer)
                guard let self, var active = self.quiz, active.activeQuestion.id == question.id else { return }
                self.recordOutcome(question: question, answer: answer, grade: grade)
                if isFollowUp, case .gradingFollowUp(let first, let f) = active.phase {
                    if grade.isCorrect { self.streak += 1 }
                    active.phase = .followUpResult(first, followUp: f, result: grade)
                    withAnimation(DS.Motion.settle) { self.quiz = active }
                    self.announce(grade.isCorrect ? "Correct" : "Not quite")
                    self.scheduleDismiss()
                    return
                }
                if grade.isCorrect {
                    self.streak += 1
                    active.phase = .correct(grade)
                    withAnimation(DS.Motion.settle) { self.quiz = active }
                    self.announce("Correct")
                    self.scheduleDismiss()
                } else {
                    self.streak = 0
                    active.phase = .wrong(grade, followUp: nil, followUpPending: wantsFollowUp)
                    active.selectedOption = nil
                    withAnimation(DS.Motion.settle) { self.quiz = active }
                    self.announce("Not quite. \(grade.feedback)")
                    if wantsFollowUp {
                        let f = await followUp
                        guard var again = self.quiz, again.activeQuestion.id == question.id else { return }
                        var followUpQuestion = f
                        followUpQuestion?.followUpOf = question.id
                        again.phase = .wrong(grade, followUp: followUpQuestion, followUpPending: false)
                        withAnimation(DS.Motion.float) { self.quiz = again }
                        if let followUpQuestion {
                            self.session.quiz.append(QuizRecord(question: followUpQuestion, askedAt: self.elapsed))
                        } else {
                            self.scheduleDismiss(after: 8)
                        }
                    } else {
                        self.scheduleDismiss(after: 8)
                    }
                }
            } catch {
                guard let self else { return }
                self.push(Notice(id: "grade", kind: .warning, symbol: "exclamationmark.triangle", title: "Couldn't grade: \(error.localizedDescription)", placement: .takeaways, actionLabel: nil))
                self.dismissQuiz()
            }
        }
    }

    private func recordOutcome(question: QuizQuestion, answer: String?, grade: QuizGrade?, outcome: QuizOutcome? = nil) {
        let resolved = outcome ?? (grade?.isCorrect == true ? .correct : .incorrect)
        var record = session.quiz.first { $0.id == question.id } ?? QuizRecord(question: question, askedAt: elapsed)
        record.answer = answer
        record.grade = grade
        record.outcome = resolved
        record.answeredAt = .now
        if let i = session.quiz.firstIndex(where: { $0.id == question.id }) { session.quiz[i] = record } else { session.quiz.append(record) }
        let snapshot = record
        withBrain { await $0.record(snapshot) }
        markDirty()
    }

    func snoozeQuiz() {
        guard let active = quiz, active.phase == .asking else { return }
        quizTimerTask?.cancel()
        let q = active.question
        session.quiz.removeAll { $0.id == q.id }
        withAnimation(DS.Motion.float) { quiz = nil }
        snoozedTask?.cancel()
        snoozedTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(300))
            guard !Task.isCancelled else { return }
            self?.offer(q)
        }
    }

    func skipQuiz() {
        guard let active = quiz else { return }
        quizTimerTask?.cancel()
        if active.phase == .asking {
            recordOutcome(question: active.question, answer: nil, grade: nil, outcome: .skipped)
        } else if case .wrong(_, let f?, _) = active.phase {
            recordOutcome(question: f, answer: nil, grade: nil, outcome: .skipped)
        }
        withAnimation(DS.Motion.float) { quiz = nil }
    }

    func dismissQuiz() {
        quizTimerTask?.cancel()
        quizDismissTask?.cancel()
        if let active = quiz, active.phase == .asking {
            recordOutcome(question: active.question, answer: nil, grade: nil, outcome: .skipped)
        }
        withAnimation(DS.Motion.float) { quiz = nil }
    }

    func setQuizHovered(_ hovered: Bool) {
        quiz?.isHovered = hovered
        if let active = quiz, active.isResult {
            if hovered { quizDismissTask?.cancel() } else { scheduleDismiss() }
        }
    }

    private func scheduleDismiss(after seconds: Double = 4) {
        quizDismissTask?.cancel()
        quizDismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self, self.quiz?.isHovered != true else { return }
            withAnimation(DS.Motion.float) { self.quiz = nil }
        }
    }

    // MARK: - Ask

    func ask(_ text: String) {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isAnswering else { return }
        askDraft = ""
        askError = nil
        lastQuestionAsked = question
        let history = session.chat
        session.chat.append(ChatMessage(role: .user, text: question))
        streamingAnswer = ""
        isAnswering = true
        inspectorTab = .ask
        askTask?.cancel()
        askTask = Task { [weak self] in
            do {
                guard let brain = await self?.readyBrain() else { throw CancellationError() }
                for try await event in await brain.ask(question, history: history) {
                    guard let self, !Task.isCancelled else { return }
                    switch event {
                    case .delta(let d): self.streamingAnswer = (self.streamingAnswer ?? "") + d
                    case .done(let message):
                        self.session.chat.append(message)
                        self.streamingAnswer = nil
                        self.markDirty()
                        self.saveSoon()
                    }
                }
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.askError = Self.friendly(error)
                self.streamingAnswer = nil
            }
            self?.isAnswering = false
        }
    }

    func retryAsk() {
        guard let last = lastQuestionAsked else { return }
        if session.chat.last?.role == .user { session.chat.removeLast() }
        ask(last)
    }

    /// Review only: regenerate the last answer.
    func regenerateLastAnswer() {
        guard mode == .review, let lastUser = session.chat.last(where: { $0.role == .user }) else { return }
        if session.chat.last?.role == .assistant { session.chat.removeLast() }
        if session.chat.last?.role == .user { session.chat.removeLast() }
        ask(lastUser.text)
    }

    func cancelAsk() {
        askTask?.cancel()
        isAnswering = false
        streamingAnswer = nil
    }

    private static func friendly(_ error: Error) -> String {
        if let e = error as? LLMError {
            switch e {
            case .missingAPIKey(let k): return "\(k.displayName): no API key — add one in Settings › Models"
            case .http(let s, let m): return "\(s) — \(m.isEmpty ? "check your key in Settings › Models" : m)"
            case .network(let m): return "Network problem: \(m)"
            case .modelNotDownloaded(let m): return "\(m) isn't downloaded — see Settings › Models"
            case .invalidResponse(let m): return "Unexpected response: \(m)"
            case .cancelled: return "Cancelled"
            }
        }
        return error.localizedDescription
    }

    // MARK: - Review missed concepts

    func startReviewMissed() {
        let concepts = missedConcepts
        guard !concepts.isEmpty else { return }
        withAnimation(DS.Motion.settle) { reviewFlow = ReviewFlow(concepts: concepts) }
        loadFreshQuestion()
    }

    private func loadFreshQuestion() {
        guard let flow = reviewFlow, let current = flow.current else { return }
        Task { [weak self] in
            let q = try? await self?.readyBrain()?.makeQuestion(followUpOf: current.record.question)
            guard let self, self.reviewFlow?.current?.id == current.id else { return }
            withAnimation(DS.Motion.settle) { self.reviewFlow?.freshQuestion = q }
        }
    }

    func reviewSelect(_ index: Int) {
        reviewFlow?.freshSelected = index
        reviewSubmit(answer: "\(index)")
    }

    func reviewSubmit(answer: String) {
        guard var flow = reviewFlow, let q = flow.freshQuestion, !flow.isGrading, flow.freshGrade == nil, let brain else { return }
        flow.isGrading = true
        reviewFlow = flow
        Task { [weak self] in
            let grade = try? await brain.grade(q, answer: answer)
            guard let self, self.reviewFlow?.freshQuestion?.id == q.id else { return }
            withAnimation(DS.Motion.settle) {
                self.reviewFlow?.isGrading = false
                self.reviewFlow?.freshGrade = grade
            }
        }
    }

    func reviewNext() {
        guard var flow = reviewFlow else { return }
        flow.index += 1
        flow.freshQuestion = nil
        flow.freshSelected = nil
        flow.freshGrade = nil
        flow.isGrading = false
        if flow.index >= flow.concepts.count { flow.isFinished = true }
        withAnimation(DS.Motion.settle) { reviewFlow = flow }
        if !flow.isFinished { loadFreshQuestion() }
    }

    func exitReview() {
        withAnimation(DS.Motion.settle) { reviewFlow = nil }
    }

    // MARK: - Export

    func exportMarkdown() -> String {
        MarkdownExporter.document(session: session, course: course)
    }

    func copySummary() {
        let text = summary.map(Self.plainText) ?? settledTakeaways.map { "• \($0.title): \($0.summary)" }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// The summary as plain text for the clipboard.
    nonisolated static func plainText(_ summary: LectureSummary) -> String {
        var parts = [summary.overview]
        if !summary.keyConcepts.isEmpty {
            parts.append("Key concepts\n" + summary.keyConcepts.map { "• \($0.term): \($0.definition)" }.joined(separator: "\n"))
        }
        if !summary.reviewThese.isEmpty { parts.append("Review these\n" + summary.reviewThese.map { "• \($0)" }.joined(separator: "\n")) }
        if !summary.flagged.isEmpty { parts.append("Flagged\n" + summary.flagged.map { "• \($0)" }.joined(separator: "\n")) }
        return parts.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    // MARK: - "While you were away"

    /// The app left the foreground (resigned active or the main window was occluded).
    func appDidResignActive() {
        if case .loading = recap { recapTask?.cancel(); recap = nil }
        guard mode == .live, recordingState == .recording, awaySince == nil else { return }
        awaySince = (.now, elapsed)
    }

    func appDidBecomeActive() {
        guard let away = awaySince else { return }
        awaySince = nil
        let gone = Date.now.timeIntervalSince(away.date)
        guard preferences.showRecapWhenBack, gone >= preferences.awayThresholdSeconds, elapsed - away.time >= 30 else { return }
        requestRecap(from: away.time, to: elapsed)
    }

    /// Debug helper: pretend the user was away for `seconds` ending now.
    func simulateAway(seconds: TimeInterval) {
        awaySince = (Date.now.addingTimeInterval(-seconds), max(0, elapsed - seconds))
        appDidBecomeActive()
    }

    private func requestRecap(from: TimeInterval, to: TimeInterval) {
        recapTask?.cancel()
        withAnimation(DS.Motion.float) { recap = .loading(from: from, to: to) }
        recapTask = Task { [weak self] in
            do {
                guard let brain = await self?.readyBrain() else { throw CancellationError() }
                let r = try await brain.recap(from: from, to: to)
                guard let self, !Task.isCancelled else { return }
                withAnimation(DS.Motion.morph) { self.recap = .ready(r) }
                self.announce("While you were away: \(r.headline)")
            } catch is CancellationError {
            } catch {
                guard let self, !Task.isCancelled else { return }
                withAnimation(DS.Motion.morph) { self.recap = .failed(error.localizedDescription) }
            }
        }
    }

    func dismissRecap() {
        recapTask?.cancel()
        withAnimation(DS.Motion.float) { recap = nil }
    }

    // MARK: - Notices

    private func push(_ notice: Notice) {
        withAnimation(DS.Motion.float) {
            notices.removeAll { $0.placement == notice.placement }
            notices.append(notice)
        }
    }

    /// A notice raised outside the session (e.g. the monthly API cap was reached).
    func showNotice(_ notice: Notice) { push(notice) }

    /// One-time tip when the window gets narrow: the Focus panel keeps the essentials floating.
    func showFocusPanelTip() {
        push(Notice(id: "focus-tip", kind: .info, symbol: "rectangle.inset.topright.filled", title: "Tight on space? The Focus panel (⌘⇧F) floats the current takeaway over any app.", placement: .takeaways, actionLabel: "Open"))
    }

    func dismissNotice(_ id: String) {
        withAnimation(DS.Motion.float) { notices.removeAll { $0.id == id } }
    }

    func notice(for placement: Notice.Placement) -> Notice? { notices.first { $0.placement == placement } }

    // MARK: - Persistence

    private func markDirty() {
        guard !isDiscarded else { return }
        dirty = true
        publishSoon()
    }

    /// Tells the library about the newest state at most once a second: every final segment marks
    /// the session dirty, and each hand-over invalidates the library views and forces a copy of
    /// the growing transcript. The autosaver coalesces the disk writes separately.
    private func publishSoon() {
        guard libraryPublishTask == nil else { return }
        libraryPublishTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.publishNow()
        }
    }

    /// Hands the current state to the library right away (status changes, flush).
    private func publishNow() {
        libraryPublishTask?.cancel()
        libraryPublishTask = nil
        guard !isDiscarded else { return }
        onSessionChanged?(session)
    }

    private func saveSoon() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.saveIfDirty()
        }
    }

    /// Hands the newest state to the autosaver, which writes it in order and at most once a second.
    func saveIfDirty() {
        guard dirty, !isDiscarded else { return }
        dirty = false
        _ = hand(session)
    }

    private func hand(_ snapshot: LectureSession) -> Task<Void, Never> {
        let previous = handoff
        let autosaver = autosaver
        let task = Task {
            await previous?.value
            await autosaver.update(snapshot)
        }
        handoff = task
        return task
    }

    /// Writes the newest state now and waits for it: on stop, when the lecture is closed, at quit.
    func flush() async {
        guard !isDiscarded else { return }
        publishNow()
        if dirty {
            dirty = false
            await hand(session).value
        } else {
            await handoff?.value
        }
        do { try await autosaver.flush() } catch { saveFailed(error) }
    }

    /// The lecture is being deleted: drop pending saves and wait for a write in flight, so a late
    /// save can't bring it back.
    func discardPendingSave() async {
        isDiscarded = true
        saveTask?.cancel()
        await handoff?.value
        await autosaver.discard()
    }

    /// A finished lecture with nothing running: safe to close when it leaves the screen.
    var isIdle: Bool {
        mode == .review && recordingState == .finished && summaryState != .writing && !isAnswering && !isBusy
            && recap == nil && reviewFlow == nil && !isFocusPanelOpen
    }

    /// Saves, then stops everything this model started (the brain and its update loop, timers) so
    /// the model can be released. Called when a review lecture leaves the screen.
    func close() async {
        await flush()
        for task in [askTask, recapTask, quizTimerTask, quizDismissTask, snoozedTask, deferredQuizTask, highlightTask, saveTask, updatesTask, clockTask, engineTask, brainStartTask] {
            task?.cancel()
        }
        brain = nil
    }

    private func saveFailed(_ error: any Error) {
        guard !isDiscarded else { return }
        dirty = true
        push(Notice(id: "save", kind: .warning, symbol: "exclamationmark.triangle", title: "Couldn't save: \(error.localizedDescription)", placement: .takeaways, actionLabel: nil))
    }

    // MARK: - Accessibility

    private func announce(_ text: String) {
        AccessibilityNotification.Announcement(text).post()
    }
}
