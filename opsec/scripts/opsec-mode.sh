#!/bin/bash
# opsec-mode — Master toggle for Advanced OPSEC Mode
# Usage: sudo opsec-mode on|off|status|breakglass|breakglass-off
#
# ON:         Activates all subsystems (torrc, DNS, kill switch, MAC, hostname, hardening)
# OFF:        Reverses everything back to standard mode (blocked on paranoid levels)
# STATUS:     Shows current state of all subsystems with config values
# BREAKGLASS: Emergency override — drops kill switch temporarily
# BREAKGLASS-OFF: End break-glass early

## NOTE: Do NOT use "set -euo pipefail" — it causes silent crashes
## throughout this script when commands like grep, systemctl, etc.
## return non-zero. Use explicit error handling instead.

if [ "$EUID" -ne 0 ]; then
    echo "[!] Please run as root: sudo opsec-mode on|off|status"
    exit 1
fi

# ─── EARLY ARG PARSE (needed before lock decision) ───────────────────────────
_VERBOSE_EARLY=false
_CMD_EARLY=""
for _a in "$@"; do
    case "$_a" in
        -v|--verbose) _VERBOSE_EARLY=true ;;
        *)  [ -z "$_CMD_EARLY" ] && _CMD_EARLY="$_a" ;;
    esac
done

echo "[*] opsec-mode: ${_CMD_EARLY:-} (pid $$)"
mkdir -p /run/opsec 2>/dev/null || true

LOCK_FILE="/run/opsec/mode.lock"
PID_FILE="/run/opsec/mode.pid"

# ─── MUTEX: PID-FILE BASED (no inherited fd leaks) ──────────────────────────
# Previous approach used flock(fd 9) but child processes (opsec-harden.sh etc.)
# inherit the fd and hold the lock after the parent exits, causing "Another
# instance running" on the next invocation. Fix: use flock only for the brief
# atomic check, then immediately close the fd. The PID file guards ongoing
# exclusivity, and stale PIDs are detected automatically.
_acquire_lock() {
    exec 9>"$LOCK_FILE"
    if flock -n 9; then
        # Got it clean
        echo $$ > "$PID_FILE"
        exec 9>&-   # Close fd 9 immediately — children won't inherit it
        return 0
    fi
    exec 9>&-   # Close our attempt either way

    # flock failed — check if the holder is still a real opsec-mode process
    local stale_pid
    stale_pid=$(cat "$PID_FILE" 2>/dev/null || echo "")
    if [ -n "$stale_pid" ] && kill -0 "$stale_pid" 2>/dev/null; then
        local stale_cmd
        stale_cmd=$(cat "/proc/${stale_pid}/comm" 2>/dev/null || echo "")
        if echo "$stale_cmd" | grep -q "opsec-mode"; then
            echo "[!] Another opsec-mode instance is running (PID ${stale_pid})"
            return 1
        fi
    fi

    # Stale lock: previous opsec-mode exited but a child inherited the fd,
    # or the process crashed. Force-reclaim.
    echo "[*] Reclaiming stale lock (previous holder gone or inherited by child)"
    rm -f "$LOCK_FILE"
    exec 9>"$LOCK_FILE"
    if flock -n 9; then
        echo $$ > "$PID_FILE"
        exec 9>&-
        return 0
    fi
    exec 9>&-

    echo "[!] Cannot acquire lock even after cleanup"
    return 1
}

# ─── DISPATCH READ-ONLY COMMANDS BEFORE LOCK ─────────────────────────────────
# diag and status are read-only — they must not be blocked by a running mode_on
_OWNS_LOCK=false
case "${_CMD_EARLY:-}" in
    diag|status) ;; # handled after full init below, but skip lock
    *)  _acquire_lock || exit 1; _OWNS_LOCK=true ;;
esac
# Only clean up PID file if WE own the lock (diag/status must not delete mode_on's PID)
trap '[ -n "${TAIL_PID:-}" ] && kill "$TAIL_PID" 2>/dev/null; [ "$_OWNS_LOCK" = "true" ] && rm -f "$PID_FILE"' EXIT

STATE_FILE="/var/run/opsec-advanced.enabled"
BOOT_MARKER="/etc/opsec/boot-advanced.enabled"
TORRC_DEFAULT="/etc/tor/torrc-default"
RESOLV_BACKUP="/etc/resolv.conf.backup"
OPSEC_LIB="/usr/local/lib/opsec/opsec-lib.sh"
BREAKGLASS_STATE="/var/run/opsec-breakglass.active"
BREAKGLASS_TIMEOUT="${BREAKGLASS_TIMEOUT:-900}"  # 15 minutes default
PREFLIGHT_LOG="/run/opsec/preflight.log"
DEBUG_LOG="/run/opsec/debug.log"
BOOTSTRAP_STOP="/var/run/opsec-bootstrap-stop"
NM_MAC_CONF="/etc/NetworkManager/conf.d/opsec-mac-random.conf"

# Debug logger — appends timestamped entries (prints to terminal in verbose mode)
opsec_debug() {
    local msg="[$(date -Is)] $*"
    echo "$msg" >> "$DEBUG_LOG"
    chmod 600 "$DEBUG_LOG" 2>/dev/null
    if [ "$VERBOSE" = "true" ]; then
        echo -e "\033[38;5;240m  DBG: $*\033[0m"
    fi
}

# ─── SOURCE SHARED LIBRARY ────────────────────────────────────────────────────
if [ -f "$OPSEC_LIB" ]; then
    . "$OPSEC_LIB"
    opsec_load_config 2>/dev/null || true
    _HAS_LIB=true
else
    # Fallback: hardcoded behavior if lib not yet deployed
    _HAS_LIB=false
    opsec_green()  { echo -e "\033[38;5;49m[+] $*\033[0m"; }
    opsec_red()    { echo -e "\033[38;5;196m[-] $*\033[0m"; }
    opsec_yellow() { echo -e "\033[38;5;214m[*] $*\033[0m"; }
    opsec_info()   { echo -e "\033[38;5;39m[~] $*\033[0m"; }
    opsec_cyan()   { echo -e "\033[38;5;51m[>] $*\033[0m"; }
    opsec_mag()    { echo -e "\033[38;5;201m[*] $*\033[0m"; }
    opsec_dim()    { echo -e "\033[38;5;244m    $*\033[0m"; }
    opsec_hdr()    { echo -e "\033[38;5;51m━━━ \033[38;5;201m$*\033[38;5;51m ━━━\033[0m"; }
fi

# ─── HELPERS ───────────────────────────────────────────────────────────────────

get_level_type() {
    echo "${LEVEL_TYPE:-standard}"
}

is_paranoid() {
    [ "$(get_level_type)" = "paranoid" ]
}

is_cloud_level() {
    local level="${DEPLOYMENT_LEVEL:-bare-metal-standard}"
    case "$level" in
        cloud-*) return 0 ;;
        *)       return 1 ;;
    esac
}

