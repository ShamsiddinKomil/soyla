import Foundation

// APP-1 (a): what Home and the menu-bar header say, as pure values. Ports the
// approved prototype's `home()` title, hero, `langFix()` and `langRow()` (design prototype v2), plus
// two states the prototype doesn't draw but the app has: Accessibility off, and a hosted engine with no key at all.

/// One answer to "can Soyla dictate right now?" (audit 2026-10-19 V-01, V-11, V-22). Home's rows, the Languages page,
/// Privacy's "Where your voice goes", setup's Done and Try, the menu and the pill all read this one value, so they can't
/// drift apart again. Order matters: a missing permission wins over a missing key.
public enum Readiness: Equatable, Sendable {
    /// The mic or Accessibility is off: nothing works yet, whatever the keys say.
    case blocked(mic: Bool, ax: Bool)
    /// Soyla works except for a key: `combo` = the cloud languages still waiting (nil = no cloud language chosen);
    /// `englishWorks` = English dictates now (false when the engine in use is a hosted service with no key).
    /// `englishWaits` = English is chosen and waits for that key too (D22: the copy then says "Soyla needs an API key").
    case needsKey(CloudCombo?, englishWorks: Bool, englishWaits: Bool = false)
    case ready

    /// `englishChosen`: English is one of the user's languages (flows audit F-06: "English works" is never said to
    /// someone who doesn't speak it).
    public init(micMissing: Bool, axMissing: Bool, englishNeedsKey: Bool, missing: CloudCombo?, englishChosen: Bool = true) {
        if micMissing || axMissing { self = .blocked(mic: micMissing, ax: axMissing) }
        else if englishNeedsKey || missing != nil {
            self = .needsKey(missing, englishWorks: englishChosen && !englishNeedsKey, englishWaits: englishChosen && englishNeedsKey)
        }
        else { self = .ready }
    }

    public var isBlocked: Bool { if case .blocked = self { return true }; return false }
    /// The mic is the thing to fix first (the copy says "Allow the microphone first.").
    public var micFirst: Bool { if case .blocked(let mic, _) = self { return mic }; return false }
    /// English dictates now: no permission missing and no key needed for it.
    public var englishWorks: Bool {
        switch self {
        case .blocked: return false
        case .needsKey(_, let e, _): return e
        case .ready: return true
        }
    }
    /// English is chosen and waits for a key (a hosted engine with none on file).
    public var englishWaits: Bool { if case .needsKey(_, _, let w) = self { return w }; return false }

    /// What a language row shows: while a permission is missing every row waits for it, whatever its key says.
    public func shown(_ s: HomeState.LangStatus) -> HomeState.LangStatus { isBlocked ? .blocked : s }
}

/// Where one chosen language goes and whether it works there (flows audit 2026-10-19, Bigger suggestion 1; F-03, F-04,
/// F-06). Setup's Done rows and Languages captions, its ⓘ, and Home's captions all read this one function.
public struct LanguageRoute: Equatable, Sendable {
    public enum Place: Equatable, Sendable {
        case onMac
        /// Through this Cloud service; nil = not known yet (no key on file) or a custom endpoint.
        case cloud(String?)
    }
    public let language: SpokenLanguage
    public let place: Place
    public let ready: Bool

    /// `engine`: the engine in use (or the one setup will leave). `engineReady`: its key is on file (always true for
    /// On this Mac and a custom endpoint). `keyService`: the service of a key on file, named while On this Mac is on.
    public static func route(_ l: SpokenLanguage, engine: ProviderKind, engineReady: Bool, keyService: String? = nil) -> LanguageRoute {
        let ready = engine == .custom || engineReady
        switch (l, engine) {
        case (.en, .apple): return LanguageRoute(language: l, place: .onMac, ready: true)
        case (_, .apple): return LanguageRoute(language: l, place: .cloud(keyService), ready: false)
        default: return LanguageRoute(language: l, place: .cloud(HomeState.serviceName(engine)), ready: ready)
        }
    }

    /// The chosen languages only, in a stable order (English is listed only if chosen).
    public static func routes(_ chosen: [SpokenLanguage], engine: ProviderKind, engineReady: Bool, keyService: String? = nil) -> [LanguageRoute] {
        SpokenLanguage.allCases.filter(chosen.contains).map { route($0, engine: engine, engineReady: engineReady, keyService: keyService) }
    }
}

public struct HomeState: Equatable, Sendable {
    public enum Title: Equatable, Sendable {
        case micOff
        /// Accessibility is off: the hotkey and typing can't work (not in the prototype, which assumes it).
        case axOff
        /// The engine in use is a hosted service with no key saved, so even English fails (the old Home banner).
        case needsKey
        case oneMore(CloudCombo)
        case ready
    }
    public enum Hero: Equatable, Sendable { case permissions, fnKey }
    /// The one fix in the "Your languages" header. `.addKey` opens the Engine page (no cloud language to connect).
    public enum Action: Equatable, Sendable { case connect(CloudCombo), useCloud, addKey }
    public enum LangStatus: Equatable, Sendable {
        case onMac
        /// Ready through this service; nil = a custom endpoint (shown as plain "Cloud").
        case cloud(String?)
        case needsKey
        /// A key is on file but the engine is "On this Mac".
        case off
        /// Shown only (never in `rows`): the mic or Accessibility is off, so the language can't work yet.
        case blocked
    }
    public struct LangRow: Equatable, Sendable {
        public let language: SpokenLanguage
        public let status: LangStatus
    }

