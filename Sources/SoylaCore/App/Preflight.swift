import Foundation

// Flows audit 2026-10-19 F-16 (Bigger suggestion 3): at key-down, when the shared Readiness says dictation cannot work
// at all, nothing is recorded and the card shows at once, instead of after the user has spoken a paragraph.

public enum KeyDownPreflight {
    /// The card to show instead of recording, or nil to record. A missing permission, or a Cloud engine with no key
    /// at all. A skipped Uzbek/Russian key while English works on this Mac records as usual.
    public static func card(home: HomeState) -> PillFailure? {
        if case .blocked(let mic, _) = home.readiness { return .permissionNeeded(mic: mic) }
        if home.title == .needsKey { return .from(SoylaError.missingAPIKey("preflight"), stage: "preflight") }
        return nil
    }
}

/// Swallows the hotkey gesture whose key-down was refused, and tells the reducer the pipeline is idle at its end.
public struct PreflightGate: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable { case pass, swallow, idle, show(PillFailure) }
    public private(set) var holding = false

    public init() {}

    public mutating func route(_ a: HotkeyReducer.Action, card: () -> PillFailure?) -> Outcome {
        if case .startRecording = a {
            guard let c = card() else { holding = false; return .pass }
            holding = true
            return .show(c)
        }
        guard holding else { return .pass }
        switch a {
        case .stopAndSend, .cancelRecording: holding = false; return .idle
        case .reveal, .conceal, .lock, .busyNotice: return .swallow
        default: return .pass
        }
    }
}
