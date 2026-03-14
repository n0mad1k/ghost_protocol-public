"""izPBX (FreePBX + Asterisk) VOIP deployment module."""

import secrets

CYAN = "\033[38;5;51m"
WHITE = "\033[38;5;255m"
GREY = "\033[38;5;244m"
YELLOW = "\033[38;5;214m"
RESET = "\033[0m"

_ENV = f"{GREY}(from .env){RESET}"

_PROVIDERS = {
    "1": ("voipms", "VoIP.ms (KYC required — Persona identity verification)"),
    "2": ("gsm_gateway", "GSM Gateway (no KYC — prepaid SIMs, self-hosted)"),
    "3": ("generic", "Generic SIP trunk"),
    "4": ("telnyx", "Telnyx (KYC required)"),
    "5": ("twilio", "Twilio (KYC required)"),
    "6": ("sip_only", "SIP-to-SIP only (no PSTN — internal/team comms)"),
    "7": ("skip", "Skip (configure later)"),
}


def gather_config(config):
    """Gather izPBX VOIP configuration."""
    print(f"\n{CYAN}  \u250c\u2500 VOIP Configuration (izPBX) \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2510{RESET}")
    print(f"  {CYAN}\u2502{RESET}  {GREY}FreePBX + Asterisk PBX via Docker{RESET}")

    # Host networking warning for all-in-one mode
    if config.get("all_in_one"):
        print(f"  {CYAN}\u2502{RESET}")
        print(f"  {CYAN}\u2502{RESET}  {YELLOW}WARNING: izPBX uses host networking for SIP/RTP.{RESET}")
        print(f"  {CYAN}\u2502{RESET}  {YELLOW}This may conflict with other services on ports{RESET}")
        print(f"  {CYAN}\u2502{RESET}  {YELLOW}80/443. The built-in web server will bind directly.{RESET}")

    # 1. PBX hostname
    if config.get("voip_hostname"):
        print(f"  {CYAN}\u2502{RESET}  Hostname: {WHITE}{config['voip_hostname']}{RESET} {_ENV}")
    else:
        config["voip_hostname"] = input(
            f"  {CYAN}\u2502{RESET}  PBX FQDN (e.g. pbx.example.com): "
        ).strip()

    # 2. Admin password
    if config.get("voip_admin_password"):
        print(f"  {CYAN}\u2502{RESET}  Admin password: {WHITE}***{RESET} {_ENV}")
    else:
        config["voip_admin_password"] = input(
            f"  {CYAN}\u2502{RESET}  FreePBX admin password [{WHITE}auto-generate{RESET}]: "
        ).strip() or secrets.token_urlsafe(16)

    # 3. SIP trunk provider
    if config.get("voip_provider"):
        print(f"  {CYAN}\u2502{RESET}  SIP provider: {WHITE}{config['voip_provider']}{RESET} {_ENV}")
    else:
        print(f"  {CYAN}\u2502{RESET}")
        print(f"  {CYAN}\u2502{RESET}  {YELLOW}SIP Trunk Provider{RESET}")
        print(f"  {CYAN}\u2502{RESET}  {GREY}All major SIP trunk providers now require identity verification (KYC).{RESET}")
        print(f"  {CYAN}\u2502{RESET}  {GREY}For maximum privacy, use a GSM gateway with prepaid SIMs:{RESET}")
        print(f"  {CYAN}\u2502{RESET}  {GREY}  \u2022 GoIP gateway (1/4/8/16 port) + prepaid SIM cards{RESET}")
        print(f"  {CYAN}\u2502{RESET}  {GREY}  \u2022 No account, no KYC \u2014 calls route through cellular network{RESET}")
        print(f"  {CYAN}\u2502{RESET}  {GREY}  \u2022 Buy SIMs with cash, swap when needed{RESET}")
        print(f"  {CYAN}\u2502{RESET}  {GREY}  \u2022 Connects to FreePBX as a standard SIP trunk{RESET}")
        for num in sorted(_PROVIDERS):
            _, label = _PROVIDERS[num]
            print(f"  {CYAN}\u2502{RESET}    {WHITE}{num}{RESET}) {label}")
        provider_choice = input(f"  {CYAN}\u2502{RESET}  Select [{WHITE}7{RESET}]: ").strip() or "7"
        if provider_choice in _PROVIDERS:
            config["voip_provider"] = _PROVIDERS[provider_choice][0]
        else:
            config["voip_provider"] = "skip"

    # 4. Provider-specific SIP credentials
    if config.get("voip_provider") == "gsm_gateway":
        print(f"  {CYAN}\u2502{RESET}")
        print(f"  {CYAN}\u2502{RESET}  {YELLOW}GSM Gateway Setup{RESET}")
        print(f"  {CYAN}\u2502{RESET}  {GREY}Configure after deployment \u2014 connect GoIP device to FreePBX:{RESET}")
        print(f"  {CYAN}\u2502{RESET}  {GREY}  1. Connect GoIP to same network as PBX (or VPN){RESET}")
        print(f"  {CYAN}\u2502{RESET}  {GREY}  2. Access GoIP web UI (default: 192.168.x.x:80){RESET}")
        print(f"  {CYAN}\u2502{RESET}  {GREY}  3. Configure SIP trunk: point to PBX IP, set auth credentials{RESET}")
        print(f"  {CYAN}\u2502{RESET}  {GREY}  4. In FreePBX: create PJSIP trunk matching GoIP credentials{RESET}")
        print(f"  {CYAN}\u2502{RESET}  {GREY}  5. Insert prepaid SIM, create inbound/outbound routes{RESET}")
        print(f"  {CYAN}\u2502{RESET}  {GREY}  Recommended hardware: GoIP-1 (~$50), GoIP-4 (~$120){RESET}")
        config["voip_provider"] = "skip"  # No SIP creds to gather — manual post-deploy
    elif config.get("voip_provider") == "sip_only":
        print(f"  {CYAN}\u2502{RESET}")
        print(f"  {CYAN}\u2502{RESET}  {YELLOW}SIP-to-SIP Only (No PSTN){RESET}")
        print(f"  {CYAN}\u2502{RESET}  {GREY}No trunk provider needed \u2014 create extensions in FreePBX{RESET}")
        print(f"  {CYAN}\u2502{RESET}  {GREY}and register SIP clients (Ooma, Zoiper, Linphone, etc.){RESET}")
        print(f"  {CYAN}\u2502{RESET}  {GREY}Users can call each other via extension numbers or SIP URIs.{RESET}")
        config["voip_provider"] = "skip"  # No SIP creds to gather

    provider = config["voip_provider"]
    if provider == "telnyx":
        _gather_sip_creds(config, "sip.telnyx.com", "5060", "udp",
                          user_label="Telnyx SIP username",
                          pass_label="Telnyx SIP password")
    elif provider == "voipms":
        print(f"  {CYAN}\u2502{RESET}  {GREY}Pick nearest server from voip.ms/en/rates/united-states \u2014 e.g. atlanta1, chicago4, seattle1{RESET}")
        _gather_sip_creds(config, "chicago4.voip.ms", "5060", "udp",
                          user_label="VoIP.ms account number",
                          pass_label="VoIP.ms SIP password",
                          host_label="VoIP.ms server",
                          host_editable=True)
    elif provider == "twilio":
        _gather_sip_creds(config, "", "5061", "tls",
                          user_label="Twilio SIP username",
                          pass_label="Twilio SIP password",
                          host_label="Twilio SIP domain (e.g. yourapp.sip.twilio.com)",
                          host_editable=True)
    elif provider == "generic":
        _gather_sip_creds(config, "", "5060", "udp",
                          user_label="SIP username",
                          pass_label="SIP password",
                          host_label="SIP server host",
                          host_editable=True,
                          port_editable=True,
                          transport_editable=True)

    # 5. Timezone
    if config.get("voip_timezone"):
        print(f"  {CYAN}\u2502{RESET}  Timezone: {WHITE}{config['voip_timezone']}{RESET} {_ENV}")
    else:
        config["voip_timezone"] = input(
            f"  {CYAN}\u2502{RESET}  Timezone [{WHITE}America/New_York{RESET}]: "
        ).strip() or "America/New_York"

    # 6. Cloudflare Tunnel (optional -- web UI only, SIP needs direct ports)
    hostname = config.get("voip_hostname", "")
    if hostname and not hostname.replace(".", "").isdigit():
        if config.get("cf_tunnel_token"):
            print(f"  {CYAN}\u2502{RESET}  CF tunnel token: {WHITE}***{RESET} {_ENV}")
        else:
            print(f"  {CYAN}\u2502{RESET}  {GREY}Note: CF tunnel covers web UI only. SIP/RTP need direct ports.{RESET}")
            cf_token = input(
                f"  {CYAN}\u2502{RESET}  Cloudflare tunnel token [{WHITE}skip{RESET}]: "
            ).strip()
            if cf_token:
                config["cf_tunnel_token"] = cf_token

    # DNS / port reminder
    print(f"  {CYAN}\u2502{RESET}")
    print(f"  {CYAN}\u2502{RESET}  {GREY}Required DNS / firewall:{RESET}")
    print(f"  {CYAN}\u2502{RESET}  {GREY}  A record:  {hostname} \u2192 server IP{RESET}")
    print(f"  {CYAN}\u2502{RESET}  {GREY}  Ports:     5060/udp (SIP), 5061/tcp (TLS){RESET}")
    print(f"  {CYAN}\u2502{RESET}  {GREY}             10000-20000/udp (RTP media){RESET}")
    print(f"  {CYAN}\u2502{RESET}  {GREY}             80/tcp, 443/tcp (web UI){RESET}")

    print(f"  {CYAN}\u2502{RESET}")
    print(f"  {CYAN}\u2502{RESET}  {YELLOW}Privacy notes:{RESET}")
    print(f"  {CYAN}\u2502{RESET}  {GREY}  \u2022 Set rDNS on VPS IP to the PBX hostname{RESET}")
    print(f"  {CYAN}\u2502{RESET}  {GREY}  \u2022 GSM gateway: most private option (no provider KYC){RESET}")
    print(f"  {CYAN}\u2502{RESET}  {GREY}  \u2022 All SIP trunk providers now require identity verification{RESET}")
    print(f"  {CYAN}\u2502{RESET}  {GREY}  \u2022 If using VoIP.ms: fund via Settings \u2192 Payments{RESET}")

    print(f"  {CYAN}\u2514\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2518{RESET}")
    return config


