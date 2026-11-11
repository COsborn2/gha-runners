output "webhook_endpoint" {
  description = "Paste into the GitHub App: General → Webhook URL."
  value       = module.runners.webhook.endpoint
}

output "webhook_secret" {
  description = "Paste into the GitHub App: General → Webhook secret. Read with `terraform output -raw webhook_secret`."
  value       = random_password.webhook_secret.result
  sensitive   = true
}

output "runner_labels" {
  description = "The labels workflow jobs can put in runs-on, one per runner type."
  value       = keys(local.runner_types)
}
