import Testing
import Foundation
@testable import SoylaCore

// D7 (owner, 2026-10-26): a saved plain-http address that isn't this Mac gets its own card, not "odd reply / Retry".
@Suite struct InsecureEndpointTests {
    @Test func aRemoteHTTPAddressThrowsItsOwnError() {
        do {
            _ = try ProviderFactory.customBase("http://studio.local:8080/v1")
            Issue.record("expected an error")
        } catch let e as SoylaError {
            guard case .insecureEndpoint = e else { Issue.record("wrong error: \(e)"); return }
        } catch { Issue.record("wrong error type") }
    }

    @Test func itsCardSaysHTTPSAndOffersNoRetry() {
        let c = PillFailure.from(SoylaError.insecureEndpoint, stage: "transcribe")
        #expect(c.title == "This server needs https" && !c.canRetry)
        #expect(c.localized(.uz).title != c.title && c.localized(.ru).title != c.title)
        #expect(c.localized(.uz).hint != c.hint && c.localized(.ru).hint != c.hint)
    }
}
