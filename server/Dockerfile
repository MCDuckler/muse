FROM python:3.13-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY muse ./muse
ENV MUSE_CONFIG=/config/muse.toml
EXPOSE 8770
CMD ["python", "-m", "uvicorn", "muse.main:app", "--host", "0.0.0.0", "--port", "8770"]
