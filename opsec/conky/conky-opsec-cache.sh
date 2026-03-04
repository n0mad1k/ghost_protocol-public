#!/bin/bash
# conky-opsec-cache — Background IP/geo cache updater
# Runs in a loop, writes results to cache file that the status script reads.
# This keeps all slow network calls OUT of the conky render path.

CACHE_DIR="/tmp/.opsec-cache"
CACHE_FILE="${CACHE_DIR}/netinfo"
LOCK_FILE="${CACHE_DIR}/.updating"
INTERVAL=30  # seconds between updates

mkdir -p "$CACHE_DIR"
chmod 700 "$CACHE_DIR"

update_cache() {
    # Prevent concurrent updates
    [ -f "$LOCK_FILE" ] && return
    touch "$LOCK_FILE"

    local advanced=false
    [ -f /var/run/opsec-advanced.enabled ] && advanced=true

    local pub_ip="" pub_geo="" routed_tor=false exit_country=""

    # In Advanced mode with SOCKS available: verify Tor via HTTPS, then get geo
    if $advanced && ss -tln 2>/dev/null | grep -q ':9050 '; then
        # Step 1: Verify Tor routing via HTTPS (encrypted, trusted endpoint)
        local tor_json
        tor_json=$(curl -4 -s --max-time 10 --socks5-hostname 127.0.0.1:9050 "https://check.torproject.org/api/ip" 2>/dev/null)
        if echo "$tor_json" | grep -q '"IsTor":true'; then
            pub_ip=$(echo "$tor_json" | grep -o '"IP":"[^"]*"' | cut -d'"' -f4)
            if [ -n "$pub_ip" ] && echo "$pub_ip" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
                routed_tor=true
            else
                pub_ip=""
            fi
        fi
        # Step 2: Get geo data via ip-api.com (HTTP only — but over Tor SOCKS so exit encrypts)
        # ip-api.com pro HTTPS requires a paid key; free tier is HTTP-only
        # This is acceptable: traffic goes through Tor SOCKS tunnel, so local network can't see it
        if [ -n "$pub_ip" ]; then
            local geo_json
            geo_json=$(curl -4 -s --max-time 10 --socks5-hostname 127.0.0.1:9050 "http://ip-api.com/json/${pub_ip}?fields=countryCode,city" 2>/dev/null)
            local geo_country geo_city
            geo_country=$(echo "$geo_json" | grep -o '"countryCode":"[^"]*"' | cut -d'"' -f4)
            geo_city=$(echo "$geo_json" | grep -o '"city":"[^"]*"' | cut -d'"' -f4)
            exit_country="$geo_country"
            [ -n "$geo_country" ] && pub_geo="${geo_city:+${geo_city}, }${geo_country}"
        fi
    fi

    # Fallback to direct — only if NOT in advanced mode (kill switch would DROP it)
    if [ -z "$pub_ip" ] && ! $advanced; then
        local api_json
        api_json=$(curl -4 -s --max-time 4 "https://check.torproject.org/api/ip" 2>/dev/null)
        if [ -n "$api_json" ]; then
            pub_ip=$(echo "$api_json" | grep -o '"IP":"[^"]*"' | cut -d'"' -f4)
        fi
        # Validate IP format
        if [ -n "$pub_ip" ] && ! echo "$pub_ip" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
            pub_ip=""
        fi
        # Get geo via HTTPS (direct mode — no Tor)
        if [ -n "$pub_ip" ]; then
            local geo_json
            geo_json=$(curl -4 -s --max-time 4 "http://ip-api.com/json/${pub_ip}?fields=countryCode,city" 2>/dev/null)
            local geo_country geo_city
            geo_country=$(echo "$geo_json" | grep -o '"countryCode":"[^"]*"' | cut -d'"' -f4)
            geo_city=$(echo "$geo_json" | grep -o '"city":"[^"]*"' | cut -d'"' -f4)
            [ -n "$geo_country" ] && pub_geo="${geo_city:+${geo_city}, }${geo_country}"
        fi
    fi

    # Sanitize exit country — should be 2-3 letter country code
    [ -n "$exit_country" ] && [ ${#exit_country} -gt 3 ] && exit_country=""

    # Track when exit IP last changed (for circuit age display)
    local exit_change_time=""
    local prev_ip="" prev_change_time=""
    if [ -f "$CACHE_FILE" ]; then
        prev_ip=$(grep '^PUB_IP=' "$CACHE_FILE" 2>/dev/null | cut -d'"' -f2)
        prev_change_time=$(grep '^EXIT_CHANGE_TIME=' "$CACHE_FILE" 2>/dev/null | cut -d'"' -f2)
    fi
    if [ -n "$pub_ip" ] && [ "$pub_ip" != "$prev_ip" ]; then
        exit_change_time="$(date +%s)"
    elif [ -n "$prev_change_time" ]; then
        exit_change_time="$prev_change_time"
    else
        exit_change_time="$(date +%s)"
    fi

    # Tor bootstrap progress — only from current Tor session
    local tor_bootstrap="" tor_phase=""
    if $advanced && systemctl is-active tor >/dev/null 2>&1; then
        # Get Tor start time, only read log lines after it
        local tor_start
        tor_start=$(systemctl show tor@default --property=ActiveEnterTimestamp 2>/dev/null | cut -d= -f2)
        if [ -n "$tor_start" ]; then
            local start_ts
            start_ts=$(date -d "$tor_start" +%s 2>/dev/null || echo 0)
            local boot_line=""
            # Read bootstrap lines — -h suppresses filename prefix when checking both paths
            while IFS= read -r line; do
                local log_date
                log_date=$(echo "$line" | grep -oP '^\w+ \d+ [\d:.]+')
                if [ -n "$log_date" ]; then
                    local log_ts
                    log_ts=$(date -d "$log_date" +%s 2>/dev/null || echo 0)
                    [ "$log_ts" -ge "$start_ts" ] && boot_line="$line"
                fi
            done < <(grep -h "Bootstrapped" /run/tor/notices.log /var/log/tor/notices.log 2>/dev/null)
            if [ -n "$boot_line" ]; then
                tor_bootstrap=$(echo "$boot_line" | grep -oP '\d+(?=%)')
                tor_phase=$(echo "$boot_line" | grep -oP '\(\K[^)]+' | head -1)
            fi
        fi
    fi

    # Write atomically (write to tmp then move) — quote values for safe sourcing
    local tmp="${CACHE_FILE}.tmp"
    cat > "$tmp" <<EOF
PUB_IP="${pub_ip}"
PUB_GEO="${pub_geo}"
ROUTED_TOR="${routed_tor}"
EXIT_COUNTRY="${exit_country}"
EXIT_CHANGE_TIME="${exit_change_time}"
TOR_BOOTSTRAP="${tor_bootstrap}"
TOR_PHASE="${tor_phase}"
CACHE_TIME="$(date +%s)"
EOF
    chmod 600 "$tmp"
    mv -f "$tmp" "$CACHE_FILE"
    rm -f "$LOCK_FILE"
}

# Initial update immediately
update_cache

# Loop forever — poll faster when Tor is bootstrapping
while true; do
    if [ -f /var/run/opsec-advanced.enabled ] && systemctl is-active tor >/dev/null 2>&1 && ! ss -tln 2>/dev/null | grep -q ':9050 '; then
        sleep 5  # Tor bootstrapping — fast poll
    else
        sleep "$INTERVAL"
    fi
    update_cache
done
