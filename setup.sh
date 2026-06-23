#!/usr/bin/env bash
#
# Connects this Google Cloud project to Ops.
#
# It reads the connection details from Ops, provisions Workload Identity
# Federation in your project with Terraform, and reports the result back so
# Ops can finish the connection. It is safe to re-run: Terraform reuses the
# existing state and the final step is idempotent.
#
# Required environment variables (provided by the Ops setup command):
#   OPS_API_URL             Ops API base URL
#   OPS_CONNECTION_ID       Your connection identifier
#   OPS_VERIFICATION_TOKEN  One-time token authorizing this setup
#
# The active Cloud Shell project (GOOGLE_CLOUD_PROJECT) is the project that gets
# connected.

set -euo pipefail

err() {
  echo "Error: $*" >&2
  exit 1
}

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    err "$name is not set. Copy the setup command from the Ops dashboard and run it again."
  fi
}

# ensure_terraform guarantees a working `terraform` is on PATH. Some environments
# (e.g. Cloud Shell) don't ship Terraform and print install instructions instead
# of running it, so a successful `terraform version` is the real test — not
# `command -v`. When it's missing, install it from the HashiCorp apt repository.
ensure_terraform() {
  if terraform version 2>/dev/null | grep -q '^Terraform v'; then
    return
  fi

  if ! command -v apt-get >/dev/null 2>&1 || ! command -v sudo >/dev/null 2>&1; then
    err "Terraform is not installed and can't be installed automatically here. Install it (https://developer.hashicorp.com/terraform/install) and run this command again."
  fi

  local codename
  codename="$(. /etc/os-release && echo "${VERSION_CODENAME:-}")"
  [[ -n "$codename" ]] || codename="$(lsb_release -cs 2>/dev/null || true)"
  [[ -n "$codename" ]] || err "Could not determine the OS codename to install Terraform. Install it manually (https://developer.hashicorp.com/terraform/install) and re-run."

  echo "==> Terraform not found; installing it from the HashiCorp apt repository"
  # Cloud Shell pauses 5s with a warning before every apt-get; this opt-out file
  # silences it so the install runs unattended.
  if [[ "${CLOUD_SHELL:-}" == "true" ]]; then
    mkdir -p "$HOME/.cloudshell" 2>/dev/null || true
    touch "$HOME/.cloudshell/no-apt-get-warning" 2>/dev/null || true
  fi
  curl -fsSL https://apt.releases.hashicorp.com/gpg \
    | sudo gpg --batch --yes --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com ${codename} main" \
    | sudo tee /etc/apt/sources.list.d/hashicorp.list >/dev/null
  sudo apt-get update -qq
  sudo apt-get install -y terraform

  hash -r
  terraform version 2>/dev/null | grep -q '^Terraform v' \
    || err "Installed Terraform but the 'terraform' command still isn't working. Start a fresh shell ('exec bash') and re-run this command."
}

# pick_project shows an arrow-key menu over the given project IDs and stores the
# chosen one in PROJECT_REF. Navigate with ↑/↓, select with Enter.
pick_project() {
  local projects=("$@") selected=0 count=$# key i
  printf 'Use the up/down arrows to choose a project, then press Enter:\n' >/dev/tty
  command -v tput >/dev/null 2>&1 && tput civis >/dev/tty 2>/dev/null || true
  while true; do
    for i in "${!projects[@]}"; do
      if [[ $i -eq $selected ]]; then
        printf '\033[K\033[7m> %s\033[0m\n' "${projects[$i]}" >/dev/tty
      else
        printf '\033[K  %s\n' "${projects[$i]}" >/dev/tty
      fi
    done
    IFS= read -rsn1 key </dev/tty
    case $key in
      $'\x1b')
        read -rsn2 -t 0.05 key </dev/tty || true
        case $key in
          '[A') selected=$(((selected - 1 + count) % count)) ;;
          '[B') selected=$(((selected + 1) % count)) ;;
        esac
        ;;
      '') break ;; # Enter
    esac
    printf '\033[%dA' "$count" >/dev/tty
  done
  command -v tput >/dev/null 2>&1 && tput cnorm >/dev/tty 2>/dev/null || true
  PROJECT_REF="${projects[$selected]}"
}

require_env OPS_API_URL
require_env OPS_CONNECTION_ID
require_env OPS_VERIFICATION_TOKEN

for cmd in gcloud jq curl; do
  command -v "$cmd" >/dev/null 2>&1 || err "'$cmd' is required but was not found."
done

ensure_terraform

# Resolve the project to connect. The active value may be a project number, so
# normalize to the canonical project ID. If nothing is set, let the user pick.
PROJECT_REF="${GOOGLE_CLOUD_PROJECT:-$(gcloud config get-value project 2>/dev/null)}"