# ─── BASE MODE (standard privacy hardening only) ─────────────────────────────
mode_base() {
    local profile="${PROFILE_NAME:-default}"

    echo ""
    opsec_hdr "APPLYING BASE PRIVACY HARDENING"
    opsec_dim "Profile: ${profile}"
    echo ""

    # 1. Disable IPv6
    opsec_info "Step 1/5: Disabling IPv6..."
    local ipv6_all
    ipv6_all=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo "0")
    if [ "$ipv6_all" = "1" ]; then
        opsec_green "IPv6 already disabled"
    else
        sysctl -w net.ipv6.conf.all.disable_ipv6=1 >/dev/null
        sysctl -w net.ipv6.conf.default.disable_ipv6=1 >/dev/null
        opsec_green "IPv6 disabled"
    fi

    # 2. Set privacy DNS (not Tor — use BASE_DNS)
    opsec_info "Step 2/5: Setting privacy DNS..."
    local base_dns="${BASE_DNS:-quad9}"
    chattr -i /etc/resolv.conf 2>/dev/null || true
    if [ ! -f "$RESOLV_BACKUP" ]; then
        cp /etc/resolv.conf "$RESOLV_BACKUP" 2>/dev/null || true
        chmod 600 "$RESOLV_BACKUP" 2>/dev/null || true
    fi
    case "$base_dns" in
        quad9)
            cat > /etc/resolv.conf << 'EOF'
nameserver 9.9.9.9
nameserver 149.112.112.112
EOF
            ;;
        cloudflare)
            cat > /etc/resolv.conf << 'EOF'
nameserver 1.1.1.1
nameserver 1.0.0.1
EOF
            ;;
        *)
            cat > /etc/resolv.conf << 'EOF'
nameserver 9.9.9.9
nameserver 149.112.112.112
EOF
            ;;
    esac
    opsec_green "DNS set to ${base_dns}"

    # 3. Randomize MAC (bare-metal only) + reconnect network after
    if ! is_cloud_level && [ "${BASE_MAC_RANDOMIZE:-1}" = "1" ]; then
        opsec_info "Step 3/5: Randomizing MAC addresses..."
        if [ -x /usr/local/bin/randomize-mac.sh ]; then
            /usr/local/bin/randomize-mac.sh
            # Reconnect WiFi to get new DHCP lease with new MAC
            local wifi_if
            wifi_if=$(nmcli -t -f DEVICE,TYPE device status 2>/dev/null | grep ':wifi$' | head -1 | cut -d: -f1)
            if [ -n "$wifi_if" ]; then
                opsec_dim "Reconnecting ${wifi_if} for new DHCP lease..."
                nmcli device disconnect "$wifi_if" 2>/dev/null || true
                sleep 1
                nmcli device connect "$wifi_if" 2>/dev/null || true
                sleep 3
            fi
        else
            opsec_yellow "randomize-mac.sh not found — skipping"
        fi
    else
        opsec_dim "Step 3/5: MAC randomization skipped (cloud or disabled)"
    fi

    # 4. Disable swap + core dumps
    opsec_info "Step 4/5: Hardening swap and core dumps..."
    if [ "${HARDEN_SWAP:-1}" = "1" ]; then
        swapoff -a 2>/dev/null || true
        opsec_green "Swap disabled"
    fi
    if [ "${HARDEN_CORE_DUMPS:-1}" = "1" ]; then
        sysctl -w kernel.core_pattern='|/bin/false' >/dev/null 2>&1 || true
        opsec_green "Core dumps disabled"
    fi

    # 5. Apply additional system hardening (base-only: skip ghost-mode features like USB block)
    opsec_info "Step 5/5: Applying system hardening..."
    if [ -x /usr/local/bin/opsec-harden.sh ]; then
        OPSEC_BASE_ONLY=1 /usr/local/bin/opsec-harden.sh apply
    else
        opsec_yellow "opsec-harden.sh not found — skipping"
    fi

    echo ""
    opsec_hdr "BASE PRIVACY MODE: ACTIVE"
    echo ""
    opsec_dim "DNS:          ${base_dns}"
    opsec_dim "IPv6:         disabled"
    opsec_dim "Swap:         disabled"
    opsec_dim "Core dumps:   disabled"
    if ! is_cloud_level; then
        opsec_dim "MAC:          randomized"
    fi
    echo ""
    opsec_dim "Ghost mode:   sudo opsec-mode on"
    echo ""

    # Run base preflight
    if [ -x /usr/local/bin/opsec-preflight.sh ]; then
        /usr/local/bin/opsec-preflight.sh --base --enforce || {
            opsec_red "Base preflight FAILED — check /run/opsec/preflight.log"
        }
    fi
}

