# GKE node SA — minimal permissions for node VMs
# AWS parallel: EC2 instance profile for EKS worker nodes
resource "google_service_account" "gke_node" {
  account_id   = "gke-node-sa"
  display_name = "GKE Node Service Account"
  project      = var.project_id
}

resource "google_project_iam_member" "gke_node_logging" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.gke_node.email}"
}

resource "google_project_iam_member" "gke_node_monitoring" {
  project = var.project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.gke_node.email}"
}

resource "google_project_iam_member" "gke_node_monitoring_viewer" {
  project = var.project_id
  role    = "roles/monitoring.viewer"
  member  = "serviceAccount:${google_service_account.gke_node.email}"
}

resource "google_project_iam_member" "gke_node_ar_reader" {
  project = var.project_id
  role    = "roles/artifactregistry.reader"
  member  = "serviceAccount:${google_service_account.gke_node.email}"
}

# Payment API app GSA — runtime identity for pods
# AWS parallel: IAM role assumed via IRSA
resource "google_service_account" "payment_api" {
  account_id   = "payment-api-sa"
  display_name = "Payment API Service Account"
  project      = var.project_id
}

# Secret-scoped accessor lives in root main.tf — needs the secret resource
# (avoid project-wide secretAccessor; assignment requires minimal permissions)

resource "google_project_iam_member" "payment_api_trace_agent" {
  project = var.project_id
  role    = "roles/cloudtrace.agent"
  member  = "serviceAccount:${google_service_account.payment_api.email}"
}

# Workload Identity binding lives in root main.tf — depends on GKE cluster creating the pool first

# GitHub Actions GSA — CI/CD pipeline identity
resource "google_service_account" "github_actions" {
  account_id   = "github-actions-sa"
  display_name = "GitHub Actions CI/CD"
  project      = var.project_id
}

# Artifact Registry writer is granted at REPOSITORY scope in root main.tf
# (google_artifact_registry_repository_iam_member.github_actions_ar_writer)
# — project-wide writer would let CI push to any AR repo in the project.

# Cluster entry: IAM-level read-only access to the cluster API + ability
# to call container.clusters.getCredentials. Nothing more at the IAM layer.
# Write access on workloads comes from a namespace-scoped K8s RBAC
# RoleBinding (k8s/rbac-ci.yaml) — least-privilege CI to GKE pattern.
#
# Why not roles/container.developer + IAM condition: GCP IAM conditions do
# not evaluate for container.* permissions on K8s sub-resources
# (container.namespaces.*, container.deployments.*, ...). They work for the
# legacy Container API verbs only. Documented limitation.
resource "google_project_iam_member" "github_actions_container_viewer" {
  project = var.project_id
  role    = "roles/container.clusterViewer"
  member  = "serviceAccount:${google_service_account.github_actions.email}"
}

# Workload Identity Federation pool (GitHub OIDC → GCP)
# AWS parallel: IAM OIDC provider for github.com/token.actions.githubusercontent.com
resource "google_iam_workload_identity_pool" "github" {
  workload_identity_pool_id = "github-pool"
  display_name              = "GitHub Actions Pool"
  project                   = var.project_id
}

resource "google_iam_workload_identity_pool_provider" "github" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = "github-provider"
  display_name                       = "GitHub OIDC"
  project                            = var.project_id

  attribute_mapping = {
    "google.subject"       = "assertion.sub"
    "attribute.actor"      = "assertion.actor"
    "attribute.repository" = "assertion.repository"
    "attribute.ref"        = "assertion.ref"
    "attribute.event_name" = "assertion.event_name"
  }

  # Scope WIF to:
  #   1. this specific repo
  #   2. main branch only (refs/heads/main) — applies to BOTH push and
  #      workflow_dispatch. Without the ref pin on dispatch, a contributor
  #      could push a backdoor branch and trigger `gh workflow run --ref X`
  #      to mint a token impersonating the CI/CD GSA.
  attribute_condition = <<-EOT
    assertion.repository == '${var.github_repository}' &&
    assertion.ref == 'refs/heads/main' &&
    (assertion.event_name == 'push' || assertion.event_name == 'workflow_dispatch')
  EOT

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

# Allow GitHub Actions to impersonate the CI/CD SA via WIF
resource "google_service_account_iam_member" "github_wif_binding" {
  service_account_id = google_service_account.github_actions.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.repository/${var.github_repository}"
}
