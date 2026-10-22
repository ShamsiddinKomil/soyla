import AppKit
import SwiftUI
import Combine

/// The pill: a borderless, non-activating panel that shows dictation state.
///
/// - Placement: on the screen under the pointer, chosen once at show; preset or dragged position stored as
///   fractions of `visibleFrame` (`PillGeometry`), so it survives display changes.
/// - Never `orderOut`: hidden = `alphaValue 0` + `ignoresMouseEvents` (window-server stalls on order in/out).
/// - Mouse only where it does something: the recording capsule (click = stop, drag = move), the Cancel at 4 s,
///   cards with buttons. Right-click there: "Hide for 1 hour", "Reset position".
/// - Reduce Motion: no scale, no frame animation, no wobble/ripple, instant fades.
@MainActor
public final class FloatingPanel {
    /// Settings → Pill → Place on screen: show the pill and let it be dragged until a few seconds after the last drag.
    public static let placeRequested = Notification.Name("ai.soyla.pill.place")
    private let panel: NSPanel
    private let model: PanelModel
    private let hosting: PillHostingView
    private let store: SettingsStore
    private var hideWork: DispatchWorkItem?
    private var screenWork: DispatchWorkItem?
    private var sinks = Set<AnyCancellable>()
    private var observers: [NSObjectProtocol] = []
    /// Logical visibility (the window itself stays ordered in, alpha 0 when hidden).
    private var shown = false
    /// Screen chosen at show; kept while visible.
    private var screenNumber: Int?
    private var screenVF: CGRect?
    private var previewing = false
    private var lastPrefs: Prefs
    private var announcedPhase: PanelModel.Phase = .idle
    /// Last frame `layout` aimed for (the window may still be animating towards it).
    private var targetFrame: CGRect = .zero

    private struct Prefs: Equatable { var position: PillPosition; var anchor: PillAnchor?; var snoozedUntil: Double? }

    public init(model: PanelModel, store: SettingsStore = .shared) {
        self.model = model
        self.store = store
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 158, height: 44),
                        styleMask: [.nonactivatingPanel, .borderless, .utilityWindow],
                        backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .statusBar
        p.hidesOnDeactivate = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.isMovableByWindowBackground = false        // dragging is done by PillHostingView (so a click can mean stop)
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.becomesKeyOnlyIfNeeded = true
        p.ignoresMouseEvents = true
        p.alphaValue = 0
        hosting = PillHostingView(rootView: PillView(model: model))
        // The window size is ours (`layout`). Left on, the hosting view resized the window itself mid-swap: a
        // failure card laid out at the 158 pt pill width wrapped into a 451 pt column and hung off the screen.
        hosting.sizingOptions = [.intrinsicContentSize]   // reports its size, never forces the window
        p.contentView = hosting
        panel = p
        let s = store.current
        lastPrefs = Prefs(position: s.pillPosition, anchor: s.pillAnchor, snoozedUntil: s.pillSnoozedUntil)
        model.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        hosting.handlesMouse = { [weak self] in self?.model.phase == .recording || self?.placing == true }
        hosting.onClick = { [weak self] in if self?.model.phase == .recording { self?.model.onStopRequested?() } }
        hosting.onDragEnded = { [weak self] in self?.dragEnded() }
        hosting.menuProvider = { [weak self] in self?.contextMenu() }