# ─── ON ──────────────────────────────────────────────────────────────────────
mode_on() {
    local rotation="${TOR_CIRCUIT_ROTATION:-30}"
    local blacklist="${TOR_BLACKLIST-us,gb,ca,au,nz}"
    local socks_port="${TOR_SOCKS_PORT:-9050}"
    local dns_port="${TOR_DNS_PORT:-5353}"
    local profile="${PROFILE_NAME:-default}"

    echo ""
    opsec_hdr "ACTIVATING GHOST MODE"
    opsec_dim "Profile: ${profile}"
    echo ""

    opsec_debug "=========================================="
    opsec_debug "=== MODE ON START ==="
    opsec_debug "=========================================="

    # Clear any stale stop signal from previous runs
    rm -f "$BOOTSTRAP_STOP"

    # 0. Disarm stale KS, then immediately arm filter-only lockdown
    if iptables -L GP_FW >/dev/null 2>&1; then
        opsec_debug "Step 0: Disarming stale kill switch"
        /usr/local/bin/opsec-killswitch.sh off 2>/dev/null
    fi
    opsec_debug "Step 0.5: Arming filter-only lockdown (pre-bootstrap)"
    /usr/local/bin/opsec-killswitch.sh filter-on
    opsec_debug "  Filter lockdown active — only Tor/VPN/DHCP allowed"

    # 1. Disable IPv6
    opsec_info "Step 1/10: Disabling IPv6..."
    opsec_debug "Step 1: Disabling IPv6"
    sysctl -w net.ipv6.conf.all.disable_ipv6=1 >/dev/null 2>&1 || true
    sysctl -w net.ipv6.conf.default.disable_ipv6=1 >/dev/null 2>&1 || true
    opsec_green "IPv6 disabled"

    # 2. Randomize MAC via NetworkManager (prevents NM from reverting macchanger)
    opsec_info "Step 2/10: Randomizing MAC addresses..."
    opsec_debug "Step 2: MAC randomization via NetworkManager"
    if ! is_cloud_level; then
        local wifi_if
        wifi_if=$(nmcli -t -f DEVICE,TYPE device status 2>/dev/null | grep ':wifi$' | head -1 | cut -d: -f1)
        # Configure NetworkManager to use random MACs natively
        mkdir -p /etc/NetworkManager/conf.d
        cat > "$NM_MAC_CONF" << 'NMEOF'
# OPSEC: random MAC on every connection (managed by opsec-mode)
[device]
wifi.scan-rand-mac-address=yes

[connection]
wifi.cloned-mac-address=random
ethernet.cloned-mac-address=random
NMEOF
        opsec_debug "  NM MAC config written to ${NM_MAC_CONF}"
        # Reload NM config and reconnect to apply random MAC
        nmcli general reload 2>/dev/null || true
        if [ -n "$wifi_if" ]; then
            opsec_debug "  Reconnecting WiFi: ${wifi_if}"
            local old_mac
            old_mac=$(ip link show "$wifi_if" 2>/dev/null | awk '/ether/ {print $2}')
            opsec_debug "  MAC before: ${old_mac}"
            nmcli device disconnect "$wifi_if" 2>/dev/null || true
            sleep 2
            nmcli device connect "$wifi_if" 2>/dev/null || true
            # Wait for connection to establish
            for w in $(seq 1 15); do
                if nmcli -t -f DEVICE,STATE device status 2>/dev/null | grep "^${wifi_if}:connected" >/dev/null; then
                    opsec_debug "  WiFi reconnected at second ${w}"
                    break
                fi
                sleep 1
            done
            # Wait for actual IP routing (NM "connected" != routed)
            opsec_debug "  Waiting for network route to establish..."
            for r in $(seq 1 10); do
                if ip route show default 2>/dev/null | grep -q .; then
                    opsec_debug "  Default route available at second ${r}"
                    break
                fi
                sleep 1
            done
            sleep 2  # Brief settle for ARP/DHCP
        fi
        local new_mac
        new_mac=$(ip link show "$wifi_if" 2>/dev/null | awk '/ether/ {print $2}')
        opsec_debug "  MAC after: ${new_mac}"
        if [ "$old_mac" != "$new_mac" ] 2>/dev/null; then
            opsec_green "MAC randomized: ${new_mac}"
        else
            opsec_yellow "MAC unchanged — NM may need restart"
            opsec_debug "  WARNING: MAC did not change (${old_mac} -> ${new_mac})"
        fi
    else
        opsec_dim "Skipped (cloud deployment)"
    fi

    # 3. Randomize hostname
    opsec_info "Step 3/10: Randomizing hostname..."
    opsec_debug "Step 3: Hostname randomization"
    if ! is_cloud_level; then
        if [ ! -f /run/opsec/hostname.original ]; then
            hostname > /run/opsec/hostname.original
            chmod 600 /run/opsec/hostname.original
            opsec_dim "Saved original hostname: $(cat /run/opsec/hostname.original)"
            opsec_debug "  Saved original to tmpfs: $(hostname)"
        fi
        /usr/local/bin/opsec-hostname-randomize.sh 2>&1 | tee -a "$DEBUG_LOG" || true
        opsec_debug "  Hostname after randomize: $(hostname)"
    else
        opsec_dim "Skipped (cloud deployment)"
    fi

    # 4. Set state marker EARLY — needed for chattr +i in DNS step
    touch "$STATE_FILE"
    opsec_debug "Step 4: State marker set early (for DNS lock)"

    # 5. Deploy hardened torrc + clear stale Tor state + restart Tor
    opsec_info "Step 5/10: Deploying hardened Tor configuration..."
    opsec_debug "Step 5: Deploying torrc (HAS_LIB=${_HAS_LIB})"

    # Clear Tor caches only if TOR_CLEAR_CACHE=1 (preserving guard state)
    opsec_debug "  Cache clear: TOR_CLEAR_CACHE=${TOR_CLEAR_CACHE:-0}"
    systemctl stop tor 2>/dev/null || true
    if [ "${TOR_CLEAR_CACHE:-0}" = "1" ]; then
        opsec_debug "  Clearing Tor descriptor caches"
        rm -f /var/lib/tor/cached-descriptors /var/lib/tor/cached-descriptors.new \
              /var/lib/tor/cached-microdesc* /var/lib/tor/cached-consensus \
              /var/lib/tor/cached-certs 2>/dev/null || true
    else
        opsec_debug "  Keeping Tor descriptor caches (faster bootstrap)"
    fi

    if [ "$_HAS_LIB" = "true" ]; then
        opsec_generate_torrc
        opsec_green "Torrc generated from config (blacklist: ${blacklist})"
        opsec_debug "Torrc generated via lib (blacklist: ${blacklist})"
    else
        local torrc_opsec="/etc/tor/torrc-opsec"
        if [ -f "$torrc_opsec" ]; then
            cp "$torrc_opsec" /etc/tor/torrc
        fi
    fi

    opsec_debug "Current torrc contents:"
    cat /etc/tor/torrc >> "$DEBUG_LOG" 2>&1
    opsec_debug "---"

    # Truncate Tor log so bootstrap check doesn't read stale entries
    mkdir -p /run/tor && chown debian-tor:debian-tor /run/tor 2>/dev/null || true
    : > /run/tor/notices.log
    chown debian-tor:debian-tor /run/tor/notices.log 2>/dev/null || true

    opsec_debug "Restarting Tor service..."
    systemctl restart tor 2>&1 | tee -a "$DEBUG_LOG"
    opsec_debug "systemctl restart tor exit code: $?"
    opsec_debug "Tor service status: $(systemctl is-active tor 2>&1)"

    # 6. Configure DNS (lock it before bootstrap wait)
    opsec_info "Step 6/10: Configuring DNS..."
    opsec_debug "Step 6: Configuring DNS (DNS_MODE=${DNS_MODE:-tor})"
    if [ ! -f "$RESOLV_BACKUP" ]; then
        chattr -i /etc/resolv.conf 2>/dev/null || true
        cp /etc/resolv.conf "$RESOLV_BACKUP"
        chmod 600 "$RESOLV_BACKUP" 2>/dev/null || true
        opsec_debug "Backed up resolv.conf (mode 600)"
    fi
    if [ "$_HAS_LIB" = "true" ]; then
        opsec_generate_resolv
        opsec_green "DNS set to mode: ${DNS_MODE:-tor}"
    else
        chattr -i /etc/resolv.conf 2>/dev/null || true
        echo "nameserver 127.0.0.1" > /etc/resolv.conf
        chattr +i /etc/resolv.conf
        opsec_green "DNS locked to 127.0.0.1 (Tor DNSPort ${dns_port})"
    fi
    # Force lock DNS regardless — state file is already set
    chattr +i /etc/resolv.conf 2>/dev/null || true
    # Verify immutable flag actually took hold
    if ! lsattr /etc/resolv.conf 2>/dev/null | grep -q 'i'; then
        opsec_red "WARNING: chattr +i failed on resolv.conf — DNS lock may not hold"
        opsec_debug "  CRITICAL: chattr +i verification FAILED — filesystem may not support extended attributes"
    else
        opsec_debug "  chattr +i verified on resolv.conf"
    fi
    opsec_debug "resolv.conf now: $(cat /etc/resolv.conf 2>/dev/null | tr '\n' ' ')"
    # Lock NetworkManager out of DNS management
    mkdir -p /etc/NetworkManager/conf.d
    cat > /etc/NetworkManager/conf.d/opsec-dns-lock.conf << 'DNSEOF'
[main]
dns=none
DNSEOF
    nmcli general reload 2>/dev/null || true
    opsec_debug "  NM dns=none lock installed"

    # 7. Wait for Tor bootstrap (up to 180s — first guard may timeout)
    opsec_yellow "Waiting for Tor to fully bootstrap (100%)..."
    opsec_debug "Step 7: Tor bootstrap wait (180s max)"
    TAIL_PID=""
    if [ "$VERBOSE" = "true" ]; then
        tail -f /run/tor/notices.log 2>/dev/null &
        TAIL_PID=$!
    fi
    local tor_ready=false
    for i in $(seq 1 180); do
        # Check if mode_off signaled us to stop
        if [ -f "$BOOTSTRAP_STOP" ]; then
            opsec_yellow "Bootstrap wait aborted (mode_off requested)"
            opsec_debug "Bootstrap loop aborted by stop signal at ${i}s"
            rm -f "$BOOTSTRAP_STOP"
            break
        fi
        local boot_pct
        boot_pct=$(grep "Bootstrapped" /run/tor/notices.log 2>/dev/null | tail -1 | grep -oP '\d+(?=%)' || true)
        if [ "$boot_pct" = "100" ] && ss -tln | grep -q ":${socks_port} "; then
            opsec_green "Tor fully bootstrapped (100%) at ${i}s"
            opsec_debug "Tor bootstrapped 100% at second ${i}"
            tor_ready=true
            break
        fi
        if [ $((i % 5)) -eq 0 ] || [ "$i" -eq 1 ]; then
            opsec_dim "  Bootstrap: ${boot_pct:-0}% (${i}s)"
            opsec_debug "Tor wait ${i}s: bootstrap=${boot_pct:-0}%"
        fi
        sleep 1
        if [ "$i" -eq 180 ]; then
            opsec_red "Tor bootstrap timeout after 180s (at ${boot_pct:-0}%)"
            opsec_debug "TIMEOUT: Tor at ${boot_pct:-0}% after 180s"
            opsec_debug "Last 10 Tor log lines:"
            tail -10 /run/tor/notices.log >> "$DEBUG_LOG" 2>&1
        fi
    done
    [ -n "${TAIL_PID:-}" ] && kill "$TAIL_PID" 2>/dev/null

    # 8. Add NAT transparent proxy AFTER Tor is ready
    opsec_info "Step 8/10: Arming NAT transparent proxy..."
    opsec_debug "Step 8: NAT proxy (tor_ready=${tor_ready})"
    local ks_exit
    if [ "$tor_ready" = "true" ]; then
        /usr/local/bin/opsec-killswitch.sh nat-on
        ks_exit=$?
        opsec_debug "  NAT proxy armed with Tor at 100% (exit=${ks_exit})"
    else
        # If mode_off aborted us, don't arm NAT — teardown is already running
        if [ ! -f "$STATE_FILE" ]; then
            opsec_yellow "Bootstrap aborted by mode_off — skipping NAT arm"
            opsec_debug "  Skipping NAT — state file gone (mode_off in progress)"
            return 0
        fi
        opsec_yellow "WARNING: Tor not fully bootstrapped — arming NAT anyway"
        /usr/local/bin/opsec-killswitch.sh nat-on
        ks_exit=$?
        opsec_debug "  NAT proxy armed with Tor NOT ready (exit=${ks_exit})"
    fi
    opsec_debug "  Kill switch exit code: ${ks_exit}"
    # Flush conntrack so stale entries don't bypass NAT redirect
    conntrack -F 2>/dev/null && opsec_debug "  conntrack table flushed" || opsec_debug "  conntrack flush skipped (not available)"
    opsec_debug "  Filter rule count: $(iptables -L GP_FW --line-numbers 2>/dev/null | tail -n +3 | wc -l)"
    local _nat_count
    _nat_count=$(iptables -t nat -L GP_NAT --line-numbers 2>/dev/null | tail -n +3 | wc -l)
    opsec_debug "  NAT chain (GP_NAT) rule count: ${_nat_count}"
    opsec_debug "  NAT OUTPUT jump rules: $(iptables -t nat -L OUTPUT --line-numbers 2>/dev/null | tail -n +3 | wc -l)"
    # TCP listeners (TransPort 9040, SOCKSPort 9050)
    local _tcp_ports
    _tcp_ports=$(ss -tlnp 2>/dev/null | grep -E ":(9040|9050|5353)" || echo "  NONE")
    opsec_debug "  Tor TCP ports listening:"
    echo "$_tcp_ports" >> "$DEBUG_LOG" 2>&1
    if [ "$VERBOSE" = "true" ]; then echo -e "\033[38;5;240m  DBG: TCP: ${_tcp_ports}\033[0m"; fi
    # UDP listener (DNSPort 5353)
    local _udp_ports
    _udp_ports=$(ss -ulnp 2>/dev/null | grep -E ":5353" || echo "  NONE")
    opsec_debug "  Tor UDP ports listening:"
    echo "$_udp_ports" >> "$DEBUG_LOG" 2>&1
    if [ "$VERBOSE" = "true" ]; then echo -e "\033[38;5;240m  DBG: UDP: ${_udp_ports}\033[0m"; fi

    # 9. Apply system hardening + boot services
    opsec_info "Step 9/10: Applying system hardening..."
    opsec_debug "Step 9: Hardening + boot services"
    if [ -x /usr/local/bin/opsec-harden.sh ]; then
        /usr/local/bin/opsec-harden.sh apply 2>&1 | tee -a "$DEBUG_LOG" || true
    else
        opsec_yellow "opsec-harden.sh not found — skipping"
    fi
    systemctl enable opsec-mac-randomize.service 2>/dev/null && opsec_green "MAC randomize on boot: enabled" || opsec_yellow "MAC service not found"
    systemctl enable opsec-hostname-randomize.service 2>/dev/null && opsec_green "Hostname randomize on boot: enabled" || opsec_yellow "Hostname service not found"
    systemctl enable opsec-killswitch.service 2>/dev/null && opsec_green "Kill switch on boot: enabled" || opsec_yellow "Kill switch service not found"
    if [ -f "$BOOT_MARKER" ]; then
        systemctl enable opsec-boot-advanced.service 2>/dev/null || true
        opsec_green "Boot-into-advanced: enabled"
    fi

    # 10. Start sentry daemon if available
    opsec_info "Step 10/10: Starting sentry..."
    opsec_debug "Step 10: Sentry + traffic blend"
    if [ -x /usr/local/bin/opsec-sentry.sh ]; then
        /usr/local/bin/opsec-sentry.sh start 2>/dev/null && opsec_green "Sentry daemon started" || opsec_yellow "Sentry start failed"
    else
        opsec_dim "Sentry not installed — skipping"
    fi
    if [ -x /usr/local/bin/opsec-traffic-blend.sh ]; then
        /usr/local/bin/opsec-traffic-blend.sh start 2>/dev/null && opsec_green "Traffic blending started" || opsec_dim "Traffic blend not started"
    fi

    # ─── EXIT GATE: Verify all subsystems before declaring active ────────────
    _final_ok=true
    if ! systemctl is-active tor >/dev/null 2>&1; then
        opsec_red "CRITICAL: Tor is NOT running"; _final_ok=false
    fi
    if ! iptables -C OUTPUT -j GP_FW 2>/dev/null; then
        opsec_red "CRITICAL: Kill switch is NOT armed"; _final_ok=false
    fi
    # Check NAT rules exist (either in chain or direct OUTPUT fallback)
    local _gate_nat_count=0
    if iptables -t nat -L GP_NAT >/dev/null 2>&1; then
        _gate_nat_count=$(iptables -t nat -L GP_NAT --line-numbers 2>/dev/null | tail -n +3 | wc -l)
    fi
    if [ "$_gate_nat_count" -lt 3 ]; then
        # Check if fallback direct OUTPUT rules are present
        local _gate_output_nat
        _gate_output_nat=$(iptables -t nat -L OUTPUT --line-numbers 2>/dev/null | tail -n +3 | wc -l)
        if [ "$_gate_output_nat" -lt 3 ]; then
            opsec_red "CRITICAL: NAT transparent proxy NOT armed (chain=${_gate_nat_count}, output=${_gate_output_nat} rules)"
            _final_ok=false
        else
            opsec_debug "  NAT using direct OUTPUT fallback (${_gate_output_nat} rules)"
        fi
    fi
    if ! ss -tln | grep -q ":${socks_port} "; then
        opsec_red "CRITICAL: SOCKS port ${socks_port} NOT listening"; _final_ok=false
    fi
    # Check TransPort (9040) and DNSPort (5353) are listening
    if ! ss -tln | grep -q ":9040 "; then
        opsec_red "CRITICAL: TransPort 9040 NOT listening"; _final_ok=false
    fi
    if ! ss -uln | grep -q ":5353 "; then
        opsec_red "CRITICAL: DNSPort 5353 NOT listening (UDP)"; _final_ok=false
    fi
    # Live connectivity test — actually verify traffic flows through Tor
    if [ "$_final_ok" = "true" ]; then
        opsec_info "Testing transparent proxy connectivity..."
        local _tp_result
        _tp_result=$(curl -4 -s --max-time 15 https://check.torproject.org/api/ip 2>&1)
        opsec_debug "  TransProxy test result: ${_tp_result}"
        if echo "$_tp_result" | grep -q '"IsTor":true'; then
            opsec_green "Transparent proxy VERIFIED — traffic routed through Tor"
        elif echo "$_tp_result" | grep -q '"IsTor":false'; then
            opsec_red "CRITICAL: Transparent proxy LEAKING — traffic NOT through Tor"
            _final_ok=false
        else
            opsec_yellow "WARNING: Transparent proxy test inconclusive (timeout or network error)"
            opsec_debug "  curl output: ${_tp_result}"
            # Don't fail — services are running, might just be slow
        fi
    fi
    if [ "$_final_ok" = "false" ]; then
        opsec_red "=========================================="
        opsec_red "  GHOST MODE ACTIVATION FAILED"
        opsec_red "  YOU ARE NOT PROTECTED"
        opsec_red "=========================================="
        opsec_red "  Tearing down partial activation..."
        # Clean teardown — don't leave zombie armed state
        /usr/local/bin/opsec-killswitch.sh off 2>/dev/null
        rm -f /etc/NetworkManager/conf.d/opsec-dns-lock.conf
        nmcli general reload 2>/dev/null || true
        chattr -i /etc/resolv.conf 2>/dev/null || true
        rm -f "$STATE_FILE"
        opsec_red "  Recovery: sudo opsec-mode off   (full cleanup)"
        opsec_red "=========================================="
        exit 1
    fi

    echo ""
    opsec_hdr "GHOST MODE: ACTIVE"
    echo ""
    opsec_dim "Profile:          ${profile}"
    opsec_dim "Kill switch:      armed (Tor/VPN only)"
    opsec_dim "DNS:              ${DNS_MODE:-tor}"
    opsec_dim "Exit blacklist:   ${blacklist}"
    opsec_dim "Circuit rotation: ${rotation}s"
    if ! is_cloud_level; then
        opsec_dim "MAC addresses:    randomized"
        opsec_dim "Hostname:         randomized"
    fi
    echo ""
    opsec_dim "Test: curl --socks5-hostname 127.0.0.1:${socks_port} https://ifconfig.me"
    opsec_dim "Off:  sudo opsec-mode off"
    echo ""

    # Run full preflight verification
    if [ -x /usr/local/bin/opsec-preflight.sh ]; then
        opsec_info "Running post-activation preflight..."
        /usr/local/bin/opsec-preflight.sh --full --enforce || {
            opsec_red "Preflight FAILED — kill switch stays armed (safe default)"
            opsec_red "Check failures: opsec-preflight"
            echo "[$(date -Is)] PREFLIGHT FAIL after mode_on" >> "$PREFLIGHT_LOG"
        }
    fi

    # ─── FINAL STATE SUMMARY ─────────────────────────────────────────────────
    opsec_debug "=========================================="
    opsec_debug "=== MODE ON FINAL STATE ==="
    opsec_debug "=========================================="
    opsec_debug "Hostname: $(hostname)"
    opsec_debug "DNS: $(cat /etc/resolv.conf 2>/dev/null | tr '\n' ' ')"
    opsec_debug "IPv6 disabled: $(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null)"
    opsec_debug "Tor status: $(systemctl is-active tor 2>&1)"
    opsec_debug "Tor bootstrap: $(grep 'Bootstrapped' /run/tor/notices.log 2>/dev/null | tail -1 || echo NONE)"
    opsec_debug "Tor TCP ports:"
    ss -tlnp 2>/dev/null | grep -E ":(9040|9050|5353)" >> "$DEBUG_LOG" 2>&1
    opsec_debug "Tor UDP ports:"
    ss -ulnp 2>/dev/null | grep -E ":5353" >> "$DEBUG_LOG" 2>&1
    opsec_debug "Kill switch chain rule count: $(iptables -L GP_FW --line-numbers 2>/dev/null | tail -n +3 | wc -l)"
    opsec_debug "NAT chain (GP_NAT) rule count: $(iptables -t nat -L GP_NAT --line-numbers 2>/dev/null | tail -n +3 | wc -l)"
    opsec_debug "State file: $([ -f "$STATE_FILE" ] && echo EXISTS || echo MISSING)"
    opsec_debug "Network interfaces:"
    ip -br addr 2>/dev/null >> "$DEBUG_LOG" 2>&1
    opsec_debug "Default route: $(ip route show default 2>/dev/null | head -1)"
    opsec_debug "=========================================="
    opsec_debug "=== MODE ON COMPLETE ==="
    opsec_debug "=========================================="

}

# ─── OFF ─────────────────────────────────────────────────────────────────────
mode_off() {
    # Block mode_off on paranoid levels
    if is_paranoid; then
        echo ""
        opsec_red "BLOCKED: Cannot disable ghost mode on paranoid level."
        opsec_red "Current level: ${DEPLOYMENT_LEVEL:-unknown} (LEVEL_TYPE=paranoid)"
        opsec_yellow "To lower security, change deployment level first:"
        opsec_dim "  sudo opsec-config.sh --level apply bare-metal-standard"
        opsec_dim "  sudo opsec-config.sh --level apply cloud-normal"
        echo ""
        exit 1
    fi

    echo ""
    opsec_hdr "DEACTIVATING GHOST MODE"
    opsec_debug "=== MODE OFF START ==="
    echo ""

    # Interrupt safety: if mode_off is killed mid-teardown (after kill switch is down),
    # re-arm the kill switch to avoid leaving the system exposed
    _mode_off_rearm() {
        echo ""
        opsec_red "INTERRUPTED — re-arming kill switch to prevent exposure"
        /usr/local/bin/opsec-killswitch.sh on 2>/dev/null
        opsec_debug "mode_off interrupted — kill switch re-armed"
        exit 1
    }
    trap '_mode_off_rearm' INT TERM

    # Signal any running mode_on bootstrap loop to stop immediately
    touch "$BOOTSTRAP_STOP"
    opsec_debug "  Stop signal sent to bootstrap loop"

    # Stop sentry if running
    opsec_debug "Stopping sentry..."
    if [ -x /usr/local/bin/opsec-sentry.sh ]; then
        opsec_info "Stopping sentry..."
        /usr/local/bin/opsec-sentry.sh stop 2>/dev/null || true
    fi

    # Stop traffic blending if running
    if [ -x /usr/local/bin/opsec-traffic-blend.sh ]; then
        /usr/local/bin/opsec-traffic-blend.sh stop 2>/dev/null || true
    fi

    # Clear break-glass if active
    rm -f "$BREAKGLASS_STATE"

    # 1. Disarm kill switch
    opsec_info "Disarming kill switch..."
    opsec_debug "Step 1: Disarming kill switch"
    /usr/local/bin/opsec-killswitch.sh off
    local ks_off_exit=$?
    opsec_debug "  Kill switch off exit code: ${ks_off_exit}"
    opsec_debug "  iptables OUTPUT after disarm:"
    iptables -L OUTPUT -n --line-numbers >> "$DEBUG_LOG" 2>&1
    opsec_debug "  NAT OUTPUT after disarm:"
    iptables -t nat -L OUTPUT -n --line-numbers >> "$DEBUG_LOG" 2>&1

    # 2. Restore DNS FIRST (before NM lock removal to prevent race)
    opsec_info "Restoring DNS to base privacy resolver..."
    opsec_debug "Step 2: Restoring DNS"
    opsec_debug "  resolv.conf before: $(cat /etc/resolv.conf 2>/dev/null | tr '\n' ' ')"
    chattr -i /etc/resolv.conf 2>/dev/null || true
    local base_dns="${BASE_DNS:-quad9}"
    case "$base_dns" in
        quad9)
            cat > /etc/resolv.conf << 'EOF'
nameserver 9.9.9.9
nameserver 149.112.112.112
EOF
            ;;
        cloudflare)
            cat > /etc/resolv.conf << 'EOF'
