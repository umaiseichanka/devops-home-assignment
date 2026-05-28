"""
Payment API — FastAPI app with:
- Structured JSON logging (Cloud Logging-friendly: severity/timestamp/message)
- OpenTelemetry tracing exported to Cloud Trace (graceful no-op locally)
- Secret Manager integration at startup via Workload Identity (KSA -> GSA)
- Split probes: /health = liveness (always 200), /ready = readiness (deps loaded)

Liveness MUST be cheap and decoupled from external deps. Tying liveness to
Secret Manager would cause the kubelet to kill the pod on transient upstream
issues, masking the real problem.
"""
import logging
import os
import sys

from fastapi import FastAPI, Response, status
from opentelemetry import trace
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
from pythonjsonlogger import jsonlogger


# Structured JSON logging — Cloud Logging parses severity/timestamp natively.
_handler = logging.StreamHandler(sys.stdout)
_handler.setFormatter(
    jsonlogger.JsonFormatter(
        fmt="%(asctime)s %(levelname)s %(name)s %(message)s",
        rename_fields={"asctime": "timestamp", "levelname": "severity"},
    )
)
logging.root.handlers = [_handler]
logging.root.setLevel(logging.INFO)

# Force uvicorn loggers through the JSON handler too, so access logs end up
# in Cloud Logging with parseable severity/timestamp fields.
for _name in ("uvicorn", "uvicorn.access", "uvicorn.error"):
    _l = logging.getLogger(_name)
    _l.handlers = [_handler]
    _l.propagate = False

log = logging.getLogger("payment-api")


# OpenTelemetry -> Cloud Trace. Try/except so the app starts in local / CI
# environments where Application Default Credentials are not configured.
try:
    from opentelemetry.exporter.cloud_trace import CloudTraceSpanExporter

    _provider = TracerProvider()
    _provider.add_span_processor(BatchSpanProcessor(CloudTraceSpanExporter()))
    trace.set_tracer_provider(_provider)
    log.info("Cloud Trace exporter initialised")
except Exception as exc:
    trace.set_tracer_provider(TracerProvider())
    log.warning("Cloud Trace exporter unavailable, tracing is no-op: %s", exc)

tracer = trace.get_tracer(__name__)


# Secret Manager — read once at startup.
SECRET_VALUE: str | None = None


def _load_secret() -> str | None:
    project = os.getenv("GCP_PROJECT_ID")
    name = os.getenv("SECRET_NAME", "payment-api-key")
    if not project:
        log.warning("GCP_PROJECT_ID not set, skipping Secret Manager lookup")
        return None
    try:
        from google.cloud import secretmanager

        client = secretmanager.SecretManagerServiceClient()
        path = f"projects/{project}/secrets/{name}/versions/latest"
        resp = client.access_secret_version(request={"name": path})
        log.info("loaded secret %s (length=%d)", name, len(resp.payload.data))
        return resp.payload.data.decode("utf-8")
    except Exception as exc:
        # CRITICAL severity: surfaced as an ERROR in Cloud Logging and counts
        # toward severity-filtered alert policies. App will start but /ready
        # returns 503 below, so the pod is removed from the service endpoint
        # and the existing uptime check alert fires.
        log.error("failed to load secret %s: %s", name, exc)
        return None


SECRET_VALUE = _load_secret()
if SECRET_VALUE is None:
    log.critical(
        "secret load failed at startup — pod will report NotReady. "
        "Investigate Workload Identity binding + secret-scoped IAM."
    )


app = FastAPI(title="Payment API", version="1.0.0")
FastAPIInstrumentor.instrument_app(app)


@app.get("/health")
def health():
    """Liveness — process is alive. Cheap, no external deps."""
    return {"status": "ok"}


@app.get("/ready")
def ready(response: Response):
    """Readiness — pod can serve traffic (secret loaded).

    Returns 503 when the secret has not been loaded so kubelet removes the
    pod from the Service endpoint. Body never exposes internal state
    (avoids /ready info disclosure on a public Ingress).
    """
    if SECRET_VALUE is None:
        response.status_code = status.HTTP_503_SERVICE_UNAVAILABLE
        return {"status": "not_ready"}
    return {"status": "ready"}


@app.get("/")
def index():
    with tracer.start_as_current_span("index"):
        return {"service": "payment-api", "version": "1.0.0"}


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host="0.0.0.0", port=int(os.environ.get("PORT", "8080")))
