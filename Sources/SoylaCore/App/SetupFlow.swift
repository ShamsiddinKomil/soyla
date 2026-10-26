import Foundation

// OB-2: first-run setup v2 as a pure reducer. Mirrors the approved v5 prototype's
// state machine; the view and SetupModel only render it and feed it what macOS reports. No AppKit here.

public enum SetupStep: String, CaseIterable, Sendable { case welcome, languages, permissions, connect, tryIt, done }

/// The two hosted providers the Connect step offers.
public enum SetupProvider: String, CaseIterable, Sendable {
    case google, openRouter
    public var kind: ProviderKind { self == .google ? .google : .openRouter }
    public var key: KeyProvider { self == .google ? .google : .openRouter }
    public var displayName: String { self == .google ? "Google AI Studio" : "OpenRouter" }
    public var host: String { self == .google ? "aistudio.google.com" : "openrouter.ai" }
}

/// A real macOS surface Soyla opened and is waiting on (the stage then shows only the one-line instruction).
public enum SystemSurface: Equatable, Sendable { case micAlert, micSettings, accessibility, fnSetting, inputMonitoring }

/// The next permission to ask for, in the order the rows are listed.
public enum PendingPermission: Equatable, Sendable { case mic, micSettings, accessibility, fn }

/// Uzbek, Russian or both (titles like "Connect Uzbek and Russian").
public enum CloudCombo: Equatable, Sendable { case uz, ru, uzru }

public enum SetupKeyFailure: Equatable, Sendable { case malformed, wrongProvider, rejected, unreachable, notSaved }

public enum SetupKeyState: Equatable, Sendable { case idle, opened, checking, ok, failed(SetupKeyFailure) }

public enum TryEngine: Equatable, Sendable { case onDevice, cloud(String) }

public struct TryResult: Equatable, Sendable {
    public let language: SpokenLanguage
    /// What landed in the practice field (kept with its result, so Back shows both or neither). Never logged.
    public let text: String
    /// Measured from hotkey release to the text landing in the practice field.
    public let seconds: Double
    public let engine: TryEngine
}

public struct SetupFlow: Equatable, Sendable {
    public private(set) var step: SetupStep = .languages
    public private(set) var languages: Set<SpokenLanguage> = [.en]
    /// The in-window interface language (decides which connected cloud language Try reads).
    public var uiLanguage: UILanguage = .en

    // Permissions, fed from AppStatus / the fn-setting read.
    public private(set) var mic: PermissionState.Mic = .notDetermined
    public private(set) var ax = false
    public private(set) var inputMonitoringOK = false
    /// The Try step waited `HotkeyProbe.silentTimeout` without a single key event reaching the tap.
    public var keysNotDelivered = false
    /// Sticky: the hotkey was fn and "Press 🌐 key to" was not Do Nothing when first read (stays if another key is
    /// picked on that row).
    public private(set) var fnRowShown = false
    public private(set) var fnOK = true
    /// Last `AppleFnUsageType` read (nil = key absent, the macOS default).
    public private(set) var fnUsage: Int?
    public private(set) var awaiting: SystemSurface?

    // Connect
    /// D3 (owner, 2026-10-25): OpenRouter is pre-selected and listed first; Google stays as the free option.
    public private(set) var provider: SetupProvider = .openRouter
    public private(set) var keyState: SetupKeyState = .idle

    // Try / Done
    private var tried: TryResult?
    public private(set) var triedLanguages: Set<SpokenLanguage> = []
    public private(set) var returnTo: SetupStep?
    public private(set) var finished = false
    /// Connect was skipped (the rail shows it as skipped, not ticked) until a key connects.
    public private(set) var connectSkipped = false

    /// v6: setup opens on a brand Welcome before Languages (Back on Languages returns to it). Flows made with `init()`
    /// start at Languages and have no Welcome.
    public private(set) var hasWelcome = false

