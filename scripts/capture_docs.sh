#!/usr/bin/env bash
# Re-takes the docs/media screenshots from a throwaway demo profile: fictional dictations (scripts/make_demo_data.py),
# separate settings (SOYLA_SETTINGS_SUITE), an empty Keychain slot (SOYLA_KEYCHAIN_SERVICE) and a fake key, in a
# developer build. Nothing of your own settings, keys or History can appear in a picture.
# Usage: scripts/capture_docs.sh [--keep]   (needs Screen Recording for the terminal; quit your own Soyla first)
# Afterwards: look at every picture before committing (git diff --stat docs/media; open docs/media).
set -euo pipefail
cd "$(dirname "$0")/.."
SUITE=ai.soyla.capture
running=$(pgrep -f "/Applications/Soyla.app/Contents/MacOS/soyla" || true)   # captured: no `| grep -q` under pipefail
[ -z "$running" ] || { echo "error: quit your Soyla first (its window would be captured instead)" >&2; exit 1; }

SOYLA_DEV=1 NO_INSTALL=1 scripts/bundle.sh | tail -1
DEMO=$(mktemp -d)
cleanup() {
  [ -n "${PID:-}" ] && kill "$PID" 2>/dev/null || true
  defaults delete "$SUITE" >/dev/null 2>&1 || true
  security delete-generic-password -s "$SUITE" >/dev/null 2>&1 || true
  rm -rf "$DEMO"
  echo "cleaned up the demo profile"
}
trap cleanup EXIT
python3 -I scripts/make_demo_data.py "$DEMO"

shoot() {  # shoot <out name> <appearance> <launch args...>
  local out=$1 look=$2; shift 2
  defaults delete "$SUITE" >/dev/null 2>&1 || true
  defaults write "$SUITE" settings.v1 -data 7b7d   # "{}": every default, setup marked done
  SOYLA_HOME="$DEMO" SOYLA_SETTINGS_SUITE=$SUITE SOYLA_KEYCHAIN_SERVICE=$SUITE \
    OPENROUTER_API_KEY=sk-or-v1-FAKE-demo-key-not-real \
    build/Soyla.app/Contents/MacOS/soyla --appearance "$look" "$@" >/dev/null 2>&1 &
  PID=$!
  sleep 3
  scripts/shot.sh Soyla Soyla "docs/media/$out.png" --wait 10
  kill "$PID" 2>/dev/null || true; wait "$PID" 2>/dev/null || true; PID=
  sleep 1
}

shoot home light --tab home
shoot home-dark dark --tab home
shoot history light --tab history
for p in permissions apiKeys dictation hotkey pill privacy about developer; do shoot "page-$p" light --page "$p"; done
echo "done: review every picture in docs/media before committing"
