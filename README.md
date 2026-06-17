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
- The **APIs** needed to establish the connection.
- A small set of **roles** on the service account so LocalOps can finish setting
  up your project without this step requesting broad owner access.

No long-lived credentials are created or exported.

## How to run it

The easiest way is from the LocalOps dashboard: create a Google Cloud connection
and click **Open in Cloud Shell**. This opens Google Cloud Shell with this
repository ready and a guided walkthrough — you run a single command and return
to LocalOps.

### Running manually

If you prefer to run it yourself, you need the [Terraform CLI](https://developer.hashicorp.com/terraform/install)
and the [Google Cloud CLI](https://cloud.google.com/sdk/docs/install), and
permission to manage IAM and Workload Identity in the target project
(`roles/owner` is sufficient). Use the values shown for your connection in the
LocalOps dashboard:

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

To disconnect, delete the LocalOps Workload Identity Pool in the Google Cloud
console under **IAM & Admin → Workload Identity Federation**. This immediately
stops LocalOps from obtaining new credentials. You can then delete the LocalOps
service account, and remove the connection in the LocalOps dashboard.
