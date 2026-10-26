# Soyla design code

The rules every screen follows, so the app looks like one hand drew it. The code lives in
`Sources/SoylaCore/App/DesignKit.swift` (tokens as `Ink.*`, components below). Written 2026-10-16 after a
pass with two design skills (Anthropic's `frontend-design`, Dammyjay93's `interface-design`); the format is
the second skill's `system.md`.

## Who, what, feel

- **Who:** someone in Tashkent who thinks in three languages, between a Telegram thread and a document.
  They open the window rarely: to confirm Soyla is ready, to fix one thing, to find a sentence from yesterday.
- **Verb:** make sure it works, then get out of the way. The product is the held key and the pill.
- **Feel:** a voice turning into ink. Calm, exact, a little warm in the words, cool in the surfaces.
  Not a dashboard, not a landing page. A good pen.

## The world the colours come from

Registan tile lapis, the blue-black of ink, the cool grey of paper under daylight, a red recording lamp.
One hue (blue) across every surface, shifting only in lightness; colour appears only when it means something.

## Signature (five places to point at)

1. **Speech is a note, not a label.** Every sentence the user said (Last dictation, History, the sample
   sentence) sits on its own card (`NoteCard`): a meta line (when · app · length), then the text in the system face
   at 15 pt with open leading, selectable. The card keeps what you said apart from the controls around it.
2. **The key is a key.** `FnKeyCap` draws the real Apple key (globe, "fn", 4 pt of travel); the large one on Home
   sinks while the hotkey is held. Same cap in the Hotkey page and the Setup Assistant; `KeyChip` names a key inline.
3. **One mark everywhere.** The brand is the pill: a capsule with five bars in the silhouette of a spoken word
   (heights 0.42 · 0.82 · 0.58 · 1.0 · 0.5, asymmetric on purpose: a voice, not an equaliser). It is drawn from
   one geometry (`Brand` in DesignKit.swift, mirrored in `scripts/make_icon.swift`) as the app icon (white
   capsule, lapis bars, on a lapis tile), the menu-bar icon (template capsule with the bars knocked out; red
   while recording), the sidebar lockup with the wordmark, the Welcome screen, and the live pill itself (black
   capsule, the same five bars moving with your voice).
4. **Status is a dot and a word**, never a coloured box: `● Ready`, `● Needs an API key`.
5. **Tokens named after the world:** `paper`, `sheet`, `well`, `ink`, `lazur`, `signal`.

## Tokens

### Colour (light / dark)

| Token | Light | Dark | Use |
|---|---|---|---|
| `paper` | #F6F7F9 | #15181D | window canvas, sidebar too |
| `sheet` | #FFFFFF | #1C2027 | groups, cards |
| `well` | #EEF0F3 | #11141A | text fields, the try box (inset = darker) |
| `raised` | #FFFFFF | #262B34 | key caps, popovers |
| `hairline` | black 8 % | white 9 % | row dividers, group borders |
| `hairlineStrong` | black 14 % | white 16 % | key-cap edges, focus |
| `ink` | #1A2230 | #E8EBF0 | text, four steps: 100 / 62 / 45 / 30 % |
| `lazur` | #2A5BD7 | #7A9BFF | the one accent: selection, links, primary button, pressed key |
| `signal` | #E0443E | #FF6B66 | recording dot and bars, errors |
| `ok` / `warn` | #2B9A5B / #C98A0A | #5FCB8A / #F0B33E | status dots, nothing else |

