#!/bin/bash
# /usr/local/bin/opsec-config.sh — Interactive OPSEC Configuration Manager
# TUI: whiptail primary, pure ANSI fallback
# CLI: --boot, --profile, --theme, --set, --get, --apply
#
# Usage:
#   sudo opsec-config.sh                    # Interactive TUI
#   sudo opsec-config.sh --boot on|off      # Toggle boot-into-advanced
#   sudo opsec-config.sh --profile save|load|list|delete NAME
#   sudo opsec-config.sh --set KEY VALUE    # Set config value
#   sudo opsec-config.sh --get KEY          # Get config value
#   sudo opsec-config.sh --apply            # Regenerate configs and restart services

set -euo pipefail

if [ "$EUID" -ne 0 ]; then
    echo "[!] Please run as root: sudo opsec-config.sh"
    exit 1
fi

OPSEC_LIB="/usr/local/lib/opsec/opsec-lib.sh"
BOOT_MARKER="/etc/opsec/boot-advanced.enabled"

# Source shared library
if [ -f "$OPSEC_LIB" ]; then
    . "$OPSEC_LIB"
    opsec_load_config 2>/dev/null || true
else
    echo "[-] OPSEC library not found at $OPSEC_LIB"
    echo "    Deploy with: sudo mkdir -p /usr/local/lib/opsec && sudo cp opsec-lib.sh $OPSEC_LIB"
    exit 1
fi

# ─── TUI DETECTION ─────────────────────────────────────────────────────────────
USE_WHIPTAIL=false
if command -v whiptail >/dev/null 2>&1 && [ -t 0 ]; then
    USE_WHIPTAIL=true
fi

TERM_ROWS=$(tput lines 2>/dev/null || echo 24)
TERM_COLS=$(tput cols 2>/dev/null || echo 80)
WT_HEIGHT=$((TERM_ROWS - 4))
WT_WIDTH=$((TERM_COLS - 10))
[ "$WT_HEIGHT" -gt 30 ] && WT_HEIGHT=30
[ "$WT_WIDTH" -gt 78 ] && WT_WIDTH=78

# ─── ANSI COLORS ───────────────────────────────────────────────────────────────
C_CYAN="\033[38;5;51m"
C_MAG="\033[38;5;201m"
C_GREEN="\033[38;5;49m"
C_RED="\033[38;5;196m"
C_AMBER="\033[38;5;214m"
C_DIM="\033[38;5;244m"
C_WHITE="\033[38;5;255m"
C_BLUE="\033[38;5;75m"
C_RST="\033[0m"

# ─── ANSI FALLBACK HELPERS ─────────────────────────────────────────────────────

ansi_banner() {
    echo -e "${C_CYAN}╔══════════════════════════════════════════════════╗${C_RST}"
    echo -e "${C_CYAN}║${C_MAG}       OPSEC CONFIGURATION MANAGER              ${C_CYAN}║${C_RST}"
    echo -e "${C_CYAN}║${C_DIM}       Profile: ${PROFILE_NAME:-default}${C_CYAN}$(printf '%*s' $((36 - ${#PROFILE_NAME:-7})) '')║${C_RST}"
    echo -e "${C_CYAN}╚══════════════════════════════════════════════════╝${C_RST}"
    echo ""
}

ansi_menu() {
    local title="$1"
    shift
    local items=("$@")
    local choice=""

    echo -e "${C_CYAN}━━━ ${C_MAG}${title}${C_CYAN} ━━━${C_RST}"
    echo ""

    local i=1
    for item in "${items[@]}"; do
        local num label
        num=$(echo "$item" | cut -d'|' -f1)
        label=$(echo "$item" | cut -d'|' -f2)
        echo -e "  ${C_CYAN}${num}${C_RST}) ${C_WHITE}${label}${C_RST}"
        i=$((i + 1))
    done
    echo -e "  ${C_RED}0${C_RST}) ${C_DIM}Back / Exit${C_RST}"
    echo ""
    echo -ne "${C_BLUE}▸ ${C_RST}"
    read -r choice
    echo "$choice"
}

ansi_toggle() {
    local label="$1" current="$2"
    local display
    if [ "$current" = "1" ]; then
        display="${C_GREEN}ON${C_RST}"
    else
        display="${C_RED}OFF${C_RST}"
    fi
    echo -e "  ${C_WHITE}${label}: ${display}${C_RST}"
}

ansi_input() {
    local prompt="$1" default="$2"
    echo -ne "${C_BLUE}${prompt}${C_RST} [${C_DIM}${default}${C_RST}]: "
    local val
    read -r val
    echo "${val:-$default}"
}

ansi_confirm() {
    local prompt="$1"
    echo -ne "${C_AMBER}${prompt} (y/N): ${C_RST}"
    local ans
    read -r ans
    [[ "$ans" =~ ^[Yy] ]]
}

# ─── WHIPTAIL HELPERS ──────────────────────────────────────────────────────────

