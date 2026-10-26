import Foundation
import AppKit
import Carbon
import ApplicationServices
import os
// OWNER: F1 (paste hardening). Pure decision logic lives here so it can be unit-tested without a GUI:
// restore-delay table, pre-flight decision, restore guard, ⌘V keycode resolution order, terminal text prep.
// The system probes (TIS/UCKeyTranslate, IsSecureEventInputEnabled, AX focused role) are thin wrappers around them.

/// The app that should receive the paste, captured at hotkey release (key-up), not at paste time.
public struct PasteTarget: Equatable, Sendable {
    public var pid: pid_t?
    public var bundleId: String?
    public var name: String?
    public init(pid: pid_t?, bundleId: String?, name: String?) {
        self.pid = pid; self.bundleId = bundleId; self.name = name
    }
    /// Snapshot of the app that has keyboard focus right now.
    public static func frontmost() -> PasteTarget {
        guard let pid = frontmostPID() else { return PasteTarget(pid: nil, bundleId: nil, name: nil) }
        let app = NSRunningApplication(processIdentifier: pid)
        return PasteTarget(pid: pid, bundleId: app?.bundleIdentifier, name: app?.localizedName)
    }

    /// AX focused application first (live, also right for non-activating panels like Spotlight); NSWorkspace as the
    /// fallback. NSWorkspace.frontmostApplication is only refreshed by the main run loop, which never runs in CLI mode.
    public static func frontmostPID() -> pid_t? {
        let sys = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(sys, 0.25)
        var ref: CFTypeRef?
        if AXUIElementCopyAttributeValue(sys, kAXFocusedApplicationAttribute as CFString, &ref) == .success,
           let r = ref, CFGetTypeID(r) == AXUIElementGetTypeID() {
            var pid: pid_t = 0
            if AXUIElementGetPid(r as! AXUIElement, &pid) == .success, pid > 0 { return pid }
        }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier
    }
}

/// How a paste ended. Never carries the text itself.
public enum PasteOutcome: Equatable, Sendable {
    /// Text was handed to the target app. `targetLooksEditable == false` means AX said the focused element is not a
    /// text field (warn only; we pasted anyway, FluidVoice's hard refusal gave false positives). nil = unknown.
    case pasted(method: PasteMethod, targetLooksEditable: Bool?)
    /// Nothing was inserted; the text is on the clipboard (not restored) so the user can press ⌘V.
    case copiedOnly(reason: PasteBlockReason)

    public var inserted: Bool { if case .pasted = self { return true }; return false }
    /// Short machine label for logs/run records, e.g. "commandV" or "copied:secureInput".
    public var label: String {
        switch self {
        case .pasted(let m, _): return m.rawValue
        case .copiedOnly(let r): return "copied:\(r.rawValue)"
        }
    }
}

public enum PasteMethod: String, Sendable {
    case commandV            // pasteboard + synthetic ⌘V (primary)
    case axSelectedText      // AX kAXSelectedTextAttribute set (only if ⌘V could not be posted)
    case menuPaste           // AX press on the menu item bound to ⌘V (locale-independent)
    case unicodeTyping       // CGEvent unicode strings; opt-in (Paster.allowUnicodeTyping), Developer mode only
}

public enum PasteBlockReason: String, Sendable {
    case noAccessibility     // AXIsProcessTrusted() == false
    case secureInput         // IsSecureEventInputEnabled(): password field / Terminal Secure Keyboard Entry
    case focusChanged        // frontmost PID differs from the one at hotkey release
    case postFailed          // every rung of the fallback ladder failed
}

// MARK: - Restore delay table

public enum PasteDelays {
    public static let defaultMs = 500
    public static let chromiumMs = 1200
    public static let remoteMs = 2000

    /// Chromium/Electron apps read the pasteboard lazily (and slowly) after ⌘V.
    static let chromium: Set<String> = [
        "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.vscodium", "com.todesktop.230313mzl4w4u92", // Cursor
        "com.tinyspeck.slackmacgap", "com.hnc.Discord",
        "ru.keepcoder.Telegram", "org.telegram.desktop", "com.tdesktop.Telegram",
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary", "org.chromium.Chromium",
        "com.brave.Browser", "com.microsoft.edgemac", "company.thebrowser.Browser", "com.operasoftware.Opera",
        "com.vivaldi.Vivaldi", "notion.id", "md.obsidian", "com.figma.Desktop", "com.spotify.client",
    ]
    /// Remote desktop / screen sharing / VMs forward the clipboard over the network before the remote side pastes.
    static let remote: Set<String> = [
        "com.apple.ScreenSharing", "com.microsoft.rdc.macos", "com.microsoft.rdc.mac",
        "com.teamviewer.TeamViewer", "com.philandro.anydesk", "com.parallels.desktop.console", "com.vmware.fusion",
    ]

    /// Milliseconds to wait between ⌘V and putting the user's clipboard back.
    /// `isElectron` = the app bundle ships Electron/Chromium frameworks (detected separately, see `bundleLooksChromium`).
    public static func restoreDelayMs(bundleId: String?, isElectron: Bool = false) -> Int {
        if let b = bundleId {
            if remote.contains(b) { return remoteMs }
            if chromium.contains(b) { return chromiumMs }
        }
        return isElectron ? chromiumMs : defaultMs
    }

