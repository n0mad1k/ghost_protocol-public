"""Git server deployment module — Forgejo (lightweight) or GitLab CE (enterprise)."""

import getpass
import re
import secrets

CYAN = "\033[38;5;51m"
WHITE = "\033[38;5;255m"
GREY = "\033[38;5;244m"
YELLOW = "\033[38;5;214m"
RED = "\033[38;5;196m"
RESET = "\033[0m"

_ENV = f"{GREY}(from .env){RESET}"

_VALID_DOMAIN_RE = re.compile(r'^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$')


def gather_config(config):
    """Gather Git server configuration."""
    print(f"\n{CYAN}  ┌─ Git Server Configuration ──────────────────────────┐{RESET}")

    # ── Platform selection ────────────────────────────────────────────
    if config.get("git_platform"):
        print(f"  {CYAN}│{RESET}  Platform: {WHITE}{config['git_platform']}{RESET} {_ENV}")
    else:
        print(f"  {CYAN}│{RESET}  {WHITE}1{RESET}) Forgejo   {GREY}— lightweight, ~200MB RAM, Docker{RESET}")
        print(f"  {CYAN}│{RESET}  {WHITE}2{RESET}) GitLab CE {GREY}— enterprise, 4-8 GiB RAM, native{RESET}")
        choice = input(f"  {CYAN}│{RESET}  Choice [{WHITE}1{RESET}]: ").strip() or "1"
        config["git_platform"] = "gitlab" if choice == "2" else "forgejo"

    if config["git_platform"] == "gitlab":
        print(f"  {CYAN}│{RESET}  {YELLOW}GitLab CE requires 4-8 GiB RAM minimum{RESET}")
        print(f"  {CYAN}│{RESET}  {YELLOW}CI/CD disabled by default for security{RESET}")

    # ── Domain ────────────────────────────────────────────────────────
    if config.get("domain"):
        print(f"  {CYAN}│{RESET}  Domain: {WHITE}{config['domain']}{RESET} {_ENV}")
    else:
        config["domain"] = input(
            f"  {CYAN}│{RESET}  Domain or IP (e.g. git.example.com): "
        ).strip()
    if config["domain"] and not _VALID_DOMAIN_RE.match(config["domain"]):
        print(f"  {CYAN}│{RESET}  {YELLOW}Invalid domain: must start/end with alphanumeric, only dots and hyphens allowed.{RESET}")
        return None

    # ── Git SSH port ──────────────────────────────────────────────────
    system_ssh = config.get("ssh_port", "22")
    if config.get("git_ssh_port"):
        if config["git_ssh_port"] == str(system_ssh):
            print(f"  {CYAN}│{RESET}  {RED}ERROR: git_ssh_port from .env conflicts with system SSH on port {system_ssh}{RESET}")
            return None
        print(f"  {CYAN}│{RESET}  Git SSH port: {WHITE}{config['git_ssh_port']}{RESET} {_ENV}")
    else:
        while True:
            git_ssh = input(
                f"  {CYAN}│{RESET}  Git SSH port [{WHITE}2222{RESET}]: "
            ).strip() or "2222"
            if git_ssh == str(system_ssh):
                print(f"  {CYAN}│{RESET}  {RED}ERROR: Conflicts with system SSH on port {system_ssh}{RESET}")
                continue
            config["git_ssh_port"] = git_ssh
            break

    # ── Admin credentials ─────────────────────────────────────────────
    if config.get("git_admin_user"):
        print(f"  {CYAN}│{RESET}  Admin user: {WHITE}{config['git_admin_user']}{RESET} {_ENV}")
    else:
        config["git_admin_user"] = input(
            f"  {CYAN}│{RESET}  Admin username [{WHITE}sysadmin{RESET}]: "
        ).strip() or "sysadmin"

    if config.get("git_admin_password"):
        print(f"  {CYAN}│{RESET}  Admin password: {WHITE}***{RESET} {_ENV}")
    else:
        config["git_admin_password"] = getpass.getpass(
            f"  {CYAN}│{RESET}  Admin password (blank=generate): "
        ).strip() or secrets.token_urlsafe(16)

    if config.get("git_admin_email"):
        print(f"  {CYAN}│{RESET}  Admin email: {WHITE}{config['git_admin_email']}{RESET} {_ENV}")
    else:
        config["git_admin_email"] = input(
            f"  {CYAN}│{RESET}  Admin email [{WHITE}admin@localhost{RESET}]: "
        ).strip() or "admin@localhost"

    print(f"  {CYAN}│{RESET}")
    print(f"  {CYAN}│{RESET}  {GREY}Git SSH exposed on port {config['git_ssh_port']} (all interfaces){RESET}")
    print(f"  {CYAN}│{RESET}  {GREY}Web UI behind nginx with TLS{RESET}")

    # Cloudflare Tunnel (optional)
    if config.get("domain") and not config["domain"].replace(".", "").isdigit():
        print(f"  {CYAN}│{RESET}")
        if config.get("cf_tunnel_token"):
            print(f"  {CYAN}│{RESET}  CF tunnel token: {WHITE}***{RESET} {_ENV}")
        else:
            cf_token = input(
                f"  {CYAN}│{RESET}  Cloudflare API token for tunnel [{WHITE}skip{RESET}]: "
            ).strip()
            if cf_token:
                config["cf_tunnel_token"] = cf_token

    print(f"  {CYAN}└────────────────────────────────────────────────────────┘{RESET}")
    return config
