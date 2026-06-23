terraform {
  required_version = ">= 1.5.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }

  # State is stored in a GCS bucket in the customer project, configured at
  # init time by setup.sh (-backend-config bucket/prefix). Keyed on the
  # connection id so retries resume from existing state.
  backend "gcs" {}
}

provider "google" {
  project = var.project_id
}