        model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.react() } }
        }.store(in: &sinks)
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: SettingsStore.didChange, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.settingsChanged() }
        })
        observers.append(nc.addObserver(forName: Self.placeRequested, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.place() }
        })
        // Fires several times per reconfiguration → debounce 400 ms.
        observers.append(nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.screenWork?.cancel()
                let w = DispatchWorkItem { MainActor.assumeIsolated { self?.screensChanged() } }
                self?.screenWork = w
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: w)
            }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
        })
    }

    // MARK: state → visibility

    private var snoozed: Bool { Date().timeIntervalSince1970 < (store.current.pillSnoozedUntil ?? 0) }

    /// Everything that can change the pill's size, visibility or mouse handling. Level and elapsed time are not in
    /// it: they used to re-run `react()` (a SwiftUI layout pass via `fittingSize`) up to 60 times a second.
    private struct Look: Equatable {
        var phase: PanelModel.Phase; var caption: String?; var live: String; var failure: String?
        var details: Bool; var wait: PillWaitStage; var arming: Bool; var micLive: Bool; var tapPending: Bool
    }
    private var lastLook: Look?
    private var lastWasCard = false

    private func react() {
        let look = Look(phase: model.phase, caption: model.caption, live: model.showLiveText ? model.liveText : "",
                        failure: model.failure?.title, details: model.showDetails, wait: model.waitStage,
                        arming: model.arming, micLive: model.micLive, tapPending: model.tapPending)
        guard look != lastLook else { return }
        lastLook = look
        announce()
        switch model.phase {
        case .idle, .needsPermission, .ready:
            if !previewing { scheduleHide(after: 0.05) }   // permissions live in Settings; the pill is only for dictation
        case .recording, .transcribing, .cleaning, .pasting:
            if snoozed { hideNow() } else if model.tapPending { dimOut() } else { show() }
        case .done:
            if model.showDetails && !snoozed { show(); scheduleHide(after: 6) } else { scheduleHide(after: 0.05) }
        case .failed:
            show(force: true)                              // failures show even when snoozed: never lose words silently
            scheduleDismiss(after: model.failure?.dismissAfter ?? 8)
        }
        // Pill ↔ card is a different view, not a bigger pill: swap the size at once (animating it squeezed the
        // card's text into the pill's width for a few frames).
        let card = model.phase == .failed || (model.phase == .done && model.showDetails)
        let swap = card != lastWasCard
        lastWasCard = card
        if shown && !hosting.isDragging { layout(animated: !swap) }
        updateMouse()
        // SwiftUI applies the new body after this call; measure again once the swap has rendered.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.shown, !self.hosting.isDragging else { return }
                self.layout(animated: !swap)
            }
        }
    }

    /// Called by the pipeline at key-down and by the menu. Places the pill on the screen under the pointer.
    public func show() { show(force: false) }

    private func show(force: Bool) {
        hideWork?.cancel(); hideWork = nil
        if !force && snoozed && model.phase != .failed { return }
        if !shown {
            pickScreen()
            let s = store.current
            let lim = DictationPipeline.recordingLimits(s)
            model.warnAtSec = lim.warn
            model.hardStopSec = lim.stop
            model.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            model.appeared = false
            layout(animated: false)
            if !panel.isVisible { panel.orderFrontRegardless() }   // once; afterwards only alpha changes
            shown = true
            hosting.setAccessibilityHidden(false)
            model.appeared = true
            fade(to: 1)
        } else {
            if dimmed { dimmed = false; fade(to: 1) }        // the second press of a double-tap: straight back
            layout(animated: true)
        }
        updateMouse()
    }

    /// A tap's release: fade out at once (it used to wait, dimmed, for the whole double-tap window: up to 1.3 s),
    /// but stay logically shown, so a second press brings it back with a pure fade, no scale or layout reset.
    private var dimmed = false
    private func dimOut() {
        guard shown, !dimmed else { return }
        dimmed = true
        panel.ignoresMouseEvents = true
        fade(to: 0)
    }

    public func scheduleHide(after sec: Double) {
        hideWork?.cancel()
        guard shown else { return }
        let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.hideNow() } }
        hideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + sec, execute: w)
    }

    /// F-05: a card ends itself (the phase goes idle), so nothing can bring it back later; a new hold replaces it.
    private func scheduleDismiss(after sec: Double) {
        hideWork?.cancel()
        let shownFailure = model.failure
        let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated {
            guard let self, self.model.phase == .failed, self.model.failure == shownFailure else { return }
            self.model.phase = .idle
        } }
        hideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + sec, execute: w)
    }

    private func hideNow() {
        hideWork?.cancel(); hideWork = nil
        previewing = false; placing = false
        if model.placeHint { model.placeHint = false }
        guard shown else { return }
        shown = false
        dimmed = false
        panel.ignoresMouseEvents = true
        hosting.setAccessibilityHidden(true)            // F-29: a hidden pill says nothing to VoiceOver
        model.appeared = false
        fade(to: 0, close: true)
    }

    /// In 100 ms. A tap's dim-out: 120 ms ease-out. A close: `PillMotion` (the pill shrinks while still visible).
    private func fade(to alpha: CGFloat, close: Bool = false) {
        if model.reduceMotion { stop("alpha"); panel.alphaValue = alpha; return }
        let from = panel.alphaValue
        if close {
            run("alpha", duration: PillMotion.closeDuration, curve: PillMotion.closeAlpha) { [weak self] e in
                self?.panel.alphaValue = from * (1 - e)
            }
            return
        }
        run("alpha", duration: alpha > from ? 0.1 : 0.12) { [weak self] e in self?.panel.alphaValue = from + (alpha - from) * e }
    }

    // Own 60 Hz stepper instead of `animator()`: an NSWindow alpha animation interrupted by the opposite one
    // (show → hide within 150 ms, i.e. every tap) was measured ending at alpha 1, leaving a stuck pill.
    // Here a new animation of the same property always replaces the old one and ends exactly on its target.
    private var steppers: [String: Timer] = [:]

    private func run(_ key: String, duration: Double, curve: @escaping @Sendable (Double) -> Double = PillMotion.easeOut,
                     _ apply: @escaping @MainActor @Sendable (CGFloat) -> Void) {
        stop(key)
        let start = CACurrentMediaTime()
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            let id = ObjectIdentifier(timer)   // the Timer itself stays outside the main-actor closure (not Sendable)
            let done = MainActor.assumeIsolated { () -> Bool in
                let p = min(1, (CACurrentMediaTime() - start) / duration)
                apply(CGFloat(curve(p)))
                if p >= 1, let cur = self?.steppers[key], ObjectIdentifier(cur) == id { self?.steppers[key] = nil }
                return p >= 1
            }
            if done { timer.invalidate() }   // main run loop: same thread the timer was added on
        }
        RunLoop.main.add(t, forMode: .common)
        steppers[key] = t
    }

    private func stop(_ key: String) { steppers[key]?.invalidate(); steppers[key] = nil }

    /// Clicks pass through unless the pill shows something clickable.
    private func updateMouse() {
        let interactive: Bool = {
            guard shown, !dimmed else { return false }   // an invisible pill must not catch clicks
            switch model.phase {
            case .recording: return true
            case .transcribing, .cleaning, .pasting: return model.waitStage == .slow
            case .failed: return model.failure != nil
            case .done: return model.showDetails
            default: return previewing
            }
        }()
        if panel.ignoresMouseEvents == interactive { panel.ignoresMouseEvents = !interactive }
    }

    // MARK: placement

    private func pickScreen() {
        let screens = NSScreen.screens
        let i = PillGeometry.screenIndex(containing: NSEvent.mouseLocation, frames: screens.map(\.frame))
        guard let scr = i.map({ screens[$0] }) ?? NSScreen.main ?? screens.first else { return }
        screenNumber = Self.number(of: scr)
        screenVF = scr.visibleFrame
    }

    private static func number(of s: NSScreen) -> Int? {
        (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.intValue
    }

    private func layout(animated: Bool) {
        if screenVF == nil { pickScreen() }
        guard let vf = screenVF else { return }
        let fit = hosting.fittingSize
        let size = CGSize(width: min(ceil(fit.width), 620), height: ceil(fit.height))
        let s = store.current
        let target = PillGeometry.frame(size: size, position: s.pillPosition, anchor: s.pillAnchor, in: vf)
        guard target != targetFrame || (steppers["frame"] == nil && target != panel.frame) else { return }
        targetFrame = target
        if animated && shown && !model.reduceMotion {
            let from = panel.frame
            run("frame", duration: 0.16) { [weak self] e in
                guard let self, !self.hosting.isDragging else { self?.stop("frame"); return }
                self.panel.setFrame(CGRect(x: from.minX + (target.minX - from.minX) * e, y: from.minY + (target.minY - from.minY) * e,
                                           width: from.width + (target.width - from.width) * e,
                                           height: from.height + (target.height - from.height) * e), display: true)
            }
        } else {
            stop("frame")
            panel.setFrame(target, display: true)
        }
    }

    /// Displays added/removed/rearranged (debounced): keep the same display if it still exists.
    private func screensChanged() {
        guard shown else { screenVF = nil; screenNumber = nil; return }
        if let n = screenNumber, let scr = NSScreen.screens.first(where: { Self.number(of: $0) == n }) {
            screenVF = scr.visibleFrame
        } else {
            pickScreen()
        }
        layout(animated: false)
    }

    private func dragEnded() {
        // The display the pill was dropped on becomes its screen; the position is stored relative to it.
        let f = panel.frame
        let screens = NSScreen.screens
        if let i = PillGeometry.screenIndex(containing: CGPoint(x: f.midX, y: f.midY), frames: screens.map(\.frame)) {
            screenNumber = Self.number(of: screens[i]); screenVF = screens[i].visibleFrame
        }
        guard let vf = screenVF else { return }
        let a = PillGeometry.anchor(of: f, in: vf)
        lastPrefs.position = .custom; lastPrefs.anchor = a    // our own write: no preview
        store.update { $0.pillPosition = .custom; $0.pillAnchor = a }
        layout(animated: true)                                 // settles inside the margins if dropped past an edge
        if placing { scheduleHide(after: 4) }
    }

    private func settingsChanged() {
        let s = store.current
        let p = Prefs(position: s.pillPosition, anchor: s.pillAnchor, snoozedUntil: s.pillSnoozedUntil)
        guard p != lastPrefs else { return }
        let moved = p.position != lastPrefs.position || p.anchor != lastPrefs.anchor
        lastPrefs = p
        if snoozed && shown && model.phase != .failed { hideNow(); return }
        guard moved else { return }
        if shown { layout(animated: true) } else { preview() }
    }

    /// Place mode: the pill stays up and draggable; it hides 4 s after the last drag (10 s if never dragged).
    private var placing = false

    private func place() {
        guard [.idle, .ready, .needsPermission].contains(model.phase) else { return }
        previewing = true; placing = true
        model.placeHint = true
        show(force: true)
        updateMouse()
        scheduleHide(after: 10)
    }

    /// Settings → Pill → Position: show the capsule at its new place for a moment.
    private func preview() {
        guard !snoozed, [.idle, .ready, .needsPermission].contains(model.phase) else { return }
        previewing = true
        show(force: true)
        scheduleHide(after: 1.5)
    }

    // MARK: right-click

    private func contextMenu() -> NSMenu {
        let m = NSMenu()
        m.addItem(ClosureMenuItem(AppStrings.for(model.uiLanguage).d.pcHide1h) { [weak self] in
            guard let self else { return }
            self.store.update { $0.pillSnoozedUntil = Date().addingTimeInterval(3600).timeIntervalSince1970 }
            self.hideNow()
        })
        m.addItem(ClosureMenuItem(AppStrings.for(model.uiLanguage).d.pcResetPos) { [weak self] in
            self?.store.update { $0.pillPosition = .bottomCenter; $0.pillAnchor = nil }
        })
        return m
    }

    // MARK: VoiceOver

    private func announce() {
        let ph = model.phase
        guard ph != announcedPhase else { return }
        announcedPhase = ph
        guard let text = PanelModel.announcement(for: ph, failure: model.failure?.shown(model.uiLanguage, readiness: model.readiness()), language: model.uiLanguage) else { return }
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }
}

