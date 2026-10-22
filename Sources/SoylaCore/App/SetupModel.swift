import AppKit
import Combine
import Observation

// OB-2: drives the setup window. Feeds `SetupFlow` what macOS reports (permissions, the fn setting, key checks, the
// practice dictation) and performs its side effects (prompts, deep links, the helper note, the engine choice).
// Logs states and timings only, never dictated text or keys.

enum SetupFocus: Hashable { case title, primary, mic, micSettings, ax, fn, im, keyField, practice }

@MainActor @Observable
final class SetupModel {
    private(set) var flow = SetupFlow()
    private(set) var isPresented = false
    var keyDraft = ""
    private(set) var practiceText = ""
    private(set) var hotkeyHeld = false
    private(set) var tryNote: TryNote = .idle
    /// F-11: the last practice attempt's card (shown inline on Try), cleared by the next hold.
    private(set) var tryFailure: PillFailure?
    /// Bumped with `focusRequest` so the view moves focus to the next action after each grant or step.
    private(set) var focusRequest: SetupFocus?
    private(set) var focusToken = 0
    /// The pane's measured need; the window grows past the step's base height only if the copy needs it.
    private(set) var neededHeight: CGFloat = 0

    var strings: SetupStrings { .shown(flow.uiLanguage) }
    /// HOTKEY-1: mirrored from settings so the panes redraw when a key is picked here; named in the window's language.
    private(set) var hotkey: HotkeyChoice = .fn
    var hotkeyLabel: String { AppStrings.for(flow.uiLanguage).d.hotkey(hotkey) }
    /// Try's "Change key" is open: the hotkey's gestures are swallowed and the next key pressed alone is picked.
    private(set) var pickingKey = false
    var height: CGFloat { max(SetupFlow.height(flow.step), neededHeight) }
    var capturesHotkey: Bool { isPresented && (!flow.hotkeysReachPipeline || pickingKey) }
    var onDeviceEngine: Bool { settings.s.provider == .apple }

    @ObservationIgnored let status: AppStatus
    @ObservationIgnored let settings: SettingsModel
    @ObservationIgnored let keys = APIKeysModel()
    @ObservationIgnored let helper = SettingsHelperPanel()
    @ObservationIgnored private let keyPicker = KeyPickMonitor()
    @ObservationIgnored var onPresent: () -> Void = {}
    @ObservationIgnored var onDismiss: () -> Void = {}
    /// Setup finished (Done, or a step entered from the app closed it): the app shows the main window again.
    @ObservationIgnored var onFinish: () -> Void = {}
    @ObservationIgnored var onResize: (CGFloat) -> Void = { _ in }
    @ObservationIgnored var activateWindow: () -> Void = {}
    @ObservationIgnored private var sinks: Set<AnyCancellable> = []
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var setUpBefore = false
    @ObservationIgnored private var freeAvailable = true
    @ObservationIgnored private var pendingCheck: SetupProvider?
    @ObservationIgnored private var releasedAt: Date?
    @ObservationIgnored private var tryEnteredAt = Date()
    @ObservationIgnored private var hotkeySeenOnTry = false

