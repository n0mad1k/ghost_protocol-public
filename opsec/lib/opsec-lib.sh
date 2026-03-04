#!/bin/bash
# /usr/local/lib/opsec/opsec-lib.sh — Shared OPSEC function library
# Sourced by all OPSEC scripts for config management and common operations

OPSEC_CONF="/etc/opsec/opsec.conf"
OPSEC_COUNTRY_CODES="/etc/opsec/country-codes.conf"
OPSEC_PROFILES_DIR="/etc/opsec/profiles"
OPSEC_STATE_FILE="/var/run/opsec-advanced.enabled"
OPSEC_BOOT_MARKER="/etc/opsec/boot-advanced.enabled"

# ─── COLOR OUTPUT ──────────────────────────────────────────────────────────────
opsec_green()  { echo -e "\033[38;5;49m[+]\033[0m \033[38;5;49m$*\033[0m"; }
opsec_red()    { echo -e "\033[38;5;196m[-]\033[0m \033[38;5;196m$*\033[0m"; }
opsec_yellow() { echo -e "\033[38;5;214m[*]\033[0m \033[38;5;214m$*\033[0m"; }
opsec_info()   { echo -e "\033[38;5;39m[~]\033[0m \033[38;5;75m$*\033[0m"; }
opsec_cyan()   { echo -e "\033[38;5;51m[>]\033[0m \033[38;5;51m$*\033[0m"; }
opsec_mag()    { echo -e "\033[38;5;201m[*]\033[0m \033[38;5;201m$*\033[0m"; }
opsec_dim()    { echo -e "\033[38;5;244m    $*\033[0m"; }
opsec_hdr()    { echo -e "\033[38;5;51m━━━ \033[38;5;201m$*\033[38;5;51m ━━━\033[0m"; }

# ─── CONFIG MANAGEMENT ─────────────────────────────────────────────────────────

opsec_load_config() {
    if [ -f "$OPSEC_CONF" ]; then
        # shellcheck disable=SC1090
        . "$OPSEC_CONF"
        return 0
    fi
    return 1
}

