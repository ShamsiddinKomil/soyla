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

/// Where the key bundle lives: the Keychain (release) or, for Soyla Dev only, a 0600 file (`KeyFileStore`).
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

/// Soyla Dev only (`Soyla.usesKeyFile`): every rebuild changes the ad-hoc signature, so a Keychain item asks for the
/// login password after each build. Owner decision 2026-10-17: the dev build keeps its keys in a JSON file instead,
/// mode 0600 in a 0700 folder. Any process running as the user can read it; release never uses it.
public struct KeyFileStore: KeyStore {
    public let url: URL
    public init(url: URL) { self.url = url }

    private func read() throws -> [String: String] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        return (try JSONSerialization.jsonObject(with: data) as? [String: String]) ?? [:]
    }

    private func write(_ all: [String: String]) throws {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if all.isEmpty { try? fm.removeItem(at: url); return }
        let data = try JSONSerialization.data(withJSONObject: all, options: [.sortedKeys])
        if !fm.fileExists(atPath: url.path) {
            guard fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteNoPermission)
            }
        }
        try data.write(to: url)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public func get(_ account: String) throws -> String? { try read()[account] }

    public func set(_ value: String, for account: String, label: String? = nil) throws {
        var all = try read(); all[account] = value; try write(all)
    }

    public func delete(_ account: String) throws {
        var all = try read()
        guard all.removeValue(forKey: account) != nil else { return }
        try write(all)
    }
}
