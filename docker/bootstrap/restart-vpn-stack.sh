#!/usr/bin/env bash
# Restarts gluetun together with every service sharing its network namespace.
#
# Recreating gluetun destroys its network sandbox. Containers using
# `network_mode: service:gluetun` stay attached to the old, dead namespace and
# go silently unreachable: the published host port now points into gluetun's
# new sandbox, where nothing is listening. Compose only cascades the recreate
# when you `up -d` the whole stack, so redeploying gluetun on its own orphans
# its dependents with no error anywhere.
#
# Restarting a dependent by itself does NOT need this script; it rejoins the
# same namespace as long as gluetun was untouched.
#
# Usage: bootstrap/restart-vpn-stack.sh
# Requires: docker compose v2.20+, jq
set -euo pipefail

VPN_SERVICE="${VPN_SERVICE:-gluetun}"
# qBittorrent sets a 30m stop_grace_period so active torrents can announce and
# flush. An orphaned container has no network to announce on, so don't wait it
# out. Override for a clean shutdown of a healthy stack: STOP_TIMEOUT=1800
STOP_TIMEOUT="${STOP_TIMEOUT:-60}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}/.."

# Read dependents from compose instead of hardcoding, so a new VPN-routed
# service is picked up without editing this script.
mapfile -t DEPS < <(docker compose config --format json \
    | jq -r --arg svc "${VPN_SERVICE}" \
        '.services | to_entries[]
         | select(.value.network_mode == "service:" + $svc) | .key')

# Guard, not a nicety: an empty list here (renamed service, compose schema
# change, jq missing) would restart gluetun and orphan every dependent, which
# is the exact failure this script exists to prevent.
if [[ ${#DEPS[@]} -eq 0 ]]; then
    echo "ERROR: no services found with 'network_mode: service:${VPN_SERVICE}'" >&2
    echo "       check the service name and that 'docker compose config' parses" >&2
    exit 1
fi

echo "Recreating ${VPN_SERVICE} and dependents: ${DEPS[*]}"
docker compose up -d --force-recreate -t "${STOP_TIMEOUT}" "${VPN_SERVICE}" "${DEPS[@]}"
