#!/usr/bin/env bash
# Usage: scripts/release.sh vX.Y.Z[-suffix]   (DRY_RUN=1 skips the git checks and `gh release create`)
# Builds the app signed with the stable identity, zips it, writes a .sha256, extracts CHANGELOG notes, publishes.
# Run it in a checkout of the public repository, on the tagged commit: the release must be traceable to public source.
set -euo pipefail
cd "$(dirname "$0")/.."
TAG=${1:?usage: scripts/release.sh <tag, e.g. v0.2.0>}
VER=${TAG#v}
OUT=dist; mkdir -p "$OUT"
ZIP="$OUT/Soyla-$TAG.zip"; NOTES="$OUT/notes-$TAG.md"

unset SOYLA_DEV   # never ship the developer switches (DevOverrides)
if [ "${DRY_RUN:-}" != "1" ]; then
  [ -z "$(git status --porcelain)" ] || { echo "error: uncommitted changes; a release must be built from a clean tree" >&2; exit 1; }
  [ "$(git rev-parse HEAD)" = "$(git rev-parse "$TAG^{commit}" 2>/dev/null)" ] || { echo "error: HEAD is not $TAG (git tag $TAG && git push origin $TAG)" >&2; exit 1; }
  git ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null || { echo "error: $TAG is not pushed (git push origin $TAG)" >&2; exit 1; }
fi

# The app reports Soyla.version (Settings.swift) to the update check; it must match the tag's base version.
SRC_VER=$(sed -n 's/.*public static let version = "\([^"]*\)".*/\1/p' Sources/SoylaCore/Settings/Settings.swift)
if [ "$SRC_VER" != "${VER%%-*}" ]; then
  echo "error: Soyla.version in Sources/SoylaCore/Settings/Settings.swift is \"$SRC_VER\" but tag $TAG needs \"${VER%%-*}\"; bump it first." >&2
  exit 1
fi

# Signed with the stable self-made identity ("Soyla Dev Signing", scripts/make_signing_identity.sh): the in-app
# updater installs a download only if it carries the SAME certificate as the running app, and macOS keeps
# Accessibility / Input Monitoring across updates. So releases are built on the owner's Mac, never ad-hoc in CI.
NO_INSTALL=1 VERSION="$VER" scripts/bundle.sh
dr=$(codesign -dr - build/Soyla.app 2>&1)   # captured: `| grep -q` would SIGPIPE codesign under pipefail
case "$dr" in *"certificate leaf"*) ;; *)
  echo "error: build/Soyla.app is ad-hoc signed; run scripts/make_signing_identity.sh (or restore its backup) first." >&2; exit 1;; esac
certs=$(mktemp -d); codesign -d --extract-certificates="$certs/c" build/Soyla.app 2>/dev/null
FPR=$(shasum -a 256 "$certs/c0" | cut -d' ' -f1); rm -rf "$certs"
rm -f "$ZIP" "$ZIP.sha256"
ditto -c -k --keepParent build/Soyla.app "$ZIP"
(cd "$OUT" && shasum -a 256 "Soyla-$TAG.zip" > "Soyla-$TAG.zip.sha256")

# Notes: the "## [X.Y.Z]" section (base version, suffix stripped); fall back to "## [Unreleased]".
BASE=${VER%%-*}
extract() { awk -v h="## [$1]" 'index($0,h)==1{f=1;next} /^## [[]/{f=0} f' CHANGELOG.md; }
extract "$BASE" > "$NOTES"
[ -s "$NOTES" ] || extract "Unreleased" > "$NOTES"
[ -s "$NOTES" ] || echo "Release $TAG" > "$NOTES"
cat >> "$NOTES" <<EON

---
Built from commit \`$(git rev-parse HEAD)\`. Signing certificate SHA-256: \`$FPR\`
([how to check a download](https://github.com/ShamsiddinKomil/soyla/blob/main/docs/INSTALL.md#1-download-and-install)).
EON

# Every release note links the previous version's zip, so anyone can go back (docs/TROUBLESHOOTING.md).
REPO_SLUG="ShamsiddinKomil/soyla"
PREV=$(gh release list --limit 20 --json tagName -q '.[].tagName' 2>/dev/null | grep -vx "$TAG" | head -1 || true)
if [ -n "$PREV" ]; then
  printf '\n---\nPrevious version: [Soyla-%s.zip](https://github.com/%s/releases/download/%s/Soyla-%s.zip). To go back, see [Troubleshooting](https://github.com/%s/blob/main/docs/TROUBLESHOOTING.md#go-back-to-an-earlier-version).\n' \
    "$PREV" "$REPO_SLUG" "$PREV" "$PREV" "$REPO_SLUG" >> "$NOTES"
fi

echo "zip:    $ZIP ($(du -k "$ZIP" | cut -f1) KB)"
cat "$ZIP.sha256"
if [ "${DRY_RUN:-}" = "1" ]; then echo "DRY_RUN=1: skipping gh release create (notes: $NOTES)"; exit 0; fi
PRE=(); case "$VER" in *-*) PRE=(--prerelease);; esac
gh release create "$TAG" "$ZIP" "$ZIP.sha256" --verify-tag --title "Soyla $VER" --notes-file "$NOTES" ${PRE[@]+"${PRE[@]}"}
