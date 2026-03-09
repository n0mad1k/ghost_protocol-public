"""All-in-one single-server deployment module.

Composes multiple services onto a single server with nginx reverse proxy
and TLS via Certbot. Includes clear warnings about single-server risks.
"""

CYAN = "\033[38;5;51m"
WHITE = "\033[38;5;255m"
GREY = "\033[38;5;244m"
YELLOW = "\033[38;5;214m"
RED = "\033[38;5;196m"
RESET = "\033[0m"

SERVICES = [
    ("matrix", "Matrix + Element", "Encrypted messaging"),
    ("vpn", "WireGuard VPN", "Private VPN server"),
    ("dns", "Pi-hole DNS", "Ad-blocking DNS"),
    ("cloud", "Nextcloud", "File sync"),
    ("vault", "Vaultwarden", "Password manager"),
    ("media", "Jellyfin", "Media server"),
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

    # Base domain for nginx vhosts
    config["domain"] = input(
        f"\n  {CYAN}Base domain (e.g. example.com):{RESET} "
    ).strip()
    if not config["domain"]:
        print(f"  {RED}Domain is required for reverse proxy.{RESET}")
        return None

    config["certbot_email"] = input(
        f"  {CYAN}Email for Let's Encrypt [{GREY}optional{RESET}]: "
    ).strip()

    # Gather per-service configs
    # Save base domain — each service stores config under its own prefixed keys
    base_domain = config["domain"]
    for svc in selected_services:
        try:
            mod = __import__(f"modules.{svc}", fromlist=[svc])
            if hasattr(mod, "gather_config"):
                # Set per-service subdomain default
                svc_subdomains = {
                    "matrix": f"matrix.{base_domain}",
                    "cloud": f"cloud.{base_domain}",
                    "vault": f"vault.{base_domain}",
                    "media": f"media.{base_domain}",
                    "email": f"mail.{base_domain}",
                    "dns": f"dns.{base_domain}",
                    "vpn": base_domain,
                }
                if svc in svc_subdomains:
                    config["domain"] = svc_subdomains[svc]
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
