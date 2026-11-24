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
ACTIVATING_FILE="/run/opsec/activation-in-progress"
FAILED_FILE="/run/opsec/activation-failed"
UNSAFE_FILE="/run/opsec/activation-unsafe"
BROWSER_UID_FILE="/run/opsec/browser.uid"
IDENTITY_SERVICE_STATE="/run/opsec/identity-services.active"
BOOT_MARKER="/etc/opsec/boot-advanced.enabled"
TORRC_DEFAULT="/etc/tor/torrc-default"
TOR_LOG="${TOR_LOG_FILE:-/var/log/tor/notices.log}"
RESOLV_BACKUP="/etc/resolv.conf.backup"
OPSEC_LIB="/usr/local/lib/opsec/opsec-lib.sh"
BREAKGLASS_STATE="/var/run/opsec-breakglass.active"
BREAKGLASS_TIMEOUT="${BREAKGLASS_TIMEOUT:-900}"  # 15 minutes default
PREFLIGHT_LOG="/run/opsec/preflight.log"
DEBUG_LOG="/run/opsec/debug.log"
BOOTSTRAP_STOP="/var/run/opsec-bootstrap-stop"
ACTIVATION_WATCHDOG_UNIT="opsec-activation-rollback"
ACTIVATION_WATCHDOG_STATE="/run/opsec/activation-watchdog.state"
ACTIVATION_WATCHDOG_SCRIPT="/run/opsec/activation-watchdog.sh"
ACTIVATION_ROLLBACK_SECONDS="${OPSEC_ACTIVATION_ROLLBACK_SECONDS:-300}"
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

arm_activation_watchdog() {
    local activation_id start_time tmp
    command -v systemd-run >/dev/null 2>&1 || return 1
    [[ "$ACTIVATION_ROLLBACK_SECONDS" =~ ^[0-9]+$ ]] && [ "$ACTIVATION_ROLLBACK_SECONDS" -ge 60 ] || return 1
    activation_id=$(cat /proc/sys/kernel/random/uuid) || return 1
    start_time=$(awk '{print $22}' "/proc/$$/stat") || return 1
    tmp=$(mktemp /run/opsec/.activation-watchdog.XXXXXX) || return 1
    printf '%s %s %s\n' "$activation_id" "$$" "$start_time" > "$tmp"
    chmod 0600 "$tmp"
    mv -f "$tmp" "$ACTIVATION_WATCHDOG_STATE"
    cat > "$ACTIVATION_WATCHDOG_SCRIPT" <<'WATCHDOG'
#!/bin/bash
set -u
state=/run/opsec/activation-watchdog.state
[ -f "$state" ] && [ ! -L "$state" ] && [ "$(stat -c '%u:%g:%a' "$state" 2>/dev/null)" = "0:0:600" ] || exit 1
read -r activation_id activation_pid activation_start < "$state" || exit 1
[[ "$activation_id" =~ ^[0-9a-f-]{36}$ && "$activation_pid" =~ ^[0-9]+$ && "$activation_start" =~ ^[0-9]+$ ]] || exit 1
if [ -f /var/run/opsec-advanced.enabled ] && [ ! -f /run/opsec/activation-in-progress ]; then
    rm -f "$state" /run/opsec/activation-watchdog.sh
    exit 0
fi
if [ -r "/proc/$activation_pid/stat" ] && [ "$(awk '{print $22}' "/proc/$activation_pid/stat" 2>/dev/null)" = "$activation_start" ]; then
    kill -TERM "$activation_pid" 2>/dev/null || true
    for _ in $(seq 1 20); do
        kill -0 "$activation_pid" 2>/dev/null || break
        sleep 0.25
    done
    kill -KILL "$activation_pid" 2>/dev/null || true
fi
touch /var/run/opsec-bootstrap-stop
OPSEC_TIMEOUT_ROLLBACK=1 /usr/local/bin/opsec-mode off || {
    /usr/local/bin/opsec-killswitch.sh strict-off >/dev/null 2>&1 || true
    exit 1
}
rm -f "$state" /run/opsec/activation-watchdog.sh
WATCHDOG
    chmod 0700 "$ACTIVATION_WATCHDOG_SCRIPT"
    systemctl stop "${ACTIVATION_WATCHDOG_UNIT}.timer" "${ACTIVATION_WATCHDOG_UNIT}.service" >/dev/null 2>&1 || true
    systemctl reset-failed "${ACTIVATION_WATCHDOG_UNIT}.service" >/dev/null 2>&1 || true
    systemd-run --quiet --unit="$ACTIVATION_WATCHDOG_UNIT" \
        --on-active="${ACTIVATION_ROLLBACK_SECONDS}s" --timer-property=AccuracySec=1s \
        /bin/bash "$ACTIVATION_WATCHDOG_SCRIPT" || return 1
    systemctl is-active --quiet "${ACTIVATION_WATCHDOG_UNIT}.timer" || return 1
    opsec_green "Automatic activation rollback armed (${ACTIVATION_ROLLBACK_SECONDS}s)"
}

