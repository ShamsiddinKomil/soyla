import Testing
import Foundation
import os
import Security
@testable import SoylaCore

/// D4 (owner 2026-10-25): the release app keeps its keys in a 0600 file. An existing Keychain bundle is moved once,
/// then the Keychain item is deleted. Every store here is fake or a temp file: no real Keychain, no dialog.
@Suite("Key file migration (D4)")
struct KeyFileMigrationTests {
    /// In-memory stand-in for the Keychain that counts reads and can refuse them like the macOS dialog's Deny.
    final class FakeStore: KeyStore {
        struct State { var items: [String: String] = [:]; var reads = 0; var deletes: [String] = [] }
        let state: OSAllocatedUnfairLock<State>
        let readError: KeychainStore.Failure?
        init(_ items: [String: String] = [:], readError: KeychainStore.Failure? = nil) {
            state = OSAllocatedUnfairLock(initialState: State(items: items))
            self.readError = readError
        }
        var items: [String: String] { state.withLock { $0.items } }
        var reads: Int { state.withLock { $0.reads } }
        func get(_ account: String) throws -> String? {
            try state.withLock { s in
                s.reads += 1
                if let e = readError { throw e }
                return s.items[account]
            }
        }
        func set(_ value: String, for account: String, label: String?) throws { state.withLock { $0.items[account] = value } }
        func delete(_ account: String) throws { state.withLock { $0.items[account] = nil; $0.deletes.append(account) } }
    }

