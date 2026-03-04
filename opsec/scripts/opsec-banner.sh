#!/bin/bash
# /usr/local/bin/opsec-banner.sh — Terminal OPSEC Status Banner
# Mirrors the Conky desktop widget layout and Widget theme colors
# Modes: compact | full | off (configured via OPSEC_BANNER in opsec.conf)

OPSEC_CONF="/etc/opsec/opsec.conf"
[ -f "$OPSEC_CONF" ] && . "$OPSEC_CONF"

BANNER_MODE="${OPSEC_BANNER:-compact}"
[ -n "$1" ] && BANNER_MODE="$1"
[ "$BANNER_MODE" = "off" ] && exit 0

# ─── Widget theme colors (matching Conky widget) ────────────────────────────
R=$'\e[0m'
BLD=$'\e[1m'
C0=$'\e[38;5;135m'     # ALERT/BAD    — #B55AFC purple
C1=$'\e[38;5;204m'     # SECURE/GOOD  — #FF63BE hot pink
C2=$'\e[38;5;117m'     # INFO/NEUTRAL — #85E7FF cyan
C4=$'\e[38;5;32m'      # STRUCTURAL   — #268BD2 blue
C5=$'\e[38;5;45m'      # TITLE/ACCENT — #07CAF9 bright cyan
C6=$'\e[38;5;117m'     # LABELS       — #85E7FF cyan
C7=$'\e[38;5;189m'     # VALUES       — #ECDEF7 lavender
C8=$'\e[38;5;135m'     # SECTION HDR  — #B55AFC purple
C9=$'\e[38;5;66m'      # METADATA     — #4A6A7A dark grey

# ─── DETECT STATE ────────────────────────────────────────────────────────────
ADVANCED=false
[ -f /var/run/opsec-advanced.enabled ] && ADVANCED=true

BREAKGLASS=false
if [ -f /var/run/opsec-breakglass.active ]; then
    BREAKGLASS=true
    _bge=$(cat /var/run/opsec-breakglass.active 2>/dev/null)
    _bgn=$(date +%s)
    BG_REM=""
    [ -n "$_bge" ] && [ "$_bge" -gt "$_bgn" ] 2>/dev/null && BG_REM="$(( (_bge - _bgn) / 60 ))m"
fi

# ─── HELPERS ─────────────────────────────────────────────────────────────────
HR="  ${C4}$(printf '─%.0s' {1..48})${R}"

# ─── READ CACHE ──────────────────────────────────────────────────────────────
CACHE_FILE="/tmp/.opsec-cache/netinfo"
PUB_IP="" PUB_GEO="" ROUTED_TOR=false EXIT_COUNTRY="" EXIT_CHANGE_TIME="" TOR_BOOTSTRAP="" TOR_PHASE=""
if [ -f "$CACHE_FILE" ]; then
    _cr() { grep "^${1}=" "$CACHE_FILE" 2>/dev/null | head -1 | cut -d'"' -f2; }
    PUB_IP=$(_cr PUB_IP)
    PUB_GEO=$(_cr PUB_GEO)
    ROUTED_TOR=$(_cr ROUTED_TOR)
    EXIT_COUNTRY=$(_cr EXIT_COUNTRY)
    EXIT_CHANGE_TIME=$(_cr EXIT_CHANGE_TIME)
    TOR_BOOTSTRAP=$(_cr TOR_BOOTSTRAP)
    TOR_PHASE=$(_cr TOR_PHASE)
    PUB_IP=$(echo "$PUB_IP" | tr -cd '0-9.')
    EXIT_COUNTRY=$(echo "$EXIT_COUNTRY" | tr -cd 'A-Za-z')
    EXIT_CHANGE_TIME=$(echo "$EXIT_CHANGE_TIME" | tr -cd '0-9')
    TOR_BOOTSTRAP=$(echo "$TOR_BOOTSTRAP" | tr -cd '0-9')
fi

# ─── GATHER LIVE STATUS ─────────────────────────────────────────────────────

LOCAL_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)
[ -z "$LOCAL_IP" ] && LOCAL_IP="No route"

VPN_IF=$(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep -E '^(tun|wg)' | head -1)
VPN_OK=false; VPN_IP=""
if [ -n "$VPN_IF" ]; then
    VPN_OK=true
    VPN_IP=$(ip -4 addr show "$VPN_IF" 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1)
fi