opsec_save_config() {
    # Re-serialize all known keys back to config file
    # Preserves comments and structure
    local tmp
    tmp=$(mktemp)
    cat > "$tmp" << 'HEADER'
# /etc/opsec/opsec.conf — Central OPSEC Configuration
# Shell-sourceable KEY="value" format. All scripts source this file.
# Edit via: sudo opsec-config.sh (interactive TUI)

HEADER

    cat >> "$tmp" << EOF
# ─── ACTIVE PROFILE ────────────────────────────────────────────────────────────
PROFILE_NAME="${PROFILE_NAME:-default}"

# ─── TOR SETTINGS ──────────────────────────────────────────────────────────────
TOR_CIRCUIT_ROTATION="${TOR_CIRCUIT_ROTATION:-30}"
TOR_BLACKLIST="${TOR_BLACKLIST:-}"
TOR_STRICT_NODES="${TOR_STRICT_NODES:-1}"
TOR_ISOLATION="${TOR_ISOLATION:-1}"
TOR_PADDING="${TOR_PADDING:-1}"
TOR_SOCKS_PORT="${TOR_SOCKS_PORT:-9050}"
TOR_DNS_PORT="${TOR_DNS_PORT:-5353}"
TOR_TRANS_PORT="${TOR_TRANS_PORT:-9040}"
TOR_NUM_GUARDS="${TOR_NUM_GUARDS:-3}"
TOR_SAFE_LOGGING="${TOR_SAFE_LOGGING:-1}"

# ─── DNS SETTINGS ──────────────────────────────────────────────────────────────
DNS_MODE="${DNS_MODE:-tor}"
DNS_CUSTOM_SERVERS="${DNS_CUSTOM_SERVERS:-}"

# ─── KILL SWITCH ───────────────────────────────────────────────────────────────
KILLSWITCH_ALLOW_DHCP="${KILLSWITCH_ALLOW_DHCP:-1}"
KILLSWITCH_ALLOW_OPENVPN="${KILLSWITCH_ALLOW_OPENVPN:-1}"
KILLSWITCH_ALLOW_WIREGUARD="${KILLSWITCH_ALLOW_WIREGUARD:-1}"
KILLSWITCH_EXTRA_PORTS="${KILLSWITCH_EXTRA_PORTS:-}"

# ─── MAC ADDRESS ───────────────────────────────────────────────────────────────
MAC_INTERFACES="${MAC_INTERFACES:-auto}"
MAC_VENDOR_SPOOF="${MAC_VENDOR_SPOOF:-}"

# ─── HOSTNAME ──────────────────────────────────────────────────────────────────
HOSTNAME_PATTERN="${HOSTNAME_PATTERN:-desktop}"
HOSTNAME_CUSTOM_PREFIX="${HOSTNAME_CUSTOM_PREFIX:-}"

# ─── SYSTEM HARDENING ──────────────────────────────────────────────────────────
HARDEN_IPV6="${HARDEN_IPV6:-1}"
HARDEN_SWAP="${HARDEN_SWAP:-1}"
HARDEN_CORE_DUMPS="${HARDEN_CORE_DUMPS:-1}"
HARDEN_CLIPBOARD_CLEAR="${HARDEN_CLIPBOARD_CLEAR:-0}"
HARDEN_SCREEN_LOCK="${HARDEN_SCREEN_LOCK:-1}"
HARDEN_SCREEN_LOCK_TIMEOUT="${HARDEN_SCREEN_LOCK_TIMEOUT:-300}"
HARDEN_TIMEZONE_SPOOF="${HARDEN_TIMEZONE_SPOOF:-0}"
HARDEN_TIMEZONE_VALUE="${HARDEN_TIMEZONE_VALUE:-UTC}"
HARDEN_LOCALE_SPOOF="${HARDEN_LOCALE_SPOOF:-0}"
HARDEN_LOCALE_VALUE="${HARDEN_LOCALE_VALUE:-en_US.UTF-8}"

# ─── LEAK PREVENTION ──────────────────────────────────────────────────────────
LEAK_WEBRTC_BLOCK="${LEAK_WEBRTC_BLOCK:-1}"
LEAK_USB_BLOCK="${LEAK_USB_BLOCK:-0}"

# ─── MONITORING ────────────────────────────────────────────────────────────────
MONITOR_PROCESSES="${MONITOR_PROCESSES:-0}"
MONITOR_LOG_ROTATION="${MONITOR_LOG_ROTATION:-1}"
LOG_ROTATION_HOURS="${LOG_ROTATION_HOURS:-4}"

# ─── TRAFFIC SHAPING ──────────────────────────────────────────────────────────
TRAFFIC_JITTER_ENABLED="${TRAFFIC_JITTER_ENABLED:-0}"
TRAFFIC_JITTER_MS="${TRAFFIC_JITTER_MS:-50}"

# ─── LEVEL TYPE ───────────────────────────────────────────────────────────────
LEVEL_TYPE="${LEVEL_TYPE:-standard}"

# ─── BASE STATE ───────────────────────────────────────────────────────────────
BASE_DNS="${BASE_DNS:-quad9}"
BASE_MAC_RANDOMIZE="${BASE_MAC_RANDOMIZE:-1}"
BASE_IPV6_DISABLE="${BASE_IPV6_DISABLE:-1}"

# ─── TOR BRIDGES ──────────────────────────────────────────────────────────────
TOR_BRIDGE_MODE="${TOR_BRIDGE_MODE:-off}"
TOR_BRIDGE_RELAY="${TOR_BRIDGE_RELAY:-}"

# ─── SECURE DELETION ──────────────────────────────────────────────────────────
WIPE_METHOD="${WIPE_METHOD:-auto}"

# ─── DEPLOYMENT LEVEL ─────────────────────────────────────────────────────────
DEPLOYMENT_LEVEL="${DEPLOYMENT_LEVEL:-bare-metal-standard}"

# ─── TERMINAL BANNER ──────────────────────────────────────────────────────────
OPSEC_BANNER="${OPSEC_BANNER:-compact}"

# ─── WIDGET THEME ────────────────────────────────────────────────────────────
WIDGET_THEME="${WIDGET_THEME:-default}"
EOF
    mv "$tmp" "$OPSEC_CONF"
    chmod 600 "$OPSEC_CONF"
}

