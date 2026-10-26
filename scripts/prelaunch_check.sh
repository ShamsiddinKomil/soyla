#!/usr/bin/env bash
# Usage: scripts/prelaunch_check.sh [vX.Y.Z]
# The automatable half of the release checklist. Read-only; prints every failure, exits 1 on any.
# Runs in the release workflow before anything is built, and locally before tagging.
set -uo pipefail
cd "$(dirname "$0")/.."
TAG=${1:-}
fail=0
bad() { echo "FAIL  $*"; fail=1; }
ok() { echo "ok    $*"; }

# 1. No secrets in tracked files or in history.
KEYS='sk-or-v1-[A-Za-z0-9]{20,}|AIza[0-9A-Za-z_-]{30,}|gh[opsu]_[A-Za-z0-9]{30,}|AQ\.[A-Za-z0-9_-]{30,}'
# Test fixtures spell FAKE inside every key-shaped value; those lines are exempt.
hits=$(git grep -nIE "$KEYS" | grep -v FAKE || true)
if [ -n "$hits" ]; then bad "key-shaped string in tracked files: $(echo "$hits" | cut -d: -f1 | sort -u | tr '\n' ' ')"; else ok "no key-shaped strings in tracked files"; fi
n=$(git log -p --all 2>/dev/null | grep -E "$KEYS" | grep -vc FAKE || true)
[ "$n" = "0" ] && ok "no key-shaped strings in git history" || bad "$n key-shaped lines in git history"

# 1b. gitleaks (default rules + .gitleaks.toml) over the tracked tree, when installed (it is in the export script).
if command -v gitleaks >/dev/null; then
  t=$(mktemp -d); git ls-files -z | xargs -0 -I{} rsync -R "{}" "$t/" 2>/dev/null || true
  gitleaks dir --no-banner --redact --config .gitleaks.toml "$t" >/dev/null 2>&1 && ok "gitleaks: no findings" || bad "gitleaks found something (run: gitleaks dir --config .gitleaks.toml .)"
  rm -rf "$t"
fi

# 2. No real home paths (`/Users/<name>`); the tests' `/Users/fake` and `/Users/test` fixtures are fine.
paths=$(git grep -nIE '/Users/[A-Za-z0-9._-]+' -- ':!scripts/prelaunch_check.sh' | grep -viE '/Users/fake|/Users/test"' || true)
if [ -n "$paths" ]; then bad "absolute /Users/ paths: $(echo "$paths" | cut -d: -f1 | sort -u | tr '\n' ' ')"; else ok "no /Users/ paths in public files"; fi

# 2b. Commit emails become public with the first push. Warn only: rewriting history is the owner's decision.
emails=$(git log --all --format='%ae%n%ce' | sort -u | grep -v 'noreply' || true)
[ -z "$emails" ] && ok "commit emails are noreply" || echo "WARN  $(echo "$emails" | wc -l | tr -d ' ') non-noreply commit email(s) in this history; never push it directly (publish through scripts/export_public.sh)"

# 3. Private folders and local data are not tracked.
for p in research recordings logs build dist .env.local PLAN.md; do
  if [ -n "$(git ls-files -- "$p")" ]; then bad "$p is tracked"; fi
done
ok "checked private paths (research, recordings, logs, build, dist, .env.local, PLAN.md)"

# 4. Required repo files.
for f in LICENSE README.md SECURITY.md CONTRIBUTING.md CODE_OF_CONDUCT.md CHANGELOG.md .github/ISSUE_TEMPLATE/bug.yml \
         .github/ISSUE_TEMPLATE/config.yml .github/PULL_REQUEST_TEMPLATE.md docs/media/social-preview.png; do
  [ -s "$f" ] || bad "missing $f"
done
ok "required repo files present"

# 5. Version consistency (only with a tag).
SRC_VER=$(sed -n 's/.*public static let version = "\([^"]*\)".*/\1/p' Sources/SoylaCore/Settings/Settings.swift)
if [ -n "$TAG" ]; then
  BASE=${TAG#v}; BASE=${BASE%%-*}
  [ "$SRC_VER" = "$BASE" ] && ok "Soyla.version $SRC_VER matches $TAG" || bad "Soyla.version is $SRC_VER, tag needs $BASE"
  grep -q "^## \[$BASE\] - [0-9]\{4\}-" CHANGELOG.md && ok "CHANGELOG has a dated [$BASE] section" || bad "CHANGELOG has no dated '## [$BASE] - YYYY-MM-DD' section"
else
  ok "Soyla.version is $SRC_VER (pass a tag to check it against CHANGELOG)"
fi

# 6. Privacy-sensitive defaults for new installs.
S=Sources/SoylaCore/Settings/Settings.swift
grep -q 'public var developerMode: Bool = false' "$S" || bad "developerMode must default to false"
grep -q 'public var livePreview: Bool = false' "$S" || bad "livePreview must default to false"
grep -q 'public var micWarmMode: MicWarmMode = .off' "$S" || bad "micWarmMode must default to .off (mic off between dictations)"
grep -q 'public var autoInstallUpdates: Bool = false' "$S" || bad "autoInstallUpdates must default to false (updates install only on a click)"
ok "checked privacy defaults (developer mode, live preview, warm mic, auto-install)"

# 7. Media budget: each picture ≤ 1.5 MB, docs/media ≤ 12 MB.
while IFS= read -r f; do
  sz=$(stat -f %z "$f" 2>/dev/null || stat -c %s "$f")
  [ "$sz" -le 1572864 ] || bad "$f is $((sz / 1024)) KB (> 1.5 MB)"
done < <(git ls-files docs/media; ls docs/media/social-preview.png 2>/dev/null)
total=$(du -sk docs/media | cut -f1)
[ "$total" -le 12288 ] && ok "docs/media is $((total / 1024)) MB" || bad "docs/media is $((total / 1024)) MB (> 12 MB)"

# 8. Relative links and images in the public Markdown resolve.
python3 -I - <<'EOF' || fail=1
import re, os, sys, subprocess
# Top-level and docs/ Markdown (not subfolders): the pages people read.
files = [f for f in subprocess.check_output(["git", "ls-files", "*.md"], text=True).split()
         if f.count("/") == 0 or (f.startswith("docs/") and f.count("/") == 1)]
broken = []
for f in files:
    text = re.sub(r"```.*?```", "", open(f, encoding="utf-8").read(), flags=re.S)
    for m in re.finditer(r"!?\[[^\]]*\]\(([^)\s]+)(?:\s+\"[^\"]*\")?\)", text):
        url = m.group(1)
        if re.match(r"^[a-z]+:", url) or url.startswith("#"): continue
        path = os.path.normpath(os.path.join(os.path.dirname(f), url.split("#")[0]))
        if not os.path.exists(path): broken.append(f"{f}: {url}")
for b in broken: print("FAIL  broken link", b)
print("ok    relative links resolve" if not broken else "")
sys.exit(1 if broken else 0)
EOF

echo
[ "$fail" = 0 ] && echo "prelaunch: all checks passed" || echo "prelaunch: FAILED"
exit "$fail"