    private func withDir(_ body: (URL) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("soyla-d4-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try body(dir)
    }

    private func perms(_ url: URL) throws -> Int? {
        try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
    }

    private let both = ["openrouter": "sk-or-v1-FAKE1234", "google": "AIzaFAKE1234"]

    // MARK: where the file lives

    @Test func releaseKeysLiveInKeysJSONUnderApplicationSupport() {
        let home = URL(fileURLWithPath: "/Users/fake")
        let rel = SoylaPaths.resolve(env: [:], home: home, supportFolder: "Soyla")
        #expect(SoylaPaths.keyFile(root: rel.root, devLayout: rel.devLayout, isRelease: true).path
            == "/Users/fake/Library/Application Support/Soyla/keys.json")
        let dev = SoylaPaths.resolve(env: [:], home: home, supportFolder: "Soyla Dev")
        #expect(SoylaPaths.keyFile(root: dev.root, devLayout: dev.devLayout, isRelease: false).path
            == "/Users/fake/Library/Application Support/Soyla Dev/dev-keys.json")
    }

    @Test func soylaHomeKeepsTheFileInGitignoredLogs() {
        let r = SoylaPaths.resolve(env: ["SOYLA_HOME": "/Users/fake/repo"], home: URL(fileURLWithPath: "/Users/fake"))
        #expect(SoylaPaths.keyFile(root: r.root, devLayout: r.devLayout, isRelease: true).path == "/Users/fake/repo/logs/keys.json")
    }

    @Test func onlyTheRealReleaseFolderMigrates() {
        #expect(KeyMigration.allowed(isRelease: true, devLayout: false))
        #expect(!KeyMigration.allowed(isRelease: true, devLayout: true))     // SOYLA_HOME must never empty the real Keychain
        #expect(!KeyMigration.allowed(isRelease: false, devLayout: false))   // Soyla Dev already moved (2026-10-17)
    }

    // MARK: migration

    @Test func movesTheBundleToTheFileAndDeletesTheKeychainItem() throws {
        try withDir { dir in
            let file = KeyFileStore(url: dir.appendingPathComponent("keys.json"))
            let old = FakeStore([KeyBundle.account: KeyBundle.encode(both)])
            let r = try KeyMigration.run(from: old, to: file, done: false)
            #expect(r.outcome == .moved(2))
            #expect(r.keys == both)
            #expect(r.markDone)
            #expect(try KeyBundle.load(file) == both)
            #expect(old.items.isEmpty)
            #expect(try perms(file.url) == 0o600)
            #expect(try perms(dir) == 0o700)
        }
    }

    @Test func movesLegacyPerProviderItemsWithoutWritingTheKeychain() throws {
        try withDir { dir in
            let file = KeyFileStore(url: dir.appendingPathComponent("keys.json"))
            let old = FakeStore(["openrouter": "sk-or-v1-FAKE1234"])
            let r = try KeyMigration.run(from: old, to: file, done: false)
            #expect(r.outcome == .moved(1))
            #expect(try KeyBundle.load(file) == ["openrouter": "sk-or-v1-FAKE1234"])
            #expect(old.items.isEmpty)
        }
    }

    @Test func anExistingFileWithTheMoveDoneNeverTouchesTheKeychain() throws {
        try withDir { dir in
            let file = KeyFileStore(url: dir.appendingPathComponent("keys.json"))
            try KeyBundle.store(["google": "AIzaFAKE1234"], in: file)
            let old = FakeStore([KeyBundle.account: KeyBundle.encode(both)])
            let r = try KeyMigration.run(from: old, to: file, done: true)
            #expect(r.outcome == .fileInUse)
            #expect(r.keys == ["google": "AIzaFAKE1234"])
            #expect(old.reads == 0)
        }
    }

    /// Review D4 #1: a key connected while the move was still pending (file created) must not strand the others.
    @Test func aKeySavedBeforeTheMoveIsMergedNotStranded() throws {
        try withDir { dir in
            let file = KeyFileStore(url: dir.appendingPathComponent("keys.json"))
            try KeyBundle.store(["google": "AIzaFAKE-NEW1234"], in: file)
            let old = FakeStore([KeyBundle.account: KeyBundle.encode(both)])
            let r = try KeyMigration.run(from: old, to: file, done: false)
            let merged = ["openrouter": "sk-or-v1-FAKE1234", "google": "AIzaFAKE-NEW1234"]   // the file wins per key
            #expect(r.outcome == .moved(1))
            #expect(r.keys == merged)
            #expect(r.markDone)
            #expect(try KeyBundle.load(file) == merged)
            #expect(old.items.isEmpty)
        }
    }

    /// Second review #1: a key removed while the move is pending must not come back from the Keychain.
    @Test func aKeyRemovedWhileTheMoveIsPendingStaysGone() throws {
        try withDir { dir in
            let file = KeyFileStore(url: dir.appendingPathComponent("keys.json"))
            let old = FakeStore([KeyBundle.account: KeyBundle.encode(both)])
            try KeyBundle.store(["google": "AIzaFAKE-NEW1234"], in: file)        // saved during pending
            try KeyMigration.forget("google", in: file, done: false)            // then removed (Secrets.remove)
            try KeyBundle.store([:], in: file)
            let r = try KeyMigration.run(from: old, to: file, done: false)
            #expect(r.keys == ["openrouter": "sk-or-v1-FAKE1234"])
            #expect(r.markDone)
            #expect(try KeyBundle.load(file) == ["openrouter": "sk-or-v1-FAKE1234"])
            #expect(old.items.isEmpty)
            #expect(KeyMigration.removed(in: file).isEmpty)                     // marker cleared once the move is done
        }
    }

    @Test func aRemovedMarkerSurvivesAFailedMoveAndIsNotWrittenOnceDone() throws {
        try withDir { dir in
            let file = KeyFileStore(url: dir.appendingPathComponent("keys.json"))
            try KeyMigration.forget("openrouter", in: file, done: false)
            let locked = FakeStore([KeyBundle.account: KeyBundle.encode(both)],
                                   readError: KeychainStore.Failure(op: "read", status: errSecInteractionNotAllowed))
            let pending = try KeyMigration.run(from: locked, to: file, done: false)
            #expect(pending.outcome == .pending)
            #expect(KeyMigration.removed(in: file) == ["openrouter"])
            let r = try KeyMigration.run(from: FakeStore([KeyBundle.account: KeyBundle.encode(both)]), to: file, done: false)
            #expect(r.keys == ["google": "AIzaFAKE1234"])
            // After the move a remove only edits the file: nothing to remember.
            try KeyMigration.forget("google", in: file, done: true)
            #expect(KeyMigration.removed(in: file).isEmpty)
        }
    }

    /// Review D4 #1: a locked Keychain (not Deny) keeps the move pending, keeps the file's keys usable, deletes nothing.
    @Test func aLockedKeychainLeavesTheMovePending() throws {
        try withDir { dir in
            let file = KeyFileStore(url: dir.appendingPathComponent("keys.json"))
            try KeyBundle.store(["google": "AIzaFAKE1234"], in: file)
            let old = FakeStore([KeyBundle.account: KeyBundle.encode(both)],
                                readError: KeychainStore.Failure(op: "read", status: errSecInteractionNotAllowed))
            let r = try KeyMigration.run(from: old, to: file, done: false)
            #expect(r.outcome == .pending)
            #expect(r.retry == .pending)
            #expect(r.keys == ["google": "AIzaFAKE1234"])
            #expect(!r.markDone)
            #expect(old.items[KeyBundle.account] != nil)
            #expect(try KeyBundle.load(file) == ["google": "AIzaFAKE1234"])
        }
    }

    @Test func aPendingMoveIsNotAnEmptyReady() throws {
        let cache = KeyCache()
        cache.begin("openrouter")
        cache.finish("openrouter", load: { throw KeyMigration.Blocked(denied: false) })
        #expect(cache.state("openrouter") == .pending)
        var loads = 0
        #expect(cache.value("openrouter", load: { loads += 1; return nil }) == nil)
        #expect(loads == 0)                                       // no file-only read that would cache "no key"
        for p in KeyProvider.allCases where p != .openRouter { cache.set(p.rawValue, nil) }
        // Saving stays allowed: the next launch merges the Keychain keys in (the moved flag is still unset).
        #expect(try KeyBundle.merged(cache: cache, set: "google", to: "AIzaFAKE1234") == ["google": "AIzaFAKE1234"])
        let denied = KeyCache()
        denied.begin("google")
        denied.finish("google", load: { throw KeyMigration.Blocked(denied: true) })
        #expect(denied.state("google") == .denied)
    }

    @Test func doneNeverTouchesTheKeychain() throws {
        try withDir { dir in
            let file = KeyFileStore(url: dir.appendingPathComponent("keys.json"))
            let old = FakeStore([KeyBundle.account: KeyBundle.encode(both)])
            let r = try KeyMigration.run(from: old, to: file, done: true)
            #expect(r.outcome == .alreadyDone)
            #expect(r.keys.isEmpty)
            #expect(old.reads == 0)
        }
    }

    @Test func nothingInTheKeychainIsDoneWithoutAFile() throws {
        try withDir { dir in
            let file = KeyFileStore(url: dir.appendingPathComponent("keys.json"))
            let r = try KeyMigration.run(from: FakeStore(), to: file, done: false)
            #expect(r.outcome == .nothingFound)
            #expect(r.markDone)
            #expect(!file.exists)
        }
    }

    @Test func denyWritesNothingAndDeletesNothing() throws {
        try withDir { dir in
            let file = KeyFileStore(url: dir.appendingPathComponent("keys.json"))
            let old = FakeStore([KeyBundle.account: KeyBundle.encode(both)],
                                readError: KeychainStore.Failure(op: "read", status: errSecUserCanceled))
            let r = try KeyMigration.run(from: old, to: file, done: false)
            #expect(r.outcome == .denied)
            #expect(r.retry == .denied)
            #expect(!r.markDone)
            #expect(!file.exists)
            #expect(old.items[KeyBundle.account] != nil)
        }
    }

    @Test func aFailedWriteKeepsTheKeychainItem() throws {
        try withDir { dir in
            // The folder's parent is a plain file, so the folder (and the key file) can't be created.
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let blocker = dir.appendingPathComponent("blocker")
            #expect(FileManager.default.createFile(atPath: blocker.path, contents: Data()))
            let file = KeyFileStore(url: blocker.appendingPathComponent("sub/keys.json"))
            let old = FakeStore([KeyBundle.account: KeyBundle.encode(both)])
            let r = try KeyMigration.run(from: old, to: file, done: false)
            #expect(r.outcome == .keptInKeychain)
            #expect(r.keys == both)                      // this session still works
            #expect(!r.markDone)                         // the next launch tries again
            #expect(old.items[KeyBundle.account] != nil)
        }
    }
}

