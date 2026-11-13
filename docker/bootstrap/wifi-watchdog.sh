#!/usr/bin/env bash
# Reboots a wifi-only host whose link stays "up" but passes no traffic.
#
# phis1 (Pi 5, k3s) hung this way on 2026-11-12: wpa_supplicant stayed
# associated, the OS kept running, but nothing got in or out for ~7.5 hours
# until a manual power cycle. A neighbouring wifi client saw no outage, so the
# fault was the Pi's wifi path, not the router or the internet. Power save has
# to stay on (turning it off made throughput unusable), so this is the
# stopgap until the host gets a wired drop.
#
# Install on the host as root (needs systemctl reboot), every minute:
#   * * * * * root /home/is/perihelion/docker/bootstrap/wifi-watchdog.sh
set -u
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

GATEWAY="${GATEWAY:-192.168.1.1}"
MAX_FAILS="${MAX_FAILS:-5}"          # consecutive failed minutes before reboot
MIN_UPTIME="${MIN_UPTIME:-1800}"     # seconds; stops a reboot loop if the router itself is down
STATE=/run/wifi-watchdog.fails       # tmpfs, so a reboot resets the count

if ping -c 3 -i 0.5 -W 2 -q "${GATEWAY}" >/dev/null 2>&1; then
    rm -f "${STATE}"
    exit 0
fi

fails=$(( $(cat "${STATE}" 2>/dev/null || echo 0) + 1 ))
echo "${fails}" > "${STATE}"
(( fails < MAX_FAILS )) && exit 0

uptime_s=$(cut -d. -f1 /proc/uptime)
if (( uptime_s < MIN_UPTIME )); then
    exit 0
fi

logger -t wifi-watchdog "gateway ${GATEWAY} unreachable for ${fails} min, rebooting"
sync
systemctl reboot
