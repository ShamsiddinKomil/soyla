import Foundation
import AppKit
import CoreAudio
import AVFoundation
import os

/// Tiny stderr logger (stderr is redirected to logs/app.log by AppMain).
enum Log {
    static func info(_ s: String) {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"
        FileHandle.standardError.write("\(f.string(from: Date())) \(s)\n".data(using: .utf8)!)
    }
}

/// The UI cues. Bundled sets (Resources/Sounds, preloaded once): `soyla` ("Soft", the default), `glass`, `wood`,
/// `classic`; `system` = macOS sounds; `off` = silence. Settings → Sounds also has a volume and a preview.
/// Errors never play a sound (D13): the pill card is the signal. `warn` marks the recording limit (4:45; 0:45 without segment streaming, `recordingLimits`).
/// Main actor: NSSound playback and the preloaded caches; only AppDelegate and the pipeline (both main) call it.
@MainActor enum Sounds {
    enum Cue: String, CaseIterable {
        case start, done, cancel, warn
        /// Relative level; the user's volume multiplies it. Done and cancel sit under start, warn (mid-dictation) lowest.
        var volume: Float { switch self { case .start: 0.8; case .done, .cancel: 0.6; case .warn: 0.5 } }
        var systemName: String { switch self { case .start: "Tink"; case .done: "Pop"; case .cancel: "Funk"; case .warn: "Purr" } }
    }
    /// Directory holding the sound sets: the app bundle's Resources/Sounds (nil under `swift run`/tests).
    nonisolated static var bundleDir: URL? { Bundle.main.resourceURL?.appendingPathComponent("Sounds") }
    private static var cache: [SoundSet: [Cue: NSSound]] = [:]

    /// Load every set once at launch so the first cue has no disk latency (~200 KB in all).
    static func preload(from dir: URL? = bundleDir) {
        for set in SoundSet.allCases where set != .off {
            var cues: [Cue: NSSound] = [:]
            for cue in Cue.allCases {
                if set == .system { cues[cue] = NSSound(named: NSSound.Name(cue.systemName)); continue }
                guard let dir else { continue }
                let d = set.folder.map { dir.appendingPathComponent($0) } ?? dir
                cues[cue] = NSSound(contentsOf: d.appendingPathComponent("\(cue.rawValue).aiff"), byReference: false)
            }
            cache[set] = cues
        }
    }

    static func play(_ cue: Cue) {
        let s = SettingsStore.shared.current
        play(cue, set: s.soundSet, volume: s.soundVolume)
    }

    /// Settings preview: plays the chosen set at the chosen volume, even before it is saved.
    static func play(_ cue: Cue, set: SoundSet, volume: Double) {
        guard set != .off, let sound = cache[set]?[cue] ?? cache[.system]?[cue] else { return }
        sound.stop()                                    // restart if the previous cue is still playing
        sound.volume = cue.volume * Float(volume)
        sound.play()
    }
}

/// Hotkey down → record → hotkey up → encode → transcribe → (cleanup) → paste → log.
/// Owns the timeline marks; every stage reports into `panel`.
@MainActor
public final class DictationPipeline {
    public let panel: PanelModel
    private let settings: SettingsStore
    private var recorder: Recorder?
    private var timeline = RunTimeline()
    private var tickTimer: Timer?
    private var recordingStart: Date?
    private var hardStopped = false
    private var busy = false
    private var warnBeeped = false
    public var onPanelShouldShow: (() -> Void)?
    /// Warm recorder kept across runs (Settings.micWarmMode .always, or .idleClose30s for 30 s after a run).
    private var warmRecorder: Recorder?
    /// Pre-roll kept in RAM while the engine is warm (nothing to pre-roll when the mic is off).
    nonisolated static let preRollMs = 300
    static let idleCloseSec: Double = 30
    private var idleCloseWork: DispatchWorkItem?
    /// Screen lock / display sleep / system sleep: the warm engine is torn down until all of them clear.
    private var suspendReasons = Set<String>()
    private var systemObserversInstalled = false
    /// The default input changed while a recording was running: rebuild the warm engine right after it.
    private var pendingDeviceRestart = false
    /// Mid-recording mic swap (AirPods switching mode, a dead engine): audio of the replaced recorder(s), its
    /// pre-roll, the swap in flight, and when the last chunk arrived (audio thread → main).
    private var carried = Data(), carriedPreRoll = 0, swapTask: Task<Void, Never>?, lastSwapAt: Date?
    nonisolated let lastChunkAt = OSAllocatedUnfairLock(initialState: 0.0)
    /// Voiced ms so far, counted per chunk on the audio thread: at key-up a run with no speech hides at once.
    nonisolated let liveVoicedMs = OSAllocatedUnfairLock(initialState: 0.0)
    private var appliedPreferBuiltIn: Bool?
    /// Input device of the latest capture (Settings and the latency line show it).
    public private(set) var activeInputName: String?
    private var firstBufferAt: Date?
    private var silenceWarned = false
    /// Long-lived provider (one URLSession) re-warmed every 25 s while Soyla was used in the last 10 min.
    private var sharedProvider: (fp: String, provider: any PrewarmableProvider)?
    private var lastUsedAt: Date?
    private var rewarmTimer: Timer?
    private var watchdogFired = false
    private var startedWarm = false
    /// App the user is dictating into (captured at key-down), given to the correction pass as context.
    private var targetApp: String?
    /// App frontmost at hotkey release: the paste goes there or nowhere (F1 pre-flight).
    private var pasteTarget: PasteTarget?
    /// Live preview session for the current run (nil when off or no Gemini key).
    private var live: GeminiLiveProvider?
    private var liveChunk: PCMChunkHandler?
    /// Pieces transcribed while fn is held (nil unless Settings.streamSegments).
    private var segments: SegmentFeeder?
    private var liveRace: LiveRace?                                // S6: Live fast path (nil unless liveFastPath)
    private var liveRaceLaunched = false
    private var deviceListenerInstalled = false
    /// One provider (= one URLSession) per run, so the pre-warmed connection is the one the request uses.
    private var provider: (any PrewarmableProvider)?
    /// Last run that failed to transcribe; the pill's Retry re-reads its audio from disk (F4).
    private var lastFailed: (runId: String, ts: String, file: URL, settings: Settings)?
    /// F4: run id allocated at key-down; the WAV is streamed to disk while recording.
    private var runId: String?
    private var runTs: String?
    private var writer: WAVStreamWriter?
    private var chunkSink: PCMChunkHandler?
    /// Recordings the retention sweep must not touch (the run in progress, the one awaiting Retry).
    public var protectedRunIds: Set<String> { Set([runId, lastFailed?.runId].compactMap { $0 }) }
    public var isRecording: Bool { recorder != nil }
    /// Bumped by `cancelInFlight()`; a run whose generation is stale must not touch the pill or paste.
    private var generation = 0
    /// The task running stop → encode → transcribe → paste; cancelled by `cancelInFlight()` so the
    /// URLSession request is really cancelled, not just ignored.
    private var inflight: Task<Void, Never>?
    /// B2: the pill is shown only 0.1 s into a hold (`reveal`), capture starts at key-down regardless.
    private var revealed = false
    private var noticeToken = 0
    /// Pipeline → hotkey reducer (`.processingStarted` / `.pipelineIdle`), wired by AppDelegate.
    public var onGestureEvent: ((HotkeyReducer.Event) -> Void)?
    /// FE-4: hotkey-down with the free engine, given `onDeviceLocale`. AppDelegate refreshes the model state off the
    /// recording path (fire-and-forget; never delays capture).
    public var onOnDeviceKeyDown: ((String) -> Void)?

