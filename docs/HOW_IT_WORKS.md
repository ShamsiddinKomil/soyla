# How Soyla works

A map of the code for contributors and for anyone checking what the app does. What Soyla can access and why is in
[SECURITY_MODEL.md](SECURITY_MODEL.md); the measurement tooling is in [HARNESS.md](HARNESS.md).

## One dictation, end to end

```
 hotkey down ──► Recorder (AVAudioEngine, 16 kHz mono) ──► WAV streamed to disk while you speak
                                                              │
 hotkey up ───► hold gate: held < 0.5 s? ──► a tap: nothing is sent (may be the first half of a double-tap)
                │
                └─► capture gate: < 0.6 s of audio or < 250 ms of voice? ──► dropped silently (accidental touch) · lock or hold ≥ 1.5 s: "Didn't catch that"
                                                              │
               ┌──────────────── Cloud ───────────────┐   ┌──── On this Mac (English) ────┐
               │ Encoder (WAV/FLAC) ──► provider      │   │ WAV ──► Apple's on-device     │
               │ (your key) ──► transcript            │   │ recognizer ──► transcript     │
               └──────────────────────────────────────┘   │ (no network, no key)          │
                                                          └───────────────────────────────┘
                                                              │
               fillers removed · optional correction pass (Cloud only) · personal dictionary
                                                              │
               Paster: clipboard + ⌘V into the focused app, previous clipboard restored
                                                              │
               History row (runs.jsonl) updated · recording kept or deleted per retention
```

The **hold gate** is the 0.5 s a key must be held to count as push-to-talk; a shorter press is a tap, which is only
used for the double-tap lock. The **capture gate** then checks what was recorded: less than 0.6 s of audio or less than
250 ms of voiced sound is treated as an accidental touch. The voiced-sound part is the Pill setting **Ignore
accidental touches**: Relaxed is 150 ms, Normal 250 ms (default), Strict 400 ms.

A History row is written as `pending` *before* any network call, so a crash, lost Wi-Fi or a rejected key never
loses the recording: Retry re-sends the file.

## Code layout

Swift Package, no third-party packages. `Sources/soyla/main.swift` starts either the app or a CLI command;
everything else is in `Sources/SoylaCore/`:

| Folder | What it does | Key files |
|---|---|---|
| `App/` | AppKit app, the main window (Home, Languages, Settings, History), the pill, the Setup Assistant, update check | `DictationPipeline.swift` (the orchestrator), `FreeEnginePipeline.swift` (what changes for the free engine), `MainWindow.swift`, `FloatingPanel.swift` (pill), `SetupFlow.swift`, `DesignKit.swift` (UI tokens, see [DESIGN.md](DESIGN.md)) |
| `Audio/` | Microphone capture, device changes, WAV/FLAC encoding, "was anything said" checks | `Recorder.swift`, `Encoder.swift`, `CaptureCheck.swift` |
| `Hotkey/` | The global hotkey: a CGEventTap that reports only the hotkey's down/up and Esc, plus a pure gesture state machine (hold, double-tap lock, cancel) | `HotkeyMonitor.swift`, `HotkeyReducer.swift` |
| `Providers/` | Speech-to-text: OpenRouter, Google AI Studio, any OpenAI-compatible URL, Apple's on-device engine, optional Gemini Live preview | `TranscriptionProvider.swift` (the protocol), `ProviderFactory.swift`, `AppleSpeechProvider.swift` and `OnDeviceAvailability.swift` (free engine), `HedgedProvider.swift` (backup request) |
| `Cleanup/` | Filler removal, the optional correction pass, guards that fall back to the raw text, personal dictionary | `CleanupFlow.swift`, `TextGuards.swift` |
| `Paste/` | Inserting text into the focused app; keyboard-layout-aware ⌘V; Secure Input detection | `Paster.swift`, `PasteTarget.swift` |
| `Settings/` | Settings model and storage, API keys in the Keychain, file locations | `Settings.swift`, `Secrets.swift`, `KeychainStore.swift` |
| `Metrics/` | History (`runs.jsonl`), per-run latency timeline, recordings and retention | `RunLog.swift`, `RunRecord.swift`, `RecordingStore.swift` |
| `CLI/` | Developer commands (below) | `Replay.swift`, `Models.swift` |

## Where things are stored

| What | Where |
|---|---|
| Settings | `UserDefaults` suite `ai.soyla.settings` |
| API keys | One macOS Keychain item (service `ai.soyla.app`) holding the keys you saved |
| History (transcripts, timings, errors) | `~/Library/Application Support/Soyla/runs.jsonl` |
| Recordings | `~/Library/Application Support/Soyla/recordings/`, deleted after 14 days by default (Settings → Privacy & data) |
| Diagnostics | `~/Library/Application Support/Soyla/app.log`: timings and error types, never dictated text |

`SOYLA_HOME=/some/folder` moves all files to that folder (development and tests).

## The free engine

The **On this Mac** engine is a provider like the others (`AppleSpeechProvider`), but the pipeline treats it
differently (`App/FreeEnginePipeline.swift`): English only, WAV audio, no correction pass, no Live preview, no
backup request and no cloud connection warm-up, because there is nothing to send. A small rule adds the punctuation
Apple's engine leaves out. `OnDeviceAvailability.swift` decides whether the engine is ready: on macOS 26 Apple's
English model may need a one-time download; on macOS 14 and 15 it needs the Speech Recognition permission and an
on-device model already installed. Soyla never falls back to Apple's server recognition.

## Providers

Every provider implements one protocol:

```swift
public protocol TranscriptionProvider: Sendable {
    var id: String { get }
    func transcribe(_ audio: EncodedAudio, options: TranscribeOptions, timeline: RunTimeline) async throws -> TranscriptResult
}
```

The default sends the audio and a short prompt for mixed Uzbek/Russian/English speech to a general-purpose model
(Gemini 3.5 Flash), because dedicated transcription models decode each recording in one language and drop the
other. Requests that carry a key use an ephemeral `URLSession` with no cache. If a cloud answer takes about 3 s or
more, `HedgedProvider` sends the same recording again and keeps whichever answer arrives first. Adding a provider:
[CONTRIBUTING.md](../CONTRIBUTING.md#adding-a-provider).

## Developer commands

The app binary doubles as a CLI (`.build/release/soyla <command>`):

| Command | Purpose |
|---|---|
| `replay <wav> --models a,b --formats wav,flac` | Re-send one recording to several models for a fair comparison |
| `report` | p50/p90 latency and cost from `runs.jsonl` |
| `models` | List the provider's available models |
| `rec-test`, `hotkey-test`, `paste-test`, `live-test` | Check the microphone, hotkey, paste and live preview in isolation |
| `update-check` | Ask GitHub for the latest release once |

## Tests and checks

`scripts/test.sh` runs the swift-testing suite (plain `swift test` does not find the framework under Command Line
Tools). `scripts/lint.sh` and `swiftformat --lint .` check style; `scripts/prelaunch_check.sh` is the release gate.
CI runs the tests, lint and format check on every push; the release gate runs on every release tag.
