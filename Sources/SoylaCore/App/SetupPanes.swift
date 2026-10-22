import SwiftUI

// OB-2: the five questions. One title, one short line, a few controls with short captions, one status line, buttons.

struct SetupPane: View {
    @Bindable var model: SetupModel
    var focus: FocusState<SetupFocus?>.Binding

    var body: some View {
        Group { panes }
            .buttonStyle(.bordered)                        // secondary actions: plain push buttons; only the primary is lapis
    }

    @ViewBuilder private var panes: some View {
        switch model.flow.step {
        case .welcome: EmptyView()                          // full-window WelcomeView (SetupWelcome.swift)
        case .languages: LanguagesPane(model: model, focus: focus)
        case .permissions: PermissionsPane(model: model, focus: focus)
        case .connect: ConnectPane(model: model, focus: focus)
        case .tryIt: TryPane(model: model, focus: focus)
        case .done: DonePane(model: model, focus: focus)
        }
    }
}

/// Back on the left, the primary action bottom-right (Raycast's placement). Entered from the app there is no Back.
private struct BackButton: View {
    let model: SetupModel
    var body: some View {
        if model.flow.showsBack { Button(model.strings.back) { model.back() } }
    }
}

private struct LinkButton: View {
    let title: String
    let action: () -> Void
    var body: some View {
        Button(title, action: action).buttonStyle(.plain).font(.system(size: SetupScale.type(13))).foregroundStyle(Ink.text2)
    }
}

extension SpokenLanguage {
    /// Its own name, as the Languages rows list it.
    var nativeName: String {
        switch self { case .en: return UILanguage.en.nativeName; case .uz: return UILanguage.uz.nativeName; case .ru: return UILanguage.ru.nativeName }
    }
}

// MARK: Languages

private struct LanguagesPane: View {
    let model: SetupModel
    var focus: FocusState<SetupFocus?>.Binding

    var body: some View {
        let t = model.strings, f = model.flow
        PaneScaffold(title: t.lTitle, info: (t.lInfo, tips), sub: Text(t.lSub)) {
            VStack(alignment: .leading, spacing: SetupScale.pt(16)) {
                SetupGroup {
                    ForEach(SpokenLanguage.allCases, id: \.self) { l in
                        VStack(spacing: 0) {
                            Toggle(isOn: Binding(get: { f.languages.contains(l) }, set: { _ in model.toggle(l) })) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(t.n[l] ?? l.nativeName).font(Ink.Font.setupLabel).foregroundStyle(Ink.text)
                                    Text(caption(l)).font(Ink.Font.setupCaption).foregroundStyle(Ink.text2)
                                }
                                .padding(.leading, SetupScale.pt(8))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .toggleStyle(.checkbox)
                            .tint(Ink.lazur)
                            .padding(.horizontal, SetupScale.pt(16)).padding(.vertical, SetupScale.pt(10))
                            .frame(minHeight: Ink.setupRow)
                            if l != .ru { Hairline().padding(.leading, SetupScale.pt(16)) }
                        }
                    }
                }
                status
            }
        } footer: {
            // V-38: the first run's Languages goes back to Welcome (its entrance plays again), like every later step.
            if f.hasWelcome { BackButton(model: model) }
            Spacer()
            // V-29: entered from the app every step's primary is Done.
            Button(f.finishesOnNext || f.fromApp ? t.close : t.cont) { model.next() }
                .buttonStyle(.borderedProminent).tint(Ink.lazur).keyboardShortcut(.defaultAction)
                .disabled(!f.canContinue)
                .focused(focus, equals: .primary)
        }
    }

    @ViewBuilder private var status: some View {
        let t = model.strings, f = model.flow
        if f.languages.isEmpty { SetupStatus(text: t.lNone) }
        else if let c = f.cloudCombo { SetupStatus(color: Ink.warn, text: t.lCloud(c)) }
        else if case .cloud(let name) = model.route(.en).place { SetupStatus(color: Ink.ok, text: t.lEnVia(name ?? "Cloud")) }
        else { SetupStatus(color: Ink.ok, text: t.lEn) }
    }

    /// F-04: each caption says where that language goes with the engine setup will leave, not a fixed "On this Mac".
    private func caption(_ l: SpokenLanguage) -> String {
        let t = model.strings, r = model.route(l)
        switch r.place {
        case .onMac: return t.lEnSub
        case .cloud(let name): return r.ready ? t.lCloudVia(name ?? "Cloud") : t.lClSub
        }
    }

    /// The ⓘ: with Cloud on, English goes to that service too (not "runs on this Mac").
    private var tips: [String] {
        let t = model.strings
        guard case .cloud(let name) = model.route(.en).place else { return t.lTip }
        return [t.lTipCloud(name ?? "Cloud")] + t.lTip.dropFirst()
    }
}

