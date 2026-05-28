# Runbook: payment-api returns 5xx

## Quick context

- **Cluster:** `payment-api-cluster` (zonal, `europe-west1-b`, **fully private endpoint** + master_global_access)
- **Namespace:** `payment-api` (managed by `k8s/namespace.yaml`, PSA `restricted`)
- **Deployment:** `payment-api` (Helm release `payment-api`)
- **Replicas:** 2 (`replicaCount: 2` + topologySpread + soft anti-affinity), spread across different nodes
- **KSA → GSA:** `payment-api/payment-api` → `payment-api-sa@payment-api-task.iam.gserviceaccount.com` (Workload Identity)
- **Image registry:** `europe-west1-docker.pkg.dev/payment-api-task/payment-api/payment-api`
- **External entry point:** `http://34.117.51.222` (GCE Ingress on reserved global static IP)
- **Node pool:** `e2-medium` × 2-4 **Spot** VMs (autoscaler)

### Get kubeconfig (cluster is private — use Connect Gateway)

```bash
gcloud container fleet memberships get-credentials payment-api-cluster --project=payment-api-task
```

Direct `gcloud container clusters get-credentials` won't work — master endpoint is private. Connect Gateway proxies kubectl through Google APIs.

**Note:** Connect Gateway does NOT support `kubectl exec` / `kubectl port-forward` (SPDY upgrade unsupported). To run interactive debug — start a debug pod with `kubectl run` and read its logs.

---

## 1. Check pod and recent rollout

```bash
kubectl -n payment-api get pods -l app=payment-api -o wide
kubectl -n payment-api describe pod -l app=payment-api
kubectl -n payment-api rollout history deployment/payment-api
kubectl -n payment-api get events --sort-by=.lastTimestamp | tail -30
```

Look for:
- `CrashLoopBackOff`, `ImagePullBackOff`, `OOMKilled` (exitCode 137)
- `FailedScheduling` ("Insufficient cpu" — CPU starvation on small nodes)
- `NotTriggerScaleUp` ("max node group size reached" — autoscaler hit max_node_count)
- Recent `ReplicaSet` changes lining up with the incident start time
- Pods on the SAME node — `topologySpreadConstraints` are soft (`whenUnsatisfiable: ScheduleAnyway`) so a single-node moment can co-locate them

---

## 2. Check application logs (Cloud Logging)

**Logs Explorer filter** (paste verbatim):

```
resource.type="k8s_container"
resource.labels.cluster_name="payment-api-cluster"
resource.labels.namespace_name="payment-api"
resource.labels.container_name="payment-api"
severity>=ERROR
```

App logs are JSON-structured. Cloud Logging parses `severity` and `timestamp` directly — you can filter by them as first-class fields.

For 5xx specifically:

```
resource.type="k8s_container"
resource.labels.container_name="payment-api"
jsonPayload.message=~"HTTP/1.1\" 5\d\d"
```

CLI equivalent:

```bash
gcloud logging read 'resource.type="k8s_container" AND resource.labels.container_name="payment-api" AND severity>=ERROR' \
  --limit=50 --project=payment-api-task --freshness=1h
```

**Zero log output but container running for minutes = check NetworkPolicy + WI** (see escalation table below).

---

## 3. Check metrics and alerts (Cloud Monitoring)

- **Uptime checks:** *Monitoring → Uptime checks → `payment-api-health`*. Status across 6 prober regions. Click → 90-day history.
- **Alert policy:** *Monitoring → Alerting → Policies → `payment-api-uptime-failure`*. Open incident to see firing time, host, check_id. Auto-closes after 30 min once symptom clears.
- **Notification:** email to channel `On-call Email`.
- **Metrics Explorer:**
  - `monitoring.googleapis.com/uptime_check/check_passed` filter by `metric.label.check_id` — split by `checker_location` to detect single-region vs cluster-wide outages
  - `kubernetes.io/container/restart_count` filter by `metadata.user_labels.app="payment-api"` — spike = CrashLoop
  - `kubernetes.io/container/memory/used_bytes` vs limit `512Mi` — near limit = OOMKill risk
  - `kubernetes.io/container/cpu/used_cores` vs request `100m` — heavy throttling = startup probe could fail

---

## 4. Check distributed traces

- *Trace → Trace Explorer*, filter `Service: payment-api`.
- Look for spans with `status.code != OK` or unusual latency. Span attributes carry HTTP method/path.
- Exporter: `opentelemetry-exporter-gcp-trace` (configured in [app/main.py](../app/main.py)).

---

## 5. Check GCE Ingress backend (external 5xx but pod looks fine)

```bash
gcloud compute backend-services list --project=payment-api-task
gcloud compute backend-services get-health <BACKEND_NAME> --global --project=payment-api-task
```

- `UNHEALTHY` instance + healthy pod = readiness probe path mismatch with backend HC, or readiness returning non-200. Default GCE Ingress uses the readiness probe path (`/ready`).
- `UNKNOWN` for several minutes after deploy = NEG controller hasn't registered the pods yet; wait ~3 min then re-check.

