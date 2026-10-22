import AppKit
import SwiftUI

/// Set only by `docs-shots`, never by the app: lists that always scroll draw unscrolled (a snapshot draws a scroll
/// view's content blank), and the developer-only "key from an environment variable" note stays hidden (the demo key
/// comes from one; a real install's comes from the Keychain). A plain EnvironmentKey: `@Entry` needs a macro plugin
/// that Command Line Tools don't ship.
struct DocsCaptureKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var docsCapture: Bool {
        get { self[DocsCaptureKey.self] }
        set { self[DocsCaptureKey.self] = newValue }
    }
}

/// A scroll view, except in a docs capture (`docsCapture`).
struct DocsScrollView<Content: View>: View {
    @Environment(\.docsCapture) private var unscrolled
    @ViewBuilder var content: Content
    var body: some View {
        if unscrolled { content } else { ScrollView { content } }
    }
}

/// The app's switch. In the app it is the system switch; in a docs capture it draws one of the same size, because on
/// macOS 26 the system switch's tint is composited by the window server and a snapshot draws its track grey.
struct AppSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View { AppSwitch(configuration: configuration) }
}

extension ToggleStyle where Self == AppSwitchStyle {
    static var app: AppSwitchStyle { AppSwitchStyle() }
}

private struct AppSwitch: View {
    let configuration: ToggleStyleConfiguration
    @Environment(\.docsCapture) private var docsCapture
    @Environment(\.isEnabled) private var enabled

    /// Every app switch hides its label (`appControl()` / `rowControl()`), so the drawn one has none.
    var body: some View {
        if docsCapture {
            drawn
        } else {
            Toggle(configuration).toggleStyle(.switch)
        }
    }

    /// 54 × 24 pt like `NSSwitch` (macOS 26): a lazur track when on, a white capsule knob.
    private var drawn: some View {
        let on = configuration.isOn
        return ZStack(alignment: on ? .trailing : .leading) {
            Capsule().fill(on ? Ink.lazur : Color(nsColor: .tertiaryLabelColor).opacity(0.5))
            Capsule().fill(.white).frame(width: 32, height: 20).padding(2)
                .shadow(color: .black.opacity(0.18), radius: 1, y: 0.5)
        }
        .frame(width: 54, height: 24)
        .opacity(enabled ? 1 : 0.5)
    }
}

/// `soyla docs-shots <dir>`: renders the docs pictures without showing anything on screen. The process never
/// activates (no Dock icon, no focus change), windows are never ordered in, nothing records the screen, and no hotkey
/// tap, microphone or poller starts. Run it through `scripts/docs_shots.sh`, which points settings, History and the
/// Keychain at a throwaway demo profile (the CLI honours `SOYLA_HOME` / `SOYLA_SETTINGS_SUITE` /
/// `SOYLA_KEYCHAIN_SERVICE`), so no real data can reach a picture.
@MainActor
public enum DocsShots {
    struct ShotError: Error, LocalizedError {
        let errorDescription: String?
        init(_ m: String) { errorDescription = m }
    }

    /// Controls ask the app, not only the window, whether to draw active; this one says yes without activating.
    final class ShotApp: NSApplication {
        override var isActive: Bool { true }
    }

    /// Draws as the frontmost window does (an inactive window greys filled buttons), without ever being shown.
    final class KeyWindow: NSWindow {
        override var isKeyWindow: Bool { true }
        override var isMainWindow: Bool { true }
    }