    init(status: AppStatus, settings: SettingsModel) {
        self.status = status
        self.settings = settings
        status.$permissions.sink { [weak self] p in self?.mutate { $0.update(p) } }.store(in: &sinks)
        keys.$rows.sink { [weak self] rows in self?.keyRowsChanged(rows) }.store(in: &sinks)
        // The main window's globe menu: setup follows it live. `$s` fires on willSet, so read it a turn later.
        settings.$s.map(\.uiLanguage).removeDuplicates().sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.followUILanguage() }
        }.store(in: &sinks)
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.appBecameActive() }
        })
    }

    // MARK: presentation

    func present() {
        if !isPresented {
            var f = SetupFlow(welcome: true)              // v6: every run (first or Setup Assistant) opens on Welcome
            f.preselect(settings.s.spokenLanguages ?? [])     // a rerun starts from the languages chosen last time
            begin(f)
        }
        onPresent()
        requestFocus(.title)
    }

    /// APP-1: Home's Connect…, Change… and Allow… (and the menu bar's items) open setup at that one step
    /// (`SetupFlow(entry:)`): no Welcome, no Back, and the step's Continue closes it. If setup is already open
    /// mid-flow it is only brought to the front.
    func present(entry: SetupStep) {
        guard entry != .welcome else { present(); return }
        if !isPresented {
            let s = settings.s
            let verified: (KeyProvider) -> Bool = { [status] in status.keys[$0]?.verified ?? false }
            let current = s.provider.hostedKey.flatMap { verified($0) ? $0 : nil }
            let onFile = current ?? [KeyProvider.google, .openRouter].first(where: verified)
            // A key already serves Cloud for this engine, or one is on file while "On this Mac" is on (Home then
            // offers "Use Cloud" instead of a second Connect), or a custom endpoint is in use.
            let ready = current != nil || s.provider == .custom || (s.provider == .apple && onFile != nil)
            begin(SetupFlow(entry: entry, languages: s.spokenLanguages ?? [.en],
                            provider: onFile.map { $0 == .openRouter ? .openRouter : .google }, cloudReady: ready))
            Log.info("setup: opened at \(flow.step.rawValue) from the app")
            enter(flow.step)
            onResize(height)
        }
        onPresent()
        if flow.step != .connect && flow.step != .permissions { requestFocus(.title) }
    }

    /// The Languages page's Connect… / Replace… for one service (a custom endpoint has no setup step).
    func present(connectFor p: KeyProvider) {
        guard p != .custom else { return }
        if !isPresented {
            begin(SetupFlow(connectFor: p == .openRouter ? .openRouter : .google, languages: settings.s.spokenLanguages ?? [.en]))
            Log.info("setup: opened at connect for \(p.rawValue) from the Languages page")
            enter(flow.step)
            onResize(height)
        }
        onPresent()
    }

    private func begin(_ start: SetupFlow) {
        var f = start
        f.uiLanguage = settings.s.uiLanguage
        f.update(status.permissions)
        flow = f
        readFn()
        setUpBefore = settings.s.onboardingDone
        freeAvailable = settings.s.provider == .apple || OnDeviceLocale.freshInstallAvailable()
        keyDraft = ""; practiceText = ""; tryNote = .idle; releasedAt = nil; neededHeight = 0; pendingCheck = nil
        keys.refresh()
        isPresented = true
        Log.info("setup: shown (set up before: \(setUpBefore))")
        startPolling()
    }

    private func followUILanguage() {
        let l = settings.s.uiLanguage
        if isPresented, flow.uiLanguage != l { mutate { $0.uiLanguage = l } }
    }

    /// The window's close button: "set up later" (setup shows again next launch).
    func windowClosed() {
        guard isPresented else { return }
        Log.info("setup: closed at \(flow.step.rawValue)")
        dismiss()
    }

    private func finish() {
        applyEngine()
        settings.s.spokenLanguages = flow.languageList
        settings.s.onboardingDone = true
        Log.info("setup: finished (languages: \(flow.languages.map(\.rawValue).sorted().joined(separator: ",")), engine: \(settings.s.provider.rawValue))")
        dismiss()
        onFinish()
    }

    private func dismiss() {
        isPresented = false
        setPickingKey(false)
        pollTask?.cancel(); pollTask = nil
        helper.close()
        hotkeyHeld = false
        onDismiss()
    }

    func reportContentHeight(_ h: CGFloat) {
        let need = h.rounded(.up)
        guard abs(need - neededHeight) > 1 else { return }
        neededHeight = need
        onResize(height)
    }

    private func requestFocus(_ f: SetupFocus) { focusRequest = f; focusToken += 1 }

    private var permissionFocus: SetupFocus {
        switch flow.firstPending {
        case .mic: return .mic
        case .micSettings: return .micSettings
        case .accessibility: return .ax
        case .fn: return .fn
        case nil: return .primary
        }
    }

    // MARK: reducer plumbing

    /// `docs-shots` only (a frozen demo status): set the flow's state directly, as the user's steps would.
    func preview(practice: String? = nil, _ body: (inout SetupFlow) -> Void = { _ in }) {
        guard status.frozen else { return }
        mutate(body)
        if let practice { practiceText = practice }
    }

    private func mutate(_ body: (inout SetupFlow) -> Void) {
        let old = flow
        var f = flow
        body(&f)
        guard f != old else { return }
        flow = f
        changed(from: old)
    }

    private func changed(from old: SetupFlow) {
        if old.awaiting != nil && flow.awaiting == nil {
            helper.close()
            if isPresented && !NSApp.isActive { activateWindow() }
        }
        if old.uiLanguage != flow.uiLanguage {
            if settings.s.uiLanguage != flow.uiLanguage { settings.s.uiLanguage = flow.uiLanguage }
            helper.update(strings: strings)
        }
        if old.step != flow.step {
            setPickingKey(false)
            Log.info("setup: \(old.step.rawValue) → \(flow.step.rawValue)")
            neededHeight = 0
            enter(flow.step)
            onResize(height)
        } else if flow.step == .permissions && old.firstPending != flow.firstPending {
            requestFocus(permissionFocus)
        }
        if flow.step == .tryIt && old.tryLanguage != flow.tryLanguage { resetTry() }
    }

    private func enter(_ step: SetupStep) {
        switch step {
        case .welcome: requestFocus(.primary)
        case .languages: requestFocus(.title)
        case .permissions:
            status.refreshPermissions(); readFn()
            requestFocus(permissionFocus)
        case .connect:
            if !flow.replacesKey, keys.rows[flow.provider.key]?.verified == true { mutate { $0.keyConnected() } }
            requestFocus(flow.connected ? .primary : .title)
        case .tryIt:
            applyEngine()
            resetTry()
            if onDeviceEngine {
                let locale = settings.s.onDeviceLocale
                Task { await OnDeviceModels.shared.ensureReady(locale: locale) }
            }
            requestFocus(.practice)
        case .done: requestFocus(.primary)
        }
    }

    /// Entering Try (or its language changed): the field shows the kept result's text, or nothing.
    private func resetTry() {
        practiceText = flow.currentTry?.text ?? ""; releasedAt = nil; tryNote = .idle
        tryEnteredAt = Date(); hotkeySeenOnTry = false
    }

    // MARK: navigation

    func next() {
        mutate { $0.next() }
        if flow.finished { finish() }
    }
    func back() { mutate { $0.back() } }
    func toggle(_ l: SpokenLanguage) { mutate { $0.toggle(l) } }
    func skipConnect() {
        Log.info("setup: connect skipped")
        mutate { $0.skipConnect() }
        if flow.finished { finish() }                     // entered from the app: Skip closes setup
    }
    func skipTry() { Log.info("setup: practice skipped"); mutate { $0.skipTry() } }
    func connectLater() { mutate { $0.connectLater() } }
    func tryCloud() { mutate { $0.tryCloud() } }
    func setUILanguage(_ l: UILanguage) { mutate { $0.uiLanguage = l } }

    // MARK: permissions

    private func startPolling() {
        pollTask?.cancel()
        guard !status.frozen else { return }      // docs captures: the demo state stays as drawn
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, self.isPresented else { return }
                self.tick()
            }
        }
    }

    /// Every 0.5 s while the window is up: permissions and the fn setting while they matter, the helper's position,
    /// and on Try whether any key event reaches the tap at all.
    private func tick() {
        if flow.step == .permissions || flow.awaiting != nil {
            status.refreshPermissions()
            readFn()
            if flow.awaiting != nil { helper.reposition() }
        }
        if flow.step == .tryIt { probeKeys() }
    }

    /// HOTKEY-1: a key chosen on the fn row or in Try. Another key clears the fn row (no System Settings trip).
    func pickKey(_ c: HotkeyChoice) {
        if settings.s.hotkey != c { Log.info("setup: hotkey → \(c.rawValue)") }
        settings.s.hotkey = c
        setPickingKey(false)
        readFn()
    }

    func setPickingKey(_ on: Bool) {
        guard on != pickingKey else { return }
        pickingKey = on
        if on { keyPicker.start { [weak self] in self?.pickKey($0) } } else { keyPicker.stop() }
    }

    private func readFn() {
        hotkey = settings.s.hotkey
        guard !status.frozen else { return }      // docs captures never read this Mac's fn setting
        let isFn = settings.s.hotkey == .fn
        mutate { $0.updateFn(hotkeyIsFn: isFn, usage: isFn ? SystemSurfaces.fnUsage() : nil) }
    }

    /// Input Monitoring is not asked for by default. Only when Accessibility is on and not one key event reached the
    /// tap for `HotkeyProbe.silentTimeout` on Try does its row appear (pending the owner's AX-only test).
    private func probeKeys() {
        guard flow.ax, !flow.inputMonitoringOK, !flow.keysNotDelivered else { return }
        let p = status.permissions
        let anyEvent = (status.lastKeyEventAt() ?? .distantPast) > tryEnteredAt
        let v = HotkeyProbe.verdict(elapsed: Date().timeIntervalSince(tryEnteredAt), hotkeySeen: hotkeySeenOnTry,
                                    anyEventSeen: anyEvent, toggleOn: p.canListen || p.eventsFlowing)
        guard v == .notDelivered else { return }
        Log.info("setup: no key event reached the tap with Accessibility only; showing Input Monitoring")
        mutate { $0.keysNotDelivered = true }
    }

    private func appBecameActive() {
        guard isPresented, let a = flow.awaiting, a != .micAlert else { return }
        mutate { $0.cancelAwait() }
    }

    func allowMic() {
        mutate { $0.awaitSurface(.micAlert) }
        Task {
            let ok = await SystemSurfaces.requestMicrophone()
            Log.info("setup: microphone \(ok ? "allowed" : "not allowed")")
            status.refreshPermissions()
            if flow.awaiting == .micAlert { mutate { $0.cancelAwait() } }
            if isPresented { activateWindow() }
        }
    }

    func openMicSettings() { openPane(.micSettings, PermissionLinks.microphone, .toggle(canBeMissing: false)) }

    func openAccessibility() {
        _ = Permissions.accessibilityTrusted(prompt: true)     // lists Soyla in the pane (as Settings → Permissions does)
        openPane(.accessibility, PermissionLinks.accessibility, .toggle(canBeMissing: true))
    }

    func openKeyboard() { openPane(.fnSetting, SystemSurfaces.keyboard, .fn) }

    func openInputMonitoring() {
        _ = Permissions.inputMonitoring(prompt: true)
        openPane(.inputMonitoring, PermissionLinks.inputMonitoring, .toggle(canBeMissing: true))
    }

    private func openPane(_ s: SystemSurface, _ link: String, _ kind: SettingsHelperPanel.Kind) {
        mutate { $0.awaitSurface(s) }
        SystemSurfaces.open(link)
        helper.show(kind, strings: strings)
        Log.info("setup: opened System Settings for \(s)")
    }
}

