# The MilkDrop presets measured: each one on its own (the MilkDrop scene, as the stage
# finished it) and as a background under a few of the scenes' figures (blended the
# stage's way, audit.py), for how good it looks and how intense it is.
#
#   stage_bench --scene milk --milk <preset> --frames 661 --ppm-at 600,660 --ppm <bench>/<n>
#                                                   each preset headless, ten seconds in (a
#                                                   preset starts blank and builds up: a frame
#                                                   two seconds in is mostly black or white)
#   MILK_REAL=<real> MILK_AUDIO=<audio> [MILK_OLD=<table>] python milk.py <dir> <out dir> [notes.json]
#                                                   the same off real records (milk_feed.py,
#                                                   stage_bench --audio --feed --stats): the
#                                                   techno one's frames 900 and 1020, and every
#                                                   frame's light and motion on each record —
#                                                   how much a preset moves with the music
#   MILK_BENCH=<bench> python milk.py <dir> <out dir> [notes.json]
#                                                   the scores, and pictures to look at; <dir>
#                                                   the combination audit's (its figures), and
#                                                   <bench>/names.json the presets by n (the
#                                                   library's order)
#
# On its own: audit.py's measures (blown, black, mud, noise, contrast), and still — a
# preset that hardly moves is a picture, not a show. As a background: the figures
# below put over it (normal and screened) and audit.py's visibility — a preset so
# bright or so busy that a dancer is lost in it scores low here, however fine alone.
# Intensity: contrast, detail, motion, light and colour, ranked across the presets.
#
# Reacting (MILK_REAL): on each record, how well its light and its motion follow the
# kick (the best correlation over a few frames' lag), averaged over the records and
# ranked across the presets. The booth's accents (milk_accent.dart) go easy on the
# ones that react by themselves.
#
# Out: <out>/milk_scores.json (assets/show/milk_scores.json): by preset (its full name)
# characters 0–z: alone, as a background, intensity, reacting — the presets whose render
# came out black, white or frozen left out (not known). "Alone" is kept, not used:
# on the bench it disagrees with the hands' favourites. And <out>/sheets/milk_*.jpg.
import json, os, sys
import numpy as np
from PIL import Image, ImageDraw
from audit import load_raw, fit_size, measure, quality, blend, finish, edges, coverage, smoothstep, SIZE

# The figures put over each preset: one of each kind of figure, as the audit drew them.
FIGURES = ['dance-art.plain', 'dance-art.chrono', 'flock.ink', 'kinetic.raw', 'type3d.raw', 'glide.raw', 'blocks.raw']


def load_fig(src, name):
    base = f'{src}/fig/{name}.0'
    if os.path.exists(base + '.fig') and os.path.exists(base + '.json'):
        return fit_size(load_raw(base + '.fig'), SIZE), json.load(open(base + '.json')), True
    if os.path.exists(base + '.png'):
        im = fit_size(np.asarray(Image.open(base + '.png').convert('RGB'), np.float32) / 255, SIZE)
        return np.dstack([im, np.ones(im.shape[:2], np.float32)]), dict(coverage=2, strength=1, bloom=0, tone=0, vignette=0), False
    return None


CLIPS = ['techno', 'trance', 'pop']


def react_of(stats, kick, start=300):
    """How well a run's light and motion follow the kick: the best correlation over a
    lag of up to four frames."""
    s = np.fromfile(stats, np.float32).reshape(-1, 2)
    k = kick[:len(s)]
    luma, motion = s[start:, 0], s[start:, 1]
    hp = luma - np.convolve(luma, np.ones(15) / 15, 'same')
    best = 0.0
    for lag in range(5):
        kk = k[start:len(s) - lag]
        for x in (motion[lag:], hp[lag:]):
            if x.std() > 1e-6 and kk.std() > 1e-6:
                best = max(best, float(np.corrcoef(kk, x)[0, 1]))
    return best, float(motion.mean())


