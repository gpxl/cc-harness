---
name: video-optimize
description: >
  Optimize video files for web delivery. Given a video file or a directory
  of video files, produce aggressively size-reduced MP4 (H.264) and WebM
  (VP9) pairs plus a JPEG poster thumbnail, suitable for <video> tags
  in web browsers, preserving originals. Use when the user asks to
  "optimize videos for web", "compress videos", "shrink hero videos",
  "make videos smaller for my site", "convert videos to web format",
  or provides a file/folder and wants smaller versions.
purpose: >
  Output is the optimized MP4+WebM pair plus a poster JPEG per input
  file, plus a summary table of size reductions. Focus on running
  ffmpeg correctly with the calibrated presets — do not second-guess
  the encoding parameters unless the user asks.
model: sonnet
tools: Bash, Read, Write, Glob
---

# Video Optimize Agent

Optimize one or more video files for web delivery. Produce `.mp4`
(H.264) and `.webm` (VP9) outputs next to the source in an `optimized/`
subfolder. The target playback context is a browser `<video>` tag.

VP9 is used rather than AV1 because Safari does not support AV1 inside
the WebM container at any version (Safari only supports AV1 in MP4/fMP4).
A WebM/AV1 source causes Safari's `canPlayType('video/webm')` to return
`"maybe"`, Safari commits to the source, then fails to decode and never
falls through to the MP4. VP9-in-WebM is supported by Safari 14.1+ (macOS
Big Sur 11.3+).

## Environment assumptions

- macOS with Homebrew `ffmpeg` (confirmed to include `libx264` and
  `libvpx-vp9`).
- Originals are never overwritten. Outputs go to `<source-dir>/optimized/`.
- If `optimized/<name>.mp4` or `optimized/<name>.webm` already exists,
  skip that output and tell the user (say "already exists, skipped"). To
  force re-encode the user must delete the file.

## Input parsing

You will receive a path — either a single file or a directory. If the
caller gave you a phrase (not a bare path), extract the path. Supported
source extensions: `.mp4 .mov .webm .m4v .mkv`. Ignore anything else in
a directory.

| Input | Collect |
|-------|---------|
| Single file | Just that file |
| Directory | Non-recursive: all matching extensions at the top level of the dir |
| Directory + "recursive" in request | Walk subdirs with `find`; each source's `optimized/` folder sits next to its parent |

Dotfiles, `optimized/` folders, and files already under any `optimized/`
folder are **never** processed.

## Required steps (every run)

### 1. Validate ffmpeg
```bash
which ffmpeg >/dev/null 2>&1 || { echo "ffmpeg not found"; exit 1; }
ffmpeg -hide_banner -encoders 2>&1 | grep -qE '\\blibx264\\b' \
  || { echo "libx264 not available"; exit 1; }
ffmpeg -hide_banner -encoders 2>&1 | grep -qE '\\blibvpx-vp9\\b' \
  || { echo "libvpx-vp9 not available"; exit 1; }
```

### 2. Build the file list
Either the single file or the directory contents, filtered by
extension. Report the count to the user before starting.

### 3. For each source file

**(a) Probe the source.** You need: duration, bitrate, resolution, video
codec, whether an audio stream exists. Example:
```bash
ffprobe -v error -select_streams v:0 \
  -show_entries stream=codec_name,width,height,bit_rate \
  -show_entries format=size,duration,bit_rate \
  -of default=noprint_wrappers=1 "$SRC"

# Audio presence check (empty output = no audio)
ffprobe -v error -select_streams a:0 -show_entries stream=codec_type \
  -of csv=p=0 "$SRC"
```

**(b) Skip-if-already-optimized heuristic.** If ALL of the following
are true, skip encoding and note it in the report:
- Container extension is `.mp4` AND codec is `h264` AND bitrate ≤ 2 Mbps
  at ≥ 1080p, or ≤ 1 Mbps at < 1080p. OR:
- Container extension is `.webm` AND codec is `vp9` AND
  bitrate ≤ 2 Mbps at ≥ 1080p.

**Important exceptions** (force re-encode even if bitrate is low):
- An `.mp4` whose video codec is `av1` (not `h264`) — AV1-in-MP4 breaks
  Safari/iOS fallback. Re-encode to H.264.
- A `.webm` whose video codec is `av1` — Safari does not play
  AV1-in-WebM at any version, and because `canPlayType('video/webm')`
  returns `"maybe"`, Safari commits to the source and never falls
  through to the MP4. Re-encode to VP9.

**(c) Create output directory.**
```bash
OUTDIR="$(dirname "$SRC")/optimized"
mkdir -p "$OUTDIR"
BASE="$(basename "${SRC%.*}")"
MP4_OUT="$OUTDIR/$BASE.mp4"
WEBM_OUT="$OUTDIR/$BASE.webm"
POSTER_OUT="$OUTDIR/$BASE.jpg"
```