// Connect, Try and the engine choice (an extension to keep the class body short).
extension SetupModel {
    // MARK: connect

    func replaceKey() { mutate { $0.replaceKey() }; keyDraft = ""; requestFocus(.keyField) }

    func setProvider(_ p: SetupProvider) {
        mutate { $0.setProvider(p) }
        if flow.provider == p, keys.rows[p.key]?.verified == true { mutate { $0.keyConnected() } }
    }

    func openSite() {
        if let u = flow.provider.key.keysURL { NSWorkspace.shared.open(u) }
        mutate { $0.markOpened() }
        requestFocus(.keyField)
    }

    /// Saves through the existing Keychain path and checks the key with the provider (`APIKeysModel`).
    func connect() {
        let p = flow.provider
        let v = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if let f = SetupFlow.shapeFailure(v, for: p) {
            mutate { $0.keyFailed(f) }
            Log.info("setup: key refused before saving (\(f))")
            return
        }
        mutate { $0.keyChecking() }
        keys.binding(p.key).wrappedValue = v          // F-21: the draft stays until it verifies, so Connect can retry
        keys.save(p.key)
        let row = keys.rows[p.key]
        if row?.testing == true { pendingCheck = p } else { finishCheck(p, row) }
    }

    /// `APIKeysModel.test` clears `testing` before its `refresh()` sets `verified`, and `@Published` fires on willSet,
    /// so the verdict is read one main-actor turn later, after the whole update landed.
    private func keyRowsChanged(_ rows: [KeyProvider: APIKeysModel.Row]) {
        guard let p = pendingCheck, let r = rows[p.key], !r.testing else { return }
        Task { @MainActor [weak self] in
            guard let self, self.pendingCheck == p else { return }
            self.finishCheck(p, self.keys.rows[p.key])
        }
    }

