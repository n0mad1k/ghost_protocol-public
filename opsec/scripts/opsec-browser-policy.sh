#!/bin/bash
# Durable dirty-browser network policy transaction manager.
# Usage: opsec-browser-policy.sh apply|recover|status UID

set -euo pipefail
umask 077

STATE_ROOT="/var/lib/opsec/browser-policy"
POLICY_SOURCE="${OPSEC_POLICY_SOURCE:-/usr/local/share/opsec/apparmor/opsec-dirty-browser-block}"
KILLSWITCH_BIN="${OPSEC_KILLSWITCH_BIN:-/usr/local/bin/opsec-killswitch.sh}"
APP_ID="org.chromium.Chromium"
PLACEHOLDER_SWAP_ACTIVE=false

die() {
    echo "opsec-browser-policy: $*" >&2
    if [ "$PLACEHOLDER_SWAP_ACTIVE" = true ]; then
        unload_opsec_policy >/dev/null 2>&1 || true
        reload_packaged_placeholders >/dev/null 2>&1 || true
        reload_firefox_profile >/dev/null 2>&1 || true
        PLACEHOLDER_SWAP_ACTIVE=false
    fi
    exit 1
}
[ "${EUID:-$(id -u)}" -eq 0 ] || die "root is required"

action="${1:-}"
uid="${2:-}"
[[ "$uid" =~ ^[0-9]+$ ]] || die "a numeric desktop UID is required"
[ "$uid" -ge 1000 ] || die "refusing system UID $uid"
passwd=$(getent passwd "$uid") || die "UID $uid does not exist"
user=$(cut -d: -f1 <<<"$passwd")
home=$(cut -d: -f6 <<<"$passwd")
[ -d "$home" ] || die "home directory is missing"
[ "$(stat -c %u "$home")" = "$uid" ] || die "home directory owner mismatch"

txn="$STATE_ROOT/$uid"
manifest="$txn/manifest.json"
flatpak_path="$home/.local/share/flatpak/overrides/$APP_ID"
firefox_local="/etc/apparmor.d/local/firefox"
torbrowser_local="/etc/apparmor.d/local/torbrowser.Browser.firefox"

sync_path() { sync -f "$1" 2>/dev/null || sync; }

profile_is_enforcing() {
    local wanted="$1" allow_reported_unconfined="${2:-false}" mode
    mode=$(profile_reported_mode "$wanted")
    case "$mode" in
        enforce|default_allow|kill) return 0 ;;
        unconfined) [ "$allow_reported_unconfined" = true ] && return 0 ;;
    esac
    return 1
}

profile_mode_is() {
    local wanted="$1" wanted_mode="$2" dir
    for dir in /sys/kernel/security/apparmor/policy/profiles/*; do
        [ -d "$dir" ] || continue
        [ "$(cat "$dir/name" 2>/dev/null)" = "$wanted" ] || continue
        [ "$(cat "$dir/mode" 2>/dev/null)" = "$wanted_mode" ]
        return
    done
    return 1
}

profile_reported_mode() {
    local wanted="$1" dir line mode
    for dir in /sys/kernel/security/apparmor/policy/profiles/*; do
        [ -d "$dir" ] || continue
        [ "$(cat "$dir/name" 2>/dev/null)" = "$wanted" ] || continue
        cat "$dir/mode" 2>/dev/null
        return 0
    done
    if [ -r /sys/kernel/security/apparmor/profiles ]; then
        while IFS= read -r line; do
            case "$line" in
                "$wanted ("*")")
                    mode=${line#"$wanted ("}
                    printf '%s\n' "${mode%)}"
                    return 0
                    ;;
            esac
        done < /sys/kernel/security/apparmor/profiles
    fi
    printf 'missing\n'
}

stop_probe_group() {
    local leader="$1"
    kill -TERM -- "-$leader" 2>/dev/null || true
    for _ in $(seq 1 10); do
        kill -0 -- "-$leader" 2>/dev/null || break
        sleep 0.05
    done
    kill -0 -- "-$leader" 2>/dev/null && kill -KILL -- "-$leader" 2>/dev/null || true
    wait "$leader" 2>/dev/null || true
}

validate_firefox_launcher() {
    local launcher package target_package altered path
    launcher=$(command -v firefox) || return 0
    launcher=$(realpath -e "$launcher") || die "Firefox launcher path could not be canonicalized"
    if [ "$(readlink -f "$launcher")" = /usr/lib/firefox/firefox ]; then
        return 0
    fi
    [ "$launcher" = /usr/bin/firefox ] && command -v pacman >/dev/null 2>&1 || \
        die "unsupported persistent Firefox path must be explicitly covered: $launcher"
    for path in "$launcher" /usr/lib/firefox/firefox; do
        [ -f "$path" ] && [ ! -L "$path" ] || die "$path is not a regular packaged Firefox file"
        [ "$(stat -c %U:%G "$path")" = root:root ] || die "$path owner mismatch"
        [ $((8#$(stat -c %a "$path") & 0022)) -eq 0 ] || die "$path is group/other writable"
    done
    [ "$(cat "$launcher")" = '#!/bin/sh
exec /usr/lib/firefox/firefox "$@"' ] || die "$launcher is not the supported Arch Firefox wrapper"
    package=$(pacman -Qoq "$launcher") || die "$launcher is not package-owned"
    target_package=$(pacman -Qoq /usr/lib/firefox/firefox) || die "/usr/lib/firefox/firefox is not package-owned"
    [ "$package" = "$target_package" ] || die "Firefox wrapper and target package owners differ"
    pacman -Q "$package" >/dev/null || die "$package version could not be verified"
    altered=$(pacman -Qkk "$package" 2>&1 | tail -1)
    grep -q '0 altered files' <<<"$altered" || die "$package integrity check failed"
}

validate_replaceable_placeholder() {
    local profile="$1" source="/etc/apparmor.d/$1" local_file="/etc/apparmor.d/local/$1"
    local package altered include_path
    aa-status --show=profiles 2>/dev/null | grep -qx "$profile" || return 0
    [ -f "$source" ] && [ ! -L "$source" ] || die "loaded $profile profile has no trusted source"
    [ "$(stat -c %U:%G "$source")" = root:root ] || die "$source owner mismatch"
    [ $((8#$(stat -c %a "$source") & 0022)) -eq 0 ] || die "$source is group/other writable"
    grep -q 'flags=(unconfined)' "$source" || die "refusing to replace an already-confined $profile profile"
    include_path=$(sed -n 's/.*include if exists <\(local\/[^>]*\)>.*/\1/p' "$source")
    [ "$include_path" = "local/$profile" ] || die "$profile has unexpected local includes"
    [ ! -s "$local_file" ] || die "refusing to replace $profile with a nonempty local policy"
    if command -v pacman >/dev/null 2>&1; then
        package=$(pacman -Qoq "$source") || die "$source is not package-owned"
        altered=$(pacman -Qkk "$package" 2>&1 | tail -1)
        grep -q '0 altered files' <<<"$altered" || die "$package integrity check failed"
    elif command -v dpkg-query >/dev/null 2>&1; then
        package=$(dpkg-query -S "$source" | head -1 | cut -d: -f1)
        [ -n "$package" ] || die "$source is not package-owned"
        [ -z "$(dpkg-query -W -f='${Conffiles}\n' "$package" | awk -v path="$source" '$1==path && $NF=="obsolete" {print}')" ] || \
            die "$source is an obsolete conffile"
        [ -z "$(dpkg -V "$package" 2>/dev/null | awk -v path="$source" '$NF==path {print}')" ] || die "$source package verification failed"
    else
        die "no supported package integrity provider for $source"
    fi
}

