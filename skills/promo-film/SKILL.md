---
name: promo-film
description: Produce a professional 30–60 s product promo / launch film as pure JavaScript (Canvas2D + WebGL2 + a procedural Web Audio soundtrack + TTS voiceover), rendered deterministically to MP4 in 16:9 and a native 9:16 social cut. Use when asked for a promo video, launch film, product teaser, animated explainer, or a LinkedIn/Instagram/TikTok vertical cut of one.
---

# Promo film — pure-JS, frame-deterministic, rendered to MP4

A method that shipped a 56 s, 1080p60 product film plus a 1080×1920 LinkedIn cut, with no video
editor, no stock footage and no paid music. Everything is code, so it can be re-timed, re-worded
and re-rendered in minutes. Read the whole file before starting; the **Gotchas** section alone
saves hours.

## 0. Before you write a word: the claims check

The single most expensive mistake was scripting a feature that had not shipped. The owner caught it
after delivery, and it cost a re-cut of both formats.

1. Build the **claims list** from the product itself: the shipped UI, the README, the release notes,
   the tracker's *closed* items. Planned features, open epics and roadmap docs are not evidence.
2. Show the owner the claims list and the script **before** building, and get a yes.
3. Check the project's own memory for marketing constraints, for example `bd memories promo` or
   `bd memories marketing`, and the project's terminology or brand docs. Some products ban certain
   verbs, and every brand has exact colours and fonts.
4. Hard rules: no real artist, label or brand names or logos, and no third-party service logos. Use
   a fictional demo track or customer. Legal clearance is the owner's call, not yours.

If the project keeps a promo brief (e.g. `docs/marketing/promo-brief.md`), it overrides the defaults
here.

## 1. Architecture (why it works)

**Everything is a pure function of time `t`.** The same code drives live playback in a browser *and*
a frame-by-frame offline render. `renderFrame(t)` must produce identical pixels for the same `t`
regardless of what rendered before. Consequences:

- No `Math.random()`. Use a seeded PRNG. Particle systems simulate analytically, or re-simulate from
  scene start with a fixed step.
- **One authoritative cue sheet** (`site/js/timeline.js`) holds BPM, the bar grid, `SCENES`,
  `markers`, the `VO` clips (start, dur, speechOffset, words), `stemAutomation` and `sfx`. Visuals and
  audio both read it; re-timing is a data change. Author on the **musical bar grid**: every cut,
  reveal and hit lands on a beat, which is most of what makes it feel produced.
- Layout: `site/` (index.html shell, css, `js/timeline.js`, `js/audio/`, `js/visual/`, `js/main.js`,
  `assets/{fonts,brand,vo}`) plus `render/`. ES modules, no bundler, no CDN, fonts via local `@font-face`.
- Render API: with `?render=1` the page exposes
  `window.__film = { ready: Promise, duration, fps, format, renderFrame(t), getMasterWav(): base64 }`.
  `?format=vertical` switches the design space to 1080×1920.
- Visual stack: WebGL2 background (fog, perspective grid floor that pulses with the kick, dust), a
  Canvas2D foreground (type, UI mocks, waveforms drawn from the *real* audio, pooled particles), and
  post (bloom, grain, vignette, chromatic aberration on transitions only).

`templates/SPEC-template.md` is a full production-spec skeleton covering story table, brand tokens,
the audio/visual contract and definition of done. Fill it in first. It doubles as the prompt for
delegated implementation rounds.

## 2. Voiceover (Gemini TTS)

`scripts/tts.py <model> <voice> <out.wav> "<text>"` reads `GOOGLE_API_KEY` from the environment and
never prints it. It retries 429/500/503 and handles both RIFF and raw L16 responses.

- Working recipe: model `gemini-3.1-flash-tts-preview`, voice **Kore**, text prefixed with a natural
  style instruction:
  `Say in a low, warm, intimate, confident and unhurried voice, like a premium product film narrator: <line>`
