import AppKit
import Combine
import SwiftUI
import Carbon.HIToolbox

/// GUI entry point: menu bar item, floating panel, settings + runs windows, hotkey → pipeline.
public enum AppMain {
    public static func run() {
        // All diagnostics go to app.log (SoylaPaths.appLog) so a silent failure can be read after the fact.
        SoylaPaths.rotateIfLarge(SoylaPaths.appLog)   // keeps app.log + app.log.1, about 2 MB at most
        SoylaPaths.ensureDirectories()
        let logPath = SoylaPaths.appLog.path
        if freopen(logPath, "a", stderr) != nil { setvbuf(stderr, nil, _IOLBF, 0); chmod(logPath, 0o600) }
        Log.info("=== Soyla \(Soyla.version) launched (\(Bundle.main.bundleIdentifier ?? "no bundle")) ===")
        // Before any model reads a key: after an update macOS may hold the read behind its password dialog,
        // and on the main thread that kept the window from ever appearing.
        Secrets.loadInBackground()
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            let delegate = AppDelegate()
            app.delegate = delegate
            app.setActivationPolicy(.regular)       // Dock icon, app menu, ⌘Q, appears in app switcher
            app.run()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var iconState = ""
    private let panelModel = PanelModel()
    private var panel: FloatingPanel!
    private var pipeline: DictationPipeline!
    private var hotkey: HotkeyMonitor?
    private let settingsModel = SettingsModel()
    private var phraseMenu: NSMenu!
    private var phraseItem: NSMenuItem!
    private var updateMenuItem: NSMenuItem!
    /// APP-1 (b): the status menu's retitled and hidden-or-shown items; the language the menus were last built in.
    private var menuSlots: [MenuSlot: NSMenuItem] = [:], menuLanguage: UILanguage?
    private var lastAX = false, lastIM = false
    private var preflight = PreflightGate()
    private var iconSink: AnyCancellable?
    private var keySink: AnyCancellable?
    private var permissionSink: AnyCancellable?
    private var keychainObserver: NSObjectProtocol?
    private var mainWindow: NSWindow?
    private let nav = MainWindowModel()
    private let appStatus = AppStatus()
    private let runsModel = RunsModel()
    private lazy var setup = SetupModel(status: appStatus, settings: settingsModel)
    private lazy var setupWindow = SetupWindowController(model: setup, panel: panelModel)
    /// v3: the inline Connect panel on Home and the Languages page (one at a time, app-wide).
    private lazy var inlineConnect = InlineConnectModel(settings: settingsModel, status: appStatus)
    /// FE-3 state for the free engine; FE-4 wires launch / engine switch / locale change / hotkey-down.
    private let onDeviceModels = OnDeviceModels.shared
    /// Locale last handed to `ensureReady` while the engine is `.apple` (nil = cloud engine).
    private var onDeviceReadyLocale: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Sounds.preload()
        panel = FloatingPanel(model: panelModel)
        pipeline = DictationPipeline(panel: panelModel)
        pipeline.onPanelShouldShow = { [weak self] in self?.panel.show() }
        pipeline.onGestureEvent = { [weak self] e in self?.hotkey?.send(e) }
        pipeline.onOnDeviceKeyDown = { [weak self] locale in self?.refreshOnDeviceModel(locale: locale) }
        panelModel.onRetry = { [weak self] in self?.pipeline.retry() }
        panelModel.onOpenSettings = { [weak self] in self?.pillFixClicked() }
        panelModel.readiness = { [weak self] in self?.readiness ?? .ready }
        buildMenu()
        buildMainMenu()
        settingsModel.onChange = { [weak self] s in self?.applySettings(s) }
        syncOnDeviceModel(SettingsStore.shared.current)   // FE-0: inside the app, English is unusable until reserved
        // F4: recover recordings cut off by a crash, then apply retention (again every 24 h).
        RecordingStore.repairInterrupted(model: SettingsStore.shared.current.sttModel)
        startRetentionSweep()
        installLastDictationKeys()
        PasteKeycode.prepare()     // main thread: TIS calls trap off-main on macOS 26 (crash 2026-10-16)
        runsModel.onRetry = { [weak self] r, model in self?.pipeline.retryFromHistory(r, model: model) ?? false }
        panelModel.hotkeyLabel = SettingsStore.shared.current.hotkey.shortLabel; panelModel.uiLanguage = SettingsStore.shared.current.uiLanguage
        // One permission poller (AppStatus) for the whole app; the hotkey starts/upgrades from its changes.
        appStatus.lastKeyEventAt = { [weak self] in self?.hotkey?.lastEventAt }
        lastAX = appStatus.permissions.ax; lastIM = appStatus.permissions.inputMonitoring
        permissionSink = appStatus.$permissions.dropFirst().sink { [weak self] p in
            DispatchQueue.main.async { self?.permissionsChanged(p); self?.refreshIcon() }
        }
        appStatus.start()
        keychainObserver = NotificationCenter.default.addObserver(forName: Secrets.didLoad, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Log.info("keychain read done: \(Secrets.keychainAccess)")
                self.appStatus.refresh(); self.settingsModel.refreshKeyStatus(); self.settingsModel.loadModels()
            }
        }
        startHotkey()
        pipeline.applyWarmMode(SettingsStore.shared.current.micWarmMode)
        keySink = appStatus.$keys.dropFirst().sink { [weak self] _ in DispatchQueue.main.async { self?.refreshIcon() } }
        iconSink = panelModel.objectWillChange.sink { [weak self] _ in DispatchQueue.main.async { self?.refreshIcon() } }
        // First run (or `--onboarding`): the setup window on its own. Otherwise missing permissions → Settings.
        let args = CommandLine.arguments
        // Docs captures: force an appearance (`--appearance dark|light`).
        if let i = args.firstIndex(of: "--appearance"), i + 1 < args.count {
            NSApp.appearance = NSAppearance(named: args[i + 1] == "dark" ? .darkAqua : .aqua)
        }
        if args.contains("--pill-demo") { startPillDemo() }; startCaptureIfAsked(args)
        if !SettingsStore.shared.current.onboardingDone || args.contains("--onboarding") {
            showOnboarding()
        } else if let i = args.firstIndex(of: "--page"), i + 1 < args.count, args[i + 1] == "history" {
            showMainWindow(tab: .history)
        } else if let i = args.firstIndex(of: "--page"), i + 1 < args.count, let p = SettingsPage(argument: args[i + 1]) {
            nav.page = p; showMainWindow(tab: .settings)   // docs captures: open straight on one Settings page
        } else {
            // `--tab` (docs captures) wins; otherwise the readiness-aware launch page.
            if let tab = MainTab.launchArgument(args) { showMainWindow(tab: tab) } else { showLaunchWindow() }
        }
        // Daily update check (at launch, then every 24 h): silent; a newer release shows the Update button.
        Updater.shared.start(settings: settingsModel) { [weak self] in
            self.map { $0.panelModel.phase == .recording || PanelModel.processingPhases.contains($0.panelModel.phase) } ?? false
        }
    }

    /// `--pill-demo`: drive the pill through recording (a synthesized voice envelope), transcribing and a failure card,
    /// twice, so the motion can be screen-recorded without a hotkey press. Nothing is recorded or sent.
    private func startPillDemo() {
        let m = panelModel
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            for _ in 0..<2 {
                m.reset(); m.phase = .recording
                try? await Task.sleep(for: .milliseconds(120)); m.micLive = true
                let t0 = Date()
                while Date().timeIntervalSince(t0) < 4.5 {
                    let t = Date().timeIntervalSince(t0)
                    let syllable = pow(max(0, sin(t * 3.1 * .pi)), 2) * (0.6 + 0.4 * sin(t * 0.9))   // ~3 syllables/s, phrased
                    let pause = t > 1.9 && t < 2.5 ? 0.0 : 1.0
                    m.elapsedSec = t
                    m.level = Float(0.004 + 0.16 * syllable * pause)
                    try? await Task.sleep(for: .milliseconds(50))
                }
                m.phase = .transcribing
                try? await Task.sleep(for: .seconds(3))
                m.phase = .idle
                try? await Task.sleep(for: .seconds(1))
                m.failure = .from(SoylaError.missingAPIKey("demo"), stage: "demo")
                m.phase = .failed
                try? await Task.sleep(for: .seconds(4))
                m.phase = .idle
                try? await Task.sleep(for: .seconds(1.5))
            }
        }
    }

    // MARK: app lifecycle (regular app: window, Dock, ⌘Q)

    /// Closing the window keeps Soyla running (hotkey stays active); quit with ⌘Q, the Dock, or the menu bar icon.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Dock icon click / reopening from Launchpad brings the window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow(tab: nil); return true
    }

    func showMainWindow(tab: MainTab?) {
        if setup.isPresented { setup.present(); return }   // during setup the assistant is the only window (OB-2)
        if let tab { nav.tab = tab }
        if mainWindow == nil {
            let root = MainView(nav: nav, panel: panelModel, status: appStatus, settings: settingsModel, runs: runsModel,
                                openSetup: { [weak self] step in self?.openSetup(step) },
                                connectFor: { [weak self] p in self?.openConnect(for: p) }, connect: inlineConnect)
            let w = NSWindow(contentRect: NSRect(origin: .zero, size: Ink.appWindow),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "Soyla"
            // The lapis sidebar runs to the top edge with the traffic lights on it (docs/DESIGN.md "Main window").
            w.titleVisibility = .hidden
            w.titlebarAppearsTransparent = true
            w.isMovableByWindowBackground = true
            w.backgroundColor = NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(hex: 0x15181D) : NSColor(hex: 0xF6F7F9) }
            w.contentView = NSHostingView(rootView: root)
            w.isReleasedWhenClosed = false
            w.contentMinSize = Ink.appWindowMin
            // A new name, so a frame saved earlier (880 × 600, then 1056 × 768) doesn’t win over 1056 × 688 (owner, 2026-10-18).
            // First open: centred. (Checking `frame.origin == .zero` after setting the autosave name missed it and
            // the window opened off-centre, low on the left.)
            if !w.setFrameUsingName("SoylaMainWindow3") { w.center() }
            w.setFrameAutosaveName("SoylaMainWindow3")
            mainWindow = w
        }
        appStatus.refresh()
        runsModel.reload()
        settingsModel.refreshKeyStatus()
        NSApp.activate(ignoringOtherApps: true)
        mainWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func openTab(_ sender: NSMenuItem) { showMainWindow(tab: MainTab.allCases[sender.tag]) }
    /// F-22: "Open Soyla" lands on Home; "Settings…" opens the last Settings page.
    @objc private func openMainWindow() { showMainWindow(tab: .home) }
    /// Setup Assistant (first launch, Help menu, `--onboarding`): its own window since OB-2.
    @objc private func showOnboarding() { openSetup(.welcome) }

    /// Menu-bar icon: monochrome SF Symbols like native apps; red only while recording.
    private func refreshIcon() {
        let state: String
        switch panelModel.phase {
        case .needsPermission: state = "perm"
        case .recording: state = "rec"
        case .transcribing, .cleaning, .pasting: state = "busy"
        default: state = needsAttention ? "warn" : "idle"
        }
        guard state != iconState, let button = statusItem.button else { return }
        iconState = state
        button.title = ""
        button.appearsDisabled = false
        switch state {
        case "rec":
            button.image = Brand.image(fill: .systemRed, label: "Soyla: recording")
        case "busy":
            button.image = Brand.image(label: "Soyla: transcribing")
            button.appearsDisabled = true                          // dimmed while waiting for the transcript
        case "perm":
            button.image = Self.badgedMark("Soyla: needs permissions")
        case "warn":
            button.image = Self.badgedMark("Soyla: needs attention (permission, key or Secure Input)")
        default:
            button.image = Brand.image(label: "Soyla")
        }
    }

    /// Warning state: the brand capsule with a small `exclamationmark.triangle` over its lower-right corner, so the
    /// icon stays recognisable (a replacement symbol reads as a different app). Template: the system tints it, and the
    /// badge area is knocked out of the capsule so the two don't merge into a blob.
    static func badgedMark(_ label: String) -> NSImage? {
        let wave = Brand.image(label: label)
        guard let tri = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 9, weight: .bold))
        else { return statusSymbol("exclamationmark.triangle", label) }
        let size = NSSize(width: ceil(wave.size.width) + 3, height: ceil(wave.size.height))
        let img = NSImage(size: size, flipped: false) { rect in
            wave.draw(in: NSRect(x: 0, y: 0, width: wave.size.width, height: wave.size.height))
            let t = NSRect(x: rect.maxX - tri.size.width, y: 0, width: tri.size.width, height: tri.size.height)
            NSGraphicsContext.current?.cgContext.setBlendMode(.clear)
            tri.draw(in: t.insetBy(dx: -1.5, dy: -1.5))            // knock-out halo
            NSGraphicsContext.current?.cgContext.setBlendMode(.normal)
            tri.draw(in: t)
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = label
        return img
    }

    private static func statusSymbol(_ name: String, _ label: String) -> NSImage? {
        let img = NSImage(systemSymbolName: name, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
        img?.isTemplate = true                                     // follows light/dark menu bar
        return img
    }

    @objc private func setPhrase(_ sender: NSMenuItem) {
        SettingsStore.shared.update { $0.phraseId = sender.tag == 0 ? nil : sender.tag }
        settingsModel.s = SettingsStore.shared.current
        refreshMenuState()
    }

    @objc private func showSettings() { showMainWindow(tab: .settings) }

    // MARK: hotkey + permissions

    private func startHotkey() {
        hotkey?.stop()
        let choice = SettingsStore.shared.current.hotkey
        panelModel.hotkeyLabel = choice.shortLabel
        let h = HotkeyMonitor(choice: choice)
        // Actions arrive on the main queue in reducer order; run them synchronously (a Task could reorder
        // e.g. [cancel tap, start recording]). While setup is up and before its Try step the gesture is
        // swallowed, never sent to the pipeline; echo pipelineIdle so the reducer doesn't wait.
        // Home's key cap: raw key edges, delivered on the main queue (callbackQueue) like the actions.
        h.onTrace = { [weak self] e, _, _ in MainActor.assumeIsolated { self?.panelModel.noteHotkeyEvent(e) } }
        h.onAction = { [weak self] a in MainActor.assumeIsolated {
            guard let self else { return }
            if self.setup.capturesHotkey {
                switch a {
                case .stopAndSend, .cancelRecording: self.hotkey?.send(.pipelineIdle)
                default: break
                }
            } else if self.hotkeyPageInFront {
                // HOTKEY-1: the Hotkey page's live test hears the key; nothing records, nothing is sent.
                self.settingsModel.keyTest.note(a)
                switch a {
                case .stopAndSend, .cancelRecording: self.hotkey?.send(.pipelineIdle)
                default: break
                }
            } else if self.preflightPasses(a) {
                self.setup.noteHotkey(a)       // Try: the stage key and the release time; the pipeline still runs
                self.pipeline.handle(a)
            }
        } }
        do {
            try h.start(); hotkey = h
            let ax = Permissions.accessibilityTrusted(prompt: false)
            Log.info("hotkey active (\(choice.rawValue)); accessibility=\(ax)")
            if ax {
                panelModel.errorText = ""
                panelModel.phase = .ready
            } else {
                // Tap works via Input Monitoring, but ⌘V paste needs Accessibility too (AppStatus reports the grant).
                panelModel.phase = .needsPermission
            }
        } catch {
            hotkey = nil
            // No prompts here: Settings → Permissions → Grant… registers Soyla and opens the pane.
            let ax = Permissions.accessibilityTrusted(prompt: false)
            let im = Permissions.inputMonitoring(prompt: false)
            Log.info("hotkey inactive (accessibility=\(ax), inputMonitoring=\(im)) — waiting for a grant")
            panelModel.phase = .needsPermission
        }
        refreshMenuState()
    }

    /// The Hotkey page is what the user is looking at: the main window is key and on it, and setup isn't up.
    private var hotkeyPageInFront: Bool {
        !setup.isPresented && mainWindow?.isKeyWindow == true && nav.tab == .settings && nav.page == .hotkey
    }

    /// AppStatus saw a permission change (1 s poll while missing, app activation, wake): start the hotkey as soon as
    /// either grant exists, and restart it once Accessibility arrives (tap-only → paste-capable).
    private func permissionsChanged(_ p: PermissionState) {
        guard p.ax != lastAX || p.inputMonitoring != lastIM else { return }
        Log.info("permission change: accessibility=\(p.ax) inputMonitoring=\(p.inputMonitoring)")
        let gainedAX = p.ax && !lastAX
        lastAX = p.ax; lastIM = p.inputMonitoring
        if hotkey == nil, p.canListen { startHotkey() }
        else if hotkey != nil, gainedAX { startHotkey() }
        else { refreshMenuState() }
    }

    private var lastHotkeyChoice: HotkeyChoice?
    private func applySettings(_ s: Settings) {
        panelModel.hotkeyLabel = s.hotkey.shortLabel     // Home, the pill and History follow a key or language change
        if let h = hotkey { h.update(choice: s.hotkey) }
        else if lastHotkeyChoice != s.hotkey { startHotkey() }   // don't re-prompt on every keystroke in Settings
        lastHotkeyChoice = s.hotkey
        pipeline.applyWarmMode(s.micWarmMode)
        panelModel.uiLanguage = s.uiLanguage
        syncOnDeviceModel(s)
        refreshMenuState()
    }

    // MARK: F4 — Paste last / Copy last, retention sweep

    private var lastKeyMonitor: Any?
    private var sweepTimer: Timer?

    fileprivate func lastDictationItems(_ t: AppStrings) -> [NSMenuItem] {
        let p = NSMenuItem(title: t.mPaste, action: #selector(pasteLast), keyEquivalent: "v")
        let c = NSMenuItem(title: t.mCopyLast, action: #selector(copyLast), keyEquivalent: "c")
        for it in [p, c] { it.keyEquivalentModifierMask = [.command, .control]; it.target = self }
        return [p, c]
    }

    /// Global ⌘⌃V / ⌘⌃C while another app is frontmost (inside Soyla the menu key equivalents handle them).
    private func installLastDictationKeys() {
        guard lastKeyMonitor == nil else { return }
        lastKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard !e.isARepeat, let a = LastDictation.action(keyCode: e.keyCode, chars: e.charactersIgnoringModifiers, flags: e.modifierFlags) else { return }
            MainActor.assumeIsolated { a == .paste ? self?.pasteLast() : self?.copyLast() }
        }
    }

    /// Cancels in-flight work first (its result would otherwise paste on top), then pastes into the frontmost app.
    @objc private func pasteLast() {
        guard !pipeline.isRecording else { return }
        pipeline.cancelInFlight()
        guard let text = LastDictation.latestText() else { Log.info("paste last: no successful dictation yet"); return }
        Log.info("paste last: \(text.count) chars")
        Task { @MainActor in
            let outcome = await Paster.paste(text, target: PasteTarget.frontmost(), timeline: RunTimeline())
            if case .copiedOnly(let reason) = outcome {   // same card as a dictation that couldn't be inserted
                panelModel.failure = PillFailure.paste(reason); panelModel.phase = .failed; panel.show()
            }
        }
    }

    @objc private func copyLast() {
        guard let text = LastDictation.latestText() else { Log.info("copy last: no successful dictation yet"); return }
        Paster.copy(text)
        Log.info("copy last: \(text.count) chars")
    }

    private func startRetentionSweep() {
        let sweep: @MainActor @Sendable () -> Void = { [weak self] in
            guard let self else { return }
            let n = RecordingStore.sweep(retention: SettingsStore.shared.current.retention, protect: self.pipeline.protectedRunIds)
            if n > 0 { Log.info("retention sweep: removed \(n) recording(s)") }
        }
        sweep()
        let t = Timer(timeInterval: 24 * 3600, repeats: true) { _ in Task { @MainActor in sweep() } }
        RunLoop.main.add(t, forMode: .common)
        sweepTimer = t
    }

    func applicationWillTerminate(_ notification: Notification) {
        pipeline.shutdown()
        hotkey?.stop()
        if NSApp.windows.contains(where: { $0.identifier?.rawValue == "soyla.preview" }) {   // `--preview` scratch state
            UserDefaults.standard.removePersistentDomain(forName: Self.previewSuite)
        }
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) { refreshMenuState() }
}

// Updates, outside the class body to keep AppDelegate's size in check.
extension AppDelegate {
    @objc func checkForUpdates() {
        Task { @MainActor in
            if await UpdateCheck.run(silent: false, language: SettingsStore.shared.current.uiLanguage, onAvailable: { Updater.shared.offer($0) }) { settingsModel.s.lastUpdateCheck = Date() }
        }
    }

    func reportMenuItem(_ t: AppStrings) -> NSMenuItem {
        let it = NSMenuItem(title: t.mReport, action: #selector(reportProblem), keyEquivalent: ""); it.target = self; return it
    }

    @objc func reportProblem() {
        appStatus.refreshPermissions()
        ReportProblemWindow.show(permissions: appStatus.permissions)
    }

    @objc func installUpdate() { showMainWindow(tab: nil); Updater.shared.install() }
}

extension MainTab {
    /// `--tab home|history`: docs captures open straight on that tab.
    static func launchArgument(_ args: [String]) -> MainTab? {
        guard let i = args.firstIndex(of: "--tab"), i + 1 < args.count else { return nil }
        return MainTab(rawValue: args[i + 1].capitalized)
    }
}

// MARK: FE-4 — free engine model readiness

extension AppDelegate {
    /// Reserve (and if needed download) the free engine's model when it becomes the engine or its locale changes.
    /// Cheap when nothing changed, so it can run on every settings change.
    private func syncOnDeviceModel(_ s: Settings) {
        let wanted = s.provider == .apple ? s.onDeviceLocale : nil
        guard wanted != onDeviceReadyLocale else { return }
        onDeviceReadyLocale = wanted
        guard let locale = wanted else { return }
        Log.info("on-device model: ensure ready (\(locale))")
        Task { [onDeviceModels] in
            await onDeviceModels.ensureReady(locale: locale)
            refreshMenuState()
        }
    }

    /// Hotkey-down with the free engine: a status re-read off the recording path. A model that went missing
    /// (purged, reservation lost) is re-reserved so the next Retry can succeed.
    private func refreshOnDeviceModel(locale: String) {
        Task { [onDeviceModels] in
            await onDeviceModels.refresh(locale: locale)
            if onDeviceModels.state == .needsDownload { await onDeviceModels.ensureReady(locale: locale) }
            refreshMenuState()
        }
    }
}

// MARK: Audit 2026-10-19 — one readiness, an honest first page

extension AppDelegate {
    /// The shared answer (V-01): what the pill's key card and the menu read, from the same inputs as Home.
    private var readiness: Readiness { HomeState.current(status: appStatus, settings: SettingsStore.shared.current).readiness }

    /// F-16: at key-down, refuse a dictation that cannot work at all and show its card at once.
    private func preflightPasses(_ a: HotkeyReducer.Action) -> Bool {
        let home = HomeState.current(status: appStatus, settings: SettingsStore.shared.current)
        switch preflight.route(a, card: { KeyDownPreflight.card(home: home) }) {
        case .pass: return true
        case .swallow: return false
        case .idle: hotkey?.send(.pipelineIdle); return false
        case .show(let f):
            Log.info("preflight: key-down refused (\(f.fix == .connectKey ? "no key" : "permission"))")
            panelModel.failure = f; panelModel.phase = .failed; panel.show()
            return false
        }
    }

    /// V-07: a missing mic or Accessibility opens Home (its Permissions group has Allow…); anything else missing opens
    /// the Permissions page, never the default Dictation page.
    private func showLaunchWindow() {
        let p = appStatus.permissions
        if appStatus.allPermissions || p.mic != .granted || !p.ax { showMainWindow(tab: .home); return }
        nav.page = .permissions
        showMainWindow(tab: .settings)
    }
}

// MARK: APP-1 — setup from the app (Home, the Languages page, the menu bar)

extension AppDelegate {
    /// Setup at `step` (`.welcome` = the full assistant). On Done the main window comes back on the page it was
    /// opened from (a full run lands on Home, the hand-over from Done).
    func openSetup(_ step: SetupStep) {
        presentSetup(returnHome: step == .welcome) { [setup] in
            if step == .welcome { setup.present() } else { setup.present(entry: step) }
        }
    }

    /// The Languages page's Connect… / Replace…: setup's Connect step for that service, then back to the page.
    /// v3: Connect from the app is inline: the Languages page, with the first missing language's panel open (or the
    /// API key row's, when every language is ready). Setup's Connect step stays for the onboarding run.
    func openConnect(for p: KeyProvider) {
        guard p != .custom else { nav.page = .languages; showMainWindow(tab: .settings); return }
        openInlineConnect(p == .openRouter ? .openRouter : .google)
    }

    private func openInlineConnect(_ provider: SetupProvider? = nil) {
        nav.page = .languages
        showMainWindow(tab: .settings)
        let home = HomeState.current(status: appStatus, settings: settingsModel.s)
        inlineConnect.open(home.firstMissing.map { .language($0) } ?? .key, provider: provider)
    }

    private func presentSetup(returnHome: Bool, _ present: () -> Void) {
        setupWindow.anchor = { [weak self] in
            guard let m = self?.mainWindow, m.isVisible, !m.isMiniaturized else { return nil }
            return m.frame
        }
        if !setup.isPresented {
            let back = (tab: nav.tab, page: nav.page)
            setup.onFinish = { [weak self] in
                guard let self else { return }
                if returnHome { self.nav.tab = .home } else { self.nav.tab = back.tab; self.nav.page = back.page }
                self.showMainWindow(tab: nil)
            }
        }
        present()
    }
}

// MARK: APP-1 — docs captures without Screen Recording

extension AppDelegate {
    /// `--entry <step>` opens setup at that step from the app; `--snapshot <file.png>` renders Soyla's own front
    /// window into a PNG after 3 s (no Screen Recording needed, nothing leaves the Mac). Dev and docs only.
    private func startCaptureIfAsked(_ args: [String]) {
        if let i = args.firstIndex(of: "--entry"), i + 1 < args.count, let step = SetupStep(rawValue: args[i + 1]) {
            Task { @MainActor in try? await Task.sleep(for: .seconds(1)); openSetup(step) }
        }
        if let i = args.firstIndex(of: "--preview"), i + 1 < args.count { showPreview(args[i + 1]) }
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return }
        let path = args[i + 1]
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            let preview = NSApp.windows.first { $0.identifier?.rawValue == "soyla.preview" }
            let window = preview ?? (setup.isPresented ? NSApp.windows.first { $0.isVisible && $0 !== mainWindow && $0.title == "Soyla" && $0.frame.width >= 1000 } : mainWindow)
            // `--tall`: 1100 pt, so a page taller than the window renders unscrolled (cacheDisplay can't draw a ScrollView).
            if args.contains("--tall"), preview == nil, let w = window { w.setContentSize(NSSize(width: w.frame.width, height: 1100)) }
            // Key and active, so controls draw as the user sees them (an inactive window greys the filled primary).
            NSApp.activate(ignoringOtherApps: true)
            window?.makeKeyAndOrderFront(nil)
            try? await Task.sleep(for: .milliseconds(600))
            guard let view = window?.contentView?.superview ?? window?.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { Log.info("snapshot: no window"); return }
            view.cacheDisplay(in: view.bounds, to: rep)       // draws a SwiftUI ScrollView's content blank: see --preview
            let ok = (try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))) != nil
            Log.info("snapshot: \(ok ? "written" : "failed") (\(Int(view.bounds.width))×\(Int(view.bounds.height)))")
            if preview != nil { UserDefaults.standard.removePersistentDomain(forName: Self.previewSuite) }
        }
    }
}