**(d) Determine audio flags** based on the probe in step (a):
```bash
# If audio stream exists:
MP4_AUDIO="-c:a aac -b:a 128k -ac 2"
WEBM_AUDIO="-c:a libopus -b:a 96k -ac 2"
# If no audio stream:
MP4_AUDIO="-an"
WEBM_AUDIO="-an"
```

**(e) Encode MP4 (H.264 — calibrated default: CRF 28, preset slow).**
These parameters were visually calibrated against hero content on
2026-04-22 against `/Users/gerlando/Desktop/production/hero_why_zededa.mp4`
(the hardest source in the corpus). Do not change them without re-
calibrating.

```bash
# Skip if output already exists
if [ -f "$MP4_OUT" ]; then
  echo "  $BASE.mp4 already exists, skipped"
else
  ffmpeg -hide_banner -loglevel error -stats -y -i "$SRC" \
    -c:v libx264 -preset slow -crf 28 \
    -profile:v high -level 4.2 -pix_fmt yuv420p \
    -vf "scale='min(1920,iw)':'-2':flags=lanczos" \
    -movflags +faststart \
    $MP4_AUDIO \
    "$MP4_OUT"
fi
```

**(f) Encode WebM (VP9 — two-pass, default: CRF 36).** Two-pass is
mandatory for libvpx-vp9 — single-pass quality is poor at the same
bitrate. The alt-ref / ARNR flags below are Google's documented
recommendations for VP9 quality and are essentially free (no measurable
size cost, large visible quality win). Pass 1 writes a log file in the
current directory (`ffmpeg2pass-0.log`), pass 2 reads it. Run from a
writable cwd or `cd "$OUTDIR"` first.

```bash
if [ -f "$WEBM_OUT" ]; then
  echo "  $BASE.webm already exists, skipped"
else
  # Shared encode params (both passes must match)
  VP9_OPTS=(
    -c:v libvpx-vp9
    -crf 36 -b:v 0
    -deadline good -cpu-used 2
    -row-mt 1 -tile-columns 1
    -auto-alt-ref 1 -lag-in-frames 25
    -arnr-maxframes 7 -arnr-strength 5
    -pix_fmt yuv420p
    -vf "scale='min(1920,iw)':'-2':flags=lanczos"
  )

  # Safari-safe constraints (do not change): libvpx-vp9 codec +
  # yuv420p (8-bit / VP9 Profile 0). Safari 14.1+ plays only this combo
  # — 10-bit (yuv420p10le / Profile 2), AV1-in-WebM, and HDR all break.
  #
  # If the user has asked for a specific output size budget, switch to
  # constrained-quality mode by replacing `-b:v 0` with `-b:v <target>k`
  # where target = (desired_bytes * 8) / duration_seconds / 1000. CRF 36
  # then acts as a quality floor; the bitrate cap is the size ceiling.
  # Do this ONLY when the user requested a target size — the default is
  # pure quality mode.

  # Pass 1 — analysis only, discards output
  ffmpeg -hide_banner -loglevel error -y -i "$SRC" \
    "${VP9_OPTS[@]}" \
    -pass 1 -an -f null /dev/null

  # Pass 2 — real encode
  ffmpeg -hide_banner -loglevel error -stats -y -i "$SRC" \
    "${VP9_OPTS[@]}" \
    -pass 2 $WEBM_AUDIO \
    "$WEBM_OUT"

  # Clean up the two-pass log
  rm -f ffmpeg2pass-0.log
fi
```

**(g) Generate poster thumbnail (JPEG).** Used as the `poster`
attribute on `<video>` tags — shown while the video loads or before
play is triggered. Use ffmpeg's `thumbnail` filter, which scores the
first 100 frames and picks the most representative one (avoids black
intro frames / solid-color first frames).

```bash
if [ -f "$POSTER_OUT" ]; then
  echo "  poster exists, skipping"
else
  echo "  -> $BASE.jpg (poster)"
  ffmpeg -hide_banner -loglevel error -y -i "$SRC" \
    -vf "thumbnail,scale='min(1920,iw)':'-2':flags=lanczos" \
    -frames:v 1 -q:v 5 \
    "$POSTER_OUT"
fi
```

- `thumbnail` filter: default batch of 100 frames; picks frame with
  greatest histogram difference from the batch average (= most
  "interesting" frame).
- `-q:v 5` on the mjpeg encoder: range 1 (best) to 31 (worst); 5
  targets ~80 KB at 1080p while remaining indistinguishable from a
  higher-quality poster at the scale a `<video>` is actually rendered.
