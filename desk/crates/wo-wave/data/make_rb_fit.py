#!/usr/bin/env python3
"""Makes ../src/rb_fit.rs: the curves the Desk makes rekordbox's waveform columns on,
fitted to rekordbox's own columns for the same audio (rb.rs `emulate`).

    cargo run --release -p wo-deskcore --example rb_fit_dump -- DUMP_DIR   # stick plugged in
    python3 -I make_rb_fit.py DUMP_DIR ../src/rb_fit.rs

Each band: the Desk's band's peak (lows, mids, highs) held with a release a column; RGB's
and BLUE's heights: the whole signal's peak. Its log in 64 steps between its 0.5 and 99.9
percentiles; each step the median of rekordbox's value there, made monotone. No record is
scaled to its own loudest: fitted that way, the error was larger (rekordbox's heights
follow the absolute level). 2026-11-19 from the HIHIHI stick: 75 records, 2.4 M columns;
mean error lows 4.5, mids 6.0, highs 4.2 of 127, RGB height 1.2 and BLUE 0.65 of 31.
"""
import os
import sys

import numpy as np

F = 26
NAMES = [f'{c}{m}' for c in ['40', '80', '160', '315', '630', '1k25', '2k5', '5k', '10k', 'all'] for m in ['p', 'r']] + ['dlp', 'dlr', 'dmp', 'dmr', 'dhp', 'dhr']
SPECS = [('LOW', 'dlp', 'bands', 0, 0.95), ('MID', 'dmp', 'bands', 1, 0.92), ('HIGH', 'dhp', 'bands', 2, 0.88), ('HEIGHT', 'allp', 'h5', None, 0.0), ('BLUE', 'allp', 'h3', None, 0.0)]
NB = 64


def tracks(d):
    for line in open(os.path.join(d, 'index.tsv')):
        if not line.strip():
            continue
        tid = line.split('\t')[0]
        f = np.fromfile(os.path.join(d, tid + '.f32'), '<f4').reshape(-1, F)
        rb = np.fromfile(os.path.join(d, tid + '.rb'), np.uint8).reshape(-1, 6)
        pw5 = (rb[:, 3].astype(np.uint16) << 8) | rb[:, 4]
        n = min(len(f), len(rb))
        yield dict(f=f[:n], bands=rb[:n, :3].astype(float), h5=((pw5 >> 2) & 31)[:n].astype(float), h3=(rb[:n, 5] & 31).astype(float))


def release(x, r):
    if r <= 0:
        return x
    y = np.empty_like(x)
    m = 0.0
    for i, v in enumerate(x):
        m = max(v, m * r)
        y[i] = m
    return y


def main(d, out):
    T = list(tracks(d))
    lines = [f"//! rekordbox's curves, fitted (data/make_rb_fit.py); generated: do not edit by hand.\n//! From {len(T)} records, {sum(len(t['f']) for t in T)} columns.\nuse super::Curve;\n"]
    for name, fn, tgt, k, r in SPECS:
        j = NAMES.index(fn)
        Z = np.concatenate([release(t['f'][:, j].astype(float), r) for t in T])
        Y = np.concatenate([t[tgt][:, k] if k is not None else t[tgt] for t in T])
        lz = np.log(np.maximum(Z, 1e-5))
        lo, hi = np.percentile(lz, [0.5, 99.9])
        pos = (lz - lo) / (hi - lo) * NB
        b = np.clip(pos.astype(int), 0, NB - 1)
        lut = np.array([np.median(Y[b == i]) if np.any(b == i) else np.nan for i in range(NB)])
        idx = np.arange(NB)
        m = ~np.isnan(lut)
        lut = np.maximum.accumulate(np.interp(idx, idx[m], lut[m]))
        p = np.clip(pos - 0.5, 0, NB - 1)
        i0 = np.floor(p).astype(int)
        i1 = np.minimum(i0 + 1, NB - 1)
        fr = p - i0
        mae = np.abs(np.round(lut[i0] * (1 - fr) + lut[i1] * fr) - Y).mean()
        print(f'{name}: {fn} release {r}: mean error {mae:.2f}')
        lines.append(f"/// {fn}, release {r}: mean error {mae:.2f}\npub(crate) const {name}: Curve = Curve {{ release: {r:.2f}, lo: {lo:.5f}, hi: {hi:.5f}, at: [{', '.join(str(int(v)) for v in np.round(lut))}] }};\n")
    open(out, 'w').write('\n'.join(lines))


if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2])
