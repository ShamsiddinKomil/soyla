#!/usr/bin/env bash
# One-time: private self-signed code-signing identity in a dedicated keychain (not trusted system-wide,
# not added to the login keychain search list). Gives Soyla a stable designated requirement so macOS
# Accessibility / Input Monitoring grants survive rebuilds, and the in-app updater pins this certificate.
# Run in Terminal.app: you choose the keychain password (keep it in a password manager; losing it means losing the
# signing key). The keychain locks after 1 hour and on sleep; scripts/bundle.sh asks for the password when needed.
set -euo pipefail
D="$HOME/.soyla-signing"; KC="$HOME/Library/Keychains/soyla.keychain-db"
[ -f "$KC" ] && { echo "already exists: $KC"; exit 0; }
[ -t 0 ] || { echo "error: run this in Terminal.app (it asks for a password)" >&2; exit 1; }
mkdir -p "$D"; chmod 700 "$D"; cd "$D"
read -rsp "New password for the signing keychain: " KCPW; echo
read -rsp "Same password again: " KCPW2; echo
[ -n "$KCPW" ] && [ "$KCPW" = "$KCPW2" ] || { echo "error: passwords empty or different" >&2; exit 1; }
printf '[req]\ndistinguished_name=dn\nprompt=no\nx509_extensions=ext\n[dn]\nCN=Soyla Dev Signing\n[ext]\nbasicConstraints=critical,CA:false\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=critical,codeSigning\n' > cert.cnf
openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem -days 3650 -config cert.cnf 2>/dev/null
P=$(openssl rand -hex 12)
openssl pkcs12 -export -inkey key.pem -in cert.pem -out soyla.p12 -passout "pass:$P" -legacy 2>/dev/null \
  || openssl pkcs12 -export -inkey key.pem -in cert.pem -out soyla.p12 -passout "pass:$P"
security create-keychain -p "$KCPW" soyla.keychain-db
security set-keychain-settings -l -u -t 3600 "$KC"   # lock on sleep and after 1 hour
security unlock-keychain -p "$KCPW" "$KC"
security import soyla.p12 -k "$KC" -P "$P" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KCPW" "$KC" >/dev/null
unset KCPW KCPW2
rm -f key.pem soyla.p12
security list-keychains -d user -s $(security list-keychains -d user | tr -d '"') "$KC"
echo "created identity 'Soyla Dev Signing' in $KC"
