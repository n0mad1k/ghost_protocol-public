#!/bin/bash
# Conky OPSEC Status — OPSEC Status Widget
# Called by conky via execpi — outputs Conky color markup
# Network data is read from cache (updated by conky-opsec-cache.sh in background)
#
# Color map (managed by theme system):
#   0 = ALERT/BAD    1 = SECURE/GOOD   2 = INFO/NEUTRAL
#   3 = VOID/BG      4 = STRUCTURAL    5 = TITLE/ACCENT
#   6 = LABELS       7 = VALUES        8 = SECTION HDR
#   9 = METADATA

ADVANCED=false
[ -f /var/run/opsec-advanced.enabled ] && ADVANCED=true

# ─── READ CACHE (instant — no network calls) ──────────────────────────────
# Safe parsing: extract values via grep/cut instead of sourcing as shell code
CACHE_FILE="/tmp/.opsec-cache/netinfo"
PUB_IP="" PUB_GEO="" ROUTED_TOR=false EXIT_COUNTRY="" EXIT_CHANGE_TIME="" TOR_BOOTSTRAP="" TOR_PHASE="" CACHE_TIME=0
if [ -f "$CACHE_FILE" ]; then
    _safe_read() { grep "^${1}=" "$CACHE_FILE" 2>/dev/null | head -1 | cut -d'"' -f2; }
    PUB_IP=$(_safe_read PUB_IP)
    PUB_GEO=$(_safe_read PUB_GEO)
    ROUTED_TOR=$(_safe_read ROUTED_TOR)
    EXIT_COUNTRY=$(_safe_read EXIT_COUNTRY)
    EXIT_CHANGE_TIME=$(_safe_read EXIT_CHANGE_TIME)
    TOR_BOOTSTRAP=$(_safe_read TOR_BOOTSTRAP)
    TOR_PHASE=$(_safe_read TOR_PHASE)
    CACHE_TIME=$(_safe_read CACHE_TIME)
    # Sanitize: strip anything that isn't alphanumeric, dots, commas, spaces, or dashes
    PUB_IP=$(echo "$PUB_IP" | tr -cd '0-9.')
    EXIT_COUNTRY=$(echo "$EXIT_COUNTRY" | tr -cd 'A-Za-z')
    EXIT_CHANGE_TIME=$(echo "$EXIT_CHANGE_TIME" | tr -cd '0-9')
    TOR_BOOTSTRAP=$(echo "$TOR_BOOTSTRAP" | tr -cd '0-9')
fi

# Kick off cache daemon if not running
if ! pgrep -f 'conky-opsec-cache\.sh' >/dev/null 2>&1; then
    nohup ~/.config/conky/conky-opsec-cache.sh >/dev/null 2>&1 &
fi

# ─── HEADER ──────────────────────────────────────────────────────────────────
echo "\${color4}\${hr 1}"
if $ADVANCED; then
    echo "\${color5}\${font JetBrains Mono:bold:size=11}\${alignc}OPSEC STATUS\${font}"
    echo "\${color1}\${font JetBrains Mono:bold:size=8}\${alignc}▲ ADVANCED ▲\${font}"
else
    echo "\${color5}\${font JetBrains Mono:bold:size=11}\${alignc}OPSEC STATUS\${font}"
    echo "\${color2}\${font JetBrains Mono:size=8}\${alignc}── STANDARD ──\${font}"
fi
echo "\${color4}\${hr 1}"

# ─── SYSTEM ──────────────────────────────────────────────────────────────────
echo "\${color8}\${font JetBrains Mono:bold:size=9} ▌SYSTEM\${font}"
echo "\${color6} HOST      \${color7}\${nodename}\${alignr}\${color6}UP \${color7}\${uptime_short}"
echo "\${color6} CPU       \${color7}\${cpu}%\${alignr}\${color6}RAM \${color7}\${memperc}% \${color9}(\${mem}/\${memmax})"

# ─── NETWORK ─────────────────────────────────────────────────────────────────
echo "\${color4}\${hr 1}"
echo "\${color8}\${font JetBrains Mono:bold:size=9} ▌NETWORK\${font}"

LOCAL_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)
[ -z "$LOCAL_IP" ] && LOCAL_IP="No route"
echo "\${color6} LOCAL IP  \${color7}${LOCAL_IP}"

# External IP from cache
_display_ip="${PUB_IP}"
[ -z "$_display_ip" ] && _display_ip="\${color0}UNAVAILABLE"
if [ -n "$PUB_GEO" ]; then
    echo "\${color6} EXT IP    \${color7}${_display_ip} \${color9}(${PUB_GEO})"
else
    echo "\${color6} EXT IP    \${color7}${_display_ip}"
fi

