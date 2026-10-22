# Product

<!-- impeccable:product-schema 1 -->

## Platform

ios

> Soyla is a native **macOS** app (SwiftUI + AppKit, macOS 14+). Impeccable has no `macos` value, so `ios` is
> recorded to load Apple-native guidance. Apply it with macOS conventions: pointer and keyboard first, menu-bar
> app, window sheets, macOS control sizes (not iOS touch targets), System Settings privacy panes.

## Users

- **Primary (v0.3.0 launch):** people with no tech background in Uzbekistan and the CIS. Office workers,
  students, parents, small-business owners. They write all day in Telegram, Google Docs, email and browser
  fields, and they think and speak in a mix of Uzbek, Russian and English. They have never heard of an API key
  and will not read long instructions.
- **Secondary:** technical users (developers, power users) who want to know what runs where. They are served
  by optional detail, never by making the main path more technical.
- **Situation:** they open the Soyla window rarely: the first-run setup, to check it is ready, to fix one
  thing, or to find yesterday's sentence. The product they actually use is a held key and a small floating pill.

## Product Purpose

Hold a key, speak the way you actually talk, let go: the text appears where the cursor is. Success for a new
user is a first real dictation in their own app within about two minutes of first launch, without a key for
English.

## Positioning

- Built for **mixed-language sentences** (Uzbek in Latin script, Russian in Cyrillic, English) in one
  dictation, with no language switch to flip. Competitors pick one language per recording.
- **No Soyla account and no Soyla server.** English runs free and offline on the Mac (Apple's on-device speech
  model). Uzbek, Russian and mixed speech use a cloud model the user connects with their own key (Google AI
  Studio or OpenRouter); audio goes straight from the Mac to that provider.
- Free and open source (MIT).

## Operating Context

- A menu-bar app. Default hotkey: hold **fn (🌐)**. Double-tap fn locks hands-free; Esc cancels.
- First run needs macOS permissions the user must grant themselves: Microphone, Accessibility (paste + hotkey),
  possibly Input Monitoring (being removed if Accessibility alone suffices), and the "Press 🌐 key to: Do
  Nothing" keyboard setting when fn is the hotkey.
- Getting a cloud key means leaving the app for a provider website (Google AI Studio or OpenRouter), signing
  in, creating a key and pasting it back. This is the hardest step for the primary user.
- Distributed as a zip from GitHub Releases, self-signed: the first open goes through macOS "Open Anyway".

## Capabilities and Constraints

- Engines: **On this Mac** (free, English only, offline, macOS 26 analyzer or macOS 14–15 legacy recognizer)
  and **Cloud** (user's key; Uzbek, Russian, English and mixed).
- Onboarding decisions confirmed 2026-10-17: ask **"Which languages do you speak?"** instead of choosing an
  engine; a small info button with a hover hint carries the technical explanation; key setup appears in
  onboarding **only** when Uzbek or Russian is picked; Input Monitoring is dropped if testing confirms
  Accessibility alone is enough.
- **Interface languages: English, Uzbek (Latin) and Russian** (owner decision 2026-10-17). No localization
  layer exists yet; SwiftPM-only build with Command Line Tools (no Xcode), so string resources must work without
  Xcode tooling.
- Hard rules: never log dictated text; zero third-party dependencies; UI only through `docs/DESIGN.md` tokens and
  `DesignKit.swift` components (until a redesign replaces them).
- macOS system prompts and System Settings switches cannot be clicked for the user; the design must guide the
  user through them.

## Brand Commitments

- Name: **Soyla** (Uzbek "speak"). The mark is the pill: a capsule with five bars in the silhouette of a spoken
  word (heights 0.42 · 0.82 · 0.58 · 1.0 · 0.5). Used as app icon, menu-bar icon and the live recording pill.
- Voice: plain, calm, short sentences, written from the user's side; no jargon on the main path.
- Owner-named references for the onboarding redesign: **Wispr Flow** and **Raycast**.

## Evidence on Hand

- Real measured numbers: on-device English ≈ 0.3–0.6 s from release to text (2026-10-17 tests); cloud cost
  about $0.005 per 40 s of speech.
- App screenshots: `docs/media/home.png`. Current onboarding is the incumbent implementation in
  `Sources/SoylaCore/App/OnboardingView.swift`.
- No user testimonials, user counts or press exist. Do not invent any.

## Product Principles

1. **First success before any decision.** A new user dictates once before being asked anything they can't
   answer.
2. **Ask what people know, not how it's built.** Languages, not engines; "type where your cursor is", not
   "Accessibility".
3. **Depth on request.** Technical truth is always one hover away and never in the way.
4. **Privacy is stated, not implied.** Say exactly where audio goes for each language.
5. **Get out of the way.** The window is a place you visit rarely; the key and the pill are the product.

## Accessibility & Inclusion

macOS basics: VoiceOver labels on every control, full keyboard navigation, readable contrast in light and dark,
respects Reduce Motion. Copy must work in three interface languages (Uzbek and Russian run 20–40 % longer than
English).
