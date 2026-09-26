#!/bin/bash
# Render the film in fresh-browser chunks (a long single session crashes headless Chromium),
# then concatenate the video losslessly and mux the master soundtrack once.
set -u
cd "$(dirname "$0")/.."
FORMAT="${1:-landscape}"
if [ "$FORMAT" != landscape ] && [ "$FORMAT" != vertical ]; then
  echo "Usage: $0 [vertical]" >&2; exit 2
fi
if [ "$FORMAT" = vertical ]; then
  CHUNKS=out/chunks-vertical; FINAL=out/film-vertical.mp4
else
  CHUNKS=out/chunks; FINAL=out/film.mp4
fi
D=$(node --input-type=module -e "import { DURATION } from './site/js/timeline.js'; process.stdout.write(String(DURATION))") || exit 1
STEP=5; mkdir -p "$CHUNKS"; : > "$CHUNKS/list.txt"
if [ "$(cat "$CHUNKS/duration.txt" 2>/dev/null)" != "$D" ]; then
  rm -f "$CHUNKS"/*.ok
  printf '%s\n' "$D" > "$CHUNKS/duration.txt"
fi
i=0; t=0
while awk "BEGIN{exit !(($D - $t) > 0.000001)}"; do
  e=$(awk "BEGIN{v=$t+$STEP; if (v>$D) v=$D; printf \"%.9f\", v}")
  f="$CHUNKS/c$(printf %02d $i).mp4"
  ok=0
  for attempt in 1 2 3; do
    if [ -s "$f" ] && [ -f "$f.ok" ]; then ok=1; break; fi
    node render/render.mjs --format "$FORMAT" --from "$t" --to "$e" --out "$f" > "$CHUNKS/c$i.log" 2>&1 && touch "$f.ok" && ok=1 && break
    echo "chunk $i attempt $attempt failed: $(grep -m1 -iE 'error|closed|crash' "$CHUNKS/c$i.log")"
  done
  [ $ok = 1 ] || { echo "CHUNK $i FAILED"; exit 1; }
  echo "file '$(basename "$f")'" >> "$CHUNKS/list.txt"
  echo "chunk $i [$t,$e] done"
  i=$((i+1)); t=$e
done
ffmpeg -hide_banner -loglevel error -y -f concat -safe 0 -i "$CHUNKS/list.txt" -an -c:v copy "$CHUNKS/video.mp4" || exit 1
ffmpeg -hide_banner -loglevel error -y -i "$CHUNKS/video.mp4" -i out/master.wav -map 0:v -map 1:a -c:v copy -af "lowpass=f=19000:poles=2" -c:a aac -b:a 320k -t $D -movflags +faststart "$FINAL" || exit 1
echo DONE
