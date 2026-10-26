import Foundation
import SwiftUI

/// A failure shown in the pill: a human title, one line of what to do, and what the user can click.
public struct PillFailure: Equatable, Sendable {
    /// `info`: not a failure, a pointer (FE-4 P6 hint); the text was pasted.
    public enum Kind: Sendable { case error, warning, soft, info }
    public var kind: Kind
    public var title: String
    public var hint: String
    public var canRetry: Bool = false
    public var openSettings: Bool = false
    /// Which Settings page "Open Settings" lands on (nil = wherever the window last was).
    public var settingsPage: SettingsPage? = nil
    /// APP-1 (c): what the card's second button fixes (a setup step or a page); `openSettings` stays for the old routes.
    public var fix: PillFix? = nil

    /// Map any pipeline error to something a person can act on. Raw details go to logs/app.log, not the pill.
    public static func from(_ error: Error, stage: String) -> PillFailure {
        // D26 (a): a stock invented phrase on a quiet clip reads like an empty transcript.
        if error is StockPhraseDropped || error is ShortJunkDropped { return from(SoylaError.emptyTranscript, stage: stage) }
        if error is ScriptCheckError {
            // F3: the transcript came back in the wrong script twice (Korean for Uzbek, Uzbek in Cyrillic). Not pasted.
            return .init(kind: .warning, title: "Didn't understand that", hint: "Nothing was pasted. Retry, or say it again.", canRetry: true)
        }
        if let u = error as? URLError {
            switch u.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .dataNotAllowed:
                return .init(kind: .error, title: "No internet", hint: "Your recording is saved. Retry when you're online.", canRetry: true)
            case .timedOut:
                return .init(kind: .error, title: "The server didn't answer in time", hint: "Your recording is saved. Retry.", canRetry: true)
            default:
                return .init(kind: .error, title: "Couldn't reach the server", hint: "Check your internet, then retry.", canRetry: true)
            }
        }
        if let s = error as? SoylaError {
            switch s {
            case .missingAPIKey:
                // V-10: a normal setup state, not a failure: calm (`shown(_:readiness:)` words it per language).
                return .init(kind: .info, title: Self.noKeyTitle, hint: "Connect a key to start dictating.", openSettings: true, fix: .connectKey)
            case .keychainBlocked(let denied):
                return denied
                    ? .init(kind: .warning, title: "Soyla can't read your API key", hint: "Quit and reopen Soyla, then click Always Allow.", canRetry: false)
                    : .init(kind: .warning, title: "Waiting for your Mac password", hint: "Type it in the macOS dialog, click Always Allow, then retry.", canRetry: true)
            case .http(let code, _):
                return httpCard(code)
            case .onDeviceUnavailable(let reason):
                return .onDevice(reason: reason)
            case .emptyTranscript:
                return .init(kind: .soft, title: "No speech heard", hint: "")
            case .decode:
                return .init(kind: .error, title: "The server sent an odd reply", hint: Self.otherModel, canRetry: true)
            case .insecureEndpoint:
                return .init(kind: .error, title: "This server needs https", hint: "Change its address in Languages → Custom.")
            case .permission:
                return .init(kind: .warning, title: "Not pasted: it's on your clipboard", hint: Self.allowAccessibility, openSettings: true,
                             fix: .setup(.permissions))
            case .audio:
                return .init(kind: .error, title: "Microphone problem", hint: "Try again. If it repeats, choose another mic in System Settings → Sound.")
            default: break
            }
        }
        if stage.hasPrefix("record") {
            return .init(kind: .error, title: "Microphone problem", hint: "Try again. If it repeats, choose another mic in System Settings → Sound.")
        }
        return .init(kind: .error, title: "Something went wrong", hint: Self.otherModel, canRetry: true)
    }

    /// The card for an HTTP error status from the speech service.
    static func httpCard(_ code: Int) -> PillFailure {
        switch code {
        case 401, 403: return .init(kind: .error, title: "Your API key was refused", hint: "Replace it in Languages.", openSettings: true, fix: .connectKey)
        case 402: return .init(kind: .error, title: "Out of OpenRouter credit", hint: "Top up at openrouter.ai, then retry.", canRetry: true)
        case 429: return .init(kind: .error, title: "Too many requests", hint: "Wait a few seconds, then retry.", canRetry: true)
        case 408, 500...599: return .init(kind: .error, title: "The speech service is having trouble", hint: "It's usually brief. Retry in a moment.", canRetry: true)
        default: return .init(kind: .error, title: "Transcription failed (HTTP \(code))", hint: otherModel, canRetry: true)
        }
    }

    static let noKeyTitle = "No API key yet"
    static let otherModel = "Retry. If it keeps failing, pick another model in Languages."
    static let allowAccessibility = "Press ⌘V. To paste automatically, allow Accessibility."

    /// A deliberate run with too little speech to send (`CaptureVerdict.missedSpeech`): quiet, no buttons.
    static let missedSpeech = PillFailure(kind: .soft, title: "Didn't catch that", hint: "")

    /// Empty capture on a deliberate run. `input` is `DictationPipeline.logInput`. External or gone (AirPods unplugged
    /// mid-hold): the quiet card, never an error card (owner, 2026-10-17 + 2026-10-19). Built-in: name the device.
    /// `kind` / `lidClosed` pick the built-in card's hint (F-05).
    static func forEmptyCapture(device: String?, input: String, kind: AudioDevices.InputKind,
                                lidClosed: Bool = false) -> PillFailure {
        device != nil && input != "builtIn" ? .missedSpeech : .noSound(device: device, input: kind, lidClosed: lidClosed)
    }

    /// F-05: the same card, told what the input is. A closed lid with the built-in mic says so; the AirPods line only
    /// for a Bluetooth input; anything else gets a plain check.
    static func noSound(device: String?, input: AudioDevices.InputKind, lidClosed: Bool) -> PillFailure {
        var f = noSound(device: device)
        if input == .builtIn && lidClosed { f.hint = lidClosedHint; f.fix = nil; f.openSettings = false }
        else if input != .bluetooth { f.hint = checkMicHint }
        return f
    }
    static let lidClosedHint = "Your Mac’s lid is closed, so its microphone is off. Open the lid or connect a microphone."
    static let checkMicHint = "Check that the microphone is connected and not muted, or pick another in Privacy & data."

    /// Key-down pre-flight (F-16): Soyla can't hear or can't type yet, so nothing is recorded.
    static func permissionNeeded(mic: Bool) -> PillFailure {
        mic ? .init(kind: .info, title: "Soyla can’t hear you yet", hint: "Allow the microphone first.", fix: .setup(.permissions))
            : .init(kind: .info, title: "Soyla can’t type for you yet", hint: "Allow Accessibility first.", fix: .setup(.permissions))
    }

    /// How long a card stays before it dismisses itself (F-05: never sticky). The next hold replaces it at once.
    var dismissAfter: Double {
        switch kind {
        case .soft: return 1.8
        case .warning, .info: return 6
        case .error: return canRetry ? 15 : 8
        }
    }

    /// A deliberate hold but the mic gave nothing: say which device; the built-in mic is one switch away.
    static func noSound(device: String?) -> PillFailure {
        .init(kind: .error, title: "No sound from \(device ?? "the microphone")",
              hint: "If it's AirPods, they may be on your iPhone. Switch them to this Mac, or use the built-in mic (Privacy & data).",
              openSettings: true, fix: .page(.privacy))
    }
}

