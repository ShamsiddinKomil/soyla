import Testing
import Foundation
import CoreGraphics
import Combine
@testable import SoylaCore

@Suite struct PillGeometryTests {
    typealias G = PillGeometry
    // MacBook-like visible frame (Dock at the bottom, menu bar excluded) and a second, larger display to its right.
    let laptop = CGRect(x: 0, y: 70, width: 1512, height: 875)
    let external = CGRect(x: 1512, y: -200, width: 2560, height: 1415)
    let capsule = CGSize(width: 158, height: 44)

    func inside(_ r: CGRect, _ vf: CGRect) -> Bool {
        r.minX >= vf.minX + G.margin - 0.001 && r.maxX <= vf.maxX - G.margin + 0.001 &&
        r.minY >= vf.minY + G.margin - 0.001 && r.maxY <= vf.maxY - G.margin + 0.001
    }

    @Test func presets() {
        let b = G.frame(size: capsule, position: .bottomCenter, anchor: nil, in: laptop)
        #expect(b == CGRect(x: 756 - 79, y: 70 + 48, width: 158, height: 44))
        let t = G.frame(size: capsule, position: .topCenter, anchor: nil, in: laptop)
        #expect(t.maxY == laptop.maxY - G.topInset && t.midX == laptop.midX)
        let r = G.frame(size: capsule, position: .bottomRight, anchor: nil, in: laptop)
        #expect(r.maxX == laptop.maxX - G.rightInset && r.minY == laptop.minY + 48)
        // custom without a drag yet = bottom centre
        #expect(G.frame(size: capsule, position: .custom, anchor: nil, in: laptop) == b)
    }

    @Test func dragRoundTripsThroughAnchor() {
        for f in [CGRect(x: 100, y: 200, width: 158, height: 44),     // lower half
                  CGRect(x: 1200, y: 800, width: 158, height: 44),    // upper half
                  CGRect(x: 600, y: 470, width: 158, height: 44)] {   // near the middle
            let a = G.anchor(of: f, in: laptop)
            let back = G.frame(size: f.size, position: .custom, anchor: a, in: laptop)
            #expect(abs(back.minX - f.minX) < 0.001 && abs(back.minY - f.minY) < 0.001, "\(f) → \(a) → \(back)")
        }
    }

    @Test func anchorSurvivesDisplayChange() {
        // Dragged to the right third, low on the laptop → same relative spot on the external display.
        let f = CGRect(x: 1000, y: 150, width: 158, height: 44)
        let a = G.anchor(of: f, in: laptop)
        let g = G.frame(size: f.size, position: .custom, anchor: a, in: external)
        #expect(inside(g, external))
        #expect(abs((g.midX - external.minX) / external.width - (f.midX - laptop.minX) / laptop.width) < 0.001)
        #expect(abs((g.minY - external.minY) / external.height - (f.minY - laptop.minY) / laptop.height) < 0.001)
    }

    @Test func growsAwayFromNearestEdge() {
        let tall = CGSize(width: 520, height: 120)               // live text appears
        let low = G.anchor(of: CGRect(x: 600, y: 120, width: 158, height: 44), in: laptop)
        let lowBig = G.frame(size: tall, position: .custom, anchor: low, in: laptop)
        #expect(lowBig.minY == 120)                               // bottom edge stays, grows up
        let high = G.anchor(of: CGRect(x: 600, y: 850, width: 158, height: 44), in: laptop)
        let highBig = G.frame(size: tall, position: .custom, anchor: high, in: laptop)
        #expect(highBig.maxY == 894)                              // top edge stays, grows down
        let top = G.frame(size: tall, position: .topCenter, anchor: nil, in: laptop)
        #expect(top.maxY == laptop.maxY - G.topInset)
    }

    @Test func clampsIntoScreen() {
        for a in [PillAnchor(fx: 0, fy: 0), PillAnchor(fx: 1, fy: 1), PillAnchor(fx: 1, fy: 0), PillAnchor(fx: 0, fy: 1)] {
            for size in [capsule, CGSize(width: 408, height: 90)] {
                #expect(inside(G.frame(size: size, position: .custom, anchor: a, in: laptop), laptop))
            }
        }
        // Wider than the screen: pinned to the left margin rather than off-screen to the left.
        let tiny = CGRect(x: 0, y: 0, width: 300, height: 200)
        #expect(G.frame(size: CGSize(width: 520, height: 44), position: .bottomCenter, anchor: nil, in: tiny).minX == G.margin)
        // A drop past the edge is pulled back in.
        let a = G.anchor(of: CGRect(x: 1500, y: 60, width: 158, height: 44), in: laptop)
        #expect(inside(G.frame(size: capsule, position: .custom, anchor: a, in: laptop), laptop))
    }