// MARK: APP-1 (b) — the menu bar and the main menu, in the interface language

/// The status menu's items that change with state or language.
enum MenuSlot: Hashable { case header, secure, hotkeyOff, engineLine, context, open, paste, copy, settings, setup, report, quit }

extension AppDelegate {
    private var strings: AppStrings { .for(SettingsStore.shared.current.uiLanguage) }

    /// Prototype `renderMenu()`: the status line pair and the one fix, from `MenuHeader` (same inputs as Home).
    private var menuHeader: MenuHeader {
        MenuHeader(home: .current(status: appStatus, settings: SettingsStore.shared.current), secureInput: IsSecureEventInputEnabled())
    }

    /// The free engine's model state (download, permission) in the interface language; it opens the Languages page.
    fileprivate var engineLine: String? {
        let s = SettingsStore.shared.current
        return EngineCopy.attention(provider: s.provider, state: onDeviceModels.state, language: s.uiLanguage)
    }

    /// Warning icon: a missing permission or key, Secure Input, or the free engine's model. A skipped key (Uzbek or
    /// Russian waiting for a key while English works) is calm: no badge. Re-read when permissions/keys or the panel
    /// change and when the menu opens; Secure Input alone has no notification.
    private var needsAttention: Bool { menuHeader.badge || engineLine != nil }

