import Foundation
import CryptoKit
import os

/// API key lookup. Order: process environment → the key file (`KeyFileStore`, `SoylaPaths.keyFile`) →
/// `SoylaPaths.envFile` (`.env.local`, development only). The Keychain is read once, at launch, to move old keys (D4).
/// NEVER print or log a key; only `masked` values may reach the UI, never the log.
public enum Secrets {
    public enum Source: String, Sendable { case environment, keychain, envFile }

    /// The store the app saves keys in: the key file in every build (D4). Named `keychain` from before D4; `Source.keychain`
    /// likewise means "saved by Soyla". Tests use their own stores via `lookup` / `KeyMigration`.
    static let keychain: any KeyStore = KeyFileStore(url: SoylaPaths.keyFile)

    // MARK: lookup

    /// Pure lookup, injectable for tests.
    static func lookup(_ p: KeyProvider, env: [String: String], keychain: KeychainStore?, envFile: URL?) -> (value: String, source: Source)? {
        if let v = env[p.envName]?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty { return (v, .environment) }
        if let kc = keychain, let v = (try? kc.get(p.rawValue)) ?? nil, !v.isEmpty { return (v, .keychain) }
        if let f = envFile, let text = try? String(contentsOf: f, encoding: .utf8), let v = parseEnv(text)[p.envName], !v.isEmpty {
            return (v, .envFile)
        }
        return nil
    }

    /// Cached key reads: the app asks for keys on every key-down and every 2 s in the status view.
    private static let cache = KeyCache()

    public static func find(_ p: KeyProvider) -> (value: String, source: Source)? {
        // Environment and `.env.local` are developer switches: the installed app reads the key file only.
        if let hit = lookup(p, env: DevOverrides.environment, keychain: nil, envFile: nil) { return hit }
        if let v = cache.value(p.rawValue, load: { try KeyBundle.load(keychain)[p.rawValue] }), !v.isEmpty { return (v, .keychain) }
        return DevOverrides.enabled ? lookup(p, env: [:], keychain: nil, envFile: SoylaPaths.envFile) : nil
    }

    public static func key(for p: KeyProvider) throws -> String {
        guard let hit = find(p) else {
            switch cache.state(p.rawValue) {
            case .loading: throw SoylaError.keychainBlocked(denied: false)
            case .denied: throw SoylaError.keychainBlocked(denied: true)
            case .pending: throw SoylaError.missingAPIKey("\(p.label) — Soyla couldn't open the Keychain to move it; quit and reopen Soyla")
            case .unreadable: throw SoylaError.missingAPIKey("\(p.label) — Soyla can't read its saved keys file; connect the key again in Settings → Languages")
            case .ready: throw SoylaError.missingAPIKey("\(p.label) — add it in Settings → Engine")
            }
        }
        return hit.value
    }

    // MARK: launch read (GUI)

    /// Posted on the main queue when `loadInBackground` has finished (the key is in the cache, missing, or refused).
    public static let didLoad = Notification.Name("ai.soyla.secrets.didLoad")

    /// Where the launch read stands, for the window. `.waiting` / `.denied`: the one-time move out of the Keychain
    /// (`KeyMigration`) is waiting on, or was refused at, the macOS password dialog. `.pending`: the Keychain could not
    /// be opened (locked…), the move is retried next launch. `.unreadable`: the key file is broken.
    /// See docs/TROUBLESHOOTING.md.
    public enum KeychainAccess: Sendable, Equatable { case ready, waiting, denied, pending, unreadable }

    public static var keychainAccess: KeychainAccess {
        let states = KeyProvider.allCases.map { cache.state($0.rawValue) }
        if states.contains(.loading) { return .waiting }
        if states.contains(.denied) { return .denied }
        if states.contains(.pending) { return .pending }
        if states.contains(.unreadable) { return .unreadable }
        return .ready
    }

    /// Set once the old Keychain bundle has been moved (or there was none), so the Keychain is never read again.
    static let movedFlag = "keys.movedFromKeychain"

    /// True when this build will never read the Keychain again (moved, or not allowed to move here).
    static var moveDone: Bool {
        !KeyMigration.allowed(isRelease: Soyla.storage.isRelease, devLayout: SoylaPaths.isDevLayout) || defaults.bool(forKey: movedFlag)
    }

