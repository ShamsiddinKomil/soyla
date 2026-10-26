import Foundation

public enum Soyla {
    public static let version = "0.3.0"
    public static let bundleId = "ai.soyla.app"
    /// Where this process keeps its settings and Keychain items. Release (`ai.soyla.app`), the CLI and tests
    /// (any non-Soyla bundle id) keep today's names. A side-by-side variant (`ai.soyla.dev`, `VARIANT=dev
    /// scripts/bundle.sh`) gets its own suite and Keychain service, so first-run testing never touches real data.
    public struct StorageNames: Equatable, Sendable {
        public var defaultsSuite: String
        public var keychainService: String
        public var isRelease: Bool
        /// Folder name under Application Support (logs, recordings).
        public var supportFolder: String
    }
    public static func storageNames(bundleID: String?) -> StorageNames {
        let release = StorageNames(defaultsSuite: "ai.soyla.settings", keychainService: "ai.soyla.app", isRelease: true,
                                   supportFolder: "Soyla")
        guard let id = bundleID, id.hasPrefix("ai.soyla."), id != "ai.soyla.app" else { return release }
        let variant = String(id.dropFirst("ai.soyla.".count))
        guard !variant.isEmpty else { return release }
        return StorageNames(defaultsSuite: "ai.soyla.\(variant).settings", keychainService: "ai.soyla.app.\(variant)",
                            isRelease: false, supportFolder: "Soyla \(variant.capitalized)")
    }
    public static let storage = storageNames(bundleID: Bundle.main.bundleIdentifier)
    /// Every build keeps API keys in a 0600 file, not the Keychain (`KeyFileStore`): Soyla Dev since 2026-10-17,
    /// release, the CLI and tests since D4 (owner, 2026-10-25). The Keychain is only read once, to move old keys.
    public static func usesKeyFile(bundleID _: String?) -> Bool { true }
    /// Must differ from the bundle id: UserDefaults(suiteName: <bundle id>) silently does not persist.
    public static let defaultsSuite = settingsSuite(env: DevOverrides.environment)
    /// `SOYLA_SETTINGS_SUITE` (dev/capture switch, like `SOYLA_KEYCHAIN_SERVICE`) runs the app on separate settings;
    /// otherwise the suite of this build's variant (`storage`).
    static func settingsSuite(env: [String: String], storage: StorageNames = storage) -> String {
        if let s = env["SOYLA_SETTINGS_SUITE"], !s.isEmpty { return s }
        return storage.defaultsSuite
    }
    /// The pre-rename settings are imported once into an empty store, but only into the release store: never into a
    /// side-by-side variant's or a capture/dev store.
    static func legacyImportSuite(env: [String: String], storage: StorageNames = storage) -> String? {
        storage.isRelease && settingsSuite(env: env, storage: storage) == storage.defaultsSuite ? "ai." + "ovoz.settings" : nil
    }
}

/// Where Soyla keeps its data.
/// Default: `~/Library/Application Support/Soyla/` with a flat layout (`runs.jsonl`, `app.log`, `recordings/`,
/// `models_cache.json`). `SOYLA_HOME=/path/to/repo` keeps the old development layout (`logs/…`, `recordings/`,
/// `.env.local` under that path).
public enum SoylaPaths {
    /// Pure resolver (testable): returns the root and whether it uses the dev (repo) layout.
    public static func resolve(env: [String: String], home: URL, supportFolder: String = Soyla.storage.supportFolder) -> (root: URL, devLayout: Bool) {
        if let h = env["SOYLA_HOME"], !h.isEmpty { return (URL(fileURLWithPath: (h as NSString).expandingTildeInPath), true) }
        return (home.appendingPathComponent("Library/Application Support/\(supportFolder)", isDirectory: true), false)
    }
    private static var resolved: (root: URL, devLayout: Bool) {
        resolve(env: DevOverrides.environment, home: FileManager.default.homeDirectoryForCurrentUser)
    }
    public static var root: URL { resolved.root }
    public static var isDevLayout: Bool { resolved.devLayout }
    /// Directory holding runs.jsonl, app.log and models_cache.json.
    public static var logs: URL { isDevLayout ? root.appendingPathComponent("logs") : root }
    public static var runsLog: URL { logs.appendingPathComponent("runs.jsonl") }
    public static var appLog: URL { logs.appendingPathComponent("app.log") }
    public static var recordings: URL { root.appendingPathComponent("recordings") }
    /// Dev-only fallback for keys (see Secrets). Never logged.
    public static var envFile: URL { root.appendingPathComponent(".env.local") }
    /// The API key file (`KeyFileStore`, 0600 in a 0700 folder). Never logged.
    public static var keyFile: URL { keyFile(root: root, devLayout: isDevLayout, isRelease: Soyla.storage.isRelease) }
    /// Release, CLI, tests: `Application Support/Soyla/keys.json`. Soyla Dev keeps its `dev-keys.json` (the folder
    /// already tells the builds apart; renaming would drop the dev keys). `SOYLA_HOME` puts it in `logs/`, which is
    /// gitignored, so a repo checkout can never commit it.
    static func keyFile(root: URL, devLayout: Bool, isRelease: Bool) -> URL {
        (devLayout ? root.appendingPathComponent("logs") : root).appendingPathComponent(isRelease ? "keys.json" : "dev-keys.json")
    }
    public static var modelsCache: URL { logs.appendingPathComponent("models_cache.json") }

