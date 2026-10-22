# Troubleshooting

Find what you see, try the fix. Most problems are a permission. If you cannot find yours, see [Still stuck](#still-stuck).

**Nothing happens**
- [Nothing happens when I hold fn](#nothing-happens-when-i-hold-fn)
- [Permissions look on, but nothing works](#permissions-look-on-but-nothing-works)
- [The pill says "No sound from ..."](#no-sound-from-)
- [The pill is off-screen or missing](#the-pill-is-off-screen-or-missing)

**Text does not appear**
- [Text doesn't appear where I wanted it](#text-doesnt-appear-where-i-wanted-it)
- [Not pasted: it's on your clipboard](#text-went-to-the-clipboard-only)
- [Text was pasted in the wrong app](#text-was-pasted-in-the-wrong-app)

**Cloud errors (Uzbek, Russian, mixed)**
- [Key rejected](#your-api-key-was-refused)
- [No API key yet](#no-api-key-yet)
- [Out of credits](#out-of-credits)
- [Too many requests](#too-many-requests-and-the-60-second-pause)
- [No internet](#no-internet)
- [Wrong language or script](#wrong-language-or-script)

**Free engine (On this Mac)**
- [Free engine: model not ready](#free-engine-model-not-ready)

**The app and macOS**
- [All pill messages](#other-pill-messages)
- [macOS blocks Soyla from opening](#macos-blocks-soyla-from-opening)
- [I cannot find the Soyla window](#i-cannot-find-the-soyla-window-or-it-is-tiny)
- [macOS asks for your password after an update](#macos-asks-for-your-password-soyla-wants-to-use-your-confidential-information)
- [Go back to an earlier version](#go-back-to-an-earlier-version)
- [Still stuck](#still-stuck)

---

## Nothing happens when I hold fn

Hold the key for at least half a second. A quicker press is treated as an accident ([gestures](USAGE.md#gesture-cheat-sheet)). If you hold longer and still see no pill, look at the menu bar menu. If the menu says *Hotkey not active: check permissions*, a permission is missing.

Check these in order:

1. **Input Monitoring and Accessibility** are both on (Settings, Permissions).
2. **Another app owns fn.** Wispr Flow and Amical also listen to fn. Quit them, or pick a different hotkey in Settings, Hotkey.
3. **"Press 🌐 key to" is not "Do Nothing".** Set it in System Settings, Keyboard ([how](PERMISSIONS.md)).
4. **Your keyboard has no fn key** (common on non-Apple keyboards). Choose another key in Settings, Hotkey, **Hold to talk**: Right ⌥, Right ⌘, Right ⌃, ⌃⇧Space or F13.
5. Run the Setup Assistant again: menu bar icon, **Setup Assistant…** (also in Settings, About). Its Try it step tells you whether macOS delivers the key at all.

If the pill says **Soyla can't hear you yet** or **Soyla can't type for you yet**, allow the microphone or Accessibility first (Settings, Permissions).

## Permissions look on, but nothing works

macOS can treat a new build of Soyla as a different app while the lists still show Soyla as on. Switch Soyla **off and on again** under both Accessibility and Input Monitoring, or run in Terminal:

```
tccutil reset Accessibility ai.soyla.app; tccutil reset ListenEvent ai.soyla.app
```

and grant both again. Full explanation: [Permissions](PERMISSIONS.md#after-an-update-toggles-look-on-but-nothing-works).

## "No sound from ..."

With the built-in microphone, the pill says **No sound from <device name>**. With AirPods or another external mic (or when they disconnect mid-recording) the pill quietly says **Didn't catch that** and nothing is sent. Either way you held the key, but the microphone delivered silence. Usual causes:

- **AirPods or another headset are connected to your iPhone** (for example through Handoff) and the Mac cannot actually use them. Switch the headset to this Mac, or pick another input.
- **The wrong input** is selected. Open System Settings, Sound, Input and choose the right one. The Setup Assistant's microphone step also has an input picker and a level meter.
- **Use the built-in microphone** while a headset is connected: Settings, Privacy & data, **Prefer the built-in microphone**. The line below it shows the input Soyla is using now.
- **The lid is closed** on a MacBook, so its own microphone is off. Open the lid or connect a microphone.
- **The microphone permission is off:** Settings, Permissions.

Then try again.

## The pill is off-screen or missing

- Settings, Pill, **Reset** (next to **Place on screen**), or click a spot on the picture. Or right-click the pill and choose **Reset position**.
- Settings, Pill may say the pill is hidden until a time. Click **Show again**. (You chose **Hide for 1 hour**.)

## Text doesn't appear where I wanted it

The pill shows a card: **Not pasted: it's on your clipboard** with the hint *Press ⌘V. To paste automatically, allow Accessibility.* The next section explains the other versions of this card.

1. Press **⌘V** now to get your text.
2. Open Soyla, then **Settings**, **Permissions**. If **Accessibility** is orange, click **Allow…** and switch Soyla on in the list ([details](PERMISSIONS.md)).
3. Check Settings, Hotkey: **Paste into the app** must be on. If it is off, Soyla only copies.

If Accessibility is already on but pasting still fails right after you installed a new version, see [permissions look on](#permissions-look-on-but-nothing-works). You can always get the last text back with **⌘⌃V** ([Using Soyla](USAGE.md#paste-last-and-copy-last)) or from History.

## Text went to the clipboard only

Card: **Not pasted: it's on your clipboard** with *A password field or Secure Keyboard Entry blocks typing. Press ⌘V if it's safe.*

macOS blocks apps from typing into some places on purpose. Two common cases:

- You were in a **password field**. This is working as intended; paste with ⌘V only if you are sure.
- **Terminal has "Secure Keyboard Entry" switched on** (Terminal menu, Secure Keyboard Entry). Turn it off if you want Soyla to paste into Terminal. The menu bar menu shows *Secure Input is on: paste disabled* while this is the case.

Soyla copies the text so nothing is lost.

## Text was pasted in the wrong app

Soyla pastes into the app that was in front when you let go of the key. If you switched to another app while it was transcribing, it does not paste there. Instead you see **Not pasted: it's on your clipboard** with *You switched apps. Press ⌘V where you want it.* Press ⌘V in the right place.

To avoid it, wait for the pill to disappear before switching apps. You can also use **⌘⌃V** later in the right app to paste your last dictation again.

## Your API key was refused

The pill says **Your API key was refused** (hint: *Replace it in Languages.*), or the API key row on the Languages page says **Key rejected**.

1. Open Soyla, then Settings, **Languages**. In the **Cloud** group, click **Replace…** on the **API key** row (or **Connect…** on Home).
2. Copy the key again from the provider's page and paste it. Soyla checks it right away ([Keys](KEYS.md)).
3. Make sure the key matches the service chosen under **Cloud**. A Google key does not work for OpenRouter and the other way round.
4. If the key was deleted at the provider, create a new one.

## No API key yet

The pill says **No API key yet** (hint: *Connect a key to start dictating.*), or names the language, for example **Uzbek needs an API key** with *English works without one.* This is not a failure. You asked for a language that runs in the Cloud and no key is saved yet.

Click **Connect…** on the card, on Home, or in Settings, Languages. Steps: [Keys](KEYS.md).

## Out of credits

The pill says **Out of OpenRouter credit** with *Top up at openrouter.ai, then retry.* Add credit on the OpenRouter site, then click **Retry** on the card. Your recording was kept. If you set a credit limit on the key itself, that limit can run out too; raise it on the OpenRouter keys page.

## Too many requests, and the 60-second pause

**Too many requests** (*Wait a few seconds, then retry.*) means the provider is rate-limiting you. Wait a moment and click **Retry**. Free-tier keys have tighter limits ([Keys](KEYS.md)).

After such a response, Soyla skips the Correction pass for that provider for **60 seconds** and pastes the original text instead, so you can keep dictating.

## No internet

![The offline card: No internet, Your recording is saved. Retry when you're online.](media/pill-offline.png)

The pill says **No internet** with *Your recording is saved. Retry when you're online.* Cloud languages need a connection. Click **Retry** once you are back online, or find the recording in History and retry it there. English with **On this Mac** works without internet.

Similar cards: **The server didn't answer in time** (*Your recording is saved. Retry.*) and **Couldn't reach the server** (*Check your internet, then retry.*). If it keeps happening on a working connection, the service may be down; try again in a few minutes.

## Wrong language or script

- **Only one language comes out of a mixed sentence.** Settings, Languages: the Cloud service should be **OpenRouter** (the more reliable one for mixed speech). Settings, Dictation: **Mainly speak** should be **Auto-detect**. See [Keys](KEYS.md).
- **Didn't understand that.** The reply came back in the wrong script twice (for example Uzbek in Cyrillic), so Soyla pasted nothing. Click **Retry** or say it again.
- **Uzbek or Russian came out as English words, or the pill says "Speaking Uzbek or Russian?".** You are on the free engine, which does English only. Add a Cloud key in Settings, Languages ([Using Soyla](USAGE.md#languages-cloud-or-on-this-mac)).

## Free engine: model not ready

These cards appear when **On this Mac** is your engine.

- **English model not ready** (*Open Soyla to finish setup.*): Apple's English model needs a one-time download, which needs internet. Open Soyla, then Settings, Languages. In the **On this Mac** section, the **English speech model** row says *Needs a one-time download (internet)*. Click **Download**, wait until it says **Ready**, then retry the recording.
- **Allow Speech Recognition in Settings:** switch on **Recognize English on this Mac** in Settings, Permissions (or allow Speech Recognition in System Settings, Privacy & Security), then click **Retry**.
- **On-device engine unavailable:** try again. If it repeats, the **English speech model** row on the Languages page says why (for example, Speech Recognition is restricted on this Mac, or the model is not installed). Choose **Cloud** instead if you have a key.

## Other pill messages

| You see | What it means |
|---|---|
| No internet | Offline. The recording is kept; click **Retry** when you are back online. |
| The server didn't answer in time | Try again. |
| The speech service is having trouble | Usually brief; retry in a moment. |
| Didn't understand that | The reply came back in the wrong script twice, so Soyla pasted nothing. Click **Retry**. |
| No speech heard | You held the key but there was almost no sound. |
| Didn't catch that | You locked or held for a while, but there was too little speech to send, or AirPods / an external mic went silent. Say it again. |
| Microphone problem | Try again; if it repeats, choose another mic in System Settings, Sound. See also ["No sound from ..."](#no-sound-from-). |
| Still working on your last dictation | You pressed the hotkey while the previous dictation was still being processed. Wait for it to finish. |
| Transcription failed (HTTP ...) | Retry. If it keeps failing, pick another model in Settings, Languages. |
| Something went wrong | Retry. If it keeps failing, pick another model in Settings, Languages. |

## macOS blocks Soyla from opening

Soyla is not signed by Apple yet, so the first open of each version needs **Open Anyway** in System Settings, Privacy & Security. Step by step with pictures: [Install, section 2](INSTALL.md#2-first-open-open-anyway-one-time-per-version).

## I cannot find the Soyla window, or it is tiny

Soyla lives in the menu bar. Click the Soyla icon (a small sound-wave mark) and choose **Open Soyla**. Or use the **Window** menu, **Soyla Window** (⌘0) while Soyla is the active app. Closing the window does not stop the hotkey; only **Quit Soyla** does.

## Go back to an earlier version

If an update broke something, you can install the previous one. Your settings and history are kept (Soyla never resets them).

1. Choose **Quit Soyla** from the menu bar icon.
2. Open [github.com/ShamsiddinKomil/soyla/releases](https://github.com/ShamsiddinKomil/soyla/releases). Every release note ends with a link to the previous version's zip.
3. Download that `Soyla-vX.Y.Z.zip`, open it, and drag **Soyla** into Applications, replacing the newer one.
4. If macOS asks for your password about the Keychain, type it and click **Always Allow**. If Accessibility or Input Monitoring show as off, switch Soyla off and on again in System Settings.
5. Soyla may offer the newer version again. Settings, About, **Check daily** can be turned off. Please also tell us what broke: menu bar icon, **Report a Problem…**.

## Still stuck

Choose **Report a Problem…** from the menu bar icon (or the Help menu): it shows a short summary of your setup that you can edit, then copies it or opens a prefilled GitHub issue for you to submit. It never includes dictated text, audio or keys. Or open an issue at [github.com/ShamsiddinKomil/soyla/issues](https://github.com/ShamsiddinKomil/soyla/issues). Say what you did, what the pill said, and your macOS version. Do not paste your API key or your transcripts. Soyla's log is `~/Library/Application Support/Soyla/app.log` (Settings, Developer, switch on **Developer mode**, then **Open logs**). Skim it before sharing.

## macOS asks for your password: "soyla wants to use your confidential information"

Soyla keeps your key in the Keychain. Because Soyla is not signed with a paid Apple certificate, macOS asks once after each update whether the new version may read it. All your keys sit in one Keychain item called *Soyla API keys*, so it is one dialog, not one per key. Type your Mac login password and click **Always Allow** (plain **Allow** works only once, so it would ask again next time). While the dialog is open, Soyla's window says so and dictation waits. If you click **Deny**, Soyla can't use the key until you quit and reopen it and click Always Allow. Your key is not lost either way, so don't paste it again.
