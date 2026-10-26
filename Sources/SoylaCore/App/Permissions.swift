import Foundation
import AVFoundation

// Pure permission and hotkey-probe state shared by Setup, Home, the pill and the menu bar (no AppKit / SwiftUI).
// Moved out of the retired OnboardingFlow.swift (owner D11, 2026-10-25).

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
