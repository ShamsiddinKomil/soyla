import AppKit
import AVFoundation

// OB-2: the macOS surfaces first-run setup points at. Reads only: the fn-key setting, the System Settings window's
// bounds (no permission needed for bounds) and the microphone prompt. Nothing here writes another app's settings.

enum SystemSurfaces {
    /// Keyboard settings ("Press 🌐 key to"). Same legacy-style link family as `PermissionLinks`.
    static let keyboard = "x-apple.systempreferences:com.apple.Keyboard-Settings.extension"
    static let settingsBundleID = "com.apple.systempreferences"

    /// `AppleFnUsageType` in `com.apple.HIToolbox` (0 Do Nothing, 1 Change Input Source, 2 Emoji, 3 Dictation;
    /// nil = never set, the macOS default). Synchronised first so a change made in System Settings is seen.
    static func fnUsage() -> Int? {
        if let captured = captureFnUsage { return captured }
        let domain = "com.apple.HIToolbox" as CFString
        _ = CFPreferencesAppSynchronize(domain)
        return (CFPreferencesCopyAppValue("AppleFnUsageType" as CFString, domain) as? NSNumber)?.intValue
    }

    /// Docs captures only: `--fn-usage <n>` stands in for the setting, so the fn row can be drawn without touching
    /// the Mac's own (HOTKEY-1).
    private static let captureFnUsage: Int? = {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: "--fn-usage"), i + 1 < a.count else { return nil }
        return Int(a[i + 1])
    }()

    /// The frontmost on-screen System Settings window, in AppKit screen coordinates (origin bottom-left).
    @MainActor static func settingsWindowFrame() -> CGRect? {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let primary = NSScreen.screens.first?.frame else { return nil }
        let pids = Set(NSRunningApplication.runningApplications(withBundleIdentifier: settingsBundleID).map(\.processIdentifier))
        guard !pids.isEmpty else { return nil }
        // The list is front to back; take the first normal-layer window of the app.
        for w in info {
            guard let pid = (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, pids.contains(pid),
                  (w[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let b = w[kCGWindowBounds as String] as? NSDictionary,
                  let cg = CGRect(dictionaryRepresentation: b), cg.width > 200, cg.height > 200 else { continue }
            return CGRect(x: cg.minX, y: primary.height - cg.maxY, width: cg.width, height: cg.height)
        }
        return nil
    }

    /// The real microphone prompt. Nonisolated so the completion can't be inferred onto the main actor: the system
    /// calls it back on an arbitrary queue, and Swift 6 would trap.
    nonisolated static func requestMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    static func open(_ link: String) { if let u = URL(string: link) { NSWorkspace.shared.open(u) } }
}

/// Where the helper note goes, as a pure function: beside the System Settings window when there is room (arrow on
/// its left edge), else under it (arrow on top; Soyla is the last row of the alphabetical list, so it still lands
/// near its switch), else the screen's top-right corner.
enum HelperPlacement {
    enum Arrow: Equatable, Sendable { case left, top, none }
    static let gap: CGFloat = 12

    static func place(settings: CGRect?, helper: CGSize, screen: CGRect) -> (origin: CGPoint, arrow: Arrow) {
        if let s = settings {
            if s.maxX + gap + helper.width <= screen.maxX {
                let y = min(max(s.maxY - 96 - helper.height, screen.minY), screen.maxY - helper.height)
                return (CGPoint(x: s.maxX + gap, y: y), .left)
            }
            if s.minY - gap - helper.height >= screen.minY {
                let x = min(max(s.minX + 16, screen.minX), screen.maxX - helper.width)
                return (CGPoint(x: x, y: s.minY - gap - helper.height), .top)
            }
        }
        return (CGPoint(x: screen.maxX - helper.width - 16, y: screen.maxY - helper.height - 16), .none)
    }
}
