#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALLER="$ROOT/scripts/opsec-install.sh"
TXN="$ROOT/scripts/opsec-browser-deploy-transaction.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

bash -n "$ROOT/install.sh" "$INSTALLER" "$TXN"
grep -Fq '"$txn" prepare "$deploy_id" "$REAL_HOME"' "$INSTALLER" || fail "installer does not snapshot before deployment"
grep -Fq 'trap rollback ERR INT TERM' "$INSTALLER" || fail "installer does not arm rollback"
grep -Fq '"$txn" commit "$deploy_id" "$REAL_HOME"' "$INSTALLER" || fail "installer does not commit the transaction"
grep -Fq 'sha256sum -c -' "$INSTALLER" || fail "Tor Browser checksum gate missing"
grep -Fq 'gpgv --keyring' "$INSTALLER" || fail "Tor Browser signature gate missing"
grep -Fq 'apparmor_parser -Q -K' "$INSTALLER" || fail "AppArmor parse gate missing"
grep -Fq 'systemctl enable opsec-browser-recovery.service' "$INSTALLER" || fail "early recovery is not enabled"
grep -Fq '[ -e /etc/opsec/opsec.conf ] || install' "$INSTALLER" || fail "existing operator config would be overwritten"
grep -Fq '"$user_home/.config/conky"' "$TXN" || fail "Conky directory lifecycle is not tracked"
grep -Fq '"$user_home/.config"' "$TXN" || fail "Conky parent directory lifecycle is not tracked"
grep -Fq '$(stat -c %a "$target")' "$TXN" || fail "directory mode is not snapshotted"
grep -Fq 'chown "$owner:$group" "$target"' "$TXN" || fail "directory ownership is not restored"

for target in \
    /usr/local/bin/opsec-browser \
    /usr/local/bin/opsec-mode.sh \
    /usr/local/bin/opsec-killswitch.sh \
    /usr/local/bin/opsec-browser-policy.sh \
    /usr/local/libexec/opsec-browser-run.sh \
    /usr/local/libexec/opsec-browser-postcheck.sh \
    /usr/local/lib/opsec/opsec-lib.sh \
    /usr/local/share/opsec/apparmor/opsec-dirty-browser-block \
    /usr/lib/systemd/user/opsec-browser.service \
    /etc/systemd/system/opsec-browser-recovery.service \
    /etc/systemd/system/opsec-killswitch.service \
    /usr/share/applications/opsec-browser.desktop \
    /etc/opsec/opsec.conf; do
    grep -Fq "$target" "$TXN" || fail "rollback manifest is missing $target"
done

echo "PASS: transactional installer contract"
