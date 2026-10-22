# FAQ

Quick answers to what newcomers ask most. For step-by-step use, see [Using Soyla](USAGE.md); for problems, see [Troubleshooting](TROUBLESHOOTING.md).

## Basics

**What is Soyla?**
A Mac menu-bar app. You hold a key, speak, let go, and the text is typed into whatever app has your cursor. It is built for people who mix Uzbek, Russian and English in one sentence. See [Using Soyla](USAGE.md).

**Is it free?**
The app is free and open source. English with **On this Mac** costs nothing at all. Uzbek, Russian and mixed speech use a Cloud service (OpenRouter or Google AI Studio) with your own key, and you pay that provider for what you use, or use Google's free tier. As a rough guide, a 40-second dictation costs about half a cent. Details and figures: [Privacy and cost](PRIVACY_AND_COST.md#what-it-costs).

**Which Mac and macOS do I need?**
macOS 14 (Sonoma) or newer. Apple's built-in English engine is the default on macOS 26; on macOS 14 and 15 it is used when Apple's English model is installed. Intel Macs have not been tested; if the app will not open on one, please [open an issue](https://github.com/ShamsiddinKomil/soyla/issues).

**Which languages work?**
Uzbek (written in Latin letters), Russian (Cyrillic) and English, mixed freely in one sentence. Other languages are not tested. See [Languages](USAGE.md#languages-cloud-or-on-this-mac).

## Offline, keys and privacy

**Does it work offline?**
English does, with **On this Mac** (Apple's speech engine, no key needed). Uzbek, Russian and mixed speech need internet, because they run in the Cloud. Without internet the pill says *No internet*; your recording is kept, and **Retry** works when you are back online.

**Why do I need my own API key?**
You only need one for Uzbek and Russian. English does not need a key. Soyla has no server and no subscription: for Uzbek and Russian your audio goes straight from your Mac to OpenRouter or Google with your key, and nobody in the middle sees it. See [Keys](KEYS.md).

**Why is Uzbek not on the Mac, offline?**
Apple's on-device engine does English only. The models that handle Uzbek, Russian and English mixed in one sentence are large hosted models, so those languages go to the Cloud.

**Does Soyla see my screen or my keystrokes?**
No. It listens for one key (your hotkey) and records the microphone only while you hold it. It does not read your screen or log what you type. What it can and cannot do is written out in the [security model](SECURITY_MODEL.md).

**Where is my data?**
On your Mac, in `~/Library/Application Support/Soyla/`, and your keys in the macOS Keychain. Nothing goes to the Soyla author; there is no telemetry. Details: [Privacy and cost](PRIVACY_AND_COST.md).

**Does my voice get used to train AI?**
Soyla itself never uses it. But **Google AI Studio free-tier keys let Google train on your audio**, so use a paid key for confidential speech. See [Privacy and cost](PRIVACY_AND_COST.md#free-tier-warning). With **On this Mac**, your audio never leaves the Mac.

## Setup and settings

**Can I change the hotkey?**
Yes: Settings, Hotkey, **Hold to talk**: fn, Right ⌥, Right ⌘, Right ⌃, ⌃⇧Space or F13. Useful if your keyboard has no fn key or another app uses it ([Permissions](PERMISSIONS.md)).

**Is the app signed or notarized by Apple?**
Not yet. The first open of each version needs one extra click, **Open Anyway** ([Install](INSTALL.md#2-first-open-open-anyway-one-time-per-version)). The code is open, so you can read it or build it yourself.

**How do I uninstall it?**
Quit Soyla, drag it to the Trash, and optionally delete `~/Library/Application Support/Soyla`, the Soyla items in Keychain Access, and its entries under Accessibility and Input Monitoring. Apple's on-device English model belongs to macOS, so it stays and is not part of Soyla. Steps: [Install, Uninstall](INSTALL.md#6-uninstall).

## Quality

**How accurate is it?**
In our tests the default setup kept both languages on a 41-second Uzbek and Russian clip in 7 of 7 runs. It is not perfect: names, rare words and noisy rooms can go wrong. Use the personal dictionary for names, and the original text is always kept in History ([Using Soyla](USAGE.md#personal-dictionary)).

**Can Soyla tidy my text?**
Yes, with the Cloud. The **Correction pass** is Off by default, so text is pasted exactly as heard. Settings, Dictation, **Correction pass**: **Light** removes repeats and applies self-corrections ("at three, no, at four"), about 1.8 s slower. The original is kept in History either way.

**Can I use it in Terminal or in a password field?**
Soyla can paste into Terminal unless **Secure Keyboard Entry** is on. macOS blocks pasting into password fields, so there the text stays on the clipboard for you to paste yourself ([Troubleshooting](TROUBLESHOOTING.md#text-went-to-the-clipboard-only)).

## Help

**How can I help or report a bug?**
Choose **Report a Problem…** in the menu bar to build a short summary of your setup, or open an issue or pull request on [GitHub](https://github.com/ShamsiddinKomil/soyla). Developer notes are in [CONTRIBUTING](../CONTRIBUTING.md), the license is in [LICENSE](../LICENSE), and security reports go via [SECURITY](../SECURITY.md).