- Don't use a `systemInstruction` (400), and don't use an "AUDIO PROFILE:"-style structured prompt
  (PROHIBITED_CONTENT on 3.1). Newer TTS models may have a ~10/day free quota; spend it on finals,
  not drafts. Lyria (music) had quota 0 on the free tier, which is why the music is procedural.
- Generate **per phrase**, not per paragraph. Short clips give you timing control on the bar grid and
  let captions and kinetic type sync exactly. Trim silence, speed up gently (`atempo=1.10` read
  natural), and resample to 48 kHz mono. Record each clip's `dur` and `speechOffset` in the timeline.
- A breathy "vocal chop" clip (e.g. "ooh… hear it… yeah") from the same TTS makes a convincing vocal
  stem once sliced, pitched to key and thrown through delay.

## 3. Soundtrack (procedural Web Audio, offline)

Build the whole track in an `OfflineAudioContext` (48 kHz stereo). It is deterministic and renders in
seconds.

- Buses: drums, bass, vocals, other, sfx and vo. Export each as a stem as well as the master; the
  visuals use per-frame stem RMS *after* solo/mute automation, so what you see matches what you hear.
- Mix moves that sell it:
  - a "heard through a wall" low-pass that snaps open on the key action
  - a build with a snare roll and a silence gap before the drop
  - real solos per stem when the VO names them
  - kick sidechain done as deterministic gain automation
  - VO ducking of −6…−8 dB with a 2–4 kHz presence dip
  - a master glue comp, then a soft limiter, then tanh soft clip
- Targets, measured on the rendered file (never trust the graph):
  - **−14 LUFS integrated**
  - true peak ≤ −1 dBTP (−2.5 gives AAC headroom)
  - LRA around 6–7
  - drop short-term around −12 LUFS
- Gap-bridge 20 ms crossfades on every solo edge and cut, then run the click scan (§6).
- Keep a unit-tested pure-logic module for kick/snare times, automation lookups and true-peak math
  (`node --test`). Those tests caught real bugs.

## 4. Vertical 9:16 cut (LinkedIn / Reels / Shorts)

Recompose natively; never crop the 16:9.

- Design space is 1080×1920. The **safe zone** is x ∈ [72, 1008] and y ∈ [220, 1620]; platform UI
  covers the top bar and the bottom ~300 px.
- **Burn in captions** from the `VO` words, since most feeds autoplay muted. Put them in the lower
  band (baseline ≤ y 1560), with at most 2 lines, a high-contrast plate, and word timing from
  `speechOffset`.
- Stack what was side-by-side. Scale headline type for phone reading distance. Keep the HUD row
  above y ≈ 1600.
- Prove the landscape film is unchanged by the vertical work: render stills at fixed times from a
  frozen copy and the new tree, and compare with PSNR. Expect `inf`, and a negative control, a
  deliberately changed frame, should read ~15 dB (§6).

## 5. Rendering to MP4

`scripts/render.mjs` (Playwright + ffmpeg) and `scripts/chunked.sh`. Copy both into the film's
`render/`. Needs `npm i playwright`, `npx playwright install chromium` and ffmpeg.

```bash
node render/render.mjs --stills 1,9.5,17.42,30 [--format vertical]   # review stills
node render/render.mjs --scale 0.5 --from 15 --to 22                  # fast preview
bash render/chunked.sh [vertical]                                     # final: out/film[-vertical].mp4
```

- Frames are PNG screenshots piped to `libx264 -preset slow -crf 16 -pix_fmt yuv420p -profile:v high
  -movflags +faststart` at 60 fps. The master WAV comes from `__film.getMasterWav()`.
- `chunked.sh` renders 5 s chunks, each in a fresh browser with 3 retries and `.ok` markers, then
  concatenates them with `-c copy` and muxes the audio **once** through `lowpass=f=19000:poles=2`
  into AAC 320k. Delete `out/chunks*` before a re-render after timeline changes, because stale `.ok`
  markers get reused. The script resets them when DURATION changes, but not on other edits.