    public static func run(args: [String]) throws {
        guard let dir = args.first else { throw ShotError("usage: soyla docs-shots <dir> [name…]") }
        let out = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        if args.dropFirst().first == "--video-slides", args.count > 2 {
            _ = ShotApp.shared
            NSApp.setActivationPolicy(.prohibited)
            try videoSlides(to: out, media: URL(fileURLWithPath: args[2], isDirectory: true))
            return
        }
        if args.dropFirst().first == "--demo" {
            _ = ShotApp.shared
            NSApp.setActivationPolicy(.prohibited)
            try demo(to: out, dark: args.contains("--dark"))
            return
        }
        let only = Set(args.dropFirst())
        _ = ShotApp.shared                     // first access picks the class: NSApp is a ShotApp
        NSApp.setActivationPolicy(.prohibited)
        let keyPass = DevOverrides.environment["OPENROUTER_API_KEY"] != nil
        for shot in shots where (only.isEmpty || only.contains(shot.name)) && shot.noKey != keyPass {
            for dark in shot.looks {
                let name = shot.name + (dark ? "-dark" : "")
                let (view, want) = shot.make()
                let size = try render(view, size: want, dark: dark, measure: shot.measure, chrome: shot.chrome, to: out.appendingPathComponent("\(name)@2x.png"))
                print("\(name)@2x.png \(Int(size.width))×\(Int(size.height))")
            }
        }
    }

    struct Shot {
        let name: String
        var looks: [Bool] = [false]
        /// The main window grows to its content (full-page pictures); setup keeps the size it asks for.
        var measure = true
        /// Window frame and traffic lights (off for the pill, which floats without a window).
        var chrome = true
        /// Rendered in the script's second pass, which has no demo key in the environment ("no key yet" states).
        var noKey = false
        let make: @MainActor () -> (AnyView, CGSize)

        init(name: String, looks: [Bool] = [false], noKey: Bool = false, view: @escaping @MainActor () -> AnyView) {
            self.name = name; self.looks = looks; self.noKey = noKey
            make = { (view(), Ink.appWindow) }
        }

        init(setup name: String, make: @escaping @MainActor () -> (AnyView, CGSize)) {
            self.name = name; measure = false; self.make = make
        }

        init(pill name: String, make: @escaping @MainActor () -> (AnyView, CGSize)) {
            self.name = name; measure = false; chrome = false; self.make = make
        }
    }

    static var shots: [Shot] {
        [
            Shot(name: "home", looks: [false, true]) { mainWindow(tab: .home) },
            Shot(name: "home-free") { mainWindow(tab: .home, profile: .free) },
            Shot(name: "home-needs-key", noKey: true) { mainWindow(tab: .home, profile: .needsKey) },
            Shot(name: "home-connect", noKey: true) { mainWindow(tab: .home, profile: .needsKey, connectOpen: true) },
            Shot(name: "history") { mainWindow(tab: .history) },
            Shot(name: "page-languages") { mainWindow(tab: .settings, page: .apiKeys) },
            Shot(name: "page-permissions") { mainWindow(tab: .settings, page: .permissions) },
            Shot(name: "page-dictation") { mainWindow(tab: .settings, page: .dictation) },
            Shot(name: "page-hotkey") { mainWindow(tab: .settings, page: .hotkey) },
            Shot(name: "page-pill") { mainWindow(tab: .settings, page: .pill) },
            Shot(name: "page-privacy") { mainWindow(tab: .settings, page: .privacy) },
            Shot(name: "page-about") { mainWindow(tab: .settings, page: .about) },
            Shot(setup: "setup-welcome") { setup(.welcome) },
            Shot(setup: "setup-languages") { setup(.languages) },
            Shot(setup: "setup-permissions") { setup(.permissions) },
            Shot(setup: "setup-connect") { setup(.connect) },
            Shot(setup: "setup-try") { setup(.tryIt) },
            Shot(setup: "setup-done") { setup(.done) },
            Shot(pill: "pill-recording") { pill(.recording) },
            Shot(pill: "pill-processing") { pill(.transcribing) },
            Shot(pill: "pill-offline") { pill(.failed) },
        ]
    }

    // MARK: the main window over demo state

    /// The shipped `MainView` with every permission granted and the demo History; settings and keys come from the
    /// demo profile the script set up.
    /// `cloud`: English, Uzbek and Russian through OpenRouter (the demo key). `free`: English on Apple's on-device
    /// engine, no key.
    /// `needsKey`: English on this Mac, Uzbek chosen and waiting for a key (the Connect states).
    enum Profile { case cloud, free, needsKey }
    /// Must match `OPENROUTER_API_KEY` in scripts/docs_shots.sh.
    static let demoKey = "sk-or-v1-FAKE0000000000000000000000000000demo7f3a"

