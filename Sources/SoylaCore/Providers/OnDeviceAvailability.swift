import Foundation

// FE-3: pure, unit-tested pieces of on-device model availability. No Apple Speech types appear here: the impure
// reads live in `OnDeviceModels.swift` (`OnDeviceProbe`) and are mirrored into these enums.

/// Mirror of `AssetInventory.Status` (macOS 26+).
public enum OnDeviceAssetStatus: Equatable, Sendable { case unsupported, supported, downloading, installed }

/// Mirror of `SFSpeechRecognizerAuthorizationStatus` (only matters on macOS 14–15).
public enum SpeechAuthorization: Equatable, Sendable { case notDetermined, denied, restricted, authorized }

public enum OnDeviceUnavailableReason: Equatable, Sendable {
    /// macOS 26: DictationTranscriber has no model for this locale.
    case localeUnsupported
    /// macOS 14–15: `supportsOnDeviceRecognition` is false. Never falls back to Apple's servers (V1).
    case noOnDeviceModel
    /// macOS 14–15: Speech Recognition is blocked by a profile or Screen Time; the user cannot grant it.
    case restricted
    /// macOS 26: every reserved slot belongs to other apps, so Soyla cannot reserve its locale.
    case reservationsFull
    /// Below the package floor (cannot happen in the shipped app; keeps the reducer total).
    case osTooOld
}

/// One answer to "can the free engine transcribe now?" for the chosen locale (English only, V5).
public enum OnDeviceModelState: Equatable, Sendable {
    case ready
    /// macOS 26: the model must be downloaded (or the locale reserved) first.
    case needsDownload
    /// 0...1.
    case downloading(Double)
    case unavailable(OnDeviceUnavailableReason)
    /// macOS 14–15 only: Speech Recognition is not authorized yet (or was denied).
    case needsPermission

    public var isReady: Bool { self == .ready }
}

public enum OnDeviceAvailability {
    /// First macOS with `DictationTranscriber` / `AssetInventory`.
    public static let analyzerOS = 26

    /// The reducer. `asset` is the analyzer's status (macOS 26+), nil when there is no analyzer reading; then the
    /// legacy recogniser's on-device flag and authorization decide. `progress` is Soyla's own running download.
    public static func state(osMajor: Int, asset: OnDeviceAssetStatus?, legacyOnDevice: Bool,
                             legacyAuth: SpeechAuthorization, progress: Double?) -> OnDeviceModelState {
        guard osMajor >= 14 else { return .unavailable(.osTooOld) }
        if osMajor >= analyzerOS, let asset {
            switch asset {
            case .installed: return .ready
            case .downloading: return .downloading(clamp(progress ?? 0))
            case .supported: return progress.map { .downloading(clamp($0)) } ?? .needsDownload
            case .unsupported: return .unavailable(.localeUnsupported)
            }
        }
        // Legacy. Permission first: until it is granted the on-device flag is not worth acting on, and granting is the
        // one thing the user can do. Restricted can't be granted, so it is "unavailable", not "needs permission".
        switch legacyAuth {
        case .notDetermined, .denied: return .needsPermission
        case .restricted: return .unavailable(.restricted)
        case .authorized: return legacyOnDevice ? .ready : .unavailable(.noOnDeviceModel)
        }
    }

    /// P1 at fresh-install time, synchronously (the settings store is created before any async work can run).
    /// macOS 26+: `true` without asking. `DictationTranscriber.supportedLocales` is async-only, and FE-0 found every
    /// English variant supported, so the OS version is the conservative synchronous answer; a Mac where it is wrong
    /// shows "Not available" on the Engine page and the user picks Cloud. macOS 14–15: the legacy recogniser's
    /// on-device English flag (a cheap synchronous read, `legacyOnDevice`, evaluated only there).
    public static func freshInstallAvailable(osMajor: Int, legacyOnDevice: () -> Bool) -> Bool {
        if osMajor >= analyzerOS { return true }
        return osMajor >= 14 && legacyOnDevice()
    }

    /// The Speech Recognition permission row: only macOS 14–15 with the free engine selected (macOS 26 never prompts,
    /// FE-0).
    public static func showsSpeechPermissionRow(osMajor: Int, provider: ProviderKind) -> Bool {
        provider == .apple && usesLegacyPermission(osMajor: osMajor)
    }

    public static func usesLegacyPermission(osMajor: Int) -> Bool { osMajor >= 14 && osMajor < analyzerOS }

    private static func clamp(_ p: Double) -> Double { min(1, max(0, p)) }
}

/// `AssetInventory` reservation bookkeeping (macOS 26 allows `maximumReservedLocales` = 5 per app, FE-0). Soyla
/// releases only locales it reserved itself, oldest first. "Ours" lives in the `ai.soyla.settings` UserDefaults suite
/// under `onDevice.reservedLocales` (not in the `Settings` blob: it is bookkeeping, not a user choice).
public enum OnDeviceReservations {
    public enum Plan: Equatable, Sendable {
        case alreadyReserved, reserve
        case releaseThenReserve(String)
        /// No free slot and nothing of Soyla's to release.
        case full
    }

    public static let defaultsKey = "onDevice.reservedLocales"

    /// `owned` is oldest first.
    public static func plan(wanted: String, reserved: [String], owned: [String], max: Int) -> Plan {
        let reservedIDs = reserved.map(norm)
        if reservedIDs.contains(norm(wanted)) { return .alreadyReserved }
        if reservedIDs.count < max { return .reserve }
        if let victim = owned.first(where: { reservedIDs.contains(norm($0)) && norm($0) != norm(wanted) }) {
            return .releaseThenReserve(victim)
        }
        return .full
    }

    /// The owned list after a successful reserve: drop the released locale, append the new one once.
    public static func owned(_ owned: [String], released: String?, reserved: String) -> [String] {
        var out = owned.filter { o in released.map { norm($0) != norm(o) } ?? true }
        if !out.contains(where: { norm($0) == norm(reserved) }) { out.append(norm(reserved)) }
        return out
    }

    public static func load(_ d: UserDefaults) -> [String] { d.stringArray(forKey: defaultsKey) ?? [] }
    public static func save(_ owned: [String], to d: UserDefaults) { d.set(owned, forKey: defaultsKey) }

    /// "en_US" and "en-US" are the same locale (`Locale.identifier` uses "_").
    static func norm(_ id: String) -> String { id.replacingOccurrences(of: "_", with: "-") }
}
