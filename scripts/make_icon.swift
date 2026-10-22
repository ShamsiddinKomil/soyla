// Renders build/AppIcon.iconset: the brand capsule (white, lapis bars) on a lapis tile. Run: swift scripts/make_icon.swift
// then: iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
// Geometry mirrors `Brand` in Sources/SoylaCore/App/DesignKit.swift (bars, ratio, bar width, gap, inner height).
import AppKit
let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath)
let set = root.appendingPathComponent("build/AppIcon.iconset")
try? FileManager.default.removeItem(at: set)
try! FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)

let bars: [CGFloat] = [0.42, 0.82, 0.58, 1.0, 0.5]
let lazur = NSColor(srgbRed: 0x2A / 255, green: 0x5B / 255, blue: 0xD7 / 255, alpha: 1)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    let inset = s * 0.09                                   // macOS icon grid: art inside ~82% square
    let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let tile = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    NSGradient(colors: [NSColor(srgbRed: 0x1E / 255, green: 0x46 / 255, blue: 0xB4 / 255, alpha: 1),
                        NSColor(srgbRed: 0x3A / 255, green: 0x6C / 255, blue: 0xF0 / 255, alpha: 1)])!.draw(in: tile, angle: 90)
    // the capsule: 76 % of the tile wide, ratio 0.53
    let cw = rect.width * 0.76, ch = cw * 0.53
    let cap = NSRect(x: rect.midX - cw / 2, y: rect.midY - ch / 2, width: cw, height: ch)
    NSColor.white.setFill()
    NSBezierPath(roundedRect: cap, xRadius: ch / 2, yRadius: ch / 2).fill()
    let barW = cw * 0.083, gap = cw * 0.075
    let total = CGFloat(bars.count) * barW + CGFloat(bars.count - 1) * gap
    var x = cap.midX - total / 2
    lazur.setFill()
    for h in bars {
        let bh = ch * 0.56 * h
        NSBezierPath(roundedRect: NSRect(x: x, y: cap.midY - bh / 2, width: barW, height: bh), xRadius: barW / 2, yRadius: barW / 2).fill()
        x += barW + gap
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}
for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                   ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! render(px).write(to: set.appendingPathComponent("icon_\(name).png"))
}
print(set.path)
