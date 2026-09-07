# muse

Private music streaming for a handful of configured users. The client asks for a song; the
server serves it from disk, or fetches it once and keeps it forever.

Plan: `~/.claude/plans/music-streaming.md` · report: https://claude.ai/code/artifact/0857ab85-fd85-4742-8355-449acbaafa8a

## The one structural fact

YouTube refuses datacenter IPs at the player API. Measured on 2026-09-07 with the same
yt-dlp binary, same video, same minute:

| Host | Result |
|---|---|
| laptop (residential) | itag 140 downloaded, no cookies, no PO token |
| OVH box, IPv6 | `HTTP 429` → `This video is not available` |
| OVH box, IPv4 | `Sign in to confirm you're not a bot` |

So **the server never downloads.** A worker on a residential connection leases jobs over an
outbound HTTPS call and uploads the finished audio back. Details in `worker/NOTES.md`.

## Layout

```
server/   FastAPI + Postgres. Catalog, auth, job queue, blob store, streaming.
worker/   yt-dlp + ffmpeg. Runs where the IP is residential. Outbound only.
deploy/   compose + Caddyfile for the OVH box (api + db + caddy; never the worker).
app/      Flutter client (phase 3, not started).
```

## Running it locally

Postgres 17 runs rootless out of `~/.local/pgroot` — no docker, no sudo:

```bash
make db-start      # portable Postgres on :5433
make api           # http://127.0.0.1:8770
make worker        # in another shell; picks the secret out of server/muse.toml
make test          # 17 tests against a throwaway muse_test database
```

First-time setup:

```bash
cd server && python3 -m venv .venv && ./.venv/bin/pip install -r requirements.txt
cp muse.example.toml muse.toml
./.venv/bin/python -m muse.cli secret        # -> [worker] secret
./.venv/bin/python -m muse.cli adduser chris # -> [[users]] block
```

## API

```
POST /auth/login            user, password, device  -> bearer token (rate limited)
GET  /me
GET  /search?q=             local catalog + YouTube Music, remote hits flagged `known`
POST /tracks/resolve        {query|video_id} -> 200 if cached, 202 if newly queued
GET  /tracks/{id}
GET  /tracks/{id}/stream    Range, ETag, immutable
GET  /events                SSE: track_ready, track_failed
GET  /admin/storage         bytes, track states, outstanding jobs, worker heartbeats

POST /internal/jobs/lease            worker secret; SKIP LOCKED, one job to one worker
POST /internal/jobs/{id}/complete    multipart audio + meta
POST /internal/jobs/{id}/fail        {reason, retryable}
```

## Decisions worth not re-litigating

- **m4a/AAC canonical.** iOS AVPlayer cannot play Ogg/Opus. itag 140 already *is* AAC 128k
  in m4a, so the common path is a remux, not a transcode.
- **Loudness is measured, never baked in.** `gain_db` is stored against −14 LUFS and applied
  by the client, so YouTube rips and your own uploads don't fight each other.
- **Blobs are content-addressed** (`audio/<sha[:2]>/<sha>.m4a`) — two tracks with the same
  rip cost one file.
- **PO provider and cookies are contingencies**, both off. Enable via `MUSE_POT_BASE_URL` /
  `MUSE_COOKIES` the day a download actually fails.
- **Terminal errors are not retried.** "unavailable", "sign in to confirm", "po token" and
  friends fail the job immediately; anything else backs off quadratically. A job flapping at
  full speed is what turns a working residential IP into a challenged one.
