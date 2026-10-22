import Foundation

// FE-5: the words and decisions of the Engine page, onboarding, menu bar and History, as pure functions so the copy
// is tested and the views only render it. The free engine is English only (V5).

public enum EngineCopy {
    public static let freeTitle = "On this Mac"
    public static let freeBadge = "Free"
    public static let freeSubtitle = "Free · English only. Your audio never leaves this Mac."
    public static let freePrivacy = "Your audio never leaves this Mac. The only network use is Apple's one-time download of its English speech model."
    public static let cloudTitle = "Cloud"
    public static let cloudSubtitle = "Your key · Uzbek, Russian, English + mixed speech"
    public static let cloudNote = "Needed for Uzbek and Russian. Your audio goes to the provider you pick, with your own key."

    public enum Tone: Equatable, Sendable { case ok, pending, warn, neutral }
    public enum Action: Equatable, Sendable {
        case download, retry, allowSpeech
        public var title: String { title(.en) }
        /// The button's word in the interface language (English as before).
        public func title(_ l: UILanguage) -> String {
            let t = AppStrings.for(l)
            switch self { case .download: return t.d.ecDownload; case .retry: return t.d.ecRetry; case .allowSpeech: return t.pMicB }
        }
    }
    public struct Status: Equatable, Sendable {
        public var text: String
        public var tone: Tone
        public var action: Action?
        /// 0...1 while downloading (drives the progress bar).
        public var progress: Double?
    }

    /// The free card's status line. `failure` = the last reserve/download threw (error class only). `language`: the
    /// interface language (English output is unchanged).
    public static func status(_ state: OnDeviceModelState?, failure: String? = nil, language: UILanguage = .en) -> Status {
        let d = AppStrings.for(language).d
        guard let state else { return Status(text: d.ecChecking, tone: .neutral, action: nil, progress: nil) }
        switch state {
        case .ready:
            return Status(text: d.ecReady, tone: .ok, action: nil, progress: nil)
        case .downloading(let p):
            return Status(text: d.ecDownloading(Int((p * 100).rounded())), tone: .pending, action: nil, progress: p)
        case .needsDownload:
            if failure != nil {
                return Status(text: d.ecDlFailed, tone: .warn, action: .retry, progress: nil)
            }
            return Status(text: d.ecNeedsDl, tone: .warn, action: .download, progress: nil)
        case .needsPermission:
            return Status(text: d.ecNeedsPerm, tone: .warn, action: .allowSpeech, progress: nil)
        case .unavailable(let reason):
            return Status(text: unavailableText(reason, language: language), tone: .warn, action: failure != nil ? .retry : nil, progress: nil)
        }
    }

    static func unavailableText(_ reason: OnDeviceUnavailableReason, language: UILanguage = .en) -> String {
        let d = AppStrings.for(language).d
        switch reason {
        case .localeUnsupported: return d.ecNoLocale
        case .noOnDeviceModel: return d.ecNoModel
        case .restricted: return d.ecRestricted
        case .reservationsFull: return d.ecSlotsFull
        case .osTooOld: return d.ecOsOld
        }
    }

    /// Menu-bar attention line and Home banner text for the free engine; nil when ready or not yet read. Never says
    /// "API key missing" (no key is needed).
    public static func attention(provider: ProviderKind, state: OnDeviceModelState?, language: UILanguage = .en) -> String? {
        guard provider == .apple, let state else { return nil }
        let d = AppStrings.for(language).d
        switch state {
        case .ready: return nil
        case .downloading(let p): return d.atDownloading(Int((p * 100).rounded()))
        case .needsDownload: return d.atNeedsDl
        case .needsPermission: return d.atNeedsPerm
        case .unavailable: return d.atUnavailable
        }
    }

    /// The History engine label: "On this Mac" for a free run (its `model` is a locale such as `en-US`), else the
    /// model's plain name.
    public static func engineLabel(model: String) -> String {
        isOnDevice(model: model) ? freeTitle : ModelNames.name(model)
    }

    /// A run recorded by the free engine stores its locale as the model (`ProviderKind.apple.defaultSTTModel`, R3).
    public static func isOnDevice(model: String) -> Bool {
        let parts = model.split(separator: "-")
        return parts.count == 2 && parts[0].count == 2 && parts[1].count == 2
            && parts[0].allSatisfy { $0.isLowercase && $0.isLetter } && parts[1].allSatisfy { $0.isUppercase && $0.isLetter }
    }

    /// Developer "Last request": the free engine sends nothing anywhere.
    public static func lastRequestNote(model: String) -> String? { isOnDevice(model: model) ? "Nothing left this Mac" : nil }

    /// Which cloud provider the Cloud card switches to: the one that already has a key (Google first, it has a free
    /// tier), else Google.
    public static func cloudTarget(hasKey: (KeyProvider) -> Bool, developerMode: Bool) -> ProviderKind {
        if hasKey(.google) { return .google }
        if hasKey(.openRouter) { return .openRouter }
        if developerMode, hasKey(.custom) { return .custom }
        return .google
    }
}