/// The unreadable-file, file-write and Home cases (an extension keeps the suite under the type-length limit).
extension KeyFileMigrationTests {
    // MARK: unreadable file

    @Test func aBrokenFileIsUnreadableNotMissing() throws {
        try withDir { dir in
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("keys.json")
            try Data("not json FAKE1234".utf8).write(to: url)
            let file = KeyFileStore(url: url)
            #expect(throws: KeyFileStore.Unreadable.self) { try file.get(KeyBundle.account) }
            let cache = KeyCache()
            #expect(cache.value("google", load: { try KeyBundle.load(file)["google"] }) == nil)
            #expect(cache.state("google") == .unreadable)
            // Saving a key replaces the broken file: it is Soyla's own file, nothing readable is lost.
            try KeyBundle.store(["google": "AIzaFAKE1234"], in: file)
            #expect(try KeyBundle.load(file) == ["google": "AIzaFAKE1234"])
        }
    }

    @Test func aFileOfTheWrongShapeIsUnreadable() throws {
        try withDir { dir in
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("keys.json")
            try Data("[1, 2]".utf8).write(to: url)
            #expect(throws: KeyFileStore.Unreadable.self) { try KeyFileStore(url: url).get(KeyBundle.account) }
        }
    }

    @Test func savingWhileUnreadableIsAllowed() throws {
        let cache = KeyCache()
        cache.begin("openrouter")
        cache.finish("openrouter", load: { throw KeyFileStore.Unreadable() })
        for p in KeyProvider.allCases where p != .openRouter { cache.set(p.rawValue, nil) }
        #expect(cache.state("openrouter") == .unreadable)
        let merged = try KeyBundle.merged(cache: cache, set: "google", to: "AIzaFAKE1234")
        #expect(merged == ["google": "AIzaFAKE1234"])
    }

