#!/bin/bash
# Runs only inside opsec-browser.service as the desktop user.

set -euo pipefail
umask 077

ACTIVE_FILE="/var/run/opsec-advanced.enabled"
FAILED_FILE="/run/opsec/activation-failed"
SOCKS_HOST="127.0.0.1"
SOCKS_PORT="${TOR_SOCKS_PORT:-9050}"
RUNTIME_ROOT="${RUNTIME_DIRECTORY:-${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/opsec-browser}"
PROBE_URL="https://check.torproject.org/api/ip"
TOR_BROWSER_VERSION="15.0.19"
TOR_BROWSER_SHA256="2eb4ab431f4921ca63b123b6f9f445a073fbf7b65f188f45a577d576eb2be2cf"
TOR_BROWSER_BUILD_ID="20260720080000"
TOR_BROWSER_SOURCE_STAMP="b98a4b6556beae53c84f445dfcc3d60784399c76"

clear_proxy_env() {
    unset http_proxy https_proxy all_proxy no_proxy
    unset HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY
}

fail() {
    echo "opsec-browser: $*" >&2
    exit 1
}

verify_immutable_archive() {
    local archive="$1" owner mode
    [ -f "$archive" ] && [ ! -L "$archive" ] || fail "packaged Tor Browser archive is missing or not a regular file"
    owner=$(stat -c %u "$archive")
    mode=$(stat -c %a "$archive")
    # A user service may see host root as overflow uid 65534.  In either
    # namespace, reject an archive owned by this user or writable by any
    # non-root principal.  The pinned SHA-256 below authenticates its bytes.
    case "$owner" in 0|65534) ;; *) fail "packaged Tor Browser archive has an untrusted owner" ;; esac
    [ $((8#$mode & 0022)) -eq 0 ] || fail "packaged Tor Browser archive is group/other writable"
}

configure_system_tor_profile() {
    local browser_root="$1" profile user_js
    profile="$browser_root/Browser/TorBrowser/Data/Browser/profile.default"
    [ -d "$profile" ] || fail "Tor Browser default profile is missing"
    user_js="$profile/user.js"
    cat >"$user_js" <<EOF
user_pref("network.proxy.type", 1);
user_pref("network.proxy.socks", "${SOCKS_HOST}");
user_pref("network.proxy.socks_port", ${SOCKS_PORT});
user_pref("network.proxy.socks_version", 5);
user_pref("network.proxy.socks_remote_dns", true);
user_pref("network.proxy.failover_direct", false);
user_pref("network.proxy.no_proxies_on", "");
user_pref("extensions.torlauncher.prompt_at_startup", false);
user_pref("extensions.torlauncher.start_tor", false);
EOF
    chmod 0600 "$user_js"
}

supervise_browser() {
    "$@" &
    browser_pid=$!
    if ! /usr/local/libexec/opsec-browser-postcheck.sh; then
        kill -TERM "$browser_pid" 2>/dev/null || true
        wait "$browser_pid" 2>/dev/null || true
        fail "post-launch system-Tor verification failed"
    fi
    wait "$browser_pid"
}

[ "$(id -u)" -ne 0 ] || fail "refusing to run Tor Browser as root"
[ -f "$ACTIVE_FILE" ] || fail "ghost mode is not active"
[ ! -e "$FAILED_FILE" ] || fail "OPSEC is failed-closed"
[ -d "$RUNTIME_ROOT" ] || fail "systemd RuntimeDirectory is missing"
[ ! -L "$RUNTIME_ROOT" ] || fail "runtime directory must not be a symlink"
[ "$(stat -c %u "$RUNTIME_ROOT")" = "$(id -u)" ] || fail "runtime directory owner mismatch"
findmnt -T "$RUNTIME_ROOT" -no OPTIONS 2>/dev/null | grep -qw noexec && fail "runtime filesystem is noexec"
[ "$(df -Pk "$RUNTIME_ROOT" | awk 'NR==2 {print $4}')" -ge 524288 ] || fail "less than 512 MiB runtime space available"

clear_proxy_env
probe=$(curl --fail --silent --show-error --connect-timeout 10 --max-time 30 \
    --socks5-hostname "${SOCKS_HOST}:${SOCKS_PORT}" "$PROBE_URL") || fail "system Tor SOCKS probe failed"
jq -e '.IsTor == true' <<<"$probe" >/dev/null || fail "system Tor SOCKS probe did not report IsTor=true"

if command -v pacman >/dev/null 2>&1 && pacman -Q tor-browser >/dev/null 2>&1; then
    version=$(pacman -Q tor-browser | awk '{print $2}')
    [ "$version" = "${TOR_BROWSER_VERSION}-1" ] || fail "unsupported Tor Browser package version: $version"
    archive="/opt/tor-browser/tor-browser-x86_64-${TOR_BROWSER_VERSION}.tar.xz"
    verify_immutable_archive "$archive"
    printf '%s  %s\n' "$TOR_BROWSER_SHA256" "$archive" | sha256sum -c - >/dev/null || fail "packaged Tor Browser archive checksum failed"
    tar -xJf "$archive" -C "$RUNTIME_ROOT"
    browser_root="$RUNTIME_ROOT/tor-browser"
    configure_system_tor_profile "$browser_root"
    launcher="$browser_root/Browser/start-tor-browser"
    [ -x "$launcher" ] || fail "extracted Tor Browser launcher is missing"
    clear_proxy_env
    export TOR_PROVIDER=none
    export TOR_SKIP_LAUNCH=1
    export TOR_SOCKS_HOST="$SOCKS_HOST"
    export TOR_SOCKS_PORT="$SOCKS_PORT"
    supervise_browser "$launcher"
    exit $?
fi

# Debian-family deployments use a root-owned, signature-verified release
# archive staged by the playbook. Never seed a disposable profile from the
# user's persistent torbrowser-launcher tree.
archive="/var/lib/opsec/tor-browser/tor-browser-linux-x86_64-${TOR_BROWSER_VERSION}.tar.xz"
if [ -f "$archive" ] && [ ! -L "$archive" ]; then
    verify_immutable_archive "$archive"
    printf '%s  %s\n' "$TOR_BROWSER_SHA256" "$archive" | sha256sum -c - >/dev/null || fail "Debian Tor Browser archive checksum failed"
    tar -xJf "$archive" -C "$RUNTIME_ROOT"
    app_ini="$RUNTIME_ROOT/tor-browser/Browser/application.ini"
    [ -f "$app_ini" ] || fail "extracted Tor Browser application metadata is missing"
    grep -q "^BuildID=${TOR_BROWSER_BUILD_ID}$" "$app_ini" || fail "unexpected Tor Browser build ID"
    grep -q "^SourceStamp=${TOR_BROWSER_SOURCE_STAMP}$" "$app_ini" || fail "unexpected Tor Browser source stamp"
    configure_system_tor_profile "$RUNTIME_ROOT/tor-browser"
    launcher="$RUNTIME_ROOT/tor-browser/Browser/start-tor-browser"
    [ -x "$launcher" ] || fail "extracted Tor Browser launcher is missing"
    clear_proxy_env
    export TOR_PROVIDER=none
    export TOR_SKIP_LAUNCH=1
    export TOR_SOCKS_HOST="$SOCKS_HOST"
    export TOR_SOCKS_PORT="$SOCKS_PORT"
    supervise_browser "$launcher"
    exit $?
fi

fail "no supported, clean Tor Browser ${TOR_BROWSER_VERSION} archive was found"
