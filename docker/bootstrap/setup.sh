#!/usr/bin/env bash
# phis4 Docker node — initial directory provisioning.
# Run once before first `docker compose up`.
# Must be run as a user with write access to DATA_DIR and CONFIG_DIR,
# or via sudo with the env vars set.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../.env"

if [[ ! -f "${ENV_FILE}" ]]; then
    echo "ERROR: ${ENV_FILE} not found. Copy and populate docker/.env first." >&2
    exit 1
fi

# shellcheck source=/dev/null
source "${ENV_FILE}"

echo "=== Data directories (${DATA_DIR}) ==="
mkdir -p \
    "${DATA_DIR}/movies" \
    "${DATA_DIR}/shows" \
    "${DATA_DIR}/music" \
    "${DATA_DIR}/torrents/movies" \
    "${DATA_DIR}/torrents/shows" \
    "${DATA_DIR}/torrents/music" \
    "${DATA_DIR}/torrents/audiobooks" \
    "${DATA_DIR}/usenet/incomplete" \
    "${DATA_DIR}/usenet/complete/movies" \
    "${DATA_DIR}/usenet/complete/shows" \
    "${DATA_DIR}/usenet/complete/music" \
    "${DATA_DIR}/usenet/complete/audiobooks" \
    "${DATA_DIR}/photos" \
    "${DATA_DIR}/books" \
    "${DATA_DIR}/podcasts" \
    "${DATA_DIR}/docs"

echo "Setting ownership on writable data directories..."
chown -R "${PUID}:${PGID}" \
    "${DATA_DIR}/torrents" \
    "${DATA_DIR}/usenet"

echo "=== Config directories (${CONFIG_DIR}) ==="
mkdir -p \
    "${CONFIG_DIR}/gluetun" \
    "${CONFIG_DIR}/qbittorrent" \
    "${CONFIG_DIR}/prowlarr" \
    "${CONFIG_DIR}/radarr" \
    "${CONFIG_DIR}/sonarr" \
    "${CONFIG_DIR}/lidarr" \
    "${CONFIG_DIR}/bookshelf" \
    "${CONFIG_DIR}/seedboxapi" \
    "${CONFIG_DIR}/jellyseerr" \
    "${CONFIG_DIR}/jellyfin" \
    "${CONFIG_DIR}/audiobookshelf/config" \
    "${CONFIG_DIR}/audiobookshelf/metadata" \
    "${CONFIG_DIR}/immich/db" \
    "${CONFIG_DIR}/metrics"

echo "Setting ownership on config directories..."
chown -R "${PUID}:${PGID}" "${CONFIG_DIR}"

echo "=== SOPS secrets ==="
echo "Decrypt secrets before starting services:"
echo "  sops -d docker/services/ingest/secrets.enc.env  > docker/services/ingest/.secrets.env"
echo "  sops -d docker/services/photos/secrets.enc.env  > docker/services/photos/.secrets.env"
echo ""
echo "Setup complete. Run 'docker compose up -d' from docker/ when ready."
