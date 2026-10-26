import SwiftUI
import AppKit

// Soyla's design code (docs/DESIGN.md): tokens as `Ink.*`, then the handful of components every screen is built from.
// One hue across surfaces, one accent (lazur), speech on a note card, keys drawn as keys, status as a dot and a word.

// MARK: - Tokens

enum Ink {
    // Surfaces (light / dark)
    static let paper = dyn(0xF6F7F9, 0x15181D)
    static let sheet = dyn(0xFFFFFF, 0x1C2027)
    static let well = dyn(0xEEF0F3, 0x11141A)
    static let raised = dyn(0xFFFFFF, 0x262B34)
    // Increase Contrast (V-26): hairlines take hairlineStrong's weight, text3 takes text2's, lapis text 90 %.
    static let hairline = dyn(0x000000, 0xFFFFFF, light: 0.08, dark: 0.09, contrast: (0.14, 0.16))
    static let hairlineStrong = dyn(0x000000, 0xFFFFFF, light: 0.14, dark: 0.16)

    // Ink, four steps
    static let text = dyn(0x1A2230, 0xE8EBF0)
    static let text2 = dyn(0x1A2230, 0xE8EBF0, light: 0.62, dark: 0.62)
    static let text3 = dyn(0x1A2230, 0xE8EBF0, light: 0.45, dark: 0.45, contrast: (0.62, 0.62))
    static let text4 = dyn(0x1A2230, 0xE8EBF0, light: 0.30, dark: 0.30)

    // Colour that means something
    static let lazur = dyn(0x2A5BD7, 0x7A9BFF)
    static let lazurWash = dyn(0x2A5BD7, 0x7A9BFF, light: 0.12, dark: 0.16)
    static let signal = dyn(0xE0443E, 0xFF6B66)
    static let ok = dyn(0x2B9A5B, 0x5FCB8A)
    static let warn = dyn(0xC98A0A, 0xF0B33E)
    static let warnWash = dyn(0xC98A0A, 0xF0B33E, light: 0.10, dark: 0.14)

    // First-run setup (docs/DESIGN.md "First-run setup"): the lapis stage. Firuza = "you are here / act here" only;
    // success on the stage is `okOnLapis`, in the pane `ok`.
    static let lapis = dyn(0x1D3C97, 0x172F7A)
    static let lapisDeep = dyn(0x152D78, 0x0F2160)
    static let lapisLine = Color.white.opacity(0.14)
    static let onLapis = Color.white
    static let onLapis2 = dyn(0xFFFFFF, 0xFFFFFF, light: 0.80, dark: 0.80, contrast: (0.90, 0.90))
    static let onLapis3 = dyn(0xFFFFFF, 0xFFFFFF, light: 0.68, dark: 0.68, contrast: (0.90, 0.90))
    static let firuza = dyn(0x5FD3DF, 0x6EE0EA)
    static let okOnLapis = Color(nsColor: NSColor(hex: 0x86E3AD))
    /// The live pill: black from recording through the success bounce.
    static let pill = dyn(0x0E0F12, 0x000000)

    // Spacing (base 4) and radius
    static let s1: CGFloat = 4, s2: CGFloat = 8, s3: CGFloat = 12, s4: CGFloat = 16, s6: CGFloat = 24, s8: CGFloat = 32, s10: CGFloat = 40
    static let rControl: CGFloat = 6, rCard: CGFloat = 10, rSheet: CGFloat = 14
    static let sidebarWidth: CGFloat = 200

