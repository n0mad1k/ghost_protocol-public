"""All-in-one single-server deployment module.

Composes multiple services onto a single server with nginx reverse proxy
and TLS via Certbot. Includes clear warnings about single-server risks.
"""

import re

CYAN = "\033[38;5;51m"
WHITE = "\033[38;5;255m"
GREY = "\033[38;5;244m"
YELLOW = "\033[38;5;214m"
RED = "\033[38;5;196m"
RESET = "\033[0m"

_IP_RE = re.compile(r'^\d+\.\d+\.\d+\.\d+$')
_LOCAL_RE = re.compile(r'\.(local|lan|home|internal|test)$')

SERVICES = [
    ("matrix", "Matrix + Element", "Encrypted messaging"),
    ("vpn", "WireGuard VPN", "Private VPN server"),
    ("dns", "AdGuard Home", "Ad-blocking DNS"),
    ("cloud", "Nextcloud", "File sync"),
    ("vault", "Vaultwarden", "Password manager"),
    ("media", "Jellyfin", "Media server"),
    ("email", "Mailcow", "Email server"),
    ("git", "Git Server", "Forgejo or GitLab"),
    ("voip", "VOIP (izPBX)", "FreePBX + Asterisk PBX"),
]


def gather_config(config):
    """Gather all-in-one deployment configuration."""
    # Risk warning
    print(f"\n{RED}  ╔═══════════════════════════════════════════════════════╗{RESET}")
    print(f"  {RED}║{RESET}  {YELLOW}WARNING: Single-Server Deployment{RESET}                     {RED}║{RESET}")
    print(f"  {RED}║{RESET}                                                       {RED}║{RESET}")
    print(f"  {RED}║{RESET}  Running multiple services on one server means:       {RED}║{RESET}")
    print(f"  {RED}║{RESET}  - A compromise of one service risks ALL services     {RED}║{RESET}")
    print(f"  {RED}║{RESET}  - Resource contention between services               {RED}║{RESET}")
    print(f"  {RED}║{RESET}  - Single point of failure for all infrastructure     {RED}║{RESET}")
    print(f"  {RED}║{RESET}  - More complex backup and recovery                   {RED}║{RESET}")
    print(f"  {RED}║{RESET}                                                       {RED}║{RESET}")
    print(f"  {RED}║{RESET}  For production use, prefer one service per server.   {RED}║{RESET}")
    print(f"  {RED}║{RESET}  This mode is intended for lab/testing or personal    {RED}║{RESET}")
    print(f"  {RED}║{RESET}  use where convenience outweighs isolation.           {RED}║{RESET}")
    print(f"  {RED}╚═══════════════════════════════════════════════════════╝{RESET}")

    confirm = input(f"\n  {YELLOW}Acknowledge risks and continue? [y/N]:{RESET} ").strip().lower()
    if confirm != "y":
        return None

    # Service selection
    print(f"\n{CYAN}  ┌─ Select Services ────────────────────────────────────┐{RESET}")
    for i, (svc_id, label, desc) in enumerate(SERVICES, 1):
        print(f"  {CYAN}│{RESET}  {WHITE}{i}{RESET}) {label:<20} {GREY}{desc}{RESET}")
    print(f"  {CYAN}└────────────────────────────────────────────────────────┘{RESET}")

    selections = input(
        f"\n  {CYAN}Services to deploy (comma-separated, e.g. 1,2,3):{RESET} "
    ).strip()

    selected_services = []
    for s in selections.split(","):
        s = s.strip()
        try:
            idx = int(s) - 1
            if 0 <= idx < len(SERVICES):
                selected_services.append(SERVICES[idx][0])
        except ValueError:
            pass

    if not selected_services:
        print(f"  {RED}No services selected.{RESET}")
        return None

    config["services"] = selected_services
    config["all_in_one"] = True

    # Base domain or IP for nginx vhosts
    config["domain"] = input(
        f"\n  {CYAN}Base domain or IP (e.g. example.com or 192.168.1.100):{RESET} "
    ).strip()
    if not config["domain"]:
        print(f"  {RED}Domain or IP is required for reverse proxy.{RESET}")
        return None

    base_domain = config["domain"]
    is_ip = bool(_IP_RE.match(base_domain))
    is_local = bool(_LOCAL_RE.search(base_domain))

    if is_ip:
        # Warn about multiple web services on a single IP
        web_services = [s for s in selected_services if s not in ("vpn", "dns")]
        if len(web_services) > 1:
            print(f"\n  {YELLOW}WARNING: Multiple web services on a single IP.{RESET}")
            print(f"  {YELLOW}Only the last nginx config on port 443 wins.{RESET}")
            print(f"  {YELLOW}Consider using different ports or a reverse proxy with path-based routing.{RESET}")

    # Skip certbot email for IPs / .local domains
    if is_ip or is_local:
        config["certbot_email"] = ""
    else:
        config["certbot_email"] = input(
            f"  {CYAN}Email for Let's Encrypt [{GREY}optional{RESET}]: "
        ).strip()

    # Gather per-service configs
    for svc in selected_services:
        try:
            mod = __import__(f"modules.{svc}", fromlist=[svc])
            if hasattr(mod, "gather_config"):
                # Set per-service domain: use same IP for all when base is IP
                if is_ip:
                    config["domain"] = base_domain
                else:
                    svc_subdomains = {
                        "matrix": f"matrix.{base_domain}",
                        "cloud": f"cloud.{base_domain}",
                        "vault": f"vault.{base_domain}",
                        "media": f"media.{base_domain}",
                        "email": base_domain,
                        "dns": f"dns.{base_domain}",
                        "git": f"git.{base_domain}",
                        "vpn": base_domain,
                        "voip": f"pbx.{base_domain}",
                    }
                    if svc in svc_subdomains:
                        config["domain"] = svc_subdomains[svc]
                    # Email needs hostname separate from domain
                    if svc == "email" and not is_ip:
                        config["email_hostname"] = f"mx.{base_domain}"
                    # VOIP needs voip_hostname set
                    if svc == "voip" and not is_ip:
                        config["voip_hostname"] = f"pbx.{base_domain}"
                config = mod.gather_config(config)
                if config is None:
                    return None
        except ImportError:
            pass  # Module not yet loaded, skip
    # Restore base domain
    config["domain"] = base_domain

    config["nginx_reverse_proxy"] = True
    config["certbot_enabled"] = bool(config.get("certbot_email"))

    return config
