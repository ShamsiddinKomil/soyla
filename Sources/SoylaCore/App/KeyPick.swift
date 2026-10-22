import AppKit

/// HOTKEY-1: choose the hotkey by pressing it. Fed from a local NSEvent monitor (Soyla's own window is key, so no
/// permission is needed). A modifier counts when it goes down and up alone; a shortcut (⌘W) or a second modifier
/// cancels it. F13 and ⌃⇧Space count on key-down.
struct KeyPick: Equatable {
    /// The keys every Mac has, left to right as they sit on a MacBook's bottom row.
    static let main: [HotkeyChoice] = [.fn, .rightCommand, .rightOption]
    /// The rest: Right ⌃ is only on external keyboards, F13 on extended ones, ⌃⇧Space is a combo.
    static let more: [HotkeyChoice] = [.rightControl, .f13, .ctrlShiftSpace]

    private static let modifiers: [UInt16: (HotkeyChoice, NSEvent.ModifierFlags)] = [
        63: (.fn, .function), 54: (.rightCommand, .command), 61: (.rightOption, .option), 62: (.rightControl, .control),
    ]
    private static let relevant: NSEvent.ModifierFlags = [.function, .command, .option, .control, .shift]

    private var candidate: UInt16?

    mutating func flagsChanged(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> HotkeyChoice? {
        let held = flags.intersection(Self.relevant)
        guard let (choice, flag) = Self.modifiers[keyCode] else { candidate = nil; return nil }
        if held.contains(flag) {
            candidate = held == flag ? keyCode : nil      // alone, or not at all
            return nil
        }
        defer { candidate = nil }
        return candidate == keyCode && held.isEmpty ? choice : nil
    }

    mutating func keyDown(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> HotkeyChoice? {
        candidate = nil
        let held = flags.intersection(Self.relevant).subtracting(.function)   // F-keys carry the fn flag
        if keyCode == 105 && held.isEmpty { return .f13 }
        if keyCode == 49 && held == [.control, .shift] { return .ctrlShiftSpace }
        return nil
    }
}

/// The Hotkey page's live test: while the page is in front, the hotkey's gestures come here instead of the pipeline.
enum KeyTest: Equatable {
    case idle, held, worked

    mutating func note(_ a: HotkeyReducer.Action) {
        switch a {
        case .startRecording: self = .held
        case .lock: self = .worked
        case .stopAndSend, .cancelRecording: if self == .held { self = .worked }
        default: break
        }
    }
}
