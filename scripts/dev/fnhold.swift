// Holds the fn key (synthetic flagsChanged) while `say` plays a phrase through the speakers, then releases.
import CoreGraphics
import Foundation
setvbuf(stdout, nil, _IONBF, 0)
let args = CommandLine.arguments
let phrase = args.count > 1 ? args[1] : "This is a test."
let voice = args.count > 2 ? args[2] : "Samantha"
print("AX trusted for posting:", CGPreflightPostEventAccess())
func fn(_ down: Bool) {
    let e = CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState), virtualKey: 63, keyDown: down)!
    e.type = .flagsChanged
    e.flags = down ? .maskSecondaryFn : []
    e.post(tap: .cghidEventTap)
}
fn(true); print("fn down")
Thread.sleep(forTimeInterval: 0.6)
let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/say"); p.arguments = ["-v", voice, phrase]
try! p.run(); p.waitUntilExit()
Thread.sleep(forTimeInterval: 0.5)
fn(false); print("fn up")
