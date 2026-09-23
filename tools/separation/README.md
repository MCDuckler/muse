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
    .venv/bin/python run_current.py          # the first 24 tracks: all training tracks
    .venv/bin/python run_current.py test     # 24 held-out tracks

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

## What replaced it, measured 2026-09-23

The desktop app now takes records apart with a trained network — **SCNet Small**
(starrytong's, trained by ZFTurbo on MUSDB18, MIT) — run by ONNX Runtime in a program
of its own, `wetowl-separate` (`app/bin/wetowl_separate.dart`). The arithmetic above
is still what runs where the network cannot: a phone, a browser, the server, a desk
whose separator could not start.

Scored on the 24 **held-out** tracks, which is the fair test: every candidate network
learned from the training ones and scores higher there. Measured through the program
itself (`run_worker.py test`), so it is the shipped code, not the Python it came from:

| part         | the arithmetic | the separator | through the booth's AAC | doing nothing |
|--------------|----------------|---------------|-------------------------|---------------|
| instrumental | 5.54 dB        | **13.79 dB**  | 13.00 dB                | 3.53 dB       |
| drums        | −1.11 dB       | **8.83 dB**   | 8.44 dB                 | −3.93 dB      |
| music        | 1.71 dB        | **13.32 dB**  | 13.01 dB                | 3.93 dB       |
| worse than doing nothing | 4, 2 and 18 of 24 | **0 of 24, every part** | 0 | — |

"Music" is everything but the drums, as the booth means it — and the arithmetic's was
worse than handing back the untouched record on three quarters of them.

Also measured and not chosen: htdemucs (12.71 / 9.26 / 13.39 — as good, three times
the size, more memory), htdemucs_ft (no better than htdemucs at four times the work),
UVR's MDX-Net Inst HQ3 (14.57 instrumental, but nothing else and no licence on the
weights), Mel-Band RoFormer (no licence on the weights; not run).

**Speed.** A four minute record, on an Intel Core Ultra 7 155H (16 cores, 22
threads), eight threads: about 100 seconds, against 6 for the arithmetic. It is
minutes, not seconds — fine for a booth that looks three records ahead. 1.5–2.5 GB
while it runs, flat from start to finish.

**Two things it took to get there, both measured, both in the code with why:**
the network's own FFTs exported as ONNX DFT operators were 56 % of the time, so
`dftpatch.py` turns them into matrix multiplies (the same numbers to 2e-6) — 172 s
became 85 s; and with ONNX Runtime's memory arena on, or glibc keeping a heap per
thread, memory went to 5–7 GB for no gain in speed.

### The files it fetches

The program is in the desktop download; the network (51 MB) and ONNX Runtime (16 MB
on Windows, 29 MB on Linux) are not — the app fetches them from the house the first
time it takes a record apart, and checks each against a hash it carries
(`app/lib/src/worker/separation_kit.dart`). They are made here and published with:

    tools/separation/make_kit.sh      # exports the network, fetches the runtime, checks every hash
    deploy/publish.sh models          # puts them on the box, under /models/

`make_kit.sh` builds everything from its public source and refuses to go on if any
of it is not the bytes the app expects; the export is reproducible (see
`export_scnet.py` for the one thing that made it not). A changed network is a new
name — `scnet-small-v2.onnx` — never new bytes under the old one.

### Checking the program against the Python

    kit/work/venv/bin/python check_worker.py <a record> [seconds]

runs the same record through ZFTurbo's own demix and through the program and says
how far apart they are. Last run: 4.5e-7 at worst, 124 dB agreement or better — the
same sound to within float rounding. Worth running after touching
`app/lib/src/separation/`.

### The C API table

`app/lib/src/separation/ort.dart` calls ONNX Runtime through its table of function
pointers, by position. The positions were read out of 1.30's `onnxruntime_c_api.h`
by counting the members of `struct OrtApi`; the table only ever grows at the end, so
they hold for every later version. A function not in the list there needs its
position read the same way.
