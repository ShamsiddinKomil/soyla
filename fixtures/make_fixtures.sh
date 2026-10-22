#!/usr/bin/env bash
# Synthetic 16 kHz mono WAVs for plumbing tests (NOT for accuracy — macOS has no Uzbek voice).
set -euo pipefail
cd "$(dirname "$0")"
mk() { say -v "$2" -o "/tmp/soyla_$1.aiff" "$3"; ffmpeg -loglevel error -y -i "/tmp/soyla_$1.aiff" -ar 16000 -ac 1 -c:a pcm_s16le "$1.wav"; rm -f "/tmp/soyla_$1.aiff"; echo "$1.wav $(stat -f%z "$1.wav") bytes"; }
mk en1 Samantha "Deadline is Friday, please open the pull request today."
mk en2 Samantha "The contract amount is fifteen million, payment by the twentieth of November."
