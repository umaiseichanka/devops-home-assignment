variable "project_id" {
  type = string
}

variable "region" {
  type = string
}

variable "zone" {
  type        = string
  description = "Zone for zonal cluster (location). Set to override regional default."
  default     = ""
}

variable "cluster_name" {
  type = string
}

variable "network" {
  type = string
}

variable "subnetwork" {
  type = string
}

variable "secondary_range_pods" {
  type = string
}

variable "secondary_range_services" {
  type = string
}

variable "node_service_account" {
  type        = string
  description = "GCP SA email used by GKE nodes (not app pods)"
}

variable "master_authorized_networks" {
  type = list(object({
    cidr_block   = string
    display_name = string
  }))
  default = [
    {
      cidr_block   = "0.0.0.0/0"
      display_name = "all"
    }
  ]
}