    /// Creates root, logs and recordings (0700) if missing. Called once at launch; cheap to repeat.
    /// Existing folders and files are tightened again (0700 / 0600) because creation-time modes don't fix old installs.
    /// The dev layout's root is a source checkout, so only its `logs/` and `recordings/` are tightened.
    public static func ensureDirectories() {
        let fm = FileManager.default
        for dir in [root, logs, recordings] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        tighten(dirs: isDevLayout ? [logs, recordings] : [root, recordings], files: [runsLog, appLog, URL(fileURLWithPath: appLog.path + ".1"), keyFile])
    }

    static func tighten(dirs: [URL], files: [URL]) {
        let fm = FileManager.default
        for d in dirs { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: d.path) }
        for f in files where fm.fileExists(atPath: f.path) { try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: f.path) }
    }

    /// Moves `url` to `url.1` (replacing an older one) once it passes `limit` bytes. Returns true if it rotated.
    @discardableResult
    static func rotateIfLarge(_ url: URL, limit: Int = 1_048_576) -> Bool {
        let fm = FileManager.default
        guard let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil, size > limit else { return false }
        let old = URL(fileURLWithPath: url.path + ".1")
        try? fm.removeItem(at: old)
        return (try? fm.moveItem(at: url, to: old)) != nil
    }
}

public enum HotkeyChoice: String, Codable, CaseIterable, Sendable {
    case fn, rightOption, rightCommand, rightControl, ctrlShiftSpace, f13
    public var label: String {
        switch self {
        case .fn: return "fn (🌐)"
        case .rightOption: return "Right ⌥"
        case .rightCommand: return "Right ⌘"
        case .rightControl: return "Right ⌃"
        case .ctrlShiftSpace: return "⌃⇧Space"
        case .f13: return "F13"
        }
    }
}

/// Which cue set plays on start / done / cancel (B5).
public enum SoundSet: String, Codable, CaseIterable, Sendable {
    /// `soyla` is the default set, "Soft" since 2026-10-19 (warm marimba notes); `classic` keeps the old pure tones.
    case soyla, glass, wood, classic, system, off
    public var label: String {
        switch self {
        case .soyla: "Soft"; case .glass: "Glass"; case .wood: "Wood"; case .classic: "Classic beeps"
        case .system: "macOS sounds"; case .off: "Off"
        }
    }
    /// Folder under Resources/Sounds (nil: the default files at its root, or not bundled).
    public var folder: String? {
        switch self { case .glass, .wood, .classic: rawValue; default: nil }
    }
}

/// What the mic does between dictations (F2). Pre-roll only exists when the engine is warm.
public enum MicWarmMode: String, Codable, CaseIterable, Sendable {
    /// Mic (and the macOS indicator) on only while the hotkey is held. Default.
    case off
    /// Stays on for 30 s after a dictation, then closes (quick follow-ups get instant capture + pre-roll).
    case idleClose30s
    /// Always on while Soyla runs: instant capture + pre-roll, indicator always on.
    case always

    public var label: String {
        switch self {
        case .off: return "Off between dictations"
        case .idleClose30s: return "On for 30 s after a dictation"
        case .always: return "Always on"
        }
    }

    /// Tolerant: an unknown raw value from a newer build falls back to .off (privacy-safe).
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = MicWarmMode(rawValue: raw) ?? .off
    }
}

/// Which API a dictation goes to. The model id is always plain; the provider decides the route
/// (OpenRouter: chat/completions for chat models, /audio/transcriptions for dedicated STT models;
/// Google: generateContent; custom: an OpenAI-compatible server at `Settings.customBaseURL`, chat route).
public enum ProviderKind: String, Codable, CaseIterable, Sendable {
    case openRouter, google, custom
    /// The free on-device engine (Apple Speech). No key, no network. English only in v0.3.0 (V5).
    case apple

    public var label: String {
        switch self {
        case .openRouter: return "OpenRouter"
        case .google: return "Google AI Studio"
        case .custom: return "Custom (OpenAI-compatible)"
        case .apple: return "On this Mac"
        }
    }