wt_menu() {
    local title="$1"
    shift
    local items=()
    while [ $# -gt 0 ]; do
        items+=("$1" "$2")
        shift 2
    done
    whiptail --title "$title" --menu "Profile: ${PROFILE_NAME:-default}" \
        "$WT_HEIGHT" "$WT_WIDTH" $((WT_HEIGHT - 8)) "${items[@]}" 3>&1 1>&2 2>&3 || echo ""
}

wt_yesno() {
    whiptail --title "$1" --yesno "$2" 10 60 3>&1 1>&2 2>&3
}

wt_input() {
    whiptail --title "$1" --inputbox "$2" 10 60 "$3" 3>&1 1>&2 2>&3 || echo "$3"
}

wt_toggle() {
    local key="$1" label="$2" current
    current=$(opsec_get_value "$key")
    if [ "$current" = "1" ]; then
        opsec_set_value "$key" "0"
        opsec_yellow "${label}: OFF"
    else
        opsec_set_value "$key" "1"
        opsec_green "${label}: ON"
    fi
    opsec_load_config
}

# ─── MENU IMPLEMENTATIONS ─────────────────────────────────────────────────────

menu_tor() {
    while true; do
        opsec_load_config 2>/dev/null || true
        local choice
        if $USE_WHIPTAIL; then
            choice=$(wt_menu "Tor Settings" \
                "1" "Circuit Rotation: ${TOR_CIRCUIT_ROTATION:-30}s" \
                "2" "Exit Blacklist: ${TOR_BLACKLIST:-us,gb,ca,au,nz}" \
                "3" "Strict Nodes: $([ "${TOR_STRICT_NODES:-1}" = "1" ] && echo ON || echo OFF)" \
                "4" "Stream Isolation: $([ "${TOR_ISOLATION:-1}" = "1" ] && echo ON || echo OFF)" \
                "5" "Traffic Padding: $([ "${TOR_PADDING:-1}" = "1" ] && echo ON || echo OFF)" \
                "6" "SOCKS Port: ${TOR_SOCKS_PORT:-9050}" \
                "7" "DNS Port: ${TOR_DNS_PORT:-5353}" \
                "8" "Entry Guards: ${TOR_NUM_GUARDS:-3}" \
                "9" "Blacklist Editor...")
        else
            clear
            ansi_banner
            echo -e "${C_CYAN}━━━ ${C_MAG}TOR SETTINGS${C_CYAN} ━━━${C_RST}"
            echo ""
            echo -e "  ${C_CYAN}1${C_RST}) Circuit Rotation: ${C_WHITE}${TOR_CIRCUIT_ROTATION:-30}s${C_RST}"
            echo -e "  ${C_CYAN}2${C_RST}) Exit Blacklist: ${C_WHITE}${TOR_BLACKLIST:-us,gb,ca,au,nz}${C_RST}"
            ansi_toggle "3) Strict Nodes" "${TOR_STRICT_NODES:-1}"
            ansi_toggle "4) Stream Isolation" "${TOR_ISOLATION:-1}"
            ansi_toggle "5) Traffic Padding" "${TOR_PADDING:-1}"
            echo -e "  ${C_CYAN}6${C_RST}) SOCKS Port: ${C_WHITE}${TOR_SOCKS_PORT:-9050}${C_RST}"
            echo -e "  ${C_CYAN}7${C_RST}) DNS Port: ${C_WHITE}${TOR_DNS_PORT:-5353}${C_RST}"
            echo -e "  ${C_CYAN}8${C_RST}) Entry Guards: ${C_WHITE}${TOR_NUM_GUARDS:-3}${C_RST}"
            echo -e "  ${C_CYAN}9${C_RST}) ${C_MAG}Blacklist Editor...${C_RST}"
            echo -e "  ${C_RED}0${C_RST}) ${C_DIM}Back${C_RST}"
            echo ""
            echo -ne "${C_BLUE}▸ ${C_RST}"
            read -r choice
        fi

        case "$choice" in
            1) local val; val=$(ansi_input "Circuit rotation (seconds)" "${TOR_CIRCUIT_ROTATION:-30}")
               opsec_set_value TOR_CIRCUIT_ROTATION "$val" ;;
            2) local val; val=$(ansi_input "Blacklist (comma-separated country codes)" "${TOR_BLACKLIST:-us,gb,ca,au,nz}")
               opsec_set_value TOR_BLACKLIST "$val" ;;
            3) wt_toggle TOR_STRICT_NODES "Strict Nodes" ;;
            4) wt_toggle TOR_ISOLATION "Stream Isolation" ;;
            5) wt_toggle TOR_PADDING "Traffic Padding" ;;
            6) local val; val=$(ansi_input "SOCKS port" "${TOR_SOCKS_PORT:-9050}")
               opsec_set_value TOR_SOCKS_PORT "$val" ;;
            7) local val; val=$(ansi_input "DNS port" "${TOR_DNS_PORT:-5353}")
               opsec_set_value TOR_DNS_PORT "$val" ;;
            8) local val; val=$(ansi_input "Number of entry guards" "${TOR_NUM_GUARDS:-3}")
               opsec_set_value TOR_NUM_GUARDS "$val" ;;
            9) menu_blacklist_editor ;;
            0|"") return ;;
        esac
    done
}

menu_blacklist_editor() {
    while true; do
        opsec_load_config 2>/dev/null || true
        opsec_load_country_presets 2>/dev/null || true
        local current="${TOR_BLACKLIST:-}"

        clear
        echo -e "${C_CYAN}━━━ ${C_MAG}BLACKLIST EDITOR${C_CYAN} ━━━${C_RST}"
        echo ""
        echo -e "${C_DIM}Current blacklist:${C_RST} ${C_WHITE}${current:-none}${C_RST}"
        echo ""
        echo -e "  ${C_CYAN}1${C_RST}) Add country code"
        echo -e "  ${C_CYAN}2${C_RST}) Remove country code"
        echo -e "  ${C_CYAN}3${C_RST}) Load preset: ${C_GREEN}Five Eyes${C_RST}"
        echo -e "  ${C_CYAN}4${C_RST}) Load preset: ${C_AMBER}Nine Eyes${C_RST}"
        echo -e "  ${C_CYAN}5${C_RST}) Load preset: ${C_RED}Fourteen Eyes${C_RST}"
        echo -e "  ${C_CYAN}6${C_RST}) Load preset: ${C_MAG}Max Exclusion${C_RST}"
        echo -e "  ${C_CYAN}7${C_RST}) Clear blacklist"
        echo -e "  ${C_RED}0${C_RST}) ${C_DIM}Back${C_RST}"
        echo ""
        echo -ne "${C_BLUE}▸ ${C_RST}"
        local choice
        read -r choice

        case "$choice" in
            1)
                local code
                code=$(ansi_input "Country code to add (e.g. us, de, cn)" "")
                if [ -n "$code" ]; then
                    if [ -z "$current" ]; then
                        opsec_set_value TOR_BLACKLIST "$code"
                    else
                        # Avoid duplicates
                        if ! echo ",$current," | grep -q ",$code,"; then
                            opsec_set_value TOR_BLACKLIST "${current},${code}"
                        else
                            opsec_yellow "${code} already in blacklist"
                            sleep 1
                        fi
                    fi
                fi
                ;;
            2)
                local code
                code=$(ansi_input "Country code to remove" "")
                if [ -n "$code" ]; then
                    local new_list
                    new_list=$(echo "$current" | tr ',' '\n' | grep -v "^${code}$" | paste -sd,)
                    opsec_set_value TOR_BLACKLIST "$new_list"
                fi
                ;;
            3) opsec_set_value TOR_BLACKLIST "$FIVE_EYES"; opsec_green "Five Eyes preset loaded" ; sleep 1 ;;
            4) opsec_set_value TOR_BLACKLIST "$NINE_EYES"; opsec_green "Nine Eyes preset loaded" ; sleep 1 ;;
            5) opsec_set_value TOR_BLACKLIST "$FOURTEEN_EYES"; opsec_green "Fourteen Eyes preset loaded" ; sleep 1 ;;
            6) opsec_set_value TOR_BLACKLIST "$MAX_EXCLUSION"; opsec_green "Max exclusion preset loaded" ; sleep 1 ;;
            7) opsec_set_value TOR_BLACKLIST ""; opsec_yellow "Blacklist cleared" ; sleep 1 ;;
            0|"") return ;;
        esac
    done
}

