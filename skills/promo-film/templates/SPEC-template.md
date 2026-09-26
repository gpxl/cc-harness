# <Product> — launch film (pure JS) — production spec

Goal: a ~<N> s, 1920×1080, 60 fps, **pure JavaScript** animated product film (no video files, no
frameworks, no CDN) with a procedurally synthesized soundtrack and a pre-recorded TTS voiceover, plus
a native 1080×1920 vertical cut. Quality bar: a professional agency launch film. Every frame should
be screenshot-worthy, and every transition should be motivated by the music.

Everything is a **pure function of time `t`**, so the same code drives live browser playback and a
deterministic frame-by-frame render to MP4.

## The product — only claim these (owner-confirmed on <date>)

1. <shipped feature, in user words>
2. …

Never show: <unshipped features>, real artist/brand/service names or logos, <banned UI verbs>.
Demo content is fictional: <track / customer name>.

## Brand (from the product's design system — use exactly)

| Token | Value |
|---|---|
| accent | `#……` |
| background ink | `#……` |
| text / secondary | `#……` / `#……` |
| semantic colours (record, done, category colours) | … |
| display font | <family + weights, local .ttf in site/assets/fonts> |
| mono font | <family> for HUD, timecode and filenames |
| logo | site/assets/brand/… |

Visual motif: <one sentence, e.g. "the icon is pixel art → pixel particles lit with modern bloom">.

## Files

```
site/  index.html · css/film.css · js/timeline.js (AUTHORITATIVE) · js/audio/ · js/visual/ · js/main.js · assets/{fonts,brand,vo}/
render/  render.mjs · chunked.sh        (copied from the promo-film skill)
```

## Audio ↔ visual contract

`js/audio/index.js`:
- `buildSoundtrack({ timeline, baseUrl, onProgress }) → { sampleRate, duration, stems:{drums,bass,vocals,other,sfx,vo}, master, features:{ fps:120, rms:{…}, low, mid, high, kicks, snares, audible:{…} } }`. Offline, 48 kHz, seeded, deterministic.
- `playLive(ctx, soundtrack, startAt, offset) → { stop() }` plays `master`.
- `encodeWav(buffer) → ArrayBuffer`.

Render mode, `?render=1[&format=vertical]`: `window.__film = { ready, duration, fps, format, renderFrame(t), getMasterWav() }`.

## Timeline & story

<BPM>, <key>, `BAR = 240/BPM`, duration `<expr>`. Bars are 0-based and timeline.js wins over this table.

| # | Bars | Scene | Voiceover | Music / audio | Visual |
|---|---|---|---|---|---|
| 1 | 0–4 | HOOK | "…" | intro, filtered "other room" | … |
| 2 | … | ACTION | "…" | filter snaps open on the key action | … |
| 3 | … | BUILD | "…" | roll, riser, silence gap | … |
| 4 | … | DROP / REVEAL | — | full drop + impact | … |
| … | … | FEATURE beats | one feature per 1–2 bars | demonstrate it in the mix | … |
| n | …–end | LOCKUP | "<Product>. <tagline>" | final hit + tail | logo assembles, CTA |

## Soundtrack targets

−14 LUFS integrated · true peak ≤ −1 dBTP (−2.5 before AAC) · LRA ~6–7 · VO ducking −6…−8 dB with a
2–4 kHz dip · 20 ms ramps on every solo or mute · no clicks (audio_qc.py).

## Visual rules

- Motion: expo/quint easing and spring pops. Anything that lands, lands on a beat, with 40–70 ms
  stagger. Transitions are motivated (whip, flash on drop, glitch cut). No hard cut without a hit.
- Type: one headline on screen at a time, title-safe ±80 px (landscape). Wide-tracked uppercase
  kickers in the accent colour.
- HUD chrome at ~30% opacity: timecode, bar·beat, scene label and progress line. It fades for the
  lockup.
- UI mocks are stylized dark-glass windows that read as the real product, not screenshots.
- Vertical: safe zone x∈[72,1008], y∈[220,1620]. Burned-in captions from VO at baseline ≤ 1560. Stack
  what was side-by-side.

## Definition of done

- `python3 -m http.server -d site` → preloader → Play → film in sync, with no console errors and no
  network requests beyond the local server.
- `bash render/chunked.sh` and `bash render/chunked.sh vertical` produce both MP4s. audio_qc.py
  passes on both, ffprobe shows the expected frames and fps, and the stills contact sheets are
  reviewed.
- Every VO line and on-screen claim maps to the claims list above.
