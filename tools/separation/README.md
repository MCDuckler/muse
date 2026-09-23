# How good is the separation?

The booth plays parts of records — drums, the music under them, the record with the
voice taken out. Two implementations make them: `server/muse/stems.py` and
`app/lib/src/worker/separate.dart`, which are one algorithm written twice.

This measures them, so "it sucks" can be a number instead of an opinion.

## What it does

MUSDB18 publishes freely distributable 7-second clips of 144 real tracks **with their
true stems**. So what we produce can be compared with what it should have been. The
score is SDR — the ratio of the wanted signal's energy to the energy of the error, in
dB, higher better.

The number that matters is not the SDR itself but **the improvement over doing
nothing**: handing back the untouched mix and calling it an instrumental already
scores several dB, because most of a record is not the voice.

> Note: this is the plain energy-ratio SDR, not `museval`'s BSS Eval v4 that the
> papers quote. BSS Eval allows a distortion filter before scoring and reads a little
> higher. Right for comparing our own options with each other; only roughly
> comparable with a published figure.

## Running it

    python -m venv .venv && .venv/bin/pip install -r requirements.txt
    .venv/bin/python run_current.py

The first run downloads the MUSDB18 sample set (~140 MB) to `~/MUSDB18`.

**Do not run this on the server.** See below.

## The baseline, measured 2026-09-23

What we ship today (mid/side vocal removal + HPSS), 24 tracks:

| part        | our SDR   | doing nothing | we add    | worse than nothing |
|-------------|-----------|---------------|-----------|--------------------|
| instrumental| 5.60 dB   | 4.96 dB       | **+0.64** | **5 of 24**        |
| drums       | −3.31 dB  | −6.45 dB      | +3.15     | 2 of 24            |

Read plainly: **the "no vox" part is not doing anything.** Six tenths of a decibel is
inside the noise, and on a fifth of records it is actively worse than not trying —
those will be the panned, doubled and reverbed vocals that mid/side cannot touch.
The drums split is real work but the output still has more error in it than signal.

Published figures for Demucs-class models are around 8–9 dB on these sources. That
gap is not a tuning problem; it is the gap between a trick and a model.

Speed, for whatever replaces it to be judged against: **21.6× realtime** on 4 cores.

## Why not on the server

The box is 8 GB and it is *production* — it serves the music. Loading an htdemucs
ONNX export there was killed by the kernel three times, the last at 5.8 GB resident:

    Out of memory: Killed process 2920292 (python) ... anon-rss:5868924kB

Nothing was lost that time, but the kernel picks its victim by score, and next time it
could pick postgres. Model work belongs on a desk.