menu_dns() {
    while true; do
        opsec_load_config 2>/dev/null || true
        clear
        echo -e "${C_CYAN}━━━ ${C_MAG}DNS SETTINGS${C_CYAN} ━━━${C_RST}"
        echo ""
        echo -e "${C_DIM}Current mode:${C_RST} ${C_WHITE}${DNS_MODE:-tor}${C_RST}"
        [ -n "${DNS_CUSTOM_SERVERS:-}" ] && echo -e "${C_DIM}Custom servers:${C_RST} ${C_WHITE}${DNS_CUSTOM_SERVERS}${C_RST}"
        echo ""
        echo -e "  ${C_CYAN}1${C_RST}) ${C_GREEN}tor${C_RST}        — Route DNS through Tor (127.0.0.1)"
        echo -e "  ${C_CYAN}2${C_RST}) ${C_WHITE}quad9${C_RST}      — Quad9 (9.9.9.9 / 149.112.112.112)"
        echo -e "  ${C_CYAN}3${C_RST}) ${C_WHITE}cloudflare${C_RST} — Cloudflare (1.1.1.1 / 1.0.0.1)"
        echo -e "  ${C_CYAN}4${C_RST}) ${C_AMBER}doh${C_RST}        — DNS-over-HTTPS via systemd-resolved"
        echo -e "  ${C_CYAN}5${C_RST}) ${C_AMBER}dot${C_RST}        — DNS-over-TLS via systemd-resolved"
        echo -e "  ${C_CYAN}6${C_RST}) ${C_MAG}custom${C_RST}     — Specify custom servers"
        echo -e "  ${C_RED}0${C_RST}) ${C_DIM}Back${C_RST}"
        echo ""
        echo -ne "${C_BLUE}▸ ${C_RST}"
        local choice
        read -r choice

        case "$choice" in
            1) opsec_set_value DNS_MODE "tor" ;;
            2) opsec_set_value DNS_MODE "quad9" ;;
            3) opsec_set_value DNS_MODE "cloudflare" ;;
            4) opsec_set_value DNS_MODE "doh" ;;
            5) opsec_set_value DNS_MODE "dot" ;;
            6)
                local servers
                servers=$(ansi_input "DNS servers (comma-separated IPs)" "${DNS_CUSTOM_SERVERS:-}")
                opsec_set_value DNS_MODE "custom"
                opsec_set_value DNS_CUSTOM_SERVERS "$servers"
                ;;
            0|"") return ;;
        esac
    done
}

menu_killswitch() {
    while true; do
        opsec_load_config 2>/dev/null || true
        clear
        echo -e "${C_CYAN}━━━ ${C_MAG}KILL SWITCH SETTINGS${C_CYAN} ━━━${C_RST}"
        echo ""
        ansi_toggle "1) Allow DHCP" "${KILLSWITCH_ALLOW_DHCP:-1}"
        ansi_toggle "2) Allow OpenVPN" "${KILLSWITCH_ALLOW_OPENVPN:-1}"
        ansi_toggle "3) Allow WireGuard" "${KILLSWITCH_ALLOW_WIREGUARD:-1}"
        echo -e "  ${C_CYAN}4${C_RST}) Extra Ports: ${C_WHITE}${KILLSWITCH_EXTRA_PORTS:-none}${C_RST}"
        echo -e "  ${C_RED}0${C_RST}) ${C_DIM}Back${C_RST}"
        echo ""
        echo -ne "${C_BLUE}▸ ${C_RST}"
        local choice
        read -r choice

        case "$choice" in
            1) wt_toggle KILLSWITCH_ALLOW_DHCP "DHCP" ;;
            2) wt_toggle KILLSWITCH_ALLOW_OPENVPN "OpenVPN" ;;
            3) wt_toggle KILLSWITCH_ALLOW_WIREGUARD "WireGuard" ;;
            4) local val; val=$(ansi_input "Extra ports (format: tcp:443,udp:8080)" "${KILLSWITCH_EXTRA_PORTS:-}")
               opsec_set_value KILLSWITCH_EXTRA_PORTS "$val" ;;
            0|"") return ;;
        esac
    done
}

menu_mac() {
    while true; do
        opsec_load_config 2>/dev/null || true
        clear
        echo -e "${C_CYAN}━━━ ${C_MAG}MAC ADDRESS SETTINGS${C_CYAN} ━━━${C_RST}"
        echo ""
        echo -e "  ${C_CYAN}1${C_RST}) Interfaces: ${C_WHITE}${MAC_INTERFACES:-auto}${C_RST}"
        echo -e "  ${C_CYAN}2${C_RST}) Vendor Spoof OUI: ${C_WHITE}${MAC_VENDOR_SPOOF:-random}${C_RST}"
        echo -e "  ${C_RED}0${C_RST}) ${C_DIM}Back${C_RST}"
        echo ""
        echo -ne "${C_BLUE}▸ ${C_RST}"
        local choice
        read -r choice

        case "$choice" in
            1) local val; val=$(ansi_input "Interfaces (auto or comma-separated, e.g. eth0,wlan0)" "${MAC_INTERFACES:-auto}")
               opsec_set_value MAC_INTERFACES "$val" ;;
            2) local val; val=$(ansi_input "Vendor OUI prefix (e.g. 00:1A:2B) or empty for random" "${MAC_VENDOR_SPOOF:-}")
               opsec_set_value MAC_VENDOR_SPOOF "$val" ;;
            0|"") return ;;
        esac
    done
}