opsec_set_value() {
    local key="$1" val="$2"
    if [ -z "$key" ]; then return 1; fi
    # Validate key: must be a valid shell variable name (letters, digits, underscore, starts with letter/underscore)
    if ! echo "$key" | grep -qE '^[A-Za-z_][A-Za-z0-9_]*$'; then
        echo "[!] opsec_set_value: invalid key name '${key}'" >&2
        return 1
    fi
    # Sanitize value: strip characters that could break shell quoting
    val=$(printf '%s' "$val" | tr -d '`$\\\"'"'" | tr -cd '[:print:]')
    opsec_load_config
    eval "${key}=\"${val}\""
    opsec_save_config
}

opsec_get_value() {
    local key="$1"
    # Validate key: must be a valid shell variable name
    if ! echo "$key" | grep -qE '^[A-Za-z_][A-Za-z0-9_]*$'; then
        echo "[!] opsec_get_value: invalid key name '${key}'" >&2
        return 1
    fi
    opsec_load_config
    eval "echo \"\${${key}:-}\""
}

# ─── TORRC GENERATION ──────────────────────────────────────────────────────────

opsec_generate_torrc() {
    local _dbg="/run/opsec/debug.log"
    echo "[$(date -Is)] [lib] opsec_generate_torrc called" >> "$_dbg" 2>/dev/null || true

    opsec_load_config || return 1

    local torrc="/etc/tor/torrc"
    local socks_port="${TOR_SOCKS_PORT:-9050}"
    local trans_port="${TOR_TRANS_PORT:-9040}"
    local dns_port="${TOR_DNS_PORT:-5353}"
    local rotation="${TOR_CIRCUIT_ROTATION:-30}"
    local blacklist="${TOR_BLACKLIST:-}"
    local strict="${TOR_STRICT_NODES:-1}"
    local isolation="${TOR_ISOLATION:-1}"
    local padding="${TOR_PADDING:-1}"
    local guards="${TOR_NUM_GUARDS:-3}"
    local safe_log="${TOR_SAFE_LOGGING:-1}"
    echo "[$(date -Is)] [lib]   socks=${socks_port} trans=${trans_port} dns=${dns_port} blacklist=${blacklist}" >> "$_dbg" 2>/dev/null || true

    # Build SocksPort line with isolation flags
    local socks_line="SocksPort ${socks_port}"
    if [ "$isolation" = "1" ]; then
        socks_line="${socks_line} IsolateDestAddr IsolateDestPort"
    fi

    # Build ExcludeExitNodes from blacklist
    local exclude_line=""
    if [ -n "$blacklist" ]; then
        local formatted
        formatted=$(echo "$blacklist" | sed 's/\([a-z][a-z]\)/{\1}/g; s/,/,/g')
        exclude_line="ExcludeExitNodes ${formatted}"
    fi

    local bridge_mode="${TOR_BRIDGE_MODE:-off}"
    local bridge_relay="${TOR_BRIDGE_RELAY:-}"

    cat > "$torrc" << EOF
# Autogenerated — do not edit manually
# Regenerate via: opsec-config.sh --apply

# ─── SOCKS, TRANSPARENT PROXY & DNS ─────────────────────────────────────────
${socks_line}
TransPort ${trans_port}
DNSPort ${dns_port}

# ─── EXIT NODE EXCLUSION ────────────────────────────────────────────────────
${exclude_line}
StrictNodes ${strict}

# ─── CIRCUIT ROTATION ───────────────────────────────────────────────────────
MaxCircuitDirtiness ${rotation}

# ─── TRAFFIC PADDING ────────────────────────────────────────────────────────
ConnectionPadding ${padding}

# ─── SAFE LOGGING ────────────────────────────────────────────────────────────
SafeLogging ${safe_log}
Log notice file /run/tor/notices.log

# ─── ENTRY GUARDS ───────────────────────────────────────────────────────────
NumEntryGuards ${guards}
UseEntryGuards 1

EOF

    # ─── PLUGGABLE TRANSPORTS (bridges) ──────────────────────────────────────
    if [ "$bridge_mode" != "off" ] && [ "$bridge_mode" != "" ]; then
        cat >> "$torrc" << 'BRIDGE_HEADER'

# ─── BRIDGE CONFIGURATION ────────────────────────────────────────────────────
UseBridges 1
BRIDGE_HEADER

        case "$bridge_mode" in
            obfs4)
                echo "ClientTransportPlugin obfs4 exec /usr/bin/obfs4proxy" >> "$torrc"
                ;;
            meek-azure)
                echo "ClientTransportPlugin meek_lite exec /usr/bin/obfs4proxy" >> "$torrc"
                ;;
            snowflake)
                # snowflake-client location varies by distro
                local sf_bin
                sf_bin=$(command -v snowflake-client 2>/dev/null || echo "/usr/bin/snowflake-client")
                echo "ClientTransportPlugin snowflake exec ${sf_bin}" >> "$torrc"
                ;;
        esac

        # Add user-specified bridge relay if provided
        if [ -n "$bridge_relay" ]; then
            echo "Bridge ${bridge_relay}" >> "$torrc"
        else
            # Default bridges for each transport type
            case "$bridge_mode" in
                meek-azure)
                    echo "Bridge meek_lite 192.0.2.18:80 BE776A53492E1E044A26F17306E1BC46A55A1625 url=https://meek.azureedge.net/ front=ajax.aspnetcdn.com" >> "$torrc"
                    ;;
                snowflake)
                    echo "Bridge snowflake 192.0.2.3:80 2B280B23E1107BB62ABFC40DDCC8824814F80A72 fingerprint=2B280B23E1107BB62ABFC40DDCC8824814F80A72 url=https://snowflake-broker.torproject.net.global.prod.fastly.net/ front=foursquare.com ice=stun:stun.l.google.com:19302,stun:stun.antisip.com:3478,stun:stun.bluesip.net:3478,stun:stun.dus.net:3478,stun:stun.epygi.com:3478,stun:stun.sonetel.com:3478,stun:stun.uls.co.za:3478,stun:stun.voipgate.com:3478,stun:stun.voys.nl:3478 utls-imitate=hellorandomizedalpn" >> "$torrc"
                    ;;
            esac
        fi
    fi

    chmod 644 "$torrc"
    echo "[$(date -Is)] [lib]   torrc written ($(wc -l < "$torrc") lines)" >> "$_dbg" 2>/dev/null || true
    echo "[$(date -Is)] [lib]   torrc contents:" >> "$_dbg" 2>/dev/null || true
    cat "$torrc" >> "$_dbg" 2>/dev/null || true
    echo "[$(date -Is)] [lib]   --- end torrc ---" >> "$_dbg" 2>/dev/null || true
}