    private func finishCheck(_ p: SetupProvider, _ r: APIKeysModel.Row?) {
        pendingCheck = nil
        // A rejected key is rolled back (KeyRollback), so its row may be gone, or hold the key it replaced.
        guard let r, r.masked != nil || r.rejected else { mutate { $0.keyFailed(.notSaved) }; Log.info("setup: key not saved"); return }
        if r.verified && !r.rejected {
            mutate { $0.keyConnected() }
            keyDraft = ""
            applyEngine()
            Log.info("setup: key connected (\(p.rawValue))")
            requestFocus(.primary)
        } else {
            let f: SetupKeyFailure = r.rejected ? .rejected : .unreachable
            mutate { $0.keyFailed(f) }
            if r.rejected && r.masked != nil { keys.settleAfterRollback(p.key) }   // the old key is back and fine
            Log.info("setup: key check failed (\(f))")
        }
    }

    // MARK: try

    /// The practice field. Text that lands after a hotkey release on this step is the practice result.
    func setPracticeText(_ t: String) {
        practiceText = t
        guard flow.step == .tryIt, releasedAt != nil else { return }
        let s = settings.s
        let engine: TryEngine = s.provider == .apple ? .onDevice : .cloud(Self.providerName(s.provider))
        var ok = false
        mutate { ok = $0.recordTry(text: t, releasedAt: releasedAt, now: Date(), engine: engine) }
        guard ok, let r = flow.currentTry else { return }
        releasedAt = nil                                    // consumed: later typing is not a dictation
        tryNote = .ok
        Log.info(String(format: "setup: practice dictation landed, %.2f s release→text, engine %@", r.seconds, s.provider.rawValue))
        requestFocus(.primary)
    }

