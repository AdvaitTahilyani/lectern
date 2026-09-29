import Foundation
import LecternCore
import Testing
@testable import LecternTranscription

@Suite("SpeakerTurn")
struct SpeakerTurnTests {
    @Test func runsSplitPerSpeakerAndHonorFrameOffset() {
        // 6 frames, 2 speakers (frame-major): speaker 0 active in frames 0-2, speaker 1 in frames 2-3.
        let probabilities: [Float] = [
            0.9, 0.1,
            0.8, 0.2,
            0.7, 0.6,
            0.2, 0.9,
            0.1, 0.1,
            0.1, 0.1,
        ]
        let turns = SpeakerTurn.runs(probabilities: probabilities, speakerCount: 2, firstFrame: 10, frameDuration: 0.08)
        #expect(turns.count == 2)
        #expect(turns[0].speaker == 0)
        #expect(abs(turns[0].start - 0.8) < 1e-9 && abs(turns[0].end - 1.04) < 1e-9)
        #expect(turns[1].speaker == 1)
        #expect(abs(turns[1].start - 0.96) < 1e-9 && abs(turns[1].end - 1.12) < 1e-9)   // overlaps speaker 0
    }

    @Test func runActiveUntilLastFrameIsClosed() {
        let turns = SpeakerTurn.runs(probabilities: [0.1, 0.9, 0.9], speakerCount: 1, firstFrame: 0, frameDuration: 0.1)
        #expect(turns.count == 1)
        #expect(abs(turns[0].start - 0.1) < 1e-9 && abs(turns[0].end - 0.3) < 1e-9)
    }
}

@Suite("SpeakerLabelTracker")
struct SpeakerLabelTrackerTests {
    private func progress(_ turns: [(Int, Double, Double)], through: Double) -> DiarizationProgress {
        DiarizationProgress(turns: turns.map { SpeakerTurn(speaker: $0.0, start: $0.1, end: $0.2) }, through: through)
    }

    @Test func labelsWaitUntilDiarizerPassesSegmentEnd() {
        var tracker = SpeakerLabelTracker()
        let id = UUID()
        tracker.register(id: id, start: 0, end: 10)
        #expect(tracker.advance(progress([(2, 0, 6)], through: 6)).isEmpty)
        let labels = tracker.advance(progress([(2, 6, 12)], through: 12))
        #expect(labels == [id: .lecturer])
    }

    @Test func lecturerIsTheTrackWithMostSpeechAndOthersAreNumberedByFirstAppearance() {
        var tracker = SpeakerLabelTracker()
        let lecture = UUID(), question = UUID(), answer = UUID(), otherQuestion = UUID()
        tracker.register(id: lecture, start: 0, end: 30)
        tracker.register(id: question, start: 30, end: 36)
        tracker.register(id: answer, start: 36, end: 60)
        tracker.register(id: otherQuestion, start: 60, end: 66)
        let labels = tracker.advance(progress(
            [(0, 0, 30), (3, 30, 36), (0, 36, 60), (1, 60, 66)], through: 70
        ))
        #expect(labels[lecture] == .lecturer)
        #expect(labels[question] == .audience(index: 1))
        #expect(labels[answer] == .lecturer)
        #expect(labels[otherQuestion] == .audience(index: 2))
    }

    @Test func dominantOverlapDecidesWhenSpeakersShareASegment() {
        var tracker = SpeakerLabelTracker()
        let id = UUID(), filler = UUID()
        tracker.register(id: filler, start: 0, end: 20)
        tracker.register(id: id, start: 20, end: 30)
        // Track 1 speaks 2 s inside the segment, track 0 the other 8 s.
        let labels = tracker.advance(progress([(0, 0, 24), (1, 24, 26), (0, 26, 30)], through: 31))
        #expect(labels[id] == .lecturer)
    }

    @Test func mappingChangeReissuesEarlierLabels() {
        var tracker = SpeakerLabelTracker()
        let first = UUID(), second = UUID()
        tracker.register(id: first, start: 0, end: 5)
        // Track 4 is heard first, briefly, and looks like the lecturer for now.
        var labels = tracker.advance(progress([(4, 0, 5)], through: 6))
        #expect(labels == [first: .lecturer])

        tracker.register(id: second, start: 6, end: 60)
        labels = tracker.advance(progress([(7, 6, 60)], through: 61))
        #expect(labels[second] == .lecturer)               // track 7 now has far more speech
        #expect(labels[first] == .audience(index: 1))      // and the early label is corrected
    }

