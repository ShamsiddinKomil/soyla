#!/usr/bin/env bash
# Renders the docs pictures off-screen (`soyla docs-shots`): nothing appears on screen, nothing takes focus, nothing
# records the screen, so it can run while you work. Settings, History and the Keychain point at a throwaway demo
# profile (fictional dictations, a fake key, a Keychain name that holds nothing), removed on exit; your own Soyla,
# settings, keys and History are never read.
# Usage: scripts/docs_shots.sh [out dir (default docs/media)] [shot name…]
# Writes <name>@2x.png and a 1x <name>.png next to it. Look at every picture before committing.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=${1:-docs/media}; shift || true
SUITE=ai.soyla.docshots
out=$(swift build -c release 2>&1) || { echo "$out" | grep -A3 error: >&2; exit 1; }
BASE=$(mktemp -d)
DEMO="$BASE/Application Support/Soyla"   # Privacy & data shows the folder's last two names
cleanup() { defaults delete "$SUITE" >/dev/null 2>&1 || true; rm -rf "$BASE"; }
trap cleanup EXIT
python3 -I scripts/make_demo_data.py "$DEMO" >/dev/null
defaults delete "$SUITE" >/dev/null 2>&1 || true
# No saved settings: a fresh install's defaults (an empty blob would read as an older install's). The shots mark
# setup done themselves.
TMP=$(mktemp -d)
SOYLA_HOME="$DEMO" SOYLA_SETTINGS_SUITE=$SUITE SOYLA_KEYCHAIN_SERVICE=$SUITE \
  OPENROUTER_API_KEY=sk-or-v1-FAKE0000000000000000000000000000demo7f3a \
  .build/release/soyla docs-shots "$TMP" "$@"
# Second pass without the demo key: the "no key yet" shots (Home's Connect).
SOYLA_HOME="$DEMO" SOYLA_SETTINGS_SUITE=$SUITE SOYLA_KEYCHAIN_SERVICE=$SUITE \
  .build/release/soyla docs-shots "$TMP" "$@"
if [ "$#" -eq 0 ] || [[ " $* " == *" demo "* ]]; then   # the README loop: frames → GIF (≤ 1.5 MB, the gate checks)
  SOYLA_HOME="$DEMO" SOYLA_SETTINGS_SUITE=$SUITE SOYLA_KEYCHAIN_SERVICE=$SUITE \
    .build/release/soyla docs-shots "$TMP/demo" --demo
  ffmpeg -loglevel error -y -framerate 15 -i "$TMP/demo/frame-%04d.png" \
    -vf "scale=640:-1:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff:max_colors=128[p];[b][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle" \
    -loop 0 "$TMP/demo.gif"
fi
mkdir -p "$OUT"
[ ! -f "$TMP/demo.gif" ] || mv "$TMP/demo.gif" "$OUT/demo.gif"
for f in "$TMP"/*@2x.png; do
  [ -e "$f" ] || continue
  name=$(basename "$f" @2x.png)
  cp "$f" "$OUT/$name@2x.png"
  w=$(sips -g pixelWidth "$f" | awk '/pixelWidth/{print $2}')
  sips --resampleWidth $((w / 2)) "$f" --out "$OUT/$name.png" >/dev/null
done
rm -rf "$TMP"
echo "wrote $(ls "$OUT" | wc -l | tr -d ' ') files in $OUT"
