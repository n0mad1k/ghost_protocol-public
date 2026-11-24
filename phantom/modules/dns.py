"""AdGuard Home DNS server deployment module."""

import getpass
import secrets

CYAN = "\033[38;5;51m"
WHITE = "\033[38;5;255m"
GREY = "\033[38;5;244m"
YELLOW = "\033[38;5;214m"
RESET = "\033[0m"

_ENV = f"{GREY}(from .env){RESET}"


def gather_config(config):
    """Gather DNS server configuration."""
    print(f"\n{CYAN}  ┌─ DNS Server Configuration ────────────────────────┐{RESET}")

    if config.get("dns_upstream"):
        print(f"  {CYAN}│{RESET}  Upstream DNS: {WHITE}{config['dns_upstream']}{RESET} {_ENV}")
        config.setdefault("dns_upstream_name", "Custom")
    else:
        print(f"  {CYAN}│{RESET}  Upstream DNS provider:")
        print(f"  {CYAN}│{RESET}    {WHITE}1{RESET}) Quad9 (9.9.9.9) — security-focused")
        print(f"  {CYAN}│{RESET}    {WHITE}2{RESET}) Cloudflare (1.1.1.1) — privacy-focused")
        print(f"  {CYAN}│{RESET}    {WHITE}3{RESET}) Custom")

        dns_choice = input(f"  {CYAN}│{RESET}  Choice [{WHITE}1{RESET}]: ").strip() or "1"

        if dns_choice == "1":
            config["dns_upstream"] = "9.9.9.9;149.112.112.112"
            config["dns_upstream_name"] = "Quad9"
        elif dns_choice == "2":
            config["dns_upstream"] = "1.1.1.1;1.0.0.1"
            config["dns_upstream_name"] = "Cloudflare"
        else:
            config["dns_upstream"] = input(
                f"  {CYAN}│{RESET}  Custom DNS (semicolon-separated): "
            ).strip()
            config["dns_upstream_name"] = "Custom"

    if config.get("dns_domain"):
        print(f"  {CYAN}│{RESET}  Admin domain: {WHITE}{config['dns_domain']}{RESET} {_ENV}")
    else:
        config["dns_domain"] = input(
            f"  {CYAN}│{RESET}  Admin interface domain (optional): "
        ).strip()

    # Admin credentials
    if config.get("dns_admin_user"):
        print(f"  {CYAN}│{RESET}  Admin user: {WHITE}{config['dns_admin_user']}{RESET} {_ENV}")
    else:
        config["dns_admin_user"] = input(
            f"  {CYAN}│{RESET}  Admin username [{WHITE}admin{RESET}]: "
        ).strip() or "admin"

    if config.get("dns_admin_password"):
        print(f"  {CYAN}│{RESET}  Admin password: {WHITE}***{RESET} {_ENV}")
    else:
        config["dns_admin_password"] = getpass.getpass(
            f"  {CYAN}│{RESET}  Admin password (blank=generate): "
        ) or secrets.token_urlsafe(16)

    print(f"  {CYAN}│{RESET}")
    if config.get("dns_blocklist"):
        print(f"  {CYAN}│{RESET}  Blocklist: {WHITE}{config['dns_blocklist']}{RESET} {_ENV}")
    else:
        print(f"  {CYAN}│{RESET}  Blocklist presets:")
        print(f"  {CYAN}│{RESET}    {WHITE}1{RESET}) Standard (ads + trackers)")
        print(f"  {CYAN}│{RESET}    {WHITE}2{RESET}) Aggressive (+ social media trackers)")
        print(f"  {CYAN}│{RESET}    {WHITE}3{RESET}) Minimal (ads only)")

        bl_choice = input(f"  {CYAN}│{RESET}  Choice [{WHITE}1{RESET}]: ").strip() or "1"
        config["dns_blocklist"] = {"1": "standard", "2": "aggressive", "3": "minimal"}.get(
            bl_choice, "standard"
        )

    # Cloudflare Tunnel (optional)
    if config.get("dns_domain") and not config["dns_domain"].replace(".", "").isdigit():
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