    /// Launch read: the key file, after moving an old Keychain bundle into it once (D4).
    static func loadAtLaunch() throws -> KeyMigration.Result {
        guard let file = keychain as? KeyFileStore else {
            return KeyMigration.Result(outcome: .fileInUse, keys: try KeyBundle.load(keychain), markDone: false)
        }
        let r = try KeyMigration.run(from: KeychainStore(service: KeychainStore.defaultService), to: file, done: moveDone)
        if r.markDone, !moveDone { defaults.set(true, forKey: movedFlag) }
        if r.outcome != .fileInUse, r.outcome != .alreadyDone { Log.info("keys: \(r.outcome)") }   // counts only, never keys
        return r
    }

    /// Reads the saved keys off the main thread. While macOS shows its password dialog (the one-time move out of the
    /// Keychain), `find` returns nil at once instead of blocking, so the window opens and can explain the dialog.
    /// Call once at launch, before any `find`.
    public static func loadInBackground() {
        let accounts = KeyProvider.allCases.map(\.rawValue)
        for a in accounts { cache.begin(a) }
        DispatchQueue.global(qos: .userInitiated).async {
            let all = Result { try loadAtLaunch() }
            // A key the file has is usable even while the move waits; the others stay denied / pending, never "no key".
            for a in accounts {
                cache.finish(a, load: {
                    let r = try all.get()
                    if let v = r.keys[a] { return v }
                    if let retry = r.retry { throw KeyMigration.Blocked(denied: retry == .denied) }
                    return nil
                })
            }
            Task { @MainActor in NotificationCenter.default.post(name: didLoad, object: nil) }
        }
    }

    public static func openRouterKey() throws -> String { try key(for: .openRouter) }
    /// Google AI Studio key (Gemini Live preview; Google provider in A3).
    public static func geminiKey() throws -> String { try key(for: .google) }

    // MARK: key writes (Settings → Engine)

    public static func save(_ value: String, for p: KeyProvider) throws {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty else { return }
        try KeyBundle.store(KeyBundle.merged(cache: cache, set: p.rawValue, to: v), in: keychain)
        cache.set(p.rawValue, v)
        clearVerified(p)
    }

    public static func remove(_ p: KeyProvider) throws {
        // While the move is pending the old Keychain copy would merge this key back (second review #1).
        if let file = keychain as? KeyFileStore { try KeyMigration.forget(p.rawValue, in: file, done: moveDone) }
        try KeyBundle.store(KeyBundle.merged(cache: cache, set: p.rawValue, to: nil), in: keychain)
        cache.set(p.rawValue, nil)
        clearVerified(p)
    }

    // MARK: verified fingerprint (SHA256(baseURL|key), stored in the defaults suite; never the key itself)

