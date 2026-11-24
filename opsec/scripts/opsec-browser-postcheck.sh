#!/bin/bash
# Positive post-launch gate for the disposable OPSEC Browser cgroup.

set -euo pipefail

runtime_root="${RUNTIME_DIRECTORY:-${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/opsec-browser}"
socks_port="${TOR_SOCKS_PORT:-9050}"
[ -d "$runtime_root" ] && [ ! -L "$runtime_root" ] || exit 1
[ "$(stat -c %u "$runtime_root")" = "$(id -u)" ] || exit 1

found=false
prefs_ok=false
for _ in $(seq 1 30); do
    if pgrep -u "$(id -u)" -x tor >/dev/null 2>&1; then
        echo "opsec-browser: a user-owned bundled Tor process appeared" >&2
        exit 1
    fi
    while IFS= read -r proc; do
        exe=$(readlink -f "$proc" 2>/dev/null || true)
        case "$exe" in
            "$runtime_root"/*/Browser/TorBrowser/Tor/tor|"$runtime_root"/home/app/Browser/TorBrowser/Tor/tor)
                echo "opsec-browser: bundled Tor executable appeared" >&2
                exit 1 ;;
            "$runtime_root"/*/Browser/firefox|"$runtime_root"/*/Browser/firefox.real|\
            "$runtime_root"/home/app/Browser/firefox|"$runtime_root"/home/app/Browser/firefox.real)
                found=true ;;
        esac
    done < <(find /proc -maxdepth 2 -path '/proc/[0-9]*/exe' -user "$(id -u)" -print 2>/dev/null)
    # user.js is the authoritative startup policy. Firefox does not copy every
    # active user.js value into prefs.js until shutdown, so prefs.js is not a
    # reliable live gate.
    while IFS= read -r prefs; do
        grep -q 'user_pref("network.proxy.type", 1);' "$prefs" || continue
        grep -q 'user_pref("network.proxy.socks", "127.0.0.1");' "$prefs" || continue
        grep -q "user_pref(\"network.proxy.socks_port\", ${socks_port});" "$prefs" || continue
        grep -q 'user_pref("network.proxy.socks_remote_dns", true);' "$prefs" || continue
        prefs_ok=true
        break
    done < <(find "$runtime_root" -xdev -type f -name user.js -print 2>/dev/null)
    "$found" && "$prefs_ok" && break
    sleep 1
done

"$found" || { echo "opsec-browser: disposable Tor Browser process did not appear" >&2; exit 1; }
"$prefs_ok" || { echo "opsec-browser: system-Tor startup preferences were not verified" >&2; exit 1; }
pgrep -u "$(id -u)" -x tor >/dev/null 2>&1 && exit 1
ss -ltn 2>/dev/null | grep -qE '(^|[[:space:]])[^[:space:]]*:9051[[:space:]]' && {
    echo "opsec-browser: unexpected Tor ControlPort listener detected" >&2
    exit 1
}
exit 0
