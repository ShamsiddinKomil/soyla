import SwiftUI

// OB-2 v6: the Welcome screen (owner-approved prototype-v6.html, DIRECTION.md "v6 Welcome"). A brand moment, not a
// page: the pill mark, the name, one line, one Start. The v6 numbers are drawn at the SetupScale window (1056 wide),
// so they are used as given; colours come from DesignKit.

struct WelcomeView: View {
    let model: SetupModel
    var focus: FocusState<SetupFocus?>.Binding
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The entrance runs once per appearance (a new view on every return to Welcome; a language switch keeps it).
    @State private var shown = false
    @State private var appearedAt = Date()

    /// cubic-bezier(.16, 1, .3, 1), the entrance curve.
    private func entrance(_ duration: Double, delay: Double) -> Animation {
        .timingCurve(0.16, 1, 0.3, 1, duration: duration).delay(delay)
    }

    var body: some View {
        let t = model.strings
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                WelcomeMark(reduceMotion: reduceMotion, since: appearedAt)
                    .opacity(shown ? 1 : 0)
                    .scaleEffect(shown ? 1 : 0.96)
                    .animation(reduceMotion ? nil : entrance(0.64, delay: 0), value: shown)
                Text("Soyla")
                    .font(.system(size: 62, weight: .semibold)).tracking(-0.03 * 62)
                    .foregroundStyle(Ink.onLapis)
                    .padding(.top, 32)
                    .accessibilityAddTraits(.isHeader)
                    .rise(shown, reduceMotion ? nil : entrance(0.56, delay: 0.12))
                Text(t.wLine)
                    .font(.system(size: 19.5)).lineSpacing(19.5 * 0.35 / 2)
                    .foregroundStyle(Ink.onLapis2).multilineTextAlignment(.center)
                    .padding(.top, 16)
                    .rise(shown, reduceMotion ? nil : entrance(0.56, delay: 0.24))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .offset(y: -20)                                 // the prototype's margin-top −40 on a centred column
            VStack(spacing: 12) {
                Button(t.wStart) { model.next() }
                    .buttonStyle(WelcomeStartStyle())
                    .keyboardShortcut(.defaultAction)
                    .focused(focus, equals: .primary)
                Text(t.wTime).font(.system(size: 14)).foregroundStyle(Ink.onLapis3)
            }
            .padding(.bottom, 64)
            .rise(shown, reduceMotion ? nil : entrance(0.56, delay: 0.42))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            ZStack {
                Ink.lapis
                // A static soft lift behind the mark: white 7 % at the centre, gone by 70 %. Glaze depth; it never moves.
                EllipticalGradient(colors: [Color.white.opacity(0.07), Color.white.opacity(0)], center: UnitPoint(x: 0.5, y: 0.42),
                                   startRadiusFraction: 0, endRadiusFraction: 0.9)
            }
        }
        .onAppear {
            appearedAt = Date()
            shown = true                                    // each element's animation (nil under Reduce Motion) decides the motion
        }
        .accessibilityElement(children: .contain)
    }
}

private extension View {
    /// Fades in and rises 8 pt (the prototype's `wUp`).
    func rise(_ shown: Bool, _ animation: Animation?) -> some View {
        opacity(shown ? 1 : 0).offset(y: shown ? 0 : 8).animation(animation, value: shown)
    }
}

/// The white pill, 208 × 96, with lapis bars at the brand heights. The bars swell like the pill while it transcribes
/// (`WelcomeMotion`); static at the brand heights under Reduce Motion.
private struct WelcomeMark: View {
    let reduceMotion: Bool
    let since: Date
    private let w: CGFloat = 208, h: CGFloat = 96

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: reduceMotion)) { ctx in
            let t = ctx.date.timeIntervalSince(since)
            Canvas { g, size in
                g.fill(Capsule().path(in: CGRect(origin: .zero, size: size)), with: .color(.white))
                // The prototype's proportions: bar width 6.2 %, gap 5 %, tallest bar 56 % of the height.
                let bw = (w * 0.062).rounded(), gap = (w * 0.05).rounded(), mh = h * 0.56
                let total = CGFloat(Brand.bars.count) * bw + CGFloat(Brand.bars.count - 1) * gap
                var x = (size.width - total) / 2
                for (i, b) in Brand.bars.enumerated() {
                    let scale = reduceMotion ? 1 : WelcomeMotion.barScale(at: t, index: i)
                    let bh = max(2, mh * CGFloat(b) * CGFloat(scale))
                    g.fill(Capsule().path(in: CGRect(x: x, y: (size.height - bh) / 2, width: bw, height: bh)), with: .color(Ink.lapis))
                    x += bw + gap
                }
            }
        }
        .frame(width: w, height: h)
        .shadow(color: Color(nsColor: NSColor(hex: 0x040A24)).opacity(0.65), radius: 14, y: 20)
        .accessibilityHidden(true)
    }
}

/// White, 44 tall, at least 208 wide, radius 12, 16.5 pt semibold lapis-deep text.
private struct WelcomeStartStyle: ButtonStyle {
    func makeBody(configuration c: Configuration) -> some View { WelcomeStartLabel(label: c.label, pressed: c.isPressed) }
}

private struct WelcomeStartLabel<Label: View>: View {
    let label: Label
    let pressed: Bool
    @State private var hover = false
    var body: some View {
        label
            .font(.system(size: 16.5, weight: .semibold))
            .foregroundStyle(Ink.lapisDeep)
            .padding(.horizontal, 32)
            .frame(minWidth: 208, minHeight: 44)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(hover ? Color(nsColor: NSColor(hex: 0xEEF2FA)) : .white))
            .offset(y: pressed ? 1 : 0)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .onHover { hover = $0 }
    }
}