if [[ -z "$PROJECT_REF" ]]; then
  [[ -t 0 ]] || err "No active project. Run 'gcloud config set project <PROJECT_ID>' and try again."
  mapfile -t PROJECT_CHOICES < <(gcloud projects list --format='value(projectId)' --sort-by=projectId)
  [[ ${#PROJECT_CHOICES[@]} -gt 0 ]] || err "No Google Cloud projects found for your account."
  pick_project "${PROJECT_CHOICES[@]}"
fi

PROJECT_ID="$(gcloud projects describe "$PROJECT_REF" --format='value(projectId)' 2>/dev/null)" \
  || err "Could not resolve project '$PROJECT_REF'. Check the active project and your access."

echo
echo "==> Project to connect"
gcloud projects describe "$PROJECT_ID" \
  --format='flattened(projectId, name, projectNumber, lifecycleState)'
if [[ -t 0 ]]; then
  printf 'Connect this project to Ops? [y/N] '
  read -r confirm
  [[ "$confirm" =~ ^[Yy]([Ee][Ss])?$ ]] || err "Cancelled. No changes were made."
fi

API_BASE="${OPS_API_URL%/}/api/v1/clouds/gcp/${OPS_CONNECTION_ID}"

echo "==> Fetching connection details from Ops"
DETAILS="$(curl -fsS -X POST "${API_BASE}/details" \
  -H "Content-Type: application/json" \
  -d "{\"verification_token\":\"${OPS_VERIFICATION_TOKEN}\"}")" \
  || err "Could not fetch connection details. The setup command may have expired; copy a fresh one from the dashboard."

OIDC_CLIENT_ID="$(jq -r '.data.details.oidc_client_id' <<<"$DETAILS")"
OIDC_ISSUER_URI="$(jq -r '.data.details.oidc_issuer_uri' <<<"$DETAILS")"
OIDC_AUDIENCE="$(jq -r '.data.details.oidc_audience' <<<"$DETAILS")"

[[ -n "$OIDC_CLIENT_ID" && "$OIDC_CLIENT_ID" != "null" ]] || err "Connection details were incomplete."

# Terraform state is kept in a bucket in your own project so re-runs are safe.
STATE_BUCKET="${PROJECT_ID}-ops-tfstate"
STATE_PREFIX="connections/${OPS_CONNECTION_ID}"

echo "==> Ensuring Terraform state bucket gs://${STATE_BUCKET}"
if ! gcloud storage buckets describe "gs://${STATE_BUCKET}" --project="$PROJECT_ID" >/dev/null 2>&1; then
  gcloud storage buckets create "gs://${STATE_BUCKET}" \
    --project="$PROJECT_ID" \
    --uniform-bucket-level-access \
    >/dev/null
fi

echo "==> Initializing Terraform"
# -reconfigure points Terraform at this connection's backend without trying to
# migrate state from a previously initialized connection in the same directory.
terraform init -input=false -reconfigure \
  -backend-config="bucket=${STATE_BUCKET}" \
  -backend-config="prefix=${STATE_PREFIX}"

echo "==> Applying Terraform"
terraform apply -input=false -auto-approve \
  -var "project_id=${PROJECT_ID}" \
  -var "connection_id=${OPS_CONNECTION_ID}" \
  -var "oidc_client_id=${OIDC_CLIENT_ID}" \
  -var "oidc_issuer_uri=${OIDC_ISSUER_URI}" \
  -var "oidc_audience=${OIDC_AUDIENCE}"

SERVICE_ACCOUNT_EMAIL="$(terraform output -raw service_account_email)"
WORKLOAD_IDENTITY_PROVIDER="$(terraform output -raw workload_identity_provider)"
PROJECT_NUMBER="$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')"

# Guard against reporting non-functional values to Ops: the outputs must be a GCP
# service account email and a Workload Identity provider resource name. If they
# are anything else, the apply did not produce real resources — fail without
# reporting so the connection is not marked connected with bad details.
case "$SERVICE_ACCOUNT_EMAIL" in
  *@*.iam.gserviceaccount.com) ;;
  *) err "Terraform did not return a valid service account email. Nothing was reported to Ops; check the apply output above and re-run." ;;
esac
case "$WORKLOAD_IDENTITY_PROVIDER" in
  */workloadIdentityPools/*/providers/*) ;;
  *) err "Terraform did not return a valid workload identity provider. Nothing was reported to Ops; check the apply output above and re-run." ;;
esac

echo "==> Reporting result to Ops"
curl -fsS -X POST "${API_BASE}/connect" \
  -H "Content-Type: application/json" \
  -d "$(jq -n \
    --arg token "$OPS_VERIFICATION_TOKEN" \
    --arg number "$PROJECT_NUMBER" \
    --arg sa "$SERVICE_ACCOUNT_EMAIL" \
    --arg wip "$WORKLOAD_IDENTITY_PROVIDER" \
    '{verification_token:$token, project_number:$number, service_account_email:$sa, workload_identity_provider:$wip}')" \
  >/dev/null \
  || err "Setup completed in your project but reporting back to Ops failed. Re-run this command to retry."

echo
echo "Done. Return to the Ops dashboard — the connection will show as connected shortly."