    /// APP-1: opened from the main window at one step (Home's Connect…, Change…, Allow…). The run is already
    /// finished: no Welcome, no Back, the rail shows every other step ticked, and the step's Continue closes setup.
    public private(set) var fromApp = false
    /// A key was verified during this run (only then may an app re-entry change the engine).
    private var keyAddedHere = false
    /// APP-1 (b): opened by the Languages page's Connect… / Replace… for one service. A key on file is not taken as
    /// connected (the user is replacing it), and Connect works without a cloud language (English through Cloud).
    public private(set) var replacesKey = false

    public init() {}

    public init(welcome: Bool) {
        hasWelcome = welcome
        if welcome { step = .welcome }
    }

    /// Setup entered from the app. `languages` are the saved spoken languages; `cloudReady` = a verified key (or a
    /// custom endpoint) already serves Cloud, for `provider`. `.connect` without a cloud language opens Languages.
    public init(entry: SetupStep, languages: [SpokenLanguage] = [], provider: SetupProvider? = nil, cloudReady: Bool = false) {
        fromApp = true
        if !languages.isEmpty { self.languages = Set(languages) }
        if let provider { self.provider = provider }
        if cloudReady { keyState = .ok }
        switch entry {
        case .welcome: step = .languages
        case .connect:
            step = .languages
            jumpToConnect()
        default: step = entry
        }
    }

    /// The Languages page's Connect… / Replace… for `provider`: straight to Connect, then Done.
    public init(connectFor provider: SetupProvider, languages: [SpokenLanguage] = []) {
        fromApp = true
        replacesKey = true
        if !languages.isEmpty { self.languages = Set(languages) }
        self.provider = provider
        step = .connect
        returnTo = .done
    }

    // MARK: derived

    public var cloudLanguages: [SpokenLanguage] { [SpokenLanguage.uz, .ru].filter(languages.contains) }
    /// The chosen languages in a stable order (what Settings stores).
    public var languageList: [SpokenLanguage] { SpokenLanguage.allCases.filter(languages.contains) }
    public var needsCloud: Bool { !cloudLanguages.isEmpty }
    public var cloudCombo: CloudCombo? {
        switch (languages.contains(.uz), languages.contains(.ru)) {
        case (true, true): return .uzru
        case (true, false): return .uz
        case (false, true): return .ru
        default: return nil
        }
    }
    public var steps: [SetupStep] { [.languages, .permissions] + (needsCloud ? [.connect] : []) + [.tryIt, .done] }
    public var railIndex: Int { steps.firstIndex(of: step) ?? 0 }
    /// No rail (and no "Step n of N") on Welcome.
    public var showsRail: Bool { step != .welcome }

    public enum RailMark: Equatable, Sendable { case done, skipped, current, pending }
    public func railMark(_ s: SetupStep) -> RailMark {
        guard let i = steps.firstIndex(of: s) else { return .pending }
        if fromApp {
            if s == step { return .current }
            return s == .connect && !connected ? .skipped : .done
        }
        if i == railIndex { return .current }
        if i > railIndex { return .pending }
        if s == .tryIt && triedLanguages.isEmpty { return .skipped }
        return s == .connect && connectSkipped && !connected ? .skipped : .done
    }
    public var connected: Bool { keyState == .ok }

    /// The UI language when it is one of the chosen cloud languages, else the first chosen one.
    public var cloudPick: SpokenLanguage? {
        let ui = SpokenLanguage(uiLanguage)
        return cloudLanguages.contains(ui) ? ui : cloudLanguages.first
    }
    /// What the practice sentence is in: a connected cloud language, otherwise English (the free engine).
    public var tryLanguage: SpokenLanguage { connected ? (cloudPick ?? .en) : .en }
    /// The practice result, only while it is in the current try language (no stale dictation).
    public var currentTry: TryResult? { tried?.language == tryLanguage ? tried : nil }

    public var firstPending: PendingPermission? {
        switch mic {
        case .notDetermined: return .mic
        case .denied: return .micSettings
        case .granted: break
        }
        if !ax { return .accessibility }
        if fnRowShown && !fnOK { return .fn }
        return nil
    }
    public var permissionsDone: Bool { firstPending == nil }
    /// Shown only when Accessibility is on but no key event reached the tap (pending the owner's AX-only test).
    public var inputMonitoringRowShown: Bool { ax && !inputMonitoringOK && keysNotDelivered }

