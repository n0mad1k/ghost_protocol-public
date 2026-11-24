#!/bin/bash
# Root integration test for system Tor + strict nft + browser-policy transactions.

set -euo pipefail
umask 077

[ "${EUID:-$(id -u)}" -eq 0 ] || { echo "FAIL: root is required" >&2; exit 1; }
[[ "${1:-}" =~ ^[0-9]+$ ]] && [ "$1" -ge 1000 ] || { echo "FAIL: numeric desktop UID is required" >&2; exit 1; }

desktop_uid="$1"
passwd=$(getent passwd "$desktop_uid") || { echo "FAIL: UID does not exist" >&2; exit 1; }
desktop_user=$(cut -d: -f1 <<<"$passwd")
desktop_home=$(cut -d: -f6 <<<"$passwd")
[ -d "$desktop_home" ] && [ "$(stat -c %u "$desktop_home")" = "$desktop_uid" ] || {
    echo "FAIL: UID does not own its home" >&2
    exit 1
}

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
policy="$repo/scripts/opsec-browser-policy.sh"
killswitch="$repo/scripts/opsec-killswitch.sh"
export OPSEC_KILLSWITCH_BIN="$killswitch"
export OPSEC_POLICY_SOURCE="$repo/configs/apparmor/opsec-dirty-browser-block"
txn="/var/lib/opsec/browser-policy/$desktop_uid"
run_root=/run/opsec
firefox_local=/etc/apparmor.d/local/firefox
torbrowser_local=/etc/apparmor.d/local/torbrowser.Browser.firefox
cleanup_needed=false
strict_owned=false
strict_fingerprint=""
tor_service=""
tor_started=false
torrc_backup="$run_root/browser-live-torrc.$$.bak"
torrc_changed=false
watchdog_seconds="${OPSEC_TEST_ROLLBACK_SECONDS:-120}"
watchdog_unit="opsec-browser-live-rollback-$$"
watchdog_script="$run_root/browser-live-rollback.$$.sh"
watchdog_armed=false

exec 8>"$run_root/browser-live-test.lock"
flock -n 8 || { echo "FAIL: another browser-policy integration test is active" >&2; exit 1; }
exec 9>"$run_root/mode.lock"
flock -n 9 || { echo "FAIL: an OPSEC mode operation is active" >&2; exit 1; }
[ ! -e /var/run/opsec-advanced.enabled ] && [ ! -e "$run_root/activation-in-progress" ] || {
    echo "FAIL: OPSEC mode is active or activating" >&2
    exit 1
}

