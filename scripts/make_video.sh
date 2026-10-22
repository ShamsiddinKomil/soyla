#!/usr/bin/env bash
# The release video: captioned slides of the docs pictures plus the demo loop, silent, ~60 s, 1920×1080 H.264.
# Rendered off-screen like scripts/docs_shots.sh (nothing appears on screen). Run docs_shots.sh first so the pictures
# are current. Writes dist/media/soyla-demo.mp4 (dist/ is never committed; attach the file to the GitHub release).
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(swift build -c release 2>&1) || { echo "$out" | grep -A3 error: >&2; exit 1; }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"; defaults delete ai.soyla.docshots >/dev/null 2>&1 || true' EXIT
mkdir -p "$TMP/home"
SOYLA_HOME="$TMP/home" SOYLA_SETTINGS_SUITE=ai.soyla.docshots SOYLA_KEYCHAIN_SERVICE=ai.soyla.docshots \
  .build/release/soyla docs-shots "$TMP/slides" --video-slides docs/media
SOYLA_HOME="$TMP/home" SOYLA_SETTINGS_SUITE=ai.soyla.docshots SOYLA_KEYCHAIN_SERVICE=ai.soyla.docshots \
  .build/release/soyla docs-shots "$TMP/demo" --demo
mkdir -p dist/media
python3 -I scripts/video_concat.py "$TMP/slides" "$TMP/demo" dist/media/soyla-demo.mp4
ls -la dist/media/soyla-demo.mp4
