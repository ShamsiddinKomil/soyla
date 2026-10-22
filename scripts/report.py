#!/usr/bin/env python3
"""Soyla run-log report (stdlib only). Reads runs.jsonl from --home (default: SOYLA_HOME, else ~/Library/Application Support/Soyla) (snake_case keys as RunRecord encodes them)."""
import argparse
import csv
import json
import math
import os
import sys
from pathlib import Path

APP_SUPPORT = Path.home() / "Library" / "Application Support" / "Soyla"


def default_home():
    """SOYLA_HOME (dev repo layout) if set, else ~/Library/Application Support/Soyla."""
    h = os.environ.get("SOYLA_HOME")
    return Path(h).expanduser() if h else APP_SUPPORT


def runs_file(home):
    """App Support is flat (home/runs.jsonl); a repo / SOYLA_HOME keeps home/logs/runs.jsonl (same rule as SoylaPaths)."""
    home = Path(home).expanduser()
    return home / "runs.jsonl" if home == APP_SUPPORT else home / "logs" / "runs.jsonl"


TIMELINE_KEYS = ["warmup", "recording", "encode", "request_prep", "upload_to_first_byte", "stt_request",
                 "stt_total", "cleanup", "paste", "release_to_paste", "clipboard_restore"]


def load(path):
    rows, bad = [], 0
    if not os.path.exists(path):
        return rows, 0
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                r = json.loads(line)
                if not isinstance(r, dict) or "run_id" not in r:
                    raise ValueError("not a run record")
                rows.append(r)
            except ValueError:
                bad += 1
    return rows, bad


def pct(vals, p):
    """Nearest-rank percentile."""
    if not vals:
        return None
    s = sorted(vals)
    k = max(1, math.ceil(p / 100.0 * len(s)))
    return s[k - 1]


def tl(r, key):
    v = (r.get("timeline_ms") or {}).get(key)
    return v if isinstance(v, (int, float)) else None


def audio(r):
    return r.get("audio") or {}


def cost(r):
    c = (r.get("usage") or {}).get("cost")
    cc = (r.get("cleanup_usage") or {}).get("cost")
    if c is not None and cc is not None:
        c = c + cc
    return c if isinstance(c, (int, float)) else None


def engine(r):
    """'apple' for the on-device engine (provider_meta.provider, set by AppleSpeechProvider and replay), else 'cloud'."""
    m = r.get("provider_meta")
    p = m.get("provider") if isinstance(m, dict) else None
    return p if isinstance(p, str) and p else "cloud"


def fmt(v, nd=0):
    return "-" if v is None else f"{v:.{nd}f}"


def table(rows):
    groups = {}
    show_engine = any(engine(r) != "cloud" for r in rows)   # engine column only once a non-cloud engine is present
    for r in rows:
        key = ((engine(r) if show_engine else ""), r.get("model", "?"), audio(r).get("format", "?"), "on" if r.get("cleanup") else "off", r.get("source", "?"))
        groups.setdefault(key, []).append(r)
    cols = ["engine", "model", "format", "cleanup", "source", "n", "rtp_p50", "rtp_p90", "stt_p50", "stt_p90",
            "req_p50", "req_p90", "enc_p50", "cln_p50", "cost_mean", "err"]
    out = []
    for key in sorted(groups):
        g = groups[key]
        ok = [r for r in g if r.get("error") is None]
        live = key[4] == "live"

        def vals(k):
            return [v for v in (tl(r, k) for r in ok) if v is not None]
        rtp = vals("release_to_paste") if live else []
        costs = [c for c in (cost(r) for r in ok) if c is not None]
        out.append([key[0], key[1], key[2], key[3], key[4], str(len(g)),
                    fmt(pct(rtp, 50)), fmt(pct(rtp, 90)),
                    fmt(pct(vals("stt_total"), 50)), fmt(pct(vals("stt_total"), 90)),
                    fmt(pct(vals("stt_request"), 50)), fmt(pct(vals("stt_request"), 90)),
                    fmt(pct(vals("encode"), 50)), fmt(pct(vals("cleanup"), 50)),
                    fmt(sum(costs) / len(costs), 5) if costs else "-",
                    str(len(g) - len(ok))])
    left = {0, 1, 2, 3, 4}
    if not show_engine:   # keep the original layout (and column order) for all-cloud logs
        cols = cols[1:]
        out = [row[1:] for row in out]
        left = {0, 1, 2, 3}
    widths = [max([len(c)] + [len(row[i]) for row in out]) for i, c in enumerate(cols)]

    def line(cells):
        return "  ".join(c.ljust(widths[i]) if i in left else c.rjust(widths[i]) for i, c in enumerate(cells))
    print(line(cols))
    print("  ".join("-" * w for w in widths))
    for row in out:
        print(line(row))
    print("\nms; percentiles nearest-rank over non-error runs; rtp = release_to_paste (live only)")
    if show_engine:
        print("engine = provider_meta.provider (apple = on-device, cloud = everything else); rows are grouped per engine")


