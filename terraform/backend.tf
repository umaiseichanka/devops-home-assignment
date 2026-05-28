terraform {
  backend "gcs" {
    bucket = "tfstate-payment-api-task"
    prefix = "payment-api/dev"
  }
}