nameserver 1.1.1.1
nameserver 1.0.0.1
EOF
            ;;
        *)
            if [ -f "$RESOLV_BACKUP" ]; then
                cp "$RESOLV_BACKUP" /etc/resolv.conf
            else
                cat > /etc/resolv.conf << 'EOF'
nameserver 9.9.9.9
nameserver 149.112.112.112
EOF
            fi
            ;;
    esac
    # Secure-delete ISP DNS backup (contains pre-opsec resolver config)
    if [ -f "$RESOLV_BACKUP" ]; then
        shred -fuz -n 1 "$RESOLV_BACKUP" 2>/dev/null || rm -f "$RESOLV_BACKUP"
        opsec_debug "  resolv.conf.backup securely deleted"
    fi
    opsec_green "DNS restored to ${base_dns}"
    opsec_debug "  resolv.conf after: $(cat /etc/resolv.conf 2>/dev/null | tr '\n' ' ')"

    # NOW unlock NM DNS management (after DNS is written and settled)
    rm -f /etc/NetworkManager/conf.d/opsec-dns-lock.conf
    nmcli general reload 2>/dev/null || true
    opsec_debug "  NM dns=none lock removed (after DNS restore)"

    # 3. Restore stock torrc and stop Tor
    opsec_info "Restoring default Tor configuration..."
    opsec_debug "Step 3: Stopping Tor"
    opsec_debug "  Tor status before: $(systemctl is-active tor 2>&1)"
    if [ -f "$TORRC_DEFAULT" ]; then
        cp "$TORRC_DEFAULT" /etc/tor/torrc
        opsec_debug "  Restored torrc from ${TORRC_DEFAULT}"
    else
        opsec_debug "  WARNING: ${TORRC_DEFAULT} not found"
    fi
    systemctl stop tor 2>/dev/null || true
    opsec_debug "  Tor status after: $(systemctl is-active tor 2>&1)"
    opsec_green "Tor stopped, default torrc restored"

    # 4. Revert system hardening
    opsec_info "Reverting system hardening..."
    opsec_debug "Step 4: Reverting hardening"
    if [ -x /usr/local/bin/opsec-harden.sh ]; then
        /usr/local/bin/opsec-harden.sh revert 2>&1 | tee -a "$DEBUG_LOG" || true
    else
        opsec_debug "  opsec-harden.sh not found"
    fi

    # 5. Restore hostname
    opsec_info "Restoring hostname..."
    opsec_debug "Step 5: Restoring hostname"
    # Check both tmpfs (new) and disk (legacy) locations
    local _hostname_file=""
    if [ -f /run/opsec/hostname.original ]; then
        _hostname_file="/run/opsec/hostname.original"
    elif [ -f /etc/opsec/hostname.original ]; then
        _hostname_file="/etc/opsec/hostname.original"
    fi
    opsec_debug "hostname.original location: ${_hostname_file:-NONE}"
    opsec_debug "hostname.original content: $(cat "$_hostname_file" 2>/dev/null || echo MISSING)"
    opsec_debug "Current hostname: $(hostname)"
    if [ -n "$_hostname_file" ]; then
        local orig_hostname
        orig_hostname=$(cat "$_hostname_file")
        local cur_hostname
        cur_hostname=$(hostname)
        hostnamectl set-hostname "$orig_hostname" 2>/dev/null || {
            echo "$orig_hostname" > /etc/hostname
            hostname "$orig_hostname"
        }
        # Update /etc/hosts
        if [ "$cur_hostname" != "$orig_hostname" ]; then
            sed -i "s/$cur_hostname/$orig_hostname/g" /etc/hosts 2>/dev/null || true
        fi
        # Secure-delete from both locations
        shred -fuz -n 1 "$_hostname_file" 2>/dev/null || rm -f "$_hostname_file"
        rm -f /etc/opsec/hostname.original /run/opsec/hostname.original 2>/dev/null
        opsec_green "Hostname restored to: ${orig_hostname}"
        opsec_debug "Hostname restored: ${cur_hostname} -> ${orig_hostname}"
    else
        opsec_dim "No saved hostname — keeping current: $(hostname)"
        opsec_debug "WARNING: No hostname.original file found, hostname stays: $(hostname)"
    fi

    # 6. Remove NM MAC randomization config
    if [ -f "$NM_MAC_CONF" ]; then
        rm -f "$NM_MAC_CONF"
        nmcli general reload 2>/dev/null || true
        opsec_debug "Step 6: NM MAC config removed, NM reloaded"
        opsec_green "MAC randomization config removed"
    fi

    # 7. Disable boot services
    opsec_info "Disabling boot persistence..."
    opsec_debug "Step 7: Disabling boot services"
    systemctl disable opsec-mac-randomize.service 2>/dev/null || true
    systemctl disable opsec-hostname-randomize.service 2>/dev/null || true
    systemctl disable opsec-killswitch.service 2>/dev/null || true
    systemctl disable opsec-boot-advanced.service 2>/dev/null || true
    opsec_green "Boot services disabled"

    # 8. Remove state marker (keep boot marker if user wants it)
    rm -f "$STATE_FILE"
    opsec_green "State marker removed"
    opsec_debug "Step 8: State marker removed"

    # Teardown complete — clear the interrupt trap (no longer dangerous)
    trap - INT TERM

    echo ""
    opsec_hdr "GHOST MODE: OFF"
    echo ""
    opsec_dim "Base privacy mode restored"
    opsec_dim "Kill switch disarmed"
    opsec_dim "DNS using ${base_dns}"
    opsec_dim "Tor stopped"
    opsec_dim "Hostname restored"
    echo ""

    opsec_debug "--- MODE OFF FINAL STATE ---"
    opsec_debug "  Hostname: $(hostname)"
    opsec_debug "  DNS: $(cat /etc/resolv.conf 2>/dev/null | tr '\n' ' ')"
    opsec_debug "  Tor: $(systemctl is-active tor 2>&1)"
    opsec_debug "  iptables OUTPUT rules: $(iptables -L OUTPUT --line-numbers 2>/dev/null | tail -n +3 | wc -l)"
    opsec_debug "  State file exists: $([ -f "$STATE_FILE" ] && echo YES || echo NO)"
    opsec_debug "=== MODE OFF COMPLETE ==="

    # Re-apply base hardening (skip MAC re-randomization — already handled)
    opsec_debug "Re-applying base hardening..."
    BASE_MAC_RANDOMIZE=0 mode_base
}

