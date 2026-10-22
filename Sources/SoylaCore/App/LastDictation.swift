import AppKit

/// F4: Paste last (⌘⌃V) and Copy last (⌘⌃C). Global key-down monitor (needs Accessibility, which Soyla already
/// requires for paste) plus menu items; the event is observed, not swallowed.
enum LastDictation {
    enum Action: Equatable { case paste, copy }

    /// Text of the latest successful live dictation (cleaned if there was a correction pass), newest last in `records`.
    static func text(in records: [RunRecord]) -> String? {
        records.last { $0.source == "live" && $0.status == .ok && !($0.finalText ?? "").isEmpty }?.finalText
    }

    static func latestText() -> String? { text(in: (try? RunLog.readAll()) ?? []) }

    /// ⌘⌃V / ⌘⌃C exactly (no ⇧/⌥). Letters by character, falling back to the ANSI key position (9 = V, 8 = C) for
    /// layouts whose ⌘ layer isn't Latin (see PLAN §13, F1).
    static func action(keyCode: UInt16, chars: String?, flags: NSEvent.ModifierFlags) -> Action? {
        let mods = flags.intersection([.command, .control, .option, .shift])
        guard mods == [.command, .control] else { return nil }
        switch chars?.lowercased() {
        case "v": return .paste
        case "c": return .copy
        case let c? where c.unicodeScalars.allSatisfy({ $0.isASCII }) && !c.isEmpty: return nil
        default: return keyCode == 9 ? .paste : keyCode == 8 ? .copy : nil
        }
    }
}
