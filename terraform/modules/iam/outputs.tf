output "payment_api_gsa_email" {
  value = google_service_account.payment_api.email
}

output "github_actions_gsa_email" {
  value = google_service_account.github_actions.email
}

output "gke_node_sa_email" {
  value = google_service_account.gke_node.email
}

output "workload_identity_provider" {
  value = google_iam_workload_identity_pool_provider.github.name
}