/// Observable state shared by the floating panel and the menu bar.
///
/// The pipeline drives `phase`, `elapsedSec`, `level`, `micLive`, `warn` and the texts. Everything the pill
/// derives from those (smoothed level, wait stage, caption) is computed here so it is testable.
/// Whether the hotkey is physically down (`PanelModel.hotkeyHeld`).
@MainActor @Observable
final class HotkeyKeyState {
    private(set) var held = false

    func note(_ e: HotkeyReducer.Event) {
        let down: Bool
        switch e {
        case .down: down = true
        case .up, .reset: down = false
        default: return
        }
        if down != held { held = down }
    }
}

@MainActor
public final class PanelModel: ObservableObject {
    public enum Phase: Equatable { case idle, needsPermission, ready, recording, transcribing, cleaning, pasting, done, failed }
    @Published public var phase: Phase = .idle { didSet { if phase != oldValue { phaseChanged(from: oldValue) } } }
    /// Seconds since key-down. Not published: it changes 20× a second, and a SwiftUI update plus a pill re-layout
    /// per tick made the motion stutter. Only `shownElapsed` (what a caption can show) publishes.
    public var elapsedSec: Double = 0 {
        didSet { let q = (elapsedSec * (showDetails ? 10 : 1)).rounded(.down); if q != shownElapsed { shownElapsed = q } }
    }
    @Published public private(set) var shownElapsed: Double = 0
    /// Raw RMS of the last mic buffer (0…1) when no `levelSource` is set (pill demo, tests). Not published.
    public var level: Float = 0
    /// While recording: reads the recorder's latest buffer, so the bars sample the mic at display rate (60 fps)
    /// instead of a 20 Hz copy. Set and cleared by the pipeline.
    /// nil from the source (no recorder) falls back to `level`.
    public var levelSource: (() -> Float?)?
    /// What the bars show: the current RMS mapped to dB. The only smoothing is `Waveform.ease`, per frame.
    public var displayLevel: Double { PillGeometry.level(rms: (levelSource?() ?? nil) ?? level) }
    /// First audio buffer arrived: the mic is really capturing (cold start takes 230–420 ms).
    @Published public var micLive = false
    /// Processing time bucket: drives "Still working…" (2 s) and "Taking longer than usual… · Cancel" (4 s).
    @Published public private(set) var waitStage: PillWaitStage = .quiet
    @Published public var warn: Bool = false
    @Published public var rawText: String = ""
    @Published public var cleanText: String = ""
    @Published public var latencyLine: String = ""
    /// Last error as plain text (menu bar / Home); the pill shows `failure`.
    @Published public var errorText: String = ""
    @Published public var failure: PillFailure? = nil
    @Published public var model: String = ""
    @Published public var phraseId: Int? = nil
    @Published public var hotkeyLabel: String = "fn"
    /// The hotkey is physically down: Home's key cap. Driven by the monitor's raw `.down` / `.up` edges, not by
    /// `phase`, which starts 0.1 s late and stays `.recording` after a tap and in a lock (key lagged the pill,
    /// 2026-10-19). Not part of `reset()`: it belongs to the key, not the run. Kept in its own `@Observable` so a key
    /// edge redraws only the views that read it, not every view on this model (review, 2026-10-20).
    let hotkeyKey = HotkeyKeyState()
    public var hotkeyHeld: Bool { hotkeyKey.held }
    public func noteHotkeyEvent(_ e: HotkeyReducer.Event) { hotkeyKey.note(e) }
    /// APP-1 (c): the interface language the failure cards are shown in (mirrored from Settings by AppDelegate).
    @Published public var uiLanguage: UILanguage = .en
    /// The app's shared readiness, read when a card is drawn (wired by AppDelegate; V-10).
    public var readiness: @MainActor () -> Readiness = { .ready }
    /// B2: hands-free after a double press; the pill shows a lock glyph, no words (owner, 2026-10-17).
    @Published public var locked = false
    /// A revealed tap waiting for its second press: the pill stays, dimmed (no hide/show blink).
    @Published public var tapPending = false
    /// B2: one-off line while processing ("Still working on your last note"), cleared by the pipeline.
    @Published public var notice: String? = nil
    /// F-05: 300 ms of digital silence while recording (a closed lid, a muted or stolen device): said in the pill now.
    @Published public var silentInput = false
    /// Settings → Pill → Place on screen: the idle pill says what to do.
    @Published public var placeHint = false
    /// Gemini Live interim text while speaking (preview; replaced by the real transcript when done).
    @Published public var liveText: String = ""
    /// Pill extras, mirrored from Settings at each key-down. Off by default: the pill only animates.
    @Published public var showLiveText = false
    @Published public var showDetails = false
    /// D26(b): the language-set chip while recording ("RU", "UZ·EN"); nil for the default set. Set at reveal.
    @Published public var languageChip: String?
    /// Mirrored from Settings by the panel at show: amber from `warnAtSec`, red near `hardStopSec`.
    @Published public var warnAtSec: Double = 45
    @Published public var hardStopSec: Double = 55
    /// System "Reduce motion": no scale, no wobble, no ripple, no frame animation.
    @Published public var reduceMotion = false
    /// Drives the 0.96 → 1 appear scale (set by FloatingPanel).
    @Published public var appeared = false
    /// Wired by AppDelegate: re-send the last failed recording / open Settings.
    public var onRetry: (() -> Void)?
    public var onOpenSettings: (() -> Void)?
    /// Wired by DictationPipeline: click on the recording capsule = stop; Cancel on a slow request.
    public var onStopRequested: (() -> Void)?
    public var onCancel: (() -> Void)?