    enum Font {
        static let caption = SwiftUI.Font.system(size: 11)
        static let body = SwiftUI.Font.system(size: 13)
        static let subhead = SwiftUI.Font.system(size: 13, weight: .semibold)
        static let title = SwiftUI.Font.system(size: 17, weight: .semibold)
        /// What you said: the system face at reading size (the serif read poorly in mixed Latin/Cyrillic, owner
        /// 2026-10-16). Paired with `Ink.transcriptLeading`.
        static let spoken = SwiftUI.Font.system(size: 15)
        static let noteMeta = SwiftUI.Font.system(size: 11, weight: .medium)
        static let key = SwiftUI.Font.system(size: 12, weight: .semibold, design: .rounded)
        static let mono = SwiftUI.Font.system(size: 11, design: .monospaced)
        // Setup's type scale, drawn at v5's sizes (title 28, subtitle/label 14, caption 12.5, practice 22) × SetupScale.
        static let setupTitle = SwiftUI.Font.system(size: SetupScale.type(28), weight: .semibold)
        static let setupSub = SwiftUI.Font.system(size: SetupScale.type(14))
        static let setupLabel = SwiftUI.Font.system(size: SetupScale.type(14), weight: .medium)
        static let setupCaption = SwiftUI.Font.system(size: SetupScale.type(12.5))
        static let setupScript = SwiftUI.Font.system(size: SetupScale.type(22), weight: .medium)
        static let setupStage = SwiftUI.Font.system(size: SetupScale.type(14))
        // The main window continues setup's world at the same scale (APP-1, docs/DESIGN.md "Main window"):
        // title 31/600, subtitle 15.5, section 15.5/600, row label 15.5/500, caption and status 14, the try field
        // and the last dictation 16.5, the sidebar 14 with a 19.5 wordmark.
        static let appTitle = setupTitle
        static let appSub = setupSub
        static let appSection = SwiftUI.Font.system(size: SetupScale.type(14), weight: .semibold)
        static let appLabel = setupLabel
        static let appCaption = setupCaption
        static let appText = SwiftUI.Font.system(size: SetupScale.type(15))
        static let appNav = SwiftUI.Font.system(size: SetupScale.type(12.5))
        static let appNavSelected = SwiftUI.Font.system(size: SetupScale.type(12.5), weight: .semibold)
        static let appFoot = SwiftUI.Font.system(size: SetupScale.type(12))
        static let appWordmark = SwiftUI.Font.system(size: 19.5, weight: .semibold)
        static let appKey = SwiftUI.Font.system(size: SetupScale.type(12), weight: .medium, design: .rounded)
    }
    static let setupRow: CGFloat = SetupScale.pt(54)

    // Main window (APP-1): the 264 pt lapis sidebar, the pane's padding (top 56, sides 72, bottom 24), 60 pt rows.
    static let appSidebarWidth: CGFloat = SetupScale.pt(240)       // 264
    static let appRow: CGFloat = setupRow                           // 60
    static let appPaneTop: CGFloat = 56, appPaneSide: CGFloat = 72, appPaneBottom: CGFloat = 24
    static let appWindow = CGSize(width: 1056, height: 688)
    static let appWindowMin = CGSize(width: 1056, height: 600)

    private static func dyn(_ light: Int, _ dark: Int, light la: Double = 1, dark da: Double = 1,
                            contrast: (light: Double, dark: Double)? = nil) -> Color {
        Color(nsColor: dynamic(light, dark, light: la, dark: da, contrast: contrast))
    }

    /// A colour that follows the appearance, and with Increase Contrast on (the high-contrast appearances) takes the
    /// `contrast` alphas when given.
    static func dynamic(_ light: Int, _ dark: Int, light la: Double = 1, dark da: Double = 1,
                        contrast: (light: Double, dark: Double)? = nil) -> NSColor {
        NSColor(name: nil) { app in
            let m = app.bestMatch(from: [.accessibilityHighContrastDarkAqua, .accessibilityHighContrastAqua, .darkAqua, .aqua])
            let isDark = m == .darkAqua || m == .accessibilityHighContrastDarkAqua
            let high = m == .accessibilityHighContrastAqua || m == .accessibilityHighContrastDarkAqua
                || NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            return NSColor(hex: isDark ? dark : light, alpha: alpha(dark: isDark, high: high, light: la, dark: da, contrast: contrast))
        }
    }

    /// The alpha a token draws with (pure, so Increase Contrast is testable without changing the Mac's setting).
    static func alpha(dark: Bool, high: Bool, light la: Double, dark da: Double, contrast: (light: Double, dark: Double)?) -> Double {
        if high, let c = contrast { return dark ? c.dark : c.light }
        return dark ? da : la
    }
}

