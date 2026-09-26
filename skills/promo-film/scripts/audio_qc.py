#!/usr/bin/env python3
"""Loudness / true-peak / click QC for a rendered film or its stems. Needs ffmpeg + numpy.

Usage:
  audio_qc.py <file.mp4|wav>                      integrated LUFS, LRA, 4x true peak, max short-term
  audio_qc.py --clicks <stem.wav> [...]           isolated discontinuities (candidate clicks)
  audio_qc.py --selftest                          proves each detector can fail

Exit 1 when a target is missed: integrated outside -14 +/-0.5 LUFS, true peak above -1 dBTP,
or any click candidate. Decodes through ffmpeg f32le on purpose: Python's `wave` misreads 24-bit PCM.
"""
import re, subprocess, sys
import numpy as np

RATE = 48000

def decode(path, rate=RATE):
    raw = subprocess.run(["ffmpeg", "-v", "error", "-i", path, "-f", "f32le", "-acodec", "pcm_f32le",
                          "-ac", "2", "-ar", str(rate), "-"], capture_output=True, check=True).stdout
    return np.frombuffer(raw, dtype=np.float32).reshape(-1, 2)

def ebur128(path):
    log = subprocess.run(["ffmpeg", "-nostats", "-i", path, "-filter_complex", "ebur128=peak=true",
                          "-f", "null", "-"], capture_output=True, text=True).stderr
    summary = log[log.rfind("Summary:"):]
    get = lambda key: float(re.search(rf"{key}:\s+(-?[\d.]+|-inf)", summary).group(1))
    return get("I"), get("LRA")

def true_peak_db(samples):
    # 4x oversampling via FFT zero-padding per channel (BS.1770-style estimate).
    peak = 0.0
    for channel in samples.T:
        n = len(channel)
        spectrum = np.fft.rfft(channel)
        padded = np.zeros(2 * n + 1, dtype=complex)
        padded[: len(spectrum)] = spectrum
        up = np.fft.irfft(padded, 4 * n) * 4
        peak = max(peak, float(np.max(np.abs(up))))
    return 20 * np.log10(max(peak, 1e-12))

def short_term_max(samples, rate=RATE):
    # Unweighted 3 s RMS proxy; use it to compare sections, not as a certified meter.
    energy = np.mean(samples.astype(np.float64) ** 2, axis=1)
    window = 3 * rate
    if len(energy) < window:
        return float("-inf")
    cumulative = np.concatenate([[0], np.cumsum(energy)])
    blocks = (cumulative[window:] - cumulative[:-window])[:: rate // 10] / window
    return -0.691 + 10 * np.log10(max(blocks.max(), 1e-20))

def clicks(samples, threshold=0.3, ratio=2.5, rate=RATE):
    # A click is a sample-to-sample jump > threshold that is also far larger than every other jump
    # within +/-1 ms around it. Drum transients are rough over the whole window, so they don't qualify.
    events = []
    for c, channel in enumerate(samples.T):
        d = np.abs(np.diff(channel.astype(np.float64)))
        for i in np.flatnonzero(d > threshold):
            window = d[max(0, i - 48): i + 48].copy()
            window[max(0, i - 2 - max(0, i - 48)): i + 3 - max(0, i - 48)] = 0
            if d[i] > ratio * max(float(window.max(initial=0)), 0.015):
                if not events or i / rate - events[-1][0] > 0.005:
                    events.append((i / rate, c, float(d[i])))
    return sorted(events)

def selftest():
    t = np.arange(RATE * 4) / RATE
    tone = (0.25 * np.sin(2 * np.pi * 440 * t)).astype(np.float32)
    clean = np.stack([tone, tone], axis=1)
    assert not clicks(clean), "clean tone must not report clicks"
    broken = clean.copy()
    broken[RATE, :] += 0.6
    assert clicks(broken), "an injected step must report a click"
    assert true_peak_db(clean) < -11, "0.25 sine must read about -12 dBTP"
    assert true_peak_db(clean * 3.9) > -0.5, "near-full-scale sine must read near 0 dBTP"
    print("audio_qc selftest: PASS")

def main(argv):
    if not argv:
        sys.exit(__doc__)
    if argv[0] == "--selftest":
        return selftest()
    if argv[0] == "--clicks":
        bad = 0
        for path in argv[1:]:
            found = clicks(decode(path))
            bad += len(found)
            print(f"{path}: {len(found)} click candidate(s)")
            for time, channel, jump in found[:20]:
                print(f"  {time:9.5f} s  ch{channel + 1}  jump {jump:.3f}")
        sys.exit(1 if bad else 0)
    path = argv[0]
    samples = decode(path)
    integrated, lra = ebur128(path)
    peak = true_peak_db(samples)
    print(f"integrated {integrated:.1f} LUFS · LRA {lra:.1f} LU · true peak {peak:.2f} dBTP · "
          f"max short-term (proxy) {short_term_max(samples):.1f} · {len(samples) / RATE:.3f} s")
    ok = abs(integrated + 14) <= 0.5 and peak <= -1.0
    print("PASS" if ok else "FAIL (targets: -14 ±0.5 LUFS, ≤ -1 dBTP)")
    sys.exit(0 if ok else 1)

if __name__ == "__main__":
    main(sys.argv[1:])
