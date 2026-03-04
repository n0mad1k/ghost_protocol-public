#!/bin/bash
# /usr/local/bin/opsec-harden.sh — System hardening apply/revert
# Usage: sudo opsec-harden.sh apply|revert
#
# Reads settings from /etc/opsec/opsec.conf
# Handles: core dumps, swap, timezone, locale, screen lock, WebRTC,
#          USB blocking, clipboard auto-clear, traffic jitter

## NOTE: Do NOT use "set -euo pipefail" — it causes silent crashes
## when commands like sysctl, dconf, tc, etc. return non-zero.
## Use explicit error handling instead (|| true).

if [ "$EUID" -ne 0 ]; then
    echo "[-] Please run as root"
    exit 1
fi

OPSEC_LIB="/usr/local/lib/opsec/opsec-lib.sh"
BACKUP_DIR="/etc/opsec/.harden-backup"

# Source shared library
if [ -f "$OPSEC_LIB" ]; then
    . "$OPSEC_LIB"
else
    # Minimal fallback
    opsec_green()  { echo -e "\033[38;5;49m[+] $*\033[0m"; }
    opsec_red()    { echo -e "\033[38;5;196m[-] $*\033[0m"; }
    opsec_yellow() { echo -e "\033[38;5;214m[*] $*\033[0m"; }
    opsec_info()   { echo -e "\033[38;5;39m[~] $*\033[0m"; }
    opsec_load_config() {
        [ -f /etc/opsec/opsec.conf ] && . /etc/opsec/opsec.conf
    }
fi

mkdir -p "$BACKUP_DIR"
opsec_load_config 2>/dev/null || true

# ─── CORE DUMPS ────────────────────────────────────────────────────────────────

apply_core_dumps() {
    if [ "${HARDEN_CORE_DUMPS:-1}" = "1" ]; then
        opsec_info "Disabling core dumps..."

        # sysctl
        sysctl -w kernel.core_pattern='|/bin/false' >/dev/null 2>&1
        sysctl -w fs.suid_dumpable=0 >/dev/null 2>&1

        # limits.d
        cat > /etc/security/limits.d/opsec-coredump.conf << 'EOF'
# OPSEC: Disable core dumps
* hard core 0
* soft core 0
EOF
        # systemd coredump
        mkdir -p /etc/systemd/coredump.conf.d
        cat > /etc/systemd/coredump.conf.d/opsec.conf << 'EOF'
[Coredump]
Storage=none
ProcessSizeMax=0
EOF
        opsec_green "Core dumps disabled"
    fi
}

revert_core_dumps() {
    sysctl -w kernel.core_pattern='core' >/dev/null 2>&1
    sysctl -w fs.suid_dumpable=1 >/dev/null 2>&1
    rm -f /etc/security/limits.d/opsec-coredump.conf
    rm -f /etc/systemd/coredump.conf.d/opsec.conf
    opsec_green "Core dumps restored"
}

# ─── SWAP ──────────────────────────────────────────────────────────────────────

apply_swap() {
    if [ "${HARDEN_SWAP:-1}" = "1" ]; then
        opsec_info "Disabling swap..."
        swapoff -a 2>/dev/null || true

        # Comment out swap entries in fstab (backup first)
        if [ ! -f "$BACKUP_DIR/fstab.swap" ]; then
            grep -E '^\s*[^#].*\sswap\s' /etc/fstab > "$BACKUP_DIR/fstab.swap" 2>/dev/null || true
        fi
        sed -i '/\sswap\s/s/^/#OPSEC# /' /etc/fstab 2>/dev/null || true
        opsec_green "Swap disabled"
    fi
}

revert_swap() {
    sed -i 's/^#OPSEC# //' /etc/fstab 2>/dev/null || true
    swapon -a 2>/dev/null || true
    opsec_green "Swap restored"
}

# ─── IPv6 ──────────────────────────────────────────────────────────────────────

apply_ipv6() {
    if [ "${HARDEN_IPV6:-1}" = "1" ]; then
        opsec_info "Disabling IPv6..."
        sysctl -w net.ipv6.conf.all.disable_ipv6=1 >/dev/null
        sysctl -w net.ipv6.conf.default.disable_ipv6=1 >/dev/null
        opsec_green "IPv6 disabled"
    fi
}

revert_ipv6() {
    sysctl -w net.ipv6.conf.all.disable_ipv6=0 >/dev/null
    sysctl -w net.ipv6.conf.default.disable_ipv6=0 >/dev/null
    opsec_green "IPv6 restored"
}

# ─── TIMEZONE SPOOF ────────────────────────────────────────────────────────────

apply_timezone() {
    if [ "${HARDEN_TIMEZONE_SPOOF:-0}" = "1" ]; then
        local tz="${HARDEN_TIMEZONE_VALUE:-UTC}"
        opsec_info "Spoofing timezone to ${tz}..."

        # Backup current timezone
        timedatectl show -p Timezone --value > "$BACKUP_DIR/timezone.orig" 2>/dev/null || true
        timedatectl set-timezone "$tz" 2>/dev/null || {
            ln -sf "/usr/share/zoneinfo/${tz}" /etc/localtime
        }
        opsec_green "Timezone set to ${tz}"
    fi
}

