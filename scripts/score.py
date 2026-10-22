#!/usr/bin/env python3
"""Word error rate of every tagged run against the reference texts in TEST_SCRIPTS.md (stdlib only).

usage: score.py [--home DIR | --file runs.jsonl] [--phrase N] [--show] [--clean]
  --clean   score clean_text (cleanup pass) instead of raw_text; phrase 9 uses its "Clean" reference
  --show    print reference + hypothesis with the word-level diff for each run
"""
import argparse, json, os, re, unicodedata
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent  # repo: TEST_SCRIPTS.md lives here
APP_SUPPORT = Path.home() / "Library" / "Application Support" / "Soyla"


def default_home():
    """SOYLA_HOME (dev repo layout) if set, else ~/Library/Application Support/Soyla."""
    h = os.environ.get("SOYLA_HOME")
    return Path(h).expanduser() if h else APP_SUPPORT


def runs_file(home):
    """App Support is flat (home/runs.jsonl); a repo / SOYLA_HOME keeps home/logs/runs.jsonl (same rule as SoylaPaths)."""
    home = Path(home).expanduser()
    return home / "runs.jsonl" if home == APP_SUPPORT else home / "logs" / "runs.jsonl"



def load_refs():
    text = (ROOT / "docs" / "TEST_SCRIPTS.md").read_text(encoding="utf-8")
    refs = {}
    for sec in re.split(r"^## Phrase ", text, flags=re.M)[1:]:
        n = int(sec.split(" ", 1)[0])
        blocks = re.findall(r"```\n(.*?)\n```", sec, flags=re.S)
        if blocks:
            refs[n] = {"raw": blocks[0].strip(), "clean": blocks[-1].strip()}
    return refs


APOS = "'ʻʼ’‘`´"


def norm(s):
    s = unicodedata.normalize("NFC", s or "").lower()
    for a in APOS:
        s = s.replace(a, "'")
    s = s.replace("ё", "е")
    s = re.sub(r"[^\w'\- ]+", " ", s)          # drop punctuation, keep apostrophes/hyphens inside words
    s = s.replace("-", " ")
    return [w.strip("'") for w in s.split() if w.strip("'")]


def edit_ops(ref, hyp):
    n, m = len(ref), len(hyp)
    d = [[0] * (m + 1) for _ in range(n + 1)]
    for i in range(n + 1): d[i][0] = i
    for j in range(m + 1): d[0][j] = j
    for i in range(1, n + 1):
        for j in range(1, m + 1):
            d[i][j] = min(d[i-1][j] + 1, d[i][j-1] + 1, d[i-1][j-1] + (ref[i-1] != hyp[j-1]))
    ops, i, j = [], n, m
    while i or j:
        if i and j and d[i][j] == d[i-1][j-1] + (ref[i-1] != hyp[j-1]):
            if ref[i-1] != hyp[j-1]: ops.append(("sub", ref[i-1], hyp[j-1]))
            i, j = i-1, j-1
        elif i and d[i][j] == d[i-1][j] + 1:
            ops.append(("del", ref[i-1], "")); i -= 1
        else:
            ops.append(("ins", "", hyp[j-1])); j -= 1
    return d[n][m], ops[::-1]


def script_mix(text):
    lat = sum(1 for c in text if "a" <= c.lower() <= "z")
    cyr = sum(1 for c in text if "а" <= c.lower() <= "я" or c.lower() == "ё")
    oth = sum(1 for c in text if c.isalpha()) - lat - cyr
    return lat, cyr, oth


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--home", default=str(default_home()),
                    help="Soyla data folder (default: $SOYLA_HOME, else ~/Library/Application Support/Soyla)")
    ap.add_argument("--file", help="explicit runs.jsonl path (overrides --home)")
    ap.add_argument("--phrase", type=int)
    ap.add_argument("--show", action="store_true")
    ap.add_argument("--clean", action="store_true")
    a = ap.parse_args()
    refs = load_refs()
    rows = []
    for line in open(a.file or runs_file(a.home), encoding="utf-8"):
        try: r = json.loads(line)
        except Exception: continue
        p = r.get("phrase_id")
        if p not in refs or (a.phrase and p != a.phrase) or r.get("error"): continue
        hyp = r.get("clean_text") if a.clean else r.get("raw_text")
        if not hyp: continue
        ref = refs[p]["clean" if a.clean else "raw"]
        rw, hw = norm(ref), norm(hyp)
        dist, ops = edit_ops(rw, hw)
        wer = dist / max(1, len(rw))
        lat, cyr, oth = script_mix(hyp)
        rlat, rcyr, _ = script_mix(ref)
        rows.append(dict(p=p, model=r["model"].split("/")[-1], fmt=r["audio"]["format"],
                         lang=r.get("language_hint") or "auto", src=r["source"], wer=wer,
                         ms=(r.get("timeline_ms") or {}).get("stt_total"), dur=r["audio"]["duration_sec"],
                         cyr_ok=(cyr > 0) == (rcyr > 0), other=oth, ops=ops, hyp=hyp, ref=ref, run=r["run_id"]))
    if not rows:
        print("no tagged runs for phrases", sorted(refs)); return

    print(f"{'phrase':>6} {'model':<22} {'fmt':<4} {'lang':<4} {'src':<6} {'dur s':>5} {'WER':>6} {'stt ms':>7}  script")
    for x in sorted(rows, key=lambda x: (x["p"], x["model"], x["lang"], x["run"])):
        flag = "ok" if x["cyr_ok"] and x["other"] == 0 else ("NON-LATIN/CYR CHARS" if x["other"] else "Cyrillic mismatch")
        ms = f"{x['ms']:.0f}" if x["ms"] else "-"
        print(f"{x['p']:>6} {x['model']:<22} {x['fmt']:<4} {x['lang']:<4} {x['src']:<6} {x['dur']:5.1f} {x['wer']*100:5.1f}% {ms:>7}  {flag}")
        if a.show:
            print("    REF:", x["ref"]); print("    HYP:", x["hyp"])
            for op, rw_, hw_ in x["ops"][:40]:
                print(f"      {op}: {rw_!r} → {hw_!r}")
            print()

    g = defaultdict(list)
    for x in rows: g[(x["p"], x["model"], x["lang"])].append(x["wer"])
    print("\nmean WER by phrase × model × language hint")
    for k in sorted(g):
        v = g[k]; print(f"  phrase {k[0]:>2}  {k[1]:<22} {k[2]:<4} n={len(v)}  {sum(v)/len(v)*100:5.1f}%")


if __name__ == "__main__":
    main()
