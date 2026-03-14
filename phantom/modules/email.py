"""Mailcow dockerized deployment module."""

import re

CYAN = "\033[38;5;51m"
WHITE = "\033[38;5;255m"
GREY = "\033[38;5;244m"
RED = "\033[38;5;196m"
YELLOW = "\033[38;5;214m"
RESET = "\033[0m"

_IP_RE = re.compile(r'^\d+\.\d+\.\d+\.\d+$')
_FQDN_RE = re.compile(
    r'^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?'
    r'(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)+$'
)

_ENV = f"{GREY}(from .env){RESET}"


def gather_config(config):
    """Gather Mailcow configuration."""
    print(f"\n{CYAN}  ┌─ Mailcow Configuration ──────────────────────────────┐{RESET}")
    print(f"  {CYAN}│{RESET}  {GREY}Dockerized mail stack — SMTP, IMAP, webmail, admin UI{RESET}")

    # Mail hostname — the FQDN Mailcow binds to (e.g. mx.example.com, post.example.com)
    if config.get("email_hostname"):
        print(f"  {CYAN}│{RESET}  Mail hostname: {WHITE}{config['email_hostname']}{RESET} {_ENV}")
    else:
        config["email_hostname"] = input(
            f"  {CYAN}│{RESET}  Mail server hostname (e.g. mx.example.com): "
        ).strip()

    if _IP_RE.match(config.get("email_hostname", "")):
        print(f"  {CYAN}│{RESET}  {RED}ERROR: Email requires a real FQDN — bare IPs cannot receive mail.{RESET}")
        return None

    if not _FQDN_RE.match(config.get("email_hostname", "")):
        print(f"  {CYAN}│{RESET}  {RED}ERROR: '{config['email_hostname']}' is not a valid FQDN.{RESET}")
        return None

    # Base domain — the domain that gets MX/SPF/DKIM/DMARC records
    if config.get("domain"):
        print(f"  {CYAN}│{RESET}  Mail domain: {WHITE}{config['domain']}{RESET} {_ENV}")
    else:
        # Try to guess base domain from hostname (strip first label)
        hostname = config["email_hostname"]
        parts = hostname.split(".", 1)
        suggested = parts[1] if len(parts) > 1 else hostname
        domain_input = input(
            f"  {CYAN}│{RESET}  Mail domain [{WHITE}{suggested}{RESET}]: "
        ).strip()
        config["domain"] = domain_input if domain_input else suggested

    if _IP_RE.match(config.get("domain", "")):
        print(f"  {CYAN}│{RESET}  {RED}ERROR: Mail domain must be a real domain, not an IP.{RESET}")
        return None

    if config["email_hostname"] == config["domain"]:
        print(f"  {CYAN}│{RESET}  {RED}ERROR: Hostname and mail domain must differ (Mailcow requirement).{RESET}")
        print(f"  {CYAN}│{RESET}  {GREY}  Hostname = server FQDN (e.g. mx.example.com){RESET}")
        print(f"  {CYAN}│{RESET}  {GREY}  Domain   = email domain (e.g. example.com){RESET}")
        return None

    # Timezone
    if config.get("email_timezone"):
        print(f"  {CYAN}│{RESET}  Timezone: {WHITE}{config['email_timezone']}{RESET} {_ENV}")
    else:
        tz = input(
            f"  {CYAN}│{RESET}  Server timezone [{WHITE}America/New_York{RESET}]: "
        ).strip()
        config["email_timezone"] = tz if tz else "America/New_York"

    # Admin password
    if config.get("email_admin_password"):
        print(f"  {CYAN}│{RESET}  Admin password: {WHITE}***{RESET} {_ENV}")
    else:
        config["email_admin_password"] = input(
            f"  {CYAN}│{RESET}  Admin password [{WHITE}auto-generate{RESET}]: "
        ).strip()

    # First mailbox user
    if config.get("email_first_user"):
        print(f"  {CYAN}│{RESET}  First user: {WHITE}{config['email_first_user']}{RESET} {_ENV}")
    else:
        config["email_first_user"] = input(
            f"  {CYAN}│{RESET}  First mailbox user (e.g. admin@example.com): "
        ).strip()

    # First mailbox password
    if config.get("email_first_password"):
        print(f"  {CYAN}│{RESET}  First user password: {WHITE}***{RESET} {_ENV}")
    else:
        config["email_first_password"] = input(
            f"  {CYAN}│{RESET}  First user password [{WHITE}auto-generate{RESET}]: "
        ).strip()

    # Cloudflare Tunnel (optional)
    if config.get("domain") and not _IP_RE.match(config.get("domain", "")):
        if config.get("cf_tunnel_token"):
            print(f"  {CYAN}│{RESET}  CF tunnel token: {WHITE}***{RESET} {GREY}(from .env){RESET}")
        else:
            cf_token = input(
                f"  {CYAN}│{RESET}  Cloudflare API token for tunnel [{WHITE}skip{RESET}]: "
            ).strip()
            if cf_token:
                config["cf_tunnel_token"] = cf_token

    # Email Relay Configuration
    print(f"  {CYAN}│{RESET}")
    print(f"  {CYAN}│{RESET}  {YELLOW}Email Relay Configuration{RESET}")
    print(f"  {CYAN}│{RESET}  {GREY}Your ISP may block port 25 or you may be behind CGNAT.{RESET}")

    if config.get("email_relay_mode"):
        print(f"  {CYAN}│{RESET}  Relay mode: {WHITE}{config['email_relay_mode']}{RESET} {_ENV}")
    else:
        print(f"  {CYAN}│{RESET}")
        print(f"  {CYAN}│{RESET}  {WHITE}1{RESET}) No relay (direct — ISP allows port 25, public IP)")
        print(f"  {CYAN}│{RESET}  {WHITE}2{RESET}) Deploy relay VPS (auto-provision Linode/AWS nanode + WireGuard tunnel)")
        print(f"  {CYAN}│{RESET}  {WHITE}3{RESET}) External smarthost (SendGrid, Mailgun, etc. — outbound only)")
        relay_choice = input(f"  {CYAN}│{RESET}  Choice [{WHITE}1{RESET}]: ").strip()
        if relay_choice == "2":
            config["email_relay_mode"] = "vps"
        elif relay_choice == "3":
            config["email_relay_mode"] = "smarthost"
        else:
            config["email_relay_mode"] = "none"

    # VPS relay prompts
    if config.get("email_relay_mode") == "vps":
        print(f"  {CYAN}│{RESET}  {GREY}A relay VPS (nanode) will be provisioned automatically.{RESET}")
        print(f"  {CYAN}│{RESET}  {GREY}MX/A records must point to the relay VPS IP (shown after deploy).{RESET}")
        if not config.get("relay_provider"):
            relay_prov = input(
                f"  {CYAN}│{RESET}  Relay provider [{WHITE}same as main{RESET}]: "
            ).strip().lower()
            if relay_prov in ("linode", "aws"):
                config["relay_provider"] = relay_prov
        if not config.get("relay_api_token"):
            print(f"  {CYAN}│{RESET}  {GREY}Leave blank to use the same API token as the main deployment.{RESET}")
            relay_token = input(
                f"  {CYAN}│{RESET}  Separate relay API token [{WHITE}same{RESET}]: "
            ).strip()
            if relay_token:
                config["relay_api_token"] = relay_token
        if not config.get("relay_region"):
            relay_reg = input(
                f"  {CYAN}│{RESET}  Relay region [{WHITE}same as main{RESET}]: "
            ).strip()
            if relay_reg:
                config["relay_region"] = relay_reg

    # External smarthost prompts
    elif config.get("email_relay_mode") == "smarthost":
        if config.get("email_relay_host"):
            print(f"  {CYAN}│{RESET}  Relay host: {WHITE}{config['email_relay_host']}{RESET} {_ENV}")
        else:
            relay_host = input(
                f"  {CYAN}│{RESET}  SMTP relay hostname: "
            ).strip()
            if relay_host:
                config["email_relay_host"] = relay_host

        if config.get("email_relay_host"):
            if config.get("email_relay_port"):
                print(f"  {CYAN}│{RESET}  Relay port: {WHITE}{config['email_relay_port']}{RESET} {_ENV}")
            else:
                relay_port = input(
                    f"  {CYAN}│{RESET}  Relay port [{WHITE}587{RESET}]: "
                ).strip()
                config["email_relay_port"] = relay_port if relay_port else "587"

            if config.get("email_relay_user"):
                print(f"  {CYAN}│{RESET}  Relay user: {WHITE}{config['email_relay_user']}{RESET} {_ENV}")
            else:
                config["email_relay_user"] = input(
                    f"  {CYAN}│{RESET}  Relay username: "
                ).strip()

            if config.get("email_relay_password"):
                print(f"  {CYAN}│{RESET}  Relay password: {WHITE}***{RESET} {_ENV}")
            else:
                config["email_relay_password"] = input(
                    f"  {CYAN}│{RESET}  Relay password: "
                ).strip()

    # DNS reminder
    mail_host = config['email_hostname']
    base_domain = config['domain']
    print(f"  {CYAN}│{RESET}")
    print(f"  {CYAN}│{RESET}  {YELLOW}Required DNS records (create after deployment):{RESET}")
    if config.get("email_relay_mode") == "vps":
        print(f"  {CYAN}│{RESET}  {GREY}  A     → {mail_host} → relay VPS IP (shown after provisioning){RESET}")
        print(f"  {CYAN}│{RESET}  {GREY}  MX    → {mail_host} (priority 10) — points to relay VPS{RESET}")
    else:
        print(f"  {CYAN}│{RESET}  {GREY}  A     → {mail_host} → server IP{RESET}")
        print(f"  {CYAN}│{RESET}  {GREY}  MX    → {mail_host} (priority 10){RESET}")
    print(f"  {CYAN}│{RESET}  {GREY}  SPF   → v=spf1 mx -all{RESET}")
    print(f"  {CYAN}│{RESET}  {GREY}  DKIM  → retrieved after install{RESET}")
    print(f"  {CYAN}│{RESET}  {GREY}  DMARC → v=DMARC1; p=quarantine{RESET}")

    print(f"  {CYAN}└────────────────────────────────────────────────────────┘{RESET}")
    return config
