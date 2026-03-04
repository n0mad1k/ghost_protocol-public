#!/bin/bash
# /usr/local/bin/opsec-wifi-check.sh — Wireless Evil Twin Detection
# Periodic scan for AP changes, open networks, BSSID anomalies
# Usage: opsec-wifi-check.sh [scan|watch]

set -euo pipefail

OPSEC_LIB="/usr/local/lib/opsec/opsec-lib.sh"
if [ -f "$OPSEC_LIB" ]; then
    . "$OPSEC_LIB"
else
    opsec_green()  { echo -e "\033[38;5;49m[+] $*\033[0m"; }
    opsec_red()    { echo -e "\033[38;5;196m[-] $*\033[0m"; }
    opsec_yellow() { echo -e "\033[38;5;214m[*] $*\033[0m"; }
    opsec_info()   { echo -e "\033[38;5;39m[~] $*\033[0m"; }
    opsec_cyan()   { echo -e "\033[38;5;51m[>] $*\033[0m"; }
    opsec_hdr()    { echo -e "\033[38;5;51m━━━ \033[38;5;201m$*\033[38;5;51m ━━━\033[0m"; }
fi

STATE_DIR="/var/run/opsec-wifi"
mkdir -p "$STATE_DIR"

notify() {
    local msg="$1" urgency="${2:-normal}"
    local real_user="${SUDO_USER:-$USER}"
    su - "$real_user" -c "DISPLAY=:0 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u "$real_user")/bus notify-send -u '$urgency' 'OPSEC WiFi' '$msg'" 2>/dev/null || true
}

do_scan() {
    opsec_hdr "WIRELESS SECURITY SCAN"
    echo ""

    # Check if connected to WiFi
    local connected_ssid connected_bssid connected_security
    connected_ssid=$(nmcli -t -f active,ssid dev wifi 2>/dev/null | grep '^yes:' | cut -d: -f2)
    connected_bssid=$(nmcli -t -f active,bssid dev wifi 2>/dev/null | grep '^yes:' | cut -d: -f2-)
    connected_security=$(nmcli -t -f active,security dev wifi 2>/dev/null | grep '^yes:' | cut -d: -f2)

    if [ -z "$connected_ssid" ]; then
        opsec_info "Not connected to any WiFi network"
        return
    fi

    opsec_cyan "Connected: ${connected_ssid} (${connected_bssid})"
    echo ""

    # ─── Check for open/unencrypted network ────────────────────────────────
    if [ -z "$connected_security" ] || [ "$connected_security" = "--" ]; then
        opsec_red "WARNING: Connected to OPEN (unencrypted) network!"
        notify "Connected to OPEN WiFi: ${connected_ssid}" "critical"
    elif echo "$connected_security" | grep -qi 'WEP'; then
        opsec_red "WARNING: WEP encryption (trivially crackable)"
        notify "WiFi using WEP: ${connected_ssid}" "critical"
    else
        opsec_green "Encryption: ${connected_security}"
    fi

    # ─── Scan for duplicate SSIDs (evil twin indicators) ───────────────────
    opsec_info "Scanning for duplicate SSIDs..."
    local scan_results
    scan_results=$(nmcli -t -f ssid,bssid,signal,security dev wifi list --rescan yes 2>/dev/null || true)

    if [ -n "$scan_results" ]; then
        # Find APs with same SSID as connected but different BSSID
        local duplicates
        duplicates=$(echo "$scan_results" | grep "^${connected_ssid}:" | grep -v "${connected_bssid}" || true)

        if [ -n "$duplicates" ]; then
            local dup_count
            dup_count=$(echo "$duplicates" | wc -l)
            opsec_yellow "ALERT: ${dup_count} other AP(s) broadcasting '${connected_ssid}':"
            echo "$duplicates" | while IFS=: read -r ssid bssid signal security; do
                echo -e "  \033[38;5;214m  BSSID: ${bssid}  Signal: ${signal}  Security: ${security}\033[0m"
            done
            notify "Evil twin risk: ${dup_count} duplicate AP(s) for ${connected_ssid}" "critical"
        else
            opsec_green "No duplicate SSIDs detected"
        fi
    fi

    # ─── BSSID change detection ────────────────────────────────────────────
    local state_file="${STATE_DIR}/${connected_ssid}.bssid"
    if [ -f "$state_file" ]; then
        local prev_bssid
        prev_bssid=$(cat "$state_file")
        if [ "$prev_bssid" != "$connected_bssid" ]; then
            opsec_red "BSSID CHANGED for '${connected_ssid}'!"
            opsec_red "  Previous: ${prev_bssid}"
            opsec_red "  Current:  ${connected_bssid}"
            notify "BSSID changed for ${connected_ssid}: ${prev_bssid} → ${connected_bssid}" "critical"
        else
            opsec_green "BSSID consistent with last scan"
        fi
    fi
    echo "$connected_bssid" > "$state_file"

    echo ""
}

do_watch() {
    opsec_info "Starting continuous WiFi monitoring (Ctrl+C to stop)..."
    while true; do
        do_scan
        echo ""
        opsec_info "Next scan in 60 seconds..."
        sleep 60
    done
}

case "${1:-scan}" in
    scan)  do_scan ;;
    watch) do_watch ;;
    *)
        echo "Usage: $(basename "$0") [scan|watch]"
        echo ""
        echo "  scan  — One-time wireless security scan (default)"
        echo "  watch — Continuous monitoring (60s interval)"
        exit 1
        ;;
esac