extension NSColor {
    convenience init(hex: Int, alpha: Double = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

/// One Settings page per entry. `.apiKeys` is the Engine page (renamed in FE-5; the case name stays so saved links and tests keep working). Drives the sidebar, the page header, and the jump targets used by Home and the menu bar.
public enum SettingsPage: String, CaseIterable, Identifiable, Sendable {
    case permissions, apiKeys, dictation, hotkey, pill, privacy, about, developer
    public var id: String { rawValue }

    /// APP-1 (b): the Languages page. The case stays `apiKeys` (raw value too) so saved links, `--page apiKeys` and the
    /// pill cards keep working; this is the name new code uses.
    public static var languages: SettingsPage { .apiKeys }

    /// `--page <id>`: the raw values plus the `languages` alias.
    public init?(argument: String) {
        if argument == "languages" { self = .apiKeys } else if let p = SettingsPage(rawValue: argument) { self = p } else { return nil }
    }

    var title: String {
        switch self {
        case .permissions: return "Permissions"
        case .apiKeys: return "Languages"
        case .dictation: return "Dictation"
        case .hotkey: return "Hotkey"
        case .pill: return "Pill"
        case .privacy: return "Privacy & data"
        case .about: return "About"
        case .developer: return "Developer"
        }
    }
    var icon: String {
        switch self {
        case .permissions: return "checkmark.shield"
        case .apiKeys: return "translate"
        case .dictation: return "text.quote"
        case .hotkey: return "keyboard"
        case .pill: return "capsule"
        case .privacy: return "lock"
        case .about: return "info.circle"
        case .developer: return "hammer"
        }
    }
}

// MARK: - Components

/// The brand: a capsule (the pill) with five bars in the silhouette of a spoken word. Drawn, never an asset, so the
/// app icon, the menu bar, the sidebar, Welcome and the live pill all share one geometry (docs/DESIGN.md).
enum Brand {
    /// Bar heights relative to the tallest, left to right. Asymmetric on purpose: a voice, not an equaliser.
    static let bars: [Double] = [0.42, 0.82, 0.58, 1.0, 0.5]
    /// Capsule height / width.
    static let ratio: CGFloat = 0.53
    /// Bar width and gap as fractions of the capsule width; bars fill 56 % of the capsule height.
    static let barW: CGFloat = 0.083, gap: CGFloat = 0.075, inner: CGFloat = 0.56

    /// Bar rectangles for a capsule of `size`.
    static func barRects(in size: CGSize) -> [CGRect] {
        let w = size.width * barW, g = size.width * gap
        let total = CGFloat(bars.count) * w + CGFloat(bars.count - 1) * g
        var x = size.width / 2 - total / 2
        return bars.map { h in
            let H = size.height * inner * CGFloat(h)
            defer { x += w + g }
            return CGRect(x: x, y: size.height / 2 - H / 2, width: w, height: H)
        }
    }

    static func draw(in ctx: GraphicsContext, size: CGSize, capsule: Color, bar: Color) {
        ctx.fill(Capsule().path(in: CGRect(origin: .zero, size: size)), with: .color(capsule))
        for r in barRects(in: size) { ctx.fill(Capsule().path(in: r), with: .color(bar)) }
    }

    /// Menu-bar image: a filled capsule with the bars knocked out. Template unless a colour is given.
    static func image(width: CGFloat = 22, fill: NSColor? = nil, label: String) -> NSImage {
        let size = NSSize(width: width, height: ceil(width * ratio))
        let img = NSImage(size: size, flipped: false) { rect in
            (fill ?? .black).setFill()
            NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
            NSGraphicsContext.current?.cgContext.setBlendMode(.clear)
            for r in barRects(in: rect.size) { NSBezierPath(roundedRect: r, xRadius: r.width / 2, yRadius: r.width / 2).fill() }
            NSGraphicsContext.current?.cgContext.setBlendMode(.normal)
            return true
        }
        img.isTemplate = fill == nil
        img.accessibilityDescription = label
        return img
    }
}

/// The brand capsule as a view.
struct BrandMark: View {
    var width: CGFloat = 30
    var capsule: Color = Ink.lazur
    var bar: Color = .white
    var body: some View {
        Canvas { ctx, size in Brand.draw(in: ctx, size: size, capsule: capsule, bar: bar) }
            .frame(width: width, height: (width * Brand.ratio).rounded())
            .accessibilityHidden(true)
    }
}

/// The five bars alone, resting or live from the pill's level (Home hero while recording).
struct Mark: View {
    var level: () -> Double = { 0 }
    var live = false
    var reduceMotion = false
    var height: CGFloat = 18
    var color: Color = Ink.lazur
    var body: some View {
        Waveform(level: level, mode: live ? .live : .rest, color: color, reduceMotion: reduceMotion, barHeight: height)
            .accessibilityHidden(true)
    }
}

/// Status is a dot and a word.
struct StatusLine: View {
    let color: Color
    let text: String
    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(color).frame(width: 7, height: 7).accessibilityHidden(true)
            Text(text).font(Ink.Font.body).foregroundStyle(Ink.text)
        }
        .accessibilityElement(children: .combine)
    }
}