    private func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        refreshIcon()
        let t = strings
        let menu = NSMenu()
        updateMenuItem = NSMenuItem(title: "", action: #selector(installUpdate), keyEquivalent: "")
        updateMenuItem.isHidden = true
        menu.addItem(updateMenuItem)
        func slot(_ k: MenuSlot, _ title: String, _ action: Selector?, _ key: String = "") -> NSMenuItem {
            let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
            menuSlots[k] = it; menu.addItem(it); return it
        }
        slot(.header, "", nil).view = MenuHeaderView()          // V-05: legible, not a greyed disabled item
        _ = slot(.secure, "", nil)
        _ = slot(.hotkeyOff, t.mHotkeyOff, #selector(hotkeyLineClicked))
        _ = slot(.engineLine, "", #selector(engineLineClicked))
        _ = slot(.context, "", #selector(menuContextClicked))
        menu.addItem(.separator())
        _ = slot(.open, t.mOpen, #selector(openMainWindow))
        for (k, it) in zip([MenuSlot.paste, .copy], lastDictationItems(t)) { menuSlots[k] = it; menu.addItem(it) }
        _ = slot(.settings, t.mSettings, #selector(showSettings), ",")
        menu.addItem(.separator())
        _ = slot(.setup, t.mSetup, #selector(showOnboarding))
        let report = reportMenuItem(t)
        menuSlots[.report] = report; menu.addItem(report)
        // Developer mode only (hidden otherwise, see refreshMenuState).
        phraseItem = NSMenuItem(title: "Tag next run as", action: nil, keyEquivalent: "")
        phraseMenu = NSMenu()
        for i in 0...10 {
            let title = i == 0 ? "free" : (i <= 5 ? "phrase \(i) (short)" : "phrase \(i) (long, TEST_SCRIPTS.md)")
            let it = NSMenuItem(title: title, action: #selector(setPhrase(_:)), keyEquivalent: i <= 9 ? "\(i)" : "")
            it.tag = i
            phraseMenu.addItem(it)
        }
        phraseItem.submenu = phraseMenu
        menu.addItem(phraseItem)
        menu.addItem(.separator())
        _ = slot(.quit, t.mQuit, #selector(NSApplication.terminate(_:)), "q")
        for it in menu.items where it.action != #selector(NSApplication.terminate(_:)) { it.target = self }
        for it in phraseMenu.items { it.target = self }
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu
        refreshMenuState()
    }

    private func refreshMenuState() {
        let s = SettingsStore.shared.current
        let t = AppStrings.for(s.uiLanguage)
        if menuLanguage != s.uiLanguage { menuLanguage = s.uiLanguage; buildMainMenu() }
        phraseItem.isHidden = !s.developerMode
        updateMenuItem.isHidden = !Updater.shared.showsButton
        updateMenuItem.title = Updater.shared.buttonTitle(s.uiLanguage) + "…"
        refreshIcon()
        let h = menuHeader, words = h.text(t, key: s.hotkey.shortLabel)
        (menuSlots[.header]?.view as? MenuHeaderView)?.update(words, tone: h.tone)
        set(.secure, words.secure, enabled: false)
        set(.hotkeyOff, h.showsHotkeyOff(hotkeyActive: hotkey != nil) ? t.mHotkeyOff : nil)
        set(.engineLine, engineLine)
        set(.context, words.item)
        for (k, title) in [(MenuSlot.open, t.mOpen), (.paste, t.mPaste), (.copy, t.mCopyLast), (.settings, t.mSettings),
                           (.setup, t.mSetup), (.report, t.mReport), (.quit, t.mQuit)] { menuSlots[k]?.title = title }
        statusItem.button?.toolTip = words.title
        for it in phraseMenu.items { it.state = (it.tag == (s.phraseId ?? 0)) ? .on : .off }
    }

    private func set(_ k: MenuSlot, _ title: String?, enabled: Bool = true) {
        guard let it = menuSlots[k] else { return }
        it.title = title ?? ""
        it.isHidden = title == nil
        it.isEnabled = enabled
    }

    /// The one fix routes into setup (mic and Accessibility → Permissions, a key → Connect), "Use Cloud" switches.
    @objc private func menuContextClicked() {
        guard let item = menuHeader.item else { showMainWindow(tab: .home); return }
        follow(item.route.inApp)
    }

    private func follow(_ route: MenuRoute) {
        switch route {
        case .setup(let step): openSetup(step)
        case .useCloud: settingsModel.useCloudEngine(settingsModel.cloudTarget(hasKey: { appStatus.keys[$0]?.verified ?? false }))
        case .page(let p): nav.page = p; showMainWindow(tab: .settings)
        case .connectInline: openInlineConnect()
        }
    }

    /// The pill card's second button: its fix (setup step or page); older cards open their Settings page.
    private func pillFixClicked() {
        let f = panelModel.failure
        panelModel.phase = .idle
        NSApp.activate(ignoringOtherApps: true)
        if let fix = f?.fix {
            let cloud = (SettingsStore.shared.current.spokenLanguages ?? []).contains(where: \.isCloud)
            follow(fix.route(cloudLanguage: cloud).inApp); return
        }
        if let page = f?.settingsPage { nav.page = page }
        showMainWindow(tab: .settings)
    }

    @objc private func engineLineClicked() { nav.page = .languages; showMainWindow(tab: .settings) }
    @objc private func hotkeyLineClicked() { openSetup(.permissions) }

    /// Standard app menu bar (needed for ⌘Q, ⌘, and copy/paste inside text fields), in the interface language.
    private func buildMainMenu() {
        let t = strings
        let main = NSMenu()
        func sub(_ title: String) -> NSMenu { let it = NSMenuItem(); main.addItem(it); let m = NSMenu(title: title); it.submenu = m; return m }
        func add(_ m: NSMenu, _ title: String, _ action: Selector?, _ key: String = "", mine: Bool = false) -> NSMenuItem {
            let it = m.addItem(withTitle: title, action: action, keyEquivalent: key)
            if mine { it.target = self }
            return it
        }
        let app = sub("Soyla")
        _ = add(app, t.mmAbout, #selector(NSApplication.orderFrontStandardAboutPanel(_:)))
        _ = add(app, t.mmUpdates, #selector(checkForUpdates), mine: true)
        app.addItem(.separator())
        _ = add(app, t.mSettings, #selector(showSettings), ",", mine: true)
        app.addItem(.separator())
        _ = add(app, t.mmHide, #selector(NSApplication.hide(_:)), "h")
        add(app, t.mmHideOthers, #selector(NSApplication.hideOtherApplications(_:)), "h").keyEquivalentModifierMask = [.command, .option]
        app.addItem(.separator())
        _ = add(app, t.mQuit, #selector(NSApplication.terminate(_:)), "q")

        let edit = sub(t.mmEdit)
        _ = add(edit, t.mmUndo, Selector(("undo:")), "z")
        _ = add(edit, t.mmRedo, Selector(("redo:")), "Z")
        edit.addItem(.separator())
        _ = add(edit, t.mmCut, #selector(NSText.cut(_:)), "x")
        _ = add(edit, t.mmCopy, #selector(NSText.copy(_:)), "c")
        _ = add(edit, t.mmPaste, #selector(NSText.paste(_:)), "v")
        _ = add(edit, t.mmSelectAll, #selector(NSText.selectAll(_:)), "a")
        edit.addItem(.separator())
        for it in lastDictationItems(t) { edit.addItem(it) }

        let view = sub(t.mmView)
        for (i, tab) in MainTab.allCases.enumerated() {
            let title = switch tab { case .home: t.navHome; case .history: t.navHistory; case .settings: t.mmSettingsTab }
            add(view, title, #selector(openTab(_:)), "\(i + 1)", mine: true).tag = i
        }

        let win = sub(t.mmWindow)
        _ = add(win, t.mmSoylaWindow, #selector(openMainWindow), "0", mine: true)
        _ = add(win, t.mmMinimize, #selector(NSWindow.performMiniaturize(_:)), "m")
        _ = add(win, t.mmClose, #selector(NSWindow.performClose(_:)), "w")
        NSApp.windowsMenu = win

        let help = sub(t.mmHelp)
        _ = add(help, t.mSetup, #selector(showOnboarding), mine: true)
        help.addItem(reportMenuItem(t))
        NSApp.helpMenu = help
        NSApp.mainMenu = main
    }
}

// MARK: APP-1 (b) — `--preview`: the Languages page in a made-up state, for docs captures

extension AppDelegate {
    /// One scratch defaults domain for `--preview`, removed after the snapshot is written.
    static let previewSuite = "ai.soyla.preview"

    /// A second window with the sidebar and the Languages page over throwaway state: settings in a scratch defaults
    /// domain (removed after the snapshot), keys as masked fake rows. Nothing reaches the real settings or Keychain.
    /// States: en, uz-missing, uz-mac, uz-connected (v2); v3 inline Connect: home-open, langs-open, langs-fail,
    /// langs-connected; home-micoff, langs-micoff (mic and Accessibility off, whatever this Mac has granted); a "-ru" / "-uz" suffix sets the preview's interface language (the real settings are untouched).
    private func showPreview(_ raw: String) {
        guard let defaults = UserDefaults(suiteName: Self.previewSuite) else { return }
        let ui: UILanguage? = raw.hasSuffix("-ru") ? .ru : (raw.hasSuffix("-uz") ? .uz : nil)
        let state = ui == nil ? raw : String(raw.dropLast(3))
        let model = SettingsModel(store: SettingsStore(defaults: defaults))
        let connected = state == "uz-connected" || state == "langs-connected"
        let keyed = connected || state == "uz-mac"
        var s = model.s
        s.uiLanguage = ui ?? SettingsStore.shared.current.uiLanguage
        s.spokenLanguages = state == "en" ? [.en] : (state == "langs-open" ? [.en, .uz, .ru] : [.en, .uz])
        if connected { s.provider = .google; s.sttModel = ProviderKind.google.defaultSTTModel } else { s.provider = .apple }
        model.s = s
        let fake = Secrets.masked("AIzaFAKE1234")
        // V-39: rows that nothing reloads (the plain init re-read the store on Secrets.didLoad and wiped them).
        let keys = APIKeysModel(preview: keyed ? [.google: APIKeysModel.Row(masked: fake, source: .keychain, verified: true)] : [:])
        let status = AppStatus()
        status.keys = keyed ? [.google: AppStatus.KeyState(masked: fake, verified: true)] : [:]
        status.keychain = .ready
        if state.hasSuffix("micoff") { status.previewPermissions(PermissionState(mic: .denied, ax: false, inputMonitoring: false)) }
        status.lastRun = nil
        status.today = TodayStats()
        let connect = InlineConnectModel(settings: model, status: status)
        if ["home-open", "langs-open", "langs-fail"].contains(state) { connect.open(.language(.uz), provider: .google) }
        if state == "langs-fail" { connect.simulate(draft: "AIzaFAKE1234", verdict: .failed(.rejected)) }
        let nav = MainWindowModel(); nav.tab = state.hasPrefix("home") ? .home : .settings; nav.page = .languages
        let home = HomeState.current(status: status, settings: s)
        let t = AppStrings.for(s.uiLanguage)
        let root = HStack(spacing: 0) {
            Sidebar(nav: nav, t: t, home: home, openSetup: { _ in })
                .frame(width: Ink.appSidebarWidth)
            Group {
                // Tinted exactly as `MainView.detail` tints them (Home none, Settings pages lazur), so secondary buttons
                // draw neutral here too (V-39).
                if nav.tab == .home {
                    HomeView(panel: PanelModel(), status: status, settings: model, nav: nav, home: home, t: t, connect: connect)
                } else {
                    LanguagesPage(m: model, keys: keys, status: status, openSetup: { _ in }, connect: connect).tint(Ink.lazur)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Ink.paper).ignoresSafeArea()
        // 1100 tall, so the page renders unscrolled: `cacheDisplay` draws a ScrollView's content blank, and with Cloud
        // shown the page is taller than the 768 window (it scrolls there).
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: CGSize(width: Ink.appWindow.width, height: 1100)),
                         styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        w.identifier = NSUserInterfaceItemIdentifier("soyla.preview")
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: root)
        w.center()
        w.makeKeyAndOrderFront(nil)
        Log.info("preview: \(raw)")
    }
}
