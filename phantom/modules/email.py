"""Mail-in-a-Box deployment module (stub — playbook TODO)."""

CYAN = "\033[38;5;51m"
WHITE = "\033[38;5;255m"
GREY = "\033[38;5;244m"
RESET = "\033[0m"


def gather_config(config):
    """Gather Mail-in-a-Box configuration."""
    print(f"\n{CYAN}  ┌─ Mail-in-a-Box Configuration ─────────────────────┐{RESET}")
    print(f"  {CYAN}│{RESET}  {GREY}Note: Playbook coming soon{RESET}")

    config["domain"] = config.get("domain") or input(
        f"  {CYAN}│{RESET}  Mail domain (e.g. mail.example.com): "
    ).strip()

    config["email_first_user"] = input(
        f"  {CYAN}│{RESET}  First email user (e.g. admin@example.com): "
    ).strip()

    print(f"  {CYAN}└─────────────────────────────────────────────────────┘{RESET}")
    return config
