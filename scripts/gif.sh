#!/bin/bash
# scripts/gif.sh in.mov out.gif [maxwidth=900] [fps=12] — ffmpeg palettegen/paletteuse, for README/docs.
set -euo pipefail
in="$1"; out="$2"; w="${3:-900}"; fps="${4:-12}"
ffmpeg -y -loglevel error -i "$in" -vf "fps=$fps,scale='min($w,iw)':-1:flags=lanczos,split[s0][s1];[s0]palettegen=max_colors=128[p];[s1][p]paletteuse=dither=bayer:bayer_scale=5" "$out"
ls -la "$out"
