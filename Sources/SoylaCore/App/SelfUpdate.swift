import AppKit
import CryptoKit
import Foundation
import Observation
import Security
import SwiftUI

/// One-click update: download the release zip, check its SHA-256, unzip, accept it
/// only if it is signed with the SAME certificate as the running app, then swap the bundle and relaunch.
/// Never touches user data (Application Support, defaults, Keychain).
public enum SelfUpdate {
    public enum Failure: Error, Equatable, Sendable {
        case notOffered, network, tooBig, checksum, unzip, notSoyla, wrongVersion, unsigned, untrusted, notWritable, install

        /// Card text: what happened, then what to do (DESIGN.md copy rules).
        public var message: String { message(AppStrings.en.d) }

        /// The same text in the interface language (the card's tooltip).
        func message(_ d: AppDStrings) -> String {
            switch self {
            case .notOffered: return d.sfNotOffered
            case .network: return d.sfNetwork
            case .tooBig, .checksum, .unzip, .notSoyla, .wrongVersion, .untrusted: return d.sfVerify
            case .unsigned: return d.sfUnsigned
            case .notWritable: return d.sfNotWritable
            case .install: return d.sfInstall
            }
        }
    }

    static let maxBytes = 50 * 1024 * 1024

    // MARK: pure checks (unit-tested)

    /// `shasum -a 256` output: "<64 hex>  Soyla-v0.2.1.zip". Only the first field counts.
    static func checksumMatches(_ data: Data, shasumFile: String) -> Bool {
        guard let want = shasumFile.split(whereSeparator: { $0 == " " || $0.isNewline }).first?.lowercased(),
              want.count == 64 else { return false }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == want
    }

    /// The new bundle must be Soyla, carry exactly the release's version, and be newer than the running one.
    static func plistProblem(_ info: [String: Any], tag: String, current: String) -> Failure? {
        guard info["CFBundleIdentifier"] as? String == Soyla.bundleId else { return .notSoyla }
        guard let v = info["CFBundleShortVersionString"] as? String,
              UpdateCheck.components(v) == UpdateCheck.components(tag),
              UpdateCheck.isNewer(tag: tag, current: current) else { return .wrongVersion }
        return nil
    }

    /// An ad-hoc build's requirement names its own cdhash: it could never accept a newer build, so it doesn't try.
    static func isCertificateBased(_ requirement: String) -> Bool { requirement.contains("certificate leaf") }

    // MARK: code signature

    /// The running app's designated requirement ("identifier … and certificate leaf = H\"…\"").
    static func ownRequirement() -> SecRequirement? {
        var me: SecCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me else { return nil }
        var st: SecStaticCode?
        guard SecCodeCopyStaticCode(me, [], &st) == errSecSuccess, let st else { return nil }
        var req: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(st, [], &req) == errSecSuccess else { return nil }
        return req
    }

    static func requirementString(_ r: SecRequirement) -> String {
        var s: CFString?
        return SecRequirementCopyString(r, [], &s) == errSecSuccess ? (s as String? ?? "") : ""
    }