    static func mainWindow(tab: MainTab, page: SettingsPage = .dictation, profile: Profile = .cloud,
                           connectOpen: Bool = false) -> AnyView {
        SettingsStore.shared.update { s in
            s.spokenLanguages = switch profile { case .cloud: [.en, .uz, .ru]; case .free: [.en]; case .needsKey: [.en, .uz] }
            s.provider = profile == .cloud ? .openRouter : .apple
            if profile == .cloud { s.sttModel = ProviderKind.openRouter.defaultSTTModel }   // as switching to Cloud does
            s.uiLanguage = .en
            s.onboardingDone = true
        }
        let status = AppStatus()
        if profile == .cloud { Secrets.markVerified(.openRouter, key: demoKey) }   // the demo profile's settings only
        if profile == .cloud { status.keys = [.openRouter: AppStatus.KeyState(masked: Secrets.masked(demoKey), verified: true)] }
        status.previewPermissions(PermissionState(mic: .granted, ax: true, inputMonitoring: true, eventsFlowing: true))
        if profile != .cloud {   // only English works yet: the last dictation is the English one
            status.lastRun = ((try? RunLog.readAll()) ?? []).last { ($0.cleanText ?? $0.rawText ?? "").hasPrefix("Please send") } ?? status.lastRun
        }
        let settings = SettingsModel(store: .shared)
        let nav = MainWindowModel(); nav.tab = tab; nav.page = page
        let runs = RunsModel(); runs.reload()
        let connect = InlineConnectModel(settings: settings, status: status)
        if connectOpen { connect.open(.language(.uz), provider: .openRouter) }
        return AnyView(MainView(nav: nav, panel: PanelModel(), status: status, settings: settings, runs: runs,
                                openSetup: { _ in }, connect: connect)
                .environment(\.docsCapture, true))
    }

    // MARK: the Setup Assistant over demo state

    /// The first-run Setup Assistant walked to `step` with its own `next()`. Permissions: the microphone allowed and
    /// Accessibility still to do (the picture shows the button). Connect and later: every grant done and OpenRouter
    /// connected with the demo key. Try: a mixed sentence came back.
    static func setup(_ step: SetupStep) -> (AnyView, CGSize) {
        SettingsStore.shared.update { s in
            s.spokenLanguages = [.en, .uz, .ru]; s.provider = .openRouter; s.sttModel = ProviderKind.openRouter.defaultSTTModel
            s.uiLanguage = .en; s.onboardingDone = false
        }
        Secrets.markVerified(.openRouter, key: demoKey)
        let status = AppStatus()
        status.keys = [.openRouter: AppStatus.KeyState(masked: Secrets.masked(demoKey), verified: true)]
        let partial = PermissionState(mic: .granted, ax: false, inputMonitoring: false)
        let all = PermissionState(mic: .granted, ax: true, inputMonitoring: true, eventsFlowing: true)
        status.previewPermissions(step == .permissions ? partial : all)
        let settings = SettingsModel(store: .shared)
        let model = SetupModel(status: status, settings: settings)
        model.present()
        model.preview { $0.update(status.permissions); $0.updateFn(hotkeyIsFn: true, usage: step == .permissions ? 2 : 0) }
        for _ in 0..<SetupStep.allCases.count where model.flow.step != step {
            if model.flow.step == .connect { model.preview { $0.setProvider(.openRouter); $0.keyConnected() } }
            if model.flow.step == .tryIt {
                model.preview(practice: tryText) {
                    $0.recordTry(text: tryText, releasedAt: Date().addingTimeInterval(-2.2), now: Date(), engine: .cloud("OpenRouter"))
                }
            }
            model.next()
        }
        if step == .connect { model.preview { $0.setProvider(.openRouter); $0.keyConnected() } }
        if step == .tryIt {
            model.preview(practice: tryText) {
                $0.recordTry(text: tryText, releasedAt: Date().addingTimeInterval(-2.2), now: Date(), engine: .cloud("OpenRouter"))
            }
        }
        let view = SetupView(model: model, panel: PanelModel()).environment(\.docsCapture, true)
        return (AnyView(view), CGSize(width: SetupFlow.width, height: model.height))
    }