    /// The key a hosted provider needs before it can work; nil for `.custom` (key optional) and `.apple` (none).
    /// The attention line and the Home banner use this instead of hard-coding "needs key unless custom" (S2).
    public var hostedKey: KeyProvider? {
        switch self {
        case .openRouter: return .openRouter
        case .google: return .google
        case .custom, .apple: return nil
        }
    }

    /// Prompted Gemini chat model — the only route that keeps Uzbek↔Russian switches (PLAN §13).
    public var defaultSTTModel: String {
        switch self {
        case .openRouter, .custom: return "google/gemini-3.5-flash"
        case .google: return "gemini-3.5-flash"
        // Display only (History); the locale lives in `Settings.onDeviceLocale` and nothing reads this back (R3).
        case .apple: return OnDeviceLocale.fallback
        }
    }

    /// `.apple` has no cleanup model (the free path has no correction pass).
    public var defaultCleanupModel: String { self == .apple ? "" : defaultSTTModel }

    /// Best guess for blobs saved before `provider` existed: a bare "gemini-…" id is Google direct, anything else
    /// ("vendor/model", legacy "chat:vendor/model") was OpenRouter.
    public static func inferred(fromModel model: String) -> ProviderKind {
        let m = OpenRouterSTTProvider.plainModel(model)
        return m.hasPrefix("gemini-") ? .google : .openRouter
    }
}

/// OB-2: the language of Soyla's own words (onboarding for now; the rest of the app stays English this round).
public enum UILanguage: String, Codable, CaseIterable, Sendable {
    case en, uz, ru

    /// The first of the Mac's preferred languages Soyla speaks ("uz-Latn-UZ" and "uz-Cyrl" → uz), else English.
    public static func from(preferredLanguages: [String]) -> UILanguage {
        for raw in preferredLanguages {
            let code = raw.replacingOccurrences(of: "_", with: "-").split(separator: "-").first.map { $0.lowercased() } ?? ""
            if let l = UILanguage(rawValue: code) { return l }
        }
        return .en
    }

    /// Its own name, as the globe menu lists it.
    public var nativeName: String {
        switch self { case .en: return "English"; case .uz: return "O\u{2018}zbekcha"; case .ru: return "Русский" }
    }
}

/// OB-2: what the user speaks (the setup's Languages step). English runs on the Mac; Uzbek and Russian need a key.
public enum SpokenLanguage: String, Codable, CaseIterable, Sendable {
    case en, uz, ru
    public init(_ ui: UILanguage) {
        switch ui { case .en: self = .en; case .uz: self = .uz; case .ru: self = .ru }
    }
    public var isCloud: Bool { self != .en }
}

/// The free engine's language (V5: English only). Pure functions, so the defaults are testable.
public enum OnDeviceLocale {
    public static let fallback = "en-US"
    /// English variants DictationTranscriber supports (FE-0).
    public static let supported = ["en-AU", "en-CA", "en-GB", "en-IE", "en-IN", "en-NZ", "en-SG", "en-US", "en-ZA"]

    /// The first English variant among the user's preferred languages that the engine supports, else en-US.
    /// A bare "en" or an unsupported English variant (en-PH) gives en-US; "ru-RU", "uz" give en-US too.
    public static func `default`(preferredLanguages: [String]) -> String {
        for raw in preferredLanguages {
            let parts = raw.replacingOccurrences(of: "_", with: "-").split(separator: "-").map(String.init)
            guard parts.first?.lowercased() == "en" else { continue }
            // Tags can carry a script ("en-Latn-GB"); match on the 2-letter region.
            if let region = parts.dropFirst().first(where: { $0.count == 2 && $0.allSatisfy(\.isLetter) }),
               supported.contains("en-" + region.uppercased()) {
                return "en-" + region.uppercased()
            }
        }
        return fallback
    }

    /// FE-1's placeholder, kept for its test. The shared store now uses `freshInstallAvailable()` (FE-3).
    public static func assumedAvailable(osMajorVersion: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion) -> Bool {
        osMajorVersion >= 14
    }

    /// FE-3: the real P1 answer (see `OnDeviceAvailability.freshInstallAvailable`): macOS 26+ → true (the async
    /// supported-locales list can't be read synchronously; FE-0 found all English variants supported); macOS 14–15 →
    /// the legacy recogniser has on-device English for the default locale.
    public static func freshInstallAvailable(osMajorVersion: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
                                             preferredLanguages: [String] = Locale.preferredLanguages) -> Bool {
        OnDeviceAvailability.freshInstallAvailable(osMajor: osMajorVersion) {
            OnDeviceProbe.legacyOnDevice(locale: Self.default(preferredLanguages: preferredLanguages))
        }
    }
}