# ─── BREAK-GLASS ──────────────────────────────────────────────────────────────
mode_breakglass() {
    if [ ! -f "$STATE_FILE" ]; then
        opsec_red "Break-glass requires ghost mode to be active"
        exit 1
    fi

    local expiry
    expiry=$(( $(date +%s) + BREAKGLASS_TIMEOUT ))

    echo ""
    opsec_hdr "BREAK-GLASS EMERGENCY OVERRIDE"
    echo ""
    opsec_red "WARNING: Temporarily disabling kill switch"
    opsec_red "Direct internet access will be available"
    opsec_dim "Auto-expires in $((BREAKGLASS_TIMEOUT / 60)) minutes"
    echo ""

    # Drop kill switch only
    /usr/local/bin/opsec-killswitch.sh off

    # Write state file with expiry timestamp
    echo "$expiry" > "$BREAKGLASS_STATE"

    # Log the event
    echo "[$(date -Is)] BREAKGLASS ACTIVATED — expires $(date -d @${expiry} -Is) — timeout ${BREAKGLASS_TIMEOUT}s" >> "$PREFLIGHT_LOG"

    opsec_yellow "Kill switch DISARMED — all other OPSEC settings preserved"
    opsec_dim "DNS, MAC, hostname remain randomized"
    echo ""
    opsec_dim "End early:    sudo opsec-mode breakglass-off"
    opsec_dim "Auto-rearm:   $(date -d @${expiry} '+%H:%M:%S')"
    echo ""

    # Schedule auto-rearm via at or background process
    (
        exec 9>&-   # Release lock fd — don't hold it during sleep
        sleep "$BREAKGLASS_TIMEOUT"
        if [ -f "$BREAKGLASS_STATE" ]; then
            /usr/local/bin/opsec-killswitch.sh on
            rm -f "$BREAKGLASS_STATE"
            echo "[$(date -Is)] BREAKGLASS EXPIRED — kill switch re-armed" >> "$PREFLIGHT_LOG"
            # Re-run preflight
            if [ -x /usr/local/bin/opsec-preflight.sh ]; then
                /usr/local/bin/opsec-preflight.sh --full --enforce >> "$PREFLIGHT_LOG" 2>&1 || true
            fi
        fi
    ) &
    disown
}