    public static func fingerprintHex(baseURL: String, key: String) -> String {
        SHA256.hash(data: Data((baseURL + "|" + key).utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private static var defaults: UserDefaults { UserDefaults(suiteName: Soyla.defaultsSuite) ?? .standard }
    private static func fpKey(_ p: KeyProvider) -> String { "verifiedFingerprint.\(p.rawValue)" }

    public static func markVerified(_ p: KeyProvider, key: String) {
        defaults.set(fingerprintHex(baseURL: p.baseURL, key: key), forKey: fpKey(p))
    }
    public static func clearVerified(_ p: KeyProvider) { defaults.removeObject(forKey: fpKey(p)) }
    /// True only while the current key (any source) matches the last successful Test.
    public static func isVerified(_ p: KeyProvider, key: String) -> Bool {
        guard let fp = defaults.string(forKey: fpKey(p)) else { return false }
        return fp == fingerprintHex(baseURL: p.baseURL, key: key)
    }

    // MARK: helpers

    /// KEY=VALUE lines, `#` comments, optional `export `, optional single/double quotes.
    static func parseEnv(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let k = line[..<eq].trimmingCharacters(in: .whitespaces)
            var v = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if v.count >= 2, let f = v.first, let l = v.last, (f == "\"" && l == "\"") || (f == "'" && l == "'") {
                v = String(v.dropFirst().dropLast())
            } else if let hash = v.range(of: " #") {
                v = String(v[..<hash.lowerBound]).trimmingCharacters(in: .whitespaces)
            }
            if !k.isEmpty { out[k] = v }
        }
        return out
    }

    /// "…" + last 4 characters, for any provider. Keys shorter than 12 characters show no characters at all.
    public static func masked(_ key: String) -> String { key.count >= 12 ? "…" + key.suffix(4) : "…" }
}

/// Every saved key in ONE entry (account `keys`, JSON `{provider: key}`), in the key file since D4.
/// Keychain history: without an Apple team ID, macOS ties each item to the exact build that may read it, so an update
/// asked for the Mac password once per item: one item = one dialog (owner, 2026-10-16). Older builds kept one item per
/// provider; `load` moves those into the bundle the first time.
enum KeyBundle {
    static let account = "keys"
    static let label = "Soyla API keys"

    static func encode(_ keys: [String: String]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: keys.filter { !$0.value.isEmpty }, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(bytes: data, encoding: .utf8) ?? "{}"
    }

    static func decode(_ text: String) -> [String: String] {
        let obj = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
        return obj.compactMapValues { ($0 as? String).flatMap { $0.isEmpty ? nil : $0 } }
    }

    /// The bundle, or the old per-provider items (`legacy`), without writing anything. Throws on a real store error.
    static func read(_ store: some KeyStore) throws -> (keys: [String: String], legacy: Bool) {
        if let text = try store.get(account) { return (decode(text), false) }
        var old: [String: String] = [:]
        for p in KeyProvider.allCases { if let v = try store.get(p.rawValue), !v.isEmpty { old[p.rawValue] = v } }
        return (old, !old.isEmpty)
    }

    /// Throws only on a real store error (Keychain locked or Deny, key file unreadable). Never runs on main in the app.
    static func load(_ store: some KeyStore) throws -> [String: String] {
        let (old, legacy) = try read(store)
        guard legacy else { return old }
        try Self.store(old, in: store)
        for p in KeyProvider.allCases { try? store.delete(p.rawValue) }
        return old
    }

    /// Writes the whole set; an empty set deletes the item.
    static func store(_ keys: [String: String], in kc: some KeyStore) throws {
        let kept = keys.filter { !$0.value.isEmpty }
        if kept.isEmpty { try kc.delete(account) } else { try kc.set(encode(kept), for: account, label: label) }
    }

    /// The set to write when one key changes: the others come from the cache, never from a read on main.
    /// While macOS still asks for the password (or after Deny) the others are unknown, and saving would erase them.
    /// An unreadable key file has nothing to keep, so a save may replace it. A pending move may also save: the moved
    /// flag stays unset, so the next launch merges the Keychain keys into the file (`KeyMigration`).
    static func merged(cache: KeyCache, set k: String, to v: String?) throws -> [String: String] {
        var all: [String: String] = [:]
        for p in KeyProvider.allCases {
            switch cache.state(p.rawValue) {
            case .loading: throw SoylaError.keychainBlocked(denied: false)
            case .denied: throw SoylaError.keychainBlocked(denied: true)
            case .ready: if let v = cache.peek(p.rawValue) { all[p.rawValue] = v }
            case .unreadable, .pending: break
            }
        }
        all[k] = v
        return all.filter { !$0.value.isEmpty }
    }
}

final class KeyCache: Sendable {
    enum State: Equatable { case ready, loading, denied, pending, unreadable }
    private enum Entry: Sendable { case value(String?), loading, denied, pending, unreadable }
    private let entries = OSAllocatedUnfairLock(initialState: [String: Entry]())

    /// A throwing load (Keychain locked) is NOT cached, so the key is found once the Keychain unlocks (R1).
    /// While a background load runs, or after the user clicked Deny, returns nil without touching the Keychain:
    /// a second read would block the caller behind (or re-open) the macOS password dialog.
    func value(_ k: String, load: () throws -> String?) -> String? {
        // Unchecked only because `load` is not @Sendable: it is non-escaping and runs right here, on the caller's
        // thread, under the lock (so two first reads never open two Keychain dialogs).
        entries.withLockUnchecked { entries in
            switch entries[k] {
            case .value(let v): return v
            case .loading, .denied, .pending, .unreadable: return nil
            case nil: break
            }
            let v: String?
            do { v = try load() } catch { if let e = Self.cached(error) { entries[k] = e }; return nil }
            entries[k] = .value(v)
            return v
        }
    }

    func state(_ k: String) -> State {
        entries.withLock { entries in
            switch entries[k] {
            case .loading: return .loading
            case .denied: return .denied
            case .pending: return .pending
            case .unreadable: return .unreadable
            default: return .ready
            }
        }
    }

    func begin(_ k: String) { entries.withLock { if $0[k] == nil { $0[k] = .loading } } }

    /// Runs the load WITHOUT the lock held (it can wait minutes on the password dialog), then stores the result.
    /// A save or remove that happened meanwhile wins.
    func finish(_ k: String, load: () throws -> String?) {
        let pending = entries.withLock { if case .loading? = $0[k] { return true }; return false }
        guard pending else { return }
        let result: Entry?
        do { result = .value(try load()) } catch { result = Self.cached(error) }
        entries.withLock { if case .loading? = $0[k] { $0[k] = result } }
    }

    func set(_ k: String, _ v: String?) { entries.withLock { $0[k] = .value(v) } }

    /// The cached value without loading (nil when missing, not loaded yet, waiting or denied).
    func peek(_ k: String) -> String? { entries.withLock { if case .value(let v)? = $0[k] { return v }; return nil } }

    /// Errors kept for the session: Deny / Cancel (so Soyla does not reopen the dialog on every refresh), a move that
    /// could not open the Keychain (retried next launch, never shown as "no key") and a broken key file.
    private static func cached(_ error: Error) -> Entry? {
        if let b = error as? KeyMigration.Blocked { return b.denied ? .denied : .pending }
        if isDenial(error) { return .denied }
        return error is KeyFileStore.Unreadable ? .unreadable : nil
    }

    /// Deny in the macOS dialog (or Cancel).
    static func isDenial(_ error: Error) -> Bool {
        guard let f = error as? KeychainStore.Failure else { return false }
        return f.status == errSecUserCanceled || f.status == errSecAuthFailed
    }
}

/// D4: moves an old Keychain bundle into the key file once, then deletes the Keychain item. Pure over two stores, so
/// tests run it on fakes; the app runs it from `Secrets.loadAtLaunch` off the main thread.
enum KeyMigration {
    enum Outcome: Equatable, CustomStringConvertible {
        /// The move is done and the key file exists: the Keychain is not read.
        case fileInUse
        /// Moved earlier (or not allowed here), no file yet: the Keychain is not read.
        case alreadyDone
        /// The Keychain had no Soyla keys.
        case nothingFound
        /// This many keys came from the Keychain (merged into the file; the file wins per key); the item is deleted.
        case moved(Int)
        /// Writing the file failed: the Keychain item stays, the keys are used from memory, the next launch retries.
        case keptInKeychain
        /// Deny / Cancel in the macOS dialog: nothing written or deleted, asked again next launch.
        case denied
        /// The Keychain could not be read for another reason (locked, no UI allowed): retried next launch.
        case pending
        var description: String {
            switch self {
            case .fileInUse: return "file in use"
            case .alreadyDone: return "already moved"
            case .nothingFound: return "nothing in the Keychain"
            case .moved(let n): return "moved \(n) from the Keychain"
            case .keptInKeychain: return "file write failed, kept in the Keychain"
            case .denied: return "move refused at the dialog"
            case .pending: return "Keychain not readable, move pending"
            }
        }
    }

    /// Why keys the file lacks are not "missing" yet.
    enum Retry: Equatable { case denied, pending }

    /// Thrown into `KeyCache` for a key the file lacks while the move waits, so it is never cached as "no key".
    struct Blocked: Error { let denied: Bool }

    struct Result: Equatable {
        let outcome: Outcome
        /// The keys usable now: the file's, plus the Keychain's once read.
        let keys: [String: String]
        /// Set the "moved" flag: never read the Keychain again.
        let markDone: Bool
        var retry: Retry?
    }

    /// Keys removed while the move is pending (JSON array in the key file), so the merge never brings them back.
    /// Cleared once the move is done.
    static let removedAccount = "removedBeforeMove"

    static func removed(in file: KeyFileStore) -> Set<String> {
        guard let text = (try? file.get(removedAccount)) ?? nil,
              let list = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String] else { return [] }
        return Set(list)
    }

    /// Remembers a removed key until the move is done; after it, a remove only edits the file.
    static func forget(_ account: String, in file: KeyFileStore, done: Bool) throws {
        guard !done else { return }
        let data = try JSONSerialization.data(withJSONObject: removed(in: file).union([account]).sorted())
        try file.set(String(bytes: data, encoding: .utf8) ?? "[]", for: removedAccount)
    }

    /// Only the release build in its real folder moves keys. Under `SOYLA_HOME` a dev run would otherwise empty the
    /// real Keychain into a repo folder the installed app never reads; Soyla Dev left its old item behind on purpose.
    static func allowed(isRelease: Bool, devLayout: Bool) -> Bool { isRelease && !devLayout }

    /// Until the moved flag is set the Keychain is read on every launch, even when the file exists: a key connected
    /// while the move was still pending must not strand the others (review D4 #1). Throws only for an unreadable file.
    static func run(from old: some KeyStore, to file: KeyFileStore, done: Bool) throws -> Result {
        let inFile = try KeyBundle.load(file)
        if done { return Result(outcome: file.exists ? .fileInUse : .alreadyDone, keys: inFile, markDone: true) }
        let inKeychain: [String: String]
        do {
            inKeychain = try KeyBundle.read(old).keys   // the one last macOS dialog for an upgrader
        } catch {
            let denied = KeyCache.isDenial(error)
            return Result(outcome: denied ? .denied : .pending, keys: inFile, markDone: false, retry: denied ? .denied : .pending)
        }
        let gone = removed(in: file)
        guard !inKeychain.isEmpty else {
            if !gone.isEmpty { try? file.delete(removedAccount) }
            return Result(outcome: .nothingFound, keys: inFile, markDone: true)
        }
        let fromKeychain = inKeychain.filter { !gone.contains($0.key) }   // removed while pending: never merged back
        let merged = fromKeychain.merging(inFile) { _, fileValue in fileValue }
        let taken = fromKeychain.keys.filter { inFile[$0] == nil }.count
        if merged != inFile {
            do {
                try KeyBundle.store(merged, in: file)
                guard try KeyBundle.load(file) == merged else { throw KeyFileStore.Unreadable() }
            } catch {
                // A bad bundle must not hide the Keychain next time; the removed-keys marker and older keys stay.
                if inFile.isEmpty { try? file.delete(KeyBundle.account) }
                return Result(outcome: .keptInKeychain, keys: merged, markDone: false)
            }
        }
        for a in [KeyBundle.account] + KeyProvider.allCases.map(\.rawValue) { try? old.delete(a) }
        if !gone.isEmpty { try? file.delete(removedAccount) }
        return Result(outcome: .moved(taken), keys: merged, markDone: true)
    }
}

/// Settings → Engine → Test. Ephemeral session, no cache (PLAN §13 R3). Never logs the key or a response body.
public enum KeyCheck {
    public struct Result: Sendable, Equatable {
        public let ok: Bool
        public let message: String
        /// The provider refused the key (401/403/invalid), as opposed to a network or server problem.
        public var rejected: Bool { !ok && message.hasPrefix("Key rejected") }
    }

