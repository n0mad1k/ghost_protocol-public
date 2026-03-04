#!/bin/bash
# /usr/local/bin/opsec-sentry.sh — Continuous Threat Sentry Manager
# Manages the sentry daemon for background threat detection
# Usage: opsec-sentry.sh start|stop|status|restart

set -euo pipefail

SENTRY_BIN="${SENTRY_BIN:-/usr/local/bin/sentry-daemon}"
PID_FILE="/var/run/opsec-sentry.pid"
LOG_FILE="/var/log/opsec-sentry.log"
ALERT_HOOK=""

# Source config for alert hook if available
OPSEC_CONF="/etc/opsec/opsec.conf"
[ -f "$OPSEC_CONF" ] && . "$OPSEC_CONF"

# Color output helpers
_green()  { echo -e "\033[38;5;49m[+] $*\033[0m"; }
_red()    { echo -e "\033[38;5;196m[-] $*\033[0m"; }
_yellow() { echo -e "\033[38;5;214m[*] $*\033[0m"; }
_info()   { echo -e "\033[38;5;39m[~] $*\033[0m"; }

is_running() {
    [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE" 2>/dev/null)" 2>/dev/null
}

sentry_start() {
    if is_running; then
        _yellow "Sentry already running (PID $(cat "$PID_FILE"))"
        return 0
    fi

    if [ ! -x "$SENTRY_BIN" ]; then
        _red "Sentry binary not found at ${SENTRY_BIN}"
        return 1
    fi

    local cmd="$SENTRY_BIN --daemon --sentry-pid $PID_FILE --sentry-log $LOG_FILE"
    [ -n "$ALERT_HOOK" ] && cmd="$cmd --alert-hook $ALERT_HOOK"

    # Run sentry in daemon mode
    $cmd &
    local pid=$!
    echo "$pid" > "$PID_FILE"

    # Verify it started
    sleep 1
    if kill -0 "$pid" 2>/dev/null; then
        _green "Sentry daemon started (PID ${pid})"
        _info "Log: ${LOG_FILE}"
    else
        rm -f "$PID_FILE"
        _red "Sentry failed to start — check ${LOG_FILE}"
        return 1
    fi
}

sentry_stop() {
    if ! is_running; then
        _yellow "Sentry not running"
        rm -f "$PID_FILE"
        return 0
    fi

    local pid
    pid=$(cat "$PID_FILE" 2>/dev/null)
    kill "$pid" 2>/dev/null
    # Wait for graceful shutdown
    local i=0
    while kill -0 "$pid" 2>/dev/null && [ $i -lt 10 ]; do
        sleep 1
        i=$((i + 1))
    done

    if kill -0 "$pid" 2>/dev/null; then
        kill -9 "$pid" 2>/dev/null
    fi

    rm -f "$PID_FILE"
    _green "Sentry daemon stopped"
}

sentry_status() {
    if is_running; then
        local pid
        pid=$(cat "$PID_FILE" 2>/dev/null)
        _green "Sentry ACTIVE (PID ${pid})"
        if [ -f "$LOG_FILE" ]; then
            local lines
            lines=$(wc -l < "$LOG_FILE" 2>/dev/null || echo "0")
            _info "Log entries: ${lines}"
            local last
            last=$(tail -1 "$LOG_FILE" 2>/dev/null)
            [ -n "$last" ] && _info "Last: ${last}"
        fi
    else
        _yellow "Sentry NOT running"
        rm -f "$PID_FILE"
    fi
}

case "${1:-}" in
    start)   sentry_start ;;
    stop)    sentry_stop ;;
    restart)
        sentry_stop
        sleep 1
        sentry_start
        ;;
    status)  sentry_status ;;
    *)
        echo "Usage: opsec-sentry.sh start|stop|status|restart"
        exit 1
        ;;
esac
