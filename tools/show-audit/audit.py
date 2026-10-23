# The combination audit: every background, mask and blend of every scene's every style,
# put together offline from the stage's own layers and scored for how it looks.
#
#   wetowl --stage --demo --audit <dir>            the layers (ui/show/stage_audit.dart)
#   python audit.py <dir> <out dir> [--fit]        the scores, and pictures to look at
#
# Each figure (a scene in a style, drawn by itself) and each background was written out
# by the native stage as it draws them (ws_dump): the figure layer before the blend, the
# background, and the finished frame. Here they are blended the stage's way (a port of
# shaders/show/under.frag) and finished its way (stage.cpp's kFinish: bloom, vignette,
# ACES), so 16,000-odd combinations come from a few hundred captures.
#
# What is measured, on the finished picture:
#   visible   how much of the finished picture's structure is the figure's own: its
#             edges (drawn alone) against the picture's, correlated — 1 the figure
#             alone, near 0 the background swamping it
#   blown     how much of the figure is clipped to white
#   empty     nothing there: no figure to speak of and no detail
#   mud       grey: no contrast, no colour, middling light
#   noise     fine detail everywhere (two busy layers on top of each other)
# and, for matching the record's sections, how intense it is: contrast, detail, motion,
# light and colour, ranked across them all.
#
# Out: <out>/combo_scores.json (the app's assets/show/combo_scores.json) and
# <out>/sheets/*.jpg (the worst, the best and a spread, to look at).
import json, math, os, sys, glob
import numpy as np
from PIL import Image, ImageDraw
from scipy.ndimage import gaussian_filter, sobel

GROUNDS = ['black', 'white', 'milk', 'wash', 'pulse.grid', 'pulse.rays', 'pulse.smoke', 'pulse.stars', 'field.drift', 'cover', 'camera']
MASKS = ['none', 'keyhole', 'inverted']
MIXES = ['normal', 'add', 'screen', 'contrast']
# The backgrounds the audit cannot capture without a record's cover or a camera: scored
# as the wash (a cover is a picture of colour; a camera, a dim room).
STAND_IN = {'cover': 'wash', 'camera': 'wash'}
BLOOM_K = 1.3
CAMERA_SCENES = {'echo', 'fold'}


def load_raw(path):
    b = open(path, 'rb').read()
    w, h = np.frombuffer(b[:8], '<i4')
    return np.frombuffer(b[8:], '<f4').reshape(h, w, 4).astype(np.float32)


def lum(c):
    return c[..., 0] * 0.299 + c[..., 1] * 0.587 + c[..., 2] * 0.114


def smoothstep(a, b, x):
    t = np.clip((x - a) / (b - a), 0, 1)
    return t * t * (3 - 2 * t)


def coverage(sa, how):
    """under.frag's: which pixels are the figure, and the figure's light."""
    s = sa[..., :3]
    a = sa[..., 3]
    if how == 2:
        return smoothstep(0.02, 0.3, lum(s)), s
    cov = np.where(a >= 0.98, 1.0, np.clip(a, 0, 1)) if how == 1 else ((a >= 0.98) & (a <= 0.9985)).astype(np.float32)
    return cov, s * cov[..., None]


def blend(sa, how, strength, m, mask, mix):
    """under.frag, on a figure layer [sa] and a background picture [m] (dimmed)."""
    s = sa[..., :3]
    cov, f = coverage(sa, how)
    c = cov[..., None]
    g = m * c if mask == 1 else (m * (1 - c) if mask == 2 else m)
    if mix == 1:
        col = g + f
    elif mix == 2:
        col = 1 - (1 - g) * (1 - np.clip(f, 0, 1))
    elif mix == 3:
        col = np.abs(np.clip(f, 0, 1) - g) * 1.2
    else:
        col = m * (1 - c) + f if mask == 0 else g
    return s + (col - s) * strength, cov


def aces(x):
    a, b, c, d, e = 2.51, 0.03, 2.43, 0.59, 0.14
    return np.clip((x * (a * x + b)) / (x * (c * x + d) + e), 0, 1)


_vig = {}


