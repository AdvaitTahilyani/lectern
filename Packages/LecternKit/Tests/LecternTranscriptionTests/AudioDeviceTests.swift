import AVFoundation
import CoreAudio
import Foundation
import Testing
@testable import LecternTranscription

@Suite("Audio devices")
struct AudioDeviceTests {
    @Test func inputDevicesAreListedWithOneDefaultFirst() {
        let devices = CoreAudioDeviceProvider().inputDevices()
        // CI machines may have no microphone; when there is one, the invariants must hold.
        guard !devices.isEmpty else { return }
        #expect(devices.filter(\.isDefault).count <= 1)
        if let defaultIndex = devices.firstIndex(where: \.isDefault) { #expect(defaultIndex == 0) }
        #expect(Set(devices.map(\.id)).count == devices.count, "UIDs are unique")
        #expect(devices.allSatisfy { !$0.name.isEmpty && !$0.id.isEmpty })
    }

    @Test func deviceUIDsRoundTripToDeviceIDs() {
        for device in CoreAudioDeviceProvider().inputDevices() {
            let id = CoreAudioDevices.deviceID(forUID: device.id)
            #expect(id != nil)
            #expect(id.flatMap(CoreAudioDevices.uid(of:)) == device.id)
            #expect(id.map(CoreAudioDevices.hasInput) == true)
        }
    }

    @Test func unknownUIDIsNotFound() {
        #expect(CoreAudioDevices.deviceID(forUID: "no-such-device-uid") == nil)
    }
}

/// Exercises the device-selection path up to (but not including) starting the engine, which needs
/// microphone permission a command-line test process cannot obtain.
@Suite("Microphone setup dry run")
struct MicrophoneDryRunTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LECTERN_LIVE_TESTS"] == "1"))
    func selectingEachInputDeviceYieldsAUsableFormat() throws {
        let devices = CoreAudioDeviceProvider().inputDevices()
        print("=== LIVE input devices: \(devices.map { "\($0.name) [\($0.id)]\($0.isDefault ? " (default)" : "")" })")
        for device in devices {
            let engine = AVAudioEngine()
            let node = engine.inputNode
            let id = try #require(CoreAudioDevices.deviceID(forUID: device.id))
            try AudioCapture.select(id, on: node)
            let format = node.outputFormat(forBus: 0)
            print("=== LIVE \(device.name): \(format.sampleRate) Hz, \(format.channelCount) ch")
            #expect(format.sampleRate > 0 && format.channelCount > 0)
            let resampler = try MonoResampler(from: format)
            _ = resampler
            engine.prepare()
        }
    }
}
