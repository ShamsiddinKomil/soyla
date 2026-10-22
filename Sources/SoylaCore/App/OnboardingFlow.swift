import Foundation
import AVFoundation

// A4: pure, unit-tested pieces of first-run onboarding (no AppKit / SwiftUI here).

/// One source of truth for "can Soyla hear, listen and paste?". Owned by `AppStatus` (one poller) and
/// published to onboarding, Home, the pill and the menu bar.
public struct PermissionState: Equatable, Sendable {
    public enum Mic: Equatable, Sendable { case notDetermined, granted, denied }
    public var mic: Mic = .notDetermined
    /// Accessibility (paste; also enough for a listen-only tap).
    public var ax = false
    /// Input Monitoring as reported by `CGPreflightListenEventAccess` (can be stale, Hex #250).
    public var inputMonitoring = false
    /// A key event actually reached our tap. Proof of delivery: overrides a stale Input Monitoring denial.
    public var eventsFlowing = false
    /// Speech Recognition (FE-3). Read only on macOS 14–15; only the free engine there needs it, so it is not part of
    /// `allGranted` (the row shows only for that case, `OnDeviceAvailability.showsSpeechPermissionRow`).
    public var speech: SpeechAuthorization = .notDetermined

    public init(mic: Mic = .notDetermined, ax: Bool = false, inputMonitoring: Bool = false, eventsFlowing: Bool = false) {
        self.mic = mic; self.ax = ax; self.inputMonitoring = inputMonitoring; self.eventsFlowing = eventsFlowing
    }

    public var inputMonitoringOK: Bool { inputMonitoring || eventsFlowing }
    /// Enough for the event tap to be created (either grant suffices for listen-only).
    public var canListen: Bool { ax || inputMonitoring }
    public var allGranted: Bool { mic == .granted && ax && inputMonitoringOK }

    public static func mic(_ s: AVAuthorizationStatus) -> Mic {
        switch s {
        case .authorized: return .granted
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }
}

/// FE-5: the two ways to listen on the engine step.
public enum OnboardingEngine: Equatable, Sendable { case free, cloud }

public enum OnboardingStep: Int, CaseIterable, Sendable {
    case welcome, microphone, permissions, hotkey, key, tryIt

    public var title: String {
        switch self {
        case .welcome: return "Welcome to Soyla"
        case .microphone: return "Microphone"
        case .permissions: return "Permissions"
        case .hotkey: return "Try the hotkey"
        case .key: return "How should Soyla listen?"
        case .tryIt: return "First dictation"
        }
    }
}

/// Step gating as a reducer: which step, and what unlocks Continue. The view only renders this.
public struct OnboardingFlow: Equatable, Sendable {
    public private(set) var step: OnboardingStep = .welcome
    public var permissions = PermissionState()
    /// The live meter rose above the speech threshold at least once (buffers really flow from this device).
    public var micHeard = false
    /// A hotkey down edge arrived during step 2c.
    public var hotkeyProven = false
    /// The chosen provider's key passed Test.
    public var keyVerified = false
    /// Engine step: On this Mac (free) or Cloud (a key). Defaults to cloud so a flow that never sets it behaves as
    /// before FE-5; the view model preselects free when it is available.
    public var engine: OnboardingEngine = .cloud
    /// The free engine's model state (nil until first read). Continue needs `.ready` when `engine == .free`.
    public var modelState: OnDeviceModelState?
    public var modelReady: Bool { modelState == .ready }
    /// The step-4 field's text changed (dictation landed).
    public var tryTextChanged = false
    /// "Skip for now" on the permissions step: the hotkey proof is skipped and step 4 can finish without dictating.
    public private(set) var permissionsSkipped = false
    /// "Skip for now" on the microphone / key steps (same warning style as permissions).
    public private(set) var micSkipped = false
    public private(set) var keySkipped = false
    public var anySkipped: Bool { micSkipped || permissionsSkipped || keySkipped }
    public private(set) var finished = false

    public init() {}

    public var canContinue: Bool {
        switch step {
        case .welcome: return true
        case .microphone: return permissions.mic == .granted && micHeard
        case .permissions: return permissions.ax && permissions.inputMonitoringOK
        case .hotkey: return hotkeyProven
        case .key: return engine == .free ? modelReady : keyVerified
        case .tryIt: return tryTextChanged || anySkipped
        }
    }

