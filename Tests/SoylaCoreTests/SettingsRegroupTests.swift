import Testing
import Foundation
@testable import SoylaCore

@Suite struct SettingsRegroupTests {
    @Test func percentiles() {
        let v = (1...10).map(Double.init)
        #expect(LatencyStats.percentile(v, 0.5) == 6)
        #expect(LatencyStats.percentile(v, 0.9) == 9)
        #expect(LatencyStats.percentile([], 0.5) == nil)
    }

    @Test func modelNamesAreHumanAndRecommendedIsTheDefault() {
        #expect(ModelNames.name("google/gemini-3.5-flash") == "Gemini 3.5 Flash")
        #expect(ModelNames.name("gemini-3.5-flash") == "Gemini 3.5 Flash")
        for p in ProviderKind.allCases {
            #expect(ModelNames.curated(p).contains(p.defaultSTTModel))
            #expect(ModelNames.title(p.defaultSTTModel, provider: p).hasSuffix("(recommended)"))
        }
    }
}
