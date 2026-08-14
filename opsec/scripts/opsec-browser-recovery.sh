#!/bin/bash
# Early-boot recovery for interrupted persistent browser-policy transactions.

set -euo pipefail

STATE_ROOT="/var/lib/opsec/browser-policy"
FAILED_FILE="/run/opsec/activation-failed"
MASK_FILE="/run/opsec/browser-recovery.masks"

mark_failed() {
    install -d -o root -g root -m 0700 /run/opsec
    tmp=$(mktemp /run/opsec/.activation-failed.XXXXXX)
    printf 'browser-policy-recovery\n' > "$tmp"
    chmod 0600 "$tmp"
    mv -f "$tmp" "$FAILED_FILE"
}

block_network_services() {
    [ -f "$MASK_FILE" ] || : > "$MASK_FILE"
    chmod 0600 "$MASK_FILE"
    for unit in NetworkManager.service networking.service systemd-networkd.service; do
        if systemctl list-unit-files "$unit" --no-legend 2>/dev/null | grep -q "^$unit"; then
            case "$(systemctl is-enabled "$unit" 2>/dev/null || true)" in
                masked|masked-runtime) continue ;;
            esac
            systemctl stop "$unit" >/dev/null 2>&1 || true
            if systemctl mask --runtime "$unit" >/dev/null 2>&1; then
                grep -qxF "$unit" "$MASK_FILE" || echo "$unit" >> "$MASK_FILE"
            fi
        fi
    done
}

[ -d "$STATE_ROOT" ] || install -d -o root -g root -m 0700 "$STATE_ROOT"
mapfile -t txns < <(find "$STATE_ROOT" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | grep -E '^[0-9]+$' || true)
[ "${#txns[@]}" -gt 0 ] || [ -f /etc/opsec/boot-advanced.enabled ] || exit 0

if ! /usr/local/bin/opsec-killswitch.sh strict-on || ! /usr/local/bin/opsec-killswitch.sh strict-status; then
    /usr/local/bin/opsec-killswitch.sh emergency-on >/dev/null 2>&1 || true
    mark_failed
    block_network_services
    exit 1
fi

for uid in "${txns[@]}"; do
    if ! /usr/local/bin/opsec-browser-policy.sh recover "$uid"; then
        mark_failed
        block_network_services
        exit 1
    fi
done

if find "$STATE_ROOT" -mindepth 1 -maxdepth 1 -type d -print -quit | grep -q .; then
    mark_failed
    block_network_services
    exit 1
fi

for profile in opsec-dirty-brave opsec-dirty-brave-debian opsec-dirty-chromium \
    opsec-dirty-tor-browser opsec-dirty-tor-browser-real; do
    if aa-status --show=profiles 2>/dev/null | grep -qx "$profile"; then
        mark_failed
        block_network_services
        exit 1
    fi
done

if [ ! -f /etc/opsec/boot-advanced.enabled ]; then
    /usr/local/bin/opsec-killswitch.sh strict-off
fi
