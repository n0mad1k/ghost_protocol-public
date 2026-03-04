#!/bin/bash
# OPSEC Kill Switch — iptables rules to block non-Tor/VPN traffic
# Config-aware: reads KILLSWITCH_* settings from /etc/opsec/opsec.conf
# Usage: opsec-killswitch.sh on|off|status

if [ "$EUID" -ne 0 ]; then
    echo "Please run as root"
    exit 1
fi

# Source config if available
OPSEC_LIB="/usr/local/lib/opsec/opsec-lib.sh"
if [ -f "$OPSEC_LIB" ]; then
    . "$OPSEC_LIB"
    opsec_load_config 2>/dev/null || true
else
    opsec_green()  { echo -e "\033[38;5;49m[+] $*\033[0m"; }
    opsec_info()   { echo -e "\033[38;5;39m[~] $*\033[0m"; }
fi

# Config values with defaults
ALLOW_DHCP="${KILLSWITCH_ALLOW_DHCP:-1}"
ALLOW_OPENVPN="${KILLSWITCH_ALLOW_OPENVPN:-1}"
ALLOW_WIREGUARD="${KILLSWITCH_ALLOW_WIREGUARD:-1}"
EXTRA_PORTS="${KILLSWITCH_EXTRA_PORTS:-}"
TRANS_PORT="${TOR_TRANS_PORT:-9040}"
DNS_PORT="${TOR_DNS_PORT:-5353}"

CHAIN="GP_FW"
TOR_UID=$(id -u debian-tor 2>/dev/null || id -u tor 2>/dev/null || echo "")
KS_LOG="/run/opsec/debug.log"
mkdir -p /run/opsec 2>/dev/null || true
KS_ERR=$(mktemp /run/opsec/.ks-err.XXXXXX 2>/dev/null || mktemp /tmp/.ks-err.XXXXXX)
KS_FAIL=0
trap 'rm -f "$KS_ERR"' EXIT

ks_log() { echo "[$(date -Is)] [killswitch] $*" >> "$KS_LOG"; }

# Wrapper that logs failures and tracks failure count
ipt() {
    if ! iptables "$@" 2>>"$KS_ERR"; then
        ks_log "FAILED: iptables $*  — $(cat "$KS_ERR" 2>/dev/null)"
        cat "$KS_ERR" >&2 2>/dev/null
        KS_FAIL=$((KS_FAIL + 1))
        : > "$KS_ERR" 2>/dev/null
        return 1
    fi
    : > "$KS_ERR" 2>/dev/null
    return 0
}

ipt6() {
    if ! ip6tables "$@" 2>>"$KS_ERR"; then
        ks_log "FAILED: ip6tables $*  — $(cat "$KS_ERR" 2>/dev/null)"
        KS_FAIL=$((KS_FAIL + 1))
        : > "$KS_ERR" 2>/dev/null
        return 1
    fi
    : > "$KS_ERR" 2>/dev/null
    return 0
}

ks_filter_on() {
    opsec_info "Arming OPSEC kill switch (filter-only)..."
    ks_log "=== KILL SWITCH FILTER-ONLY ==="
    ks_log "TOR_UID=${TOR_UID:-NONE}"
    ks_log "ALLOW_DHCP=${ALLOW_DHCP} ALLOW_OPENVPN=${ALLOW_OPENVPN} ALLOW_WIREGUARD=${ALLOW_WIREGUARD}"
    ks_log "EXTRA_PORTS=${EXTRA_PORTS:-none}"

    iptables -N "$CHAIN" 2>/dev/null || iptables -F "$CHAIN"

    ipt -A "$CHAIN" -o lo -j ACCEPT
    ipt -A "$CHAIN" -i lo -j ACCEPT
    ipt -A "$CHAIN" -d 127.0.0.0/8 -j ACCEPT
    ipt -A "$CHAIN" -m state --state ESTABLISHED,RELATED -j ACCEPT

    if [ -n "$TOR_UID" ]; then
        ipt -A "$CHAIN" -m owner --uid-owner "$TOR_UID" -j ACCEPT
    else
        ks_log "WARNING: No TOR_UID — Tor will be blocked by filter!"
    fi

    ipt -A "$CHAIN" -o tun+ -j ACCEPT
    ipt -A "$CHAIN" -i tun+ -j ACCEPT
    ipt -A "$CHAIN" -o wg+ -j ACCEPT
    ipt -A "$CHAIN" -i wg+ -j ACCEPT

    [ "$ALLOW_DHCP" = "1" ] && ipt -A "$CHAIN" -p udp --dport 67:68 --sport 67:68 -j ACCEPT
    [ "$ALLOW_OPENVPN" = "1" ] && { ipt -A "$CHAIN" -p udp --dport 1194 -j ACCEPT; ipt -A "$CHAIN" -p tcp --dport 1194 -j ACCEPT; }
    [ "$ALLOW_WIREGUARD" = "1" ] && ipt -A "$CHAIN" -p udp --dport 51820 -j ACCEPT

    if [ -n "$EXTRA_PORTS" ]; then
        local IFS=','
        for rule in $EXTRA_PORTS; do
            local proto=$(echo "$rule" | cut -d: -f1)
            local port=$(echo "$rule" | cut -d: -f2)
            [ -n "$proto" ] && [ -n "$port" ] && ipt -A "$CHAIN" -p "$proto" --dport "$port" -j ACCEPT
        done
    fi

    ipt -A "$CHAIN" -j DROP
    iptables -D OUTPUT -j "$CHAIN" 2>/dev/null
    ipt -I OUTPUT 1 -j "$CHAIN"

    # IPv6
    ip6tables -N "$CHAIN" 2>/dev/null || ip6tables -F "$CHAIN"
    ipt6 -A "$CHAIN" -o lo -j ACCEPT
    ipt6 -A "$CHAIN" -j DROP
    ip6tables -D OUTPUT -j "$CHAIN" 2>/dev/null
    ipt6 -I OUTPUT 1 -j "$CHAIN"

    ks_log "Filter-only lockdown active (no NAT)"
    opsec_green "Kill switch filter ARMED (pre-bootstrap)"
}

