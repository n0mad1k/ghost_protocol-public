#!/bin/bash
# Exact deployment backup/restore for the OPSEC Browser integration.

set -euo pipefail
umask 077

action="${1:-}"
deploy_id="${2:-}"
user_home="${3:-}"
root="/var/backups/opsec-browser"
backup="$root/$deploy_id"

die() { echo "opsec-browser-deploy: $*" >&2; exit 1; }
[ "${EUID:-$(id -u)}" -eq 0 ] || die "root is required"
[[ "$deploy_id" =~ ^[0-9T_-]+$ ]] || die "invalid deployment ID"
[ -n "$user_home" ] && [ -d "$user_home" ] || die "invalid user home"
[ "$(realpath -m "$user_home")" = "$user_home" ] || die "user home traverses a symlink"

targets=(
    /usr/local/bin/opsec-browser
    /usr/local/libexec/opsec-browser-run.sh
    /usr/local/libexec/opsec-browser-postcheck.sh
    /usr/local/bin/opsec-browser-policy.sh
    /usr/local/bin/opsec-browser-recovery.sh
    /usr/local/bin/opsec-mode.sh
    /usr/local/bin/opsec-mode
    /usr/local/bin/opsec-preflight.sh
    /usr/local/lib/opsec/opsec-lib.sh
    /usr/local/bin/opsec-harden.sh
    /usr/local/bin/opsec-killswitch.sh
    /usr/local/bin/opsec-mode-toggle.sh
    /usr/local/bin/opsec-toggle.sh
    /usr/local/bin/opsec-banner.sh
    /usr/local/bin/opsec-banner-cache.sh
    /usr/local/bin/opsec-boot-init.sh
    /usr/local/bin/opsec-check.sh
    /usr/local/bin/opsec-config.sh
    /usr/local/bin/opsec-hostname-randomize.sh
    /usr/local/bin/opsec-log-rotate.sh
    /usr/local/bin/opsec-monitor.sh
    /usr/local/bin/opsec-sentry.sh
    /usr/local/bin/opsec-ssh-check.sh
    /usr/local/bin/opsec-traffic-blend.sh
    /usr/local/bin/opsec-widget-launch.sh
    /usr/local/bin/opsec-wifi-check.sh
    /etc/opsec/opsec.conf
    /etc/opsec/country-codes.conf
    /etc/opsec/resolv.conf.head
    /etc/opsec/resolv.conf.opsec
    /etc/opsec/levels/bare-metal-standard.conf
    /etc/opsec/levels/bare-metal-paranoid.conf
    /etc/opsec/levels/cloud-normal.conf
    /etc/opsec/levels/cloud-paranoid.conf
    /etc/opsec/torrc/torrc-default
    /etc/opsec/torrc/torrc-opsec
    /etc/opsec/vpn-templates/double-hop-ovpn.conf.template
    /etc/opsec/vpn-templates/wireguard-multihop.conf.template
    /etc/opsec/themes/aurora.theme
    /etc/opsec/themes/cyberpunk.theme
    /etc/opsec/themes/default.theme
    /etc/opsec/themes/ember.theme
    /etc/opsec/themes/frost.theme
    /etc/opsec/themes/slate.theme
    /etc/opsec/themes/terminal.theme
    /etc/cron.d/opsec-banner-cache
    /etc/cron.d/opsec-log-rotate
    /usr/share/polkit-1/actions/com.opsec.mode.policy
    /etc/udev/rules.d/99-opsec-usb.rules
    /usr/share/applications/opsec-toggle.desktop
    /etc/systemd/system/opsec-boot-advanced.service
    /etc/systemd/system/opsec-hostname-randomize.service
    /etc/systemd/system/opsec-mac-randomize.service
    /usr/local/share/opsec/apparmor/opsec-dirty-browser-block
    /usr/lib/systemd/user/opsec-browser.service
    /etc/systemd/system/opsec-browser-recovery.service
    /etc/systemd/system/opsec-killswitch.service
    /etc/systemd/system/sysinit.target.wants/opsec-browser-recovery.service
    /etc/systemd/system/NetworkManager.service.d/50-opsec-browser-recovery.conf
    /etc/systemd/system/networking.service.d/50-opsec-browser-recovery.conf
    /etc/systemd/system/systemd-networkd.service.d/50-opsec-browser-recovery.conf
    /usr/share/applications/opsec-browser.desktop
    /var/lib/opsec/tor-browser/tor-browser-linux-x86_64-15.0.19.tar.xz
    /var/lib/opsec/tor-browser/tor-browser-linux-x86_64-15.0.19.tar.xz.asc
    "$user_home/.config/conky/conky-opsec-status.sh"
    "$user_home/.config/conky/conky-opsec-cache.sh"
    "$user_home/.config/conky/conky-opsec-widget.conf"
    "$user_home/.config/conky/opsec-widget-launch.sh"
    "$user_home/.opsec-aliases"
)

