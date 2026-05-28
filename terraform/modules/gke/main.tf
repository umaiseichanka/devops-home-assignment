resource "google_container_cluster" "primary" {
  name     = var.cluster_name
  location = var.zone != "" ? var.zone : var.region
  project  = var.project_id

  # Delete default node pool immediately — we manage our own
  remove_default_node_pool = true
  initial_node_count       = 1

  # Minimal default pool — created then deleted, but quota counted during creation.
  # pd-standard avoids SSD_TOTAL_GB quota; 30GB fits COS image and matches the
  # primary pool size.
  node_config {
    machine_type = "e2-medium"
    disk_size_gb = 30
    disk_type    = "pd-standard"
  }

  network    = var.network
  subnetwork = var.subnetwork

  # VPC-native (alias IP ranges)
  # AWS parallel: this is like EKS VPC CNI — pod IPs come from VPC CIDR, not overlay
  ip_allocation_policy {
    cluster_secondary_range_name  = var.secondary_range_pods
    services_secondary_range_name = var.secondary_range_services
  }

  # Fully private cluster — no public master endpoint, no public node IPs.
  # CI/CD reaches kube-apiserver via Connect Gateway (Fleet), not the public
  # endpoint. master_authorized_networks below limits in-VPC reachability;
  # Connect Gateway routes through Google APIs and bypasses this list.
  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = true
    master_ipv4_cidr_block  = "172.16.0.0/28"

    # Allow private endpoint to be reached from any region in the VPC, not
    # just the cluster region. Connect Gateway works either way; this is
    # required when add VPC peering or hub-spoke topology later.
    master_global_access_config {
      enabled = true
    }
  }

  master_authorized_networks_config {
    dynamic "cidr_blocks" {
      for_each = var.master_authorized_networks
      content {
        cidr_block   = cidr_blocks.value.cidr_block
        display_name = cidr_blocks.value.display_name
      }
    }
  }

  # NetworkPolicy support — must enable both the addon and the cluster-level
  # network_policy block. Without this, NetworkPolicy CRDs are a no-op and
  # every pod can talk to every other pod.
  network_policy {
    enabled  = true
    provider = "CALICO"
  }

  addons_config {
    network_policy_config {
      disabled = false
    }
  }

  release_channel {
    channel = "REGULAR"
  }

  # Workload Identity — pods get GCP credentials without SA keys
  # AWS parallel: IRSA (IAM Roles for Service Accounts) on EKS
  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  master_auth {
    client_certificate_config {
      issue_client_certificate = false
    }
  }

  deletion_protection = false

  # Default node pool is removed (remove_default_node_pool = true). TF state
  # carries over the primary pool's node_config attrs after refresh, causing
  # bogus drift (e.g. preemptible) that would force cluster replacement.
  lifecycle {
    ignore_changes = [
      node_config,
      node_pool,
    ]
  }

  # Private cluster + regional control plane provisioning can exceed 40m default
  timeouts {
    create = "60m"
    update = "60m"
    delete = "30m"
  }
}

resource "google_container_node_pool" "primary_nodes" {
  name     = "${var.cluster_name}-node-pool"
  location = var.zone != "" ? var.zone : var.region
  cluster  = google_container_cluster.primary.name
  project  = var.project_id

  initial_node_count = 2

  # min=2 keeps a warm node when a single Spot VM is reclaimed — application
  # pods are spread across both nodes so one preemption never empties the
  # service. max=4 gives autoscaler headroom for rolling updates + the
  # second kube-dns replica (previously stuck Pending on e2-small).
  autoscaling {
    min_node_count = 2
    max_node_count = 4
  }

  node_config {
    # e2-medium: 2 vCPU + 4 GiB. e2-small had ~940m allocatable CPU which
    # was 91-98% pinned by system DaemonSets (calico-node + gke-metadata-
    # server + fluent-bit + kube-proxy), causing app pods to starve and
    # kube-dns HA replica to stay Pending. e2-medium gives ~1930m
    # allocatable per node.
    machine_type = "e2-medium"
    disk_size_gb = 30
    disk_type    = "pd-standard"

    # Spot VMs: modern replacement for preemptible. Same ~60-91% discount,
    # no hard 24h lifetime cap, gradual preemption signals via systemd, and
    # better fleet-level signals. Single Spot can still be preempted any
    # time — HA is provided by replicaCount: 2 + topologySpreadConstraints.
    spot = true

    service_account = var.node_service_account
    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform",
    ]

    # Required for Workload Identity on nodes
    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  timeouts {
    create = "45m"
    update = "45m"
    delete = "30m"
  }
}