    public var canContinue: Bool {
        switch step {
        case .welcome: return true
        case .languages: return !languages.isEmpty
        case .permissions: return permissionsDone
        case .connect: return connected
        case .tryIt: return currentTry != nil
        case .done: return true
        }
    }

    /// The primary button closes setup (labelled Done): the last step, or a step entered from the app that has
    /// nothing after it.
    public var finishesOnNext: Bool {
        if step == .done { return true }
        guard fromApp else { return false }
        switch step {
        case .languages: return !(needsCloud && !connected)
        case .permissions: return true
        default: return false
        }
    }

    /// Entered from the app there is no Back, except from a Try that Done opened.
    public var showsBack: Bool { !fromApp || (step == .tryIt && returnTo != nil) }

    /// Before Try the gesture is swallowed, so setup can't start a dictation by accident.
    public var hotkeysReachPipeline: Bool { step == .tryIt || step == .done }

    // MARK: Done

    public struct DoneRow: Equatable, Sendable {
        public enum Status: Equatable, Sendable { case readyOnDevice, readyCloud, connectButton, needsKey }
        public let language: SpokenLanguage
        public let status: Status
    }

    /// English always (it works on every Mac), then each chosen cloud language; only the first missing one gets
    /// the Connect… button.
    public var doneRows: [DoneRow] { doneRows(englishReady: true) }
    /// `englishReady`: English's route has a key (false while setup leaves a hosted engine with none on file). D22 /
    /// R-15: then English is the first waiting row and gets the Connect… button (when there is a Connect step).
    public func doneRows(englishReady: Bool) -> [DoneRow] {
        // F-03: English only when chosen (its caption follows the engine in the view, from `LanguageRoute`).
        let enFirst = englishWaits(englishReady: englishReady) && needsCloud
        var rows = languages.contains(.en) ? [DoneRow(language: .en, status: enFirst ? .connectButton : .readyOnDevice)] : []
        var buttonShown = enFirst
        for l in cloudLanguages {
            if connected { rows.append(DoneRow(language: l, status: .readyCloud)); continue }
            rows.append(DoneRow(language: l, status: buttonShown ? .needsKey : .connectButton))
            buttonShown = true
        }
        return rows
    }
    public var allReady: Bool { !needsCloud || connected }
    public var showsTryCloud: Bool { needsCloud && connected && !(cloudPick.map(triedLanguages.contains) ?? true) }

    // MARK: navigation

    @discardableResult
    public mutating func next() -> Bool {
        guard canContinue else { return false }
        if fromApp && (step == .languages || step == .permissions) {
            if step == .languages && needsCloud && !connected { returnTo = .done; go(.connect) } else { finished = true }
            return true
        }
        if let r = returnTo, step == .connect || step == .tryIt { step = r; returnTo = nil; return true }
        if step == .done { finished = true; return true }
        if step == .welcome { go(.languages); return true }
        if let i = steps.firstIndex(of: step), i + 1 < steps.count { go(steps[i + 1]) }
        return true
    }

    public mutating func back() {
        guard showsBack else { return }
        if let r = returnTo, step == .connect || step == .tryIt { step = r; returnTo = nil; return }
        if step == .languages && hasWelcome { go(.welcome); return }
        if let i = steps.firstIndex(of: step), i > 0 { go(steps[i - 1]) }
    }

    private mutating func go(_ s: SetupStep) { step = s; awaiting = nil }

    public mutating func toggle(_ l: SpokenLanguage) {
        guard step == .languages else { return }
        if languages.contains(l) { languages.remove(l) } else { languages.insert(l) }
        if !connected { keyState = .idle }
    }

    /// Setup Assistant rerun: start from the languages chosen last time (an empty list keeps the default).
    public mutating func preselect(_ saved: [SpokenLanguage]) {
        guard step == .languages || step == .welcome, !saved.isEmpty else { return }
        languages = Set(saved)
    }

    /// Setup Assistant reopened: start over, keep what macOS reports and the interface language.
    public mutating func restart() {
        var f = SetupFlow(welcome: hasWelcome)
        f.uiLanguage = uiLanguage
        f.mic = mic; f.ax = ax; f.inputMonitoringOK = inputMonitoringOK
        f.fnUsage = fnUsage; f.fnOK = fnOK; f.fnRowShown = fnRowShown && !fnOK
        self = f
    }

