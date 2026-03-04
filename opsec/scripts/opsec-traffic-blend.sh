#!/bin/bash
# /usr/local/bin/opsec-traffic-blend.sh — Decoy Traffic Blending Daemon
# Generates background browsing noise through Tor/VPN to blend tool traffic
# with normal-looking web activity. Ghost mode only.
# Usage: opsec-traffic-blend.sh start|stop|status

set -euo pipefail

PID_FILE="/var/run/opsec-traffic-blend.pid"
LOG_FILE="/var/log/opsec-traffic-blend.log"

# Source config
OPSEC_CONF="/etc/opsec/opsec.conf"
[ -f "$OPSEC_CONF" ] && . "$OPSEC_CONF"

SOCKS_PORT="${TOR_SOCKS_PORT:-9050}"
# Mean interval in seconds (Poisson distribution approximation)
BLEND_INTERVAL="${TRAFFIC_BLEND_INTERVAL:-30}"

# Color helpers
_green()  { echo -e "\033[38;5;49m[+] $*\033[0m"; }
_red()    { echo -e "\033[38;5;196m[-] $*\033[0m"; }
_yellow() { echo -e "\033[38;5;214m[*] $*\033[0m"; }

# Benign URLs to simulate normal browsing (mix of news, tech, social)
DECOY_URLS=(
    "https://en.wikipedia.org/wiki/Special:Random"
    "https://www.bbc.com/news"
    "https://news.ycombinator.com"
    "https://www.reuters.com"
    "https://stackoverflow.com/questions"
    "https://github.com/trending"
    "https://www.reddit.com/r/technology/.json"
    "https://www.weather.gov"
    "https://httpbin.org/get"
    "https://www.kernel.org"
    "https://www.python.org"
    "https://www.debian.org"
    "https://archive.org"
    "https://www.mozilla.org"
    "https://duckduckgo.com/?q=weather"
    "https://lite.cnn.com"
    "https://text.npr.org"
)

# Random delay using Poisson-like distribution (exponential inter-arrival)
poisson_delay() {
    # Approximate exponential distribution using bash
    # -ln(U) * mean where U is uniform(0,1)
    local mean="$1"
    local rand
    rand=$((RANDOM % 1000 + 1))
    # Approximate: -ln(rand/1000) * mean
    # Using awk for floating point
    awk -v r="$rand" -v m="$mean" 'BEGIN {
        u = r / 1000.0;
        if (u < 0.001) u = 0.001;
        delay = -log(u) * m;
        if (delay < 5) delay = 5;
        if (delay > 120) delay = 120;
        printf "%d\n", delay;
    }'
}

is_running() {
    [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE" 2>/dev/null)" 2>/dev/null
}

blend_loop() {
    local url_count=${#DECOY_URLS[@]}

    echo "[$(date -Is)] Traffic blend daemon started (mean interval: ${BLEND_INTERVAL}s)" >> "$LOG_FILE"

    while true; do
        # Pick a random URL
        local idx=$((RANDOM % url_count))
        local url="${DECOY_URLS[$idx]}"

        # Determine proxy method
        local curl_opts=("--silent" "--output" "/dev/null" "--max-time" "15")

        # Use Tor SOCKS if available
        if ss -tln 2>/dev/null | grep -q ":${SOCKS_PORT} "; then
            curl_opts+=("--socks5-hostname" "127.0.0.1:${SOCKS_PORT}")
        fi

        # Add realistic headers
        curl_opts+=("-H" "User-Agent: Mozilla/5.0 (X11; Linux x86_64; rv:128.0) Gecko/20100101 Firefox/128.0")
        curl_opts+=("-H" "Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8")
        curl_opts+=("-H" "Accept-Language: en-US,en;q=0.5")

        # Make the request
        curl "${curl_opts[@]}" "$url" 2>/dev/null || true

        # Calculate next delay (Poisson-distributed)
        local delay
        delay=$(poisson_delay "$BLEND_INTERVAL")

        sleep "$delay"
    done
}

blend_start() {
    if ! [ -f /var/run/opsec-advanced.enabled ]; then
        _yellow "Traffic blending requires ghost mode to be active"
        return 1
    fi

    if is_running; then
        _yellow "Traffic blend already running (PID $(cat "$PID_FILE"))"
        return 0
    fi

    # Start the blend loop as a background process
    blend_loop &
    local pid=$!
    echo "$pid" > "$PID_FILE"
    disown "$pid"

    sleep 1
    if kill -0 "$pid" 2>/dev/null; then
        _green "Traffic blend started (PID ${pid}, mean interval ${BLEND_INTERVAL}s)"
    else
        rm -f "$PID_FILE"
        _red "Traffic blend failed to start"
        return 1
    fi
}

blend_stop() {
    if ! is_running; then
        _yellow "Traffic blend not running"
        rm -f "$PID_FILE"
        return 0
    fi

    local pid
    pid=$(cat "$PID_FILE" 2>/dev/null)
    kill "$pid" 2>/dev/null || true

    # Wait for process to stop
    local i=0
    while kill -0 "$pid" 2>/dev/null && [ $i -lt 5 ]; do
        sleep 1
        i=$((i + 1))
    done

    kill -9 "$pid" 2>/dev/null || true
    rm -f "$PID_FILE"

    echo "[$(date -Is)] Traffic blend daemon stopped" >> "$LOG_FILE"
    _green "Traffic blend stopped"
}

blend_status() {
    if is_running; then
        local pid
        pid=$(cat "$PID_FILE" 2>/dev/null)
        _green "Traffic blend ACTIVE (PID ${pid})"
        _yellow "Mean interval: ${BLEND_INTERVAL}s"
    else
        _yellow "Traffic blend NOT running"
        rm -f "$PID_FILE"
    fi
}

case "${1:-}" in
    start)   blend_start ;;
    stop)    blend_stop ;;
    restart)
        blend_stop
        sleep 1
        blend_start
        ;;
    status)  blend_status ;;
    *)
        echo "Usage: opsec-traffic-blend.sh start|stop|status|restart"
        exit 1
        ;;
esac