created_dirs=(
    "$user_home/.config/conky"
    "$user_home/.config"
    /usr/local/libexec
    /usr/local/lib/opsec
    /etc/opsec/levels
    /etc/opsec/torrc
    /etc/opsec/vpn-templates
    /etc/opsec/themes
    /etc/opsec
    /usr/local/share/opsec/apparmor
    /usr/local/share/opsec
    /var/lib/opsec/browser-policy
    /var/lib/opsec/tor-browser
    /var/lib/opsec
    /etc/systemd/system/NetworkManager.service.d
    /etc/systemd/system/networking.service.d
    /etc/systemd/system/systemd-networkd.service.d
)

validate_target() {
    local target="$1"
    case "$target" in
        "$user_home"/*)
            [ "$(realpath -m "$target")" = "$target" ] || die "user target traverses a symlink: $target"
            ;;
    esac
}

prepare() {
    local desktop_uid state mode digest
    desktop_uid=$(stat -c %u "$user_home")
    install -d -o root -g root -m 0700 "$root"
    [ ! -e "$backup" ] || die "backup already exists"
    install -d -o root -g root -m 0700 "$backup"
    : > "$backup/present.list"
    : > "$backup/manifest.tsv"
    : > "$backup/directories.tsv"
    for target in "${created_dirs[@]}"; do
        validate_target "$target"
        if [ -d "$target" ] && [ ! -L "$target" ]; then
            printf 'present\t%s\t%s\t%s\t%s\n' "$target" "$(stat -c %a "$target")" \
                "$(stat -c %u "$target")" "$(stat -c %g "$target")" >> "$backup/directories.tsv"
        elif [ -e "$target" ] || [ -L "$target" ]; then
            die "deployment directory target is not a real directory: $target"
        else
            printf 'absent\t%s\t-\t-\t-\n' "$target" >> "$backup/directories.tsv"
        fi
    done
    for target in "${targets[@]}"; do
        validate_target "$target"
        if [ -e "$target" ] || [ -L "$target" ]; then
            [ ! -d "$target" ] || die "refusing directory target $target"
            case "$target" in
                "$user_home"/*)
                    [ -f "$target" ] && [ ! -L "$target" ] || die "user target is not a regular non-symlink file: $target"
                    [ "$(stat -c %u "$target")" = "$desktop_uid" ] || die "user target owner mismatch: $target"
                    [ "$(getfacl -cp "$target" | grep -Ec '^(user|group|mask|other):')" -le 4 ] || \
                        die "user target has an extended ACL: $target"
                    [ -z "$(getfattr -d -m- --absolute-names "$target" 2>/dev/null | grep '=')" ] || \
                        die "user target has xattrs: $target"
                    ;;
            esac
            mode=$(stat -c %a "$target")
            digest=$(sha256sum "$target" 2>/dev/null | awk '{print $1}' || printf 'symlink')
            printf 'present\t%s\t%s\t%s\n' "$target" "$mode" "$digest" >> "$backup/manifest.tsv"
            printf '%s\n' "${target#/}" >> "$backup/present.list"
        else
            printf 'absent\t%s\t-\t-\n' "$target" >> "$backup/manifest.tsv"
        fi
    done
    tar --acls --xattrs --selinux --numeric-owner --verbatim-files-from \
        -cpf "$backup/prior.tar" -C / -T "$backup/present.list"
    printf 'prepared\n' > "$backup/phase"
    sync -f "$backup/manifest.tsv" "$backup/prior.tar" "$backup/phase" 2>/dev/null || sync
    sync -f "$backup" 2>/dev/null || sync
}

restore() {
    local desktop_uid desktop_user mode digest actual
    [ -f "$backup/manifest.tsv" ] && [ -f "$backup/prior.tar" ] || die "deployment backup is incomplete"
    desktop_uid=$(stat -c %u "$user_home")
    desktop_user=$(getent passwd "$desktop_uid" | cut -d: -f1)
    [ -n "$desktop_user" ] || die "desktop user could not be resolved"
    : > "$backup/root-restore.list"
    while IFS=$'\t' read -r state target mode digest; do
        case "$state" in
            present|absent) ;;
            *) die "invalid manifest state" ;;
        esac
        case "$target" in
            /usr/local/*|/usr/lib/systemd/user/*|/etc/opsec/*|/etc/cron.d/*|/etc/udev/rules.d/*|/etc/systemd/system/*|/usr/share/applications/*|/usr/share/polkit-1/actions/*|/var/lib/opsec/*|"$user_home"/*) ;;
            *) die "refusing unexpected restore target $target" ;;
        esac
        validate_target "$target"
        case "$target" in
            "$user_home"/*)
                runuser -u "$desktop_user" -- rm -f -- "$target"
                ;;
            *)
                rm -f -- "$target"
                [ "$state" = present ] && printf '%s\n' "${target#/}" >> "$backup/root-restore.list"
                ;;
        esac
    done < "$backup/manifest.tsv"
    tar --acls --xattrs --selinux --numeric-owner --verbatim-files-from \
        -xpf "$backup/prior.tar" -C / -T "$backup/root-restore.list"
    while IFS=$'\t' read -r state target mode digest; do
        case "$target" in
            "$user_home"/*)
                [ "$state" = present ] || continue
                runuser -u "$desktop_user" -- mkdir -p -- "$(dirname "$target")"
                tar -xOf "$backup/prior.tar" "${target#/}" | runuser -u "$desktop_user" -- \
                    bash -c 'set -euo pipefail
                        target=$1; mode=$2; parent=$(dirname "$target")
                        tmp=$(mktemp "$parent/.opsec-deploy-restore.XXXXXX")
                        trap '\''rm -f -- "$tmp"'\'' EXIT
                        cat > "$tmp"
                        chmod "$mode" "$tmp"
                        mv -f -- "$tmp" "$target"
                        trap - EXIT' _ "$target" "$mode"
                ;;
        esac
    done < "$backup/manifest.tsv"
    while IFS=$'\t' read -r state target mode owner group; do
        validate_target "$target"
        if [ "$state" = absent ] && [ -d "$target" ]; then
            rmdir --ignore-fail-on-non-empty "$target"
        elif [ "$state" = present ]; then
            [ -d "$target" ] && [ ! -L "$target" ] || die "rollback directory missing: $target"
            chown "$owner:$group" "$target"
            chmod "$mode" "$target"
        fi
    done < "$backup/directories.tsv"
    while IFS=$'\t' read -r state target mode digest; do
        validate_target "$target"
        if [ "$state" = absent ]; then
            [ ! -e "$target" ] && [ ! -L "$target" ] || die "rollback left an originally absent target: $target"
            continue
        fi
        [ -e "$target" ] || [ -L "$target" ] || die "rollback failed to restore $target"
        if [ "$digest" != symlink ]; then
            actual=$(sha256sum "$target" | awk '{print $1}')
            [ "$actual" = "$digest" ] || die "rollback content mismatch: $target"
            [ "$(stat -c %a "$target")" = "$mode" ] || die "rollback mode mismatch: $target"
        fi
    done < "$backup/manifest.tsv"
    printf 'restored\n' > "$backup/phase"
    sync -f "$backup/phase" 2>/dev/null || sync
}

case "$action" in
    prepare) prepare ;;
    commit)
        [ "$(cat "$backup/phase" 2>/dev/null)" = prepared ] || die "deployment was not prepared"
        printf 'committed\n' > "$backup/phase"
        sync -f "$backup/phase" 2>/dev/null || sync
        ;;
    restore) restore ;;
    *) die "usage: $0 prepare|commit|restore DEPLOY_ID USER_HOME" ;;
esac
