import Testing
import Foundation
@testable import SoylaCore

/// Setup opened from the app centres on the main window, not the screen (owner, 2026-10-18).
@Suite("Setup window centres on the main window")
@MainActor
struct SetupAnchorTests {
    private let screen = NSRect(x: 0, y: 0, width: 1728, height: 1084)

    @Test func centresOnTheAnchor() {
        let f = SetupWindowController.centred(CGSize(width: 1056, height: 616), on: NSRect(x: 240, y: 331, width: 1056, height: 688), within: screen)
        #expect(f == NSRect(x: 240, y: 367, width: 1056, height: 616))
    }

    @Test func staysOnScreen() {
        let f = SetupWindowController.centred(CGSize(width: 1056, height: 640), on: NSRect(x: 1500, y: -200, width: 400, height: 300), within: screen)
        #expect(f.minX >= screen.minX && f.maxX <= screen.maxX)
        #expect(f.minY >= screen.minY && f.maxY <= screen.maxY)
    }
}