---

## 6. Escalation / remediation

| Symptom | Likely cause | Fix |
|---|---|---|
| `CrashLoopBackOff`, log: `PermissionDenied: secretmanager.versions.access` | Workload Identity broken | `kubectl -n payment-api describe sa payment-api` — check `iam.gke.io/gcp-service-account` annotation matches `payment-api-sa@payment-api-task...`. Verify `google_service_account_iam_member.payment_api_wi_binding` + `google_secret_manager_secret_iam_member.payment_api_secret_accessor` in TF state. |
| `ImagePullBackOff` | `gke-node-sa` missing `roles/artifactregistry.reader` or wrong image URI | `kubectl -n payment-api describe pod ...`. Verify image: `gcloud artifacts docker images list europe-west1-docker.pkg.dev/payment-api-task/payment-api`. |
| `OOMKilled` (exitCode 137 + has logs) | Memory limit too low for FastAPI+OTel+gRPC | Temp: `kubectl -n payment-api set resources deployment/payment-api --limits=memory=1Gi`. Permanent: bump `resources.limits.memory` in `charts/payment-api/values.yaml` + helm upgrade via workflow. |
| **exitCode 137 + ZERO logs**, container ran ~150s then killed | Startup probe failed because app hung before binding to 8080. Most likely: NetworkPolicy egress blocked Workload Identity metadata (`169.254.169.254`) or NodeLocal DNS (`169.254.20.10`). | Check `kubectl -n payment-api get netpol payment-api -o yaml` — if egress restriction includes link-local IPs, REMOVE it (Calico Dataplane V1 can't filter them; use ingress-only NetworkPolicy). Confirm Workload Identity from a test pod with `app: payment-api` label: `curl -H 'Metadata-Flavor: Google' http://169.254.169.254/computeMetadata/v1/instance/service-accounts/default/email` should return the GSA email. |
| Pod Running, 5xx returned | Upstream / Secret Manager rate-limit / `/ready` returns 503 `{"status":"not_ready"}` | Run an in-cluster curl pod: `kubectl -n payment-api run check --rm -i --restart=Never --image=curlimages/curl:latest -- sh -c 'curl -i http://payment-api/ready'`. HTTP 503 → secret load failed at startup, check Cloud Logging for `severity=CRITICAL` + "secret load failed". WI / Secret-scoped IAM is the usual cause. |
| `FailedScheduling` "Insufficient cpu" + autoscaler `NotTriggerScaleUp: max node group size reached` | Cluster hit `max_node_count`. Usually after Spot reclaim + many DaemonSets. | Temp: bump `terraform/modules/gke/main.tf` `max_node_count`, `terraform apply -target=module.gke.google_container_node_pool.primary_nodes`. Investigate why so many pods landed at once (rolling deploy + autoscaler lag). |
| Uptime check fires but pod healthy | GCE LB backend not healthy yet (provisioning) OR static IP changed | `kubectl -n payment-api get ingress payment-api -o wide`. `gcloud compute backend-services get-health ...`. If IP changed → update `health_check_host` in `terraform.tfvars` + `terraform apply`. |
| `kubectl exec` / `port-forward` fails with HTTP 400 SPDY error | Connect Gateway does not support these. | Workaround: run a debug pod (`kubectl -n payment-api run debug --image=...`) and read its logs, or hit the Service ClusterIP from another in-cluster pod. |
| `kubectl` from local laptop hangs / "no route to host" on master | Cluster is private endpoint, no Connect Gateway creds | `gcloud container fleet memberships get-credentials payment-api-cluster --project=payment-api-task` |
| **Multi-minute outage right after `compute.instances.preempted` event** | Spot VM reclaim + cluster autoscaler too slow + replicaCount=1 | Check `replicaCount: 2` in `values-<env>.yaml`. Check `min_node_count >= 2` in TF. If single-replica is the desired state for dev, accept ~5-10 min reclaim downtime as documented trade-off. |

### Roll back the bad release

```bash
helm -n payment-api history payment-api
helm -n payment-api rollback payment-api <REVISION>
```

CI does `helm rollback` on `--atomic` failure automatically with a guard (skips if no previous revision). For post-deploy regressions roll back manually.

### Trigger a new deploy

```bash
gh workflow run build-deploy.yml --ref main --field environment=dev
```

(or omit `--field` to default to dev)

### Common Cloud Logging queries

**Liveness/readiness probe history (last 10 min):**
```
resource.type="k8s_pod"
resource.labels.namespace_name="payment-api"
jsonPayload.message=~"Startup probe|Liveness probe|Readiness probe"
timestamp >= "..."
```

**Spot preemption events:**
```
protoPayload.methodName="compute.instances.preempted"
protoPayload.resourceName=~"gke-payment-api-clus-"
```

**Node creation/deletion:**
```
protoPayload.methodName=~"v1.compute.instances.(delete|insert)"
protoPayload.resourceName=~"gke-payment-api"
```
