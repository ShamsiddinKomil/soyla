import Foundation
import CoreGraphics

/// Where the pill sits. Presets are computed from the screen's `visibleFrame`; `custom` uses the last drag.
public enum PillPosition: String, Codable, CaseIterable, Sendable {
    case bottomCenter, topCenter, bottomRight, custom
    public var label: String {
        switch self {
        case .bottomCenter: return "Bottom centre"
        case .topCenter: return "Top centre (under the notch)"
        case .bottomRight: return "Bottom right"
        case .custom: return "Custom (last drag)"
        }
    }
}

/// The six spots of Settings → Pill's screen map. Three are presets; the corners are stored as custom anchors.
public enum PillSpot: String, CaseIterable, Sendable {
    case topLeft, topCenter, topRight, bottomLeft, bottomCenter, bottomRight

    public var label: String {
        switch self {
        case .topLeft: return "Top left"
        case .topCenter: return "Top centre"
        case .topRight: return "Top right"
        case .bottomLeft: return "Bottom left"
        case .bottomCenter: return "Bottom centre"
        case .bottomRight: return "Bottom right"
        }
    }
    public var isTop: Bool { [.topLeft, .topCenter, .topRight].contains(self) }
    /// 0, 0.5 or 1 across the screen.
    public var column: Double { switch self { case .topLeft, .bottomLeft: return 0; case .topCenter, .bottomCenter: return 0.5; default: return 1 } }

    /// What to store for this spot.
    public var setting: (position: PillPosition, anchor: PillAnchor?) {
        switch self {
        case .topCenter: return (.topCenter, nil)
        case .bottomCenter: return (.bottomCenter, nil)
        case .bottomRight: return (.bottomRight, nil)
        case .topLeft: return (.custom, PillAnchor(fx: 0.1, fy: 0.995))
        case .topRight: return (.custom, PillAnchor(fx: 0.9, fy: 0.995))
        case .bottomLeft: return (.custom, PillAnchor(fx: 0.1, fy: 0.045))
        }
    }

    /// The spot a stored position corresponds to; nil for a dragged position that matches none of them.
    public static func from(position: PillPosition, anchor: PillAnchor?) -> PillSpot? {
        switch position {
        case .topCenter: return .topCenter
        case .bottomCenter: return .bottomCenter
        case .bottomRight: return .bottomRight
        case .custom:
            guard let a = anchor else { return .bottomCenter }
            return allCases.first { s in
                guard let b = s.setting.anchor else { return false }
                return abs(b.fx - a.fx) < 0.001 && abs(b.fy - a.fy) < 0.001
            }
        }
    }
}

/// A dragged position stored as fractions of the screen's `visibleFrame`, so it survives display changes.
/// `fx` is the pill's horizontal centre. `fy` is its bottom edge when in the lower half of the screen and its
/// top edge when in the upper half, so the pill grows away from the screen edge it is closest to.
public struct PillAnchor: Codable, Equatable, Sendable {
    public var fx: Double
    public var fy: Double
    public init(fx: Double, fy: Double) { self.fx = fx; self.fy = fy }
}

/// How long processing has taken, as the pill shows it (design rule: never look frozen).
public enum PillWaitStage: Int, Comparable, Sendable {
    case quiet          // < 0.6 s: bars only (most results land here, so no label flicker)
    case label          // ≥ 0.6 s: "Transcribing…" (only when details are on)
    case stillWorking   // ≥ 2 s: "Still working…"
    case slow           // ≥ 4 s: "Taking longer than usual…" + Cancel
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// Recording colour: white, amber from the warning time, red in the last seconds before the hard stop.
public enum PillTint: Equatable, Sendable { case normal, amber, red }

/// Pure geometry and mapping for the pill. No AppKit, so all of it is unit-tested.
public enum PillGeometry {
    /// Gap kept between the pill and the edges of the visible frame.
    public static let margin: CGFloat = 8
    /// Bottom presets sit this far above the Dock / screen bottom (same as v0.1).
    public static let bottomInset: CGFloat = 48
    /// Top preset: just under the menu bar (visibleFrame already excludes the menu bar and the notch).
    public static let topInset: CGFloat = 8
    /// Bottom-right preset: distance from the right edge.
    public static let rightInset: CGFloat = 24

    // MARK: placement

