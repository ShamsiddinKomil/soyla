import SwiftUI

// APP-1 (b): Settings → Languages (was Engine), prototype `engine()`. Which groups show is `LanguagesPageState`
// (pure, tested); keys are added and replaced only through setup's Connect step (one guided path, one Keychain write).

struct LanguagesPage: View {
    @Environment(\.docsCapture) private var docsCapture
    @ObservedObject var m: SettingsModel
    @ObservedObject var keys: APIKeysModel
    @ObservedObject var status: AppStatus
    let openSetup: (SetupStep) -> Void
    /// v3: keys are connected and replaced inline (no setup window).
    let connect: InlineConnectModel
    let models = OnDeviceModels.shared
    @State private var chosen: KeyProvider?
    /// F-09: Remove key asks first.
    @State private var removing: KeyProvider?
    /// Esc / Cancel in the Replace… panel give focus back to Replace… (as Home's rows get it back; DESIGN.md "Inline Connect").
    @FocusState private var replaceFocused: Bool

    private var t: AppStrings { .for(m.s.uiLanguage) }
    private func hasKey(_ p: KeyProvider) -> Bool { keys.rows[p]?.masked != nil }
    private var service: KeyProvider { chosen ?? LanguagesPageState.defaultService(provider: m.s.provider, hasKey: hasKey) }

    var body: some View {
        let home = HomeState.current(status: status, settings: m.s)
        let st = LanguagesPageState(home: home, spoken: m.s.spokenLanguages, provider: m.s.provider, hasKey: hasKey,
                                    developerMode: m.s.developerMode)
        // Unscrolled whenever it fits (also what `--snapshot` can draw); a scroll view only when it doesn't.
        ViewThatFits(in: .vertical) {
            content(home, st)
            ScrollViewReader { proxy in
                ScrollView { content(home, st) }.modifier(RevealInlineConnect(model: connect, proxy: proxy))
            }
        }
        .onAppear { Task { await models.refresh(locale: m.s.onDeviceLocale) } }   // read when the page opens, never polled
        .onChange(of: connect.cancelToken) { _, _ in if connect.cancelled == .key { replaceFocused = true } }
        .confirmationDialog(t.keyRemoveQ, isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button(t.keyRemove, role: .destructive) {
                if let p = removing { keys.remove(p); status.refresh() }
                removing = nil
            }
            Button(t.cxCancel, role: .cancel) { removing = nil }
        } message: {
            Text(CloudNudge.combo(m.s.spokenLanguages ?? []).map(t.keyRemoveStops) ?? t.keyRemoveCloud)
        }
    }

