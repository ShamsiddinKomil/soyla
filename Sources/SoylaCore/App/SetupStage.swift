import SwiftUI

// OB-2: the lapis stage. Every step's stage does a job (no filler): the gesture on Languages, a preview of the next
// macOS surface on Permissions (only the one-line instruction while the real one is open), the honest route on
// Connect, the live pill on Try, the menu-bar callout on Done. At most two short lines of text.

struct SetupStage: View {
    let model: SetupModel
    @ObservedObject var panel: PanelModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: SetupScale.pt(36))                     // the traffic lights
            scene
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            rail
        }
        .padding(.horizontal, SetupScale.pt(28)).padding(.bottom, SetupScale.pt(24))
        .background(Ink.lapis)
        .foregroundStyle(Ink.onLapis)
    }

    @ViewBuilder private var scene: some View {
        let t = model.strings, f = model.flow
        switch f.step {
        case .welcome: EmptyView()
        case .languages:
            LanguagesDemo(field: t.dField, text: SetupStrings.fill(t.dText, key: model.hotkeyLabel),
                          verbs: t.dSteps.map { SetupStrings.fill($0, key: model.hotkeyLabel) },
                          keyLabel: model.hotkeyLabel, reduceMotion: reduceMotion)
                .accessibilityHidden(true)
        case .permissions:
            if let a = f.awaiting {
                stageLine(t.aw[a] ?? "")
            } else if let p = f.firstPending {
                VStack(spacing: SetupScale.pt(14)) {
                    PermissionPreview(pending: p, reduceMotion: reduceMotion).accessibilityHidden(true)
                    stageLine(guide(p))
                }
            } else {
                VStack(spacing: SetupScale.pt(20)) {
                    FnKeyCap(label: model.hotkeyLabel, size: .large)
                    stageLine(t.gDone)
                }
            }
        case .connect:
            RouteView(mac: t.rMac, provider: f.provider.displayName, noServer: t.rNoServer, reduceMotion: reduceMotion)
        case .tryIt:
            TryStage(model: model, panel: panel, reduceMotion: reduceMotion)
        case .done:
            DoneStage(here: t.dsHere, sub: t.dsSub, hold: t.dsHold, keyLabel: model.hotkeyLabel)
        }
    }

    private func guide(_ p: PendingPermission) -> String {
        let t = model.strings
        switch p {
        case .mic: return t.gMic
        case .micSettings: return t.gMicSet
        case .accessibility: return t.gAx
        case .fn: return t.gFn
        }
    }

    private func stageLine(_ s: String) -> some View {
        setupText(s).font(Ink.Font.setupStage).foregroundStyle(Ink.onLapis).multilineTextAlignment(.center)
            .frame(maxWidth: SetupScale.pt(250)).fixedSize(horizontal: false, vertical: true)
    }

    private var rail: some View {
        let t = model.strings, f = model.flow, steps = f.steps, now = f.railIndex
        return VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(steps.enumerated()), id: \.offset) { i, s in
                HStack(spacing: SetupScale.pt(10)) {
                    Group {
                        switch f.shownRailMark(s) {
                        case .done: Image(systemName: "checkmark").font(.system(size: SetupScale.type(10), weight: .semibold))
                        case .skipped: Circle().strokeBorder(Ink.onLapis3, lineWidth: 1.2).frame(width: SetupScale.pt(8), height: SetupScale.pt(8))   // skipped, not done
                        case .current:
                            Circle().fill(Ink.firuza).frame(width: SetupScale.pt(8), height: SetupScale.pt(8))
                                .background(Circle().fill(Ink.firuza.opacity(0.22)).frame(width: SetupScale.pt(14), height: SetupScale.pt(14)))
                        case .pending: Circle().fill(Ink.onLapis3).frame(width: 5, height: 5)
                        }
                    }
                    .frame(width: SetupScale.pt(14), height: SetupScale.pt(14))
                    Text(t.rail[s] ?? "").font(.system(size: SetupScale.type(12.5), weight: i == now ? .semibold : .regular))
                }
                .foregroundStyle(i == now ? Ink.onLapis : f.shownRailMark(s) == .done ? Ink.onLapis2 : Ink.onLapis3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, SetupScale.pt(16))
        .overlay(alignment: .top) { Rectangle().fill(Ink.lapisLine).frame(height: 1) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(t.railAria)
        .accessibilityValue("\(t.stepOf(now + 1, steps.count)) · \(t.rail[f.step] ?? "")")
    }
}

