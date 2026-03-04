"""Pi-hole / AdGuard DNS server deployment module."""

CYAN = "\033[38;5;51m"
WHITE = "\033[38;5;255m"
GREY = "\033[38;5;244m"
YELLOW = "\033[38;5;214m"
RESET = "\033[0m"


def gather_config(config):
    """Gather DNS server configuration."""
    print(f"\n{CYAN}  ┌─ DNS Server Configuration ────────────────────────┐{RESET}")

    print(f"  {CYAN}│{RESET}  Upstream DNS provider:")
    print(f"  {CYAN}│{RESET}    {WHITE}1{RESET}) Quad9 (9.9.9.9) — security-focused")
    print(f"  {CYAN}│{RESET}    {WHITE}2{RESET}) Cloudflare (1.1.1.1) — privacy-focused")
    print(f"  {CYAN}│{RESET}    {WHITE}3{RESET}) Custom")

    dns_choice = input(f"  {CYAN}│{RESET}  Choice [{WHITE}1{RESET}]: ").strip() or "1"

    if dns_choice == "1":
        config["dns_upstream"] = "9.9.9.9;149.112.112.112"
        config["dns_upstream_name"] = "Quad9"
    elif dns_choice == "2":
        config["dns_upstream"] = "1.1.1.1;1.0.0.1"
        config["dns_upstream_name"] = "Cloudflare"
    else:
        config["dns_upstream"] = input(
            f"  {CYAN}│{RESET}  Custom DNS (semicolon-separated): "
        ).strip()
        config["dns_upstream_name"] = "Custom"

    config["dns_domain"] = input(
        f"  {CYAN}│{RESET}  Admin interface domain (optional): "
    ).strip()

    print(f"  {CYAN}│{RESET}")
    print(f"  {CYAN}│{RESET}  Blocklist presets:")
    print(f"  {CYAN}│{RESET}    {WHITE}1{RESET}) Standard (ads + trackers)")
    print(f"  {CYAN}│{RESET}    {WHITE}2{RESET}) Aggressive (+ social media trackers)")
    print(f"  {CYAN}│{RESET}    {WHITE}3{RESET}) Minimal (ads only)")

    bl_choice = input(f"  {CYAN}│{RESET}  Choice [{WHITE}1{RESET}]: ").strip() or "1"
    config["dns_blocklist"] = {"1": "standard", "2": "aggressive", "3": "minimal"}.get(
        bl_choice, "standard"
    )

    print(f"  {CYAN}└─────────────────────────────────────────────────────┘{RESET}")
    return config
