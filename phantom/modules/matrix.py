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

_ENV = f"{GREY}(from .env){RESET}"


def gather_config(config):
    """Gather Matrix/Synapse + Element configuration."""
    print(f"\n{CYAN}  ┌─ Matrix Homeserver Configuration ─────────────────┐{RESET}")

    if config.get("domain"):
        print(f"  {CYAN}│{RESET}  Domain: {WHITE}{config['domain']}{RESET} {_ENV}")
    else:
        config["domain"] = input(
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

    if config.get("matrix_admin_user"):
        print(f"  {CYAN}│{RESET}  Admin user: {WHITE}{config['matrix_admin_user']}{RESET} {_ENV}")
    else:
        config["matrix_admin_user"] = input(
            f"  {CYAN}│{RESET}  Admin username [{WHITE}admin{RESET}]: "
        ).strip() or "admin"

    if config.get("matrix_admin_password"):
        print(f"  {CYAN}│{RESET}  Admin password: {WHITE}***{RESET} {_ENV}")
    else:
        config["matrix_admin_password"] = getpass.getpass(
            f"  {CYAN}│{RESET}  Admin password (blank=generate): "
        ) or secrets.token_urlsafe(20)

    if "matrix_registration" in config:
        print(f"  {CYAN}│{RESET}  Open registration: {WHITE}{config['matrix_registration']}{RESET} {_ENV}")
    else:
        config["matrix_registration"] = input(
            f"  {CYAN}│{RESET}  Open registration? [{WHITE}no{RESET}]: "
        ).strip().lower()
        config["matrix_registration"] = config["matrix_registration"] in ("yes", "y", "true")

    if "matrix_element_web" in config:
        print(f"  {CYAN}│{RESET}  Element Web: {WHITE}{config['matrix_element_web']}{RESET} {_ENV}")
    else:
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

    # Cloudflare Tunnel (optional)
    if config.get("domain") and not is_ip:
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