    /// Rebuild the warm engine from scratch (new default input device, or the engine stopped delivering audio).
    /// Always: re-opens now. Idle-close: re-opens only if it was open (keeps the 30 s window). Off: just closes.
    public func restartWarmRecorder(reason: String) {
        Log.info("mic restart: \(reason)")
        dropSpare()                                          // built for the old device
        let wasWarm = warmRecorder != nil
        closeWarm()
        let mode = settings.current.micWarmMode
        if mode == .idleClose30s && wasWarm && suspendReasons.isEmpty {
            openWarm()
            scheduleIdleClose()
        } else {
            applyWarmMode(mode)
        }
    }

    /// AirPods connecting etc. changes the default input; a warm AVAudioEngine keeps running on the old
    /// device and delivers nothing. Listen for the change and rebuild.
    private func installDeviceListener() {
        guard !deviceListenerInstalled else { return }
        deviceListenerInstalled = true
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.recorder != nil {
                    // The engine on the old device stops delivering: switch now, keep what was said so far. Waiting
                    // for the end lost whole locked dictations on AirPods (2026-10-19).
                    self.pendingDeviceRestart = true
                    self.swapRecorderMidRun(reason: "default input changed")
                    return
                }
                self.restartWarmRecorder(reason: "default input device changed")
            }
        }
        Log.info("default-input listener installed (status \(status))")
    }

    /// Call at launch and whenever settings change (cheap when nothing changed).
    public func applyWarmMode(_ mode: MicWarmMode) {
        installDeviceListener()
        installSystemObservers()
        let prefer = settings.current.preferBuiltInMic
        if let a = appliedPreferBuiltIn, a != prefer, warmRecorder != nil {
            Log.info("mic restart: prefer built-in mic \(prefer ? "on" : "off")")
            closeWarm()
        }
        appliedPreferBuiltIn = prefer
        switch mode {
        case .off:
            idleCloseWork?.cancel(); idleCloseWork = nil
            closeWarm()
            if let s = spare, s.preferBuiltIn != prefer { dropSpare() }
            preloadSpare()
        case .always:
            idleCloseWork?.cancel(); idleCloseWork = nil
            if suspendReasons.isEmpty { openWarm() } else { closeWarm() }
        case .idleClose30s:
            // Never opened at launch: the mic comes on with the first dictation and closes 30 s after the last.
            if !suspendReasons.isEmpty { closeWarm() }
            else if warmRecorder != nil, recorder == nil, !busy, idleCloseWork == nil { scheduleIdleClose() }
        }
    }

    private func makeRecorder() -> Recorder {
        Recorder(preRollMs: Self.preRollMs, preferBuiltInMic: settings.current.preferBuiltInMic)
    }

    /// Mic off between dictations: a recorder built ahead of time (engine, tap, prepare; NOT started, so no mic
    /// indicator), saving ~65 ms of every cold start. Rebuilt after each run and on device/setting changes.
    private var spare: (recorder: Recorder, preferBuiltIn: Bool)?

    private func preloadSpare() {
        guard settings.current.micWarmMode == .off, warmRecorder == nil, recorder == nil, spare == nil,
              AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return }
        let r = makeRecorder()
        spare = (r, settings.current.preferBuiltInMic)
        Task.detached(priority: .utility) { r.preload() }
    }

    /// The spare if it still matches the settings and finished building; otherwise nil (caller builds cold).
    private func takeSpare() -> Recorder? {
        guard let s = spare else { return nil }
        spare = nil
        if s.preferBuiltIn == settings.current.preferBuiltInMic, s.recorder.isPreloaded { return s.recorder }
        s.recorder.shutdown()
        return nil
    }

    private func dropSpare() { spare?.recorder.shutdown(); spare = nil }

    private func openWarm() {
        guard warmRecorder == nil else { return }
        let r = makeRecorder()
        warmRecorder = r
        Task { [weak self] in
            do {
                try await r.prepare()
                await MainActor.run { if self?.warmRecorder === r { self?.activeInputName = r.activeInputName } }
            }
            catch { await MainActor.run { self?.panel.errorText = "Mic: \(error.localizedDescription)"; if self?.warmRecorder === r { self?.warmRecorder = nil } } }
        }
    }

    /// Mic off now. A warm recorder that is mid-recording is only detached; afterCapture() shuts it down.
    private func closeWarm() {
        if let w = warmRecorder, w !== recorder { w.shutdown() }
        warmRecorder = nil
    }

    private func scheduleIdleClose() {
        idleCloseWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.idleCloseWork = nil
                guard self.settings.current.micWarmMode == .idleClose30s, self.warmRecorder != nil else { return }
                // Still recording/transcribing: try again later rather than leave the mic open for good.
                guard self.recorder == nil, !self.busy else { self.scheduleIdleClose(); return }
                if self.warmRecorder != nil { Log.info("mic closed: idle \(Int(Self.idleCloseSec)) s") }
                self.closeWarm()
            }
        }
        idleCloseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.idleCloseSec, execute: work)
    }

    /// Every capture ends here (sent, dropped, failed or cancelled): mic off unless it should stay warm.
    private func afterCapture(_ r: Recorder) {
        // No `r.activeInputName` here: it waits on the recorder's lock, which a cold engine start holds for 0.1–1.4 s,
        // so a quick tap froze the pill and macOS disabled the hotkey tap (2026-10-17). micBecameLive() records it.
        if r !== warmRecorder { Recorder.release([r]) }  // cold, detached or replaced: never leave a mic open
        if pendingDeviceRestart {
            pendingDeviceRestart = false
            restartWarmRecorder(reason: "default input device changed (deferred until the recording ended)")
        } else if !suspendReasons.isEmpty {
            closeWarm()
        } else {
            switch settings.current.micWarmMode {
            case .idleClose30s: if warmRecorder != nil { scheduleIdleClose() }
            case .always: openWarm()            // no-op when already warm; re-arms after a cold/replaced run
            case .off: preloadSpare()
            }
        }
    }

    // MARK: sleep / lock

    /// Hex pattern: tear the warm engine down on screen lock, display sleep and system sleep; re-arm when
    /// the last of them clears. Avoids stale engines after wake and a lit mic indicator on a locked Mac.
    private func installSystemObservers() {
        guard !systemObserversInstalled else { return }
        systemObserversInstalled = true
        let ws = NSWorkspace.shared.notificationCenter
        let pairs: [(Notification.Name, String, Bool)] = [
            (NSWorkspace.willSleepNotification, "system sleep", true), (NSWorkspace.didWakeNotification, "system sleep", false),
            (NSWorkspace.screensDidSleepNotification, "display sleep", true), (NSWorkspace.screensDidWakeNotification, "display sleep", false),
        ]
        for (name, reason, on) in pairs {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setSuspended(reason, on) }
            }
        }
        let dnc = DistributedNotificationCenter.default()
        for (name, on) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)] {
            dnc.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setSuspended("screen lock", on) }
            }
        }
    }

    private func setSuspended(_ reason: String, _ on: Bool) {
        if on {
            guard suspendReasons.insert(reason).inserted else { return }
            Log.info("mic suspended: \(reason)")
            idleCloseWork?.cancel(); idleCloseWork = nil
            closeWarm()
            if reason == "system sleep" { sharedProvider = nil }   // its connections won't survive sleep
        } else {
            guard suspendReasons.remove(reason) != nil else { return }
            Log.info("mic resume: \(reason) cleared\(suspendReasons.isEmpty ? "" : ", still: \(suspendReasons.sorted().joined(separator: ", "))")")
            if suspendReasons.isEmpty { applyWarmMode(settings.current.micWarmMode) }
        }
    }

    // MARK: connection re-warm

    /// One provider (= one URLSession) per provider+key, so the idle re-warm keeps the connection the request uses.
    private func currentProvider() -> (any PrewarmableProvider)? {
        let s = settings.current
        guard let key = try? ProviderFactory.apiKey(for: s.provider) else { sharedProvider = nil; return nil }
        let fp = "\(s.provider.rawValue)|\(s.customBaseURL ?? "")|\(s.provider == .apple ? s.onDeviceLocale : "")|\(key)"
        if let sp = sharedProvider, sp.fp == fp { return sp.provider }
        guard let p = try? ProviderFactory.transcriber(for: s) else { sharedProvider = nil; return nil }
        sharedProvider = (fp, p)
        return p
    }

    private func ensureRewarmTimer() {
        guard rewarmTimer == nil else { return }
        let t = Timer(timeInterval: 25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.idleRewarm() }
        }
        RunLoop.main.add(t, forMode: .common)
        rewarmTimer = t
    }

    private func idleRewarm() {
        guard let last = lastUsedAt, Date().timeIntervalSince(last) < 600 else {
            rewarmTimer?.invalidate(); rewarmTimer = nil
            sharedProvider = nil
            Log.info("connection re-warm stopped: unused for 10 min")
            return
        }
        guard !busy, recorder == nil, suspendReasons.isEmpty, settings.current.prewarmConnection,
              let p = sharedProvider?.provider else { return }
        Task.detached { await p.prewarm() }
    }

    public func shutdown() {
        idleCloseWork?.cancel(); idleCloseWork = nil
        rewarmTimer?.invalidate(); rewarmTimer = nil
        warmRecorder?.shutdown(); warmRecorder = nil
        recorder?.cancel(); recorder?.shutdown(); recorder = nil
    }

    public init(panel: PanelModel, settings: SettingsStore = .shared) {
        self.panel = panel
        self.settings = settings
        panel.onStopRequested = { [weak self] in self?.hotkeyUp() }      // click on the recording capsule
        panel.onCancel = { [weak self] in self?.cancelInFlight() }       // "Taking longer than usual… · Cancel"
        // The bars read the recorder's last buffer every frame (they draw on the main thread).
        panel.levelSource = { [weak self] in MainActor.assumeIsolated { self?.recorder?.level } }
    }

    /// Pill → Cancel or ESC while transcribing/cleaning: drop the in-flight result (nothing is pasted), cancel
    /// the request task (its URLSessionTask is cancelled through Swift task cancellation) and free the pipeline.
    /// The recording stays on disk and the run is still logged as "cancelled".
    public func cancelInFlight() {
        guard busy, recorder == nil else { return }
        generation += 1
        inflight?.cancel(); inflight = nil
        live?.close(); live = nil; dropSegments()
        Log.info("cancelled in flight by the user")
        Sounds.play(.cancel)
        panel.phase = .idle
        endBusy()
    }

    /// Every "pipeline is free" exit except a reducer-requested recording cancel reports to the reducer.
    private func endBusy() {
        busy = false
        onGestureEvent?(.pipelineIdle)
    }

    // MARK: hotkey (B2: driven by HotkeyReducer actions)

    public func handle(_ action: HotkeyReducer.Action) {
        switch action {
        case .startRecording: hotkeyDown()
        case .reveal: reveal()
        case .conceal: conceal()
        case .lock: lock()
        case .unlock: unlock()
        case .stopAndSend: hotkeyUp()
        case .cancelRecording(let why): hotkeyCancel(reason: why)
        case .cancelProcessing: cancelInFlight()
        case .busyNotice: busyNotice()
        case .consumeEscape, .escCapture, .schedule: break   // handled inside HotkeyMonitor
        }
    }

    /// Key-down: capture starts now (no first word lost), but nothing is shown until `reveal()` at 0.1 s.
    public func hotkeyDown() {
        guard !busy, recorder == nil else {
            if busy { busyNotice() }   // the reducer didn't know (e.g. Retry running): reject, don't queue
            return
        }
        let s = Self.effectiveSettings(settings.current)   // S3/R1: the live gate below reads the effective copy
        busy = true
        hardStopped = false
        warnBeeped = false
        revealed = false
        timeline = RunTimeline()
        timeline.mark(.keyDown)
        // The pill is reset at reveal; only clear what the hidden part of this run reads (first-buffer state).
        panel.micLive = false; panel.liveText = ""
        // The user is clearly at the Mac: a suspension whose "end" notification never came must not stick.
        if !suspendReasons.isEmpty { Log.info("key down while suspended (\(suspendReasons.sorted().joined(separator: ", "))) — clearing"); suspendReasons.removeAll() }
        idleCloseWork?.cancel(); idleCloseWork = nil
        lastUsedAt = Date()
        ensureRewarmTimer()
        startedWarm = warmRecorder != nil
        firstBufferAt = nil
        silenceWarned = false
        Log.info("key down → recording (model \(s.sttModel), mic \(s.micWarmMode.rawValue), warm=\(warmRecorder != nil), preloaded=\(spare?.recorder.isPreloaded == true))")

        // Same provider (= same URLSession) across runs, so the idle re-warm keeps the connection the request uses.
        provider = currentProvider()
        if let p = provider, s.prewarmConnection { Task.detached { await p.prewarm() } }
        if s.provider == .apple { onOnDeviceKeyDown?(s.onDeviceLocale) }

        watchdogFired = false
        targetApp = NSWorkspace.shared.frontmostApplication?.localizedName
        // Live preview: open the Gemini Live session now; audio chunks are buffered until it is ready.
        live?.close(); live = nil; dropSegments(); liveChunk = nil
        if let gkey = Self.livePreviewKey(s, key: { try? Secrets.geminiKey() }) {   // never for .apple (R1)
            let l = GeminiLiveProvider(apiKey: gkey)
            live = l
            liveChunk = { l.feedSync($0) }
            var lopts = TranscribeOptions(model: GeminiLiveProvider.model, languageHint: s.languageHint)
            lopts.vocabulary = s.vocabulary
            Task { try? await l.startSession(options: lopts); try? await l.activityStart() }
            Task { [weak self] in
                for await t in l.partials {
                    await MainActor.run {
                        guard let self, self.live === l, self.recorder != nil || self.panel.phase == .transcribing || self.panel.phase == .cleaning else { return }
                        self.panel.liveText = t
                    }
                }
            }
        }
        // F4: the WAV is written while recording, so a crash mid-dictation leaves recoverable audio.
        let (rid, rts) = RunRecord.newId()
        runId = rid; runTs = rts
        writer = nil
        do { writer = try WAVStreamWriter(url: RecordingStore.url(runId: rid, retention: s.retention)) }
        catch { Log.info("recording file: \(error.localizedDescription) — keeping audio in memory only") }
        segments = Self.segmentFeeder(s, provider); liveRace = Self.makeLiveRace(s); liveRaceLaunched = false
        let w = writer, lc = liveChunk, sf = segments, lr = liveRace, lca = lastChunkAt, lvm = liveVoicedMs
        carried = Data(); carriedPreRoll = 0; swapTask = nil; lastSwapAt = nil
        lvm.withLock { $0 = 0 }
        let sink: PCMChunkHandler = { pcm in
            lca.withLock { $0 = ProcessInfo.processInfo.systemUptime }
            let v = Encoder.voicedMs(pcm16: pcm)
            lvm.withLock { $0 += v }
            w?.append(pcm); lc?(pcm); sf?.feed(pcm); lr?.feed(pcm)
        }
        chunkSink = sink
        // Idle-close mode with the mic closed: open it cold for this run and keep it warm afterwards.
        let keepWarm = warmRecorder == nil && s.micWarmMode == .idleClose30s
        let r = warmRecorder ?? takeSpare() ?? makeRecorder()
        if keepWarm { warmRecorder = r }
        recorder = r
        let tl = timeline
        r.onFirstBuffer = { [weak self] in tl.mark(.recStart); Task { @MainActor in self?.micBecameLive() } }
        recordingStart = Date()
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in     // 20 Hz: the pill eases between ticks
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)   // keeps ticking (and hard-stopping) while a menu or alert is open
        tickTimer = timer
        Task { [weak self] in
            do { try await r.start(onChunk: sink, keepWarm: keepWarm) }
            catch {
                await MainActor.run {
                    if self?.warmRecorder === r { self?.warmRecorder = nil }
                    // A late start error from a run that already ended (or was replaced) must not fail the current one.
                    guard let self, self.recorder === r else { r.shutdown(); return }
                    self.fail(stage: "record", error, audio: nil)
                    r.shutdown()
                }
            }
        }
    }

    /// 0.1 s into a hold (or on lock): show the pill. The start tick plays now, or at the first buffer if later.
    public func reveal() {
        guard recorder != nil, !revealed else { return }
        revealed = true
        let s = settings.current
        let live = panel.micLive
        panel.reset()
        panel.micLive = live
        panel.model = s.sttModel
        panel.phraseId = s.phraseId
        panel.showLiveText = s.livePreview
        panel.showDetails = s.showDetails
        panel.phase = .recording
        onPanelShouldShow?()
        if live { Sounds.play(.start) }
    }

    /// A tap that was already revealed (released at 0.1–0.5 s): the pill stays, dimmed, while a second press can
    /// still lock it; the tap's cancel then fades it out. Hiding and re-showing made a double-tap blink (2026-10-17).
    public func conceal() {
        guard recorder != nil, revealed else { return }
        panel.tapPending = true
    }

    /// Double press: hands-free until the next press, a click on the pill, ESC or the hard stop.
    public func lock() {
        guard recorder != nil else { return }
        reveal()
        panel.tapPending = false
        panel.locked = true
        launchLiveRace()
        Log.info("locked (hands-free)")
    }

    /// Tap, then press-and-hold: the second press was a hold after all, so it is push-to-talk again.
    public func unlock() { if recorder != nil { panel.locked = false; Log.info("unlocked: second press held") } }

    /// Press while processing: one notice, the press is not queued.
    public func busyNotice() {
        guard busy else { return }
        noticeToken += 1
        let tok = noticeToken
        panel.notice = AppStrings.for(panel.uiLanguage).d.pcBusy
        if panel.isProcessing { onPanelShouldShow?() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            MainActor.assumeIsolated { if let self, self.noticeToken == tok { self.panel.notice = nil } }
        }
    }

    public func hotkeyUp() {
        guard let r = recorder, !hardStopped else {
            if !busy { onGestureEvent?(.pipelineIdle) }   // nothing to stop (start failed): let the reducer go idle
            return
        }
        finishRecording(r)
    }

    /// Abort the recording, send nothing, show nothing: a tap, a shortcut like fn+F, or ESC.
    public func hotkeyCancel(reason: HotkeyReducer.CancelReason = .otherKey) {
        guard let r = recorder else { return }
        live?.close(); live = nil; dropSegments()
        tickTimer?.invalidate(); tickTimer = nil
        recorder = nil
        if r === warmRecorder { r.cancel() }      // warm: running, quick; cold ones are released off-main below
        afterCapture(r)
        keepCancelledCapture(reason == .escape)
        switch reason {
        case .tap: Log.info("tap: no hold, no second press — dropped, nothing sent")
        case .otherKey: Log.info("cancelled: another key was pressed while holding the hotkey")
        case .escape: Log.info("cancelled: ESC while recording"); if revealed { Sounds.play(.cancel) }
        }
        revealed = false
        if panel.phase == .recording { panel.phase = .idle }   // just disappear (a hidden tap leaves any card alone)
        busy = false                                         // no .pipelineIdle: the reducer asked for this
    }

    /// Start sound + bright bars only once audio is really flowing, so "speak now" is honest even on a cold mic.
    /// While the hold is still hidden (< 0.1 s) only `micLive` is set; `reveal()` plays the tick.
    private func micBecameLive() {
        guard recorder != nil, !panel.micLive else { return }
        firstBufferAt = Date()
        if let t0 = recordingStart { Log.info("first buffer after \(Int(Date().timeIntervalSince(t0) * 1000)) ms") }
        if let n = recorder?.activeInputName { activeInputName = n }
        panel.micLive = true
        if revealed { Sounds.play(.start) }
    }

    private func tick() {
        guard let start = recordingStart, let r = recorder else { return }
        let el = Date().timeIntervalSince(start)
        panel.elapsedSec = el
        if el >= HotkeyReducer.holdThreshold { launchLiveRace() }
        swapIfStalled()
        let s = settings.current
        // Meter sanity: real mics never give exact zeros; 300 ms of them after the first buffer means a muted
        // or stolen device (AirPods held by an iPhone). Warn now; the run itself ends in a named "No audio" card.
        if let fb = firstBufferAt, !silenceWarned, Date().timeIntervalSince(fb) >= 0.3, r.capturedPeak == 0 {
            silenceWarned = true
            // External mics: log only (AirPods often start silent; owner 2026-10-17). Built-in (closed lid, muted): F-05 says so while holding.
            Log.info("meter: digital silence 300 ms after the first buffer (input \(Self.logInput(r.activeInputName)))")
            if Self.logInput(r.activeInputName) == "builtIn" { panel.errorText = "No sound from \(r.activeInputName ?? "the microphone")"; panel.silentInput = true }
        }
        // Warm engine should deliver within ~70 ms; a cold start takes 230–420 ms (more on Bluetooth).
        if el >= (startedWarm ? 0.8 : 2.0) && !watchdogFired && !timeline.has(.recStart) {
            watchdogFired = true
            Log.info("no audio buffers after \(startedWarm ? "0.8" : "2.0") s — mic engine is stale, switching to a fresh one")
            panel.errorText = "Mic was stale (device changed?) — restarted, keep talking"
            // Off the main thread: a hung Bluetooth start holds the recorder's lock, and waiting for it here froze
            // the app ("hotkey tap disabled by timeout", 2026-10-16).
            let stale = [r, warmRecorder].compactMap { $0 }
            Recorder.release(stale)
            warmRecorder = nil
            let fresh = makeRecorder()
            recorder = fresh
            writer?.reset()
            let tl = timeline
            fresh.onFirstBuffer = { [weak self] in tl.mark(.recStart); Task { @MainActor in self?.micBecameLive() } }
            Task { [weak self] in
                do { try await fresh.start(onChunk: self?.chunkSink) }
                catch {
                    await MainActor.run {
                        guard let self, self.recorder === fresh else { fresh.shutdown(); return }
                        self.fail(stage: "record (restart)", error, audio: nil)
                    }
                }
            }
            // Re-warm in the background for the next run.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self, self.warmRecorder == nil else { return }
                self.applyWarmMode(s.micWarmMode)
            }
        }
        if el >= Self.recordingLimits(s).warn && !warnBeeped { warnBeeped = true; panel.warn = true; Sounds.play(.warn) }
        if el >= Self.recordingLimits(s).stop && !hardStopped {
            hardStopped = true
            finishRecording(r)
        }
    }

    private func finishRecording(_ r: Recorder) {
        tickTimer?.invalidate(); tickTimer = nil
        recorder = nil
        timeline.mark(.keyUp)
        pasteTarget = PasteTarget.frontmost()
        revealed = false
        let wasLocked = panel.locked; panel.locked = false
        panel.phase = releasePhase(s: settings.current)
        onGestureEvent?(.processingStarted)   // hard stop / pill click: the reducer leaves held/locked
        if let l = live { Task { try? await l.activityEnd() } }
        launchLiveRace()                       // a hold shorter than one tick past the threshold
        let lr = liveRace; liveRace = nil; lr?.releaseSoon()
        Log.info("key up → transcribing")
        let tl = timeline
        let s = settings.current
        let gen = generation
        let w = writer, rid = runId ?? RunRecord.newId().runId, rts = runTs ?? RunRecord.newId().ts
        writer = nil
        let sf = segments; segments = nil
        inflight = Task { [weak self] in
            guard let self else { return }
            do {
                let (pcm, preRoll) = try await self.collectCapture(r)
                let device = r.activeInputName
                await MainActor.run { self.afterCapture(r) }
                guard gen == self.generation else {   // cancelled while stopping: mic is off, keep the audio + a History row
                    w?.finishStreamed()
                    if let w { Self.persistCancelledCapture(url: w.url, runId: rid, ts: rts, settings: s) }
                    return
                }
                // Gate on the audio after key-down only: pre-roll must never turn a tap into a "dictation".
                let post = pcm.subdata(in: preRoll..<pcm.count)
                let held = tl.ms(from: .keyDown, to: .keyUp) ?? 0
                let verdict = CaptureCheck.classify(pcm: post, heldMs: held, locked: wasLocked, minDurationSec: s.minDurationSec, minVoicedMs: s.minVoicedMs)
                let dur = Encoder.duration(pcm16: post)
                let voiced = Encoder.voicedMs(pcm16: post)
                switch verdict {
                case .send: await self.showProcessing()         // hidden at key-up as "no speech": it had some
                default: w?.discard()                           // nothing worth keeping
                }
                switch verdict {
                case .send: break
                case .dropSilently:
                    await MainActor.run { self.dropAccidental(dur, voiced: voiced) }
                    return
                case .noAudio:
                    await MainActor.run { self.noAudio(device: device, dur: dur, held: held) }
                    return
                case .didntCatch, .missedSpeech:
                    await MainActor.run { self.didntCatch(dur, voiced: voiced, held: held, missed: verdict == .missedSpeech) }
                    return
                }
                var capMeta: [String: String] = [:]
                if preRoll > 0 { capMeta["pre_roll_ms"] = String(format: "%.0f", Encoder.duration(pcm16: pcm.prefix(preRoll)) * 1000) }
                if let device { capMeta["input_device"] = device }
                let wavURL = w?.url ?? RecordingStore.url(runId: rid, retention: s.retention)
                let fmt = s.uploadFormat
                // Finalise the streamed WAV + encode off the main actor: ffmpeg/AVAudioFile must not block the UI.
                let audio = try await Task.detached(priority: .userInitiated) { () throws -> EncodedAudio in
                    var saved: URL? = wavURL
                    do {
                        if let w { try w.finish(pcm: pcm) }
                        else { _ = try Encoder.encode(pcm16: pcm, format: .wav, saveTo: wavURL) }
                    } catch { saved = nil }
                    // Segments: the pieces are already out; encode the whole recording only if they fail.
                    if sf != nil {
                        return EncodedAudio(data: Data(), format: fmt.rawValue, durationSec: Encoder.duration(pcm16: pcm),
                                            sampleRate: PCMSpec.sampleRate, fileURL: saved)
                    }
                    let a = try Encoder.encode(pcm16: pcm, format: fmt)
                    return EncodedAudio(data: a.data, format: a.format, durationSec: a.durationSec, sampleRate: a.sampleRate, fileURL: saved)
                }.value
                tl.mark(.encodeDone)
                // Cancelled while encoding: the run's generation is stale, never send it (but keep it in History).
                guard gen == self.generation else {
                    if let f = audio.fileURL { Self.persistCancelledCapture(url: f, runId: rid, ts: rts, settings: s) }
                    return
                }
                await self.transcribeAndFinish(audio: audio, runId: rid, ts: rts, settings: s, gen: gen, captureMeta: capMeta,
                                               segments: sf.map { ($0, pcm) }, fast: lr.map { ($0, voiced / 1000) })
            } catch {
                await MainActor.run {
                    w?.finishStreamed(); self.afterCapture(r)
                    if gen == self.generation { self.fail(stage: "encode", error, audio: nil) }
                    else if let w { Self.persistCancelledCapture(url: w.url, runId: rid, ts: rts, settings: s) }
                }
            }
        }
    }

    /// Accidental touch or silence: nothing is sent, pasted or logged as a run, and the pill just disappears.
    private func dropAccidental(_ dur: Double, voiced: Double) {
        live?.close(); live = nil; dropSegments()
        let held = timeline.ms(from: .keyDown, to: .keyUp) ?? 0
        Log.info(String(format: "dropped: %.2f s audio, %.0f ms voiced, %.0f ms hold — nothing sent", dur, voiced, held))
        if panel.phase != .failed { panel.phase = .idle }   // a start() error already explained what happened
        endBusy()
    }

    /// Deliberate hold but the mic gave nothing (or exact zeros): say which device, restart the mic.
    private func noAudio(device: String?, dur: Double, held: Double) {
        live?.close(); live = nil; dropSegments()
        let name = device ?? "the microphone"
        let input = Self.logInput(device); Log.info(String(format: "no audio: %.2f s captured (empty or digital silence), %.0f ms hold, input %@ — nothing sent", dur, held, input))
        // External or gone (AirPods): the quiet "Didn't catch that", no error card. Built-in: "No sound from …".
        let card = PillFailure.forEmptyCapture(device: device, input: input, kind: AudioDevices.kind(named: device), lidClosed: AudioDevices.lidClosed())
        if panel.phase != .failed {   // a start() error already explained what happened
            panel.failure = card
            if card != .missedSpeech { panel.errorText = "No sound from \(name)" }
            panel.phase = .failed
        }
        restartWarmRecorder(reason: "empty capture after a \(Int(held)) ms hold")
        endBusy()
    }

    /// Deliberate hold, only near-silence (peak < 0.01, rms < 0.002, ≤ 4 s): a soft hint, not an error.
    /// `missed`: a lock or long hold below the voice gate ("Didn't catch that"), which used to vanish (2026-10-19).
    private func didntCatch(_ dur: Double, voiced: Double, held: Double, missed: Bool) {
        live?.close(); live = nil; dropSegments()
        Log.info(String(format: "%@: %.2f s audio, %.0f ms voiced, %.0f ms hold — nothing sent", missed ? "missed" : "didn't catch", dur, voiced, held))
        if panel.phase != .failed {
            panel.failure = missed ? .missedSpeech : PillFailure(kind: .soft, title: "No speech heard", hint: "")
            panel.phase = .failed
        }
        endBusy()
    }

    /// Pill → Retry: re-send the last failed recording (read from disk) with the settings it was recorded with, and paste.
    public func retry() {
        guard let f = lastFailed else { return }
        retryStored(runId: f.runId, ts: f.ts, file: f.file, durationSec: nil, settings: f.settings, copyOnly: false)
    }

    /// History → Retry / Retry with another model: re-send the stored recording and only **copy** the result (never
    /// paste into whatever is focused now). Updates the same History row. False when busy or the audio is gone.
    @discardableResult
    public func retryFromHistory(_ r: RunRecord, model: String? = nil) -> Bool {
        guard let file = r.audio.file else { return false }
        let url = RecordingStore.resolve(file)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        var s = settings.current
        if let model { s.sttModel = model }
        return retryStored(runId: r.runId, ts: r.ts, file: url, durationSec: r.audio.durationSec, settings: s, copyOnly: true)
    }

    @discardableResult
    private func retryStored(runId: String, ts: String, file: URL, durationSec: Double?, settings s: Settings, copyOnly: Bool) -> Bool {
        guard !busy, recorder == nil else { if busy { busyNotice() }; return false }
        busy = true
        timeline = RunTimeline()
        timeline.mark(.keyDown); timeline.mark(.keyUp)
        provider = nil
        panel.reset()
        panel.phase = .transcribing
        onPanelShouldShow?()
        onGestureEvent?(.processingStarted)
        Log.info("retry: re-sending recording \(runId)\(copyOnly ? " (copy only)" : "")")
        if !copyOnly { pasteTarget = PasteTarget.frontmost() }   // paste where the user is now, not the old run's app
        let gen = generation
        self.runId = runId
        inflight = Task { [weak self] in
            do {
                let audio = try await Task.detached(priority: .userInitiated) {
                    try Self.loadStoredAudio(file, format: s.uploadFormat, durationSec: durationSec)
                }.value
                await self?.transcribeAndFinish(audio: audio, runId: runId, ts: ts, settings: s, gen: gen,
                                                existingRow: true, copyOnly: copyOnly)
            } catch {
                await MainActor.run { if let self, gen == self.generation { self.fail(stage: "retry", error, audio: nil) } }
            }
        }
        return true
    }

    /// A stored recording as upload audio: Soyla WAVs are re-encoded to `format`; older non-WAV files go as they are.
    nonisolated static func loadStoredAudio(_ url: URL, format: AudioFormatChoice, durationSec: Double?) throws -> EncodedAudio {
        let ext = url.pathExtension.lowercased()
        if ext == "wav" {
            let pcm = try WAVFile.readPCM(at: url)
            let a = try Encoder.encode(pcm16: pcm, format: format)
            return EncodedAudio(data: a.data, format: a.format, durationSec: a.durationSec, sampleRate: a.sampleRate, fileURL: url)
        }
        let data = try Data(contentsOf: url)
        return EncodedAudio(data: data, format: ext, durationSec: durationSec ?? 0, sampleRate: PCMSpec.sampleRate, fileURL: url)
    }

    // MARK: network + paste + log

    /// `captureMeta`: pre-roll length and input device name, merged into providerMeta (Developer latency line).
    /// `gen`: the generation the run started in; a cancel bumps `generation`, so a stale run never pastes.
    /// `existingRow`: a retry updates the run's History row instead of adding one. `copyOnly`: History retry.
    private func transcribeAndFinish(audio: EncodedAudio, runId: String, ts: String, settings s: Settings,
                                     gen: Int, captureMeta: [String: String] = [:],
                                     existingRow: Bool = false, copyOnly: Bool = false,
                                     segments: (feeder: SegmentFeeder, pcm: Data)? = nil,
                                     fast: (race: LiveRace, voicedSec: Double)? = nil) async {
        let s = Self.effectiveSettings(s)   // S3: everything below (record, cleanup, retry) reads the effective copy
        let tl = timeline
        var record = Self.pendingRecord(audio: audio, runId: runId, ts: ts, settings: s)
        // F4: audio is on disk and the row exists *before* the network call (never lose the user's words).
        if !captureMeta.isEmpty { record.providerMeta = captureMeta }
        if !copyOnly { record.targetApp = targetApp }
        // A retry's row already exists: it is only written at the end, through RetryMerge (F-01), so a failed retry
        // never blanks a good row while the network call runs.
        RunLog.persistRun(record, retry: existingRow, final: false)

        do {
            let provider = try self.provider ?? ProviderFactory.transcriber(for: s)
            var opts = TranscribeOptions(model: s.sttModel, languageHint: s.languageHint)
            opts.vocabulary = s.vocabulary
            // F3 script check (cloud): wrong script → one retry with "Uzbek in Latin script" → still wrong → card, not
            // pasted. Cloud may use pieces / the Live fast path. `.apple`: whole clip on device, D-PUNCT (b), no pieces.
            let result = s.provider == .apple
                ? try await Self.transcribeStage(provider, audio: audio, options: opts, settings: s, timeline: tl)
                : try await Self.transcript(provider, audio: audio, options: opts, timeline: tl, segments: segments, fast: fast)
            if gen != generation { throw CancellationError() }
            record.rawText = result.text
            record.usage = result.usage
            record.providerMeta = result.providerMeta
            panel.rawText = result.text

            // F3: skip rule, cooldown, guards and the dictionary live in CleanupFlow; any doubt → raw is pasted.
            let cooldownKey = ProviderCooldown.key(s.provider, customBaseURL: s.customBaseURL)
            if CleanupFlow.decision(raw: result.text, level: s.cleanupLevel, cooling: ProviderCooldown.shared.isCooling(cooldownKey)) == .call {
                panel.phase = .cleaning
            }
            let c = await CleanupFlow.run(raw: result.text, level: s.cleanupLevel, cleaner: { try ProviderFactory.cleaner(for: s) },
                                          model: s.cleanupModel, vocabulary: s.vocabulary, appName: targetApp,
                                          languageHint: s.languageHint, dictionary: ReplacementDictionary(s.dictionary),
                                          cooldownKey: cooldownKey, timeline: tl)
            if gen != generation { throw CancellationError() }
            record.cleanupUsage = c.usage
            record.providerMeta = (record.providerMeta ?? [:]).merging(c.meta) { _, b in b }
            if let e = c.error { record.error = e }               // raw text is still pasted; logged only
            if c.text != result.text { record.cleanText = c.text; panel.cleanText = c.text }
            let finalText = c.text

            if gen != generation { throw CancellationError() }
            panel.phase = .pasting
            if s.pasteEnabled && !copyOnly {
                // Unstructured Task: cancelling the pipeline Task must not turn Paster's internal sleeps into no-ops
                // (that would restore the clipboard before ⌘V lands).
                let target = pasteTarget
                let outcome = await Task { await Paster.paste(finalText, target: target, timeline: tl) }.value
                var meta = record.providerMeta ?? [:]
                meta["paste"] = outcome.label
                record.providerMeta = meta
                if case .copiedOnly(let reason) = outcome {
                    record.error = (record.error.map { $0 + "; " } ?? "") + "paste: not inserted (\(reason.rawValue))"
                    panel.errorText = "Not pasted: it's on your clipboard"
                    panel.failure = PillFailure.paste(reason)
                }
            } else {
                Paster.copy(finalText)
                tl.mark(.pasted)
            }
            lastFailed = nil
            record.status = .ok
            // P6: free engine, long clip, almost no words → probably not English. Info card; the text was pasted.
            if !copyOnly, panel.failure == nil, OnDeviceHint.shows(provider: s.provider, durationSec: audio.durationSec, text: result.text) {
                panel.failure = .onDeviceHint
                record.providerMeta = (record.providerMeta ?? [:]).merging(["on_device_hint": "1"]) { _, b in b }
            }
            if gen == generation {
                if copyOnly && panel.failure == nil {
                    // History retry only copies: no "Pasted" (phase .done announces it) and no done sound.
                    panel.notice = AppStrings.for(panel.uiLanguage).copied
                    panel.phase = .idle
                } else {
                    panel.phase = panel.failure == nil ? .done : .failed
                    // No sound on errors (D13): the card is the signal. The P6 info card is not an error.
                    if panel.failure == nil || panel.failure?.kind == .info { Sounds.play(.done) }
                }
            }
        } catch where gen != generation {
            record.error = "cancelled"                           // the user pressed Cancel; the pill is already gone
            record.status = .cancelled
        } catch {
            record.error = error.localizedDescription
            if case SoylaError.http(status: 429, body: _)? = error as? SoylaError {
                ProviderCooldown.shared.note429(ProviderCooldown.key(s.provider, customBaseURL: s.customBaseURL))
            }
            if let sc = error as? ScriptCheckError {
                record.providerMeta = (record.providerMeta ?? [:]).merging(["script_check": "failed:" + sc.issue.tag]) { _, b in b }
            }
            record.status = .failed
            var f = PillFailure.from(error, stage: "transcribe")
            // P6: nothing came back from a ≥ 3 s free clip. Nothing to paste (empty-transcript convention), but say why.
            if case SoylaError.emptyTranscript? = error as? SoylaError, !copyOnly,
               OnDeviceHint.shows(provider: s.provider, durationSec: audio.durationSec, text: "") {
                f = .onDeviceHint
                record.providerMeta = (record.providerMeta ?? [:]).merging(["on_device_hint": "1"]) { _, b in b }
            }
            lastFailed = f.canRetry ? audio.fileURL.map { (runId, ts, $0, s) } : nil
            panel.failure = f
            panel.errorText = f.title
            panel.phase = .failed
        }

        if gen == generation, let l = live {             // after a cancel, `live` may belong to the next run
            let lr = try? await l.finish(waitMs: 0)
            var meta = record.providerMeta ?? [:]
            if let v = l.setupMs { meta["live_setup_ms"] = String(format: "%.0f", v) }
            if let v = l.firstInterimMs { meta["live_first_text_ms"] = String(format: "%.0f", v) }
            if let v = l.releaseToFinalMs { meta["live_release_to_final_ms"] = String(format: "%.0f", v) }
            if let t = lr?.text, !t.isEmpty { meta["live_text"] = t; meta["live_final"] = lr?.providerMeta["live_final"] ?? "0" }
            record.providerMeta = meta
            live = nil
        }
        if !captureMeta.isEmpty { record.providerMeta = (record.providerMeta ?? [:]).merging(captureMeta) { a, _ in a } }
        record.timelineMs = tl.toMillis()
        record.net = tl.net
        if gen == generation { panel.latencyLine = settings.current.developerMode ? Self.latencyLine(record) : Self.userLatencyLine(record, language: panel.uiLanguage) }
        Log.info("run \(runId) \(record.status.rawValue)\(record.error.map { ": " + Self.logSafe($0) } ?? "") \(Self.latencyLine(record, forLog: true))")
        if let f = audio.fileURL, Self.deletesAudio(s.retention, status: record.status) {
            try? FileManager.default.removeItem(at: f)
            record.audio.file = nil
        }
        RunLog.persistRun(record, retry: existingRow, final: true)
        if gen == generation { inflight = nil; self.runId = nil; endBusy() }
    }

    private func fail(stage: String, _ error: Error, audio: EncodedAudio?) {
        live?.close(); live = nil; dropSegments()
        tickTimer?.invalidate(); tickTimer = nil
        if let r = recorder { if r === warmRecorder { r.cancel() }; recorder = nil; afterCapture(r) }
        if let w = writer { if w.streamedBytes > 0 { w.finishStreamed() } else { w.discard() }; writer = nil }
        panel.failure = PillFailure.from(error, stage: stage)
        panel.errorText = "\(stage): \(error.localizedDescription)"
        panel.phase = .failed
        Log.info("FAILED at \(stage): \(Self.logSafe(error.localizedDescription))")
        revealed = false
        endBusy()
    }

    /// app.log never gets dictated text: provider errors can carry a response body (which may hold a transcript),
    /// so everything from " body:" on is dropped.
    nonisolated static func logSafe(_ error: String) -> String {
        guard let r = error.range(of: " body:") ?? error.range(of: "body:") else { return error }
        return String(error[..<r.lowerBound]) + " [body omitted]"
    }

    /// Per-run retention (the age-based part is `RecordingStore.sweep`). A failed run always keeps its audio for Retry.
    nonisolated static func deletesAudio(_ retention: AudioRetention, status: RunStatus) -> Bool {
        switch retention {
        case .neverStore: return status != .failed
        case .deleteAfterRun: return status == .ok
        case .keep, .deleteAfter7Days, .deleteAfter14Days: return false
        }
    }

    /// Append (new run) or update in place (retry, final status). A failed update falls back to append.
    private static func persist(_ record: RunRecord, existing: Bool) {
        do {
            if existing, try RunLog.update(record) { return }
            try RunLog.append(record)
        } catch {
            Log.info("runlog: \(error.localizedDescription)")
        }
    }

    /// ESC while recording keeps a capture that had speech in it as a `cancelled` row (Retry from History);
    /// a tap or another key just deletes it.
    private func keepCancelledCapture(_ keep: Bool) {
        guard let w = writer else { return }
        writer = nil
        defer { runId = nil }
        guard keep, let rid = runId, let rts = runTs else { w.discard(); return }
        w.finishStreamed()
        Self.persistCancelledCapture(url: w.url, runId: rid, ts: rts, settings: settings.current)
    }

    /// A cancelled capture with speech in it → a `cancelled` History row (Retry from History); otherwise the file goes.
    /// Shared by ESC-while-recording and a cancel that lands while the run is stopping/encoding.
    private static func persistCancelledCapture(url: URL, runId rid: String, ts rts: String, settings s: Settings) {
        guard let pcm = try? WAVFile.readPCM(at: url), Encoder.voicedMs(pcm16: pcm) >= s.minVoicedMs,
              s.retention != .neverStore else { try? FileManager.default.removeItem(at: url); return }
        let r = RunRecord(runId: rid, ts: rts, source: "live", phraseId: s.phraseId, model: s.sttModel,
                          cleanup: s.cleanupEnabled, cleanupModel: s.cleanupEnabled ? s.cleanupModel : nil,
                          languageHint: s.languageHint, prewarm: s.prewarmConnection,
                          audio: .init(format: "wav", bytes: pcm.count + WAVFile.headerBytes, b64Bytes: 0,
                                       durationSec: Encoder.duration(pcm16: pcm), sampleRate: PCMSpec.sampleRate,
                                       file: RecordingStore.relPath(url)),
                          timelineMs: [:], net: nil, usage: nil, cleanupUsage: nil, rawText: nil, cleanText: nil,
                          error: "cancelled", providerMeta: nil, status: .cancelled)
        Self.persist(r, existing: false)
    }

    /// app.log names the kind of input, never the device's name ("Name's AirPods" is personal).
    nonisolated static func logInput(_ name: String?, inputs: [AudioDevices.Input]? = nil) -> String {
        guard let name else { return "unknown" }
        guard let i = (inputs ?? AudioDevices.inputs()).first(where: { $0.name == name }) else { return "unknown" }
        return i.builtIn ? "builtIn" : "external"
    }

    /// What the pill shows outside Developer mode: no stage names, just the total and the cost when known.
    public static func userLatencyLine(_ r: RunRecord, language: UILanguage = .en) -> String {
        var parts: [String] = []
        if let ms = r.timelineMs["release_to_paste"] { parts.append("\(AppStrings.seconds(ms, language: language)) \(AppStrings.for(language).secs)") }
        if let c = r.usage?.cost { parts.append(String(format: "$%.4f", c)) }
        return parts.joined(separator: " · ")
    }

    /// `forLog`: the app.log copy names only the input kind (builtIn/external), never the device name (R1);
    /// runs.jsonl and the Developer pill keep the name.
    public static func latencyLine(_ r: RunRecord, forLog: Bool = false) -> String {
        let t = r.timelineMs
        func f(_ k: String) -> String { t[k].map { String(format: "%.0f", $0) } ?? "–" }
        var parts = ["stt \(f("stt_total")) ms", "enc \(f("encode"))", "ttfb \(r.net?.ttfb.map { String(format: "%.0f", $0) } ?? "–")"]
        if r.cleanup { parts.append("clean \(f("cleanup"))") }
        parts.append("total \(f("release_to_paste"))")
        if let c = r.usage?.cost { parts.append(String(format: "$%.4f", c)) }
        else if let t = r.usage?.totalTokens { parts.append("\(t) tok") }   // Google direct reports no cost
        if let reused = r.net?.reused { parts.append(reused ? "reused" : "new conn") }
        if let m = r.providerMeta?["pre_roll_ms"] { parts.append("pre-roll \(m) ms") }
        if let d = r.providerMeta?["input_device"] { parts.append("mic \(forLog ? logInput(d) : d)") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Streaming segments

extension DictationPipeline {
    /// Segments when they were streamed (fallback: the whole recording, encoded now), else the whole recording.
    static func transcript(_ provider: any TranscriptionProvider, audio: EncodedAudio, options: TranscribeOptions,
                           timeline tl: RunTimeline, segments: (feeder: SegmentFeeder, pcm: Data)?,
                           fast: (race: LiveRace, voicedSec: Double)? = nil) async throws -> TranscriptResult {
        guard let fast else { return try await transcriptGemini(provider, audio: audio, options: options, timeline: tl, segments: segments) }
        let outcome = await fast.race.finish()
        let pieces = await segments?.feeder.transcriber.finishedPrefix()
        let d = LiveFastDecision.decide(strict: fast.race.strict, live: outcome, pieces: pieces, voicedSec: fast.voicedSec)
        let meta = ["paste_source": d.source.rawValue, "live_reason": d.reason, "live_lang": outcome?.language ?? "-"]
        Log.info("paste source: \(d.source.rawValue) (\(d.reason), \(outcome?.language ?? "-"))")
        if d.source == .live, let outcome {
            segments?.feeder.cancel()
            tl.mark(.requestSent); tl.mark(.responseReceived)
            return TranscriptResult(text: outcome.text, providerMeta: meta.merging(["script_check": "ok"]) { a, _ in a })
        }
        var r = try await transcriptGemini(provider, audio: audio, options: options, timeline: tl, segments: segments)
        r.providerMeta.merge(meta) { a, _ in a }
        return r
    }

    /// The Gemini text: pieces when they were streamed (fallback: the whole recording), else the whole recording.
    static func transcriptGemini(_ provider: any TranscriptionProvider, audio: EncodedAudio, options: TranscribeOptions,
                                 timeline tl: RunTimeline, segments: (feeder: SegmentFeeder, pcm: Data)?) async throws -> TranscriptResult {
        let provider = HedgedProvider.wrap(provider)
        guard let segments else { return try await ScriptCheck.transcribe(provider, audio: audio, options: options, timeline: tl) }
        tl.mark(.requestSent)
        do {
            let o = try await segments.feeder.finish(whole: segments.pcm)
            tl.mark(.responseReceived)
            var r = o.result
            r.providerMeta["segments_pending_at_release"] = String(o.pendingAtRelease)
            return r
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            Log.info("segments failed (\(type(of: error))) — sending the whole recording")
            let fmt = AudioFormatChoice(rawValue: audio.format) ?? .flac
            let whole = try Encoder.encode(pcm16: segments.pcm, format: fmt)
            var r = try await ScriptCheck.transcribe(provider, audio: whole, options: options, timeline: tl)
            r.providerMeta["segments"] = "fallback"
            return r
        }
    }

    /// The run's audio: what replaced recorders captured (mid-run swaps), then the last recorder's.
    func collectCapture(_ r: Recorder) async throws -> (pcm: Data, preRoll: Int) {
        if let st = swapTask { await st.value }
        let tail = try await r.stop()
        if carried.isEmpty { return (tail, min(r.lastPreRollBytes, tail.count)) }
        return (carried + tail, carriedPreRoll)
    }

    /// Key-up: a hold with no speech so far fades out now instead of showing the working wave until the drop
    /// (110 ms usually, up to 1.1 s on Bluetooth). The real check (`CaptureCheck`) still decides.
    func releasePhase(s: Settings) -> PanelModel.Phase {
        liveVoicedMs.withLock { $0 } < s.minVoicedMs ? .idle : .transcribing
    }

    func showProcessing() {
        if panel.phase == .idle { panel.phase = .transcribing; onPanelShouldShow?() }
    }

    /// Audio had started, then no chunk for 1 s: the engine died (device gone or switched). Swap it.
    func swapIfStalled() {
        guard timeline.has(.recStart), ProcessInfo.processInfo.systemUptime - lastChunkAt.withLock({ $0 }) > 1.0 else { return }
        swapRecorderMidRun(reason: "no audio for 1 s")
    }

    /// Replace the recorder during a recording and keep its audio: the new one opens the current default input.
    /// At most one swap in flight and one every 2 s (a device that keeps failing must not loop).
    func swapRecorderMidRun(reason: String) {
        guard let old = recorder, swapTask == nil, let sink = chunkSink,
              Date().timeIntervalSince(lastSwapAt ?? .distantPast) > 2 else { return }
        lastSwapAt = Date()
        Log.info("mic swap during the recording: \(reason)")
        let fresh = makeRecorder()
        recorder = fresh
        if old === warmRecorder { warmRecorder = nil }
        lastChunkAt.withLock { $0 = ProcessInfo.processInfo.systemUptime }   // the new engine gets its own second
        swapTask = Task { [weak self] in
            let pcm = (try? await old.stop()) ?? Data()
            let pre = old.lastPreRollBytes
            Recorder.release([old])
            guard let self else { return }
            let current = await MainActor.run { () -> Bool in
                if self.carried.isEmpty { self.carriedPreRoll = min(pre, pcm.count) }
                self.carried.append(pcm)
                return self.recorder === fresh
            }
            if current {
                do { try await fresh.start(onChunk: sink) } catch { Log.info("mic swap: start failed: \(error.localizedDescription)") }
            }
            await MainActor.run {
                self.swapTask = nil
                // Cancelled while swapping (busy is cleared by a cancel; a key-up keeps it and stops `fresh` itself).
                if self.recorder !== fresh, !self.busy { Recorder.release([fresh]) }
            }
        }
    }

    /// The press is a dictation (hold past the tap threshold, or locked): open the Live sessions now.
    func launchLiveRace() {
        guard let lr = liveRace, !liveRaceLaunched else { return }
        liveRaceLaunched = true
        let v = settings.current.vocabulary
        Task { await lr.launch(vocabulary: v) }
    }

    func dropSegments() {
        segments?.cancel(); segments = nil
        if let lr = liveRace { Task { await lr.cancel() } }; liveRace = nil
    }

    /// S6: Live sessions when the setting is on, the language is uz/ru/en or Auto, and a Google AI Studio key exists.
    static func makeLiveRace(_ s: Settings) -> LiveRace? {
        guard s.liveFastPath, let codes = LiveFastDecision.sessions(for: s.languageHint), let key = try? Secrets.geminiKey() else { return nil }
        return LiveRace(apiKey: key, codes: codes)   // opened by `launchLiveRace()` once the press is a hold
    }

    /// A feeder when the setting is on and a provider exists.
    static func segmentFeeder(_ s: Settings, _ provider: (any TranscriptionProvider)?) -> SegmentFeeder? {
        guard s.streamSegments, let provider else { return nil }
        var o = TranscribeOptions(model: s.sttModel, languageHint: s.languageHint)
        o.vocabulary = s.vocabulary
        return SegmentFeeder(transcriber: SegmentedTranscriber(provider: HedgedProvider.wrap(provider), options: o, minVoicedMs: s.minVoicedMs),
                             config: .app)
    }

    /// Warn/stop seconds. Without pieces one request carries the whole clip, so the old 45/55 s guard applies.
    nonisolated static func recordingLimits(_ s: Settings) -> (warn: Double, stop: Double) {
        s.streamSegments ? (s.warnAtSec, s.hardStopSec) : (min(s.warnAtSec, 45), min(s.hardStopSec, 55))
    }
}
