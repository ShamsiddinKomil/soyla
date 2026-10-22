import AppKit
import Foundation
import Testing
@testable import SoylaCore

/// app.log gets timings and error classes only. A reply body can hold the user's words, so every error that embeds
/// one must be cut by `DictationPipeline.logSafe`.
@Suite struct LogSafetyTests {
    let words = "FAKE dictated words, never log"

    @Test func cleanupOddShapeBodyIsNotLogged() throws {
        // HTTP 200 from an OpenAI-compatible server that uses `text` instead of `message` (legacy completions shape).
        let data = Data(#"{"choices":[{"text":"\#(words)"}]}"#.utf8)
        do {
            _ = try CleanupService.decode(data)
            Issue.record("expected a decode error")
        } catch {
            let logged = DictationPipeline.logSafe(String(describing: error))
            #expect(!logged.contains("FAKE dictated"))
            let logged2 = DictationPipeline.logSafe(error.localizedDescription)
            #expect(!logged2.contains("FAKE dictated"))
        }
    }

    @Test func httpAndDecodeBodiesAreCut() {
        #expect(!DictationPipeline.logSafe((SoylaError.http(status: 500, body: words).errorDescription ?? "")).contains("FAKE"))
        #expect(!DictationPipeline.logSafe((SoylaError.decode("x body: \(words)").errorDescription ?? "")).contains("FAKE"))
    }
}

/// Text left on the clipboard because Secure Input was on was meant for a password-style field: clipboard managers
/// must be told not to keep it (nspasteboard.org ConcealedType). An ordinary copy stays an ordinary copy.
@Suite struct ClipboardPrivacyTests {
    @Test func secureInputCopyIsConcealed() {
        #expect(Paster.markerTypes(concealed: true).contains(NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")))
    }

    @Test func ordinaryCopyIsPlain() {
        #expect(Paster.markerTypes(concealed: false).isEmpty)
    }
}
