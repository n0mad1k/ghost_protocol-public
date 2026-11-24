#!/bin/bash
# Transactional installer for the standalone Ghost Protocol OPSEC component.

set -euo pipefail
umask 077

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ACTION=install
RESTORE_ID=""
REAL_USER="${SUDO_USER:-}"
INSTALL_DEPS=1
TOR_BROWSER_VERSION=15.0.19
TOR_BROWSER_SHA256=2eb4ab431f4921ca63b123b6f9f445a073fbf7b65f188f45a577d576eb2be2cf

die() { printf 'opsec-install: %s\n' "$*" >&2; exit 1; }
info() { printf '[~] %s\n' "$*"; }
ok() { printf '[+] %s\n' "$*"; }

while [ "$#" -gt 0 ]; do
    case "$1" in
        --uninstall)
            [ "$#" -ge 2 ] || die "--uninstall requires a deployment ID"
            ACTION=uninstall; RESTORE_ID="$2"; shift 2; continue
            ;;
        --user)
            [ "$#" -ge 2 ] || die "--user requires a username"
            REAL_USER="$2"; shift 2; continue
            ;;
        --no-install-deps) INSTALL_DEPS=0 ;;
        -h|--help)
            echo "Usage: sudo ./install.sh [--user USER] [--no-install-deps]"
            echo "       sudo ./install.sh --uninstall DEPLOYMENT_ID [--user USER]"
            exit 0
            ;;
        *) die "unknown option: $1" ;;
    esac
    shift
done

[ "${EUID:-$(id -u)}" -eq 0 ] || die "run as root"
[ -n "$REAL_USER" ] || die "desktop user is required; use sudo or --user USER"
REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"
[ -n "$REAL_HOME" ] && [ -d "$REAL_HOME" ] || die "desktop user home was not found"
[ "$(realpath -m "$REAL_HOME")" = "$REAL_HOME" ] || die "desktop user home traverses a symlink"
REAL_UID="$(id -u "$REAL_USER")"

# shellcheck disable=SC1091
. /etc/os-release
case "${ID:-}:${ID_LIKE:-}" in
    arch:*|*:arch*) DISTRO=arch ;;
    debian:*|ubuntu:*|kali:*|parrot:*|*:debian*) DISTRO=debian ;;
    *) die "supported platforms are Arch and Debian-family distributions" ;;
esac

install_dependencies() {
    [ "$INSTALL_DEPS" -eq 1 ] || return 0
    if [ "$DISTRO" = arch ]; then
        pacman -S --needed --noconfirm tor macchanger iptables nftables apparmor flatpak acl attr jq curl gnupg python
    else
        export DEBIAN_FRONTEND=noninteractive
        apt-get update
        apt-get install -y tor macchanger iptables nftables apparmor apparmor-utils flatpak acl attr jq curl gpgv python3 torbrowser-launcher
    fi
}

require_commands() {
    local command
    for command in tor nft curl jq getfacl getfattr systemctl runuser tar sha256sum; do
        command -v "$command" >/dev/null 2>&1 || die "missing required command: $command"
    done
    command -v apparmor_parser >/dev/null 2>&1 || die "AppArmor parser is required"
}

uninstall_opsec() {
    [ -n "$RESTORE_ID" ] || die "--uninstall requires the deployment ID printed by install"
    /usr/local/bin/opsec-mode off >/dev/null 2>&1 || true
    "$ROOT/scripts/opsec-browser-deploy-transaction.sh" restore "$RESTORE_ID" "$REAL_HOME"
    systemctl daemon-reload
    ok "restored the exact pre-install state from deployment $RESTORE_ID"
    exit 0
}

[ "$ACTION" = install ] || uninstall_opsec
install_dependencies
require_commands

if [ "$DISTRO" = arch ]; then
    pacman -Q tor-browser >/dev/null 2>&1 || die "Arch requires the tor-browser package"
    [ "$(pacman -Q tor-browser | awk '{print $2}')" = "${TOR_BROWSER_VERSION}-1" ] || \
        die "tested Tor Browser ${TOR_BROWSER_VERSION}-1 is required"
else
    keyring=/usr/share/torbrowser-launcher/tor-browser-developers.asc
    [ -f "$keyring" ] || die "Tor Browser developers keyring is missing"
fi

deploy_id="$(date -u +%Y%m%dT%H%M%SZ)"
txn="$ROOT/scripts/opsec-browser-deploy-transaction.sh"
"$txn" prepare "$deploy_id" "$REAL_HOME"
rollback() {
    rc=$?
    trap - ERR INT TERM
    "$txn" restore "$deploy_id" "$REAL_HOME" || true
    exit "$rc"
}
trap rollback ERR INT TERM

install -d -m 0755 /usr/local/bin /usr/local/libexec /usr/local/lib/opsec /usr/local/share/opsec/apparmor
install -d -m 0700 /var/lib/opsec/browser-policy
install -d -m 0755 /var/lib/opsec/tor-browser /etc/opsec/{levels,themes,torrc,vpn-templates}
install -d -m 0755 /etc/security/limits.d

for source in "$ROOT"/scripts/opsec-*.sh; do
    base="$(basename "$source")"
    case "$base" in
        opsec-browser-run.sh|opsec-browser-postcheck.sh) install -m 0755 "$source" "/usr/local/libexec/$base" ;;
        opsec-browser-deploy-transaction.sh|opsec-install.sh) ;;
        *) install -m 0755 "$source" "/usr/local/bin/$base" ;;
    esac
