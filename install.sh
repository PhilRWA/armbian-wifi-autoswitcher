#!/usr/bin/env bash
#
# install.sh - one-shot installer for wifi-ap-fallback + wifi-manager
#
# Run this FROM WITHIN the cloned repo directory, with sudo:
#   git clone <your-repo-url>
#   cd <repo-name>
#   sudo ./install.sh
#
# Sets up:
#   - NetworkManager managing wlan0
#   - Your home Wi-Fi saved as a known network
#   - A "Hotspot" fallback AP profile
#   - The wifi-ap-fallback background service (known network <-> AP switching)
#   - The wifi-manager web UI for adding networks without the command line

set -uo pipefail

BOLD="\033[1m"
RED="\033[31m"
YELLOW="\033[33m"
GREEN="\033[32m"
RESET="\033[0m"

die() { echo -e "${RED}${BOLD}ERROR:${RESET} $*" >&2; exit 1; }
info() { echo -e "${GREEN}==>${RESET} $*"; }
warn() { echo -e "${YELLOW}WARNING:${RESET} $*"; }

[ "$(id -u)" -eq 0 ] || die "Please run this with sudo: sudo ./install.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for f in bin/wifi-ap-fallback.sh bin/wifi-manager.py \
         systemd/wifi-ap-fallback.service systemd/wifi-ap-fallback.timer systemd/wifi-manager.service; do
    [ -f "$SCRIPT_DIR/$f" ] || die "Expected file missing: $f. Are you running this from inside the cloned repo?"
done

IFACE="wlan0"

cat <<'BANNER'
=========================================================================
 Wi-Fi known-network / AP-fallback installer
=========================================================================

This will configure NetworkManager to control your Wi-Fi adaptor
(wlan0). If you are connected over SSH via Wi-Fi right now, there is a
real chance of a brief (or, if something goes wrong, longer) loss of
connection while network management switches over.