    /// True only when `app` has a valid signature that satisfies `requirement` (the running app's own).
    static func satisfies(_ app: URL, requirement: SecRequirement) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        return SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess
    }

    // MARK: steps

    static func download(_ url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> Data {
        let c = URLSessionConfiguration.ephemeral
        c.urlCache = nil
        c.timeoutIntervalForRequest = 30
        let session = URLSession(configuration: c)
        defer { session.finishTasksAndInvalidate() }
        let (bytes, resp) = try await session.bytes(from: url)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw Failure.network }
        let total = max(resp.expectedContentLength, 1)
        guard total <= maxBytes else { throw Failure.tooBig }
        var data = Data(); data.reserveCapacity(Int(total))
        var buf = [UInt8](); buf.reserveCapacity(64 * 1024)
        for try await b in bytes {
            buf.append(b)
            if buf.count == 64 * 1024 {
                data.append(contentsOf: buf); buf.removeAll(keepingCapacity: true)
                guard data.count <= maxBytes else { throw Failure.tooBig }
                progress(min(1, Double(data.count) / Double(total)))
            }
        }
        data.append(contentsOf: buf)
        progress(1)
        return data
    }

    static func run(_ tool: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }

    /// Downloads, checks and unzips; returns the verified new `Soyla.app` in a fresh temp folder.
    static func prepare(_ rel: UpdateCheck.Release, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        guard let zipURL = rel.zip, let shaURL = rel.sha256 else { throw Failure.notOffered }
        guard let req = ownRequirement(), isCertificateBased(requirementString(req)) else { throw Failure.unsigned }
        let sha: Data, zip: Data
        do {
            sha = try await download(shaURL, progress: { _ in })
            zip = try await download(zipURL, progress: progress)
        } catch let f as Failure { throw f } catch { throw Failure.network }
        guard checksumMatches(zip, shasumFile: String(bytes: sha, encoding: .utf8) ?? "") else { throw Failure.checksum }

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("soyla-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let zipFile = dir.appendingPathComponent("update.zip")
        try zip.write(to: zipFile)
        let out = dir.appendingPathComponent("new")
        guard run("/usr/bin/ditto", ["-x", "-k", zipFile.path, out.path]) == 0 else { throw Failure.unzip }
        let app = out.appendingPathComponent("Soyla.app")
        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any]
        else { throw Failure.notSoyla }
        if let f = plistProblem(info, tag: rel.tag, current: Soyla.version) { throw f }
        guard satisfies(app, requirement: req) else { throw Failure.untrusted }
        // Downloaded by URLSession, the files carry no quarantine flag; strip one anyway, only after the check above.
        _ = run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path])
        return app
    }

    /// Run detached after Soyla quits: $1 pid, $2 new app, $3 installed app, $4 temp dir, $5 the running app's designated
    /// requirement. It waits up to 20 s for the old process, aborts if it is still alive, re-checks the new bundle's
    /// signature against $5 at the moment of the swap (closing the window since the in-app check), then swaps.
    static let installScript = """
    #!/bin/sh
    PID="$1"; NEW="$2"; TARGET="$3"; OLD="$4/Soyla-old.app"
    i=0; while kill -0 "$PID" 2>/dev/null && [ $i -lt 100 ]; do sleep 0.2; i=$((i+1)); done
    if kill -0 "$PID" 2>/dev/null; then rm -rf "$4"; exit 1; fi
    if ! codesign --verify --strict --deep -R="$5" "$NEW" 2>/dev/null; then rm -rf "$4"; open "$TARGET"; exit 1; fi
    if mv "$TARGET" "$OLD"; then
      if mv "$NEW" "$TARGET"; then rm -rf "$OLD"; else mv "$OLD" "$TARGET"; fi
    fi
    open "$TARGET"
    rm -rf "$4"
    """

    /// Swaps the bundle after this process exits, then opens the new one. The old app is moved back on failure.
    static func installAndRelaunch(_ newApp: URL) throws {
        let target = Bundle.main.bundleURL
        let parent = target.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path),
              !target.path.contains("/AppTranslocation/") else { throw Failure.notWritable }
        let dir = newApp.deletingLastPathComponent().deletingLastPathComponent()
        guard let req = ownRequirement() else { throw Failure.untrusted }
        let script = dir.appendingPathComponent("install.sh")
        try installScript.write(to: script, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Clean environment: the new Soyla must not inherit dev overrides (SOYLA_KEYCHAIN_SERVICE, API key vars) from
        // this process. Found in the 2026-10-16 update test: the relaunched app read the empty capture Keychain.
        p.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory()]
        // Detached: it must outlive this process.
        p.arguments = ["-c", "nohup /bin/sh \"$0\" \"$1\" \"$2\" \"$3\" \"$4\" \"$5\" >/dev/null 2>&1 &",
                       script.path, "\(ProcessInfo.processInfo.processIdentifier)", newApp.path, target.path, dir.path,
                       requirementString(req)]
        do { try p.run(); p.waitUntilExit() } catch { throw Failure.install }
        guard p.terminationStatus == 0 else { throw Failure.install }
    }
}

