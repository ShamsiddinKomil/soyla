import SwiftUI
import AppKit
import ServiceManagement

// APP-1 (c): Privacy & data (prototype `privacy`), Permissions, Dictation, Hotkey, Pill, About and Developer at the
// app scale. One subtitle line, 2–4-word captions (the rest in ⓘ), setup's status words, only the primary filled.

// MARK: Privacy & data

struct PrivacyPage: View {
    /// Docs captures show a generic device, never this Mac's (a headset name can carry its owner's name).
    @Environment(\.docsCapture) private var docsCapture
    @ObservedObject var m: SettingsModel
    @ObservedObject var status: AppStatus
    @State private var loginStatus = SMAppService.mainApp.status
    @State private var loginError: String?
    private var t: AppStrings { .for(m.s.uiLanguage) }

    var body: some View {
        let home = HomeState.current(status: status, settings: m.s)
        AppPage(title: t.pvTitle, sub: t.pvSub, info: (t.pvTitle, t.pvInfo)) {
            AppSection(title: t.pvWhere) {
                ForEach(Array(home.rows.enumerated()), id: \.offset) { i, row in
                    AppRow(label: t.n[row.language] ?? row.language.rawValue, divider: i < home.rows.count - 1) { goes(home.readiness.shown(row.status)) }
                }
            }
            AppSection(title: t.recs) {
                AppRow(label: t.keep, caption: t.keepC, info: (t.keepA, [t.keepI])) {
                    Picker(t.keep, selection: $m.s.retention) {
                        ForEach(retentionChoices, id: \.self) { Text(retention($0)).tag($0) }
                    }.appControl()
                }
                AppRow(label: t.folder, caption: AppStrings.folderPath(SoylaPaths.root), divider: false) {
                    Button(t.finder) {
                        SoylaPaths.ensureDirectories()
                        NSWorkspace.shared.activateFileViewerSelecting([SoylaPaths.recordings])
                    }
                }
                .help((SoylaPaths.root.path as NSString).abbreviatingWithTildeInPath)
            }
            AppSection(title: t.mic) {
                AppRow(label: t.warm, caption: t.warmC, info: (t.warmA, [t.warmI])) {
                    Picker(t.warm, selection: $m.s.micWarmMode) {
                        ForEach(MicWarmMode.allCases, id: \.self) { Text(warm($0)).tag($0) }
                    }.appControl()
                }
                AppRow(label: t.builtin, caption: t.builtinNow(docsCapture ? "MacBook Microphone" : AudioDevices.activeInputName(preferBuiltIn: m.s.preferBuiltInMic)), divider: false) {
                    Toggle(t.builtin, isOn: $m.s.preferBuiltInMic).toggleStyle(.app).appControl()
                }
            }
            AppSection(title: t.startup) {
                AppRow(label: t.login, caption: loginError ?? (loginStatus == .requiresApproval ? t.loginApproval : nil), divider: false) {
                    Toggle(t.login, isOn: Binding(
                        get: { loginStatus == .enabled || loginStatus == .requiresApproval },
                        set: { on in
                            do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }; loginError = nil }
                            catch { loginError = t.loginFailed(error.localizedDescription) }
                            loginStatus = SMAppService.mainApp.status
                        })).toggleStyle(.app).appControl()
                }
            }
        }
        .onAppear { loginStatus = SMAppService.mainApp.status }
    }

    /// One fact per language: it stays here, it goes to a service, or it's off for want of a key (saffron).
    @ViewBuilder private func goes(_ s: HomeState.LangStatus) -> some View {
        switch s {
        case .onMac:
            Label(t.stays, systemImage: "lock").font(Ink.Font.appCaption).foregroundStyle(Ink.text2)
        case .cloud(let name):
            HStack(spacing: 6) { Text(t.rMac); Image(systemName: "arrow.right").font(.system(size: 11)); Text(name ?? t.cloudOnly) }
                .font(Ink.Font.appCaption).foregroundStyle(Ink.text2)
        case .needsKey: SetupState(color: Ink.warn, text: t.needsKey, font: Ink.Font.appCaption)
        case .off: SetupState(color: Ink.warn, text: t.offW, font: Ink.Font.appCaption)
        case .blocked: SetupState(color: Ink.text3, text: t.waitPerms, font: Ink.Font.appCaption)
        }
    }

    /// The prototype offers Don't keep / 14 days / Forever; a value saved by an older build stays selectable.
    private var retentionChoices: [AudioRetention] {
        var c: [AudioRetention] = [.neverStore, .deleteAfter14Days, .keep]
        if !c.contains(m.s.retention) { c.insert(m.s.retention, at: 0) }
        return c
    }

    private func retention(_ r: AudioRetention) -> String {
        switch r {
        case .neverStore: t.retNever
        case .deleteAfter14Days: t.ret14
        case .keep: t.retForever
        case .deleteAfter7Days: t.ret7
        case .deleteAfterRun: t.retAfterRun
        }
    }

    private func warm(_ w: MicWarmMode) -> String {
        switch w { case .off: t.warmOff; case .idleClose30s: t.warm30; case .always: t.warmOn }
    }
}

