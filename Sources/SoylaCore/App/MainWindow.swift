import SwiftUI
import AppKit
import AVFoundation

/// Live app status: the single `PermissionState` (one poller for the whole app — onboarding, Home, Settings, pill and
/// menu bar all read it), plus keys and recent runs for the main window.
/// Permissions: checked every 1 s while any is missing, every 2 s otherwise (catches revocation), and right away on
/// app activation and wake. Keys/runs: every 2 s.
@MainActor
final class AppStatus: ObservableObject {
    @Published private(set) var permissions = PermissionState()
    /// Per provider: masked key + whether it matches the last successful Test. Missing providers are absent.
    @Published var keys: [KeyProvider: KeyState] = [:]
    /// The launch key read: the one-time Keychain move (dialog) or a broken key file. While not `.ready`, a missing key is not missing.
    @Published var keychain: Secrets.KeychainAccess = .ready
    @Published var lastRun: RunRecord? = nil
    @Published var today = TodayStats()
    /// When the hotkey tap last saw any key event (set by AppDelegate; nil while no tap runs).
    var lastKeyEventAt: () -> Date? = { nil }
    private var timer: Timer?
    private var tick = 0
    private var observers: [NSObjectProtocol] = []

    /// `loadNow: false` (tests): no first read, so nothing touches the Keychain or History.
    init(loadNow: Bool = true) { if loadNow { refresh() } }

    var accessibility: Bool { permissions.ax }
    var inputMonitoring: Bool { permissions.inputMonitoringOK }
    var allPermissions: Bool { permissions.allGranted }

    func start() {
        guard timer == nil, !frozen else { return }
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in Task { @MainActor in self?.onTick() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        let recheck: @Sendable (Notification) -> Void = { [weak self] _ in Task { @MainActor in self?.refreshPermissions() } }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main, using: recheck))
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main, using: recheck))
        refresh()
    }

    private func onTick() {
        tick += 1
        if tick % 2 == 0 { refresh() } else if !permissions.allGranted { refreshPermissions() }
    }

    func refreshPermissions() {
        guard !frozen else { return }
        var p = permissions
        p.ax = Permissions.accessibilityTrusted(prompt: false)
        p.inputMonitoring = Permissions.inputMonitoring(prompt: false)
        p.mic = PermissionState.mic(AVCaptureDevice.authorizationStatus(for: .audio))
        // Speech Recognition matters only for the free engine on 14–15 (a cheap class-method read; skipped on 26).
        if OnDeviceAvailability.usesLegacyPermission(osMajor: Self.osMajor) { p.speech = OnDeviceProbe.speechAuthorization() }
        // Sticky proof of delivery, dropped when the tap can't exist any more.
        p.eventsFlowing = p.canListen && (p.eventsFlowing || lastKeyEventAt() != nil)
        if p != permissions { permissions = p }
    }

    /// `--preview` / `docs-shots` only: draw a made-up permission state. Freezes the status, so a view that calls
    /// `start()` (MainView) never starts the poller that would replace it with this Mac's real grants.
    func previewPermissions(_ p: PermissionState) { permissions = p; frozen = true }
    private(set) var frozen = false

    func refresh() {
        refreshPermissions()
        var k: [KeyProvider: KeyState] = [:]
        for p in KeyProvider.allCases {
            if let hit = Secrets.find(p) { k[p] = KeyState(masked: Secrets.masked(hit.value), verified: Secrets.isVerified(p, key: hit.value)) }
        }
        keys = k
        let access = Secrets.keychainAccess
        if access != keychain { keychain = access }
        let runs = ((try? RunLog.readAll()) ?? []).filter { $0.source == "live" }
        lastRun = runs.last
        today = TodayStats.compute(runs)
    }

    struct KeyState: Equatable { let masked: String; let verified: Bool }
    static let osMajor = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
}

/// System Settings deep links (legacy pane ids; the ones shipping apps use, see research 18 §2).
enum PermissionLinks {
    static let accessibility = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    static let inputMonitoring = "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
    static let microphone = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
    /// Same legacy pattern; only shown on macOS 14–15 (FE-3). Not verified on macOS 26, where the row never appears.
    static let speechRecognition = "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition"
    static func open(_ link: String) { if let u = URL(string: link) { NSWorkspace.shared.open(u) } }
}

enum MainTab: String, CaseIterable, Identifiable {
    case home = "Home", history = "History", settings = "Settings"
    var id: String { rawValue }
    var icon: String { switch self { case .home: return "waveform"; case .history: return "clock"; case .settings: return "gearshape" } }
}

@MainActor
final class MainWindowModel: ObservableObject {
    @Published var tab: MainTab = .home
    /// Which Settings page the sidebar shows (Home and the menu bar can jump straight to one).
    @Published var page: SettingsPage = .dictation
}

/// Sidebar rows: the three tabs, with Settings expanded into its pages.
enum SidebarItem: Hashable {
    case tab(MainTab), page(SettingsPage)
}

