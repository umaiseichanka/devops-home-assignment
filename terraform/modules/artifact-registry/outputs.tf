output "repository_url" {
  value       = "${var.region}-docker.pkg.dev/${var.project_id}/${var.repository_id}"
  description = "Full Docker image URL prefix: REGION-docker.pkg.dev/PROJECT/REPO"
}

output "repository_id" {
  value       = google_artifact_registry_repository.docker.repository_id
  description = "Artifact Registry repository ID (short name)"
}

output "repository_location" {
  value       = google_artifact_registry_repository.docker.location
  description = "Artifact Registry repository location/region"
}
