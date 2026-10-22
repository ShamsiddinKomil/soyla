import Testing
import Foundation
@testable import SoylaCore

/// A1: Keychain round-trip uses a unique test service and deletes its items afterwards.
@Suite(.serialized) struct KeychainTests {
    static let fake = "sk-or-v1-FAKE-TEST-KEY-0000"

    private func withStore(_ body: (KeychainStore) throws -> Void) throws {
        let store = KeychainStore(service: "ai.soyla.test.\(UUID().uuidString)")
        defer { for p in KeyProvider.allCases { try? store.delete(p.rawValue) } }
        try body(store)
        for p in KeyProvider.allCases { try store.delete(p.rawValue) }
        for p in KeyProvider.allCases { #expect(try store.get(p.rawValue) == nil) }
    }

    @Test func roundTrip() throws {
        try withStore { kc in
            #expect(try kc.get("openrouter") == nil)
            try kc.set(Self.fake, for: "openrouter")
            #expect(try kc.get("openrouter") == Self.fake)
            try kc.set(Self.fake + "-v2", for: "openrouter")          // update path
            #expect(try kc.get("openrouter") == Self.fake + "-v2")
            try kc.delete("openrouter")
            #expect(try kc.get("openrouter") == nil)
            try kc.delete("openrouter")                                // deleting a missing item is fine
        }
    }

    @Test func lookupOrderEnvThenKeychainThenFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("soyla-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let envFile = dir.appendingPathComponent(".env.local")
        try "OPENROUTER_API_KEY=sk-or-v1-FAKE-FILE\nGEMINI_API_KEY=AIzaFAKE-FILE\n".write(to: envFile, atomically: true, encoding: .utf8)

        try withStore { kc in
            // file only
            #expect(Secrets.lookup(.openRouter, env: [:], keychain: kc, envFile: envFile)?.source == .envFile)
            // keychain beats file
            try kc.set("sk-or-v1-FAKE-KC", for: KeyProvider.openRouter.rawValue)
            let k = Secrets.lookup(.openRouter, env: [:], keychain: kc, envFile: envFile)
            #expect(k?.value == "sk-or-v1-FAKE-KC" && k?.source == .keychain)
            // env beats keychain
            let e = Secrets.lookup(.openRouter, env: ["OPENROUTER_API_KEY": " sk-or-v1-FAKE-ENV\n"], keychain: kc, envFile: envFile)
            #expect(e?.value == "sk-or-v1-FAKE-ENV" && e?.source == .environment)
            // providers are independent
            #expect(Secrets.lookup(.google, env: [:], keychain: kc, envFile: envFile)?.source == .envFile)
            #expect(Secrets.lookup(.custom, env: [:], keychain: kc, envFile: envFile) == nil)
            #expect(Secrets.lookup(.custom, env: [:], keychain: kc, envFile: nil) == nil)
        }
    }

    @Test func fingerprintBindsURLAndKey() {
        let a = Secrets.fingerprintHex(baseURL: "https://openrouter.ai/api/v1", key: Self.fake)
        #expect(a.count == 64)
        #expect(a == Secrets.fingerprintHex(baseURL: "https://openrouter.ai/api/v1", key: Self.fake))
        #expect(a != Secrets.fingerprintHex(baseURL: "https://example.invalid/v1", key: Self.fake))
        #expect(a != Secrets.fingerprintHex(baseURL: "https://openrouter.ai/api/v1", key: Self.fake + "x"))
        #expect(!a.contains("FAKE"))
    }

    @Test func keyCheckRequests() throws {
        let o = try #require(KeyCheck.request(.openRouter, key: Self.fake))
        #expect(o.url?.absoluteString == "https://openrouter.ai/api/v1/key")
        #expect(o.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.fake)")
        let g = try #require(KeyCheck.request(.google, key: "AIzaFAKE"))
        #expect(g.url?.host == "generativelanguage.googleapis.com")
        #expect(g.url?.absoluteString.contains("AIzaFAKE") == false)    // key in a header, never in the URL
        #expect(g.value(forHTTPHeaderField: "x-goog-api-key") == "AIzaFAKE")
        #expect(KeyCheck.request(.custom, key: "x") == nil)
    }

    @Test func keyCheckInterpret() {
        let or1 = KeyCheck.interpret(.openRouter, status: 200,
            body: Data(#"{"data":{"label":"sk-or-v1-abc...xyz","usage":1.5,"limit":10,"limit_remaining":8.5}}"#.utf8))
        #expect(or1 == .init(ok: true, message: "OK · $8.50 credit left"))       // masked-key label hidden
        let or2 = KeyCheck.interpret(.openRouter, status: 200,
            body: Data(#"{"data":{"label":"laptop","usage":0,"limit":null,"limit_remaining":null}}"#.utf8))
        #expect(or2 == .init(ok: true, message: "OK · laptop · no credit limit"))
        #expect(KeyCheck.interpret(.openRouter, status: 401, body: Data()).ok == false)
        let g = KeyCheck.interpret(.google, status: 200, body: Data(#"{"models":[{"name":"models/a"},{"name":"models/b"}]}"#.utf8))
        #expect(g == .init(ok: true, message: "OK, 2 models"))
        let bad = KeyCheck.interpret(.google, status: 400,
            body: Data(#"{"error":{"code":400,"message":"API key not valid. Please pass a valid API key.","status":"INVALID_ARGUMENT"}}"#.utf8))
        #expect(bad.ok == false && bad.message.hasPrefix("Key rejected"))
        #expect(KeyCheck.interpret(.google, status: 500, body: Data()).message == "HTTP 500 — try again later")
    }
}

@Suite struct KeyCardTests {
    // Obviously fake keys only.
    let fakeOR = "sk-or-v1-" + String(repeating: "0", count: 40)
    let fakeGoogle = "AIza" + String(repeating: "x", count: 35)

    @Test func pasteMistakesAreCaughtBeforeSaving() {
        #expect(KeyShape.problem("", for: .openRouter)?.contains("empty") == true)
        #expect(KeyShape.problem("Dear team, here is the key", for: .openRouter)?.contains("spaces") == true)
        #expect(KeyShape.problem(fakeGoogle, for: .openRouter)?.contains("Google AI Studio key") == true)
        // AI Studio "auth keys" (since May 2026) start with AQ.: also another provider's key on the OpenRouter card.
        #expect(KeyShape.problem("AQ.FAKE-not-a-real-key-0123456789", for: .openRouter)?.contains("Google AI Studio key") == true)
        #expect(KeyShape.problem("AQ.FAKE-not-a-real-key-0123456789", for: .google) == nil)
        #expect(KeyShape.problem(fakeOR, for: .google)?.contains("OpenRouter key") == true)
        #expect(KeyShape.problem("sk-or-123", for: .openRouter)?.contains("too short") == true)
        #expect(KeyShape.problem(fakeOR, for: .openRouter) == nil)
        #expect(KeyShape.problem(fakeGoogle, for: .google) == nil)
        #expect(KeyShape.problem("local", for: .custom) == nil)
    }

    @MainActor @Test func statusSaysWhereThingsStand() {
        typealias R = APIKeysModel.Row
        #expect(APIKeysModel.status(R(), provider: .openRouter) == .empty(problem: nil))
        #expect(APIKeysModel.status(R(message: "The clipboard is empty.", messageOK: false), provider: .openRouter) == .empty(problem: "The clipboard is empty."))
        #expect(APIKeysModel.status(R(masked: "sk-…0000", testing: true), provider: .openRouter) == .checking)
        #expect(APIKeysModel.status(R(masked: "sk-…0000", verified: true, message: "OK · $4.20 credit left", messageOK: true), provider: .openRouter)
                == .connected(detail: "$4.20 credit left"))
        #expect(APIKeysModel.status(R(masked: "sk-…0000", message: "Key rejected — check", messageOK: false, rejected: true), provider: .openRouter) == .rejected)
        #expect(APIKeysModel.status(R(masked: "sk-…0000", message: "Network error — offline", messageOK: false), provider: .openRouter)
                == .unchecked(reason: "Network error — offline"))
        #expect(APIKeysModel.status(R(masked: "loc…al"), provider: .custom) == .unchecked(reason: nil))
    }

    @Test func rejectedIsOnlyTheProvidersNo() {
        #expect(KeyCheck.interpret(.openRouter, status: 401, body: Data()).rejected)
        #expect(!KeyCheck.interpret(.openRouter, status: 503, body: Data()).rejected)
    }
}

/// One Keychain item for all keys, so an update asks for the Mac password once, not once per key (owner, 2026-10-16).
@Suite(.serialized) struct KeyBundleTests {
    private func withStore(_ body: (KeychainStore) throws -> Void) throws {
        let store = KeychainStore(service: "ai.soyla.test.\(UUID().uuidString)")
        defer { for a in KeyProvider.allCases.map(\.rawValue) + [KeyBundle.account] { try? store.delete(a) } }
        try body(store)
    }

    @Test func encodeDropsEmptyAndDecodeSurvivesGarbage() {
        let s = KeyBundle.encode(["openrouter": "sk-or-v1-FAKE", "google": "", "custom": "local"])
        #expect(KeyBundle.decode(s) == ["openrouter": "sk-or-v1-FAKE", "custom": "local"])
        #expect(KeyBundle.decode("not json") == [:])
        #expect(KeyBundle.decode(#"{"google": 3, "openrouter": "sk-FAKE"}"#) == ["openrouter": "sk-FAKE"])
    }

    @Test func oneItemHoldsEveryKey() throws {
        try withStore { kc in
            #expect(try KeyBundle.load(kc) == [:])
            try KeyBundle.store(["openrouter": "sk-or-v1-FAKE", "google": "AIzaFAKE"], in: kc)
            #expect(try KeyBundle.load(kc) == ["openrouter": "sk-or-v1-FAKE", "google": "AIzaFAKE"])
            #expect(try kc.get("openrouter") == nil && kc.get("google") == nil)   // no per-key items
            try KeyBundle.store([:], in: kc)                                      // last key removed → item gone
            #expect(try kc.get(KeyBundle.account) == nil)
        }
    }

    @Test func oldPerKeyItemsMoveIntoTheBundleOnce() throws {
        try withStore { kc in
            try kc.set("sk-or-v1-FAKE-OLD", for: "openrouter")
            try kc.set("AIzaFAKE-OLD", for: "google")
            #expect(try KeyBundle.load(kc) == ["openrouter": "sk-or-v1-FAKE-OLD", "google": "AIzaFAKE-OLD"])
            #expect(try kc.get("openrouter") == nil && kc.get("google") == nil)   // old items deleted
            #expect(try KeyBundle.load(kc) == ["openrouter": "sk-or-v1-FAKE-OLD", "google": "AIzaFAKE-OLD"])
        }
    }

    @Test func bundleWinsOverLeftoverOldItems() throws {
        try withStore { kc in
            try KeyBundle.store(["google": "AIzaFAKE-NEW"], in: kc)
            try kc.set("AIzaFAKE-STALE", for: "google")
            #expect(try KeyBundle.load(kc) == ["google": "AIzaFAKE-NEW"])
        }
    }

    @Test func saveMergesWithTheOtherKeysAndRefusesWhileTheReadIsPending() throws {
        let c = KeyCache()
        for p in KeyProvider.allCases { c.set(p.rawValue, nil) }
        c.set("google", "AIzaFAKE")
        #expect(try KeyBundle.merged(cache: c, set: "openrouter", to: "sk-or-v1-FAKE") == ["google": "AIzaFAKE", "openrouter": "sk-or-v1-FAKE"])
        #expect(try KeyBundle.merged(cache: c, set: "google", to: nil) == [:])
        // While macOS still asks (or after Deny) the other keys are unknown: saving would erase them.
        let waiting = KeyCache(); waiting.begin("google")
        #expect(throws: SoylaError.self) { try KeyBundle.merged(cache: waiting, set: "openrouter", to: "sk-or-v1-FAKE") }
    }
}
