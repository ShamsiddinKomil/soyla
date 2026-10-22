#!/usr/bin/env bash
# swiftlint wrapper. Under Command Line Tools only (no Xcode) swiftlint cannot find sourcekitd unless TOOLCHAIN_DIR
# points at the CLT; with full Xcode this is a no-op. Usage: scripts/lint.sh [swiftlint args...]; no args = whole tree
# against the baseline. Not --strict: style warnings (file_length, whitespace) must not block; safety rules are errors.
set -euo pipefail
cd "$(dirname "$0")/.."
DEV="$(xcode-select -p 2>/dev/null || true)"
case "$DEV" in
  *Xcode*.app/Contents/Developer) ;;
  *) export TOOLCHAIN_DIR="${TOOLCHAIN_DIR:-/Library/Developer/CommandLineTools}" ;;
esac
# Whole tree: no --config, so the nested Tests/.swiftlint.yml applies (an explicit --config switches nested configs
# off); the parent-checkout merge below only happens with explicit file paths.
if [ "$#" -eq 0 ]; then
  exec swiftlint lint --quiet --baseline .swiftlint.baseline
fi
# Explicit file paths: --config pins this checkout's rules (inside a worktree swiftlint would otherwise also merge the
# parent checkout's .swiftlint.yml, and the baseline would match the wrong messages). Tests/ files get the nested
# config added by hand, in their own run so app code keeps force_unwrapping.
src=(); tests=(); opts=()
for a in "$@"; do case "$a" in Tests/*) tests+=("$a") ;; *.swift) src+=("$a") ;; *) opts+=("$a") ;; esac; done
if [ "${#src[@]}" -eq 0 ] && [ "${#tests[@]}" -eq 0 ]; then exec swiftlint "${opts[@]}" --config .swiftlint.yml; fi
rc=0
if [ "${#src[@]}" -gt 0 ]; then swiftlint "${opts[@]}" --config .swiftlint.yml "${src[@]}" || rc=$?; fi
if [ "${#tests[@]}" -gt 0 ]; then
  swiftlint "${opts[@]}" --config .swiftlint.yml --config Tests/.swiftlint.yml "${tests[@]}" || rc=$?
fi
exit "$rc"
