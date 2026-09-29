import Foundation

/// Turns a 16 kHz sample stream into smoothed 0...1 level readings at 20 Hz for the input meter.
struct LevelMeter: Sendable {
    /// 50 ms of 16 kHz audio per reading.
    static let windowSamples = 800
    /// RMS at or below this maps to 0 (dBFS).
    static let floorDB: Float = -60
    /// RMS at or above this maps to 1 (dBFS).
    static let ceilingDB: Float = -10

    private var sumOfSquares: Double = 0
    private var count = 0
    private var smoothed: Float = 0

    /// Feeds samples; returns one smoothed level for every completed 50 ms window.
    mutating func feed(_ samples: [Float]) -> [Float] {
        var levels: [Float] = []
        for sample in samples {
            sumOfSquares += Double(sample * sample)
            count += 1
            if count == Self.windowSamples {
                levels.append(closeWindow())
            }
        }
        return levels
    }

    private mutating func closeWindow() -> Float {
        let rms = Float((sumOfSquares / Double(count)).squareRoot())
        sumOfSquares = 0
        count = 0
        let decibels = 20 * log10(max(rms, 1e-7))
        let target = min(1, max(0, (decibels - Self.floorDB) / (Self.ceilingDB - Self.floorDB)))
        // Fast attack, slower release: the meter follows syllables without flickering.
        smoothed += (target > smoothed ? 0.6 : 0.2) * (target - smoothed)
        return smoothed
    }
}