    public let title: Title
    public let hero: Hero
    public let action: Action?
    public let rows: [LangRow]
    /// The hero's Permissions group lists only what is missing.
    public let micMissing: Bool
    public let axMissing: Bool
    /// The launch key read is not ready: the one-time move out of the Keychain waits on (or was refused at) the macOS
    /// password dialog, or the key file is unreadable (D4). Never shown without a cloud key in use (GAPS 7).
    public let keychainNotice: Bool
    /// The shared answer (see `Readiness`). `rows` keep the key/engine status; views draw `shownRows`.
    public let readiness: Readiness

    /// Where each listed language goes (the shared route); Home's captions read it.
    public let routes: [LanguageRoute]
    /// F-06: "English works now." only when English is chosen and really works.
    public var englishWorksNow: Bool { routes.contains { $0.language == .en && $0.ready } && !readiness.isBlocked }

    /// The rows as drawn: every row waits while a permission is missing.
    public var shownRows: [LangRow] { rows.map { LangRow(language: $0.language, status: readiness.shown($0.status)) } }

    /// The header action is the primary button only while nothing more urgent (the mic) is on screen.
    public var actionIsPrimary: Bool { !micMissing }

    /// `hasKey`: a key is saved (what dictation needs). `verified`: it passed the last check (what `CloudNudge` needs).
    public init(mic: PermissionState.Mic, ax: Bool = true, spoken: [SpokenLanguage]?, provider: ProviderKind,
                hasKey: (KeyProvider) -> Bool, verified: (KeyProvider) -> Bool, keychain: Secrets.KeychainAccess) {
        let chosen = Set(spoken ?? [.en])
        let langs = SpokenLanguage.allCases.filter(chosen.contains)
        let ready = keychain == .ready
        let missing = CloudNudge.missing(spoken: langs, provider: provider, verified: verified, keychainReady: ready)
        let hostedVerified = [KeyProvider.google, .openRouter].contains(where: verified)
        let englishNeedsKey = ready && (provider.hostedKey.map { !hasKey($0) } ?? false)
        let service = Self.serviceName(provider)

        micMissing = mic != .granted
        axMissing = !ax
        hero = micMissing || axMissing ? .permissions : .fnKey
        if micMissing { title = .micOff }
        else if axMissing { title = .axOff }
        else if englishNeedsKey { title = .needsKey }
        else if let c = missing { title = .oneMore(c) }
        else { title = .ready }

        if let c = missing { action = provider == .apple && hostedVerified ? .useCloud : .connect(c) }
        else { action = englishNeedsKey ? .addKey : nil }

        rows = (langs.isEmpty ? [.en] : langs).map { l in
            let status: LangStatus
            if l == .en {
                status = provider == .apple ? .onMac : (englishNeedsKey ? .needsKey : .cloud(service))
            } else if provider != .apple && missing == nil {
                status = .cloud(service)
            } else if provider == .apple {
                status = hostedVerified || !ready ? .off : .needsKey
            } else {
                status = .needsKey
            }
            return LangRow(language: l, status: status)
        }
        keychainNotice = !ready && provider.hostedKey != nil
        let waiting: CloudCombo? = missing ?? (englishNeedsKey ? CloudNudge.combo(langs) : nil)
        let listed = langs.isEmpty ? [SpokenLanguage.en] : langs
        readiness = Readiness(micMissing: micMissing, axMissing: axMissing, englishNeedsKey: englishNeedsKey, missing: waiting,
                              englishChosen: listed.contains(.en))
        let keyService = [KeyProvider.google, .openRouter].first(where: hasKey).map { $0 == .google ? SetupProvider.google.displayName : SetupProvider.openRouter.displayName }
        routes = LanguageRoute.routes(listed, engine: provider, engineReady: !englishNeedsKey, keyService: keyService)
    }

    /// The service a language runs through, as the rows name it.
    static func serviceName(_ p: ProviderKind) -> String? {
        switch p {
        case .google: return SetupProvider.google.displayName
        case .openRouter: return SetupProvider.openRouter.displayName
        case .custom, .apple: return nil
        }
    }
}

/// The menu bar's header (status dot, one line, one quieter line) and its one contextual item. Prototype
/// `renderMenu()`; Secure Input keeps its own line below. A skipped key is calm: no badge on the icon.
public struct MenuHeader: Equatable, Sendable {
    public enum Tone: Equatable, Sendable { case ok, warn }
    public enum Item: Equatable, Sendable { case allowMic, allowAccessibility, connect(CloudCombo), useCloud, addKey }

