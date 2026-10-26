import Foundation
import Security

/// Which API key. The raw value is the Keychain account name.
public enum KeyProvider: String, CaseIterable, Sendable, Identifiable {
    case openRouter = "openrouter", google, custom
    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .openRouter: return "OpenRouter"
        case .google: return "Google AI Studio"
        case .custom: return "Custom (OpenAI-compatible)"
        }
    }
    /// Process-env / `.env.local` variable name (dev fallback).
    public var envName: String {
        switch self {
        case .openRouter: return "OPENROUTER_API_KEY"
        case .google: return "GEMINI_API_KEY"
        case .custom: return "SOYLA_CUSTOM_API_KEY"
        }
    }
    /// Base URL used for the verified fingerprint. Custom gets its URL from Settings later (A3).
    public var baseURL: String {
        switch self {
        case .openRouter: return "https://openrouter.ai/api/v1"
        case .google: return "https://generativelanguage.googleapis.com/v1beta"
        case .custom: return ""
        }
    }
}

/// Where the key bundle lives: a 0600 file (`KeyFileStore`, every build since D4). `KeychainStore` is only the source of
/// the one-time move (`KeyMigration`) and the test double for the Keychain behaviour.
public protocol KeyStore: Sendable {
    func get(_ account: String) throws -> String?
    func set(_ value: String, for account: String, label: String?) throws
    func delete(_ account: String) throws
}

/// Generic-password items via Security.framework only. Service `ai.soyla.app`, account = provider raw value.
/// Values are never logged; errors carry the OSStatus only.
public struct KeychainStore: KeyStore {
    /// `SOYLA_KEYCHAIN_SERVICE` points a dev or capture run at a separate, empty set of items (never the real key).
    public static let defaultService = DevOverrides.environment["SOYLA_KEYCHAIN_SERVICE"] ?? Soyla.storage.keychainService
    public static let shared = KeychainStore()
    public let service: String

    public init(service: String = KeychainStore.defaultService) { self.service = service }

    public struct Failure: Error, LocalizedError, Sendable {
        public let op: String, status: OSStatus
        public var errorDescription: String? {
            let msg = (SecCopyErrorMessageString(status, nil) as String?) ?? "OSStatus \(status)"
            return "Keychain \(op) failed: \(msg)"
        }
    }

    private func base(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    /// nil when there is no item. Throws only on a real Keychain error (locked, denied…).
    public func get(_ account: String) throws -> String? {
        var q = base(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let st = SecItemCopyMatching(q as CFDictionary, &out)
        if st == errSecItemNotFound { return nil }
        guard st == errSecSuccess else { throw Failure(op: "read", status: st) }
        guard let data = out as? Data, let s = String(data: data, encoding: .utf8) else { return nil }
        return s
    }

    /// Adds or replaces the item.
    public func set(_ value: String, for account: String, label: String? = nil) throws {
        let data = Data(value.utf8)
        let upd: [String: Any] = [kSecValueData as String: data,
                                  kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var st = SecItemUpdate(base(account) as CFDictionary, upd as CFDictionary)
        if st == errSecItemNotFound {
            var add = base(account)
            add.merge(upd) { $1 }
            add[kSecAttrLabel as String] = label ?? "Soyla API key (\(account))"
            st = SecItemAdd(add as CFDictionary, nil)
        }
        guard st == errSecSuccess else { throw Failure(op: "save", status: st) }
    }

    /// Deleting a missing item is not an error.
    public func delete(_ account: String) throws {
        let st = SecItemDelete(base(account) as CFDictionary)
        guard st == errSecSuccess || st == errSecItemNotFound else { throw Failure(op: "delete", status: st) }
    }
}

/// Where every build keeps its keys (`Soyla.usesKeyFile`): a JSON file, mode 0600 in a 0700 folder, left out of
/// backups. Soyla Dev since 2026-10-17, release since D4 (owner, 2026-10-25): without an Apple team ID a Keychain item
/// made macOS ask for the login password after every update. Trade-off the owner accepted: any process running as
/// this user can read the file, the Keychain would have asked first.
public struct KeyFileStore: KeyStore {
    /// The file exists but is not Soyla's JSON (or can't be opened). Carries no path and no contents.
    public struct Unreadable: Error, LocalizedError, Sendable {
        public init() {}
        public var errorDescription: String? { "Soyla can't read its saved keys file" }
    }

    public let url: URL
    public init(url: URL) { self.url = url }

    public var exists: Bool { FileManager.default.fileExists(atPath: url.path) }

    private func read() throws -> [String: String] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return [:] }
        // Creation-time modes don't fix a file someone loosened later.
        if let p = try? fm.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int, p & 0o077 != 0 {
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        guard let data = try? Data(contentsOf: url),
              let all = (try? JSONSerialization.jsonObject(with: data)) as? [String: String] else { throw Unreadable() }
        return all
    }

    private func write(_ all: [String: String]) throws {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if all.isEmpty { try? fm.removeItem(at: url); return }
        let data = try JSONSerialization.data(withJSONObject: all, options: [.sortedKeys])
        try replaceAtomically(with: data, in: dir)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        var u = url
        var v = URLResourceValues()
        v.isExcludedFromBackup = true
        try? u.setResourceValues(v)
    }

    /// Review D4 #2: a crash or a full disk must never leave a truncated key file (after the move it is the only copy).
    /// The data goes to a temp file created 0600 in the same 0700 folder, is flushed, then renamed over the old file,
    /// so the result is the whole new file with mode 0600 or the untouched old one. `F_FULLFSYNC` (plain `fsync` on
    /// macOS may leave data in the drive's cache) and a sync of the folder make it survive a power cut before the
    /// Keychain copy is deleted (second review #2).
    private func replaceAtomically(with data: Data, in dir: URL) throws {
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        var ok = fchmod(fd, 0o600) == 0
        ok = ok && data.withUnsafeBytes { buf -> Bool in
            guard let base = buf.baseAddress else { return true }
            var off = 0
            while off < buf.count {
                let n = Darwin.write(fd, base + off, buf.count - off)
                if n <= 0 { return false }
                off += n
            }
            return true
        }
        ok = ok && Self.fullSync(fd)
        ok = close(fd) == 0 && ok
        guard ok, rename(tmp.path, url.path) == 0 else {
            unlink(tmp.path)
            throw CocoaError(.fileWriteUnknown)
        }
        // The rename lives in the folder's entry: flush it too.
        let dfd = open(dir.path, O_RDONLY)
        guard dfd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        let synced = Self.fullSync(dfd)
        close(dfd)
        guard synced else { throw CocoaError(.fileWriteUnknown) }
    }

    /// `F_FULLFSYNC` asks the drive to flush to the media; some file systems refuse it, then plain `fsync`.
    private static func fullSync(_ fd: Int32) -> Bool { fcntl(fd, F_FULLFSYNC) != -1 || fsync(fd) == 0 }

    public func get(_ account: String) throws -> String? { try read()[account] }

    /// A broken file is replaced: it is Soyla's own file and nothing in it can be read anyway.
    public func set(_ value: String, for account: String, label: String? = nil) throws {
        var all = (try? read()) ?? [:]; all[account] = value; try write(all)
    }

    public func delete(_ account: String) throws {
        guard var all = try? read() else { return try write([:]) }   // broken file: removing a key drops it
        guard all.removeValue(forKey: account) != nil else { return }
        try write(all)
    }
}
