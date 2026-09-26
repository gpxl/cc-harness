#!/usr/bin/env python3
"""Ask a Gemini model a question about local media files (audio, images, short video).

Usage: ask.py <model> "<question>" file [file ...]

Use it as a second pair of ears ("is the VO intelligible over the drop?"). Treat its timestamps
and click reports as hypotheses: verify numerically before acting, and avoid leading questions.
Reads GOOGLE_API_KEY from the environment and never prints it. Retries 429/500/503 with backoff.
"""
import base64, json, mimetypes, os, sys, time, urllib.error, urllib.request

def main():
    if len(sys.argv) < 4:
        sys.exit(__doc__)
    model, question, *files = sys.argv[1:]
    key = os.environ.get("GOOGLE_API_KEY")
    if not key:
        sys.exit("GOOGLE_API_KEY is not set")
    parts = [{"text": question}]
    for path in files:
        mime = mimetypes.guess_type(path)[0] or "application/octet-stream"
        with open(path, "rb") as handle:
            parts.append({"inline_data": {"mime_type": mime, "data": base64.b64encode(handle.read()).decode()}})
    body = json.dumps({"contents": [{"parts": parts}]}).encode()
    url = f"https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent"
    for attempt in range(6):
        request = urllib.request.Request(url, body, {"Content-Type": "application/json", "x-goog-api-key": key})
        try:
            with urllib.request.urlopen(request, timeout=300) as response:
                payload = json.load(response)
            break
        except urllib.error.HTTPError as error:
            detail = error.read().decode(errors="replace")[:400]
            if error.code in (429, 500, 503) and attempt < 5:
                time.sleep(2 ** attempt * 3)
                continue
            sys.exit(f"HTTP {error.code}: {detail}")
    try:
        print("".join(part.get("text", "") for part in payload["candidates"][0]["content"]["parts"]))
    except (KeyError, IndexError):
        sys.exit("No text in response: " + json.dumps(payload)[:600])

if __name__ == "__main__":
    main()
