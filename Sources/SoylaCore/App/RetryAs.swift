import Foundation

extension DictationPipeline {
    /// History retry settings (D26b): another model and/or one forced language ("Retry as Russian"); `language` nil
    /// keeps the saved set ("My languages"). Pure, so the menu's effect is testable without the network.
    nonisolated static func historyRetrySettings(_ current: Settings, model: String?, language: String?) -> Settings {
        var s = LanguageSet.forced(current, language: language)
        if let model { s.sttModel = model }
        return s
    }
}