snapshot_placeholder() {
    local profile="$1" source="/etc/apparmor.d/$1" local_file="/etc/apparmor.d/local/$1" package version
    if aa-status --show=profiles 2>/dev/null | grep -qx "$profile"; then
        printf 'loaded\n' > "$txn/placeholder-$profile.state"
        sha256sum "$source" | awk '{print $1}' > "$txn/placeholder-$profile.source.sha256"
        if command -v pacman >/dev/null 2>&1; then
            package=$(pacman -Qoq "$source"); version=$(pacman -Q "$package" | awk '{print $2}')
        else
            package=$(dpkg-query -S "$source" | head -1 | cut -d: -f1); version=$(dpkg-query -W -f='${Version}' "$package")
        fi
        printf '%s\n' "$package" > "$txn/placeholder-$profile.package"
        printf '%s\n' "$version" > "$txn/placeholder-$profile.version"
        if [ -e "$local_file" ]; then
            sha256sum "$local_file" | awk '{print $1}' > "$txn/placeholder-$profile.local.sha256"
        else
            printf 'absent\n' > "$txn/placeholder-$profile.local.sha256"
        fi
    else
        printf 'absent\n' > "$txn/placeholder-$profile.state"
        printf 'absent\n' > "$txn/placeholder-$profile.source.sha256"
        printf 'absent\n' > "$txn/placeholder-$profile.package"
        printf 'absent\n' > "$txn/placeholder-$profile.version"
        printf 'absent\n' > "$txn/placeholder-$profile.local.sha256"
    fi
}

placeholder_snapshot_matches() {
    local profile="$1" source="/etc/apparmor.d/$1" local_file="/etc/apparmor.d/local/$1" state package version actual_local
    state=$(cat "$txn/placeholder-$profile.state")
    [ "$state" = loaded ] || { [ "$state" = absent ]; return; }
    [ "$(sha256sum "$source" | awk '{print $1}')" = "$(cat "$txn/placeholder-$profile.source.sha256")" ] || return 1
    package=$(cat "$txn/placeholder-$profile.package")
    if command -v pacman >/dev/null 2>&1; then version=$(pacman -Q "$package" | awk '{print $2}'); else version=$(dpkg-query -W -f='${Version}' "$package"); fi
    [ "$version" = "$(cat "$txn/placeholder-$profile.version")" ] || return 1
    if [ -e "$local_file" ]; then actual_local=$(sha256sum "$local_file" | awk '{print $1}'); else actual_local=absent; fi
    [ "$actual_local" = "$(cat "$txn/placeholder-$profile.local.sha256")" ]
}

verify_placeholder_snapshot() {
    local profile="$1"
    placeholder_snapshot_matches "$profile" || die "$profile packaged placeholder changed during the transaction"
}

unload_replaceable_placeholder() {
    local profile="$1" source="/etc/apparmor.d/$1"
    [ "$(cat "$txn/placeholder-$profile.state")" = loaded ] || return 0
    apparmor_parser -R "$source"
}

reload_packaged_placeholders() {
    local profile source
    for profile in chromium brave; do
        source="/etc/apparmor.d/$profile"
        [ -f "$txn/placeholder-$profile.state" ] || continue
        [ "$(cat "$txn/placeholder-$profile.state")" = loaded ] || continue
        placeholder_snapshot_matches "$profile" || return 1
        apparmor_parser -r "$source"
        profile_mode_is "$profile" unconfined || return 1
    done
}