// MARK: Permissions

/// The fn row: free the Globe key in System Settings, or (HOTKEY-1) pick another key right here, which needs no
/// System Settings trip. Once another key is picked the row stays and says which one; fn can be picked back.
private struct FnRow: View {
    let model: SetupModel
    var focus: FocusState<SetupFocus?>.Binding
    var divider = false

    var body: some View {
        let t = model.strings, f = model.flow, fn = model.hotkey == .fn
        VStack(alignment: .leading, spacing: 0) {
            SetupRow(symbol: "globe", label: fn ? t.pFn : SetupStrings.fill(t.pFnUses, key: model.hotkeyLabel),
                     caption: fn ? (f.fnOK ? t.pFnDone : t.fnCaption(usage: f.fnUsage)) : nil, divider: false) {
                if !fn { SetupState(text: t.pOk) } else if f.fnOK { SetupState(text: t.pFixed) } else {
                    Button(t.pFnB) { model.openKeyboard() }.focused(focus, equals: .fn)
                }
            }
            if !(fn && f.fnOK) {
                VStack(alignment: .leading, spacing: SetupScale.pt(8)) {
                    if fn { Text(t.pFnOr).font(Ink.Font.setupCaption).foregroundStyle(Ink.text2) }
                    KeyChoiceStrip(selection: model.hotkey) { model.pickKey($0) }
                }
                .padding(.leading, SetupScale.pt(54)).padding(.trailing, SetupScale.pt(16)).padding(.bottom, SetupScale.pt(12))
            }
            if divider { Hairline().padding(.leading, SetupScale.pt(16)) }
        }
    }
}

private struct PermissionsPane: View {
    let model: SetupModel
    var focus: FocusState<SetupFocus?>.Binding

    var body: some View {
        let t = model.strings, f = model.flow, key = model.hotkeyLabel
        PaneScaffold(title: t.pTitle, sub: Text(SetupStrings.fill(t.pSub, key: key))) {
            VStack(alignment: .leading, spacing: SetupScale.pt(16)) {
                SetupGroup {
                    SetupRow(symbol: "mic", label: t.pMic, caption: f.mic == .denied ? t.pMicDenied : t.pMicC) { micControl }
                    SetupRow(symbol: "character.cursor.ibeam", label: t.pAx, caption: t.pAxC,
                             divider: f.fnRowShown || f.inputMonitoringRowShown) {
                        if f.ax { SetupState(text: t.pOk) } else {
                            Button(t.pSet) { model.openAccessibility() }.focused(focus, equals: .ax)
                        }
                    }
                    if f.fnRowShown { FnRow(model: model, focus: focus, divider: f.inputMonitoringRowShown) }
                    if f.inputMonitoringRowShown {
                        SetupRow(symbol: "keyboard", label: SetupStrings.fill(t.pIm, key: key), caption: t.pImC, divider: false) {
                            Button(t.pSet) { model.openInputMonitoring() }.focused(focus, equals: .im)
                        }
                    }
                }
                if let p = f.firstPending { SetupStatus(text: t.pNext[p] ?? "") }
                else { SetupStatus(color: Ink.ok, text: t.pAll) }
            }
        } footer: {
            BackButton(model: model)
            Spacer()
            // V-09: from the app, Done always closes (Home keeps nudging what is still missing).
            Button(f.finishesOnNext || f.fromApp ? t.close : t.cont) { model.primary() }
                .buttonStyle(.borderedProminent).tint(Ink.lazur).keyboardShortcut(.defaultAction)
                .disabled(!f.primaryEnabled)
                .focused(focus, equals: .primary)
        }
    }