/// OB-2: Uzbek/Russian were picked in setup but the engine in use has no verified key (the user skipped Connect).
/// Home shows a calm card and the menu bar a line, until a key is verified or those languages are unticked.
/// English only: these lines are not shown by any screen yet (Home and the menu use `AppStrings`).
public enum CloudNudge {
    /// The languages still waiting for a key, or nil. A custom endpoint is trusted (it may need no key); while the
    /// Keychain read is pending nothing counts as missing.
    public static func missing(spoken: [SpokenLanguage]?, provider: ProviderKind, verified: (KeyProvider) -> Bool,
                               keychainReady: Bool) -> CloudCombo? {
        guard keychainReady else { return nil }
        let langs = Set(spoken ?? [])
        let combo: CloudCombo? = switch (langs.contains(.uz), langs.contains(.ru)) {
        case (true, true): .uzru
        case (true, false): .uz
        case (false, true): .ru
        default: nil
        }
        guard let combo, provider != .custom else { return nil }
        if let k = provider.hostedKey, verified(k) { return nil }
        return combo
    }

    static func name(_ c: CloudCombo) -> String {
        switch c { case .uz: "Uzbek"; case .ru: "Russian"; case .uzru: "Uzbek and Russian" }
    }
    public static func homeText(_ c: CloudCombo) -> String {
        "\(name(c)) \(c == .uzru ? "aren't" : "isn't") connected yet · English works now"
    }
    public static func button(_ c: CloudCombo) -> String { "Connect \(name(c))" }
    public static func menuLine(_ c: CloudCombo) -> String { "\(name(c)) \(c == .uzru ? "need" : "needs") an API key" }
}

/// P5: when a key is added while on the free engine, or removed while on Cloud, offer the switch once. Never switches
/// silently; the "asked" flags persist in the settings suite.
public enum EngineSwitchPrompt: Equatable, Sendable {
    case toCloud(KeyProvider)
    case toFree

    /// Which offers were already made (persisted by `EnginePromptFlags`).
    public struct Asked: Equatable, Sendable {
        public var toCloud = false, toFree = false
        public init(toCloud: Bool = false, toFree: Bool = false) { self.toCloud = toCloud; self.toFree = toFree }
    }

    /// F-09: "Switch to On this Mac?" (English only) makes sense only to someone who speaks English.
    public func fits(spoken: [SpokenLanguage]?) -> Bool {
        if case .toFree = self { return (spoken ?? [.en]).contains(.en) }
        return true
    }

    public static func decide(provider: ProviderKind, keyedProviders: [KeyProvider], verified: Set<KeyProvider>,
                              asked: Asked, freeAvailable: Bool) -> EngineSwitchPrompt? {
        if provider == .apple {
            guard !asked.toCloud else { return nil }
            // First verified key (Google first); a custom key has no check, so a saved one counts.
            for k in [KeyProvider.google, .openRouter, .custom] where keyedProviders.contains(k) && (verified.contains(k) || k == .custom) {
                return .toCloud(k)
            }
            return nil
        }
        // On Cloud: the provider in use lost its key and no other key remains.
        guard !asked.toFree, freeAvailable, let used = provider.hostedKey, !keyedProviders.contains(used), keyedProviders.isEmpty else { return nil }
        return .toFree
    }

    public var title: String { title(.en) }
    public var message: String { message(.en) }
    public var confirmTitle: String { confirmTitle(.en) }
    public var declineTitle: String { declineTitle(.en) }

    // The same four lines in the interface language (the alert in Settings).
    public func title(_ l: UILanguage) -> String {
        let d = AppStrings.for(l).d
        switch self { case .toCloud: return d.spToCloudT; case .toFree: return d.spToFreeT }
    }
    public func message(_ l: UILanguage) -> String {
        let d = AppStrings.for(l).d
        switch self { case .toCloud: return d.spToCloudM; case .toFree: return d.spToFreeM }
    }
    public func confirmTitle(_ l: UILanguage) -> String {
        let d = AppStrings.for(l).d
        switch self { case .toCloud: return d.spToCloudB; case .toFree: return d.spToFreeB }
    }
    public func declineTitle(_ l: UILanguage) -> String {
        let d = AppStrings.for(l).d
        switch self { case .toCloud: return d.spStay; case .toFree: return d.spNotNow }
    }
}

/// The "asked once" flags (settings suite, not the Settings blob: bookkeeping, not a user choice).
public struct EnginePromptFlags {
    let defaults: UserDefaults
    static let cloudKey = "engine.askedSwitchToCloud", freeKey = "engine.askedSwitchToFree"
    public init(defaults: UserDefaults = UserDefaults(suiteName: Soyla.defaultsSuite) ?? .standard) { self.defaults = defaults }
    public var askedToCloud: Bool { defaults.bool(forKey: Self.cloudKey) }
    public var askedToFree: Bool { defaults.bool(forKey: Self.freeKey) }
    public var asked: EngineSwitchPrompt.Asked { .init(toCloud: askedToCloud, toFree: askedToFree) }
    public func markAsked(_ p: EngineSwitchPrompt) {
        defaults.set(true, forKey: { if case .toCloud = p { return Self.cloudKey } else { return Self.freeKey } }())
    }
}