    /// What reading the Uzbek practice sentence aloud gives back.
    /// The pill alone on paper: recording (a voice level), processing, or the offline card (the recording is kept
    /// for Retry). Real pill code; nothing records or sends.
    static func pill(_ phase: PanelModel.Phase) -> (AnyView, CGSize) {
        let m = PanelModel()
        m.reset()
        m.phase = phase == .failed ? .recording : phase
        m.appeared = true
        if phase == .recording { m.micLive = true; m.level = 0.12; m.elapsedSec = 3 }
        if phase == .failed {
            m.failure = .from(URLError(.notConnectedToInternet), stage: "stt")
            m.phase = .failed
        }
        let size = phase == .failed ? CGSize(width: 440, height: 136) : CGSize(width: 300, height: 90)
        let view = PillView(model: m).fixedSize()
            .frame(width: size.width, height: size.height)
            .background(Ink.paper)
        return (AnyView(view), size)
    }

    static let tryText = SetupStrings.sample[.uz] ?? ""

    // MARK: rendering

    /// The title-bar buttons draw grey in a window that was never on screen; paint them as an active window shows
    /// them (macOS's red, yellow and green, at the buttons' own frames).
    static func paintTrafficLights(_ w: NSWindow, _ target: NSView, _ rep: NSBitmapImageRep) {
        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        let colors: [(NSWindow.ButtonType, Int, Int)] = [(.closeButton, 0xFF5F57, 0xE0443E),
                                                              (.miniaturizeButton, 0xFEBC2E, 0xDEA123),
                                                              (.zoomButton, 0x28C840, 0x1AAB29)]
        for (type, fill, edge) in colors {
            guard let b = w.standardWindowButton(type) else { continue }
            var r = b.convert(b.bounds, to: target)
            if target.isFlipped { r.origin.y = target.bounds.height - r.maxY }
            let d: CGFloat = 12
            let dot = NSRect(x: r.midX - d / 2, y: r.midY - d / 2, width: d, height: d)
            NSColor(hex: fill).setFill()
            NSBezierPath(ovalIn: dot).fill()
            NSColor(hex: edge).setStroke()
            let ring = NSBezierPath(ovalIn: dot.insetBy(dx: 0.25, dy: 0.25)); ring.lineWidth = 0.5; ring.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    static func settle(_ host: NSView, turns: Int = 4) {
        for _ in 0..<turns {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
    }

    /// The lowest drawn row of the page pane (right of the sidebar), in points from the top.
    static func contentBottom(_ target: NSView, _ w: NSWindow) -> CGFloat? {
        w.displayIfNeeded()
        guard let rep = target.bitmapImageRepForCachingDisplay(in: target.bounds) else { return nil }
        target.cacheDisplay(in: target.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / target.bounds.width
        let x0 = Int((Ink.appSidebarWidth + 24) * scale), x1 = rep.pixelsWide - Int(24 * scale)
        guard let bg = rep.colorAt(x: x1, y: rep.pixelsHigh - 2) else { return nil }
        for y in stride(from: rep.pixelsHigh - 1, through: 0, by: -1) {
            for x in stride(from: x0, to: x1, by: 2) {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                if abs(c.redComponent - bg.redComponent) + abs(c.greenComponent - bg.greenComponent)
                    + abs(c.blueComponent - bg.blueComponent) > 0.06 { return CGFloat(y) / scale }
            }
        }
        return nil
    }

    /// How much taller than its visible area the tallest scroll view's content is.
    static func scrollOverflow(in v: NSView) -> CGFloat? {
        var best: CGFloat?
        if let sv = v as? NSScrollView, let doc = sv.documentView {
            let extra = doc.frame.height - sv.contentView.bounds.height
            best = max(best ?? extra, extra)
        }
        for sub in v.subviews { if let e = scrollOverflow(in: sub) { best = max(best ?? e, e) } }
        return best
    }

    static func dump(_ v: NSView, _ depth: Int) {
        guard depth < 14 else { return }
        print(String(repeating: "  ", count: depth) + "\(type(of: v)) \(Int(v.frame.width))x\(Int(v.frame.height)) layer=\(v.layer.map { "\(type(of: $0))" } ?? "-")")
        for s in v.subviews { dump(s, depth + 1) }
    }

    /// Lays the view out in a never-shown window and draws the window (traffic lights included) into a PNG at the
    /// screen's scale. Returns the size in pixels.
    @discardableResult
    static func render(_ view: AnyView, size: CGSize, dark: Bool, measure: Bool, chrome: Bool = true, to url: URL) throws -> CGSize {
        let w = KeyWindow(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: chrome ? [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView] : [.borderless],
                          backing: .buffered, defer: false)
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        w.backgroundColor = dark ? NSColor(hex: 0x15181D) : NSColor(hex: 0xF6F7F9)
        let host = NSHostingView(rootView: AnyView(view.environment(\.controlActiveState, .key)))
        host.sizingOptions = []                // the shot owns the size (as SetupWindow does), not SwiftUI
        w.contentView = host
        // The title-bar buttons colour themselves on these notifications, not from `isKeyWindow`.
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: w)
        NotificationCenter.default.post(name: NSWindow.didBecomeMainNotification, object: w)
        settle(host, turns: 8)                 // SwiftUI settles over a few run-loop turns (onAppear, async state)
        let target = host.superview ?? host
        // A snapshot draws a scroll view's content blank. Pages pick their unscrolled layout when it fits
        // (ViewThatFits), so lay out very tall, find where the content ends, and size the window to that.
        if measure {
            w.setContentSize(NSSize(width: size.width, height: 2400))
            settle(host)
            if let bottom = contentBottom(target, w) {
                w.setContentSize(NSSize(width: size.width, height: max(size.height, ceil(bottom) + 40)))
                settle(host)
            }
        }
        // Again now that the controls exist: a default button paints its blue on the key notification, a switch
        // its track on the app's.
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: w)
        NotificationCenter.default.post(name: NSWindow.didBecomeMainNotification, object: w)
        settle(host)
        w.layoutIfNeeded()
        w.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        guard let rep = target.bitmapImageRepForCachingDisplay(in: target.bounds) else { throw ShotError("no bitmap") }
        target.cacheDisplay(in: target.bounds, to: rep)
        if chrome { paintTrafficLights(w, target, rep) }
        if ProcessInfo.processInfo.environment["SHOTS_TREE"] == "1" { dump(target, 0) }
        guard let png = rep.representation(using: .png, properties: [:]) else { throw ShotError("no png") }
        try png.write(to: url)
        w.close()
        return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
    }
}

// MARK: - the README demo (`docs-shots --demo <dir>`)

/// One silent loop of the gesture with the app's own pill and keycap: hold fn, speak (a synthesized voice level,
/// nothing recorded), let go, the mixed sentence lands in a message field. Frames at 15 fps for ffmpeg.
@MainActor
final class DemoState: ObservableObject {
    @Published var keyDown = false
    @Published var text = ""
    @Published var caption = ""
    @Published var cursorOn = true
    let pill = PanelModel()
}

struct DemoScene: View {
    @ObservedObject var s: DemoState
    @ObservedObject var pill: PanelModel
    static let size = CGSize(width: 640, height: 400)

    var body: some View {
        VStack(spacing: 0) {
            Text(s.caption)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Ink.text)
                .frame(height: 36)
                .padding(.top, 26)
                .animation(.easeOut(duration: 0.2), value: s.caption)
            Spacer(minLength: 0)
            field
            ZStack {
                if pill.appeared { PillView(model: pill).fixedSize().transition(.scale(scale: 0.6).combined(with: .opacity)) }
            }
            .frame(height: 64)
            .animation(.spring(response: 0.22, dampingFraction: 0.8), value: pill.appeared)
            Spacer(minLength: 0)
            HStack(spacing: 14) {
                FnKeyCap(size: .medium, pressed: s.keyDown, lifted: false)
                    .animation(.easeOut(duration: 0.08), value: s.keyDown)
                Text("hold to talk").font(.system(size: 14)).foregroundStyle(Ink.text2)
            }
            .padding(.bottom, 26)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(Ink.paper)
    }

    private var field: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Message").font(.system(size: 12, weight: .medium)).foregroundStyle(Ink.text3)
            // The caret is part of the text, so it follows the last line when the sentence wraps.
            (Text(s.text) + Text("|").foregroundColor(s.cursorOn ? Ink.lazur : .clear))
                .font(.system(size: 17))
                .foregroundStyle(Ink.text)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: 56, alignment: .topLeading)
        }
        .padding(18)
        .frame(width: 540, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Ink.sheet))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Ink.hairline))
    }
}

