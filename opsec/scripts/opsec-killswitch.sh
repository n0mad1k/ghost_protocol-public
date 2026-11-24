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

CHAIN="OPSEC_KILLSWITCH"
TOR_SERVICE=$(opsec_find_tor_service 2>/dev/null || echo tor.service)
TOR_USER=$(systemctl show -p User --value "$TOR_SERVICE" 2>/dev/null || true)
[ -n "$TOR_USER" ] || TOR_USER=$(awk '$1 == "User" {print $2; exit}' /etc/tor/torrc 2>/dev/null)
[ -n "$TOR_USER" ] || { getent passwd tor >/dev/null 2>&1 && TOR_USER=tor; }
[ -n "$TOR_USER" ] || { getent passwd debian-tor >/dev/null 2>&1 && TOR_USER=debian-tor; }
TOR_UID=$(id -u "$TOR_USER" 2>/dev/null || echo "")
KS_LOG="/run/opsec/debug.log"
KS_POLICY_STATE="/run/opsec/strict-policy.state"
mkdir -p /run/opsec 2>/dev/null || true
KS_ERR=$(mktemp /run/opsec/.ks-err.XXXXXX 2>/dev/null || mktemp /tmp/.ks-err.XXXXXX)
KS_FAIL=0
trap 'rm -f "$KS_ERR"' EXIT

ks_log() { echo "[$(date -Is)] [killswitch] $*" >> "$KS_LOG"; }

ks_policy_fingerprint() {
    local policy_json
    policy_json=$(nft -j list table inet opsec_strict 2>/dev/null) || return 1
    [ -n "$policy_json" ] || return 1
    jq -e '.nftables | type == "array" and length > 0' <<<"$policy_json" >/dev/null || return 1
    jq -S 'walk(if type == "object" then del(.handle, .packets, .bytes) else . end)' <<<"$policy_json" |
        sha256sum | awk '{print $1}'
}

ks_record_policy() {
    local mode="$1" fingerprint tmp
    fingerprint=$(ks_policy_fingerprint) || return 1
    [ "${#fingerprint}" -eq 64 ] || return 1
    tmp=$(mktemp /run/opsec/.strict-policy.XXXXXX) || return 1
    printf '%s %s\n' "$mode" "$fingerprint" > "$tmp"
    chmod 0600 "$tmp"
    chown root:root "$tmp"
    mv -f "$tmp" "$KS_POLICY_STATE"
}

ks_policy_matches() {
    local expected_mode="$1" mode expected current owner mode_bits
    [ -f "$KS_POLICY_STATE" ] && [ ! -L "$KS_POLICY_STATE" ] || return 1
    owner=$(stat -c '%u:%g' "$KS_POLICY_STATE" 2>/dev/null) || return 1
    mode_bits=$(stat -c '%a' "$KS_POLICY_STATE" 2>/dev/null) || return 1
    [ "$owner" = "0:0" ] && [ "$mode_bits" = "600" ] || return 1
    read -r mode expected < "$KS_POLICY_STATE" || return 1
    [ "$mode" = "$expected_mode" ] && [ "${#expected}" -eq 64 ] || return 1
    current=$(ks_policy_fingerprint) || return 1
    [ "$current" = "$expected" ]
}

ks_strict_status() {
    command -v nft >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && [ -n "$TOR_UID" ] || return 1
    nft -j list table inet opsec_strict 2>/dev/null | jq -e --argjson tor_uid "$TOR_UID" '
        def chains: [.nftables[] | .chain? | select(.family == "inet" and .table == "opsec_strict")];
        def rules($name): [.nftables[] | .rule? | select(.family == "inet" and .table == "opsec_strict" and .chain == $name)];
        def accepts: any(.expr[]; has("accept"));
        def meta($key; $right): any(.expr[]; .match?.left?.meta?.key == $key and .match.right == $right);
        (chains | length == 3) and
        (chains | any(.name == "output_nat" and .type == "nat" and .hook == "output" and .prio == -100 and .policy == "accept")) and
        (chains | any(.name == "input" and .type == "filter" and .hook == "input" and .prio == 0 and .policy == "drop")) and
        (chains | any(.name == "output" and .type == "filter" and .hook == "output" and .prio == 0 and .policy == "drop")) and
        (rules("output_nat") | length == 6) and
        (rules("input") | length == 3) and
        (rules("output") | length == 18) and
        (rules("input") | any((meta("iif"; "lo") or meta("iifname"; "lo")) and accepts)) and
        (rules("input") | any(any(.expr[]; .match?.left?.ct?.key == "state") and accepts)) and
        (rules("output") | any((meta("oif"; "lo") or meta("oifname"; "lo")) and accepts)) and
        (rules("output") | any(meta("skuid"; $tor_uid) and meta("l4proto"; "tcp") and accepts)) and
        (rules("output") | any(meta("l4proto"; "udp") and any(.expr[]; has("reject")))) and
        (rules("output") | all(any(.expr[]; .match?.left?.ct?.key == "state") | not))
    ' >/dev/null && ks_policy_matches strict
}

