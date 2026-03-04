#!/bin/bash
# OPSEC Toggle — single entry point for keyboard shortcut + desktop file
# Uses pkexec directly on opsec-mode.sh for proper polkit policy matching
OPSEC_MODE="/usr/local/bin/opsec-mode.sh"
STATE_FILE="/var/run/opsec-advanced.enabled"

[ ! -x "$OPSEC_MODE" ] && exit 1

if [ -f "$STATE_FILE" ]; then
    # Turning OFF — opsec-mode.sh off handles bootstrap stop signal internally
    if [ "$EUID" -eq 0 ] 2>/dev/null; then
        "$OPSEC_MODE" off
    else
        pkexec "$OPSEC_MODE" off
    fi
else
    # Turning ON — pkexec prompts for auth via polkit policy
    if [ "$EUID" -eq 0 ] 2>/dev/null; then
        "$OPSEC_MODE" on
    else
        pkexec "$OPSEC_MODE" on
    fi
fi