extension DocsShots {
    static let demoSentence = "Ertaga ertalab qo‘ng‘iroq qilaman, а потом обсудим детали договора."

    /// Renders the loop into `<dir>/frame-0001.png…` in real time (the app's own animations run between frames).
    static func demo(to dir: URL, dark: Bool) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let st = DemoState()
        let m = st.pill
        let view = AnyView(DemoScene(s: st, pill: m).environment(\.docsCapture, true))
        let w = KeyWindow(contentRect: NSRect(origin: .zero, size: DemoScene.size), styleMask: [.borderless],
                          backing: .buffered, defer: false)
        w.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        w.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: AnyView(view.environment(\.controlActiveState, .key)))
        host.sizingOptions = []
        w.contentView = host
        settle(host, turns: 8)
        let fps = 15.0, total = 9.6
        var n = 0
        let start = Date()
        while true {
            let t = Double(n) / fps
            guard t < total else { break }
            step(st, m, at: t)
            // Real time: the waveform and the springs read the clock.
            let due = start.addingTimeInterval(t)
            while Date() < due { RunLoop.main.run(until: min(due, Date().addingTimeInterval(0.01))) }
            host.layoutSubtreeIfNeeded()
            w.displayIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw ShotError("no bitmap") }
            host.cacheDisplay(in: host.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else { throw ShotError("no png") }
            n += 1
            try png.write(to: dir.appendingPathComponent(String(format: "frame-%04d.png", n)))
        }
        print("demo: \(n) frames at \(Int(fps)) fps")
    }

    /// The script: idle 1 s, hold and speak 3.6 s, process 2 s, the text lands and stays.
    private static func step(_ st: DemoState, _ m: PanelModel, at t: Double) {
        st.cursorOn = st.text.isEmpty ? Int(t * 2) % 2 == 0 : true
        switch t {
        case ..<1.0:
            st.caption = "Hold fn in any app"
        case ..<4.6:
            st.caption = "Speak the way you talk"
            if !st.keyDown { st.keyDown = true; m.reset(); m.phase = .recording; m.appeared = true }
            if t > 1.15 { m.micLive = true }
            let v = t - 1.0
            let syllable = pow(max(0, sin(v * 3.1 * .pi)), 2) * (0.6 + 0.4 * sin(v * 0.9))
            let pause = v > 1.7 && v < 2.1 ? 0.0 : 1.0
            m.elapsedSec = v
            m.level = Float(0.004 + 0.16 * syllable * pause)
        case ..<6.6:
            st.caption = "Let go"
            if st.keyDown { st.keyDown = false; m.phase = .transcribing }
        default:
            st.caption = "Uzbek and Russian in one sentence, typed for you"
            if st.text.isEmpty { st.text = demoSentence; m.phase = .done; m.appeared = false }
        }
    }
}

