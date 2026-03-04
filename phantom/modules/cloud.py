"""Nextcloud deployment module (stub — playbook TODO)."""

CYAN = "\033[38;5;51m"
WHITE = "\033[38;5;255m"
GREY = "\033[38;5;244m"
RESET = "\033[0m"


def gather_config(config):
    """Gather Nextcloud configuration."""
    print(f"\n{CYAN}  ┌─ Nextcloud Configuration ─────────────────────────┐{RESET}")
    print(f"  {CYAN}│{RESET}  {GREY}Note: Playbook coming soon{RESET}")

    config["domain"] = config.get("domain") or input(
        f"  {CYAN}│{RESET}  Domain (e.g. cloud.example.com): "
    ).strip()

    config["cloud_admin_user"] = input(
        f"  {CYAN}│{RESET}  Admin username [{WHITE}admin{RESET}]: "
    ).strip() or "admin"

    config["cloud_storage_gb"] = input(
        f"  {CYAN}│{RESET}  Storage quota per user (GB) [{WHITE}10{RESET}]: "
    ).strip() or "10"

    print(f"  {CYAN}└─────────────────────────────────────────────────────┘{RESET}")
    return config
