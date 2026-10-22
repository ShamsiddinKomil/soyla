import Foundation
// SAFETY: AVAudioConverter's input block is annotated @Sendable but runs synchronously inside `convert(to:error:)` on
// the tap thread; @preconcurrency lets it capture the non-Sendable AVAudioPCMBuffer it hands over (as in Replay.swift).
@preconcurrency import AVFoundation
import AudioToolbox
import os

// OWNER: Agent A (Audio).
//
// Contract:
//   let r = Recorder()
//   try await r.prepare()                        // optional: warm mode — engine runs, buffers discarded, level live
//   try await r.start(onChunk: { pcm in ... })   // arm capture (cold: request mic permission + start engine first)
//   r.onFirstBuffer -> called once per start(), on the first captured buffer (pipeline marks .recStart)
//   let pcm: Data = try await r.stop()          // returns all PCM16 bytes captured; engine stays warm if prepared
//   r.cancel()                                  // disarm + discard; engine stays warm if prepared
//   r.shutdown()                                // fully stop the engine (app quit / settings change)
//   r.level: Float (0…1 RMS of last buffer, for the panel)
//
// F2 (2026-10-16) additions:
//   Recorder(preRollMs: 300, preferBuiltInMic: true)
//   - pre-roll: while prepared (warm) and NOT armed, the last `preRollMs` of converted audio is kept in a RAM
//     ring; start() prepends it to the capture (and delivers it as the first chunk). Never written anywhere
//     unless start() is called. Cold recorders have nothing to pre-roll. `lastPreRollBytes` = what start() used.
//   - stop() waits a short grace (observed tap cadence + 8 ms, clamped 20–80 ms) before disarming, so the
//     buffer holding the last syllable before release is kept, instead of a fixed sleep.
//   - device: preferBuiltInMic pins the built-in mic on the input AU; if that fails or it vanished, the
//     system default is used. `activeInputName` is set only after the engine actually started on a device.
//   - capturedPeak (0…1) since start(): exactly 0 after real buffers = digital silence (muted / stolen device).
//
// Why warm mode: a cold AVAudioEngine start takes ~400 ms before the first buffer, which eats the
// first syllable in push-to-talk. Warm, start() only flips `capturing`, so the very next buffer counts.
//
// Threading: the tap callback runs on an AVAudioEngine thread. All mutable state is guarded by
// `lock`; callbacks (onFirstBuffer, onChunk) are invoked outside the lock. All calls are idempotent.
// On AVAudioEngineConfigurationChange (device switched, sample rate changed) the tap + converter are
// rebuilt and the engine restarted, keeping prepared/capturing state and already captured PCM.
//
// SAFETY (unchecked Sendable, kept on purpose in Phase 5): every mutable field is guarded by `lock` (level by
// `levelLock`). The state holds non-Sendable AVAudioEngine/AVAudioConverter/AVAudioFormat, so moving it into an
// OSAllocatedUnfairLock<State> would only trade this for withLockUnchecked everywhere, while rewriting the
// hard-won locked paths (engine start under the lock, tap convert, generation token). Behaviour first.
public final class Recorder: @unchecked Sendable {
    public var onFirstBuffer: (@Sendable () -> Void)? {
        get { lock.withLock { _onFirstBuffer } }
        set { lock.withLock { _onFirstBuffer = newValue } }
    }
    /// Own lock: the pill reads this on the main thread every frame, and `lock` can be held for seconds while a
    /// Bluetooth input starts (it froze the app: "hotkey tap disabled by timeout", 2026-10-16).
    public private(set) var level: Float {
        get { levelLock.withLock { _levelValue } }
        set { levelLock.withLock { _levelValue = newValue } }
    }
    private let levelLock = NSLock()
    private var _levelValue: Float = 0
    private var _level: Float {
        get { levelLock.withLock { _levelValue } }
        set { levelLock.withLock { _levelValue = newValue } }
    }

