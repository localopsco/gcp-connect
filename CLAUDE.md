# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**gcp-connect** is a Terraform configuration (not an app) that connects a customer's Google Cloud project to Ops using **Workload Identity Federation**. It lets Ops obtain short-lived, on-demand credentials for a GCP project with no service account keys ever created, stored, or exported. The repo is meant to be run by customers (via Google Cloud Shell) or by the setup/teardown scripts, not built or deployed as a service.

## Tech Stack

- **Terraform** >= 1.5.0, `hashicorp/google` provider `~> 6.0`
- **Bash** (`setup.sh` / `destroy.sh`), using `gcloud`, `jq`, `curl`
- State backend: GCS (`backend "gcs" {}`), configured at `terraform init` time — not hardcoded

## Repository Layout

| File | Purpose |
|------|---------|
| `main.tf` | Core resources: service account, Workload Identity Pool + OIDC provider, IAM bindings, required API enablement |
| `variables.tf` | Input variables (`project_id`, `connection_id`, `oidc_client_id`, `oidc_issuer_uri`, `oidc_audience`, `resource_suffix`, `provider_id`, `project_role`, `service_account_display_name`), each with validation blocks |
| `outputs.tf` | `service_account_email`, `workload_identity_provider`, `project_id`, `project_number` |
| `versions.tf` | Terraform/provider version constraints and the GCS backend declaration |
| `terraform.tfvars.example` | Sample values; normal setup does not require creating this file since Ops provides the values via `setup.sh` |
| `setup.sh` | End-to-end connect flow: installs Terraform if missing, resolves the active GCP project, fetches connection details from the Ops API, ensures a per-project GCS state bucket, runs `terraform init`/`apply`, validates the outputs look like real GCP resources, then reports results back to Ops |
| `destroy.sh` | End-to-end disconnect flow: fetches connection details, runs `terraform destroy` against the existing state, cleans up the connection's state prefix (and the bucket if empty), then notifies Ops |
| `.tutorial.md` | Cloud Shell walkthrough script shown to users running the guided setup (referenced via `walkthrough-*` directives) |
| `.github/workflows/terraform-lint.yml` | CI: `terraform fmt -check`, `terraform init -backend=false`, `terraform validate`, and `tflint` on every push to `main` |

## Architecture / How It Works

1. A customer opens Google Cloud Shell from the Ops dashboard and runs the setup command, which sets `OPS_API_URL`, `OPS_CONNECTION_ID`, `OPS_VERIFICATION_TOKEN` and invokes `setup.sh`.
2. `setup.sh` resolves the active GCP project (`GOOGLE_CLOUD_PROJECT` or `gcloud config get-value project`, prompting the user to pick one if unset), then calls `POST {OPS_API_URL}/api/v1/clouds/gcp/{OPS_CONNECTION_ID}/details` to fetch the OIDC client ID, issuer URI, and audience for this connection.
3. Terraform state lives in a per-project GCS bucket named `${PROJECT_ID}-ops-tfstate`, under prefix `connections/${OPS_CONNECTION_ID}` — created by `setup.sh` if it doesn't exist. This makes re-running the script idempotent and keeps state isolated per connection within a shared bucket.
4. `terraform apply` (via `main.tf`) creates: required API enablement (`iam`, `iamcredentials`, `sts`, `cloudresourcemanager`), a service account (`ops-<suffix>`), a Workload Identity Pool + OIDC provider (`ops-<suffix>`) scoped to accept only the single connection's identity (`attribute_condition` pins `assertion.sub`), an IAM role binding on the project (default `roles/owner`, via `project_role`), and an impersonation binding letting the federated identity act as the service account.
5. `setup.sh` validates the Terraform outputs look like real resources (service account email matches `*.iam.gserviceaccount.com`, provider name matches the expected resource path) before reporting them back to Ops via `POST {API_BASE}/connect` — this guards against marking a connection "connected" with bad/empty data.
6. `destroy.sh` mirrors this flow in reverse: fetch details, `terraform destroy` against the same backend/prefix, best-effort remove the state prefix (and bucket, if now empty — shared across connections in the same project), then `POST {API_BASE}/disconnect`.

Both scripts are designed to run unattended in Cloud Shell: they auto-install Terraform via the HashiCorp apt repo if missing, and skip confirmation prompts when stdin isn't a TTY.

## Common Commands

```bash
# Format and validate (matches CI)
terraform fmt -check -recursive -diff
terraform init -backend=false
terraform validate
tflint --recursive

# Manual apply (normally done for you by setup.sh with values from Ops)
terraform init \
  -backend-config="bucket=YOUR_STATE_BUCKET" \
  -backend-config="prefix=YOUR_STATE_PREFIX"

terraform apply \
  -var "project_id=YOUR_PROJECT_ID" \
  -var "connection_id=YOUR_IDENTIFIER" \
  -var "oidc_client_id=SUBJECT_ALLOWED_TO_IMPERSONATE" \
  -var "oidc_issuer_uri=https://YOUR_OIDC_ISSUER" \
  -var "oidc_audience=YOUR_AUDIENCE"

# Manual teardown (mirrors apply)
terraform destroy \
  -var "project_id=YOUR_PROJECT_ID" \
  -var "connection_id=YOUR_IDENTIFIER" \
  -var "oidc_client_id=SUBJECT_ALLOWED_TO_IMPERSONATE" \
  -var "oidc_issuer_uri=https://YOUR_OIDC_ISSUER" \
  -var "oidc_audience=YOUR_AUDIENCE"
```

There is no application build/test suite in this repo — CI only lints and validates the Terraform.

## Notes for Changes

- `variables.tf` validation blocks enforce format constraints (e.g. `project_id` regex, `resource_suffix` lowercase alphanumeric 4-24 chars) — keep these in sync if renaming/adding variables.
- `oidc_client_id`, `oidc_issuer_uri`, and `oidc_audience` are marked "Do not edit" in their descriptions — they're issued by Ops per connection, not user-configurable.
- The `attribute_condition` in `main.tf` is what restricts the Workload Identity provider to a single trusted identity; changes here directly affect the security boundary of the connection.
- `setup.sh` and `destroy.sh` are near-duplicates (shared `ensure_terraform`/`pick_project` helpers) — when fixing a bug in one, check whether the same fix applies to the other.
