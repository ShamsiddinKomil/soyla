import AppKit

// D26 (c) / BL-03: the correction pass is Raw or Light, one menu away. Off is only called Raw on screen; the stored
// value and the `.off` case are unchanged.

enum CleanupChoice {
    static let levels: [CleanupLevel] = [.off, .light]

    /// The free engine has no correction pass (the Dictation page hides the row for the same reason).
    static func offered(for provider: ProviderKind) -> Bool { provider != .apple }

    static func name(_ level: CleanupLevel, _ language: UILanguage) -> String {
        let t = AppStrings.for(language)
        return level == .off ? t.cleanOff : t.cleanLight
    }

    /// "Correction pass: Raw": the menu item that opens the choice, and each row of the pill's right-click menu.
    static func menuTitle(_ level: CleanupLevel, _ language: UILanguage) -> String {
        "\(AppStrings.for(language).dClean): \(name(level, language))"
    }

    static func rows(current: CleanupLevel, _ language: UILanguage) -> [(level: CleanupLevel, title: String, checked: Bool)] {
        levels.map { ($0, name($0, language), $0 == current) }
    }

    /// Persists through the settings store; its change notice reaches Settings and the pill.
    static func set(_ level: CleanupLevel, in store: SettingsStore = .shared) {
        store.update { $0.cleanupLevel = level }
    }

    /// The pill's right-click rows (empty on the free engine). A checkmark marks the current level.
    @MainActor static func pillItems(store: SettingsStore, language: UILanguage) -> [NSMenuItem] {
        let s = store.current
        guard offered(for: s.provider) else { return [] }
        return levels.map { level in
            let it = ClosureMenuItem(menuTitle(level, language)) { set(level, in: store) }
            it.state = level == s.cleanupLevel ? .on : .off
            return it
        }
    }
}

/// The status menu's "Correction pass: Raw ▸" item with its Raw / Light submenu.
@MainActor
final class CleanupMenu: NSObject {
    let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let submenu = NSMenu()

    override init() {
        super.init()
        submenu.autoenablesItems = false
        for i in CleanupChoice.levels.indices {
            let it = NSMenuItem(title: "", action: #selector(pick(_:)), keyEquivalent: "")
            it.tag = i; it.target = self
            submenu.addItem(it)
        }
        item.submenu = submenu
    }

    /// Re-read at every menu open and language change.
    func refresh(_ s: Settings) {
        item.isHidden = !CleanupChoice.offered(for: s.provider)
        item.title = CleanupChoice.menuTitle(s.cleanupLevel, s.uiLanguage)
        for (it, row) in zip(submenu.items, CleanupChoice.rows(current: s.cleanupLevel, s.uiLanguage)) {
            it.title = row.title
            it.state = row.checked ? .on : .off
        }
    }

    @objc private func pick(_ sender: NSMenuItem) {
        guard CleanupChoice.levels.indices.contains(sender.tag) else { return }
        CleanupChoice.set(CleanupChoice.levels[sender.tag])
    }
}