// MARK: Permissions

struct PermissionsPage: View {
    @ObservedObject var m: SettingsModel
    @ObservedObject var status: AppStatus
    let openSetup: (SetupStep) -> Void
    @State private var fnUsage: Int?

    private var t: AppStrings { .for(m.s.uiLanguage) }
    private var st: SetupStrings { .shown(m.s.uiLanguage) }

    /// Setup's rule: Input Monitoring shows only when Accessibility is on and still no key event reached the tap.
    static func showsInputMonitoring(_ p: PermissionState) -> Bool { p.ax && !p.inputMonitoringOK }

    var body: some View {
        let p = status.permissions
        let key = m.s.hotkey.shortLabel
        let fnRow = m.s.hotkey == .fn
        let fnOK = fnUsage == 0
        let im = Self.showsInputMonitoring(p)
        let speech = OnDeviceAvailability.showsSpeechPermissionRow(osMajor: AppStatus.osMajor, provider: m.s.provider)
        let speechOK = p.speech == .authorized
        let missing = [p.mic != .granted, !p.ax, fnRow && !fnOK, im, speech && !speechOK]
        let first = missing.firstIndex(of: true)
        AppPage(title: t.page[.permissions] ?? "", sub: t.permSub) {
            AppSection(title: t.perms) {          // V-24: one status per row, none on the header
                AppRow(symbol: "mic", label: t.pMic, caption: p.mic == .denied ? st.pMicDenied : t.pMicC) {
                    allow(p.mic == .granted, primary: first == 0) { openSetup(.permissions) }
                }
                AppRow(symbol: "character.cursor.ibeam", label: t.pAx, caption: t.pAxC, divider: fnRow || im || speech) {
                    allow(p.ax, primary: first == 1) { openSetup(.permissions) }
                }
                if fnRow {
                    // V-24: a setting, not a permission: "● Set" over the state macOS shows ("Do Nothing").
                    AppRow(symbol: "globe", label: st.pFn, caption: fnOK ? MacTerms.name("Do Nothing") : st.fnCaption(usage: fnUsage),
                           divider: im || speech) {
                        allow(fnOK, primary: first == 2, title: st.pFnB, done: t.pFnSet) { openSetup(.permissions) }
                    }
                }
                if im {
                    AppRow(symbol: "keyboard", label: SetupStrings.fill(st.pIm, key: key), caption: st.pImC, divider: speech) {
                        allow(false, primary: first == 3, title: st.pSet) {
                            _ = Permissions.inputMonitoring(prompt: true)
                            PermissionLinks.open(PermissionLinks.inputMonitoring)
                        }
                    }
                }
                if speech {
                    AppRow(symbol: "waveform", label: t.pSpeech, caption: t.pSpeechC, divider: false) {
                        allow(speechOK, primary: first == 4) {
                            Task { _ = await OnDeviceProbe.requestSpeechAuthorization(); status.refreshPermissions() }
                            PermissionLinks.open(PermissionLinks.speechRecognition)
                        }
                    }
                }
            }
        }
        .onAppear { fnUsage = SystemSurfaces.fnUsage() }
    }