// MARK: - the release video's slides (`docs-shots --video-slides <dir> <media dir>`)

/// One captioned slide: a docs picture (or a title) on paper, 960 × 540 pt (1920 × 1080 px).
struct VideoSlide: View {
    static let size = CGSize(width: 960, height: 540)
    var kicker: String? = nil
    let title: String
    var sub: String? = nil
    var image: NSImage? = nil
    var icon: NSImage? = nil

    var body: some View {
        VStack(spacing: 14) {
            if let icon {
                Spacer(minLength: 0)
                Image(nsImage: icon).resizable().frame(width: 112, height: 112)
            }
            if let kicker {
                Text(kicker.uppercased()).font(.system(size: 13, weight: .semibold)).kerning(1.2).foregroundStyle(Ink.lazur)
            }
            Text(title).font(.system(size: image == nil ? 40 : 28, weight: .bold)).foregroundStyle(Ink.text)
                .multilineTextAlignment(.center)
            if let sub {
                Text(sub).font(.system(size: image == nil ? 20 : 16)).foregroundStyle(Ink.text2).multilineTextAlignment(.center)
            }
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                    .frame(maxWidth: image.size.width * 1.5)       // a small picture (the pill) isn't blown up
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .shadow(color: .black.opacity(0.16), radius: 18, y: 8)
                    .padding(.top, 6)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 60).padding(.top, image == nil && icon == nil ? 180 : 34).padding(.bottom, image == nil ? 0 : 30)
        .frame(width: Self.size.width, height: Self.size.height)
        .background(Ink.paper)
    }
}

