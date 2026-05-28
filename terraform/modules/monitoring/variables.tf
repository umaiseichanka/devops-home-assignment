variable "project_id" {
  type = string
}

variable "alert_email" {
  type = string
}

variable "health_check_host" {
  type        = string
  default     = ""
  description = "External IP or hostname. Leave empty to skip uptime check creation."
}
