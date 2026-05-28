output "cluster_name" {
  value       = module.gke.cluster_name
  description = "GKE cluster name for use in CI/CD and Helm"
}

output "region" {
  value       = module.gke.region
  description = "GCP region where cluster is deployed"
}

output "gsa_email" {
  value       = module.iam.payment_api_gsa_email
  description = "Payment API GSA email — used as Helm values serviceAccount annotation"
}

output "github_actions_gsa_email" {
  value       = module.iam.github_actions_gsa_email
  description = "GitHub Actions GSA email — used in WIF GitHub secret GCP_SERVICE_ACCOUNT"
}

output "workload_identity_provider" {
  value       = module.iam.workload_identity_provider
  description = "WIF provider resource name — used in GitHub secret GCP_WORKLOAD_IDENTITY_PROVIDER"
}

output "artifact_registry_url" {
  value       = module.artifact_registry.repository_url
  description = "Artifact Registry Docker repo URL — used in CI/CD for image push/pull"
}

output "secret_resource_name" {
  value       = google_secret_manager_secret.api_key.name
  description = "Secret Manager secret resource name — app reads this at runtime"
}

output "ingress_static_ip" {
  value       = google_compute_global_address.ingress_ip.address
  description = "Reserved global static IP for GCE Ingress (staging/prod). Use for uptime check host."
}

output "fleet_membership_id" {
  value       = google_gke_hub_membership.primary.membership_id
  description = "Fleet membership ID — used by CI for Connect Gateway access (Phase B)."
}