/// The window (APP-1): setup's world continued. A 264 pt lapis sidebar (traffic lights on it) and one page on the
/// paper pane, with the interface-language globe menu top-right (docs/DESIGN.md "Main window").
struct MainView: View {
    @ObservedObject var nav: MainWindowModel
    @ObservedObject var panel: PanelModel
    @ObservedObject var status: AppStatus
    @ObservedObject var settings: SettingsModel
    let runs: RunsModel
    /// Opens setup: `.welcome` = the full Setup Assistant, any other step = that one step from the app.
    let openSetup: (SetupStep) -> Void
    /// The Languages page's Connect… / Replace… for one service.
    var connectFor: (KeyProvider) -> Void = { _ in }
    /// v3: the inline Connect panel (Home and the Languages page).
    let connect: InlineConnectModel

    private var strings: AppStrings { .for(settings.s.uiLanguage) }

    var body: some View {
        let home = HomeState.current(status: status, settings: settings.s)
        HStack(spacing: 0) {
            Sidebar(nav: nav, t: strings, home: home, openSetup: openSetup, onSelect: { connect.close() })
                .frame(width: Ink.appSidebarWidth)
            ZStack(alignment: .topTrailing) {
                detail(home).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                InterfaceLanguageMenu(settings: settings, label: strings.uiAria)
                    .padding(.top, 16).padding(.trailing, 20)
            }
        }
        .background(Ink.paper)
        .ignoresSafeArea()
        .frame(minWidth: Ink.appWindowMin.width, minHeight: Ink.appWindowMin.height)
        .onAppear { status.start() }
    }

    @ViewBuilder private func detail(_ home: HomeState) -> some View {
        switch nav.tab {
        case .home: HomeView(panel: panel, status: status, settings: settings, nav: nav, home: home, t: strings, connect: connect,
                             openSetup: openSetup)
        case .history: RunsView(m: runs, t: strings).tint(Ink.lazur)
        case .settings:
            SettingsView(model: settings, status: status, page: nav.page, onSetupAssistant: { openSetup(.welcome) },
                         openSetup: openSetup, connectFor: connectFor, connect: connect).tint(Ink.lazur)
        }
    }
}

extension HomeState {
    /// Home and the sidebar badges from the live app state. Reads only what `AppStatus` already holds (no Keychain).
    @MainActor static func current(status: AppStatus, settings s: Settings) -> HomeState {
        HomeState(mic: status.permissions.mic, ax: status.permissions.ax, spoken: s.spokenLanguages, provider: s.provider,
                  hasKey: { status.keys[$0] != nil }, verified: { status.keys[$0]?.verified ?? false }, keychain: status.keychain)
    }
}

/// The interface language, live for the whole app (and the setup window when it is open). Quiet and grey like a
/// borderless popup, as on setup's panes.
private struct InterfaceLanguageMenu: View {
    @ObservedObject var settings: SettingsModel
    let label: String
    var body: some View {
        Menu {
            ForEach(UILanguage.allCases, id: \.self) { l in
                Button { settings.s.uiLanguage = l } label: {
                    if l == settings.s.uiLanguage { Label(l.nativeName, systemImage: "checkmark") } else { Text(l.nativeName) }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "globe")
                Text(settings.s.uiLanguage.nativeName)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: SetupScale.type(8), weight: .medium))
            }
            .font(.system(size: SetupScale.type(12)))
            .foregroundStyle(Ink.text2)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .tint(Ink.text2)
        .fixedSize()
        .accessibilityLabel(label)
        .accessibilityValue(settings.s.uiLanguage.nativeName)
    }
}

/// Lapis, white mark and wordmark, three groups of pages, Setup Assistant… and the version at the foot. The selected
/// row: a 12 % white wash, a firuza icon, a white semibold label; the others 80 % white.
struct Sidebar: View {
    @ObservedObject var nav: MainWindowModel
    let t: AppStrings
    let home: HomeState
    let openSetup: (SetupStep) -> Void
    /// Changing page closes an open Connect panel.
    var onSelect: () -> Void = {}

    private static let groups: [[SidebarItem]] = [
        [.tab(.home), .tab(.history)],
        [.page(.apiKeys), .page(.permissions), .page(.dictation), .page(.hotkey), .page(.pill), .page(.privacy)],
        // Developer stays listed: its page holds the developer-mode switch itself.
        [.page(.about), .page(.developer)],
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                BrandMark(width: 40, capsule: .white, bar: Ink.lapis)
                Text("Soyla").font(Ink.Font.appWordmark).tracking(-0.39).foregroundStyle(Ink.onLapis)
            }
            .padding(.leading, 8).padding(.top, 72).padding(.bottom, 28)
            .accessibilityElement(children: .ignore).accessibilityLabel("Soyla")