verify_profile_live() {
    local profile="$1" allow_reported_unconfined="${2:-false}" label_modes='enforce|default_allow|kill'
    [ "$allow_reported_unconfined" != true ] || label_modes+='|unconfined'
    if ! profile_is_enforcing "$profile" "$allow_reported_unconfined"; then
        local raw_kernel raw_status
        raw_kernel=$(grep -F "$profile" /sys/kernel/security/apparmor/profiles 2>/dev/null | head -1 || true)
        raw_status=$(aa-status --show=profiles 2>/dev/null | grep -F "$profile" | head -1 || true)
        die "$profile is not enforcing (kernel mode: $(profile_reported_mode "$profile"); kernel entry: ${raw_kernel:-none}; aa-status: ${raw_status:-none})"
    fi
    aa-exec -p "$profile" -- cat /proc/self/attr/current 2>/dev/null | grep -Eq "^${profile} \((${label_modes})\)$" || \
        die "$profile transition could not be proven"
    if aa-exec -p "$profile" -- python3 -c 'import socket; socket.socket(socket.AF_INET, socket.SOCK_STREAM)' >/dev/null 2>&1; then
        die "$profile did not deny IPv4 socket creation"
    fi
    if aa-exec -p "$profile" -- python3 -c 'import socket; socket.socket(socket.AF_INET6, socket.SOCK_STREAM)' >/dev/null 2>&1; then
        die "$profile did not deny IPv6 socket creation"
    fi
}

verify_actual_attachment() {
    local path="$1" expected="$2" run_as="${3:-root}" allow_reported_unconfined="${4:-false}"
    local tmp launcher="" pid exe current found=false
    [ -x "$path" ] || return 0
    tmp=$(mktemp -d /run/opsec/.aa-browser-profile.XXXXXX)
    if [ "$run_as" != root ]; then chown "$uid:$uid" "$tmp"; fi
    if [ "$run_as" = root ]; then
        setsid env MOZ_HEADLESS=1 "$path" --headless --no-remote --profile "$tmp" about:blank >/dev/null 2>&1 &
    else
        setsid runuser -u "$user" -- env HOME="$home" MOZ_HEADLESS=1 \
            "$path" --headless --no-remote --profile "$tmp" about:blank >/dev/null 2>&1 &
    fi
    launcher=$!
    for _ in $(seq 1 20); do
        while IFS= read -r pid; do
            exe=$(readlink -f "/proc/$pid/exe" 2>/dev/null || true)
            [ "$exe" = "$(readlink -f "$path")" ] || continue
            current=$(cat "/proc/$pid/attr/current" 2>/dev/null || true)
            case "$current" in
                "$expected (enforce)"|"$expected (default_allow)"|"$expected (kill)") found=true ;;
                "$expected (unconfined)") [ "$allow_reported_unconfined" = true ] && found=true ;;
            esac
        done < <(pgrep -u "$uid" -f -- "--profile $tmp" 2>/dev/null || true)
        "$found" && break
        sleep 0.25
    done
    stop_probe_group "$launcher"
    find "$tmp" -xdev -depth -mindepth 1 -delete 2>/dev/null || true
    rmdir "$tmp" 2>/dev/null || true
    "$found" || die "$path did not enter the expected AppArmor profile $expected"
}

verify_chromium_attachment() {
    local path="$1" expected="$2" tmp launcher pid exe current found=false
    [ -x "$path" ] || return 0
    tmp=$(mktemp -d /run/opsec/.aa-chromium-profile.XXXXXX)
    chown "$uid:$uid" "$tmp"
    setsid runuser -u "$user" -- env HOME="$home" \
        "$path" --headless=new --disable-gpu --no-first-run --user-data-dir="$tmp" about:blank >/dev/null 2>&1 &
    launcher=$!
    for _ in $(seq 1 30); do
        while IFS= read -r pid; do
            exe=$(readlink -f "/proc/$pid/exe" 2>/dev/null || true)
            [ "$exe" = "$(readlink -f "$path")" ] || continue
            current=$(cat "/proc/$pid/attr/current" 2>/dev/null || true)
            [ "$current" = "$expected (enforce)" ] && found=true
        done < <(pgrep -u "$uid" -f -- "--user-data-dir=$tmp" 2>/dev/null || true)
        "$found" && break
        sleep 0.2
    done
    stop_probe_group "$launcher"
    find "$tmp" -xdev -depth -mindepth 1 -delete 2>/dev/null || true
    rmdir "$tmp" 2>/dev/null || true
    "$found" || die "$path did not enter the expected AppArmor profile $expected"
}

