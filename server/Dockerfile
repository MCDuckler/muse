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
EXPOSE 8770
CMD ["python", "-m", "uvicorn", "muse.main:app", "--host", "0.0.0.0", "--port", "8770"]
