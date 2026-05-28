variable "project_id" {
  type = string
}

variable "kubernetes_namespace" {
  type = string
}

variable "kubernetes_sa_name" {
  type = string
}

variable "github_repository" {
  type        = string
  description = "GitHub repo in owner/repo format"
}

variable "cluster_name" {
  type        = string
  description = "GKE cluster name — kept for future namespace-scoped RBAC binding"
}

variable "cluster_location" {
  type        = string
  description = "GKE cluster location (zone for zonal, region for regional)"
}