            ForEach(Self.groups.indices, id: \.self) { i in
                if i > 0 { Rectangle().fill(Ink.lapisLine).frame(height: 1).padding(.vertical, 12) }
                VStack(spacing: 2) {
                    ForEach(Self.groups[i], id: \.self) { item in
                        SidebarRow(icon: icon(item), title: title(item), selected: selected(item), badge: badge(item)) { select(item) }
                    }
                }
            }
            Spacer(minLength: 0)
            if Updater.shared.showsButton {
                SidebarUpdateCard(updater: Updater.shared, t: t).padding(.bottom, Ink.s3)
            }
            VStack(alignment: .leading, spacing: 8) {
                Button(t.setupA) { openSetup(.welcome) }
                    .buttonStyle(.plain).font(Ink.Font.appFoot).foregroundStyle(Ink.onLapis2)
                Text(t.version(Soyla.version)).font(Ink.Font.appFoot).foregroundStyle(Ink.onLapis3)
            }
            .padding(.horizontal, 10)
        }
        .padding(.horizontal, 16).padding(.bottom, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Ink.lapis)
    }

    private func title(_ i: SidebarItem) -> String {
        switch i {
        case .tab(.home): return t.navHome
        case .tab(.history): return t.navHistory
        case .tab(.settings): return t.mSettings
        case .page(let p): return t.page[p] ?? p.title
        }
    }

    private func icon(_ i: SidebarItem) -> String {
        switch i {
        case .tab(let tab): return tab.icon
        case .page(.apiKeys): return "globe"          // V-34: "translate" drew 20 pt wide beside 14 pt neighbours
        case .page(.developer): return "chevron.left.forwardslash.chevron.right"
        case .page(let p): return p.icon
        }
    }

    private func selected(_ i: SidebarItem) -> Bool {
        switch i {
        case .tab(let tab): return nav.tab == tab
        case .page(let p): return nav.tab == .settings && nav.page == p
        }
    }

    /// A saffron dot where a fix lives: Languages while a key is needed, Permissions while one is missing.
    private func badge(_ i: SidebarItem) -> Bool {
        switch i {
        case .page(.apiKeys):
            switch home.action { case .connect, .addKey: return true; default: return false }
        case .page(.permissions): return home.micMissing || home.axMissing
        default: return false
        }
    }

    private func select(_ i: SidebarItem) {
        onSelect()
        switch i {
        case .tab(let tab): nav.tab = tab
        case .page(let p): nav.page = p; nav.tab = .settings
        }
    }
}

private struct SidebarRow: View {
    let icon: String
    let title: String
    let selected: Bool
    let badge: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 15)).imageScale(.medium).frame(width: 20, height: 20)
                    .foregroundStyle(selected ? Ink.firuza : (hover ? Ink.onLapis : Ink.onLapis2))
                Text(title).font(selected ? Ink.Font.appNavSelected : Ink.Font.appNav)
                    .foregroundStyle(selected || hover ? Ink.onLapis : Ink.onLapis2)
                    .lineLimit(1).minimumScaleFactor(0.85)
                Spacer(minLength: 0)
                if badge { Circle().fill(Ink.warn).frame(width: 7, height: 7).accessibilityHidden(true) }
            }
            .padding(.horizontal, 10).frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(selected ? 0.12 : (hover ? 0.07 : 0))))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityValue(badge ? AppStrings.current.attention : "")     // V-28: the saffron dot, in words
    }
}

/// Home "Today" numbers, from the run log. Pure so it can be unit-tested.
struct TodayStats: Equatable {
    var count = 0
    var words = 0
    /// Median `release_to_paste` in ms over today's ok runs that have one.
    var medianWaitMs: Double? = nil

    static func compute(_ runs: [RunRecord], now: Date = Date(), calendar: Calendar = .current) -> TodayStats {
        let start = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        let ok = runs.filter { r in
            guard r.error == nil, let d = parse(r.ts) else { return false }
            return d >= start && d < end
        }
        let waits = ok.compactMap { $0.timelineMs["release_to_paste"] }.sorted()
        var median: Double? = nil
        if !waits.isEmpty {
            let m = waits.count / 2
            median = waits.count % 2 == 1 ? waits[m] : (waits[m - 1] + waits[m]) / 2
        }
        let words = ok.reduce(0) { $0 + wordCount($1.cleanText ?? $1.rawText ?? "") }
        return TodayStats(count: ok.count, words: words, medianWaitMs: median)
    }

    static func wordCount(_ text: String) -> Int { text.split(whereSeparator: { $0.isWhitespace }).count }

    static func parse(_ ts: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: ts) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: ts)
    }

    var waitText: String { medianWaitMs.map { String(format: "%.1f s", $0 / 1000) } ?? "–" }
}

/// "Today 15:41 · Notes · 12 s" for a dictation card. Main actor: only views call it, and it uses `RunsView.when`.
@MainActor
enum NoteMeta {
    static func line(_ r: RunRecord, engine: Bool = false, t: AppStrings = .en) -> String {
        var parts = [RunsView.when(r.ts, t: t)]
        if let a = r.targetApp, !a.isEmpty { parts.append(a) }
        if r.audio.durationSec > 0 { parts.append(duration(r.audio.durationSec, t: t)) }
        if engine { parts.append(EngineCopy.isOnDevice(model: r.model) ? t.onMac : ModelNames.name(r.model)) }
        return parts.joined(separator: " · ")
    }
    static func duration(_ s: Double, t: AppStrings = .en) -> String {
        s < 60 ? "\(max(1, Int(s.rounded()))) \(t.secs)" : String(format: "%d:%02d", Int(s) / 60, Int(s) % 60)
    }
}