    /// "● Allowed", or the one button (filled only for the first thing missing).
    @ViewBuilder private func allow(_ ok: Bool, primary: Bool, title: String? = nil, done: String? = nil,
                                    _ action: @escaping () -> Void) -> some View {
        if ok {
            SetupState(text: done ?? st.pOk, font: Ink.Font.appCaption)
        } else if primary {
            Button(title ?? t.pMicB, action: action).buttonStyle(.borderedProminent).tint(Ink.lazur)
        } else {
            Button(title ?? t.pMicB, action: action).buttonStyle(.bordered)
        }
    }
}

// MARK: Dictation

struct DictationPage: View {
    @ObservedObject var m: SettingsModel
    fileprivate var t: AppStrings { .for(m.s.uiLanguage) }

    var body: some View {
        AppPage(title: t.page[.dictation] ?? "", sub: t.dicSub) {
            // The free engine has one model, one language and no correction pass: hidden, not reset. (V-16: no read-only
            // "Engine" card here; the Languages page says where each language runs.)
            if m.s.provider != .apple {
                AppSection {
                    AppRow(label: t.dLang, caption: t.dLangC, info: (t.dLang, [t.dLangI])) {
                        Picker(t.dLang, selection: Binding(get: { m.s.languageHint ?? "" }, set: { m.s.languageHint = $0.isEmpty ? nil : $0 })) {
                            Text(t.langAuto).tag("")
                            ForEach(SpokenLanguage.allCases, id: \.self) { Text(t.n[$0] ?? $0.rawValue).tag($0.rawValue) }
                        }.appControl()
                    }
                    AppRow(label: t.dClean, caption: t.dCleanC, info: (t.dClean, [t.dCleanI])) {
                        Picker(t.dClean, selection: $m.s.cleanupLevel) {
                            ForEach(CleanupLevel.allCases, id: \.self) { Text($0 == .off ? t.cleanOff : t.cleanLight).tag($0) }
                        }.appControl()
                    }
                    sounds
                }
            } else {
                AppSection { sounds }
            }
            // HOTKEY-1: where the text goes is about dictation, not the key (moved from the Hotkey page).
            AppSection(title: t.hkWhere) {
                AppRow(label: t.hkPaste, caption: t.hkPasteC, divider: false) {
                    Toggle(t.hkPaste, isOn: $m.s.pasteEnabled).toggleStyle(.app).appControl()
                }
            }
            DictionarySections(m: m, t: t)
        }
    }
}

/// V-16: the personal dictionary as two sections at the app scale: replacements (heard → written) and spelling hints.
/// The long explanations sit in the ⓘ.
struct DictionarySections: View {
    @ObservedObject var m: SettingsModel
    let t: AppStrings

