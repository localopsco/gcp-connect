# Connect Google Cloud to LocalOps

This repository connects a Google Cloud project to
[LocalOps](https://localops.co) using **Workload Identity Federation**.
LocalOps receives short-lived, on-demand credentials for your project — there
are **no service account keys** to create, store, rotate, or leak.

The code is open so you can review exactly what is created in your project, and
which permissions are granted, before you run it.

## What it creates

In the project you connect, this configuration creates:

- A **service account** that LocalOps acts as when managing your project.
- A **Workload Identity Pool** and **provider** that let LocalOps exchange its
  sign-in for short-lived access — and that accept **only** the single identity
  issued for your connection.
- A **role** granted to that service account on the project (Owner by default,
  configurable via `project_role`) so LocalOps can manage resources for you.
- The **APIs** needed to establish the connection.

No long-lived credentials are created or exported.

## How to connect

The easiest way is from the LocalOps dashboard: create a Google Cloud connection
and click **Open in Cloud Shell**. You can also open it directly here:

[![Open in Cloud Shell](https://gstatic.com/cloudssh/images/open-btn.svg)](https://shell.cloud.google.com/cloudshell/open?cloudshell_git_repo=https://github.com/localopsco/gcp-connect&cloudshell_git_branch=main&cloudshell_tutorial=.tutorial.md&ephemeral=true)

This opens Google Cloud Shell with this repository ready and a guided
walkthrough. You paste the setup command shown on your connection's page and run
it:

```bash
export LOCALOPS_API_URL="..." \
       LOCALOPS_CONNECTION_ID="..." \
       LOCALOPS_VERIFICATION_TOKEN="..." && \
./setup.sh
```

`setup.sh` reads your connection's details from LocalOps, applies the Terraform
in this repository, and reports the result back so LocalOps can finish the
connection. It is safe to re-run if anything is interrupted. Terraform state is
kept in a bucket in your own project, so re-runs and teardown work from any
Cloud Shell session.

### Running Terraform directly

If you prefer to drive Terraform yourself, you need the
[Terraform CLI](https://developer.hashicorp.com/terraform/install) and the
[Google Cloud CLI](https://cloud.google.com/sdk/docs/install), and permission to
manage IAM and Workload Identity in the target project. Use the values shown for
your connection in the LocalOps dashboard:

```bash
terraform init
terraform apply \
  -var "project_id=YOUR_PROJECT_ID" \
  -var "connection_id=FROM_DASHBOARD" \
  -var "oidc_client_id=FROM_DASHBOARD" \
  -var "oidc_issuer_uri=FROM_DASHBOARD" \
  -var "oidc_audience=FROM_DASHBOARD"
```

When it finishes, copy the `service_account_email` and
`workload_identity_provider` outputs into LocalOps to complete the connection.

## Disconnecting

Run `destroy.sh` from Cloud Shell with the same connection values, **before**
deleting the connection in the LocalOps dashboard:

```bash
export LOCALOPS_API_URL="..." \
       LOCALOPS_CONNECTION_ID="..." \
       LOCALOPS_VERIFICATION_TOKEN="..." && \
./destroy.sh
```

This removes the service account, pool, and provider from your project. Then
delete the connection in the LocalOps dashboard.

To tear down with Terraform directly instead, run `terraform destroy` with the
same variables you used for `apply`.
