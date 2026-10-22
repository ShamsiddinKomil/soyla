import Testing
@testable import SoylaCore

/// Developer switches (env keys, SOYLA_HOME, SOYLA_KEYCHAIN_SERVICE, SOYLA_SETTINGS_SUITE, SOYLA_UPDATE_API,
/// SOYLA_LIVE_DEBUG, .env.local) must not work in an installed app: another process could relaunch Soyla with its own
/// key, data folder or update server and inherit the app's microphone and Accessibility grants.
@Suite struct DevOverridesTests {
    @Test func cliAndTestsKeepOverrides() {
        #expect(DevOverrides.allowed(isAppBundle: false, devBuild: false))
    }

    @Test func installedAppIgnoresOverrides() {
        #expect(!DevOverrides.allowed(isAppBundle: true, devBuild: false))
    }

    @Test func devBundleKeepsOverridesForCaptures() {
        #expect(DevOverrides.allowed(isAppBundle: true, devBuild: true))
    }

    @Test func filteredEnvironmentIsEmptyWhenNotAllowed() {
        let env = ["OPENROUTER_API_KEY": "sk-or-v1-FAKE", "SOYLA_HOME": "/tmp/x", "PATH": "/usr/bin"]
        #expect(DevOverrides.environment(env, allowed: false).isEmpty)
        #expect(DevOverrides.environment(env, allowed: true) == env)
    }

    @Test func runnerIsNotAnAppBundle() {
        #expect(DevOverrides.enabled)   // the swift-testing runner is not a .app, so tests keep their switches
    }
}
