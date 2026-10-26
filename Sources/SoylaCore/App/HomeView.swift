import SwiftUI

/// Home (APP-1, prototype `home()`): the state of things in setup's words, the fn key with a place to try it (or the
/// missing permissions), your languages with their one fix, and the last dictation. The everyday state fits 1056 × 688 unscrolled (D23).
struct HomeView: View {
    @ObservedObject var panel: PanelModel
    @ObservedObject var status: AppStatus
    @ObservedObject var settings: SettingsModel
    @ObservedObject var nav: MainWindowModel
    let home: HomeState
    let t: AppStrings
    let connect: InlineConnectModel
    var openSetup: (SetupStep) -> Void = { _ in }
    @State private var tryText = ""
    @State private var copied = false
    @State private var copyToken = 0

    private var key: String { panel.hotkeyShortLabel }
    private var lang: UILanguage { settings.s.uiLanguage }

    /// Unscrolled whenever it fits; a scroll view only below that (an open Connect panel scrolls into view).
    var body: some View {
        ViewThatFits(in: .vertical) {
            content
            ScrollViewReader { proxy in
                ScrollView { content }.modifier(RevealInlineConnect(model: connect, proxy: proxy))
            }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(t.title(home.title)).font(Ink.Font.appTitle).tracking(-0.74).foregroundStyle(Ink.text)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            setupKeyLine(t.sub(home), key: key).font(Ink.Font.appSub).foregroundStyle(Ink.text2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
            if home.keychainNotice {
                Callout(.warn, t.keyNotice(status.keychain)).padding(.top, 20)
            }
            Group {
                if home.hero == .fnKey { hero } else { permissions }
            }
            // D23 (owner, 2026-10-26): 24/18/16 and the medium key so the everyday Home fits 1056 × 688 unscrolled (R-06).
            .padding(.top, 24)
            languages.padding(.top, 18)
            lastDictation.padding(.top, 16)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, Ink.appPaneTop).padding(.horizontal, Ink.appPaneSide).padding(.bottom, Ink.appPaneBottom)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: hero

    private var hero: some View {
        HStack(alignment: .center, spacing: 32) {
            FnKeyCap(label: key, size: .medium, pressed: panel.hotkeyHeld, lifted: false)
            VStack(alignment: .leading, spacing: 12) {
                TextField(key == "fn" ? t.tryPh : t.tryPh.replacingOccurrences(of: "fn", with: key), text: $tryText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(Ink.Font.appText)
                    .lineLimit(2)
                    .padding(.horizontal, 16).padding(.vertical, 14)
                    .frame(maxWidth: .infinity, minHeight: 72, alignment: .topLeading)
                    .background(RoundedRectangle(cornerRadius: Ink.rCard, style: .continuous).fill(Ink.well))
                    .overlay(RoundedRectangle(cornerRadius: Ink.rCard, style: .continuous).strokeBorder(Ink.hairline))
                    .accessibilityLabel(t.tryPh)
                hints.frame(minHeight: 22, alignment: .leading)
            }
        }
    }

    @ViewBuilder private var hints: some View {
        switch panel.phase {
        case .recording:
            SetupState(color: Ink.signal, text: t.listening, font: Ink.Font.appCaption)
        case .transcribing, .cleaning, .pasting:
            SetupState(color: Ink.warn, text: t.writing, font: Ink.Font.appCaption)
        default:
            HStack(spacing: 20) {
                HStack(spacing: 6) { KeyChip(label: key); Text("×2 · \(t.handsFree)") }
                HStack(spacing: 6) { KeyChip(label: "esc"); Text(t.cancel) }
            }
            .font(Ink.Font.appCaption).foregroundStyle(Ink.text2)
            .accessibilityElement(children: .ignore)                       // F-29: not "fn key, fn key, ×2…"
            .accessibilityLabel("\(key) ×2: \(t.handsFree). esc: \(t.cancel)")
        }
    }

    // MARK: permissions (replaces the hero while the mic or Accessibility is off)

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle(t.perms)
            SetupGroup {
                if home.micMissing {
                    SetupRow(symbol: "mic", label: t.pMic, caption: t.pMicC, divider: home.axMissing) { allow(primary: true) }
                }
                if home.axMissing {
                    SetupRow(symbol: "character.cursor.ibeam", label: t.pAx, caption: t.pAxC, divider: false) { allow(primary: !home.micMissing) }
                }
            }
        }
    }

    @ViewBuilder private func allow(primary: Bool) -> some View {
        HStack(spacing: 12) {
            SetupState(color: Ink.warn, text: t.pOff, font: Ink.Font.appCaption)
            if primary {
                Button(t.pMicB) { openSetup(.permissions) }.buttonStyle(.borderedProminent).tint(Ink.lazur).controlSize(.large)
            } else {
                Button(t.pMicB) { openSetup(.permissions) }.buttonStyle(.bordered).controlSize(.large)
            }
        }
    }

    // MARK: your languages

    private var languages: some View {
        YourLanguagesSection(home: home, primaryAllowed: home.actionIsPrimary, t: t, connect: connect,
                             onChange: { openSetup(.languages) },
                             onUseCloud: { settings.useCloudEngine(settings.cloudTarget(hasKey: { status.keys[$0]?.verified ?? false })) })
    }

    // MARK: last dictation

    private var lastDictation: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                sectionTitle(t.last)
                Spacer(minLength: 12)
                if status.today.count > 0, let ms = status.today.medianWaitMs {
                    Text(t.today(status.today.count, AppStrings.seconds(ms, language: lang)))
                        .font(Ink.Font.appCaption).foregroundStyle(Ink.text2).monospacedDigit().lineLimit(1)
                }
                Button(t.allHist) { nav.tab = .history }.buttonStyle(.plain).font(Ink.Font.appCaption).foregroundStyle(Ink.text2)
            }
            .frame(minHeight: 28)
            // V-23: while the Permissions group stands in for the hero, the header line is enough (Home fits unscrolled).
            if let r = status.lastRun {
                if home.hero != .permissions { note(r) }
            } else {
                Text(t.todayEmpty).font(Ink.Font.appSub).foregroundStyle(Ink.text3)
            }
        }
    }

    private func note(_ r: RunRecord) -> some View {
        let text = r.finalText ?? ""
        let shape = RoundedRectangle(cornerRadius: Ink.rCard, style: .continuous)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                if r.status != .ok { Circle().fill(r.status.color).frame(width: 7, height: 7).accessibilityHidden(true) }
                Text(HomeMeta.line(r, t, lang)).font(Ink.Font.appCaption).foregroundStyle(Ink.text2).monospacedDigit().lineLimit(1)
                Spacer(minLength: 8)
                if !text.isEmpty {
                    Button(copied ? t.copied : t.copy) { copy(text) }.buttonStyle(.bordered)
                }
            }
            .frame(minHeight: 28)
            // Regression pass 2026-10-20: a cancelled run says so, as its History card does (V-19), not "Retry it".
            Text(text.isEmpty ? (r.status == .cancelled ? t.d.phCancelled : t.failedRun) : text)
                .font(Ink.Font.appText).lineSpacing(4).lineLimit(2)
                .foregroundStyle(text.isEmpty ? Ink.text3 : Ink.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(Ink.sheet))
        .overlay(shape.strokeBorder(Ink.hairline))
        .accessibilityElement(children: .contain)
    }

    private func copy(_ text: String) {
        Paster.copy(text)
        copyToken += 1
        let token = copyToken
        copied = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            if copyToken == token { copied = false }
        }
    }

    private func sectionTitle(_ s: String) -> some View {
        Text(s).font(Ink.Font.appSection).foregroundStyle(Ink.text).accessibilityAddTraits(.isHeader)
    }
}