ks_nat_on() {
    opsec_info "Arming NAT transparent proxy..."
    ks_log "=== NAT PROXY ON ==="

    local NAT_CHAIN="GP_NAT"

    # Remove jump before flush to prevent brief bypass window
    iptables -t nat -D OUTPUT -j "$NAT_CHAIN" 2>/dev/null
    iptables -t nat -N "$NAT_CHAIN" 2>/dev/null || iptables -t nat -F "$NAT_CHAIN"

    # Tor UID RETURN
    [ -n "$TOR_UID" ] && ipt -t nat -A "$NAT_CHAIN" -p tcp -m owner --uid-owner "$TOR_UID" -j RETURN

    # VPN RETURN — BEFORE DNS redirect
    ipt -t nat -A "$NAT_CHAIN" -o tun+ -j RETURN
    ipt -t nat -A "$NAT_CHAIN" -o wg+ -j RETURN

    # DNS redirect
    ipt -t nat -A "$NAT_CHAIN" -p udp --dport 53 -j REDIRECT --to-ports "$DNS_PORT"
    ipt -t nat -A "$NAT_CHAIN" -p tcp --dport 53 -j REDIRECT --to-ports "$DNS_PORT"

    # Loopback RETURN
    ipt -t nat -A "$NAT_CHAIN" -d 127.0.0.0/8 -j RETURN

    # TCP catch-all TransPort
    ipt -t nat -A "$NAT_CHAIN" -p tcp -j REDIRECT --to-ports "$TRANS_PORT"

    # Install jump
    ipt -t nat -I OUTPUT 1 -j "$NAT_CHAIN"

    # Verify chain was populated (at least 3 rules: DNS redirect + TCP catch-all + others)
    local nat_count
    nat_count=$(iptables -t nat -L "$NAT_CHAIN" --line-numbers 2>/dev/null | tail -n +3 | wc -l)
    ks_log "NAT chain rule count: ${nat_count}"

    if [ "$nat_count" -lt 3 ]; then
        ks_log "WARNING: NAT chain has only ${nat_count} rules — falling back to direct OUTPUT rules"
        opsec_info "NAT chain underpopulated (${nat_count} rules) — using direct OUTPUT fallback"

        # Remove the jump to the empty/broken chain
        iptables -t nat -D OUTPUT -j "$NAT_CHAIN" 2>/dev/null
        iptables -t nat -F "$NAT_CHAIN" 2>/dev/null
        iptables -t nat -X "$NAT_CHAIN" 2>/dev/null

        # Direct OUTPUT rules as fallback
        [ -n "$TOR_UID" ] && iptables -t nat -A OUTPUT -p tcp -m owner --uid-owner "$TOR_UID" -j RETURN 2>/dev/null
        iptables -t nat -A OUTPUT -o tun+ -j RETURN 2>/dev/null
        iptables -t nat -A OUTPUT -o wg+ -j RETURN 2>/dev/null
        iptables -t nat -A OUTPUT -p udp --dport 53 -j REDIRECT --to-ports "$DNS_PORT" 2>/dev/null
        iptables -t nat -A OUTPUT -p tcp --dport 53 -j REDIRECT --to-ports "$DNS_PORT" 2>/dev/null
        iptables -t nat -A OUTPUT -d 127.0.0.0/8 -j RETURN 2>/dev/null
        iptables -t nat -A OUTPUT -p tcp -j REDIRECT --to-ports "$TRANS_PORT" 2>/dev/null

        local fb_count
        fb_count=$(iptables -t nat -L OUTPUT --line-numbers 2>/dev/null | tail -n +3 | wc -l)
        ks_log "Fallback OUTPUT NAT rule count: ${fb_count}"
    fi

    if [ "$KS_FAIL" -gt 0 ]; then
        ks_log "WARNING: ${KS_FAIL} iptables commands failed during NAT setup"
        opsec_info "WARNING: ${KS_FAIL} iptables rule(s) failed — check /run/opsec/debug.log"
        return 1
    fi

    ks_log "NAT transparent proxy armed"
    opsec_green "Kill switch fully ARMED — Tor + NAT active"
}