mode_breakglass_off() {
    if [ ! -f "$BREAKGLASS_STATE" ]; then
        opsec_yellow "Break-glass is not active"
        exit 0
    fi

    echo ""
    opsec_hdr "ENDING BREAK-GLASS"
    echo ""

    # Re-arm kill switch
    /usr/local/bin/opsec-killswitch.sh on
    rm -f "$BREAKGLASS_STATE"

    echo "[$(date -Is)] BREAKGLASS ENDED MANUALLY — kill switch re-armed" >> "$PREFLIGHT_LOG"

    opsec_green "Kill switch re-armed"
    opsec_green "Break-glass ended"
    echo ""

    # Re-run preflight
    if [ -x /usr/local/bin/opsec-preflight.sh ]; then
        opsec_info "Running preflight verification..."
        /usr/local/bin/opsec-preflight.sh --full --enforce || {
            opsec_red "Preflight FAILED — check: opsec-preflight"
        }
    fi
}

# ─── STATUS ──────────────────────────────────────────────────────────────────
mode_status() {
    local profile="${PROFILE_NAME:-default}"
    local level="${DEPLOYMENT_LEVEL:-bare-metal-standard}"
    local level_type="$(get_level_type)"

    echo ""
    opsec_hdr "OPSEC STATUS"
    echo ""

    # Mode state
    if [ -f "$STATE_FILE" ]; then
        opsec_green "Mode: GHOST (active)"
    else
        opsec_yellow "Mode: BASE PRIVACY"
    fi

    # Level info
    opsec_info "Level: ${level} (${level_type})"
    opsec_info "Profile: ${profile}"

    # Break-glass warning
    if [ -f "$BREAKGLASS_STATE" ]; then
        local bg_expiry bg_remaining
        bg_expiry=$(cat "$BREAKGLASS_STATE" 2>/dev/null)
        bg_remaining=$(( bg_expiry - $(date +%s) ))
        if [ "$bg_remaining" -gt 0 ]; then
            opsec_red "BREAK-GLASS ACTIVE — kill switch DOWN — ${bg_remaining}s remaining"
        fi
    fi
    echo ""

    # Boot-into-advanced
    if [ -f "$BOOT_MARKER" ]; then
        opsec_green "Boot Mode: PERSISTENT (will activate on reboot)"
    else
        opsec_dim "Boot Mode: standard (manual activation only)"
    fi
    echo ""

    # ─── Tor ───
    opsec_cyan "Tor Configuration"
    if systemctl is-active tor >/dev/null 2>&1; then
        opsec_green "  Status: Running"
        if grep -q "ExcludeExitNodes" /etc/tor/torrc 2>/dev/null; then
            local blacklist_display
            blacklist_display=$(grep "ExcludeExitNodes" /etc/tor/torrc | sed 's/ExcludeExitNodes //' | tr -d '{}')
            opsec_green "  Torrc: Hardened"
            opsec_dim "  Blacklist: ${blacklist_display}"
        else
            opsec_yellow "  Torrc: Default"
        fi
        local rotation_val
        rotation_val=$(grep "MaxCircuitDirtiness" /etc/tor/torrc 2>/dev/null | awk '{print $2}')
        [ -n "$rotation_val" ] && opsec_dim "  Circuit rotation: ${rotation_val}s"

        local isolation_val
        isolation_val=$(grep "IsolateDestAddr" /etc/tor/torrc 2>/dev/null | head -1)
        [ -n "$isolation_val" ] && opsec_green "  Stream isolation: ON" || opsec_dim "  Stream isolation: off"

        local padding_val
        padding_val=$(grep "ConnectionPadding" /etc/tor/torrc 2>/dev/null | awk '{print $2}')
        [ "$padding_val" = "1" ] && opsec_green "  Traffic padding: ON" || opsec_dim "  Traffic padding: off"
    else
        opsec_yellow "  Status: Stopped"
    fi
    echo ""

    # ─── IPv6 ───
    local ipv6_all
    ipv6_all=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo "0")
    [ "$ipv6_all" = "1" ] && opsec_green "IPv6: Disabled" || opsec_red "IPv6: ENABLED (risk)"

    # ─── DNS ───
    local dns_server
    dns_server=$(awk '/^nameserver/ {print $2; exit}' /etc/resolv.conf 2>/dev/null)
    if [ "$dns_server" = "127.0.0.1" ]; then
        opsec_green "DNS: Tor DNS (127.0.0.1)"
        if lsattr /etc/resolv.conf 2>/dev/null | grep -q 'i'; then
            opsec_green "DNS Lock: Immutable (chattr +i)"
        else
            opsec_yellow "DNS Lock: Not locked"
        fi
    elif echo "$dns_server" | grep -qE '^(9\.9\.9\.9|149\.112|1\.1\.1\.1|1\.0\.0\.1)$'; then
        opsec_green "DNS: Privacy resolver (${dns_server})"
    else
        opsec_yellow "DNS: ${dns_server}"
    fi

    # ─── Kill switch ───
    if [ -f "$BREAKGLASS_STATE" ]; then
        opsec_red "Kill Switch: DISARMED (BREAK-GLASS)"
    elif iptables -L GP_FW >/dev/null 2>&1; then
        opsec_green "Kill Switch: ARMED"
    else
        opsec_yellow "Kill Switch: Off"
    fi

    # ─── VPN ───
    local vpn_if
    vpn_if=$(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep -E '^(tun|wg)' | head -1)
    if [ -n "$vpn_if" ]; then
        local vpn_ip
        vpn_ip=$(ip -4 addr show "$vpn_if" 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1)
        opsec_green "VPN: Active (${vpn_if}: ${vpn_ip})"
    else
        opsec_yellow "VPN: Not connected"
    fi

    # ─── MAC ───
    if ! is_cloud_level; then
        local primary_if
        primary_if=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -1)
        if [ -n "$primary_if" ]; then
            local cur_mac first_octet first_dec
            cur_mac=$(ip link show "$primary_if" 2>/dev/null | awk '/ether/ {print $2}')
            first_octet=$(echo "$cur_mac" | cut -d: -f1)
            first_dec=$((16#${first_octet}))
            if (( first_dec & 2 )); then
                opsec_green "MAC: Randomized (${primary_if}: ${cur_mac})"
            else
                opsec_yellow "MAC: Hardware (${primary_if}: ${cur_mac})"
            fi
        fi
    fi
    echo ""

    # ─── Hardening status ───
    opsec_cyan "System Hardening"
    # Core dumps
    local core_pattern
    core_pattern=$(sysctl -n kernel.core_pattern 2>/dev/null)
    [[ "$core_pattern" == *"/bin/false"* ]] && opsec_green "  Core dumps: Disabled" || opsec_dim "  Core dumps: enabled"
    # Swap
    local swap_total
    swap_total=$(swapon --show=SIZE --noheadings 2>/dev/null | head -1)
    [ -z "$swap_total" ] && opsec_green "  Swap: Disabled" || opsec_dim "  Swap: active (${swap_total})"
    echo ""

    # ─── Hostname ───
    opsec_info "Hostname: $(hostname)"

    # ─── Boot services ───
    echo ""
    opsec_cyan "Boot Services"
    for svc in opsec-boot-advanced opsec-mac-randomize opsec-hostname-randomize opsec-killswitch; do
        if systemctl is-enabled "$svc" 2>/dev/null | grep -q enabled; then
            opsec_green "  ${svc}: enabled"
        else
            opsec_dim "  ${svc}: disabled"
        fi
    done

    # ─── Preflight ───
    if [ -x /usr/local/bin/opsec-preflight.sh ]; then
        echo ""
        opsec_cyan "Preflight Score"
        /usr/local/bin/opsec-preflight.sh --score 2>/dev/null || opsec_dim "  Preflight not available"
    fi

    echo ""
}

# ─── DIAGNOSTIC ──────────────────────────────────────────────────────────────
mode_diag() {
    echo "=== OPSEC DIAGNOSTIC ==="
    echo "Time: $(date -Is)"
    echo ""
    echo "--- State ---"
    echo "Ghost mode: $([ -f "$STATE_FILE" ] && echo ACTIVE || echo INACTIVE)"
    echo "Breakglass: $([ -f "$BREAKGLASS_STATE" ] && echo ACTIVE || echo INACTIVE)"
    echo ""
    echo "--- Tor ---"
    echo "Service: $(systemctl is-active tor 2>&1)"
    echo "TCP ports: $(ss -tlnp 2>/dev/null | grep -E ':(9040|9050|5353)' || echo NONE)"
    echo "UDP ports: $(ss -ulnp 2>/dev/null | grep -E ':5353' || echo NONE)"
    echo "Bootstrap: $(grep 'Bootstrapped' /run/tor/notices.log 2>/dev/null | tail -1 || echo NONE)"
    echo "Last 5 log:"
    tail -5 /run/tor/notices.log 2>/dev/null || echo "  (no log)"
    echo ""
    echo "--- Kill Switch ---"
    echo "Filter: $(iptables -L GP_FW >/dev/null 2>&1 && echo ARMED || echo OFF)"
    local _diag_nat_count=0
    if iptables -t nat -L GP_NAT >/dev/null 2>&1; then
        _diag_nat_count=$(iptables -t nat -L GP_NAT --line-numbers 2>/dev/null | tail -n +3 | wc -l)
        echo "NAT chain: ARMED (${_diag_nat_count} rules)"
    else
        echo "NAT chain: OFF"
        local _diag_out_nat
        _diag_out_nat=$(iptables -t nat -L OUTPUT --line-numbers 2>/dev/null | tail -n +3 | wc -l)
        [ "$_diag_out_nat" -gt 0 ] && echo "NAT OUTPUT fallback: ${_diag_out_nat} rules"
    fi
    echo ""
    echo "--- DNS ---"
    echo "Resolver: $(grep nameserver /etc/resolv.conf 2>/dev/null | tr '\n' ' ')"
    echo "Locked: $(lsattr /etc/resolv.conf 2>/dev/null | grep -q 'i' && echo YES || echo NO)"
    echo "NM dns=none: $([ -f /etc/NetworkManager/conf.d/opsec-dns-lock.conf ] && echo YES || echo NO)"
    echo ""
    echo "--- Network ---"
    echo "Route: $(ip route show default 2>/dev/null | head -1)"
    echo ""
    echo "--- Quick Test ---"
    echo -n "SOCKS: "
    curl -s --max-time 5 --socks5-hostname 127.0.0.1:9050 https://check.torproject.org/api/ip 2>/dev/null || echo "FAILED"
    echo ""
    echo -n "TransPort: "
    curl -s --max-time 10 https://check.torproject.org/api/ip 2>/dev/null || echo "FAILED (transparent proxy not working)"
}

# ─── APPLY FLAGS ─────────────────────────────────────────────────────────────
VERBOSE="$_VERBOSE_EARLY"
if [ "$VERBOSE" = "true" ]; then
    echo -e "\033[38;5;196m[!] VERBOSE: debug output may contain sensitive identifiers\033[0m"
fi

# ─── MAIN ────────────────────────────────────────────────────────────────────
case "${_CMD_EARLY:-}" in
    on)              mode_on ;;
    off)             mode_off ;;
    status)          mode_status ;;
    diag)            mode_diag ;;
    breakglass)      mode_breakglass ;;
    breakglass-off)  mode_breakglass_off ;;
    *)
        echo "Usage: sudo opsec-mode [--verbose] on|off|status|diag|breakglass|breakglass-off"
        echo ""
        echo "  on             — Activate ghost mode (Tor, kill switch, full lockdown)"
        echo "  off            — Deactivate ghost mode (returns to base privacy)"
        echo "  status         — Show current OPSEC subsystem status"
        echo "  diag           — Quick diagnostic of all subsystems"
        echo "  breakglass     — Emergency: temporarily drop kill switch"
        echo "  breakglass-off — End break-glass, re-arm kill switch"
        echo ""
        echo "  --verbose, -v  — Show debug output in real-time"
        exit 1
        ;;
esac
