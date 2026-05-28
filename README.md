# Payment API — DevOps Home Assignment

GCP environment for a fictional "payment API". GKE-only, Terraform, GitHub Actions CI/CD, Helm-based CD, Cloud Logging/Monitoring/Trace. Production-grade defaults: fully private cluster, Connect Gateway for CI/CD, Workload Identity end-to-end, scoped secret access, PSA `restricted` pods, namespace-scoped K8s RBAC for CI, HA across Spot reclamations.

**Submission:** [github.com/umaiseichanka/devops-home-assignment3](https://github.com/umaiseichanka/devops-home-assignment3)

---

## Repo layout

```
.
├── app/                          # FastAPI + uvicorn, JSON logs, OTel, multi-stage Dockerfile
│   ├── main.py
│   ├── Dockerfile
│   ├── .dockerignore
│   └── requirements.txt
├── charts/payment-api/           # Helm chart
│   ├── values.yaml               # defaults — PSA `restricted`-compatible pod, startup+liveness+readiness probes
│   ├── values-dev.yaml           # replicaCount: 2, PDB on, Ingress on static IP
│   ├── values-staging.yaml       # replicaCount: 2, PDB on, HPA on, larger limits
│   └── templates/
│       ├── deployment.yaml       # topologySpread + podAntiAffinity + preStop + emptyDir /tmp
│       ├── service.yaml
│       ├── ingress.yaml          # GCE LB, static-IP annotation
│       ├── networkpolicy.yaml    # ingress-only (see "NetworkPolicy" below for why)
│       ├── hpa.yaml              # rendered only if values.hpa.enabled
│       ├── poddisruptionbudget.yaml
│       ├── serviceaccount.yaml   # KSA with iam.gke.io/gcp-service-account annotation
│       └── _helpers.tpl
├── k8s/                          # one-time bootstrap (applied by a project Owner)
│   ├── namespace.yaml            # PSA `restricted` labels (enforce + audit + warn)
│   └── rbac-ci.yaml              # Role/ci-deployer + RoleBinding to github-actions-sa
├── terraform/
│   ├── apis.tf                   # google_project_service × 13
│   ├── main.tf, variables.tf, outputs.tf, backend.tf.example
│   └── modules/
│       ├── vpc/                  # 1 VPC, 2 subnets w/ secondary ranges, Cloud NAT
│       ├── gke/                  # private zonal cluster, Spot nodes, Calico NetworkPolicy, shielded nodes (secure_boot + integrity_monitoring), master_global_access
│       ├── iam/                  # 3 GSAs, WIF pool/provider pinned to ref==refs/heads/main AND (push OR workflow_dispatch)
│       ├── artifact-registry/    # Docker repo
│       └── monitoring/           # email channel, uptime check, alert policy with auto_close
├── .github/workflows/build-deploy.yml   # PR + main: hadolint → Trivy + SBOM → Artifact Registry push → helm via Connect Gateway
└── docs/
    └── runbook.md                # "API returns 5xx" runbook
```

---

## Architecture (2-paragraph)

**Fully private zonal GKE cluster** (`europe-west1-b`) in a custom VPC with secondary ranges for pods (`10.1.0.0/16`) and services (`10.2.0.0/20`) — pods get real VPC IPs (= AWS VPC CNI). The master endpoint is private (`enablePrivateEndpoint=true`) + `master_global_access`; CI/CD reaches `kube-apiserver` through **Connect Gateway** (Fleet membership) — proxied via Google APIs, no public exposure, no VPN. Cloud NAT lets private nodes reach the internet. Node pool: `e2-medium` × 2–4 **Spot** VMs with shielded boot + integrity monitoring; cluster-wide Calico NetworkPolicy enabled. Workload Identity binds a Kubernetes SA (`payment-api/payment-api`) to a GCP SA (`payment-api-sa`) — pods access Secret Manager and Cloud Trace without static keys (= AWS IRSA). The GSA has a **resource-scoped** `secretAccessor` on a single secret. The CI/CD GSA holds `roles/container.clusterViewer` at the IAM layer (read-only entry) + a **namespace-scoped K8s `RoleBinding`** (`Role/ci-deployer` in `payment-api`) — least-privilege CI-to-GKE: cannot read foreign-namespace Secrets, cannot exec into pods, cannot create namespaces or RoleBindings.

CI/CD is GitHub Actions: hadolint → docker buildx + **Trivy** (HIGH/CRITICAL fail, markdown summary in `$GITHUB_STEP_SUMMARY`, **CycloneDX SBOM** uploaded as workflow artifact) → push to Artifact Registry → `helm upgrade --atomic --wait` with **guarded `--rollback on failure`**. Auth to GCP is **Workload Identity Federation** with the attribute condition `repository AND ref==refs/heads/main AND (event=push OR event=workflow_dispatch)` — no SA keys, no token issuance from feature branches/forks/non-main dispatches. Deploy job runs inside a GitHub `environment` (Settings → Environments → `dev`/`staging`/`prod`) so required reviewers + branch policy act as a second gate independent of WIF. PR runs build+scan locally for the gate but do not push images or deploy. Pods run under PSA **`restricted`** (read-only root FS + non-root UID + `seccompProfile: RuntimeDefault` + dropped capabilities) with 2 replicas spread across nodes via topology constraints + soft anti-affinity, so a Spot reclaim of one node drops at most one replica and the surviving replica keeps serving. Observability: uvicorn structured-JSON logs → Cloud Logging; OpenTelemetry FastAPI → Cloud Trace; Cloud Monitoring uptime check on the reserved global static IP `34.117.51.222` from 6 prober regions, alert policy → email channel; alerts `auto_close` after 30 min.

---

## Prerequisites

- GCP project with billing enabled
- `gcloud` SDK + `gke-gcloud-auth-plugin`, `terraform >= 1.0`, `helm v3`, `docker`
- GCS bucket for Terraform state (one-time, manual — chicken-and-egg with TF):
  ```bash
  gsutil mb -p YOUR_PROJECT -l europe-west1 gs://tfstate-YOUR_PROJECT
  gsutil versioning set on gs://tfstate-YOUR_PROJECT
  ```
- Local `gcloud auth login` + `gcloud auth application-default login`

---

## Step 1 — Terraform init/apply

```bash
cd terraform

cp backend.tf.example backend.tf
# edit backend.tf, set bucket and prefix

cp terraform.tfvars.example terraform.tfvars
# edit: project_id, github_repository, alert_email

terraform init
terraform plan
terraform apply
```

Apply order (driven by `depends_on`):
1. `google_project_service.apis` — 13 GCP APIs enabled in code
2. `module.vpc` + `module.iam` (parallel)
3. `module.gke` (depends on iam+vpc; creates WI pool)
4. `module.artifact_registry`, `module.monitoring`, `secret`, `static IP`
5. `google_gke_hub_membership` (Fleet membership, depends_on module.gke)
6. `google_service_account_iam_member.payment_api_wi_binding` (KSA→GSA, depends on cluster's WI pool)
7. `google_secret_manager_secret_iam_member.payment_api_secret_accessor` (resource-scoped accessor)
8. `google_project_iam_member.github_actions_gkehub_*` (CI/CD can use Connect Gateway)

After apply, **add the secret value** (TF only creates the empty secret):

```bash
echo -n "your-secret-value" | gcloud secrets versions add payment-api-key \
  --data-file=- --project=YOUR_PROJECT
```

Also bootstrap the **namespace + CI RBAC** (one-time, by a project Owner). CI runs as `github-actions-sa` and has only `roles/container.clusterViewer` at the IAM layer — it can authenticate to the cluster API and read-only globally, but cannot create namespaces or RoleBindings. Namespace-scoped write is granted by `k8s/rbac-ci.yaml` (`Role/ci-deployer` + `RoleBinding` to the GSA email, in the `payment-api` namespace). PSA `restricted` labels live on the namespace.

```bash
# Auth as Owner via Connect Gateway
gcloud container fleet memberships get-credentials payment-api-cluster --project=YOUR_PROJECT

# Apply the bootstrap manifests (idempotent — safe to re-run)
kubectl apply -f k8s/namespace.yaml -f k8s/rbac-ci.yaml
```

Useful outputs:
```bash
terraform output workload_identity_provider
terraform output github_actions_gsa_email
terraform output artifact_registry_url
terraform output ingress_static_ip
terraform output fleet_membership_id
```

---

## Step 2 — Configure GitHub Actions secrets & vars

```bash
gh secret set GCP_WORKLOAD_IDENTITY_PROVIDER \
  --body "$(terraform -chdir=terraform output -raw workload_identity_provider)" \
  --repo OWNER/REPO

gh secret set GCP_SERVICE_ACCOUNT \
  --body "$(terraform -chdir=terraform output -raw github_actions_gsa_email)" \
  --repo OWNER/REPO

# Route deploys through Connect Gateway (required — endpoint is fully private)
gh variable set USE_CONNECT_GATEWAY --body "true" --repo OWNER/REPO
```

Everything else (project ID, region, cluster name, AR host) is in `env:` of [.github/workflows/build-deploy.yml](.github/workflows/build-deploy.yml).

---

## Step 3 — Trigger the pipeline

Auto: push to `main`. Manual:
```bash
gh workflow run build-deploy.yml --ref main --field environment=dev
```

Pipeline triggers: `push: main`, `pull_request: main`, `workflow_dispatch`. PR runs **lint + build + Trivy + SBOM** for the gate; image push and helm deploy run only on main / dispatch (WIF attribute condition enforces this server-side at the GCP STS layer).

Pipeline does:
1. **lint** — hadolint on `app/Dockerfile`, fail on error
2. **build-scan-push** — docker buildx → Trivy JSON (HIGH/CRITICAL fail, `ignore-unfixed=true`) + **CycloneDX SBOM** uploaded as workflow artifact (30 d retention) → markdown summary into `$GITHUB_STEP_SUMMARY` → on main / dispatch: push to Artifact Registry with tag `<sha-first-12>`
3. **deploy** (main / dispatch only) — WIF auth → kubeconfig via `get-gke-credentials --use_connect_gateway=true` → `helm upgrade --install --atomic --wait --timeout 5m` with `-f values.yaml -f values-<env>.yaml`. Namespace + RBAC are bootstrap infra (applied once by Owner; CI no longer has permissions to create them).

**Rollback:** `--atomic` triggers automatic rollback on readiness failure; an explicit `if: failure()` step then runs `helm rollback` with a **guard** for the no-previous-revision case (first install: --atomic already cleaned up, skip).

---

## Step 4 — Verify deployment

```bash
# Cluster is private — must use Connect Gateway
gcloud container fleet memberships get-credentials payment-api-cluster --project=YOUR_PROJECT

kubectl -n payment-api get pods,svc,ingress,sa,pdb,netpol,hpa
# 2 pods Running 1/1 on different nodes (topology spread)
# service ClusterIP
# ingress address = 34.117.51.222 (reserved static IP)
# sa payment-api has annotation iam.gke.io/gcp-service-account: payment-api-sa@...

curl http://34.117.51.222/health
# {"status":"ok"}

curl -i http://34.117.51.222/ready
# HTTP/1.1 200 OK
# {"status":"ready"}
```

**HTTP 200 on `/ready`** = Workload Identity works end-to-end (KSA→GSA→Secret Manager). On secret-load failure `/ready` returns **HTTP 503 `{"status":"not_ready"}`** (no internal state in body); the pod is removed from the Service endpoints and the uptime check alert fires.

---

## NetworkPolicy

Cluster-wide Calico NetworkPolicy is enabled. The chart ships an **ingress-only** policy targeting `app: payment-api`:

- Allow LB health-check ranges (`35.191.0.0/16`, `130.211.0.0/22`, `209.85.152.0/22`, `209.85.204.0/22`) on the app port
- Allow kubelet probes from the node CIDRs (`10.0.0.0/24`, `10.0.1.0/24`)
- Allow same-namespace traffic
- Deny everything else inbound

**Egress is intentionally not filtered.** GKE Dataplane V1 (Calico) does not reliably match `ipBlock` rules against link-local destinations (`169.254.169.254` for Workload Identity metadata, `169.254.20.10` for NodeLocal DNS cache) because the iptables DNAT to `gke-metadata-server` / NodeLocal DNS happens around Calico's egress filter path. An egress NetworkPolicy on these IPs either silently fails to allow them (breaking Workload Identity + DNS, pod hangs with zero log output) or has no effect even when defined. The defense-in-depth egress restriction belongs on GKE Dataplane V2 (eBPF) or a sidecar proxy — out of scope here.

---

## Logging filter (paste into Cloud Logging → Logs Explorer)

```
resource.type="k8s_container"
resource.labels.cluster_name="payment-api-cluster"
resource.labels.namespace_name="payment-api"
resource.labels.container_name="payment-api"
```

App and uvicorn loggers emit **structured JSON** with `severity`/`timestamp` fields parsed natively. For errors only: append `severity>=ERROR`.

---

## Tracing

OpenTelemetry auto-instruments FastAPI. Spans → Cloud Trace via `opentelemetry-exporter-gcp-trace` + GSA role `roles/cloudtrace.agent`. View at **Trace Explorer**, filter by `Service: payment-api`.

Tracing exporter init has `try/except` fallback for local/CI environments without ADC — app starts even when Cloud Trace credentials are missing.

---

## Monitoring + alert

| What | Where |
|---|---|
| Uptime check | Cloud Monitoring → Uptime checks → `payment-api-health` (HTTP GET `/health` every 60s, 6 prober regions) |
| Alert policy | Cloud Monitoring → Alerting → `payment-api-uptime-failure` (fires if check fails ≥120s, **auto_close after 30 min**) |
| Notification | email channel `On-call Email` → configured in `alert_email` tfvar |

Threshold rationale: 120s = 2 consecutive failed checks at 60s period — avoids single-prober flapping.

---

## HA design (Spot VM tolerance)

Node pool is `e2-medium` × 2–4 **Spot** VMs (autoscaler). Spot is the modern replacement for preemptible: ~60-91% discount, no hard 24 h cap, gradual preemption signals.

Application defaults (dev + staging):
- `replicaCount: 2` + `topologySpreadConstraints` (maxSkew=1 / hostname / ScheduleAnyway) + soft `podAntiAffinity`
- `PodDisruptionBudget` minAvailable=1

A single Spot reclaim drops one replica; the surviving replica on the other node keeps serving (0 externally-visible downtime). Cluster autoscaler provisions a replacement node; the second replica reschedules onto it.

Staging additionally enables `HorizontalPodAutoscaler` (CPU 70 %, 2–5 replicas).

---

## Runbook

[docs/runbook.md](docs/runbook.md) — concrete 6-step procedure for "API returns 5xx" with exact filters, kubectl commands, GCE backend health checks, escalation table. Includes Connect Gateway kubectl access for the private endpoint.

---

## Trade-offs (1-paragraph)

The cluster is **zonal in `europe-west1-b`** to fit GCP free-trial CPU/disk quotas and to provision in ~10 min vs 30+; production path is regional (3-zone control plane + nodes). Nodes are `e2-medium` Spot (was `e2-small` preemptible — CPU starvation from system DaemonSets caused kube-dns HA replica to stay Pending and app pods to fail startup probes; `e2-medium` with ~1930m allocatable per node fixed it; Spot replaces preemptible for the modern 24h-cap-less semantics). The control-plane endpoint is **fully private** with `master_authorized_networks=10.0.0.0/8` + `master_global_access`; CI/CD reaches `kube-apiserver` through Connect Gateway via Fleet membership (no VPN, no peering). Service is exposed via **GCE Ingress** on a **reserved global static IP** — survives Ingress recreations, keeps the uptime check stable. Trivy gate uses JSON output + markdown summary in `$GITHUB_STEP_SUMMARY` + a separate `Fail on HIGH/CRITICAL` step; `ignore-unfixed=true` suppresses noise from CVEs with no available patch, and the **multi-stage Dockerfile** strips `pip/setuptools/wheel/jaraco.context` from the runtime image. CI identity uses `roles/container.clusterViewer` (read-only IAM entry) + a namespace-scoped K8s RoleBinding (`Role/ci-deployer`) — IAM conditions on `container.developer` do not evaluate reliably for K8s sub-resources in GKE, so the canonical least-privilege pattern moves authority into K8s RBAC. The WIF attribute condition pins `ref==refs/heads/main` AND `(event_name in {push, workflow_dispatch})`, so feature-branch / fork / non-main-dispatch workflows cannot mint a GCP token. CI's Artifact Registry writer is **repo-scoped** (single `payment-api` repo), not project-wide. Deploy job is wired to a GitHub `environment` for required-reviewer gating independent of WIF. NetworkPolicy is ingress-only on GKE Dataplane V1 because Calico does not reliably filter egress to link-local IPs (Workload Identity + NodeLocal DNS break otherwise); production hardening would migrate to Dataplane V2 (eBPF) and re-enable egress filtering. CI builds use `github.sha` short tag; supply-chain hardening would add image **digest pinning** + `cosign sign` + Binary Authorization policy.

## Out of scope

- Real payment logic / PCI compliance — name only.
- Multi-region failover / DR.
- HTTPS on Ingress (managed cert + custom domain).
- Image digest pinning + signing (next step in supply chain hardening).
- **GitHub Code Scanning (SARIF)** — requires GitHub Advanced Security on private repos. The Trivy `Fail on HIGH/CRITICAL` step is the authoritative gate; the CycloneDX SBOM is uploaded as a workflow artifact (30 d retention) and would be ingested by an external dependency-track / Trivy server in production.
- **NetworkPolicy egress filtering** — requires GKE Dataplane V2 (eBPF) on the cluster. Current Calico (Dataplane V1) cannot reliably filter link-local IPs needed by Workload Identity + NodeLocal DNS.