/// "Today 16:24 · Notes · 4 s" on Home's last-dictation card, in the interface language.
@MainActor
enum HomeMeta {
    static func line(_ r: RunRecord, _ t: AppStrings, _ l: UILanguage) -> String {
        var parts: [String] = []
        if let d = TodayStats.parse(r.ts) {
            let f = DateFormatter()
            f.locale = Locale(identifier: l == .en ? "en_GB" : (l == .uz ? "uz_Latn" : "ru"))
            f.dateFormat = Calendar.current.isDateInToday(d) ? "HH:mm" : "d MMM HH:mm"
            parts.append(Calendar.current.isDateInToday(d) ? "\(t.metaToday) \(f.string(from: d))" : f.string(from: d))
        }
        if let a = r.targetApp, !a.isEmpty { parts.append(a) }
        let s = r.audio.durationSec
        if s > 0 { parts.append(s < 60 ? "\(max(1, Int(s.rounded()))) \(t.secs)" : String(format: "%d:%02d", Int(s) / 60, Int(s) % 60)) }
        return parts.joined(separator: " · ")
    }
}

/// "Your languages" on Home and the Languages page (prototype-v3 `langRow`): Change… in the header, one status per
/// row and the row's own fix next to it (Connect… opens the inline panel under it; Use Cloud switches the engine).
struct YourLanguagesSection: View {
    let home: HomeState
    /// The page may fill one Connect… (Home: only while the mic is allowed).
    let primaryAllowed: Bool
    let t: AppStrings
    let connect: InlineConnectModel
    let onChange: () -> Void
    let onUseCloud: () -> Void
    @FocusState private var rowFocus: SpokenLanguage?