menu_hostname() {
    while true; do
        opsec_load_config 2>/dev/null || true
        clear
        echo -e "${C_CYAN}━━━ ${C_MAG}HOSTNAME SETTINGS${C_CYAN} ━━━${C_RST}"
        echo ""
        echo -e "  ${C_CYAN}1${C_RST}) Pattern: ${C_WHITE}${HOSTNAME_PATTERN:-desktop}${C_RST}"
        echo -e "     ${C_DIM}desktop = desktop-XXXX | random = XXXXXXXX | custom = PREFIX-XXXX${C_RST}"
        echo -e "  ${C_CYAN}2${C_RST}) Custom Prefix: ${C_WHITE}${HOSTNAME_CUSTOM_PREFIX:-}${C_RST}"
        echo -e "  ${C_RED}0${C_RST}) ${C_DIM}Back${C_RST}"
        echo ""
        echo -ne "${C_BLUE}▸ ${C_RST}"
        local choice
        read -r choice

        case "$choice" in
            1) local val; val=$(ansi_input "Pattern (desktop/random/custom)" "${HOSTNAME_PATTERN:-desktop}")
               opsec_set_value HOSTNAME_PATTERN "$val" ;;
            2) local val; val=$(ansi_input "Custom prefix" "${HOSTNAME_CUSTOM_PREFIX:-}")
               opsec_set_value HOSTNAME_CUSTOM_PREFIX "$val" ;;
            0|"") return ;;
        esac
    done
}

menu_hardening() {
    while true; do
        opsec_load_config 2>/dev/null || true
        clear
        echo -e "${C_CYAN}━━━ ${C_MAG}SYSTEM HARDENING${C_CYAN} ━━━${C_RST}"
        echo ""
        ansi_toggle "1) Disable IPv6" "${HARDEN_IPV6:-1}"
        ansi_toggle "2) Disable Swap" "${HARDEN_SWAP:-1}"
        ansi_toggle "3) Disable Core Dumps" "${HARDEN_CORE_DUMPS:-1}"
        ansi_toggle "4) Clipboard Auto-Clear" "${HARDEN_CLIPBOARD_CLEAR:-0}"
        ansi_toggle "5) Screen Lock" "${HARDEN_SCREEN_LOCK:-1}"
        echo -e "  ${C_CYAN}6${C_RST}) Screen Lock Timeout: ${C_WHITE}${HARDEN_SCREEN_LOCK_TIMEOUT:-300}s${C_RST}"
        ansi_toggle "7) Timezone Spoof" "${HARDEN_TIMEZONE_SPOOF:-0}"
        echo -e "  ${C_CYAN}8${C_RST}) Timezone Value: ${C_WHITE}${HARDEN_TIMEZONE_VALUE:-UTC}${C_RST}"
        ansi_toggle "9) Locale Spoof" "${HARDEN_LOCALE_SPOOF:-0}"
        echo -e "  ${C_RED}0${C_RST}) ${C_DIM}Back${C_RST}"
        echo ""
        echo -ne "${C_BLUE}▸ ${C_RST}"
        local choice
        read -r choice

        case "$choice" in
            1) wt_toggle HARDEN_IPV6 "IPv6 Disable" ;;
            2) wt_toggle HARDEN_SWAP "Swap Disable" ;;
            3) wt_toggle HARDEN_CORE_DUMPS "Core Dumps Disable" ;;
            4) wt_toggle HARDEN_CLIPBOARD_CLEAR "Clipboard Auto-Clear" ;;
            5) wt_toggle HARDEN_SCREEN_LOCK "Screen Lock" ;;
            6) local val; val=$(ansi_input "Lock timeout (seconds)" "${HARDEN_SCREEN_LOCK_TIMEOUT:-300}")
               opsec_set_value HARDEN_SCREEN_LOCK_TIMEOUT "$val" ;;
            7) wt_toggle HARDEN_TIMEZONE_SPOOF "Timezone Spoof" ;;
            8) local val; val=$(ansi_input "Timezone (e.g. UTC, Europe/London)" "${HARDEN_TIMEZONE_VALUE:-UTC}")
               opsec_set_value HARDEN_TIMEZONE_VALUE "$val" ;;
            9) wt_toggle HARDEN_LOCALE_SPOOF "Locale Spoof" ;;
            0|"") return ;;
        esac
    done
}

menu_leak_prevention() {
    while true; do
        opsec_load_config 2>/dev/null || true
        clear
        echo -e "${C_CYAN}━━━ ${C_MAG}LEAK PREVENTION${C_CYAN} ━━━${C_RST}"
        echo ""
        ansi_toggle "1) WebRTC Blocking" "${LEAK_WEBRTC_BLOCK:-1}"
        ansi_toggle "2) USB Device Blocking" "${LEAK_USB_BLOCK:-0}"
        echo -e "  ${C_RED}0${C_RST}) ${C_DIM}Back${C_RST}"
        echo ""
        echo -ne "${C_BLUE}▸ ${C_RST}"
        local choice
        read -r choice

        case "$choice" in
            1) wt_toggle LEAK_WEBRTC_BLOCK "WebRTC Block" ;;
            2) wt_toggle LEAK_USB_BLOCK "USB Block" ;;
            0|"") return ;;
        esac
    done
}

menu_monitoring() {
    while true; do
        opsec_load_config 2>/dev/null || true
        clear
        echo -e "${C_CYAN}━━━ ${C_MAG}NETWORK MONITORING${C_CYAN} ━━━${C_RST}"
        echo ""
        ansi_toggle "1) Process Monitor" "${MONITOR_PROCESSES:-0}"
        ansi_toggle "2) Traffic Jitter" "${TRAFFIC_JITTER_ENABLED:-0}"
        echo -e "  ${C_CYAN}3${C_RST}) Jitter Delay: ${C_WHITE}${TRAFFIC_JITTER_MS:-50}ms${C_RST}"
        ansi_toggle "4) Log Rotation" "${MONITOR_LOG_ROTATION:-1}"
        echo -e "  ${C_CYAN}5${C_RST}) Log Rotation Interval: ${C_WHITE}${LOG_ROTATION_HOURS:-4}h${C_RST}"
        echo -e "  ${C_RED}0${C_RST}) ${C_DIM}Back${C_RST}"
        echo ""
        echo -ne "${C_BLUE}▸ ${C_RST}"
        local choice
        read -r choice

        case "$choice" in
            1) wt_toggle MONITOR_PROCESSES "Process Monitor" ;;
            2) wt_toggle TRAFFIC_JITTER_ENABLED "Traffic Jitter" ;;
            3) local val; val=$(ansi_input "Jitter delay (ms)" "${TRAFFIC_JITTER_MS:-50}")
               opsec_set_value TRAFFIC_JITTER_MS "$val" ;;
            4) wt_toggle MONITOR_LOG_ROTATION "Log Rotation" ;;
            5) local val; val=$(ansi_input "Rotation interval (hours)" "${LOG_ROTATION_HOURS:-4}")
               opsec_set_value LOG_ROTATION_HOURS "$val" ;;
            0|"") return ;;
        esac
    done
}

