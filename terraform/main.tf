terraform {
  required_version = ">= 1.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

module "vpc" {
  source       = "./modules/vpc"
  project_id   = var.project_id
  region       = var.region
  network_name = var.network_name

  depends_on = [google_project_service.apis]
}

module "iam" {
  source               = "./modules/iam"
  project_id           = var.project_id
  kubernetes_namespace = var.kubernetes_namespace
  kubernetes_sa_name   = var.kubernetes_sa_name
  github_repository    = var.github_repository
  cluster_name         = var.cluster_name
  cluster_location     = var.zone != "" ? var.zone : var.region

  depends_on = [google_project_service.apis]
}

module "gke" {
  source                     = "./modules/gke"
  project_id                 = var.project_id
  region                     = var.region
  zone                       = var.zone
  cluster_name               = var.cluster_name
  network                    = module.vpc.network_name
  subnetwork                 = module.vpc.dev_subnet_name
  secondary_range_pods       = module.vpc.dev_pods_range_name
  secondary_range_services   = module.vpc.dev_services_range_name
  node_service_account       = module.iam.gke_node_sa_email
  master_authorized_networks = var.master_authorized_networks

  depends_on = [module.iam, module.vpc]
}

# KSA → GSA Workload Identity binding
# Must run after GKE cluster creates the pool (PROJECT.svc.id.goog)
resource "google_service_account_iam_member" "payment_api_wi_binding" {
  service_account_id = "projects/${var.project_id}/serviceAccounts/${module.iam.payment_api_gsa_email}"
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[${var.kubernetes_namespace}/${var.kubernetes_sa_name}]"

  depends_on = [module.gke]
}

module "artifact_registry" {
  source        = "./modules/artifact-registry"
  project_id    = var.project_id
  region        = var.region
  repository_id = "payment-api"
}

# Repo-scoped AR writer for CI/CD GSA — project-wide writer was overbroad
# (CI could push to any AR repo in project). This binding limits push to
# the single payment-api repository.
resource "google_artifact_registry_repository_iam_member" "github_actions_ar_writer" {
  project    = var.project_id
  location   = module.artifact_registry.repository_location
  repository = module.artifact_registry.repository_id
  role       = "roles/artifactregistry.writer"
  member     = "serviceAccount:${module.iam.github_actions_gsa_email}"
}

# Reserved global static IP for the GCE Ingress (used by staging/production env).
# Stable IP that survives Ingress recreations; required for Cloud Monitoring
# uptime check to keep working without re-applying Terraform.
resource "google_compute_global_address" "ingress_ip" {
  project = var.project_id
  name    = "payment-api-ingress-ip"

  depends_on = [google_project_service.apis]
}

# Fleet membership — pre-req for Connect Gateway access to fully private cluster.
# Created now (no impact while cluster has public endpoint); used in Phase B
# when enable_private_endpoint is flipped to true.
resource "google_gke_hub_membership" "primary" {
  project       = var.project_id
  membership_id = var.cluster_name
  location      = "global"

  endpoint {
    gke_cluster {
      resource_link = "//container.googleapis.com/projects/${var.project_id}/locations/${var.zone}/clusters/${var.cluster_name}"
    }
  }

  depends_on = [module.gke]
}

# CI/CD SA permissions for Connect Gateway access (Phase B).
resource "google_project_iam_member" "github_actions_gkehub_gateway" {
  project = var.project_id
  role    = "roles/gkehub.gatewayEditor"
  member  = "serviceAccount:${module.iam.github_actions_gsa_email}"
}

resource "google_project_iam_member" "github_actions_gkehub_viewer" {
  project = var.project_id
  role    = "roles/gkehub.viewer"
  member  = "serviceAccount:${module.iam.github_actions_gsa_email}"
}

module "monitoring" {
  source            = "./modules/monitoring"
  project_id        = var.project_id
  alert_email       = var.alert_email
  health_check_host = var.health_check_host
}

# Secret Manager secret — value added manually, never in Terraform
# App reads this at runtime via Workload Identity + Secret Manager SDK
resource "google_secret_manager_secret" "api_key" {
  secret_id = "payment-api-key"
  project   = var.project_id

  replication {
    auto {}
  }

  depends_on = [google_project_service.apis]
}

# Scoped accessor: GSA can read ONLY this one secret (not all secrets in project)
resource "google_secret_manager_secret_iam_member" "payment_api_secret_accessor" {
  project   = var.project_id
  secret_id = google_secret_manager_secret.api_key.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${module.iam.payment_api_gsa_email}"
}
