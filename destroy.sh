#!/usr/bin/env bash
#
# Removes the Ops connection from this Google Cloud project.
#
# It tears down the Workload Identity Federation resources created by setup.sh
# (pool, OIDC provider, service account, and bindings), using the Terraform
# state stored in your project. Run this before deleting the connection in the
# Ops dashboard, so the connection details are still available.
#
# Required environment variables (provided by the Ops dashboard):
#   OPS_API_URL             Ops API base URL
#   OPS_CONNECTION_ID       Your connection identifier
#   OPS_VERIFICATION_TOKEN  Token authorizing this teardown
#
# The active Cloud Shell project (GOOGLE_CLOUD_PROJECT) is the project that gets
# disconnected.

set -euo pipefail

err() {
  echo "Error: $*" >&2
  exit 1
}

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    err "$name is not set. Copy the teardown command from the Ops dashboard and run it again."
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

# Resolve the project to disconnect. The active value may be a project number, so
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
echo "==> Project to disconnect"
gcloud projects describe "$PROJECT_ID" \
  --format='flattened(projectId, name, projectNumber, lifecycleState)'
if [[ -t 0 ]]; then
  printf 'Remove the Ops connection from this project? [y/N] '
  read -r confirm
  [[ "$confirm" =~ ^[Yy]([Ee][Ss])?$ ]] || err "Cancelled. No changes were made."
fi

API_BASE="${OPS_API_URL%/}/api/v1/clouds/gcp/${OPS_CONNECTION_ID}"

echo "==> Fetching connection details from Ops"
DETAILS="$(curl -fsS -X POST "${API_BASE}/details" \
  -H "Content-Type: application/json" \
  -d "{\"verification_token\":\"${OPS_VERIFICATION_TOKEN}\"}")" \
  || err "Could not fetch connection details. Tear down before deleting the connection in Ops."

OIDC_CLIENT_ID="$(jq -r '.data.details.oidc_client_id' <<<"$DETAILS")"
OIDC_ISSUER_URI="$(jq -r '.data.details.oidc_issuer_uri' <<<"$DETAILS")"
OIDC_AUDIENCE="$(jq -r '.data.details.oidc_audience' <<<"$DETAILS")"

[[ -n "$OIDC_CLIENT_ID" && "$OIDC_CLIENT_ID" != "null" ]] || err "Connection details were incomplete."

STATE_BUCKET="${PROJECT_ID}-ops-tfstate"
STATE_PREFIX="connections/${OPS_CONNECTION_ID}"

echo "==> Initializing Terraform"
# -reconfigure points Terraform at this connection's backend without trying to
# migrate state from a previously initialized connection in the same directory.
terraform init -input=false -reconfigure \
  -backend-config="bucket=${STATE_BUCKET}" \
  -backend-config="prefix=${STATE_PREFIX}"

echo "==> Destroying connection resources"
terraform destroy -input=false -auto-approve \
  -var "project_id=${PROJECT_ID}" \
  -var "connection_id=${OPS_CONNECTION_ID}" \
  -var "oidc_client_id=${OIDC_CLIENT_ID}" \
  -var "oidc_issuer_uri=${OIDC_ISSUER_URI}" \
  -var "oidc_audience=${OIDC_AUDIENCE}"

# Clean up the Terraform state. The bucket is shared across every connection in
# this project (one prefix per connection), so delete only this connection's
# prefix, then remove the bucket itself only if nothing else is left in it.
# Best-effort: state cleanup failures must not block the disconnect below.
echo "==> Removing this connection's Terraform state"
if gcloud storage rm --recursive "gs://${STATE_BUCKET}/${STATE_PREFIX}" --project="$PROJECT_ID" >/dev/null 2>&1; then
  echo "    Removed gs://${STATE_BUCKET}/${STATE_PREFIX}"
else
  echo "    Nothing to remove at gs://${STATE_BUCKET}/${STATE_PREFIX}"
fi

if [[ -z "$(gcloud storage ls "gs://${STATE_BUCKET}" --project="$PROJECT_ID" 2>/dev/null || true)" ]]; then
  if gcloud storage buckets delete "gs://${STATE_BUCKET}" --project="$PROJECT_ID" >/dev/null 2>&1; then
    echo "    Removed now-empty state bucket gs://${STATE_BUCKET}"
  else
    echo "    State bucket gs://${STATE_BUCKET} is empty but could not be removed; delete it manually if desired."
  fi
else
  echo "    State bucket gs://${STATE_BUCKET} kept (other connections still use it)."
fi

echo "==> Notifying Ops that the connection was removed"
curl -fsS -X POST "${API_BASE}/disconnect" \
  -H "Content-Type: application/json" \
  -d "{\"verification_token\":\"${OPS_VERIFICATION_TOKEN}\"}" \
  >/dev/null \
  || err "Resources were removed from your project but notifying Ops failed. Re-run this command, or disconnect the connection in the dashboard."

echo
echo "Done. The Ops federation resources have been removed from ${PROJECT_ID},"
echo "and the connection now shows as disconnected in the Ops dashboard."
