"""Jellyfin media server deployment module — official apt repo + nginx."""

CYAN = "\033[38;5;51m"
WHITE = "\033[38;5;255m"
GREY = "\033[38;5;244m"
RESET = "\033[0m"

_ENV = f"{GREY}(from .env){RESET}"


def gather_config(config):
    """Gather Jellyfin configuration."""
    print(f"\n{CYAN}  ┌─ Jellyfin Configuration ──────────────────────────┐{RESET}")
    print(f"  {CYAN}│{RESET}  {GREY}Official apt repo + nginx reverse proxy{RESET}")

    if config.get("domain"):
        print(f"  {CYAN}│{RESET}  Domain: {WHITE}{config['domain']}{RESET} {_ENV}")
    else:
        config["domain"] = input(
            f"  {CYAN}│{RESET}  Domain or IP (e.g. media.example.com or 192.168.1.100): "
        ).strip()

    if config.get("media_library_path"):
        print(f"  {CYAN}│{RESET}  Media path: {WHITE}{config['media_library_path']}{RESET} {_ENV}")
    else:
        config["media_library_path"] = input(
            f"  {CYAN}│{RESET}  Media library path [{WHITE}/srv/media{RESET}]: "
        ).strip() or "/srv/media"

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
