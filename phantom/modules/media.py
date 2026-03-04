"""Jellyfin media server deployment module (stub — playbook TODO)."""

CYAN = "\033[38;5;51m"
WHITE = "\033[38;5;255m"
GREY = "\033[38;5;244m"
RESET = "\033[0m"


def gather_config(config):
    """Gather Jellyfin configuration."""
    print(f"\n{CYAN}  ┌─ Jellyfin Configuration ──────────────────────────┐{RESET}")
    print(f"  {CYAN}│{RESET}  {GREY}Note: Playbook coming soon{RESET}")

    config["domain"] = config.get("domain") or input(
        f"  {CYAN}│{RESET}  Domain (e.g. media.example.com): "
    ).strip()

    config["media_library_path"] = input(
        f"  {CYAN}│{RESET}  Media library path [{WHITE}/srv/media{RESET}]: "
    ).strip() or "/srv/media"

    print(f"  {CYAN}└─────────────────────────────────────────────────────┘{RESET}")
    return config
