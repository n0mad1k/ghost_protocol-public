"""Matrix + Element homeserver deployment module."""

import getpass
import re
import secrets

CYAN = "\033[38;5;51m"
WHITE = "\033[38;5;255m"
GREY = "\033[38;5;244m"
YELLOW = "\033[38;5;214m"
RESET = "\033[0m"

_IP_RE = re.compile(r'^\d+\.\d+\.\d+\.\d+$')


def gather_config(config):
    """Gather Matrix/Synapse + Element configuration."""
    print(f"\n{CYAN}  ┌─ Matrix Homeserver Configuration ─────────────────┐{RESET}")

    config["domain"] = config.get("domain") or input(
        f"  {CYAN}│{RESET}  Domain or IP (e.g. matrix.example.com or 192.168.1.100): "
    ).strip()
    if not config["domain"]:
        print(f"  {CYAN}│{RESET}  Domain is required.")
        return None

    is_ip = bool(_IP_RE.match(config["domain"]))

    if is_ip:
        print(f"  {CYAN}│{RESET}  {YELLOW}WARNING: Deploying with an IP as server_name.{RESET}")
        print(f"  {CYAN}│{RESET}  {YELLOW}Synapse server_name is immutable after first federation.{RESET}")
        print(f"  {CYAN}│{RESET}  {YELLOW}Migrating to a domain later requires a fresh database.{RESET}")

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

    # Skip matrix. prefix stripping for IPs
    if is_ip:
        config["matrix_server_name"] = config["domain"]
    else:
        config["matrix_server_name"] = config["domain"].replace("matrix.", "", 1) \
            if config["domain"].startswith("matrix.") else config["domain"]

    config["matrix_signing_key"] = secrets.token_hex(32)
    config["matrix_form_secret"] = secrets.token_hex(32)
    config["matrix_macaroon_secret"] = secrets.token_hex(32)

    print(f"  {CYAN}└─────────────────────────────────────────────────────┘{RESET}")
    return config