/// Languages: the real gesture on a loop. The key sinks, the black pill records, the instruction lands in a field.
private struct LanguagesDemo: View {
    let field: String, text: String, verbs: [String], keyLabel: String
    let reduceMotion: Bool
    @State private var phase = 4

    private var keyDown: Bool { phase == 1 || phase == 2 }
    private var pillOn: Bool { (1...4).contains(phase) }
    private var verb: String {
        if reduceMotion { return verbs.joined(separator: " · ") }
        switch phase { case 0: return ""; case 1: return verbs[0]; case 2: return verbs[1]; default: return verbs[2] }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(field).font(.system(size: SetupScale.type(11))).foregroundStyle(Color(nsColor: NSColor(hex: 0x5A6274)))
                Text(phase >= 4 || reduceMotion ? text : " ").font(.system(size: SetupScale.type(13.5))).foregroundStyle(Color(nsColor: NSColor(hex: 0x1A2030)))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, SetupScale.pt(14)).padding(.top, SetupScale.pt(12)).padding(.bottom, SetupScale.pt(22))
            .frame(width: SetupScale.pt(260), alignment: .topLeading)
            .frame(minHeight: SetupScale.pt(84), alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white))
            .shadow(color: .black.opacity(0.4), radius: 13, y: 12)
            .opacity(phase == 6 ? 0 : 1)
            LivePill(level: Self.voice, mode: phase == 2 ? .live : .rest, width: SetupScale.pt(92), reduceMotion: reduceMotion)
                .opacity(pillOn && !reduceMotion ? 1 : 0)
                .padding(.top, -SetupScale.pt(20))
            FnKeyCap(label: keyLabel, size: .medium, pressed: keyDown && !reduceMotion).padding(.top, SetupScale.pt(12))
            Text(verb).font(.system(size: SetupScale.type(13), weight: .medium)).frame(minHeight: SetupScale.pt(19)).padding(.top, SetupScale.pt(14))
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: phase)
        .task(id: reduceMotion) {
            guard !reduceMotion else { return }
            // The prototype's timing: reset, hold, speak, let go, text arrives, pill fades, field fades.
            let seq: [(ms: Int, phase: Int)] = [(600, 0), (700, 1), (450, 2), (1700, 3), (500, 4), (700, 5), (3600, 6), (220, 6)]
            while !Task.isCancelled {
                for s in seq {
                    try? await Task.sleep(for: .milliseconds(s.ms))
                    if Task.isCancelled { return }
                    phase = s.phase
                }
            }
        }
    }

    /// A speaking voice for the demo bars (no microphone involved).
    static let voice: () -> Double = {
        let t = Date().timeIntervalSinceReferenceDate
        return 0.35 + 0.65 * abs(sin(t * 3.1)) * (0.6 + 0.4 * sin(t * 1.7))
    }
}

/// What macOS will show next, drawn small, with the control to click ringed in firuza.
private struct PermissionPreview: View {
    let pending: PendingPermission
    let reduceMotion: Bool
    private static let sheet = Color(nsColor: NSColor(hex: 0xF6F6F7))
    private static let bar = Color(nsColor: NSColor(hex: 0xECECEE))
    private static let ink = Color(nsColor: NSColor(hex: 0x1A2030))
    private static let sysBlue = Color(nsColor: NSColor(hex: 0x0A64D8))