revert_timezone() {
    if [ -f "$BACKUP_DIR/timezone.orig" ]; then
        local orig_tz
        orig_tz=$(cat "$BACKUP_DIR/timezone.orig")
        timedatectl set-timezone "$orig_tz" 2>/dev/null || true
        rm -f "$BACKUP_DIR/timezone.orig"
        opsec_green "Timezone restored to ${orig_tz}"
    fi
}

# ─── LOCALE SPOOF ─────────────────────────────────────────────────────────────

apply_locale() {
    if [ "${HARDEN_LOCALE_SPOOF:-0}" = "1" ]; then
        local loc="${HARDEN_LOCALE_VALUE:-en_US.UTF-8}"
        opsec_info "Spoofing locale to ${loc}..."

        # Backup
        locale > "$BACKUP_DIR/locale.orig" 2>/dev/null || true
        export LANG="$loc"
        export LC_ALL="$loc"
        echo "LANG=${loc}" > /etc/default/locale.opsec
        opsec_green "Locale set to ${loc}"
    fi
}

revert_locale() {
    rm -f /etc/default/locale.opsec
    if [ -f "$BACKUP_DIR/locale.orig" ]; then
        rm -f "$BACKUP_DIR/locale.orig"
    fi
    opsec_green "Locale restored"
}

# ─── SCREEN LOCK ───────────────────────────────────────────────────────────────

apply_screen_lock() {
    if [ "${HARDEN_SCREEN_LOCK:-1}" = "1" ]; then
        local timeout="${HARDEN_SCREEN_LOCK_TIMEOUT:-300}"
        opsec_info "Setting screen lock timeout to ${timeout}s..."

        # Try GNOME dconf (runs as user via sudo)
        local real_user="${SUDO_USER:-$USER}"
        if command -v dconf >/dev/null 2>&1; then
            su - "$real_user" -c "
                dconf write /org/gnome/desktop/session/idle-delay 'uint32 ${timeout}' 2>/dev/null
                dconf write /org/gnome/desktop/screensaver/lock-enabled 'true' 2>/dev/null
                dconf write /org/gnome/desktop/screensaver/lock-delay 'uint32 0' 2>/dev/null
            " 2>/dev/null || true
        fi
        opsec_green "Screen lock set to ${timeout}s"
    fi
}

revert_screen_lock() {
    local real_user="${SUDO_USER:-$USER}"
    if command -v dconf >/dev/null 2>&1; then
        su - "$real_user" -c "
            dconf write /org/gnome/desktop/session/idle-delay 'uint32 900' 2>/dev/null
        " 2>/dev/null || true
    fi
    opsec_green "Screen lock restored to default"
}

# ─── WEBRTC BLOCKING ──────────────────────────────────────────────────────────