/// What the user said, in the system face at reading size.
struct SpokenText: View {
    let text: String
    var lines: Int? = 4
    /// D26 (c): the same words with what cleanup changed marked (History's diff). VoiceOver still reads `text`.
    var styled: AttributedString? = nil
    var body: some View {
        Group { if let styled { Text(styled).accessibilityLabel(text) } else { Text(text) } }
            .font(Ink.Font.spoken).foregroundStyle(Ink.text)
            .lineSpacing(5).lineLimit(lines).textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// One dictation, drawn as a saved note and kept apart from the controls around it (docs/DESIGN.md):
/// a meta line (when · which app · how long, a status if it didn't go through), the text, and its actions.
struct NoteCard<Actions: View>: View {
    let meta: String
    var status: (color: Color, label: String)? = nil
    let text: String?
    var placeholder: String = ""
    var lines: Int? = 6
    /// D26 (c): a small tag after the meta line ("Cleaned"), the diff-marked text, and a quiet line under the text.
    var badge: String? = nil
    var badgeHelp: String? = nil
    var styled: AttributedString? = nil
    var note: String? = nil
    @ViewBuilder var actions: Actions

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: Ink.rCard, style: .continuous) }
    var body: some View {
        VStack(alignment: .leading, spacing: Ink.s3) {
            HStack(spacing: Ink.s2) {
                if let st = status {
                    Circle().fill(st.color).frame(width: 6, height: 6).accessibilityHidden(true)
                    Text(st.label).font(Ink.Font.noteMeta).foregroundStyle(Ink.text2)
                    Text("·").font(Ink.Font.noteMeta).foregroundStyle(Ink.text4)
                }
                Text(meta).font(Ink.Font.noteMeta).foregroundStyle(Ink.text2).monospacedDigit().lineLimit(1)
                if let badge {
                    Text(badge).font(Ink.Font.noteMeta).foregroundStyle(Ink.lazur).lineLimit(1)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: Ink.rControl, style: .continuous).fill(Ink.lazurWash))
                        .help(badgeHelp ?? badge)
                }
                Spacer(minLength: Ink.s2)
                actions
            }
            if let t = text, !t.isEmpty {
                SpokenText(text: t, lines: lines, styled: styled)
                if let note { Text(note).font(Ink.Font.caption).foregroundStyle(Ink.text2).fixedSize(horizontal: false, vertical: true) }
            } else {
                Text(placeholder).font(Ink.Font.body).foregroundStyle(Ink.text3).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, Ink.s4).padding(.vertical, Ink.s3 + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(Ink.sheet))
        .overlay(shape.strokeBorder(Ink.hairline))
        .accessibilityElement(children: .contain)
    }
}

/// A note card's action: icon + word in a quiet capsule that lights up on hover and sinks on press.
struct CardButton: View {
    let icon: String
    let label: String
    var tint: Color = Ink.text2
    var help: String? = nil
    let action: () -> Void
    @State private var hover = false
    @State private var cursorPushed = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 11, weight: .semibold))
                Text(label).font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(hover ? (tint == Ink.text2 ? Ink.text : tint) : tint)
            .padding(.horizontal, 9).frame(height: 24)
            .contentShape(Capsule())
        }
        .buttonStyle(CardButtonStyle(hover: hover))
        .onHover { h in
            withAnimation(.easeOut(duration: 0.12)) { hover = h }
            if h, !cursorPushed { NSCursor.pointingHand.push(); cursorPushed = true }
            else if !h, cursorPushed { NSCursor.pop(); cursorPushed = false }
        }
        .onDisappear { if cursorPushed { NSCursor.pop(); cursorPushed = false } }
        .help(help ?? label)
        .accessibilityLabel(help ?? label)
    }
}

struct CardButtonStyle: ButtonStyle {
    var hover: Bool
    func makeBody(configuration c: Configuration) -> some View {
        c.label
            .background(Capsule().fill(c.isPressed ? Ink.hairline : (hover ? Ink.well : Color.clear)))
            .overlay(Capsule().strokeBorder(hover || c.isPressed ? Ink.hairline : Color.clear))
            .scaleEffect(c.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.08), value: c.isPressed)
    }
}