Depth: surface steps and hairlines only. No shadows inside windows (the pill keeps its window shadow;
the key cap's 2 pt bottom edge is drawn, not blurred).

### Spacing

Base 4. Scale 4 · 8 · 12 · 16 · 24 · 32 · 40. Inside a row 12/16, between rows 0 (hairline), between
groups 24, page margins 32, sidebar width 200.

### Radius

6 controls and key caps · 10 groups and cards · 14 sheets · capsule for the pill and status dots.

### Type

San Francisco for the interface and for spoken text (no serif: New York read poorly in mixed Latin/Cyrillic,
2026-10-16), SF Rounded only for numbers and key caps.

| Role | Size / weight | Where |
|---|---|---|
| caption | 11 / 400 | captions under rows, timestamps |
| body | 13 / 400 | everything |
| subhead | 13 / 600 | group titles, row labels that lead |
| title | 17 / 600 | Home hero line, step titles |
| page | 22 / 600, tracking −0.4 | page headers |
| stat | 28 / 600 rounded, tabular | Today numbers |
| spoken | 15 system, line spacing 5 | what the user said |
| key | 12 / 600 rounded (hero 26) | key caps |

Hierarchy comes from weight and the four ink steps, not from size.

## Components

- `FnKeyCap(label, size: .medium | .large)`, `KeyChip(label)`
- `PillChip(text, label)` the tiny language-set label in caption type on the black pill while recording ("RU", "UZ·EN"); hidden for the default set
- `Mark(level:mode:)` the waveform as a static or live mark
- `StatusLine(colour, text)` dot + word
- `SpokenText(text)` system 15, selectable
- `NoteCard(meta:status:text:actions:)` one dictation as a saved note (Home, History). Optional `badge` (a small `lazurWash` tag after the meta line, "Cleaned"), `styled` (the text with a word diff: removed words struck through in `text3`, added or changed words on `lazurWash`) and `note` (a quiet caption line under the text)
- `SettingsGroup(title?) { Row(...) }` sheet surface, hairline rows; `Row(label, caption?) { control }`
- `Callout(kind: .warn | .info, text, action)` the only coloured box, for "needs an API key" and warnings
- `Hairline()`

## Copy

Sentence case. Verbs on buttons, and a button keeps its name through the flow (Save → "Saved"). Errors say
what happened and what to do, never sorry. No all-caps labels, no eyebrow labels, no "→" in button text.

## Motion

Only in answer to the user: the key sinking, a group expanding, the pill appearing. Under 300 ms, ease-out.
Reduce Motion turns movement off and keeps fades.

The pill's bars are the one continuous motion. Each bar eases towards `level × its silhouette height` at 60 fps
(attack 45 ms, release 160 ms, outer bars up to 35 % slower), so speech reads as one shape moving, never a
jitter. While transcribing, a slow swell (about 2.9 s) travels left to right. `--pill-demo` drives it without
a hotkey press for recordings.

## First-run setup (onboarding v2, 2026-10-17)

The setup window is the one place the Registan world is used at full strength: **a lapis tile with the pill
living on it**.

- **Shape.** A fixed window 1056 pt wide, hidden title bar (the traffic lights sit on the lapis). Left: the
  **stage**, 376 pt of lapis, which acts out the step (the fn key sinking and the black pill recording on
  Languages, a preview of the next macOS surface on Permissions, the route "This Mac → provider" on Connect, the
  live pill on Try, the menu-bar callout on Done) above the step rail. Right: the **pane**, one question per
  step. Height follows the step (Languages 616, Permissions 616, Connect 640, Try 640, Done 616); the pane swaps
  at once and the window height animates 0.25 s, none under Reduce Motion.
- **Welcome (v6, owner-approved 2026-10-17).** A brand moment before Languages, on every run (first launch and
  Setup Assistant). The full window is lapis (1056 × 616) with a static radial lift (white 7 % at the centre, gone
  by 70 %); no rail, no stage split. The white pill mark 208 × 96 with lapis bars at the brand heights; "Soyla" at
  62 pt semibold, tracking −0.03 em, 32 pt below it; the line ("You speak. Soyla types.") at 19.5 pt, 80 % white,
  16 pt lower. A white Start button (44 tall, min 208 wide, radius 12, 16.5 pt semibold lapis-deep) sits 64 pt above
  the bottom with "About 2 minutes" (14 pt, 68 % white) under it; Return = Start. The globe menu stays top-right,
  light on lapis. Motion: the entrance plays once per arrival (on first show and on Back, never on a language
  switch): mark fade + scale 0.96 → 1 over 640 ms, the wordmark rises 8 pt over 560 ms from 120 ms, the line from
  240 ms, the button group from 420 ms, all on (.16, 1, .3, 1). The only loop is the pill's 2.9 s "working" swell:
  each bar's scaleY 1 → 0.62 → 1 on (.45, 0, .55, 1), from 700 ms, staggered 160 ms left to right. Reduce Motion:
  static, bars at their brand heights, no entrance. The v6 numbers are already drawn at the SetupScale window.
- **One question per pane.** Title, one short line, controls with a 2–4 word caption each, one status line,
  buttons (primary bottom-right). Detail lives in the ⓘ popover. Stage text is at most two short lines. While a
  real macOS surface is open, the stage shows only the sentence that names the control ("Click **Allow**.").
- **Scale (owner 2026-10-17: "a bit larger").** v5 was drawn at 960 wide. Every setup dimension now goes through
  one ratio, `SetupScale.ratio` = 1.1: lengths snapped to the 4 pt grid (`SetupScale.pt`; insets under 8 pt stay
  as drawn), type snapped to 0.5 pt (`SetupScale.type`). Why 1.1: the smallest common target is a 13" MacBook Air at
  its default resolution, about 1470 × 920 pt visible after the menu bar and Dock. 1056 × 640 leaves ~207 pt on
  each side and ~140 pt above and below, so the window reads as a dialog, not a full-screen page. It sits inside the
  suggested 1040–1100 × 620–660 range; 1.15 (1104 × 668) would also fit, but the owner asked for "a bit" larger, and
  1.1 keeps most v5 spacings on whole grid steps. Not yet checked on a real 13" screen. Line breaks are kept: the pane's text column grows
  1.09× and the type 1.10×, so EN/UZ/RU wrap where the reviewed v5 build wrapped, and the window still grows past
  the step height if a pane's measured content needs it. Native controls (buttons, checkboxes, fields) keep the
  system's large control size; they are not scaled.

  | Element | v5 | Now |
  |---|---|---|
  | Window | 960 × 560 / 580 | 1056 × 616 / 640 |
  | Stage width · padding | 340 · 28 / 24 | 376 · 32 / 28 |
  | Pane padding (top · sides · bottom) | 72 · 64 · 32 | 80 · 72 · 36 |
  | Title · subtitle | 28 / 600 · 14 | 31 / 600 · 15.5 |
  | Row height · label · caption · status | 54 · 14 / 500 · 12.5 · 12.5 | 60 · 15.5 / 500 · 14 · 14 |
  | Title → body gap · row gaps | 32 · 16 | 36 · 16 |
  | Practice sentence · field | 22 / 500 · 15 in a 64 pt box | 24 / 500 · 16.5 in a 72 pt box |
  | Stage text · rail | 14 · 12.5 | 15.5 · 14 |
  | fn key large · medium | 120 × 110 · 88 × 82 | 132 × 120 · 96 × 92 |
  | Demo field · demo pill · Try pill | 260 × 84 · 92 · 100 | 288 × 92 · 100 · 112 |
  | Stage previews · route · stage line | 250 · 240 · 250 | 276 · 264 · 276 |
  | Helper note | 230 wide, title 13, body 12 | 252 wide, title 14.5, body 13 |

- **The fn key** is drawn as the real Apple key (globe bottom-left, "fn" top-right, 4 pt travel), 96–132 pt.
  No emoji globe anywhere.
- **Interface language**: a borderless globe menu at the pane's top-right (English, O‘zbekcha, Русский).

| Token | Light | Dark | Role |
|---|---|---|---|
| `lapis` | #1D3C97 | #172F7A | the stage |
| `lapisDeep` | #152D78 | #0F2160 | the System Settings helper panel |
| `onLapis` / `2` / `3` | white 100 / 80 / 68 % | same | text on the stage |
| `firuza` | #5FD3DF | #6EE0EA | **"you are here / act here" only**: current rail step, the control ring in a stage preview |
| `okOnLapis` | #86E3AD | same | "it worked" on the stage |
| `ok` | (existing) | | "it worked" in the pane: granted, connected, ready |
| `warn` (saffron) | (existing) | | "needs one more step" |
| `pill` | #0E0F12 | #000000 | the live pill, black from recording through the success bounce |

Rules: turquoise never means success; green never means "you are here". The pane keeps `paper`/`sheet`/`ink`
and the one `lazur` accent for the primary button and checked controls.

## Main window (APP-1 (a), 2026-10-17)

Setup's world continued, so Done hands over to Home without a seam. Spec: the approved design prototype (v2).

- **Shape.** 1056 × 688 (min 1056 × 600; owner 2026-10-18: 768 felt too tall), hidden transparent title bar, frame saved as `SoylaMainWindow3`. Left: a
  264 pt **lapis sidebar** (`Ink.appSidebarWidth`) with the traffic lights on it, the white mark (40 wide) and a
  19.5 pt wordmark, then three groups: Home, History · Languages, Permissions, Dictation, Hotkey, Pill, Privacy &
  data · About, Developer, split by `lapisLine` rules. Rows 36 tall, radius 8, 14 pt; selected = white 12 % wash,
  firuza icon, white semibold label; others `onLapis2`, hover white 7 %. A saffron dot marks where a fix lives
  (Languages while a key is needed, Permissions while one is missing). Foot: "Setup Assistant…" and the version, 13 pt.
- **Pane.** `paper`, padding 56 top · 72 sides · 24 bottom, the globe menu (interface language, live) top-right.
- **Type** (`Ink.Font.app*`, the SetupScale sizes): title 31/600, subtitle 15.5, section 15.5/600, row label
  15.5/500, caption and status 14, try field and last dictation 16.5, sidebar 14, footer 13. Rows 60 (`Ink.appRow`).
- **Home.** Title + one line from `HomeState`; the hero is `FnKeyCap` medium (D23: so the everyday Home fits 1056 × 688;
  Done keeps the large one) beside a 72 pt try field and the hints "fn ×2 · Hands-free · esc Cancel" (`KeyChip`); with the mic or Accessibility off a
  Permissions group replaces it. "Your languages": Change… plus the one fix (Connect… / Use Cloud), status only on the
  rows. "Last dictation": today's count and usual wait, All in History, a note card capped at two lines. It renders
  unscrolled whenever it fits (`ViewThatFits`), a scroll view only below the window height. Section gaps 24 · 18 · 16
  (hero, Your languages, Last dictation). The key notice (one-time Keychain move, or an unreadable key file) shows only while a
  cloud key is in use and the launch key read is not ready.
- **Re-entry.** Every Connect…, Change… and Allow… opens the setup window at that step (`SetupFlow(entry:)`): no
  Welcome, no Back, a rail step ticked only when it really happened (permissions granted, a practice made; the rest
  show skipped), every primary says Done (Connect's skip is Cancel). Done returns to the page it came from. Whether
  Soyla is ready comes from one `Readiness` value on every surface (audit 2026-10-19).
- **`InfoButton`** (DesignKit): ⓘ that opens a native popover of short paragraphs, at most 320 wide in the app.
- **Languages page (b)** (was Engine; `SettingsPage.languages` = `.apiKeys`). Title with ⓘ (three paragraphs), Your
  languages (the header fix only once a key is on file), Engine radio (Cloud / On this Mac) once a key exists, Cloud
  group (service radios, API key row: Connect… filled when none, else ● status + a Replace… split button whose arrow
  holds Remove key, Model popup while Cloud is the engine), "On this Mac" (English speech model, its EngineCopy status).
  Keys are added and replaced only through setup's Connect step. `RadioRow` (DesignKit) draws the choices. The page
  scrolls when Cloud is shown (taller than the window); only Home must fit.
- **Other pages (c).** `AppPage` / `AppSection` / `AppRow` (App/AppPage.swift): title (+ ⓘ), one subtitle line of at
  most 6 words (Privacy keeps the prototype's own line), sections with at most one status on the right, 60 pt rows
  whose caption is 2–4 words and whose longer text sits in a small ⓘ beside the label. Secondary buttons are neutral
  bordered (`.tint(nil)` on the page); only the primary is filled lazur; switches and pickers keep lazur. Privacy is
  the prototype `privacy` render (data folder "Application Support › Soyla", full path as tooltip). Permissions uses
  setup's rows and words; each Allow… opens setup at Permissions. The hotkey picker says "fn", never "fn (🌐)".
- **Pill cards (c).** Titles and hints are shown in the interface language (`PillFailure.localized`); a card's second
  button names its fix (Connect… / Allow… / Open Privacy & data) and routes into setup (`PillFix`).
- **Inline Connect (v3, owner 2026-10-18; prototype-v3 `langRow`/`cxPanel`).** Each cloud-language row that needs
  a key carries "● Needs an API key" and its own Connect… (filled only on the first missing row, and on Home only while
  the mic is allowed); a key on file with "On this Mac" on shows "● Off" + Use Cloud. The group header keeps only
  Change…. Connect… opens a panel under its row (`InlineConnectPanel`: well, radius 10, padding 16, 16 from the group
  edge): two service tiles (radio), "1 Create an API key [Open …]", "2 [Paste the API key] [Connect]" (filled only once
  the key is long enough; Return submits, Esc/Cancel close and refocus the row button), the result line, the lock line
  ("Audio goes straight to …", "One key covers Uzbek and Russian." when both are chosen) and Cancel. One panel at a
  time; it scrolls into view. The check is setup's (save → verify); success applies setup's engine rule. On the
  Languages page the Cloud section appears only once a key exists, and Replace… opens the same panel under the API
  key row. The menu's Connect X…, the pill's Connect… and `openConnect(for:)` land on the Languages page with the
  first missing language's panel open; setup's Connect step stays for the onboarding run.
- **Menu bar (b).** A two-line header from `MenuHeader` (● + title, then the quieter line), Secure Input / hotkey /
  model lines when they apply, the one fix (Allow the Microphone…, Connect X…, Use Cloud), then Open Soyla · Paste/Copy
  Last Dictation · Settings… · Setup Assistant… · Report a Problem… · Quit. All words from `AppStrings`; the main menu
  too, rebuilt when the interface language changes.

## What it looks like

![Home in light and dark](media/home.png)

Stills: `media/home.png`, `media/home-dark.png`, `media/page-*.png`, `media/setup-*.png`, `media/history.png`.

## Decisions

| Decision | Why | Date |
|---|---|---|
| Own sidebar instead of `NavigationSplitView` | same canvas as the content, no vibrancy, no second colour world | 2026-10-16 |
| ~~Serif for spoken text~~ → note cards in the system face | the serif read poorly in mixed Latin/Cyrillic; the card, not the typeface, now sets speech apart | 2026-10-16 |
| Cool paper, not cream | cream + serif + clay is the current generated-page cliché; our blue comes from the city | 2026-10-16 |
| Rainbow page icons removed | eight tints fought the one accent; the sidebar is a list, the page header carries the purpose | 2026-10-16 |
| Pill stays black | it sits over other apps; black with white bars reads on any wallpaper | 2026-10-16 |