menu_boot_mode() {
    clear
    echo -e "${C_CYAN}━━━ ${C_MAG}BOOT MODE${C_CYAN} ━━━${C_RST}"
    echo ""
    if [ -f "$BOOT_MARKER" ]; then
        echo -e "${C_GREEN}Boot-into-advanced is: ENABLED${C_RST}"
        echo -e "${C_DIM}System will boot into advanced OPSEC mode automatically${C_RST}"
        echo ""
        if ansi_confirm "Disable boot-into-advanced?"; then
            rm -f "$BOOT_MARKER"
            systemctl disable opsec-boot-advanced.service 2>/dev/null || true
            opsec_green "Boot-into-advanced disabled"
        fi
    else
        echo -e "${C_AMBER}Boot-into-advanced is: DISABLED${C_RST}"
        echo -e "${C_DIM}System boots in standard mode (manual activation)${C_RST}"
        echo ""
        if ansi_confirm "Enable boot-into-advanced?"; then
            mkdir -p /etc/opsec
            touch "$BOOT_MARKER"
            systemctl enable opsec-boot-advanced.service 2>/dev/null || true
            opsec_green "Boot-into-advanced enabled"
        fi
    fi
    sleep 1
}

menu_profiles() {
    while true; do
        clear
        echo -e "${C_CYAN}━━━ ${C_MAG}PROFILE MANAGEMENT${C_CYAN} ━━━${C_RST}"
        echo ""
        echo -e "${C_DIM}Active profile:${C_RST} ${C_WHITE}${PROFILE_NAME:-default}${C_RST}"
        echo ""

        # List existing profiles
        local profiles
        profiles=$(opsec_profile_list 2>/dev/null)
        if [ -n "$profiles" ]; then
            echo -e "${C_DIM}Saved profiles:${C_RST}"
            echo "$profiles" | while read -r p; do
                if [ "$p" = "${PROFILE_NAME:-default}" ]; then
                    echo -e "  ${C_GREEN}▸ ${p} (active)${C_RST}"
                else
                    echo -e "  ${C_DIM}  ${p}${C_RST}"
                fi
            done
            echo ""
        fi

        echo -e "  ${C_CYAN}1${C_RST}) Save current config as profile"
        echo -e "  ${C_CYAN}2${C_RST}) Load profile"
        echo -e "  ${C_CYAN}3${C_RST}) Delete profile"
        echo -e "  ${C_CYAN}4${C_RST}) Export profile to file"
        echo -e "  ${C_CYAN}5${C_RST}) Import profile from file"
        echo -e "  ${C_RED}0${C_RST}) ${C_DIM}Back${C_RST}"
        echo ""
        echo -ne "${C_BLUE}▸ ${C_RST}"
        local choice
        read -r choice

        case "$choice" in
            1)
                local name
                name=$(ansi_input "Profile name" "")
                if [ -n "$name" ]; then
                    opsec_profile_save "$name"
                    opsec_set_value PROFILE_NAME "$name"
                    opsec_green "Profile '${name}' saved"
                    sleep 1
                fi
                ;;
            2)
                local name
                name=$(ansi_input "Profile name to load" "")
                if [ -n "$name" ]; then
                    if opsec_profile_load "$name"; then
                        opsec_load_config
                        opsec_green "Profile '${name}' loaded"
                    else
                        opsec_red "Profile '${name}' not found"
                    fi
                    sleep 1
                fi
                ;;
            3)
                local name
                name=$(ansi_input "Profile name to delete" "")
                if [ -n "$name" ] && ansi_confirm "Delete profile '${name}'?"; then
                    opsec_profile_delete "$name"
                    opsec_green "Profile '${name}' deleted"
                    sleep 1
                fi
                ;;
            4)
                local name dest
                name=$(ansi_input "Profile name to export" "${PROFILE_NAME:-default}")
                dest=$(ansi_input "Export path" "/tmp/${name}.conf")
                if opsec_profile_export "$name" "$dest" 2>/dev/null || cp "$OPSEC_CONF" "$dest"; then
                    opsec_green "Exported to ${dest}"
                else
                    opsec_red "Export failed"
                fi
                sleep 1
                ;;
            5)
                local src name
                src=$(ansi_input "Import file path" "")
                name=$(ansi_input "Profile name" "")
                if [ -n "$src" ] && [ -n "$name" ]; then
                    if opsec_profile_import "$src" "$name"; then
                        opsec_green "Profile '${name}' imported"
                    else
                        opsec_red "Import failed (file not found?)"
                    fi
                    sleep 1
                fi
                ;;
            0|"") return ;;
        esac
    done
}

menu_tor_bridges() {
    while true; do
        opsec_load_config 2>/dev/null || true
        clear
        echo -e "${C_CYAN}━━━ ${C_MAG}TOR BRIDGES (PLUGGABLE TRANSPORTS)${C_CYAN} ━━━${C_RST}"
        echo ""
        echo -e "${C_DIM}Current mode:${C_RST} ${C_WHITE}${TOR_BRIDGE_MODE:-off}${C_RST}"
        [ -n "${TOR_BRIDGE_RELAY:-}" ] && echo -e "${C_DIM}Custom relay:${C_RST} ${C_WHITE}${TOR_BRIDGE_RELAY}${C_RST}"
        echo ""
        echo -e "  ${C_CYAN}1${C_RST}) ${C_GREEN}off${C_RST}        — Direct Tor connection (no bridge)"
        echo -e "  ${C_CYAN}2${C_RST}) ${C_AMBER}obfs4${C_RST}      — obfs4 obfuscated bridge (recommended)"
        echo -e "  ${C_CYAN}3${C_RST}) ${C_AMBER}meek-azure${C_RST} — Domain-fronted via Azure CDN"
        echo -e "  ${C_CYAN}4${C_RST}) ${C_AMBER}snowflake${C_RST}  — WebRTC-based (resembles video call)"
        echo -e "  ${C_CYAN}5${C_RST}) ${C_WHITE}Custom relay${C_RST} — Set bridge relay line manually"
        echo -e "  ${C_RED}0${C_RST}) ${C_DIM}Back${C_RST}"
        echo ""
        echo -ne "${C_BLUE}▸ ${C_RST}"
        local choice
        read -r choice

        case "$choice" in
            1) opsec_set_value TOR_BRIDGE_MODE "off"; opsec_green "Bridges disabled" ; sleep 1 ;;
            2) opsec_set_value TOR_BRIDGE_MODE "obfs4"; opsec_green "Bridge mode: obfs4" ; sleep 1 ;;
            3) opsec_set_value TOR_BRIDGE_MODE "meek-azure"; opsec_green "Bridge mode: meek-azure" ; sleep 1 ;;
            4) opsec_set_value TOR_BRIDGE_MODE "snowflake"; opsec_green "Bridge mode: snowflake" ; sleep 1 ;;
            5)
                local relay
                relay=$(ansi_input "Bridge relay line (e.g. obfs4 IP:PORT FINGERPRINT ...)" "${TOR_BRIDGE_RELAY:-}")
                opsec_set_value TOR_BRIDGE_RELAY "$relay"
                ;;
            0|"") return ;;
        esac
    done
}

