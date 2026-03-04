#!/bin/bash
# OPSEC Hostname Randomization
# Config-aware: reads HOSTNAME_PATTERN and HOSTNAME_CUSTOM_PREFIX from /etc/opsec/opsec.conf
# Patterns: desktop (desktop-XXXX), random (8 random chars), custom (PREFIX-XXXX)

if [ "$EUID" -ne 0 ]; then
    echo "Please run as root"
    exit 1
fi

# Source config if available
OPSEC_LIB="/usr/local/lib/opsec/opsec-lib.sh"
if [ -f "$OPSEC_LIB" ]; then
    . "$OPSEC_LIB"
    opsec_load_config 2>/dev/null || true
else
    opsec_green()  { echo -e "\033[38;5;49m[+] $*\033[0m"; }
    opsec_info()   { echo -e "\033[38;5;39m[~] $*\033[0m"; }
    opsec_dim()    { echo -e "\033[38;5;244m    $*\033[0m"; }
fi

# Config values with defaults
PATTERN="${HOSTNAME_PATTERN:-desktop}"
PREFIX="${HOSTNAME_CUSTOM_PREFIX:-}"

RAND_HEX=$(head -c 2 /dev/urandom | od -An -tx1 | tr -d ' ')
OLD_HOSTNAME=$(hostname)

case "$PATTERN" in
    desktop)
        NEW_HOSTNAME="desktop-${RAND_HEX}"
        ;;
    random)
        NEW_HOSTNAME=$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' ')
        ;;
    custom)
        NEW_HOSTNAME="${PREFIX}-${RAND_HEX}"
        ;;
    *)
        NEW_HOSTNAME="desktop-${RAND_HEX}"
        ;;
esac

opsec_info "Randomizing hostname..."
opsec_dim "Old: ${OLD_HOSTNAME}"
opsec_dim "New: ${NEW_HOSTNAME} (pattern: ${PATTERN})"

# Set hostname via hostnamectl (persistent)
hostnamectl set-hostname "$NEW_HOSTNAME" 2>/dev/null || {
    echo "$NEW_HOSTNAME" > /etc/hostname
    hostname "$NEW_HOSTNAME"
}

# Update /etc/hosts to match
if grep -q "$OLD_HOSTNAME" /etc/hosts 2>/dev/null; then
    sed -i "s/$OLD_HOSTNAME/$NEW_HOSTNAME/g" /etc/hosts
fi

# Ensure localhost entries exist
if ! grep -q "127.0.0.1.*$NEW_HOSTNAME" /etc/hosts; then
    sed -i "/127\.0\.0\.1/s/$/ $NEW_HOSTNAME/" /etc/hosts
fi

opsec_green "Hostname randomized to: ${NEW_HOSTNAME}"