    /// Name of the input device the engine is running on (set only after a successful start).
    public var activeInputName: String? { lock.withLock { _activeInputName } }
    /// Bytes of pre-roll prepended by the last start() (0 when cold or pre-roll is off).
    public var lastPreRollBytes: Int { lock.withLock { _lastPreRollBytes } }
    /// Peak |sample| (0…1) of everything captured since start(), pre-roll included.
    public var capturedPeak: Float { lock.withLock { _capturedPeak } }
    /// Largest recent interval between tap callbacks, in ms (nil before two buffers arrived).
    public var observedCadenceMs: Double? { lock.withLock { tapIntervalsMs.max() } }

    public init(preRollMs: Int = 0, preferBuiltInMic: Bool = false) {
        let frames = PCMSpec.sampleRate * max(0, preRollMs) / 1000
        preRollCap = frames * PCMSpec.channels * PCMSpec.bitsPerSample / 8
        preferBuiltIn = preferBuiltInMic
    }

    /// Release grace: one observed buffer period + 8 ms, clamped to 20–80 ms (Hex's adaptive stop).
    public static func stopGraceMs(cadenceMs: Double?) -> Double {
        guard let c = cadenceMs, c.isFinite else { return 20 }
        return min(80, max(20, c + 8))
    }

    // MARK: state (guarded by lock)
    private let lock = NSLock()
    private var _onFirstBuffer: (@Sendable () -> Void)?
    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var pcm = Data()
    /// Tap → converter path is live (engine running, or the test hook installed a converter).
    private var active = false
    /// Warm mode requested via prepare(): stop()/cancel() keep the engine running.
    private var prepared = false
    /// Armed by start(): converted buffers are kept and delivered.
    private var capturing = false
    private var firstBufferSeen = false
    private var onChunk: PCMChunkHandler?
    /// Bumped by stop/cancel/shutdown so a start() still awaiting mic permission cannot arm afterwards.
    private var generation = 0
    private var configObserver: NSObjectProtocol?
    // F2 state (guarded by lock)
    private let preRollCap: Int
    private let preferBuiltIn: Bool
    private var preRoll = Data()
    private var _lastPreRollBytes = 0
    private var _capturedPeak: Float = 0
    private var _activeInputName: String?
    private var lastTapNs: UInt64 = 0
    private var tapIntervalsMs: [Double] = []
    /// Set by preload(): the engine is built for this device and format but not running.
    private var preloaded: (device: AudioDeviceID?, format: AVAudioFormat, name: String)?
    private var building = false

