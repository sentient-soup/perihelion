#!/usr/bin/env bash
#
# Regenerate SealedSecret manifests from values in .env.
#
# Usage:
#   ./k8s/scripts/generate-secret.sh cloudflare         # cert-manager Cloudflare API token
#   ./k8s/scripts/generate-secret.sh pihole             # Pihole admin password
#   ./k8s/scripts/generate-secret.sh traefik-dashboard  # Traefik dashboard basic-auth
#   ./k8s/scripts/generate-secret.sh all                # regenerate all
#
# Secret values are read from k8s/.env (git-ignored; see k8s/.env.example).
# Requires kubectl + kubeseal on PATH and a reachable cluster — kubeseal fetches
# the sealed-secrets controller's public cert from the `infra` namespace.
#
# After running, commit the updated sealed-secret.yaml and let ArgoCD sync it.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$K8S_ROOT/.env"

CONTROLLER_NS="infra"   # namespace running the sealed-secrets controller

# Public cert used for offline sealing (no cluster access needed). Override with
# SEALED_SECRETS_CERT; defaults to k8s/pub-cert.pem. Refresh it when the controller
# rotates keys:  kubeseal --controller-namespace infra --fetch-cert > pub-cert.pem
CERT_FILE="${SEALED_SECRETS_CERT:-$K8S_ROOT/pub-cert.pem}"

die() { echo "error: $*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: ./k8s/scripts/generate-secret.sh <target>

Targets:
  cloudflare         Cloudflare API token   -> k8s/manifests/infra/cert-manager/sealed-secret.yaml
  pihole             Pihole admin password  -> k8s/manifests/services/pihole/sealed-secret.yaml
  traefik-dashboard  Dashboard basic-auth   -> k8s/manifests/platform/traefik/dashboard-auth-sealed-secret.yaml
  all                regenerate all

Values are read from k8s/.env (see k8s/.env.example).
EOF
}

require() {
  [[ -n "${!1:-}" ]] || die "$1 is not set in $ENV_FILE"
}

# reseal <secret-name> <namespace> <key> <value> <output-path-relative-to-k8s/>
reseal() {
  local name=$1 namespace=$2 key=$3 value=$4 outfile=$5
  local out="$K8S_ROOT/$outfile"
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
    manifests/infra/cert-manager/sealed-secret.yaml
}

gen_pihole() {
  require PIHOLE_PASSWORD
  echo "pihole:"
  reseal pihole-secrets networking PIHOLE_PASSWORD "$PIHOLE_PASSWORD" \
    manifests/services/pihole/sealed-secret.yaml
}

gen_traefik_dashboard() {
  require TRAEFIK_DASHBOARD_USER
  require TRAEFIK_DASHBOARD_PASSWORD
  # Traefik basicAuth expects htpasswd-format lines under key `users`.
  local htpasswd
  if command -v htpasswd >/dev/null 2>&1; then
    htpasswd="$(htpasswd -nbB "$TRAEFIK_DASHBOARD_USER" "$TRAEFIK_DASHBOARD_PASSWORD")"
  else
    htpasswd="$TRAEFIK_DASHBOARD_USER:$(openssl passwd -apr1 "$TRAEFIK_DASHBOARD_PASSWORD")"
  fi
  echo "traefik-dashboard:"
  reseal traefik-dashboard-auth traefik users "$htpasswd" \
    manifests/platform/traefik/dashboard-auth-sealed-secret.yaml
}

# --- entry point ---------------------------------------------------------

[[ $# -eq 1 ]] || { usage; exit 1; }
case "$1" in
  -h|--help) usage; exit 0 ;;
  cloudflare|pihole|traefik-dashboard|all) target=$1 ;;
  *) usage; exit 1 ;;
esac

command -v kubectl  >/dev/null 2>&1 || die "kubectl not found on PATH"
command -v kubeseal >/dev/null 2>&1 || die "kubeseal not found on PATH"
[[ -f "$ENV_FILE" ]] || die ".env not found at $ENV_FILE (copy k8s/.env.example to k8s/.env)"

# Load .env: export every assignment, then stop exporting. Strip carriage
# returns so a Windows/CRLF-edited .env doesn't bake a trailing \r into values
# (which silently corrupts secrets — e.g. an htpasswd user "admin\r").
set -a
# shellcheck disable=SC1090
source <(tr -d '\r' < "$ENV_FILE")
set +a

case "$target" in
  cloudflare)        gen_cloudflare ;;
  pihole)            gen_pihole ;;
  traefik-dashboard) gen_traefik_dashboard ;;
  all)               gen_cloudflare; gen_pihole; gen_traefik_dashboard ;;
esac
