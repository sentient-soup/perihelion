#!/usr/bin/env bash
# smartd "-M exec" handler: push SMART warnings to Discord and/or ntfy.
#
# smartd invokes this with the alert details in environment variables and the
# full report on stdin. Configured in /etc/smartd.conf with:
#   -m <nomailer> -M exec /opt/homelab/docker/bootstrap/smartd-notify.sh
# The <nomailer> literal is what tells smartd to skip mail entirely and only
# run the script.
#
# Webhook URLs are secrets, so they live in /etc/default/smartd-notify
# (root-owned, 0600, host-only) rather than in this file. See the .example.
#
# Deliberately not "set -e": a failed push must not stop the other transport
# from being tried, and must not make smartd think the handler crashed.
set -uo pipefail

# smartd hands handlers a minimal environment and smartctl lives in /usr/sbin,
# so pin PATH instead of trusting whatever we were launched with.
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

CONF=/etc/default/smartd-notify
# shellcheck source=/dev/null
[ -r "$CONF" ] && . "$CONF"

BODY="$(cat)"
DEV="${SMARTD_DEVICE:-unknown}"
TYPE="${SMARTD_FAILTYPE:-unknown}"
MSG="${SMARTD_MESSAGE:-no message}"

# The serial is what turns an alert into a physical action. Every drive here is
# behind a USB bridge, so device letters move across reboots and are useless for
# identifying which disk to pull. Cross-reference against the bay table.
#
# Auto-detect first so this works for the nvme too, then fall back to the
# explicit SAT passthrough the USB bridges need.
read_serial() {
    smartctl "$@" -i "$DEV" 2>/dev/null |
        awk -F': *' '/Serial Number/{print $2; exit}'
}
SERIAL="$(read_serial)"
[ -z "$SERIAL" ] && SERIAL="$(read_serial -d sat)"
if [ -z "$SERIAL" ]; then
    # An alert with no serial is unactionable, so leave the reason in the journal.
    why="$(smartctl -d sat -i "$DEV" 2>&1 | head -5 | tr '\n' '|')"
    logger -t smartd-notify -p daemon.warning "serial lookup failed for ${DEV}: ${why}"
fi
SERIAL="${SERIAL:-unknown}"

HOST="$(hostname -s)"

TEXT="${MSG}

device: ${DEV}
serial: ${SERIAL}
type:   ${TYPE}
host:   ${HOST}
time:   $(date '+%Y-%m-%d %H:%M:%S %Z')

${BODY}"

sent=0

if [ -n "${DISCORD_WEBHOOK:-}" ]; then
    # Discord caps content at 2000 chars and a long SMART report blows past it.
    # jq -Rn does the JSON escaping; hand-rolled quoting breaks on the backticks
    # and newlines that SMART output is full of.
    # DISCORD_MENTION (e.g. <@&ROLE_ID>) is what makes the phone buzz: the server
    # default is "only @mentions", so an unmentioned alert arrives silently.
    payload=$(jq -Rn --arg c "${TEXT:0:1700}" --arg h "$HOST" \
        --arg m "${DISCORD_MENTION:-}" \
        '{content: ((if $m != "" then $m + " " else "" end)
            + "**SMART warning on " + $h + "**\n```\n" + $c + "\n```")}')
    if curl -fsS -m 15 -H 'Content-Type: application/json' -d "$payload" \
            "$DISCORD_WEBHOOK" >/dev/null 2>&1; then
        sent=1
    else
        logger -t smartd-notify "discord push failed for ${SERIAL}"
    fi
fi

if [ -n "${NTFY_URL:-}" ]; then
    # An array, not a bare ${VAR:+...} expansion: unquoted word splitting would
    # break "Authorization: Bearer xxx" into three separate curl arguments.
    ntfy_auth=()
    if [ -n "${NTFY_TOKEN:-}" ]; then
        ntfy_auth=(-H "Authorization: Bearer ${NTFY_TOKEN}")
    fi
    if curl -fsS -m 15 \
            "${ntfy_auth[@]}" \
            -H "Title: SMART warning: ${SERIAL}" \
            -H "Priority: urgent" \
            -H "Tags: rotating_light,floppy_disk" \
            -d "$TEXT" \
            "$NTFY_URL" >/dev/null 2>&1; then
        sent=1
    else
        logger -t smartd-notify "ntfy push failed for ${SERIAL}"
    fi
fi

# A SMART warning nobody receives is worse than no monitoring, because you
# believe you are covered. Leave a trace in the journal either way.
if [ "$sent" -eq 0 ]; then
    logger -t smartd-notify -p daemon.err \
        "ALL TRANSPORTS FAILED, unsent SMART warning: ${SERIAL} ${TYPE} ${MSG}"
else
    logger -t smartd-notify "sent SMART warning: ${SERIAL} ${TYPE}"
fi

exit 0