# ─── RESOLV.CONF GENERATION ───────────────────────────────────────────────────

opsec_generate_resolv() {
    local _dbg="/run/opsec/debug.log"
    echo "[$(date -Is)] [lib] opsec_generate_resolv called" >> "$_dbg" 2>/dev/null || true

    opsec_load_config || return 1

    local mode="${DNS_MODE:-tor}"
    local resolv="/etc/resolv.conf"
    echo "[$(date -Is)] [lib]   DNS_MODE=${mode}" >> "$_dbg" 2>/dev/null || true

    # Unlock if immutable
    chattr -i "$resolv" 2>/dev/null || true

    case "$mode" in
        tor)
            echo "nameserver 127.0.0.1" > "$resolv"
            ;;
        quad9)
            cat > "$resolv" << 'EOF'
nameserver 9.9.9.9
nameserver 149.112.112.112
EOF
            ;;
        cloudflare)
            cat > "$resolv" << 'EOF'
nameserver 1.1.1.1
nameserver 1.0.0.1
EOF
            ;;
        doh)
            # DNS-over-HTTPS via dnscrypt-proxy
            # Ensure dnscrypt-proxy is running
            if command -v dnscrypt-proxy >/dev/null 2>&1; then
                # Deploy config if not present
                if [ ! -f /etc/dnscrypt-proxy/dnscrypt-proxy.toml ] && [ -f /etc/opsec/dnscrypt-proxy.toml ]; then
                    mkdir -p /etc/dnscrypt-proxy
                    cp /etc/opsec/dnscrypt-proxy.toml /etc/dnscrypt-proxy/dnscrypt-proxy.toml
                fi
                mkdir -p /var/log/dnscrypt-proxy /var/cache/dnscrypt-proxy
                # Stop systemd-resolved if it conflicts on :53
                systemctl stop systemd-resolved 2>/dev/null || true
                systemctl start dnscrypt-proxy 2>/dev/null || dnscrypt-proxy -config /etc/dnscrypt-proxy/dnscrypt-proxy.toml &
            fi
            cat > "$resolv" << 'EOF'