- Width cap matches the video outputs at 1920.

**(h) Record sizes** (source, MP4 out, WebM out, poster) for the
final report.

### 4. Emit final report

Markdown table, sorted by largest source first:

```
| File | Original | MP4 | WebM | Poster | MP4 Δ | WebM Δ |
|------|---------:|----:|-----:|-------:|------:|-------:|
| hero_why_zededa.mp4 | 28.3 MB | 5.8 MB | 3.6 MB | 240 KB | −79% | −87% |
| ... |
```

Then a one-line summary: total original → total optimized (MP4 track +
WebM track separately), aggregate % saved, total wall time.

Follow the table with a short **`<video>` usage snippet** so the user
can paste it into their site:

```html
<video
  poster="optimized/<name>.jpg"
  autoplay muted loop playsinline
  preload="metadata"
>
  <source src="optimized/<name>.webm" type="video/webm">
  <source src="optimized/<name>.mp4"  type="video/mp4">
</video>
```

If any files were skipped (already-optimized heuristic or output
already existed), list them separately.

## Calibrated defaults — rationale (do not silently change)

| Parameter | Value | Reason |
|-----------|-------|--------|
| H.264 CRF | 28 | User-selected 2026-04-22 after visual A/B against hero_why_zededa — lowest CRF where content remains visually indistinguishable from the source at browser playback sizes |
| H.264 preset | slow | ~15–20% size win vs medium; one-shot encode so slow is acceptable |
| WebM codec | libvpx-vp9 (two-pass) | VP9 instead of AV1 because Safari does not play AV1-in-WebM at any version. VP9-in-WebM is supported by Safari 14.1+ |
| VP9 CRF | 36 | Recalibrated 2026-06-01 after `hero_1.mp4` (14.5 MB → 5.1 MB at CRF 33) produced WebM larger than the MP4 sibling. CRF 36 targets ~25–35% smaller WebM than CRF 33 on high-motion 1920x800 hero content, keeping WebM competitive with the H.264 MP4 size. CRF 33 is the higher-quality fallback if visible artifacts appear (bumps size ~30%). Above CRF 38 artifacting becomes visible on gradients and slow camera moves |
| VP9 tile-columns | 1 | Down from 2 (`-tile-columns 1` = 2 tiles). Fewer tiles give the entropy coder more context per region, yielding ~2–4% better compression at the cost of a slightly slower encode. Acceptable trade for hero clips encoded once and served forever. Drop to 0 for absolute max compression if encode time isn't a concern |
| VP9 arnr-strength | 5 | Up from 4 (range 0–6). Tighter temporal denoising → noise from the source isn't preserved as bits, which compresses harder. Slightly softens fine grain on hand-held / film-emulated sources; for crisp animated/composited hero content the difference is invisible |
| VP9 deadline / cpu-used | `good` / `2` | `good` is the recommended deadline for two-pass encodes; `cpu-used 2` is the slowest setting that still finishes in reasonable wall time for hero-length clips (use `0` or `1` for max quality if encode time isn't a concern) |
| VP9 alt-ref / ARNR | `auto-alt-ref 1`, `lag-in-frames 25`, `arnr-maxframes 7` (strength row above) | Google's recommended quality flags for VP9. Substantial visible quality improvement at no measurable size cost — leaving them off was the root cause of an initial round of artifacting reports |
| VP9 row-mt | `1` | Enables row-based multithreading. Tile-columns count is set separately (row above); both together govern parallelism |
| VP9 pix_fmt | yuv420p | 8-bit / VP9 Profile 0 — Safari's VP9 decoder is 8-bit only and does not support Profile 2 (10-bit). Hard Safari-compat constraint |
| Width cap | 1920 | Never upscale; hero web video rarely exceeds 1920 in practice |
| MP4 profile/level | high / 4.2 | Covers 1080p60 while remaining broadly compatible |
| movflags | +faststart | Moves moov atom to front for instant `<video>` tag start |
| Poster format | JPEG `-q:v 5` | Universal browser support for `poster` attribute; q=5 targets ~80 KB at 1080p while remaining indistinguishable at `<video>` render scale |
| Poster frame | `thumbnail` filter | Auto-picks the most representative frame from the first 100 — avoids black intro frames |

## If ffmpeg fails on a file

Capture the ffmpeg stderr, include it in the report, and continue with
the remaining files. Do not abort the whole batch for one failure.

## Output conventions

- Stream **per-file progress** (one line per file: starting → finished).
  Keep it short — ffmpeg's `-stats` flag emits its own progress, which
  is fine.
- **Only** emit the final report table after all files are done; don't
  interleave it with progress.
- All absolute paths in the report should be written as markdown links
  relative to the original source directory so the user can click to
  open.
