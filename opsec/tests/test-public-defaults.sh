#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
failures=0

pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; failures=$((failures + 1)); }

assert_absent() {
    local pattern="$1" label="$2"
    if rg -n --glob '*.conf' --glob '*.sh' --glob 'torrc-*' "$pattern" "$ROOT/configs" "$ROOT/lib" "$ROOT/scripts" >/dev/null; then
        fail "$label"
    else
        pass "$label"
    fi
}

for config in "$ROOT/configs/opsec.conf" "$ROOT"/configs/levels/*.conf; do
    for assignment in \
        'TOR_CIRCUIT_ROTATION=""' \
        'TOR_BLACKLIST=""' \
        'TOR_STRICT_NODES=""' \
        'TOR_PADDING=""' \
        'TOR_NUM_GUARDS=""' \
        'TOR_BRIDGE_MODE="off"' \
        'TRAFFIC_BLEND_ENABLED="0"'; do
        grep -Fqx "$assignment" "$config" || fail "$(basename "$config") does not preserve upstream default: $assignment"
    done
done
pass "all shipped profiles preserve upstream Tor defaults"

assert_absent 'TOR_BLACKLIST="us,gb,ca,au,nz' "no private exit blacklist default"
assert_absent 'TOR_CIRCUIT_ROTATION="(15|30)"' "no forced rapid circuit lifetime"
assert_absent '^MaxCircuitDirtiness[[:space:]]+[0-9]+' "no static circuit lifetime directive"
assert_absent '^NumEntryGuards[[:space:]]+[0-9]+' "no static guard-count directive"
assert_absent '^ConnectionPadding[[:space:]]+[01]' "no static padding directive"

if rg -n 'if \[ "\$\{TRAFFIC_BLEND_ENABLED:-0\}" = "1" \].*opsec-traffic-blend' "$ROOT/scripts/opsec-mode.sh" >/dev/null; then
    pass "traffic blending is explicit opt-in"
else
    fail "traffic blending is not guarded by explicit opt-in"
fi

for marker in carbon oraculo '192\.168\.1\.' '100\.71\.'; do
    if rg -n -i "$marker" "$ROOT" --glob '!**/test-public-defaults.sh' --glob '!**/audit-public.sh' >/dev/null; then
        fail "private marker present: $marker"
    else
        pass "private marker absent: $marker"
    fi
done

[ "$failures" -eq 0 ] || exit 1
printf 'All public-default checks passed.\n'
