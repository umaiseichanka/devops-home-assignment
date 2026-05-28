# Required GCP APIs — managed via Terraform per assignment
# disable_on_destroy=false: don't disable APIs on `terraform destroy`
# (other resources in the project might depend on them)

locals {
  required_apis = [
    "compute.googleapis.com",              # VPC, subnets, NAT, static IP
    "container.googleapis.com",            # GKE
    "iam.googleapis.com",                  # Service accounts, IAM
    "iamcredentials.googleapis.com",       # WIF token exchange
    "sts.googleapis.com",                  # WIF
    "secretmanager.googleapis.com",        # Secret Manager
    "artifactregistry.googleapis.com",     # Docker repo
    "monitoring.googleapis.com",           # Cloud Monitoring, uptime, alerts
    "logging.googleapis.com",              # Cloud Logging
    "cloudtrace.googleapis.com",           # Distributed tracing
    "gkehub.googleapis.com",               # Fleet membership for Connect Gateway (Phase B)
    "connectgateway.googleapis.com",       # Connect Gateway for private cluster CI access
    "cloudresourcemanager.googleapis.com", # IAM resource manager
  ]
}

resource "google_project_service" "apis" {
  for_each           = toset(local.required_apis)
  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}