/// NSMenuItem that runs a closure (the pill's right-click menu).
final class ClosureMenuItem: NSMenuItem {
    private let run: () -> Void
    init(_ title: String, _ run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError("unused") }
    @objc private func fire() { run() }
}

/// Hosting view that turns mouse input on the recording capsule into click (= stop) or drag (= move).
/// Other states pass mouse events to SwiftUI so buttons work.
final class PillHostingView: NSHostingView<PillView> {
    var handlesMouse: () -> Bool = { false }
    var onClick: (() -> Void)?
    var onDragEnded: (() -> Void)?
    var menuProvider: (() -> NSMenu?)?
    private(set) var isDragging = false
    private var downPoint: NSPoint?
    private var downOrigin: NSPoint = .zero

    required init(rootView: PillView) { super.init(rootView: rootView) }
    required init?(coder: NSCoder) { fatalError("unused") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with e: NSEvent) {
        guard handlesMouse() else { super.mouseDown(with: e); return }
        downPoint = NSEvent.mouseLocation
        downOrigin = window?.frame.origin ?? .zero
        isDragging = false
    }

    override func mouseDragged(with e: NSEvent) {
        guard let start = downPoint, let w = window else { super.mouseDragged(with: e); return }
        let p = NSEvent.mouseLocation
        let dx = p.x - start.x, dy = p.y - start.y
        if !isDragging && hypot(dx, dy) < 3 { return }     // tiny jitter is still a click
        isDragging = true
        w.setFrameOrigin(NSPoint(x: downOrigin.x + dx, y: downOrigin.y + dy))
    }

