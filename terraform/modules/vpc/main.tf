resource "google_compute_network" "vpc" {
  name                    = var.network_name
  auto_create_subnetworks = false
  project                 = var.project_id
}

# Dev subnet — GKE cluster lives here
resource "google_compute_subnetwork" "dev" {
  name                     = "${var.network_name}-dev"
  ip_cidr_range            = "10.0.0.0/24"
  region                   = var.region
  network                  = google_compute_network.vpc.id
  project                  = var.project_id
  private_ip_google_access = true

  secondary_ip_range {
    range_name    = "dev-pods"
    ip_cidr_range = "10.1.0.0/16"
  }

  secondary_ip_range {
    range_name    = "dev-services"
    ip_cidr_range = "10.2.0.0/20"
  }
}

# Staging subnet — separate network segment
resource "google_compute_subnetwork" "staging" {
  name                     = "${var.network_name}-staging"
  ip_cidr_range            = "10.0.1.0/24"
  region                   = var.region
  network                  = google_compute_network.vpc.id
  project                  = var.project_id
  private_ip_google_access = true

  secondary_ip_range {
    range_name    = "staging-pods"
    ip_cidr_range = "10.3.0.0/16"
  }

  secondary_ip_range {
    range_name    = "staging-services"
    ip_cidr_range = "10.4.0.0/20"
  }
}

# Cloud NAT — private nodes need this to pull images / call external APIs
# AWS parallel: NAT Gateway in private subnet
resource "google_compute_router" "router" {
  name    = "${var.network_name}-router"
  region  = var.region
  network = google_compute_network.vpc.id
  project = var.project_id
}

resource "google_compute_router_nat" "nat" {
  name                               = "${var.network_name}-nat"
  router                             = google_compute_router.router.name
  region                             = var.region
  project                            = var.project_id
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
}
