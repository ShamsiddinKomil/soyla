import Foundation
import CoreAudio
import AudioToolbox
import IOKit

/// CoreAudio input-device lookups (F2). Pure queries, no state; safe from any thread.
public enum AudioDevices {
    public struct Input: Equatable, Sendable {
        public var id: AudioDeviceID
        public var name: String
        public var builtIn: Bool
    }

    /// System default input device, or nil when there is none (e.g. a Mac mini without a mic).
    public static func defaultInputID() -> AudioDeviceID? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        let st = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return st == noErr && id != 0 ? id : nil
    }

    /// All devices that have at least one input stream.
    public static func inputs() -> [Input] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.filter(hasInput).map { Input(id: $0, name: name(of: $0) ?? "Unknown input", builtIn: isBuiltIn($0)) }
    }

    /// Make `id` the macOS default input (onboarding device picker; same as choosing it in Sound settings).
    @discardableResult
    public static func setDefaultInput(_ id: AudioDeviceID) -> Bool {
        var dev = id
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
                                          UInt32(MemoryLayout<AudioDeviceID>.size), &dev) == noErr
    }

    public static func builtInInputID() -> AudioDeviceID? { inputs().first { $0.builtIn }?.id }

    /// What kind of input a device is, by name (the pipeline knows only the name it recorded from; flows audit F-05).
    public enum InputKind: Equatable, Sendable { case builtIn, bluetooth, other, unknown }

    public static func kind(named name: String?) -> InputKind {
        guard let name, let id = inputs().first(where: { $0.name == name })?.id else { return .unknown }
        switch transport(id) {
        case kAudioDeviceTransportTypeBuiltIn: return .builtIn
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return .bluetooth
        default: return .other
        }
    }

    /// The lid of a MacBook is closed (`AppleClamshellState` on IOPMrootDomain, read-only). Then its built-in mic is
    /// switched off by the hardware and delivers digital silence. False on Macs without a lid.
    public static func lidClosed() -> Bool {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return false }
        defer { IOObjectRelease(root) }
        let v = IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        return (v as? Bool) ?? false
    }

    static func transport(_ id: AudioDeviceID) -> UInt32 {
        var t: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &t) == noErr ? t : 0
    }

    public static func name(of id: AudioDeviceID) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var cf: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let st = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &cf)
        guard st == noErr, let s = cf?.takeRetainedValue() else { return nil }
        return s as String
    }

    /// Still present and usable (a pinned device can vanish: lid closed, headset unplugged).
    public static func isAlive(_ id: AudioDeviceID) -> Bool {
        var alive: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsAlive,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &alive) == noErr && alive != 0
    }

    static func hasInput(_ id: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                              mScope: kAudioDevicePropertyScopeInput,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr && size > 0
    }

    static func isBuiltIn(_ id: AudioDeviceID) -> Bool {
        var t: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &t) == noErr && t == kAudioDeviceTransportTypeBuiltIn
    }

    /// The device a recorder would use right now. `pinned` = we must set it on the engine explicitly
    /// (built-in preferred); otherwise AVAudioEngine follows the system default by itself.
    public static func resolve(preferBuiltIn: Bool) -> (id: AudioDeviceID?, name: String, pinned: Bool) {
        if preferBuiltIn, let b = builtInInputID(), isAlive(b) {
            return (b, name(of: b) ?? "Built-in microphone", true)
        }
        if let d = defaultInputID() { return (d, name(of: d) ?? "Default input", false) }
        return (nil, "No input device", false)
    }

    /// Name shown in Settings: what the next dictation will record from.
    public static func activeInputName(preferBuiltIn: Bool) -> String { resolve(preferBuiltIn: preferBuiltIn).name }
}