/// Copy with feedback: the button turns into a green "Copied" for 1.5 s.
struct CopyButton: View {
    let text: String
    var onCopy: (() -> Void)? = nil
    /// The interface language's words (APP-1 (d)).
    var t: AppStrings = .en
    @State private var copied = false
    @State private var token = 0
    var body: some View {
        CardButton(icon: copied ? "checkmark" : "doc.on.doc", label: copied ? t.copied : t.copy,
                   tint: copied ? Ink.ok : Ink.text2, help: t.d.hCopyH) {
            Paster.copy(text); onCopy?()
            token += 1; let t = token
            withAnimation(.easeOut(duration: 0.12)) { copied = true }
            Task { @MainActor in if await MainDelay.elapsed(1.5), token == t { withAnimation { copied = false } } }
        }
    }
}

struct Hairline: View {
    var body: some View { Rectangle().fill(Ink.hairline).frame(height: 1) }
}

/// A sheet-coloured group of rows with hairlines between them. Title above, caption below, both optional.
struct SettingsGroup<Content: View>: View {
    var title: String? = nil
    var footer: String? = nil
    @ViewBuilder var content: Content
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: Ink.rCard, style: .continuous) }
    var body: some View {
        VStack(alignment: .leading, spacing: Ink.s2) {
            if let title { Text(title).font(Ink.Font.subhead).foregroundStyle(Ink.text).padding(.leading, 2) }
            VStack(spacing: 0) { content }
                .background(shape.fill(Ink.sheet))
                .overlay(shape.strokeBorder(Ink.hairline))
                .clipShape(shape)
            if let footer {
                Text(footer).font(Ink.Font.caption).foregroundStyle(Ink.text2).padding(.horizontal, 2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// One row: a label (and caption) on the left, the control on the right. `divider: false` on the last row.
struct Row<Control: View>: View {
    let label: String
    var caption: String? = nil
    var divider = true
    @ViewBuilder var control: Control

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: Ink.s4) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label).font(Ink.Font.body).foregroundStyle(Ink.text)
                    if let caption {
                        Text(caption).font(Ink.Font.caption).foregroundStyle(Ink.text2).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: Ink.s4)
                control.layoutPriority(1)      // the control keeps its size; the caption wraps
            }
            .padding(.horizontal, Ink.s4).padding(.vertical, 10)
            if divider { Hairline().padding(.leading, Ink.s4) }
        }
    }
}

/// A row whose content is full-width (text editors, lists of fields), with the same hairline rule.
struct WideRow<Content: View>: View {
    var divider = true
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Ink.s2) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Ink.s4).padding(.vertical, 10)
            if divider { Hairline().padding(.leading, Ink.s4) }
        }
    }
}

/// The only coloured box: something needs attention (amber) or is worth knowing (plain).
struct Callout<Action: View>: View {
    enum Kind { case warn, info }
    let kind: Kind
    let text: String
    @ViewBuilder var action: Action

    init(_ kind: Kind, _ text: String, @ViewBuilder action: () -> Action) { self.kind = kind; self.text = text; self.action = action() }

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: Ink.rCard, style: .continuous) }
    var body: some View {
        HStack(alignment: .center, spacing: Ink.s3) {
            Circle().fill(kind == .warn ? Ink.warn : Ink.text3).frame(width: 7, height: 7).accessibilityHidden(true)
            Text(text).font(Ink.Font.body).foregroundStyle(Ink.text).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Ink.s2)
            action
        }
        .padding(.horizontal, Ink.s4).padding(.vertical, Ink.s3)
        .background(shape.fill(kind == .warn ? Ink.warnWash : Ink.sheet))
        .overlay(shape.strokeBorder(kind == .warn ? Ink.warn.opacity(0.35) : Ink.hairline))
        .accessibilityElement(children: .contain)
    }
}

extension Callout where Action == EmptyView {
    init(_ kind: Kind, _ text: String) { self.init(kind, text) { EmptyView() } }
}

/// The inset "well" every text field sits in.
struct WellModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(Ink.Font.body)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: Ink.rControl, style: .continuous).fill(Ink.well))
            .overlay(RoundedRectangle(cornerRadius: Ink.rControl, style: .continuous).strokeBorder(Ink.hairline))
    }
}

extension View {
    func well() -> some View { modifier(WellModifier()) }
    /// Menu pickers and switches inside rows: no label of their own, natural size, lazur tint.
    func rowControl() -> some View { labelsHidden().fixedSize().tint(Ink.lazur) }
}