def finish(light, bloom=0.5, vignette=0.6, tone=1.0):
    """kFinish, near enough: the bloom (the picture halved five times and brought back,
    as a sum of wide blurs), the vignette, ACES."""
    h, w = light.shape[:2]
    blur = sum(gaussian_filter(light, (sg, sg, 0)) for sg in (1.5, 3, 6, 12, 24)) / 5
    lit = light + blur * bloom * BLOOM_K
    key = (h, w)
    if key not in _vig:
        y, x = np.mgrid[0:h, 0:w]
        r = np.sqrt(((x + 0.5) / w - 0.5) ** 2 + ((y + 0.5) / h - 0.5) ** 2) * 1.414
        _vig[key] = smoothstep(0.35, 1.0, r)
    lit = lit * (1 - _vig[key] * 0.75 * vignette)[..., None]
    return np.clip(lit, 0, 1) + (aces(lit * 1.1) - np.clip(lit, 0, 1)) * tone


def edges(p):
    y = lum(p)
    return gaussian_filter(np.hypot(sobel(y, 0), sobel(y, 1)), 1.0)


def measure(p, cov, ef=None):
    """The numbers of one finished picture [p], its figure [cov] (None: the whole of it
    is the figure — a world, a picture with no edge) and the figure's own edges [ef]."""
    y = lum(p)
    gx, gy = sobel(y, 0), sobel(y, 1)
    detail = float(np.mean(np.hypot(gx, gy))) / 4
    fine = float(np.mean(np.abs(y - gaussian_filter(y, 1.5))))
    chroma = p.max(2) - p.min(2)
    out = dict(light=float(y.mean()), contrast=float(y.std()), detail=detail, fine=fine, colour=float(chroma.mean()),
               clip=float((y > 0.97).mean()), dark=float((y < 0.03).mean()))
    if cov is None:
        out.update(area=1.0, legible=None, blown=float((y > 0.97).mean()))
        return out
    area = float((cov > 0.5).mean())
    gc = gaussian_filter(cov, 4)
    band = (gc > 0.15) & (gc < 0.85)
    leg = None
    if band.mean() > 0.002:
        inside = gaussian_filter(p * cov[..., None], (4, 4, 0)) / np.maximum(gc, 1e-3)[..., None]
        outside = gaussian_filter(p * (1 - cov)[..., None], (4, 4, 0)) / np.maximum(1 - gc, 1e-3)[..., None]
        d = inside[band] - outside[band]
        dy = d @ np.array([0.299, 0.587, 0.114])
        leg = float(np.mean(np.sqrt(dy * dy + 0.25 * (d * d).sum(1))))
    fig = cov > 0.5
    out.update(area=area, legible=leg, blown=float((y[fig] > 0.97).mean()) if fig.any() else 0.0)
    vis = None
    if ef is not None and ef.std() > 1e-3:
        ec = gaussian_filter(np.hypot(gx, gy), 1.0)
        if ec.std() > 1e-6:
            vis = float(max(0.0, np.corrcoef(ef.ravel(), ec.ravel())[0, 1]))
    out['visible'] = vis
    return out


def quality(m):
    """0..1: how good it looks, by the numbers (calibrated by eye on the sheets)."""
    if m.get('visible') is not None:
        leg = smoothstep(0.2, 0.6, m['visible']) * smoothstep(0.02, 0.08, m['contrast'])
    else:
        leg = smoothstep(0.03, 0.14, m['contrast'])
    blown = smoothstep(0.35, 0.8, m['blown']) * 0.7 + smoothstep(0.6, 0.95, m['clip']) * 0.3
    empty = 1.0 if (m['area'] < 0.003 and m['detail'] < 0.01) or m['dark'] > 0.995 else 0.0
    mud = (1 - smoothstep(0.04, 0.1, m['contrast'])) * (1 - smoothstep(0.08, 0.2, m['colour'])) * smoothstep(0.08, 0.2, m['light'])
    noise = smoothstep(0.07, 0.14, m['fine'])
    return float(leg ** 0.7 * (1 - 0.7 * blown) * (1 - 0.85 * empty) * (1 - 0.6 * mud) * (1 - 0.5 * noise))


