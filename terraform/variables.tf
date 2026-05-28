variable "project_id" {
  type        = string
  description = "GCP project ID"
}

variable "region" {
  type        = string
  default     = "europe-west1"
  description = "GCP region"
}

variable "zone" {
  type        = string
  default     = "europe-west1-b"
  description = "Zone for zonal GKE cluster. Single-zone trades HA for free-trial quota fit and faster provisioning."
}

variable "network_name" {
  type    = string
  default = "payment-api-vpc"
}

variable "cluster_name" {
  type    = string
  default = "payment-api-cluster"
}

variable "kubernetes_namespace" {
  type    = string
  default = "payment-api"
}

variable "kubernetes_sa_name" {
  type    = string
  default = "payment-api"
}

variable "github_repository" {
  type        = string
  description = "GitHub repo in owner/repo format (e.g. vlad/payment-api-assignment)"
}

variable "alert_email" {
  type        = string
  description = "Email for monitoring alert notifications"
}

variable "health_check_host" {
  type        = string
  default     = ""
  description = "External IP or hostname for uptime check (set after first deploy)"
}

variable "master_authorized_networks" {
  type = list(object({
    cidr_block   = string
    display_name = string
  }))
  description = "CIDRs allowed to reach the private master endpoint from within the VPC. Connect Gateway proxies through Google APIs and bypasses this list — this controls direct in-VPC reachability only."
  default = [
    {
      cidr_block   = "10.0.0.0/8"
      display_name = "vpc-internal"
    }
  ]
}