nameserver 127.0.0.53
EOF
            ;;
        dot)
            # DNS-over-TLS via systemd-resolved
            cat > "$resolv" << 'EOF'
nameserver 127.0.0.53
options edns0 trust-ad
EOF
            ;;
        custom)
            if [ -n "$DNS_CUSTOM_SERVERS" ]; then
                : > "$resolv"
                local IFS=','
                for server in $DNS_CUSTOM_SERVERS; do
                    echo "nameserver ${server}" >> "$resolv"
                done
            else
                echo "nameserver 9.9.9.9" > "$resolv"
            fi
            ;;
        *)
            echo "nameserver 9.9.9.9" > "$resolv"
            ;;
    esac

    # Lock if in advanced mode
    if opsec_is_advanced; then
        chattr +i "$resolv"
        echo "[$(date -Is)] [lib]   resolv.conf locked (chattr +i)" >> "$_dbg" 2>/dev/null || true
    fi
    echo "[$(date -Is)] [lib]   resolv.conf contents: $(cat "$resolv" 2>/dev/null | tr '\n' ' ')" >> "$_dbg" 2>/dev/null || true
}

# ─── STATE CHECKS ─────────────────────────────────────────────────────────────

opsec_is_advanced() {
    [ -f "$OPSEC_STATE_FILE" ]
}

opsec_is_boot_enabled() {
    [ -f "$OPSEC_BOOT_MARKER" ]
}

# ─── PROFILE MANAGEMENT ───────────────────────────────────────────────────────

opsec_profile_save() {
    local name="$1"
    if [ -z "$name" ]; then return 1; fi
    mkdir -p "$OPSEC_PROFILES_DIR"
    cp "$OPSEC_CONF" "${OPSEC_PROFILES_DIR}/${name}.conf"
    # Tag profile name inside the saved copy
    sed -i "s/^PROFILE_NAME=.*/PROFILE_NAME=\"${name}\"/" "${OPSEC_PROFILES_DIR}/${name}.conf"
}

opsec_profile_load() {
    local name="$1"
    local profile="${OPSEC_PROFILES_DIR}/${name}.conf"
    if [ ! -f "$profile" ]; then return 1; fi
    cp "$profile" "$OPSEC_CONF"
    # Update active profile name
    sed -i "s/^PROFILE_NAME=.*/PROFILE_NAME=\"${name}\"/" "$OPSEC_CONF"
}

opsec_profile_list() {
    if [ -d "$OPSEC_PROFILES_DIR" ]; then
        find "$OPSEC_PROFILES_DIR" -name '*.conf' -printf '%f\n' | sed 's/\.conf$//'
    fi
}

opsec_profile_delete() {
    local name="$1"
    rm -f "${OPSEC_PROFILES_DIR}/${name}.conf"
}

