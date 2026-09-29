import CoreAudio
import Foundation
import LecternCore

/// Thin, typed wrappers over the CoreAudio HAL property API.
enum CoreAudioDevices {
    private static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func read<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, as type: T.Type, default value: T) -> T? {
        var address = address(selector, scope: scope)
        var result = value
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &result) {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
        }
        return status == noErr ? result : nil
    }

    private static func readString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
        }
        return status == noErr ? value?.takeRetainedValue() as String? : nil
    }

    /// Every audio device known to the HAL.
    static func allDeviceIDs() -> [AudioDeviceID] {
        var address = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr,
              size > 0
        else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids
    }

    /// True when the device exposes at least one input channel.
    static func hasInput(_ device: AudioDeviceID) -> Bool {
        var address = address(kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return false }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw) == noErr else { return false }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.contains { $0.mNumberChannels > 0 }
    }

    static func uid(of device: AudioDeviceID) -> String? { readString(device, kAudioDevicePropertyDeviceUID) }
    static func name(of device: AudioDeviceID) -> String? { readString(device, kAudioObjectPropertyName) }

    static func defaultInputDevice() -> AudioDeviceID? {
        guard let id = read(
            AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice,
            as: AudioDeviceID.self, default: 0
        ), id != kAudioObjectUnknown else { return nil }
        return id
    }

    /// Translates a persisted device UID to the current session's `AudioDeviceID`, or nil if the
    /// device is not connected.
    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        var address = address(kAudioHardwarePropertyTranslateUIDToDevice)
        var cfUID = uid as CFString
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafeMutablePointer(to: &cfUID) { uidPointer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address,
                UInt32(MemoryLayout<CFString>.size), uidPointer, &size, &device
            )
        }
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }
}

/// Lists the Mac's audio input devices.
public struct CoreAudioDeviceProvider: AudioDeviceProviding {
    public init() {}

    /// Input-capable devices, the system default first, then alphabetically.
    public func inputDevices() -> [AudioInputDevice] {
        let defaultID = CoreAudioDevices.defaultInputDevice()
        return CoreAudioDevices.allDeviceIDs()
            .filter(CoreAudioDevices.hasInput)
            .compactMap { id -> AudioInputDevice? in
                guard let uid = CoreAudioDevices.uid(of: id) else { return nil }
                return AudioInputDevice(id: uid, name: CoreAudioDevices.name(of: id) ?? uid, isDefault: id == defaultID)
            }
            .sorted { lhs, rhs in
                if lhs.isDefault != rhs.isDefault { return lhs.isDefault }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }
}
