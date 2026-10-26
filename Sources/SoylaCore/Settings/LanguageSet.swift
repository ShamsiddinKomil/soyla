import Foundation

/// D26(b) · BL-04: the languages the user speaks ("my languages"). Stored as `Settings.languages` (ISO-639-1 codes,
/// canonical order uz · ru · en, never empty). `Settings.languageHint` stays the optional primary ("Mainly speak").
/// Cloud only: the free engine is English and ignores the set.
public enum LanguageSet {
    /// Every code the set can hold, in display and prompt order.
    public static let all = ["uz", "ru", "en"]
    public static let defaultSet = all

    /// Known codes only, lowercased, deduplicated, in canonical order; nil or nothing left → the default set.
    public static func sanitize(_ codes: [String]?) -> [String] {
        let wanted = Set((codes ?? []).map { $0.lowercased() })
        let out = all.filter { wanted.contains($0) }
        return out.isEmpty ? defaultSet : out
    }

    public static func isDefault(_ codes: [String]) -> Bool { sanitize(codes) == defaultSet }

    /// The set (and a forced language) only reaches the cloud engines; the free engine is English and ignores it.
    public static func applies(_ s: Settings) -> Bool { s.provider != .apple }

    /// The pill's chip while recording ("RU", "UZ·EN"). nil for the default set (most users never see it) and on the
    /// free engine, where the set doesn't apply.
    public static func chip(_ s: Settings) -> String? {
        guard applies(s), !isDefault(s.languages) else { return nil }
        return sanitize(s.languages).map { $0.uppercased() }.joined(separator: "·")
    }

    /// The settings for "Retry as <language>": that one language, also as the primary. nil or an unknown code keeps
    /// the saved set ("My languages").
    public static func forced(_ s: Settings, language: String?) -> Settings {
        guard let l = language?.lowercased(), all.contains(l) else { return s }
        var out = s
        out.languages = [l]
        out.languageHint = l
        return out
    }
}

public extension Settings {
    /// A "My languages" checkbox. The last ticked language can't be unticked; unticking the primary clears it.
    mutating func toggleLanguage(_ code: String) {
        let c = code.lowercased()
        guard LanguageSet.all.contains(c) else { return }
        if languages.contains(c) {
            guard languages.count > 1 else { return }
            languages = LanguageSet.sanitize(languages.filter { $0 != c })
            if languageHint?.lowercased() == c { languageHint = nil }
        } else {
            languages = LanguageSet.sanitize(languages + [c])
        }
    }
}