This script tries hard to avoid that (it saves your current Wi-Fi
network's credentials into NetworkManager BEFORE handing it control),
but on an SBC like this the safest way to run this is:
  - with a monitor + keyboard plugged directly into the board, OR
  - with serial console access as a fallback, OR
  - accepting that you may need to wait ~30-60 seconds and reconnect,
    or in a bad case, plug in a monitor/keyboard to recover.

If this device is currently running an active 3D print via Klipper,
that print will NOT be interrupted by anything in this script -
Klipper talks to the printer over USB/serial, independent of Wi-Fi.
Only remote monitoring (Mainsail/Moonraker over the network) could
blip briefly.
BANNER
echo
read -r -p "Type YES (all caps) to confirm you understand and want to continue: " CONFIRM
[ "$CONFIRM" = "YES" ] || die "Aborted. Nothing was changed."

echo
info "Gathering some information first (nothing is changed yet)."
echo

read -r -p "Your home/known Wi-Fi network's SSID (exact, case-sensitive): " HOME_SSID
[ -n "$HOME_SSID" ] || die "SSID cannot be empty."
[ "$HOME_SSID" != "Hotspot" ] || die "Please don't name your home network 'Hotspot' - that name is reserved internally for the fallback AP profile and reusing it will break known-network detection. Rename it on your router, or just pick a different network to use here."

read -r -s -p "Its password (input hidden, leave blank if it's an open network): " HOME_PASS
echo
if [ -n "$HOME_PASS" ] && [ "${#HOME_PASS}" -lt 8 ]; then
    die "Wi-Fi passwords need to be at least 8 characters."
fi

read -r -p "Fallback hotspot SSID to broadcast when no known network is found [BPI-Fallback]: " HOTSPOT_SSID
HOTSPOT_SSID="${HOTSPOT_SSID:-BPI-Fallback}"
[ "$HOTSPOT_SSID" != "$HOME_SSID" ] || die "The hotspot SSID can't be the same as your home network's SSID."

while true; do
    read -r -s -p "Fallback hotspot password (min 8 characters): " HOTSPOT_PASS
    echo
    [ "${#HOTSPOT_PASS}" -ge 8 ] && break
    echo "Too short - needs to be at least 8 characters."
done

while true; do
    read -r -s -p "Password for the web UI (used to add/remove networks from a browser, min 8 characters): " WEBUI_PASS
    echo
    [ "${#WEBUI_PASS}" -ge 8 ] && break
    echo "Too short - needs to be at least 8 characters."
done

read -r -p "Port for the web UI [8080]: " WEBUI_PORT
WEBUI_PORT="${WEBUI_PORT:-8080}"
[[ "$WEBUI_PORT" =~ ^[0-9]+$ ]] || die "Port must be a number."

echo
info "Got everything. Starting installation."

info "Installing NetworkManager (skipped if already installed)..."
apt-get update -qq || warn "apt-get update failed, continuing with cached package lists"
apt-get install -y network-manager || die "Failed to install network-manager"

info "Starting NetworkManager..."
systemctl enable --now NetworkManager || die "Failed to start NetworkManager"
sleep 2

info "Saving your home network into NetworkManager BEFORE handing it wlan0..."
nmcli connection delete "$HOME_SSID" >/dev/null 2>&1 || true
if [ -n "$HOME_PASS" ]; then
    nmcli connection add type wifi ifname "$IFACE" con-name "$HOME_SSID" ssid "$HOME_SSID" \
        wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$HOME_PASS" connection.autoconnect yes \
        || die "Failed to create the home network profile"
else
    nmcli connection add type wifi ifname "$IFACE" con-name "$HOME_SSID" ssid "$HOME_SSID" \
        connection.autoconnect yes \
        || die "Failed to create the home network profile"
fi

info "Handing wlan0 to NetworkManager..."
nmcli device set "$IFACE" managed yes

info "Connecting to '$HOME_SSID' now (this is the moment a Wi-Fi SSH session could blip)..."
if nmcli connection up "$HOME_SSID" ifname "$IFACE"; then
    info "Connected to '$HOME_SSID' successfully."
else
    warn "Could not connect to '$HOME_SSID' automatically."
    warn "Double check the SSID/password are correct and it's in range, then run:"
    warn "  sudo nmcli connection up \"$HOME_SSID\" ifname $IFACE"
    warn "Stopping here so nothing else changes on top of a broken connection."
    die "Fix the connection above, then re-run this installer."
fi

info "Creating the fallback hotspot profile ('$HOTSPOT_SSID')..."
nmcli connection delete Hotspot >/dev/null 2>&1 || true
nmcli connection add type wifi ifname "$IFACE" con-name Hotspot autoconnect no ssid "$HOTSPOT_SSID" \
    || die "Failed to create hotspot profile"
nmcli connection modify Hotspot 802-11-wireless.mode ap 802-11-wireless.band bg
nmcli connection modify Hotspot ipv4.method shared
nmcli connection modify Hotspot wifi-sec.key-mgmt wpa-psk
nmcli connection modify Hotspot wifi-sec.psk "$HOTSPOT_PASS"

info "Testing the hotspot briefly (will drop your Wi-Fi client connection for ~10 seconds)..."
if nmcli connection up Hotspot ifname "$IFACE"; then
    sleep 3
    info "Hotspot came up. Switching back to '$HOME_SSID'..."
    nmcli connection down Hotspot >/dev/null 2>&1 || true
    sleep 1
    nmcli connection up "$HOME_SSID" ifname "$IFACE" >/dev/null 2>&1 \
        || warn "Could not reconnect automatically to '$HOME_SSID' - you may need to run: sudo nmcli connection up \"$HOME_SSID\""
else
    warn "Hotspot test failed to come up. Check 'journalctl -u NetworkManager -n 50' later."
    warn "Continuing installation anyway - the background service will retry it later."
fi

info "Installing the background fallback script..."
install -m 755 "$SCRIPT_DIR/bin/wifi-ap-fallback.sh" /usr/local/bin/wifi-ap-fallback.sh

info "Installing the web UI..."
install -m 755 "$SCRIPT_DIR/bin/wifi-manager.py" /usr/local/bin/wifi-manager.py

info "Writing web UI config..."
{
    printf 'PORT=%s\n' "$WEBUI_PORT"
    printf 'PASSWORD=%s\n' "$WEBUI_PASS"
} > /etc/wifi-manager.conf
chmod 600 /etc/wifi-manager.conf

info "Installing systemd units..."
install -m 644 "$SCRIPT_DIR/systemd/wifi-ap-fallback.service" /etc/systemd/system/wifi-ap-fallback.service
install -m 644 "$SCRIPT_DIR/systemd/wifi-ap-fallback.timer" /etc/systemd/system/wifi-ap-fallback.timer
install -m 644 "$SCRIPT_DIR/systemd/wifi-manager.service" /etc/systemd/system/wifi-manager.service

info "Enabling services..."
systemctl daemon-reload
systemctl enable --now wifi-ap-fallback.timer || die "Failed to enable wifi-ap-fallback.timer"
systemctl enable --now wifi-manager.service || die "Failed to enable wifi-manager.service"

CURRENT_IP=$(hostname -I 2>/dev/null | awk '{print $1}')

echo
echo -e "${GREEN}${BOLD}=========================================================================${RESET}"
echo -e "${GREEN}${BOLD} Done!${RESET}"
echo -e "${GREEN}${BOLD}=========================================================================${RESET}"
echo
echo "Web UI (while on your home network):  http://${CURRENT_IP:-<device-ip>}:$WEBUI_PORT"
echo "Web UI (while on the fallback hotspot '$HOTSPOT_SSID'): http://10.42.0.1:$WEBUI_PORT"
echo "Log in with any username and the web UI password you just set."
echo
echo "Check status any time with:"
echo "  systemctl status wifi-ap-fallback.timer"
echo "  systemctl status wifi-manager"
echo "  journalctl -t wifi-ap-fallback -f"
echo
