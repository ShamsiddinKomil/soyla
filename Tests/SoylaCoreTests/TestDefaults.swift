import Foundation

/// Removes a throwaway UserDefaults suite. `removePersistentDomain` alone leaves an empty
/// plist in ~/Library/Preferences on every run, so the file goes too.
func dropTestDomain(_ name: String) {
    UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
    CFPreferencesAppSynchronize(name as CFString)
    let file = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Preferences/\(name).plist")
    try? FileManager.default.removeItem(at: file)
}
