#!/usr/bin/env python3
"""Makes rb_colour.lut: rekordbox's RGB and BLUE colours as a function of its own three
band heights, measured on a real rekordbox stick (rb.rs `colour_of`).

    python3 -I make_rb_colour.py /path/to/stick-or-backup/PIONEER rb_colour.lut

Every analysed record's .EXT (PWV3 blue, PWV5 colour) and .2EX (PWV7 bands) are read,
column by column (150 a second), and each 16x16x16 cell of (lows, mids, highs) keeps the
mean red, green, blue (0-7) and whiteness (0-7) rekordbox gave its columns, x32, as four
bytes; cells with under 20 columns take their nearest filled cell's. 2026-11-18 from the
HIHIHI stick: 75 records, 2.4 million columns, held-out error ~0.8 of 7 a channel.
"""
import glob
import os
import struct
import sys

import numpy as np


def tags(path):
    b = open(path, 'rb').read()
    at = struct.unpack('>I', b[4:8])[0]
    out = {}
    while at + 12 <= len(b):
        tag = b[at:at + 4].decode('latin1')
        total = struct.unpack('>I', b[at + 8:at + 12])[0]
        if total < 12:
            break
        out.setdefault(tag, []).append(b[at:at + total])
        at += total
    return out


def body(s):
    return s[struct.unpack('>I', s[4:8])[0]:]


def main(pioneer, out, q=16):
    bands, targets = [], []
    for d in sorted(glob.glob(os.path.join(pioneer, 'USBANLZ', '*', '*'))):
        try:
            e = tags(os.path.join(d, 'ANLZ0000.EXT'))
            x = tags(os.path.join(d, 'ANLZ0000.2EX'))
            w3 = np.frombuffer(body(e['PWV3'][0]), np.uint8)
            w5 = np.frombuffer(body(e['PWV5'][0]), '>u2')
            w7 = np.frombuffer(body(x['PWV7'][0]), np.uint8).reshape(-1, 3)
        except (OSError, KeyError):
            continue
        n = min(len(w3), len(w5), len(w7))
        bands.append(w7[:n].astype(float))
        targets.append(np.stack([(w5 >> 13) & 7, (w5 >> 10) & 7, (w5 >> 7) & 7, w3 >> 5], 1)[:n].astype(float))
    B, T = np.concatenate(bands), np.concatenate(targets)
    idx = np.clip((B / 128 * q).astype(int), 0, q - 1)
    cell = idx[:, 0] * q * q + idx[:, 1] * q + idx[:, 2]
    cnt = np.bincount(cell, None, q ** 3)
    lut = np.stack([np.bincount(cell, T[:, j], q ** 3) / np.maximum(cnt, 1) for j in range(4)], 1)
    have = cnt >= 20
    g = np.stack(np.meshgrid(*[np.arange(q)] * 3, indexing='ij'), -1).reshape(-1, 3)
    src = np.where(have)[0]
    for c in np.where(~have)[0]:
        lut[c] = lut[src[np.argmin(np.abs(g[src] - g[c]).sum(1))]]
    np.clip(np.round(lut * 32), 0, 255).astype(np.uint8).tofile(out)
    print(f'{len(B)} columns, {have.sum()} of {q ** 3} cells filled -> {out}')


if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2])
