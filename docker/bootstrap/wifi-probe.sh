#!/usr/bin/env bash
# Pushes wifi radio quality + latency metrics to VictoriaMetrics.
#
# Temporary instrumentation while phis4 is on wifi. The byte and packet
# counters node_exporter already collects structurally cannot see 802.11
# contention: the radio retries failed frames at the MAC layer, so TCP never
# sees loss, only added latency. Jitter alongside a flat TCP retransmit ratio
# is exactly that signature. Retry ratio and negotiated PHY rate are what
# actually move during an event.
#
# Install on each wifi host worth watching: phis4 for the rich iwlwifi
# counters, phis1 as a second vantage point for the ping probe. Whatever the
# local driver does not expose is simply not emitted, so one script covers
# both (brcmfmac on the Pi reports no "tx retries").
#
# Cron (every minute):
#   * * * * * /opt/homelab/docker/bootstrap/wifi-probe.sh
#
# Requires: iw, curl, iputils-ping. No scrape job needed - this pushes to
# VictoriaMetrics' import endpoint by IP, which also sidesteps the
# container-side DNS that cannot resolve phis1.perihelion.live.
#
# Deliberately not "set -e": one failed ping or one absent driver counter must
# still leave the remaining metrics to be pushed. Deliberately not "pipefail"
# either, so the final pipeline's status is curl's and not a probe's.
set -u

# cron hands scripts a minimal environment and iw lives in /usr/sbin, so pin
# PATH rather than trusting whatever we were launched with.
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

VM_URL="${VM_URL:-http://192.168.1.215:8428/api/v1/import/prometheus}"
# Router first (the wifi hop on its own), then a WAN target. Subtracting the
# two RTTs isolates the leg beyond the gateway.
TARGETS="${TARGETS:-192.168.1.1 1.1.1.1}"
IFACE="${IFACE:-$(iw dev 2>/dev/null | awk '/Interface/{print $2; exit}')}"
HOST="$(hostname)"

{
    # ponytail: field equality rather than regexes over tab-indented output.
    # "tx packets" feeds the retry *ratio*; absolute retries track traffic
    # volume and say nothing on their own.
    [[ -n "${IFACE}" ]] && iw dev "${IFACE}" station dump | awk -v h="${HOST}" '
        $1=="signal:"              { printf "wifi_signal_dbm{host=\"%s\"} %s\n",       h, $2 }
        $1=="tx" && $2=="bitrate:" { printf "wifi_tx_bitrate_mbps{host=\"%s\"} %s\n",  h, $3 }
        $1=="rx" && $2=="bitrate:" { printf "wifi_rx_bitrate_mbps{host=\"%s\"} %s\n",  h, $3 }
        $1=="tx" && $2=="retries:" { printf "wifi_tx_retries_total{host=\"%s\"} %s\n", h, $3 }
        $1=="tx" && $2=="failed:"  { printf "wifi_tx_failed_total{host=\"%s\"} %s\n",  h, $3 }
        $1=="tx" && $2=="packets:" { printf "wifi_tx_packets_total{host=\"%s\"} %s\n", h, $3 }'

    for t in ${TARGETS}; do
        # 10 probes at 0.2s, the shortest interval ping allows unprivileged.
        ping -c 10 -i 0.2 -W 2 -q "${t}" 2>/dev/null | awk -v h="${HOST}" -v t="${t}" '
            /packet loss/ { for (i = 1; i <= NF; i++) if ($i ~ /%$/) { sub("%", "", $i)
                                printf "probe_loss_pct{host=\"%s\",target=\"%s\"} %s\n", h, t, $i } }
            $1=="rtt"     { split($4, a, "/")
                                printf "probe_rtt_ms{host=\"%s\",target=\"%s\"} %s\n",    h, t, a[2]
                                printf "probe_jitter_ms{host=\"%s\",target=\"%s\"} %s\n", h, t, a[4] }'
    done
} | curl -sf --max-time 10 --data-binary @- "${VM_URL}" || {
    echo "$(date -Iseconds) ERROR: metrics push to ${VM_URL} failed" >&2
    exit 1
}
