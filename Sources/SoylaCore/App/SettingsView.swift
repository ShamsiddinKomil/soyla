import SwiftUI
import AppKit
import ServiceManagement

/// ObservableObject bridge over SettingsStore for SwiftUI bindings.
@MainActor
public final class SettingsModel: ObservableObject {
    @Published public var s: Settings { didSet { guard !syncing else { return }; store.update { $0 = s } ; onChange?(s) } }
    @Published public var models: [ModelInfo] = []
    @Published public var keyStatus: String = "key: not found"
    /// HOTKEY-1: the Hotkey page's live test (AppDelegate feeds it while that page is in front).
    @Published var keyTest: KeyTest = .idle
    @Published public var vocabularyText: String = "" { didSet { s.vocabulary = vocabularyText.split(whereSeparator: { $0 == "\n" || $0 == "," }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } } }
    public var onChange: ((Settings) -> Void)?
    private let store: SettingsStore
    /// Pulling in changes made elsewhere (pill drag/right-click, menu bar) so this copy doesn't overwrite them.
    private var syncing = false
    private var syncObserver: NSObjectProtocol?

    public init(store: SettingsStore = .shared) {
        self.store = store
        self.s = store.current
        self.vocabularyText = store.current.vocabulary.joined(separator: "\n")
        refreshKeyStatus()
        syncObserver = NotificationCenter.default.addObserver(forName: SettingsStore.didChange, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncFromStore() }
        }
    }

    private func syncFromStore() {
        let c = store.current
        guard c != s else { return }
        syncing = true; s = c; syncing = false
    }

    public func refreshKeyStatus() {
        if let k = try? Secrets.openRouterKey() { keyStatus = "key: loaded (\(Secrets.masked(k)))" } else { keyStatus = "key: missing — add it in Engine" }
    }

    public func loadModels(force: Bool = false) {
        guard let key = try? Secrets.openRouterKey() else { return }
        Task {
            if let list = try? await OpenRouterSTTProvider.listTranscriptionModels(apiKey: key, forceRefresh: force) {
                await MainActor.run { self.models = list.sorted { $0.id < $1.id } }
            }
        }
    }
}

/// Settings → Engine: per-provider key state. Values stay in the key file; the UI only ever sees `Secrets.masked`.
/// One path: paste (or type) → saved to the key file → checked with the provider right away. No separate Test step.
@MainActor
final class APIKeysModel: ObservableObject {
    private var loadObserver: NSObjectProtocol?
    struct Row {
        var masked: String? = nil
        var source: Secrets.Source? = nil
        var verified = false
        var draft = ""
        var testing = false
        var message: String? = nil
        var messageOK = false
        /// The last check said the provider refused this key (as opposed to a network problem).
        var rejected = false
    }

    /// What the card shows, derived from the row. Pure so it can be tested.
    enum Status: Equatable {
        case empty(problem: String?)          // nothing saved; `problem` = why the last paste was refused
        case checking
        case connected(detail: String?)       // saved and the provider accepted it
        case rejected                         // saved, provider said no
        case unchecked(reason: String?)       // saved, couldn't reach the provider (or custom: no check exists)
    }

    @Published var rows: [KeyProvider: Row] = [:]
    var onChange: ((KeyProvider) -> Void)?

    /// `--preview` only (V-39): fixed fake rows; never reads the Keychain and never reloads over them.
    init(preview: [KeyProvider: Row]) { rows = preview }