cancel_activation_watchdog() {
    [ "${OPSEC_TIMEOUT_ROLLBACK:-0}" = "1" ] && return 0
    systemctl stop "${ACTIVATION_WATCHDOG_UNIT}.timer" "${ACTIVATION_WATCHDOG_UNIT}.service" >/dev/null 2>&1 || true
    systemctl reset-failed "${ACTIVATION_WATCHDOG_UNIT}.service" >/dev/null 2>&1 || true
    rm -f "$ACTIVATION_WATCHDOG_STATE" "$ACTIVATION_WATCHDOG_SCRIPT"
}

TOR_SERVICE=$(opsec_find_tor_service 2>/dev/null || echo tor.service)

tor_bootstrap_line() {
    journalctl -u "$TOR_SERVICE" -b --no-pager -o cat 2>/dev/null | grep 'Bootstrapped' | tail -1 || true
}

tor_tcp_loopback_listener() {
    ss -H -ltn 2>/dev/null | awk -v port="$1" '$4 == "127.0.0.1:" port {found=1} END {exit !found}'
}

tor_udp_loopback_listener() {
    ss -H -lun 2>/dev/null | awk -v port="$1" '$4 == "127.0.0.1:" port {found=1} END {exit !found}'
}

verify_tor_service_identity() {
    local expected_user expected_uid pid pid_again process_uid process_exe cgroup attempt
    expected_user=$(systemctl show -p User --value "$TOR_SERVICE" 2>/dev/null || true)
    [ -n "$expected_user" ] || expected_user=$(awk '$1 == "User" {print $2; exit}' /etc/tor/torrc 2>/dev/null)
    expected_uid=$(id -u "$expected_user" 2>/dev/null || true)
    [[ "$expected_uid" =~ ^[0-9]+$ ]] || return 1
    for attempt in $(seq 1 30); do
        if systemctl is-active --quiet "$TOR_SERVICE"; then
            pid=$(systemctl show -p MainPID --value "$TOR_SERVICE" 2>/dev/null || true)
            if [[ "$pid" =~ ^[1-9][0-9]*$ ]] && [ -r "/proc/$pid/stat" ]; then
                process_uid=$(stat -c %u "/proc/$pid" 2>/dev/null || true)
                process_exe=$(readlink -f "/proc/$pid/exe" 2>/dev/null || true)
                cgroup=$(cat "/proc/$pid/cgroup" 2>/dev/null || true)
                sleep 0.25
                pid_again=$(systemctl show -p MainPID --value "$TOR_SERVICE" 2>/dev/null || true)
                if [ "$pid" = "$pid_again" ] && [ "$process_uid" = "$expected_uid" ] && \
                   [ "$process_exe" = /usr/bin/tor ] && grep -Fq "/${TOR_SERVICE}" <<<"$cgroup"; then
                    opsec_debug "Verified Tor identity: service=$TOR_SERVICE pid=$pid uid=$process_uid exe=$process_exe"
                    return 0
                fi
            fi
        fi
        sleep 0.25
    done
    opsec_debug "Tor identity verification exhausted restart window: service=$(systemctl is-active "$TOR_SERVICE" 2>&1) pid=$(systemctl show -p MainPID --value "$TOR_SERVICE" 2>&1)"
    return 1
}

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