    @Test func lecturerSwitchNeedsAClearMargin() {
        var tracker = SpeakerLabelTracker()
        let a = UUID(), b = UUID()
        tracker.register(id: a, start: 0, end: 50)
        _ = tracker.advance(progress([(0, 0, 50)], through: 51))
        tracker.register(id: b, start: 50, end: 65)
        // Track 1 talks 55 s vs 50 s: closer than the switch ratio, so the lecturer stays track 0.
        let labels = tracker.advance(progress([(1, 50, 105)], through: 106))
        #expect(labels[b] == .audience(index: 1))
        #expect(labels[a] == nil)
    }

    @Test func briefBlipFromAnotherTrackDoesNotBecomeAudience() {
        var tracker = SpeakerLabelTracker()
        let lecture = UUID(), blip = UUID(), question = UUID()
        tracker.register(id: lecture, start: 0, end: 40)
        tracker.register(id: blip, start: 40, end: 40.8)
        tracker.register(id: question, start: 41, end: 47)
        let labels = tracker.advance(progress([(0, 0, 40), (5, 40, 40.6), (0, 40.6, 41), (5, 41, 47)], through: 50))
        #expect(labels[blip] == .lecturer)                       // 0.6 s of another track: not enough
        #expect(labels[question] == .audience(index: 1))         // 6 s of it: a real speaker
    }

    @Test func unchangedLabelsAreNotReissued() {
        var tracker = SpeakerLabelTracker()
        let id = UUID(), next = UUID()
        tracker.register(id: id, start: 0, end: 4)
        _ = tracker.advance(progress([(0, 0, 4)], through: 5))
        tracker.register(id: next, start: 5, end: 9)
        let labels = tracker.advance(progress([(0, 5, 9)], through: 10))
        #expect(labels == [next: .lecturer])
    }

    @Test func silentSegmentUsesNearbyTurnOrStaysUnlabeled() {
        var tracker = SpeakerLabelTracker()
        let near = UUID(), far = UUID()
        tracker.register(id: near, start: 10.5, end: 11)     // 0.5 s after the turn
        tracker.register(id: far, start: 40, end: 41)        // nothing around
        let labels = tracker.advance(progress([(0, 0, 10)], through: 50))
        #expect(labels[near] == .lecturer)
        #expect(labels[far] == nil)
    }

    @Test func flushLabelsWhatIsLeft() {
        var tracker = SpeakerLabelTracker()
        let id = UUID()
        tracker.register(id: id, start: 0, end: 10)
        _ = tracker.advance(progress([(0, 0, 8)], through: 8))
        #expect(tracker.flush() == [id: .lecturer])
    }
}

@Suite("EventSink")
struct EventSinkTests {
    private func collect(_ stream: AsyncThrowingStream<TranscriptionEvent, Error>) async throws -> [TranscriptionEvent] {
        var events: [TranscriptionEvent] = []
        for try await event in stream { events.append(event) }
        return events
    }

    @Test func speakersFollowTheirFinalsAndUseSessionTimeOffset() async throws {
        let (stream, continuation) = AsyncThrowingStream<TranscriptionEvent, Error>.makeStream()
        let sink = EventSink(continuation: continuation, timeOffset: 100, labelSpeakers: true)
        let segment = TranscriptSegment(text: "hello", start: 101, end: 104, isFinal: true)
        sink.send(.final(segment))
        // Diarizer turns are on the stream clock (no offset).
        sink.diarizationAdvanced(DiarizationProgress(turns: [SpeakerTurn(speaker: 0, start: 1, end: 4)], through: 5))
        sink.finish()

        let events = try await collect(stream)
        #expect(events == [.final(segment), .speakers([segment.id: .lecturer])])
    }

    @Test func noLabelsWhenDiarizationIsOff() async throws {
        let (stream, continuation) = AsyncThrowingStream<TranscriptionEvent, Error>.makeStream()
        let sink = EventSink(continuation: continuation, timeOffset: 0, labelSpeakers: false)
        sink.send(.final(TranscriptSegment(text: "x", start: 0, end: 1, isFinal: true)))
        sink.diarizationAdvanced(DiarizationProgress(turns: [SpeakerTurn(speaker: 0, start: 0, end: 1)], through: 5))
        sink.flushSpeakerLabels()
        sink.finish()
        let events = try await collect(stream)
        #expect(events.count == 1)
    }

    @Test func stopLabelingSilencesLaterLabels() async throws {
        let (stream, continuation) = AsyncThrowingStream<TranscriptionEvent, Error>.makeStream()
        let sink = EventSink(continuation: continuation, timeOffset: 0, labelSpeakers: true)
        sink.send(.final(TranscriptSegment(text: "x", start: 0, end: 1, isFinal: true)))
        sink.stopLabeling()
        sink.diarizationAdvanced(DiarizationProgress(turns: [SpeakerTurn(speaker: 0, start: 0, end: 1)], through: 5))
        sink.finish()
        #expect(try await collect(stream).count == 1)
    }
}