/// How long recordings stay in `recordings/` (D12). Transcripts in History are kept regardless.
public enum AudioRetention: String, Codable, CaseIterable, Sendable {
    /// Forever.
    case keep
    /// Deleted once the run succeeded (a failed run keeps its audio for Retry; the sweep removes leftovers after 14 days).
    case deleteAfterRun
    case deleteAfter7Days
    /// Default (D12).
    case deleteAfter14Days
    /// Recorded to `recordings/.tmp/` and deleted after the request (kept only while a failed run awaits Retry).
    case neverStore

    public var label: String {
        switch self {
        case .keep: return "Forever"
        case .deleteAfterRun: return "Delete after each successful run"
        case .deleteAfter7Days: return "7 days"
        case .deleteAfter14Days: return "14 days"
        case .neverStore: return "Never store"
        }
    }

    /// Age in days after which the sweep deletes a recording; nil = never.
    public var maxAgeDays: Double? {
        switch self {
        case .keep: return nil
        case .deleteAfter7Days: return 7
        case .deleteAfter14Days, .deleteAfterRun: return 14
        case .neverStore: return 0
        }
    }

    /// Tolerant: an unknown raw value from a newer build falls back to the D12 default.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AudioRetention(rawValue: raw) ?? .deleteAfter14Days
    }
}

