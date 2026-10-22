# Soyla measurement harness

How to measure latency and accuracy with Soyla: log format, `replay`, `report`, `score`, and the first test protocol.
Reference scripts for long phrases are in [TEST_SCRIPTS.md](TEST_SCRIPTS.md); the code map in [HOW_IT_WORKS.md](HOW_IT_WORKS.md).

## Latency timeline and log


`RunTimeline` records monotonic timestamps (`ContinuousClock`) at each boundary; durations are
derived at write time so the JSONL is self-explanatory.

| Timestamp | Meaning |
|---|---|
| `t_key_down` | hotkey pressed |
| `t_rec_start` | first audio buffer received (engine warm-up cost) |
| `t_key_up` | hotkey released — **zero point for user-perceived latency** |
| `t_encode_done` | audio encoded + base64'd |
| `t_request_sent` | `URLSession` task resumed |
| (first byte) | not a mark; `net.ttfb` from `URLSessionTaskMetrics` (also DNS / TLS / connect split, `reused`) |
| `t_response_received` | full body parsed |
| `t_cleanup_sent` / `t_cleanup_done` | only when cleanup on |
| `t_pasted` | Cmd+V posted |
| `t_clipboard_restored` | previous pasteboard put back |

Logged per run (one line in `logs/runs.jsonl`):

```json
{"run_id":"2026-10-15T14-02-11-123","ts":"…","phrase_id":2,"model":"google/gemini-3.5-transcribe",
 "cleanup":true,"cleanup_model":"google/gemini-3.5-flash-lite","language_hint":null,
 "audio":{"format":"wav","bytes":331244,"b64_bytes":441660,"duration_sec":10.35,"sample_rate":16000,"file":"recordings/….wav"},
 "timeline_ms":{"warmup":41,"encode":3,"stt_request":2100,"stt_total":2110,"cleanup":640,"paste":22,"release_to_paste":2795},
 "net":{"dns":0,"connect":0,"tls":0,"ttfb":1812,"reused":true},
 "usage":{"seconds":10.35,"input_tokens":332,"output_tokens":28,"cost":0.00099},
 "raw_text":"…","clean_text":"…","app_version":"0.1.0"}
// keys with no value (error, clean_text, language_hint, cleanup_model, audio.file, usage.seconds) are omitted
```

**Pre-warm trick (setting, default on, logged so you can A/B it):** on hotkey *down* we fire a
tiny `GET /api/v1/auth/key` on the same `URLSession` so TLS is already up when the audio is
ready. `connection_reused` in the log tells you whether it worked.

## Reporting

- `scripts/report.py` (stdlib only): reads `logs/runs.jsonl`, prints p50 / p90 / n of
  `release_to_paste`, `stt_total`, `encode`, `cleanup` **per model × format × cleanup**, plus
  mean `usage.cost`. `--phrase 2` prints raw/clean text of every run of phrase 2 side by side,
  grouped by model, so you can score words by eye. `--csv` for a spreadsheet.
- In-app: a "Runs" window (table: time, model, phrase, ms, first 60 chars) and a
  "Compare" tab that shows the latest run of each model for the selected phrase. Minimal.

---

## CLI (same binary)

```
soyla replay recordings/<id>.wav --models google/gemini-3.5-transcribe,elevenlabs/scribe-v2 --formats wav,flac,ogg [--cleanup] [--language uz] [--phrase N] [--prewarm] [--no-log]
soyla models [--refresh]                # transcription models + pricing
soyla replay recordings/<id>.wav --provider apple [--language en-GB] [--no-log]   # free on-device engine
soyla report [--phrase N] [--csv] [--source live|replay|all] [--since YYYY-MM-DD]
soyla rec-test [sec] [--warm]           # mic -> every format, sizes + encode ms
soyla hotkey-test [fn|rightOption|...]  # prints DOWN/UP for 20 s
soyla paste-test "text"                 # pastes into the frontmost app after 3 s
```

`replay` re-sends one saved recording to any models/formats (`source = "replay"` in the log), so accuracy
comparisons use identical audio without re-dictating.

