output "cluster_name" {
  value = google_container_cluster.primary.name
}

output "region" {
  value = google_container_cluster.primary.location
}

output "cluster_ca_certificate" {
  value     = google_container_cluster.primary.master_auth[0].cluster_ca_certificate
  sensitive = true
}

output "endpoint" {
  value     = google_container_cluster.primary.endpoint
  sensitive = true
}