    /// Why Continue is disabled (nil when enabled). Shown under the button.
    public var blocker: String? {
        guard !canContinue else { return nil }
        switch step {
        case .welcome: return nil
        case .microphone: return permissions.mic != .granted ? "Allow microphone access to continue." : "Say something so the bars move."
        case .permissions:
            if !permissions.ax && !permissions.inputMonitoringOK { return "Turn Soyla on in both lists." }
            return permissions.ax ? "Turn Soyla on in Input Monitoring." : "Turn Soyla on in Accessibility."
        case .hotkey: return "Waiting for the hotkey…"
        case .key:
            guard engine == .free else { return "Save a key and press Test." }
            switch modelState {
            case .needsPermission: return "Allow Speech Recognition, or skip for now."
            case .unavailable: return "The free engine isn't available on this Mac. Choose Cloud, or skip for now."
            default: return "Wait for the English model, or skip for now."
            }
        case .tryIt: return "Dictate into the box to finish."
        }
    }

    /// The pipeline only receives hotkey events from step 4 on, so setup can't trigger a dictation.
    public var hotkeysActive: Bool { step == .tryIt }
    public var isLastStep: Bool { step == .tryIt }
    public var canGoBack: Bool { step != .welcome }

    /// Continue / Finish. Returns false (and changes nothing) while the step's check fails.
    @discardableResult
    public mutating func next() -> Bool {
        guard canContinue else { return false }
        if step == .permissions { permissionsSkipped = false }
        if step == .microphone { micSkipped = false }
        if step == .key { keySkipped = false }
        if step == .tryIt { finished = true; return true }
        var n = OnboardingStep(rawValue: step.rawValue + 1)!
        if n == .hotkey && permissionsSkipped { n = .key }
        step = n
        return true
    }

    public mutating func back() {
        guard canGoBack else { return }
        var p = OnboardingStep(rawValue: step.rawValue - 1)!
        if p == .hotkey && permissionsSkipped { p = .permissions }
        step = p
    }

    /// "Skip for now" (permissions step only): goes straight to the key step.
    public mutating func skipPermissions() {
        guard step == .permissions else { return }
        skip()
    }

    /// "Skip for now" on the microphone, permissions and key steps. Other steps ignore it.
    public mutating func skip() {
        switch step {
        case .microphone: micSkipped = true; step = .permissions
        case .permissions: permissionsSkipped = true; step = .key
        case .key: keySkipped = true; step = .tryIt
        default: break
        }
    }

    /// Setup Assistant reopened from the Help menu: start over, keep the live permission state.
    public mutating func restart() {
        let p = permissions
        self = OnboardingFlow()
        permissions = p
    }
}

/// Step 2c verdict: did a hotkey event arrive, and if not, why (pure; the view polls it at 10 Hz).
public enum HotkeyProbe {
    public enum Verdict: Equatable, Sendable {
        case waiting
        case proven
        /// Neither Accessibility nor Input Monitoring is on: there is no tap to test.
        case noPermission
        /// The toggle is on but not a single key event arrived (ad-hoc signing / stale TCC entry trap).
        case notDelivered
        /// Other keys arrive but the hotkey never did: likely a keyboard without fn → suggest another key.
        case noHotkeyKey
    }

    public static let timeout: TimeInterval = 5
    /// Total silence (no key at all) is ambiguous: a broken tap or a reader who hasn't pressed yet. Wait longer before
    /// calling it the TCC trap (D1 walkthrough showed the warning before anyone touched the keyboard).
    public static let silentTimeout: TimeInterval = 12

    public static func verdict(elapsed: TimeInterval, hotkeySeen: Bool, anyEventSeen: Bool, toggleOn: Bool,
                               timeout: TimeInterval = HotkeyProbe.timeout,
                               silentTimeout: TimeInterval = HotkeyProbe.silentTimeout) -> Verdict {
        if hotkeySeen { return .proven }                 // a delivered event wins over any status call
        if !toggleOn { return .noPermission }
        if elapsed < timeout { return .waiting }
        if anyEventSeen { return .noHotkeyKey }
        return elapsed < silentTimeout ? .waiting : .notDelivered
    }
}

/// Other dictation apps that also hold fn: if they run, both apps fire.
public enum ConflictingApps {
    /// (bundle id prefix, display name). Wispr Flow's Mac id is `com.electron.wispr-flow` (checked on the owner's Mac);
    /// `com.wisprflow.` covers a future native build.
    public static let known: [(prefix: String, name: String)] = [
        ("com.electron.wispr-flow", "Wispr Flow"),
        ("com.wisprflow.", "Wispr Flow"),
        ("ai.amical.", "Amical"),
        ("com.superduper.superwhisper", "Superwhisper"),
    ]

    /// Display names of known conflicting apps among `bundleIds` (deduplicated, in `known` order).
    public static func detect(_ bundleIds: [String]) -> [String] {
        var out: [String] = []
        for k in known where bundleIds.contains(where: { $0.hasPrefix(k.prefix) }) && !out.contains(k.name) {
            out.append(k.name)
        }
        return out
    }
}
