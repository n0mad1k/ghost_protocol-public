# opsec — Privacy Hardening Toolkit

A comprehensive OPSEC hardening suite for Linux systems. Designed for anyone who needs strong privacy defaults without constant manual configuration.

## Features

- **Kill Switch**: iptables rules that block all non-Tor/VPN traffic when enabled
- **MAC Randomization**: Automatic MAC address spoofing on boot
- **Hostname Randomization**: Random hostname generation to prevent tracking
- **DNS Leak Prevention**: Locks DNS to privacy resolvers with immutable resolv.conf
- **Tor Integration**: Configurable Tor routing with circuit management, exit node filtering, and bridge support
- **Traffic Blending**: Decoy browsing traffic to mask real activity patterns
- **Desktop Widget**: Conky-based status HUD with theme support (7 themes included)
- **Deployment Levels**: Preset configurations from standard privacy to full paranoid mode
- **Profile System**: Save, load, and switch between configuration profiles
- **SSH Honeypot Detection**: Check SSH servers against known honeypot signatures
- **WiFi Security Auditing**: Check wireless configuration for common leaks

## Installation

```bash
sudo ./install.sh
```

This copies scripts to `/usr/local/bin/`, configs to `/etc/opsec/`, and sets up systemd services.

## Usage

```bash
# Interactive configuration
sudo opsec-config.sh

# Toggle ghost mode (advanced privacy)
sudo opsec-mode.sh on
sudo opsec-mode.sh off

# Check OPSEC status
opsec-check.sh

# Pre-flight readiness check
opsec-preflight.sh

# Kill switch control
sudo opsec-killswitch.sh on|off|status

# Apply a deployment level
sudo opsec-config.sh --level apply bare-metal-standard
```

## Deployment Levels

| Level | Description |
|---|---|
| `bare-metal-standard` | Physical machine, ghost mode toggle available |
| `bare-metal-paranoid` | Physical machine, ghost mode always on |
| `cloud-normal` | Cloud VPS, standard privacy (no MAC/hostname) |
| `cloud-paranoid` | Cloud VPS, maximum security always on |

## Configuration

All settings live in `/etc/opsec/opsec.conf`. Edit via `opsec-config.sh` (interactive TUI) or manually.

Key settings:
- `TOR_BLACKLIST` — Comma-separated country codes to exclude from Tor exit nodes
- `DNS_MODE` — DNS resolution mode: `tor`, `quad9`, `cloudflare`, `doh`, `dot`, `custom`
- `HOSTNAME_PATTERN` — Hostname strategy: `desktop`, `random`, `custom`
- `LEVEL_TYPE` — `standard` (toggle) or `paranoid` (always on)

## Widget Themes

Seven color themes for the desktop status widget:

`default` `aurora` `ember` `slate` `cyberpunk` `frost` `terminal`

```bash
sudo opsec-config.sh --theme apply cyberpunk
```

## Important: Review Your Configuration

**This toolkit ships with intentionally generic defaults.** After installing, you **must** run `sudo opsec-config.sh` and review every setting.

Key items that require your input:
- **`TOR_BLACKLIST`** is empty by default. You need to set exit node exclusions based on your threat model.
- **`HOSTNAME_PATTERN`** defaults to `desktop` with no prefix. Set to `random` if you want randomization.
- **Kill switch and traffic blending** are off by default. Enable them if your threat model requires it.
- **Deployment level** should be selected to match your environment (bare metal vs cloud, standard vs paranoid).

The generic defaults are **safe but minimal**. They prevent accidental misconfiguration but do not represent a hardened posture. Customize for your needs.

## Responsible Use

This toolkit is designed for legitimate privacy protection. Secure deletion features are irreversible. Network anonymization tools have limitations and are not a guarantee of anonymity. Comply with applicable laws in your jurisdiction. This software is provided as-is.

## License

MIT