extension DocsShots {
    /// The storyboard: `name` is the slide's file, `image` a docs/media picture (1x name; the @2x is used).
    static let storyboard: [(name: String, kicker: String?, title: String, sub: String?, image: String?)] = [
        ("01-title", nil, "Soyla", "Push-to-talk dictation for macOS.\nUzbek, Russian and English in one sentence.", nil),
        ("03-download", "Install · 1", "Download the zip from Releases", "Unzip it and drag Soyla to Applications.", "install-02"),
        ("04-blocked", "Install · 2", "macOS asks once: click Done", "Soyla isn't signed by Apple yet.", "install-04"),
        ("05-openanyway", "Install · 3", "Privacy & Security → Open Anyway", "Once per version.", "install-05"),
        ("06-welcome", "Setup · about 2 minutes", "The Setup Assistant opens", nil, "setup-welcome"),
        ("07-languages", "Setup", "Pick the languages you speak", "English runs on your Mac, free. Uzbek and Russian use the cloud.", "setup-languages"),
        ("08-permissions", "Setup", "Allow the microphone and typing", "Soyla listens only while you hold fn.", "setup-permissions"),
        ("09-connect", "Setup", "Connect Uzbek and Russian with your own key", "OpenRouter or Google AI Studio. No Soyla account, no Soyla server.", "setup-connect"),
        ("10-try", "Setup", "Try one sentence", nil, "setup-try"),
        ("11-done", "Setup", "Done. Hold fn in any app", nil, "setup-done"),
        ("12-home", "Every day", "Home: your languages and the last dictation", nil, "home"),
        ("13-history", "Every day", "History: copy, play or retry any dictation", nil, "history"),
        ("14-languages", "Every day", "Cloud or On this Mac, per language", nil, "page-languages"),
        ("15-offline", "Never lost", "No internet? The recording is kept", "Retry when you're back online.", "pill-offline"),
        ("16-privacy", nil, "Private by design", "Audio goes from your Mac to the service you chose, with your key.\nNo telemetry. No screenshots. Mic off between dictations.", nil),
        ("17-end", nil, "github.com/ShamsiddinKomil/soyla", "Free and open source (MIT).", nil),
    ]

    static func videoSlides(to dir: URL, media: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let icon = NSImage(contentsOf: media.appendingPathComponent("icon.png"))
        for s in storyboard {
            let img = s.image.flatMap { NSImage(contentsOf: media.appendingPathComponent("\($0)@2x.png")) }
            if s.image != nil && img == nil { throw ShotError("missing picture \(s.image ?? "")") }
            let slide = VideoSlide(kicker: s.kicker, title: s.title, sub: s.sub, image: img,
                                   icon: s.name == "01-title" ? icon : nil)
            try render(AnyView(slide), size: VideoSlide.size, dark: false, measure: false, chrome: false,
                       to: dir.appendingPathComponent("\(s.name).png"))
        }
        print("video: \(storyboard.count) slides")
    }
}
