#!/usr/bin/env bash
#
# Removes the LocalOps connection from this Google Cloud project.
#
# It tears down the Workload Identity Federation resources created by setup.sh
# (pool, OIDC provider, service account, and bindings), using the Terraform
# state stored in your project. Run this before deleting the connection in the
# LocalOps dashboard, so the connection details are still available.
#
# Required environment variables (provided by the LocalOps dashboard):
#   LOCALOPS_API_URL             LocalOps API base URL
#   LOCALOPS_CONNECTION_ID       Your connection identifier
#   LOCALOPS_VERIFICATION_TOKEN  Token authorizing this teardown
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
    err "$name is not set. Copy the teardown command from the LocalOps dashboard and run it again."
  fi
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

require_env LOCALOPS_API_URL
require_env LOCALOPS_CONNECTION_ID
require_env LOCALOPS_VERIFICATION_TOKEN

for cmd in terraform gcloud jq curl; do
  command -v "$cmd" >/dev/null 2>&1 || err "'$cmd' is required but was not found."
done

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
  printf 'Remove the LocalOps connection from this project? [y/N] '
  read -r confirm
  [[ "$confirm" =~ ^[Yy]([Ee][Ss])?$ ]] || err "Cancelled. No changes were made."
fi

API_BASE="${LOCALOPS_API_URL%/}/api/v1/clouds/gcp/${LOCALOPS_CONNECTION_ID}"

echo "==> Fetching connection details from LocalOps"
DETAILS="$(curl -fsS -X POST "${API_BASE}/details" \
  -H "Content-Type: application/json" \
  -d "{\"verification_token\":\"${LOCALOPS_VERIFICATION_TOKEN}\"}")" \
  || err "Could not fetch connection details. Tear down before deleting the connection in LocalOps."

OIDC_CLIENT_ID="$(jq -r '.data.details.oidc_client_id' <<<"$DETAILS")"
OIDC_ISSUER_URI="$(jq -r '.data.details.oidc_issuer_uri' <<<"$DETAILS")"
OIDC_AUDIENCE="$(jq -r '.data.details.oidc_audience' <<<"$DETAILS")"

[[ -n "$OIDC_CLIENT_ID" && "$OIDC_CLIENT_ID" != "null" ]] || err "Connection details were incomplete."

STATE_BUCKET="${PROJECT_ID}-localops-tfstate"
STATE_PREFIX="connections/${LOCALOPS_CONNECTION_ID}"

echo "==> Initializing Terraform"
terraform init -input=false \
  -backend-config="bucket=${STATE_BUCKET}" \
  -backend-config="prefix=${STATE_PREFIX}"

echo "==> Destroying connection resources"
terraform destroy -input=false -auto-approve \
  -var "project_id=${PROJECT_ID}" \
  -var "connection_id=${LOCALOPS_CONNECTION_ID}" \
  -var "oidc_client_id=${OIDC_CLIENT_ID}" \
  -var "oidc_issuer_uri=${OIDC_ISSUER_URI}" \
  -var "oidc_audience=${OIDC_AUDIENCE}"

echo
echo "Done. The LocalOps federation resources have been removed from ${PROJECT_ID}."
echo "You can now delete the connection in the LocalOps dashboard."
echo "(The Terraform state bucket gs://${STATE_BUCKET} is left in place for any other connections.)"
