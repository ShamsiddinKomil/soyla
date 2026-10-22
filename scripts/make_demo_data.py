#!/usr/bin/env python3
"""Demo History for screenshots and videos: fictional test phrases only (docs/HARNESS.md), never real dictations.

Usage: python3 -I scripts/make_demo_data.py <DEMO_HOME>
Then run the app on it, fully separate from your own settings, keys and data (the empty settings blob reads as
"setup done" with every default, so the Setup Assistant stays closed; omit it to capture the assistant):
  defaults write ai.soyla.capture settings.v1 -data 7b7d
  SOYLA_HOME=<DEMO_HOME> SOYLA_SETTINGS_SUITE=ai.soyla.capture SOYLA_KEYCHAIN_SERVICE=ai.soyla.capture \\
  OPENROUTER_API_KEY=sk-or-v1-FAKE-demo-key-not-real build/Soyla.app/Contents/MacOS/soyla --page home
Clean up afterwards: defaults delete ai.soyla.capture; rm -rf <DEMO_HOME>
"""
import json, sys
from datetime import datetime, timedelta
from pathlib import Path

PHRASES = [  # (text, target app, seconds spoken, release→paste ms)
    ("Assalomu alaykum, bugun soat uchda mijoz bilan uchrashuv bor, prezentatsiyani tayyorlab qo'ying.", "Telegram", 6.1, 2140),
    ("Deadline juma kuni, pull request ni bugun ochib qo'ying, iltimos.", "Slack", 4.2, 1980),
    ("Shartnoma summasi o'n besh million so'm, to'lov yigirmanchi noyabrgacha.", "Mail", 4.8, 2420),
    ("Ertaga ertalab qo'ng'iroq qilaman, а потом обсудим детали договора.", "Telegram", 4.6, 2260),
    ("Please send me the final version by Friday, rahmat.", "Mail", 3.3, 1870),
    ("Keyingi haftaga reja tuzamiz, но сначала нужно согласовать бюджет с бухгалтерией.", "Notes", 5.4, 2310),
]


def main() -> None:
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    home = Path(sys.argv[1]).expanduser()
    (home / "logs").mkdir(parents=True, exist_ok=True)
    (home / "recordings").mkdir(exist_ok=True)
    now = datetime.now().astimezone()
    rows = []
    for i, (text, app, secs, wait) in enumerate(PHRASES):
        t = now - timedelta(minutes=12 * (len(PHRASES) - i))
        rows.append({
            "run_id": t.strftime("%Y-%m-%dT%H-%M-%S-") + f"{i:03d}",
            "ts": t.isoformat(timespec="milliseconds"),
            "source": "live", "model": "google/gemini-3.5-flash", "cleanup": False, "prewarm": True,
            "audio": {"format": "wav", "bytes": int(secs * 32000), "b64_bytes": int(secs * 42700),
                      "duration_sec": secs, "sample_rate": 16000, "file": None},
            "timeline_ms": {"release_to_paste": wait, "stt_total": wait - 180},
            "raw_text": text, "app_version": "0.2.0", "target_app": app, "status": "ok",
        })
    out = home / "logs" / "runs.jsonl"
    out.write_text("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in rows), encoding="utf-8")
    print(f"{out}: {len(rows)} demo dictations")


if __name__ == "__main__":
    main()