opsec_profile_export() {
    local name="$1" dest="$2"
    local profile="${OPSEC_PROFILES_DIR}/${name}.conf"
    if [ ! -f "$profile" ]; then return 1; fi
    cp "$profile" "$dest"
}

opsec_profile_import() {
    local src="$1" name="$2"
    if [ ! -f "$src" ]; then return 1; fi
    mkdir -p "$OPSEC_PROFILES_DIR"
    cp "$src" "${OPSEC_PROFILES_DIR}/${name}.conf"
}

# ─── COUNTRY CODE HELPERS ─────────────────────────────────────────────────────

opsec_load_country_presets() {
    if [ -f "$OPSEC_COUNTRY_CODES" ]; then
        # shellcheck disable=SC1090
        . "$OPSEC_COUNTRY_CODES"
    fi
}

opsec_get_preset() {
    local preset="$1"
    opsec_load_country_presets
    case "$preset" in
        5eyes|fiveeyes)   echo "$FIVE_EYES" ;;
        9eyes|nineeyes)   echo "$NINE_EYES" ;;
        14eyes|fourteeneyes) echo "$FOURTEEN_EYES" ;;
        surveillance)     echo "$SURVEILLANCE_STATES" ;;
        max)              echo "$MAX_EXCLUSION" ;;
        *)                echo "" ;;
    esac
}

# ─── DEPLOYMENT LEVEL MANAGEMENT ─────────────────────────────────────────────

OPSEC_LEVELS_DIR="/etc/opsec/levels"

opsec_level_list() {
    if [ -d "$OPSEC_LEVELS_DIR" ]; then
        find "$OPSEC_LEVELS_DIR" -name '*.conf' -printf '%f\n' | sed 's/\.conf$//' | sort
    fi
}

opsec_level_apply() {
    local level="$1"
    local level_file="${OPSEC_LEVELS_DIR}/${level}.conf"
    if [ ! -f "$level_file" ]; then
        opsec_red "Level '${level}' not found in ${OPSEC_LEVELS_DIR}"
        return 1
    fi

    # Preserve current PROFILE_NAME before overwriting
    opsec_load_config 2>/dev/null || true
    local saved_profile="${PROFILE_NAME:-default}"

    # Copy level preset over active config
    cp "$level_file" "$OPSEC_CONF"
    chmod 600 "$OPSEC_CONF"

    # Restore profile name and ensure deployment level is tagged
    opsec_load_config
    PROFILE_NAME="$saved_profile"
    DEPLOYMENT_LEVEL="$level"
    opsec_save_config
}

# ─── SECURE DELETION ─────────────────────────────────────────────────────────

opsec_detect_storage_type() {
    # Detect storage type for a given path
    # Returns: hdd | ssd | luks | unknown
    local target_path="${1:-/}"
    local device

    # Find the block device for the path
    device=$(df -P "$target_path" 2>/dev/null | tail -1 | awk '{print $1}')
    [ -z "$device" ] && echo "unknown" && return

    # Check for LUKS
    if command -v cryptsetup >/dev/null 2>&1; then
        # Check if device is on a dm-crypt layer
        local dm_name
        dm_name=$(basename "$device" 2>/dev/null)
        if [ -e "/sys/block/${dm_name}/dm/uuid" ] 2>/dev/null; then
            local dm_uuid
            dm_uuid=$(cat "/sys/block/${dm_name}/dm/uuid" 2>/dev/null)
            if echo "$dm_uuid" | grep -qi "CRYPT-LUKS"; then
                echo "luks"
                return
            fi
        fi
        # Also check via dmsetup
        if dmsetup info "$device" 2>/dev/null | grep -qi "CRYPT-LUKS"; then
            echo "luks"
            return
        fi
    fi

    # Resolve to physical disk (strip partition number, handle /dev/mapper)
    local phys_disk
    phys_disk=$(lsblk -ndo PKNAME "$device" 2>/dev/null | head -1)
    [ -z "$phys_disk" ] && phys_disk=$(echo "$device" | sed 's/[0-9]*$//' | sed 's|^/dev/||')

    # Check rotational flag (0 = SSD, 1 = HDD)
    local rotational_file="/sys/block/${phys_disk}/queue/rotational"
    if [ -f "$rotational_file" ]; then
        local rotational
        rotational=$(cat "$rotational_file" 2>/dev/null)
        if [ "$rotational" = "0" ]; then
            echo "ssd"
        else
            echo "hdd"
        fi
        return
    fi

    echo "unknown"
}

