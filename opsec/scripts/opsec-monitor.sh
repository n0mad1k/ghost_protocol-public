#!/bin/bash
# /usr/local/bin/opsec-monitor.sh — Background connection monitor
# Watches for non-Tor/non-VPN outbound connections, new listening ports,
# unexpected DNS queries. Sends desktop notifications + logs.
# Usage: sudo opsec-monitor.sh start|stop|status

set -euo pipefail

PIDFILE="/var/run/opsec-monitor.pid"
LOGFILE="/var/log/opsec-monitor.log"
INTERVAL=10

OPSEC_LIB="/usr/local/lib/opsec/opsec-lib.sh"
if [ -f "$OPSEC_LIB" ]; then
    . "$OPSEC_LIB"
else
    opsec_green()  { echo "[+] $*"; }
    opsec_red()    { echo "[-] $*"; }
    opsec_info()   { echo "[~] $*"; }
fi

notify() {
    local msg="$1" urgency="${2:-normal}"
    local real_user="${SUDO_USER:-$USER}"
    # Desktop notification
    su - "$real_user" -c "DISPLAY=:0 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u "$real_user")/bus notify-send -u '$urgency' 'OPSEC Monitor' '$msg'" 2>/dev/null || true
    # Log
    echo "[$(date '+%H:%M:%S')] $msg" >> "$LOGFILE"
}

monitor_loop() {
    local known_listeners=""
    local tor_uid
    tor_uid=$(id -u debian-tor 2>/dev/null || id -u tor 2>/dev/null || echo "")

    while true; do
        # ─── Check for non-Tor/VPN outbound connections ────────────────────
        local suspicious
        suspicious=$(ss -tunp 2>/dev/null | grep ESTAB | grep -v '127.0.0.1' | grep -v '::1' | \
            grep -v "tun\|wg\|tor\|${tor_uid:-NOOP}" | \
            grep -v ':9050\|:5353\|:1194\|:51820' || true)

        if [ -n "$suspicious" ]; then
            local count
            count=$(echo "$suspicious" | wc -l)
            notify "ALERT: ${count} non-Tor/VPN outbound connection(s) detected" "critical"
        fi

        # ─── Check for new listening ports ─────────────────────────────────
        local current_listeners
        current_listeners=$(ss -tlnp 2>/dev/null | tail -n +2 | awk '{print $4}' | sort)

        if [ -n "$known_listeners" ] && [ "$current_listeners" != "$known_listeners" ]; then
            local new_ports
            new_ports=$(comm -13 <(echo "$known_listeners") <(echo "$current_listeners") 2>/dev/null || true)
            if [ -n "$new_ports" ]; then
                notify "New listening port(s): ${new_ports}" "critical"
            fi
        fi
        known_listeners="$current_listeners"

        # ─── Check for unexpected DNS queries ──────────────────────────────
        local dns_leaks
        dns_leaks=$(ss -tunp 2>/dev/null | grep ':53 ' | grep -v '127.0.0.1' | grep -v '::1' || true)
        if [ -n "$dns_leaks" ]; then
            notify "DNS LEAK: Non-local DNS query detected" "critical"
        fi

        sleep "$INTERVAL"
    done
}

do_start() {
    if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
        opsec_info "Monitor already running (PID: $(cat "$PIDFILE"))"
        return
    fi

    monitor_loop &
    echo $! > "$PIDFILE"
    opsec_green "Monitor started (PID: $!, logging to ${LOGFILE})"
}

do_stop() {
    if [ -f "$PIDFILE" ]; then
        local pid
        pid=$(cat "$PIDFILE")
        kill "$pid" 2>/dev/null || true
        # Kill child processes
        pkill -P "$pid" 2>/dev/null || true
        rm -f "$PIDFILE"
        opsec_green "Monitor stopped"
    else
        opsec_info "Monitor not running"
    fi
}

do_status() {
    if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
        opsec_green "Monitor running (PID: $(cat "$PIDFILE"))"
        if [ -f "$LOGFILE" ]; then
            echo ""
            echo "Last 10 log entries:"
            tail -10 "$LOGFILE" 2>/dev/null || true
        fi
    else
        opsec_info "Monitor not running"
    fi
}

case "${1:-}" in
    start)  do_start ;;
    stop)   do_stop ;;
    status) do_status ;;
    *)
        echo "Usage: $(basename "$0") start|stop|status"
        exit 1
        ;;
esac
