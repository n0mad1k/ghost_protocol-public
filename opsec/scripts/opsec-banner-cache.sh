#!/bin/bash
# /usr/local/bin/opsec-banner-cache.sh — Background WAN IP Cache Updater
# Updates /var/cache/opsec/wan_ip every 5 minutes (via cron)
# Never blocks shell startup — the banner reads from cache only

CACHE_DIR="/var/cache/opsec"
CACHE_FILE="${CACHE_DIR}/wan_ip"
ENDPOINTS="https://icanhazip.com https://ifconfig.me https://api.ipify.org"

mkdir -p "$CACHE_DIR"
chmod 755 "$CACHE_DIR"

PUB_IP=""

# Try via Tor first if running
if pgrep -x tor >/dev/null 2>&1 && ss -tln 2>/dev/null | grep -q ':9050 '; then
    for ep in $ENDPOINTS; do
        PUB_IP=$(curl -s --max-time 10 --socks5-hostname 127.0.0.1:9050 "$ep" 2>/dev/null | tr -d '[:space:]')
        [ -n "$PUB_IP" ] && break
    done
fi

# Fallback to direct if Tor failed or not running
if [ -z "$PUB_IP" ]; then
    for ep in $ENDPOINTS; do
        PUB_IP=$(curl -s --max-time 5 "$ep" 2>/dev/null | tr -d '[:space:]')
        [ -n "$PUB_IP" ] && break
    done
fi

# Only write if we got a valid-looking IP
if echo "$PUB_IP" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo "$PUB_IP" > "$CACHE_FILE"
    chmod 644 "$CACHE_FILE"
fi