opsec_secure_delete() {
    # SSD-aware secure file deletion
    # Usage: opsec_secure_delete <file_or_dir> [method]
    # method: auto (default) | shred | fstrim | luks
    local target="$1"
    local method="${2:-${WIPE_METHOD:-auto}}"

    [ -z "$target" ] && return 1

    if [ "$method" = "auto" ]; then
        method=$(opsec_detect_storage_type "$target")
    fi

    case "$method" in
        hdd|shred)
            # Traditional shred for spinning disks
            if [ -d "$target" ]; then
                find "$target" -type f -exec shred -fuz -n 1 {} \; 2>/dev/null
                rm -rf "$target" 2>/dev/null
            elif [ -f "$target" ]; then
                shred -fuz -n 1 "$target" 2>/dev/null
            fi
            ;;
        ssd|fstrim)
            # For SSDs: overwrite with zeros, delete, then fstrim
            # shred is ineffective on SSDs due to wear leveling
            if [ -d "$target" ]; then
                find "$target" -type f -exec dd if=/dev/zero of={} bs=4k count=1 conv=notrunc 2>/dev/null \;
                find "$target" -type f -delete 2>/dev/null
                rm -rf "$target" 2>/dev/null
            elif [ -f "$target" ]; then
                dd if=/dev/zero of="$target" bs=4k count=1 conv=notrunc 2>/dev/null
                rm -f "$target" 2>/dev/null
            fi
            # Request TRIM/discard on the filesystem
            local mount_point
            mount_point=$(df -P "${target%/*}" 2>/dev/null | tail -1 | awk '{print $6}')
            if [ -n "$mount_point" ]; then
                fstrim "$mount_point" 2>/dev/null || true
            fi
            ;;
        luks)
            # For LUKS: zero file + rely on LUKS key destroy for full wipe
            if [ -d "$target" ]; then
                find "$target" -type f -exec dd if=/dev/zero of={} bs=4k count=1 conv=notrunc 2>/dev/null \;
                find "$target" -type f -delete 2>/dev/null
                rm -rf "$target" 2>/dev/null
            elif [ -f "$target" ]; then
                dd if=/dev/zero of="$target" bs=4k count=1 conv=notrunc 2>/dev/null
                rm -f "$target" 2>/dev/null
            fi
            # Note: full LUKS key destroy handled by emergency-wipe
            ;;
        *)
            # Fallback: basic shred
            if [ -d "$target" ]; then
                find "$target" -type f -exec shred -fuz -n 1 {} \; 2>/dev/null
                rm -rf "$target" 2>/dev/null
            elif [ -f "$target" ]; then
                shred -fuz -n 1 "$target" 2>/dev/null
            fi
            ;;
    esac
}

# ─── WIDGET THEME MANAGEMENT ─────────────────────────────────────────────────

OPSEC_THEMES_DIR="/etc/opsec/themes"

opsec_theme_list() {
    if [ -d "$OPSEC_THEMES_DIR" ]; then
        find "$OPSEC_THEMES_DIR" -name '*.theme' -printf '%f\n' | sed 's/\.theme$//' | sort
    fi
}