    /// The window frame for a pill of `size` on a screen whose visible frame is `vf`.
    public static func frame(size: CGSize, position: PillPosition, anchor: PillAnchor?, in vf: CGRect) -> CGRect {
        let w = size.width, h = size.height
        var r: CGRect
        switch position {
        case .topCenter:
            r = CGRect(x: vf.midX - w / 2, y: vf.maxY - topInset - h, width: w, height: h)
        case .bottomRight:
            r = CGRect(x: vf.maxX - rightInset - w, y: vf.minY + bottomInset, width: w, height: h)
        case .custom where anchor != nil:
            let a = anchor!
            let cx = vf.minX + CGFloat(a.fx) * vf.width
            let edgeY = vf.minY + CGFloat(a.fy) * vf.height
            let y = a.fy <= 0.5 ? edgeY : edgeY - h
            r = CGRect(x: cx - w / 2, y: y, width: w, height: h)
        case .bottomCenter, .custom:
            r = CGRect(x: vf.midX - w / 2, y: vf.minY + bottomInset, width: w, height: h)
        }
        return clamp(r, into: vf)
    }

    /// Inverse of `frame(… .custom …)`: the anchor that reproduces `frame` on the screen `vf`.
    public static func anchor(of frame: CGRect, in vf: CGRect) -> PillAnchor {
        guard vf.width > 0, vf.height > 0 else { return PillAnchor(fx: 0.5, fy: 0) }
        let fx = (frame.midX - vf.minX) / vf.width
        let lowerHalf = frame.midY < vf.midY
        let edge = lowerHalf ? frame.minY : frame.maxY
        var fy = (edge - vf.minY) / vf.height
        // Keep the edge rule consistent with `frame`: lower half ↔ fy ≤ 0.5.
        fy = lowerHalf ? min(fy, 0.5) : max(fy, 0.5 + 1e-9)
        return PillAnchor(fx: Double(min(1, max(0, fx))), fy: Double(min(1, max(0, fy))))
    }

    /// Keep `r` fully inside `vf` (minus the margin). A pill wider/taller than the screen pins to its left/bottom.
    public static func clamp(_ r: CGRect, into vf: CGRect, margin m: CGFloat = margin) -> CGRect {
        var o = r.origin
        o.x = min(o.x, vf.maxX - m - r.width); o.x = max(o.x, vf.minX + m)
        o.y = min(o.y, vf.maxY - m - r.height); o.y = max(o.y, vf.minY + m)
        return CGRect(origin: o, size: r.size)
    }

    /// Index of the screen (by its full frame) that contains `point` (the mouse pointer), nil if none.
    /// Uses half-open ranges like `NSMouseInRect`, except that a point on the very top/right edge still counts.
    public static func screenIndex(containing p: CGPoint, frames: [CGRect]) -> Int? {
        if let i = frames.firstIndex(where: { p.x >= $0.minX && p.x < $0.maxX && p.y >= $0.minY && p.y < $0.maxY }) { return i }
        return frames.firstIndex(where: { $0.insetBy(dx: -1, dy: -1).contains(p) })
    }

    // MARK: waveform

    /// Map a buffer's RMS (0…1) to a bar level (0…1) in dB: −55…−15 dBFS → 0…1, then `pow(x, 0.7)`.
    /// The old linear `rms × 7` left quiet voices near the floor (looked frozen).
    public static func level(rms: Float) -> Double {
        let db = 20 * log10(Double(max(rms, 1e-5)))
        let x = min(1, max(0, (db + 55) / 40))
        return pow(x, 0.7)
    }

    /// One EMA step: fast attack (0.6), slower release (0.25), so bars jump up with speech and settle calmly.
    public static func smooth(_ previous: Double, toward target: Double) -> Double {
        let k = target > previous ? 0.6 : 0.25
        return previous + k * (target - previous)
    }

    // MARK: timing

    public static let labelAfter: Double = 0.6
    public static let stillWorkingAfter: Double = 2
    public static let slowAfter: Double = 4

    public static func waitStage(elapsed: Double) -> PillWaitStage {
        if elapsed >= slowAfter { return .slow }
        if elapsed >= stillWorkingAfter { return .stillWorking }
        if elapsed >= labelAfter { return .label }
        return .quiet
    }

    /// Seconds left before the hard stop at which the bars turn red.
    public static let redWithin: Double = 5

    public static func tint(elapsed: Double, warnAt: Double, hardStop: Double) -> PillTint {
        if elapsed >= hardStop - redWithin { return .red }
        if elapsed >= warnAt { return .amber }
        return .normal
    }
}