    // MARK: permissions

    public mutating func update(_ p: PermissionState) {
        mic = p.mic; ax = p.ax; inputMonitoringOK = p.inputMonitoringOK
        if inputMonitoringOK { keysNotDelivered = false }
        switch awaiting {
        case .micAlert where mic != .notDetermined: awaiting = nil
        case .micSettings where mic == .granted: awaiting = nil
        case .accessibility where ax: awaiting = nil
        case .inputMonitoring where inputMonitoringOK: awaiting = nil
        default: break
        }
    }

    public mutating func updateFn(hotkeyIsFn: Bool, usage: Int?) {
        fnUsage = usage
        // HOTKEY-1: another key picked on the fn row clears it, and the row stays to show that key.
        guard hotkeyIsFn else { fnOK = true; if awaiting == .fnSetting { awaiting = nil }; return }
        fnOK = usage == 0
        if !fnOK { fnRowShown = true }
        if fnOK, awaiting == .fnSetting { awaiting = nil }
    }

    public mutating func awaitSurface(_ s: SystemSurface) { awaiting = s }
    /// The user came back to Soyla without granting: show the preview again.
    public mutating func cancelAwait() { awaiting = nil }

    // MARK: connect

    public mutating func setProvider(_ p: SetupProvider) {
        guard !connected, p != provider else { return }
        provider = p; keyState = .idle
    }
    public mutating func markOpened() { if keyState != .ok && keyState != .checking { keyState = .opened } }
    public mutating func keyChecking() { if keyState != .ok { keyState = .checking } }
    public mutating func keyFailed(_ f: SetupKeyFailure) { if keyState != .ok { keyState = .failed(f) } }
    public mutating func keyConnected() { keyState = .ok; connectSkipped = false; keyAddedHere = true }

    public mutating func skipConnect() {
        guard step == .connect else { return }
        if !connected { keyState = .idle; connectSkipped = true }
        if fromApp { finished = true; return }        // "Skip for now" from the app closes setup
        if let r = returnTo { step = r; returnTo = nil } else { go(.tryIt) }
    }

    /// Same checks as `KeyShape` (which says it in English), as a failure kind the copy table can word.
    public static func shapeFailure(_ v: String, for p: SetupProvider) -> SetupKeyFailure? {
        guard KeyShape.problem(v, for: p.key) != nil else { return nil }
        let wrong = p == .openRouter ? (v.hasPrefix("AIza") || v.hasPrefix("AQ.")) : v.hasPrefix("sk-or-")
        return wrong ? .wrongProvider : .malformed
    }

    // MARK: try / done

    /// Any non-empty text that arrived after a hotkey release on this step counts (never a string match).
    @discardableResult
    public mutating func recordTry(text: String, releasedAt: Date?, now: Date, engine: TryEngine) -> Bool {
        guard step == .tryIt, let r = releasedAt, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        tried = TryResult(language: tryLanguage, text: text, seconds: max(0, now.timeIntervalSince(r)), engine: engine)
        triedLanguages.insert(tryLanguage)
        return true
    }

    /// The hotkey went down on Try: a new attempt replaces the old one, so no old number shows during it.
    public mutating func beginTryRecording() {
        guard step == .tryIt else { return }
        tried = nil
    }

    public mutating func skipTry() {
        guard step == .tryIt else { return }
        tried = nil
        if let r = returnTo { step = r; returnTo = nil } else { go(.done) }
    }

    /// D22 / R-05: Try with nothing that can transcribe (no key, and English waits for one) shows the key nudge.
    public mutating func connectFromTry() {
        guard step == .tryIt, needsCloud else { return }
        returnTo = .tryIt; go(.connect)
    }

    /// Done → Connect…; a successful key returns to Done.
    public mutating func connectLater() {
        guard step == .done, needsCloud else { return }
        returnTo = .done; go(.connect)
    }