stop_identity_apps() {
    opsec_info "Stopping identity-bearing applications..."
    if [ ! -f "$IDENTITY_SERVICE_STATE" ]; then
        : > "$IDENTITY_SERVICE_STATE"
        chmod 0600 "$IDENTITY_SERVICE_STATE"
        for service in tailscaled.service avahi-daemon.service; do
            systemctl is-active "$service" >/dev/null 2>&1 && echo "$service" >> "$IDENTITY_SERVICE_STATE"
        done
    fi
    for service in tailscaled.service avahi-daemon.service; do
        systemctl stop "$service" 2>/dev/null || true
    done
    resolve_desktop_user || return 1
    user_systemctl stop opsec-browser.service >/dev/null 2>&1 || true
    runuser -u "$DESKTOP_USER" -- flatpak kill org.chromium.Chromium >/dev/null 2>&1 || true
    for process_name in spotify Discord discord kdeconnectd; do
        pkill -TERM -u "$DESKTOP_UID" -x "$process_name" 2>/dev/null || true
    done
    while IFS= read -r proc; do
        local pid exe
        pid="${proc#/proc/}"; pid="${pid%/exe}"
        [ "$(stat -c %u "/proc/$pid" 2>/dev/null)" = "$DESKTOP_UID" ] || continue
        exe=$(readlink -f "$proc" 2>/dev/null || true)
        case "$exe" in
            /opt/brave-bin/brave|/opt/brave.com/brave/brave|/usr/lib/firefox/firefox|/usr/lib/chromium/chromium|\
            /home/*/.local/opt/tor-browser/app/Browser/firefox|/home/*/.local/opt/tor-browser/app/Browser/firefox.real|\
            /home/*/.local/share/torbrowser/tbb/x86_64/tor-browser/Browser/firefox|\
            /home/*/.local/share/torbrowser/tbb/x86_64/tor-browser/Browser/firefox.real)
                kill -TERM "$pid" 2>/dev/null || true ;;
        esac
    done < <(find /proc -maxdepth 2 -path '/proc/[0-9]*/exe' -print 2>/dev/null)
    sleep 2
    for process_name in spotify Discord discord kdeconnectd; do
        pkill -KILL -u "$DESKTOP_UID" -x "$process_name" 2>/dev/null || true
    done
    while IFS= read -r proc; do
        local pid exe
        pid="${proc#/proc/}"; pid="${pid%/exe}"
        [ "$(stat -c %u "/proc/$pid" 2>/dev/null)" = "$DESKTOP_UID" ] || continue
        exe=$(readlink -f "$proc" 2>/dev/null || true)
        case "$exe" in
            /opt/brave-bin/brave|/opt/brave.com/brave/brave|/usr/lib/firefox/firefox|/usr/lib/chromium/chromium|\
            /home/*/.local/opt/tor-browser/app/Browser/firefox|/home/*/.local/opt/tor-browser/app/Browser/firefox.real|\
            /home/*/.local/share/torbrowser/tbb/x86_64/tor-browser/Browser/firefox|\
            /home/*/.local/share/torbrowser/tbb/x86_64/tor-browser/Browser/firefox.real)
                kill -KILL "$pid" 2>/dev/null || true ;;
        esac
    done < <(find /proc -maxdepth 2 -path '/proc/[0-9]*/exe' -print 2>/dev/null)
    if pgrep -u "$DESKTOP_UID" -x brave >/dev/null 2>&1 || \
       pgrep -u "$DESKTOP_UID" -x firefox >/dev/null 2>&1 || \
       pgrep -u "$DESKTOP_UID" -x chrome >/dev/null 2>&1 || \
       pgrep -u "$DESKTOP_UID" -x chromium >/dev/null 2>&1; then
        opsec_red "A browser process could not be safely identified and stopped"
        return 1
    fi
    for service in tailscaled.service avahi-daemon.service; do
        if systemctl is-active "$service" >/dev/null 2>&1; then
            opsec_red "$service could not be stopped"
            return 1
        fi
    done
    for process_name in spotify Discord discord kdeconnectd; do
        if pgrep -u "$DESKTOP_UID" -x "$process_name" >/dev/null 2>&1; then
            opsec_red "$process_name could not be stopped"
            return 1
        fi
    done
    opsec_green "Identity-bearing applications stopped"
}