    public let tone: Tone
    public let title: HomeState.Title
    public let item: Item?
    public let secureInput: Bool
    public let badge: Bool
    /// The shared answer the header was built from (V-22: one line per fix).
    public let readiness: Readiness

    public init(home: HomeState, secureInput: Bool) {
        title = home.title
        readiness = home.readiness
        self.secureInput = secureInput
        switch home.title {
        case .micOff: tone = .warn; item = .allowMic
        case .axOff: tone = .warn; item = .allowAccessibility
        case .needsKey, .oneMore:
            tone = .warn
            switch home.action {
            case .connect(let c): item = .connect(c)
            case .useCloud: item = .useCloud
            case .addKey, nil: item = .addKey
            }
        case .ready: tone = .ok; item = nil
        }
        let urgent: Bool = switch home.title { case .micOff, .axOff, .needsKey: true; default: false }
        badge = urgent || secureInput
    }

    /// V-22: "Hotkey not active" only when no permission fix is already in the header (every permission is granted and
    /// the tap still failed); otherwise the header's own item says what to allow.
    public func showsHotkeyOff(hotkeyActive: Bool) -> Bool { !hotkeyActive && !readiness.isBlocked }

    public struct Text: Equatable, Sendable {
        public let title: String
        public let detail: String
        public let item: String?
        public let secure: String?
    }

    /// The words, in the interface language. `key` is the hotkey's short label.
    func text(_ t: AppStrings, key: String) -> Text {
        let detail: String
        switch title {
        case .micOff: detail = t.mMicFirst
        case .axOff: detail = t.mAxFirst
        case .needsKey: detail = t.mKeyFirst
        case .oneMore: detail = readiness.englishWorks ? t.mWorks : t.mKeyFirst
        case .ready: detail = AppStrings.fill(t.mHold, key: key)
        }
        let itemText: String? = item.map {
            switch $0 {
            case .allowMic: return t.mMic
            case .allowAccessibility: return t.mAx
            case .connect(let c): return t.mConnect(c)
            case .useCloud: return t.useCloud
            case .addKey: return t.connect
            }
        }
        return Text(title: t.title(title), detail: detail, item: itemText, secure: secureInput ? t.mSecure : nil)
    }
}

/// Where a menu-bar item leads: a setup step, the "Use Cloud" switch, or a main-window page.
public enum MenuRoute: Equatable, Sendable {
    case setup(SetupStep), useCloud, page(SettingsPage)
    /// v3: the Languages page with the first missing language's Connect panel open.
    case connectInline
}

extension MenuHeader.Item {
    /// Fixes go through setup (mic and Accessibility → Permissions, a key → Connect); "add a key" with no cloud
    /// language to connect opens the Languages page.
    public var route: MenuRoute {
        switch self {
        case .allowMic, .allowAccessibility: return .setup(.permissions)
        case .connect: return .setup(.connect)
        case .useCloud: return .useCloud
        case .addKey: return .page(.languages)
        }
    }
}

/// APP-1 (b): which groups the Languages page shows (prototype `engine()`). One deliberate difference: an English-only
/// user who dictates through Cloud (every v0.2 user) still sees the Cloud group and the engine choice, so the key
/// and the engine stay manageable.
public struct LanguagesPageState: Equatable, Sendable {
    public let home: HomeState
    public let showsCloud: Bool
    public let showsEngineChoice: Bool
    public let showsOnMac: Bool
    public let engineIsCloud: Bool
    /// The model popup belongs to the engine in use (its id is that provider's), so only while Cloud is on.
    public let showsModel: Bool
    /// The one fix in the "Your languages" header; only with a key on file (otherwise Connect… sits in the Cloud group).
    public let headerAction: HomeState.Action?
    public let services: [KeyProvider]

    public init(home: HomeState, spoken: [SpokenLanguage]?, provider: ProviderKind, hasKey: (KeyProvider) -> Bool,
                developerMode: Bool) {
        self.home = home
        let cloudLanguage = (spoken ?? []).contains(where: \.isCloud)
        let anyKey = hasKey(.google) || hasKey(.openRouter)
        engineIsCloud = provider != .apple
        showsCloud = cloudLanguage || engineIsCloud || anyKey
        showsEngineChoice = showsCloud && (anyKey || provider == .custom)
        showsOnMac = provider == .apple
        showsModel = engineIsCloud && provider != .custom
        headerAction = anyKey ? home.action : nil
        services = [.google, .openRouter] + (developerMode || provider == .custom ? [.custom] : [])
    }

    /// The service the Cloud group opens on: the one in use, else the first with a key, else Google (free to start).
    public static func defaultService(provider: ProviderKind, hasKey: (KeyProvider) -> Bool) -> KeyProvider {
        switch provider {
        case .google: return .google
        case .openRouter: return .openRouter
        case .custom: return .custom
        case .apple: return hasKey(.google) ? .google : (hasKey(.openRouter) ? .openRouter : .google)
        }
    }

    /// "Gemini 3.5 Flash-Lite" (the caption says what it trades), not the long History label.
    public static func modelName(_ id: String) -> String {
        ModelNames.name(id).components(separatedBy: " (").first ?? id
    }
}
