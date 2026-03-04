#!/bin/bash
# /usr/local/bin/opsec-boot-init.sh — Level-aware boot initializer
# Called by opsec-boot-advanced.service at boot
# Standard levels: apply base privacy hardening only
# Paranoid levels: activate full ghost mode

set -euo pipefail

BOOT_MARKER="/etc/opsec/boot-advanced.enabled"
STATE_FILE="/var/run/opsec-advanced.enabled"
OPSEC_LIB="/usr/local/lib/opsec/opsec-lib.sh"
OPSEC_CONF="/etc/opsec/opsec.conf"

# Source shared library if available
if [ -f "$OPSEC_LIB" ]; then
    . "$OPSEC_LIB"
    opsec_load_config 2>/dev/null || true
fi

# Load config directly if lib not available
if [ -f "$OPSEC_CONF" ]; then
    . "$OPSEC_CONF"
fi

LEVEL_TYPE="${LEVEL_TYPE:-standard}"
DEPLOYMENT_LEVEL="${DEPLOYMENT_LEVEL:-bare-metal-standard}"

echo "[opsec-boot] Level: ${DEPLOYMENT_LEVEL} (type: ${LEVEL_TYPE})"

# Paranoid levels: always activate full ghost mode
if [ "$LEVEL_TYPE" = "paranoid" ]; then
    echo "[opsec-boot] Paranoid level detected — activating full ghost mode"
    touch "$STATE_FILE"

    if [ -x /usr/local/bin/opsec-mode.sh ]; then
        /usr/local/bin/opsec-mode.sh on
    else
        echo "[opsec-boot] ERROR: opsec-mode.sh not found"
        exit 1
    fi

    echo "[opsec-boot] Ghost mode activated at boot (paranoid level)"
    exit 0
fi

# Standard levels: check boot marker, apply base or full accordingly
if [ -f "$BOOT_MARKER" ]; then
    echo "[opsec-boot] Boot marker detected — activating ghost mode"
    touch "$STATE_FILE"

    if [ -x /usr/local/bin/opsec-mode.sh ]; then
        /usr/local/bin/opsec-mode.sh on
    else
        echo "[opsec-boot] ERROR: opsec-mode.sh not found"
        exit 1
    fi

    echo "[opsec-boot] Ghost mode activated at boot (boot marker)"
else
    echo "[opsec-boot] Standard level, no boot marker — applying base privacy hardening"

    # Apply base hardening inline (cannot source opsec-mode.sh — its exit kills the caller)
    echo "[opsec-boot] Applying inline base hardening..."
    sysctl -w net.ipv6.conf.all.disable_ipv6=1 >/dev/null 2>&1 || true
    sysctl -w net.ipv6.conf.default.disable_ipv6=1 >/dev/null 2>&1 || true
    swapoff -a 2>/dev/null || true
    sysctl -w kernel.core_pattern='|/bin/false' >/dev/null 2>&1 || true

    # Set privacy DNS
    base_dns="${BASE_DNS:-quad9}"
    chattr -i /etc/resolv.conf 2>/dev/null || true
    case "$base_dns" in
        quad9)
            printf "nameserver 9.9.9.9\nnameserver 149.112.112.112\n" > /etc/resolv.conf
            ;;
        cloudflare)
            printf "nameserver 1.1.1.1\nnameserver 1.0.0.1\n" > /etc/resolv.conf
            ;;
    esac

    echo "[opsec-boot] Base privacy hardening applied"
fi
