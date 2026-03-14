"""Vaultwarden (Bitwarden-compatible) deployment module — binary + systemd + nginx."""

import secrets

CYAN = "\033[38;5;51m"
WHITE = "\033[38;5;255m"
GREY = "\033[38;5;244m"
RESET = "\033[0m"

_ENV = f"{GREY}(from .env){RESET}"


def gather_config(config):
    """Gather Vaultwarden configuration."""
    print(f"\n{CYAN}  ┌─ Vaultwarden Configuration ───────────────────────┐{RESET}")
    print(f"  {CYAN}│{RESET}  {GREY}Pre-built binary + systemd + nginx{RESET}")

    if config.get("domain"):
        print(f"  {CYAN}│{RESET}  Domain: {WHITE}{config['domain']}{RESET} {_ENV}")
    else:
        config["domain"] = input(
            f"  {CYAN}│{RESET}  Domain or IP (e.g. vault.example.com or 192.168.1.100): "
        ).strip()

    if config.get("vault_admin_token"):
        print(f"  {CYAN}│{RESET}  Admin token: {WHITE}***{RESET} {_ENV}")
    else:
        config["vault_admin_token"] = input(
            f"  {CYAN}│{RESET}  Admin token (blank=generate): "
        ).strip() or secrets.token_urlsafe(32)

    if "vault_signups_allowed" in config:
        print(f"  {CYAN}│{RESET}  Allow signups: {WHITE}{config['vault_signups_allowed']}{RESET} {_ENV}")
    else:
        config["vault_signups_allowed"] = input(
            f"  {CYAN}│{RESET}  Allow signups? [{WHITE}no{RESET}]: "
        ).strip().lower() in ("yes", "y", "true")

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