## 6. Verification (a green must be able to be red)

| Check | How | Pass |
|---|---|---|
| Visual review | Stills at every scene's midpoint and each transition → contact sheet, then zoom crops of type and edges | No clipping outside safe zone, no half-rendered text, nothing static |
| Loudness | `scripts/audio_qc.py out/film.mp4` (ffmpeg ebur128 + 4× oversampled true peak in numpy) | −14 ±0.5 LUFS, TP ≤ −1 dBTP **after AAC** |
| Clicks | `audio_qc.py --clicks out/master.wav stems/*.wav` (a jump > 0.3 that dwarfs every other jump within ±1 ms; drum transients don't qualify). `--selftest` proves the detectors can fail | 0 candidates; for a new detector, inject a step and watch it go red |
| Format parity | PSNR on stills vs frozen reference, plus one known-different negative control | `inf` / ~15 dB control |
| Container | `ffprobe` frames, fps, duration, streams | frames = ⌈duration·fps⌉, both streams present |
| Claims | grep the script, timeline and captions against the claims list from §0 | Every sentence maps to a shipped feature |

An AI audio judge (Gemini flash via `scripts/ask.py <model> "<question>" file.wav`) is useful for
"does this sound produced / is the VO intelligible". Its **timestamps and click reports are not
reliable**, especially after a leading question. Confirm every claim numerically before acting.

## 7. Working loop and delegation

- Delegate implementation rounds (audio engine, scene code, vertical layouts) to the build-tier coder
  with self-contained prompts: the SPEC, the files to own, and exact deliverables. Delegated coders
  often **cannot launch Chromium** in their sandbox, so the orchestrator renders the stills and
  reviews them, then feeds back concrete notes ("scene 06 headline clips at x > 1008 at t=33.1").
- A round is: spec delta → code → stills + audio QC → notes. Three or four rounds got to agency
  polish. Dispatch fresh rather than resuming long threads.

## 8. Delivery

- Deliver the 16:9 1080p60 MP4, the 9:16 1080×1920 MP4 and the master WAV, plus a **zip of the
  source** (`site/`, `render/`, SPEC.md, package.json). Put all of it in a durable folder (e.g.
  `~/Movies/<Product> Film/`), **never only in a session scratchpad**, which the OS clears.
- Optionally publish the live HTML version as a private artifact: strip the doctype, html, head and
  body wrappers and exclude test and debug files.
- Keep superseded cuts in a `superseded/` subfolder rather than deleting them.

## Gotchas (each cost real time)

| Symptom | Cause | Fix |
|---|---|---|
| Browser dies ~30 s into a render, even idle | `chrome-headless-shell` gets killed on this macOS setup | Playwright `channel: 'chromium'` (full Chromium) plus the chunked renderer |
| AAC file peaks at 0.0 dBTP from a −2.5 dBTP master | Encoder inter-sample overshoot from HF content | `lowpass=f=19000:poles=2` before AAC; re-measure the MP4, not the WAV |
| Python reports 0 dBFS / clicks everywhere | `wave` + int32 misreads 24-bit PCM | Decode via `ffmpeg -f f32le` into numpy |
| ebur128 framelog prints nothing | ffmpeg log-level quirks | Compute short-term/true peak in numpy (audio_qc.py) |
| Old CSS after an edit | Browser cache | Cache-bust `film.css?v=N` |
| Ghost outline text looks clipped behind a long headline | Outline sized for short words | Only draw it for ≤12 chars |
| Play button covers the logo on poster frame | Centred overlay | Anchor bottom, responsive `clamp()` size |
| Re-render reuses old chunks | Stale `.ok` markers | `rm -rf out/chunks*` |
| `--resume` continues the wrong delegated thread | Resume targets the newest thread | Dispatch fresh each round |
