import AppKit
import SwiftUI
import Observation

// OB-2: the setup window (960 wide, hidden title bar, centred, height per step) and the System Settings helper note.

@MainActor
final class SetupWindowController: NSObject, NSWindowDelegate {
    private let model: SetupModel
    private let panel: PanelModel
    private var window: NSWindow?

    init(model: SetupModel, panel: PanelModel) {
        self.model = model
        self.panel = panel
        super.init()
        model.onPresent = { [weak self] in self?.show() }
        model.onDismiss = { [weak self] in self?.window?.close() }
        model.onResize = { [weak self] h in self?.resize(to: h) }
        model.activateWindow = { [weak self] in self?.activate() }
    }

    /// The main window's frame when setup opens from the app: setup centres on it instead of the screen, so it reads
    /// as a step of that window and not a second window popping out of its corner (owner, 2026-10-18).
    var anchor: () -> NSRect? = { nil }

    private func show() {
        let fresh = window == nil || window?.isVisible == false
        if window == nil { window = makeWindow() }
        if fresh, let w = window, let a = anchor() { w.setFrame(Self.centred(w.frame.size, on: a, within: w.screen?.visibleFrame), display: false) }
        activate()
    }

    /// `size` centred on `anchor`, pulled back inside `bounds` (the visible screen) when it would hang off an edge.
    static func centred(_ size: CGSize, on anchor: NSRect, within bounds: NSRect?) -> NSRect {
        var f = NSRect(x: (anchor.midX - size.width / 2).rounded(), y: (anchor.midY - size.height / 2).rounded(), width: size.width, height: size.height)
        if let b = bounds {
            f.origin.x = min(max(f.minX, b.minX), b.maxX - f.width)
            f.origin.y = min(max(f.minY, b.minY), b.maxY - f.height)
        }
        return f
    }

    private func activate() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let size = NSSize(width: SetupFlow.width, height: model.height)
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        w.title = "Soyla"
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true      // the traffic lights sit on the lapis stage
        w.isMovableByWindowBackground = true
        w.backgroundColor = NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(hex: 0x15181D) : NSColor(hex: 0xF6F7F9) }
        let host = NSHostingView(rootView: SetupView(model: model, panel: panel))
        host.sizingOptions = []                  // the controller owns the size (per step), not SwiftUI
        w.contentView = host
        w.isReleasedWhenClosed = false
        w.delegate = self
        // Centred on the screen in front, from its visible frame (the old sheet's window could open half off-screen).
        let screen = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: SetupScale.pt(1440), height: SetupScale.pt(900))
        w.setFrame(NSRect(x: (screen.midX - size.width / 2).rounded(), y: (screen.midY - size.height / 2 + 40).rounded(),
                          width: size.width, height: size.height), display: false)
        return w
    }

    /// Keeps the top edge where it is; 0.25 s ease-out, instant under Reduce Motion.
    private func resize(to height: CGFloat) {
        guard let w = window, abs(w.frame.height - height) > 0.5 else { return }
        var f = w.frame
        f.origin.y = f.maxY - height
        f.size.height = height
        if let vf = w.screen?.visibleFrame, f.minY < vf.minY { f.origin.y = vf.minY }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || !w.isVisible {
            w.setFrame(f, display: true)
            return
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            w.animator().setFrame(f, display: true)
        }
    }

    func windowWillClose(_ notification: Notification) { model.windowClosed() }
}

// MARK: - System Settings helper

@MainActor @Observable
final class HelperState {
    var kind: SettingsHelperPanel.Kind = .fn
    var strings: SetupStrings = .en
    var missing = false
    var arrow: HelperPlacement.Arrow = .none
}

/// A small lapis note docked beside the System Settings window while a permission pane is open. Borderless,
/// non-activating, floating; it never covers the list it points to and closes itself when the grant arrives.
@MainActor
final class SettingsHelperPanel {
    enum Kind: Equatable { case toggle(canBeMissing: Bool), fn }