/// The update card's state. Lives for the whole app; the sidebar card and the menu bar read it.
@MainActor @Observable
public final class Updater {
    public enum State: Equatable {
        case idle, available, downloading(Double), installing, failed(String)
    }

    /// The × hides the card for this long; it comes back afterwards (and at every launch).
    static let snooze: TimeInterval = 6 * 3600

    public private(set) var release: UpdateCheck.Release?
    public private(set) var state: State = .idle
    /// Why `state` is `.failed`, kept apart from the English text so the card can show it in the interface language.
    private var failure: SelfUpdate.Failure?
    private var hiddenUntil: Date?
    /// Wired by AppDelegate: an update must not start in the middle of a dictation.
    public var isBusy: () -> Bool = { false }

    public init() {}

    public func isVisible(now: Date = Date()) -> Bool {
        guard release != nil else { return false }
        if case .downloading = state { return true }
        if state == .installing { return true }
        return hiddenUntil.map { now >= $0 } ?? true
    }

    public var showsButton: Bool { isVisible() }
    public var buttonTitle: String { buttonTitle(.en) }
    public func buttonTitle(_ l: UILanguage) -> String { AppStrings.for(l).d.upButton(version) }

    /// The failure card's tooltip in `d`'s language; falls back to the stored English text.
    func failureMessage(_ d: AppDStrings) -> String {
        guard case .failed(let english) = state else { return "" }
        return failure.map { $0.message(d) } ?? (english == AppStrings.en.d.sfBusy ? d.sfBusy : english)
    }
    public var version: String { release.map { Self.display($0.tag) } ?? "" }

    static func display(_ tag: String) -> String { tag.hasPrefix("v") ? String(tag.dropFirst()) : tag }

    public func dismiss(now: Date = Date()) { hiddenUntil = now.addingTimeInterval(Self.snooze) }

    /// First lines of the release notes as plain text (the card's tooltip).
    public var notesPreview: String {
        let lines = (release?.notes ?? "").split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .map { $0.hasPrefix("- ") || $0.hasPrefix("* ") ? "• " + $0.dropFirst(2) : $0 }
        return lines.prefix(5).joined(separator: "\n").replacingOccurrences(of: "**", with: "")
    }

    public func offer(_ r: UpdateCheck.Release) {
        guard r != release else { return }
        release = r
        if case .downloading = state {} else if state != .installing { state = .available }
        Log.info("update available: \(r.tag)")
    }

    /// Settings → About → "Install updates automatically": only with the switch on, a one-click release, and no
    /// dictation running.
    static func shouldAutoInstall(enabled: Bool, release: UpdateCheck.Release?, busy: Bool) -> Bool {
        enabled && !busy && release?.zip != nil && release?.sha256 != nil
    }

    public func install() {
        guard let rel = release else { return }
        switch state { case .downloading, .installing: return; default: break }
        failure = nil
        if isBusy() { state = .failed(AppStrings.en.d.sfBusy); return }
        state = .downloading(0)
        Task { @MainActor in
            do {
                let app = try await SelfUpdate.prepare(rel) { p in Task { @MainActor in self.progress(p) } }
                state = .installing
                Log.info("update \(Soyla.version) → \(rel.tag): verified, installing")
                try SelfUpdate.installAndRelaunch(app)
                NSApp.terminate(nil)
            } catch {
                let f = error as? SelfUpdate.Failure ?? .install
                Log.info("update \(rel.tag) failed: \(f)")
                failure = f
                state = .failed(f.message)
            }
        }
    }

