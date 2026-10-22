import Testing
import Foundation
@testable import SoylaCore

/// Soyla Dev keeps its keys in a 0600 file instead of the Keychain: every rebuild changes the signature and
/// macOS would ask for the password again (owner decision 2026-10-17). Release must never use the file.
@Suite("Dev key file (Soyla Dev only)")
struct DevKeyFileTests {
    private func withFile(_ body: (KeyFileStore, URL) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("soyla-keyfile-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("dev-keys.json")
        try body(KeyFileStore(url: url), url)
    }

    @Test func onlyTheDevVariantUsesTheFile() {
        #expect(Soyla.usesKeyFile(bundleID: "ai.soyla.dev"))
        for id in [nil, "", "ai.soyla.app", "ai.soyla.", "ai.soyla.capture", "ai.soyla.devx", "com.apple.dt.xctest.tool"] as [String?] {
            #expect(!Soyla.usesKeyFile(bundleID: id))
        }
    }

    @Test func testProcessStillUsesTheKeychain() {
        #expect(Secrets.keychain is KeychainStore)
    }

    @Test func missingFileIsEmpty() throws {
        try withFile { store, _ in
            let v = try store.get(KeyBundle.account)
            #expect(v == nil)
        }
    }

    @Test func roundTripThroughKeyBundle() throws {
        try withFile { store, url in
            try KeyBundle.store(["openrouter": "sk-or-v1-FAKE1234", "google": "AIzaFAKE1234"], in: store)
            let loaded = try KeyBundle.load(store)
            #expect(loaded == ["openrouter": "sk-or-v1-FAKE1234", "google": "AIzaFAKE1234"])
            let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
            #expect(perms == 0o600)
            let dirPerms = try FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)[.posixPermissions] as? Int
            #expect(dirPerms == 0o700)
            try KeyBundle.store([:], in: store)                      // last key removed → entry gone
            let gone = try store.get(KeyBundle.account)
            #expect(gone == nil)
        }
    }

    @Test func otherAccountsSurviveADelete() throws {
        try withFile { store, _ in
            try store.set("a", for: "one")
            try store.set("b", for: "two")
            try store.delete("one")
            try store.delete("missing")                              // deleting a missing entry is not an error
            let one = try store.get("one"), two = try store.get("two")
            #expect(one == nil)
            #expect(two == "b")
        }
    }
}
