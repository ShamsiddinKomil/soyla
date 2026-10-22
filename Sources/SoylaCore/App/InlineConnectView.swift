import SwiftUI
import AppKit
import Combine
import Observation

// APP-1 v3: the inline Connect panel's live side. The same save + check path as setup's Connect (`APIKeysModel`:
// save → test with the provider → verified), the same engine rule (`InlineConnect.engine`), no setup window.

@MainActor @Observable
final class InlineConnectModel {
    private(set) var c = InlineConnect()
    /// Bumped when a panel opens (scroll it into view, focus its field) and when one is cancelled (focus its row).
    private(set) var openToken = 0
    private(set) var cancelled: InlineConnect.Target?
    private(set) var cancelToken = 0

    @ObservationIgnored let keys = APIKeysModel()
    @ObservationIgnored let settings: SettingsModel
    @ObservationIgnored let status: AppStatus
    @ObservationIgnored private var sink: AnyCancellable?
    @ObservationIgnored private var pending: SetupProvider?

    init(settings: SettingsModel, status: AppStatus) {
        self.settings = settings
        self.status = status
        sink = keys.$rows.sink { [weak self] rows in self?.rowsChanged(rows) }
    }

    func open(_ t: InlineConnect.Target, provider: SetupProvider? = nil) {
        c.open(t, provider: provider ?? InlineConnect.defaultProvider(for: settings.s.provider))
        openToken += 1
        Log.info("inline connect: opened")
    }

    /// Cancel / Esc: close and give focus back to the row's button.
    func cancel() {
        guard c.target != nil else { return }      // Esc can reach both the panel and its Cancel button
        cancelled = c.target
        c.close()
        cancelToken += 1
    }

    /// Leaving the page closes the panel quietly.
    func close() { if c.target != nil { c.close() } }

    func setProvider(_ p: SetupProvider) { c.setProvider(p) }
    func edit(_ s: String) { c.edit(s) }

    /// `--preview` only: show a checked state without saving or sending anything.
    func simulate(draft: String, verdict: InlineConnect.Verdict) {
        c.edit(draft)
        if c.canSubmit { c.forceChecking() }
        c.checked(verdict)
    }

    func openSite() { if let u = c.provider.key.keysURL { NSWorkspace.shared.open(u) } }

    /// Saves through the existing key path and checks the key with the provider.
    func connect() {
        guard let v = c.submit() else {
            if case .failed(let f) = c.state { Log.info("inline connect: key refused before saving (\(f))") }
            return
        }
        let p = c.provider
        keys.refresh()
        keys.binding(p.key).wrappedValue = v
        keys.save(p.key)
        let row = keys.rows[p.key]
        if row?.testing == true { pending = p } else { finish(p, row) }
    }

    /// As in `SetupModel`: `test` clears `testing` before `refresh()` sets `verified`, and `@Published` fires on
    /// willSet, so the verdict is read one main-actor turn later.
    private func rowsChanged(_ rows: [KeyProvider: APIKeysModel.Row]) {
        guard let p = pending, let r = rows[p.key], !r.testing else { return }
        Task { @MainActor [weak self] in
            guard let self, self.pending == p else { return }
            self.finish(p, self.keys.rows[p.key])
        }
    }

    private func finish(_ p: SetupProvider, _ r: APIKeysModel.Row?) {
        pending = nil
        // A rejected key is rolled back (KeyRollback), so its row may be gone, or hold the key it replaced.
        guard let r, r.masked != nil || r.rejected else { c.checked(.failed(.notSaved)); Log.info("inline connect: key not saved"); return }
        if r.verified && !r.rejected {
            c.checked(.ok)
            if let k = InlineConnect.engine(after: p, spoken: settings.s.spokenLanguages, current: settings.s.provider) {
                settings.useCloudEngine(k)
            }
            settings.refreshKeyStatus()
            status.refresh()
            // F-19: the panel collapses into a Ready row; say it for VoiceOver.
            NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                                 userInfo: [.announcement: AppStrings.for(settings.s.uiLanguage).connected, .priority: NSAccessibilityPriorityLevel.high.rawValue])
            Log.info("inline connect: key connected (\(p.rawValue))")
        } else {
            let f: SetupKeyFailure = r.rejected ? .rejected : .unreachable
            c.checked(.failed(f))
            if r.rejected && r.masked != nil { keys.settleAfterRollback(p.key) }   // the old key is back and fine
            Log.info("inline connect: key check failed (\(f))")
        }
    }
}