def one_line(s):
    return " ".join(str(s).split())


def phrase(rows, n):
    sel = [r for r in rows if r.get("phrase_id") == n]
    if not sel:
        print(f"no runs for phrase {n}")
        return
    sel.sort(key=lambda r: (r.get("model", ""), r.get("ts", "")))
    last = None
    for r in sel:
        if r.get("model") != last:
            last = r.get("model")
            print(f"\n=== {last} ===")
        head = f"{r.get('run_id')}  {r.get('model')}  {audio(r).get('format', '?')}  stt_total={fmt(tl(r, 'stt_total'))}ms"
        if r.get("error") is not None:
            head += f"  ERROR: {r['error']}"
        print(head)
        print("  raw:   " + one_line(r.get("raw_text") or ""))
        if r.get("clean_text") is not None:
            print("  clean: " + one_line(r["clean_text"]))


def write_csv(rows):
    def net(r, k):
        return (r.get("net") or {}).get(k)
    header = (["run_id", "ts", "source", "phrase_id", "model", "format", "cleanup", "duration_sec", "bytes"]
              + TIMELINE_KEYS + ["net_ttfb", "net_reused", "cost", "error", "raw_text", "clean_text", "engine"])
    w = csv.writer(sys.stdout, lineterminator="\n")
    w.writerow(header)
    for r in rows:
        a = audio(r)
        w.writerow([r.get("run_id"), r.get("ts"), r.get("source"), r.get("phrase_id"), r.get("model"),
                    a.get("format"), r.get("cleanup"), a.get("duration_sec"), a.get("bytes")]
                   + [tl(r, k) for k in TIMELINE_KEYS]
                   + [net(r, "ttfb"), net(r, "reused"), cost(r), r.get("error"), r.get("raw_text"), r.get("clean_text"), engine(r)])


def main():
    ap = argparse.ArgumentParser(description="Soyla run-log report")
    ap.add_argument("--home", default=str(default_home()),
                    help="Soyla data folder (default: $SOYLA_HOME, else ~/Library/Application Support/Soyla)")
    ap.add_argument("--file", help="explicit runs.jsonl path (overrides --home)")
    ap.add_argument("--phrase", type=int)
    ap.add_argument("--csv", action="store_true")
    ap.add_argument("--source", choices=["live", "replay", "all"], default="all")
    ap.add_argument("--since", help="YYYY-MM-DD; keep runs with ts >= this date")
    a = ap.parse_args()
    rows, bad = load(a.file or str(runs_file(a.home)))
    if bad:
        print(f"report.py: skipped {bad} malformed line(s)", file=sys.stderr)
    if a.source != "all":
        rows = [r for r in rows if r.get("source") == a.source]
    if a.since:
        rows = [r for r in rows if str(r.get("ts", "")) >= a.since]
    if a.csv:
        write_csv(rows)
    elif a.phrase is not None:
        phrase(rows, a.phrase)
    else:
        if not rows:
            print("no runs")
            return
        table(rows)


if __name__ == "__main__":
    main()