    init() {
        refresh()
        loadObserver = NotificationCenter.default.addObserver(forName: Secrets.didLoad, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func status(_ p: KeyProvider) -> Status { Self.status(rows[p] ?? Row(), provider: p) }

    static func status(_ r: Row, provider p: KeyProvider) -> Status {
        if r.testing { return .checking }
        guard r.masked != nil else { return .empty(problem: r.messageOK ? nil : r.message) }
        if r.verified { return .connected(detail: detail(r.message)) }
        if p == .custom { return .unchecked(reason: nil) }
        if r.rejected { return .rejected }
        return .unchecked(reason: r.messageOK ? nil : r.message)
    }

    /// "OK · $4.20 credit left" → "$4.20 credit left"; "OK, 52 models" → nil.
    static func detail(_ message: String?) -> String? {
        guard let m = message, m.hasPrefix("OK · ") else { return nil }
        return String(m.dropFirst(5))
    }

    func refresh() {
        for p in KeyProvider.allCases {
            var r = rows[p] ?? Row()
            if let hit = Secrets.find(p) {
                r.masked = Secrets.masked(hit.value); r.source = hit.source; r.verified = Secrets.isVerified(p, key: hit.value)
            } else {
                r.masked = nil; r.source = nil; r.verified = false; r.rejected = false
            }
            rows[p] = r
        }
    }

    func binding(_ p: KeyProvider) -> Binding<String> {
        Binding(get: { self.rows[p]?.draft ?? "" }, set: { self.rows[p, default: Row()].draft = $0 })
    }

    private func setMessage(_ p: KeyProvider, _ text: String?, ok: Bool) {
        rows[p, default: Row()].message = text; rows[p, default: Row()].messageOK = ok
    }

    /// Typed key: same path as Paste.
    func save(_ p: KeyProvider) {
        let v = (rows[p]?.draft ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        rows[p, default: Row()].draft = ""
        guard !v.isEmpty else { return }
        accept(p, v)
    }

    /// Reads the clipboard, saves and checks it, then clears the clipboard so the key does not linger there.
    func paste(_ p: KeyProvider) {
        let v = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if accept(p, v) { NSPasteboard.general.clearContents() }
    }

    @discardableResult
    private func accept(_ p: KeyProvider, _ v: String) -> Bool {
        if let problem = KeyShape.problem(v, for: p) {
            setMessage(p, problem, ok: false)
            return false
        }
        // A saved key (key file) that this one replaces: put back if the service rejects the new one.
        let old = Secrets.find(p).flatMap { $0.source == .keychain && $0.value != v ? $0.value : nil }
        let oldVerified = old.map { Secrets.isVerified(p, key: $0) } ?? false
        do {
            try Secrets.save(v, for: p)
            Log.info("key saved: \(p.rawValue)")
            rows[p, default: Row()].rejected = false
            setMessage(p, nil, ok: true)
        } catch {
            Log.info("key save failed: \(p.rawValue) \(error.localizedDescription)")
            setMessage(p, "Couldn't save the key: \(error.localizedDescription)", ok: false)
            return false
        }
        refresh(); onChange?(p)
        if p != .custom { test(p, rollback: (old, oldVerified)) }
        return true
    }

    func remove(_ p: KeyProvider) {
        do {
            try Secrets.remove(p)
            Log.info("key removed: \(p.rawValue)")
            setMessage(p, nil, ok: true)
        } catch {
            setMessage(p, error.localizedDescription, ok: false)
        }
        refresh(); onChange?(p)
    }

    /// `rollback`: after a save, the key it replaced (nil = none). A key the service rejects is not kept (`KeyRollback`).
    func test(_ p: KeyProvider, rollback: (previous: String?, verified: Bool)? = nil) {
        guard let key = Secrets.find(p)?.value else { return }
        rows[p, default: Row()].testing = true
        Task {
            let r = await KeyCheck.run(p, key: key)
            await MainActor.run {
                if let rb = rollback { self.roll(p, KeyRollback.action(rejected: r.rejected, previous: rb.previous, previousVerified: rb.verified)) }
                self.rows[p, default: Row()].testing = false
                self.rows[p, default: Row()].rejected = r.rejected
                self.setMessage(p, r.message, ok: r.ok)
                self.refresh(); self.onChange?(p)
            }
        }
    }
}

extension APIKeysModel {
    /// After a rejected Replace… put the old key back: the card shows that key again, not the rejection.
    func settleAfterRollback(_ p: KeyProvider) {
        rows[p, default: Row()].rejected = false
        rows[p, default: Row()].message = nil
        refresh()
    }

    private func roll(_ p: KeyProvider, _ a: KeyRollback.Action) {
        do {
            switch a {
            case .keep: return
            case .remove: try Secrets.remove(p); Log.info("key rejected, removed: \(p.rawValue)")
            case let .restore(v, verified):
                try Secrets.save(v, for: p)
                if verified { Secrets.markVerified(p, key: v) }
                Log.info("key rejected, previous restored: \(p.rawValue)")
            }
        } catch {
            Log.info("key rollback failed: \(p.rawValue) \(error.localizedDescription)")
        }
    }
}

/// What happens to a just-saved key once the service has answered (regression pass 2026-10-20: a rejected key stayed
/// on file as "Unchecked", and Replace… with a bad key lost the good one). Pure, unit-tested.
enum KeyRollback {
    enum Action: Equatable { case keep, remove, restore(String, verified: Bool) }

    static func action(rejected: Bool, previous: String?, previousVerified: Bool) -> Action {
        guard rejected else { return .keep }
        guard let previous else { return .remove }
        return .restore(previous, verified: previousVerified)
    }
}

/// Catches the common paste mistakes before anything is saved. Pure, unit-tested.
enum KeyShape {
    /// English as built; the key card shows these two in the interface language (`AppDStrings.kpEmpty`, `kpSpaces`).
    static let emptyMessage = "The clipboard is empty. Copy the key first, then press Paste key."
    static let spacesMessage = "That isn't a key: the clipboard holds text with spaces. Copy just the key."

    static func problem(_ v: String, for p: KeyProvider) -> String? {
        if v.isEmpty { return emptyMessage }
        if v.contains(where: \.isWhitespace) || v.count > 300 { return spacesMessage }
        // Google keys start with AIza, or AQ. for the "auth keys" AI Studio creates since May 2026.
        if p == .openRouter && (v.hasPrefix("AIza") || v.hasPrefix("AQ.")) { return "That's a Google AI Studio key. Use the Google AI Studio card, or copy your OpenRouter key (it starts with sk-or-)." }
        if p == .google && v.hasPrefix("sk-or-") { return "That's an OpenRouter key. Use the OpenRouter card, or copy the key from aistudio.google.com." }
        if p != .custom && v.count < 20 { return "That's too short to be a key. Copy the whole key." }
        return nil
    }
}

extension KeyProvider {
    /// Where to create a key, for the "Get a key" button.
    var keysURL: URL? {
        switch self {
        case .openRouter: return URL(string: "https://openrouter.ai/keys")
        case .google: return URL(string: "https://aistudio.google.com/apikey")
        case .custom: return nil
        }
    }
    /// The short in-app guide under "How do I get a key?" (full version: docs/KEYS.md). Checked 2026-10-16.
    var guide: (steps: [String], note: String?) {
        switch self {
        case .openRouter:
            return (["Sign in at openrouter.ai (Google, GitHub or email).",
                     "Add credit: Settings → Credits. The minimum is $5; card payments carry a small fee.",
                     "Open Keys → Create key. Name it Soyla and set a credit limit, for example $5.",
                     "Copy the key. It starts with sk-or-. Copy it now: it may be shown only once."],
                    "About half a cent per 40 seconds of speech, so $5 lasts a long time.")
        case .google:
            return (["Open aistudio.google.com/apikey and sign in with your Google account (18+).",
                     "Accept the terms. AI Studio makes a project and a key for you; if not, click Create API key.",
                     "Copy the key."],
                    "Free keys work, but Google may use free-tier audio to improve its products. For private dictation, turn on billing in AI Studio.")
        case .custom:
            return ([], nil)
        }
    }

    var keysHost: String {
        switch self {
        case .openRouter: return "openrouter.ai"
        case .google: return "aistudio.google.com"
        case .custom: return "your server"
        }
    }
}

/// One provider's key as a guided card: get a key → paste it → connected. The status line at the top always says
/// where things stand; there is only ever one main button.
struct KeyCard: View {
    @ObservedObject var keys: APIKeysModel
    let provider: KeyProvider
    /// Settings: shows "Used for dictation" or a button to switch to this provider.
    var inUse: Bool? = nil
    var onUse: (() -> Void)? = nil
    /// The interface language (APP-1 (d)); the custom-endpoint card is the one that shows in the app.
    var language: UILanguage = .en
    @State private var replacing = false
    @State private var typing = false
    private var s: AppStrings { .for(language) }
    private var t: AppDStrings { s.d }

    var body: some View {
        let st = keys.status(provider)
        let r = keys.rows[provider] ?? APIKeysModel.Row()
        SettingsGroup {
            Row(label: provider.label, caption: caption(st, r)) { statusLine(st) }
            WideRow(divider: false) { content(st, r) }
        }
        .onChange(of: st) { _, new in if case .connected = new { replacing = false; typing = false } }
    }

    private func caption(_ st: APIKeysModel.Status, _ r: APIKeysModel.Row) -> String? {
        let use: String? = inUse.map { $0 ? t.kcUsed : t.kcOptional }
        let parts: [String?]
        switch st {
        case .connected(let d): parts = [use, r.masked, d]
        case .rejected, .unchecked: parts = [use, r.masked]
        default: parts = [use]
        }
        let text = parts.compactMap { $0 }.joined(separator: " · ")
        return text.isEmpty ? nil : text
    }

    @ViewBuilder private func statusLine(_ st: APIKeysModel.Status) -> some View {
        switch st {
        case .empty: StatusLine(color: Ink.text4, text: t.kcEmpty)
        case .checking: HStack(spacing: 6) { ProgressView().controlSize(.mini); Text(s.keyChecking).font(Ink.Font.body).foregroundStyle(Ink.text2) }
        case .connected: StatusLine(color: Ink.ok, text: s.connected)
        case .rejected: StatusLine(color: Ink.signal, text: s.keyRejected)
        case .unchecked: StatusLine(color: Ink.warn, text: provider == .custom ? t.kcSaved : s.keyUnchecked)
        }
    }

    @ViewBuilder private func content(_ st: APIKeysModel.Status, _ r: APIKeysModel.Row) -> some View {
        switch st {
        case .connected where !replacing:
            HStack(spacing: Ink.s3) {
                Text(t.kcWorks).font(Ink.Font.body).foregroundStyle(Ink.text2)
                Spacer()
                usage
                Menu(t.kcMore) {
                    Button(t.kcReplaceKey) { replacing = true }
                    if r.source == .keychain { Button(s.keyRemove, role: .destructive) { keys.remove(provider) } }
                }
                .menuStyle(.borderlessButton).fixedSize().foregroundStyle(Ink.text2)
            }
            .controlSize(.small)
        case .checking:
            Text(t.kcAsking(provider.keysHost))
                .font(Ink.Font.body).foregroundStyle(Ink.text2)
        case .rejected:
            Text(t.kcRefused(provider.label))
                .font(Ink.Font.body).foregroundStyle(Ink.text).fixedSize(horizontal: false, vertical: true)
            steps(problem: nil)
        case .unchecked(let reason) where provider != .custom && !replacing:
            Text("Saved, but Soyla couldn't reach \(provider.keysHost) to check it" + (reason.map { ": \($0)" } ?? ".")
                 + " Dictation will still try it.")
                .font(Ink.Font.body).foregroundStyle(Ink.text).fixedSize(horizontal: false, vertical: true)
            HStack { Button(t.kcCheckAgain) { keys.test(provider) }.buttonStyle(.borderedProminent); Button(t.kcReplaceKey) { replacing = true } }
                .controlSize(.small)
        default:
            steps(problem: { if case .empty(let p) = st { return p }; return nil }())
            if replacing { Button(s.cancel) { replacing = false }.buttonStyle(.plain).font(Ink.Font.body).foregroundStyle(Ink.text2) }
        }
        if r.source == .environment || r.source == .envFile {
            Text(t.ceEnv(r.source == .environment))
                .font(Ink.Font.caption).foregroundStyle(Ink.text2)
        }
    }

    /// Settings only: which provider dictation uses.
    @ViewBuilder private var usage: some View {
        if inUse == false, let onUse { Button(t.kcUse, action: onUse) }
    }

    /// The two numbered steps. The one main button is Paste key.
    @ViewBuilder private func steps(problem: String?) -> some View {
        VStack(alignment: .leading, spacing: Ink.s3) {
            if let url = provider.keysURL {
                step(1, "Create a key on \(provider.keysHost) and copy it.") {
                    Button("Open \(provider.keysHost)") { NSWorkspace.shared.open(url) }
                }
                KeyGuide(provider: provider)
            }
            step(provider.keysURL == nil ? 1 : 2, t.kcStep2) {
                Button(t.kcPaste) { keys.paste(provider) }
                    .buttonStyle(.borderedProminent)
                    .help(t.kcPasteH)
            }
            if let problem {
                Text(problem == KeyShape.emptyMessage ? t.kpEmpty : problem == KeyShape.spacesMessage ? t.kpSpaces : problem).font(Ink.Font.body).foregroundStyle(Ink.signal).fixedSize(horizontal: false, vertical: true)
            }
            if typing {
                HStack(spacing: Ink.s2) {
                    SecureField(t.kcField, text: keys.binding(provider)).well()
                        .onSubmit { keys.save(provider) }
                        .accessibilityLabel(t.kcA11y(provider.label))
                    Button(t.kcSave) { keys.save(provider) }.disabled((keys.rows[provider]?.draft ?? "").isEmpty)
                }
            } else {
                Button(t.kcType) { typing = true }.buttonStyle(.plain).font(Ink.Font.caption).foregroundStyle(Ink.lazur)
            }
        }
        .controlSize(.regular)
    }

    private func step<B: View>(_ n: Int, _ text: String, @ViewBuilder button: () -> B) -> some View {
        HStack(spacing: Ink.s3) {
            Text("\(n)").font(Ink.Font.key).foregroundStyle(Ink.lazur).frame(width: 20, height: 20)
                .background(Circle().fill(Ink.lazurWash))
            Text(text).font(Ink.Font.body).foregroundStyle(Ink.text).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Ink.s2)
            button()
        }
    }
}

extension ProviderKind {
    var keyProvider: KeyProvider? { switch self { case .openRouter: return .openRouter; case .google: return .google; case .custom: return .custom; case .apple: return nil } }
}

extension SettingsModel {
    /// Switch dictation to the provider that owns this key, with that provider's default models.
    func useProvider(_ p: KeyProvider) {
        let kind: ProviderKind = p == .google ? .google : (p == .custom ? .custom : .openRouter)
        guard s.provider != kind else { return }
        var n = s; n.provider = kind; n.sttModel = kind.defaultSTTModel; n.cleanupModel = kind.defaultCleanupModel; s = n
    }
}

/// Human names for the curated model ids (shown instead of raw ids), and which one is recommended.
enum ModelNames {
    static func name(_ id: String) -> String {
        switch OpenRouterSTTProvider.plainModel(id) {
        case "google/gemini-3.5-flash", "gemini-3.5-flash": return "Gemini 3.5 Flash"
        case "google/gemini-3.5-flash-lite", "gemini-3.5-flash-lite": return "Gemini 3.5 Flash-Lite (faster, less accurate)"
        default: return id
        }
    }
    static func curated(_ p: ProviderKind) -> [String] {
        switch p {
        case .openRouter, .custom: return ["google/gemini-3.5-flash", "google/gemini-3.5-flash-lite"]
        case .google: return ["gemini-3.5-flash", "gemini-3.5-flash-lite"]
        case .apple: return [ProviderKind.apple.defaultSTTModel]   // unused: the free engine has no model picker
        }
    }
    static func title(_ id: String, provider: ProviderKind) -> String {
        name(id) + (id == provider.defaultSTTModel ? " (recommended)" : "")
    }
}

/// One Settings page at a time: header, then groups of rows (docs/DESIGN.md).
public struct SettingsView: View {
    @ObservedObject var m: SettingsModel
    @StateObject private var keys = APIKeysModel()
    let status: AppStatus
    /// Opens the Setup Assistant (wired by the main window).
    var onSetupAssistant: (() -> Void)? = nil
    /// APP-1 (b): setup at one step, and setup's Connect for one service (the Languages page).
    var openSetup: (SetupStep) -> Void = { _ in }
    var connectFor: (KeyProvider) -> Void = { _ in }
    var connect: InlineConnectModel?
    let page: SettingsPage
    /// P5: the one-time "switch engine?" offer after a key is added (while free) or removed (while on Cloud).
    @State private var switchPrompt: EngineSwitchPrompt?
    init(model: SettingsModel, status: AppStatus, page: SettingsPage, onSetupAssistant: (() -> Void)? = nil,
         openSetup: @escaping (SetupStep) -> Void = { _ in }, connectFor: @escaping (KeyProvider) -> Void = { _ in },
         connect: InlineConnectModel? = nil) {
        self.m = model; self.status = status; self.page = page; self.onSetupAssistant = onSetupAssistant
        self.openSetup = openSetup; self.connectFor = connectFor; self.connect = connect
    }

    public var body: some View {
        Group {
            switch page {
            case .apiKeys:
                LanguagesPage(m: m, keys: keys, status: status, openSetup: openSetup,
                              connect: connect ?? InlineConnectModel(settings: m, status: status))
            case .permissions: PermissionsPage(m: m, status: status, openSetup: openSetup)
            case .dictation: DictationPage(m: m)
            case .hotkey: HotkeyPage(m: m)
            case .pill: PillPage(m: m)
            case .privacy: PrivacyPage(m: m, status: status)
            case .about: AboutPage(m: m, onSetupAssistant: onSetupAssistant)
            case .developer: DeveloperPage(m: m)
            }
        }
        .onAppear {
            m.loadModels(); keys.refresh()
            keys.onChange = { [m, status] p in
                if p == .openRouter { m.refreshKeyStatus(); m.loadModels() }
                status.refresh()
                evaluateSwitchPrompt()
            }
        }
        // Keys now arrive through setup's Connect (its own APIKeysModel): re-read them here, then make the P5 offer.
        .onChange(of: status.keys) { _, _ in keys.refresh(); evaluateSwitchPrompt() }
        .alert(switchPrompt?.title(m.s.uiLanguage) ?? "", isPresented: Binding(get: { switchPrompt != nil }, set: { if !$0 { switchPrompt = nil } }),
               presenting: switchPrompt) { p in
            Button(p.confirmTitle(m.s.uiLanguage)) {
                switch p {
                case .toCloud(let k): m.useCloudEngine(m.cloudTarget(hasKey: { $0 == k }))
                case .toFree: m.useFreeEngine()
                }
            }
            Button(p.declineTitle(m.s.uiLanguage), role: .cancel) {}
        } message: { p in Text(p.message(m.s.uiLanguage)) }
    }

    /// Decides from the current keys; each offer is made at most once (persisted), and never switches by itself.
    private func evaluateSwitchPrompt() {
        let flags = EnginePromptFlags()
        let keyed = KeyProvider.allCases.filter { keys.rows[$0]?.masked != nil }
        let verified = Set(keyed.filter { keys.rows[$0]?.verified == true })
        var freeOK = true
        if case .unavailable? = OnDeviceModels.shared.state { freeOK = false }
        guard let p = EngineSwitchPrompt.decide(provider: m.s.provider, keyedProviders: keyed, verified: verified,
                                                asked: flags.asked, freeAvailable: freeOK) else { return }
        guard p.fits(spoken: m.s.spokenLanguages) else { return }     // F-09: never offer English-only to a UZ+RU user
        flags.markAsked(p)
        switchPrompt = p
    }
}

extension SettingsView {
    /// Start, then done: what a dictation sounds like with this set and volume.
    @MainActor static func previewSounds(_ set: SoundSet, _ volume: Double) {
        Sounds.play(.start, set: set, volume: volume)
        Task { @MainActor in
            if await MainDelay.elapsed(0.45) { Sounds.play(.done, set: set, volume: volume) }
        }
    }
}

extension HotkeyChoice {
    /// The key's name in the interface language ("fn", "O‘ng ⌘", "Правый ⌘"), never the English settings label
    /// "fn (🌐)" (HOTKEY-1: other keys are now offered in onboarding, so their names show in UZ/RU text).
    @MainActor var shortLabel: String { AppStrings.current.d.hotkey(self) }
}

// MARK: Developer

/// Everything lab-related lives here and is hidden until the toggle is on.
struct DeveloperSection: View {
    @ObservedObject var m: SettingsModel
    /// The app's Developer page draws its own switch at the app scale (audit V-15).
    var showsSwitch = true

    var body: some View {
        if showsSwitch {
            SettingsGroup {
                Row(label: "Developer mode", caption: "Shows timings and run tags in History and the controls below. Nothing here is needed for everyday use.", divider: false) {
                    Toggle("Developer mode", isOn: $m.s.developerMode).toggleStyle(.app).controlSize(.small).rowControl()
                }
            }
        }
        if m.s.developerMode {
            SettingsGroup(title: "Lab") {
                Row(label: "Audio format") {
                    Picker("Audio format", selection: $m.s.audioFormat) {
                        ForEach(AudioFormatChoice.allCases, id: \.self) { Text($0.label).tag($0) }
                    }.pickerStyle(.menu).rowControl()
                }
                Row(label: "Transcribe while speaking (experimental)",
                    caption: "Sends the recording in pieces at your pauses while fn is held, so long dictations paste sooner. Same model and audio as normal.") {
                    Toggle("Transcribe while speaking", isOn: $m.s.streamSegments).toggleStyle(.app).controlSize(.small).rowControl()
                }
                Row(label: "Instant results with Live",
                    caption: "On by default when Google AI Studio is your engine: uses Google Live's text when it is safe (one language, or Auto locked onto one), about 0.5 s instead of 2 s. Mixed speech still waits for the pieces.") {
                    Toggle("Instant results with Live", isOn: $m.s.liveFastPath).toggleStyle(.app).controlSize(.small).rowControl()
                }
                Row(label: "Pre-warm connection on key down") {
                    Toggle("Pre-warm connection", isOn: $m.s.prewarmConnection).toggleStyle(.app).controlSize(.small).rowControl()
                }
                Row(label: "Tag next run as phrase") {
                    Picker("Tag next run as phrase", selection: Binding(get: { m.s.phraseId ?? 0 }, set: { m.s.phraseId = $0 == 0 ? nil : $0 })) {
                        Text("free").tag(0)
                        ForEach(1...10, id: \.self) { Text("phrase \($0)").tag($0) }
                    }.pickerStyle(.menu).rowControl()
                }
                Row(label: "Warn at \(Int(m.s.warnAtSec)) s") {
                    Stepper("Warn at", value: $m.s.warnAtSec, in: 10...Double(max(20, m.s.hardStopSec - 5)), step: 5).labelsHidden()
                }
                Row(label: "Stop at \(Int(m.s.hardStopSec)) s") {
                    Stepper("Stop at", value: $m.s.hardStopSec, in: (m.s.warnAtSec + 5)...300, step: 5).labelsHidden()
                }
                if m.s.provider != .custom && m.s.provider != .apple {
                    Row(label: "Correction pass model") {
                        Picker("Correction pass model", selection: $m.s.cleanupModel) {
                            ForEach(Set(ModelNames.curated(m.s.provider) + [m.s.cleanupModel]).sorted(), id: \.self) { Text(ModelNames.name($0)).tag($0) }
                        }.pickerStyle(.menu).rowControl().disabled(m.s.cleanupLevel == .off)
                    }
                }
                if m.s.provider == .openRouter {
                    Row(label: "Other models") {
                        HStack(spacing: Ink.s2) {
                            Picker("Other models", selection: $m.s.sttModel) {
                                let ids = Set(m.models.map(\.id) + [m.s.sttModel] + ModelNames.curated(.openRouter))
                                ForEach(ids.sorted(), id: \.self) { Text($0).tag($0) }
                            }.pickerStyle(.menu).rowControl()
                            Button("Refresh") { m.loadModels(force: true) }.controlSize(.small)
                        }
                    }
                }
                WideRow { LatencyDetails() }
                WideRow { LastRequestView() }
                Row(label: "Logs and the measurement harness", divider: false) {
                    HStack(spacing: Ink.s3) {
                        Link("HARNESS.md", destination: URL(string: "https://github.com/ShamsiddinKomil/soyla/blob/main/docs/HARNESS.md")!).font(Ink.Font.body)
                        Button("Open logs") {
                            SoylaPaths.ensureDirectories()
                            NSWorkspace.shared.activateFileViewerSelecting([SoylaPaths.appLog])
                        }.controlSize(.small)
                    }
                }
            }
        }
    }
}

/// p50 / p90 per stage over the most recent live runs.
enum LatencyStats {
    static func percentile(_ sorted: [Double], _ p: Double) -> Double? {
        guard !sorted.isEmpty else { return nil }
        let idx = Int((Double(sorted.count - 1) * p).rounded())
        return sorted[min(max(idx, 0), sorted.count - 1)]
    }

    static func compute(_ runs: [RunRecord], last n: Int = 50) -> [(stage: String, p50: Double, p90: Double, count: Int)] {
        let recent = runs.filter { $0.source == "live" && $0.status == .ok }.suffix(n)
        var byStage: [String: [Double]] = [:]
        for r in recent { for (k, v) in r.timelineMs { byStage[k, default: []].append(v) } }
        return byStage.keys.sorted().compactMap { k in
            let v = byStage[k]!.sorted()
            guard let a = percentile(v, 0.5), let b = percentile(v, 0.9) else { return nil }
            return (k, a, b, v.count)
        }
    }
}

struct LatencyDetails: View {
    @State private var rows: [(stage: String, p50: Double, p90: Double, count: Int)] = []
    @State private var expanded = false

    var body: some View {
        DisclosureGroup("Latency details", isExpanded: $expanded) {
            if rows.isEmpty {
                Text("No dictations yet.").font(Ink.Font.caption).foregroundStyle(Ink.text2)
            } else {
                Text("Last 50 dictations, milliseconds.").font(Ink.Font.caption).foregroundStyle(Ink.text2)
                ForEach(rows, id: \.stage) { r in
                    HStack {
                        Text(r.stage).font(Ink.Font.mono)
                        Spacer()
                        Text("p50 \(Int(r.p50)) · p90 \(Int(r.p90)) · n=\(r.count)").font(Ink.Font.mono).foregroundStyle(Ink.text2)
                    }
                }
            }
            Button("Reload") { load() }.controlSize(.small)
        }
        .font(Ink.Font.body)
        .onChange(of: expanded) { _, on in if on { load() } }
    }

    private func load() { rows = LatencyStats.compute((try? RunLog.readAll()) ?? []) }
}

/// Read-only view of the newest run: provider metadata and timeline. Never shows transcript text or keys.
struct LastRequestView: View {
    @State private var run: RunRecord?
    @State private var expanded = false

    var body: some View {
        DisclosureGroup("Last request", isExpanded: $expanded) {
            if let r = run {
                Text("\(r.ts) · \(r.model) · \(r.status.rawValue) · \(r.audio.format), \(String(format: "%.1f s", r.audio.durationSec))")
                    .font(Ink.Font.mono).textSelection(.enabled)
                if let e = r.error { Text(Self.displayError(e)).font(Ink.Font.caption).foregroundStyle(Ink.signal).lineLimit(3) }
                if let note = EngineCopy.lastRequestNote(model: r.model) { Text(note).font(Ink.Font.body).foregroundStyle(Ink.text2) }
                block("provider", (r.providerMeta ?? [:]).map { ($0.key, Self.displayValue(key: $0.key, value: $0.value)) })
                block("timeline (ms)", r.timelineMs.map { ($0.key, String(format: "%.0f", $0.value)) })
            } else {
                Text("No dictations yet.").font(Ink.Font.caption).foregroundStyle(Ink.text2)
            }
            Button("Reload") { load() }.controlSize(.small)
        }
        .font(Ink.Font.body)
        .onChange(of: expanded) { _, on in if on { load() } }
    }

    @ViewBuilder private func block(_ title: String, _ items: [(String, String)]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Ink.Font.caption.weight(.medium))
                ForEach(items.sorted { $0.0 < $1.0 }, id: \.0) { k, v in
                    Text("\(k): \(v)").font(Ink.Font.mono).foregroundStyle(Ink.text2).textSelection(.enabled)
                }
            }
        }
    }

    private func load() { run = ((try? RunLog.readAll()) ?? []).last }

    /// Dictated text (`live_text`, `transcript`, `cleanup_rejected`, any `*_text`) shows as its length only, so a
    /// screenshot of this panel never carries what was said (owner D8, 2026-10-25). `*_ms` timings stay numbers.
    nonisolated static func displayValue(key: String, value: String) -> String {
        let isText = key == "transcript" || key == "cleanup_rejected" || key.hasSuffix("_text")
        return isText ? "\(value.count) characters" : value
    }

    /// The error without a provider's response body, which may hold a transcript (same rule as app.log).
    nonisolated static func displayError(_ error: String) -> String { DictationPipeline.logSafe(error) }
}