menu_widget_theme() {
    while true; do
        opsec_load_config 2>/dev/null || true
        clear
        echo -e "${C_CYAN}━━━ ${C_MAG}WIDGET THEME${C_CYAN} ━━━${C_RST}"
        echo ""
        echo -e "${C_DIM}Current theme:${C_RST} ${C_WHITE}${WIDGET_THEME:-default}${C_RST}"
        echo ""

        # List available themes with numbers
        local themes=()
        local i=1
        if [ -d /etc/opsec/themes ]; then
            while IFS= read -r t; do
                [ -z "$t" ] && continue
                # Source theme to get label
                local label="$t"
                if [ -f "/etc/opsec/themes/${t}.theme" ]; then
                    label=$(grep '^THEME_LABEL=' "/etc/opsec/themes/${t}.theme" 2>/dev/null | cut -d'"' -f2)
                    [ -z "$label" ] && label="$t"
                fi
                themes+=("$t")
                local marker=""
                if [ "$t" = "${WIDGET_THEME:-default}" ]; then
                    marker=" ${C_GREEN}◀ active${C_RST}"
                fi
                echo -e "  ${C_CYAN}${i}${C_RST}) ${C_WHITE}${label}${C_RST} ${C_DIM}(${t})${C_RST}${marker}"
                i=$((i + 1))
            done < <(opsec_theme_list 2>/dev/null)
        fi

        if [ ${#themes[@]} -eq 0 ]; then
            echo -e "${C_RED}No themes found in /etc/opsec/themes/${C_RST}"
            echo -e "${C_DIM}Deploy with playbook first.${C_RST}"
            echo ""
            echo -e "${C_DIM}Press Enter to go back...${C_RST}"
            read -r
            return
        fi

        echo -e "  ${C_RED}0${C_RST}) ${C_DIM}Back${C_RST}"
        echo ""
        echo -ne "${C_BLUE}▸ ${C_RST}"
        local choice
        read -r choice

        if [ "$choice" = "0" ] || [ -z "$choice" ]; then
            return
        fi

        # Validate numeric choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#themes[@]} ]; then
            local selected="${themes[$((choice - 1))]}"
            opsec_set_value WIDGET_THEME "$selected"
            opsec_load_config
            opsec_info "Applying theme '${selected}'..."
            opsec_generate_conky
            opsec_green "Theme '${selected}' applied"
            sleep 1
        fi
    done
}

do_apply() {
    echo ""
    opsec_hdr "APPLYING CONFIGURATION"
    echo ""

    opsec_load_config

    # Regenerate torrc
    opsec_info "Regenerating torrc..."
    opsec_generate_torrc
    opsec_green "Torrc regenerated"

    # Regenerate resolv.conf if in advanced mode
    if opsec_is_advanced; then
        opsec_info "Regenerating resolv.conf..."
        opsec_generate_resolv
        opsec_green "DNS config regenerated"

        # Restart Tor
        opsec_info "Restarting Tor..."
        systemctl restart tor 2>/dev/null || true

        # Reapply hardening
        if [ -x /usr/local/bin/opsec-harden.sh ]; then
            opsec_info "Reapplying hardening..."
            /usr/local/bin/opsec-harden.sh apply
        fi

        # Reapply kill switch
        opsec_info "Reapplying kill switch..."
        /usr/local/bin/opsec-killswitch.sh on 2>/dev/null || true
    fi

    # Regenerate conky widget with current theme
    opsec_info "Regenerating conky widget..."
    opsec_generate_conky 2>/dev/null && opsec_green "Widget theme applied" || true

    opsec_green "Configuration applied"
    echo ""
}

menu_deployment_level() {
    while true; do
        opsec_load_config 2>/dev/null || true
        clear
        echo -e "${C_CYAN}━━━ ${C_MAG}DEPLOYMENT LEVEL${C_CYAN} ━━━${C_RST}"
        echo ""
        echo -e "${C_DIM}Current level:${C_RST} ${C_WHITE}${DEPLOYMENT_LEVEL:-bare-metal}${C_RST}"
        echo ""

        # List available levels
        local levels
        levels=$(opsec_level_list 2>/dev/null)
        if [ -z "$levels" ]; then
            echo -e "${C_RED}No levels found in /etc/opsec/levels/${C_RST}"
            echo -e "${C_DIM}Deploy with playbook first.${C_RST}"
            echo ""
            echo -e "${C_DIM}Press Enter to go back...${C_RST}"
            read -r
            return
        fi

        echo -e "  ${C_CYAN}1${C_RST}) ${C_WHITE}bare-metal-standard${C_RST}  ${C_DIM}— Physical box, privacy base + ghost toggle${C_RST}"
        echo -e "  ${C_CYAN}2${C_RST}) ${C_RED}bare-metal-paranoid${C_RST}  ${C_DIM}— Physical box, ghost mode always on${C_RST}"
        echo -e "  ${C_CYAN}3${C_RST}) ${C_AMBER}cloud-normal${C_RST}         ${C_DIM}— Cloud VPS, privacy base + ghost toggle${C_RST}"
        echo -e "  ${C_CYAN}4${C_RST}) ${C_RED}cloud-paranoid${C_RST}       ${C_DIM}— Cloud VPS, ghost mode always on${C_RST}"
        echo ""
        echo -e "  ${C_CYAN}5${C_RST}) ${C_BLUE}Banner Mode${C_RST}     ${C_DIM}— Terminal banner: ${OPSEC_BANNER:-compact}${C_RST}"
        echo -e "  ${C_RED}0${C_RST}) ${C_DIM}Back${C_RST}"
        echo ""
        echo -ne "${C_BLUE}▸ ${C_RST}"
        local choice
        read -r choice

        case "$choice" in
            1) if ansi_confirm "Apply 'bare-metal-standard'? (privacy base + ghost toggle)"; then
                   opsec_level_apply "bare-metal-standard" && opsec_green "Level 'bare-metal-standard' applied" || opsec_red "Failed to apply level"
                   sleep 1
               fi ;;
            2) if ansi_confirm "Apply 'bare-metal-paranoid'? (ghost mode always on)"; then
                   opsec_level_apply "bare-metal-paranoid" && opsec_green "Level 'bare-metal-paranoid' applied" || opsec_red "Failed to apply level"
                   sleep 1
               fi ;;
            3) if ansi_confirm "Apply 'cloud-normal'? (cloud privacy base + ghost toggle)"; then
                   opsec_level_apply "cloud-normal" && opsec_green "Level 'cloud-normal' applied" || opsec_red "Failed to apply level"
                   sleep 1
               fi ;;
            4) if ansi_confirm "Apply 'cloud-paranoid'? (cloud ghost mode always on)"; then
                   opsec_level_apply "cloud-paranoid" && opsec_green "Level 'cloud-paranoid' applied" || opsec_red "Failed to apply level"
                   sleep 1
               fi ;;
            5)
                echo ""
                echo -e "  ${C_CYAN}a${C_RST}) compact"
                echo -e "  ${C_CYAN}b${C_RST}) full"
                echo -e "  ${C_CYAN}c${C_RST}) off"
                echo -ne "${C_BLUE}▸ ${C_RST}"
                local bchoice
                read -r bchoice
                case "$bchoice" in
                    a) opsec_set_value OPSEC_BANNER "compact"; opsec_green "Banner: compact" ;;
                    b) opsec_set_value OPSEC_BANNER "full"; opsec_green "Banner: full" ;;
                    c) opsec_set_value OPSEC_BANNER "off"; opsec_green "Banner: off" ;;
                esac
                sleep 1
                ;;
            0|"") return ;;
        esac
    done
}