def _gather_sip_creds(config, default_host, default_port, default_transport,
                      user_label="SIP username", pass_label="SIP password",
                      host_label=None, host_editable=False,
                      port_editable=False, transport_editable=False):
    """Gather SIP trunk credentials with provider-specific defaults."""

    # Host
    if host_editable:
        if config.get("voip_sip_host"):
            print(f"  {CYAN}\u2502{RESET}  SIP host: {WHITE}{config['voip_sip_host']}{RESET} {_ENV}")
        else:
            prompt = f"  {CYAN}\u2502{RESET}  {host_label}"
            if default_host:
                prompt += f" [{WHITE}{default_host}{RESET}]"
            prompt += ": "
            config["voip_sip_host"] = input(prompt).strip() or default_host
    else:
        config["voip_sip_host"] = config.get("voip_sip_host", default_host)

    # Port
    if port_editable:
        if config.get("voip_sip_port"):
            print(f"  {CYAN}\u2502{RESET}  SIP port: {WHITE}{config['voip_sip_port']}{RESET} {_ENV}")
        else:
            config["voip_sip_port"] = input(
                f"  {CYAN}\u2502{RESET}  SIP port [{WHITE}{default_port}{RESET}]: "
            ).strip() or default_port
    else:
        config["voip_sip_port"] = config.get("voip_sip_port", default_port)

    # Transport
    if transport_editable:
        if config.get("voip_sip_transport"):
            print(f"  {CYAN}\u2502{RESET}  Transport: {WHITE}{config['voip_sip_transport']}{RESET} {_ENV}")
        else:
            config["voip_sip_transport"] = input(
                f"  {CYAN}\u2502{RESET}  Transport (udp/tcp/tls) [{WHITE}{default_transport}{RESET}]: "
            ).strip() or default_transport
    else:
        config["voip_sip_transport"] = config.get("voip_sip_transport", default_transport)

    # Username
    if config.get("voip_sip_username"):
        print(f"  {CYAN}\u2502{RESET}  {user_label}: {WHITE}{config['voip_sip_username']}{RESET} {_ENV}")
    else:
        config["voip_sip_username"] = input(
            f"  {CYAN}\u2502{RESET}  {user_label}: "
        ).strip()

    # Password
    if config.get("voip_sip_password"):
        print(f"  {CYAN}\u2502{RESET}  {pass_label}: {WHITE}***{RESET} {_ENV}")
    else:
        config["voip_sip_password"] = input(
            f"  {CYAN}\u2502{RESET}  {pass_label}: "
        ).strip()
