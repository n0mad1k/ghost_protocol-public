#!/bin/bash
# /usr/local/bin/opsec-log-rotate.sh — Secure log rotation and cleanup
# Truncates sensitive logs, shreds rotated files, clears journald + shell histories
# Runs via cron (configurable LOG_ROTATION_HOURS in /etc/opsec/opsec.conf)

set -euo pipefail

if [ "$EUID" -ne 0 ]; then
    echo "[-] Please run as root"
    exit 1
fi

OPSEC_LIB="/usr/local/lib/opsec/opsec-lib.sh"
_HAS_LIB=false
if [ -f "$OPSEC_LIB" ]; then
    . "$OPSEC_LIB"
    opsec_load_config 2>/dev/null || true
    _HAS_LIB=true
else
    opsec_green()  { echo "[+] $*"; }
    opsec_info()   { echo "[~] $*"; }
fi

LOG_FILE="/var/log/opsec-log-rotate.log"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

log() { echo "[$TIMESTAMP] $*" >> "$LOG_FILE"; }

log "Starting secure log rotation"

# ─── TRUNCATE SENSITIVE SYSTEM LOGS ────────────────────────────────────────────
SENSITIVE_LOGS=(
    /var/log/auth.log
    /var/log/syslog
    /var/log/kern.log
    /var/log/daemon.log
    /var/log/messages
    /var/log/user.log
    /var/log/mail.log
    /var/log/debug
    /var/log/wtmp
    /var/log/btmp
    /var/log/lastlog
    /var/log/faillog
)

for logfile in "${SENSITIVE_LOGS[@]}"; do
    if [ -f "$logfile" ]; then
        truncate -s 0 "$logfile" 2>/dev/null || true
        log "Truncated: $logfile"
    fi
done

# ─── SHRED ROTATED LOG FILES (SSD-aware) ─────────────────────────────────────
for rotated in /var/log/*.gz /var/log/*.1 /var/log/*.old; do
    if [ -f "$rotated" ]; then
        if [ "$_HAS_LIB" = "true" ]; then
            opsec_secure_delete "$rotated"
        else
            shred -fuz "$rotated" 2>/dev/null || rm -f "$rotated"
        fi
        log "Wiped: $rotated"
    fi
done

# ─── CLEAR JOURNALD ───────────────────────────────────────────────────────────
if command -v journalctl >/dev/null 2>&1; then
    journalctl --vacuum-time=1h 2>/dev/null || true
    log "Journald vacuumed (1h retention)"
fi

# ─── CLEAR SHELL HISTORIES ────────────────────────────────────────────────────
for user_home in /home/* /root; do
    [ -d "$user_home" ] || continue
    for hist_file in .bash_history .zsh_history .python_history .psql_history .mysql_history .lesshst .viminfo; do
        if [ -f "${user_home}/${hist_file}" ]; then
            if [ "$_HAS_LIB" = "true" ]; then
                opsec_secure_delete "${user_home}/${hist_file}"
            else
                shred -fuz "${user_home}/${hist_file}" 2>/dev/null || truncate -s 0 "${user_home}/${hist_file}" 2>/dev/null || true
            fi
            log "Cleared: ${user_home}/${hist_file}"
        fi
    done
done

# ─── CLEAR RECENTLY USED ──────────────────────────────────────────────────────
for user_home in /home/* /root; do
    [ -d "$user_home" ] || continue
    rm -f "${user_home}/.local/share/recently-used.xbel" 2>/dev/null || true
done

# ─── CLEAR TEMP FILES ─────────────────────────────────────────────────────────
find /tmp -type f -mmin +60 -delete 2>/dev/null || true
find /var/tmp -type f -mmin +60 -delete 2>/dev/null || true

log "Secure log rotation complete"
