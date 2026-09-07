# Built for both arches from day one: this image starts on a laptop and ends up on a Pi.
#   docker buildx build --platform linux/amd64,linux/arm64 -t muse-worker .
FROM python:3.13-slim

# ffmpeg for probe/loudness/transcode; nodejs because yt-dlp needs a JS runtime
# (`--js-runtimes node`) — deno is the default but node is what we verified.
RUN apt-get update && apt-get install -y --no-install-recommends ffmpeg nodejs \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY worker.py .
CMD ["python", "worker.py"]
