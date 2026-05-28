output "network_name" {
  value = google_compute_network.vpc.name
}

output "network_self_link" {
  value = google_compute_network.vpc.self_link
}

output "dev_subnet_name" {
  value = google_compute_subnetwork.dev.name
}

output "dev_subnet_self_link" {
  value = google_compute_subnetwork.dev.self_link
}

output "dev_pods_range_name" {
  value = "dev-pods"
}

output "dev_services_range_name" {
  value = "dev-services"
}