SIZE = (180, 320)


def frames(dirpath, prefix):
    """A capture's frames: (layer, settings, finished picture, native?) each, at one size
    (the stage draws smaller when it is busy)."""
    out = []
    for n in range(8):
        base = f'{dirpath}/{prefix}.{n}'
        if not os.path.exists(base + '.meta.json'):
            break
        native = json.load(open(base + '.meta.json')).get('native', True)
        if native and os.path.exists(base + '.json'):
            st = json.load(open(base + '.json'))
            fig = load_raw(base + '.fig') if os.path.exists(base + '.fig') else None
            gr = load_raw(base + '.ground') if os.path.exists(base + '.ground') else None
            fin = load_raw(base + '.out')[..., :3] if os.path.exists(base + '.out') else None
            fit = lambda a: None if a is None else fit_size(a, SIZE)
            out.append(dict(fig=fit(fig), ground=fit(gr), out=fit(fin), st=st, native=True))
        elif os.path.exists(base + '.png'):
            im = fit_size(np.asarray(Image.open(base + '.png').convert('RGB'), np.float32) / 255, SIZE)
            out.append(dict(fig=np.dstack([im, np.ones(im.shape[:2], np.float32)]), ground=None, out=im,
                            st=dict(coverage=2, strength=1, bloom=0, tone=0, vignette=0), native=False))
    return out


def fit_size(a, shape):
    if a.shape[:2] == shape:
        return a
    im = [Image.fromarray(a[..., i]).resize((shape[1], shape[0]), Image.BILINEAR) for i in range(a.shape[2])]
    return np.dstack([np.asarray(x, np.float32) for x in im])


GROUNDS_LOADED, GMOTION, SRC = {}, {}, ''


def _init(grounds, gmotion, src):
    """A worker's backgrounds (a worker is started afresh: nothing of the parent's)."""
    global GROUNDS_LOADED, GMOTION, SRC
    GROUNDS_LOADED, GMOTION, SRC = grounds, gmotion, src


def compose(fr, name, g, mi, xi, j):
    """One combination's finished picture from figure frame [fr] and the background's
    frame [j], and its figure's coverage."""
    st = fr['st']
    if g == 'black' and mi == 0 and xi == 0:
        # Plainly on black the stage draws the figure layer as it is.
        pic, cov = fr['fig'][..., :3], coverage(fr['fig'], st.get('coverage', 2))[0]
    else:
        pic, cov = blend(fr['fig'], st.get('coverage', 2), st.get('strength', 1), GROUNDS_LOADED[g][j], mi, xi)
    fin = finish(pic, st.get('bloom', 0.5), st.get('vignette', 0.6), st.get('tone', 1)) if fr['native'] else np.clip(pic, 0, 1)
    return fin, cov


def pairs(nf, ng):
    return [(i % nf, i) for i in range(ng)] if ng > nf else [(i, i % ng) for i in range(nf)]


def score_figure(arg):
    name, world = arg
    fr = frames(f'{SRC}/fig', name)
    if not fr:
        return name, None, []
    fmotion = float(np.mean([np.abs(a['fig'][..., :3] - b['fig'][..., :3]).mean() for a, b in zip(fr, fr[1:])])) if len(fr) > 1 else 0.0
    if world:
        ms = [measure(f['out'] if f['out'] is not None else f['fig'][..., :3], None) for f in fr]
        m = {k: float(np.mean([x[k] for x in ms])) if ms[0][k] is not None else None for k in ms[0]}
        m['motion'] = fmotion
        q = quality(m)
        return name, dict(world=True, q=q, m=m), [(q, name, None)]
    # The figure alone, finished on black: its own edges, what the picture should show.
    alone = [compose(f, name, 'black', 0, 0, 0)[0] for f in fr]
    efs = [edges(a) for a in alone]
    cells, seen = {}, []
    for g in GROUNDS:
        if g not in GROUNDS_LOADED:
            continue
        for mi, mask in enumerate(MASKS):
            for xi, mix in enumerate(MIXES):
                ms = [measure(*compose(fr[i], name, g, mi, xi, j), efs[i]) for i, j in pairs(len(fr), len(GROUNDS_LOADED[g]))]
                m = {k: (float(np.mean([x[k] for x in ms if x[k] is not None])) if any(x[k] is not None for x in ms) else None) for k in ms[0]}
                m['motion'] = fmotion + GMOTION.get(g, 0)
                q = float(np.mean([quality(x) for x in ms]))
                cells[f'{g}|{mask}|{mix}'] = dict(q=q, m=m)
                seen.append((q, name, (g, mi, xi)))
    return name, dict(world=False, cells=cells), seen