ks_emergency_status() {
    command -v nft >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 || return 1
    nft -j list table inet opsec_strict 2>/dev/null | jq -e '
        def chains: [.nftables[] | .chain? | select(.family == "inet" and .table == "opsec_strict")];
        def rules($name): [.nftables[] | .rule? | select(.family == "inet" and .table == "opsec_strict" and .chain == $name)];
        (chains | length == 2) and
        (chains | all(.type == "filter" and .prio == 0 and .policy == "drop")) and
        (chains | any(.name == "input" and .hook == "input")) and
        (chains | any(.name == "output" and .hook == "output")) and
        (rules("input") | length == 1) and (rules("output") | length == 1) and
        (rules("input") | all(any(.expr[]; (.match?.left?.meta?.key == "iif" or .match?.left?.meta?.key == "iifname") and .match.right == "lo") and any(.expr[]; has("accept")))) and
        (rules("output") | all(any(.expr[]; (.match?.left?.meta?.key == "oif" or .match?.left?.meta?.key == "oifname") and .match.right == "lo") and any(.expr[]; has("accept"))))
    ' >/dev/null && ks_policy_matches emergency
}

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

    local NAT_CHAIN="OPSEC_KS_NAT"

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
    local NAT_CHAIN="OPSEC_KS_NAT"
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
    if ks_strict_status; then
        opsec_green "Strict no-leak policy is ARMED"
        nft list table inet opsec_strict
        return 0
    elif ks_emergency_status; then
        opsec_info "Emergency containment policy is ARMED"
        nft list table inet opsec_strict
        return 0
    elif nft list table inet opsec_strict >/dev/null 2>&1; then
        echo "Strict firewall table exists but could not be verified" >&2
        return 1
    fi
    if iptables -L "$CHAIN" >/dev/null 2>&1; then
        opsec_green "Kill switch is ARMED"
        echo ""
        echo "IPv4 rules:"
        iptables -L "$CHAIN" -v -n --line-numbers
        echo ""
        echo "NAT chain:"
        if iptables -t nat -L OPSEC_KS_NAT >/dev/null 2>&1; then
            iptables -t nat -L OPSEC_KS_NAT -v -n --line-numbers
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

ks_strict_on() {
    command -v nft >/dev/null 2>&1 || { echo "nftables is required for strict mode" >&2; return 1; }
    [ -n "$TOR_UID" ] || { echo "Tor service account was not found" >&2; return 1; }
    local rules
    rules=$(mktemp /run/opsec/.strict-nft.XXXXXX) || return 1
    cat > "$rules" <<EOF
table inet opsec_strict {
  chain output_nat {
    type nat hook output priority -100; policy accept;
    meta skuid $TOR_UID return
    udp dport 53 counter redirect to :$DNS_PORT
    tcp dport 53 counter redirect to :$DNS_PORT
    ip daddr 127.0.0.0/8 return
    ip6 daddr ::1 return
    meta l4proto tcp counter redirect to :$TRANS_PORT
  }
  chain input {
    type filter hook input priority 0; policy drop;
    iif lo accept
    ct state established,related accept
    udp sport 67 udp dport 68 accept
  }
  chain output {
    type filter hook output priority 0; policy drop;
    oif lo accept
    ip daddr 127.0.0.1 tcp dport $TRANS_PORT accept
    ip daddr 127.0.0.1 udp dport $DNS_PORT accept
    ip daddr 127.0.0.1 tcp dport $DNS_PORT accept
    udp sport 68 udp dport 67 ip daddr 255.255.255.255 accept
    udp sport 68 udp dport 67 ip daddr 0.0.0.0/0 accept
    ip daddr 10.0.0.0/8 reject
    ip daddr 100.64.0.0/10 reject
    ip daddr 169.254.0.0/16 reject
    ip daddr 172.16.0.0/12 reject
    ip daddr 192.168.0.0/16 reject
    ip daddr 224.0.0.0/4 reject
    ip daddr 255.255.255.255 reject
    ip6 daddr fc00::/7 reject
    ip6 daddr fe80::/10 reject
    ip6 daddr ff00::/8 reject
    meta skuid $TOR_UID meta l4proto tcp accept
    meta l4proto udp counter reject
  }
}
EOF
    if nft list table inet opsec_strict >/dev/null 2>&1; then
        sed -i '1i delete table inet opsec_strict' "$rules"
    fi
    if ! nft -c -f "$rules" || ! nft -f "$rules"; then
        rm -f "$rules"
        return 1
    fi
    rm -f "$rules"
    ks_record_policy strict || return 1
    ks_strict_status || return 1
    ks_log "Strict nftables policy armed; only Tor UID and DHCP egress allowed"
    opsec_green "Strict no-leak policy ARMED"
}

ks_strict_off() {
    if nft list table inet opsec_strict >/dev/null 2>&1; then
        nft delete table inet opsec_strict || return 1
    fi
    rm -f "$KS_POLICY_STATE"
}

ks_emergency_on() {
    command -v nft >/dev/null 2>&1 || return 1
    local rules
    rules=$(mktemp /run/opsec/.emergency-nft.XXXXXX) || return 1
    cat > "$rules" <<'EOF'
table inet opsec_strict {
  chain input {
    type filter hook input priority 0; policy drop;
    iif lo accept
  }
  chain output {
    type filter hook output priority 0; policy drop;
    oif lo accept
  }
}
EOF
    if nft list table inet opsec_strict >/dev/null 2>&1; then
        sed -i '1i delete table inet opsec_strict' "$rules"
    fi
    if ! nft -c -f "$rules" || ! nft -f "$rules"; then
        rm -f "$rules"
        return 1
    fi
    rm -f "$rules"
    ks_record_policy emergency || return 1
    ks_emergency_status
}

case "${1}" in
    on)         ks_on ;;
    filter-on)  ks_filter_on ;;
    nat-on)     ks_nat_on ;;
    strict-on)  ks_strict_on ;;
    strict-status) ks_strict_status ;;
    emergency-on) ks_emergency_on ;;
    emergency-status) ks_emergency_status ;;
    strict-off) ks_strict_off ;;
    off)        ks_off ;;
    status)     ks_status ;;
    *)
        echo "Usage: $(basename "$0") on|off|filter-on|nat-on|strict-on|strict-status|strict-off|emergency-on|emergency-status|status"
        exit 1
        ;;
esac
