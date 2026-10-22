// Renders docs/media/social-preview.png (1280×640, GitHub's social preview size): brand tile, name, pitch, a spoken
// mixed-language line on a note card. Run: swift scripts/make_social.swift
// Tokens from docs/DESIGN.md (paper, sheet, ink, lazur); tile geometry mirrors scripts/make_icon.swift.
import AppKit

let out = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("docs/media/social-preview.png")
let W = 1280, H = 640
func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}
let paper = rgb(0xF6F7F9), sheet = rgb(0xFFFFFF), ink = rgb(0x1A2230), lazur = rgb(0x2A5BD7), signal = rgb(0xE0443E)

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: H, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
// AppKit origin is bottom-left; `top(y, h)` converts a top-based y.
func top(_ y: CGFloat, _ h: CGFloat) -> CGFloat { CGFloat(H) - y - h }

paper.setFill(); NSRect(x: 0, y: 0, width: W, height: H).fill()

// Brand tile (same drawing as the app icon, no inset).
func tile(_ r: NSRect) {
    NSGradient(colors: [rgb(0x1E46B4), rgb(0x3A6CF0)])!.draw(in: NSBezierPath(roundedRect: r, xRadius: r.width * 0.225, yRadius: r.width * 0.225), angle: 90)
    let cw = r.width * 0.76, ch = cw * 0.53
    let cap = NSRect(x: r.midX - cw / 2, y: r.midY - ch / 2, width: cw, height: ch)
    NSColor.white.setFill(); NSBezierPath(roundedRect: cap, xRadius: ch / 2, yRadius: ch / 2).fill()
    let bars: [CGFloat] = [0.42, 0.82, 0.58, 1.0, 0.5], barW = cw * 0.083, gap = cw * 0.075
    var x = cap.midX - (CGFloat(bars.count) * barW + CGFloat(bars.count - 1) * gap) / 2
    lazur.setFill()
    for h in bars {
        let bh = ch * 0.56 * h
        NSBezierPath(roundedRect: NSRect(x: x, y: cap.midY - bh / 2, width: barW, height: bh), xRadius: barW / 2, yRadius: barW / 2).fill()
        x += barW + gap
    }
}
let L: CGFloat = 96
tile(NSRect(x: L, y: top(88, 112), width: 112, height: 112))

func draw(_ s: String, _ font: NSFont, _ color: NSColor, x: CGFloat, y: CGFloat, w: CGFloat) -> CGFloat {
    let p = NSMutableParagraphStyle(); p.lineSpacing = font.pointSize * 0.18
    let a = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: p])
    let h = ceil(a.boundingRect(with: NSSize(width: w, height: 1000), options: [.usesLineFragmentOrigin]).height)
    a.draw(with: NSRect(x: x, y: top(y, h), width: w, height: h), options: [.usesLineFragmentOrigin])
    return h
}
_ = draw("Soyla", .systemFont(ofSize: 88, weight: .bold), ink, x: L + 140, y: 92, w: 700)
_ = draw("Dictation for macOS", .systemFont(ofSize: 30, weight: .medium), ink.withAlphaComponent(0.62), x: L + 144, y: 196, w: 700)
_ = draw("Uzbek, Russian and English in one sentence.\nHold a key, speak, let go.", .systemFont(ofSize: 40, weight: .semibold), ink,
         x: L, y: 262, w: CGFloat(W) - 2 * L)

// Note card with a spoken line, as the app shows a dictation.
let card = NSRect(x: L, y: top(420, 100), width: CGFloat(W) - 2 * L, height: 100)
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow(); shadow.shadowColor = ink.withAlphaComponent(0.08); shadow.shadowBlurRadius = 18; shadow.shadowOffset = NSSize(width: 0, height: -4)
shadow.set(); sheet.setFill(); NSBezierPath(roundedRect: card, xRadius: 18, yRadius: 18).fill()
NSGraphicsContext.restoreGraphicsState()
ink.withAlphaComponent(0.10).setStroke(); let border = NSBezierPath(roundedRect: card.insetBy(dx: 0.5, dy: 0.5), xRadius: 18, yRadius: 18); border.lineWidth = 1; border.stroke()
signal.setFill(); NSBezierPath(ovalIn: NSRect(x: card.minX + 32, y: card.midY - 7, width: 14, height: 14)).fill()
_ = draw("Kecha mijoz bilan gaplashdim, но есть один нюанс…", .systemFont(ofSize: 36, weight: .regular), ink,
         x: card.minX + 64, y: 420 + 28, w: card.width - 96)
_ = draw("Free and open source · your own API key · no account", .systemFont(ofSize: 24, weight: .medium), lazur,
         x: L, y: 560, w: CGFloat(W) - 2 * L)

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: out)
print(out.path)