/// Everything the user can change. Persisted as one JSON blob in UserDefaults (suite `Soyla.defaultsSuite`, normally ai.soyla.settings).
public struct Settings: Codable, Sendable, Equatable {
    /// Where transcription (and the correction pass) goes. Keys: OpenRouter → OPENROUTER_API_KEY, Google → GEMINI_API_KEY.
    public var provider: ProviderKind = .openRouter
    /// Base URL for `.custom`, e.g. "http://localhost:8080/v1" (POST {base}/chat/completions).
    public var customBaseURL: String? = nil
    /// Plain model id for `provider` (e.g. "google/gemini-3.5-flash" on OpenRouter, "gemini-3.5-flash" on Google).
    /// The legacy "chat:" prefix is stripped by `Settings.migrate`.
    public var sttModel: String = ProviderKind.openRouter.defaultSTTModel
    /// FLAC: lossless and ~40% smaller than WAV, so the upload is 0.3–0.8 s faster (latency step 2, 2026-10-16).
    public var audioFormat: AudioFormatChoice = .flac
    /// What actually gets uploaded. A custom endpoint may not accept FLAC, and the picker is Developer-only, so the FLAC
    /// default falls back to WAV there; any other explicit choice is sent as chosen. The on-device engine always gets
    /// WAV: it strips the header to recover PCM16 (R2), and skips the FLAC encode.
    public var uploadFormat: AudioFormatChoice {
        if provider == .apple { return .wav }
        return provider == .custom && audioFormat == .flac ? .wav : audioFormat
    }
    /// The optional primary language ("Mainly speak"); nil = no primary. D26(b): the set is `languages`.
    public var languageHint: String? = nil
    /// D26(b): "my languages", the only languages the speaker uses (cloud). Never empty; see `LanguageSet`.
    public var languages: [String] = LanguageSet.defaultSet
    /// Free-engine language (R3: the only place it lives). Written by the on-device UI only, never by cloud code;
    /// the free path never writes `languageHint`.
    public var onDeviceLocale: String = OnDeviceLocale.default(preferredLanguages: Locale.preferredLanguages)
    /// Kept in sync with `cleanupLevel` (enabled ⇔ level != .off); older builds and A6 still read this one.
    public var cleanupEnabled: Bool = false {
        didSet { if cleanupEnabled != (cleanupLevel != .off) { cleanupLevel = cleanupEnabled ? .light : .off } }
    }
    /// Off (default, owner 2026-10-16; was D14 Light) / Light. Setting it updates `cleanupEnabled`. A saved choice is kept.
    public var cleanupLevel: CleanupLevel = .off {
        didSet { if cleanupEnabled != (cleanupLevel != .off) { cleanupEnabled = cleanupLevel != .off } }
    }
    public var cleanupModel: String = "google/gemini-3.5-flash"
    public var vocabulary: [String] = []
    /// Deterministic whole-word replacements applied to every pasted text, cleanup on or off (≤ 50 used).
    public var dictionary: [DictionaryEntry] = []
    public var hotkey: HotkeyChoice = .fn
    public var prewarmConnection: Bool = true
    public var retention: AudioRetention = .deleteAfter14Days
    public var phraseId: Int? = nil                   // tag for the NEXT run; nil = free
    /// 5 minutes (owner, 2026-10-17): pieces keep every request short. Without pieces the pipeline still caps a
    /// recording at 45/55 s (`DictationPipeline.recordingLimits`), under the 60 s server timeout.
    public var warnAtSec: Double = 285
    public var hardStopSec: Double = 300
    public var minDurationSec: Double = 0.6
    /// Below this much voiced audio (20 ms frames over the speech threshold) a run is an accidental touch: dropped, nothing sent.
    public var minVoicedMs: Double = 250
    public var pasteEnabled: Bool = true
    /// Keep AVAudioEngine running between dictations (instant capture + 300 ms pre-roll, mic indicator on).
    /// Replaces the old `keepMicWarm: Bool` (false → .off, true → .always).
    public var micWarmMode: MicWarmMode = .off
    /// Record from the built-in mic even when a headset (AirPods) is the system default input.
    /// On for new installs (owner, 2026-10-16: AirPods held by an iPhone delivered silence); a saved file without
    /// the field decodes as off, so existing users keep what they had.
    public var preferBuiltInMic: Bool = true
    /// UI cues on start / done / cancel: Soyla's bundled tones, macOS system sounds, or silence. Never on errors.
    public var soundSet: SoundSet = .soyla
    /// Cue loudness, 0…1, on top of each cue's own level (owner found the old cues piercing, 2026-10-19).
    public var soundVolume: Double = 0.6
    /// Legacy Bool, derived from `soundSet` (false = off). Not stored; old blobs migrate through `LegacyKeys.sounds`.
    public var sounds: Bool {
        get { soundSet != .off }
        set { soundSet = newValue ? (soundSet == .off ? .soyla : soundSet) : .off }
    }
    /// Stream audio to Gemini Live while recording and show its interim text in the pill (preview only; paste uses sttModel).
    public var livePreview: Bool = false
    /// Transcribe the recording in pieces while fn is held. On by default (owner, 2026-10-17).
    public var streamSegments: Bool = true
    /// Paste Google Live's text when it is safe: about 0.5 s instead of ~2 s (perf tests 2026-10-26). Owner, 2026-10-26:
    /// on by default only when Google AI Studio is the chosen engine (audio goes only to the provider you picked); any
    /// engine can turn it on by hand. nil = that default; stored as `liveFast`, so settings saved under the old
    /// off-by-default `liveFastPath` key pick up the new default once. `makeLiveRace` also needs the Google key.
    public var liveFast: Bool?
    public var liveFastPath: Bool {
        get { liveFast ?? (provider == .google) }
        set { liveFast = newValue }
    }
    /// Show the transcript, timing and cost in the pill after each run (off = minimal pill: recording animation only).
    public var showDetails: Bool = false
    /// Daily GET to the GitHub releases API (nothing else sent). Launch-at-login is not stored: SMAppService is the source of truth.
    public var autoUpdateCheck: Bool = true
    /// Install a found update by itself (when no dictation runs) and restart. Off by default (owner, 2026-10-16).
    public var autoInstallUpdates: Bool = false
    public var lastUpdateCheck: Date? = nil
    /// Pill placement: a preset, or `custom` = the last drag (`pillAnchor`, fractions of the screen's visible frame).
    public var pillPosition: PillPosition = .bottomCenter
    public var pillAnchor: PillAnchor? = nil
    /// Pill → right-click → "Hide for 1 hour": seconds since 1970 until which the pill stays hidden (failures still show).
    public var pillSnoozedUntil: Double? = nil
    /// First-run Setup Assistant finished (A4). A fresh install starts false; any blob saved before A4 decodes as
    /// true (that Mac was already set up), so existing users don't get the assistant again.
    public var onboardingDone: Bool = false
    /// Developer mode: lab-only UI (History timing columns, phrase tag, Compare tab). Off for users.
    public var developerMode: Bool = false
    /// OB-2: interface language for Soyla's own words (onboarding only for now). Default: the Mac's languages.
    public var uiLanguage: UILanguage = UILanguage.from(preferredLanguages: Locale.preferredLanguages)
    /// OB-2: the languages chosen in setup, so a Setup Assistant rerun starts from them. nil = never chosen.
    public var spokenLanguages: [SpokenLanguage]? = nil

    public init() {}

    /// P1: settings for an install with no saved blob. On-device when available, else the cloud default.
    public static func freshInstall(onDeviceAvailable: Bool, preferredLanguages: [String] = Locale.preferredLanguages) -> Settings {
        var s = Settings()
        s.onDeviceLocale = OnDeviceLocale.default(preferredLanguages: preferredLanguages)
        if onDeviceAvailable {
            s.provider = .apple
            s.sttModel = s.onDeviceLocale     // display only (R3)
            s.cleanupModel = ProviderKind.apple.defaultCleanupModel
        }
        return s
    }

