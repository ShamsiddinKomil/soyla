#!/usr/bin/env python3
"""Joins the video slides and the demo frames with crossfades (ffmpeg). Used by scripts/make_video.sh.
Usage: python3 -I scripts/video_concat.py <slides dir> <demo frames dir> <out.mp4>"""
import subprocess, sys
from pathlib import Path

PAPER = "0xF6F7F9"
FADE = 0.4
# (slide file stem or "demo", seconds on screen)
PLAN = [("01-title", 3.5), ("demo", 9.6), ("03-download", 3.5), ("04-blocked", 3.0), ("05-openanyway", 3.5),
        ("06-welcome", 3.0), ("07-languages", 4.0), ("08-permissions", 4.0), ("09-connect", 4.5), ("10-try", 3.5),
        ("11-done", 3.5), ("12-home", 3.5), ("13-history", 3.5), ("14-languages", 3.5), ("15-offline", 3.5),
        ("16-privacy", 4.0), ("17-end", 3.5)]


def main() -> None:
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    slides, demo, out = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
    args, chains = ["ffmpeg", "-loglevel", "error", "-y"], []
    for i, (name, secs) in enumerate(PLAN):
        if name == "demo":
            args += ["-framerate", "15", "-i", str(demo / "frame-%04d.png")]
            chains.append(f"[{i}]scale=1600:1000:flags=lanczos,pad=1920:1080:160:40:color={PAPER},fps=30,format=yuv420p,setsar=1[v{i}]")
        else:
            args += ["-loop", "1", "-t", str(secs), "-framerate", "30", "-i", str(slides / f"{name}.png")]
            chains.append(f"[{i}]scale=1920:1080,fps=30,format=yuv420p,setsar=1[v{i}]")
    # Crossfade each clip into the next; offsets accumulate (each fade overlaps FADE seconds).
    last, t = "v0", PLAN[0][1]
    for i in range(1, len(PLAN)):
        tag = f"x{i}"
        chains.append(f"[{last}][v{i}]xfade=transition=fade:duration={FADE}:offset={t - FADE:.2f}[{tag}]")
        last, t = tag, t + PLAN[i][1] - FADE
    args += ["-filter_complex", ";".join(chains), "-map", f"[{last}]", "-c:v", "libx264", "-preset", "slow",
             "-crf", "22", "-pix_fmt", "yuv420p", "-movflags", "+faststart", out]
    subprocess.run(args, check=True)
    print(f"video: {t:.1f} s → {out}")


if __name__ == "__main__":
    main()