    @ViewBuilder private var micControl: some View {
        let t = model.strings
        switch model.flow.mic {
        case .granted: SetupState(text: t.pOk)
        case .denied: Button(t.pSet) { model.openMicSettings() }.focused(focus, equals: .micSettings)
        case .notDetermined: Button(t.pMicB) { model.allowMic() }.focused(focus, equals: .mic)
        }
    }
}

// MARK: Connect

private struct ConnectPane: View {
    @Bindable var model: SetupModel
    var focus: FocusState<SetupFocus?>.Binding

    var body: some View {
        let t = model.strings, f = model.flow
        PaneScaffold(title: t.cTitle(f.cloudCombo ?? .uz), info: (t.cInfo, t.cTip), sub: Text(t.cSub)) {
            VStack(alignment: .leading, spacing: SetupScale.pt(16)) {
                SetupGroup {
                    providerRow(.google, caption: t.cG, divider: true)
                    providerRow(.openRouter, caption: t.cO, divider: false)
                }
                .accessibilityElement(children: .contain)
                // Regression pass 2026-10-20: the tiles are the service choice ("Service", as in inline Connect);
                // "About the two services" is the ⓘ button's own label.
                .accessibilityLabel(AppStrings.for(model.flow.uiLanguage).service)
                VStack(alignment: .leading, spacing: SetupScale.pt(14)) {
                    HStack(spacing: SetupScale.pt(10)) {
                        badge("1")
                        Text(t.cS1).font(.system(size: SetupScale.type(13.5))).foregroundStyle(Ink.text)
                        Button(t.cOpen(f.provider.host)) { model.openSite() }.controlSize(.regular)
                    }
                    HStack(spacing: SetupScale.pt(10)) {
                        badge("2")
                        if f.connected, let masked = model.keys.rows[f.provider.key]?.masked {
                            // F-12: the connected key, not an empty disabled placeholder; F-20: Replace… starts over.
                            Label("\(masked) · \(f.provider.displayName)", systemImage: "checkmark.circle.fill")
                                .font(Ink.Font.setupLabel).foregroundStyle(Ink.text).labelStyle(ConnectedKeyLabel())
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Button(t.cReplace) { model.replaceKey() }.controlSize(.large)
                        } else {
                            SecureField(t.cPh, text: $model.keyDraft)
                                .textFieldStyle(.roundedBorder).controlSize(.large)
                                .disabled(f.connected)
                                .focused(focus, equals: .keyField)
                                .onSubmit { if keyReady { model.connect() } }
                                .accessibilityLabel(t.cKeyAria)
                            connectButton
                        }
                    }
                }
                status
            }
        } footer: {
            BackButton(model: model)
            if (f.returnTo == nil || f.fromApp) && !f.connected { LinkButton(title: f.fromApp ? t.cCancel : t.cSkip) { model.skipConnect() } }
            Spacer()
            Button(f.fromApp ? t.close : t.cont) { model.next() }
                .buttonStyle(.borderedProminent).tint(Ink.lazur).keyboardShortcut(.defaultAction)
                .disabled(!f.canContinue)
                .focused(focus, equals: .primary)
        }
    }

