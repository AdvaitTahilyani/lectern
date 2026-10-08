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
        var selectedOption: Int?
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
        /// Why the fresh question couldn't be written or the answer couldn't be checked.
        var error: String?
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
    private(set) var paragraphs: [TranscriptParagraph] = [] {
        didSet { transcriptRevision &+= 1 }
    }
    /// Changes whenever `paragraphs` does (any text edit, regrouping or new segment); search caches key on it.
    private(set) var transcriptRevision = 0
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
    /// Questions waiting behind the one on screen (or behind the toolbar badge). A quiz stays until the
    /// user answers, snoozes, skips or dismisses it, so new ones queue instead of replacing it.
    private(set) var queuedQuizzes: [QuizQuestion] = []
    private(set) var streak = 0
    private(set) var streamingAnswer: String?
    private(set) var isAnswering = false
    private(set) var askError: String?
    private(set) var reviewFlow: ReviewFlow?
    var slideImages: SlideImageStore? {
        didSet { if let nav = navigationAfterImagesLoad, pageCount > 0 { navigationAfterImagesLoad = nil; navigate(to: nav) } }
    }
    /// A request with a slide that arrived before the deck's pages were known (review loads the
    /// images after the view appears); applied whole once they are, so its time still wins.
    private var navigationAfterImagesLoad: PendingNavigation?

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
    var pane: SessionPane = .takeaways {
        // Questions held back while another pane was showing appear when the Takeaways come back.
        didSet { if pane == .takeaways, oldValue != .takeaways { showNextQuizIfIdle() } }
    }
    var expandedTakeawayID: UUID?
    var transcriptSeek: TranscriptSeek?
    var isFocusPanelOpen = false
    var isEditingTitle = false
    var showStopConfirmation = false
    /// "Choose mic" picker, opened from the transcript's microphone warnings.
    var showMicChooser = false
    var focusAskRequest = 0
    /// Bumped when the session root should take keyboard focus back (after leaving Ask, citations).
    var focusRootRequest = 0
    /// Bumped to open the slide viewer popover in the two-column tier (⌘3).
    var slideViewerRequest = 0
    /// Current responsive tier, mirrored from the view so pane/inspector commands can respect it.
    var layoutTier: LayoutTier = .three {
        // Widening past the single-pane tier brings the Takeaways back, where held-back questions show.
        didSet { if oldValue == .single, layoutTier != .single { showNextQuizIfIdle() } }
    }

    var onSessionChanged: ((LectureSession) -> Void)?
    var onFinished: (() -> Void)?

    private let services: AppServices
    private var settings: AppSettings
    private var preferences: UIPreferences
    private var engine: (any TranscriptionEngine)?
    private var brain: (any LectureIntelligence)?
    private var slideIndex: (any SlideSearching)?
    /// Reads the running engine's events. Pause/Finish never cancel it: it drains the words the
    /// recognizer flushes at stop.
    private var engineTask: Task<Void, Never>?
    /// The latest stop, finished once its reader has handled every flushed event.
    private var engineStop: Task<Void, Never>?
    /// Bumped by every engine start and stop, so a start that completes after a stop (permission
    /// prompt, model load) knows it is stale.
    private var engineGeneration = 0
    /// Final segments go to the brain in order; Finish waits for the last one.
    private var brainIngest: Task<Void, Never>?
    /// The microphone this lecture records from: Setup's choice, or "Choose mic" (nil follows the
    /// system default).
    private(set) var inputDeviceID: String?
    private var updatesTask: Task<Void, Never>?
    private var clockTask: Task<Void, Never>?
    private var askTask: Task<Void, Never>?
    /// One timer per question held back (typing, paused) or snoozed; each re-offers its own question.
    private var quizTimers: [Task<Void, Never>] = []
    private var highlightTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    /// Set while the deck's slide index is being built: the brain is created when it finishes.
    private var brainStartTask: Task<Void, Never>?
    /// Card details written after the summary (cancelled when the lecture is closed).
    private var enrichTask: Task<Void, Never>?
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
        // Also live: a lecture resumed after a quit has its decks but no images yet (it showed
        // "No slides"). A new lecture gets Setup's images first, which this then leaves alone.
        Task { await self.loadSlideImages() }
        if mode == .review {
            summaryState = summary == nil ? .none : .ready
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
    /// Pages in the deck; a stored deck without page metadata (seeded demo lectures) counts the
    /// rendered PDF instead, otherwise every slide chip past page 1 was refused (QA Q3-8).
    var pageCount: Int {
        let n = session.decks.reduce(0) { $0 + $1.pages.count }
        if n > 0 { return n }
        return slideImages?.pageCount ?? 0
    }
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

    /// The takeaway a question is about (see `PracticeMatching`).
    func takeaway(for question: QuizQuestion) -> Takeaway? {
        PracticeMatching.takeaway(for: question, in: settledTakeaways)
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

    /// Starts recording from `inputDeviceID` (a CoreAudio UID; nil follows the system default).
    /// `deckURL` is Setup's deck file (already ingested into the session); `conversion` its
    /// PowerPoint/Keynote conversion, deleted once the PDF is copied.
    func start(deckURL: URL?, inputDeviceID: String?, conversion: ConvertedPresentation? = nil) {
        self.inputDeviceID = inputDeviceID
        if session.startedAt == nil { session.startedAt = .now }
        session.status = .live
        resumedAt = .now
        markDirty()
        if let deckURL { enqueueDeckWork { await $0.storeStartingDeck(from: deckURL, conversion: conversion) } }
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
        engineGeneration += 1
        let generation = engineGeneration
        let options = TranscriptionOptions(inputDeviceID: inputDeviceID, vocabulary: settings.vocabulary + session.vocabulary, timeOffset: offset)
        lastAudioAt = .now
        // Engines are shared per kind, so a start right after a pause must wait for its stop.
        let stopping = engineStop
        engineTask = Task { [weak self] in
            await stopping?.value
            guard self?.engineGeneration == generation else { return }   // stopped before it began
            do {
                let stream = try await engine.start(options: options)
                // Stopped while the engine was starting: that stop may have found nothing running.
                if self?.engineGeneration != generation { await engine.stop() }
                for try await event in stream {
                    guard let self else { return }
                    self.handle(event, isCurrent: self.engineGeneration == generation)
                }
            } catch {
                self?.engineFailed(error, generation: generation)
            }
        }
    }

    /// Stops capture and lets the reader drain what the recognizer flushes (the last words and
    /// their speaker labels). The returned task finishes once all of it is in the transcript and
    /// handed to the brain; `pauseMarkerAt` is placed after those words.
    @discardableResult
    private func stopEngine(pauseMarkerAt: TimeInterval? = nil) -> Task<Void, Never> {
        engineGeneration += 1
        let engine = engine, reader = engineTask, previous = engineStop
        self.engine = nil
        volatile = nil
        let stop = Task {
            await previous?.value
            await engine?.stop()
            await reader?.value
            await self.brainIngest?.value
            if let pauseMarkerAt { self.appendPauseMarker(at: pauseMarkerAt) }
        }
        engineStop = stop
        return stop
    }

    /// Capture or recognition failed: the lecture is paused (the clock stops) rather than showing
    /// a running recording that hears nothing, and "Choose mic" offers a way back.
    private func engineFailed(_ error: any Error, generation: Int) {
        guard generation == engineGeneration, recordingState == .recording, !(error is CancellationError) else { return }
        if let resumedAt { accumulated += Date.now.timeIntervalSince(resumedAt) }
        resumedAt = nil
        elapsed = accumulated
        recordingState = .paused
        session.status = .paused
        stopEngine(pauseMarkerAt: elapsed)
        level = 0
        push(Notice(id: "engine", kind: .warning, symbol: "mic.slash", title: "Recording paused. Transcription stopped: \(error.localizedDescription)", placement: .transcript, actionLabel: "Choose mic"))
        announce("Recording paused: transcription stopped")
        markDirty()
    }

    /// Microphones to offer in "Choose mic".
    var inputDevices: [AudioInputDevice] { services.inputDevices() }

    /// "Choose mic": records from `id` from now on. A running capture restarts on it (the words
    /// heard so far are flushed first); a paused lecture resumes on it.
    func switchInputDevice(_ id: String?) {
        showMicChooser = false
        inputDeviceID = id
        dismissNotice("engine")
        dismissNotice("silence")
        switch recordingState {
        case .recording:
            let now = resumedAt.map { accumulated + Date.now.timeIntervalSince($0) } ?? elapsed
            stopEngine()
            startEngine(offset: now)
        case .paused:
            resume()
        case .finishing, .finished:
            break
        }
    }

    /// Quit while recording: stops capture and keeps the words the recognizer flushes, then saves.
    /// The lecture stays live/paused on disk, so the next launch offers to resume or finish it.
    func stopForQuit() async {
        guard mode == .live, recordingState == .recording || recordingState == .paused else { return }
        if let resumedAt { accumulated += Date.now.timeIntervalSince(resumedAt) }
        resumedAt = nil
        elapsed = accumulated
        session.duration = accumulated
        clockTask?.cancel()
        await stopEngine().value
        markDirty()
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
        stopEngine(pauseMarkerAt: elapsed)
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
        closeQuizzesForFinish()
        let stopped = stopEngine()
        session.endedAt = .now
        session.duration = accumulated
        session.status = .finished
        session.currentSlide = detectedSlide
        withAnimation(DS.Motion.settle) {
            mode = .review
            summaryState = .writing
        }
        markDirty()
        // `stopped` ends once the recognizer's last words are in the transcript and the brain.
        completeFinish(after: stopped)
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
        completeFinish(after: nil)
    }

    /// The end of Finish, shared by both paths: once the transcript is saved the lecture stops
    /// being the active one (menu, Focus panel, starting another lecture), before the model work
    /// that follows, which can take a minute on a busy device. Then the brain closes the last card
    /// and the summary is written; the announcement says whether that worked.
    private func completeFinish(after stopped: Task<Void, Never>?) {
        Task {
            await stopped?.value
            await flush()
            recordingState = .finished
            onFinished?()
            await readyBrain()?.finish()
            await writeSummary()
            await flush()
            if case .failed(let reason) = summaryState {
                announce("Finished — the summary couldn't be written: \(reason)")
            } else {
                announce("Finished — summary ready")
            }
        }
    }

    /// Asks the brain for the lecture summary (from the cards, with whatever details they already
    /// have), then has it write details for a few cards that have none as background work: they
    /// arrive through takeaway updates, yield to anything interactive, and failures are reported.
    private func writeSummary() async {
        guard let brain = await readyBrain() else { summaryState = .failed("No model"); return }
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
        enrichTask?.cancel()
        enrichTask = Task {
            await brain.enrichTakeaways(limit: 8)
            saveSoon()
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
        let providersChanged = new.providers != settings.providers
        settings = new
        withBrain { await $0.update(quiz: new.quiz, summaryIntervalSeconds: new.summaryIntervalSeconds) }
        // The lecture's brain must use the provider the UI now names (B17); a brain created later
        // gets it from `settings`.
        if providersChanged, brain != nil, let makeProviders = services.makeRoleProviders {
            let providers = makeProviders(new, id)
            withBrain { await $0.update(providers: providers) }
        }
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

    /// One engine event. `isCurrent` is false while a stopped engine drains: its final words and
    /// speaker labels still count, but its live text and level no longer belong on screen.
    private func handle(_ event: TranscriptionEvent, isCurrent: Bool) {
        switch event {
        case .volatile(let seg):
            guard isCurrent else { return }
            volatile = seg
            lastAudioAt = .now
        case .final(let heard):
            // Course jargon misheard by the recognizer is fixed from the deck before anyone sees it.
            let seg = JargonFixer.shared.fix(heard, deck: session.deck, settings: settings, services: services)
            volatile = nil
            lastAudioAt = .now
            session.transcript.append(seg)
            append(seg)
            if let brain {
                let previous = brainIngest
                brainIngest = Task { await previous?.value; await brain.ingest(seg) }
            }
            markDirty()
        case .level(let l):
            guard isCurrent else { return }
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

    /// Diarization labels arrive a few seconds after the text; later labels for an id win. Only the
    /// paragraphs from the earliest relabeled segment on are regrouped (audit P06).
    private func applySpeakers(_ labels: [UUID: SpeakerRole]) {
        var earliest: Int?
        for (id, role) in labels {
            // Labels are almost always for the newest segments, so look from the end.
            if let i = session.transcript.lastIndex(where: { $0.id == id }), session.transcript[i].speaker != role {
                session.transcript[i].speaker = role
                earliest = min(earliest ?? i, i)
            }
        }
        guard let earliest else { return }
        paragraphs = Self.regroup(paragraphs, transcript: session.transcript, pauses: pauseMarkers, from: session.transcript[earliest].id)
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

    /// `paragraphs` after a change to the segment `segmentID` or later ones: the paragraphs before
    /// the one preceding that segment's are kept (grouping only looks back one paragraph), the rest
    /// are rebuilt from `transcript`. Same result as `paragraphs(from:pauses:)`, in time
    /// proportional to the tail.
    nonisolated static func regroup(_ paragraphs: [TranscriptParagraph], transcript: [TranscriptSegment], pauses: [TimeInterval], from segmentID: UUID) -> [TranscriptParagraph] {
        guard let changed = paragraphs.lastIndex(where: { $0.kind == .speech && $0.segments.contains { $0.id == segmentID } }) else {
            return Self.paragraphs(from: transcript, pauses: pauses)
        }
        let keep = max(0, changed - 1)
        guard let first = paragraphs[keep...].lazy.compactMap(\.segments.first).first,
              let tail = transcript.lastIndex(where: { $0.id == first.id }) else {
            return Self.paragraphs(from: transcript, pauses: pauses)
        }
        let placedPauses = paragraphs[..<keep].count { $0.kind == .pause }
        let rebuilt = Self.paragraphs(from: Array(transcript[tail...]), pauses: Array(pauses.sorted().dropFirst(placedPauses)))
        return Array(paragraphs[..<keep]) + rebuilt
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

    /// Shows `page` and makes it the lecture's current slide: a manual correction when tracking is
    /// wrong (thumbnail click, ←/→, the hero's arrows, a citation). Auto follow pauses so tracking
    /// doesn't take it straight back; "Resume following" (or Auto) turns it on again and tracking
    /// continues forward from this slide, also after a correction backwards.
    func selectSlide(_ page: Int) {
        guard page >= 1, page <= max(pageCount, 1) else { return }
        withAnimation(DS.Motion.quick) {
            manualSlide = page
            followSlides = false
            if backtrackSuggestion == page { backtrackSuggestion = nil }
            if mode == .live { detectedSlide = page }
        }
        if mode == .live {
            visitedSlides.insert(page)
            session.currentSlide = page
            markDirty()
            withBrain { await $0.setCurrentSlide(page) }
        }
        if mode == .review, let start = firstTime(forSlide: page) { seekTranscript(to: start) }
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
        guard pageCount > 0 else { return }
        let current = displayedSlide ?? 1
        selectSlide(min(max(1, current + delta), pageCount))
    }

    /// Turns Auto back on. Live, tracking carries on from the slide shown (a manual correction
    /// already became the current slide), so nothing jumps.
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

    /// When a takeaway first covers `page`; nil when none does.
    private func firstTime(forSlide page: Int) -> TimeInterval? {
        takeaways.first { $0.slidePages.contains(page) }?.start
    }

    // MARK: - Decks

    /// Each deck's stretch of the combined slide numbers (deck boundaries in the Slides column).
    var deckSpans: [DeckSpan] { session.deckSpans }
    /// Files being prepared to join the lecture (converting, reading), by display name.
    private(set) var decksBeingAdded: [String] = []
    /// Deck operations run one after another, so their commits never interleave.
    private var deckTask: Task<Void, Never>?
    /// Bumped by every deck commit; work started for an older one stops at its next step.
    private var deckRevision = 0

    /// File extensions the lecture accepts as decks (PDF, plus PowerPoint/Keynote when available).
    var acceptedDeckExtensions: Set<String> { DeckIntake.acceptedExtensions(services) }

    /// Shows the open panel for adding decks ("Add Deck…").
    func chooseDecks() {
        DeckIntake.choose(extensions: acceptedDeckExtensions, multiple: true, message: "Choose slide decks to add to “\(title)”.") { [weak self] urls in
            self?.addDecks(urls: urls)
        }
    }

    /// Adds decks after the existing ones (chosen or dropped; PowerPoint/Keynote files are
    /// converted first), live or in Review. Each reaches the session, the saved lecture, the slide
    /// images, slide tracking, jargon fixing and the brain together.
    func addDecks(urls: [URL]) {
        guard !urls.isEmpty else { return }
        decksBeingAdded += urls.map(\.lastPathComponent)
        enqueueDeckWork { model in
            for url in urls {
                await model.addDeck(url)
                model.decksBeingAdded.removeFirst(min(1, model.decksBeingAdded.count))
            }
        }
    }

    /// Removes the deck at `index` (its PDF is deleted once nothing shows it).
    func removeDeck(at index: Int) {
        enqueueDeckWork { model in
            guard model.session.decks.indices.contains(index) else { return }
            var decks = model.session.decks
            let removed = decks.remove(at: index)
            await model.commitDecks(decks)
            // Delete the file only once the lecture saved without it.
            guard !model.session.decks.contains(where: { $0.fileName == removed.fileName }), !model.isDiscarded else { return }
            await model.flush()
            do { try await model.services.store.removeSlides(named: removed.fileName, from: model.id) } catch {
                model.push(Notice(id: "deck-remove", kind: .warning, symbol: "exclamationmark.triangle", title: "Couldn't delete the removed deck's file: \(error.localizedDescription)", placement: .takeaways, actionLabel: nil))
            }
        }
    }

    /// Moves the deck at `index` by `offset` places (−1 earlier, +1 later).
    func moveDeck(at index: Int, by offset: Int) {
        enqueueDeckWork { model in
            var decks = model.session.decks
            let target = index + offset
            guard decks.indices.contains(index), decks.indices.contains(target) else { return }
            decks.swapAt(index, target)
            await model.commitDecks(decks)
        }
    }

    /// Runs `work` after the deck work already queued. Cancelling the queue's last task (close,
    /// delete) cancels everything queued before it too.
    private func enqueueDeckWork(_ work: @escaping @MainActor (LiveSessionModel) async -> Void) {
        let previous = deckTask
        deckTask = Task { [weak self] in
            await withTaskCancellationHandler { await previous?.value } onCancel: { previous?.cancel() }
            guard let self, !Task.isCancelled, !isDiscarded else { return }
            await work(self)
        }
    }

    /// Prepares `url`, copies it into the lecture's folder under a name of its own, then commits.
    private func addDeck(_ url: URL) async {
        do {
            let prepared = try await DeckIntake.prepare(url, services: services)
            defer { prepared.dispose() }
            try Task.checkCancellation()
            guard !isDiscarded else { return }
            var deck = prepared.deck
            deck.fileName = try await services.store.importSlides(from: prepared.pdf, into: id)
            guard !Task.isCancelled, !isDiscarded else {
                try? await services.store.removeSlides(named: deck.fileName, from: id)
                return
            }
            await commitDecks(session.decks + [deck])
            reportMissingText(deck)
        } catch is CancellationError {
        } catch {
            push(Notice(id: "deck", kind: .warning, symbol: "exclamationmark.triangle", title: "Couldn't add “\(url.lastPathComponent)”: \(error.localizedDescription)", placement: .takeaways, actionLabel: nil))
        }
    }

    /// Audit B43: slides OCR couldn't read are said, not hidden behind a successful import.
    private func reportMissingText(_ deck: SlideDeck) {
        let missing = deck.pagesMissingText
        guard !missing.isEmpty else { return }
        let list = missing.prefix(6).map(String.init).joined(separator: ", ") + (missing.count > 6 ? "…" : "")
        push(Notice(id: "deck-ocr", kind: .warning, symbol: "text.viewfinder", title: "Couldn't read the text of \(missing.count == 1 ? "slide" : "slides") \(list) in “\(deck.originalFileName)”: they won't be searched or followed", placement: .takeaways, actionLabel: nil))
    }

    /// Makes `decks` the lecture's decks, as one step: stored slide references and the slide state
    /// shown here are renumbered (see `LectureSession.replaceDecks`), the images, the slide index
    /// and the brain switch to the new decks, and the lecture is handed to the autosaver at once
    /// (also in Review, which has no recording clock to save it, audit B06).
    private func commitDecks(_ decks: [SlideDeck]) async {
        guard !isDiscarded, !Task.isCancelled else { return }
        deckRevision += 1
        let revision = deckRevision
        let hadDecks = !session.decks.isEmpty
        let oldPageCount = session.decks.reduce(0) { $0 + $1.pages.count }
        let map = session.replaceDecks(with: decks)
        let renumbered = map.count != oldPageCount || map.contains { $0.key != $0.value }
        remapSlideState(map, hadDecks: hadDecks)
        markDirty()
        saveIfDirty()
        // `folder(for:)` creates the folder, so never after the lecture was deleted.
        if !isDiscarded, let folder = try? await services.store.folder(for: id), revision == deckRevision {
            slideImages = SlideImageStore(decks: session.decks, folder: folder)
        }
        // A brain still being created indexes the old decks; let it finish, then update it.
        await brainStartTask?.value
        let combined = session.deck
        let index = if let combined { await services.makeSlideIndex(combined) } else { nil as (any SlideSearching)? }
        guard revision == deckRevision, !isDiscarded else { return }
        slideIndex = index
        guard let brain else { return }
        if renumbered {
            // The brain's own takeaways and quiz history still carry the old slide numbers: start
            // a fresh one from the renumbered lecture.
            replaceBrain()
        } else if let combined {
            await brain.attachDeck(combined, slides: index)
            // Adding a deck after the others keeps the lecture's place (attaching starts tracking over).
            if hadDecks, mode == .live, let current = detectedSlide { await brain.setCurrentSlide(current) }
        }
    }

    /// Starts the brain over from the lecture as it is now (after its slides were renumbered).
    private func replaceBrain() {
        updatesTask?.cancel()
        brain = nil
        createBrain()
    }

    /// Setup's deck, ingested before the lecture started, copied into the lecture's folder; a
    /// conversion's temporary PDF is then deleted (audit B28).
    private func storeStartingDeck(from url: URL, conversion: ConvertedPresentation?) async {
        defer { conversion?.dispose() }
        do {
            guard !isDiscarded, !Task.isCancelled else { return }
            let name = try await services.store.importSlides(from: url, into: id)
            guard session.decks.count == 1, !isDiscarded, !Task.isCancelled else {
                try? await services.store.removeSlides(named: name, from: id)
                return
            }
            session.decks[0].fileName = name
            markDirty()
            saveIfDirty()
            // A converted deck's PDF is about to be deleted: show the library copy instead. (Setup's
            // own PDF keeps working, and its images are already rendered.)
            if conversion != nil, let folder = try? await services.store.folder(for: id) {
                slideImages = SlideImageStore(decks: session.decks, folder: folder)
            }
        } catch {
            push(Notice(id: "deck-copy", kind: .warning, symbol: "exclamationmark.triangle", title: "Couldn't copy the deck into the library: \(error.localizedDescription)", placement: .takeaways, actionLabel: nil))
        }
    }

    /// Carries the slide state shown here through a renumbering (`map`: old → new; absent = gone).
    private func remapSlideState(_ map: [Int: Int], hadDecks: Bool) {
        guard hadDecks else {
            if detectedSlide == nil, mode == .review { detectedSlide = 1 }
            return
        }
        detectedSlide = detectedSlide.flatMap { map[$0] }
        manualSlide = manualSlide.flatMap { map[$0] }
        if manualSlide == nil { followSlides = true }
        highlightedSlide = highlightedSlide.flatMap { map[$0] }
        backtrackSuggestion = backtrackSuggestion.flatMap { map[$0] }
        visitedSlides = Set(visitedSlides.compactMap { map[$0] })
        if session.decks.isEmpty { detectedSlide = nil }
    }

    /// The images for a lecture opened from the library.
    private func loadSlideImages() async {
        guard slideImages == nil, !session.decks.isEmpty else { return }
        if let folder = try? await services.store.folder(for: id), slideImages == nil {
            slideImages = SlideImageStore(decks: session.decks, folder: folder)
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

    /// Lands on an open-at request from the Library. The slide goes first (in review a chosen
    /// slide also seeks the transcript to where it was first shown) so an explicit time wins.
    func navigate(to nav: PendingNavigation) {
        guard nav.sessionID == id else { return }
        if nav.slide != nil, pageCount == 0 {
            navigationAfterImagesLoad = nav
            return
        }
        if let slide = nav.slide { showSlide(slide) }
        if let time = nav.time { seekTranscript(to: time) }
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

    /// A question from the brain. It is shown when nothing else is on screen, queued behind the one that
    /// is, and held back (retried in a minute) while the user is typing in Ask or recording is paused.
    private func offer(_ q: QuizQuestion) {
        guard mode == .live, settings.quiz.enabled, q.isWellFormed else { return }
        guard quiz?.question.id != q.id, !queuedQuizzes.contains(where: { $0.id == q.id }) else { return }
        if isTypingInAsk || recordingState != .recording {
            quizTimers.append(Task { [weak self] in
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { return }
                self?.offer(q)
            })
            return
        }
        withAnimation(DS.Motion.quick) { queuedQuizzes.append(q) }
        showNextQuizIfIdle()
    }

    /// Shows the next queued question as the card, unless one is already showing or the user chose the
    /// toolbar badge (Quiet style, or a pane where a card would be out of place); then it waits for a tap.
    private func showNextQuizIfIdle() {
        guard quiz == nil, !queuedQuizzes.isEmpty else { return }
        // `pane` only matters in the single-pane tier; wider tiers always show the Takeaways.
        let quietTier = layoutTier == .single && pane != .takeaways
        guard preferences.quizStyle != .badge, !quietTier else { return }
        openPendingQuiz()
    }

    /// Opens the next waiting question (the toolbar badge, Quiet style / narrow tier).
    func openPendingQuiz() {
        guard quiz == nil, !queuedQuizzes.isEmpty else { return }
        let q = withAnimation(DS.Motion.quick) { queuedQuizzes.removeFirst() }
        present(q)
    }

    private func present(_ q: QuizQuestion) {
        withAnimation(DS.Motion.float) {
            quiz = ActiveQuiz(question: q)
        }
        if !session.quiz.contains(where: { $0.id == q.id }) {
            session.quiz.append(QuizRecord(question: q, askedAt: elapsed))
        }
        announce("Quick check: \(q.prompt)")
        markDirty()
    }

    func selectOption(_ index: Int) {
        guard var active = quiz, active.acceptsAnswers else { return }
        active.selectedOption = index
        quiz = active
        let questionID = active.activeQuestion.id
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            // The card may have been skipped (and the next question shown) in the meantime.
            guard self?.quiz?.activeQuestion.id == questionID else { return }
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
            do {
                let grade = try await brain.grade(question, answer: answer)
                guard let self, var active = self.quiz, active.activeQuestion.id == question.id else { return }
                let record = self.recordOutcome(question: question, answer: answer, grade: grade)
                if isFollowUp, case .gradingFollowUp(let first, let f) = active.phase {
                    if grade.isCorrect { self.streak += 1 }
                    active.phase = .followUpResult(first, followUp: f, result: grade)
                    withAnimation(DS.Motion.settle) { self.quiz = active }
                    self.announce(grade.isCorrect ? "Correct" : "Not quite")
                    return
                }
                if grade.isCorrect {
                    self.streak += 1
                    active.phase = .correct(grade)
                    withAnimation(DS.Motion.settle) { self.quiz = active }
                    self.announce("Correct")
                } else {
                    self.streak = 0
                    active.phase = .wrong(grade, followUp: nil, followUpPending: wantsFollowUp)
                    active.selectedOption = nil
                    withAnimation(DS.Motion.settle) { self.quiz = active }
                    self.announce("Not quite. \(grade.feedback)")
                    if wantsFollowUp {
                        // The brain words the follow-up around what the student answered, so it must
                        // have the record first (the fire-and-forget copy may not have arrived yet).
                        await brain.record(record)
                        let f = try? await brain.makeQuestion(followUpOf: question)
                        guard var again = self.quiz, again.activeQuestion.id == question.id else { return }
                        var followUpQuestion = f
                        followUpQuestion?.followUpOf = question.id
                        again.phase = .wrong(grade, followUp: followUpQuestion, followUpPending: false)
                        withAnimation(DS.Motion.float) { self.quiz = again }
                        if let followUpQuestion {
                            self.session.quiz.append(QuizRecord(question: followUpQuestion, askedAt: self.elapsed))
                        }
                    }
                }
            } catch {
                guard let self else { return }
                self.push(Notice(id: "grade", kind: .warning, symbol: "exclamationmark.triangle", title: "Couldn't grade: \(error.localizedDescription)", placement: .takeaways, actionLabel: nil))
                // The question stays up so the user can answer again; nothing is recorded for it yet.
                guard var failed = self.quiz, failed.activeQuestion.id == question.id else { return }
                switch failed.phase {
                case .grading: failed.phase = .asking
                case .gradingFollowUp(let first, let f): failed.phase = .wrong(first, followUp: f, followUpPending: false)
                default: return
                }
                failed.selectedOption = nil
                withAnimation(DS.Motion.settle) { self.quiz = failed }
            }
        }
    }

    @discardableResult
    private func recordOutcome(question: QuizQuestion, answer: String?, grade: QuizGrade?, outcome: QuizOutcome? = nil) -> QuizRecord {
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
        return snapshot
    }

    /// Puts the question away for five minutes (it is not recorded as skipped), then offers it again.
    func snoozeQuiz() {
        guard let active = quiz, active.phase == .asking else { return }
        let q = active.question
        session.quiz.removeAll { $0.id == q.id }
        withAnimation(DS.Motion.float) { quiz = nil }
        quizTimers.append(Task { [weak self] in
            try? await Task.sleep(for: .seconds(300))
            guard !Task.isCancelled else { return }
            self?.offer(q)
        })
        showNextQuizIfIdle()
    }

    /// Closes the card on the user's say-so (Skip, Esc, or the ✕ on a result). An unanswered question is
    /// recorded as skipped; the next queued one, if any, takes its place.
    func skipQuiz() {
        guard let active = quiz else { return }
        if active.phase == .asking {
            recordOutcome(question: active.question, answer: nil, grade: nil, outcome: .skipped)
        } else if case .wrong(_, let f?, _) = active.phase {
            recordOutcome(question: f, answer: nil, grade: nil, outcome: .skipped)
        }
        withAnimation(DS.Motion.float) { quiz = nil }
        showNextQuizIfIdle()
    }

    /// The lecture is ending: the card closes and questions that were never shown are dropped (they have
    /// no record, so nothing is lost from the quiz history).
    private func closeQuizzesForFinish() {
        quizTimers.forEach { $0.cancel() }
        quizTimers = []
        withAnimation(DS.Motion.float) { queuedQuizzes = [] }
        skipQuiz()
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
        reviewFlow?.error = nil
        Task { [weak self] in
            do {
                guard let brain = await self?.readyBrain() else { return }
                let q = try await brain.makeQuestion(followUpOf: current.record.question)
                guard let self, self.reviewFlow?.current?.id == current.id else { return }
                withAnimation(DS.Motion.settle) { self.reviewFlow?.freshQuestion = q }
            } catch is CancellationError {
            } catch {
                guard let self, self.reviewFlow?.current?.id == current.id else { return }
                withAnimation(DS.Motion.settle) { self.reviewFlow?.error = Self.friendly(error) }
            }
        }
    }

    /// "Try again" after a failure: writes the question again, or checks the same answer again.
    func reviewRetry(answer: String) {
        guard let flow = reviewFlow else { return }
        if flow.freshQuestion == nil { loadFreshQuestion() } else { reviewSubmit(answer: flow.freshSelected.map(String.init) ?? answer) }
    }

    func reviewSelect(_ index: Int) {
        // A key press can arrive while the last answer is still being checked (or already was).
        guard let flow = reviewFlow, flow.freshQuestion != nil, !flow.isGrading, flow.freshGrade == nil else { return }
        reviewFlow?.freshSelected = index
        reviewSubmit(answer: "\(index)")
    }

    func reviewSubmit(answer: String) {
        guard var flow = reviewFlow, let q = flow.freshQuestion, !flow.isGrading, flow.freshGrade == nil, let brain else { return }
        flow.isGrading = true
        flow.error = nil
        reviewFlow = flow
        Task { [weak self] in
            do {
                let grade = try await brain.grade(q, answer: answer)
                guard let self, self.reviewFlow?.freshQuestion?.id == q.id else { return }
                withAnimation(DS.Motion.settle) {
                    self.reviewFlow?.isGrading = false
                    self.reviewFlow?.freshGrade = grade
                }
            } catch is CancellationError {
            } catch {
                guard let self, self.reviewFlow?.freshQuestion?.id == q.id else { return }
                withAnimation(DS.Motion.settle) {
                    self.reviewFlow?.isGrading = false
                    self.reviewFlow?.error = Self.friendly(error)
                }
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
        flow.error = nil
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
        // The clock raises "silence" again at once if audio is still missing; dismissing it means "not
        // for another 20 s".
        if id == "silence" { lastAudioAt = .now }
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
        // Deck work copies files into the lecture's folder: stop it before the folder goes.
        deckTask?.cancel()
        await deckTask?.value
        await handoff?.value
        await autosaver.discard()
    }

    /// A finished lecture with nothing running: safe to close when it leaves the screen.
    var isIdle: Bool {
        mode == .review && recordingState == .finished && summaryState != .writing && !isAnswering && !isBusy
            && recap == nil && reviewFlow == nil && !isFocusPanelOpen && decksBeingAdded.isEmpty
    }

    /// Saves, then stops everything this model started (the brain and its update loop, timers) so
    /// the model can be released. Called when a review lecture leaves the screen.
    func close() async {
        await flush()
        for task in [askTask, recapTask, highlightTask, saveTask, updatesTask, clockTask, engineTask, brainStartTask, deckTask, enrichTask] {
            task?.cancel()
        }
        quizTimers.forEach { $0.cancel() }
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
