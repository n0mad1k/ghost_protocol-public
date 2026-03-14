"""Nextcloud deployment module — PHP-FPM + MariaDB + Redis + nginx."""

import getpass
import secrets

CYAN = "\033[38;5;51m"
WHITE = "\033[38;5;255m"
GREY = "\033[38;5;244m"
RESET = "\033[0m"

_ENV = f"{GREY}(from .env){RESET}"


def gather_config(config):
    """Gather Nextcloud configuration."""
    print(f"\n{CYAN}  ┌─ Nextcloud Configuration ─────────────────────────┐{RESET}")
    print(f"  {CYAN}│{RESET}  {GREY}PHP-FPM + MariaDB + Redis + nginx{RESET}")

    if config.get("domain"):
        print(f"  {CYAN}│{RESET}  Domain: {WHITE}{config['domain']}{RESET} {_ENV}")
    else:
        config["domain"] = input(
            f"  {CYAN}│{RESET}  Domain or IP (e.g. cloud.example.com or 192.168.1.100): "
        ).strip()

    if config.get("cloud_admin_user"):
        print(f"  {CYAN}│{RESET}  Admin user: {WHITE}{config['cloud_admin_user']}{RESET} {_ENV}")
    else:
        config["cloud_admin_user"] = input(
            f"  {CYAN}│{RESET}  Admin username [{WHITE}admin{RESET}]: "
        ).strip() or "admin"

    if config.get("cloud_admin_password"):
        print(f"  {CYAN}│{RESET}  Admin password: {WHITE}***{RESET} {_ENV}")
    else:
        config["cloud_admin_password"] = getpass.getpass(
            f"  {CYAN}│{RESET}  Admin password (blank=generate): "
        ) or secrets.token_urlsafe(20)

    if config.get("cloud_storage_gb"):
        print(f"  {CYAN}│{RESET}  Storage quota: {WHITE}{config['cloud_storage_gb']} GB{RESET} {_ENV}")
    else:
        config["cloud_storage_gb"] = input(
            f"  {CYAN}│{RESET}  Storage quota per user (GB) [{WHITE}10{RESET}]: "
        ).strip() or "10"

    # Cloudflare Tunnel (optional)
    if config.get("domain") and not config["domain"].replace(".", "").isdigit():
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
