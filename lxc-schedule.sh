#!/usr/bin/env bash

# lxc-schedule.sh - Register a daily scheduled stop & start for a Proxmox LXC container.
#
# Run on the Proxmox host as root:
#   ./lxc-schedule.sh              # interactive: add/replace a schedule
#   ./lxc-schedule.sh --list       # show all registered schedules
#   ./lxc-schedule.sh --remove 101 # remove the schedule for CT 101
#
# How it works: it writes /etc/cron.d/pve-lxc-schedule-<CTID> containing one
# stop entry and one start entry. Cron picks it up automatically.

set -euo pipefail

CRON_DIR="/etc/cron.d"
PREFIX="pve-lxc-schedule-"

die() { echo "Error: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run this script as root on the Proxmox host."
command -v pct >/dev/null 2>&1 || die "'pct' not found - this must be run on a Proxmox VE host."

if [[ "${1:-}" == "--list" ]]; then
    shopt -s nullglob
    files=("$CRON_DIR/$PREFIX"*)
    [[ ${#files[@]} -gt 0 ]] || { echo "No schedules registered."; exit 0; }
    for f in "${files[@]}"; do
        echo "== $f"
        grep -vE '^\s*(#|$|SHELL|PATH)' "$f"
    done
    exit 0
fi

if [[ "${1:-}" == "--remove" ]]; then
    [[ -n "${2:-}" ]] || die "Usage: $0 --remove <CTID>"
    f="$CRON_DIR/$PREFIX$2"
    [[ -f "$f" ]] || die "No schedule found for CT $2."
    rm -f "$f"
    echo "Removed schedule for CT $2."
    exit 0
fi

echo "Available LXCs:"
pct list
echo

read -rp "Container ID/name: " CT_INPUT
[[ -n "$CT_INPUT" ]] || die "No container given."

CTID=""
# pct list columns: VMID Status [Lock] Name  -> name is always the last field
while read -r id name; do
    if [[ "$CT_INPUT" == "$id" || "$CT_INPUT" == "$name" ]]; then
        CTID="$id"
        CTNAME="$name"
        break
    fi
done < <(pct list | awk 'NR>1 {print $1, $NF}')

[[ -n "$CTID" ]] || die "Container '$CT_INPUT' not found."
echo "-> Using CT $CTID ($CTNAME)"
echo

TIME_RE='^([01]?[0-9]|2[0-3]):([0-5][0-9])$'

ask_time() {
    local prompt="$1" val
    while true; do
        read -rp "$prompt (HH:MM, 24h): " val
        if [[ "$val" =~ $TIME_RE ]]; then
            echo "$val"
            return
        fi
        echo "Invalid time, try again (e.g. 22:30)." >&2
    done
}

STOP_TIME=$(ask_time "Stop time")
START_TIME=$(ask_time "Start time")
[[ "$STOP_TIME" != "$START_TIME" ]] || die "Stop and start time can't be identical."

read -rp "Days of week [default: every day; e.g. 1-5 = Mon-Fri, 0,6 = Sat+Sun]: " DAYS
DAYS="${DAYS:-*}"
[[ "$DAYS" =~ ^[0-7,*/-]+$ ]] || die "Invalid days-of-week value."

# split HH:MM -> numeric (strip leading zeros so cron is happy)
STOP_H=$((10#${STOP_TIME%%:*}));  STOP_M=$((10#${STOP_TIME##*:}))
START_H=$((10#${START_TIME%%:*})); START_M=$((10#${START_TIME##*:}))

CRON_FILE="$CRON_DIR/$PREFIX$CTID"

if [[ -f "$CRON_FILE" ]]; then
    read -rp "A schedule for CT $CTID already exists. Replace it? [y/N]: " yn
    [[ "$yn" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
fi

# write the cron file
cat > "$CRON_FILE" <<EOF
# Managed by lxc-schedule.sh - CT $CTID ($CTNAME)
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Graceful shutdown (60s timeout, then force stop)
$STOP_M $STOP_H * * $DAYS root pct shutdown $CTID --forceStop 1 --timeout 60 2>&1 | logger -t lxc-schedule
# Start
$START_M $START_H * * $DAYS root pct start $CTID 2>&1 | logger -t lxc-schedule
EOF
chmod 644 "$CRON_FILE"

echo
echo "Schedule registered for CT $CTID ($CTNAME):"
printf "  Stop : %02d:%02d  (days: %s)\n" "$STOP_H" "$STOP_M" "$DAYS"
printf "  Start: %02d:%02d  (days: %s)\n" "$START_H" "$START_M" "$DAYS"
echo "  File : $CRON_FILE"
echo
echo "Manage with:  $0 --list   |   $0 --remove $CTID"
echo "Execution log: journalctl -t lxc-schedule"
