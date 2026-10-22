// Minimal WKWebView window that shows one local HTML file (prototype viewer for UI testing).
import AppKit
import WebKit
let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ""
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 840), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
win.title = "Soyla prototype"
let web = WKWebView(frame: win.contentView!.bounds)
web.autoresizingMask = [.width, .height]
win.contentView!.addSubview(web)
let url = URL(fileURLWithPath: path)
web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
win.center(); win.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
app.run()
