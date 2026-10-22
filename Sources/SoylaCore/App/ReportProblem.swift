import SwiftUI
import AppKit
import Carbon.HIToolbox

/// BL-06: "Report a problem…" window. Shows the diagnostic block (ProblemReport.build), editable, with Copy and
/// "Open GitHub issue". Nothing leaves the Mac from here: the button only opens the browser on a prefilled GitHub
/// address, and the user submits (or not) there. No telemetry, no attachments.
@MainActor
enum ReportProblemWindow {
    private static var window: NSWindow?

    static func facts(permissions p: PermissionState) -> ProblemReport.Facts {
        let s = SettingsStore.shared.current
        let layout = PasteKeycode.sourceId(PasteKeycode.onMain { TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() }) ?? "unknown"
        let mic: String
        switch p.mic { case .granted: mic = "granted"; case .denied: mic = "denied"; case .notDetermined: mic = "not asked" }
        let last = ((try? RunLog.readAll()) ?? []).last { $0.source == "live" }
        return ProblemReport.Facts(
            appVersion: Soyla.version,
            macOS: ProcessInfo.processInfo.operatingSystemVersionString,
            keyboardLayout: layout, hotkey: s.hotkey.label,
            inputDevice: AudioDevices.activeInputName(preferBuiltIn: s.preferBuiltInMic),
            provider: s.provider.label, model: s.sttModel,
            accessibility: p.ax, inputMonitoring: p.inputMonitoringOK, microphone: mic,
            secureInput: IsSecureEventInputEnabled(), lastRun: last)
    }

    static func show(permissions: PermissionState) {
        let f = facts(permissions: permissions)
        let language = SettingsStore.shared.current.uiLanguage
        window?.close()
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 460),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = AppStrings.for(language).d.rpTitle
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: ReportProblemView(facts: f, text: ProblemReport.build(f), language: language))
        w.center()
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }
}

struct ReportProblemView: View {
    let facts: ProblemReport.Facts
    @State var text: String
    /// The interface language (APP-1 (d)). The report text itself stays English: it goes to the developer.
    var language: UILanguage = .en
    private var d: AppDStrings { AppStrings.for(language).d }

    var body: some View {
        VStack(alignment: .leading, spacing: Ink.s3) {
            Text(d.rpTitle).font(Ink.Font.title).foregroundStyle(Ink.text)
            Text(d.rpIntro)
                .font(Ink.Font.body).foregroundStyle(Ink.text2).fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $text)
                .font(Ink.Font.mono).foregroundStyle(Ink.text).scrollContentBackground(.hidden)
                .padding(Ink.s2).background(RoundedRectangle(cornerRadius: Ink.rCard, style: .continuous).fill(Ink.well))
                .overlay(RoundedRectangle(cornerRadius: Ink.rCard, style: .continuous).strokeBorder(Ink.hairline))
            Text(d.rpNote)
                .font(Ink.Font.caption).foregroundStyle(Ink.text2).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Ink.s2) {
                Spacer()
                CopyButton(text: text, t: AppStrings.for(language))
                CardButton(icon: "arrow.up.right.square", label: d.rpOpen, tint: Ink.lazur, help: d.rpOpenH) {
                    if let url = ProblemReport.issueURL(body: text, facts: facts) { NSWorkspace.shared.open(url) }
                }
            }
        }
        .padding(Ink.s6)
        .background(Ink.paper)
        .frame(width: 520, height: 460)
    }
}
