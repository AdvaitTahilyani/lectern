import Foundation
import LecternCore

/// Decides who is talking in each finalized transcript segment.
///
/// Diarizer tracks are anonymous, so the tracker maps them to lecture roles: the track with the
/// most cumulative speech is the lecturer; every other track is an audience member, numbered by
/// when it was first heard. The mapping is re-evaluated as speech accumulates, and labels already
/// handed out are re-issued when it changes (for example when the lecturer track is only
/// established a minute into the session).
///
/// A segment is labeled once the diarizer has processed past its end, with the track that
/// overlaps it most. Pure value type; all times are stream seconds.
struct SpeakerLabelTracker {
    struct Configuration: Sendable {
        /// A challenger replaces the current lecturer only with this much more speech.
        var lecturerSwitchRatio = 1.2
        /// Segments with no diarized speech inside them use a turn this close, if any.
        var nearestTurnTolerance: TimeInterval = 1.5
        /// A non-lecturer track must be heard this long inside a segment to claim it; briefer
        /// blips (common at the start of a session and on short utterances) count as the lecturer.
        var minAudienceEvidence: TimeInterval = 1.0
        /// Turns are kept this long behind the oldest unlabeled segment.
        var retention: TimeInterval = 120
    }

    private struct Pending {
        var id: UUID
        var range: ClosedRange<TimeInterval>
    }

    private let configuration: Configuration
    private var turns: [SpeakerTurn] = []
    private var speechTotals: [Int: TimeInterval] = [:]
    private var pending: [Pending] = []
    /// The raw track chosen for each labeled segment, with how long it is heard inside it.
    private var assigned: [UUID: (speaker: Int, evidence: TimeInterval)] = [:]
    /// Earliest start of a segment firmly claimed by each raw track; orders audience indexes.
    private var firstHeard: [Int: TimeInterval] = [:]
    private var lecturer: Int?
    private var through: TimeInterval = 0
    private var issued: [UUID: SpeakerRole] = [:]

    init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// Registers a finalized segment to be labeled once the diarizer catches up.
    mutating func register(id: UUID, start: TimeInterval, end: TimeInterval) {
        pending.append(Pending(id: id, range: start...max(start, end)))
    }

    /// Feeds diarizer output. Returns the labels that are new or changed.
    mutating func advance(_ progress: DiarizationProgress) -> [UUID: SpeakerRole] {
        through = max(through, progress.through)
        for turn in progress.turns where turn.duration > 0 {
            turns.append(turn)
            speechTotals[turn.speaker, default: 0] += turn.duration
        }
        return label(through: progress.through)
    }

    /// The diarizer's recent output, for cutting transcript segments at speaker changes.
    func activity(since start: TimeInterval) -> SpeakerActivity {
        SpeakerActivity(turns: turns.filter { $0.end >= start }, through: through)
    }

    /// Labels everything still waiting, using whatever the diarizer produced.
    mutating func flush() -> [UUID: SpeakerRole] {
        label(through: .infinity)
    }

    // MARK: - Labeling

    private mutating func label(through: TimeInterval) -> [UUID: SpeakerRole] {
        updateLecturer()

        var stillPending: [Pending] = []
        for item in pending {
            guard item.range.upperBound <= through else {
                stillPending.append(item)
                continue
            }
            if let choice = dominantSpeaker(in: item.range) {
                assigned[item.id] = choice
                if choice.evidence >= configuration.minAudienceEvidence {
                    firstHeard[choice.speaker] = min(firstHeard[choice.speaker] ?? .infinity, item.range.lowerBound)
                }
            }
        }
        pending = stillPending
        pruneTurns(through: through)

        // The mapping can change with every update (lecturer switch, new audience member), which
        // relabels segments that were issued earlier. Diff the full assignment against what was sent.
        let mapping = roleMapping()
        var changes: [UUID: SpeakerRole] = [:]
        for (id, choice) in assigned {
            guard let role = role(for: choice, mapping: mapping), issued[id] != role else { continue }
            issued[id] = role
            changes[id] = role
        }
        return changes
    }

    private mutating func updateLecturer() {
        guard let leader = speechTotals.max(by: { $0.value < $1.value }) else { return }
        guard let current = lecturer else {
            lecturer = leader.key
            return
        }
        if leader.key != current,
           leader.value > (speechTotals[current] ?? 0) * configuration.lecturerSwitchRatio {
            lecturer = leader.key
        }
    }

    private func role(for choice: (speaker: Int, evidence: TimeInterval), mapping: [Int: SpeakerRole]) -> SpeakerRole? {
        if choice.speaker != lecturer, choice.evidence < configuration.minAudienceEvidence, lecturer != nil {
            return .lecturer
        }
        return mapping[choice.speaker]
    }

    /// Raw track -> role, for tracks that firmly claimed at least one segment.
    private func roleMapping() -> [Int: SpeakerRole] {
        var mapping: [Int: SpeakerRole] = [:]
        let audience = firstHeard.keys
            .filter { $0 != lecturer }
            .sorted { (firstHeard[$0] ?? 0, $0) < (firstHeard[$1] ?? 0, $1) }
        for (offset, speaker) in audience.enumerated() { mapping[speaker] = .audience(index: offset + 1) }
        if let lecturer { mapping[lecturer] = .lecturer }
        return mapping
    }

    private func dominantSpeaker(in range: ClosedRange<TimeInterval>) -> (speaker: Int, evidence: TimeInterval)? {
        var overlap: [Int: TimeInterval] = [:]
        for turn in turns where turn.end > range.lowerBound && turn.start < range.upperBound {
            overlap[turn.speaker, default: 0] += turn.overlap(with: range)
        }
        if let best = overlap.filter({ $0.value > 0 }).max(by: { ($0.value, -$0.key) < ($1.value, -$1.key) }) {
            return (best.key, best.value)
        }
        // No speech detected inside the segment: fall back to the closest turn nearby.
        let tolerance = configuration.nearestTurnTolerance
        let nearest = turns.min { distance($0, range) < distance($1, range) }
        if let nearest, distance(nearest, range) <= tolerance { return (nearest.speaker, 0) }
        return nil
    }

    private func distance(_ turn: SpeakerTurn, _ range: ClosedRange<TimeInterval>) -> TimeInterval {
        if turn.end < range.lowerBound { return range.lowerBound - turn.end }
        if turn.start > range.upperBound { return turn.start - range.upperBound }
        return 0
    }

    /// Drops turns no unlabeled segment can still need. Speech totals are kept separately.
    private mutating func pruneTurns(through: TimeInterval) {
        let horizon = min(pending.map(\.range.lowerBound).min() ?? through, through) - configuration.retention
        guard horizon.isFinite, let first = turns.first, first.end < horizon else { return }
        turns.removeAll { $0.end < horizon }
    }
}
