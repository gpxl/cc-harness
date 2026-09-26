#!/usr/bin/env python3
"""Synthesize one voiceover phrase with Gemini TTS and write a WAV.

Usage: tts.py <model> <voice> <out.wav> "<text>"
  e.g. tts.py gemini-3.1-flash-tts-preview Kore vo/01.wav \
       "Say in a low, warm, intimate, confident and unhurried voice, like a premium product film narrator: You hear something."

Reads GOOGLE_API_KEY from the environment and never prints it. Retries 429/500/503 with backoff.
The API returns either a RIFF WAV or raw 16-bit little-endian PCM (audio/L16;rate=24000); both are
written out as a mono WAV at the rate the response declares.
"""
import base64, json, os, re, sys, time, urllib.error, urllib.request, wave

def main():
    if len(sys.argv) != 5:
        sys.exit(__doc__)
    model, voice, out, text = sys.argv[1:]
    key = os.environ.get("GOOGLE_API_KEY")
    if not key:
        sys.exit("GOOGLE_API_KEY is not set")
    body = json.dumps({
        "contents": [{"parts": [{"text": text}]}],
        "generationConfig": {
            "responseModalities": ["AUDIO"],
            "speechConfig": {"voiceConfig": {"prebuiltVoiceConfig": {"voiceName": voice}}},
        },
    }).encode()
    url = f"https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent"
    for attempt in range(6):
        request = urllib.request.Request(url, body, {"Content-Type": "application/json", "x-goog-api-key": key})
        try:
            with urllib.request.urlopen(request, timeout=180) as response:
                payload = json.load(response)
            break
        except urllib.error.HTTPError as error:
            detail = error.read().decode(errors="replace")[:400]
            if error.code in (429, 500, 503) and attempt < 5:
                wait = 2 ** attempt * 3
                print(f"HTTP {error.code}; retry in {wait}s", file=sys.stderr)
                time.sleep(wait)
                continue
            sys.exit(f"HTTP {error.code}: {detail}")
    try:
        part = payload["candidates"][0]["content"]["parts"][0]["inlineData"]
    except (KeyError, IndexError):
        sys.exit("No audio in response: " + json.dumps(payload)[:600])
    data = base64.b64decode(part["data"])
    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
    if data[:4] == b"RIFF":
        with open(out, "wb") as handle:
            handle.write(data)
    else:
        match = re.search(r"rate=(\d+)", part.get("mimeType", ""))
        rate = int(match.group(1)) if match else 24000
        with wave.open(out, "wb") as handle:
            handle.setnchannels(1)
            handle.setsampwidth(2)
            handle.setframerate(rate)
            handle.writeframes(data)
    print(f"wrote {out}")

if __name__ == "__main__":
    main()
