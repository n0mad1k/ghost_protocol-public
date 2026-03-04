#!/bin/bash
# /usr/local/bin/opsec-preflight.sh — OPSEC Preflight Verification Gate
# Verifies all required security controls are active for the current mode.
#
# Usage:
#   opsec-preflight.sh              Human-readable HUD
#   opsec-preflight.sh --score      Pass/fail count
#   opsec-preflight.sh --enforce    Exit 1 if any applicable check fails
#   opsec-preflight.sh --base       Only run base checks (standard mode)
#   opsec-preflight.sh --full       Run base + ghost checks
#   opsec-preflight.sh --base --enforce   Base checks, exit 1 on fail
#   opsec-preflight.sh --full --enforce   Full checks, exit 1 on fail

OPSEC_LIB="/usr/local/lib/opsec/opsec-lib.sh"
OPSEC_CONF="/etc/opsec/opsec.conf"
PREFLIGHT_LOG="/var/log/opsec-preflight.log"

# Source library
if [ -f "$OPSEC_LIB" ]; then
    . "$OPSEC_LIB"
    opsec_load_config 2>/dev/null || true
elif [ -f "$OPSEC_CONF" ]; then
    . "$OPSEC_CONF"
fi

# Fallback colors if lib not loaded
type opsec_green >/dev/null 2>&1 || {
    opsec_green()  { echo -e "\033[38;5;49m[+] $*\033[0m"; }
    opsec_red()    { echo -e "\033[38;5;196m[-] $*\033[0m"; }
    opsec_yellow() { echo -e "\033[38;5;214m[*] $*\033[0m"; }
    opsec_info()   { echo -e "\033[38;5;39m[~] $*\033[0m"; }
    opsec_cyan()   { echo -e "\033[38;5;51m[>] $*\033[0m"; }
    opsec_dim()    { echo -e "\033[38;5;244m    $*\033[0m"; }
    opsec_hdr()    { echo -e "\033[38;5;51m━━━ \033[38;5;201m$*\033[38;5;51m ━━━\033[0m"; }
}

# ─── PARSE ARGS ───────────────────────────────────────────────────────────────
MODE_SCORE=false
MODE_ENFORCE=false
CHECK_LEVEL=""

while [ $# -gt 0 ]; do
    case "$1" in
        --score)   MODE_SCORE=true ;;
        --enforce) MODE_ENFORCE=true ;;
        --base)    CHECK_LEVEL="base" ;;
        --full)    CHECK_LEVEL="full" ;;
        *)         echo "Usage: opsec-preflight.sh [--score|--enforce] [--base|--full]"; exit 1 ;;
    esac
    shift
done

# Auto-detect check level if not specified
if [ -z "$CHECK_LEVEL" ]; then
    if [ -f /var/run/opsec-advanced.enabled ]; then
        CHECK_LEVEL="full"
    else
        CHECK_LEVEL="base"
    fi
fi

# ─── ENVIRONMENT ──────────────────────────────────────────────────────────────
LEVEL="${DEPLOYMENT_LEVEL:-bare-metal-standard}"
LTYPE="${LEVEL_TYPE:-standard}"

is_cloud() {
    case "$LEVEL" in
        cloud-*) return 0 ;;
        *)       return 1 ;;
    esac
}

is_bare_metal() {
    case "$LEVEL" in
        bare-metal-*) return 0 ;;
        *)            return 1 ;;
    esac
}

# ─── CHECK ENGINE ─────────────────────────────────────────────────────────────
PASS=0
FAIL=0
SKIP=0
FAILURES=""

check() {
    local name="$1" result="$2" detail="${3:-}"
    if [ "$result" = "pass" ]; then
        PASS=$((PASS + 1))
        $MODE_SCORE || opsec_green "PASS  ${name}${detail:+  ${detail}}"
    elif [ "$result" = "fail" ]; then
        FAIL=$((FAIL + 1))
        FAILURES="${FAILURES}\n  - ${name}${detail:+: ${detail}}"
        $MODE_SCORE || opsec_red "FAIL  ${name}${detail:+  ${detail}}"
    elif [ "$result" = "skip" ]; then
        SKIP=$((SKIP + 1))
        $MODE_SCORE || opsec_dim "SKIP  ${name}${detail:+  (${detail})}"
    fi
}