def picture(name, cell):
    """The picture of one combination (the first frames), for the sheets."""
    fr = frames(f'{SRC}/fig', name)
    if cell is None:
        return fr[0]['out'] if fr[0]['out'] is not None else fr[0]['fig'][..., :3]
    g, mi, xi = cell
    return compose(fr[0], name, g, mi, xi, 0)[0]


def main():
    src, out = sys.argv[1], sys.argv[2]
    os.makedirs(f'{out}/sheets', exist_ok=True)
    # The backgrounds: each one's pictures, dimmed as the stage dims them.
    grounds = {'black': [np.zeros((180, 320, 3), np.float32)]}
    gmotion = {'black': 0.0}
    for g in GROUNDS[1:]:
        fr = [f for f in frames(f'{src}/ground', g) if f['ground'] is not None]
        if not fr:
            continue
        grounds[g] = [f['ground'][..., :3] * f['st'].get('groundDim', 1) for f in fr]
        gmotion[g] = float(np.mean([np.abs(a - b).mean() for a, b in zip(grounds[g], grounds[g][1:])])) if g != 'milk' and len(fr) > 1 else 0.05
    for g, s in STAND_IN.items():
        if g not in grounds and s in grounds:
            grounds[g], gmotion[g] = grounds[s], gmotion[s]
    print('grounds', {g: len(v) for g, v in grounds.items()}, flush=True)

    if '--fit' in sys.argv:
        # How near the finish is: the ground captures blended and finished here against
        # what the stage finished.
        errs = []
        for g in GROUNDS[1:]:
            for f in frames(f'{src}/ground', g):
                if f['fig'] is None or f['ground'] is None or f['out'] is None:
                    continue
                st = f['st']
                pic, _ = blend(f['fig'], st['coverage'], st['strength'], f['ground'][..., :3] * st['groundDim'], st['mask'], st['mix'])
                mine = finish(pic, st['bloom'], st['vignette'], st['tone'])
                theirs = fit_size(f['out'], mine.shape[:2])
                errs.append((g, float(np.abs(mine - theirs).mean()), float(lum(mine).mean()), float(lum(theirs).mean())))
        for e in errs:
            print('fit %-12s err %.3f mine %.3f stage %.3f' % e)
        return

    global GROUNDS_LOADED, GMOTION, SRC
    GROUNDS_LOADED, GMOTION, SRC = grounds, gmotion, src
    rows = {}
    shown = []   # (q, figure, cell or None) for the sheets
    # The scenes that want a camera (none in the audit's room) are left as they are.
    figs = sorted({os.path.basename(p).rsplit('.', 3)[0] for p in glob.glob(f'{src}/fig/*.meta.json')}
                  - {n for n in (os.path.basename(p).rsplit('.', 3)[0] for p in glob.glob(f'{src}/fig/*.meta.json')) if n.split('.')[0] in CAMERA_SCENES})
    # The worlds of their own (show_combos.dart's isWorld): MilkDrop alone, the dormouse,
    # the disco floor, the viewports, the sky, and a scene with no figure (its one style).
    by_scene = {}
    for n in figs:
        by_scene.setdefault(n.split('.')[0], []).append(n)
    worlds = {n for n in figs if n.split('.')[0] in ('milk', 'siebenschlaefer') or n in ('dance-art.disco', 'dance-art.viewports', 'flock.sky')
              or by_scene[n.split('.')[0]] == [n.split('.')[0] + '.raw']}
    from multiprocessing import Pool
    with Pool(int(os.environ.get('AUDIT_PROCS', '4')), initializer=_init, initargs=(grounds, gmotion, src)) as pool:
        for name, row, seen in pool.imap_unordered(score_figure, [(n, n in worlds) for n in figs]):
            if row is None:
                continue
            rows[name] = row
            shown += seen
            print('scored', name, '%.2f' % (row['q'] if row['world'] else np.mean([c['q'] for c in row['cells'].values()])), flush=True)

    # Intensity: each number ranked across everything, then weighed together and ranked again.
    flat = []
    for name, r in rows.items():
        if r['world']:
            flat.append((name, None, r['m']))
        else:
            for k, c in r['cells'].items():
                flat.append((name, k, c['m']))

    def rank(v):
        v = np.asarray(v, float)
        return np.argsort(np.argsort(v)) / max(1, len(v) - 1)
    keys = ['contrast', 'detail', 'motion', 'light', 'colour']
    wts = [0.3, 0.25, 0.2, 0.15, 0.1]
    rk = {k: rank([x[2][k] for x in flat]) for k in keys}
    raw = sum(w * rk[k] for k, w in zip(keys, wts))
    inten = rank(raw)
    for (name, k, _), v in zip(flat, inten):
        (rows[name] if k is None else rows[name]['cells'][k])['i'] = float(v)

    # The app's table: per figure, a character a cell (0–z: 0..1) in background × mask ×
    # blend order, the quality and the intensity.
    def ch(v):
        return '0123456789abcdefghijklmnopqrstuvwxyz'[int(round(np.clip(v, 0, 1) * 35))]
    table = dict(version=1, grounds=GROUNDS, masks=MASKS, mixes=MIXES, figures={})
    for name, r in sorted(rows.items()):
        if r['world']:
            table['figures'][name] = dict(q=ch(r['q']), i=ch(r['i']))
        else:
            q = ''.join(ch(r['cells'][f'{g}|{m}|{x}']['q']) if f'{g}|{m}|{x}' in r['cells'] else '_' for g in GROUNDS for m in MASKS for x in MIXES)
            i = ''.join(ch(r['cells'][f'{g}|{m}|{x}']['i']) if f'{g}|{m}|{x}' in r['cells'] else '_' for g in GROUNDS for m in MASKS for x in MIXES)
            table['figures'][name] = dict(q=q, i=i)
    json.dump(table, open(f'{out}/combo_scores.json', 'w'), separators=(',', ':'))
    json.dump(rows, open(f'{out}/combo_metrics.json', 'w'))

    # Sheets to look at: the worst, the best, a spread.
    shown.sort(key=lambda t: t[0])
    def sheet(items, path, cols=6):
        tw, th = 240, 135
        im = Image.new('RGB', (cols * tw, ((len(items) + cols - 1) // cols) * (th + 14)), (24, 24, 28))
        dr = ImageDraw.Draw(im)
        for i, (q, name, cell) in enumerate(items):
            pic = picture(name, cell)
            label = name if cell is None else f'{name} {cell[0]} {MASKS[cell[1]]} {MIXES[cell[2]]}'
            x, y = (i % cols) * tw, (i // cols) * (th + 14)
            im.paste(Image.fromarray((np.clip(pic, 0, 1) * 255).astype(np.uint8)).resize((tw, th)), (x, y))
            dr.text((x + 2, y + th), f'{q:.2f} {label}'[:40], fill=(220, 220, 220))
        im.save(path, quality=82)
    sheet(shown[:60], f'{out}/sheets/worst.jpg')
    sheet(shown[-60:][::-1], f'{out}/sheets/best.jpg')
    edge = [x for x in shown if 0.2 <= x[0] < 0.45]
    sheet(edge[::max(1, len(edge) // 60)][:60], f'{out}/sheets/borderline.jpg')
    step = max(1, len(shown) // 60)
    sheet(shown[::step][:60], f'{out}/sheets/spread.jpg')
    print('combinations', len(shown), 'mean q %.2f' % np.mean([s[0] for s in shown]),
          'below .3: %d' % sum(s[0] < 0.3 for s in shown))


if __name__ == '__main__':
    main()