opsec_generate_conky() {
    opsec_load_config || return 1

    local theme="${WIDGET_THEME:-default}"
    local theme_file="${OPSEC_THEMES_DIR}/${theme}.theme"

    if [ ! -f "$theme_file" ]; then
        opsec_red "Theme '${theme}' not found at ${theme_file}"
        return 1
    fi

    # Source theme to get CONKY_COLOR* and CONKY_BG values
    # shellcheck disable=SC1090
    . "$theme_file"

    local conky_conf_name="conky-opsec-widget.conf"

    # Find and regenerate conky config for each user with the widget installed
    for home_dir in /home/*; do
        local conky_conf="${home_dir}/.config/conky/${conky_conf_name}"
        [ -f "$conky_conf" ] || continue

        local owner
        owner=$(stat -c '%U' "$conky_conf" 2>/dev/null) || continue

        cat > "$conky_conf" << CONKYEOF
-- OPSEC Status Widget
-- Colors managed by theme system via opsec-config.sh
-- Theme: ${theme} (${THEME_LABEL:-Custom})

conky.config = {
    -- Window settings
    alignment = 'top_right',
    gap_x = 15,
    gap_y = 60,
    minimum_width = 400,
    minimum_height = 200,
    maximum_width = 420,

    -- Multi-monitor: run xrandr --listmonitors to find head number
    xinerama_head = 0,

    -- Window type
    own_window = true,
    own_window_type = 'desktop',
    own_window_transparent = false,
    own_window_argb_visual = true,
    own_window_argb_value = 210,
    own_window_colour = '${CONKY_BG:-0d1117}',
    own_window_hints = 'undecorated,below,sticky,skip_taskbar,skip_pager',

    -- Drawing
    double_buffer = true,
    draw_shades = true,
    default_shade_color = '000000',
    draw_outline = false,
    draw_borders = true,
    border_inner_margin = 12,
    border_outer_margin = 4,
    border_width = 1,
    border_colour = '1b3a5c',
    stippled_borders = 0,

    -- Font
    use_xft = true,
    font = 'JetBrains Mono:size=10',
    override_utf8_locale = true,

    -- Colors — Theme: ${theme}
    default_color = 'b0b0b0',
    color0 = '${CONKY_COLOR0:-df2020}',
    color1 = '${CONKY_COLOR1:-33ff33}',
    color2 = '${CONKY_COLOR2:-3a8fd6}',
    color3 = '${CONKY_COLOR3:-0d1117}',
    color4 = '${CONKY_COLOR4:-1f6feb}',
    color5 = '${CONKY_COLOR5:-58a6ff}',
    color6 = '${CONKY_COLOR6:-79c0ff}',
    color7 = '${CONKY_COLOR7:-c9d1d9}',
    color8 = '${CONKY_COLOR8:-1f6feb}',
    color9 = '${CONKY_COLOR9:-484f58}',

    -- Update interval
    update_interval = 3,
    total_run_times = 0,

    -- Misc
    cpu_avg_samples = 2,
    no_buffers = true,
    text_buffer_size = 8192,
    short_units = true,
};

conky.text = [[
\${execpi 5 ~/.config/conky/conky-opsec-status.sh}
]];
CONKYEOF

        chown "$owner":"$owner" "$conky_conf"
        chmod 644 "$conky_conf"
    done

    # Restart conky for all users running the opsec widget
    pkill -f 'conky.*opsec' 2>/dev/null || true
    sleep 1

    for home_dir in /home/*; do
        local conky_conf="${home_dir}/.config/conky/${conky_conf_name}"
        [ -f "$conky_conf" ] || continue

        local owner
        owner=$(stat -c '%U' "$conky_conf" 2>/dev/null) || continue
        local uid
        uid=$(id -u "$owner" 2>/dev/null) || continue

        # Relaunch conky as the file owner
        su - "$owner" -c "DISPLAY=:0 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/${uid}/bus nohup conky -c '${conky_conf}' >/dev/null 2>&1 &" 2>/dev/null || true
    done
}

# ─── INIT CHECK ────────────────────────────────────────────────────────────────
# Ensure /etc/opsec exists
_opsec_init_dirs() {
    [ -d /etc/opsec ] || mkdir -p /etc/opsec
    [ -d "$OPSEC_PROFILES_DIR" ] || mkdir -p "$OPSEC_PROFILES_DIR"
}

# Auto-init on source if running as root
if [ "$EUID" = "0" ] 2>/dev/null || [ "$(id -u)" = "0" ] 2>/dev/null; then
    _opsec_init_dirs
fi