# ─── BASE CHECKS (always run) ────────────────────────────────────────────────
run_base_checks() {
    $MODE_SCORE || opsec_cyan "Base Privacy Checks"

    # 1. MAC randomized (bare-metal only)
    if is_bare_metal; then
        local pif cur_mac first_octet first_dec
        pif=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -1)
        if [ -n "$pif" ]; then
            cur_mac=$(ip link show "$pif" 2>/dev/null | awk '/ether/ {print $2}')
            first_octet=$(echo "$cur_mac" | cut -d: -f1)
            first_dec=$((16#${first_octet})) 2>/dev/null || first_dec=0
            if (( first_dec & 2 )); then
                check "MAC randomized" "pass" "${pif}: ${cur_mac}"
            else
                check "MAC randomized" "fail" "${pif}: ${cur_mac} (hardware address)"
            fi
        else
            check "MAC randomized" "skip" "no primary interface"
        fi
    else
        check "MAC randomized" "skip" "cloud deployment"
    fi

    # 2. IPv6 disabled
    local ipv6_all
    ipv6_all=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo "0")
    if [ "$ipv6_all" = "1" ]; then
        check "IPv6 disabled" "pass"
    else
        check "IPv6 disabled" "fail" "net.ipv6.conf.all.disable_ipv6=${ipv6_all}"
    fi

    # 3. Core dumps disabled
    local core_pat
    core_pat=$(sysctl -n kernel.core_pattern 2>/dev/null)
    if [[ "$core_pat" == *"/bin/false"* ]] || [[ "$core_pat" == *"devnull"* ]]; then
        check "Core dumps disabled" "pass"
    else
        check "Core dumps disabled" "fail" "core_pattern=${core_pat}"
    fi

    # 4. Swap disabled
    local swap_count
    swap_count=$(swapon --show --noheadings 2>/dev/null | wc -l)
    if [ "$swap_count" -eq 0 ]; then
        check "Swap disabled" "pass"
    else
        check "Swap disabled" "fail" "${swap_count} swap device(s) active"
    fi

    # 5. DNS is privacy resolver (not ISP)
    local dns_server
    dns_server=$(awk '/^nameserver/ {print $2; exit}' /etc/resolv.conf 2>/dev/null)
    case "$dns_server" in
        127.0.0.1|127.0.0.53|9.9.9.9|149.112.112.112|1.1.1.1|1.0.0.1)
            check "DNS privacy resolver" "pass" "${dns_server}"
            ;;
        *)
            check "DNS privacy resolver" "fail" "${dns_server} (possibly ISP)"
            ;;
    esac

    # 6. WebRTC blocked (if Firefox present)
    if [ -d "$HOME/.mozilla/firefox" ] || [ -d "/root/.mozilla/firefox" ]; then
        local userjs_found=false
        local profile_dirs
        profile_dirs=$(find /home/*/.mozilla/firefox /root/.mozilla/firefox -maxdepth 1 -name '*.default*' 2>/dev/null | head -3)
        for pd in $profile_dirs; do
            if [ -f "$pd/user.js" ] && grep -q "media.peerconnection.enabled.*false" "$pd/user.js" 2>/dev/null; then
                userjs_found=true
                break
            fi
        done
        if $userjs_found; then
            check "WebRTC blocked" "pass" "user.js configured"
        else
            check "WebRTC blocked" "fail" "no user.js with WebRTC disable found"
        fi
    else
        check "WebRTC blocked" "skip" "Firefox not detected"
    fi
}

# ─── GHOST CHECKS (only when ghost mode active) ──────────────────────────────
run_ghost_checks() {
    $MODE_SCORE || opsec_cyan "Ghost Mode Checks"

    # 1. VPN or Tor active
    local vpn_if tor_ok=false
    vpn_if=$(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep -E '^(tun|wg)' | head -1)
    ss -tln 2>/dev/null | grep -q ':9050 ' && tor_ok=true

    if [ -n "$vpn_if" ] || $tor_ok; then
        local detail=""
        [ -n "$vpn_if" ] && detail="VPN:${vpn_if}"
        $tor_ok && detail="${detail:+${detail} + }Tor:9050"
        check "VPN/Tor active" "pass" "$detail"
    else
        check "VPN/Tor active" "fail" "no tun/wg interface, no Tor on :9050"
    fi

    # 2. Kill switch armed
    if [ -f /var/run/opsec-breakglass.active ]; then
        check "Kill switch armed" "fail" "BREAK-GLASS active — kill switch intentionally dropped"
    elif iptables -L GP_FW >/dev/null 2>&1; then
        check "Kill switch armed" "pass"
    else
        check "Kill switch armed" "fail" "GP_FW chain not found"
    fi

    # 3. DNS locked to Tor
    local dns_server
    dns_server=$(awk '/^nameserver/ {print $2; exit}' /etc/resolv.conf 2>/dev/null)
    if [ "$dns_server" = "127.0.0.1" ]; then
        check "DNS locked to Tor" "pass"
    else
        check "DNS locked to Tor" "fail" "DNS=${dns_server} (expected 127.0.0.1)"
    fi

    # 4. Hostname randomized (bare-metal only)
    if is_bare_metal; then
        local cur_hostname
        cur_hostname=$(hostname)
        # Check if hostname looks randomized (not default patterns like kali, debian, localhost)
        case "$cur_hostname" in
            kali|debian|localhost|ubuntu|parrot)
                check "Hostname randomized" "fail" "hostname=${cur_hostname} (appears default)"
                ;;
            *)
                check "Hostname randomized" "pass" "${cur_hostname}"
                ;;
        esac
    else
        check "Hostname randomized" "skip" "cloud deployment"
    fi

    # 5. resolv.conf immutable
    if lsattr /etc/resolv.conf 2>/dev/null | grep -q 'i'; then
        check "resolv.conf immutable" "pass"
    else
        check "resolv.conf immutable" "fail" "chattr +i not set"
    fi
}

# ─── EXECUTE CHECKS ──────────────────────────────────────────────────────────

if ! $MODE_SCORE; then
    echo ""
    opsec_hdr "OPSEC PREFLIGHT — ${CHECK_LEVEL^^}"
    opsec_dim "Level: ${LEVEL} (${LTYPE})"
    echo ""
fi

run_base_checks

if [ "$CHECK_LEVEL" = "full" ]; then
    $MODE_SCORE || echo ""
    run_ghost_checks
fi

# ─── RESULTS ──────────────────────────────────────────────────────────────────

TOTAL=$((PASS + FAIL))

if $MODE_SCORE; then
    echo "${PASS}/${TOTAL} passed"
    [ "$FAIL" -gt 0 ] && exit 1
    exit 0
fi

echo ""
opsec_hdr "PREFLIGHT RESULT"

if [ "$FAIL" -eq 0 ]; then
    opsec_green "ALL CHECKS PASSED (${PASS}/${TOTAL})"
    [ "$SKIP" -gt 0 ] && opsec_dim "${SKIP} checks skipped (not applicable)"
else
    opsec_red "FAILED: ${FAIL}/${TOTAL} checks"
    opsec_dim "Passed: ${PASS} | Failed: ${FAIL} | Skipped: ${SKIP}"
    echo -e "\033[38;5;196mFailures:${FAILURES}\033[0m"
    # Log failures
    echo "[$(date -Is)] PREFLIGHT ${CHECK_LEVEL^^}: ${PASS}/${TOTAL} passed, ${FAIL} failed${FAILURES}" >> "$PREFLIGHT_LOG" 2>/dev/null || true
fi
echo ""

if $MODE_ENFORCE && [ "$FAIL" -gt 0 ]; then
    exit 1
fi

exit 0
