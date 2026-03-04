# ghost_protocol

A privacy toolkit for individuals who take digital autonomy seriously. Three tools, one goal: control your own infrastructure.

## Components

### opsec/
OPSEC hardening suite for Linux systems. MAC randomization, DNS leak prevention, kill switches, Tor integration, hostname randomization, and a desktop status widget. Configurable deployment levels from standard privacy to full paranoid mode.

```bash
cd opsec && sudo ./install.sh
```

### covert_sd/
Covert SD card tool for secure storage operations. Encryption, hidden volumes, and plausible deniability for portable media.

```bash
cd covert_sd && python3 covert_sd_card_tool.py
```

### phantom/
Privacy server deployer. Stand up Matrix, WireGuard, Pi-hole, and more on cloud providers or your own hardware — hardened out of the box.

```bash
cd phantom && python3 phantom.py
```

## Who This Is For

- Journalists protecting sources
- Researchers handling sensitive data
- Privacy advocates practicing what they preach
- Anyone who believes infrastructure shouldn't require trust in third parties

## Quick Start

```bash
git clone <this-repo> ghost_protocol
cd ghost_protocol

# OPSEC hardening
cd opsec && sudo ./install.sh

# Deploy a privacy server
cd ../phantom && python3 phantom.py

# Covert SD operations
cd ../covert_sd && python3 covert_sd_card_tool.py
```

## Requirements

- **opsec**: Linux (Debian/Ubuntu), root access
- **covert_sd**: Python 3.8+, cryptsetup
- **phantom**: Python 3.8+, Ansible 2.12+, SSH, pyyaml
  - For AWS deployments: `ansible-galaxy collection install amazon.aws` and `pip install boto3`

## Important: Configure Before Use

**This toolkit ships with intentionally blank or generic defaults.** You must configure it for your environment before relying on it.

### opsec/
After installing, run `sudo opsec-config.sh` to set:
- **Tor exit node exclusions** (`TOR_BLACKLIST`) — empty by default. Set country codes based on your threat model (e.g., `us,gb,ca,au,nz` for Five Eyes exclusion). See `configs/opsec-country-codes.conf` for presets.
- **DNS mode** (`DNS_MODE`) — defaults to `tor`. Choose based on your needs: `tor`, `quad9`, `cloudflare`, `doh`, `dot`, or `custom`.
- **Deployment level** — run `sudo opsec-config.sh --level apply <level>` to select a preset. Review `configs/levels/` to understand what each level enables.
- **Widget theme** (`WIDGET_THEME`) — defaults to `default`. Run `sudo opsec-config.sh --theme list` for options.
- **Hostname pattern** (`HOSTNAME_PATTERN`) — defaults to `desktop`. Set to `random` if you want randomization on boot.
- **MAC randomization**, **kill switch behavior**, and **traffic blending** all need to be reviewed and enabled per your use case.

The generic defaults are safe but minimal. They will **not** protect you against a sophisticated adversary without customization. Review `/etc/opsec/opsec.conf` after install and adjust every section for your threat model.

### phantom/
Each deployment prompts for service-specific configuration (domains, credentials, DNS providers). There are no hardcoded server addresses or API keys. You supply everything at deploy time.

### covert_sd/
The tool prompts for all encryption parameters interactively. No defaults to change, but read the README for security model details.

## Responsible Use

This toolkit is intended for **legitimate privacy protection**: journalists safeguarding sources, researchers handling sensitive data, organizations protecting communications, and individuals exercising their right to privacy.

- Secure deletion features are irreversible. Understand what you are deleting.
- Network anonymization is not foolproof. No tool provides absolute anonymity.
- Comply with applicable laws in your jurisdiction.
- This software is provided as-is with no warranty. You are responsible for how you use it.

## License

MIT — see [LICENSE](LICENSE)
