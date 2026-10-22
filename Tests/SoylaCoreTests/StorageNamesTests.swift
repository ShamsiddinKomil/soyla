import Testing
import Foundation
@testable import SoylaCore

@Suite("Storage names per bundle id (side-by-side Soyla Dev)")
struct StorageNamesTests {
    @Test func releaseKeepsTodaysNames() {
        let n = Soyla.storageNames(bundleID: "ai.soyla.app")
        #expect(n.defaultsSuite == "ai.soyla.settings")
        #expect(n.keychainService == "ai.soyla.app")
        #expect(n.supportFolder == "Soyla")
        #expect(n.isRelease)
    }

    @Test func cliAndTestsKeepTodaysNames() {
        for id in [nil, "", "com.apple.dt.xctest.tool", "com.example.other"] as [String?] {
            #expect(Soyla.storageNames(bundleID: id) == Soyla.storageNames(bundleID: "ai.soyla.app"))
        }
        // A bare prefix with no variant must not produce a half-empty name.
        #expect(Soyla.storageNames(bundleID: "ai.soyla.").isRelease)
    }

    @Test func devVariantIsIsolated() {
        let n = Soyla.storageNames(bundleID: "ai.soyla.dev")
        #expect(n.defaultsSuite == "ai.soyla.dev.settings")
        #expect(n.keychainService == "ai.soyla.app.dev")
        #expect(n.supportFolder == "Soyla Dev")
        #expect(!n.isRelease)
        #expect(n.defaultsSuite != "ai.soyla.dev")   // a suite equal to the bundle id silently does not persist
    }

    @Test func supportFolderFollowsVariant() {
        let home = URL(fileURLWithPath: "/Users/fake")
        let rel = SoylaPaths.resolve(env: [:], home: home, supportFolder: "Soyla")
        let dev = SoylaPaths.resolve(env: [:], home: home, supportFolder: "Soyla Dev")
        #expect(rel.root.path == "/Users/fake/Library/Application Support/Soyla")
        #expect(dev.root.path == "/Users/fake/Library/Application Support/Soyla Dev")
        #expect(SoylaPaths.resolve(env: ["SOYLA_HOME": "/x"], home: home, supportFolder: "Soyla Dev").devLayout)
    }
}