menu_apply() {
    if ansi_confirm "Regenerate configs and restart affected services?"; then
        do_apply
        echo ""
        echo -e "${C_DIM}Press Enter to continue...${C_RST}"
        read -r
    fi
}

# ─── MAIN MENU ─────────────────────────────────────────────────────────────────

main_menu() {
    while true; do
        opsec_load_config 2>/dev/null || true
        clear
        ansi_banner

        local mode_str
        if [ -f /var/run/opsec-advanced.enabled ]; then
            mode_str="${C_GREEN}ADVANCED${C_RST}"
        else
            mode_str="${C_AMBER}STANDARD${C_RST}"
        fi

        echo -e "  ${C_DIM}Mode: ${mode_str}    ${C_DIM}Boot: $([ -f "$BOOT_MARKER" ] && echo -e "${C_GREEN}PERSIST" || echo -e "${C_AMBER}MANUAL")${C_RST}"
        echo ""
        echo -e "  ${C_CYAN} 1${C_RST}) ${C_WHITE}Tor Settings${C_RST}          ${C_DIM}— circuits, blacklist, isolation, padding${C_RST}"
        echo -e "  ${C_CYAN} 2${C_RST}) ${C_WHITE}DNS Settings${C_RST}          ${C_DIM}— tor/quad9/cloudflare/doh/dot/custom${C_RST}"
        echo -e "  ${C_CYAN} 3${C_RST}) ${C_WHITE}Kill Switch${C_RST}           ${C_DIM}— DHCP/VPN toggles, extra ports${C_RST}"
        echo -e "  ${C_CYAN} 4${C_RST}) ${C_WHITE}MAC Address${C_RST}           ${C_DIM}— interfaces, vendor spoof${C_RST}"
        echo -e "  ${C_CYAN} 5${C_RST}) ${C_WHITE}Hostname${C_RST}              ${C_DIM}— pattern, custom prefix${C_RST}"
        echo -e "  ${C_CYAN} 6${C_RST}) ${C_WHITE}System Hardening${C_RST}      ${C_DIM}— IPv6, swap, core dumps, clipboard, etc.${C_RST}"
        echo -e "  ${C_CYAN} 7${C_RST}) ${C_WHITE}Leak Prevention${C_RST}       ${C_DIM}— WebRTC, USB blocking${C_RST}"
        echo -e "  ${C_CYAN} 8${C_RST}) ${C_WHITE}Network Monitoring${C_RST}    ${C_DIM}— process monitor, traffic jitter${C_RST}"
        echo -e "  ${C_CYAN} 9${C_RST}) ${C_WHITE}Boot Mode${C_RST}             ${C_DIM}— toggle boot-into-advanced${C_RST}"
        echo -e "  ${C_CYAN}10${C_RST}) ${C_WHITE}Profiles${C_RST}              ${C_DIM}— save/load/list/delete/export/import${C_RST}"
        echo -e "  ${C_CYAN}11${C_RST}) ${C_WHITE}Deployment Level${C_RST}      ${C_DIM}— ${DEPLOYMENT_LEVEL:-bare-metal} | banner: ${OPSEC_BANNER:-compact}${C_RST}"
        echo -e "  ${C_CYAN}12${C_RST}) ${C_WHITE}Tor Bridges${C_RST}           ${C_DIM}— pluggable transports: ${TOR_BRIDGE_MODE:-off}${C_RST}"
        echo -e "  ${C_CYAN}13${C_RST}) ${C_WHITE}Widget Theme${C_RST}          ${C_DIM}— conky color theme: ${WIDGET_THEME:-default}${C_RST}"
        echo -e "  ${C_MAG}14${C_RST}) ${C_MAG}Apply & Restart${C_RST}       ${C_DIM}— regenerate configs, restart services${C_RST}"
        echo -e "  ${C_RED} 0${C_RST}) ${C_DIM}Exit${C_RST}"
        echo ""
        echo -ne "${C_BLUE}▸ ${C_RST}"
        local choice
        read -r choice

        case "$choice" in
            1)  menu_tor ;;
            2)  menu_dns ;;
            3)  menu_killswitch ;;
            4)  menu_mac ;;
            5)  menu_hostname ;;
            6)  menu_hardening ;;
            7)  menu_leak_prevention ;;
            8)  menu_monitoring ;;
            9)  menu_boot_mode ;;
            10) menu_profiles ;;
            11) menu_deployment_level ;;
            12) menu_tor_bridges ;;
            13) menu_widget_theme ;;
            14) menu_apply ;;
            0|"")
                clear
                exit 0
                ;;
        esac
    done
}

