import SwiftUI
import AppKit

// FE-5: Settings → Engine (the page that replaced "API keys"): the free on-device engine and the cloud engine, side by
// side. Copy and decisions live in `EngineCopy` (pure, tested); this file only draws them.

extension SettingsModel {
    /// Pick the free engine. The stored cloud choices (model, language, cleanup) are not touched except the display
    /// model, so switching back restores a sensible cloud default.
    func useFreeEngine() {
        guard s.provider != .apple else { return }
        var n = s
        n.provider = .apple
        n.sttModel = n.onDeviceLocale          // display only (R3)
        n.cleanupModel = ProviderKind.apple.defaultCleanupModel
        s = n
    }

    /// Pick the cloud engine (`kind` from `EngineCopy.cloudTarget`), with that provider's default models.
    func useCloudEngine(_ kind: ProviderKind) {
        guard kind != .apple else { return }
        guard s.provider != kind else { return }
        var n = s
        n.provider = kind
        n.sttModel = kind.defaultSTTModel
        n.cleanupModel = kind.defaultCleanupModel
        s = n
    }

    /// The cloud provider the Cloud card selects, given which keys exist.
    func cloudTarget(hasKey: (KeyProvider) -> Bool) -> ProviderKind {
        EngineCopy.cloudTarget(hasKey: hasKey, developerMode: s.developerMode)
    }
}

extension EngineCopy.Tone {
    var color: Color {
        switch self { case .ok: Ink.ok; case .pending: Ink.lazur; case .warn: Ink.warn; case .neutral: Ink.text4 }
    }
}

/// The free card's status: a dot and a word, a button when there is something to do, a bar while downloading.
struct FreeEngineStatus: View {
    let models: OnDeviceModels
    let locale: String
    var divider = true

    var body: some View {
        let st = EngineCopy.status(models.state, failure: models.lastFailure)
        Row(label: "Status", caption: nil, divider: divider && st.progress == nil) {
            HStack(spacing: Ink.s3) {
                StatusLine(color: st.tone.color, text: st.text)
                if let a = st.action {
                    Button(a.title) { run(a) }.controlSize(.small)
                }
            }
        }
        if let p = st.progress {
            WideRow(divider: divider) {
                ProgressView(value: p).tint(Ink.lazur)
                    .accessibilityLabel("Model download")
                    .accessibilityValue("\(Int((p * 100).rounded())) percent")
            }
        }
    }

    private func run(_ a: EngineCopy.Action) {
        let models = models, locale = locale
        Task { @MainActor in
            switch a {
            case .download, .retry:
                await models.ensureReady(locale: locale)
            case .allowSpeech:
                await models.requestPermission(locale: locale)
                // Denied earlier: the prompt won't show again, so send them to the right System Settings list.
                if OnDeviceProbe.speechAuthorization() != .authorized { PermissionLinks.open(PermissionLinks.speechRecognition) }
            }
        }
    }
}

/// Settings → Engine.
struct EnginePage: View {
    @ObservedObject var m: SettingsModel
    @ObservedObject var keys: APIKeysModel
    let status: AppStatus?
    let models = OnDeviceModels.shared

    private var freeSelected: Bool { m.s.provider == .apple }

    var body: some View {
        if let status, status.keychain != .ready { KeychainNotice(access: status.keychain) }
        SettingsGroup {
            ProviderRow(title: EngineCopy.freeTitle, badge: EngineCopy.freeBadge, subtitle: EngineCopy.freeSubtitle,
                        selected: freeSelected) { m.useFreeEngine() }
            ProviderRow(title: EngineCopy.cloudTitle, badge: nil, subtitle: EngineCopy.cloudSubtitle,
                        selected: !freeSelected, divider: false) {
                m.useCloudEngine(m.cloudTarget(hasKey: { keys.rows[$0]?.masked != nil }))
            }
        }
        SettingsGroup(title: EngineCopy.freeTitle, footer: EngineCopy.freePrivacy) {
            FreeEngineStatus(models: models, locale: m.s.onDeviceLocale, divider: false)
        }
        VStack(alignment: .leading, spacing: Ink.s2) {
            Text("Cloud").font(Ink.Font.subhead).foregroundStyle(Ink.text).padding(.leading, 2)
            Text(EngineCopy.cloudNote).font(Ink.Font.caption).foregroundStyle(Ink.text2).padding(.leading, 2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, -Ink.s3)
        APIKeysSection(keys: keys, providers: KeyProvider.allCases.filter { $0 != .custom || m.s.provider == .custom || m.s.developerMode },
                       settings: m)
        .onAppear { Task { await models.refresh(locale: m.s.onDeviceLocale) } }   // read when the page opens, never polled
    }
}

/// A provider as a selectable row: a radio dot, the name (with an optional badge) and one line on cost and fit.
struct ProviderRow: View {
    let title: String, badge: String?, subtitle: String, selected: Bool
    var divider = true
    let select: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            Button(action: select) {
                HStack(alignment: .top, spacing: Ink.s3) {
                    Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(selected ? Ink.lazur : Ink.text3).padding(.top, 1)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: Ink.s2) {
                            Text(title).font(selected ? Ink.Font.subhead : Ink.Font.body).foregroundStyle(Ink.text)
                            if let badge {
                                Text(badge).font(Ink.Font.caption.weight(.medium)).foregroundStyle(Ink.lazur)
                                    .padding(.horizontal, 6).padding(.vertical, 1)
                                    .background(Capsule().fill(Ink.lazurWash))
                            }
                        }
                        Text(subtitle).font(Ink.Font.caption).foregroundStyle(Ink.text2).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, Ink.s4).padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(title): \(subtitle)")
            .accessibilityAddTraits(selected ? .isSelected : [])
            if divider { Hairline().padding(.leading, Ink.s4) }
        }
    }
}