resolve_desktop_user() {
    local candidate="${OPSEC_DESKTOP_USER:-}"
    if [ -z "$candidate" ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then
        candidate="$SUDO_USER"
    fi
    if [ -z "$candidate" ] && [[ "${PKEXEC_UID:-}" =~ ^[0-9]+$ ]]; then
        candidate=$(getent passwd "$PKEXEC_UID" | cut -d: -f1)
    fi
    if [ -z "$candidate" ]; then
        candidate=$(loginctl list-sessions --no-legend 2>/dev/null | awk '$4=="seat0" {print $3; exit}')
    fi
    [ -n "$candidate" ] || { opsec_red "No desktop user could be resolved"; return 1; }
    DESKTOP_UID=$(id -u "$candidate" 2>/dev/null) || return 1
    [ "$DESKTOP_UID" -ge 1000 ] || { opsec_red "Refusing desktop UID $DESKTOP_UID"; return 1; }
    DESKTOP_USER="$candidate"
    DESKTOP_HOME=$(getent passwd "$DESKTOP_UID" | cut -d: -f6)
    [ -d "$DESKTOP_HOME" ] && [ "$(stat -c %u "$DESKTOP_HOME")" = "$DESKTOP_UID" ] || return 1
    printf '%s\n' "$DESKTOP_UID" > "$BROWSER_UID_FILE"
    chmod 0600 "$BROWSER_UID_FILE"
}

user_systemctl() {
    systemctl --user --machine="${DESKTOP_USER}@.host" "$@"
}

mark_failed_closed() {
    local reason="$1" tmp contained=false
    rm -f "$STATE_FILE" "$ACTIVATING_FILE"
    rm -f "$FAILED_FILE" "$UNSAFE_FILE"
    if /usr/local/bin/opsec-killswitch.sh strict-on >/dev/null 2>&1 &&
       /usr/local/bin/opsec-killswitch.sh strict-status >/dev/null 2>&1; then
        contained=true
    elif /usr/local/bin/opsec-killswitch.sh emergency-on >/dev/null 2>&1 &&
         /usr/local/bin/opsec-killswitch.sh emergency-status >/dev/null 2>&1; then
        contained=true
    fi
    if "$contained"; then
        tmp=$(mktemp /run/opsec/.activation-failed.XXXXXX)
        printf '%s\n' "$reason" > "$tmp"
        chmod 0600 "$tmp"
        mv -f "$tmp" "$FAILED_FILE"
        opsec_red "GHOST MODE FAILED-CLOSED: $reason"
        opsec_red "Network containment verified. Recover with: sudo opsec-mode off"
    else
        tmp=$(mktemp /run/opsec/.activation-unsafe.XXXXXX)
        printf '%s\n' "$reason" > "$tmp"
        chmod 0600 "$tmp"
        mv -f "$tmp" "$UNSAFE_FILE"
        opsec_red "GHOST MODE ACTIVATION FAILED: $reason"
        opsec_red "CRITICAL: network containment could not be verified; traffic may be exposed"
    fi
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
    local rotation="${TOR_CIRCUIT_ROTATION:-}"
    local blacklist="${TOR_BLACKLIST:-}"
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
    rm -f "$FAILED_FILE" "$UNSAFE_FILE"
    touch "$ACTIVATING_FILE"
    chmod 0600 "$ACTIVATING_FILE"
    if ! arm_activation_watchdog; then
        rm -f "$ACTIVATING_FILE" "$ACTIVATION_WATCHDOG_STATE" "$ACTIVATION_WATCHDOG_SCRIPT"
        opsec_red "Activation refused: automatic rollback could not be armed"
        return 1
    fi

    # 0. Strict mode is fail-closed: stop identity-bearing apps, then permit only Tor UID + DHCP.
    if ! stop_identity_apps; then
        mark_failed_closed "identity-bearing applications could not be stopped"
        return 1
    fi
    if ! /usr/local/bin/opsec-killswitch.sh strict-on; then
        mark_failed_closed "strict no-leak firewall could not be verified"
        return 1
    fi
    opsec_debug "Strict nftables policy active — only Tor UID and DHCP egress allowed"
    if ! /usr/local/bin/opsec-browser-policy.sh recover "$DESKTOP_UID" || \
       ! /usr/local/bin/opsec-browser-policy.sh apply "$DESKTOP_UID"; then
        mark_failed_closed "dirty-browser network policy could not be verified"
        return 1
    fi
    opsec_green "Persistent-profile browsers blocked; disposable OPSEC Browser enabled"

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

    # 4. Activation-in-progress was marked before the first mutation so the
    # independent timeout service can always perform a complete rollback.
    opsec_debug "Step 4: Activation-in-progress marker already set"

    # 5. Deploy hardened torrc + clear stale Tor state + restart Tor
    opsec_info "Step 5/10: Deploying hardened Tor configuration..."
    opsec_debug "Step 5: Deploying torrc (HAS_LIB=${_HAS_LIB})"

    # Clear Tor caches only if TOR_CLEAR_CACHE=1 (preserving guard state)
    opsec_debug "  Cache clear: TOR_CLEAR_CACHE=${TOR_CLEAR_CACHE:-0}"
    systemctl stop "$TOR_SERVICE" 2>/dev/null || true
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

    opsec_debug "Restarting Tor service..."
    if ! systemctl restart "$TOR_SERVICE" >> "$DEBUG_LOG" 2>&1; then
        opsec_debug "systemctl restart $TOR_SERVICE failed"
        mark_failed_closed "Tor service could not be restarted"
        return 1
    fi
    opsec_debug "systemctl restart $TOR_SERVICE succeeded"
    if ! verify_tor_service_identity; then
        mark_failed_closed "Tor service process identity could not be verified"
        return 1
    fi
    opsec_debug "Tor service status: $(systemctl is-active "$TOR_SERVICE" 2>&1)"

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
    # Force lock DNS regardless while activation is in progress.
    chattr +i /etc/resolv.conf 2>/dev/null || true
    # Verify immutable flag actually took hold
    if ! lsattr /etc/resolv.conf 2>/dev/null | grep -q 'i'; then
        opsec_red "chattr +i failed on resolv.conf — refusing activation"
        opsec_debug "  CRITICAL: chattr +i verification FAILED — filesystem may not support extended attributes"
        mark_failed_closed "effective DNS resolver could not be locked"
        return 1
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
        boot_pct=$(tor_bootstrap_line | grep -oP '\d+(?=%)' || true)
        if [ "$boot_pct" = "100" ] && tor_tcp_loopback_listener "$socks_port"; then
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
            journalctl -u "$TOR_SERVICE" -b --no-pager -n 10 >> "$DEBUG_LOG" 2>&1
        fi
    done
    [ -n "${TAIL_PID:-}" ] && kill "$TAIL_PID" 2>/dev/null

    if [ "$tor_ready" != "true" ]; then
        mark_failed_closed "Tor did not fully bootstrap within 180 seconds"
        return 1
    fi

    # 8. Add NAT transparent proxy AFTER Tor is ready
    opsec_info "Step 8/10: Arming NAT transparent proxy..."
    opsec_debug "Step 8: NAT proxy (tor_ready=${tor_ready})"
    local ks_exit
    if [ "$tor_ready" = "true" ]; then
        : # strict nftables policy already provides transparent TCP/DNS redirection
        ks_exit=$?
        opsec_debug "  NAT proxy armed with Tor at 100% (exit=${ks_exit})"
    else
        # If mode_off aborted us, don't arm NAT — teardown is already running
        if [ ! -f "$STATE_FILE" ] && [ ! -f "$ACTIVATING_FILE" ]; then
            opsec_yellow "Bootstrap aborted by mode_off — skipping NAT arm"
            opsec_debug "  Skipping NAT — state file gone (mode_off in progress)"
            return 0
        fi
        mark_failed_closed "Tor was not ready for transparent proxying"
        return 1
    fi
    opsec_debug "  Kill switch exit code: ${ks_exit}"
    # Flush conntrack so stale entries don't bypass NAT redirect
    conntrack -F 2>/dev/null && opsec_debug "  conntrack table flushed" || opsec_debug "  conntrack flush skipped (not available)"
    opsec_debug "  Strict nftables policy: $(/usr/local/bin/opsec-killswitch.sh strict-status >/dev/null 2>&1 && echo VERIFIED || echo UNVERIFIED)"
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

    # 10. Start IOC-U sentry if available
    opsec_info "Step 10/10: Starting sentry..."
    opsec_debug "Step 10: Sentry and optional traffic blend"
    if [ -x /usr/local/bin/opsec-sentry.sh ]; then
        /usr/local/bin/opsec-sentry.sh start 2>/dev/null && opsec_green "IOC-U sentry started" || opsec_yellow "Sentry start failed"
    else
        opsec_dim "Sentry not installed — skipping"
    fi
    if [ "${TRAFFIC_BLEND_ENABLED:-0}" = "1" ] && [ -x /usr/local/bin/opsec-traffic-blend.sh ]; then
        /usr/local/bin/opsec-traffic-blend.sh start 2>/dev/null && opsec_green "Traffic blending started" || opsec_dim "Traffic blend not started"
    fi

    # ─── EXIT GATE: Verify all subsystems before declaring active ────────────
    _final_ok=true
    if ! systemctl is-active "$TOR_SERVICE" >/dev/null 2>&1; then
        opsec_red "CRITICAL: Tor is NOT running"; _final_ok=false
    fi
    if ! /usr/local/bin/opsec-killswitch.sh strict-status >/dev/null 2>&1; then
        opsec_red "CRITICAL: Kill switch could not be verified"; _final_ok=false
    fi
    if ! tor_tcp_loopback_listener "$socks_port"; then
        opsec_red "CRITICAL: SOCKS port ${socks_port} NOT listening"; _final_ok=false
    fi
    # Check TransPort (9040) and DNSPort (5353) are listening
    if ! tor_tcp_loopback_listener 9040; then
        opsec_red "CRITICAL: TransPort 9040 NOT listening"; _final_ok=false
    fi
    if ! tor_udp_loopback_listener 5353; then
        opsec_red "CRITICAL: DNSPort 5353 NOT listening (UDP)"; _final_ok=false
    fi
    # Live connectivity test — actually verify traffic flows through Tor
    if [ "$_final_ok" = "true" ]; then
        opsec_info "Testing transparent proxy connectivity..."
        local _tp_result _socks_result
        _tp_result=$(env -u http_proxy -u https_proxy -u all_proxy -u no_proxy \
            -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u NO_PROXY \
            curl -4 --fail --silent --show-error --connect-timeout 10 --max-time 45 \
            --noproxy '*' https://check.torproject.org/api/ip 2>&1) || _final_ok=false
        opsec_debug "  TransProxy test result: ${_tp_result}"
        if [ "$_final_ok" = "true" ] && jq -e '.IsTor == true' <<<"$_tp_result" >/dev/null 2>&1; then
            opsec_green "Transparent proxy VERIFIED — traffic routed through Tor"
        else
            opsec_red "CRITICAL: Transparent proxy verification failed or timed out"
            opsec_debug "  curl output: ${_tp_result}"
            _final_ok=false
        fi
        _socks_result=$(env -u http_proxy -u https_proxy -u all_proxy -u no_proxy \
            -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u NO_PROXY \
            curl -4 --fail --silent --show-error --connect-timeout 10 --max-time 45 \
            --socks5-hostname "127.0.0.1:${socks_port}" https://check.torproject.org/api/ip 2>&1) || _final_ok=false
        if [ "$_final_ok" = "true" ] && jq -e '.IsTor == true' <<<"$_socks_result" >/dev/null 2>&1; then
            opsec_green "SOCKS proxy VERIFIED — system Tor is usable by OPSEC Browser"
        else
            opsec_red "CRITICAL: System Tor SOCKS verification failed or timed out"
            opsec_debug "  SOCKS curl output: ${_socks_result}"
            _final_ok=false
        fi
    fi
    if [ "$_final_ok" = "false" ]; then
        mark_failed_closed "live Tor routing verification failed"
        return 1
    fi

    # Full preflight is a hard activation gate.
    if [ -x /usr/local/bin/opsec-preflight.sh ]; then
        opsec_info "Running post-activation preflight..."
        if ! /usr/local/bin/opsec-preflight.sh --full --enforce; then
            echo "[$(date -Is)] PREFLIGHT FAIL after mode_on" >> "$PREFLIGHT_LOG"
            mark_failed_closed "post-activation preflight failed"
            return 1
        fi
    else
        mark_failed_closed "opsec-preflight.sh is missing"
        return 1
    fi

    # Publish ACTIVE atomically only after every gate passes.
    local _state_tmp
    _state_tmp=$(mktemp /run/opsec/.advanced-enabled.XXXXXX)
    printf '%s\n' "$DESKTOP_UID" > "$_state_tmp"
    chmod 0600 "$_state_tmp"
    mv -f "$_state_tmp" "$STATE_FILE"
    rm -f "$ACTIVATING_FILE" "$FAILED_FILE" "$UNSAFE_FILE"
    cancel_activation_watchdog

    echo ""
    opsec_hdr "GHOST MODE: ACTIVE"
    echo ""
    opsec_dim "Profile:          ${profile}"
    opsec_dim "Kill switch:      armed (Tor only; DHCP exception)"
    opsec_dim "DNS:              ${DNS_MODE:-tor}"
    opsec_dim "Exit policy:      ${blacklist:-Tor upstream default}"
    opsec_dim "Circuit lifetime: ${rotation:+${rotation}s}${rotation:-Tor upstream default}"
    if ! is_cloud_level; then
        opsec_dim "MAC addresses:    randomized"
        opsec_dim "Hostname:         randomized"
    fi
    echo ""
    opsec_dim "Test: curl --socks5-hostname 127.0.0.1:${socks_port} https://ifconfig.me"
    opsec_dim "Off:  sudo opsec-mode off"
    echo ""

    # ─── FINAL STATE SUMMARY ─────────────────────────────────────────────────
    opsec_debug "=========================================="
    opsec_debug "=== MODE ON FINAL STATE ==="
    opsec_debug "=========================================="
    opsec_debug "Hostname: $(hostname)"
    opsec_debug "DNS: $(cat /etc/resolv.conf 2>/dev/null | tr '\n' ' ')"
    opsec_debug "IPv6 disabled: $(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null)"
    opsec_debug "Tor status: $(systemctl is-active "$TOR_SERVICE" 2>&1)"
    opsec_debug "Tor bootstrap: $(tor_bootstrap_line)"
    opsec_debug "Tor TCP ports:"
    ss -tlnp 2>/dev/null | grep -E ":(9040|9050|5353)" >> "$DEBUG_LOG" 2>&1
    opsec_debug "Tor UDP ports:"
    ss -ulnp 2>/dev/null | grep -E ":5353" >> "$DEBUG_LOG" 2>&1
    opsec_debug "Strict nftables policy: $(/usr/local/bin/opsec-killswitch.sh strict-status >/dev/null 2>&1 && echo VERIFIED || echo UNVERIFIED)"
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
    if is_paranoid && [ ! -f "$FAILED_FILE" ] && [ ! -f "$UNSAFE_FILE" ] && [ ! -f "$ACTIVATING_FILE" ]; then
        echo ""
        opsec_red "BLOCKED: Cannot disable ghost mode on paranoid level."
        opsec_red "Current level: ${DEPLOYMENT_LEVEL:-unknown} (LEVEL_TYPE=paranoid)"
        opsec_yellow "To lower security, change deployment level first:"
        opsec_dim "  sudo opsec-config.sh --level apply bare-metal-standard"
        opsec_dim "  sudo opsec-config.sh --level apply cloud-normal"
        echo ""
        exit 1
    fi

    cancel_activation_watchdog

    echo ""
    opsec_hdr "DEACTIVATING GHOST MODE"
    opsec_debug "=== MODE OFF START ==="
    echo ""

    # Interrupt safety: if mode_off is killed mid-teardown (after kill switch is down),
    # re-arm the kill switch to avoid leaving the system exposed
    _mode_off_rearm() {
        echo ""
        opsec_red "INTERRUPTED — re-arming kill switch to prevent exposure"
        /usr/local/bin/opsec-killswitch.sh strict-on 2>/dev/null || \
            /usr/local/bin/opsec-killswitch.sh emergency-on 2>/dev/null || true
        opsec_debug "mode_off interrupted — kill switch re-armed"
        exit 1
    }
    trap '_mode_off_rearm' INT TERM

    # Signal any running mode_on bootstrap loop to stop immediately
    touch "$BOOTSTRAP_STOP"
    opsec_debug "  Stop signal sent to bootstrap loop"

    # Stop the disposable browser cgroup and restore every persistent browser
    # policy mutation before opening normal networking.
    if ! stop_identity_apps; then
        mark_failed_closed "dirty browsers could not be stopped before policy restoration"
        return 1
    fi
    local browser_uid
    local -a browser_uids=()
    browser_uid=$(cat "$BROWSER_UID_FILE" 2>/dev/null || true)
    [[ "$browser_uid" =~ ^[0-9]+$ ]] && browser_uids+=("$browser_uid")
    if [ -d /var/lib/opsec/browser-policy ]; then
        while IFS= read -r browser_uid; do
            [[ "$browser_uid" =~ ^[0-9]+$ ]] || continue
            [[ " ${browser_uids[*]} " == *" $browser_uid "* ]] || browser_uids+=("$browser_uid")
        done < <(find /var/lib/opsec/browser-policy -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null)
    fi
    for browser_uid in "${browser_uids[@]}"; do
        DESKTOP_UID="$browser_uid"
        DESKTOP_USER=$(getent passwd "$browser_uid" | cut -d: -f1)
        DESKTOP_HOME=$(getent passwd "$browser_uid" | cut -d: -f6)
        if [ -n "$DESKTOP_USER" ]; then
            timeout 25 systemctl --user --machine="${DESKTOP_USER}@.host" stop opsec-browser.service >/dev/null 2>&1 || true
            if systemctl --user --machine="${DESKTOP_USER}@.host" is-active opsec-browser.service >/dev/null 2>&1; then
                mark_failed_closed "OPSEC Browser cgroup did not stop"
                return 1
            fi
        fi
        if ! /usr/local/bin/opsec-browser-policy.sh recover "$browser_uid"; then
            mark_failed_closed "dirty-browser policy restoration failed"
            return 1
        fi
    done

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

    # 1. Disarm kill switch only after browser policy restoration succeeds.
    opsec_info "Disarming kill switch..."
    opsec_debug "Step 1: Disarming kill switch"
    /usr/local/bin/opsec-killswitch.sh strict-off
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
    opsec_debug "  Tor status before: $(systemctl is-active "$TOR_SERVICE" 2>&1)"
    if [ -f "$TORRC_DEFAULT" ]; then
        cp "$TORRC_DEFAULT" /etc/tor/torrc
        opsec_debug "  Restored torrc from ${TORRC_DEFAULT}"
    else
        opsec_debug "  WARNING: ${TORRC_DEFAULT} not found"
    fi
    systemctl stop "$TOR_SERVICE" 2>/dev/null || true
    opsec_debug "  Tor status after: $(systemctl is-active "$TOR_SERVICE" 2>&1)"
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
    rm -f "$STATE_FILE" "$ACTIVATING_FILE" "$FAILED_FILE" "$UNSAFE_FILE" "$BROWSER_UID_FILE"
    if [ -f /run/opsec/browser-recovery.masks ]; then
        while IFS= read -r unit; do
            case "$unit" in
                NetworkManager.service|networking.service|systemd-networkd.service)
                    systemctl unmask --runtime "$unit" >/dev/null 2>&1 || true
                    systemctl start "$unit" >/dev/null 2>&1 || true ;;
            esac
        done < /run/opsec/browser-recovery.masks
        rm -f /run/opsec/browser-recovery.masks
    fi
    if [ -f "$IDENTITY_SERVICE_STATE" ]; then
        while IFS= read -r service; do
            case "$service" in
                tailscaled.service|avahi-daemon.service) systemctl start "$service" >/dev/null 2>&1 || true ;;
            esac
        done < "$IDENTITY_SERVICE_STATE"
        rm -f "$IDENTITY_SERVICE_STATE"
    fi
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
    opsec_debug "  Tor: $(systemctl is-active "$TOR_SERVICE" 2>&1)"
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

    # Drop the strict policy only for this time-limited emergency override.
    /usr/local/bin/opsec-killswitch.sh strict-off
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
            /usr/local/bin/opsec-killswitch.sh strict-on
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
    /usr/local/bin/opsec-killswitch.sh strict-on
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
    if [ -f "$UNSAFE_FILE" ]; then
        opsec_red "Mode: ACTIVATION UNSAFE (network containment unverified)"
    elif [ -f "$FAILED_FILE" ]; then
        opsec_red "Mode: FAILED-CLOSED (network blocked; run sudo opsec-mode off)"
    elif [ -f "$ACTIVATING_FILE" ]; then
        opsec_yellow "Mode: ACTIVATING (strict firewall armed)"
    elif [ -f "$STATE_FILE" ]; then
        opsec_green "Mode: GHOST (active)"
    else
        opsec_yellow "Mode: BASE PRIVACY"
    fi

    if [ -f "$DEBUG_LOG" ]; then
        local last_routing
        last_routing=$(grep -E 'TransProxy test result:|SOCKS curl output:|Transparent proxy verification failed|SOCKS proxy verification failed|Tor identity verification exhausted' "$DEBUG_LOG" 2>/dev/null | tail -4 || true)
        if [ -n "$last_routing" ]; then
            opsec_info "Last activation routing diagnostics:"
            sed 's/^/    /' <<<"$last_routing"
        fi
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
    if systemctl is-active "$TOR_SERVICE" >/dev/null 2>&1; then
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
        isolation_val=$(grep "IsolateSOCKSAuth" /etc/tor/torrc 2>/dev/null | awk '{print $2}')
        [ "$isolation_val" = "1" ] && opsec_green "  Stream isolation: ON" || opsec_dim "  Stream isolation: off"

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
    elif /usr/local/bin/opsec-killswitch.sh strict-status >/dev/null 2>&1; then
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
    echo "Service (${TOR_SERVICE}): $(systemctl is-active "$TOR_SERVICE" 2>&1)"
    echo "TCP ports: $(ss -tlnp 2>/dev/null | grep -E ':(9040|9050|5353)' || echo NONE)"
    echo "UDP ports: $(ss -ulnp 2>/dev/null | grep -E ':5353' || echo NONE)"
    echo "Bootstrap: $(tor_bootstrap_line)"
    echo "Last 5 log:"
    journalctl -u "$TOR_SERVICE" -b --no-pager -n 5 2>/dev/null || echo "  (no journal entries)"
    echo ""
    echo "--- Kill Switch ---"
    echo "Strict nftables: $(/usr/local/bin/opsec-killswitch.sh strict-status >/dev/null 2>&1 && echo VERIFIED || echo OFF/UNVERIFIED)"
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