    @Test func screenUnderPointer() {
        let frames = [CGRect(x: 0, y: 0, width: 1512, height: 982), CGRect(x: 1512, y: -300, width: 2560, height: 1440),
                      CGRect(x: -1920, y: 0, width: 1920, height: 1080)]
        #expect(G.screenIndex(containing: CGPoint(x: 700, y: 500), frames: frames) == 0)
        #expect(G.screenIndex(containing: CGPoint(x: 2000, y: -100), frames: frames) == 1)
        #expect(G.screenIndex(containing: CGPoint(x: -10, y: 10), frames: frames) == 2)
        #expect(G.screenIndex(containing: CGPoint(x: 1512, y: 10), frames: frames) == 1)     // shared edge → right display
        #expect(G.screenIndex(containing: CGPoint(x: 1512, y: 982), frames: frames) == 1)
        #expect(G.screenIndex(containing: CGPoint(x: 700, y: 982), frames: frames) == 0)    // top edge still counts
        #expect(G.screenIndex(containing: CGPoint(x: 700, y: 5000), frames: frames) == nil)
    }

    @Test func dbMapping() {
        func rms(db: Double) -> Float { Float(pow(10, db / 20)) }
        #expect(G.level(rms: 0) == 0)
        #expect(G.level(rms: 1e-7) == 0)
        #expect(abs(G.level(rms: rms(db: -55))) < 1e-4)     // Float RMS input
        #expect(abs(G.level(rms: rms(db: -15)) - 1) < 1e-4)
        #expect(G.level(rms: 1) == 1)
        #expect(abs(G.level(rms: rms(db: -35)) - pow(0.5, 0.7)) < 1e-6)
        // Monotonic over the window.
        var prev = -1.0
        for d in stride(from: -70.0, through: 0, by: 2.5) { let v = G.level(rms: rms(db: d)); #expect(v >= prev); prev = v }
        // A whisper (RMS ≈ 0.005, −46 dBFS) now moves the bars; the old linear ×7 left it at 0.035.
        #expect(G.level(rms: 0.005) > 0.3)
    }

    @Test func smoothingAttackAndRelease() {
        #expect(abs(G.smooth(0, toward: 1) - 0.6) < 1e-12)
        #expect(abs(G.smooth(1, toward: 0) - 0.75) < 1e-12)
        var v = 0.0
        for _ in 0..<10 { v = G.smooth(v, toward: 0.8) }
        #expect(abs(v - 0.8) < 0.001)
    }

    @Test func waitStages() {
        #expect(G.waitStage(elapsed: 0) == .quiet)
        #expect(G.waitStage(elapsed: 0.59) == .quiet)
        #expect(G.waitStage(elapsed: 0.6) == .label)
        #expect(G.waitStage(elapsed: 1.99) == .label)
        #expect(G.waitStage(elapsed: 2) == .stillWorking)
        #expect(G.waitStage(elapsed: 3.99) == .stillWorking)
        #expect(G.waitStage(elapsed: 4) == .slow)
        #expect(G.waitStage(elapsed: 60) == .slow)
    }

    @Test func recordingTint() {
        #expect(G.tint(elapsed: 44.9, warnAt: 45, hardStop: 55) == .normal)
        #expect(G.tint(elapsed: 45, warnAt: 45, hardStop: 55) == .amber)
        #expect(G.tint(elapsed: 49.9, warnAt: 45, hardStop: 55) == .amber)
        #expect(G.tint(elapsed: 50, warnAt: 45, hardStop: 55) == .red)
    }
}

@Suite struct PillModelTests {
    @MainActor @Test func captionsFollowTheCopyRules() {
        let m = PanelModel()
        m.phase = .recording
        #expect(m.caption == nil)                                  // bars only while recording
        m.warn = true; m.elapsedSec = 45.2; m.hardStopSec = 55
        #expect(m.caption == "10 s left")
        m.warn = false
        m.phase = .transcribing
        #expect(m.caption == nil)                                  // < 0.6 s: nothing
        m._setWaitStage(.label)
        #expect(m.caption == nil)                                  // label only with details on
        m.showDetails = true
        #expect(m.caption == "Transcribing…")
        m._setWaitStage(.stillWorking)
        #expect(m.caption == "Still working…")
        m._setWaitStage(.slow)
        #expect(m.caption == "Taking longer than usual…")
        m.phase = .done
        #expect(m.waitStage == .quiet && m.caption == nil)
    }

