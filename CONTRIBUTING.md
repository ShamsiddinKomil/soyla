# Contributing to Soyla

Thanks for helping. Soyla is a small macOS menu-bar dictation app (Uzbek / Russian / English) written in Swift
with no third-party packages. Design background: [docs/HOW_IT_WORKS.md](docs/HOW_IT_WORKS.md).


## Build and test (Command Line Tools are enough)

```
swift build -c release
scripts/test.sh                      # swift-testing; plain `swift test` does not find it under CLT
python3 -I Tests/test_report.py      # report-script tests
NO_INSTALL=1 scripts/bundle.sh       # build/Soyla.app without installing to /Applications
```

Format and lint (Homebrew: `brew install swiftformat swiftlint`):

```
swiftformat --lint .                 # check; `swiftformat .` to fix
scripts/lint.sh                      # swiftlint against .swiftlint.baseline (sets TOOLCHAIN_DIR under CLT)
git config core.hooksPath scripts/git-hooks   # one-time: pre-commit runs format check, lint and tests
```

`scripts/test.sh` works under Command Line Tools and under a full Xcode. XCTest is not used; tests use
`import Testing`.

## Rules

- UI follows `docs/DESIGN.md` (tokens `Ink.*`, components in `Sources/SoylaCore/App/DesignKit.swift`): no new colours, fonts or radii outside it; spoken text in the serif; one accent.

- **No new dependencies.** SwiftPM stays at zero packages. Dev scripts and tooling may use `ffmpeg`, `gh`, `python3`, `swiftformat` and `swiftlint` (Homebrew dev tools, not dependencies).
- **Never log dictated text.** `app.log` gets timings and error classes only. Transcripts live in `runs.jsonl` and History.
- **Never commit secrets.** `.env.local` is gitignored. Tests use obviously fake keys (for example `FAKE1234`) and
  obviously fake text; never real personal data.
- **Ideas from GPL apps** (VoiceInk, Handy) are welcome as patterns and numbers, never pasted code. Soyla is MIT.
- Keep changes small and focused. Run the tests before opening a PR.
- Two files carry hard-won fixes for macOS edge cases (Bluetooth inputs, device switches, sleep, event-tap timeouts): `Sources/SoylaCore/Audio/Recorder.swift`
  and `Sources/SoylaCore/Hotkey/HotkeyMonitor.swift`. Ask in an issue before changing them.
- Found a surprise (an API that behaves differently than documented, a macOS quirk)? Say so in the PR description.

## Adding a provider

1. Implement `TranscriptionProvider` (see `Sources/SoylaCore/Providers/TranscriptionProvider.swift` and
   [docs/HOW_IT_WORKS.md](docs/HOW_IT_WORKS.md)): take an `EncodedAudio`, return a `TranscriptResult`,
   and fill the `RunTimeline` marks you can measure.
2. Never put keys in logs, errors or cache. Use an ephemeral `URLSession` for any session carrying a secret.
3. Register the provider where the model list is built, add a settings entry, and add tests in
   `Tests/SoylaCoreTests/` with a stubbed network (no real calls, no real keys).
4. Measure it with the harness ([docs/HARNESS.md](docs/HARNESS.md)) on Uzbek and mixed-language clips and put the
   numbers in the PR.

## Releasing (maintainer)

1. Bump `Soyla.version` in `Sources/SoylaCore/Settings/Settings.swift`, date the `## [X.Y.Z]` section in `CHANGELOG.md`.
2. `scripts/prelaunch_check.sh vX.Y.Z` must print "all checks passed": no key-shaped strings or home paths, private
   folders untracked, privacy defaults, media sizes, links. The release workflow runs it again before building.
3. On the maintainer's Mac, `scripts/release.sh vX.Y.Z` builds with the stable signing identity (the in-app updater
   only accepts that signature, and the certificate never leaves the Mac), zips, writes the `.sha256` and publishes
   the release with notes from the CHANGELOG section. `DRY_RUN=1` stops before publishing. The Release workflow on
   the tag only re-runs the checks and proves the tag builds.
4. First public launch only: `scripts/github_setup.sh` (dry run) then `--apply` creates the repo, topics, labels,
   Discussions, private vulnerability reporting and Pages. Upload `docs/media/social-preview.png` by hand
   (Settings → General → Social preview); `swift scripts/make_social.swift` regenerates it.
5. Release rules: at most one release a week unless it is a hotfix; never reset a user's settings (new fields get
   defaults, saved choices are kept); every release note links the previous version's zip (`scripts/release.sh` adds
   the line from `gh release list`). Going back is documented in `docs/TROUBLESHOOTING.md`.

**Commit email.** Commits are public. To keep a personal address out of them, set
`git config user.email <id>+<user>@users.noreply.github.com` (GitHub → Settings → Emails). Existing history can only
be rewritten before the first push.

The landing page is `site/index.html` (no build step, no scripts); `.github/workflows/pages.yml` publishes it with
the pictures it uses from `docs/media/`.

## Reporting bugs

Use the bug template. Paste problems are the most common issue in any dictation app, so please include the target
app, keyboard layout and hotkey. Easiest: in Soyla choose **Report a Problem…** (menu bar icon or Help menu). It shows
a diagnostic block you can edit, then Copy or **Open GitHub issue**, which opens the browser with the form filled in.
You submit it yourself; it never contains dictated text, audio or keys.
