output "service_account_email" {
  description = "The service account Ops will use for this project."
  value       = google_service_account.ops.email
}

output "workload_identity_provider" {
  description = "The Workload Identity provider Ops uses to obtain short-lived credentials."
  value       = "projects/${data.google_project.target.number}/locations/global/workloadIdentityPools/${google_iam_workload_identity_pool.ops.workload_identity_pool_id}/providers/${google_iam_workload_identity_pool_provider.ops.workload_identity_pool_provider_id}"
}

output "project_id" {
  description = "The project that was connected."
  value       = var.project_id
}

output "project_number" {
  description = "The number of the project that was connected."
  value       = data.google_project.target.number
}