    var body: some View {
        let open = connect.c.target
        let combo = CloudNudge.combo(home.rows.map(\.language))
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text(t.langs).font(Ink.Font.appSection).foregroundStyle(Ink.text).accessibilityAddTraits(.isHeader)
                Spacer(minLength: 12)
                Button(t.change, action: onChange).buttonStyle(.plain).font(Ink.Font.appCaption).foregroundStyle(Ink.text2)
            }
            .frame(minHeight: 28)
            SetupGroup {
                ForEach(Array(home.rows.enumerated()), id: \.offset) { i, row in
                    let panel = open == .language(row.language)
                    SetupRow(label: t.n[row.language] ?? row.language.rawValue, caption: caption(row.language, row.status),
                             divider: i < home.rows.count - 1 && !panel) {
                        HStack(spacing: 12) {
                            state(home.readiness.shown(row.status))
                            action(row.language, home.rowAction(row.language, primaryAllowed: primaryAllowed, open: open))
                        }
                    }
                    if panel {
                        InlineConnectPanel(model: connect, t: t, combo: combo)
                        if i < home.rows.count - 1 { Hairline().padding(.leading, SetupScale.pt(16)) }
                    }
                }
            }
        }
        .tint(nil)      // bordered row buttons stay neutral; the one filled Connect… sets its own lazur
        .onChange(of: connect.cancelToken) { _, _ in
            if case .language(let l)? = connect.cancelled { rowFocus = l }
        }
    }

    @ViewBuilder private func action(_ l: SpokenLanguage, _ a: RowAction?) -> some View {
        switch a {
        case .connect(let primary):
            if primary {
                Button(t.connect) { connect.open(.language(l)) }.buttonStyle(.borderedProminent).tint(Ink.lazur).focused($rowFocus, equals: l)
            } else {
                Button(t.connect) { connect.open(.language(l)) }.buttonStyle(.bordered).focused($rowFocus, equals: l)
            }
        case .useCloud:
            Button(t.useCloud, action: onUseCloud).buttonStyle(.bordered)
        case nil:
            EmptyView()
        }
    }

    /// The place from the shared route (F-06); the key state shows on the right.
    private func caption(_ l: SpokenLanguage, _ s: HomeState.LangStatus) -> String {
        if let r = home.routes.first(where: { $0.language == l }) {
            switch r.place {
            case .onMac: return t.onMac
            case .cloud(let name): return name.map(t.cloudVia) ?? t.cloudOnly
            }
        }
        switch s {
        case .onMac: return t.onMac
        case .cloud(let name): return name.map(t.cloudVia) ?? t.cloudOnly
        case .needsKey, .off, .blocked: return t.cloudOnly
        }
    }

    private func state(_ s: HomeState.LangStatus) -> some View {
        switch s {
        case .onMac, .cloud: return SetupState(color: Ink.ok, text: t.readyW, font: Ink.Font.appCaption)
        case .needsKey: return SetupState(color: Ink.warn, text: t.needsKey, font: Ink.Font.appCaption)
        case .off: return SetupState(color: Ink.warn, text: t.offW, font: Ink.Font.appCaption)
        // Calm grey, not saffron: the title and the Permissions group already carry the fix (audit V-01).
        case .blocked: return SetupState(color: Ink.text3, text: t.waitPerms, font: Ink.Font.appCaption)
        }
    }
}