    public static func request(_ p: KeyProvider, key: String) -> URLRequest? {
        var r: URLRequest
        switch p {
        case .openRouter:
            r = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/key")!)
            r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        case .google:
            // Header instead of ?key= so the key never sits in a URL.
            r = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models?pageSize=1000")!)
            r.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        case .custom:
            return nil
        }
        r.timeoutInterval = 15
        r.cachePolicy = .reloadIgnoringLocalCacheData
        return r
    }

    /// Interprets a response. Pure, unit-tested with canned JSON.
    public static func interpret(_ p: KeyProvider, status: Int, body: Data) -> Result {
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let bodyText = String(data: body, encoding: .utf8) ?? ""
        if status == 401 || status == 403 || (p == .google && status == 400 && bodyText.contains("API key not valid")) {
            return Result(ok: false, message: "Key rejected — check that it was copied completely")
        }
        guard status == 200 else { return Result(ok: false, message: "HTTP \(status) — try again later") }
        switch p {
        case .openRouter:
            let d = json?["data"] as? [String: Any] ?? [:]
            var parts = ["OK"]
            // OpenRouter's default label is the masked key itself ("sk-or-v1-…"); show only custom labels.
            if let label = d["label"] as? String, !label.isEmpty, !label.hasPrefix("sk-") { parts.append(label) }
            if let rem = d["limit_remaining"] as? Double { parts.append(String(format: "$%.2f credit left", rem)) }
            else if d["limit"] is NSNull || d["limit"] == nil { parts.append("no credit limit") }
            return Result(ok: true, message: parts.joined(separator: " · "))
        case .google:
            let n = (json?["models"] as? [Any])?.count ?? 0
            return Result(ok: true, message: "OK, \(n) models")
        case .custom:
            return Result(ok: false, message: "Test is not available for custom providers yet")
        }
    }

    /// Runs the check; on success stores the verified fingerprint.
    public static func run(_ p: KeyProvider, key: String) async -> Result {
        guard let req = request(p, key: key) else { return interpret(p, status: 0, body: Data()) }
        let c = URLSessionConfiguration.ephemeral
        c.urlCache = nil
        let session = URLSession(configuration: c, delegate: MetricsCollector(), delegateQueue: nil)   // refuses redirects (R1)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (data, resp) = try await session.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let r = interpret(p, status: status, body: data)
            if r.ok { Secrets.markVerified(p, key: key) }
            Log.info("key test \(p.rawValue): HTTP \(status) ok=\(r.ok)")
            return r
        } catch {
            Log.info("key test \(p.rawValue): network error \((error as NSError).code)")
            return Result(ok: false, message: "Network error — \(error.localizedDescription)")
        }
    }
}
