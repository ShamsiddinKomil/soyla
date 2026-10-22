import Foundation

// APP-1 v3 (owner 2026-10-18): the API key is connected inline, in a panel under the language that needs it, on
// Home and the Languages page (prototype-v3 `langRow`, `cxPanel`, `cxConnect`). Pure state and copy; the view and
// `InlineConnectModel` render it and run the real save + check (the same APIKeysModel path as setup's Connect).

/// A language row's own fix (prototype-v3 `langRow`).
public enum RowAction: Equatable, Sendable {
    /// Filled only on the first row still missing a key (and on Home only while the mic is allowed).
    case connect(primary: Bool)
    /// A key is on file but the engine is "On this Mac".
    case useCloud
}

extension HomeState {
    /// The first language whose row needs a key (where routed Connects open the panel).
    public var firstMissing: SpokenLanguage? { rows.first { $0.status == .needsKey }?.language }

    /// `primaryAllowed`: the page may fill one button (Home: only while the mic is allowed). An open panel hides its
    /// row's button and leaves the others bordered.
    public func rowAction(_ l: SpokenLanguage, primaryAllowed: Bool, open: InlineConnect.Target?) -> RowAction? {
        guard let row = rows.first(where: { $0.language == l }) else { return nil }
        switch row.status {
        case .needsKey:
            if open == .language(l) { return nil }
            return .connect(primary: primaryAllowed && open == nil && l == firstMissing)
        case .off:
            return action == .useCloud ? .useCloud : nil
        case .onMac, .cloud, .blocked:
            return nil
        }
    }
}

/// The inline Connect panel: which row it hangs under, the service, the draft key, and the check's state.
public struct InlineConnect: Equatable, Sendable {
    /// Under a language row, or under the Languages page's API key row (Replace…).
    public enum Target: Equatable, Sendable { case language(SpokenLanguage), key }
    public enum State: Equatable, Sendable { case idle, checking, failed(SetupKeyFailure) }
    public enum Verdict: Equatable, Sendable { case ok, failed(SetupKeyFailure) }

    public private(set) var target: Target?
    public private(set) var provider: SetupProvider = .google
    public private(set) var draft = ""
    public private(set) var state: State = .idle

    public init() {}

    /// One panel at a time: opening another replaces it with a fresh draft.
    public mutating func open(_ t: Target, provider p: SetupProvider) {
        target = t; provider = p; draft = ""; state = .idle
    }

    public mutating func close() { target = nil; draft = ""; state = .idle }

    public mutating func setProvider(_ p: SetupProvider) {
        guard state != .checking else { return }
        provider = p
        if case .failed = state { state = .idle }
    }

    /// A real change clears a failure; the field writing back the same text (focus, selection) does not.
    public mutating func edit(_ s: String) {
        guard state != .checking, s != draft else { return }
        draft = s
        if case .failed = state { state = .idle }
    }

    /// The prototype's rule: more than 8 characters, and not while a check runs.
    public var canSubmit: Bool { trimmed.count > 8 && state != .checking }
    private var trimmed: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The key to save and check, or nil (too short, busy, or the wrong shape for this service: nothing is saved).
    public mutating func submit() -> String? {
        guard canSubmit else { return nil }
        let v = trimmed
        if let f = SetupFlow.shapeFailure(v, for: provider) { state = .failed(f); return nil }
        state = .checking
        return v
    }

    /// `--preview` only: the checking state without a shape check (nothing is saved).
    mutating func forceChecking() { state = .checking }

    public mutating func checked(_ v: Verdict) {
        switch v {
        case .ok: close()
        case .failed(let f): state = .failed(f)
        }
    }

    /// "That key didn't work…" for a refused key; setup's own, more specific line for the rest (offline, wrong service…).
    static func message(_ f: SetupKeyFailure, _ t: AppStrings, _ s: SetupStrings) -> String {
        f == .rejected ? t.cxFail : (s.keyFail[f] ?? t.cxFail)
    }

    /// The lock line: where the audio goes, and that one key covers both cloud languages.
    static func footnote(_ t: AppStrings, provider: SetupProvider, combo: CloudCombo?, target: Target) -> String {
        let both = combo == .uzru && target != .key
        return t.cxPriv(provider.displayName) + (both ? " " + t.cxBoth : "")
    }

    /// As setup's Connect: a verified key for a chosen cloud language makes that provider the engine; otherwise the
    /// engine stays (the P5 offer asks, nothing switches by itself).
    public static func engine(after p: SetupProvider, spoken: [SpokenLanguage]?, current: ProviderKind) -> ProviderKind? {
        guard (spoken ?? []).contains(where: \.isCloud), p.kind != current else { return nil }
        return p.kind
    }

    /// The service the panel opens on: the one in use, else Google (free to start).
    public static func defaultProvider(for current: ProviderKind) -> SetupProvider { current == .openRouter ? .openRouter : .google }
}

extension MenuRoute {
    /// v3: the app connects a key inline, so a route into setup's Connect lands on the Languages page with the first
    /// missing language's panel open. Setup's Connect step stays for the onboarding run.
    public var inApp: MenuRoute { self == .setup(.connect) ? .connectInline : self }
}

extension LanguagesPageState {
    /// v3: the Cloud section shows only once a key exists (with none, Connect lives on the language rows); a custom
    /// endpoint needs no key.
    public var showsCloudSection: Bool { showsEngineChoice }
}

extension CloudNudge {
    /// Uzbek, Russian or both among `langs` (the panel's "One key covers Uzbek and Russian.").
    static func combo(_ langs: [SpokenLanguage]) -> CloudCombo? {
        switch (langs.contains(.uz), langs.contains(.ru)) {
        case (true, true): return .uzru
        case (true, false): return .uz
        case (false, true): return .ru
        default: return nil
        }
    }
}
