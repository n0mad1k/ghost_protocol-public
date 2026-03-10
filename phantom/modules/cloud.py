"""Nextcloud deployment module — PHP-FPM + MariaDB + Redis + nginx."""

import getpass
import secrets

CYAN = "\033[38;5;51m"
WHITE = "\033[38;5;255m"
GREY = "\033[38;5;244m"
RESET = "\033[0m"


def gather_config(config):
    """Gather Nextcloud configuration."""
    print(f"\n{CYAN}  ┌─ Nextcloud Configuration ─────────────────────────┐{RESET}")
    print(f"  {CYAN}│{RESET}  {GREY}PHP-FPM + MariaDB + Redis + nginx{RESET}")

    config["domain"] = config.get("domain") or input(
        f"  {CYAN}│{RESET}  Domain or IP (e.g. cloud.example.com or 192.168.1.100): "
    ).strip()

    config["cloud_admin_user"] = input(
        f"  {CYAN}│{RESET}  Admin username [{WHITE}admin{RESET}]: "
    ).strip() or "admin"

    config["cloud_admin_password"] = getpass.getpass(
        f"  {CYAN}│{RESET}  Admin password (blank=generate): "
    ) or secrets.token_urlsafe(20)

    config["cloud_storage_gb"] = input(
        f"  {CYAN}│{RESET}  Storage quota per user (GB) [{WHITE}10{RESET}]: "
    ).strip() or "10"

    print(f"  {CYAN}└─────────────────────────────────────────────────────┘{RESET}")
    return config