/// The panel under a row (prototype-v3 `.cx`): service tiles, "1 Create an API key", "2 Paste … Connect", the result,
/// the lock line and Cancel. Well background, radius 10, padding 16, 16 from the group's edges.
struct InlineConnectPanel: View {
    let model: InlineConnectModel
    let t: AppStrings
    let combo: CloudCombo?
    @FocusState private var field: Bool

    private var s: SetupStrings { .for(model.settings.s.uiLanguage) }
    private var busy: Bool { model.c.state == .checking }

    var body: some View {
        let c = model.c
        VStack(alignment: .leading, spacing: 14) {
            // F-10: under the API key row the page's own Cloud picker already chose the service.
            if c.target != .key {
                HStack(spacing: 8) {
                    tile(.google, caption: t.gC)
                    tile(.openRouter, caption: t.oC)
                }
                .accessibilityElement(children: .contain).accessibilityLabel(t.service)
            }
            line(1) {
                Text(s.cS1)
                Button(s.cOpen(c.provider.host)) { model.openSite() }.buttonStyle(.bordered).controlSize(.small)
            }
            line(2) {
                // V-21: masked like setup's Connect (a key on screen is a key in every screen share).
                SecureField(s.cPh, text: Binding(get: { model.c.draft }, set: { model.edit($0) }))
                    .textFieldStyle(.roundedBorder).controlSize(.large)
                    .focused($field)
                    .disabled(busy)
                    .onSubmit { model.connect() }
                    .accessibilityLabel(t.key)
                if c.canSubmit {
                    Button(s.cConnect) { model.connect() }.buttonStyle(.borderedProminent).tint(Ink.lazur).controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button(busy ? s.cChecking : s.cConnect) {}.buttonStyle(.bordered).controlSize(.large).disabled(true)
                }
            }
            if case .failed(let f) = c.state {
                SetupStatus(color: Ink.warn, text: InlineConnect.message(f, t, s)).accessibilityAddTraits(.updatesFrequently)
            }
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "lock").font(.system(size: 11)).accessibilityHidden(true)
                    Text(InlineConnect.footnote(t, provider: c.provider, combo: combo, target: c.target ?? .key))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button(t.cxCancel) { model.cancel() }.buttonStyle(.plain).foregroundStyle(Ink.text2)
                    .keyboardShortcut(.cancelAction)
            }
            .font(.system(size: 13.5)).foregroundStyle(Ink.text2)
        }
        .padding(16)
        .tint(nil)      // "Open …" stays a neutral secondary; only Connect is filled (its own lazur)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Ink.well))
        .padding(.horizontal, 16).padding(.bottom, 16)
        .id(InlineConnectPanel.scrollID)
        .onExitCommand { model.cancel() }          // V-27: Esc from any control in the panel, not only the field
        .accessibilityElement(children: .contain).accessibilityLabel(t.key)
        .onAppear { focusField() }
        .onChange(of: model.c.state) { _, new in if case .failed = new { focusField() } }
    }

    static let scrollID = "inline-connect"

    private func focusField() {
        Task { @MainActor in try? await Task.sleep(for: .milliseconds(120)); field = true }
    }

    /// A service as a tile; the pair is a radio group (2 pt lazur ring on the chosen one).
    private func tile(_ p: SetupProvider, caption: String) -> some View {
        let on = model.c.provider == p
        return Button { model.setProvider(p) } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(p.displayName).font(.system(size: 14.5, weight: .medium)).foregroundStyle(Ink.text)
                Text(caption).font(.system(size: 13)).foregroundStyle(Ink.text2)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Ink.sheet))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(on ? Ink.lazur : Ink.hairline, lineWidth: on ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .accessibilityAddTraits(on ? [.isSelected, .isButton] : .isButton)
    }

    private func line<C: View>(_ n: Int, @ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 10) {
            Text("\(n)").font(.system(size: 12, weight: .semibold)).foregroundStyle(Ink.text2)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Ink.sheet)).overlay(Circle().strokeBorder(Ink.hairlineStrong))
                .accessibilityHidden(true)
            HStack(spacing: 12) { content() }.font(.system(size: 14.5)).foregroundStyle(Ink.text)
        }
    }
}

/// Scrolls the open panel fully into view (instant under Reduce Motion). Wrap a page's ScrollView content in it.
struct RevealInlineConnect: ViewModifier {
    let model: InlineConnectModel
    let proxy: ScrollViewProxy
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .onAppear { reveal() }
            .onChange(of: model.openToken) { _, _ in reveal() }
    }

    private func reveal() {
        guard model.c.target != nil else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(60))
            if reduceMotion { proxy.scrollTo(InlineConnectPanel.scrollID, anchor: .bottom) }
            else { withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(InlineConnectPanel.scrollID, anchor: .bottom) } }
        }
    }
}
