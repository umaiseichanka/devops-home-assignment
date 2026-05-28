resource "google_monitoring_notification_channel" "email" {
  display_name = "On-call Email"
  type         = "email"
  project      = var.project_id

  labels = {
    email_address = var.alert_email
  }
}

resource "google_monitoring_uptime_check_config" "payment_api_health" {
  count        = var.health_check_host != "" ? 1 : 0
  display_name = "payment-api-health"
  timeout      = "10s"
  period       = "60s"
  project      = var.project_id

  http_check {
    path         = "/health"
    port         = "80"
    use_ssl      = false
    validate_ssl = false
  }

  monitored_resource {
    type = "uptime_url"
    labels = {
      project_id = var.project_id
      host       = var.health_check_host
    }
  }
}

resource "google_monitoring_alert_policy" "uptime_alert" {
  count        = var.health_check_host != "" ? 1 : 0
  display_name = "payment-api-uptime-failure"
  combiner     = "OR"
  project      = var.project_id

  conditions {
    display_name = "Uptime check failed"
    condition_threshold {
      filter          = "metric.type=\"monitoring.googleapis.com/uptime_check/check_passed\" AND resource.type=\"uptime_url\" AND metric.label.check_id=\"${google_monitoring_uptime_check_config.payment_api_health[0].uptime_check_id}\""
      duration        = "120s"
      comparison      = "COMPARISON_LT"
      threshold_value = 1

      aggregations {
        alignment_period     = "60s"
        per_series_aligner   = "ALIGN_NEXT_OLDER"
        cross_series_reducer = "REDUCE_COUNT_TRUE"
        group_by_fields      = ["resource.labels.host"]
      }
    }
  }

  notification_channels = [google_monitoring_notification_channel.email.name]

  # Auto-close stale incidents after 30 min if symptom clears.
  # Without this, fired alerts stay open and require manual ack.
  alert_strategy {
    auto_close = "1800s"
  }
}
