# Multi-stage: build deps in venv, runtime image carries only what's needed.
# Aggressive purge of pip/setuptools/wheel/jaraco artifacts that ship in
# python:3.11-slim base and trigger Trivy HIGH (Trivy gates HIGH/CRITICAL).

FROM python:3.11-slim AS builder

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /build

COPY requirements.txt .
# hadolint ignore=DL3013
RUN pip install --no-cache-dir --upgrade --force-reinstall pip setuptools wheel \
 && pip install --no-cache-dir --prefix=/install -r requirements.txt \
 && rm -rf /install/lib/python3.11/site-packages/wheel* \
           /install/lib/python3.11/site-packages/setuptools* \
           /install/lib/python3.11/site-packages/pip* \
           /install/lib/python3.11/site-packages/pkg_resources* \
           /install/lib/python3.11/site-packages/_distutils_hack* \
           /install/lib/python3.11/site-packages/jaraco*

# ---------- runtime ----------
FROM python:3.11-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PORT=8080

WORKDIR /app

# Copy app deps from builder (already purged of installer tooling).
COPY --from=builder /install /usr/local

# Force-reinstall installer tools to CVE-clean versions, then nuke any older
# dist-info copies left by the base image / builder merge.
# hadolint ignore=DL3013
RUN pip install --no-cache-dir --upgrade --force-reinstall pip setuptools wheel \
 && rm -rf /usr/local/lib/python3.11/site-packages/wheel-0.[0-3]* \
           /usr/local/lib/python3.11/site-packages/wheel-0.4[0-5]* \
           /usr/local/lib/python3.11/site-packages/setuptools-[0-7]* \
           /usr/local/lib/python3.11/site-packages/pip-2[0-4]* \
           /usr/local/lib/python3.11/site-packages/jaraco* \
 && find /usr/local/lib/python3.11/site-packages -name "*.pyc" -delete \
 && groupadd --system app \
 && useradd --system --gid app --no-create-home --shell /sbin/nologin app

COPY . .
RUN chown -R app:app /app
USER app

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD ["python", "-c", "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://localhost:8080/health',timeout=3).status==200 else 1)"]

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080", "--workers", "1"]
