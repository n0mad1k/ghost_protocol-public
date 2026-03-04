#!/bin/bash
# opsec-mode-toggle — Keyboard shortcut wrapper for opsec-mode on/off
# Toggles between standard and advanced OPSEC mode
# Bind to: Ctrl+Alt+\

STATE_FILE="/var/run/opsec-advanced.enabled"
BOOTSTRAP_STOP="/var/run/opsec-bootstrap-stop"
DEBUG_LOG="/var/log/opsec-debug.log"

toggle_log() {
    echo "[$(date -Is)] [toggle] $*" >> "$DEBUG_LOG" 2>/dev/null || true
}

if [ -f "$STATE_FILE" ]; then
    # Turning OFF — signal bootstrap loop to stop, then run mode_off
    toggle_log "Toggling OFF (state file exists)"
    # Create stop signal so mode_on's bootstrap loop exits immediately
    # (needs root — use pkexec for a one-liner)
    pkexec bash -c "touch ${BOOTSTRAP_STOP} && /usr/local/bin/opsec-mode.sh off"
    toggle_log "Toggle OFF complete (exit: $?)"
else
    toggle_log "Toggling ON (no state file)"
    pkexec /usr/local/bin/opsec-mode.sh on
    toggle_log "Toggle ON complete (exit: $?)"
fi
