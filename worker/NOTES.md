# Ingest spike — findings

Run 2026-09-07. yt-dlp **2026.08.19**, ytmusicapi **1.12.2**, ffmpeg n8.1.1, node v26.1.0.
Venv: `worker/.venv` (`pip install yt-dlp bgutil-ytdlp-pot-provider ytmusicapi`).

## Result: ingest works from the laptop with **no cookies and no PO-token provider**

The same standalone yt-dlp binary, same video, same minute:

| Host | IP kind | Outcome |
|---|---|---|
| this laptop | residential | itag 140 listed and downloaded, 5.8 MB |
| OVH `hv-cta` (158.69.192.169), IPv6 | datacenter | `HTTP Error 429: Too Many Requests` → `This video is not available` |
| OVH `hv-cta`, forced `-4` | datacenter | `ERROR: Sign in to confirm you're not a bot.` |

**The residential-worker architecture is not a precaution, it is measured.** Neither IPv4 nor
IPv6 on the OVH box gets a playable format; the laptop needs no authentication at all.

## Working invocation (verbatim)

```bash
# search (no auth needed)
python -c "from ytmusicapi import YTMusic; print(YTMusic().search('Daft Punk Get Lucky', filter='songs', limit=2))"

# download — prefer itag 140 (AAC 128k in m4a) so the common path is a remux, not a transcode
yt-dlp --js-runtimes node -f 140 -o "%(id)s.%(ext)s" "https://music.youtube.com/watch?v=<ID>"

# loudness, measure only — never bake it into the file
ffmpeg -nostats -hide_banner -i <ID>.m4a -af ebur128=framelog=quiet -f null -
```

- **`--js-runtimes node` is required.** Without a JS runtime yt-dlp warns that extraction is
  deprecated and "some formats may be missing"; node 26 satisfies it, so **deno is not needed**
  and the worker image does not have to ship one.
- No `--cookies`. No POT provider running. Docker was never reachable on this box (user is not in
  the `docker` group and sudo wants a password) — the spike ran entirely without it.

## Measurements

| Track | Duration | itag 140 size | Probe |
|---|---|---|---|
| `4D7u5KF7SP8` Daft Punk — Get Lucky | 369.6 s (6:10) | 5.8 MB | aac 44100 Hz stereo 129.4 kbps |
| `H4RELGc9su8` Kendrick Lamar — HUMBLE. | 177.0 s (2:57) | 2.8 MB | aac 44100 Hz stereo 129.5 kbps |

- **0.94 MB per minute** → the plan's 3.6 MB / 4-minute estimate holds (10 k tracks ≈ 38 GB).
- Loudness of Get Lucky: **I −10.9 LUFS**, LRA 3.8 LU → `gain_db = −3.1` against the −14 LUFS
  target. `ebur128` measured a 6-minute track in **0.32 s** (~1150× realtime) — cheap enough to run
  on every ingest, and cheap enough for a Pi.
- Age-restricted / licensed checks (`8Uee_mcxvrw`, `JGwWNGJdvx8`) both resolved itag 140 with
  `age_limit 0`, `availability public`. No case needing cookies was found yet.
- ytmusicapi search unauthenticated returns `videoId`, artist, album flag and duration — enough to
  create the track row before anything is downloaded.

## What this changes in the plan

- **POT provider is a contingency, not a baseline.** Keep `bgutil-ytdlp-pot-provider` in the
  compose file commented out with a one-line "enable when downloads start failing" note, rather
  than running a container that currently does nothing.
- **Cookies are a contingency too.** No throwaway account is needed today. Keep the env-file swap
  documented; do not create the account until a download actually demands it.
- Worker image must contain node (for `--js-runtimes node`) and ffmpeg. Build `amd64,arm64`.
- Re-run this spike before blaming anything else when ingest breaks: it is the canary.

## Not yet tested

- Sustained rate (how many tracks/hour from one residential IP before a challenge appears).
- A track that genuinely needs cookies (age-gated ones tried were not gated in this region).
- arm64: the Pi path is unverified until there is a Pi.
