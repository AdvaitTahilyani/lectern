import Foundation

/// A stretch of speech attributed to one diarizer output track ("raw speaker") on the stream clock.
/// Long utterances arrive as several adjacent pieces (one per processed audio chunk).
struct SpeakerTurn: Sendable, Hashable {
    /// The diarizer's track index. Identity is local to the recording and says nothing about roles.
    var speaker: Int
    var start: TimeInterval
    var end: TimeInterval

    var duration: TimeInterval { max(0, end - start) }

    func overlap(with range: ClosedRange<TimeInterval>) -> TimeInterval {
        max(0, min(end, range.upperBound) - max(start, range.lowerBound))
    }
}

/// New diarizer output: turns for the audio processed since the previous update.
struct DiarizationProgress: Sendable {
    var turns: [SpeakerTurn]
    /// Stream time up to which the diarizer is done (all turns before it have been reported).
    var through: TimeInterval
}

extension SpeakerTurn {
    /// Converts frame-level speaker probabilities (frame-major, `speakerCount` values per frame)
    /// into turns. Consecutive active frames of one speaker form a run; each speaker gets separate
    /// runs, so overlapped speech yields overlapping turns.
    /// - Parameters:
    ///   - firstFrame: index of the first frame in `probabilities` on the stream timeline.
    static func runs(
        probabilities: [Float], speakerCount: Int, firstFrame: Int, frameDuration: TimeInterval, threshold: Float = 0.5
    ) -> [SpeakerTurn] {
        guard speakerCount > 0 else { return [] }
        let frames = probabilities.count / speakerCount
        var turns: [SpeakerTurn] = []
        for speaker in 0..<speakerCount {
            var runStart: Int?
            for frame in 0...frames {
                let active = frame < frames && probabilities[frame * speakerCount + speaker] >= threshold
                if active, runStart == nil {
                    runStart = frame
                } else if !active, let start = runStart {
                    turns.append(SpeakerTurn(
                        speaker: speaker,
                        start: Double(firstFrame + start) * frameDuration,
                        end: Double(firstFrame + frame) * frameDuration
                    ))
                    runStart = nil
                }
            }
        }
        return turns.sorted { ($0.start, $0.speaker) < ($1.start, $1.speaker) }
    }
}

/// What the diarizer has reported so far, for consumers that want to cut segments at speaker changes.
struct SpeakerActivity: Sendable {
    var turns: [SpeakerTurn]
    /// Stream time up to which the diarizer is done.
    var through: TimeInterval

    /// The track with the most speech inside `range`, if it covers at least `minimumFraction` of it.
    func dominantSpeaker(in range: ClosedRange<TimeInterval>, minimumFraction: Double = 0.4) -> Int? {
        var overlap: [Int: TimeInterval] = [:]
        for turn in turns where turn.end > range.lowerBound && turn.start < range.upperBound {
            overlap[turn.speaker, default: 0] += turn.overlap(with: range)
        }
        let length = max(range.upperBound - range.lowerBound, 0.05)
        guard let best = overlap.max(by: { ($0.value, -$0.key) < ($1.value, -$1.key) }),
              best.value >= length * minimumFraction else { return nil }
        return best.key
    }
}
