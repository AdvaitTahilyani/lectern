import AVFoundation
import Foundation
import Testing
@testable import LecternTranscription

@Suite("Audio support")
struct SupportTests {
    @Test func silenceMetersZero() {
        var meter = LevelMeter()
        let levels = meter.feed([Float](repeating: 0, count: 16_000))
        #expect(levels.count == 20)
        #expect(levels.allSatisfy { $0 == 0 })
    }

    @Test func loudSignalMetersNearOneWithSmoothing() {
        var meter = LevelMeter()
        let omega = 2 * Double.pi * 440 / 16_000
        var tone = [Float]()
        for index in 0..<16_000 { tone.append(Float(0.5 * sin(omega * Double(index)))) }
        let levels = meter.feed(tone)
        #expect(levels.count == 20)
        #expect(levels[0] > 0 && levels[0] < levels[19])       // attack is smoothed, not instant
        #expect(levels[19] > 0.9 && levels[19] <= 1)
    }

    @Test func meterReleasesSlowerThanItAttacks() {
        var meter = LevelMeter()
        _ = meter.feed([Float](repeating: 0.5, count: 16_000))
        let decay = meter.feed([Float](repeating: 0, count: 1_600))
        #expect(decay.count == 2)
        #expect(decay[0] < 1 && decay[0] > 0.5)
        #expect(decay[1] < decay[0])
    }

    @Test func meterEmitsAcrossBufferBoundaries() {
        var meter = LevelMeter()
        var emitted = 0
        for _ in 0..<10 { emitted += meter.feed([Float](repeating: 0.1, count: 480)).count }
        #expect(emitted == 6)   // 4800 samples = 6 windows of 800
    }

    @Test func wordBuilderHandlesBothBoundaryMarkers() {
        var builder = WordBuilder()
        builder.append([
            RecognizedToken(text: "\u{2581}Hel", start: 0, end: 0.1),
            RecognizedToken(text: "lo", start: 0.1, end: 0.2),
            RecognizedToken(text: ",", start: 0.2, end: 0.3),
            RecognizedToken(text: " world", start: 0.4, end: 0.6),
            RecognizedToken(text: "<blank>", start: 0.6, end: 0.7),
        ])
        #expect(builder.words.map(\.text) == ["Hello,", "world"])
        #expect(builder.words[0].end == 0.3)
    }

    @Test func aBareWordMarkerStartsTheNextWordEvenAcrossUpdates() {
        var builder = WordBuilder()
        builder.append([RecognizedToken(text: " in", start: 0, end: 0.2), RecognizedToken(text: " ", start: 0.2, end: 0.3)])
        builder.append([RecognizedToken(text: "1", start: 0.3, end: 0.4), RecognizedToken(text: "9", start: 0.4, end: 0.5)])
        #expect(builder.words.map(\.text) == ["in", "19"])
        #expect(builder.words[1].start == 0.3)
    }

    @Test func resamplerConvertsToSixteenKilohertzMono() throws {
        let source = AVAudioFormatFactory.make(sampleRate: 48_000, channels: 2)
        let resampler = try MonoResampler(from: source)
        var total = 0
        for _ in 0..<10 {
            let buffer = AVAudioFormatFactory.buffer(source, frames: 4_800, value: 0.25)
            let samples = try resampler.convert(buffer)
            total += samples.count
            #expect(samples.allSatisfy { abs($0) < 0.3 })
        }
        total += try resampler.flush().count
        #expect(abs(total - 16_000) <= 64)   // 1 s in, 1 s out (minus resampler latency)
    }

    @Test func resamplerPassesThroughSixteenKilohertzMono() throws {
        let format = AVAudioFormatFactory.make(sampleRate: 16_000, channels: 1)
        let resampler = try MonoResampler(from: format)
        let samples = try resampler.convert(AVAudioFormatFactory.buffer(format, frames: 1_600, value: 0.5))
        #expect(samples.count == 1_600)
        #expect(samples.allSatisfy { $0 == 0.5 })
    }

    @Test func multiChannelInputUsesFirstChannel() throws {
        let format = AVAudioFormatFactory.make(sampleRate: 16_000, channels: 4)
        let resampler = try MonoResampler(from: format)
        let samples = try resampler.convert(AVAudioFormatFactory.buffer(format, frames: 800, value: 0.5))
        #expect(samples.count == 800)
        #expect(samples.allSatisfy { $0 == 0.5 })
    }
}