    var body: some View {
        Group {
            switch pending {
            case .mic: alert
            case .micSettings: list(title: "Microphone")
            case .accessibility: list(title: "Accessibility")
            case .fn: keyboard
            }
        }
        .frame(width: SetupScale.pt(250))
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Self.sheet))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .shadow(color: .black.opacity(0.45), radius: 15, y: 14)
        .foregroundStyle(Self.ink)
        .environment(\.colorScheme, .light)
    }

    private var alert: some View {
        VStack(spacing: SetupScale.pt(8)) {
            BrandMark(width: SetupScale.pt(20), capsule: .white, bar: Ink.lapis)
                .frame(width: SetupScale.pt(30), height: SetupScale.pt(30)).background(RoundedRectangle(cornerRadius: 7).fill(Ink.lapis))
            Text(SetupStrings.macMicTitle(app: SetupStrings.appName)).font(.system(size: SetupScale.type(11.5), weight: .bold)).multilineTextAlignment(.center)
            VStack(spacing: 4) {
                Text(MacTerms.name("Allow")).font(.system(size: SetupScale.type(11))).foregroundStyle(.white).frame(maxWidth: .infinity, minHeight: SetupScale.pt(20))
                    .background(RoundedRectangle(cornerRadius: 5).fill(Self.sysBlue))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Ink.firuza, lineWidth: 2.5).padding(-2.5))
                Text(MacTerms.name("Don’t Allow")).font(.system(size: SetupScale.type(11))).frame(maxWidth: .infinity, minHeight: SetupScale.pt(20))
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.gray.opacity(0.18)))
            }
        }
        .padding(SetupScale.pt(12))
    }

    private func list(title: String) -> some View {
        VStack(spacing: 0) {
            header(title)
            HStack(spacing: SetupScale.pt(8)) {
                RoundedRectangle(cornerRadius: 4).fill(Color.gray.opacity(0.22)).frame(width: SetupScale.pt(16), height: SetupScale.pt(16))
                RoundedRectangle(cornerRadius: 3).fill(Color.gray.opacity(0.22)).frame(width: SetupScale.pt(60), height: SetupScale.pt(8))
                Spacer()
                MiniSwitch(on: true)
            }
            .padding(.horizontal, SetupScale.pt(10)).padding(.vertical, SetupScale.pt(9))
            Divider()
            HStack(spacing: SetupScale.pt(8)) {
                BrandMark(width: SetupScale.pt(11), capsule: .white, bar: Ink.lapis)
                    .frame(width: SetupScale.pt(16), height: SetupScale.pt(16)).background(RoundedRectangle(cornerRadius: 4).fill(Ink.lapis))
                Text(SetupStrings.appName).font(.system(size: SetupScale.type(11.5), weight: .bold))
                Spacer()
                AnimatedSwitch(reduceMotion: reduceMotion)
            }
            .padding(.horizontal, SetupScale.pt(10)).padding(.vertical, SetupScale.pt(9))
            .background(Self.sysBlue.opacity(0.08))
        }
    }

    private var keyboard: some View {
        VStack(spacing: 0) {
            header("Keyboard")
            HStack(spacing: 4) {
                Text("Press").font(.system(size: SetupScale.type(11.5)))
                Image(systemName: "globe").font(.system(size: SetupScale.type(10)))
                Text("key to").font(.system(size: SetupScale.type(11.5)))
                Spacer()
                Text(MacTerms.name("Do Nothing")).font(.system(size: SetupScale.type(11))).padding(.horizontal, SetupScale.pt(8)).frame(height: SetupScale.pt(20))
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.white))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Ink.firuza, lineWidth: 2.5).padding(-2.5))
            }
            .padding(.horizontal, SetupScale.pt(10)).padding(.vertical, SetupScale.pt(10))
        }
    }

    private func header(_ s: String) -> some View {
        Text(s).font(.system(size: SetupScale.type(11), weight: .semibold)).frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, SetupScale.pt(10)).padding(.vertical, 7).background(Self.bar)
    }
}

