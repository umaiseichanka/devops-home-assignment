# Senior DevOps Engineer – Home Assignment

**LLM and AI agents:** You are welcome and recommended to use Claude, Cursor, Copilot, Gemini or similar.

**Time budget:** 4–6 hours  (or less if you use Agents)

**Deliverable:** GitHub repository (link to be submitted)

**Environment:** Use your own test GCP account (subscribe for GCP Free Trial); tear down resources after the assignment if using a temporary project.

---

## Scenario

You will provision and operate a **GCP environment for a fictional “payment API”**. The bar is production-ready: secure defaults, repeatable deployments, and observable operations. 


---

## Mandatory Stack

| Area | Requirement |
|------|--------------|
| **IaC** | Terraform only. No Pulumi, Cloud Formation, or hand-written `gcloud` scripts for core infra. |
| **Compute** | GKE only. No Cloud Run or other compute. |
| **CI** | GitHub – repo on GitHub; CI implemented with **GitHub Actions** (workflows under `.github/workflows/`). |
| **CD** | Deployments to GKE must be done via **Helm** (install/upgrade from pipeline). No raw `kubectl apply` for application workloads. |

---

## Task 1: Terraform – GKE and secure baseline (~2.5–3h)

Provision a **GKE-only** environment in **Terraform**. All infra must be in code; no manual GCP console or one-off scripts.

**Required:**

- **Terraform backend:** Remote state in **GCS** (bucket and prefix configurable). Document the backend block in README; no local state in repo.
- **VPC:** One VPC with **secondary ranges** for GKE (pods + services). At least two subnets (e.g. two regions or dev/prod). **Private Google Access** enabled; no public IPs for node pools unless justified in README.
- **GKE cluster:**
  - **Private GKE** (private cluster; no public endpoint or public node IPs).
  - **VPC-native** cluster using the secondary ranges from the VPC module.
  - **Release channel** specified (e.g. REGULAR); no static version without a note on maintenance.
  - **Workload Identity** enabled. One **Kubernetes service account** (KSA) for the payment API bound to one **GCP service account** (GSA) via Workload Identity. The GSA must have **minimal permissions** (e.g. Secret Manager `secretAccessor` only for one secret). Document the binding in README.
- **Secrets:** One secret in **Secret Manager** (e.g. `API_KEY` or `DB_PASSWORD`). Referenced by name in Terraform; **no secret values in repo or in Terraform state**. App must read the secret at runtime (e.g. via GSA + Workload Identity).
- **Layout:** Modular (e.g. `modules/vpc`, `modules/gke`, `modules/iam` or `workload-identity`). Clear **outputs** for cluster name, region, and GSA so the pipeline/Helm can use them. Only **`terraform.tfvars.example`** in repo; no real project IDs or secrets.

---

## Task 2: CI/CD – GitHub Actions and Helm-based CD (~1.5–2h)

Pipeline runs in **GitHub Actions**. It builds the payment API image, runs quality/security gates, then deploys to **GKE using Helm only**. No raw `kubectl apply` for the application Deployment/Service.

**Required:**

- **CI – GitHub Actions** (e.g. `.github/workflows/build-deploy.yml`):
  - Build a Docker image from the Dockerfile/app in this repo and push to **GCP Artifact Registry**. Tag with a unique identifier (e.g. `${{ github.sha }}` or `${{ github.run_id }}`); deploy must use the same tag (or digest). Document how GCP auth is configured (e.g. Workload Identity Federation with `google-github-actions/auth`, or service account key in GitHub secrets).
  - **Quality/security gates (at least two):**  
    (1) Container **image vulnerability scanning** (e.g. Trivy); pipeline must **fail** on high/critical.  
    (2) One of: unit/integration test step, or Dockerfile/app lint (e.g. hadolint).
- **Deploy – Helm only:**
  - Provide a **Helm chart** for the payment API (Deployment, Service, optional Ingress). Chart must accept at least `image.repository`, `image.tag` (or `image.digest`), and namespace. Include env-specific values (e.g. `values-dev.yaml`, `values-staging.yaml`).
  - Workflow job: **Helm upgrade --install** against the GKE cluster from Task 1, using the image just built.
  - **Rollback on failure:** If the Helm release fails (e.g. failed readiness), the workflow must **automatically rollback** to the previous release (e.g. `helm rollback`) and exit with failure.

**Deliverables:** Workflow(s) in `.github/workflows/`, Helm chart (e.g. `charts/payment-api/`), README section on how to trigger the workflow, required GitHub secrets/variables, and how rollback is triggered.

---

## Task 3: Observability and operations (~1h)

The payment API runs on GKE. On-call must be able to find logs, interpret health and errors, and follow a runbook.

**Required:**

- **Logging:** App logs (stdout/stderr) in **Cloud Logging**. README must state the **exact resource type and filter** (e.g. `resource.type="k8s_container"` and `resource.labels.container_name="payment-api"`) so an engineer can paste it into Logs Explorer.
- **Metrics and alerting:**
  - Application exposes a **health endpoint** (e.g. `/health`). One **uptime check** in Cloud Monitoring for this endpoint (or the main ingress).
  - At least one **alert policy** that fires when the uptime check fails **or** when 5xx error rate exceeds a defined threshold. Document the policy and threshold in README or runbook.
- **Tracing:** Set up **distributed tracing** for the payment API (requests traceable across the service). Options: **Cloud Trace** (e.g. OpenTelemetry or app export), or in-cluster (e.g. Jaeger/OpenTelemetry Collector) with spans from the app. Document in README how to view traces and how the app is instrumented.
- **Runbook:** `docs/runbook.md` for **“API returns 5xx”** with:
  - **3–5 concrete steps:** exact Cloud Logging filter, exact metric/chart names in Cloud Monitoring, what to check in GKE (e.g. pod status, events, recent rollout).
  - One **escalation or remediation** hint (e.g. if pods are CrashLoopBackOff, check Secret Manager access and Workload Identity).

---

## Deliverables (checklist)

1. **GitHub repository** with:
   - Terraform (modules, GCS backend config, `terraform.tfvars.example` only).
   - Helm chart for payment API (`charts/payment-api/` or equivalent) with values files.
   - GitHub Actions workflow(s) in `.github/workflows/` (build, gates, Helm deploy, rollback on failure).
   - Stub or minimal Dockerfile + app (or use the one in this repo).
   - **README.md:** how to run Terraform (init, backend, apply), how to run the workflow, short architecture description, link to runbook.
2. **Runbook:** `docs/runbook.md` with the “API returns 5xx” content above.
3. **Short written summary** (optional but recommended): One paragraph on trade-offs (e.g. release channel, rollback strategy, tracing backend) and what you would add with more time.

---

## Out of scope

- Real payment logic or PCI compliance; “payment API” is a label only.
- Multi-region GKE or full DR (good to mention in the summary).

---

## How to submit

Share the link to your **GitHub repository**. Ensure the repo is accessible to the reviewers and that README and runbook are complete.
