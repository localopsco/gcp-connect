# This configuration connects your Google Cloud project to LocalOps using
# Workload Identity Federation. LocalOps receives short-lived, on-demand
# credentials for this project — no service account keys are created, stored,
# or downloaded. You can review every resource and permission below before
# applying.

locals {
  # A normalized, lowercase suffix used to name the resources created here.
  normalized_id = replace(lower(var.connection_id), "/[^a-z0-9]/", "")
  suffix        = var.resource_suffix != "" ? var.resource_suffix : substr(local.normalized_id, 0, min(20, length(local.normalized_id)))

  pool_id            = "localops-${local.suffix}"
  service_account_id = "localops-${local.suffix}"

  # APIs that must be enabled for federation and impersonation to work.
  required_apis = [
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "sts.googleapis.com",
    "cloudresourcemanager.googleapis.com",
  ]

  description = "Created by LocalOps connection setup. connection-id=${var.connection_id}"
}

data "google_project" "target" {
  project_id = var.project_id
}

# Enable the APIs needed to set up the connection.
resource "google_project_service" "required" {
  for_each = toset(local.required_apis)

  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

# The service account LocalOps acts as when managing this project.
resource "google_service_account" "localops" {
  project      = var.project_id
  account_id   = local.service_account_id
  display_name = var.service_account_display_name
  description  = local.description

  depends_on = [google_project_service.required]
}

# Grant the service account access to manage this project.
resource "google_project_iam_member" "localops" {
  project = var.project_id
  role    = var.project_role
  member  = "serviceAccount:${google_service_account.localops.email}"
}

# A Workload Identity Pool that lets LocalOps exchange its sign-in for
# short-lived access to this project.
resource "google_iam_workload_identity_pool" "localops" {
  project                   = var.project_id
  workload_identity_pool_id = local.pool_id
  display_name              = "LocalOps"
  description               = local.description

  depends_on = [google_project_service.required]
}

# The provider trusts LocalOps as an identity source, and only accepts the
# single connection identity issued for this connection.
resource "google_iam_workload_identity_pool_provider" "localops" {
  project                            = var.project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.localops.workload_identity_pool_id
  workload_identity_pool_provider_id = var.provider_id
  display_name                       = "LocalOps"
  description                        = local.description

  oidc {
    issuer_uri        = var.oidc_issuer_uri
    allowed_audiences = [var.oidc_audience]
  }

  attribute_mapping = {
    "google.subject" = "assertion.sub"
  }

  # Only this connection's identity is accepted; tokens for any other identity
  # are rejected.
  attribute_condition = "assertion.sub == '${var.oidc_client_id}'"
}

# Allow the trusted connection identity to act as the service account above.
resource "google_service_account_iam_member" "impersonation" {
  service_account_id = google_service_account.localops.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principal://iam.googleapis.com/projects/${data.google_project.target.number}/locations/global/workloadIdentityPools/${google_iam_workload_identity_pool.localops.workload_identity_pool_id}/subject/${var.oidc_client_id}"
}