    override func mouseUp(with e: NSEvent) {
        guard downPoint != nil else { super.mouseUp(with: e); return }
        downPoint = nil
        if isDragging { isDragging = false; onDragEnded?() } else { onClick?() }
    }

    override func rightMouseDown(with e: NSEvent) {
        if let m = menuProvider?() { NSMenu.popUpContextMenu(m, with: e, for: self) } else { super.rightMouseDown(with: e) }
    }
}

/// Default look: a 150×36 capsule with a dot and seven bars that follow your voice (in dB). While processing
/// the bars ripple; words appear only when it gets slow (2 s / 4 s) or when details are on.
/// Failures get a card with a plain-language title, what to do, and Retry / Settings buttons.
struct PillView: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        Group {
            if model.phase == .failed, let f = model.failure { failureCard(f) }
            else if model.phase == .done && model.showDetails { detailsCard }
            else { activePill }
        }
        .padding(4)
        .scaleEffect(x: model.reduceMotion || model.appeared ? 1 : PillMotion.closeScaleX,
                     y: model.reduceMotion || model.appeared ? 1 : PillMotion.closeScaleY)
        // In: a quick spring. Out: an ease-out shrink while the window is still nearly opaque (`PillMotion`).
        .animation(model.reduceMotion ? nil : model.appeared ? .spring(response: 0.18, dampingFraction: 0.82)
                   : .easeOut(duration: PillMotion.closeDuration), value: model.appeared)
    }

    // MARK: recording / processing

    private var processing: Bool { model.isProcessing }
    private var showsLiveText: Bool { model.showLiveText && !model.liveText.isEmpty && (model.phase == .recording || processing) }
    private var mode: Waveform.Mode {
        // .done keeps the working wave while the pill fades (it used to snap to the dim still bars for a frame).
        if processing || model.phase == .done { return .processing }
        return model.phase == .recording && !model.arming && !model.tapPending ? .live : .arming
    }
    private var tintColor: Color {
        switch model.tint { case .normal: return .white; case .amber: return .orange; case .red: return .red }
    }
    private var minWidth: CGFloat { model.caption == nil ? 150 : 180 }

    private var activePill: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                // One fixed slot in every phase: dropping the dot at release used to shrink and slide the pill.
                Group {
                    if model.phase == .recording && model.locked {
                        Image(systemName: "lock.fill").font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(model.tint == .normal ? Color.white.opacity(0.85) : tintColor)
                            .accessibilityHidden(true)
                    } else if model.phase == .recording {
                        Circle().fill(model.arming || model.tapPending || !model.micLive ? Color.white.opacity(0.3) : (model.tint == .normal ? Color.red : tintColor))
                            .frame(width: 6, height: 6)
                    } else {
                        Color.clear
                    }
                }
                .frame(width: 8, height: 10)
                Waveform(level: { [model] in model.displayLevel }, mode: mode, color: tintColor, reduceMotion: model.reduceMotion)
                    .animation(model.reduceMotion ? nil : .easeInOut(duration: 0.18), value: model.tint)
                if let c = model.caption {
                    Text(c).font(.system(size: 11, weight: .medium))
                        .foregroundStyle(model.tint == .normal ? Color.white.opacity(0.75) : tintColor)
                        .lineLimit(1).fixedSize()
                    if processing && model.waitStage == .slow {
                        Button(AppStrings.for(model.uiLanguage).cancel) { model.onCancel?() }.controlSize(.small)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            if showsLiveText {
                Text(model.liveText)
                    .font(.system(size: 13)).foregroundStyle(.white.opacity(0.85))
                    .lineLimit(3).truncationMode(.head)                 // keep the newest words visible
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 488, alignment: .leading)
            }
        }
        // A close clears the bars first, then the empty capsule shrinks away (measured on Wispr Flow, 2026-10-20).
        .opacity(model.reduceMotion || model.appeared ? 1 : 0)
        .animation(model.appeared ? nil : .easeOut(duration: PillMotion.contentOut), value: model.appeared)
        .padding(.horizontal, 16).padding(.vertical, showsLiveText ? 9 : 0)
        .frame(minWidth: minWidth, minHeight: 36)
        .background(shape(showsLiveText ? 16 : 18).fill(Color.black.opacity(0.82)))
        .overlay(shape(showsLiveText ? 16 : 18).strokeBorder(Color.white.opacity(0.12)))
        .animation(model.reduceMotion ? nil : .easeOut(duration: 0.3), value: model.caption)
        .animation(model.reduceMotion ? nil : .easeOut(duration: 0.2), value: showsLiveText)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(model.caption ?? (model.locked ? "Locked, press \(model.hotkeyShortLabel) to finish" : model.statusLine))
    }

    // MARK: details (opt-in)

    private var detailsCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(AppStrings.for(model.uiLanguage).d.pcPasted).font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 12)
                Button(AppStrings.for(model.uiLanguage).copy) { Paster.copy(model.finalText) }.controlSize(.mini)
            }
            if !model.finalText.isEmpty {
                Text(model.finalText).font(.system(size: 14)).lineLimit(4).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 520, alignment: .leading)
            }
            if !model.latencyLine.isEmpty {
                Text(model.latencyLine).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(minWidth: 240, alignment: .leading)
        .background(.ultraThinMaterial, in: shape(14))
        .overlay(shape(14).strokeBorder(Color.white.opacity(0.08)))
    }

    // MARK: failure

    /// V-02/V-10: the card is part of the pill: the pill's own solid black, white type, dark controls whatever the
    /// Mac's appearance or what lies under it. Red only for real failures; a missing key is a calm saffron dot.
    private func failureCard(_ english: PillFailure) -> some View {
        let f = english.shown(model.uiLanguage, readiness: model.readiness()), t = AppStrings.for(model.uiLanguage)
        let keyCard = f.kind == .info && f.fix == .connectKey
        let (icon, tint): (String, Color) = {
            switch f.kind {
            case .error: return ("exclamationmark.octagon.fill", Ink.signal)
            case .warning: return ("doc.on.clipboard.fill", Ink.warn)
            case .soft: return ("waveform.slash", Color.white.opacity(0.55))
            case .info: return ("info.circle.fill", Ink.lazur)
            }
        }()
        return HStack(alignment: f.hint.isEmpty ? .center : .top, spacing: 10) {
            if keyCard {
                Circle().fill(Ink.warn).frame(width: 8, height: 8).padding(.top, 6).padding(.horizontal, 4).accessibilityHidden(true)
            } else {
                Image(systemName: icon).font(.system(size: 16)).foregroundStyle(tint).accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(f.title).font(.system(size: 14.5, weight: .semibold)).foregroundStyle(Color.white)
                if !f.hint.isEmpty {
                    Text(f.hint).font(.system(size: 13)).foregroundStyle(Color.white.opacity(0.7))
                        .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 320, alignment: .leading)
                }
                if f.canRetry || f.openSettings || f.fix != nil {
                    HStack(spacing: 6) {
                        if f.canRetry { Button(t.pillRetry) { model.onRetry?() }.controlSize(.small).keyboardShortcut(.defaultAction) }
                        // APP-1 (c): the button names its fix ("Connect…", "Allow…", "Open Languages") and routes into setup.
                        if let fix = f.fix { Button(fix.button(t)) { model.onOpenSettings?() }.controlSize(.small) }
                        else if f.openSettings { Button(t.mmSettingsTab) { model.onOpenSettings?() }.controlSize(.small) }
                    }.padding(.top, 5)
                }
            }
            if f.kind != .soft {
                // F-05: a 20 pt hit area, not the 7 pt glyph.
                Button { model.phase = .idle } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).frame(width: 20, height: 20).contentShape(Rectangle())
                }
                    .buttonStyle(.plain).foregroundStyle(Color.white.opacity(0.6)).help(t.d.pcDismiss)
                    .accessibilityLabel(t.d.pcDismiss)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, f.kind == .soft ? 8 : 12)
        .frame(maxWidth: 400)
        .background(shape(14).fill(Ink.pill))
        .overlay(shape(14).strokeBorder(Color.white.opacity(0.12)))
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(f.hint.isEmpty ? f.title : "\(f.title). \(f.hint)")
    }

    private func shape(_ r: CGFloat) -> RoundedRectangle { RoundedRectangle(cornerRadius: r, style: .continuous) }
}