    var body: some View {
        AppSection {
            let full = m.s.dictionary.count >= ReplacementDictionary.maxEntries
            AppRow(label: t.dRepl, caption: full ? t.d.dcLimit(ReplacementDictionary.maxEntries) : t.dReplC,
                   info: (t.dRepl, [t.d.dcIntro]), divider: !m.s.dictionary.isEmpty) {
                Button(t.dAdd) { m.s.dictionary.append(DictionaryEntry(from: "", to: "")) }.disabled(full)
            }
            ForEach(Array(m.s.dictionary.indices), id: \.self) { i in
                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        TextField(t.d.dcHeard, text: field(i, \.from)).textFieldStyle(.roundedBorder).controlSize(.large)
                            .accessibilityLabel(t.d.dcHeard)
                        Image(systemName: "arrow.right").font(.system(size: 13)).foregroundStyle(Ink.text2).accessibilityHidden(true)
                        TextField(t.d.dcWrite, text: field(i, \.to)).textFieldStyle(.roundedBorder).controlSize(.large)
                            .accessibilityLabel(t.d.dcWrite)
                        Button { if i < m.s.dictionary.count { m.s.dictionary.remove(at: i) } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).accessibilityLabel(t.d.dcRemove)
                    }
                    .padding(.horizontal, SetupScale.pt(16)).padding(.vertical, 10)
                    if i < m.s.dictionary.count - 1 { Hairline().padding(.leading, SetupScale.pt(16)) }
                }
            }
        }
        AppSection {
            AppRow(label: t.dSpell, caption: t.dSpellC, info: (t.dSpell, [t.d.dcVocab])) { EmptyView() }
            TextEditor(text: $m.vocabularyText)
                .font(.system(size: SetupScale.type(13))).frame(height: 76)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: Ink.rControl, style: .continuous).fill(Ink.well))
                .overlay(RoundedRectangle(cornerRadius: Ink.rControl, style: .continuous).strokeBorder(Ink.hairline))
                .accessibilityLabel(t.dSpell)
                .padding(.horizontal, SetupScale.pt(16)).padding(.top, 4).padding(.bottom, 16)
        }
    }

    private func field(_ i: Int, _ kp: WritableKeyPath<DictionaryEntry, String>) -> Binding<String> {
        Binding(get: { i < m.s.dictionary.count ? m.s.dictionary[i][keyPath: kp] : "" },
                set: { if i < m.s.dictionary.count { m.s.dictionary[i][keyPath: kp] = $0 } })
    }
}

extension DictationPage {
    /// F-23: what you hear while dictating belongs with dictation, with a caption like every other control.
    /// Picking a set plays it, like main's Settings → Sounds; the slider plays the start cue when let go.
    @ViewBuilder var sounds: some View {
        AppRow(label: t.plSounds, caption: t.plSoundsC) {
            HStack(spacing: 8) {
                Button(t.plPlay) { SettingsView.previewSounds(m.s.soundSet, m.s.soundVolume) }
                    .disabled(m.s.soundSet == .off)
                Picker(t.plSounds, selection: $m.s.soundSet) {
                    ForEach(SoundSet.allCases, id: \.self) { Text(t.d.sound($0)).tag($0) }
                }.appControl()
            }
            .onChange(of: m.s.soundSet) { _, set in SettingsView.previewSounds(set, m.s.soundVolume) }
        }
        AppRow(label: t.plVolume, divider: false) {
            Slider(value: $m.s.soundVolume, in: 0.1...1) { editing in
                if !editing { Sounds.play(.start, set: m.s.soundSet, volume: m.s.soundVolume) }
            }
            .frame(width: 160).controlSize(.small).disabled(m.s.soundSet == .off)
            .accessibilityLabel(t.plVolume)
        }
    }
}

// MARK: Hotkey

struct HotkeyPage: View {
    @ObservedObject var m: SettingsModel
    private var t: AppStrings { .for(m.s.uiLanguage) }
    /// "Press 🌐 key to" (nil = the macOS default); read on appear and whenever Soyla comes back to the front.
    @State private var fnUsage: Int? = 0

    var body: some View {
        let key = m.s.hotkey
        AppPage(title: t.page[.hotkey] ?? "", sub: t.hkSub) {
            AppSection(title: t.hkHold, info: key == .fn ? (t.hkHold, [t.hkHoldI]) : nil) {
                VStack(alignment: .leading, spacing: 14) {
                    MacBottomRow(selection: key, pressed: m.keyTest == .held) { m.s.hotkey = $0 }
                    HStack(spacing: 12) {
                        test
                        Spacer(minLength: 12)
                        more
                    }
                }
                .padding(16)
                if key == .fn && fnUsage != 0 {
                    let st = SetupStrings.shown(m.s.uiLanguage)
                    Hairline().padding(.leading, 16)
                    AppRow(symbol: "globe", label: st.pFn, caption: st.fnCaption(usage: fnUsage), divider: false) {
                        Button(st.pFnB) { openKeyboard() }
                    }
                }
            }
            AppSection(title: t.hkDoes) {
                AppRow(label: t.hkGHold, caption: t.hkGHoldC) { KeyChip(label: t.d.hotkey(key)) }
                AppRow(label: t.hkGTwice, caption: t.hkGTwiceC) {
                    HStack(spacing: 4) { KeyChip(label: t.d.hotkey(key)); KeyChip(label: t.d.hotkey(key)) }
                }
                AppRow(label: t.cancel, divider: false) { KeyChip(label: "esc") }
            }
        }
        .onAppear { m.keyTest = .idle; readFn() }
        .onChange(of: m.s.hotkey) { _, _ in m.keyTest = .idle; readFn() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in readFn() }
    }

