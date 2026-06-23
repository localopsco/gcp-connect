variable "project_id" {
  description = "The Google Cloud project to connect to Ops."
  type        = string

  validation {
    condition     = can(regex("^[a-z][-a-z0-9]{4,28}[a-z0-9]$", var.project_id))
    error_message = "project_id must be a valid GCP project ID (6-30 chars, lowercase, digits, hyphens)."
  }
}

variable "connection_id" {
  description = "Your Ops connection ID. Used to name the resources created in your project. Do not edit."
  type        = string

  validation {
    condition     = length(var.connection_id) > 0
    error_message = "connection_id must not be empty."
  }
}

variable "oidc_client_id" {
  description = "Identifier issued by Ops for this connection. It is the only identity allowed to use the service account created below. Do not edit."
  type        = string

  validation {
    condition     = length(var.oidc_client_id) > 0
    error_message = "oidc_client_id must not be empty."
  }
}

variable "oidc_issuer_uri" {
  description = "Ops sign-in URL that the Workload Identity provider trusts. Do not edit."
  type        = string

  validation {
    condition     = can(regex("^https://", var.oidc_issuer_uri))
    error_message = "oidc_issuer_uri must be an https URL."
  }
}

variable "oidc_audience" {
  description = "Audience value Ops tokens are issued with, accepted by the Workload Identity provider. Do not edit."
  type        = string

  validation {
    condition     = length(var.oidc_audience) > 0
    error_message = "oidc_audience must not be empty."
  }
}

variable "resource_suffix" {
  description = "Suffix used in resource names. Defaults to a value derived from your connection ID."
  type        = string
  default     = ""

  validation {
    condition     = var.resource_suffix == "" || can(regex("^[a-z0-9]{4,24}$", var.resource_suffix))
    error_message = "resource_suffix must be 4-24 lowercase alphanumeric characters."
  }
}

variable "provider_id" {
  description = "Name of the Workload Identity provider created on the pool."
  type        = string
  default     = "ops-oidc"
}

variable "project_role" {
  description = "Role granted to the Ops service account on this project."
  type        = string
  default     = "roles/owner"
}

variable "service_account_display_name" {
  description = "Display name shown in the Google Cloud console for the Ops service account."
  type        = string
  default     = "Ops"
}