    /// Generic Electron/CEF detection for apps not in the table (cheap: two fileExists calls).
    public static func bundleLooksChromium(_ app: NSRunningApplication?) -> Bool {
        guard let url = app?.bundleURL else { return false }
        let fw = url.appendingPathComponent("Contents/Frameworks")
        let fm = FileManager.default
        return fm.fileExists(atPath: fw.appendingPathComponent("Electron Framework.framework").path)
            || fm.fileExists(atPath: fw.appendingPathComponent("Chromium Embedded Framework.framework").path)
    }
}

// MARK: - Pre-flight

public enum PastePreflight {
    /// Decide whether to attempt a paste at all. nil = go ahead.
    /// Order matters: permission first (nothing else works without it), then secure input, then focus.
    /// Focus only blocks when both PIDs are known and differ (unknown never blocks).
    public static func decide(axTrusted: Bool, secureInput: Bool, targetPID: pid_t?, currentPID: pid_t?) -> PasteBlockReason? {
        if !axTrusted { return .noAccessibility }
        if secureInput { return .secureInput }
        if let t = targetPID, let c = currentPID, t != c { return .focusChanged }
        return nil
    }

    /// Live probe of the same inputs.
    public static func check(target: PasteTarget?) -> PasteBlockReason? {
        decide(axTrusted: AXIsProcessTrusted(),
               secureInput: IsSecureEventInputEnabled(),
               targetPID: target?.pid,
               currentPID: PasteTarget.frontmostPID())
    }

    /// AX roles that accept typed text. Used for a warning only, never to refuse.
    static let editableRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField", "AXWebArea"]

    /// true/false when AX answered, nil when it could not (Electron, timeouts, no focus).
    public static func looksEditable(role: String?, settableValue: Bool?) -> Bool? {
        guard let role else { return nil }
        if editableRoles.contains(role) { return true }
        if settableValue == true { return true }
        // Generic containers (AXGroup/AXUnknown) are common in web/Electron content and say nothing.
        if role == "AXGroup" || role == "AXUnknown" { return nil }
        return false
    }

    /// Focused element's AX role and whether its value is settable. Bounded by a short AX messaging timeout.
    public static func focusedElementInfo() -> (role: String?, settableValue: Bool?) {
        guard let el = focusedElement() else { return (nil, nil) }
        var roleRef: CFTypeRef?
        let role: String? = AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &roleRef) == .success ? roleRef as? String : nil
        var settable = DarwinBoolean(false)
        let ok = AXUIElementIsAttributeSettable(el, kAXValueAttribute as CFString, &settable) == .success
        return (role, ok ? settable.boolValue : nil)
    }

    static func focusedElement() -> AXUIElement? {
        let sys = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(sys, 0.25)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &ref) == .success,
              let r = ref, CFGetTypeID(r) == AXUIElementGetTypeID() else { return nil }
        let el = r as! AXUIElement
        AXUIElementSetMessagingTimeout(el, 0.25)
        return el
    }
}

// MARK: - Restore guard

public enum RestoreGuard {
    /// Restore the user's clipboard only if nobody wrote to it since our write (changeCount unchanged)
    /// AND our private session marker is still there with our token.
    public static func shouldRestore(currentChangeCount: Int, ourChangeCount: Int, markerToken: String?, ourToken: String) -> Bool {
        currentChangeCount == ourChangeCount && markerToken == ourToken
    }
}

// MARK: - Terminal text prep

public enum PasteText {
    static let terminals: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "net.kovidgoyal.kitty",
        "io.alacritty", "org.alacritty", "dev.warp.Warp-Stable", "com.github.wez.wezterm", "co.zeit.hyper",
    ]
    public static func isTerminal(_ bundleId: String?) -> Bool { bundleId.map(terminals.contains) ?? false }

    /// Terminal targets: a trailing newline would execute the command, so strip trailing newlines.
    /// No trailing space is ever appended (smart spacing is v0.3).
    public static func prepare(_ text: String, bundleId: String?) -> String {
        guard isTerminal(bundleId) else { return text }
        var t = text
        while let last = t.last, last.isNewline { t.removeLast() }
        return t
    }
}

// MARK: - ⌘V keycode resolution

public enum PasteKeycode {
    public static let ansiV: CGKeyCode = 9

    /// A layout lookup: virtual keycode → the character it produces with ⌘ held (nil = no character).
    public typealias Lookup = (UInt16) -> String?

    /// Try each layout in order (current input source, then the ASCII-capable one); the first that has a key
    /// producing "v" with ⌘ wins (keycode 9 preferred when several do). Nothing found → ANSI keycode 9.
    public static func resolve(_ layouts: [Lookup?]) -> CGKeyCode {
        for case let lookup? in layouts {
            var hits: [UInt16] = []
            for k in UInt16(0)..<128 where lookup(k)?.lowercased() == "v" { hits.append(k) }
            if hits.contains(UInt16(ansiV)) { return ansiV }
            if let first = hits.first { return CGKeyCode(first) }
        }
        return ansiV
    }