done
install -m 0755 "$ROOT/scripts/opsec-browser" /usr/local/bin/opsec-browser
install -m 0644 "$ROOT/lib/opsec-lib.sh" /usr/local/lib/opsec/opsec-lib.sh
ln -sfn /usr/local/bin/opsec-mode.sh /usr/local/bin/opsec-mode

[ -e /etc/opsec/opsec.conf ] || install -m 0644 "$ROOT/configs/opsec.conf" /etc/opsec/opsec.conf
install -m 0644 "$ROOT/configs/opsec-country-codes.conf" /etc/opsec/country-codes.conf
install -m 0644 "$ROOT/configs/resolv.conf.head" "$ROOT/configs/resolv.conf.opsec" /etc/opsec/
install -m 0644 "$ROOT"/configs/levels/*.conf /etc/opsec/levels/
install -m 0644 "$ROOT"/configs/themes/*.theme /etc/opsec/themes/
install -m 0644 "$ROOT"/configs/torrc/* /etc/opsec/torrc/
install -m 0644 "$ROOT"/configs/vpn-templates/*.template /etc/opsec/vpn-templates/
install -m 0644 "$ROOT/configs/apparmor/opsec-dirty-browser-block" /usr/local/share/opsec/apparmor/
install -m 0644 "$ROOT/configs/systemd/user/opsec-browser.service" /usr/lib/systemd/user/
install -m 0644 "$ROOT/configs/systemd/opsec-browser-recovery.service" "$ROOT/configs/systemd/opsec-killswitch.service" \
    "$ROOT/configs/systemd/opsec-boot-advanced.service" "$ROOT/configs/systemd/opsec-hostname-randomize.service" \
    "$ROOT/configs/systemd/opsec-mac-randomize.service" /etc/systemd/system/
install -m 0644 "$ROOT/configs/desktop/opsec-browser.desktop" "$ROOT/configs/desktop/opsec-toggle.desktop" /usr/share/applications/
install -m 0644 "$ROOT/configs/polkit/com.opsec.mode.policy" /usr/share/polkit-1/actions/
install -m 0644 "$ROOT/configs/udev/99-opsec-usb.rules" /etc/udev/rules.d/
install -m 0644 "$ROOT/configs/cron/opsec-banner-cache" "$ROOT/configs/cron/opsec-log-rotate" /etc/cron.d/

install -d -o "$REAL_USER" -g "$REAL_USER" -m 0700 "$REAL_HOME/.config/conky"
install -o "$REAL_USER" -g "$REAL_USER" -m 0755 "$ROOT"/conky/*.sh "$REAL_HOME/.config/conky/"
install -o "$REAL_USER" -g "$REAL_USER" -m 0644 "$ROOT/conky/conky-opsec-widget.conf" "$REAL_HOME/.config/conky/"
install -o "$REAL_USER" -g "$REAL_USER" -m 0644 "$ROOT/configs/opsec-aliases" "$REAL_HOME/.opsec-aliases"

if [ "$DISTRO" = debian ]; then
    base_url="https://dist.torproject.org/torbrowser/${TOR_BROWSER_VERSION}"
    archive="/var/lib/opsec/tor-browser/tor-browser-linux-x86_64-${TOR_BROWSER_VERSION}.tar.xz"
    signature="${archive}.asc"
    curl --fail --location --proto '=https' --tlsv1.2 -o "$archive" \
        "$base_url/tor-browser-linux-x86_64-${TOR_BROWSER_VERSION}.tar.xz"
    curl --fail --location --proto '=https' --tlsv1.2 -o "$signature" \
        "$base_url/tor-browser-linux-x86_64-${TOR_BROWSER_VERSION}.tar.xz.asc"
    printf '%s  %s\n' "$TOR_BROWSER_SHA256" "$archive" | sha256sum -c -
    gpgv --keyring /usr/share/torbrowser-launcher/tor-browser-developers.asc "$signature" "$archive"
    chmod 0444 "$archive" "$signature"
fi

for service in NetworkManager.service networking.service systemd-networkd.service; do
    unit="$(systemctl show -p FragmentPath --value "$service" 2>/dev/null || true)"
    [ -n "$unit" ] || continue
    install -d -m 0755 "/etc/systemd/system/${service}.d"
    install -m 0644 "$ROOT/configs/systemd/opsec-browser-recovery-requirement.conf" \
        "/etc/systemd/system/${service}.d/50-opsec-browser-recovery.conf"
done

apparmor_parser -Q -K /usr/local/share/opsec/apparmor/opsec-dirty-browser-block
systemctl daemon-reload
systemctl enable opsec-browser-recovery.service
if [ -S "/run/user/${REAL_UID}/bus" ]; then
    runuser -u "$REAL_USER" -- env XDG_RUNTIME_DIR="/run/user/${REAL_UID}" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${REAL_UID}/bus" systemctl --user daemon-reload
fi
udevadm control --reload-rules 2>/dev/null || true
"$txn" commit "$deploy_id" "$REAL_HOME"
trap - ERR INT TERM

ok "installed transactionally (deployment ID: $deploy_id)"
info "activate with: sudo opsec-mode on"
info "recover deployment with: sudo $txn restore $deploy_id $REAL_HOME"
