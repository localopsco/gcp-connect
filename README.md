# Google Cloud Workload Identity Federation

Terraform configuration that sets up [Workload Identity Federation](https://cloud.google.com/iam/docs/workload-identity-federation)
in a Google Cloud project. It lets an external OIDC identity obtain short-lived,
on-demand access to the project — **no service account keys** are created,
stored, or exported.

The code is open so you can review exactly what is created, and which
permissions are granted, before you apply it.

## What it creates

In the target project, this configuration creates:

- A **service account** that the federated identity impersonates.
- A **Workload Identity Pool** and **provider** that trust a single OIDC
  issuer, and accept **only** the one identity (subject) you specify.
- A **project role** granted to that service account (`roles/owner` by default,
  configurable via `project_role`).
- The **APIs** required for federation and impersonation.

No long-lived credentials are created or exported.

## Requirements

- [Terraform CLI](https://developer.hashicorp.com/terraform/install) >= 1.5
- [Google Cloud CLI](https://cloud.google.com/sdk/docs/install)
- Permission to manage IAM and Workload Identity in the target project.

## Usage

State is stored in a GCS backend, configured at init time. Provide a bucket in
the target project (and a prefix to isolate this state):

```bash
terraform init \
  -backend-config="bucket=YOUR_STATE_BUCKET" \
  -backend-config="prefix=YOUR_STATE_PREFIX"

terraform apply \
  -var "project_id=YOUR_PROJECT_ID" \
  -var "connection_id=YOUR_IDENTIFIER" \
  -var "oidc_client_id=SUBJECT_ALLOWED_TO_IMPERSONATE" \
  -var "oidc_issuer_uri=https://YOUR_OIDC_ISSUER" \
  -var "oidc_audience=YOUR_AUDIENCE"
```

See `terraform.tfvars.example` for a sample set of values.

## Inputs

| Variable | Description | Default |
| --- | --- | --- |
| `project_id` | Google Cloud project to configure. | — |
| `connection_id` | Identifier used to name the resources created here. | — |
| `oidc_client_id` | The subject (`assertion.sub`) allowed to use the service account. | — |
| `oidc_issuer_uri` | OIDC issuer URL the Workload Identity provider trusts. | — |
| `oidc_audience` | Audience value the provider accepts on incoming tokens. | — |
| `resource_suffix` | Suffix for resource names. Defaults to a value derived from `connection_id`. | `""` |
| `provider_id` | Name of the Workload Identity provider created on the pool. | `ops-oidc` |
| `project_role` | Role granted to the service account on the project. | `roles/owner` |
| `service_account_display_name` | Display name for the service account. | `Ops` |

## Outputs

- `service_account_email` — the service account the federated identity impersonates.
- `workload_identity_provider` — the full provider resource name used to obtain credentials.
- `project_id` / `project_number` — the configured project.

## Teardown

```bash
terraform destroy \
  -var "project_id=YOUR_PROJECT_ID" \
  -var "connection_id=YOUR_IDENTIFIER" \
  -var "oidc_client_id=SUBJECT_ALLOWED_TO_IMPERSONATE" \
  -var "oidc_issuer_uri=https://YOUR_OIDC_ISSUER" \
  -var "oidc_audience=YOUR_AUDIENCE"
```

This removes the service account, pool, and provider from the project.
