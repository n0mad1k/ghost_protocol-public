#!/bin/bash
# opsec-toolkit installer — standalone, no Ansible required
# Usage: sudo ./install.sh [--uninstall]
#
# Installs the OPSEC privacy/security toolkit on Debian/Kali/Ubuntu systems.
# Requires: tor, macchanger, iptables, curl, jq (auto-installed if missing)

set -euo pipefail

# ─── COLORS ──────────────────────────────────────────────────────────────────
RED=$'\e[38;5;196m'
GRN=$'\e[38;5;49m'
YEL=$'\e[38;5;214m'
CYN=$'\e[38;5;45m'
RST=$'\e[0m'

ok()   { echo "${GRN}[+]${RST} $*"; }
warn() { echo "${YEL}[*]${RST} $*"; }
err()  { echo "${RED}[-]${RST} $*"; }
info() { echo "${CYN}[~]${RST} $*"; }

# ─── PREFLIGHT ───────────────────────────────────────────────────────────────
if [ "$EUID" -ne 0 ]; then
    err "Please run as root: sudo ./install.sh"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(eval echo "~${REAL_USER}")

# ─── UNINSTALL ───────────────────────────────────────────────────────────────
if [ "${1:-}" = "--uninstall" ]; then
    echo ""
    warn "Uninstalling OPSEC toolkit..."
    echo ""

    # Stop services
    for svc in opsec-boot-advanced opsec-killswitch opsec-hostname-randomize opsec-mac-randomize; do
        systemctl stop "$svc" 2>/dev/null || true
        systemctl disable "$svc" 2>/dev/null || true
    done

    # Remove scripts
    rm -f /usr/local/bin/opsec-*.sh

    # Remove library
    rm -rf /usr/local/lib/opsec

    # Remove configs (preserve opsec.conf as backup)
    if [ -d /etc/opsec ]; then
        cp /etc/opsec/opsec.conf "/tmp/opsec.conf.backup.$(date +%s)" 2>/dev/null || true
        rm -rf /etc/opsec
    fi

    # Remove systemd services
    rm -f /etc/systemd/system/opsec-*.service
    systemctl daemon-reload

    # Remove cron jobs
    rm -f /etc/cron.d/opsec-*

    # Remove polkit, desktop, udev
    rm -f /usr/share/polkit-1/actions/com.opsec.mode.policy
    rm -f /usr/share/applications/opsec-toggle.desktop
    rm -f /etc/udev/rules.d/99-opsec-usb.rules

    ok "OPSEC toolkit uninstalled"
    info "Config backup saved to /tmp/opsec.conf.backup.*"
    exit 0
fi

# ─── BANNER ──────────────────────────────────────────────────────────────────
echo ""
echo "${CYN}╔══════════════════════════════════════════╗${RST}"
echo "${CYN}║${RST}     ${RED}OPSEC TOOLKIT${RST} — Installer v1.0      ${CYN}║${RST}"
echo "${CYN}║${RST}     Privacy & Security Hardening        ${CYN}║${RST}"
echo "${CYN}╚══════════════════════════════════════════╝${RST}"
echo ""

# ─── DEPENDENCY CHECK ────────────────────────────────────────────────────────
info "Checking dependencies..."

DEPS=(tor macchanger iptables ip6tables curl jq iproute2 net-tools procps)
MISSING=()

for dep in "${DEPS[@]}"; do
    case "$dep" in
        tor)        command -v tor >/dev/null 2>&1 || MISSING+=("tor") ;;
        macchanger) command -v macchanger >/dev/null 2>&1 || MISSING+=("macchanger") ;;
        iptables)   command -v iptables >/dev/null 2>&1 || MISSING+=("iptables") ;;
        ip6tables)  command -v ip6tables >/dev/null 2>&1 || MISSING+=("iptables") ;;
        curl)       command -v curl >/dev/null 2>&1 || MISSING+=("curl") ;;
        jq)         command -v jq >/dev/null 2>&1 || MISSING+=("jq") ;;
        iproute2)   command -v ip >/dev/null 2>&1 || MISSING+=("iproute2") ;;
        net-tools)  command -v netstat >/dev/null 2>&1 || MISSING+=("net-tools") ;;
        procps)     command -v ps >/dev/null 2>&1 || MISSING+=("procps") ;;
    esac
done

# Deduplicate
MISSING=($(printf '%s\n' "${MISSING[@]}" | sort -u))

