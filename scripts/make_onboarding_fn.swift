// Renders Resources/onboarding-fn.png: a PLACEHOLDER mock of System Settings → Keyboard → "Press 🌐 key to: Do Nothing".
// Task D2 replaces it with a real screenshot. Run: swift scripts/make_onboarding_fn.swift
import AppKit
let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath)
let w = 840, h = 260                                      // 2× of a 420×130 pt image
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let W = CGFloat(w), H = CGFloat(h)
NSColor(calibratedWhite: 0.96, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: W, height: H), xRadius: 24, yRadius: 24).fill()
func text(_ s: String, _ x: CGFloat, _ y: CGFloat, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .black) {
    (s as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color])
}
text("Keyboard", 40, H - 70, size: 30, weight: .bold)
// the setting row
let row = NSRect(x: 30, y: 50, width: W - 60, height: 90)
NSColor.white.setFill(); NSBezierPath(roundedRect: row, xRadius: 16, yRadius: 16).fill()
text("Press 🌐 key to", 56, 80, size: 28)
let pop = NSRect(x: W - 330, y: 66, width: 270, height: 58)
NSColor(calibratedRed: 0.0, green: 0.48, blue: 1.0, alpha: 1).setFill()
NSBezierPath(roundedRect: pop, xRadius: 12, yRadius: 12).fill()
text("Do Nothing  ▾", pop.minX + 34, pop.minY + 13, size: 26, weight: .semibold, color: .white)
text("placeholder", W - 150, 14, size: 18, color: .gray)
NSGraphicsContext.restoreGraphicsState()
let out = root.appendingPathComponent("Resources/onboarding-fn.png")
try! rep.representation(using: .png, properties: [:])!.write(to: out)
print("wrote \(out.path)")