PRIMARY_IF=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -1)
MAC_OK=false; CUR_MAC=""
if [ -n "$PRIMARY_IF" ]; then
    CUR_MAC=$(ip link show "$PRIMARY_IF" 2>/dev/null | awk '/ether/{print $2}')
    _oct=$((16#$(echo "$CUR_MAC" | cut -d: -f1))) 2>/dev/null
    (( _oct & 2 )) 2>/dev/null && MAC_OK=true
fi

# ═════════════════════════════════════════════════════════════════════════════
# COMPACT BANNER
# ═════════════════════════════════════════════════════════════════════════════

render_compact() {
    _si() {
        local ok=$1 lbl="$2"
        if $ok; then
            echo -n "${C6}${lbl}${C1}${BLD}+${R}"
        else
            echo -n "${C6}${lbl}${C0}${BLD}x${R}"
        fi
    }

    local _tor_ok=false; ss -tln 2>/dev/null | grep -q ':9050 ' && _tor_ok=true
    local _ks_ok=false
    [ -f /var/run/opsec-killswitch.enabled ] && _ks_ok=true
    iptables -L GP_FW >/dev/null 2>&1 && _ks_ok=true
    local _dns_ok=false
    local _ds=$(awk '/^nameserver/{print $2;exit}' /etc/resolv.conf 2>/dev/null)
    case "$_ds" in 127.0.0.1|9.9.9.9|149.112.*|1.1.1.1|1.0.0.1) _dns_ok=true ;; esac
    local _v6_ok=false
    [ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null)" = "1" ] && _v6_ok=true

    echo ""
    if $BREAKGLASS; then
        echo "  ${C0}${BLD}⚠ BREAKGLASS${R}  ${C0}KS bypassed${BG_REM:+ (${BG_REM})}${R}"
    fi

    if $ADVANCED; then
        local sigil="${C1}${BLD}▲ ADVANCED${R}"
        local ind="$(_si $_tor_ok TOR) $(_si $_ks_ok KS) $(_si $_dns_ok DNS) $(_si $MAC_OK MAC) $(_si $_v6_ok v6)"
        $VPN_OK && ind="$ind $(_si $VPN_OK VPN)"
        echo "  ${sigil}  ${ind}  ${C9}${LOCAL_IP}${R}"
    else
        local sigil="${C2}── STANDARD${R}"
        local ind="$(_si $_dns_ok DNS) $(_si $MAC_OK MAC)"
        $VPN_OK && ind="$ind $(_si $VPN_OK VPN)"
        echo "  ${sigil}  ${ind}  ${C9}${LOCAL_IP}${R}"
    fi
    echo ""
}

# ═════════════════════════════════════════════════════════════════════════════
# FULL BANNER — mirrors Conky widget
# ═════════════════════════════════════════════════════════════════════════════

render_full() {
    echo ""

    # ── HEADER ──
    echo "$HR"
    if $ADVANCED; then
        echo "  ${C5}${BLD}        OPSEC STATUS${R}"
        echo "  ${C1}${BLD}        ▲ ADVANCED ▲${R}"
    else
        echo "  ${C5}${BLD}        OPSEC STATUS${R}"
        echo "  ${C2}        ── STANDARD ──${R}"
    fi
    echo "$HR"

    # Breakglass warning
    if $BREAKGLASS; then
        echo "  ${C0}${BLD} ⚠ BREAKGLASS — Kill switch bypassed ${BG_REM:+(${BG_REM})}${R}"
        echo "$HR"
    fi

    # ── SYSTEM ──
    echo "  ${C8}${BLD} ▌SYSTEM${R}"
    echo "  ${C6} HOST      ${C7}$(hostname)${R}$(printf '%*s' 1 '')${C6}UP ${C7}$(uptime -p 2>/dev/null | sed 's/^up //' | sed 's/ hours\?/h/;s/ minutes\?/m/;s/ days\?/d/;s/, */ /g' || uptime | awk -F'up ' '{print $2}' | awk -F, '{print $1}')${R}"
    local _cpu _mem _memtot _memp
    _cpu=$(awk '/^cpu /{u=$2+$4; t=$2+$4+$5; if(t>0) printf "%.0f", u*100/t}' /proc/stat 2>/dev/null)
    _mem=$(free -h 2>/dev/null | awk '/^Mem:/{print $3}')
    _memtot=$(free -h 2>/dev/null | awk '/^Mem:/{print $2}')
    _memp=$(free 2>/dev/null | awk '/^Mem:/{if($2>0) printf "%.0f", $3*100/$2}')
    echo "  ${C6} CPU       ${C7}${_cpu:-0}%${R}$(printf '%*s' 1 '')${C6}RAM ${C7}${_memp:-0}% ${C9}(${_mem:-?}/${_memtot:-?})${R}"

    # ── NETWORK ──
    echo "$HR"
    echo "  ${C8}${BLD} ▌NETWORK${R}"
    echo "  ${C6} LOCAL IP  ${C7}${LOCAL_IP}${R}"

    # External IP
    if [ -n "$PUB_IP" ]; then
        if [ -n "$PUB_GEO" ]; then
            echo "  ${C6} EXT IP    ${C7}${PUB_IP} ${C9}(${PUB_GEO})${R}"
        else
            echo "  ${C6} EXT IP    ${C7}${PUB_IP}${R}"
        fi
    else
        echo "  ${C6} EXT IP    ${C0}UNAVAILABLE${R}"
    fi

    # VPN
    if $VPN_OK; then
        echo "  ${C6} VPN       ${C1}ACTIVE  ${C7}${VPN_IP} ${C9}(${VPN_IF})${R}"
    fi

    # MAC
    if [ -n "$CUR_MAC" ]; then
        if $MAC_OK; then
            echo "  ${C6} MAC       ${C1}RANDOM  ${C9}(${CUR_MAC})${R}"
        else
            echo "  ${C6} MAC       ${C0}HWADDR  ${C9}(${CUR_MAC})${R}"
        fi
    else
        echo "  ${C6} MAC       ${C9}NO IFACE${R}"
    fi

    # ── HARDENING (advanced only) ──
    if $ADVANCED; then
        echo "$HR"
        echo "  ${C8}${BLD} ▌HARDENING${R}"

        local _v6=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo "0")
        [ "$_v6" = "1" ] && echo "  ${C6} IPv6      ${C1}BLOCKED${R}" || echo "  ${C6} IPv6      ${C0}LEAKING${R}"

        if lsattr /etc/resolv.conf 2>/dev/null | grep -q 'i'; then
            echo "  ${C6} DNSLK     ${C1}LOCKED  ${C9}(immutable)${R}"
        else
            echo "  ${C6} DNSLK     ${C0}UNLOCKED${R}"
        fi

        local _iso=$(grep "IsolateDestAddr" /etc/tor/torrc 2>/dev/null | head -1)
        [ -n "$_iso" ] && echo "  ${C6} ISOL      ${C1}ACTIVE  ${C9}(stream isolation)${R}"

        local _pad=$(grep "ConnectionPadding" /etc/tor/torrc 2>/dev/null | awk '{print $2}')
        [ "$_pad" = "1" ] && echo "  ${C6} TPAD      ${C1}ACTIVE  ${C9}(traffic padding)${R}"

        local _bl=$(grep "ExcludeExitNodes" /etc/tor/torrc 2>/dev/null | sed 's/ExcludeExitNodes //' | tr -d '{}' | tr ',' ' ')
        [ -n "$_bl" ] && echo "  ${C6} BLOCK     ${C0}$(echo "$_bl" | tr ' ' ',' | sed 's/,$//')${R}"

        local _core=$(sysctl -n kernel.core_pattern 2>/dev/null)
        [[ "$_core" == *"/bin/false"* ]] && echo "  ${C6} CORE      ${C1}BLOCKED${R}" || echo "  ${C6} CORE      ${C0}ENABLED${R}"

        local _swap=$(swapon --show=SIZE --noheadings 2>/dev/null | head -1)
        [ -z "$_swap" ] && echo "  ${C6} SWAP      ${C1}OFF${R}" || echo "  ${C6} SWAP      ${C0}ACTIVE ${C9}(${_swap})${R}"

        local _bootc=0
        for _svc in opsec-boot-advanced opsec-mac-randomize opsec-hostname-randomize opsec-killswitch; do
            systemctl is-enabled "$_svc" 2>/dev/null | grep -q enabled && _bootc=$((_bootc + 1))
        done
        if [ "$_bootc" -eq 4 ]; then
            echo "  ${C6} BOOT      ${C1}PERSIST ${C9}(${_bootc}/4)${R}"
        elif [ "$_bootc" -gt 0 ]; then
            echo "  ${C6} BOOT      ${C2}PARTIAL ${C9}(${_bootc}/4)${R}"
        else
            echo "  ${C6} BOOT      ${C0}NONE    ${C9}(${_bootc}/4)${R}"
        fi

        local _prof="${PROFILE_NAME:-}"
        [ -n "$_prof" ] && echo "  ${C6} PROF      ${C2}${_prof}${R}"
    fi

    # ── TOR STATUS (advanced only) ──
    if $ADVANCED; then
        echo "$HR"
        echo "  ${C8}${BLD} ▌TOR STATUS${R}"

        local _tor_svc=false _tor_socks=false _ks_armed=false _tor_routed=false
        systemctl is-active tor >/dev/null 2>&1 && _tor_svc=true
        ss -tln 2>/dev/null | grep -q ':9050 ' && _tor_socks=true
        $ADVANCED && _ks_armed=true
        [ "$ROUTED_TOR" = "true" ] && _tor_routed=true

        if $_tor_svc && $_tor_socks && $_ks_armed && $_tor_routed; then
            echo "  ${C6} STATE     ${C1}PROTECTED${R}"
        elif $_tor_svc && ! $_tor_socks; then
            echo "  ${C6} STATE     ${C2}BOOTSTRAP ${C9}(${TOR_BOOTSTRAP:-0}% ${TOR_PHASE:-connecting})${R}"
        elif ! $_tor_svc; then
            echo "  ${C6} STATE     ${C0}EXPOSED   ${C9}(tor down)${R}"
        elif ! $_ks_armed; then
            echo "  ${C6} STATE     ${C0}EXPOSED   ${C9}(kill switch off)${R}"
        else
            echo "  ${C6} STATE     ${C0}EXPOSED   ${C9}(not routed)${R}"
        fi

        if [ -n "$EXIT_COUNTRY" ] && [ ${#EXIT_COUNTRY} -le 3 ]; then
            echo "  ${C6} EXIT      ${C2}${EXIT_COUNTRY}${R}"
        elif $_tor_socks; then
            echo "  ${C6} EXIT      ${C9}resolving...${R}"
        else
            echo "  ${C6} EXIT      ${C9}—${R}"
        fi

        if [ -n "$EXIT_CHANGE_TIME" ] && [ "$EXIT_CHANGE_TIME" -gt 0 ] 2>/dev/null; then
            local _now=$(date +%s)
            local _age=$(( _now - EXIT_CHANGE_TIME ))
            if [ "$_age" -lt 60 ]; then
                echo "  ${C6} CIRCUIT   ${C2}${_age}s ago${R}"
            elif [ "$_age" -lt 3600 ]; then
                echo "  ${C6} CIRCUIT   ${C2}$(( _age / 60 ))m ago${R}"
            else
                echo "  ${C6} CIRCUIT   ${C2}$(( _age / 3600 ))h $(( (_age % 3600) / 60 ))m ago${R}"
            fi
        else
            echo "  ${C6} CIRCUIT   ${C9}—${R}"
        fi

        local _dns_server=$(awk '/^nameserver/{print $2;exit}' /etc/resolv.conf 2>/dev/null)
        local _dns_immutable=false
        lsattr /etc/resolv.conf 2>/dev/null | grep -q 'i' && _dns_immutable=true
        local _nm_locked=false
        [ -f /etc/NetworkManager/conf.d/opsec-dns-lock.conf ] && _nm_locked=true

        if [ "$_dns_server" = "127.0.0.1" ] && $_dns_immutable && $_nm_locked; then
            echo "  ${C6} DNS       ${C1}SECURE  ${C9}(tor + locked)${R}"
        elif [ "$_dns_server" = "127.0.0.1" ] && $_dns_immutable; then
            echo "  ${C6} DNS       ${C2}SECURE  ${C9}(tor, NM unlocked)${R}"
        elif [ "$_dns_server" = "127.0.0.1" ]; then
            echo "  ${C6} DNS       ${C2}PARTIAL ${C9}(tor, not locked)${R}"
        elif echo "$_dns_server" | grep -qE '^(9\.9\.9\.9|149\.112|1\.1\.1\.1|1\.0\.0\.1)'; then
            echo "  ${C6} DNS       ${C2}PRIVACY ${C9}(${_dns_server})${R}"
        else
            echo "  ${C6} DNS       ${C0}LEAKED  ${C9}(${_dns_server})${R}"
        fi
    fi

    # ── MODE / LEVEL ──
    echo "$HR"
    if $ADVANCED; then
        echo "  ${C6} MODE      ${C1}ADVANCED${R}"
    else
        echo "  ${C6} MODE      ${C0}STANDARD${R}"
    fi
    local _lvl="${DEPLOYMENT_LEVEL:-}"
    [ -n "$_lvl" ] && echo "  ${C6} LEVEL     ${C7}${_lvl}${R}"

    echo "$HR"
    echo "  ${C9}        // $(date +%H:%M:%S) //${R}"
    echo ""
}

# ═════════════════════════════════════════════════════════════════════════════
# DISPATCH
# ═════════════════════════════════════════════════════════════════════════════

case "$BANNER_MODE" in
    compact) render_compact ;;
    full)    render_full ;;
esac
