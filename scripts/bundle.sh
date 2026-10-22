#!/usr/bin/env bash
# Build the release binary with SwiftPM (CLT only), assemble build/Soyla.app and sign it with hardened runtime:
# the stable "Soyla Dev Signing" identity when present (permissions survive rebuilds), ad-hoc otherwise.
# SOYLA_DEV=1 compiles in the developer switches (DevOverrides: env keys, SOYLA_HOME, ...) for captures and update
# tests; normal and release builds leave them out.
set -euo pipefail
cd "$(dirname "$0")/.."
# VERSION env overrides (CI passes the tag); default = Soyla.version from Settings.swift.
VERSION=${VERSION:-$(grep -o 'version = "[^"]*"' Sources/SoylaCore/Settings/Settings.swift | head -1 | cut -d'"' -f2)}
BUILD=$(date +%Y%m%d%H%M)
# VARIANT=dev builds a side-by-side "Soyla Dev" (own bundle id, settings suite and Keychain service; see
# Soyla.storageNames). It never installs into /Applications and never quits the real app.
if [ "${VARIANT:-}" = "dev" ]; then
  APP_NAME="Soyla Dev"; BUNDLE_ID=ai.soyla.dev; NO_INSTALL=1
elif [ -z "${VARIANT:-}" ]; then
  APP_NAME=Soyla; BUNDLE_ID=ai.soyla.app
else
  echo "unknown VARIANT '$VARIANT' (only 'dev')"; exit 1
fi
DEVFLAG=(); [ "${SOYLA_DEV:-}" = "1" ] && DEVFLAG=(-Xswiftc -DSOYLA_DEV_OVERRIDES) && echo "DEV build: developer switches ON (never ship this)"
swift build -c release ${DEVFLAG[@]+"${DEVFLAG[@]}"} 2>&1 | tail -2
APP="build/$APP_NAME.app"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/soyla "$APP/Contents/MacOS/soyla"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" \
    -e "s|<string>ai.soyla.app</string>|<string>$BUNDLE_ID</string>|" \
    -e "s|<key>CFBundleName</key><string>Soyla</string>|<key>CFBundleName</key><string>$APP_NAME</string>|" \
    -e "s|<key>CFBundleDisplayName</key><string>Soyla</string>|<key>CFBundleDisplayName</key><string>$APP_NAME</string>|" \
    Resources/Info.plist.template > "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/" || true
[ -d Resources/Sounds ] && cp -R Resources/Sounds "$APP/Contents/Resources/" || true
[ -f Resources/onboarding-fn.png ] && cp Resources/onboarding-fn.png "$APP/Contents/Resources/" || true
# Stable signing identity (scripts/make_signing_identity.sh) → macOS permissions survive rebuilds, and the in-app
# updater only accepts builds with this certificate. Its keychain locks after 1 hour and on sleep; this script never
# shows a password dialog: a locked keychain is unlocked in the terminal, or (unattended) the build stops / goes ad-hoc.
KC="$HOME/Library/Keychains/soyla.keychain-db"
PASSF="$HOME/.soyla-signing/kc.pass"   # legacy plaintext password; scripts/secure_signing_keychain.sh removes it
SIGNER=adhoc
# SOYLA_ADHOC=1 forces ad-hoc signing (CI build checks must not depend on a local identity).
if [ "${SOYLA_ADHOC:-}" != "1" ] && [ -f "$KC" ]; then
  state=$(swift scripts/keychain_status.swift "$KC" 2>/dev/null || true)
  if [ "$state" = locked ] && [ -f "$PASSF" ]; then
    echo "WARNING: unlocking with the plaintext password file; run scripts/secure_signing_keychain.sh once in Terminal"
    security unlock-keychain -p "$(cat "$PASSF")" "$KC"; state=unlocked
  fi
  if [ "$state" = locked ] && [ -t 0 ]; then
    echo "The Soyla signing keychain is locked. Type its password (it stays unlocked for 1 hour):"
    security unlock-keychain "$KC" && state=unlocked
  fi
  if [ "$state" = unlocked ]; then
    SIGNER=stable
  elif [ "${NO_INSTALL:-}" != "1" ]; then
    echo "ERROR: the signing keychain is locked and there is no terminal to ask for its password." >&2
    echo "       Run in Terminal: security unlock-keychain $KC   (then build again)" >&2
    exit 1
  else
    echo "NOTE: signing keychain locked, no terminal: ad-hoc build for checks only (not for installing or releasing)"
  fi
fi
if [ "$SIGNER" = stable ]; then
  # codesign only finds identities in the user keychain search list.
  kcs=$(security list-keychains -d user)
  case "$kcs" in *soyla.keychain*) ;; *) security list-keychains -d user -s $(echo "$kcs" | tr -d '"') "$KC";; esac
  codesign --force --options runtime --entitlements Resources/Soyla.entitlements --sign "Soyla Dev Signing" --identifier "$BUNDLE_ID" "$APP"   # fails loudly (set -e)
  dr=$(codesign -dr - "$APP" 2>&1)
  case "$dr" in *"certificate leaf"*) ;; *) echo "ERROR: designated requirement is not cert-based"; exit 1;; esac
  echo "signed with stable identity 'Soyla Dev Signing' — permissions persist across rebuilds"
else
  codesign --force --options runtime --entitlements Resources/Soyla.entitlements --sign - --identifier "$BUNDLE_ID" "$APP"   # fails loudly
  echo "WARNING: ad-hoc signed — re-grant Accessibility/Input Monitoring after every rebuild"
  echo "         (run scripts/make_signing_identity.sh once to fix)"
fi
sig=$(codesign -dv "$APP" 2>&1)   # captured first: `| grep -q` would SIGPIPE codesign under pipefail
case "$sig" in *"(runtime)"*) ;; *) echo "ERROR: hardened runtime missing"; exit 1;; esac
echo "built $APP (v$VERSION build $BUILD)"
# Install into /Applications so Soyla shows up in Launchpad, Spotlight and Finder like any other app.
DEST=/Applications/Soyla.app
if [ "${NO_INSTALL:-}" != "1" ]; then
  osascript -e 'tell application id "ai.soyla.app" to quit' >/dev/null 2>&1 || true
  pkill -f "$DEST/Contents/MacOS/soyla" 2>/dev/null || true
  rm -rf "$DEST" && ditto "$APP" "$DEST"
  codesign --verify "$DEST" && echo "installed $DEST"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST" >/dev/null 2>&1 || true
  echo "run:  open -a Soyla"
else
  echo "run:  open \"$APP\""
fi