/// The brand's five bars in motion. Live: each bar eases towards `level × its silhouette height` at 60 fps, the
/// outer bars a little slower than the middle ones, so speech reads as one moving shape (no random wobble).
/// Processing: a slow travelling swell. Arming: the silhouette dimmed. Rest: the silhouette.
/// Reduce Motion: no swell; the live bars still follow the voice (that is information, not decoration).
struct Waveform: View {
    enum Mode: Equatable { case live, arming, processing, rest }
    /// Read once per frame (not a SwiftUI input, so a new level never re-renders the view).
    var level: () -> Double
    var mode: Mode
    var color: Color
    var reduceMotion: Bool
    /// Height of the tallest bar (18 in the pill; the in-window `Mark` passes its own).
    var barHeight: CGFloat = 18

    /// Per-bar eased heights, kept outside SwiftUI state so a frame never triggers a view update.
    final class Eased { var h: [Double] = Brand.bars.map { 0.2 + 0.5 * $0 }; var last: TimeInterval = 0 }
    @State private var eased = Eased()

    private var barW: CGFloat { max(2.5, barHeight / 4.5) }
    private var gap: CGFloat { barW * 0.8 }
    private var width: CGFloat { CGFloat(Brand.bars.count) * barW + CGFloat(Brand.bars.count - 1) * gap }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: mode == .rest || mode == .arming || (reduceMotion && mode == .processing))) { ctx in
            Canvas { g, size in
                let t = ctx.date.timeIntervalSinceReferenceDate
                let hs = heights(at: t)
                var x: CGFloat = 0
                for h in hs {
                    let H = max(barW, barHeight * CGFloat(h))
                    g.fill(Capsule().path(in: CGRect(x: x, y: (size.height - H) / 2, width: barW, height: H)), with: .color(color.opacity(opacity)))
                    x += barW + gap
                }
            }
        }
        .frame(width: width, height: barHeight)
    }

    private var opacity: Double {
        switch mode { case .live: return 0.95; case .arming: return 0.45; case .processing: return 0.9; case .rest: return 0.8 }
    }

    private static let silhouette: [Double] = Brand.bars.map { 0.2 + 0.5 * $0 }

    private func heights(at t: TimeInterval) -> [Double] {
        switch mode {
        case .rest, .arming: return Self.silhouette
        case .processing where reduceMotion: return Self.silhouette.map { $0 * 0.7 }
        default: break
        }
        let e = eased
        let dt = e.last == 0 ? 1.0 / 60 : min(0.05, t - e.last)
        e.last = t
        Self.ease(&e.h, toward: mode == .processing ? Self.swell(at: t) : Self.live(level()), dt: dt)
        return e.h
    }

    /// Live targets: silence sits at 0.16, full voice reaches the brand silhouette.
    nonisolated static func live(_ level: Double) -> [Double] { Brand.bars.map { 0.16 + min(1, level * 1.15) * $0 * 0.84 } }
    /// Processing targets: a ~1.1 s wave travelling left to right, tall enough to read as "working", not stalled.
    nonisolated static func swell(at t: TimeInterval) -> [Double] { Brand.bars.indices.map { 0.24 + 0.46 * (0.5 + 0.5 * sin(t * 5.7 - Double($0) * 0.9)) } }
    /// One frame of easing, the only smoothing between mic and bars: attack 30 ms, release 90 ms, the outer bars
    /// up to 25 % slower than the middle one.
    nonisolated static func ease(_ h: inout [Double], toward target: [Double], dt: Double) {
        for i in h.indices {
            let outer = 1 + 0.25 * abs(Double(i) - 2) / 2
            let tau = (target[i] > h[i] ? 0.03 : 0.09) * outer
            h[i] += (target[i] - h[i]) * (1 - exp(-dt / tau))
        }
    }
}

/// The pill's close, from frame captures (2026-10-20). Before: the window alpha eased out over 120 ms, so the pill
/// lost half its opacity in the first frame and read as a blink. Wispr Flow clears its content in one frame, then
/// the capsule shrinks (≈ 195 → 80 px wide) over ~110 ms on an ease-out. Here: bars fade in 60 ms, the capsule
/// shrinks to 60 % × 70 % on an ease-out, and the window stays nearly opaque until the shrink is mostly done.
enum PillMotion {
    static let closeDuration = 0.18
    static let contentOut = 0.06
    static let closeScaleX: CGFloat = 0.6
    static let closeScaleY: CGFloat = 0.7

    @Sendable static func easeOut(_ p: Double) -> Double { 1 - pow(1 - p, 3) }
    /// Progress of the close's alpha: slow first (the shrink is seen), all the way out at the end.
    @Sendable static func closeAlpha(_ p: Double) -> Double { pow(min(max(p, 0), 1), 3) }
}