    private static let tapFrames: AVAudioFrameCount = 1024
    static let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                            sampleRate: Double(PCMSpec.sampleRate),
                                            channels: AVAudioChannelCount(PCMSpec.channels),
                                            interleaved: true)!

    // MARK: public API

    /// Warm mode: request mic permission and keep the engine running with the tap converting, but
    /// discard buffers until start(). Updates `level` so a live meter works. Idempotent.
    public func prepare() async throws {
        if lock.withLock({ prepared && active }) { return }
        if !lock.withLock({ active }) { try await Self.ensureMicPermission() }
        try lock.withLock {
            if !active { try startEngineLocked() }
            prepared = true
        }
    }

    /// Arm capture. Warm: just flips the flag (the next buffer is the first captured one).
    /// Cold: requests permission and starts the engine first.
    /// `keepWarm`: also enter warm mode (as if prepared) in the same locked step, so stop() keeps the engine
    /// running (idle-close mode). Done here rather than via prepare() so the generation token still guards it.
    public func start(onChunk: PCMChunkHandler? = nil, keepWarm: Bool = false) async throws {
        let gen = lock.withLock { () -> Int? in capturing ? nil : generation }
        guard let gen else { return }
        if !lock.withLock({ active }) { try await Self.ensureMicPermission() }
        let pre = try lock.withLock { () -> Data? in
            // stop()/cancel() ran while we were waiting for permission: stay disarmed.
            guard generation == gen, !capturing else { return nil }
            if !active { try startEngineLocked() }
            if keepWarm { prepared = true }
            pcm = Data()
            pcm.reserveCapacity(PCMSpec.bytesPerSecond * 10)
            // Warm only: audio from just before key-down (RAM ring) becomes the start of the capture.
            var head: Data?
            if prepared, preRollCap > 0, !preRoll.isEmpty {
                let n = min(preRoll.count, preRollCap) & ~1
                head = Data(preRoll.suffix(n))
            }
            preRoll = Data()
            _lastPreRollBytes = head?.count ?? 0
            _capturedPeak = head.map(Self.peak) ?? 0
            if let head { pcm.append(head) }
            firstBufferSeen = false
            self.onChunk = onChunk
            capturing = true
            return head
        }
        if let pre, !pre.isEmpty { onChunk?(pre) }   // outside the lock, like every callback
    }

    /// Disarm and return all PCM16 bytes captured. Keeps the engine running if prepared.
    /// Calling it again (or without start) returns the last captured buffer.
    public func stop() async throws -> Data {
        // Adaptive grace: let the buffer that holds the audio up to the release arrive before disarming.
        let graceMs = lock.withLock { capturing && active ? Self.stopGraceMs(cadenceMs: tapIntervalsMs.max()) : 0 }
        if graceMs > 0 { try? await Task.sleep(nanoseconds: UInt64(graceMs * 1_000_000)) }
        let (data, eng) = lock.withLock { () -> (Data, AVAudioEngine?) in
            generation += 1
            guard capturing else { pcm = Data(); return (Data(), nil) }   // never armed → no stale audio
            flushConverterLocked()           // appends resampler tail while still capturing
            capturing = false
            onChunk = nil
            if prepared { return (pcm, nil) }
            let e = engine
            teardownLocked(); _level = 0
            return (pcm, e)
        }
        Self.stopEngine(eng)                 // outside the lock: the tap block may need it
        return data
    }

    /// Disarm and discard. Keeps the engine running if prepared.
    public func cancel() {
        let eng = lock.withLock { () -> AVAudioEngine? in
            generation += 1
            capturing = false
            onChunk = nil
            pcm = Data()
            preRoll = Data()
            if prepared { return nil }
            let e = engine
            teardownLocked(); _level = 0
            return e
        }
        Self.stopEngine(eng)
    }

    /// Fully stop the engine and leave warm mode (app quit, input device / settings change).
    /// Any in-progress capture is discarded.
    public func shutdown() {
        let eng = lock.withLock { () -> AVAudioEngine? in
            generation += 1
            let e = engine
            teardownLocked()
            prepared = false
            capturing = false
            pcm = Data()
            preRoll = Data()
            _activeInputName = nil
            _level = 0
            return e
        }
        Self.stopEngine(eng)
    }

    /// Cold-start shortcut with the mic still OFF (no macOS indicator): build the engine, point it at the input,
    /// install the tap and prepare, but don't start. start() then only starts the device. Measured on an M4 Pro
    /// (built-in mic): first buffer 150 ms after start vs 215 ms fully cold; the build itself takes ~75 ms.
    /// Needs mic permission already granted (callers check). Discarded at start if the input changed meanwhile.
    public func preload() {
        // Built WITHOUT the lock: creating the input unit can take seconds on a Bluetooth headset, and the main
        // thread reads `level`/`isPreloaded` under this lock (held, it froze the app: "hotkey tap disabled by
        // timeout", 2026-10-16). Only the hand-over is locked.
        guard let gen = lock.withLock({ engine == nil && !active && !building ? generation : nil }) else { return }
        lock.withLock { building = true }
        defer { lock.withLock { building = false } }
        let eng = AVAudioEngine()
        let pick = AudioDevices.resolve(preferBuiltIn: preferBuiltIn)
        var device = AudioDevices.defaultInputID()
        var name = device.flatMap(AudioDevices.name) ?? "Default input"
        if pick.pinned, let id = pick.id, Self.setInputDevice(eng, id) {
            device = id; name = pick.name
        } else if preferBuiltIn, let d = device {
            _ = Self.setInputDevice(eng, d)
        }
        let hw = eng.inputNode.outputFormat(forBus: 0)
        guard hw.sampleRate > 0, hw.channelCount > 0, let conv = AVAudioConverter(from: hw, to: Self.targetFormat) else { return }
        eng.inputNode.installTap(onBus: 0, bufferSize: Self.tapFrames, format: hw) { [weak self] buf, _ in self?.process(buf) }
        eng.prepare()
        let kept = lock.withLock { () -> Bool in
            // A start() went cold, or shutdown()/cancel() ran meanwhile: discard ours.
            guard engine == nil, !active, generation == gen else { return false }
            engine = eng; converter = conv
            preloaded = (device, hw, name)
            return true
        }
        if !kept { eng.inputNode.removeTap(onBus: 0) }
    }

    /// cancel() + shutdown() on a background queue, for callers on the main thread: both take `lock`, which a
    /// Bluetooth input can hold for seconds while it starts.
    public static func release(_ rs: [Recorder]) {
        guard !rs.isEmpty else { return }
        DispatchQueue.global(qos: .userInitiated).async { for r in rs { r.cancel(); r.shutdown() } }
    }

    /// True while a preloaded (built, not running) engine is waiting.
    public var isPreloaded: Bool { lock.withLock { preloaded != nil } }

    // MARK: permission

    static func ensureMicPermission() async throws {
        let msg = "Microphone access denied. System Settings → Privacy & Security → Microphone (grant the app/terminal running soyla)."
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return
        case .notDetermined:
            let ok = await AVCaptureDevice.requestAccess(for: .audio)
            if !ok { throw SoylaError.permission(msg) }
        case .denied, .restricted:
            throw SoylaError.permission(msg)
        @unknown default:
            throw SoylaError.permission("Microphone access status unknown.")
        }
    }

    // MARK: engine plumbing (call with lock held)

    private func startEngineLocked() throws {
        if let p = preloaded, let eng = engine {
            preloaded = nil
            let pick = AudioDevices.resolve(preferBuiltIn: preferBuiltIn)
            let now = pick.pinned ? pick.id : AudioDevices.defaultInputID()
            let same = now == p.device && eng.inputNode.outputFormat(forBus: 0) == p.format
            if same, (try? eng.start()) != nil {
                lastTapNs = 0; tapIntervalsMs = []
                _activeInputName = p.name
                active = true
                configObserver = NotificationCenter.default.addObserver(
                    forName: .AVAudioEngineConfigurationChange, object: eng, queue: nil
                ) { [weak self] _ in self?.handleConfigChange() }
                return
            }
            eng.inputNode.removeTap(onBus: 0)   // not running: no tap block in flight, safe under the lock
            eng.stop()
            engine = nil; converter = nil
        }
        let eng = AVAudioEngine()
        engine = eng
        do {
            try startOnBestDeviceLocked(eng)
        } catch {
            teardownLocked()
            throw error
        }
        active = true
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: eng, queue: nil
        ) { [weak self] _ in self?.handleConfigChange() }
    }

    /// Built-in mic if preferred and present, else the system default. A pinned device that fails to start
    /// falls back to the default once; the name is recorded only after the engine really runs.
    private func startOnBestDeviceLocked(_ eng: AVAudioEngine) throws {
        lastTapNs = 0; tapIntervalsMs = []
        let pick = AudioDevices.resolve(preferBuiltIn: preferBuiltIn)
        if pick.pinned, let id = pick.id {
            if Self.setInputDevice(eng, id) {
                do {
                    try installTapAndStart(eng)
                    _activeInputName = pick.name
                    return
                } catch {
                    FileHandle.standardError.write(Data("soyla recorder: preferred input failed (\(error.localizedDescription)); using the default\n".utf8))
                }
            }
            if let d = AudioDevices.defaultInputID() { _ = Self.setInputDevice(eng, d) }
        } else if preferBuiltIn, let d = AudioDevices.defaultInputID() {
            // Built-in preferred but gone (lid closed?): make sure a previously pinned AU follows the default.
            _ = Self.setInputDevice(eng, d)
        }
        try installTapAndStart(eng)
        _activeInputName = AudioDevices.defaultInputID().flatMap(AudioDevices.name) ?? "Default input"
    }

    /// Point the engine's input unit at a specific device (must happen before the input format is read).
    private static func setInputDevice(_ eng: AVAudioEngine, _ id: AudioDeviceID) -> Bool {
        guard let au = eng.inputNode.audioUnit else { return false }
        var dev = id
        return AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                    &dev, UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr
    }

    private func installTapAndStart(_ eng: AVAudioEngine) throws {
        try installTap(eng)
        eng.prepare()
        do { try eng.start() } catch {
            eng.inputNode.removeTap(onBus: 0)
            throw SoylaError.audio("AVAudioEngine failed to start: \(error.localizedDescription)")
        }
    }

    private func installTap(_ eng: AVAudioEngine) throws {
        let input = eng.inputNode
        let hw = input.outputFormat(forBus: 0)
        guard hw.sampleRate > 0, hw.channelCount > 0 else {
            throw SoylaError.audio("No audio input device (input format \(hw)).")
        }
        guard let conv = AVAudioConverter(from: hw, to: Self.targetFormat) else {
            throw SoylaError.audio("Cannot convert \(hw) → 16 kHz mono Int16.")
        }
        converter = conv
        input.installTap(onBus: 0, bufferSize: Self.tapFrames, format: hw) { [weak self] buf, _ in
            self?.process(buf)
        }
    }

    /// Call WITHOUT the lock held: removeTap/stop may wait for an in-flight tap block that needs the lock.
    private static func stopEngine(_ eng: AVAudioEngine?) {
        guard let eng else { return }
        eng.inputNode.removeTap(onBus: 0)
        eng.stop()
    }

    private func teardownLocked() {
        preloaded = nil
        if let o = configObserver { NotificationCenter.default.removeObserver(o) }
        configObserver = nil
        engine = nil
        converter = nil
        onChunk = nil
        active = false
        capturing = false
    }

    private func handleConfigChange() {
        lock.withLock {
            guard active, let eng = engine else { return }
            // The engine has stopped itself; drain the old converter (hw format may differ now) and rebuild.
            // prepared/capturing are untouched, so a warm recorder stays warm and a capture continues.
            eng.inputNode.removeTap(onBus: 0)
            eng.stop()
            flushConverterLocked()
            do {
                try startOnBestDeviceLocked(eng)   // re-resolves: a vanished pinned mic falls back to the default
            } catch {
                FileHandle.standardError.write(Data("soyla recorder: restart after config change failed: \(error.localizedDescription)\n".utf8))
                // Don't pretend to be live: tear down so the next start() goes cold and surfaces the error.
                teardownLocked(); prepared = false; capturing = false; _level = 0
            }
        }
    }

    /// Drain the resampler tail (kept only while capturing) and reset the converter for reuse.
    private func flushConverterLocked() {
        guard let conv = converter,
              let out = AVAudioPCMBuffer(pcmFormat: Self.targetFormat, frameCapacity: 4096) else { return }
        var err: NSError?
        _ = conv.convert(to: out, error: &err) { _, status in
            status.pointee = .endOfStream
            return nil
        }
        if capturing, err == nil, out.frameLength > 0 { _ = appendLocked(out) }
        conv.reset()
    }

    // MARK: tap callback

    /// Converts every input buffer (keeps the resampler continuous and `level` live); keeps the
    /// result only while capturing.
    func process(_ buf: AVAudioPCMBuffer) {
        var firstCB: (@Sendable () -> Void)?
        var chunkCB: PCMChunkHandler?
        var chunk: Data?
        lock.lock()
        guard active, let conv = converter else { lock.unlock(); return }
        let now = DispatchTime.now().uptimeNanoseconds
        if lastTapNs > 0, now > lastTapNs {
            tapIntervalsMs.append(Double(now - lastTapNs) / 1e6)
            if tapIntervalsMs.count > 8 { tapIntervalsMs.removeFirst() }
        }
        lastTapNs = now
        if capturing, !firstBufferSeen { firstBufferSeen = true; firstCB = _onFirstBuffer }
        let ratio = Self.targetFormat.sampleRate / buf.format.sampleRate
        let cap = AVAudioFrameCount((Double(buf.frameLength) * ratio).rounded(.up)) + 64
        if let out = AVAudioPCMBuffer(pcmFormat: Self.targetFormat, frameCapacity: cap) {
            // The input block is typed @Sendable but runs synchronously inside convert(), on this thread; the flag
            // lives in a lock only so the compiler can check it. Never contended (local to this call), never blocks.
            let fed = OSAllocatedUnfairLock(initialState: false)
            var err: NSError?
            _ = conv.convert(to: out, error: &err) { _, status in
                if fed.withLock({ f in let old = f; f = true; return old }) { status.pointee = .noDataNow; return nil }
                status.pointee = .haveData
                return buf
            }
            if err == nil, out.frameLength > 0 {
                if capturing {
                    chunk = appendLocked(out)
                    chunkCB = onChunk
                } else {
                    updateLevelLocked(out)
                    if prepared, preRollCap > 0, let p = out.int16ChannelData?[0] {
                        preRoll.append(Data(bytes: p, count: Int(out.frameLength) * MemoryLayout<Int16>.size))
                        if preRoll.count > preRollCap * 2 { preRoll = Data(preRoll.suffix(preRollCap)) }
                    }
                }
            }
        }
        lock.unlock()
        firstCB?()
        if let c = chunk { chunkCB?(c) }
    }

    private func appendLocked(_ out: AVAudioPCMBuffer) -> Data {
        let n = Int(out.frameLength)
        guard n > 0, let p = out.int16ChannelData?[0] else { return Data() }
        // Int16 in native byte order; Apple silicon and Intel are little-endian == PCM16 LE.
        let bytes = Data(bytes: p, count: n * MemoryLayout<Int16>.size)
        pcm.append(bytes)
        updateLevelLocked(out)
        var pk: Int32 = 0
        for i in 0..<n { pk = max(pk, abs(Int32(p[i]))) }
        _capturedPeak = max(_capturedPeak, Float(pk) / 32768)
        return bytes
    }

    private func updateLevelLocked(_ out: AVAudioPCMBuffer) {
        let n = Int(out.frameLength)
        guard n > 0, let p = out.int16ChannelData?[0] else { return }
        var sum: Double = 0
        for i in 0..<n { let s = Double(p[i]) / 32768.0; sum += s * s }
        _level = Float(min(1, (sum / Double(n)).squareRoot()))
    }

    /// Peak |sample| (0…1) of PCM16 LE bytes.
    static func peak(_ d: Data) -> Float {
        var pk: Int32 = 0
        d.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for v in raw.bindMemory(to: Int16.self) { pk = max(pk, abs(Int32(Int16(littleEndian: v)))) }
        }
        return Float(pk) / 32768
    }

    // MARK: test hook (no mic / no engine)

    /// Makes the recorder behave as if prepared with a running engine whose input is `inputFormat`.
    /// Feed buffers with `process(_:)`. Only for unit tests.
    func _prepareForTesting(inputFormat: AVAudioFormat) throws {
        try lock.withLock {
            guard let conv = AVAudioConverter(from: inputFormat, to: Self.targetFormat) else {
                throw SoylaError.audio("test converter")
            }
            converter = conv
            active = true
            prepared = true
        }
    }

    var _isActiveForTesting: Bool { lock.withLock { active } }
    var _preRollBufferedBytesForTesting: Int { lock.withLock { preRoll.count } }
}
