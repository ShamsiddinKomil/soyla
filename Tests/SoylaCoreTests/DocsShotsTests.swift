import Testing
import SwiftUI
@testable import SoylaCore

// `soyla docs-shots`: the docs pictures are drawn from a frozen demo status, and the capture-only switch is off in
// the app.

@Suite struct DocsShotsTests {
    @MainActor @Test func previewStatusIgnoresStart() {
        let status = AppStatus(loadNow: false)
        let demo = PermissionState(mic: .granted, ax: true, inputMonitoring: true, eventsFlowing: true)
        status.previewPermissions(demo)
        status.start()               // MainView calls this on appear; a frozen status must not poll the real grants
        #expect(status.permissions == demo)
    }

    @Test func captureModeIsOffByDefault() {
        #expect(EnvironmentValues().docsCapture == false)
    }
}
