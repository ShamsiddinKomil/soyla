import Foundation

/// Developer switches: `OPENROUTER_API_KEY`/`GEMINI_API_KEY`, `SOYLA_HOME`, `SOYLA_KEYCHAIN_SERVICE`,
/// `SOYLA_SETTINGS_SUITE`, `SOYLA_UPDATE_API` (+ `devUpdateAPI`), `SOYLA_LIVE_DEBUG` and `.env.local`.
/// The CLI and tests honour them. An installed Soyla.app ignores them unless it was bundled with `SOYLA_DEV=1`
/// (screenshots, update tests), so another process can't relaunch the app with its own key, data folder or update
/// server and borrow the app's microphone and Accessibility grants.
public enum DevOverrides {
    static func allowed(isAppBundle: Bool, devBuild: Bool) -> Bool { !isAppBundle || devBuild }

    static func environment(_ env: [String: String], allowed: Bool) -> [String: String] { allowed ? env : [:] }

    static var devBuild: Bool {
        #if SOYLA_DEV_OVERRIDES
        return true
        #else
        return false
        #endif
    }

    /// The app binary inside Soyla.app counts as the app even when started from a shell.
    public static let enabled = allowed(isAppBundle: Bundle.main.bundleURL.pathExtension == "app", devBuild: devBuild)

    /// The process environment if switches are allowed, otherwise empty.
    public static var environment: [String: String] { environment(ProcessInfo.processInfo.environment, allowed: enabled) }
}
