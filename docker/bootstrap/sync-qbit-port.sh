#!/usr/bin/env bash
# Syncs Gluetun's ProtonVPN forwarded port to qBittorrent's listen port.
# ProtonVPN rotates the forwarded port periodically; this keeps qBittorrent
# listening on the correct port so peers can connect.
#
# Cron (every 5 minutes):
#   */5 * * * * /opt/homelab/docker/bootstrap/sync-qbit-port.sh >> /var/log/qbit-port-sync.log 2>&1
#
# Requires: curl, jq
# qBittorrent must have the Web UI enabled. If you've set a password,
# export QBIT_PASS before running or add it to a sourced env file.
set -euo pipefail

# Defaults match docker/.env (cron runs without it): QBIT_WEBUI_PORT=8085,
# gluetun control server published on 127.0.0.1:8000.
GLUETUN_API="${GLUETUN_API:-http://localhost:8000}"
QBIT_HOST="${QBIT_HOST:-http://localhost:${QBIT_WEBUI_PORT:-8085}}"
QBIT_USER="${QBIT_USER:-admin}"
QBIT_PASS="${QBIT_PASS:-}"

COOKIE_JAR="$(mktemp)"
trap 'rm -f "${COOKIE_JAR}"' EXIT

# --- Get forwarded port from Gluetun control server ---
FORWARDED_PORT=$(curl -sf "${GLUETUN_API}/v1/openvpn/portforwarded" | jq -r '.port // empty')

if [[ -z "${FORWARDED_PORT}" || "${FORWARDED_PORT}" == "0" ]]; then
    echo "$(date -Iseconds) ERROR: No forwarded port available from Gluetun (got '${FORWARDED_PORT:-empty}')" >&2
    exit 1
fi

# --- Authenticate with qBittorrent Web API ---
LOGIN_RESULT=$(curl -sf \
    -c "${COOKIE_JAR}" \
    "${QBIT_HOST}/api/v2/auth/login" \
    --data-urlencode "username=${QBIT_USER}" \
    --data-urlencode "password=${QBIT_PASS}")

if [[ "${LOGIN_RESULT}" != "Ok." ]]; then
    echo "$(date -Iseconds) ERROR: qBittorrent login failed (response: ${LOGIN_RESULT})" >&2
    exit 1
fi

SID=$(grep -oP '(?<=\tSID\t)[^\t\n]+' "${COOKIE_JAR}" || true)
if [[ -z "${SID}" ]]; then
    echo "$(date -Iseconds) ERROR: No SID cookie received from qBittorrent" >&2
    exit 1
fi

# --- Update listen port ---
curl -sf \
    -b "SID=${SID}" \
    "${QBIT_HOST}/api/v2/app/setPreferences" \
    --data "json={\"listen_port\":${FORWARDED_PORT}}" > /dev/null

echo "$(date -Iseconds) INFO: qBittorrent listen port set to ${FORWARDED_PORT}"