    /// Home's "Connect Uzbek": straight to Connect, then Done (where "Try in X" follows).
    public mutating func jumpToConnect() {
        guard needsCloud else { return }
        returnTo = .done; go(.connect)
    }

    /// Done → "Try in X" → Try → Done.
    public mutating func tryCloud() {
        guard step == .done, showsTryCloud else { return }
        returnTo = .done; go(.tryIt)
    }

    // MARK: engine

    /// Which engine setup leaves behind (nil = keep the current one). A verified key for a chosen cloud language →
    /// that provider. Otherwise the free engine, unless an existing user's working cloud (or custom endpoint) would
    /// be dropped, or the free engine isn't available on this Mac. Never called outside setup.
    /// From the app only a key verified in this run changes the engine (Home's "Use Cloud" covers a key on file).
    public func engine(current: ProviderKind, currentHasVerifiedKey: Bool, setUpBefore: Bool, freeAvailable: Bool) -> ProviderKind? {
        if fromApp { return keyAddedHere && connected && needsCloud && provider.kind != current ? provider.kind : nil }
        if connected && needsCloud { return provider.kind == current ? nil : provider.kind }
        if current == .apple || !freeAvailable { return nil }
        if setUpBefore && (currentHasVerifiedKey || current == .custom) { return nil }
        return .apple
    }

    // MARK: layout and format

    public static let width: CGFloat = SetupScale.pt(960)          // 1056
    public static let stageWidth: CGFloat = SetupScale.pt(340)     // 376
    public static func height(_ s: SetupStep) -> CGFloat {
        switch s {
        case .connect, .tryIt: return SetupScale.pt(580)          // 640
        case .welcome, .languages, .permissions, .done: return SetupScale.pt(560)   // 616
        }
    }

    /// "0.5" in English, "0,5" in Uzbek and Russian.
    public static func seconds(_ s: Double, language: UILanguage) -> String {
        let v = String(format: "%.1f", s)
        return language == .en ? v : v.replacingOccurrences(of: ".", with: ",")
    }
}

// MARK: honest app entry (audit 2026-10-19)

extension SetupFlow {
    /// F-20: Connect with a key already connected: start over with a new key (the saved one stays until it verifies).
    public mutating func replaceKey() {
        guard step == .connect, connected else { return }
        keyState = .idle
    }
    /// V-03 (audit 2026-10-19): the marks the rail draws. A first run is `railMark`; entered from the app, a step is
    /// ticked only when it really happened (permissions granted, a practice dictation made, everything ready).
    /// `railMark` keeps its earlier app-entry meaning (every other step ticked) because its tests pin it.
    public func shownRailMark(_ s: SetupStep) -> RailMark {
        guard fromApp else { return railMark(s) }
        guard steps.contains(s) else { return .pending }
        if s == step { return .current }
        switch s {
        case .permissions: return permissionsDone ? .done : .skipped
        case .connect: return connected ? .done : .skipped
        case .tryIt: return triedLanguages.isEmpty ? .skipped : .done
        case .done: return readiness == .ready && permissionsDone ? .done : .pending
        case .welcome, .languages: return .done
        }
    }
    /// The app's shared answer, from what setup knows (the same `Readiness` Home and the menu read).
    public var readiness: Readiness { readiness(englishReady: true) }
    /// `englishReady`: English's route has a key (`SetupModel.route`); false = a hosted engine with none on file.
    public func readiness(englishReady: Bool) -> Readiness {
        Readiness(micMissing: mic != .granted, axMissing: !ax, englishNeedsKey: !englishReady,
                  missing: connected ? nil : cloudCombo, englishChosen: languages.contains(.en))
    }
    /// D22: English is chosen and waits for a key, so the copy says "Soyla needs an API key".
    public func englishWaits(englishReady: Bool) -> Bool { languages.contains(.en) && !englishReady && !connected }
    /// D22 / R-05: nothing can transcribe the practice sentence (English unless a cloud key is connected).
    public func tryWaitsForKey(englishReady: Bool) -> Bool { !connected && !englishReady }
    /// V-09: entered from the app, Permissions' Done always closes setup (Home keeps nudging what is missing), and so
    /// does Try's while a permission is missing (there is nothing to try). `canContinue` keeps its meaning.
    public var primaryEnabled: Bool { primaryEnabled(englishReady: true) }
    /// D22: Try entered from the app can also be left while it waits for a key (there is nothing to try).
    public func primaryEnabled(englishReady: Bool) -> Bool {
        guard fromApp else { return canContinue }
        switch step {
        case .permissions: return true
        case .tryIt: return canContinue || readiness.isBlocked || tryWaitsForKey(englishReady: englishReady)
        default: return canContinue
        }
    }