    public init() {}

    public var isProcessing: Bool { Self.processingPhases.contains(phase) }
    static let processingPhases: Set<Phase> = [.transcribing, .cleaning, .pasting]

    /// The pill's words in the interface language (APP-1 (d); English by default).
    private var t: AppStrings { .for(uiLanguage) }

    public var statusLine: String {
        switch phase {
        case .idle: return t.d.pcIdle(hotkeyLabel)
        case .needsPermission: return t.d.pcNeedsPerm
        case .ready: return t.d.pcReady(hotkeyLabel)
        case .recording: return t.listening
        case .transcribing: return t.d.pcTranscribing
        case .cleaning: return t.d.pcCleaning
        case .pasting: return t.d.pcPasting
        case .done: return t.d.pcPasted
        case .failed: return failure?.title ?? t.d.stFailed
        }
    }

    /// Words next to the bars. None while recording by default; while processing only once it gets slow.
    public var caption: String? {
        if placeHint && !isProcessing && phase != .recording { return t.d.pcDrag }
        if phase == .recording {
            let left = t.d.pcLeft(max(0, Int((hardStopSec - elapsedSec).rounded(.up))))
            if silentInput { return t.pcNoSound }
            if locked { return warn ? left : nil }   // the lock glyph is the hint; words only for the countdown
            if warn { return left }
            return showDetails ? String(format: "%.1f s", elapsedSec) : nil
        }
        guard isProcessing else { return nil }
        if let n = notice { return n }
        switch waitStage {
        case .quiet: return nil
        case .label: return showDetails ? statusLine : nil
        case .stillWorking: return t.d.pcStill
        case .slow: return t.d.pcSlow
        }
    }

