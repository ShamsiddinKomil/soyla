import CryptoKit
import Foundation
import Testing
@testable import SoylaCore

/// One-click update. Fake repos and data only.
@Suite struct SelfUpdateTests {
    private func release(_ assets: String, html: String = "https://github.com/o/r/releases/tag/v0.2.1") -> Data {
        Data(#"{"tag_name":"v0.2.1","html_url":"\#(html)","body":"Soyla 0.2.1\n## What's new\n- **Faster** paste\n- One dialog","assets":[\#(assets)]}"#.utf8)
    }
    private let good = #"{"name":"Soyla-v0.2.1.zip","browser_download_url":"https://github.com/o/r/releases/download/v0.2.1/Soyla-v0.2.1.zip"},{"name":"Soyla-v0.2.1.zip.sha256","browser_download_url":"https://github.com/o/r/releases/download/v0.2.1/Soyla-v0.2.1.zip.sha256"}"#

    @Test func assetsComeOnlyFromThisReposReleases() throws {
        let r = try #require(UpdateCheck.parse(release(good), repo: "o/r"))
        #expect(r.zip?.lastPathComponent == "Soyla-v0.2.1.zip" && r.sha256 != nil)
        #expect(r.notes.contains("Faster"))
        let foreign = good.replacingOccurrences(of: "https://github.com/o/r/", with: "https://evil.example/o/r/")
        #expect(UpdateCheck.parse(release(foreign), repo: "o/r")?.zip == nil)          // page still offered, no one-click
        let otherRepo = good.replacingOccurrences(of: "github.com/o/r/", with: "github.com/x/r/")
        #expect(UpdateCheck.parse(release(otherRepo), repo: "o/r")?.zip == nil)
        #expect(UpdateCheck.parse(release(""), repo: "o/r")?.zip == nil)               // no assets
        let noSha = #"{"name":"Soyla-v0.2.1.zip","browser_download_url":"https://github.com/o/r/releases/download/v0.2.1/Soyla-v0.2.1.zip"}"#
        #expect(UpdateCheck.parse(release(noSha), repo: "o/r")?.zip == nil)            // no checksum, no install
    }

    @Test func devOverrideAcceptsOnlyItsOwnHost() throws {
        let ov = URL(string: "http://127.0.0.1:8765")!
        let local = good.replacingOccurrences(of: "https://github.com/o/r/releases/download", with: "http://127.0.0.1:8765/dl")
        let r = try #require(UpdateCheck.parse(release(local, html: "http://127.0.0.1:8765/page"), repo: "o/r", override: ov))
        #expect(r.zip != nil)
        #expect(UpdateCheck.parse(release(good, html: "http://127.0.0.1:8765/page"), repo: "o/r", override: ov)?.zip == nil)
        #expect(!UpdateCheck.isAllowedAsset(URL(string: "http://127.0.0.1:9999/x.zip")!, repo: "o/r", override: ov))
    }

    @Test func dailyCheck() {
        let now = Date()
        #expect(UpdateCheck.isDue(enabled: true, last: now.addingTimeInterval(-25 * 3600), now: now))
        #expect(!UpdateCheck.isDue(enabled: true, last: now.addingTimeInterval(-23 * 3600), now: now))
    }

    @Test func checksumMustMatchTheShasumLine() {
        let d = Data("FAKE zip bytes".utf8)
        let hex = SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
        #expect(SelfUpdate.checksumMatches(d, shasumFile: "\(hex)  Soyla-v0.2.1.zip\n"))
        #expect(SelfUpdate.checksumMatches(d, shasumFile: hex.uppercased()))
        #expect(!SelfUpdate.checksumMatches(d + Data([0]), shasumFile: "\(hex)  Soyla-v0.2.1.zip"))
        #expect(!SelfUpdate.checksumMatches(d, shasumFile: ""))
    }

    @Test func newBundleMustBeSoylaAtTheReleasedNewerVersion() {
        let ok: [String: Any] = ["CFBundleIdentifier": "ai.soyla.app", "CFBundleShortVersionString": "0.2.1"]
        #expect(SelfUpdate.plistProblem(ok, tag: "v0.2.1", current: "0.2.0") == nil)
        #expect(SelfUpdate.plistProblem(["CFBundleIdentifier": "com.fake.app", "CFBundleShortVersionString": "0.2.1"], tag: "v0.2.1", current: "0.2.0") == .notSoyla)
        #expect(SelfUpdate.plistProblem(ok, tag: "v0.2.2", current: "0.2.0") == .wrongVersion)   // zip doesn't match the tag
        #expect(SelfUpdate.plistProblem(ok, tag: "v0.2.1", current: "0.2.1") == .wrongVersion)   // not newer
        #expect(SelfUpdate.plistProblem(ok, tag: "v0.2.1", current: "0.3.0") == .wrongVersion)   // no downgrade
    }

    @Test func adHocBuildsDoNotSelfUpdate() {
        #expect(SelfUpdate.isCertificateBased(#"identifier "ai.soyla.app" and certificate leaf = H"0123""#))
        #expect(!SelfUpdate.isCertificateBased(#"cdhash H"0123""#))
    }

    @Test func unsignedBundleFailsTheSignatureCheck() throws {
        // A folder that is not signed at all must never satisfy a certificate requirement.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("soyla-fake-\(UUID().uuidString).app")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var req: SecRequirement?
        #expect(SecRequirementCreateWithString(#"identifier "ai.soyla.app" and certificate leaf = H"0000000000000000000000000000000000000000""# as CFString, [], &req) == errSecSuccess)
        #expect(!SelfUpdate.satisfies(dir, requirement: try #require(req)))
    }

    @Test @MainActor func buttonAndNotes() throws {
        let u = Updater()
        #expect(!u.showsButton)
        u.offer(try #require(UpdateCheck.parse(release(good), repo: "o/r")))
        #expect(u.showsButton && u.buttonTitle == "Update to 0.2.1" && u.state == .available)
        #expect(u.notesPreview == "Soyla 0.2.1\n• Faster paste\n• One dialog")
        u.dismiss()
        #expect(!u.showsButton)
        let busy = Updater(); busy.isBusy = { true }
        busy.offer(try #require(UpdateCheck.parse(release(good), repo: "o/r")))
        busy.install()
        #expect(busy.state == .failed("Finish your dictation first, then click Update again."))
    }

    @Test func autoInstallIsOffByDefault() throws {
        #expect(Settings().autoInstallUpdates == false)
        #expect(try JSONDecoder().decode(Settings.self, from: Data("{}".utf8)).autoInstallUpdates == false)
        #expect(try JSONDecoder().decode(Settings.self, from: Data(#"{"autoInstallUpdates": true}"#.utf8)).autoInstallUpdates)
    }

    @Test @MainActor func closedCardComesBackLater() throws {
        let u = Updater()
        u.offer(try #require(UpdateCheck.parse(release(good), repo: "o/r")))
        let now = Date()
        u.dismiss(now: now)
        #expect(!u.isVisible(now: now.addingTimeInterval(3600)))
        #expect(u.isVisible(now: now.addingTimeInterval(Updater.snooze + 1)))
    }

    @Test @MainActor func autoInstallWaitsForAnIdleSoylaAndNeedsTheSwitch() throws {
        let rel = try #require(UpdateCheck.parse(release(good), repo: "o/r"))
        #expect(!Updater.shouldAutoInstall(enabled: false, release: rel, busy: false))
        #expect(!Updater.shouldAutoInstall(enabled: true, release: rel, busy: true))
        #expect(Updater.shouldAutoInstall(enabled: true, release: rel, busy: false))
        #expect(!Updater.shouldAutoInstall(enabled: true, release: nil, busy: false))
        var pageOnly = rel; pageOnly.zip = nil
        #expect(!Updater.shouldAutoInstall(enabled: true, release: pageOnly, busy: false))   // can't one-click it
    }
}

/// The detached install script re-checks the signature at the moment of the swap and never swaps under a live app.
@Suite struct InstallScriptTests {
    let s = SelfUpdate.installScript

    @Test func verifiesSignatureBeforeSwap() throws {
        let verify = try #require(s.range(of: "codesign --verify --strict --deep -R=\"$5\" \"$NEW\""))
        let swap = try #require(s.range(of: "mv \"$TARGET\" \"$OLD\""))
        #expect(verify.lowerBound < swap.lowerBound)
    }

    @Test func abortsWhileOldAppStillRuns() throws {
        let alive = try #require(s.range(of: "if kill -0 \"$PID\" 2>/dev/null; then"))
        let swap = try #require(s.range(of: "mv \"$TARGET\" \"$OLD\""))
        #expect(alive.lowerBound < swap.lowerBound)
    }
}
