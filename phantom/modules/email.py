"""Mail-in-a-Box deployment module — native installer script."""

import re

CYAN = "\033[38;5;51m"
WHITE = "\033[38;5;255m"
GREY = "\033[38;5;244m"
RED = "\033[38;5;196m"
RESET = "\033[0m"

_IP_RE = re.compile(r'^\d+\.\d+\.\d+\.\d+$')


def gather_config(config):
    """Gather Mail-in-a-Box configuration."""
    print(f"\n{CYAN}  ┌─ Mail-in-a-Box Configuration ─────────────────────┐{RESET}")
    print(f"  {CYAN}│{RESET}  {GREY}Complete mail stack — manages its own nginx/TLS/DNS{RESET}")

    config["domain"] = config.get("domain") or input(
        f"  {CYAN}│{RESET}  Mail domain (e.g. mail.example.com): "
    ).strip()

    if _IP_RE.match(config.get("domain", "")):
        print(f"  {CYAN}│{RESET}  {RED}ERROR: Email requires a real domain — bare IPs cannot receive mail (no MX records).{RESET}")
        return None

    config["email_first_user"] = input(
        f"  {CYAN}│{RESET}  First email user (e.g. admin@example.com): "
    ).strip()

    print(f"  {CYAN}└─────────────────────────────────────────────────────┘{RESET}")
    return config
