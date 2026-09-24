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
CMD ["python", "-m", "uvicorn", "muse.main:app", "--host", "0.0.0.0", "--port", "8770"]
