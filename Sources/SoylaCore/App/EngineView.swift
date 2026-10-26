import SwiftUI
import AppKit

// FE-5: Settings → Engine (the page that replaced "API keys"): the free on-device engine and the cloud engine, side by
// side. Copy and decisions live in `EngineCopy` (pure, tested); this file only draws them.

extension SettingsModel {
    /// Pick the free engine. The stored cloud choices (model, language, cleanup) are not touched except the display
    /// model, so switching back restores a sensible cloud default.
    func useFreeEngine() {
        guard s.provider != .apple else { return }
        var n = s
        n.provider = .apple
        n.sttModel = n.onDeviceLocale          // display only (R3)
        n.cleanupModel = ProviderKind.apple.defaultCleanupModel
        s = n
    }

    /// Pick the cloud engine (`kind` from `EngineCopy.cloudTarget`), with that provider's default models.
    func useCloudEngine(_ kind: ProviderKind) {
        guard kind != .apple else { return }
        guard s.provider != kind else { return }
        var n = s
        n.provider = kind
        n.sttModel = kind.defaultSTTModel
        n.cleanupModel = kind.defaultCleanupModel
        s = n
    }

    /// The cloud provider the Cloud card selects, given which keys exist.
    func cloudTarget(hasKey: (KeyProvider) -> Bool) -> ProviderKind {
        EngineCopy.cloudTarget(hasKey: hasKey, developerMode: s.developerMode)
    }
}

extension EngineCopy.Tone {
    var color: Color {
        switch self { case .ok: Ink.ok; case .pending: Ink.lazur; case .warn: Ink.warn; case .neutral: Ink.text4 }
    }
}