hash_or_absent() { if [ -e "$1" ]; then sha256sum "$1" | awk '{print $1}'; else printf 'absent\n'; fi; }
fingerprint_strict() {
    nft -j list table inet opsec_strict | jq -S 'walk(if type == "object" then del(.handle, .packets, .bytes) else . end)' | sha256sum | awk '{print $1}'
}
assert_strict() { "$killswitch" strict-status >/dev/null; }
direct_https_works() {
    env -u http_proxy -u https_proxy -u all_proxy -u no_proxy \
        -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u NO_PROXY \
        curl -4 --fail --silent --show-error --noproxy '*' --connect-timeout 3 --max-time 7 "$1" >/dev/null 2>&1
}
tor_https_works() {
    local response
    response=$(env -u http_proxy -u https_proxy -u all_proxy -u no_proxy \
        -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u NO_PROXY \
        curl -4 --fail --silent --show-error --noproxy '*' --connect-timeout 5 --max-time 20 \
        https://check.torproject.org/api/ip) || return 1
    jq -e '.IsTor == true' <<<"$response" >/dev/null
}
loopback_dns_works() {
    env -u LOCALDOMAIN -u RES_OPTIONS timeout 10 dig +short +time=3 +tries=2 \
        @127.0.0.1 check.torproject.org A 2>/dev/null | grep -Eq '^[0-9]+(\.[0-9]+){3}$'
}

find_tor_service() {
    local unit
    for unit in tor@default.service tor.service; do
        systemctl cat "$unit" >/dev/null 2>&1 && { printf '%s\n' "$unit"; return 0; }
    done
    return 1
}

prepare_tor_config() {
    [ -f /etc/tor/torrc ] && [ ! -L /etc/tor/torrc ] || {
        echo "FAIL: /etc/tor/torrc must be a regular non-symlink file" >&2
        return 1
    }
    cp --preserve=all /etc/tor/torrc "$torrc_backup"
    chmod 0600 "$torrc_backup"
    torrc_changed=true
    (
        . "$repo/lib/opsec-lib.sh"
        opsec_generate_torrc
    ) || return 1
    /usr/bin/tor -f /etc/tor/torrc --verify-config >/dev/null
}

restore_tor_config() {
    if "$torrc_changed"; then
        cp --preserve=all "$torrc_backup" /etc/tor/torrc
        rm -f "$torrc_backup"
        torrc_changed=false
    fi
}

tor_listeners_ready() {
    ss -H -ltn | awk '$4 == "127.0.0.1:9050" {s=1} $4 == "127.0.0.1:9040" {t=1} END {exit !(s && t)}' &&
        ss -H -lun | awk '$5 == "127.0.0.1:5353" || $4 == "127.0.0.1:5353" {d=1} END {exit !d}'
}

tor_socks_ready() {
    local response
    response=$(env -u http_proxy -u https_proxy -u all_proxy -u no_proxy \
        -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u NO_PROXY \
        curl -4 --fail --silent --show-error --connect-timeout 5 --max-time 20 \
        --socks5-hostname 127.0.0.1:9050 https://check.torproject.org/api/ip) || return 1
    jq -e '.IsTor == true' <<<"$response" >/dev/null
}

ensure_tor_ready() {
    local attempt
    tor_service=$(find_tor_service) || { echo "FAIL: system Tor service is unavailable" >&2; return 1; }
    if ! systemctl is-active --quiet "$tor_service"; then
        systemctl reset-failed "$tor_service" >/dev/null 2>&1 || true
        systemctl start "$tor_service"
        tor_started=true
    fi
    for attempt in $(seq 1 12); do
        if tor_listeners_ready && tor_socks_ready; then
            echo "[+] System Tor ready via $tor_service"
            return 0
        fi
        sleep 5
    done
    echo "FAIL: system Tor did not expose verified SOCKS, TransPort, and DNSPort listeners" >&2
    return 1
}

assert_no_probe_residue() {
    ! find "$run_root" -maxdepth 1 -type d -name '.aa-*' -print -quit 2>/dev/null | grep -q . || {
        echo "FAIL: browser probe directory remains" >&2
        return 1
    }
    ! pgrep -u "$desktop_uid" -f -- '/run/opsec/.aa-' >/dev/null 2>&1 || {
        echo "FAIL: browser probe process remains" >&2
        return 1
    }
}

assert_packaged_unconfined() {
    local wanted="$1" dir
    [ -f "/etc/apparmor.d/$wanted" ] || return 0
    for dir in /sys/kernel/security/apparmor/policy/profiles/*; do
        [ -d "$dir" ] || continue
        [ "$(cat "$dir/name" 2>/dev/null)" = "$wanted" ] || continue
        [ "$(cat "$dir/mode" 2>/dev/null)" = unconfined ] || {
            echo "FAIL: packaged $wanted profile was not restored unconfined" >&2
            return 1
        }
        return 0
    done
    echo "FAIL: packaged $wanted profile is not loaded" >&2
    return 1
}

assert_recovered() {
    [ ! -e "$txn" ] || { echo "FAIL: policy transaction remains" >&2; return 1; }
    for profile in opsec-dirty-brave opsec-dirty-brave-debian opsec-dirty-chromium opsec-dirty-firefox \
        opsec-dirty-tor-browser opsec-dirty-tor-browser-real; do
        ! aa-status --show=profiles 2>/dev/null | grep -qx "$profile" || {
            echo "FAIL: custom profile remains loaded: $profile" >&2
            return 1
        }
    done
    assert_packaged_unconfined brave
    assert_packaged_unconfined chromium
    assert_packaged_unconfined firefox
    assert_no_probe_residue
    assert_strict
}

arm_watchdog() {
    command -v systemd-run >/dev/null 2>&1 || {
        echo "FAIL: systemd-run is required for independent timeout rollback" >&2
        return 1
    }
    [[ "$watchdog_seconds" =~ ^[0-9]+$ ]] && [ "$watchdog_seconds" -ge 30 ] || {
        echo "FAIL: rollback timeout must be at least 30 seconds" >&2
        return 1
    }
    cat > "$watchdog_script" <<EOF
#!/bin/bash
set +e
export OPSEC_KILLSWITCH_BIN=$(printf '%q' "$killswitch")
$(printf '%q' "$policy") recover $(printf '%q' "$desktop_uid") >/dev/null 2>&1
$(printf '%q' "$killswitch") strict-off >/dev/null 2>&1
$(if "$tor_started"; then printf 'systemctl stop %q >/dev/null 2>&1\n' "$tor_service"; fi)
$(if "$torrc_changed"; then printf 'cp --preserve=all %q /etc/tor/torrc && rm -f %q\n' "$torrc_backup" "$torrc_backup"; fi)
rm -f $(printf '%q' "$watchdog_script")
EOF
    chmod 0700 "$watchdog_script"
    systemd-run --quiet --unit="$watchdog_unit" --on-active="${watchdog_seconds}s" \
        --timer-property=AccuracySec=1s /bin/bash "$watchdog_script"
    systemctl is-active --quiet "${watchdog_unit}.timer" || {
        rm -f "$watchdog_script"
        echo "FAIL: timeout rollback timer did not arm" >&2
        return 1
    }
    watchdog_armed=true
    echo "[+] Independent rollback armed for ${watchdog_seconds}s"
}

cancel_watchdog() {
    if "$watchdog_armed"; then
        systemctl stop "${watchdog_unit}.timer" "${watchdog_unit}.service" >/dev/null 2>&1 || true
        systemctl reset-failed "${watchdog_unit}.service" >/dev/null 2>&1 || true
        rm -f "$watchdog_script"
        watchdog_armed=false
    fi
}

cleanup() {
    local body_status="$1" cleanup_status=0 current_fingerprint=""
    trap - EXIT INT TERM
    if [ "$cleanup_needed" = true ] || [ -e "$txn" ]; then
        "$policy" recover "$desktop_uid" || cleanup_status=1
    fi
    if "$strict_owned"; then
        current_fingerprint=$(fingerprint_strict 2>/dev/null || true)
        if [ -n "$strict_fingerprint" ] && [ "$current_fingerprint" != "$strict_fingerprint" ]; then
            echo "WARNING: harness-owned strict table changed; forcing timeout-safe network restore" >&2
        fi
        "$killswitch" strict-off || cleanup_status=1
        ! nft list table inet opsec_strict >/dev/null 2>&1 || cleanup_status=1
    fi
    if "$tor_started"; then
        systemctl stop "$tor_service" >/dev/null 2>&1 || cleanup_status=1
        tor_started=false
    fi
    restore_tor_config || cleanup_status=1
    cancel_watchdog
    if [ "$cleanup_status" -ne 0 ]; then
        echo "FAIL: cleanup incomplete; transaction=$txn strict_owned=$strict_owned" >&2
        exit 1
    fi
    exit "$body_status"
}
trap 'cleanup $?' EXIT
trap 'exit 130' INT TERM

prepare_tor_config
ensure_tor_ready

if nft list table inet opsec_strict >/dev/null 2>&1; then
    assert_strict || { echo "FAIL: pre-existing strict nft table is malformed" >&2; exit 1; }
else
    arm_watchdog
    strict_owned=true
    if ! "$killswitch" strict-on; then
        echo "FAIL: strict firewall loaded but did not pass structural verification" >&2
        nft -j list table inet opsec_strict 2>&1 | jq . >&2 || true
        echo "Recorded policy state:" >&2
        cat /run/opsec/strict-policy.state >&2 2>/dev/null || true
        exit 1
    fi
    assert_strict || { echo "FAIL: harness could not verify its strict nft table" >&2; exit 1; }
    strict_fingerprint=$(fingerprint_strict)
fi

if ! tor_https_works; then
    echo "FAIL: transparent HTTPS was not forced through Tor" >&2
    exit 1
fi
if ! loopback_dns_works; then
    echo "FAIL: loopback DNS was not redirected to Tor DNSPort" >&2
    exit 1
fi

# Recover only this UID's interrupted transaction from a previous failed activation.
if [ -e "$txn" ]; then "$policy" recover "$desktop_uid"; fi
assert_recovered
pre_firefox=$(hash_or_absent "$firefox_local")
pre_torbrowser=$(hash_or_absent "$torbrowser_local")

for cycle in 1 2; do
    cleanup_needed=true
    "$policy" apply "$desktop_uid"
    jq -e '.phase == "applied"' "$txn/manifest.json" >/dev/null
    "$policy" status "$desktop_uid"
    assert_no_probe_residue
    assert_strict
    "$policy" recover "$desktop_uid"
    cleanup_needed=false
    assert_recovered
    [ "$(hash_or_absent "$firefox_local")" = "$pre_firefox" ] || { echo "FAIL: Firefox local policy was not restored" >&2; exit 1; }
    [ "$(hash_or_absent "$torbrowser_local")" = "$pre_torbrowser" ] || { echo "FAIL: Tor Browser local policy was not restored" >&2; exit 1; }
    echo "PASS: browser policy cycle $cycle"
done

if "$strict_owned"; then
    [ "$(fingerprint_strict)" = "$strict_fingerprint" ] || { echo "FAIL: strict nft fingerprint changed" >&2; exit 1; }
    "$killswitch" strict-off
    strict_owned=false
    if "$tor_started"; then
        systemctl stop "$tor_service"
        tor_started=false
    fi
    restore_tor_config
    cancel_watchdog
    if ! direct_https_works https://check.torproject.org/api/ip && ! direct_https_works https://example.com/; then
        echo "FAIL: normal direct HTTPS was not restored after harness cleanup" >&2
        exit 1
    fi
fi

echo "PASS: strict firewall and browser policy integration for $desktop_user ($desktop_uid)"
