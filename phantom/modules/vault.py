"""Vaultwarden (Bitwarden) deployment module (stub — playbook TODO)."""

import secrets

CYAN = "\033[38;5;51m"
WHITE = "\033[38;5;255m"
GREY = "\033[38;5;244m"
RESET = "\033[0m"


def gather_config(config):
    """Gather Vaultwarden configuration."""
    print(f"\n{CYAN}  ┌─ Vaultwarden Configuration ───────────────────────┐{RESET}")
    print(f"  {CYAN}│{RESET}  {GREY}Note: Playbook coming soon{RESET}")

    config["domain"] = config.get("domain") or input(
        f"  {CYAN}│{RESET}  Domain (e.g. vault.example.com): "
    ).strip()

    config["vault_admin_token"] = input(
        f"  {CYAN}│{RESET}  Admin token (blank=generate): "
    ).strip() or secrets.token_urlsafe(32)

    config["vault_signups_allowed"] = input(
        f"  {CYAN}│{RESET}  Allow signups? [{WHITE}no{RESET}]: "
    ).strip().lower() in ("yes", "y", "true")

    print(f"  {CYAN}└─────────────────────────────────────────────────────┘{RESET}")
    return config
