#!/usr/bin/env node
// Gemini Live transcription test (AI Studio key, no SDK, Node >= 22 global WebSocket).
// Streams a 16 kHz mono PCM16 WAV in 100 ms chunks at real-time pace, push-to-talk style
// (activityStart → audio → activityEnd), and measures:
//   first_interim_ms : from first audio chunk to first interim text (how fast words appear while speaking)
//   release_to_final_ms : from activityEnd ("key up") to the final transcript — the number that matters
//
// usage: node scripts/live_test.mjs <file.wav> [--lang uz-UZ,ru-RU] [--smart] [--vocab "a,b"] [--fast]
//   --fast  send audio as fast as possible (no real-time pacing) — upper bound, not a dictation simulation
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const args = process.argv.slice(2);
const file = args.find(a => !a.startsWith("--") && !args[args.indexOf(a) - 1]?.match(/^--(lang|vocab)$/));
const opt = (k) => { const i = args.indexOf(k); return i >= 0 ? args[i + 1] : undefined; };
const lang = opt("--lang") ? opt("--lang").split(",").filter(Boolean) : [];
const vocab = opt("--vocab") ? opt("--vocab").split(",").map(s => s.trim()).filter(Boolean) : [];
const smart = args.includes("--smart");
const fast = args.includes("--fast");
const vad = args.includes("--vad");   // server VAD segments on pauses; key-up sends audioStreamEnd to flush
if (!file) { console.error("usage: live_test.mjs <file.wav> [--lang uz-UZ,ru-RU] [--smart] [--vocab a,b] [--fast]"); process.exit(2); }

const envPath = path.join(process.env.SOYLA_HOME || path.join(os.homedir(), "projects/soyla"), ".env.local");
const key = fs.readFileSync(envPath, "utf8").split("\n").find(l => l.startsWith("GEMINI_API_KEY="))?.slice(15).trim();
if (!key) { console.error("GEMINI_API_KEY missing in " + envPath); process.exit(2); }

const wav = fs.readFileSync(file);
const pcm = wav.subarray(44);                       // Soyla WAVs: canonical 44-byte header, 16 kHz mono s16le
const CHUNK = 3200;                                 // 100 ms
const durSec = pcm.length / 32000;

const url = "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent";
// Key goes in a header (Node's undici WebSocket accepts `headers`), never in the URL, so no error/log line can carry it.
const ws = new WebSocket(url, { headers: { "x-goog-api-key": key } });
const t0 = performance.now();
const now = () => performance.now();
let tFirstAudio, tEnd, tFirstInterim, tSetup;
let finals = [], lastInterim = "", interims = 0, done = false;

function send(o) { ws.send(JSON.stringify(o)); }
function finish(reason) {
  if (done) return; done = true;
  const final = finals.join(" ").replace(/\s+/g, " ").trim();
  const tLastFinal = finals.length ? lastFinalAt : undefined;
  console.log(JSON.stringify({
    file: path.basename(file), dur_s: +durSec.toFixed(2), lang: lang.length ? lang : "auto", smart, vocab: vocab.length, vad,
    connect_setup_ms: Math.round(tSetup - t0),
    first_interim_ms: tFirstInterim ? Math.round(tFirstInterim - tFirstAudio) : null,
    interim_updates: interims,
    release_to_final_ms: tLastFinal && tEnd ? Math.round(tLastFinal - tEnd) : null,
    end_reason: reason,
  }));
  console.log("FINAL:", final || "(empty)");
  if (process.env.SHOW_INTERIM || !final) console.log("LAST INTERIM:", lastInterim);
  try { ws.close(); } catch {}
  setTimeout(() => process.exit(0), 50);
}
let lastFinalAt, idleTimer;
function armIdle() {                                 // after key-up: finish once finals stop arriving
  clearTimeout(idleTimer);
  idleTimer = setTimeout(() => finish("idle after last message"), +(process.env.IDLE_MS || 1500));
}

ws.onopen = () => {
  const transcription = { languageCodes: lang };
  if (vocab.length) transcription.customVocabulary = vocab;
  if (smart) transcription.mode = "SMART";
  send({ setup: {
    model: "models/gemini-3.5-transcribe-live",
    generationConfig: { responseModalities: ["TEXT"] },
    inputAudioTranscription: transcription,
    ...(vad ? {} : { realtimeInputConfig: { automaticActivityDetection: { disabled: true } } }),
  }});
};

ws.onmessage = async (ev) => {
  const raw = typeof ev.data === "string" ? ev.data : Buffer.from(await ev.data.arrayBuffer()).toString("utf8");
  const m = JSON.parse(raw);
  if (m.setupComplete) { tSetup = now(); stream(); return; }
  const c = m.serverContent;
  if (c?.interimInputTranscription?.text) {
    interims++; lastInterim = c.interimInputTranscription.text;
    if (!tFirstInterim) tFirstInterim = now();
    if (process.env.VERBOSE) console.log(`  [${Math.round(now() - tFirstAudio)} ms interim] ${lastInterim}`);
  }
  if (c?.inputTranscription?.text) {
    finals.push(c.inputTranscription.text); lastFinalAt = now();
    if (process.env.VERBOSE) console.log(`  [${Math.round(now() - tFirstAudio)} ms FINAL] ${c.inputTranscription.text}`);
  }
  if (m.error || m.goAway) console.log("SERVER:", JSON.stringify(m).slice(0, 300));
  if (process.env.RAW && !c?.interimInputTranscription) console.log(`  [${Math.round(now() - tFirstAudio)} ms RAW] ${JSON.stringify(m).slice(0, 400)}`);
  if (tEnd) armIdle();
};
ws.onerror = (e) => { console.log("WS ERROR", e.message || e.type); finish("ws error"); };
ws.onclose = (e) => { if (!done) { console.log("WS CLOSED", e.code, (e.reason || "").slice(0, 200)); finish("closed " + e.code); } };

async function stream() {
  if (!vad) send({ realtimeInput: { activityStart: {} } });
  tFirstAudio = now();
  for (let off = 0, i = 0; off < pcm.length; off += CHUNK, i++) {
    send({ realtimeInput: { audio: { data: pcm.subarray(off, off + CHUNK).toString("base64"), mimeType: "audio/pcm;rate=16000" } } });
    if (!fast) { const due = tFirstAudio + (i + 1) * 100; const wait = due - now(); if (wait > 0) await new Promise(r => setTimeout(r, wait)); }
  }
  tEnd = now();                                      // "key up"
  send({ realtimeInput: vad ? { audioStreamEnd: true } : { activityEnd: {} } });
  armIdle();
  setTimeout(() => finish("timeout 30 s after key-up"), 30000);
}