/// The hotkey drawn as the real Apple key: globe bottom-left, "fn" top-right, 4 pt of travel (setup stage).
/// Any other hotkey shows its label centred on the same cap.
struct FnKeyCap: View {
    enum Size { case medium, large }
    var label = "fn"
    var size: Size = .large
    var pressed = false
    /// The lapis setup stage lifts the key with a soft shadow; inside the main window it is drawn flat (DESIGN: no
    /// shadows inside windows, the 4 pt edge is drawn, not blurred; audit V-25).
    var lifted = true

    private var w: CGFloat { size == .large ? SetupScale.pt(120) : SetupScale.pt(88) }
    private var h: CGFloat { size == .large ? SetupScale.pt(110) : SetupScale.pt(82) }
    private var r: CGFloat { size == .large ? SetupScale.pt(16) : SetupScale.pt(12) }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: r, style: .continuous) }
    private static let edge = Color(nsColor: NSColor(hex: 0x8E9BBE))
    private static let face = LinearGradient(colors: [.white, Color(nsColor: NSColor(hex: 0xEEF1F6))], startPoint: .top, endPoint: .bottom)
    private static let faceDown = LinearGradient(colors: [Color(nsColor: NSColor(hex: 0xE6EBF5)), Color(nsColor: NSColor(hex: 0xD9E0EE))],
                                                 startPoint: .top, endPoint: .bottom)
    private static let legend = Color(nsColor: NSColor(hex: 0x1B2232))

    /// "Right ⌘" / "O‘ng ⌘" / "Правый ⌘" → ("Right", "⌘"); nil for fn, F13 and ⌃⇧Space.
    static func sideAndGlyph(_ label: String) -> (String, String)? {
        guard let last = label.last, "⌘⌥⌃".contains(last) else { return nil }
        let word = label.dropLast().trimmingCharacters(in: .whitespaces)
        return word.isEmpty ? nil : (word, String(last))
    }

    var body: some View {
        ZStack {
            shape.fill(pressed ? Self.faceDown : Self.face)
            if label == "fn" {
                Text("fn").font(.system(size: size == .large ? SetupScale.type(22) : SetupScale.type(17), weight: .medium, design: .rounded))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(.top, size == .large ? SetupScale.pt(14) : SetupScale.pt(10)).padding(.trailing, size == .large ? SetupScale.pt(16) : SetupScale.pt(12))
                Image(systemName: "globe").font(.system(size: size == .large ? SetupScale.type(22) : SetupScale.type(17), weight: .regular))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .padding(.bottom, size == .large ? SetupScale.pt(15) : SetupScale.pt(11)).padding(.leading, size == .large ? SetupScale.pt(15) : SetupScale.pt(11))
            } else if let (word, glyph) = Self.sideAndGlyph(label) {
                // HOTKEY-1: "Правый ⌥" drawn like the real key, glyph top right, word bottom left (no wrapping).
                Text(glyph).font(.system(size: size == .large ? SetupScale.type(26) : SetupScale.type(20), weight: .medium, design: .rounded))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(.top, size == .large ? SetupScale.pt(12) : SetupScale.pt(8)).padding(.trailing, size == .large ? SetupScale.pt(16) : SetupScale.pt(12))
                Text(word).font(.system(size: size == .large ? SetupScale.type(14) : SetupScale.type(11), weight: .medium))
                    .lineLimit(1).minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .padding(.bottom, size == .large ? SetupScale.pt(15) : SetupScale.pt(11)).padding(.horizontal, size == .large ? SetupScale.pt(15) : SetupScale.pt(11))
            } else {
                Text(label).font(.system(size: size == .large ? SetupScale.type(22) : SetupScale.type(17), weight: .medium, design: .rounded))
                    .minimumScaleFactor(0.5).padding(SetupScale.pt(8))
            }
        }
        .foregroundStyle(Self.legend)
        .frame(width: w, height: h)
        .background(shape.fill(Self.edge).offset(y: pressed ? 0 : 4))
        .shadow(color: .black.opacity(lifted ? 0.45 : 0), radius: pressed ? 4 : 12, y: pressed ? 4 : 12)
        .overlay(shape.strokeBorder(lifted ? Color.clear : Ink.hairlineStrong))
        .offset(y: pressed ? 4 : 0)
        .animation(.easeOut(duration: pressed ? 0.05 : 0.08), value: pressed)   // press lands at once, release eases
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(AppStrings.current.d.keyA11y(label))
        .accessibilityValue(pressed ? AppStrings.current.d.keyHeld : "")
    }
}