verify_chromium_baseline() {
    local path="$1" allowed_preexisting="${2:-}" tmp launcher pid exe current found=false unexpected=""
    [ -x "$path" ] || return 0
    tmp=$(mktemp -d /run/opsec/.aa-chromium-baseline.XXXXXX)
    chown "$uid:$uid" "$tmp"
    setsid runuser -u "$user" -- env HOME="$home" \
        "$path" --headless=new --disable-gpu --no-first-run --user-data-dir="$tmp" about:blank >/dev/null 2>&1 &
    launcher=$!
    for _ in $(seq 1 30); do
        while IFS= read -r pid; do
            exe=$(readlink -f "/proc/$pid/exe" 2>/dev/null || true)
            [ "$exe" = "$(readlink -f "$path")" ] || continue
            current=$(cat "/proc/$pid/attr/current" 2>/dev/null || true)
            case "$current" in
                unconfined|"$allowed_preexisting (unconfined)") found=true ;;
                *) unexpected="$current" ;;
            esac
        done < <(pgrep -u "$uid" -f -- "--user-data-dir=$tmp" 2>/dev/null || true)
        "$found" && break
        sleep 0.2
    done
    stop_probe_group "$launcher"
    find "$tmp" -xdev -depth -mindepth 1 -delete 2>/dev/null || true
    rmdir "$tmp" 2>/dev/null || true
    [ -z "$unexpected" ] || die "$path is already confined by an unexpected AppArmor profile: $unexpected"
    "$found" || die "$path baseline AppArmor attachment could not be proven"
}

verify_firefox_baseline() {
    local path="$1" tmp launcher pid exe current found=false unexpected=""
    [ -x "$path" ] || return 0
    tmp=$(mktemp -d /run/opsec/.aa-firefox-baseline.XXXXXX)
    chown "$uid:$uid" "$tmp"
    setsid runuser -u "$user" -- env HOME="$home" MOZ_HEADLESS=1 \
        "$path" --headless --no-remote --profile "$tmp" about:blank >/dev/null 2>&1 &
    launcher=$!
    for _ in $(seq 1 20); do
        while IFS= read -r pid; do
            exe=$(readlink -f "/proc/$pid/exe" 2>/dev/null || true)
            [ "$exe" = "$(readlink -f "$path")" ] || continue
            current=$(cat "/proc/$pid/attr/current" 2>/dev/null || true)
            if [ "$current" = unconfined ]; then found=true; else unexpected="$current"; fi
        done < <(pgrep -u "$uid" -f -- "--profile $tmp" 2>/dev/null || true)
        "$found" && break
        sleep 0.25
    done
    stop_probe_group "$launcher"
    find "$tmp" -xdev -depth -mindepth 1 -delete 2>/dev/null || true
    rmdir "$tmp" 2>/dev/null || true
    [ -z "$unexpected" ] || die "$path is already confined by an unexpected AppArmor profile: $unexpected"
    "$found" || die "$path baseline AppArmor attachment could not be proven"
}

verify_packaged_torbrowser() {
    local packaged_profile path
    [ -f /etc/apparmor.d/torbrowser.Browser.firefox ] || return 0
    packaged_profile=$(awk '$1 == "profile" {print $2; exit}' /etc/apparmor.d/torbrowser.Browser.firefox)
    [ -n "$packaged_profile" ] || die "packaged Tor Browser AppArmor profile name could not be resolved"
    verify_profile_live "$packaged_profile"
    for path in \
        "$home/.local/share/torbrowser/tbb/x86_64/tor-browser/Browser/firefox" \
        "$home/.local/share/torbrowser/tbb/x86_64/tor-browser/Browser/firefox.real"; do
        [ -x "$path" ] || continue
        verify_actual_attachment "$path" "$packaged_profile" "$user"
    done
}

