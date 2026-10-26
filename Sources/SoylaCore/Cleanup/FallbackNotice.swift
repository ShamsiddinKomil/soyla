import Foundation

// D26 (c) / BL-03: when the correction pass was asked for but raw was pasted, the run says so (`cleanupFallback`, a
// reason class) and the pill says so once a day. History always shows it. Never any dictated text here.

extension CleanupOutcome {
    /// Why raw was pasted although cleanup was wanted: the guard's class, or "error". nil for Raw, a skipped short text
    /// or a provider cooldown (cleanup was never tried) and for an accepted cleanup.
    public var fallbackReason: String? {
        switch status {
        case .guarded: return guardReason?.rawValue
        case .error: return "error"
        default: return nil
        }
    }

    /// The pipeline's writes after the text stage in one call (the orchestrator is at its line limit).
    public func apply(to record: inout RunRecord) {
        record.cleanupUsage = usage
        record.providerMeta = (record.providerMeta ?? [:]).merging(meta) { _, b in b }
        if let e = error { record.error = e }               // raw text is still pasted; logged only
        record.cleanupFallback = fallbackReason
    }
}

public enum FallbackNotice {
    /// English as built; `PillCopy` swaps in Uzbek or Russian at display time.
    static let skippedCard = PillFailure(kind: .info, title: "Pasted as heard (cleanup skipped)", hint: "")

    static let dayKey = "cleanupNoticeDay"
    private static var appDefaults: UserDefaults { UserDefaults(suiteName: Soyla.defaultsSuite) ?? .standard }

    /// The note for a run that fell back, or nil: no fallback, or one was already shown today (local calendar day).
    /// Returning the card records the day, so a run that was cancelled or replaced (`live` false) records nothing.
    public static func card(for reason: String?, live: Bool = true, now: Date = Date(), defaults: UserDefaults? = nil,
                            calendar: Calendar = .current) -> PillFailure? {
        guard reason != nil, live else { return nil }          // `live`: this run is still the current one
        let d = defaults ?? appDefaults
        let c = calendar.dateComponents([.year, .month, .day], from: now)
        let today = "\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)"
        guard d.string(forKey: dayKey) != today else { return nil }
        d.set(today, forKey: dayKey)
        return skippedCard
    }
}
