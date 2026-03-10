# phantom — Privacy Server Deployer

Deploy self-hosted privacy infrastructure with a single command. Supports cloud providers, existing servers, and local deployment.

## Server Types

| Service | Status | Description |
|---|---|---|
| Matrix + Element | Ready | Encrypted messaging homeserver with web client |
| WireGuard VPN | Ready | Private VPN server with client config generation |
| Pi-hole DNS | Ready | Ad-blocking DNS server (native) |
| Nextcloud | Ready | Self-hosted file sync and collaboration |
| Vaultwarden | Ready | Self-hosted Bitwarden password manager |
| Jellyfin | Ready | Self-hosted media server |
| Mail-in-a-Box | Ready | Self-hosted email |
| All-in-One | Ready | Multiple services on one server with nginx reverse proxy |

## Tested Deployments

| Service | Provider | Target | Result |
|---|---|---|---|
| Matrix + Element | Linode | Cloud (Ubuntu) | Passed |
| Matrix + Element | AWS | Cloud (Ubuntu) | Untested |
| Matrix + Element | FlokiNET | Cloud | Untested |
| Matrix + Element | Existing Server | Local (Debian 13) | Passed |
| Matrix + Element | Existing Server | Local (Raspbian) | Untested |
| WireGuard VPN | Linode | Cloud (Ubuntu) | Untested |
| WireGuard VPN | AWS | Cloud (Ubuntu) | Untested |
| WireGuard VPN | FlokiNET | Cloud | Untested |
| WireGuard VPN | Existing Server | Local (Debian 13) | Passed |
| WireGuard VPN | Existing Server | Local (Raspbian) | Untested |
| Pi-hole DNS | Linode | Cloud (Ubuntu) | Untested |
| Pi-hole DNS | AWS | Cloud (Ubuntu) | Untested |
| Pi-hole DNS | Existing Server | Local (Debian 13) | Passed |
| Pi-hole DNS | Existing Server | Local (Raspbian) | Untested |
| Nextcloud | Linode | Cloud (Ubuntu) | Untested |
| Nextcloud | AWS | Cloud (Ubuntu) | Untested |
| Nextcloud | FlokiNET | Cloud | Untested |
| Nextcloud | Existing Server | Local (Debian 13) | Untested |
| Vaultwarden | Linode | Cloud (Ubuntu) | Untested |
| Vaultwarden | AWS | Cloud (Ubuntu) | Untested |
| Vaultwarden | FlokiNET | Cloud | Untested |
| Vaultwarden | Existing Server | Local (Debian 13) | Untested |
| Jellyfin | Linode | Cloud (Ubuntu) | Untested |
| Jellyfin | AWS | Cloud (Ubuntu) | Untested |
| Jellyfin | Existing Server | Local (Debian 13) | Untested |
| Jellyfin | Existing Server | Local (Raspbian) | Untested |
| Mail-in-a-Box | Linode | Cloud (Ubuntu) | Untested |
| Mail-in-a-Box | AWS | Cloud (Ubuntu) | Untested |
| All-in-One | Linode | Cloud (Ubuntu) | Untested |
| All-in-One | AWS | Cloud (Ubuntu) | Untested |
| All-in-One | Existing Server | Local (Debian 13) | Untested |

## Deployment Targets

- **Linode** — Automated provisioning via API
- **AWS EC2** — Automated provisioning via API
- **FlokiNET** — Register pre-provisioned server
- **Existing server** — Any server with SSH access
- **Local** — Deploy directly on the current machine

## Quick Start

```bash
# Requirements
pip install ansible pyyaml   # or: apt install ansible python3-yaml
# For AWS deployments:
pip install boto3
ansible-galaxy collection install amazon.aws

# Launch
python3 phantom.py
```

Select a service, choose a deployment target, provide configuration, and phantom handles the rest:
1. Provisions infrastructure (if cloud)
2. Applies base hardening (UFW, fail2ban, SSH lockdown, kernel hardening)
3. Deploys the selected service
4. Saves deployment info to `logs/`

## All-in-One Deployment

The all-in-one option deploys multiple services on a single server with:
- Nginx reverse proxy with TLS termination
- Let's Encrypt certificates via Certbot
- Per-service vhost routing

**Warning**: Running multiple services on one server means a compromise of one service risks all services. Use for lab/testing or personal use where convenience outweighs isolation. For production, deploy one service per server.

## Local Deployment

Select "Local (this machine)" as the deployment target to install services directly on your current system. This is useful for:
- Home lab servers
- Raspberry Pi deployments
- LAN-only services
- Testing before cloud deployment

No SSH key generation or remote provisioning is needed for local deployments.

## Provider Setup

### Linode
1. Create an API token at https://cloud.linode.com/profile/tokens
2. Select "Linode" when prompted and paste your token

### AWS
1. Create an IAM user with EC2 permissions
2. Generate access keys
3. Select "AWS" when prompted and provide credentials

### FlokiNET
1. Provision a server through FlokiNET's control panel
2. Select "FlokiNET" and provide the server IP

## Project Structure

```
phantom/
├── phantom.py          # Main CLI
├── modules/            # Per-service configuration
├── playbooks/          # Ansible playbooks
│   ├── common/         # Shared hardening
│   ├── matrix/         # Synapse + Element
│   ├── vpn/            # WireGuard
│   ├── dns/            # Pi-hole
│   ├── cloud/          # Nextcloud
│   ├── vault/          # Vaultwarden
│   ├── media/          # Jellyfin
│   ├── email/          # Mail-in-a-Box
│   └── all_in_one/     # Multi-service composer
├── providers/          # Cloud provisioning
└── logs/               # Deployment artifacts
```

## License

MIT