    private var panel: NSPanel?
    private var host: NSHostingView<HelperView>?
    private let state = HelperState()
    private var shownAt: Date?

    func show(_ kind: Kind, strings: SetupStrings) {
        state.kind = kind; state.strings = strings; state.missing = false
        shownAt = Date()
        if panel == nil { makePanel() }
        reposition()
    }

    func update(strings: SetupStrings) {
        state.strings = strings
        if shownAt != nil { reposition() }
    }

    /// Called every poll while a pane is open. Waits up to 1.5 s for System Settings to open before falling back to
    /// the screen's top-right corner, so the note doesn't jump.
    func reposition() {
        guard let p = panel, let host, let shown = shownAt else { return }
        let frame = SystemSurfaces.settingsWindowFrame()
        if frame == nil && Date().timeIntervalSince(shown) < 1.5 { return }
        let size = host.fittingSize
        let screen = frame.flatMap { f in NSScreen.screens.first { $0.frame.intersects(f) } } ?? NSScreen.main ?? NSScreen.screens.first
        let placed = HelperPlacement.place(settings: frame, helper: size, screen: screen?.visibleFrame ?? .zero)
        if state.arrow != placed.arrow { state.arrow = placed.arrow }
        let target = NSRect(origin: placed.origin, size: size)
        if p.frame != target { p.setFrame(target, display: true) }
        if !p.isVisible { p.orderFrontRegardless() }
    }

    func close() {
        shownAt = nil
        panel?.orderOut(nil)
    }

    private func makePanel() {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: SetupScale.pt(240), height: SetupScale.pt(120)), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        p.level = .floating
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false              // Soyla is in the background while System Settings is in front
        p.becomesKeyOnlyIfNeeded = true
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false                      // the SwiftUI card draws its own
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let h = NSHostingView(rootView: HelperView(state: state))
        p.contentView = h
        panel = p
        host = h
    }
}

struct HelperView: View {
    let state: HelperState

    private var title: String {
        switch state.kind {
        case .fn: return state.strings.hFnT
        case .toggle: return state.missing ? state.strings.hMissingT : state.strings.hAxT
        }
    }
    private var detail: String {
        switch state.kind {
        case .fn: return state.strings.hFnB
        case .toggle: return state.missing ? state.strings.hMissingB : state.strings.hAxB
        }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            HStack(alignment: .top, spacing: SetupScale.pt(12)) {
                BrandMark(width: SetupScale.pt(30), capsule: .white, bar: Ink.lapis)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: SetupScale.type(13), weight: .semibold)).foregroundStyle(Ink.onLapis)
                    Text(detail).font(.system(size: SetupScale.type(12))).foregroundStyle(Ink.onLapis2).fixedSize(horizontal: false, vertical: true)
                    if state.kind == .toggle(canBeMissing: true) && !state.missing {
                        Button(state.strings.hMissing) { state.missing = true }
                            .buttonStyle(.plain).font(.system(size: SetupScale.type(12))).underline().foregroundStyle(Ink.onLapis2).padding(.top, 6)
                    }
                }
            }
            .padding(.horizontal, SetupScale.pt(14)).padding(.vertical, SetupScale.pt(12))
            .frame(width: SetupScale.pt(230), alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Ink.lapisDeep))
            .shadow(color: .black.opacity(0.45), radius: 14, y: 10)
            arrow
        }
        .padding(SetupScale.pt(10))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var arrow: some View {
        switch state.arrow {
        case .left:
            RoundedRectangle(cornerRadius: 2).fill(Ink.lapisDeep).frame(width: SetupScale.pt(14), height: SetupScale.pt(14)).rotationEffect(.degrees(45))
                .offset(x: -6, y: 17).accessibilityHidden(true)
        case .top:
            RoundedRectangle(cornerRadius: 2).fill(Ink.lapisDeep).frame(width: SetupScale.pt(14), height: SetupScale.pt(14)).rotationEffect(.degrees(45))
                .offset(x: 24, y: -6).accessibilityHidden(true)
        case .none: EmptyView()
        }
    }
}
