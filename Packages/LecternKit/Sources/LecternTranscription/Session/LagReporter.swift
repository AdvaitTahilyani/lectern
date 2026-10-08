import Foundation

/// Turns the live backlog's size into user-facing warnings: once when recognition falls
/// noticeably behind the room, again each time the delay doubles, once when it has caught up, and
/// when audio had to be skipped because the backlog was full (with a running total).
struct LagReporter {
    /// Backlog at which the first "behind" warning is sent.
    let warnAfter: TimeInterval
    /// Backlog under which a warned lag counts as caught up.
    let caughtUpBelow: TimeInterval

    private var announced: TimeInterval?
    private var totalSkipped: TimeInterval = 0
    private var nextSkipReport: TimeInterval = 1

    init(warnAfter: TimeInterval = 15, caughtUpBelow: TimeInterval = 3) {
        self.warnAfter = warnAfter
        self.caughtUpBelow = caughtUpBelow
    }

    /// Feeds the current backlog and the audio skipped since the last call; returns the warnings
    /// to send, if any.
    mutating func update(lag: TimeInterval, skipped: TimeInterval) -> [String] {
        var messages: [String] = []
        totalSkipped += skipped
        if totalSkipped >= nextSkipReport {
            // Overload drops audio continuously; report the running total, less and less often.
            messages.append("Transcription can't keep up: skipped \(Self.seconds(totalSkipped)) of audio so far.")
            nextSkipReport = max(totalSkipped * 2, totalSkipped + 30)
        }
        if let last = announced {
            if lag < caughtUpBelow {
                announced = nil
                messages.append("Transcription has caught up.")
            } else if lag >= last * 2 {
                announced = lag
                messages.append("Transcription is running \(Self.seconds(lag)) behind.")
            }
        } else if lag >= warnAfter {
            announced = lag
            messages.append("Transcription is running \(Self.seconds(lag)) behind.")
        }
        return messages
    }

    private static func seconds(_ t: TimeInterval) -> String {
        let s = Int(t.rounded())
        return s >= 120 ? "\(s / 60) min" : "\(s) s"
    }
}
