#!/bin/bash
# Regression checks for fail-closed OPSEC Browser invariants.

set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
scripts="$repo/scripts"
opsec_lib="$repo/lib/opsec-lib.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

for script in \
    opsec-browser opsec-browser-run.sh opsec-browser-postcheck.sh \
    opsec-browser-policy.sh opsec-browser-recovery.sh opsec-mode.sh \
    opsec-killswitch.sh opsec-preflight.sh; do
    bash -n "$scripts/$script" || fail "$script does not parse"
    head -c 12 "$scripts/$script" | grep -q '^#!/bin/bash' || fail "$script has an invalid shebang"
    ! LC_ALL=C grep -q $'\r' "$scripts/$script" || fail "$script contains CRLF data"
done

grep -q '^    export TOR_PROVIDER=none$' "$scripts/opsec-browser-run.sh" || fail "provider-none mode missing"
grep -q '^    export TOR_SKIP_LAUNCH=1$' "$scripts/opsec-browser-run.sh" || fail "bundled Tor launch suppression missing"
! grep -Eq 'TOR_CONTROL_PASSWD|ControlPort|HashedControlPassword' "$scripts/opsec-browser-run.sh" || fail "control credential reintroduced"
grep -q 'sha256sum -c' "$scripts/opsec-browser-run.sh" || fail "clean archive checksum gate missing"
grep -q '^verify_immutable_archive()' "$scripts/opsec-browser-run.sh" || fail "sandbox-aware archive ownership gate missing"
grep -Fq 'case "$owner" in 0|65534)' "$scripts/opsec-browser-run.sh" || fail "user-namespace root mapping is not handled"
grep -Fq '8#$mode & 0022' "$scripts/opsec-browser-run.sh" || fail "writable browser archive is not rejected"
grep -q '^configure_system_tor_profile()' "$scripts/opsec-browser-run.sh" || fail "disposable system-Tor profile setup missing"
grep -Fq 'user_pref("network.proxy.failover_direct", false);' "$scripts/opsec-browser-run.sh" || fail "browser proxy cannot fail closed"
grep -Fq 'user_pref("network.proxy.no_proxies_on", "");' "$scripts/opsec-browser-run.sh" || fail "browser proxy bypass list is not empty"
grep -Fq 'user_pref("extensions.torlauncher.start_tor", false);' "$scripts/opsec-browser-run.sh" || fail "bundled Tor preference is not disabled"
grep -Fq 'find "$runtime_root" -xdev -type f -name user.js' "$scripts/opsec-browser-postcheck.sh" || fail "postcheck does not inspect authoritative startup preferences"
! grep -Fq 'find "$runtime_root" -xdev -type f -name prefs.js' "$scripts/opsec-browser-postcheck.sh" || fail "postcheck relies on shutdown-persisted Firefox preferences"
grep -q '/var/lib/opsec/browser-policy' "$scripts/opsec-browser-policy.sh" || fail "durable policy journal missing"
grep -q 'validate_replaceable_placeholder brave' "$scripts/opsec-browser-policy.sh" || fail "packaged Brave profile compatibility gate missing"
grep -q 'verify_chromium_baseline /opt/brave-bin/brave brave' "$scripts/opsec-browser-policy.sh" || fail "live Brave baseline attachment gate missing"
! grep -q -- '--filter.exe=.*--show=profiles' "$scripts/opsec-browser-policy.sh" || fail "mutually exclusive aa-status filters reintroduced"
grep -q '^validate_firefox_launcher()' "$scripts/opsec-browser-policy.sh" || fail "Arch Firefox wrapper validation missing"
grep -q 'launcher=$(realpath -e "$launcher")' "$scripts/opsec-browser-policy.sh" || fail "Firefox launcher is not canonicalized across merged-/usr paths"
grep -Fq 'exec /usr/lib/firefox/firefox "$@"' "$scripts/opsec-browser-policy.sh" || fail "exact Arch Firefox wrapper target gate missing"
grep -q '^stop_probe_group()' "$scripts/opsec-browser-policy.sh" || fail "bounded browser probe cleanup missing"
grep -q 'profile opsec-dirty-firefox /usr/lib/firefox/firefox' "$repo/configs/apparmor/opsec-dirty-browser-block" || fail "fixed Firefox network-deny attachment missing"
grep -q 'opsec-dirty-firefox /usr/lib/firefox/firefox flags=(kill)' "$repo/configs/apparmor/opsec-dirty-browser-block" || fail "Firefox dirty-browser profile is not kill-enforcing"
grep -q 'verify_actual_attachment /usr/lib/firefox/firefox opsec-dirty-firefox' "$scripts/opsec-browser-policy.sh" || fail "Firefox live attachment gate missing"
grep -q 'verify_firefox_baseline "$home/.local/opt/tor-browser/app/Browser/firefox.real"' "$scripts/opsec-browser-policy.sh" || fail "Tor Browser baseline does not probe the real executable"
grep -q 'verify_actual_attachment "$home/.local/opt/tor-browser/app/Browser/firefox.real" opsec-dirty-tor-browser-real' "$scripts/opsec-browser-policy.sh" || fail "Tor Browser real executable attachment gate missing"
! grep -q 'verify_actual_attachment "$home/.local/opt/tor-browser/app/Browser/firefox" opsec-dirty-tor-browser ' "$scripts/opsec-browser-policy.sh" || fail "Tor Browser shell wrapper is incorrectly treated as /proc executable"
grep -q '"\$expected (kill)"' "$scripts/opsec-browser-policy.sh" || fail "kill-mode process attachment is not accepted"
grep -q 'apparmor_parser -R /etc/apparmor.d/firefox' "$scripts/opsec-browser-policy.sh" || fail "Firefox placeholder is not unloaded before OPSEC attachment"
! grep -q '/sys/kernel/security/apparmor/policy/profiles/.*/attach' "$scripts/opsec-browser-policy.sh" || fail "weak AppArmor attachment-text check reintroduced"
grep -A30 '^verify_policy()' "$scripts/opsec-browser-policy.sh" | grep -q 'verify_chromium_attachment /opt/brave-bin/brave' || fail "status lacks live Brave attachment proof"
grep -q 'reload_packaged_placeholders' "$scripts/opsec-browser-policy.sh" || fail "packaged browser profile recovery missing"
grep -q 'strict-status' "$scripts/opsec-browser-policy.sh" || fail "verified strict firewall swap gate missing"
grep -q 'OPSEC_POLICY_SOURCE' "$scripts/opsec-browser-policy.sh" || fail "policy source cannot be pinned for source-tree integration tests"
grep -q '^assert_strict()' "$repo/tests/test-opsec-browser-live.sh" || fail "live policy test lacks strict-firewall assertion"
! grep -Eq 'opsec-mode|kill-switch.*off|resolv.conf|NetworkManager|systemd-networkd|nmcli' "$repo/tests/test-opsec-browser-live.sh" || fail "live policy test exceeds its controlled integration scope"
grep -q 'strict_owned=false' "$repo/tests/test-opsec-browser-live.sh" || fail "live policy test lacks strict-table ownership tracking"
grep -q 'fingerprint_strict' "$repo/tests/test-opsec-browser-live.sh" || fail "live policy test lacks strict-table fingerprint guard"
grep -q 'transparent HTTPS was not forced through Tor' "$repo/tests/test-opsec-browser-live.sh" || fail "live policy test lacks transparent Tor proof"
grep -q 'loopback DNS was not redirected to Tor DNSPort' "$repo/tests/test-opsec-browser-live.sh" || fail "live policy test lacks loopback DNS redirect proof"
grep -q '^arm_watchdog()' "$repo/tests/test-opsec-browser-live.sh" || fail "live policy test lacks independent timeout rollback"
grep -q -- '--on-active=' "$repo/tests/test-opsec-browser-live.sh" || fail "live policy rollback is not independently scheduled"
grep -q '^ensure_tor_ready()' "$repo/tests/test-opsec-browser-live.sh" || fail "live policy test does not manage system Tor readiness"
grep -q '^restore_tor_config()' "$repo/tests/test-opsec-browser-live.sh" || fail "live policy test lacks torrc rollback"
grep -q 'policy_sha=$(sha256sum "$txn/opsec-dirty-browser-block"' "$scripts/opsec-browser-policy.sh" || fail "policy recovery hash assignment missing"
! grep -q 'restore-root' "$scripts/opsec-browser-policy.sh" || fail "policy restore stages user data below a root-only transaction"
! grep -q 'user-stage' "$scripts/opsec-browser-deploy-transaction.sh" || fail "deployment restore stages user data below a root-only backup"
grep -q 'emergency-on' "$scripts/opsec-mode.sh" || fail "emergency fail-closed firewall missing"
grep -q '^arm_activation_watchdog()' "$scripts/opsec-mode.sh" || fail "production activation lacks timed rollback"
grep -q '^verify_tor_service_identity()' "$scripts/opsec-mode.sh" || fail "Tor service identity lacks restart-stable verification"
grep -q 'Activation refused: automatic rollback could not be armed' "$scripts/opsec-mode.sh" || fail "activation can mutate without a rollback timer"
grep -q 'ln -sfn /usr/local/bin/opsec-mode.sh /usr/local/bin/opsec-mode' "$scripts/opsec-install.sh" || fail "canonical opsec-mode command is not deployed"
grep -q 'Dirty browsers network-blocked' "$scripts/opsec-preflight.sh" || fail "dirty-browser preflight gate missing"
grep -q 'Transparent traffic uses Tor' "$scripts/opsec-preflight.sh" || fail "transparent Tor proof missing"
grep -q 'System Tor SOCKS usable' "$scripts/opsec-preflight.sh" || fail "SOCKS Tor proof missing"
grep -q 'SocksPort 127.0.0.1:' "$opsec_lib" || fail "Tor SOCKS listener is not loopback-bound"
grep -q 'TransPort 127.0.0.1:' "$opsec_lib" || fail "Tor transparent listener is not loopback-bound"
grep -q 'DNSPort 127.0.0.1:' "$opsec_lib" || fail "Tor DNS listener is not loopback-bound"
grep -q 'meta skuid \$TOR_UID meta l4proto tcp accept' "$scripts/opsec-killswitch.sh" || fail "Tor UID egress is not TCP-only"
grep -q "sed -i '1i delete table inet opsec_strict'" "$scripts/opsec-killswitch.sh" || fail "atomic strict nft replacement is missing"
grep -q '^ks_policy_matches()' "$scripts/opsec-killswitch.sh" || fail "strict firewall lacks exact policy fingerprint verification"
grep -q 'strict-status' "$scripts/opsec-preflight.sh" || fail "preflight trusts firewall table existence"
grep -q 'activation-unsafe' "$scripts/opsec-banner.sh" || fail "terminal banner lacks unverified-containment state"
! grep -q '^ExecStartPost=' "$repo/configs/systemd/user/opsec-browser.service" || fail "postcheck would deadlock behind synchronous browser launch"