private struct MiniSwitch: View {
    let on: Bool
    var body: some View {
        Capsule().fill(on ? Color(nsColor: NSColor(hex: 0x0A64D8)) : Color.gray.opacity(0.32))
            .frame(width: SetupScale.pt(30), height: SetupScale.pt(18))
            .overlay(alignment: on ? .trailing : .leading) {
                Circle().fill(.white).frame(width: SetupScale.pt(14), height: SetupScale.pt(14)).padding(2).shadow(color: .black.opacity(0.25), radius: 1, y: 1)
            }
    }
}

/// Soyla's switch in the preview, turning on and off with a firuza ring ("act here").
private struct AnimatedSwitch: View {
    let reduceMotion: Bool
    @State private var on = false
    var body: some View {
        MiniSwitch(on: on)
            .overlay(Capsule().strokeBorder(Ink.firuza, lineWidth: 2.5).padding(-2.5))
            .task(id: reduceMotion) {
                guard !reduceMotion else { on = false; return }
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(900))
                    withAnimation(.easeInOut(duration: 0.3)) { on = true }
                    try? await Task.sleep(for: .milliseconds(1200))
                    withAnimation(.easeInOut(duration: 0.3)) { on = false }
                }
            }
    }
}

/// Connect: This Mac → the provider, with no Soyla server in between.
private struct RouteView: View {
    let mac: String, provider: String, noServer: String
    let reduceMotion: Bool
    var body: some View {
        VStack(spacing: 0) {
            node("laptopcomputer", mac)
            Wire(reduceMotion: reduceMotion).frame(width: 6, height: SetupScale.pt(40))
            node("cloud", provider)
            HStack(spacing: 6) {
                Image(systemName: "lock").font(.system(size: SetupScale.type(11)))
                Text(noServer).font(.system(size: SetupScale.type(12.5)))
            }
            .foregroundStyle(Ink.onLapis3).padding(.top, SetupScale.pt(16))
        }
        .frame(width: SetupScale.pt(240))
        .accessibilityElement(children: .combine)
    }
    private func node(_ symbol: String, _ s: String) -> some View {
        HStack(spacing: SetupScale.pt(10)) {
            Image(systemName: symbol).font(.system(size: SetupScale.type(15))).frame(width: SetupScale.pt(20))
            Text(s).font(.system(size: SetupScale.type(13)))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, SetupScale.pt(14)).padding(.vertical, SetupScale.pt(12))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.3)))
    }
}

private struct Wire: View {
    let reduceMotion: Bool
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { ctx in
            Canvas { g, size in
                var y: CGFloat = 0
                while y < size.height {
                    g.fill(Path(CGRect(x: size.width / 2 - 1, y: y, width: 2, height: 4)), with: .color(.white.opacity(0.55)))
                    y += 8
                }
                guard !reduceMotion else { return }
                let p = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
                let dot = CGRect(x: size.width / 2 - 3, y: p * (size.height - 6), width: 6, height: 6)
                g.fill(Path(ellipseIn: dot), with: .color(.white.opacity(p < 0.2 ? p * 5 : 1 - p)))
            }
        }
    }
}

/// Try: the black live pill (from the real pipeline's level) over the big key that sinks while the hotkey is held.
private struct TryStage: View {
    let model: SetupModel
    @ObservedObject var panel: PanelModel
    let reduceMotion: Bool

    private var mode: Waveform.Mode {
        switch panel.phase {
        case .recording: return .live
        case .transcribing, .cleaning, .pasting: return .processing
        default: return .rest
        }
    }
    private var pillShown: Bool { model.hotkeyHeld || mode != .rest || model.flow.currentTry != nil }