**`--provider apple` (on-device engine, FE-6).** Runs the file through `AppleSpeechProvider`: no key, no network,
no cleaner, no script check (cleanup is off for the free engine, as in the app). `--language` is English only
(`en` = en-US, or `en-GB`, `en-AU`, ...; anything else is rejected), default = `Settings.onDeviceLocale`.
`--models` is ignored: the row's `model` is the locale, and `provider_meta.provider = "apple"` marks the engine.
`soyla report` then adds an `engine` column (`apple` / `cloud`) so p50/p90 `stt_total` sit side by side; the CSV
gets an `engine` column last. All-cloud logs keep the old layout.

*Known limit:* from a bare CLI the model can report not-installed until the Soyla app has reserved the locale.
Replay then fails cleanly with the `onDeviceUnavailable` message (the run is logged as an
error row), it does not crash. Open the app once (or run the check from the bundle) and retry.

## Reading the log

- Log: `logs/runs.jsonl`, one JSON object per run (schema: `Sources/SoylaCore/Metrics/RunRecord.swift`).
  Key fields: `timeline_ms.release_to_paste` (what you feel), `timeline_ms.stt_total`, `net.ttfb`,
  `net.reused` (pre-warm worked), `usage.cost`, `raw_text`, `clean_text`, `error`.
  Optional fields are omitted when empty, not written as null.
- `python3 scripts/report.py` gives p50/p90 per model x format x cleanup x source.
- `python3 scripts/report.py --phrase 2` prints every run of phrase 2 side by side for hand scoring.
- `python3 scripts/score.py` computes word error rate of tagged runs against [TEST_SCRIPTS.md](TEST_SCRIPTS.md)
  (`--show` for word diffs, `--clean` to score the cleanup output).
- Recordings: `recordings/<run_id>.<fmt>` (retention is a setting).


## Test protocol (first session)

Setup: cleanup **off**, format **wav**, language hint **none**, pre-warm **on**, phrase id set
before each run. Quiet room, built-in mic (note which mic in the session notes).

| # | Phrase | Tests |
|---|---|---|
| 1 | Assalomu alaykum, bugun soat uchda mijoz bilan uchrashuv bor, prezentatsiyani tayyorlab qo'ying. | pure Uzbek, apostrophe (qo'ying), time |
| 2 | Keyingi haftaga reja tuzamiz, но сначала нужно согласовать бюджет с бухгалтерией. | Uzbek→Russian switch mid-sentence, Cyrillic preserved |
| 3 | Deadline juma kuni, pull request ni bugun ochib qo'ying, iltimos. | English terms inside Uzbek |
| 4 | Shartnoma summasi o'n besh million so'm, to'lov yigirmanchi noyabrgacha. | numbers, dates, currency |
| 5 | 30 s free-form mixed ramble with fillers + one self-correction | long clip, cleanup value, 45 s warning path |

Rounds (Gemini-only by decision; other models are optional and never require re-dictating):
1. **Mic dictation on Gemini**, 5 phrases × 3 reps = 15 runs (≈ 7 min). Tag each with phrase id.
2. **Format A/B** on Gemini: `soyla replay` the 15 WAVs as wav / flac / ogg → does upload size
   move `upload_to_first_byte`? (API only, no speaking.)
3. **Cleanup on**, Gemini, 5 phrases × 1 rep dictated → delta in `release_to_paste` and whether
   cleanup preserves the language mix.
4. Optional: `language: "uz"` hint, Gemini, phrases 1 & 4.
5. Optional, cheap, no speaking: `soyla replay` the same 15 WAVs through `elevenlabs/scribe-v2`
   (lists Uzbek) and `google/chirp-3` to confirm the assumption that they are worse on Uzbek.
   Skip if not curious. `openai/gpt-4o-transcribe` and `-mini` likewise.

Scoring sheet (`report.py --phrase N` gives the text; you score by hand, 0–3 each):
correct words · Uzbek stays Latin · language switches kept · numbers right · plus p50/p90 from
the report. Expect Uzbek to be the weak spot (Google lists it as Experimental). Round 5 exists only to
check whether any other hosted model does better; the working assumption is that they don't.

Results report after the session → `RESULTS.md` (table per model: p50/p90 latency, cost/run,
accuracy scores, 2–3 example diffs, recommendation).