    /// The primary when `canContinue` is false but `primaryEnabled` is true: close setup as it stands.
    public mutating func leave(englishReady: Bool = true) {
        guard fromApp, primaryEnabled(englishReady: englishReady) else { return }
        finished = true
    }
}

/// The stage and status line on Try.
public enum TryNote: Equatable, Sendable { case idle, listening, writing, short, ok }

/// What the pill's phase changes mean for the Try step's line (pure).
public enum TryFeedback {
    /// The pipeline drops a short or silent hold without a word (recording → idle) or with the soft "No speech heard"
    /// card; either way the user should hold a little longer. A real error goes back to the plain instruction.
    public static func after(from old: PanelModel.Phase, to new: PanelModel.Phase, softFailure: Bool, note: TryNote) -> TryNote {
        guard note == .writing else { return note }
        if new == .failed { return softFailure ? .short : .idle }
        if old == .recording && (new == .idle || new == .ready) { return .short }
        return note
    }

    /// The result line belongs to the last attempt; it is hidden while a new one runs or after a dropped one.
    public static func showsResult(note: TryNote) -> Bool { note == .ok || note == .idle }
}

/// One ratio for the whole setup window (owner 2026-10-17: "a bit larger"). The v5 design was drawn at 960 wide; the
/// window is now 1056 × 616–640, which sits inside a 13" MacBook Air's ~1470 × 920 pt visible area with ~200 pt
/// either side and ~140 pt above and below. Every dimension goes through `pt` (snapped to the 4 pt grid; insets under
/// 8 pt stay as drawn) and every type size through `type` (snapped to 0.5 pt), so nothing is stretched on its own.
public enum SetupScale {
    public static let ratio: CGFloat = 1.1

    public static func pt(_ v: CGFloat) -> CGFloat {
        guard v >= 8 else { return v }
        return max(v, ((v * ratio) / 4).rounded() * 4)
    }

    public static func type(_ v: CGFloat) -> CGFloat { ((v * ratio) * 2).rounded() / 2 }
}

/// v6 Welcome motion as pure math (the view samples it per frame). Entrance curve (.16, 1, .3, 1); the ambient loop
/// is the pill's 2.9 s "working" swell: each bar's scaleY 1 → 0.62 → 1 on (.45, 0, .55, 1), from 700 ms, staggered
/// 160 ms left to right.
public enum WelcomeMotion {
    public static let loopDelay = 0.7
    public static let stagger = 0.16
    public static let period = 2.9
    public static let low = 0.62

    public static func barScale(at t: Double, index: Int) -> Double {
        let local = t - loopDelay - stagger * Double(index)
        guard local > 0 else { return 1 }
        let p = local.truncatingRemainder(dividingBy: period) / period
        if p <= 0.5 { return 1 - (1 - low) * bezier(0.45, 0, 0.55, 1, p / 0.5) }
        return low + (1 - low) * bezier(0.45, 0, 0.55, 1, (p - 0.5) / 0.5)
    }

    /// CSS `cubic-bezier(x1, y1, x2, y2)` at progress `x` (0…1): solve x(s) for s, return y(s).
    public static func bezier(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, _ x: Double) -> Double {
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }
        func c(_ a: Double, _ b: Double, _ s: Double) -> Double { 3 * a * s * (1 - s) * (1 - s) + 3 * b * s * s * (1 - s) + s * s * s }
        var lo = 0.0, hi = 1.0, s = x
        for _ in 0..<40 {                               // bisection: monotonic in s for valid CSS curves
            s = (lo + hi) / 2
            if c(x1, x2, s) < x { lo = s } else { hi = s }
        }
        return c(y1, y2, s)
    }
}
