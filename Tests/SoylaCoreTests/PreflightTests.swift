import Testing
import Foundation
@testable import SoylaCore

// Flows audit 2026-10-19 F-05 and F-16.
@Suite struct PreflightTests {
    private func home(_ langs: [SpokenLanguage], _ p: ProviderKind, mic: PermissionState.Mic = .granted, ax: Bool = true,
                      keys: Set<KeyProvider> = []) -> HomeState {
        HomeState(mic: mic, ax: ax, spoken: langs, provider: p, hasKey: { keys.contains($0) }, verified: { keys.contains($0) }, keychain: .ready)
    }

    @Test func aCloudEngineWithNoKeyIsRefusedAtKeyDown() {
        let c = KeyDownPreflight.card(home: home([.en, .uz], .google))
        #expect(c?.fix == .connectKey && c?.kind == .info)
        #expect(c?.shown(.en, readiness: .needsKey(.uz, englishWorks: false)).title == "Uzbek needs an API key")
    }

    @Test func aMissingPermissionIsRefusedWithItsOwnCard() {
        let mic = KeyDownPreflight.card(home: home([.en], .apple, mic: .denied))
        #expect(mic?.title == "Soyla can’t hear you yet" && mic?.fix == .setup(.permissions))
        let ax = KeyDownPreflight.card(home: home([.en], .apple, ax: false))
        #expect(ax?.title == "Soyla can’t type for you yet")
        #expect(ax?.localized(.uz).title == AppStrings.uz.axOff && mic?.localized(.ru).hint == AppStrings.ru.mMicFirst)
    }

    @Test func englishOnThisMacStillRecords() {
        #expect(KeyDownPreflight.card(home: home([.en, .uz], .apple)) == nil)          // Uzbek skipped, English works
        #expect(KeyDownPreflight.card(home: home([.en], .google, keys: [.google])) == nil)
    }

    @Test func theRefusedGestureIsSwallowedAndEndsIdle() {
        var g = PreflightGate()
        let card = PillFailure.permissionNeeded(mic: true)
        #expect(g.route(.startRecording, card: { card }) == .show(card) && g.holding)
        #expect(g.route(.reveal, card: { nil }) == .swallow)
        #expect(g.route(.lock, card: { nil }) == .swallow)
        #expect(g.route(.stopAndSend, card: { nil }) == .idle && !g.holding)
        #expect(g.route(.reveal, card: { nil }) == .pass)                              // a normal gesture again
        #expect(g.route(.startRecording, card: { nil }) == .pass)
        #expect(g.route(.stopAndSend, card: { nil }) == .pass)
    }

    @Test func aCancelledRefusedHoldAlsoEndsIdle() {
        var g = PreflightGate()
        _ = g.route(.startRecording, card: { .permissionNeeded(mic: false) })
        #expect(g.route(.cancelRecording(.escape), card: { nil }) == .idle)
    }

    @Test func noSoundSaysWhatTheInputIs() {
        let lid = PillFailure.noSound(device: "MacBook Pro Microphone", input: .builtIn, lidClosed: true)
        #expect(lid.hint == "Your Mac’s lid is closed, so its microphone is off. Open the lid or connect a microphone.")
        #expect(lid.fix == nil && !lid.hint.contains("AirPods"))
        #expect(lid.localized(.uz).hint.contains("qopqog‘i yopiq") && lid.localized(.ru).hint.contains("Крышка"))
        let bt = PillFailure.noSound(device: "FAKE AirPods", input: .bluetooth, lidClosed: true)
        #expect(bt.hint.contains("AirPods"))
        let usb = PillFailure.noSound(device: "FAKE USB Mic", input: .other, lidClosed: false)
        #expect(!usb.hint.contains("AirPods") && usb.localized(.ru).hint != usb.hint && usb.fix == .page(.privacy))
        let openLid = PillFailure.noSound(device: "MacBook Pro Microphone", input: .builtIn, lidClosed: false)
        #expect(!openLid.hint.contains("AirPods") && !openLid.hint.contains("lid"))
    }

    @Test func cardsDismissThemselves() {
        #expect(PillFailure.noSound(device: nil, input: .builtIn, lidClosed: true).dismissAfter == 8)
        #expect(PillFailure(kind: .soft, title: "No speech heard", hint: "").dismissAfter == 1.8)
        #expect(PillFailure.permissionNeeded(mic: true).dismissAfter == 6)
        #expect(PillFailure.from(URLError(.notConnectedToInternet), stage: "t").dismissAfter == 15)   // holds your words
    }
}

@MainActor @Suite struct SilentInputCaptionTests {
    @Test func theSilenceIsSaidWhileRecording() {
        let m = PanelModel()
        m.phase = .recording
        #expect(m.caption == nil)
        m.silentInput = true
        #expect(m.caption == "No sound from the mic")
        m.uiLanguage = .uz
        #expect(m.caption == "Mikrofondan ovoz kelmayapti")
        m.reset()
        #expect(!m.silentInput)
    }
}
