#!/usr/bin/env python3
"""What the pitch shift and the echo did, heard: deck A's recording (left channel)
cut into half seconds — the loudest frequency and the level of each — against the
moments the test noted."""
import subprocess, sys
import numpy as np

rec, started, events = sys.argv[1:4]
t0 = float(open(started).read().strip())
marks = []
for line in open(events):
    t, what = line.strip().split(' ', 1)
    if what.startswith('fx '):
        marks.append((float(t) - t0, what[3:]))
rate = 48000
raw = subprocess.run(['ffmpeg', '-v', 'error', '-i', rec, '-ar', str(rate), '-f', 'f32le', '-'],
                     capture_output=True, check=True).stdout
x = np.frombuffer(raw, dtype=np.float32).reshape(-1, 2)[:, 0]
half = rate // 2
print(f"{'t':>5}  {'Hz':>6}  {'dBFS':>6}")
for i in range(len(x) // half):
    seg = x[i * half:(i + 1) * half]
    rms = float(np.sqrt(np.mean(seg * seg)) + 1e-12)
    spec = np.abs(np.fft.rfft(seg * np.hanning(len(seg))))
    hz = float(np.argmax(spec) * rate / len(seg))
    t = i * 0.5
    said = [m for (mt, m) in marks if t <= mt < t + 0.5]
    print(f"{t:5.1f}  {hz:6.1f}  {20*np.log10(rms):6.1f}  {'  <- ' + ', '.join(said) if said else ''}")