/// Settings → Pill: a small picture of the screen (menu bar on top, Dock below) with six spots to click.
/// The current spot is filled; a dragged position that matches none shows as a small pill where it sits.
struct PillScreenMap: View {
    let position: PillPosition
    let anchor: PillAnchor?
    let pick: (PillSpot) -> Void
    /// The interface language (spot names for VoiceOver and the tooltip).
    var language: UILanguage = .en

    private let w: CGFloat = 220, h: CGFloat = 138
    private var current: PillSpot? { PillSpot.from(position: position, anchor: anchor) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Ink.well)
            RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Ink.hairline)
            Rectangle().fill(Ink.hairline).frame(width: w, height: 9)                               // menu bar
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 8, topTrailingRadius: 8))
            RoundedRectangle(cornerRadius: 4).fill(Ink.hairline).frame(width: w * 0.5, height: 10)  // Dock
                .offset(x: w * 0.25, y: h - 15)
            ForEach(PillSpot.allCases, id: \.self) { spot in
                let on = spot == current
                Button { pick(spot) } label: {
                    Capsule().fill(on ? Ink.lazur : Ink.text4.opacity(0.35))
                        .frame(width: 34, height: 11)
                        .overlay(Capsule().strokeBorder(on ? Color.clear : Ink.text3.opacity(0.5), lineWidth: 1))
                        .padding(6).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(label(spot)).accessibilityLabel(label(spot)).accessibilityAddTraits(on ? .isSelected : [])
                .offset(x: point(spot).x - 23, y: point(spot).y - 11.5)   // not .position: that makes every spot as big as the map
            }
            if current == nil, let a = anchor {
                Capsule().fill(Ink.lazur).frame(width: 34, height: 11)
                    .offset(x: CGFloat(a.fx) * w - 17, y: (1 - CGFloat(a.fy)) * (h - 30) + 15 - 5.5)
                    .allowsHitTesting(false)
                    .accessibilityLabel(AppStrings.for(language).plOwn)
            }
        }
        .frame(width: w, height: h)
    }

    private func label(_ spot: PillSpot) -> String { AppStrings.for(language).d.spot[spot] ?? spot.label }

    private func point(_ s: PillSpot) -> CGPoint {
        let x = 30 + CGFloat(s.column) * (w - 60)
        return CGPoint(x: x, y: s.isTop ? 22 : h - 30)
    }
}