    // One smoothing step only (Waveform.ease): the model maps the current RMS straight to the bar level.
    @MainActor @Test func levelIsMappedNotSmoothedTwice() {
        let m = PanelModel()
        m.level = 0.1778                                            // −15 dBFS → 1.0 at once
        #expect(abs(m.displayLevel - 1) < 0.01)
        m.levelSource = { 0 }                                       // the recorder wins while it exists
        #expect(m.displayLevel == 0)
        m.levelSource = { nil }                                     // no recorder: fall back to `level`
        #expect(abs(m.displayLevel - 1) < 0.01)
        m.levelSource = nil; m.reset()
        #expect(m.displayLevel == 0)
    }

    // A caption that shows seconds updates once per second (tenths with details on), not on every 20 Hz tick.
    @MainActor @Test func elapsedPublishesOnlyWhatACaptionCanShow() {
        let m = PanelModel()
        var changes = 0
        let c = m.objectWillChange.sink { changes += 1 }
        for i in 1...19 { m.elapsedSec = Double(i) * 0.05 }       // 0.05 … 0.95 s
        #expect(changes == 0)
        m.elapsedSec = 1.0
        #expect(changes == 1)
        c.cancel()
    }

    @MainActor @Test func announcements() {
        #expect(PanelModel.announcement(for: .recording, failure: nil) == "Recording")
        #expect(PanelModel.announcement(for: .transcribing, failure: nil) == "Transcribing")
        #expect(PanelModel.announcement(for: .done, failure: nil) == "Pasted")
        #expect(PanelModel.announcement(for: .cleaning, failure: nil) == nil)
        #expect(PanelModel.announcement(for: .idle, failure: nil) == nil)
        let f = PillFailure(kind: .error, title: "No internet", hint: "Your recording is kept.")
        #expect(PanelModel.announcement(for: .failed, failure: f) == "No internet. Your recording is kept.")
    }
}

/// Home's key cap follows the physical key, not the pipeline phase: the phase starts 0.1 s late (reveal) and stays
/// `.recording` through a tap's double-tap window and a lock, so the key lagged the pill (owner, 2026-10-19).
@MainActor @Suite struct HomeKeyCapTests {
    @Test func followsThePhysicalKeyOnly() {
        let m = PanelModel()
        m.noteHotkeyEvent(.down)
        #expect(m.hotkeyHeld)
        m.noteHotkeyEvent(.timer)
        #expect(m.hotkeyHeld)                       // reducer ticks don't touch it
        m.noteHotkeyEvent(.up)
        #expect(!m.hotkeyHeld)
        m.noteHotkeyEvent(.down); m.noteHotkeyEvent(.reset)
        #expect(!m.hotkeyHeld)                      // monitor restart / hotkey change: never stuck down
        m.phase = .recording; m.locked = true; m.reset()
        #expect(!m.hotkeyHeld)                      // a lock or a pending tap is not a held key
    }

    @Test func keyEdgesDoNotRedrawEveryPanelView() {   // review 2026-10-20: only the key cap observes the key
        let m = PanelModel()
        var changes = 0
        let sub = m.objectWillChange.sink { _ in changes += 1 }
        m.noteHotkeyEvent(.down); m.noteHotkeyEvent(.up)
        #expect(changes == 0)
        sub.cancel()
    }
}

@Suite struct PillSettingsTests {
    @Test func oldBlobKeepsValuesAndGetsPillDefaults() throws {
        let old = #"{"sttModel":"chat:google/gemini-3.5-flash","showDetails":true,"minVoicedMs":400}"#
        let s = try JSONDecoder().decode(Settings.self, from: Data(old.utf8))
        #expect(s.showDetails && s.minVoicedMs == 400)
        #expect(s.pillPosition == .bottomCenter && s.pillAnchor == nil && s.pillSnoozedUntil == nil)
    }

    @Test func unknownPresetFallsBackWithoutResetting() throws {
        let blob = #"{"showDetails":true,"pillPosition":"leftEdge","pillAnchor":{"fx":"bad"}}"#
        let s = try JSONDecoder().decode(Settings.self, from: Data(blob.utf8))
        #expect(s.showDetails)
        #expect(s.pillPosition == .bottomCenter && s.pillAnchor == nil)
    }

    @Test func pillPrefsRoundTrip() throws {
        var s = Settings()
        s.pillPosition = .custom; s.pillAnchor = PillAnchor(fx: 0.8, fy: 0.12); s.pillSnoozedUntil = 1_800_000_000
        let back = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(s))
        #expect(back == s)
    }