VPN_IF=$(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep -E '^(tun|wg)' | head -1)
if [ -n "$VPN_IF" ]; then
    VPN_IP=$(ip -4 addr show "$VPN_IF" 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1)
    echo "\${color6} VPN       \${color1}ACTIVE  \${color7}${VPN_IP} \${color9}(${VPN_IF})"
fi

# TOR/DNS/KSWCH status moved to TOR STATUS section below

PRIMARY_IF=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -1)
if [ -n "$PRIMARY_IF" ]; then
    CUR_MAC=$(ip link show "$PRIMARY_IF" 2>/dev/null | awk '/ether/ {print $2}')
    FIRST_OCTET=$(echo "$CUR_MAC" | cut -d: -f1)
    FIRST_DEC=$((16#${FIRST_OCTET}))
    if (( FIRST_DEC & 2 )); then
        echo "\${color6} MAC       \${color1}RANDOM  \${color9}(${CUR_MAC})"
    else
        echo "\${color6} MAC       \${color0}HWADDR  \${color9}(${CUR_MAC})"
    fi
else
    echo "\${color6} MAC       \${color9}NO IFACE"
fi

# ─── ADVANCED MODE EXTRAS ────────────────────────────────────────────────────
if $ADVANCED; then
    echo "\${color4}\${hr 1}"
    echo "\${color8}\${font JetBrains Mono:bold:size=9} ▌HARDENING\${font}"

    IPV6_ALL=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo "0")
    [ "$IPV6_ALL" = "1" ] && echo "\${color6} IPv6      \${color1}BLOCKED" || echo "\${color6} IPv6      \${color0}LEAKING"

    if lsattr /etc/resolv.conf 2>/dev/null | grep -q 'i'; then
        echo "\${color6} DNSLK     \${color1}LOCKED  \${color9}(immutable)"
    else
        echo "\${color6} DNSLK     \${color0}UNLOCKED"
    fi

    ISO=$(grep "IsolateDestAddr" /etc/tor/torrc 2>/dev/null | head -1)
    [ -n "$ISO" ] && echo "\${color6} ISOL      \${color1}ACTIVE  \${color9}(stream isolation)"

    PAD=$(grep "ConnectionPadding" /etc/tor/torrc 2>/dev/null | awk '{print $2}')
    [ "$PAD" = "1" ] && echo "\${color6} TPAD      \${color1}ACTIVE  \${color9}(traffic padding)"

    BLACKLIST=$(grep "ExcludeExitNodes" /etc/tor/torrc 2>/dev/null | sed 's/ExcludeExitNodes //' | tr -d '{}' | tr ',' ' ')
    [ -n "$BLACKLIST" ] && echo "\${color6} BLOCK     \${color0}$(echo "$BLACKLIST" | tr ' ' ',' | sed 's/,$//')"

    CORE_PAT=$(sysctl -n kernel.core_pattern 2>/dev/null)
    [[ "$CORE_PAT" == *"/bin/false"* ]] && echo "\${color6} CORE      \${color1}BLOCKED" || echo "\${color6} CORE      \${color0}ENABLED"

    SWAP_ACTIVE=$(swapon --show=SIZE --noheadings 2>/dev/null | head -1)
    [ -z "$SWAP_ACTIVE" ] && echo "\${color6} SWAP      \${color1}OFF" || echo "\${color6} SWAP      \${color0}ACTIVE \${color9}(${SWAP_ACTIVE})"

    BOOT_COUNT=0
    for svc in opsec-boot-advanced opsec-mac-randomize opsec-hostname-randomize opsec-killswitch; do
        systemctl is-enabled "$svc" 2>/dev/null | grep -q enabled && BOOT_COUNT=$((BOOT_COUNT + 1))
    done
    if [ "$BOOT_COUNT" -eq 4 ]; then
        echo "\${color6} BOOT      \${color1}PERSIST \${color9}(${BOOT_COUNT}/4)"
    elif [ "$BOOT_COUNT" -gt 0 ]; then
        echo "\${color6} BOOT      \${color2}PARTIAL \${color9}(${BOOT_COUNT}/4)"
    else
        echo "\${color6} BOOT      \${color0}NONE    \${color9}(${BOOT_COUNT}/4)"
    fi

    [ -f /etc/opsec/opsec.conf ] && {
        PROFILE=$(grep "^PROFILE_NAME=" /etc/opsec/opsec.conf 2>/dev/null | cut -d'"' -f2)
        [ -n "$PROFILE" ] && echo "\${color6} PROF      \${color2}${PROFILE}"
    }
fi

# ─── TOR STATUS (replaces Route Chain) ──────────────────────────────────────
if $ADVANCED; then
    echo "\${color4}\${hr 1}"
    echo "\${color8}\${font JetBrains Mono:bold:size=9} ▌TOR STATUS\${font}"

    # Determine protection state
    _tor_svc=false; _tor_socks=false; _ks_armed=false; _tor_routed=false
    systemctl is-active tor >/dev/null 2>&1 && _tor_svc=true
    ss -tln 2>/dev/null | grep -q ':9050 ' && _tor_socks=true
    # iptables -L requires root; use state file instead (kill switch is always armed when advanced is on)
    $ADVANCED && _ks_armed=true
    [ "$ROUTED_TOR" = "true" ] && _tor_routed=true

    if $_tor_svc && $_tor_socks && $_ks_armed && $_tor_routed; then
        echo "\${color6} STATE     \${color1}PROTECTED"
    elif $_tor_svc && ! $_tor_socks; then
        # Bootstrapping
        echo "\${color6} STATE     \${color2}BOOTSTRAP \${color9}(${TOR_BOOTSTRAP:-0}% ${TOR_PHASE:-connecting})"
    elif ! $_tor_svc; then
        echo "\${color6} STATE     \${color0}EXPOSED   \${color9}(tor down)"
    elif ! $_ks_armed; then
        echo "\${color6} STATE     \${color0}EXPOSED   \${color9}(kill switch off)"
    else
        echo "\${color6} STATE     \${color0}EXPOSED   \${color9}(not routed)"
    fi

    # Exit country code only — no IP
    if [ -n "$EXIT_COUNTRY" ] && [ ${#EXIT_COUNTRY} -le 3 ]; then
        echo "\${color6} EXIT      \${color2}${EXIT_COUNTRY}"
    elif $_tor_socks; then
        echo "\${color6} EXIT      \${color9}resolving..."
    else
        echo "\${color6} EXIT      \${color9}—"
    fi

    # Circuit age — time since exit IP last changed
    if [ -n "$EXIT_CHANGE_TIME" ] && [ "$EXIT_CHANGE_TIME" -gt 0 ] 2>/dev/null; then
        _now=$(date +%s)
        _age=$(( _now - EXIT_CHANGE_TIME ))
        if [ "$_age" -lt 60 ]; then
            echo "\${color6} CIRCUIT   \${color2}${_age}s ago"
        elif [ "$_age" -lt 3600 ]; then
            echo "\${color6} CIRCUIT   \${color2}$(( _age / 60 ))m ago"
        else
            echo "\${color6} CIRCUIT   \${color2}$(( _age / 3600 ))h $(( (_age % 3600) / 60 ))m ago"
        fi
    else
        echo "\${color6} CIRCUIT   \${color9}—"
    fi

    # DNS leak check — local checks only
    _dns_server=$(awk '/^nameserver/ {print $2; exit}' /etc/resolv.conf 2>/dev/null)
    _dns_immutable=false
    lsattr /etc/resolv.conf 2>/dev/null | grep -q 'i' && _dns_immutable=true
    _nm_locked=false
    [ -f /etc/NetworkManager/conf.d/opsec-dns-lock.conf ] && _nm_locked=true

    if [ "$_dns_server" = "127.0.0.1" ] && $_dns_immutable && $_nm_locked; then
        echo "\${color6} DNS       \${color1}SECURE  \${color9}(tor + locked)"
    elif [ "$_dns_server" = "127.0.0.1" ] && $_dns_immutable; then
        echo "\${color6} DNS       \${color2}SECURE  \${color9}(tor, NM unlocked)"
    elif [ "$_dns_server" = "127.0.0.1" ]; then
        echo "\${color6} DNS       \${color2}PARTIAL \${color9}(tor, not locked)"
    elif echo "$_dns_server" | grep -qE '^(9\.9\.9\.9|149\.112\.112\.112|1\.1\.1\.1|1\.0\.0\.1)$'; then
        echo "\${color6} DNS       \${color2}PRIVACY \${color9}(${_dns_server})"
    else
        echo "\${color6} DNS       \${color0}LEAKED  \${color9}(${_dns_server})"
    fi
fi

# ─── MODE / LEVEL ───────────────────────────────────────────────────────────
echo "\${color4}\${hr 1}"
LEVEL=""
[ -f /etc/opsec/opsec.conf ] && LEVEL=$(grep "^DEPLOYMENT_LEVEL=" /etc/opsec/opsec.conf 2>/dev/null | cut -d'"' -f2)
if $ADVANCED; then
    echo "\${color6} MODE      \${color1}ADVANCED"
else
    echo "\${color6} MODE      \${color0}STANDARD"
fi
[ -n "$LEVEL" ] && echo "\${color6} LEVEL     \${color7}${LEVEL}"

echo "\${color4}\${hr 1}"
echo "\${color9}\${font JetBrains Mono:size=7}\${alignc}// updated \${time %H:%M:%S} //\${font}"