    /// True when the chosen provider needs a key that is not stored. `.custom` and `.apple` never do.
    public func keyMissing(hasKey: (KeyProvider) -> Bool) -> Bool {
        guard let k = provider.hostedKey else { return false }
        return !hasKey(k)
    }

    /// Tolerant decoding: a blob saved by an older build (missing newer keys) keeps its values instead of resetting everything.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        sttModel = try c.decodeIfPresent(String.self, forKey: .sttModel) ?? d.sttModel
        // Tolerant: an unknown provider string (newer build) falls back to inference instead of failing the whole blob.
        provider = ((try? c.decodeIfPresent(ProviderKind.self, forKey: .provider)) ?? nil) ?? ProviderKind.inferred(fromModel: sttModel)
        customBaseURL = try c.decodeIfPresent(String.self, forKey: .customBaseURL)
        audioFormat = ((try? c.decodeIfPresent(AudioFormatChoice.self, forKey: .audioFormat)) ?? nil) ?? d.audioFormat
        languageHint = try c.decodeIfPresent(String.self, forKey: .languageHint)
        languages = LanguageSet.sanitize((try? c.decodeIfPresent([String].self, forKey: .languages)) ?? nil)   // pre-D26b: default set
        onDeviceLocale = ((try? c.decodeIfPresent(String.self, forKey: .onDeviceLocale)) ?? nil) ?? d.onDeviceLocale
        // F3: the level wins when present; a pre-F3 blob derives it from the Bool. didSet does not run in init.
        let enabled = (try? c.decodeIfPresent(Bool.self, forKey: .cleanupEnabled)) ?? nil
        let level = (try? c.decodeIfPresent(CleanupLevel.self, forKey: .cleanupLevel)) ?? nil
        cleanupLevel = level ?? enabled.map { $0 ? CleanupLevel.light : .off } ?? d.cleanupLevel
        cleanupEnabled = cleanupLevel != .off
        cleanupModel = try c.decodeIfPresent(String.self, forKey: .cleanupModel) ?? d.cleanupModel
        vocabulary = try c.decodeIfPresent([String].self, forKey: .vocabulary) ?? d.vocabulary
        dictionary = (try? c.decodeIfPresent([DictionaryEntry].self, forKey: .dictionary)) ?? d.dictionary
        hotkey = ((try? c.decodeIfPresent(HotkeyChoice.self, forKey: .hotkey)) ?? nil) ?? d.hotkey
        prewarmConnection = try c.decodeIfPresent(Bool.self, forKey: .prewarmConnection) ?? d.prewarmConnection
        retention = ((try? c.decodeIfPresent(AudioRetention.self, forKey: .retention)) ?? nil) ?? d.retention
        phraseId = try c.decodeIfPresent(Int.self, forKey: .phraseId)
        warnAtSec = try c.decodeIfPresent(Double.self, forKey: .warnAtSec) ?? d.warnAtSec
        hardStopSec = try c.decodeIfPresent(Double.self, forKey: .hardStopSec) ?? d.hardStopSec
        minDurationSec = try c.decodeIfPresent(Double.self, forKey: .minDurationSec) ?? d.minDurationSec
        pasteEnabled = try c.decodeIfPresent(Bool.self, forKey: .pasteEnabled) ?? d.pasteEnabled
        if let m = try? c.decodeIfPresent(MicWarmMode.self, forKey: .micWarmMode) {
            micWarmMode = m
        } else {
            // Blob from before F2: migrate the Bool.
            let legacy = try decoder.container(keyedBy: LegacyKeys.self)
            let warm = (try? legacy.decodeIfPresent(Bool.self, forKey: .keepMicWarm)) ?? nil
            micWarmMode = warm == true ? .always : d.micWarmMode
        }
        preferBuiltInMic = ((try? c.decodeIfPresent(Bool.self, forKey: .preferBuiltInMic)) ?? nil) ?? false
        if let set = try? c.decodeIfPresent(SoundSet.self, forKey: .soundSet) {
            soundSet = set
        } else {
            // Blob from before B5: migrate the Bool (false → off, true/missing → soyla).
            let legacy = try decoder.container(keyedBy: LegacyKeys.self)
            let on = (try? legacy.decodeIfPresent(Bool.self, forKey: .sounds)) ?? nil
            soundSet = on == false ? .off : d.soundSet
        }
        soundVolume = min(1, max(0, ((try? c.decodeIfPresent(Double.self, forKey: .soundVolume)) ?? nil) ?? d.soundVolume))
        livePreview = try c.decodeIfPresent(Bool.self, forKey: .livePreview) ?? d.livePreview
        streamSegments = try c.decodeIfPresent(Bool.self, forKey: .streamSegments) ?? d.streamSegments
        liveFast = try c.decodeIfPresent(Bool.self, forKey: .liveFast)
        minVoicedMs = try c.decodeIfPresent(Double.self, forKey: .minVoicedMs) ?? d.minVoicedMs
        showDetails = try c.decodeIfPresent(Bool.self, forKey: .showDetails) ?? d.showDetails
        autoUpdateCheck = try c.decodeIfPresent(Bool.self, forKey: .autoUpdateCheck) ?? d.autoUpdateCheck
        lastUpdateCheck = try c.decodeIfPresent(Date.self, forKey: .lastUpdateCheck)
        autoInstallUpdates = try c.decodeIfPresent(Bool.self, forKey: .autoInstallUpdates) ?? d.autoInstallUpdates
        // try?: an unknown preset written by a newer build falls back to the default instead of resetting everything.
        pillPosition = (try? c.decodeIfPresent(PillPosition.self, forKey: .pillPosition)) ?? d.pillPosition
        pillAnchor = (try? c.decodeIfPresent(PillAnchor.self, forKey: .pillAnchor)) ?? nil
        pillSnoozedUntil = (try? c.decodeIfPresent(Double.self, forKey: .pillSnoozedUntil)) ?? nil
        onboardingDone = (try? c.decodeIfPresent(Bool.self, forKey: .onboardingDone)) ?? true
        developerMode = ((try? c.decodeIfPresent(Bool.self, forKey: .developerMode)) ?? nil) ?? d.developerMode
        uiLanguage = ((try? c.decodeIfPresent(UILanguage.self, forKey: .uiLanguage)) ?? nil) ?? d.uiLanguage; spokenLanguages = (try? c.decodeIfPresent([SpokenLanguage].self, forKey: .spokenLanguages)) ?? nil
    }

    private enum LegacyKeys: String, CodingKey { case keepMicWarm, sounds }

    /// v0.2 migration (idempotent, safe on every load): drop the user-visible "chat:" route prefix — the provider
    /// now picks the route from the plain id. Returns true when something changed (caller persists).
    @discardableResult
    public static func migrate(_ s: inout Settings) -> Bool {
        let plain = OpenRouterSTTProvider.plainModel(s.sttModel)
        guard plain != s.sttModel else { return false }
        s.sttModel = plain
        return true
    }
}

