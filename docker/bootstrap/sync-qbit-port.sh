#!/usr/bin/env bash
# Syncs Gluetun's ProtonVPN forwarded port to qBittorrent's listen port.
# ProtonVPN rotates the forwarded port periodically; this keeps qBittorrent
# listening on the correct port so peers can connect.
#
# Cron (every 5 minutes):
#   */5 * * * * /opt/homelab/docker/bootstrap/sync-qbit-port.sh >> /var/log/qbit-port-sync.log 2>&1
#
# Requires: curl, jq
# Auth: qBittorrent >=5.2.0 API key (Preferences > WebUI > API Key). Set
# QBIT_API_KEY in services/ingest/.secrets.env. Bearer-key auth is stateless —
# no login/SID/Referer dance, and it bypasses the WebUI CSRF check.
set -euo pipefail

# Pull QBIT_API_KEY from the ingest secrets file if present, so cron can run
# without inline env. ponytail: reuse the existing secrets file, no new mechanism.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECRETS_FILE="${SCRIPT_DIR}/../services/ingest/.secrets.env"
if [[ -f "${SECRETS_FILE}" ]]; then
    set -a; source "${SECRETS_FILE}"; set +a
fi

# Defaults match docker/.env (cron runs without it): QBIT_WEBUI_PORT=8085,
# gluetun control server published on 127.0.0.1:8000.
GLUETUN_API="${GLUETUN_API:-http://localhost:8000}"
QBIT_HOST="${QBIT_HOST:-http://localhost:${QBIT_WEBUI_PORT:-8085}}"
QBIT_API_KEY="${QBIT_API_KEY:-}"

if [[ -z "${QBIT_API_KEY}" ]]; then
    echo "$(date -Iseconds) ERROR: QBIT_API_KEY not set (see services/ingest/.secrets.env)" >&2
    exit 1
fi

# --- Get forwarded port from Gluetun control server ---
# /v1/portforward is the current path ({"port":N}); /v1/openvpn/portforwarded
# is deprecated. Control server requires auth (v3.40+) — see gluetun-auth.toml.
FORWARDED_PORT=$(curl -sf "${GLUETUN_API}/v1/portforward" | jq -r '.port // empty')

if [[ -z "${FORWARDED_PORT}" || "${FORWARDED_PORT}" == "0" ]]; then
    echo "$(date -Iseconds) ERROR: No forwarded port available from Gluetun (got '${FORWARDED_PORT:-empty}')" >&2
    exit 1
fi

# --- Update listen port (stateless Bearer-key auth) ---
if ! curl -sf \
    -H "Authorization: Bearer ${QBIT_API_KEY}" \
    "${QBIT_HOST}/api/v2/app/setPreferences" \
    --data "json={\"listen_port\":${FORWARDED_PORT}}" > /dev/null; then
    echo "$(date -Iseconds) ERROR: qBittorrent setPreferences failed (check QBIT_API_KEY / WebUI reachable)" >&2
    exit 1
fi

echo "$(date -Iseconds) INFO: qBittorrent listen port set to ${FORWARDED_PORT}"