    @Test func looseFilePermissionsAreTightenedOnRead() throws {
        try withDir { dir in
            let file = KeyFileStore(url: dir.appendingPathComponent("keys.json"))
            try KeyBundle.store(["google": "AIzaFAKE1234"], in: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.url.path)
            _ = try file.get(KeyBundle.account)
            #expect(try perms(file.url) == 0o600)
        }
    }

    /// Review D4 #2: the file is replaced atomically (temp file in the same folder, then rename) and stays 0600.
    @Test func aRewriteStaysPrivateAndLeavesNoTempFile() throws {
        try withDir { dir in
            let file = KeyFileStore(url: dir.appendingPathComponent("keys.json"))
            try KeyBundle.store(["google": "AIzaFAKE1234"], in: file)
            try KeyBundle.store(both, in: file)
            #expect(try perms(file.url) == 0o600)
            #expect(try KeyBundle.load(file) == both)
            #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["keys.json"])
        }
    }

    @Test func theKeyFileIsLeftOutOfBackups() throws {
        try withDir { dir in
            let file = KeyFileStore(url: dir.appendingPathComponent("keys.json"))
            try KeyBundle.store(["google": "AIzaFAKE1234"], in: file)
            let v = try file.url.resourceValues(forKeys: [.isExcludedFromBackupKey])
            #expect(v.isExcludedFromBackup == true)
        }
    }

    // MARK: Home notice

    @Test func anUnreadableFileOrAPendingMoveShowsTheNoticeNotNeedsAKey() {
        for access in [Secrets.KeychainAccess.unreadable, .pending] {
            let s = HomeState(mic: .granted, spoken: [.en, .uz], provider: .google, hasKey: { _ in false }, verified: { _ in false },
                              keychain: access)
            #expect(s.keychainNotice)
            #expect(s.title != .needsKey)
        }
    }
}