    public var tint: PillTint {
        phase == .recording ? PillGeometry.tint(elapsed: elapsedSec, warnAt: warnAtSec, hardStop: hardStopSec) : .normal
    }

    public var finalText: String { cleanText.isEmpty ? rawText : cleanText }

    /// "fn (🌐)" → "fn" for the locked caption.
    public var hotkeyShortLabel: String { hotkeyLabel.components(separatedBy: " (").first ?? hotkeyLabel }

    public func reset() {
        elapsedSec = 0; level = 0; micLive = false; warn = false; liveText = ""
        locked = false; tapPending = false; notice = nil; silentInput = false
        rawText = ""; cleanText = ""; latencyLine = ""; errorText = ""; failure = nil
    }

    /// VoiceOver announcement for entering `phase` (nil = say nothing).
    public static func announcement(for phase: Phase, failure: PillFailure?, language: UILanguage = .en) -> String? {
        let d = AppStrings.for(language).d
        switch phase {
        case .recording: return d.anRecording
        case .transcribing: return d.anTranscribing
        case .done: return d.pcPasted
        case .failed:
            guard let f = failure else { return nil }
            return f.hint.isEmpty ? f.title : "\(f.title). \(f.hint)"
        default: return nil
        }
    }

    // MARK: timers derived from phase

    private var clockToken = 0
    private var processingStartedAt: Date?

    private func phaseChanged(from old: Phase) {
        let wasProcessing = Self.processingPhases.contains(old)
        if isProcessing && !wasProcessing { startWaitClock() }
        if !isProcessing { clockToken += 1; processingStartedAt = nil; if waitStage != .quiet { waitStage = .quiet } }
    }

    private func startWaitClock() {
        clockToken += 1
        let tok = clockToken
        let start = Date()
        processingStartedAt = start
        waitStage = .quiet
        for t in [PillGeometry.labelAfter, PillGeometry.stillWorkingAfter, PillGeometry.slowAfter] {
            Task { [weak self] in
                guard await MainDelay.elapsed(t), let self, self.clockToken == tok, self.isProcessing else { return }
                self.waitStage = PillGeometry.waitStage(elapsed: Date().timeIntervalSince(start) + 0.001)
            }
        }
    }

    /// Test hook: set the wait stage directly.
    func _setWaitStage(_ s: PillWaitStage) { waitStage = s }
}