// SAFETY (unchecked Sendable): `cached` is only touched under `lock`. Not checkable because UserDefaults (documented
// thread-safe) has its Sendable conformance marked unavailable, and `update` runs a caller's closure under the lock.
public final class SettingsStore: @unchecked Sendable {
    public static let shared = SettingsStore(legacySuite: Soyla.legacyImportSuite(env: DevOverrides.environment),
                                             freshInstallOnDevice: OnDeviceLocale.freshInstallAvailable())
    /// Posted (object: the store) after every `update`, so other writers' changes reach SettingsModel and the pill.
    public static let didChange = Notification.Name("ai.soyla.settingsDidChange")
    private let defaults: UserDefaults
    private let key = "settings.v1"
    private let lock = NSLock()
    private var cached: Settings

    /// `legacySuite`: one-time import source (only the shared store passes it, so test stores stay hermetic —
    /// before A4 every "fresh" test store silently imported the owner's real Ovoz blob).
    ///
    /// `freshInstallOnDevice`: P1 — a store with no saved blob starts on `.apple` when true. Defaults to false so test
    /// stores stay hermetic (`SettingsStore(defaults:) == Settings()`); the shared store passes the real answer.
    /// An autoclosure, so the probe (a Speech read on macOS 14–15) runs only when there is no saved blob.
    public init(defaults: UserDefaults = UserDefaults(suiteName: Soyla.defaultsSuite) ?? .standard, legacySuite: String? = nil,
                freshInstallOnDevice: @autoclosure () -> Bool = false, preferredLanguages: [String] = Locale.preferredLanguages) {
        self.defaults = defaults
        // One-time import from the app's previous name (Ovoz, suite "ai.ovoz.settings"), 2026-10-15 rename.
        if defaults.data(forKey: key) == nil, let legacySuite, let old = UserDefaults(suiteName: legacySuite) {
            for k in ["settings.v1", "firstLaunchShown", "migrated.chatRoute", "migrated.cleanupFlash", "migrated.minimalPill", "migrated.coldMic"] {
                if let v = old.object(forKey: k) { defaults.set(v, forKey: k) }
            }
        }
        let blob = defaults.data(forKey: key)
        if let blob, let s = try? JSONDecoder().decode(Settings.self, from: blob) {
            cached = s
        } else if blob == nil {
            cached = Settings.freshInstall(onDeviceAvailable: freshInstallOnDevice(), preferredLanguages: preferredLanguages)
        } else {
            cached = Settings()
        }
        if !defaults.bool(forKey: Self.migrationKey) {
            Self.migrateV02(&cached, blob: blob, defaults: defaults)
            if let data = try? JSONEncoder().encode(cached) { defaults.set(data, forKey: key) }
            defaults.set(true, forKey: Self.migrationKey)
            for k in Self.legacyFlags { defaults.removeObject(forKey: k) }
        } else if Settings.migrate(&cached), let data = try? JSONEncoder().encode(cached) {
            // Cheap safety net: a "chat:" id written by a stale writer after the migration ran.
            defaults.set(data, forKey: key)
        }
        if Self.migrateFlacUpload(&cached, defaults: defaults), let data = try? JSONEncoder().encode(cached) {
            defaults.set(data, forKey: key)
        }
        if Self.migratePieces(&cached, defaults: defaults), let data = try? JSONEncoder().encode(cached) {
            defaults.set(data, forKey: key)
        }
    }

