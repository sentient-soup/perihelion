#!/usr/bin/env bash
# Prints Gluetun's current public (VPN exit) IP — the IP MAM sees from
# seedboxapi. Use it for the initial dynamicSeedbox.php cookie handshake when
# setting up the MAM ASN-locked session (see services/ingest/compose.yaml).
#
#   ./get-gluetun-ip.sh
#
# Requires: curl, jq. Gluetun's control server must be reachable (published on
# 127.0.0.1:8000 in docker/.env).
set -euo pipefail

GLUETUN_API="${GLUETUN_API:-http://localhost:8000}"

IP=$(curl -sf "${GLUETUN_API}/v1/publicip/ip" | jq -r '.public_ip // empty')

if [[ -z "${IP}" ]]; then
    echo "ERROR: no public IP from Gluetun control server at ${GLUETUN_API}" >&2
    exit 1
fi

echo "${IP}"