    /// Hotkey actions on Try (the pipeline still handles them): the stage key, the stage line, the release time.
    func noteHotkey(_ a: HotkeyReducer.Action) {
        guard isPresented, flow.step == .tryIt else { return }
        switch a {
        case .startRecording:
            // A new attempt: the old text and number go together, and "Listening…" shows while the key is down.
            hotkeyHeld = true; hotkeySeenOnTry = true; releasedAt = nil
            mutate { $0.beginTryRecording() }
            practiceText = ""; tryNote = .listening; tryFailure = nil
        case .stopAndSend:
            hotkeyHeld = false; releasedAt = Date(); tryNote = .writing
        case .cancelRecording(let reason):
            hotkeyHeld = false
            tryNote = reason == .tap ? .short : .idle
        default: break
        }
    }

    /// The pill's phase on Try: a dropped short/silent hold says "Hold a little longer.", a real error goes back to
    /// the plain instruction (`TryFeedback`).
    func pipelinePhaseChanged(from old: PanelModel.Phase, to new: PanelModel.Phase, softFailure: Bool, failure: PillFailure? = nil) {
        guard isPresented, flow.step == .tryIt else { return }
        if new == .failed, !softFailure, let failure, failure.kind != .info || failure.title == PillFailure.noKeyTitle { tryFailure = failure }
        let n = TryFeedback.after(from: old, to: new, softFailure: softFailure, note: tryNote)
        if n != tryNote { tryNote = n; if n == .short { Log.info("setup: practice hold dropped (short or silent)") } }
    }

    static func providerName(_ k: ProviderKind) -> String {
        switch k {
        case .google: return SetupProvider.google.displayName
        case .openRouter: return SetupProvider.openRouter.displayName
        default: return k.rawValue
        }
    }

    // MARK: engine

    /// The engine mapping (`SetupFlow.engine`); never switches an existing user's working cloud.
    private func applyEngine() {
        let s = settings.s
        let verified = s.provider.hostedKey.map { keys.rows[$0]?.verified ?? false } ?? false
        guard let target = flow.engine(current: s.provider, currentHasVerifiedKey: verified, setUpBefore: setUpBefore,
                                       freeAvailable: freeAvailable) else { return }
        if target == .apple { settings.useFreeEngine() } else { settings.useCloudEngine(target) }
        Log.info("setup: engine \(s.provider.rawValue) → \(target.rawValue)")
    }
}

// Audit 2026-10-19: the primary from the app, and the one fix while a permission is missing.
extension SetupModel {
    /// The engine setup will leave behind (what Done and the Languages captions describe; flows audit F-03/F-04).
    var engineAfter: ProviderKind {
        let s = settings.s
        let verified = s.provider.hostedKey.map { keys.rows[$0]?.verified ?? false } ?? false
        return flow.engine(current: s.provider, currentHasVerifiedKey: verified, setUpBefore: setUpBefore,
                           freeAvailable: freeAvailable) ?? s.provider
    }

    /// Where `l` will go once setup closes: the app's shared `LanguageRoute`.
    func route(_ l: SpokenLanguage) -> LanguageRoute {
        let e = engineAfter
        let ready = e.hostedKey.map { k in (flow.connected && flow.provider.key == k) || keys.rows[k]?.masked != nil } ?? true
        return LanguageRoute.route(l, engine: e, engineReady: ready, keyService: flow.connected ? flow.provider.displayName : nil)
    }

    /// The primary of Permissions and Try: the step's own Continue, or leave when entered from the app.
    func primary() { if flow.canContinue { next() } else { leave() } }

    /// V-09/V-11: entered from the app, Done closes setup even when the step's own condition isn't met.
    func leave() {
        mutate { $0.leave() }
        if flow.finished { finish() }
    }

    /// Try and Done while a permission is missing: ask for the first one that is (the same actions as Permissions).
    func allowMissing() {
        switch flow.mic {
        case .notDetermined: allowMic()
        case .denied: openMicSettings()
        case .granted: if !flow.ax { openAccessibility() }
        }
    }
}
