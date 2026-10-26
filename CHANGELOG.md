# Changelog

All notable changes to this project are documented here.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed
- **Faster by default on Google AI Studio.** When Google AI Studio is your engine, "Instant results with Live" is now on: text appears in about half a second instead of about two. Live hears the audio while you hold the key; turn it off in Developer settings. With OpenRouter it stays off unless you turn it on.

### Fixed
- **No more runaway transcripts.** On a short clip, the speech model sometimes answered with hundreds of invented words and took up to half a minute. Soyla now caps the answer by the clip's length, and an answer far longer than anyone speaks is sent once more instead of pasted.
- **Odd alphabets no longer slip through.** Greek, Armenian, Georgian, Hebrew, Cherokee and any other letters outside Latin and Cyrillic now count as a wrong script, the same as Korean or Arabic: the clip is sent once more, and a few stray letters are removed. Accented Latin names (é, ü, ç, ñ) stay. One or two Turkish or Polish names (ğ, ş, ł, ż) stay too; a whole sentence in such letters is sent once more.
- **Timestamps glued into words are removed.** A subtitle position stuck to a word or to another number is now taken out, and a word it split joins again ("uchra00:04shuv" → "uchrashuv"). Times you dictate ("soat 5:30 da", "14:30da") stay.
- **A reply cut short is no longer pasted as if complete.** When the speech model stops because it hit its length limit, Soyla asks once more with twice the room. If the model used up its room before writing anything, that counts as cut short too, not as silence. If the second answer is cut short too, or runs away, nothing is pasted: the card says "Didn't understand that" and Retry keeps the recording.
- **Long dictations no longer lose a piece silently.** If one piece of a long recording ran away twice, its words were dropped without a sign. Soyla now sends the whole recording instead.
- **Quiet voices are heard.** A softly spoken dictation in a quiet room no longer ends in "Didn't catch that". Soyla now also counts sound that stands well above the room's own background level. True silence and a steady hum are still not sent.
- **Noise no longer pastes stray dots.** When keyboard knocks or breathing come back as only punctuation, such as "_" or ".", nothing is pasted. Numbers always paste, so a stray "34" from noise can still appear. Short words such as "Alo" or "Да" from noise can't be told apart from speech, so they still paste.
- **A stuck request gives up sooner.** A speech request that gets no answer now fails after about 15 seconds on a short clip (longer for long clips, at most a minute) instead of always waiting a full minute. The recording is kept for Retry.

## [0.3.0] - 2026-10-26