    private static let cached = OSAllocatedUnfairLock<CGKeyCode?>(initialState: nil)
    /// Layout-change observer token; only `prepare()` (main actor) touches it.
    @MainActor private static var observer: NSObjectProtocol?

    /// Text Input Sources calls must run on the main thread: since macOS 26, HIToolbox asserts the main queue and
    /// traps (EXC_BREAKPOINT) otherwise. That killed every paste from the pipeline's background task (2026-10-16).
    /// Callers off the main thread hop over synchronously; the main thread must be free (GUI run loop, or the CLI's
    /// `dispatchMain()`), never blocked on a semaphore.
    /// Re-entrant: a nested call already on the main queue runs inline. Checks the queue, not `Thread.isMainThread`,
    /// which reported false on the main queue under `dispatchMain()` and deadlocked a nested hop (CLI, 2026-10-16).
    public static func onMain<T>(_ body: () -> T) -> T {
        if Thread.isMainThread || DispatchQueue.getSpecific(key: mainKey) != nil { return body() }
        // SAFETY (D10, stays): callers are synchronous (the paste path and the CLI), and a sync hop is what keeps TIS
        // on main without making them async. An `await MainActor.run` would need every caller async; deadlock is ruled
        // out above (re-entrant check) and by the main thread never being blocked (GUI run loop / `dispatchMain()`).
        return DispatchQueue.main.sync(execute: body)
    }
    private static let mainKey: DispatchSpecificKey<Bool> = {
        let k = DispatchSpecificKey<Bool>()
        // SAFETY (D10, stays): marks the main queue so `onMain` can tell "already on main" when `Thread.isMainThread`
        // lies (under `dispatchMain()`); the main actor has no equivalent queue-identity check.
        DispatchQueue.main.setSpecific(key: k, value: true)
        return k
    }()

    /// Cached keycode; recomputed on the main thread after the selected input source changes.
    public static func current() -> CGKeyCode {
        if let c = cached.withLock({ $0 }) { return c }
        let c = resolveLive()          // hops to main; the lock is not held across the hop
        cached.withLock { $0 = c }
        return c
    }

    /// Call once on the main thread at launch: warms the cache and watches for layout switches.
    @MainActor public static func prepare() {
        if observer == nil {
            observer = DistributedNotificationCenter.default().addObserver(
                forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil, queue: .main
            ) { _ in PasteKeycode.invalidate() }
        }
        _ = current()
    }

    public static func invalidate() { cached.withLock { $0 = nil } }

    /// Uncached: current keyboard layout, then the current ASCII-capable layout.
    public static func resolveLive() -> CGKeyCode {
        onMain {
            resolve([lookup(for: TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue()),
                     lookup(for: TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue())])
        }
    }

    /// UCKeyTranslate-backed lookup for one input source (nil if it has no Unicode layout data, e.g. some IMEs).
    /// The property read happens on the main thread; the returned closure only uses the copied layout bytes.
    public static func lookup(for source: TISInputSource?) -> Lookup? {
        guard let source else { return nil }
        let read: (Data, UInt32)? = onMain {
            guard let p = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
            return (Unmanaged<CFData>.fromOpaque(p).takeUnretainedValue() as Data, UInt32(LMGetKbdType()))
        }
        guard let (data, kbType) = read else { return nil }
        let cmd = UInt32((cmdKey >> 8) & 0xFF)
        return { key in
            data.withUnsafeBytes { raw -> String? in
                guard let lay = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
                var dead: UInt32 = 0
                var len = 0
                var chars = [UniChar](repeating: 0, count: 4)
                let st = UCKeyTranslate(lay, key, UInt16(kUCKeyActionDisplay), cmd, kbType,
                                        OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &len, &chars)
                guard st == noErr, len > 0 else { return nil }
                return String(utf16CodeUnits: chars, count: len)
            }
        }
    }

    /// Input source id (e.g. "com.apple.keylayout.Russian") for diagnostics.
    public static func sourceId(_ source: TISInputSource?) -> String? {
        guard let source else { return nil }
        return onMain {
            guard let p = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
            return Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String
        }
    }
}

// MARK: - Pill card for a paste that did not insert

extension PillFailure {
    /// "Not pasted: it's on your clipboard" + what to do, per reason.
    public static func paste(_ reason: PasteBlockReason) -> PillFailure {
        let title = "Not pasted: it's on your clipboard"
        switch reason {
        case .noAccessibility:
            return .init(kind: .warning, title: title, hint: allowAccessibility, openSettings: true, fix: .setup(.permissions))
        case .secureInput:
            return .init(kind: .warning, title: title, hint: "A password field or Secure Keyboard Entry blocks typing. Press ⌘V if it's safe.")
        case .focusChanged:
            return .init(kind: .warning, title: title, hint: "You switched apps. Press ⌘V where you want it.")
        case .postFailed:
            return .init(kind: .warning, title: title, hint: "Press ⌘V to paste it.")
        }
    }
}