    private var keyReady: Bool {
        model.keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).count > 8 && model.flow.keyState != .checking && !model.flow.connected
    }

    @ViewBuilder private var connectButton: some View {
        let t = model.strings
        if model.flow.connected {
            Button(t.cConnected) {}.disabled(true).controlSize(.large)
        } else if keyReady {
            Button(t.cConnect) { model.connect() }.buttonStyle(.borderedProminent).tint(Ink.lazur).controlSize(.large)
        } else {
            Button(t.cConnect) { model.connect() }.disabled(true).controlSize(.large)
        }
    }

    private func providerRow(_ p: SetupProvider, caption: String, divider: Bool) -> some View {
        let selected = model.flow.provider == p
        return Button { model.setProvider(p) } label: {
            VStack(spacing: 0) {
                HStack(spacing: SetupScale.pt(8)) {                      // same column and inset as the Languages checkboxes
                    Image(systemName: selected ? "circle.inset.filled" : "circle")
                        .font(.system(size: SetupScale.type(15))).foregroundStyle(selected ? Ink.lazur : Ink.text3)
                        .frame(width: SetupScale.pt(18)).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(p.displayName).font(Ink.Font.setupLabel).foregroundStyle(Ink.text)
                        Text(caption).font(Ink.Font.setupCaption).foregroundStyle(Ink.text2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, SetupScale.pt(16)).padding(.vertical, SetupScale.pt(10))
                .frame(minHeight: Ink.setupRow)
                if divider { Hairline().padding(.leading, SetupScale.pt(16)) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.flow.connected && !selected)
        .accessibilityLabel("\(p.displayName), \(caption)")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private func badge(_ n: String) -> some View {
        Text(n).font(.system(size: SetupScale.type(11), weight: .semibold, design: .rounded)).foregroundStyle(Ink.text2)
            .frame(width: SetupScale.pt(20), height: SetupScale.pt(20)).background(Circle().fill(Ink.well)).accessibilityHidden(true)
    }

    @ViewBuilder private var status: some View {
        let t = model.strings
        switch model.flow.keyState {
        case .ok: SetupStatus(color: Ink.ok, text: t.cOk)
        case .checking: SetupStatus(spinning: true, text: t.cChecking)
        case .opened: SetupStatus(text: t.cOpened)
        case .failed(let why): SetupStatus(color: Ink.warn, text: t.keyFail[why] ?? "")
        case .idle: EmptyView()
        }
    }
}

// MARK: Try

/// The connected key's line: a green check, then the masked key and the service.
private struct ConnectedKeyLabel: LabelStyle {
    func makeBody(configuration c: Configuration) -> some View {
        HStack(spacing: SetupScale.pt(8)) { c.icon.foregroundStyle(Ink.ok); c.title }
    }
}

private struct TryPane: View {
    let model: SetupModel
    var focus: FocusState<SetupFocus?>.Binding

    var body: some View {
        let t = model.strings, f = model.flow, lang = f.tryLanguage
        PaneScaffold(title: t.tTitle, sub: setupKeyLine(t.tSub, key: model.hotkeyLabel)) {
            if f.readiness.isBlocked { blocked } else { practice }
        } footer: {
            BackButton(model: model)
            if f.currentTry == nil && f.returnTo == nil && !f.readiness.isBlocked { LinkButton(title: t.skip) { model.skipTry() } }
            Spacer()
            Button(f.fromApp ? t.close : t.finish) { model.primary() }
                .buttonStyle(.borderedProminent).tint(Ink.lazur).keyboardShortcut(.defaultAction)
                .disabled(!f.primaryEnabled)
                .focused(focus, equals: .primary)
        }
    }

    /// V-11: nothing to try while Soyla can't hear or type: one status line and the fix.
    private var blocked: some View {
        let t = model.strings
        return HStack(spacing: SetupScale.pt(12)) {
            SetupStatus(color: Ink.warn, text: model.flow.readiness.micFirst ? t.blMic : t.blAx)
            Button(t.pMicB) { model.allowMissing() }.focused(focus, equals: .mic)
        }
    }

    @ViewBuilder private var practice: some View {
        let t = model.strings, f = model.flow, lang = f.tryLanguage
            VStack(alignment: .leading, spacing: SetupScale.pt(16)) {
                VStack(alignment: .leading, spacing: 5) {
                    if lang != SpokenLanguage(f.uiLanguage) {
                        Text(t.tReadIn[lang] ?? "").font(.system(size: SetupScale.type(12))).foregroundStyle(Ink.text2)
                    }
                    Text(SetupStrings.sample[lang] ?? "").font(Ink.Font.setupScript).tracking(-0.2).foregroundStyle(Ink.text)
                        .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                }
                TextField(model.tryNote == .listening ? t.tListen : t.tPh, text: Binding(get: { model.practiceText }, set: { model.setPracticeText($0) }), axis: .vertical)
                    .textFieldStyle(.plain).font(.system(size: SetupScale.type(15))).lineLimit(2...5)
                    .padding(.horizontal, SetupScale.pt(16)).padding(.vertical, SetupScale.pt(14))
                    .frame(minHeight: SetupScale.pt(64), alignment: .topLeading)
                    .background(RoundedRectangle(cornerRadius: Ink.rCard, style: .continuous).fill(Ink.sheet))
                    .overlay(RoundedRectangle(cornerRadius: Ink.rCard, style: .continuous).strokeBorder(Ink.hairlineStrong))
                    .focused(focus, equals: .practice)
                    .accessibilityLabel(t.tPh)
                if model.tryNote == .short { SetupStatus(color: Ink.warn, text: t.tShort) }
                else if let fail = model.tryFailure, model.tryNote == .idle {
                    // F-11: the window says what went wrong too, not only the card at the bottom of the screen.
                    let c = fail.shown(f.uiLanguage, readiness: f.readiness)
                    SetupStatus(color: Ink.warn, text: c.hint.isEmpty ? c.title : "\(c.title). \(c.hint)")
                }
                else if TryFeedback.showsResult(note: model.tryNote) { result }
                engineStatus
                keyChange
                if f.inputMonitoringRowShown {
                    SetupStatus(color: Ink.warn, text: SetupStrings.fill(t.tNoKeys, key: model.hotkeyLabel))
                    SetupGroup {
                        SetupRow(symbol: "keyboard", label: SetupStrings.fill(t.pIm, key: model.hotkeyLabel), caption: t.pImC, divider: false) {
                            Button(t.pSet) { model.openInputMonitoring() }.focused(focus, equals: .im)
                        }
                    }
                }
            }
    }

    /// HOTKEY-1: "Change key" opens the caps inline; pressing a key alone picks it too (the hotkey is swallowed meanwhile,
    /// so pressing doesn't start a try). fn picked while the Globe key still opens emoji brings its fix row here.
    @ViewBuilder private var keyChange: some View {
        let t = model.strings
        if model.pickingKey {
            VStack(alignment: .leading, spacing: SetupScale.pt(8)) {
                Text(t.tPick).font(Ink.Font.setupCaption).foregroundStyle(Ink.text2)
                KeyChoiceStrip(selection: model.hotkey) { model.pickKey($0) }
            }
        } else {
            LinkButton(title: t.tChange) { model.setPickingKey(true) }
        }
        if model.hotkey == .fn && !model.flow.fnOK {
            SetupGroup { FnRow(model: model, focus: focus) }
        }
    }

    @ViewBuilder private var result: some View {
        let t = model.strings
        if let r = model.flow.currentTry {
            let engine: String = {
                switch r.engine { case .onDevice: return t.tLocal; case .cloud(let name): return t.tCloud(name) }
            }()
            HStack(spacing: SetupScale.pt(8)) {
                LivePill(width: SetupScale.pt(24))
                setupText("**\(SetupFlow.seconds(r.seconds, language: model.flow.uiLanguage)) \(t.tSeconds)** · \(engine)")
                    .font(.system(size: SetupScale.type(12.5))).foregroundStyle(Ink.text2).monospacedDigit()
            }
            .accessibilityElement(children: .combine)
        }
    }

    /// The free engine's English model on Try: say it plainly when it isn't usable yet.
    @ViewBuilder private var engineStatus: some View {
        let t = model.strings
        if model.onDeviceEngine && model.flow.currentTry == nil {
            switch OnDeviceModels.shared.state {
            case .ready: EmptyView()
            case .unavailable: SetupStatus(color: Ink.warn, text: t.tModelNone)
            case .needsPermission:
                HStack(spacing: SetupScale.pt(12)) {
                    SetupStatus(color: Ink.warn, text: t.tModelPermission)
                    Button(t.pMicB) {
                        let locale = model.settings.s.onDeviceLocale
                        Task { await OnDeviceModels.shared.requestPermission(locale: locale) }
                    }
                }
            case .needsDownload, .downloading, nil: SetupStatus(spinning: true, text: t.tModelWait)
            }
        }
    }
}

// MARK: Done

private struct DonePane: View {
    let model: SetupModel
    var focus: FocusState<SetupFocus?>.Binding

    var body: some View {
        let t = model.strings, f = model.flow
        // V-01: "ready" only when Soyla can hear and type too (the shared `Readiness`), not only when a key is on file.
        let blocked = f.readiness.isBlocked
        // Regression pass 2026-10-20: English through a hosted service with no key waits too (after Remove key, or a
        // skipped Connect), so Done never calls it ready; the title is Home's own ("Soyla needs an API key").
        let ready = f.allReady && !englishWaits
        let title = blocked ? t.dnBlocked
            : (ready ? t.dnTitle : (englishWaits ? AppStrings.for(f.uiLanguage).keyTitle : t.dnMore(f.cloudCombo ?? .uz)))
        let sub = blocked ? Text(f.readiness.micFirst ? t.blMic : t.blAx)
            : (ready ? setupKeyLine(t.dnSub, key: model.hotkeyLabel)
               // F-03: "English works now." only to someone who chose English and whose English really works.
               : (f.languages.contains(.en) && model.route(.en).ready ? Text(t.dnMoreSub) : setupKeyLine(t.dnMoreNoEn, key: model.hotkeyLabel)))
        PaneScaffold(title: title, sub: sub) {
            VStack(alignment: .leading, spacing: SetupScale.pt(16)) {
                if blocked {
                    SetupGroup {
                        SetupRow(symbol: f.readiness.micFirst ? "mic" : "character.cursor.ibeam",
                                 label: f.readiness.micFirst ? t.pMic : t.pAx,
                                 caption: f.readiness.micFirst ? t.pMicC : t.pAxC, divider: false) {
                            Button(t.pMicB) { model.allowMissing() }
                                .buttonStyle(.borderedProminent).tint(Ink.lazur).keyboardShortcut(.defaultAction)
                                .focused(focus, equals: .mic)
                        }
                    }
                }
                SetupGroup {
                    ForEach(Array(f.doneRows.enumerated()), id: \.offset) { i, row in
                        SetupRow(label: t.n[row.language] ?? "", caption: caption(row), divider: i < f.doneRows.count - 1) {
                            if blocked { SetupState(color: Ink.text3, text: t.dnWait) } else { control(row) }
                        }
                    }
                }
            }
        } footer: {
            BackButton(model: model)
            if f.showsTryCloud && !blocked, let l = f.cloudPick { Button(t.dnTry(l)) { model.tryCloud() } }
            Spacer()
            if ready && !blocked {
                Button(t.close) { model.next() }
                    .buttonStyle(.borderedProminent).tint(Ink.lazur).keyboardShortcut(.defaultAction)
                    .focused(focus, equals: .primary)
            } else {
                Button(t.close) { model.next() }
            }
        }
    }

    /// F-03: where the language really goes (the shared route), or that it still needs a key.
    /// English is chosen but its route has no key yet (a hosted engine with none on file).
    private var englishWaits: Bool { model.flow.languages.contains(.en) && !model.route(.en).ready }

    private func caption(_ row: SetupFlow.DoneRow) -> String {
        let t = model.strings
        switch row.status {
        case .connectButton: return t.dnNeeds
        // Regression pass 2026-10-20: the status on the right already says "Needs an API key"; the caption says where
        // the language goes, as on Home.
        case .needsKey, .readyOnDevice, .readyCloud:
            switch model.route(row.language).place {
            case .onMac: return t.dnLocal
            case .cloud(let name): return name ?? model.flow.provider.displayName
            }
        }
    }

    @ViewBuilder private func control(_ row: SetupFlow.DoneRow) -> some View {
        let t = model.strings
        switch row.status {
        case .readyOnDevice, .readyCloud:
            if row.language == .en && englishWaits { SetupState(color: Ink.warn, text: t.dnNeeds) } else { SetupState(text: t.dnReady) }
        case .connectButton:
            Button(t.dnConnect) { model.connectLater() }
                .buttonStyle(.borderedProminent).tint(Ink.lazur).keyboardShortcut(.defaultAction)
                .focused(focus, equals: .primary)
        case .needsKey: SetupState(color: Ink.warn, text: t.dnNeeds)
        }
    }
}