    /// Hold the key: the cap goes down, let go: "Works". Nothing is recorded or sent while this page is in front.
    @ViewBuilder private var test: some View {
        let name = t.d.hotkey(m.s.hotkey)
        switch m.keyTest {
        case .idle:
            Label(t.hkTest(name), systemImage: "hand.point.up.left")
                .font(Ink.Font.appCaption).foregroundStyle(Ink.text2)
        case .held:
            Label(t.hkHeld, systemImage: "waveform")
                .font(Ink.Font.appCaption.weight(.medium)).foregroundStyle(Ink.lazur)
        case .worked:
            Label(t.hkWorks, systemImage: "checkmark.circle.fill")
                .font(Ink.Font.appCaption.weight(.medium)).foregroundStyle(Ink.ok)
        }
    }

    /// Right ⌃ (external keyboards), F13 and ⌃⇧Space: a menu, named after the key when one of them is chosen.
    private var more: some View {
        let chosen = KeyPick.more.contains(m.s.hotkey)
        return Menu {
            ForEach(KeyPick.more, id: \.self) { c in
                Button { m.s.hotkey = c } label: {
                    if c == m.s.hotkey { Label(t.d.hotkey(c), systemImage: "checkmark") } else { Text(t.d.hotkey(c)) }
                }
            }
        } label: {
            Text(chosen ? t.d.hotkey(m.s.hotkey) : t.hkMore)
        }
        .menuStyle(.button).fixedSize().tint(chosen ? Ink.lazur : nil)
        .accessibilityLabel(t.hkMore)
    }

    private func readFn() { fnUsage = m.s.hotkey == .fn ? SystemSurfaces.fnUsage() : 0 }
    private func openKeyboard() {
        if let u = URL(string: SystemSurfaces.keyboard) { NSWorkspace.shared.open(u) }
    }
}

// MARK: Pill

struct PillPage: View {
    @ObservedObject var m: SettingsModel
    private var t: AppStrings { .for(m.s.uiLanguage) }

