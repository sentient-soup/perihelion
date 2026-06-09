#!/usr/bin/env bash
#
# Regenerate SealedSecret manifests from values in .env.
#
# Usage:
#   ./scripts/generate-secret.sh cloudflare   # cert-manager Cloudflare API token
#   ./scripts/generate-secret.sh pihole       # Pihole admin password
#   ./scripts/generate-secret.sh all          # regenerate both
#
# Secret values are read from the repo-root .env (git-ignored; see .env.example).
# Requires kubectl + kubeseal on PATH and a reachable cluster — kubeseal fetches
# the sealed-secrets controller's public cert from the `infra` namespace.
#
# After running, commit the updated sealed-secret.yaml and let ArgoCD sync it.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$REPO_ROOT/.env"

CONTROLLER_NS="infra"   # namespace running the sealed-secrets controller

# Public cert used for offline sealing (no cluster access needed). Override with
# SEALED_SECRETS_CERT; defaults to ./pub-cert.pem. Refresh it when the controller
# rotates keys:  kubeseal --controller-namespace infra --fetch-cert > pub-cert.pem
CERT_FILE="${SEALED_SECRETS_CERT:-$REPO_ROOT/pub-cert.pem}"

die() { echo "error: $*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: ./scripts/generate-secret.sh <target>

Targets:
  cloudflare   Cloudflare API token  -> k8s/manifests/infra/cert-manager/sealed-secret.yaml
  pihole       Pihole admin password -> k8s/manifests/services/pihole/sealed-secret.yaml
  all          regenerate both

Values are read from .env at the repo root (see .env.example).
EOF
}

require() {
  [[ -n "${!1:-}" ]] || die "$1 is not set in $ENV_FILE"
}

# reseal <secret-name> <namespace> <key> <value> <output-path-relative-to-repo-root>
reseal() {
  local name=$1 namespace=$2 key=$3 value=$4 outfile=$5
  local out="$REPO_ROOT/$outfile"
  mkdir -p "$(dirname "$out")"

  # Prefer offline sealing against a local public cert; fall back to fetching it
  # live from the controller (which requires a configured kubeconfig).
  local seal_args
  if [[ -f "$CERT_FILE" ]]; then
    seal_args=(--cert "$CERT_FILE")
  else
    seal_args=(--controller-namespace "$CONTROLLER_NS")
  fi

  kubectl create secret generic "$name" \
    --namespace "$namespace" \
    --from-literal="$key=$value" \
    --dry-run=client -o yaml \
  | kubeseal "${seal_args[@]}" -o yaml \
  > "$out"
  echo "  wrote $outfile  (secret $namespace/$name, key $key)"
}

gen_cloudflare() {
  require CLOUDFLARE_API_TOKEN
  echo "cloudflare:"
  reseal cloudflare-api-token cert-manager api-token "$CLOUDFLARE_API_TOKEN" \
    k8s/manifests/infra/cert-manager/sealed-secret.yaml
}

gen_pihole() {
  require PIHOLE_PASSWORD
  echo "pihole:"
  reseal pihole-secrets networking PIHOLE_PASSWORD "$PIHOLE_PASSWORD" \
    k8s/manifests/services/pihole/sealed-secret.yaml
}

# --- entry point ---------------------------------------------------------

[[ $# -eq 1 ]] || { usage; exit 1; }
case "$1" in
  -h|--help) usage; exit 0 ;;
  cloudflare|pihole|all) target=$1 ;;
  *) usage; exit 1 ;;
esac

command -v kubectl  >/dev/null 2>&1 || die "kubectl not found on PATH"
command -v kubeseal >/dev/null 2>&1 || die "kubeseal not found on PATH"
[[ -f "$ENV_FILE" ]] || die ".env not found at $ENV_FILE (copy .env.example to .env)"

# Load .env: export every assignment, then stop exporting.
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

case "$target" in
  cloudflare) gen_cloudflare ;;
  pihole)     gen_pihole ;;
  all)        gen_cloudflare; gen_pihole ;;
esac