apply_webrtc() {
    if [ "${LEAK_WEBRTC_BLOCK:-1}" = "1" ]; then
        opsec_info "Blocking WebRTC..."
        local real_user="${SUDO_USER:-$USER}"
        local user_home
        user_home=$(eval echo "~${real_user}")

        # Firefox profiles
        for profile_dir in "${user_home}"/.mozilla/firefox/*.default* "${user_home}"/.mozilla/firefox/*.opsec*; do
            [ -d "$profile_dir" ] || continue
            cat >> "${profile_dir}/user.js" << 'EOF'
// OPSEC: Disable WebRTC IP leak
user_pref("media.peerconnection.enabled", false);
user_pref("media.peerconnection.turn.disable", true);
user_pref("media.peerconnection.use_document_iceservers", false);
user_pref("media.peerconnection.video.enabled", false);
user_pref("media.peerconnection.identity.timeout", 1);
EOF
        done

        # Brave/Chromium policies
        mkdir -p /etc/brave/policies/managed /etc/chromium/policies/managed
        cat > /etc/brave/policies/managed/opsec-webrtc.json << 'EOF'
{ "WebRtcIPHandling": "disable_non_proxied_udp" }
EOF
        cp /etc/brave/policies/managed/opsec-webrtc.json /etc/chromium/policies/managed/ 2>/dev/null || true
        opsec_green "WebRTC blocked (Firefox + Brave/Chromium)"
    fi
}

revert_webrtc() {
    local real_user="${SUDO_USER:-$USER}"
    local user_home
    user_home=$(eval echo "~${real_user}")

    for profile_dir in "${user_home}"/.mozilla/firefox/*.default* "${user_home}"/.mozilla/firefox/*.opsec*; do
        [ -d "$profile_dir" ] || continue
        sed -i '/OPSEC: Disable WebRTC/,/peerconnection\.identity/d' "${profile_dir}/user.js" 2>/dev/null || true
    done
    rm -f /etc/brave/policies/managed/opsec-webrtc.json
    rm -f /etc/chromium/policies/managed/opsec-webrtc.json
    opsec_green "WebRTC restrictions removed"
}

# ─── USB BLOCKING ─────────────────────────────────────────────────────────────

apply_usb_block() {
    if [ "${LEAK_USB_BLOCK:-0}" = "1" ]; then
        opsec_info "Blocking new USB devices..."
        echo 0 > /sys/bus/usb/drivers_autoprobe 2>/dev/null || true
        opsec_green "USB auto-probe disabled (new devices blocked)"
    fi
}

revert_usb_block() {
    echo 1 > /sys/bus/usb/drivers_autoprobe 2>/dev/null || true
    opsec_green "USB auto-probe restored"
}

# ─── CLIPBOARD AUTO-CLEAR ─────────────────────────────────────────────────────

apply_clipboard_clear() {
    if [ "${HARDEN_CLIPBOARD_CLEAR:-0}" = "1" ]; then
        opsec_info "Starting clipboard auto-clear..."
        # Launch background clearer (clears clipboard every 30 seconds)
        local pidfile="/var/run/opsec-clipboard.pid"
        if [ -f "$pidfile" ] && kill -0 "$(cat "$pidfile")" 2>/dev/null; then
            opsec_yellow "Clipboard cleaner already running"
            return
        fi

        (
            while true; do
                sleep 30
                # Clear X clipboard
                if command -v xclip >/dev/null 2>&1; then
                    echo -n "" | xclip -selection clipboard 2>/dev/null || true
                    echo -n "" | xclip -selection primary 2>/dev/null || true
                elif command -v xsel >/dev/null 2>&1; then
                    xsel --clipboard --clear 2>/dev/null || true
                    xsel --primary --clear 2>/dev/null || true
                fi
            done
        ) &
        echo $! > "$pidfile"
        opsec_green "Clipboard auto-clear active (every 30s)"
    fi
}

revert_clipboard_clear() {
    local pidfile="/var/run/opsec-clipboard.pid"
    if [ -f "$pidfile" ]; then
        kill "$(cat "$pidfile")" 2>/dev/null || true
        rm -f "$pidfile"
    fi
    opsec_green "Clipboard auto-clear stopped"
}

# ─── TRAFFIC JITTER ───────────────────────────────────────────────────────────

apply_traffic_jitter() {
    if [ "${TRAFFIC_JITTER_ENABLED:-0}" = "1" ]; then
        local ms="${TRAFFIC_JITTER_MS:-50}"
        opsec_info "Adding ${ms}ms traffic jitter..."

        # Find primary outbound interface
        local iface
        iface=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -1)
        if [ -n "$iface" ]; then
            # Remove existing qdisc first
            tc qdisc del dev "$iface" root 2>/dev/null || true
            tc qdisc add dev "$iface" root netem delay "${ms}ms" "${ms}ms" distribution normal 2>/dev/null || {
                opsec_yellow "tc not available — jitter skipped"
                return
            }
            echo "$iface" > "$BACKUP_DIR/jitter-iface"
            opsec_green "Traffic jitter active on ${iface} (${ms}ms)"
        else
            opsec_yellow "No outbound interface found for jitter"
        fi
    fi
}

revert_traffic_jitter() {
    if [ -f "$BACKUP_DIR/jitter-iface" ]; then
        local iface
        iface=$(cat "$BACKUP_DIR/jitter-iface")
        tc qdisc del dev "$iface" root 2>/dev/null || true
        rm -f "$BACKUP_DIR/jitter-iface"
        opsec_green "Traffic jitter removed from ${iface}"
    fi
}

# ─── MAIN ──────────────────────────────────────────────────────────────────────

do_apply() {
    echo ""
    opsec_hdr "APPLYING SYSTEM HARDENING"
    echo ""
    apply_core_dumps
    apply_swap
    apply_ipv6
    apply_timezone
    apply_locale
    apply_screen_lock
    apply_webrtc
    # Ghost-mode-only features — skip when called from mode_base (OPSEC_BASE_ONLY=1)
    if [ "${OPSEC_BASE_ONLY:-0}" != "1" ]; then
        apply_usb_block
        apply_clipboard_clear
        apply_traffic_jitter
    else
        opsec_info "Base-only mode — skipping USB block, clipboard clear, traffic jitter"
    fi
    echo ""
    opsec_green "All hardening measures applied"
}

do_revert() {
    echo ""
    opsec_hdr "REVERTING SYSTEM HARDENING"
    echo ""
    revert_core_dumps
    revert_swap
    revert_ipv6
    revert_timezone
    revert_locale
    revert_screen_lock
    revert_webrtc
    revert_usb_block
    revert_clipboard_clear
    revert_traffic_jitter
    echo ""
    opsec_green "All hardening measures reverted"
}

case "${1:-}" in
    apply)  do_apply ;;
    revert) do_revert ;;
    *)
        echo "Usage: $(basename "$0") apply|revert"
        exit 1
        ;;
esac