    /// The single one-off migration key. Bumped only for a breaking schema change; additive fields rely on
    /// `Settings.init(from:)` (`decodeIfPresent ?? default`) instead.
    static let migrationKey = "migrated.v02"
    /// One-off WAV → FLAC upload switch (latency step 2). Separate from `migrated.v02`: it is not a schema change.
    static let flacMigrationKey = "migrated.flacUpload"
    /// Pre-v0.2 one-off flags (owner installs only). Collapsed into `migrated.v02`, then deleted.
    static let legacyFlags = ["migrated.chatRoute", "migrated.cleanupFlash", "migrated.minimalPill", "migrated.coldMic"]

    /// v0.1 -> v0.2, run once. Rules:
    /// - sttModel: strip the legacy "chat:" prefix ONLY. A "...-transcribe" model is NOT swapped to Flash here (the old
    ///   `migrated.chatRoute` swap was an owner-only decision; a stranger who chose transcribe keeps it).
    /// - provider: when the blob had no `provider` key, infer it from the model id (`ProviderKind.inferred`).
    /// - the former one-offs (mic off, minimal pill, cleanup Flash) apply only if their old flag is NOT already set:
    ///   the owner's install has them set (already applied, user may have changed since); a v0.1 blob without flags
    ///   gets them once. All other user values are kept.
    static func migrateV02(_ s: inout Settings, blob: Data?, defaults: UserDefaults) {
        let hadProvider = (blob.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })?["provider"] != nil
        let rawModel = s.sttModel
        Settings.migrate(&s)
        if !hadProvider && blob != nil { s.provider = ProviderKind.inferred(fromModel: rawModel) }
        if !defaults.bool(forKey: "migrated.cleanupFlash"), s.cleanupModel == "google/gemini-3.5-flash-lite" {
            s.cleanupModel = Settings().cleanupModel
        }
        if !defaults.bool(forKey: "migrated.minimalPill") {
            s.livePreview = false
            if s.minDurationSec < 0.6 { s.minDurationSec = 0.6 }
        }
        if !defaults.bool(forKey: "migrated.coldMic") { s.micWarmMode = .off }
    }

    static let piecesMigrationKey = "migrated.piecesDefault"

    /// One-off (owner, 2026-10-17): pieces on, and the old 45/55 s limits (only if unchanged) become 285/300 s.
    /// Runs once; a later "off" or custom limit is kept. Returns true if it changed `s`.
    static func migratePieces(_ s: inout Settings, defaults: UserDefaults) -> Bool {
        guard !defaults.bool(forKey: piecesMigrationKey) else { return false }
        defaults.set(true, forKey: piecesMigrationKey)
        let before = s
        s.streamSegments = true
        if s.warnAtSec == 45, s.hardStopSec == 55 { s.warnAtSec = 285; s.hardStopSec = 300 }
        return s.streamSegments != before.streamSegments || s.hardStopSec != before.hardStopSec
    }

    /// One-off (owner, 2026-10-16): the old WAV default becomes FLAC for Google and OpenRouter. A custom endpoint may
    /// not accept FLAC, so it keeps WAV. Runs once; a later deliberate WAV choice is kept. Returns true if it changed `s`.
    static func migrateFlacUpload(_ s: inout Settings, defaults: UserDefaults) -> Bool {
        guard !defaults.bool(forKey: flacMigrationKey) else { return false }
        defaults.set(true, forKey: flacMigrationKey)
        guard s.audioFormat == .wav, s.provider != .custom else { return false }
        s.audioFormat = .flac
        return true
    }

    public var current: Settings { lock.lock(); defer { lock.unlock() }; return cached }

    public func update(_ f: (inout Settings) -> Void) {
        lock.lock()
        f(&cached)
        if let data = try? JSONEncoder().encode(cached) { defaults.set(data, forKey: key) }
        lock.unlock()
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }
}