    /// Launch check, then once a day while running (re-evaluated hourly, which also brings a closed card back and
    /// retries an automatic install that waited for a dictation). A dev server is checked at every launch.
    func start(settings: SettingsModel, isBusy: @escaping () -> Bool) {
        self.isBusy = isBusy
        Task { @MainActor [weak settings] in
            while let settings {
                if UpdateCheck.apiOverride != nil || UpdateCheck.isDue(enabled: settings.s.autoUpdateCheck, last: settings.s.lastUpdateCheck),
                   await UpdateCheck.run(silent: true, onAvailable: { self.offer($0) }) {
                    settings.s.lastUpdateCheck = Date()
                }
                if state == .available, Self.shouldAutoInstall(enabled: settings.s.autoInstallUpdates, release: release, busy: isBusy()) {
                    Log.info("update: installing automatically")
                    install()
                }
                if let h = hiddenUntil, Date() >= h { hiddenUntil = nil }
                try? await Task.sleep(for: .seconds(3600))
            }
        }
    }

    private func progress(_ p: Double) { if case .downloading = state { state = .downloading(p) } }

    public func openReleasePage() { if let u = release?.url { NSWorkspace.shared.open(u) } }
}

extension Updater {
    /// The one updater (sidebar card, menu bar, Settings → About).
    public static let shared = Updater()
}

/// Bottom of the sidebar, Arc-style: a small accent-tinted card, "Update available · Restart to get 0.2.1".
/// Click = install. A small × in its corner hides it for a few hours; it comes back.
struct SidebarUpdateCard: View {
    let updater: Updater
    /// The interface language's words (APP-1 (d)).
    var t: AppStrings = .en
    @State private var hover = false
    private var d: AppDStrings { t.d }

    private var subtitle: String {
        switch updater.state {
        case .downloading(let p): return d.ucDownloading(Int(p * 100))
        case .installing: return d.ucRestarting
        case .failed: return d.ucRetry
        default: return d.ucRestart(updater.version)
        }
    }

    private var failed: Bool { if case .failed = updater.state { return true }; return false }

    private var busy: Bool {
        switch updater.state { case .downloading, .installing: return true; default: return false }
    }

    private var tooltip: String {
        if case .failed = updater.state { return updater.failureMessage(d) }
        let notes = updater.notesPreview
        return (notes.isEmpty ? "" : notes + "\n\n") + d.ucTip
    }

    var body: some View {
        if updater.showsButton {
            let shape = RoundedRectangle(cornerRadius: Ink.rCard, style: .continuous)
            Button { updater.install() } label: {
                HStack(spacing: Ink.s2) {
                    Image(systemName: failed ? "exclamationmark" : "arrow.down")
                        .font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 20, height: 20).background(Circle().fill(Ink.lazur))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(failed ? d.ucFailed : d.ucAvail).font(.system(size: 12, weight: .semibold)).foregroundStyle(Ink.text)
                        Text(subtitle).font(Ink.Font.caption).foregroundStyle(Ink.text2).monospacedDigit()
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10).padding(.vertical, Ink.s2)
                .background(shape.fill(hover ? Ink.lazur.opacity(0.2) : Ink.lazurWash))
                .overlay(alignment: .bottom) {
                    if case .downloading(let p) = updater.state {
                        GeometryReader { g in Capsule().fill(Ink.lazur).frame(width: g.size.width * p, height: 2) }
                            .frame(height: 2).padding(.horizontal, 10).padding(.bottom, 3)
                    }
                }
                .contentShape(shape)
            }
            .buttonStyle(.plain)
            .disabled(busy)
            .onHover { hover = $0 }
            .overlay(alignment: .topTrailing) {
                if !busy {
                    Button { updater.dismiss() } label: {
                        Image(systemName: "xmark").font(.system(size: 7, weight: .bold)).foregroundStyle(Ink.text2)
                            .frame(width: 14, height: 14).background(Circle().fill(Ink.raised))
                            .overlay(Circle().strokeBorder(Ink.hairlineStrong))
                    }
                    .buttonStyle(.plain)
                    .opacity(hover ? 1 : 0.55)
                    .offset(x: 5, y: -5)
                    .help(d.ucHide)
                    .accessibilityLabel(d.ucHideA)
                }
            }
            .contextMenu { Button(d.ucPage) { updater.openReleasePage() } }
            .help(tooltip)
            .accessibilityLabel(d.ucA11y(updater.version, subtitle))
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }
}