def main():
    src, out = sys.argv[1], sys.argv[2]
    os.makedirs(f'{out}/sheets', exist_ok=True)
    real = os.environ.get('MILK_REAL')
    kicks = {}
    if real:
        audio = os.environ['MILK_AUDIO']
        kicks = {c: np.fromfile(f'{audio}/{c}/feed.f32', np.float32).reshape(-1, 8)[:, 6] for c in CLIPS}
    bench = real or os.environ.get('MILK_BENCH')
    shots = (900, 1020) if real else (600, 660)
    names = json.load(open(f'{bench}/names.json' if bench else f'{src}/milk/names.json'))
    figs = [(n, f) for n in FIGURES if (f := load_fig(src, n)) is not None]
    alone_fig = {n: (finish(f[0][..., :3], f[1].get('bloom', .5), f[1].get('vignette', .6), f[1].get('tone', 1)) if f[2] else f[0][..., :3]) for n, f in figs}
    efs = {n: edges(a) for n, a in alone_fig.items()}
    rows = {}
    for n, full in names.items():
        fr = []
        if bench:
            for f in shots:
                path = f'{bench}/{n}.{f}.ppm'
                if os.path.exists(path):
                    pic = fit_size(np.asarray(Image.open(path).convert('RGB'), np.float32) / 255, SIZE)
                    fr.append((pic, pic))
        for k in range(0 if bench else 2):
            base = f'{src}/milk/{n}.{k}'
            if os.path.exists(base + '.out') and os.path.exists(base + '.fig'):
                meta = json.load(open(base + '.meta.json')) if os.path.exists(base + '.meta.json') else {}
                if meta.get('crashed'):
                    continue
                fr.append((fit_size(load_raw(base + '.fig'), SIZE)[..., :3], fit_size(load_raw(base + '.out'), SIZE)[..., :3]))
        if not fr:
            continue
        motion = float(np.abs(fr[0][1] - fr[1][1]).mean()) if len(fr) > 1 else 0.0
        reacts, moves = [], []
        for c in kicks:
            path = f'{bench}/{n}.{c}.f32'
            if os.path.exists(path):
                r, mv = react_of(path, kicks[c])
                reacts.append(r)
                moves.append(mv)
        ms = [measure(o, None) for _, o in fr]
        m = {k: float(np.mean([x[k] for x in ms])) if ms[0][k] is not None else None for k in ms[0]}
        # Off real records: the motion frame to frame, all through (not two frames).
        m['motion'] = float(np.mean(moves)) if moves else motion
        m['react'] = float(np.mean(reacts)) if reacts else None
        alone = quality(m) * (0.4 + 0.6 * smoothstep(0.004, 0.02, motion))
        # As a background: each figure over it, normal and screened.
        gq = []
        for fname, (fl, st, native) in figs:
            for mix in (0, 2):
                pic, cov = blend(fl, st.get('coverage', 2), st.get('strength', 1), fr[0][0], 0, mix)
                fin = finish(pic, st.get('bloom', .5), st.get('vignette', .6), st.get('tone', 1)) if native else np.clip(pic, 0, 1)
                gq.append(quality(measure(fin, cov, efs[fname])))
        # A render that is all black, all white or frozen is the bench's failing (a
        # preset that wants the music's own waveform, or time), not the preset's: not
        # known, and said as not known.
        broken = m['dark'] > 0.95 or (m['light'] > 0.92 and m['contrast'] < 0.04) or (moves and np.mean(moves) < 0.0005) or (not moves and motion < 0.002)
        rows[full] = dict(n=n, alone=alone, ground=float(np.mean(gq)), m=m, broken=broken)
    # Intensity: ranked across the presets.
    keys, wts = ['contrast', 'detail', 'motion', 'light', 'colour'], [0.3, 0.25, 0.2, 0.15, 0.1]
    order = [p for p in rows if not rows[p]['broken']]
    def rank(v):
        v = np.asarray(v, float)
        return np.argsort(np.argsort(v)) / max(1, len(v) - 1)
    raw = sum(w * rank([rows[p]['m'][k] for p in order]) for k, w in zip(keys, wts))
    for p, v in zip(order, rank(raw)):
        rows[p]['i'] = float(v)
    reacting = [p for p in order if rows[p]['m'].get('react') is not None]
    if reacting:
        for p, v in zip(reacting, rank([rows[p]['m']['react'] for p in reacting])):
            rows[p]['r'] = float(v)
    # How much the ones it could not judge react, ranked among the rest.
    rs = sorted(rows[p]['m']['react'] for p in reacting)
    for p in rows:
        if 'r' not in rows[p] and rows[p]['m'].get('react') is not None and rs:
            rows[p]['r'] = float(np.searchsorted(rs, rows[p]['m']['react']) / max(1, len(rs) - 1))
    for p in rows:
        rows[p].setdefault('i', None)
        rows[p].setdefault('r', None)

    def ch(v):
        return '0123456789abcdefghijklmnopqrstuvwxyz'[int(round(np.clip(v, 0, 1) * 35))]
    # Not known: '_' for each (the app takes it as middling).
    table = dict(version=1, presets={p: ch(r['alone']) + ch(r['ground']) + ch(r['i']) + (ch(r['r']) if r['r'] is not None else '_')
                                     for p, r in sorted(rows.items()) if not r['broken']})
    # MILK_OLD=<table>: a preset this run could not judge (white or black on the one
    # record its stills are from) keeps what an earlier run said of it, and how much
    # it reacts, where that was measured.
    old = os.environ.get('MILK_OLD')
    if old and os.path.exists(old):
        before = json.load(open(old)).get('presets', {})
        for p, r in rows.items():
            if r['broken'] and p in before:
                react = ch(r['r']) if r.get('r') is not None else '_'
                table['presets'][p] = before[p][:3] + react
        table['presets'] = dict(sorted(table['presets'].items()))
    json.dump(table, open(f'{out}/milk_scores.json', 'w'), separators=(',', ':'), ensure_ascii=False)
    json.dump(rows, open(f'{out}/milk_metrics.json', 'w'), ensure_ascii=False)

    def sheet(items, path, cols=6):
        tw, th = 240, 135
        im = Image.new('RGB', (cols * tw, ((len(items) + cols - 1) // cols) * (th + 14)), (24, 24, 28))
        dr = ImageDraw.Draw(im)
        for i, (label, p) in enumerate(items):
            r = rows[p]
            pic = (fit_size(np.asarray(Image.open(f"{bench}/{r['n']}.{shots[0]}.ppm").convert('RGB'), np.float32) / 255, SIZE) if bench
                   else fit_size(load_raw(f"{src}/milk/{r['n']}.0.out"), SIZE)[..., :3])
            x, y = (i % cols) * tw, (i // cols) * (th + 14)
            im.paste(Image.fromarray((np.clip(pic, 0, 1) * 255).astype(np.uint8)).resize((tw, th)), (x, y))
            dr.text((x + 2, y + th), f"{label} {p}"[:40], fill=(220, 220, 220))
        im.save(path, quality=82)
    by_alone = sorted(rows, key=lambda p: rows[p]['alone'])
    sheet([(f"{rows[p]['alone']:.2f}", p) for p in by_alone[:42]], f'{out}/sheets/milk_worst.jpg')
    sheet([(f"{rows[p]['alone']:.2f}", p) for p in by_alone[-42:][::-1]], f'{out}/sheets/milk_best.jpg')
    by_ground = sorted(rows, key=lambda p: rows[p]['ground'])
    sheet([(f"g{rows[p]['ground']:.2f}", p) for p in by_ground[:42]], f'{out}/sheets/milk_ground_worst.jpg')
    by_i = sorted((p for p in rows if not rows[p]['broken']), key=lambda p: rows[p]['i'])
    sheet([(f"i{rows[p]['i']:.2f}", p) for p in by_i[::max(1, len(by_i) // 42)][:42]], f'{out}/sheets/milk_intensity.jpg')
    print('broken renders (not known):', sum(r['broken'] for r in rows.values()))
    if reacting:
        rs = np.array([rows[p]['m']['react'] for p in reacting])
        print('reacting: %d measured, correlation mean %.3f, quartiles %s' % (len(rs), rs.mean(), np.percentile(rs, [25, 50, 75]).round(3)))
        by_r = sorted(reacting, key=lambda p: rows[p]['r'])
        sheet([(f"r{rows[p]['m']['react']:.2f}", p) for p in by_r[:42]], f'{out}/sheets/milk_deaf.jpg')
        sheet([(f"r{rows[p]['m']['react']:.2f}", p) for p in by_r[-42:][::-1]], f'{out}/sheets/milk_reacting.jpg')
    a = np.array([r['alone'] for r in rows.values()]); g = np.array([r['ground'] for r in rows.values()])
    print('presets', len(rows), 'alone mean %.2f under .3: %d' % (a.mean(), (a < 0.3).sum()), 'ground mean %.2f under .3: %d' % (g.mean(), (g < 0.3).sum()))
    fav = sys.argv[3] if len(sys.argv) > 3 else None
    if fav and os.path.exists(fav):
        favs = json.load(open(fav)).get('favourites', [])
        pct = [float((a < rows[f]['alone']).mean()) for f in favs if f in rows]
        print('your favourites: %d scored, alone percentile mean %.2f, min %.2f' % (len(pct), np.mean(pct), min(pct)))
        print('your favourites not known (broken renders):', [f for f in favs if f in rows and rows[f]['broken']])
        its = [rows[f]['i'] for f in favs if f in rows and rows[f]['i'] is not None]
        print('your favourites intensity spread: min %.2f mean %.2f max %.2f' % (min(its), np.mean(its), max(its)))
        rfs = [rows[f]['r'] for f in favs if f in rows and rows[f]['r'] is not None]
        if rfs:
            print('your favourites reacting: mean rank %.2f' % np.mean(rfs))


if __name__ == '__main__':
    main()
