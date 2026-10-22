#!/bin/bash
# Capture one window by owner + title substring: scripts/shot.sh <owner> <title-substring|-> <out.png> [--wait SECONDS]
# Writes <out>@2x.png (Retina) and <out>.png (1x via sips). Needs Screen Recording for the terminal app.
set -euo pipefail
if [ "$1" = "--region" ]; then  # scripts/shot.sh --region x,y,w,h <out.png>  (screen points)
  base="${3%.png}"; screencapture -x -R "$2" "${base}@2x.png"
  sips -Z $(( $(sips -g pixelWidth "${base}@2x.png" | awk '/pixelWidth/{print $2}') / 2 )) "${base}@2x.png" --out "${base}.png" >/dev/null
  echo "region $2 -> ${base}.png"; exit 0
fi
owner="$1"; title="$2"; out="$3"; wait="${5:-0}"
[ "${4:-}" = "--wait" ] || wait=0
here="$(cd "$(dirname "$0")" && pwd)"
deadline=$(( $(date +%s) + wait ))
while :; do
  id=$(swift "$here/winlist.swift" --all 2>/dev/null | awk -F'\t' -v o="$owner" -v t="$title" '$3==o && $2<=25 && (t=="-" || index($4,t)>0) && $5 !~ /^0,0,1728x33$/ && !f {print $1; f=1}')
  [ -n "${id:-}" ] && break
  [ $(date +%s) -ge $deadline ] && { echo "shot.sh: no window for '$owner' / '$title'" >&2; exit 1; }
  sleep 0.5
done
base="${out%.png}"
screencapture -x -o -l "$id" "${base}@2x.png"
sips -Z $(( $(sips -g pixelWidth "${base}@2x.png" | awk '/pixelWidth/{print $2}') / 2 )) "${base}@2x.png" --out "${base}.png" >/dev/null
echo "$id -> ${base}.png"