    var body: some View {
        AppPage(title: t.page[.pill] ?? "", sub: t.plSub) {
            AppSection(title: t.plPos, info: (t.plPos, [t.plPosI])) {
                HStack(alignment: .center, spacing: 24) {
                    PillScreenMap(position: m.s.pillPosition, anchor: m.s.pillAnchor, pick: { spot in
                        let v = spot.setting
                        m.s.pillPosition = v.position; m.s.pillAnchor = v.anchor
                    }, language: m.s.uiLanguage)
                    VStack(alignment: .leading, spacing: 12) {
                        Text(PillSpot.from(position: m.s.pillPosition, anchor: m.s.pillAnchor).flatMap { t.d.spot[$0] } ?? t.plOwn)
                            .font(Ink.Font.appLabel).foregroundStyle(Ink.text)
                        HStack(spacing: 8) {
                            Button(t.plPlace) { NotificationCenter.default.post(name: FloatingPanel.placeRequested, object: nil) }
                            Button(t.plReset) { m.s.pillPosition = .bottomCenter; m.s.pillAnchor = nil }
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(16)
                if let until = m.s.pillSnoozedUntil, until > Date().timeIntervalSince1970 {
                    Hairline().padding(.leading, 16)
                    AppRow(label: t.plHidden(Date(timeIntervalSince1970: until).formatted(date: .omitted, time: .shortened)),
                           caption: t.plHiddenC, divider: false) {
                        Button(t.plShow) { m.s.pillSnoozedUntil = nil }
                    }
                }
            }
            AppSection(title: t.plWhile) {
                if m.s.provider != .apple {   // the free engine has no live preview (V3); the stored value is kept
                    AppRow(label: t.plLive, caption: t.plLiveC, info: (t.plLive, [t.plLiveI])) {
                        Toggle(t.plLive, isOn: $m.s.livePreview).toggleStyle(.app).appControl()
                    }
                }
                AppRow(label: t.plDetails, caption: t.plDetailsC) {
                    Toggle(t.plDetails, isOn: $m.s.showDetails).toggleStyle(.app).appControl()
                }
                AppRow(label: t.plTouch, caption: t.plTouchC, info: (t.plTouch, [t.plTouchI]), divider: false) {
                    Picker(t.plTouch, selection: $m.s.minVoicedMs) {
                        Text(t.touchRelaxed).tag(150.0)
                        Text(t.touchNormal).tag(250.0)
                        Text(t.touchStrict).tag(400.0)
                    }.appControl()
                }
            }
        }
    }
}

// MARK: About

struct AboutPage: View {
    @ObservedObject var m: SettingsModel
    var onSetupAssistant: (() -> Void)?
    private var t: AppStrings { .for(m.s.uiLanguage) }

    var body: some View {
        AppPage(title: t.page[.about] ?? "", sub: t.abSub) {
            AppSection(info: (t.abUpdates, [t.abUpdatesI])) {
                AppRow(label: t.abVersion) { Text(Soyla.version).font(Ink.Font.appCaption).foregroundStyle(Ink.text2).monospacedDigit() }
                AppRow(label: t.abUpdates, caption: t.abDaily, info: (t.abUpdates, [t.abUpdatesI])) {
                    HStack(spacing: 12) {
                        Toggle(t.abDaily, isOn: $m.s.autoUpdateCheck).toggleStyle(.app).appControl()
                        Button(t.abCheck) {
                            Task { @MainActor in
                                if await UpdateCheck.run(silent: false, language: m.s.uiLanguage, onAvailable: { Updater.shared.offer($0) }) { m.s.lastUpdateCheck = Date() }
                            }
                        }
                    }
                }
                AppRow(label: t.abAuto, caption: t.abAutoC, info: (t.abAuto, [t.abAutoI])) {
                    Toggle(t.abAuto, isOn: $m.s.autoInstallUpdates).toggleStyle(.app).appControl()
                }
                AppRow(label: t.abSource, divider: onSetupAssistant != nil) {
                    if let u = URL(string: "https://github.com/ShamsiddinKomil/soyla") { Link(t.abGitHub, destination: u).font(Ink.Font.appCaption) }
                }
                if let onSetupAssistant {
                    AppRow(label: t.abSetup, caption: t.abSetupC, divider: false) { Button(t.abOpen, action: onSetupAssistant) }
                }
            }
        }
    }
}

// MARK: Developer (restyle only; English is fine for a developer tool)

struct DeveloperPage: View {
    @ObservedObject var m: SettingsModel
    private var t: AppStrings { .for(m.s.uiLanguage) }

    var body: some View {
        AppPage(title: t.page[.developer] ?? "", sub: t.devSub) {
            // V-15: the switch at the app scale, in the interface language; the lab controls below stay English.
            AppSection {
                AppRow(label: t.devMode, caption: t.devModeC, info: (t.devMode, [t.devModeI]), divider: false) {
                    Toggle(t.devMode, isOn: $m.s.developerMode).toggleStyle(.app).appControl()
                }
            }
            if m.s.developerMode { VStack(alignment: .leading, spacing: Ink.s6) { DeveloperSection(m: m, showsSwitch: false) } }
        }
    }
}
