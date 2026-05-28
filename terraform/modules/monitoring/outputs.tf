output "notification_channel_name" {
  value = google_monitoring_notification_channel.email.name
}

output "uptime_check_id" {
  value = length(google_monitoring_uptime_check_config.payment_api_health) > 0 ? google_monitoring_uptime_check_config.payment_api_health[0].uptime_check_id : ""
}