ks_on() {
    ks_filter_on
    ks_nat_on
}

ks_off() {
    opsec_info "Disarming OPSEC kill switch..."
    ks_log "=== KILL SWITCH OFF ==="

    # Filter chain
    iptables -D OUTPUT -j "$CHAIN" 2>/dev/null
    iptables -F "$CHAIN" 2>/dev/null
    iptables -X "$CHAIN" 2>/dev/null

    # NAT chain (config-independent teardown)
    local NAT_CHAIN="GP_NAT"
    iptables -t nat -D OUTPUT -j "$NAT_CHAIN" 2>/dev/null
    iptables -t nat -F "$NAT_CHAIN" 2>/dev/null
    iptables -t nat -X "$NAT_CHAIN" 2>/dev/null

    # Clean up fallback direct OUTPUT NAT rules (if chain approach failed during arm)
    # Loop-delete to catch duplicates — keeps removing until no match left
    local _fb_cleaned=0
    while iptables -t nat -D OUTPUT -p tcp -j REDIRECT --to-ports "$TRANS_PORT" 2>/dev/null; do _fb_cleaned=$((_fb_cleaned+1)); done
    while iptables -t nat -D OUTPUT -p udp --dport 53 -j REDIRECT --to-ports "$DNS_PORT" 2>/dev/null; do _fb_cleaned=$((_fb_cleaned+1)); done
    while iptables -t nat -D OUTPUT -p tcp --dport 53 -j REDIRECT --to-ports "$DNS_PORT" 2>/dev/null; do _fb_cleaned=$((_fb_cleaned+1)); done
    while iptables -t nat -D OUTPUT -d 127.0.0.0/8 -j RETURN 2>/dev/null; do _fb_cleaned=$((_fb_cleaned+1)); done
    while iptables -t nat -D OUTPUT -o tun+ -j RETURN 2>/dev/null; do _fb_cleaned=$((_fb_cleaned+1)); done
    while iptables -t nat -D OUTPUT -o wg+ -j RETURN 2>/dev/null; do _fb_cleaned=$((_fb_cleaned+1)); done
    if [ -n "$TOR_UID" ]; then
        while iptables -t nat -D OUTPUT -p tcp -m owner --uid-owner "$TOR_UID" -j RETURN 2>/dev/null; do _fb_cleaned=$((_fb_cleaned+1)); done
    fi
    [ "$_fb_cleaned" -gt 0 ] && ks_log "Cleaned ${_fb_cleaned} fallback NAT OUTPUT rules"

    # IPv6
    ip6tables -D OUTPUT -j "$CHAIN" 2>/dev/null
    ip6tables -F "$CHAIN" 2>/dev/null
    ip6tables -X "$CHAIN" 2>/dev/null

    # Flush conntrack to clear stale NAT entries
    conntrack -F 2>/dev/null && ks_log "conntrack flushed" || true

    ks_log "Kill switch disarmed"
    opsec_green "Kill switch DISARMED — normal traffic allowed"
}

ks_status() {
    if iptables -L "$CHAIN" >/dev/null 2>&1; then
        opsec_green "Kill switch is ARMED"
        echo ""
        echo "IPv4 rules:"
        iptables -L "$CHAIN" -v -n --line-numbers
        echo ""
        echo "NAT chain:"
        if iptables -t nat -L GP_NAT >/dev/null 2>&1; then
            iptables -t nat -L GP_NAT -v -n --line-numbers
        else
            echo "  (not armed)"
        fi
        echo ""
        echo "IPv6 rules:"
        ip6tables -L "$CHAIN" -v -n --line-numbers 2>/dev/null
    else
        opsec_info "Kill switch is OFF"
    fi
}

case "${1}" in
    on)         ks_on ;;
    filter-on)  ks_filter_on ;;
    nat-on)     ks_nat_on ;;
    off)        ks_off ;;
    status)     ks_status ;;
    *)
        echo "Usage: $(basename "$0") on|off|filter-on|nat-on|status"
        exit 1
        ;;
esac
