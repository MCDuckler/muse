FROM python:3.13-slim

# ffmpeg/ffprobe for custom uploads (probe, loudness, transcode to m4a) and
# chromaprint so a badly tagged upload can still be identified later.
RUN apt-get update && apt-get install -y --no-install-recommends ffmpeg libchromaprint-tools \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY muse ./muse
ENV MUSE_CONFIG=/config/muse.toml
# Two malloc arenas, not one per thread: every request thread that read a record kept
# its own heap of freed memory, and the server grew until it was killed.
ENV MALLOC_ARENA_MAX=2
EXPOSE 8770
# The client's own address from Caddy's X-Forwarded-For: without it every request came
# from Caddy's container and the login limit was one bucket for the whole internet
# (one attempt every five seconds from anyone locked everyone out). Safe to trust from
# anywhere: 8770 is not published, Caddy is the only thing that reaches it, and Caddy
# replaces whatever X-Forwarded-For a client sends with the address it really came from.
CMD ["python", "-m", "uvicorn", "muse.main:app", "--host", "0.0.0.0", "--port", "8770", "--proxy-headers", "--forwarded-allow-ips", "*"]