/// "How do I get a key?" under step 1: the provider's few clicks, in order, and the one thing worth knowing.
struct KeyGuide: View {
    let provider: KeyProvider
    @State private var open = false
    static let fullGuide = URL(string: "https://github.com/ShamsiddinKomil/soyla/blob/main/docs/KEYS.md")!

    var body: some View {
        let g = provider.guide
        VStack(alignment: .leading, spacing: Ink.s2) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { open.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).rotationEffect(.degrees(open ? 90 : 0))
                    Text("How do I get a key?").font(Ink.Font.caption)
                }
                .foregroundStyle(Ink.lazur).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(open ? "Hide how to get a key" : "Show how to get a key")
            if open {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(g.steps.enumerated()), id: \.offset) { i, s in
                        HStack(alignment: .firstTextBaseline, spacing: Ink.s2) {
                            Text("\(i + 1).").font(Ink.Font.caption).foregroundStyle(Ink.text2).monospacedDigit().frame(width: 14, alignment: .trailing)
                            Text(s).font(Ink.Font.caption).foregroundStyle(Ink.text).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if let n = g.note {
                        Text(n).font(Ink.Font.caption).foregroundStyle(Ink.text2).fixedSize(horizontal: false, vertical: true).padding(.top, 2)
                    }
                    Button("Full guide") { NSWorkspace.shared.open(Self.fullGuide) }
                        .buttonStyle(.plain).font(Ink.Font.caption).foregroundStyle(Ink.lazur)
                }
                .padding(Ink.s3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Ink.rControl, style: .continuous).fill(Ink.well))
            }
        }
        .padding(.leading, 32)
    }
}
