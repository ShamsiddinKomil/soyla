import AppKit
import SwiftUI

// HOTKEY-1: the hotkey is chosen on a drawing of the Mac's bottom row (Hotkey page) or a strip of the same caps
// (setup's fn row and Try). Flat caps with a drawn 1.5 pt edge, like KeyChip: no shadows inside windows (DESIGN).

/// One key of the bottom row. `choice` nil = drawn for orientation only (dim, not a button, hidden from VoiceOver).
struct BottomRowKey: View {
    let glyph: String
    var word: String? = nil
    /// nil = flexible (the space bar).
    var width: CGFloat? = 52
    var choice: HotkeyChoice? = nil
    var selected = false
    var pressed = false
    var pick: (HotkeyChoice) -> Void = { _ in }

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 7, style: .continuous) }

    var body: some View {
        if let choice {
            Button { pick(choice) } label: { face }
                .buttonStyle(.plain)
                .accessibilityLabel(AppStrings.current.d.hotkey(choice))
                .accessibilityAddTraits(selected ? .isSelected : [])
        } else {
            face.accessibilityHidden(true)
        }
    }

    private var face: some View {
        let live = choice != nil
        let ink: Color = selected ? Ink.lazur : (live ? Ink.text : Ink.text3)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 3) {
                if glyph == "fn" { Image(systemName: "globe").font(.system(size: SetupScale.type(11))) }
                Text(glyph).font(.system(size: SetupScale.type(glyph == "fn" ? 12 : 15), weight: .medium, design: .rounded))
            }
            Spacer(minLength: 0)
            if let word { Text(word).font(.system(size: SetupScale.type(9.5), weight: .medium)).lineLimit(1).minimumScaleFactor(0.8) }
        }
        .foregroundStyle(ink)
        .padding(.horizontal, 7).padding(.vertical, 6)
        .frame(width: width.map { SetupScale.pt($0) }, height: SetupScale.pt(46), alignment: .leading)
        .frame(minWidth: width == nil ? 40 : nil, maxWidth: width == nil ? .infinity : nil, alignment: .leading)
        // The wash sits on an opaque face, so the edge drawn below doesn't show through it.
        .background(shape.fill(selected ? Ink.lazurWash : .clear))
        .background(shape.fill(live ? Ink.sheet : Ink.well))
        .background(shape.fill(selected ? Ink.lazur.opacity(0.55) : Ink.hairlineStrong).offset(y: pressed ? 0.5 : 1.5))
        .overlay(shape.strokeBorder(selected ? Ink.lazur : Ink.hairlineStrong, lineWidth: selected ? 1.5 : 0.5))
        .offset(y: pressed ? 1 : 0)
        .contentShape(shape)
        .animation(.easeOut(duration: 0.08), value: pressed)
    }
}

/// The Hotkey page's keyboard: a MacBook's bottom row, left to right. Only fn, right ⌘ and right ⌥ are choices; the
/// rest are drawn so the row reads as the real keyboard.
struct MacBottomRow: View {
    let selection: HotkeyChoice
    var pressed = false
    let pick: (HotkeyChoice) -> Void

    var body: some View {
        HStack(spacing: SetupScale.pt(5)) {
            cap("fn", nil, 40, .fn)
            cap("⌃", "control", 46, nil)
            cap("⌥", "option", 46, nil)
            cap("⌘", "command", 68, nil)
            BottomRowKey(glyph: "", width: nil)   // space
            cap("⌘", "command", 68, .rightCommand)
            cap("⌥", "option", 46, .rightOption)
            arrows
        }
    }

    private func cap(_ glyph: String, _ word: String?, _ width: CGFloat, _ choice: HotkeyChoice?) -> BottomRowKey {
        BottomRowKey(glyph: glyph, word: word, width: width, choice: choice, selected: choice == selection,
               pressed: pressed && choice == selection, pick: pick)
    }

    /// ← ↑↓ →, half-height like the real keys. Orientation only.
    private var arrows: some View {
        let s = RoundedRectangle(cornerRadius: 4, style: .continuous)
        func key(_ g: String, _ h: CGFloat) -> some View {
            Text(g).font(.system(size: SetupScale.type(9))).foregroundStyle(Ink.text3)
                .frame(width: SetupScale.pt(24), height: SetupScale.pt(h))
                .background(s.fill(Ink.well)).overlay(s.strokeBorder(Ink.hairlineStrong, lineWidth: 0.5))
        }
        return HStack(alignment: .bottom, spacing: 2) {
            key("◀", 22)
            VStack(spacing: 2) { key("▲", 22); key("▼", 22) }
            key("▶", 22)
        }
        .accessibilityHidden(true)
    }
}

/// Setup's compact choice: the three caps every Mac has, in a row.
struct KeyChoiceStrip: View {
    let selection: HotkeyChoice
    let pick: (HotkeyChoice) -> Void

    var body: some View {
        HStack(spacing: SetupScale.pt(6)) {
            BottomRowKey(glyph: "fn", width: 52, choice: .fn, selected: selection == .fn, pick: pick)
            BottomRowKey(glyph: "⌘", word: side(.rightCommand, "⌘"), width: 72, choice: .rightCommand,
                   selected: selection == .rightCommand, pick: pick)
            BottomRowKey(glyph: "⌥", word: side(.rightOption, "⌥"), width: 72, choice: .rightOption,
                   selected: selection == .rightOption, pick: pick)
        }
    }

    /// "Right ⌘" → "Right": the glyph is already on the cap.
    private func side(_ c: HotkeyChoice, _ glyph: String) -> String {
        AppStrings.current.d.hotkey(c).replacingOccurrences(of: glyph, with: "").trimmingCharacters(in: .whitespaces)
    }
}

/// Press-to-pick: a local monitor on Soyla's own windows (no permission needed). Installed only while a picker is
/// open; F13 and ⌃⇧Space are swallowed when picked so they don't also type.
@MainActor final class KeyPickMonitor {
    private var token: Any?
    private var pick = KeyPick()

    var isActive: Bool { token != nil }

    func start(_ onPick: @escaping @MainActor (HotkeyChoice) -> Void) {
        stop()
        token = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] e in
            let code = e.keyCode, flags = e.modifierFlags, down = e.type == .keyDown
            let swallow = MainActor.assumeIsolated { () -> Bool in
                guard let self else { return false }
                let c = down ? self.pick.keyDown(keyCode: code, flags: flags) : self.pick.flagsChanged(keyCode: code, flags: flags)
                guard let c else { return false }
                onPick(c)
                return down
            }
            return swallow ? nil : e
        }
    }

    func stop() {
        if let token { NSEvent.removeMonitor(token) }
        token = nil; pick = KeyPick()
    }
}