    @Test func storePostsDidChange() {
        let suite = "ai.soyla.tests.pill.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { dropTestDomain(suite) }
        let store = SettingsStore(defaults: d)
        var posted = 0
        let o = NotificationCenter.default.addObserver(forName: SettingsStore.didChange, object: store, queue: nil) { _ in posted += 1 }
        defer { NotificationCenter.default.removeObserver(o) }
        store.update { $0.pillPosition = .topCenter }
        #expect(posted == 1)
        #expect(SettingsStore(defaults: d).current.pillPosition == .topCenter)
    }
}

@Suite struct WaveformEasingTests {
    /// A shout after silence: the bars reach most of the way within a few frames, never overshoot, and settle back
    /// more slowly than they rose. No frame moves a bar by more than half its range (nothing flickers).
    @Test func barsRiseFastSettleSlowNeverOvershoot() {
        var h = Waveform.live(0)
        let loud = Waveform.live(1)
        var maxStep = 0.0
        for _ in 0..<6 { let before = h; Waveform.ease(&h, toward: loud, dt: 1.0 / 60); maxStep = max(maxStep, zip(h, before).map { abs($0 - $1) }.max()!) }
        let middleAfterRise = h[3]
        #expect(middleAfterRise > 0.75 * loud[3])
        #expect(h.indices.allSatisfy { h[$0] <= loud[$0] + 1e-9 })
        #expect(maxStep < 0.5)
        for _ in 0..<6 { Waveform.ease(&h, toward: Waveform.live(0), dt: 1.0 / 60) }
        #expect(h[3] > 0.4 * loud[3], "release is slower than attack")
        for _ in 0..<60 { Waveform.ease(&h, toward: Waveform.live(0), dt: 1.0 / 60) }
        #expect(abs(h[3] - 0.16) < 0.01, "settles at the silence floor")
    }

    @Test func outerBarsLagTheMiddle() {
        var h = Waveform.live(0)
        for _ in 0..<2 { Waveform.ease(&h, toward: Waveform.live(1), dt: 1.0 / 60) }
        let progress = h.indices.map { (h[$0] - Waveform.live(0)[$0]) / (Waveform.live(1)[$0] - Waveform.live(0)[$0]) }
        #expect(progress[2] > progress[0] && progress[2] > progress[4])
    }
}

/// The pill window takes its size from `fittingSize`; a failure card once measured 451 pt tall and hung off the
/// bottom of the screen with its buttons cut off (2026-10-16).
@MainActor @Suite struct PillCardSizeTests {
    @Test func failureCardFitsItsContent() {
        let m = PanelModel()
        m.failure = PillFailure(kind: .error, title: "No API key yet", hint: "Add one in Settings to start dictating.", openSettings: true)
        m.phase = .failed
        let h = PillHostingView(rootView: PillView(model: m))
        let size = h.fittingSize
        print("card fittingSize", size)
        #expect(size.height < 140)
        #expect(size.width < 420)
    }

    /// Release → transcribing → pasting → done keeps the window size (guard: the 150 pt minimum width hides small
    /// content changes; the dot slot now has a fixed width too, so the bars no longer jump sideways at release).
    @Test func pillKeepsItsSizeFromRecordingToDone() {
        let m = PanelModel()
        let h = PillHostingView(rootView: PillView(model: m))
        func size(_ p: PanelModel.Phase, locked: Bool = false) -> CGSize {
            m.phase = p; m.locked = locked; m.micLive = true
            h.layoutSubtreeIfNeeded()
            return h.fittingSize
        }
        let rec = size(.recording)
        #expect(size(.recording, locked: true) == rec)
        for p in [PanelModel.Phase.transcribing, .cleaning, .pasting, .done] { #expect(size(p) == rec, "\(p)") }
    }
}

/// 2026-10-20: the close used to drop half its opacity in the first frame (ease-out alpha) and read as a blink.
@Suite struct PillCloseMotionTests {
    @Test func closeStaysVisibleWhileItShrinks() {
        let d = PillMotion.closeDuration, frame = 1.0 / 60
        #expect(d <= 0.3)                                                // DESIGN.md: under 300 ms
        #expect(PillMotion.closeAlpha(frame / d) < 0.01)                // first frame: still fully there
        #expect(PillMotion.closeAlpha(0.5) < 0.2)                      // halfway: the shrink is visible
        #expect(PillMotion.closeAlpha(1) == 1)                          // ends fully gone
        #expect(PillMotion.contentOut < d)                              // bars clear before the capsule goes
        #expect(PillMotion.closeScaleX < 0.8 && PillMotion.closeScaleY < 0.9)   // a real shrink, not a 0.96 nudge
    }
}
