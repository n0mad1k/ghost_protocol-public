"""WireGuard VPN server deployment module."""

CYAN = "\033[38;5;51m"
WHITE = "\033[38;5;255m"
GREY = "\033[38;5;244m"
RESET = "\033[0m"


def gather_config(config):
    """Gather WireGuard VPN configuration."""
    print(f"\n{CYAN}  ┌─ WireGuard VPN Configuration ──────────────────────┐{RESET}")

    config["vpn_port"] = input(
        f"  {CYAN}│{RESET}  Listen port [{WHITE}51820{RESET}]: "
    ).strip() or "51820"

    config["vpn_client_count"] = input(
        f"  {CYAN}│{RESET}  Number of client configs [{WHITE}3{RESET}]: "
    ).strip() or "3"

    try:
        config["vpn_client_count"] = int(config["vpn_client_count"])
    except ValueError:
        config["vpn_client_count"] = 3

    config["vpn_dns"] = input(
        f"  {CYAN}│{RESET}  Client DNS server [{WHITE}1.1.1.1{RESET}]: "
    ).strip() or "1.1.1.1"

    config["vpn_allowed_ips"] = input(
        f"  {CYAN}│{RESET}  Allowed IPs [{WHITE}0.0.0.0/0, ::/0{RESET}]: "
    ).strip() or "0.0.0.0/0, ::/0"

    config["vpn_subnet"] = input(
        f"  {CYAN}│{RESET}  VPN subnet [{WHITE}10.66.66.0/24{RESET}]: "
    ).strip() or "10.66.66.0/24"

    print(f"  {CYAN}└─────────────────────────────────────────────────────┘{RESET}")
    return config