/// The live pill as drawn on the setup stage: a black capsule with the five white bars. `level` is read per frame.
struct LivePill: View {
    var level: () -> Double = { 0 }
    var mode: Waveform.Mode = .rest
    var width: CGFloat = 100
    var reduceMotion = false
    var body: some View {
        Waveform(level: level, mode: mode, color: .white, reduceMotion: reduceMotion, barHeight: width * 0.26)
            .frame(width: width, height: (width * Brand.ratio * 0.82).rounded())
            .background(Capsule().fill(Ink.pill))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.5), radius: 12, y: 8)
            .accessibilityHidden(true)
    }
}

/// D26(b): a tiny label on the black pill ("RU", "UZ·EN"): the language set while recording, when it isn't the default.
struct PillChip: View {
    let text: String
    let label: String
    var body: some View {
        Text(text).font(Ink.Font.caption).foregroundStyle(Ink.onLapis2)
            .padding(.horizontal, 6).frame(height: 16)
            .overlay(Capsule().strokeBorder(Ink.lapisLine, lineWidth: 0.5))
            .lineLimit(1).fixedSize()
            .accessibilityLabel(label)
    }
}

/// The round ⓘ: short paragraphs in a native popover (at most 320 wide in the app), the technical truth one click away
/// and never in the way. A real button, so Tab reaches it when the Mac's keyboard navigation is on.
struct InfoButton: View {
    let label: String
    let paragraphs: [String]
    var width: CGFloat = SetupScale.pt(300)
    /// 16 × 1.1 next to a title; rows use a smaller one beside their label.
    var size: CGFloat = SetupScale.type(16)
    @State private var shown = false
    var body: some View {
        // F-15: open, don't toggle: an accessibility press can reach the action twice, and a toggle closed it again.
        // The popover is transient, so a click outside or Esc closes it.
        Button { shown = true } label: {
            Image(systemName: "info.circle").font(.system(size: size)).foregroundStyle(Ink.text2)
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: SetupScale.pt(8)) {
                ForEach(paragraphs.indices, id: \.self) { i in
                    setupText(paragraphs[i]).font(Ink.Font.appCaption).foregroundStyle(Ink.text)   // F-28: 14, not 13
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, SetupScale.pt(16)).padding(.vertical, SetupScale.pt(14))
            .frame(width: width, alignment: .leading)
        }
    }
}

/// A key named inline in a line of text ("🌐 fn" drawn with the globe symbol, never the emoji): a small raised cap.
struct KeyChip: View {
    let label: String
    var body: some View {
        HStack(spacing: 4) {
            if label == "fn" { Image(systemName: "globe").font(.system(size: SetupScale.type(11))) }
            Text(label)
        }
        .font(Ink.Font.appKey)
        .foregroundStyle(Ink.text)
        .padding(.horizontal, 6)
        .frame(height: 22)
        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Ink.sheet))
        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Ink.hairlineStrong).offset(y: 1.5))
        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Ink.hairlineStrong, lineWidth: 0.5))
        .fixedSize()
        .accessibilityLabel(AppStrings.current.d.keyA11y(label))
    }
}

/// One choice of a group (engine, service) at the app's row scale: a 16 pt radio, the label over a short caption.
struct RadioRow: View {
    let label: String
    var caption: String? = nil
    let selected: Bool
    var divider = true
    let select: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            Button(action: select) {
                HStack(spacing: SetupScale.pt(14)) {
                    ZStack {
                        Circle().fill(selected ? Ink.lazur : Ink.sheet)
                        Circle().strokeBorder(selected ? Color.clear : Ink.hairlineStrong)
                        if selected { Circle().fill(Color.white).frame(width: 6, height: 6) }
                    }
                    .frame(width: 16, height: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(label).font(Ink.Font.appLabel).foregroundStyle(Ink.text)
                        if let caption { Text(caption).font(Ink.Font.appCaption).foregroundStyle(Ink.text2) }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, SetupScale.pt(16)).padding(.vertical, SetupScale.pt(10))
                .frame(minHeight: Ink.appRow)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
            if divider { Hairline().padding(.leading, SetupScale.pt(16)) }
        }
    }
}
