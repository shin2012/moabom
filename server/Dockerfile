FROM python:3.12-slim

RUN apt-get update && apt-get install -y --no-install-recommends ffmpeg curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app/ ./app/
RUN mkdir -p /app/data /downloads

ENV PYTHONUNBUFFERED=1
EXPOSE 8443

# TLS is optional: mount a cert dir at /certs with key.pem + cert.pem (or set MOABOM_TLS_KEY/MOABOM_TLS_CERT).
CMD ["sh", "-c", "KEY=${MOABOM_TLS_KEY:-/certs/key.pem}; CERT=${MOABOM_TLS_CERT:-/certs/cert.pem}; \
  if [ -f \"$KEY\" ] && [ -f \"$CERT\" ]; then TLS=\"--ssl-keyfile $KEY --ssl-certfile $CERT\"; else TLS=''; fi; \
  exec uvicorn app.main:app --host 0.0.0.0 --port 8443 --proxy-headers --forwarded-allow-ips='*' --limit-concurrency 64 $TLS"]

HEALTHCHECK --interval=30s --timeout=5s --retries=3 --start-period=20s \
    CMD curl -fsk https://localhost:8443/health || curl -fs http://localhost:8443/health || exit 1
