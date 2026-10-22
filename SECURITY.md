# Security policy

## Where your data goes

- **API keys never leave your Mac** except in the request headers sent to the provider you chose. They live in one
  macOS Keychain item that does not sync to other devices, and are never logged, written to `runs.jsonl` or cached.
- **With the free engine ("On this Mac", English only), audio never leaves the Mac.** Apple's on-device recognizer
  does the work; the only network use is Apple possibly downloading its English model once.
- **With Cloud, audio** is sent only to the speech-to-text provider you configured (OpenRouter, Google AI Studio, or your own
  OpenAI-compatible server), plus Google's Live service while the optional Live preview is on. Recordings stay on
  your Mac and are deleted after the retention period you pick.
- Soyla has no accounts, no telemetry and no analytics.
- Free-tier Google AI Studio keys let Google use your audio to improve its products. Use a paid key for anything
  confidential.

What Soyla can access on your Mac, why, every host it contacts and how updates are verified:
[docs/SECURITY_MODEL.md](docs/SECURITY_MODEL.md).

## Reporting a vulnerability

Please do not open a public issue for a security problem. Use GitHub's **Report a vulnerability** button
(Security tab of this repository) for a private report. If that is unavailable, open an issue titled "security
contact request" without details and the maintainer will reach out.

Expect a first reply within a week. Fixes for real vulnerabilities are released as a patch version and noted in
[CHANGELOG.md](CHANGELOG.md).

## Supported versions

Only the latest release is supported.
