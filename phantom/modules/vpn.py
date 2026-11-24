"""WireGuard VPN server deployment module."""

import re

CYAN = "\033[38;5;51m"
WHITE = "\033[38;5;255m"
GREY = "\033[38;5;244m"
RESET = "\033[0m"

_IP_RE = re.compile(r'^\d+\.\d+\.\d+\.\d+$')

_ENV = f"{GREY}(from .env){RESET}"


def gather_config(config):
    """Gather WireGuard VPN configuration."""
    print(f"\n{CYAN}  ┌─ WireGuard VPN Configuration ──────────────────────┐{RESET}")

    if config.get("vpn_port"):
        print(f"  {CYAN}│{RESET}  Listen port: {WHITE}{config['vpn_port']}{RESET} {_ENV}")
    else:
        config["vpn_port"] = input(
            f"  {CYAN}│{RESET}  Listen port [{WHITE}51820{RESET}]: "
        ).strip() or "51820"

    if config.get("vpn_client_count"):
        print(f"  {CYAN}│{RESET}  Client configs: {WHITE}{config['vpn_client_count']}{RESET} {_ENV}")
    else:
        config["vpn_client_count"] = input(
            f"  {CYAN}│{RESET}  Number of client configs [{WHITE}3{RESET}]: "
        ).strip() or "3"

    try:
        config["vpn_client_count"] = int(config["vpn_client_count"])
    except (ValueError, TypeError):
        config["vpn_client_count"] = 3

    if config.get("vpn_dns"):
        print(f"  {CYAN}│{RESET}  Client DNS: {WHITE}{config['vpn_dns']}{RESET} {_ENV}")
    else:
        config["vpn_dns"] = input(
            f"  {CYAN}│{RESET}  Client DNS server [{WHITE}1.1.1.1{RESET}]: "
        ).strip() or "1.1.1.1"

    if config.get("vpn_allowed_ips"):
        print(f"  {CYAN}│{RESET}  Allowed IPs: {WHITE}{config['vpn_allowed_ips']}{RESET} {_ENV}")
    else:
        config["vpn_allowed_ips"] = input(
            f"  {CYAN}│{RESET}  Allowed IPs [{WHITE}0.0.0.0/0, ::/0{RESET}]: "
        ).strip() or "0.0.0.0/0, ::/0"

    if config.get("vpn_subnet"):
        print(f"  {CYAN}│{RESET}  VPN subnet: {WHITE}{config['vpn_subnet']}{RESET} {_ENV}")
    else:
        config["vpn_subnet"] = input(
            f"  {CYAN}│{RESET}  VPN subnet [{WHITE}10.66.66.0/24{RESET}]: "
        ).strip() or "10.66.66.0/24"

    # Cloudflare Tunnel (optional)
    if config.get("domain") and not _IP_RE.match(config.get("domain", "")):
        if config.get("cf_tunnel_token"):
            print(f"  {CYAN}│{RESET}  CF tunnel token: {WHITE}***{RESET} {GREY}(from .env){RESET}")
        else:
            cf_token = input(
                f"  {CYAN}│{RESET}  Cloudflare API token for tunnel [{WHITE}skip{RESET}]: "
            ).strip()
            if cf_token:
                config["cf_tunnel_token"] = cf_token

    print(f"  {CYAN}└─────────────────────────────────────────────────────┘{RESET}")
    return config