    private func content(_ home: HomeState, _ st: LanguagesPageState) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(t.eTitle).font(Ink.Font.appTitle).tracking(-0.74).foregroundStyle(Ink.text).accessibilityAddTraits(.isHeader)
                InfoButton(label: t.eTitle, paragraphs: t.eInfo, width: 320)
            }
            Text(t.eSub).font(Ink.Font.appSub).foregroundStyle(Ink.text2).padding(.top, 10)
            if home.keychainNotice {
                Callout(.warn, status.keychain == .denied ? t.keychainDenied : t.keychainWaiting).padding(.top, 20)
            }
            YourLanguagesSection(home: home, primaryAllowed: true, t: t, connect: connect, onChange: { openSetup(.languages) },
                                 onUseCloud: { m.useCloudEngine(m.cloudTarget(hasKey: { status.keys[$0]?.verified ?? false })) })
                .padding(.top, 36)
            if st.showsEngineChoice { engine(st).padding(.top, 32) }
            if st.showsCloudSection { cloud(st).padding(.top, 32) }
            if st.showsOnMac { onMac.padding(.top, 32) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, Ink.appPaneTop).padding(.horizontal, Ink.appPaneSide).padding(.bottom, Ink.appPaneBottom)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(Ink.Font.appSection).foregroundStyle(Ink.text).accessibilityAddTraits(.isHeader).frame(minHeight: 28)
            content()
        }
    }

    // MARK: engine

    private func engine(_ st: LanguagesPageState) -> some View {
        section(t.eWhere) {          // F-25: what it is to the user, not how it's built
            SetupGroup {
                RadioRow(label: t.eCloud, caption: t.eCloudC, selected: st.engineIsCloud) {
                    m.useCloudEngine(m.cloudTarget(hasKey: hasKey))
                }
                RadioRow(label: t.eMac, caption: t.eMacC, selected: !st.engineIsCloud, divider: false) { m.useFreeEngine() }
            }
        }
    }

    // MARK: cloud

    private func cloud(_ st: LanguagesPageState) -> some View {
        section(t.eCloud) {
            SetupGroup {
                ForEach(st.services) { p in
                    RadioRow(label: p.label, caption: caption(p), selected: service == p) {
                        chosen = p
                        connect.close()
                        if st.engineIsCloud { m.useProvider(p) }     // Cloud on: the service is the engine's provider
                    }
                }
                if service == .custom { customRows } else { keyRow(service) }
                if st.showsModel && m.s.provider.keyProvider == service { modelRow }
            }
            if service == .custom { KeyCard(keys: keys, provider: .custom, language: m.s.uiLanguage) }
            if let r = keys.rows[service], r.source == .environment || r.source == .envFile, !docsCapture {
                Text(t.d.ceEnv(r.source == .environment))
                    .font(Ink.Font.caption).foregroundStyle(Ink.text2)
            }
        }
    }

    private func caption(_ p: KeyProvider) -> String {
        switch p { case .google: t.gC; case .openRouter: t.oC; case .custom: t.d.ceAny }
    }

    @ViewBuilder private func keyRow(_ p: KeyProvider) -> some View {
        let r = keys.rows[p] ?? APIKeysModel.Row()
        let open = connect.c.target == .key
        let sp: SetupProvider = p == .openRouter ? .openRouter : .google
        if let masked = r.masked {
            SetupRow(label: t.key, caption: masked, divider: m.s.provider.keyProvider == p && m.s.provider != .apple && !open) {
                HStack(spacing: 12) {
                    keyState(keys.status(p))
                    if !open {
                        Menu(t.replace) {
                            if r.source == .keychain { Button(t.keyRemove, role: .destructive) { removing = p } }
                        } primaryAction: { connect.open(.key, provider: sp) }
                        .menuStyle(.borderedButton).fixedSize()
                        .focused($replaceFocused)
                    }
                }
            }
        } else {
            // A key exists for the other service (the Cloud section shows only then): connect this one inline.
            SetupRow(label: t.key, caption: t.notAdded, divider: false) {
                if !open { Button(t.connect) { connect.open(.key, provider: sp) }.buttonStyle(.bordered) }
            }
        }
        if open { InlineConnectPanel(model: connect, t: t, combo: nil) }
    }

    @ViewBuilder private func keyState(_ s: APIKeysModel.Status) -> some View {
        switch s {
        case .connected: SetupState(color: Ink.ok, text: t.connected, font: Ink.Font.appCaption)
        case .checking: SetupState(color: Ink.lazur, text: t.keyChecking, font: Ink.Font.appCaption)
        case .rejected: SetupState(color: Ink.signal, text: t.keyRejected, font: Ink.Font.appCaption)
        case .unchecked, .empty: SetupState(color: Ink.warn, text: t.keyUnchecked, font: Ink.Font.appCaption)
        }
    }

    private var modelRow: some View {
        // F-24: the caption describes the model that is selected.
        SetupRow(label: t.model, caption: m.s.sttModel.contains("lite") ? t.modelC : t.modelCFull, divider: false) {
            Picker(t.model, selection: $m.s.sttModel) {
                let ids = ModelNames.curated(m.s.provider) + (ModelNames.curated(m.s.provider).contains(m.s.sttModel) ? [] : [m.s.sttModel])
                ForEach(ids, id: \.self) { Text(LanguagesPageState.modelName($0)).tag($0) }
            }
            .pickerStyle(.menu).labelsHidden().fixedSize()
        }
    }

    /// Developer tool: an OpenAI-compatible server (its rows still follow the interface language).
    @ViewBuilder private var customRows: some View {
        SetupRow(label: t.d.ceBase, caption: t.d.ceBaseC) {
            TextField(t.d.ceBase, text: Binding(get: { m.s.customBaseURL ?? "" }, set: { m.s.customBaseURL = $0.isEmpty ? nil : $0 }),
                      prompt: Text("http://localhost:8080/v1"))
                .well().frame(width: 240)
        }
        SetupRow(label: t.model, divider: false) { TextField(t.model, text: $m.s.sttModel).well().frame(width: 240) }
    }

    // MARK: on this Mac

    private var onMac: some View {
        let s = EngineCopy.status(models.state, failure: models.lastFailure, language: m.s.uiLanguage)
        return section(t.onMac) {
            SetupGroup {
                SetupRow(symbol: "desktopcomputer", label: t.macModel, caption: t.macModelC, divider: s.progress != nil) {
                    HStack(spacing: 12) {
                        SetupState(color: s.tone.color, text: s.tone == .ok ? t.readyW : s.text, font: Ink.Font.appCaption)
                        if let a = s.action { Button(a.title(m.s.uiLanguage)) { run(a) } }
                    }
                }
                if let p = s.progress {
                    ProgressView(value: p).tint(Ink.lazur).padding(.horizontal, 16).padding(.vertical, 12)
                        .accessibilityLabel(t.macModel).accessibilityValue("\(Int((p * 100).rounded())) %")
                }
            }
        }
    }

    private func run(_ a: EngineCopy.Action) {
        let locale = m.s.onDeviceLocale
        Task { @MainActor in
            switch a {
            case .download, .retry: await models.ensureReady(locale: locale)
            case .allowSpeech:
                await models.requestPermission(locale: locale)
                if OnDeviceProbe.speechAuthorization() != .authorized { PermissionLinks.open(PermissionLinks.speechRecognition) }
            }
        }
    }
}