if [ ${#MISSING[@]} -gt 0 ]; then
    warn "Installing missing packages: ${MISSING[*]}"
    apt-get update -qq
    apt-get install -y -qq "${MISSING[@]}"
    ok "Dependencies installed"
else
    ok "All dependencies present"
fi

# Optional: conky for desktop widget
if ! command -v conky >/dev/null 2>&1; then
    warn "Conky not installed — desktop widget will not be available"
    warn "Install later with: apt install conky-all"
fi

# ─── INSTALL LIBRARY ─────────────────────────────────────────────────────────
info "Installing OPSEC library..."
mkdir -p /usr/local/lib/opsec
cp "$SCRIPT_DIR/lib/opsec-lib.sh" /usr/local/lib/opsec/
chmod 644 /usr/local/lib/opsec/opsec-lib.sh
ok "Library installed → /usr/local/lib/opsec/"

# ─── INSTALL SCRIPTS ─────────────────────────────────────────────────────────
info "Installing OPSEC scripts..."
for script in "$SCRIPT_DIR"/scripts/opsec-*.sh; do
    [ -f "$script" ] || continue
    cp "$script" /usr/local/bin/
    chmod 755 "/usr/local/bin/$(basename "$script")"
done
ok "Scripts installed → /usr/local/bin/"

# ─── INSTALL CONFIGS ─────────────────────────────────────────────────────────
info "Installing configuration..."

# Main config directory
mkdir -p /etc/opsec/{themes,levels,vpn-templates,.harden-backup}

# Main config (don't overwrite existing)
if [ -f /etc/opsec/opsec.conf ]; then
    warn "Existing opsec.conf found — preserving (new config saved as opsec.conf.new)"
    cp "$SCRIPT_DIR/configs/opsec.conf" /etc/opsec/opsec.conf.new
else
    cp "$SCRIPT_DIR/configs/opsec.conf" /etc/opsec/opsec.conf
fi

# Country codes
cp "$SCRIPT_DIR/configs/opsec-country-codes.conf" /etc/opsec/country-codes.conf

# Themes
cp "$SCRIPT_DIR/configs/themes/"*.theme /etc/opsec/themes/

# Levels
for f in "$SCRIPT_DIR/configs/levels/"*.conf; do
    [ -f "$f" ] || continue
    # Map filenames: bare-metal-standard.conf → bare-metal.conf etc.
    cp "$f" /etc/opsec/levels/
done

# VPN templates
cp "$SCRIPT_DIR/configs/vpn-templates/"*.template /etc/opsec/vpn-templates/

# Torrc templates
mkdir -p /etc/opsec/torrc
cp "$SCRIPT_DIR/configs/torrc/torrc-default" /etc/opsec/torrc/
cp "$SCRIPT_DIR/configs/torrc/torrc-opsec" /etc/opsec/torrc/

# DNS configs
[ -f "$SCRIPT_DIR/configs/resolv.conf.opsec" ] && cp "$SCRIPT_DIR/configs/resolv.conf.opsec" /etc/opsec/
[ -f "$SCRIPT_DIR/configs/resolv.conf.head" ] && cp "$SCRIPT_DIR/configs/resolv.conf.head" /etc/opsec/

ok "Configuration installed → /etc/opsec/"

# ─── INSTALL SYSTEMD SERVICES ────────────────────────────────────────────────
info "Installing systemd services..."
for svc in "$SCRIPT_DIR/configs/systemd/"*.service; do
    [ -f "$svc" ] || continue
    cp "$svc" /etc/systemd/system/
done
systemctl daemon-reload

# Enable MAC randomize and hostname randomize at boot
systemctl enable opsec-mac-randomize.service 2>/dev/null || true
systemctl enable opsec-hostname-randomize.service 2>/dev/null || true
ok "Systemd services installed and enabled"

# ─── INSTALL CRON JOBS ──────────────────────────────────────────────────────
info "Installing cron jobs..."
cp "$SCRIPT_DIR/configs/cron/opsec-banner-cache" /etc/cron.d/
cp "$SCRIPT_DIR/configs/cron/opsec-log-rotate" /etc/cron.d/
chmod 644 /etc/cron.d/opsec-*
ok "Cron jobs installed → /etc/cron.d/"

# ─── INSTALL POLKIT POLICY ──────────────────────────────────────────────────
info "Installing polkit policy..."
mkdir -p /usr/share/polkit-1/actions
cp "$SCRIPT_DIR/configs/polkit/com.opsec.mode.policy" /usr/share/polkit-1/actions/
ok "Polkit policy installed"

# ─── INSTALL DESKTOP ENTRY ──────────────────────────────────────────────────
info "Installing desktop entry..."
cp "$SCRIPT_DIR/configs/desktop/opsec-toggle.desktop" /usr/share/applications/
ok "Desktop entry installed"

# ─── INSTALL UDEV RULES ─────────────────────────────────────────────────────
info "Installing udev rules..."
cp "$SCRIPT_DIR/configs/udev/99-opsec-usb.rules" /etc/udev/rules.d/
udevadm control --reload-rules 2>/dev/null || true
ok "Udev rules installed"

# ─── INSTALL CONKY WIDGET (user-space) ──────────────────────────────────────
info "Installing Conky widget files..."
CONKY_DIR="${REAL_HOME}/.config/conky"
mkdir -p "$CONKY_DIR"
for f in "$SCRIPT_DIR"/conky/*; do
    [ -f "$f" ] || continue
    cp "$f" "$CONKY_DIR/"
    chown "${REAL_USER}:${REAL_USER}" "$CONKY_DIR/$(basename "$f")"
done
chmod +x "$CONKY_DIR"/*.sh 2>/dev/null || true
ok "Conky widget installed → ${CONKY_DIR}/"

# ─── INSTALL SHELL ALIASES ──────────────────────────────────────────────────
info "Installing shell aliases..."
ALIAS_FILE="${REAL_HOME}/.opsec-aliases"
cp "$SCRIPT_DIR/configs/opsec-aliases" "$ALIAS_FILE"
chown "${REAL_USER}:${REAL_USER}" "$ALIAS_FILE"

# Add source line to .bashrc and .zshrc if not already present
for rc in "${REAL_HOME}/.bashrc" "${REAL_HOME}/.zshrc"; do
    if [ -f "$rc" ]; then
        if ! grep -q '.opsec-aliases' "$rc" 2>/dev/null; then
            echo "" >> "$rc"
            echo "# OPSEC toolkit aliases" >> "$rc"
            echo "[ -f ~/.opsec-aliases ] && . ~/.opsec-aliases" >> "$rc"
            chown "${REAL_USER}:${REAL_USER}" "$rc"
        fi
    fi
done
ok "Aliases installed → ${ALIAS_FILE}"

# ─── TOR CONFIGURATION ──────────────────────────────────────────────────────
info "Configuring Tor..."

# Ensure tor log directory exists
mkdir -p /var/log/tor /run/tor
chown debian-tor:debian-tor /var/log/tor /run/tor 2>/dev/null || true

# Stop tor if running (we'll configure, user starts via opsec-on)
systemctl stop tor 2>/dev/null || true

ok "Tor configured (start with: opsec-on)"

# ─── TMPFS FOR LOGS ─────────────────────────────────────────────────────────
info "Setting up tmpfs for OPSEC logs..."
if ! grep -q 'opsec-logs' /etc/fstab 2>/dev/null; then
    echo "" >> /etc/fstab
    echo "# OPSEC: volatile log storage (RAM-only, cleared on reboot)" >> /etc/fstab
    echo "tmpfs /var/log/opsec tmpfs nosuid,nodev,noexec,mode=0700,size=50M 0 0  # opsec-logs" >> /etc/fstab
fi
mkdir -p /var/log/opsec
mount /var/log/opsec 2>/dev/null || mount -t tmpfs -o nosuid,nodev,noexec,mode=0700,size=50M tmpfs /var/log/opsec 2>/dev/null || true
ok "OPSEC logs on tmpfs (RAM-only)"

# ─── CACHE DIRECTORY ─────────────────────────────────────────────────────────
mkdir -p /tmp/.opsec-cache
chown "${REAL_USER}:${REAL_USER}" /tmp/.opsec-cache 2>/dev/null || true

# ─── POST-INSTALL ────────────────────────────────────────────────────────────
echo ""
echo "${CYN}══════════════════════════════════════════${RST}"
ok "OPSEC toolkit installed successfully!"
echo "${CYN}══════════════════════════════════════════${RST}"
echo ""
info "Quick start:"
echo "  ${GRN}opsec-on${RST}            — Activate ghost mode (Tor + kill switch + hardening)"
echo "  ${GRN}opsec-off${RST}           — Deactivate ghost mode"
echo "  ${GRN}opsec-config${RST}        — Interactive configuration TUI"
echo "  ${GRN}opsec-show${RST}          — Show current status"
echo "  ${GRN}killswitch-on${RST}       — Activate kill switch only"
echo "  ${GRN}opsec-preflight${RST}     — Pre-session readiness check"
echo ""
info "Reload your shell to activate aliases:"
echo "  ${GRN}source ~/.bashrc${RST}  or  ${GRN}source ~/.zshrc${RST}"
echo ""
info "Uninstall with: ${YEL}sudo ./install.sh --uninstall${RST}"
echo ""
