# Security model

A dictation app needs a microphone, a global hotkey and the right to type into other apps. That is a lot of trust.
This page says exactly what Soyla does with each permission, what leaves your Mac, how updates are checked, and
what Soyla does **not** protect against. Every claim points to the code, so you can check it yourself.

## Permissions and why

| Permission | Why Soyla needs it | What it does **not** do |
|---|---|---|
| **Microphone** | Records while you hold the hotkey. | Off between dictations by default: the macOS mic indicator only shows while you hold the key. The optional "Keep the microphone on" modes keep 0.3 s of audio in memory, never on disk. |
| **Input Monitoring** or **Accessibility** (either one) | To notice the hotkey (fn by default) anywhere in macOS. | The keyboard listener is listen-only. For each key event it compares the key code and modifier flags with your hotkey, then drops the event. It never stores, logs or sends which keys you press. The only thing kept is the time of the last event, to show that the hotkey works. |
| **Accessibility** | To type the text into the focused app (it posts ⌘V) and to check that the focused spot is a text field. | It reads only the focused app's process, the focused element's role, and whether it accepts text. It never reads the text in your fields or documents, and never takes screenshots. |
| **Speech Recognition** (only the free **On this Mac** engine, macOS 14 and 15) | Lets Apple's on-device recognizer turn your recording into English text. macOS 26 does not ask for it. | The recognition runs on your Mac and Soyla never uses Apple's server recognition. No audio is sent anywhere. |

**Esc to cancel.** While the pill is visible during recording or processing, a second listener lets Esc cancel the
dictation. It exists only during that window, passes every other key through unchanged, and is removed the
moment the pill hides (`Sources/SoylaCore/Hotkey/HotkeyReducer.swift`, tested by a randomised state test).

## The clipboard