validate_state_paths() {
    [ -d "$STATE_ROOT" ] && [ ! -L "$STATE_ROOT" ] || die "$STATE_ROOT must be a real directory"
    [ "$(stat -c %U:%G "$STATE_ROOT")" = "root:root" ] || die "$STATE_ROOT owner mismatch"
    [ $((8#$(stat -c %a "$STATE_ROOT") & 0077)) -eq 0 ] || die "$STATE_ROOT permissions are too broad"
    [ "$(realpath -m "$home")" = "$home" ] || die "home directory must not traverse symlinks"
    [ "$(realpath -m "$flatpak_path")" = "$flatpak_path" ] || die "Flatpak override path traverses a symlink"
}

write_manifest() {
    local phase="$1" tmp="$txn/.manifest.tmp"
    jq -n --arg phase "$phase" --arg activation_id "$(cat "$txn/activation.id")" \
        --arg policy_sha256 "$(sha256sum "$txn/opsec-dirty-browser-block" | awk '{print $1}')" \
        --arg flatpak_sha256 "$(cat "$txn/flatpak.sha256")" \
        --arg firefox_sha256 "$(cat "$txn/firefox_local.sha256")" \
        --arg torbrowser_sha256 "$(cat "$txn/torbrowser_local.sha256")" \
        --arg brave_state "$(cat "$txn/placeholder-brave.state")" \
        --arg brave_source_sha "$(cat "$txn/placeholder-brave.source.sha256")" \
        --arg brave_package "$(cat "$txn/placeholder-brave.package")" \
        --arg brave_version "$(cat "$txn/placeholder-brave.version")" \
        --arg brave_local_sha "$(cat "$txn/placeholder-brave.local.sha256")" \
        --arg chromium_state "$(cat "$txn/placeholder-chromium.state")" \
        --arg chromium_source_sha "$(cat "$txn/placeholder-chromium.source.sha256")" \
        --arg chromium_package "$(cat "$txn/placeholder-chromium.package")" \
        --arg chromium_version "$(cat "$txn/placeholder-chromium.version")" \
        --arg chromium_local_sha "$(cat "$txn/placeholder-chromium.local.sha256")" \
        --arg user "$user" --argjson uid "$uid" \
        --arg home "$home" --arg flatpak "$flatpak_path" --arg firefox "$firefox_local" \
        --arg torbrowser "$torbrowser_local" \
        '{schema:3,activation_id:$activation_id,phase:$phase,user:$user,uid:$uid,home:$home,
          policy_sha256:$policy_sha256,
          targets:{flatpak:{path:$flatpak,sha256:$flatpak_sha256},
                   firefox_local:{path:$firefox,sha256:$firefox_sha256},
                   torbrowser_local:{path:$torbrowser,sha256:$torbrowser_sha256}},
          placeholders:{brave:{state:$brave_state,source_sha256:$brave_source_sha,package:$brave_package,version:$brave_version,local_sha256:$brave_local_sha},
                        chromium:{state:$chromium_state,source_sha256:$chromium_source_sha,package:$chromium_package,version:$chromium_version,local_sha256:$chromium_local_sha}}}' > "$tmp"
    chmod 0600 "$tmp"
    sync_path "$tmp"
    mv -f "$tmp" "$manifest"
    sync_path "$txn"
}

snapshot() {
    local key="$1" target="$2"
    if [ -e "$target" ] || [ -L "$target" ]; then
        [ -f "$target" ] && [ ! -L "$target" ] || die "$target is not a regular non-symlink file"
        command -v getfacl >/dev/null && command -v getfattr >/dev/null || die "ACL/xattr tools are required to preserve $target"
        if [ "$target" = "$flatpak_path" ]; then
            [ "$(stat -c %u "$target")" = "$uid" ] || die "$target is not owned by the desktop user"
            [ "$(getfacl -cp "$target" | grep -Ec '^(user|group|mask|other):')" -le 4 ] || \
                die "$target has an extended ACL that cannot be restored safely"
            [ -z "$(getfattr -d -m- --absolute-names "$target" 2>/dev/null | grep '=')" ] || \
                die "$target has xattrs that cannot be restored safely"
        fi
        printf 'present\n' > "$txn/$key.state"
        tar --acls --xattrs --selinux --numeric-owner -cpf "$txn/$key.tar" -C / "${target#/}"
        sha256sum "$target" | awk '{print $1}' > "$txn/$key.sha256"
        stat -c %a "$target" > "$txn/$key.mode"
    else
        printf 'absent\n' > "$txn/$key.state"
        printf 'absent\n' > "$txn/$key.sha256"
        printf 'absent\n' > "$txn/$key.mode"
    fi
    sync_path "$txn/$key.state"
    [ ! -f "$txn/$key.tar" ] || sync_path "$txn/$key.tar"
}

restore_root() {
    local key="$1" target="$2" state
    state=$(cat "$txn/$key.state")
    mkdir -p "$(dirname "$target")"
    rm -f -- "$target"
    if [ "$state" = "present" ]; then
        tar --acls --xattrs --selinux --numeric-owner -xpf "$txn/$key.tar" -C /
    elif [ "$state" != "absent" ]; then
        die "invalid snapshot state for $key"
    fi
}

restore_home() {
    local key="$1" target="$2" state parent mode
    state=$(cat "$txn/$key.state")
    parent=$(dirname "$target")
    validate_state_paths
    runuser -u "$user" -- env HOME="$home" mkdir -p -- "$parent"
    runuser -u "$user" -- env HOME="$home" rm -f -- "$target"
    if [ "$state" = present ]; then
        mode=$(cat "$txn/$key.mode")
        tar -xOf "$txn/$key.tar" "${target#/}" | runuser -u "$user" -- env HOME="$home" \
            bash -c 'set -euo pipefail
                target=$1; mode=$2; parent=$(dirname "$target")
                tmp=$(mktemp "$parent/.opsec-restore.XXXXXX")
                trap '\''rm -f -- "$tmp"'\'' EXIT
                cat > "$tmp"
                chmod "$mode" "$tmp"
                mv -f -- "$tmp" "$target"
                trap - EXIT' _ "$target" "$mode"
    elif [ "$state" != absent ]; then
        die "invalid snapshot state for $key"
    fi
}

verify_restored() {
    local key="$1" target="$2" expected state
    state=$(cat "$txn/$key.state")
    expected=$(cat "$txn/$key.sha256")
    if [ "$state" = present ]; then
        [ -f "$target" ] && [ ! -L "$target" ] || die "$target was not restored as a regular file"
        [ "$(sha256sum "$target" | awk '{print $1}')" = "$expected" ] || die "$target restore hash mismatch"
        [ "$(stat -c %a "$target")" = "$(cat "$txn/$key.mode")" ] || die "$target restore mode mismatch"
        [ "$target" != "$flatpak_path" ] || [ "$(stat -c %u "$target")" = "$uid" ] || die "$target restore owner mismatch"
    else
        [ ! -e "$target" ] && [ ! -L "$target" ] || die "$target should have been restored absent"
    fi
}

reload_firefox_profile() {
    [ -f /etc/apparmor.d/firefox ] || return 0
    if [ -f "$txn/firefox.runtime" ]; then
        apparmor_parser -R "$txn/firefox.runtime" 2>/dev/null || true
    fi
    apparmor_parser -r /etc/apparmor.d/firefox
}

unload_opsec_policy() {
    local source="$txn/opsec-dirty-browser-block"
    [ -f "$source" ] || source="$POLICY_SOURCE"
    if [ -f "$source" ]; then
        apparmor_parser -R "$source" 2>/dev/null || true
    fi
}

cleanup_txn() {
    local resolved
    resolved=$(realpath -m "$txn")
    [ "$resolved" = "$STATE_ROOT/$uid" ] || die "transaction cleanup path mismatch"
    find "$resolved" -xdev -depth -mindepth 1 -delete
    rmdir "$resolved"
    sync_path "$STATE_ROOT"
}

recover_policy() {
    local policy_sha
    if [ ! -f "$manifest" ]; then
        if [ -d "$txn" ]; then
            validate_state_paths
            [ ! -e "$txn/mutation.started" ] || die "mutated transaction exists without a recovery manifest"
            cleanup_txn
        fi
        return 0
    fi
    validate_state_paths
    [ -f "$txn/opsec-dirty-browser-block" ] || die "transaction policy snapshot is missing"
    policy_sha=$(sha256sum "$txn/opsec-dirty-browser-block" | awk '{print $1}')
    for key in flatpak firefox_local torbrowser_local; do
        [ -f "$txn/$key.state" ] && [ -f "$txn/$key.sha256" ] && [ -f "$txn/$key.mode" ] || \
            die "transaction snapshot metadata is incomplete"
        if [ "$(cat "$txn/$key.state")" = present ]; then
            [ "$(sha256sum "$txn/$key.tar" | awk '{print $1}')" = "$(cat "$txn/$key.tar.sha256")" ] || die "$key snapshot archive hash mismatch"
        fi
    done
    for profile in brave chromium; do
        for field in state source.sha256 package version local.sha256; do
            [ -f "$txn/placeholder-$profile.$field" ] || die "$profile placeholder metadata is incomplete"
        done
        verify_placeholder_snapshot "$profile"
    done
    jq -e --argjson uid "$uid" --arg home "$home" --arg flatpak "$flatpak_path" \
        --arg firefox "$firefox_local" --arg torbrowser "$torbrowser_local" \
        --arg policy_sha "$policy_sha" \
        --arg flatpak_sha "$(cat "$txn/flatpak.sha256")" \
        --arg firefox_sha "$(cat "$txn/firefox_local.sha256")" \
        --arg torbrowser_sha "$(cat "$txn/torbrowser_local.sha256")" \
        --arg brave_state "$(cat "$txn/placeholder-brave.state")" \
        --arg brave_source_sha "$(cat "$txn/placeholder-brave.source.sha256")" \
        --arg brave_package "$(cat "$txn/placeholder-brave.package")" \
        --arg brave_version "$(cat "$txn/placeholder-brave.version")" \
        --arg brave_local_sha "$(cat "$txn/placeholder-brave.local.sha256")" \
        --arg chromium_state "$(cat "$txn/placeholder-chromium.state")" \
        --arg chromium_source_sha "$(cat "$txn/placeholder-chromium.source.sha256")" \
        --arg chromium_package "$(cat "$txn/placeholder-chromium.package")" \
        --arg chromium_version "$(cat "$txn/placeholder-chromium.version")" \
        --arg chromium_local_sha "$(cat "$txn/placeholder-chromium.local.sha256")" \
        '.schema == 3 and .uid == $uid and .home == $home and
         .policy_sha256 == $policy_sha and
         .targets.flatpak.path == $flatpak and .targets.firefox_local.path == $firefox and
         .targets.torbrowser_local.path == $torbrowser and
         .targets.flatpak.sha256 == $flatpak_sha and
         .targets.firefox_local.sha256 == $firefox_sha and
         .targets.torbrowser_local.sha256 == $torbrowser_sha and
         .placeholders.brave.state == $brave_state and
         .placeholders.brave.source_sha256 == $brave_source_sha and
         .placeholders.brave.package == $brave_package and
         .placeholders.brave.version == $brave_version and
         .placeholders.brave.local_sha256 == $brave_local_sha and
         .placeholders.chromium.state == $chromium_state and
         .placeholders.chromium.source_sha256 == $chromium_source_sha and
         .placeholders.chromium.package == $chromium_package and
         .placeholders.chromium.version == $chromium_version and
         .placeholders.chromium.local_sha256 == $chromium_local_sha and
         (.phase == "prepared" or .phase == "applied" or .phase == "restoring" or .phase == "restored")' \
        "$manifest" >/dev/null || die "transaction manifest validation failed"
    write_manifest restoring
    unload_opsec_policy
    reload_packaged_placeholders || die "packaged browser placeholder restoration failed"
    restore_root firefox_local "$firefox_local"
    reload_firefox_profile
    restore_root torbrowser_local "$torbrowser_local"
    [ ! -f /etc/apparmor.d/torbrowser.Browser.firefox ] || apparmor_parser -r /etc/apparmor.d/torbrowser.Browser.firefox
    restore_home flatpak "$flatpak_path"
    verify_restored firefox_local "$firefox_local"
    verify_restored torbrowser_local "$torbrowser_local"
    verify_restored flatpak "$flatpak_path"
    write_manifest restored
    cleanup_txn
}

apply_policy() {
    local required desktop_file exec_line executable
    for required in aa-exec aa-status apparmor_parser python3 jq tar sha256sum runuser flatpak getfacl getfattr; do
        command -v "$required" >/dev/null 2>&1 || die "required command is missing: $required"
    done
    install -d -o root -g root -m 0700 "$STATE_ROOT"
    validate_state_paths
    if [ -e "$txn" ]; then
        recover_policy
    fi
    for profile in opsec-dirty-brave opsec-dirty-brave-debian opsec-dirty-chromium \
        opsec-dirty-tor-browser opsec-dirty-tor-browser-real; do
        if aa-status --show=profiles 2>/dev/null | grep -qx "$profile"; then
            die "unexpected preexisting AppArmor profile $profile"
        fi
    done
    validate_replaceable_placeholder brave
    validate_replaceable_placeholder chromium
    verify_chromium_baseline /opt/brave-bin/brave brave
    verify_chromium_baseline /opt/brave.com/brave/brave brave
    verify_chromium_baseline /usr/lib/chromium/chromium chromium
    # Tor Browser's `firefox` is a shell wrapper that immediately execs
    # `firefox.real`.  Probing the wrapper and comparing /proc/exe to the
    # wrapper path can never succeed; prove the executable that can actually
    # create sockets is unconfined before loading the deny policy.
    if [ -x "$home/.local/opt/tor-browser/app/Browser/firefox.real" ]; then
        verify_firefox_baseline "$home/.local/opt/tor-browser/app/Browser/firefox.real"
    else
        verify_firefox_baseline "$home/.local/opt/tor-browser/app/Browser/firefox"
    fi
    for unsupported in google-chrome google-chrome-stable chrome vivaldi vivaldi-stable opera librewolf waterfox floorp; do
        if command -v "$unsupported" >/dev/null 2>&1; then
            die "unsupported persistent browser is installed and cannot be blocked safely: $unsupported"
        fi
    done
    while IFS= read -r portable; do
        [ -n "$portable" ] || continue
        die "unsupported portable browser executable must be removed or explicitly covered: $portable"
    done < <(find "$home/Applications" "$home/.local/bin" "$home/Downloads" -xdev -type f -perm /111 \
        \( -iname '*chrome*' -o -iname '*chromium*' -o -iname '*firefox*' -o -iname '*librewolf*' \
           -o -iname '*waterfox*' -o -iname '*vivaldi*' -o -iname '*opera*' -o -iname '*browser*.AppImage' \) \
        -print 2>/dev/null || true)
    while IFS= read -r desktop_file; do
        grep -Eq '^(Categories=.*WebBrowser|MimeType=.*x-scheme-handler/https?)' "$desktop_file" || continue
        exec_line=$(awk -F= '$1 == "Exec" {print $2; exit}' "$desktop_file")
        executable=${exec_line%% *}
        executable=${executable#env }
        case "$(basename "$executable")" in
            brave|brave-browser|firefox|chromium|tor-browser|opsec-browser|start-tor-browser) ;;
            "") ;;
            *) die "unsupported browser desktop launcher must be explicitly covered: $desktop_file ($executable)" ;;
        esac
    done < <(find /usr/share/applications "$home/.local/share/applications" -xdev -type f -name '*.desktop' -print 2>/dev/null || true)
    while IFS= read -r installed_app; do
        case "$installed_app" in
            org.chromium.Chromium) ;;
            *[Bb]rowser*|*Chrom*|*Firefox*|*LibreWolf*|*Waterfox*|com.google.Chrome*)
                die "unsupported Flatpak browser must be removed or added to the transactional policy: $installed_app" ;;
        esac
    done < <(runuser -u "$user" -- env HOME="$home" flatpak list --app --columns=application 2>/dev/null || true)
    if command -v firefox >/dev/null 2>&1; then
        validate_firefox_launcher
        [ -f /etc/apparmor.d/firefox ] || die "packaged Firefox AppArmor profile is missing"
        grep -q 'local/firefox' /etc/apparmor.d/firefox || die "Firefox profile has no local include"
        grep -q 'flags=(unconfined)' /etc/apparmor.d/firefox || \
            die "refusing to modify an already-confined packaged Firefox profile"
        if [ -s "$firefox_local" ]; then
            die "refusing to replace a nonempty packaged Firefox local policy"
        fi
    fi
    install -d -o root -g root -m 0700 "$txn"
    cat /proc/sys/kernel/random/uuid > "$txn/activation.id"
    snapshot flatpak "$flatpak_path"
    snapshot firefox_local "$firefox_local"
    snapshot torbrowser_local "$torbrowser_local"
    snapshot_placeholder brave
    snapshot_placeholder chromium
    install -m 0600 "$POLICY_SOURCE" "$txn/opsec-dirty-browser-block"
    for key in flatpak firefox_local torbrowser_local; do
        [ ! -f "$txn/$key.tar" ] || sha256sum "$txn/$key.tar" | awk '{print $1}' > "$txn/$key.tar.sha256"
    done
    sync_path "$txn/opsec-dirty-browser-block"
    for profile in brave chromium; do
        for field in state source.sha256 package version local.sha256; do
            sync_path "$txn/placeholder-$profile.$field"
        done
    done
    apparmor_parser -Q -K "$txn/opsec-dirty-browser-block"
    write_manifest prepared
    : > "$txn/mutation.started"
    sync_path "$txn/mutation.started"
    sync_path "$txn"

    if flatpak info "$APP_ID" >/dev/null 2>&1 || runuser -u "$user" -- flatpak info "$APP_ID" >/dev/null 2>&1; then
        runuser -u "$user" -- env HOME="$home" flatpak override --user --unshare=network "$APP_ID"
        runuser -u "$user" -- env HOME="$home" flatpak override --user --show "$APP_ID" | grep -q 'shared=!network'
    fi

    if [ -f /etc/apparmor.d/torbrowser.Browser.firefox ]; then
        grep -q 'local/torbrowser.Browser.firefox' /etc/apparmor.d/torbrowser.Browser.firefox || \
            die "Tor Browser profile has no local include"
        install -d -o root -g root -m 0755 /etc/apparmor.d/local
        {
            [ ! -f "$torbrowser_local" ] || cat "$torbrowser_local"
            printf '\n# OPSEC-DIRTY-BROWSER-BLOCK\naudit deny network,\n'
        } > "$txn/torbrowser.local.new"
        install -o root -g root -m 0644 "$txn/torbrowser.local.new" "$torbrowser_local"
        apparmor_parser -r /etc/apparmor.d/torbrowser.Browser.firefox
    fi

    if command -v pacman >/dev/null 2>&1; then
        for path in /opt/brave-bin/brave /usr/lib/chromium/chromium /usr/bin/tor-browser; do
            [ -e "$path" ] || continue
            [ "$(stat -c %U:%G "$path")" = "root:root" ] || die "$path is not root-owned"
            [ $((8#$(stat -c %a "$path") & 0022)) -eq 0 ] || die "$path is group/other writable"
            pacman -Qo "$path" >/dev/null 2>&1 || die "$path is not package-owned"
        done
    elif command -v dpkg-query >/dev/null 2>&1; then
        for path in /opt/brave.com/brave/brave /usr/lib/chromium/chromium; do
            [ -e "$path" ] || continue
            [ "$(stat -c %U:%G "$path")" = "root:root" ] || die "$path is not root-owned"
            [ $((8#$(stat -c %a "$path") & 0022)) -eq 0 ] || die "$path is group/other writable"
            dpkg-query -S "$path" >/dev/null 2>&1 || die "$path is not package-owned"
        done
        [ -f /etc/apparmor.d/torbrowser.Browser.firefox ] || die "Debian Tor Browser AppArmor profile is missing"
    else
        die "unsupported Tor Browser/AppArmor package layout"
    fi
    aa-status --enabled
    verify_placeholder_snapshot brave
    verify_placeholder_snapshot chromium
    "$KILLSWITCH_BIN" strict-status >/dev/null 2>&1 || die "strict nft firewall is not verified during the AppArmor swap"
    PLACEHOLDER_SWAP_ACTIVE=true
    unload_replaceable_placeholder brave
    unload_replaceable_placeholder chromium
    if [ -x /usr/lib/firefox/firefox ]; then
        apparmor_parser -R /etc/apparmor.d/firefox
    fi
    apparmor_parser -r "$txn/opsec-dirty-browser-block"
    aa-status --show=profiles | grep -q 'opsec-dirty-brave'
    aa-status --show=profiles | grep -q 'opsec-dirty-tor-browser'
    aa-status --show=profiles | grep -q 'opsec-dirty-tor-browser-real'
    for profile in opsec-dirty-brave opsec-dirty-brave-debian opsec-dirty-chromium opsec-dirty-firefox \
        opsec-dirty-tor-browser opsec-dirty-tor-browser-real; do
        verify_profile_live "$profile"
    done
    verify_chromium_attachment /opt/brave-bin/brave opsec-dirty-brave
    verify_chromium_attachment /opt/brave.com/brave/brave opsec-dirty-brave-debian
    verify_chromium_attachment /usr/lib/chromium/chromium opsec-dirty-chromium
    if [ -x /usr/lib/firefox/firefox ]; then
        verify_actual_attachment /usr/lib/firefox/firefox opsec-dirty-firefox "$user"
    fi
    verify_actual_attachment "$home/.local/opt/tor-browser/app/Browser/firefox.real" opsec-dirty-tor-browser-real "$user"
    verify_packaged_torbrowser
    write_manifest applied
    PLACEHOLDER_SWAP_ACTIVE=false
}

verify_policy() {
    [ -f "$manifest" ] || return 1
    jq -e '.phase == "applied"' "$manifest" >/dev/null
    "$KILLSWITCH_BIN" strict-status >/dev/null 2>&1 || die "strict nft firewall is not verified"
    aa-status --enabled >/dev/null
    aa-status --show=profiles | grep -q 'opsec-dirty-brave'
    aa-status --show=profiles | grep -q 'opsec-dirty-tor-browser'
    aa-status --show=profiles | grep -q 'opsec-dirty-tor-browser-real'
    for profile in opsec-dirty-brave opsec-dirty-brave-debian opsec-dirty-chromium opsec-dirty-firefox \
        opsec-dirty-tor-browser opsec-dirty-tor-browser-real; do
        verify_profile_live "$profile"
    done
    verify_chromium_attachment /opt/brave-bin/brave opsec-dirty-brave
    verify_chromium_attachment /opt/brave.com/brave/brave opsec-dirty-brave-debian
    verify_chromium_attachment /usr/lib/chromium/chromium opsec-dirty-chromium
    verify_actual_attachment "$home/.local/opt/tor-browser/app/Browser/firefox.real" opsec-dirty-tor-browser-real "$user"
    if runuser -u "$user" -- env HOME="$home" flatpak info "$APP_ID" >/dev/null 2>&1; then
        runuser -u "$user" -- env HOME="$home" flatpak override --user --show "$APP_ID" | grep -q 'shared=!network'
    fi
    if [ -x /usr/lib/firefox/firefox ]; then
        verify_actual_attachment /usr/lib/firefox/firefox opsec-dirty-firefox "$user"
    fi
    if [ -f /etc/apparmor.d/torbrowser.Browser.firefox ]; then
        grep -q '^# OPSEC-DIRTY-BROWSER-BLOCK$' "$torbrowser_local"
        verify_packaged_torbrowser
    fi
}

case "$action" in
    apply) apply_policy ;;
    recover) recover_policy ;;
    status) verify_policy ;;
    *) die "usage: opsec-browser-policy.sh apply|recover|status UID" ;;
esac
