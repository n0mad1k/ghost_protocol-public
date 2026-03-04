# phantom — Privacy Server Deployer

Deploy self-hosted privacy infrastructure with a single command. Supports cloud providers, existing servers, and local deployment.

## Server Types

| Service | Status | Description |
|---|---|---|
| Matrix + Element | Ready | Encrypted messaging homeserver with web client |
| WireGuard VPN | Ready | Private VPN server with client config generation |
| Pi-hole DNS | Ready | Ad-blocking DNS server (Docker-based) |
| All-in-One | Ready | Multiple services on one server with nginx reverse proxy |
| Nextcloud | Stub | Self-hosted file sync and collaboration |
| Vaultwarden | Stub | Self-hosted Bitwarden password manager |
| Jellyfin | Stub | Self-hosted media server |
| Mail-in-a-Box | Stub | Self-hosted email |

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
│   └── all_in_one/     # Multi-service composer
├── providers/          # Cloud provisioning
└── logs/               # Deployment artifacts
```

## License

MIT
