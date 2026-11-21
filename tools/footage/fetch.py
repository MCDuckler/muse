#!/usr/bin/env python3
"""Fetch excerpts of public-domain / CC-BY(-SA) footage from the Internet Archive into the
WetOwl video library (~/Videos/WetOwl/<kind>/), each ≤720p H.264, no sound, and a credits
line per clip (source, licence). Reads only; skips a clip already there.

  python3 fetch.py plan.json
"""
import json, os, subprocess, sys, urllib.request, urllib.parse, pathlib

ROOT = pathlib.Path.home() / "Videos" / "WetOwl"
OK_LICENCES = ("publicdomain", "/by/", "/by-sa/")  # no NC, no ND: paid gigs, blended pictures
PREF = ["h.264 720P", "h.264", "MPEG4", "512Kb MPEG4", "h.264 HD", "Matroska", "QuickTime", "Cinepack", "MPEG2", "Ogg Video"]


def meta(ident):
    with urllib.request.urlopen(f"https://archive.org/metadata/{urllib.parse.quote(ident)}", timeout=60) as r:
        return json.load(r)


def pick(files, name_hint=None):
    vids = [f for f in files if f.get("format") in PREF and not f["name"].endswith(".gif")]
    if name_hint:
        vids = [f for f in vids if name_hint.lower() in f["name"].lower()] or vids
    vids.sort(key=lambda f: (PREF.index(f["format"]), -int(f.get("size", 0) or 0) if f["format"] == "h.264 720P" else int(f.get("size", 0) or 0)))
    return vids


def duration(url):
    out = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", url], capture_output=True, text=True, timeout=120)
    try:
        return float(out.stdout.strip())
    except ValueError:
        return None


def main():
    plan = json.load(open(sys.argv[1]))
    credits = []
    for c in plan:
        kind, ident, name = c["kind"], c["id"], c["name"]
        dest = ROOT / kind / f"{name}.mp4"
        try:
            m = meta(ident)
        except Exception as e:
            print(f"!! {ident}: no metadata ({e})"); continue
        lic = (m.get("metadata", {}).get("licenseurl") or "")
        if not any(k in lic for k in OK_LICENCES):
            print(f"!! {ident}: licence '{lic}' not taken"); continue
        title = m.get("metadata", {}).get("title", ident)
        year = m.get("metadata", {}).get("year") or m.get("metadata", {}).get("date", "")
        credits.append(f"- **{kind}/{name}.mp4** — “{title}” ({year}), Internet Archive `{ident}` — https://archive.org/details/{ident} — licence: {lic}")
        if dest.exists():
            print(f"-- {name}: there already"); continue
        if c.get("pack"):
            # a VJ pack: a spread of its loops, each up to `each` s, joined into one clip
            fmt = c.get("format")
            vids = [f for f in m.get("files", []) if (f.get("format") == fmt if fmt else f.get("format") in PREF)]
            vids.sort(key=lambda f: f["name"])
            n = min(c["pack"], len(vids))
            chosen = [vids[round(i * (len(vids) - 1) / max(n - 1, 1))] for i in range(n)]
            dest.parent.mkdir(parents=True, exist_ok=True)
            tmp = ROOT / ".fetching" / f"{kind}-{name}.mp4"; tmp.parent.mkdir(parents=True, exist_ok=True)
            # each loop's first seconds to a local file first (one at a time, retried: the
            # Archive drops a connection left idle while ffmpeg reads the others), then joined
            work = ROOT / ".fetching" / f"{kind}-{name}-parts"
            work.mkdir(parents=True, exist_ok=True)
            got = []
            for k, f in enumerate(chosen):
                part = work / f"{k:02d}.mp4"
                src = f"https://archive.org/download/{urllib.parse.quote(ident)}/{urllib.parse.quote(f['name'])}"
                for attempt in range(3):
                    rr = subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-t", str(c.get("each", 8)), "-i", src, "-an",
                                         "-vf", "scale=1280:720:force_original_aspect_ratio=decrease,pad=1280:720:(ow-iw)/2:(oh-ih)/2,setsar=1,fps=30,format=yuv420p",
                                         "-c:v", "libx264", "-preset", "veryfast", "-crf", "21", str(part)], timeout=600)
                    if rr.returncode == 0 and part.exists() and part.stat().st_size > 10_000:
                        got.append(part)
                        break
            n = len(got)
            if n == 0:
                print(f"!! {name}: no loop fetched")
                continue
            lst = work / "list.txt"
            lst.write_text("".join(f"file '{g}'\n" for g in got))
            args = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-f", "concat", "-safe", "0", "-i", str(lst), "-c", "copy", "-movflags", "+faststart", str(tmp)]
            print(f">> {kind}/{name}: {n} loops of {len(vids)} ({fmt or 'any'})")
            r = subprocess.run(args, timeout=1800)
            if r.returncode == 0 and tmp.exists() and tmp.stat().st_size > 50_000:
                tmp.rename(dest)
                print(f"   {dest.stat().st_size / 1e6:.1f} MB")
            else:
                print(f"!! {name}: ffmpeg failed")
                tmp.unlink(missing_ok=True)
            import shutil
            shutil.rmtree(work, ignore_errors=True)
            continue
        vids = pick(m.get("files", []), c.get("file"))
        if not vids:
            print(f"!! {ident}: no video file"); continue
        f = vids[0]
        url = f"https://archive.org/download/{urllib.parse.quote(ident)}/{urllib.parse.quote(f['name'])}"
        total = duration(url) or float(f.get("length", 0) or 0)
        start = c.get("start")
        if start is None:
            start = (total * c.get("at", 0.0)) if total else 0.0
        length = c.get("len", 180)
        if total:
            length = max(5.0, min(length, total - start))
        dest.parent.mkdir(parents=True, exist_ok=True)
        tmp = ROOT / ".fetching" / f"{kind}-{name}.mp4"; tmp.parent.mkdir(parents=True, exist_ok=True)
        cmd = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-ss", f"{start:.2f}", "-i", url, "-t", f"{length:.2f}", "-an",
               "-vf", "scale='min(1280,iw)':'min(720,ih)':force_original_aspect_ratio=decrease,scale=trunc(iw/2)*2:trunc(ih/2)*2",
               "-c:v", "libx264", "-preset", "veryfast", "-crf", "21", "-pix_fmt", "yuv420p", "-movflags", "+faststart", str(tmp)]
        print(f">> {kind}/{name}: {f['name']} ({f['format']}) from {start:.0f} s for {length:.0f} s")
        for attempt in range(3):
            r = subprocess.run(cmd, timeout=1800)
            if r.returncode == 0 and tmp.exists() and tmp.stat().st_size > 50_000:
                break
            print(f"   try {attempt + 2}")
        if r.returncode == 0 and tmp.exists() and tmp.stat().st_size > 50_000:
            tmp.rename(dest)
            print(f"   {dest.stat().st_size / 1e6:.1f} MB")
        else:
            print(f"!! {name}: ffmpeg failed")
            tmp.unlink(missing_ok=True)
    out = ROOT / "CREDITS.md"
    head = "# WetOwl video library — sources and licences\n\nFetched from the Internet Archive; public domain or CC-BY / CC-BY-SA only (no NC, no ND).\nCC-BY clips: credit the author as the item page says when the show is published.\n\n"
    old = out.read_text().splitlines() if out.exists() else []
    lines = [l for l in old if l.startswith("- ")]
    for l in credits:
        if l not in lines:
            lines.append(l)
    out.write_text(head + "\n".join(sorted(lines)) + "\n")
    print(f"credits: {out}")


if __name__ == "__main__":
    main()
