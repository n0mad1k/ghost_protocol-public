#!/bin/bash
# /usr/local/bin/opsec-ssh-check.sh — SSH Honeypot Detection
# Checks target SSH banners for known honeypot signatures
# Alias: ssh-safe
#
# Usage: opsec-ssh-check.sh <host> [port]

set -euo pipefail

OPSEC_LIB="/usr/local/lib/opsec/opsec-lib.sh"
if [ -f "$OPSEC_LIB" ]; then
    . "$OPSEC_LIB"
else
    opsec_green()  { echo -e "\033[38;5;49m[+] $*\033[0m"; }
    opsec_red()    { echo -e "\033[38;5;196m[-] $*\033[0m"; }
    opsec_yellow() { echo -e "\033[38;5;214m[*] $*\033[0m"; }
    opsec_info()   { echo -e "\033[38;5;39m[~] $*\033[0m"; }
    opsec_cyan()   { echo -e "\033[38;5;51m[>] $*\033[0m"; }
    opsec_hdr()    { echo -e "\033[38;5;51m━━━ \033[38;5;201m$*\033[38;5;51m ━━━\033[0m"; }
fi

HOST="${1:-}"
PORT="${2:-22}"

if [ -z "$HOST" ]; then
    echo "Usage: $(basename "$0") <host> [port]"
    echo "       ssh-safe <host> [port]"
    exit 1
fi

opsec_hdr "SSH HONEYPOT CHECK: ${HOST}:${PORT}"
echo ""

SUSPICIOUS=0

# ─── GRAB BANNER ───────────────────────────────────────────────────────────────
opsec_info "Grabbing SSH banner..."
BANNER=$(timeout 5 bash -c "echo '' | nc -w 3 $HOST $PORT 2>/dev/null" || true)

if [ -z "$BANNER" ]; then
    opsec_yellow "No banner received — port may be filtered or service is not SSH"
    exit 1
fi

opsec_cyan "Banner: ${BANNER}"
echo ""

# ─── KNOWN HONEYPOT SIGNATURES ─────────────────────────────────────────────────

# Cowrie
if echo "$BANNER" | grep -qiE 'SSH-2\.0-OpenSSH_6\.(0|1|2|6)p1.*Debian'; then
    opsec_red "COWRIE SIGNATURE: Old OpenSSH version commonly used by Cowrie honeypot"
    SUSPICIOUS=$((SUSPICIOUS + 3))
fi

# Kippo
if echo "$BANNER" | grep -qi 'SSH-1\.99-OpenSSH_5\.1p1'; then
    opsec_red "KIPPO SIGNATURE: SSH-1.99 with OpenSSH_5.1p1 is a known Kippo default"
    SUSPICIOUS=$((SUSPICIOUS + 3))
fi

# HonSSH
if echo "$BANNER" | grep -qi 'HonSSH'; then
    opsec_red "HONSH SIGNATURE: Banner explicitly mentions HonSSH"
    SUSPICIOUS=$((SUSPICIOUS + 5))
fi

# Generic old version check
if echo "$BANNER" | grep -qE 'OpenSSH_[345]\.' ; then
    opsec_yellow "SUSPICIOUS: Very old OpenSSH version (common in honeypots)"
    SUSPICIOUS=$((SUSPICIOUS + 2))
fi

# Unusual SSH protocol version
if echo "$BANNER" | grep -q 'SSH-1\.'; then
    opsec_yellow "SUSPICIOUS: SSHv1 protocol (deprecated, often honeypot)"
    SUSPICIOUS=$((SUSPICIOUS + 2))
fi

# ─── KEY EXCHANGE CHECK ────────────────────────────────────────────────────────
opsec_info "Checking key exchange algorithms..."

KEX_OUTPUT=$(timeout 5 ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o BatchMode=yes -o ConnectTimeout=3 -v -p "$PORT" "check@${HOST}" 2>&1 || true)

# Check for weak/unusual key types
if echo "$KEX_OUTPUT" | grep -qi 'ssh-dss'; then
    opsec_yellow "SUSPICIOUS: DSA host key (often seen in honeypots)"
    SUSPICIOUS=$((SUSPICIOUS + 1))
fi

# Check for unusually fast key exchange (honeypots often respond instantly)
if echo "$KEX_OUTPUT" | grep -qi 'Connection reset\|Connection refused'; then
    opsec_info "Connection dropped (may be rate-limited or filtered)"
fi

# ─── TIMING CHECK ─────────────────────────────────────────────────────────────
opsec_info "Checking authentication timing..."
AUTH_START=$(date +%s%N)
timeout 3 ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o BatchMode=yes -o ConnectTimeout=3 -p "$PORT" "probe@${HOST}" 2>/dev/null || true
AUTH_END=$(date +%s%N)
AUTH_MS=$(( (AUTH_END - AUTH_START) / 1000000 ))

if [ "$AUTH_MS" -lt 50 ] && [ "$AUTH_MS" -gt 0 ]; then
    opsec_yellow "SUSPICIOUS: Unusually fast auth response (${AUTH_MS}ms) — possible honeypot"
    SUSPICIOUS=$((SUSPICIOUS + 1))
else
    opsec_info "Auth response time: ${AUTH_MS}ms"
fi

# ─── VERDICT ───────────────────────────────────────────────────────────────────
echo ""
if [ "$SUSPICIOUS" -ge 3 ]; then
    opsec_red "VERDICT: HIGH RISK — Likely honeypot (score: ${SUSPICIOUS})"
    opsec_red "DO NOT connect to this host for operations"
elif [ "$SUSPICIOUS" -ge 1 ]; then
    opsec_yellow "VERDICT: MODERATE RISK — Some anomalies detected (score: ${SUSPICIOUS})"
    opsec_yellow "Proceed with caution"
else
    opsec_green "VERDICT: LOW RISK — No honeypot signatures detected (score: ${SUSPICIOUS})"
fi
echo ""