output_chain=$(sed -n '/chain output {/,/^  }/p' "$scripts/opsec-killswitch.sh" | head -20)
! grep -q 'ct state established,related accept' <<<"$output_chain" || fail "strict output permits preexisting non-Tor connections"
input_chain=$(sed -n '/chain input {/,/^  }/p' "$scripts/opsec-killswitch.sh" | head -10)
grep -q 'ct state established,related accept' <<<"$input_chain" || fail "strict input blocks Tor reply traffic"
grep -q 'External DNS intercepted' "$scripts/opsec-preflight.sh" || fail "external DNS redirect proof missing"
grep -q 'Non-Tor UDP blocked' "$scripts/opsec-preflight.sh" || fail "negative UDP egress proof missing"

nat_chain=$(sed -n '/chain output_nat {/,/^  }/p' "$scripts/opsec-killswitch.sh" | head -12)
dns_line=$(grep -n 'udp dport 53' <<<"$nat_chain" | head -1 | cut -d: -f1)
loopback_line=$(grep -n 'ip daddr 127.0.0.0/8 return' <<<"$nat_chain" | head -1 | cut -d: -f1)
[ -n "$dns_line" ] && [ -n "$loopback_line" ] && [ "$dns_line" -lt "$loopback_line" ] || \
    fail "loopback return bypasses Tor DNS redirection"

preflight_line=$(grep -n 'opsec-preflight.sh --full --enforce' "$scripts/opsec-mode.sh" | head -1 | cut -d: -f1)
active_line=$(grep -n 'mv -f "\$_state_tmp" "\$STATE_FILE"' "$scripts/opsec-mode.sh" | head -1 | cut -d: -f1)
[ -n "$preflight_line" ] && [ -n "$active_line" ] && [ "$preflight_line" -lt "$active_line" ] || \
    fail "ACTIVE marker can be published before preflight"

echo "PASS: OPSEC Browser static security invariants"
