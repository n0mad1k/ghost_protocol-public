# Ghost Protocol OPSEC

Fail-closed Linux routing for a disposable Tor Browser profile using the system Tor daemon.

## Security boundary

- `nftables` permits network egress only from the Tor service account while Ghost Mode is active.
- DNS is redirected to Tor's local DNS listener.
- Persistent Firefox, Brave, Chromium, and Tor Browser profiles are stopped and denied network access.
- The supported browser launcher extracts a clean Tor Browser tree into a systemd-owned runtime directory and forces it to the system Tor SOCKS listener.
- A five-minute activation watchdog automatically tears down a stalled activation and restores normal networking.
- Failed activation remains contained and never reports `ACTIVE` without positive firewall, DNS, Tor, and browser-policy checks.

This does not make an unsafe host, logged-in identity, browser action, document, or behavior anonymous. It also cannot prevent an administrator from bypassing its controls.

## Anonymity-set defaults

The shipped configuration intentionally leaves these Tor directives unset:

- `ExcludeExitNodes` and `StrictNodes`
- `MaxCircuitDirtiness`
- `ConnectionPadding`
- `NumEntryGuards`
- bridges and automatic decoy traffic

Tor therefore uses its upstream and consensus-driven defaults. Custom exit policies, rapid circuit rotation, forced guard counts, padding overrides, bridges, and traffic blending can make a deployment more distinguishable. Enable them only for a documented threat model.

## Supported platforms

- Arch Linux with the tested `tor-browser` package
- Debian-family systems with the pinned, signature-verified Tor Browser archive
- systemd, nftables, AppArmor, and a normal desktop user session

Unknown distributions or browser layouts fail closed.

## Install

```bash
sudo ./install.sh
```

The installer creates an exact rollback transaction under `/var/backups/opsec-browser/` before changing system files. Package installation is the only non-transactional step.

## Use

```bash
sudo opsec-mode on
opsec-browser
sudo opsec-mode status
sudo opsec-mode off
```

Do not launch persistent-profile browsers while Ghost Mode is active. The policy blocks their network access, but direct binary execution remains an unsupported path.

## Validation

```bash
./tests/test-opsec-browser-static.sh
./tests/test-public-defaults.sh
```

These repository checks validate policy construction and release hygiene. Run the live integration harness on a disposable target before relying on the toolkit for sensitive work.

## License

MIT. See `LICENSE` and `NOTICE.md` in the exported repository.
