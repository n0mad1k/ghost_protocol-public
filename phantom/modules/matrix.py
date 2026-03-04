"""Matrix + Element homeserver deployment module."""

import getpass
import secrets

CYAN = "\033[38;5;51m"
WHITE = "\033[38;5;255m"
GREY = "\033[38;5;244m"
RESET = "\033[0m"


def gather_config(config):
    """Gather Matrix/Synapse + Element configuration."""
    print(f"\n{CYAN}  ┌─ Matrix Homeserver Configuration ─────────────────┐{RESET}")

    config["domain"] = config.get("domain") or input(
        f"  {CYAN}│{RESET}  Domain (e.g. matrix.example.com): "
    ).strip()
    if not config["domain"]:
        print(f"  {CYAN}│{RESET}  Domain is required.")
        return None

    config["matrix_admin_user"] = input(
        f"  {CYAN}│{RESET}  Admin username [{WHITE}admin{RESET}]: "
    ).strip() or "admin"

    config["matrix_admin_password"] = getpass.getpass(
        f"  {CYAN}│{RESET}  Admin password (blank=generate): "
    ) or secrets.token_urlsafe(20)

    config["matrix_registration"] = input(
        f"  {CYAN}│{RESET}  Open registration? [{WHITE}no{RESET}]: "
    ).strip().lower()
    config["matrix_registration"] = config["matrix_registration"] in ("yes", "y", "true")

    config["matrix_element_web"] = input(
        f"  {CYAN}│{RESET}  Deploy Element Web? [{WHITE}yes{RESET}]: "
    ).strip().lower()
    config["matrix_element_web"] = config["matrix_element_web"] not in ("no", "n", "false")

    config["matrix_server_name"] = config["domain"].replace("matrix.", "", 1) \
        if config["domain"].startswith("matrix.") else config["domain"]

    config["matrix_signing_key"] = secrets.token_hex(32)

    print(f"  {CYAN}└─────────────────────────────────────────────────────┘{RESET}")
    return config