### Changed
- **No more password dialog after updates.** API keys now live in a private file on your Mac (`~/Library/Application Support/Soyla/keys.json`, readable by your user only, left out of backups) instead of the Keychain. The first launch moves your saved key out of the Keychain, which makes macOS ask for your password one last time. Going back to an older version means connecting the key again. Trade-off: other programs running as you can read the file without a prompt ([details](docs/SECURITY_MODEL.md#keys)).

### Added
- **My languages.** Settings → Dictation → **My languages**: tick the languages you speak (Uzbek, Russian, English; all three by default). Soyla tells the model you speak only these, and asks once more if the text comes back in an alphabet none of them uses. **Mainly speak** stays as an optional main language. A small label on the pill (**RU**, **UZ·EN**) shows the set while you record, unless all three are ticked. Your earlier Mainly speak choice is kept.
- **Retry as a language.** History → right-click **Retry** → **Retry as**: Uzbek, Russian, English or My languages. It sends the saved recording again with that language and copies the result; it never pastes.
- **Free on-device English engine.** Choose **On this Mac** under Settings → Languages: Apple's speech recognition runs on your Mac, with no key, no account and no audio sent anywhere. English only; Uzbek, Russian and mixed speech still use Cloud. It is the default for new installs when Apple's English model is available. On macOS 14 and 15 it asks for the Speech Recognition permission.
- **Main window redesign.** One window with Home, History and Settings; Settings has the pages Languages, Permissions, Dictation, Hotkey, Pill, Privacy & data and About. Languages replaces the old Engine and API keys pages and shows, per language, where it runs. Pill messages appear as cards. The interface is available in English, Uzbek and Russian.
- **New Setup Assistant** (Welcome, Languages, Permissions, Connect, Try it, Done). Connect appears only if you chose Uzbek or Russian, and you can connect a key right there.
- **Connect keys inline.** Home and Settings → Languages connect OpenRouter or Google AI Studio under the language that needs it. **Replace…** has a **Remove key** item. A key the service rejects is not kept.
- **Sound sets.** Four sets for the start and stop sounds, a volume slider and a **Play** preview (Settings → Dictation).
- **Ignore accidental touches** with three levels, Relaxed, Normal and Strict (Settings → Pill).
- If the provider has not answered after about 3 seconds, Soyla sends a **backup request** and uses whichever answer comes first.
- Experimental, off by default (Developer mode): **Instant results with Live**.
- **No more invented "Thanks for watching".** On a short, quiet clip, a reply that is only a stock video line ("Thanks for watching", "Спасибо за просмотр", "Tomosha qilganingiz uchun rahmat", subtitle credits) is not pasted; the pill says "No speech heard". History keeps the row, and History → Retry still copies the text if you really said it.
- **Report a Problem…** (menu bar icon and Help menu): shows an editable summary of your setup, then Copy or Open GitHub issue (prefilled; you submit it yourself). No dictated text, audio or keys; nothing is sent by Soyla.
- Troubleshooting: how to go back to an earlier version; release notes now link the previous version's zip.

### Changed
- **Raw or Light in one click.** The menu bar icon has **Correction pass: Raw ▸** with Raw and Light (a checkmark shows the current one); the pill's right-click menu has the same. "Off" is now called **Raw** everywhere on screen (your saved choice is unchanged).
- **History shows what the correction changed.** In the cleaned view, removed words are struck through and added or changed words are highlighted; cards where the correction ran and changed the text carry a **Cleaned** tag. Line breaks are kept.
- When the correction is skipped because the service failed or the result looked wrong, History says "Pasted as heard (cleanup skipped)" on that card, and the pill says it the first time each day.
- **Hotkey:** a hold counts as push-to-talk after 0.5 s (was 0.3 s). A double-tap to lock is measured from the first release and has 0.6 s. Tap, then press and hold, sends normally. A press right after locking is ignored for a moment so a stray third tap doesn't stop the recording.
- **Microphone:** you can switch microphones during a recording without losing it.
- The pill closes by shrinking instead of blinking out, and its release is calmer. Accidental taps and silent holds close at once.
- Start and stop sounds are softer by default.
- Settings → Privacy & data: **Keep recordings** offers Don't keep, 14 days or Forever; **Keep the microphone on** offers Off between dictations, For 30 s after a dictation or Always.
- A dictation that cannot work (no key, no sound from the microphone, no permission) is refused when you press the key, with a card that says why.

### Fixed
- A failed History retry never wipes a row that already has text.
- Home no longer says "ready" while Soyla cannot hear or type, and setup's last step no longer says English works to someone who chose only Uzbek or Russian.
- A cancelled last dictation is described as cancelled on Home.

### Security
- **Custom server: plain `http` only on this Mac.** `localhost`, `127.0.0.1` and `::1` still work over `http`; a `.local` name on your network now needs `https` (another device on shared Wi-Fi can pretend to be it). A saved `.local` address shows "This server needs https".
- With the free engine, audio and text never leave the Mac, and Soyla never falls back to Apple's server recognition.

## [0.2.0] - 2026-10-17

### Security
- The app is signed with the hardened runtime and asks for one exception only, the microphone, so other programs can't inject code into Soyla and use its permissions.
- The installed app ignores developer switches (API keys or folders from environment variables, `.env.local`, a test update server). Only the command-line tools use them.
- History (`runs.jsonl`) and `app.log` are readable by your user only; the data folder is re-checked at every launch, and `app.log` rotates at 1 MB.
- When Secure Input blocks pasting, the text left on the clipboard is marked so clipboard managers don't keep it.
- Updates: the installer checks the new app's signature again right before replacing the old one, and waits for the old one to quit. Release notes name the commit and the signing certificate's fingerprint.
- A malformed reply from a custom server can no longer put dictated text into `app.log`.

### Fixed
- Crash on every paste on macOS 26: the keyboard-layout lookup for ⌘V ran off the main thread.
- Error cards in the pill (for example "API key missing") could hang off the bottom of the screen with their buttons cut off.
- After an update, Soyla no longer looks frozen while macOS asks for your password to read the saved API key: the window opens and explains the dialog (type your Mac password, click Always Allow).

### Changed
- The correction pass is **Off** for new installs: text is pasted exactly as heard, with no extra model call. Turn on **Light** in Settings → Dictation. A saved choice is kept.
- Settings → Privacy & data shows the data folder as `~/Library/Application Support/Soyla`, so a shared screenshot no longer shows your Mac user name.
- Each dictation is shown as a note card (when, which app, how long, the text, Copy/Play/Retry) on Home and in History, in a more readable typeface.
- Hesitation sounds (a-a, m-m, э-э, ммм, uh, um) are removed from the pasted text, without an extra model call.
- Settings → Pill: a picture of the screen with six spots to click, and **Place on screen** to drag the pill exactly where you want it.
- Plainer pill messages: each card says what happened and one thing to do.
- The pill feels instant: it shows 0.1 s into a hold (was 0.2 s), fades in 100 ms, its bars follow your voice at 60 fps with one smoothing step, and the processing wave is clearly moving. The microphone stays off between dictations but is prepared ahead, so it starts about 65 ms sooner.
- API keys: one card per provider with a plain status (Not connected, Checking, Connected, Key rejected), two numbered steps and one Paste key button that saves and checks in one go. Pasting another provider's key, an empty clipboard or a sentence is refused with a reason. Settings shows which provider dictation uses.

### Design
- A design code of its own, written down in `docs/DESIGN.md`: one accent (lapis), surfaces that shift only in lightness, speech on note cards, keys drawn as keys (the big one on Home sinks while you hold the hotkey), status as a dot and a word. Own sidebar on the same canvas; Settings as pages of grouped rows (Permissions, API keys, Dictation, Hotkey, Pill, Privacy & data, About, Developer), each with a one-line purpose; Home rebuilt around the held key; Setup Assistant and History restyled to match. Light and dark. A brand mark drawn from one geometry (app icon, menu bar, sidebar, Welcome, the pill); the pill's bars ease at 60 fps instead of stepping at 10 Hz. `--page <id>`, `--appearance light|dark` and `--pill-demo` launch flags.

**Upgrading from 0.1:** the key is no longer read from the repo `.env.local`. Open Settings → API keys and paste it once; it goes to the Keychain.

### Added
- API keys entered in Settings and stored in the macOS Keychain (OpenRouter, Google AI Studio, custom), with Paste / Test / Remove.
- Google AI Studio as a direct provider (free tier works), plus any OpenAI-compatible endpoint; provider picker in Settings.
- First-run Setup Assistant: microphone meter, permissions with a live hotkey probe, API key, try-it step (Help → Setup Assistant… later).
- Never-lose-words: the recording is written to disk while you speak, a History row exists before any network call, Retry re-sends from disk; **Paste Last** (⌘⌃V) and **Copy Last** (⌘⌃C).
- History window for users: search, play audio, raw ↔ cleaned, status badges, retry with another model.
- Hotkey gestures as a tested state machine: hold = push-to-talk, tap = nothing, double-tap = hands-free lock, another key while held = abort, Esc = cancel; event-tap watchdog across sleep.
- Pill v2: drag anywhere with remembered position and presets, dB waveform, honest waiting states (2 s / 4 s with Cancel), right-click Hide for 1 hour, VoiceOver announcements.
- Paste hardening: keyboard-layout-aware ⌘V, per-app clipboard restore delays, Secure Input / focus-change detection with a "text is on your clipboard" card, no auto-retry.
- Capture robustness: 300 ms pre-roll when the mic is warm, warm-mic modes (Off / 30 s / Always), "No audio from <device>" detection, mic suspended on sleep and lock.
- Cleanup safety: JSON envelope prompt, length / answer / script guards that fall back to raw text, Uzbek-script check with one retry, deterministic personal dictionary that works with cleanup off.
- Accidental-touch filter: taps and silent holds are dropped before anything is sent.
- Developer mode (lab controls, latency percentiles, last-request viewer) hidden from users by default.
- Launch at login; Check for Updates… (silent daily check against GitHub Releases).
- Release tooling: `scripts/release.sh`, tag-triggered release workflow, Homebrew cask template, install guide with the Gatekeeper "Open Anyway" step.
- MIT license, contributing guide, security policy, code of conduct, issue and pull request templates; CI on every push.

### Changed
- Data moved to `~/Library/Application Support/Soyla/` (`SOYLA_HOME` keeps the repo layout for development).
- Settings schema v0.2 with a single migration; `chat:` model prefix removed (the provider picks the route).
- Audio retention defaults to 14 days for new installs (Never store / 14 days / Forever).
- Microphone is off between dictations by default; the start cue plays when audio is really flowing.
- Menu-bar icon is a template waveform (red while recording, dimmed while transcribing, badge when something is missing); no error sounds.
- Documentation split into `docs/HARNESS.md`, `docs/TEST_SCRIPTS.md`, `docs/INSTALL.md`.

### Fixed
- Pre-existing: a device switch mid-recording was logged but never acted on; a cancel during encoding could still paste; "today" stats used UTC midnight; test stores imported the developer's real settings; transcript text could reach `app.log` via decode errors.
- A late microphone start error from an earlier run no longer fails the current one; ESC during stopping or encoding still keeps the recording in History; Retry pastes into the app you are in now; History retry only copies, without the "Pasted" sound; settings with an unknown audio format or hotkey keep everything else.

### Security
- The Gemini Live preview sends the API key in a request header instead of the web address, so it can't show up in error messages.
- A custom provider address that isn't valid is refused; Soyla never falls back to sending that key to OpenRouter.
- Error messages keep the server's reply out of the log, and replace your own API key with `[key]` if a server echoes it back.
- Requests never follow redirects, and a custom provider must use https (plain http is allowed only on this Mac or `.local` addresses).
- Check for Updates only opens Soyla's own release page on github.com.

## [0.1.0]

First internal build: a menu-bar dictation harness with latency logging, replay and report tooling.