To paste, Soyla saves everything on your clipboard in memory, puts the dictation there marked as *transient* (clipboard
managers that follow the [nspasteboard.org](http://nspasteboard.org) convention skip it), presses ⌘V, then
restores your previous clipboard, unless something else changed it in the meantime
(`Sources/SoylaCore/Paste/Paster.swift`). When pasting is impossible (no Accessibility, focus changed, Secure Input
on) the text is left on the clipboard so you can paste it yourself; in the Secure Input case it is also marked
*concealed*, because it was aimed at a password-style field.

## Every host Soyla contacts

With the free **On this Mac** engine, **audio and text never leave your Mac**. The only network use is Apple downloading its English speech model once, handled by macOS, not by Soyla. The table below is for **Cloud** dictation and the update check.

| Host | When | What is sent |
|---|---|---|
| Your provider: `openrouter.ai`, `generativelanguage.googleapis.com`, or your custom URL | When you dictate with Cloud | The recording and a short instruction; with the correction pass on, a second request with the text, your names-and-terms list and the target app's name. If the answer takes about 3 s or more, the same recording is sent a second time as a backup and the first answer wins. |
| Your provider | Right before a dictation, and every 25 s for 10 minutes after the last one | A tiny signed-in request that keeps the connection warm (no audio, no text). Can be turned off. |
| Your provider | When you paste a key | The key, once, to check it |
| `wss://generativelanguage.googleapis.com` | Only with the optional Live preview on | Audio while you hold the key |
| `api.github.com` | At launch, then daily (can be turned off) | Nothing but the request for the latest release number |
| `github.com` (and its download CDN) | Only when you click Update, or with automatic install (off by default) | Nothing; downloads the release zip |

Nothing else. There is no Soyla server, no account, no telemetry, no analytics and no crash reporter. Requests that
carry a key use an ephemeral connection with no cache, send the key in a header (never in a URL), refuse redirects
so the key cannot be forwarded to another host, and strip the key from any error text
(`Sources/SoylaCore/Providers/OpenRouterHTTP.swift`). A custom base URL must use `https`, except that plain `http` is allowed for `localhost`, `127.0.0.1`, `::1` and any
`.local` name (`Sources/SoylaCore/Providers/ProviderFactory.swift`).

## Keys

API keys are stored in one macOS Keychain item, readable only on this Mac after it has been unlocked once
(`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`), so they never sync to iCloud
(`Sources/SoylaCore/Settings/KeychainStore.swift`). After each update macOS asks for your password once before Soyla
may read the item again: the app is not signed by an Apple-registered developer, so macOS ties the item to the exact
build. Clicking **Always Allow** is expected.

## What stays on your Mac

| What | Where | Protection |
|---|---|---|
| History (your transcripts, timings, errors) | `~/Library/Application Support/Soyla/runs.jsonl` | Readable by your user only (0600) |
| Recordings | `…/Soyla/recordings/` | 0600 files in a 0700 folder; deleted after 14 days by default (Settings → Privacy & data). A failed dictation keeps its audio until you retry or remove it. |
| Diagnostics | `…/Soyla/app.log` | 0600; timings and error types only, never dictated text (response bodies are cut before logging, `DictationPipeline.logSafe`); rotated at 1 MB |

History is plain text on your disk and is included in Time Machine backups like the rest of your home folder.

## The app you install

- **Hardened runtime.** The app is signed with macOS's hardened runtime and a single exception, microphone access
  (`Resources/Soyla.entitlements`). Other processes cannot inject code into it with `DYLD_*` variables and borrow its
  permissions.
- **No developer switches in the installed app.** Environment variables that the command-line tools use for testing
  (alternative keys, data folders, update servers) are ignored by `Soyla.app`
  (`Sources/SoylaCore/Settings/DevOverrides.swift`), so nobody can relaunch your Soyla with their own key or server.
  The separate "Soyla Dev" build that developers run next to the real app keeps its keys in a private file
  (readable by your user only) instead of the Keychain. Releases never do that: they always use the Keychain.
- **Self-signed, not notarized.** Releases are signed with the project's own certificate, not an Apple Developer ID,
  so macOS asks you to approve the first open. The certificate's SHA-256 fingerprint is printed in every release's
  notes. Each release also ships a `.sha256` checksum ([how to check it](INSTALL.md#1-download-and-install)).
- **Traceable releases.** A release is built from a clean checkout of the exact tagged commit, and its notes name
  that commit (`scripts/release.sh`). You can also [build the app yourself](INSTALL.md) with Apple's free Command
  Line Tools; there are no third-party packages.

## How updates are verified

When you click **Update** (`Sources/SoylaCore/App/SelfUpdate.swift`, `UpdateCheck.swift`):

1. The release must come from this repository, and the zip must be downloaded from its Releases.
2. The zip must match the published SHA-256 checksum.
3. The app inside must have Soyla's bundle id and the version named by the release tag, newer than yours (no
   downgrades).
4. Its signature must be valid, including nested code, **and** made with the same certificate as the app you are
   running. This is the check that matters: a stolen GitHub account alone cannot ship an update your Soyla accepts.
5. After Soyla quits, the installer checks the signature once more right before swapping the app, and does nothing
   if the old app is still running. The new app starts with a clean environment.

Automatic install is off by default; with it off, nothing is downloaded until you click.

## What Soyla does not protect against

- **Malware already running as your user.** It can read your files, your clipboard and your screen without Soyla's
  help. Soyla's job is to not make that easier.
- **Your provider.** OpenRouter, Google, or your custom server receives your audio and text. Their privacy terms
  apply; Google AI Studio's free tier may use your audio to improve its products.
- **Networks that intercept TLS** (some corporate proxies install their own root certificate). Soyla trusts the
  macOS certificate store and does not pin certificates.
- **A compromised signing certificate.** Updates are only as trustworthy as the certificate that signs them. The
  maintainer keeps it on one Mac and off GitHub.

## Reporting a problem

Please report security issues privately: [SECURITY.md](../SECURITY.md).