# ─── CLI MODE ──────────────────────────────────────────────────────────────────

cli_boot() {
    case "${1:-}" in
        on)
            mkdir -p /etc/opsec
            touch "$BOOT_MARKER"
            systemctl enable opsec-boot-advanced.service 2>/dev/null || true
            opsec_green "Boot-into-advanced: ENABLED"
            ;;
        off)
            rm -f "$BOOT_MARKER"
            systemctl disable opsec-boot-advanced.service 2>/dev/null || true
            opsec_green "Boot-into-advanced: DISABLED"
            ;;
        *)
            if [ -f "$BOOT_MARKER" ]; then
                echo "enabled"
            else
                echo "disabled"
            fi
            ;;
    esac
}

cli_profile() {
    local action="${1:-}" name="${2:-}"
    case "$action" in
        save)
            [ -z "$name" ] && { echo "Usage: --profile save NAME"; exit 1; }
            opsec_profile_save "$name"
            opsec_set_value PROFILE_NAME "$name"
            opsec_green "Profile '${name}' saved"
            ;;
        load)
            [ -z "$name" ] && { echo "Usage: --profile load NAME"; exit 1; }
            if opsec_profile_load "$name"; then
                opsec_green "Profile '${name}' loaded"
            else
                opsec_red "Profile '${name}' not found"
                exit 1
            fi
            ;;
        list)
            opsec_profile_list
            ;;
        delete)
            [ -z "$name" ] && { echo "Usage: --profile delete NAME"; exit 1; }
            opsec_profile_delete "$name"
            opsec_green "Profile '${name}' deleted"
            ;;
        *)
            echo "Usage: --profile save|load|list|delete [NAME]"
            exit 1
            ;;
    esac
}

# ─── ARGUMENT PARSING ─────────────────────────────────────────────────────────

case "${1:-}" in
    --boot)
        cli_boot "${2:-}"
        ;;
    --profile)
        cli_profile "${2:-}" "${3:-}"
        ;;
    --level)
        case "${2:-}" in
            apply)
                [ -z "${3:-}" ] && { echo "Usage: --level apply NAME"; echo "Available: $(opsec_level_list 2>/dev/null | tr '\n' ' ')"; exit 1; }
                opsec_level_apply "$3" && opsec_green "Level '${3}' applied"
                ;;
            list)
                opsec_level_list
                ;;
            *)
                echo "Usage: --level apply|list [NAME]"
                echo "Available levels: $(opsec_level_list 2>/dev/null | tr '\n' ' ')"
                exit 1
                ;;
        esac
        ;;
    --banner)
        case "${2:-}" in
            compact|full|off)
                opsec_set_value OPSEC_BANNER "$2"
                opsec_green "Banner mode: ${2}"
                ;;
            *)
                echo "Usage: --banner compact|full|off"
                echo "Current: $(opsec_get_value OPSEC_BANNER)"
                exit 1
                ;;
        esac
        ;;
    --theme)
        case "${2:-}" in
            list)
                _themes=$(opsec_theme_list 2>/dev/null)
                if [ -z "$_themes" ]; then
                    echo "No themes found in /etc/opsec/themes/"
                    exit 1
                fi
                _current=$(opsec_get_value WIDGET_THEME)
                echo "$_themes" | while IFS= read -r t; do
                    if [ "$t" = "$_current" ]; then
                        echo "* ${t} (active)"
                    else
                        echo "  ${t}"
                    fi
                done
                ;;
            apply)
                [ -z "${3:-}" ] && { echo "Usage: --theme apply NAME"; echo "Available: $(opsec_theme_list 2>/dev/null | tr '\n' ' ')"; exit 1; }
                if [ ! -f "/etc/opsec/themes/${3}.theme" ]; then
                    opsec_red "Theme '${3}' not found"
                    echo "Available: $(opsec_theme_list 2>/dev/null | tr '\n' ' ')"
                    exit 1
                fi
                opsec_set_value WIDGET_THEME "$3"
                opsec_load_config
                opsec_generate_conky && opsec_green "Theme '${3}' applied"
                ;;
            *)
                echo "Usage: --theme list|apply NAME"
                echo "Current: $(opsec_get_value WIDGET_THEME)"
                exit 1
                ;;
        esac
        ;;
    --set)
        [ -z "${2:-}" ] && { echo "Usage: --set KEY VALUE"; exit 1; }
        opsec_set_value "$2" "${3:-}"
        opsec_green "${2}=${3:-}"
        ;;
    --get)
        [ -z "${2:-}" ] && { echo "Usage: --get KEY"; exit 1; }
        opsec_get_value "$2"
        ;;
    --apply)
        do_apply
        ;;
    --help|-h)
        echo "OPSEC Configuration Manager"
        echo ""
        echo "Usage:"
        echo "  sudo opsec-config.sh                       Interactive TUI"
        echo "  sudo opsec-config.sh --boot on|off         Toggle boot-into-advanced"
        echo "  sudo opsec-config.sh --profile CMD NAME    Profile management"
        echo "  sudo opsec-config.sh --level apply NAME    Apply deployment level"
        echo "  sudo opsec-config.sh --level list          List available levels"
        echo "  sudo opsec-config.sh --banner compact|full|off  Set terminal banner mode"
        echo "  sudo opsec-config.sh --theme list           List widget themes"
        echo "  sudo opsec-config.sh --theme apply NAME     Apply widget theme"
        echo "  sudo opsec-config.sh --set KEY VALUE       Set config value"
        echo "  sudo opsec-config.sh --get KEY             Get config value"
        echo "  sudo opsec-config.sh --apply               Apply config changes"
        ;;
    "")
        main_menu
        ;;
    *)
        echo "Unknown option: $1"
        echo "Try: sudo opsec-config.sh --help"
        exit 1
        ;;
esac
