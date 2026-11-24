#!/bin/bash
# opsec-mode-toggle — Keyboard shortcut wrapper for opsec-mode on/off
# Toggles between standard and advanced OPSEC mode
# Bind to: Ctrl+Alt+\

STATE_FILE="/var/run/opsec-advanced.enabled"
FAILED_FILE="/run/opsec/activation-failed"
ACTIVATING_FILE="/run/opsec/activation-in-progress"
BOOTSTRAP_STOP="/var/run/opsec-bootstrap-stop"
DEBUG_LOG="/var/log/opsec-debug.log"

toggle_log() {
    echo "[$(date -Is)] [toggle] $*" >> "$DEBUG_LOG" 2>/dev/null || true
}

if [ -f "$STATE_FILE" ] || [ -f "$FAILED_FILE" ] || [ -f "$ACTIVATING_FILE" ]; then
    # Turning OFF — signal bootstrap loop to stop, then run mode_off
    toggle_log "Toggling OFF (state file exists)"
    pkexec /usr/local/bin/opsec-mode.sh off
    toggle_log "Toggle OFF complete (exit: $?)"
else
    toggle_log "Toggling ON (no state file)"
    pkexec /usr/local/bin/opsec-mode.sh on
    toggle_log "Toggle ON complete (exit: $?)"
fi