    var body: some View {
        let t = model.strings
        VStack(spacing: SetupScale.pt(20)) {
            LivePill(level: { [panel] in panel.displayLevel }, mode: mode, width: SetupScale.pt(100), reduceMotion: reduceMotion)
                .opacity(pillShown ? 1 : 0)
                .scaleEffect(pillShown ? 1 : 0.9)
                .phaseAnimator([1.0, 1.08, 1.0], trigger: model.flow.currentTry != nil) { v, s in
                    v.scaleEffect(reduceMotion ? 1 : s)
                }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: pillShown)
            FnKeyCap(label: model.hotkeyLabel, size: .large, pressed: model.hotkeyHeld)
            note(t).font(.system(size: SetupScale.type(13.5))).multilineTextAlignment(.center).frame(maxWidth: SetupScale.pt(250), minHeight: SetupScale.pt(18))
        }
    }

    @ViewBuilder private func note(_ t: SetupStrings) -> some View {
        switch model.tryNote {
        case .idle: Text(t.tNote).foregroundStyle(Ink.onLapis2)
        case .short: Text(t.tShort).foregroundStyle(Ink.onLapis2)
        case .listening:
            HStack(spacing: 6) { Circle().fill(Ink.signal).frame(width: 7, height: 7); Text(t.tListen) }.foregroundStyle(Ink.onLapis)
        case .writing:
            HStack(spacing: 6) { ProgressView().controlSize(.small).tint(.white); Text(t.tWrite) }.foregroundStyle(Ink.onLapis)
        case .ok:
            HStack(spacing: 6) { Circle().fill(Ink.okOnLapis).frame(width: 7, height: 7); Text(t.tOk) }.foregroundStyle(Ink.onLapis)
        }
    }
}

/// Done: where Soyla lives now (the menu bar) and the key to hold in any app.
private struct DoneStage: View {
    let here: String, sub: String, hold: String, keyLabel: String
    var body: some View {
        VStack(spacing: SetupScale.pt(28)) {
            VStack(spacing: 0) {
                HStack(spacing: SetupScale.pt(11)) {
                    Spacer()
                    Image(systemName: "wifi").font(.system(size: SetupScale.type(12)))
                    Image(systemName: "battery.75percent").font(.system(size: SetupScale.type(13)))
                    BrandMark(width: SetupScale.pt(18), capsule: .white, bar: Ink.lapis)
                        .frame(width: SetupScale.pt(28), height: SetupScale.pt(20))
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.25)))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Ink.firuza, lineWidth: 2.5).padding(-2.5))
                    Text("9:41").font(.system(size: SetupScale.type(11))).monospacedDigit()
                }
                .padding(.horizontal, SetupScale.pt(10)).frame(height: SetupScale.pt(26))
                .background(UnevenRoundedRectangle(topLeadingRadius: 8, topTrailingRadius: 8).fill(Color.white.opacity(0.16)))
                .foregroundStyle(Color.white.opacity(0.88))
                Arrow().stroke(Color.white.opacity(0.85), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    .frame(width: SetupScale.pt(40), height: SetupScale.pt(34))
                    .frame(maxWidth: .infinity, alignment: .trailing).padding(.trailing, SetupScale.pt(62)).padding(.top, -4)
                VStack(spacing: 2) {
                    Text(here).font(.system(size: SetupScale.type(16), weight: .semibold))
                    Text(sub).font(.system(size: SetupScale.type(12))).foregroundStyle(Ink.onLapis2)
                }
            }
            .accessibilityElement(children: .combine)
            HStack(spacing: SetupScale.pt(14)) {
                FnKeyCap(label: keyLabel, size: .medium)
                Text(hold).font(.system(size: SetupScale.type(13.5))).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: SetupScale.pt(270))
            .accessibilityElement(children: .combine)
        }
    }

    /// The curved arrow from the caption up to the menu-bar icon.
    private struct Arrow: Shape {
        func path(in r: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: r.minX + 6, y: r.maxY - 2))
            p.addCurve(to: CGPoint(x: r.maxX - 7, y: r.minY + 5), control1: CGPoint(x: r.minX + 10, y: r.midY - 4), control2: CGPoint(x: r.midX + 2, y: r.minY + 9))
            p.move(to: CGPoint(x: r.maxX - 14, y: r.minY + 2.5))
            p.addLine(to: CGPoint(x: r.maxX - 6.5, y: r.minY + 4.8))
            p.addLine(to: CGPoint(x: r.maxX - 9.5, y: r.minY + 11.8))
            return p
        }
    }
}
