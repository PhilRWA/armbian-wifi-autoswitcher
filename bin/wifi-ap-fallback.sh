#!/usr/bin/env bash
#
# wifi-ap-fallback.sh
#
# Keeps wlan0 connected to any known (saved) Wi-Fi network in range.
# If no known network is visible, brings up a local "Hotspot" AP instead.
# If the AP is already running, periodically drops it briefly to check
# whether a known network has come back into range.
#
# Requires NetworkManager, and a saved connection profile named
# by $HOTSPOT_CON for the fallback AP (see README.md).

set -uo pipefail

IFACE="wlan0"
HOTSPOT_CON="Hotspot"
STATE_FILE="/run/wifi-ap-fallback.state"
RECHECK_INTERVAL=300   # seconds between AP -> client re-checks
SCAN_SETTLE=3          # seconds to let a scan complete after dropping AP
LOG_TAG="wifi-ap-fallback"

log() { logger -t "$LOG_TAG" "$*"; }
now() { date +%s; }

# Returns success (0) if Moonraker reports the printer is currently
# printing or paused. If Moonraker isn't installed/running, or the check
# fails for any reason, treats it as "not busy" so this script still works
# fine on boards without Klipper.
printer_is_busy() {
    command -v python3 >/dev/null 2>&1 || return 1
    python3 - <<'PYEOF' 2>/dev/null
import json, sys, urllib.request
try:
    url = "http://127.0.0.1:7125/printer/objects/query?print_stats"
    with urllib.request.urlopen(url, timeout=2) as r:
        data = json.load(r)
    state = data.get("result", {}).get("status", {}).get("print_stats", {}).get("state", "")
    sys.exit(0 if state in ("printing", "paused") else 1)
except Exception:
    sys.exit(1)
PYEOF
}

get_active_con() {
    nmcli -t -f DEVICE,CONNECTION device status 2>/dev/null \
        | awk -F: -v d="$IFACE" '$1==d{print $2}'
}

# Prints the name of the first known (saved) wifi connection whose SSID
# is currently visible, or returns 1 if none match.
known_ssid_in_range() {
    local known_cons visible match ssid

    known_cons=$(nmcli -t -f NAME,TYPE connection show \
        | awk -F: -v h="$HOTSPOT_CON" '$2=="802-11-wireless" && $1!=h {print $1}')
    [ -z "$known_cons" ] && return 1

    visible=$(nmcli -t -f SSID device wifi list --rescan yes ifname "$IFACE" 2>/dev/null | sort -u)
    [ -z "$visible" ] && return 1

    match=""
    while IFS= read -r con; do
        [ -z "$con" ] && continue
        ssid=$(nmcli -g 802-11-wireless.ssid connection show "$con" 2>/dev/null)
        [ -z "$ssid" ] && ssid="$con"
        if printf '%s\n' "$visible" | grep -Fxq "$ssid"; then
            match="$con"
            break
        fi
    done <<< "$known_cons"

    [ -n "$match" ] || return 1
    echo "$match"
}

start_hotspot() {
    log "No known network in range; starting hotspot ($HOTSPOT_CON)."
    nmcli connection up "$HOTSPOT_CON" ifname "$IFACE" >/dev/null 2>&1 \
        || log "Failed to start hotspot"
}

connect_known() {
    local con="$1"
    log "Known network '$con' in range; connecting."
    nmcli connection up "$con" ifname "$IFACE" >/dev/null 2>&1 \
        || { log "Failed to connect to '$con'"; start_hotspot; }
}

main() {
    local active match last

    active=$(get_active_con)

    # Case 1: already connected to a real (non-hotspot) network. Nothing to do.
    if [ -n "$active" ] && [ "$active" != "$HOTSPOT_CON" ] && [ "$active" != "--" ]; then
        exit 0
    fi

    # Case 2: hotspot is currently running. Only re-check occasionally,
    # since checking requires briefly dropping the AP (single-radio hardware).
    if [ "$active" == "$HOTSPOT_CON" ]; then
        if printer_is_busy; then
            log "Printer is printing/paused; skipping hotspot recheck this cycle."
            exit 0
        fi

        last=0
        if [ -f "$STATE_FILE" ]; then
            last=$(cat "$STATE_FILE" 2>/dev/null || echo 0)
            [[ "$last" =~ ^[0-9]+$ ]] || last=0
        fi
        if (( $(now) - last < RECHECK_INTERVAL )); then
            exit 0
        fi
        echo "$(now)" > "$STATE_FILE"

        log "Hotspot active; briefly pausing it to check for known networks."
        nmcli connection down "$HOTSPOT_CON" >/dev/null 2>&1
        sleep "$SCAN_SETTLE"

        if match=$(known_ssid_in_range); then
            connect_known "$match"
        else
            start_hotspot
        fi
        exit 0
    fi

    # Case 3: not connected to anything at all.
    if match=$(known_ssid_in_range); then
        connect_known "$match"
    else
        start_hotspot
    fi
}

main
