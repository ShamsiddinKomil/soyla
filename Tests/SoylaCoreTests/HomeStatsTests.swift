import Testing
import Foundation
@testable import SoylaCore

@Suite struct HomeStatsTests {
    static let noon = Date(timeIntervalSince1970: 1_792_000_000)

    func run(_ offset: TimeInterval, text: String?, wait: Double?, error: String? = nil) -> RunRecord {
        let ts = ISO8601DateFormatter().string(from: Self.noon.addingTimeInterval(offset))
        return RunRecord(runId: "r\(offset)", ts: ts, source: "live", phraseId: nil, model: "m", cleanup: false, cleanupModel: nil,
                         languageHint: nil, prewarm: false,
                         audio: .init(format: "wav", bytes: 1, b64Bytes: 1, durationSec: 1, sampleRate: 16000, file: nil),
                         timelineMs: wait.map { ["release_to_paste": $0] } ?? [:], net: nil, usage: nil, cleanupUsage: nil,
                         rawText: text, cleanText: nil, error: error, providerMeta: nil)
    }

    @Test func countsWordsAndMedian() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let runs = [
            run(0, text: "one two three", wait: 1000),
            run(60, text: "  four   five\nsix seven ", wait: 3000),
            run(120, text: "eight", wait: 2000),
            run(180, text: "failed", wait: 500, error: "boom"),     // errors are excluded
            run(-3 * 86_400, text: "old old old", wait: 9000),        // other day excluded
        ]
        let s = TodayStats.compute(runs, now: Self.noon, calendar: cal)
        #expect(s.count == 3)
        #expect(s.words == 8)
        #expect(s.medianWaitMs == 2000)
        #expect(s.waitText == "2.0 s")
    }

    @Test func evenMedianAndEmpty() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let two = TodayStats.compute([run(0, text: "a", wait: 1000), run(1, text: "b", wait: 2000)], now: Self.noon, calendar: cal)
        #expect(two.medianWaitMs == 1500)
        let none = TodayStats.compute([], now: Self.noon, calendar: cal)
        #expect(none == TodayStats() && none.waitText == "–")
    }

    @Test func bannerText() {
        let ok = PermissionState(mic: .granted, ax: true, inputMonitoring: true)
        #expect(!SetupBanner(permissions: ok, keyMissing: false).isNeeded)
        let two = SetupBanner(permissions: PermissionState(mic: .granted, ax: false, inputMonitoring: false), keyMissing: true)
        #expect(two.text == "Soyla needs 2 permissions and an API key" && two.target == .permissions)
        let one = SetupBanner(permissions: PermissionState(mic: .denied, ax: true, inputMonitoring: true), keyMissing: false)
        #expect(one.text == "Soyla needs 1 permission")
        let key = SetupBanner(permissions: ok, keyMissing: true)
        #expect(key.text == "Soyla needs an API key" && key.target == .apiKeys)
    }
}
