#!/usr/bin/env python3
"""phantom — Privacy Server Deployer

Deploy self-hosted privacy infrastructure with a single command.
Supports Matrix, WireGuard VPN, Pi-hole DNS, Nextcloud, and more.

Providers: Linode, AWS, FlokiNET, or local/existing server.
"""

import json
import os
import random
import subprocess
import sys
import time
from pathlib import Path

# Allow modules to import from phantom
sys.path.insert(0, os.path.dirname(__file__))

BASE_DIR = Path(__file__).resolve().parent
PLAYBOOKS_DIR = BASE_DIR / "playbooks"
PROVIDERS_DIR = BASE_DIR / "providers"
LOGS_DIR = BASE_DIR / "logs"
LOGS_DIR.mkdir(exist_ok=True)

# ─── Color Helpers ──────────────────────────────────────────────────────────

RESET = "\033[0m"
BOLD = "\033[1m"
DIM = "\033[2m"
CYAN = "\033[38;5;51m"
GREEN = "\033[38;5;49m"
RED = "\033[38;5;196m"
YELLOW = "\033[38;5;214m"
MAGENTA = "\033[38;5;201m"
WHITE = "\033[38;5;255m"
GREY = "\033[38;5;244m"


def ok(msg):
    print(f"{GREEN}[+]{RESET} {msg}")

def err(msg):
    print(f"{RED}[-]{RESET} {msg}")

def warn(msg):
    print(f"{YELLOW}[*]{RESET} {msg}")

def info(msg):
    print(f"{CYAN}[~]{RESET} {msg}")

def dim(msg):
    print(f"{GREY}    {msg}{RESET}")


# ─── Banner ─────────────────────────────────────────────────────────────────

BANNER = f"""
{MAGENTA}    ██████╗ ██╗  ██╗ █████╗ ███╗   ██╗████████╗ ██████╗ ███╗   ███╗
    ██╔══██╗██║  ██║██╔══██╗████╗  ██║╚══██╔══╝██╔═══██╗████╗ ████║
    ██████╔╝███████║███████║██╔██╗ ██║   ██║   ██║   ██║██╔████╔██║
    ██╔═══╝ ██╔══██║██╔══██║██║╚██╗██║   ██║   ██║   ██║██║╚██╔╝██║
    ██║     ██║  ██║██║  ██║██║ ╚████║   ██║   ╚██████╔╝██║ ╚═╝ ██║
    ╚═╝     ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝   ╚═╝    ╚═════╝ ╚═╝     ╚═╝{RESET}
{GREY}         Privacy Server Deployer — Your infrastructure, your rules{RESET}
"""


def banner():
    print(BANNER)


# ─── Deployment ID Generation ───────────────────────────────────────────────

ADJECTIVES = [
    "silent", "hidden", "shadow", "quiet", "swift", "dark", "fading", "lost",
    "frozen", "drifting", "hollow", "veiled", "pale", "deep", "still", "wild",
    "broken", "burning", "crimson", "golden", "silver", "iron", "copper",
    "cobalt", "jade", "amber", "arctic", "lunar", "solar", "astral", "coral",
    "misty", "foggy", "dusty", "rusty", "mossy", "stormy", "cloudy", "windy",
    "gentle", "fierce", "steady", "rapid", "lazy", "bold", "brave", "calm",
    "clever", "cryptic", "cunning", "eager", "faint", "grave", "keen", "noble",
    "prime", "rare", "stark", "terse", "vivid", "wary", "zealous", "agile",
    "blunt", "coarse", "dense", "eerie", "fleet", "gaunt", "harsh", "lucid",
    "muted", "numb", "opaque", "plain", "rigid", "sleek", "taut", "urban",
    "vacant", "woven", "binary", "cipher", "delta", "echo", "foxtrot", "gamma",
    "hex", "index", "kilo", "lambda", "micro", "nano", "omega", "proxy",
    "quantum", "rogue", "sigma", "theta", "ultra", "vector", "xray", "zero",
]

NOUNS = [
    "phantom", "spectre", "wraith", "shade", "ghost", "echo", "void", "rift",
    "nexus", "pulse", "signal", "cipher", "prism", "beacon", "aegis", "bastion",
    "citadel", "forge", "haven", "vault", "harbor", "summit", "ridge", "canyon",
    "glacier", "tundra", "steppe", "mesa", "delta", "fjord", "grove", "marsh",
    "oasis", "reef", "shoal", "brook", "creek", "falls", "rapids", "spring",
    "falcon", "raven", "hawk", "condor", "osprey", "heron", "crane", "wren",
    "finch", "swift", "sparrow", "robin", "wolf", "fox", "lynx", "panther",
    "tiger", "cobra", "viper", "mantis", "hornet", "spider", "scorpion",
    "anchor", "arrow", "blade", "bolt", "chain", "crown", "flint", "glyph",
    "helm", "ingot", "jewel", "knot", "lance", "mast", "oar", "pike",
    "quill", "rune", "shard", "thorn", "urn", "wand", "atlas", "core",
    "dusk", "ember", "frost", "gale", "haze", "iris", "jade", "karma",
    "lumen", "myth", "nova", "orbit", "pixel", "quest", "relay", "sage",
    "trace", "unity", "vertex", "zenith",
]


def generate_id():
    """Generate a deployment ID with 10k+ unique combinations."""
    adj = random.choice(ADJECTIVES)
    noun = random.choice(NOUNS)
    num = random.randint(10, 99)
    return f"{adj}-{noun}-{num}"


# ─── SSH Key Generation ─────────────────────────────────────────────────────

def generate_ssh_key(deploy_id):
    """Generate an RSA 4096 SSH keypair for deployment."""
    key_dir = LOGS_DIR / deploy_id
    key_dir.mkdir(parents=True, exist_ok=True)
    key_path = key_dir / f"deploy_{deploy_id}"

    if key_path.exists():
        info(f"SSH key already exists: {key_path}")
        return str(key_path)

    info(f"Generating SSH key: {key_path}")
    subprocess.run(
        ["ssh-keygen", "-t", "rsa", "-b", "4096", "-f", str(key_path),
         "-N", "", "-C", f"deploy-{deploy_id}"],
        check=True, capture_output=True,
    )
    os.chmod(key_path, 0o600)
    ok(f"SSH key generated: {key_path}")
    return str(key_path)


# ─── Ansible Playbook Execution ─────────────────────────────────────────────

def run_playbook(playbook_path, config, extra_vars=None):
    """Execute an Ansible playbook with the given config.

    Args:
        playbook_path: Path object or string to the playbook file.
        config: Deployment config dict.
        extra_vars: Optional dict of extra Ansible variables.

    Returns:
        True if playbook succeeded, False otherwise.
    """
    playbook_path = Path(playbook_path)
    if not playbook_path.exists():
        err(f"Playbook not found: {playbook_path}")
        return False

    cmd = ["ansible-playbook", str(playbook_path)]

    # Build vars file
    vars_file = LOGS_DIR / config["deploy_id"] / "vars.yaml"
    vars_file.parent.mkdir(parents=True, exist_ok=True)

    try:
        import yaml  # noqa: optional dependency
        with open(vars_file, "w") as f:
            yaml.dump(config, f, default_flow_style=False)
    except ImportError:
        with open(vars_file, "w") as f:
            for k, v in config.items():
                f.write(f"{k}: {json.dumps(v)}\n")

    cmd.extend(["-e", f"@{vars_file}"])

    if extra_vars:
        for k, v in extra_vars.items():
            cmd.extend(["-e", f"{k}={v}"])

    # Set inventory
    target = config.get("target_host", "localhost")
    if target == "localhost":
        cmd.extend(["-i", "localhost,", "--connection", "local"])
    else:
        inv_file = LOGS_DIR / config["deploy_id"] / "inventory"
        with open(inv_file, "w") as f:
            ssh_key = config.get("ssh_key", "")
            ssh_user = config.get("ssh_user", "root")
            line = f"{target} ansible_user={ssh_user}"
            if ssh_key:
                line += f" ansible_ssh_private_key_file={ssh_key}"
            f.write(f"[servers]\n{line}\n")
        cmd.extend(["-i", str(inv_file)])

        # Elevate privileges for non-root users
        if ssh_user != "root":
            cmd.append("--become")

    info(f"Running: {' '.join(cmd)}")
    result = subprocess.run(cmd)
    return result.returncode == 0


# ─── Deployment Info Logging ────────────────────────────────────────────────

def save_deploy_info(config):
    """Save deployment metadata to logs."""
    deploy_dir = LOGS_DIR / config["deploy_id"]
    deploy_dir.mkdir(parents=True, exist_ok=True)
    info_file = deploy_dir / "deploy_info.json"

    config["timestamp"] = time.strftime("%Y-%m-%dT%H:%M:%S%z")
    with open(info_file, "w") as f:
        json.dump(config, f, indent=2, default=str)
    ok(f"Deployment info saved: {info_file}")


# ─── SSH Connect ────────────────────────────────────────────────────────────

def ssh_connect(config):
    """Offer to SSH into the deployed server."""
    target = config.get("target_host", "")
    if not target or target == "localhost":
        return

    ssh_key = config.get("ssh_key", "")
    ssh_user = config.get("ssh_user", "root")

    cmd = ["ssh"]
    if ssh_key:
        cmd.extend(["-i", ssh_key])
    cmd.append(f"{ssh_user}@{target}")

    print()
    resp = input(f"{CYAN}[?]{RESET} SSH into {target}? [y/N] ").strip().lower()
    if resp == "y":
        os.execvp("ssh", cmd)


# ─── Provider Selection ─────────────────────────────────────────────────────

def select_provider():
    """Select deployment target: cloud provider or local/existing server."""
    print(f"\n{CYAN}  Select deployment target:{RESET}")
    print(f"  {WHITE}1{RESET}) Linode")
    print(f"  {WHITE}2{RESET}) AWS (EC2)")
    print(f"  {WHITE}3{RESET}) FlokiNET (pre-provisioned)")
    print(f"  {WHITE}4{RESET}) Existing server (SSH)")
    print(f"  {WHITE}5{RESET}) Local (this machine)")
    print()

    choice = input(f"  {MAGENTA}>{RESET} ").strip()
    providers = {"1": "linode", "2": "aws", "3": "flokinet", "4": "existing", "5": "local"}
    return providers.get(choice)


def gather_credentials(provider, config):
    """Gather provider-specific credentials."""
    if provider == "linode":
        config["provider"] = "linode"
        config["api_token"] = input(f"  {CYAN}Linode API token:{RESET} ").strip()
        config["region"] = input(f"  {CYAN}Region (e.g. us-east):{RESET} ").strip() or "us-east"
        config["plan"] = input(f"  {CYAN}Plan (e.g. g6-nanode-1):{RESET} ").strip() or "g6-nanode-1"

    elif provider == "aws":
        config["provider"] = "aws"
        config["aws_access_key"] = input(f"  {CYAN}AWS Access Key ID:{RESET} ").strip()
        config["aws_secret_key"] = input(f"  {CYAN}AWS Secret Access Key:{RESET} ").strip()
        config["region"] = input(f"  {CYAN}Region (e.g. us-east-1):{RESET} ").strip() or "us-east-1"
        config["instance_type"] = input(f"  {CYAN}Instance type (e.g. t3.micro):{RESET} ").strip() or "t3.micro"

    elif provider == "flokinet":
        config["provider"] = "flokinet"
        config["target_host"] = input(f"  {CYAN}Server IP:{RESET} ").strip()
        config["ssh_user"] = input(f"  {CYAN}SSH user [root]:{RESET} ").strip() or "root"

    elif provider == "existing":
        config["provider"] = "existing"
        config["target_host"] = input(f"  {CYAN}Server IP/hostname:{RESET} ").strip()
        config["ssh_user"] = input(f"  {CYAN}SSH user [root]:{RESET} ").strip() or "root"
        existing_key = input(f"  {CYAN}SSH key path (blank to generate):{RESET} ").strip()
        if existing_key:
            config["ssh_key"] = existing_key

    elif provider == "local":
        config["provider"] = "local"
        config["target_host"] = "localhost"
        config["ssh_user"] = os.getenv("USER", "root")
        warn("Local deployment will install services directly on this machine.")
        confirm = input(f"  {YELLOW}Continue? [y/N]:{RESET} ").strip().lower()
        if confirm != "y":
            return False

    return True


# ─── Deployment Orchestration ───────────────────────────────────────────────

def deploy(server_type, config):
    """Full deployment pipeline: summarize -> confirm -> provision -> configure."""
    config["server_type"] = server_type
    config.setdefault("deploy_id", generate_id())
    deploy_id = config["deploy_id"]

    # Summary
    print(f"\n{CYAN}{'─' * 60}{RESET}")
    print(f"{MAGENTA}  Deployment Summary{RESET}")
    print(f"{CYAN}{'─' * 60}{RESET}")
    print(f"  {WHITE}ID:{RESET}       {deploy_id}")
    print(f"  {WHITE}Type:{RESET}     {server_type}")
    print(f"  {WHITE}Provider:{RESET} {config.get('provider', 'unknown')}")
    print(f"  {WHITE}Target:{RESET}   {config.get('target_host', 'TBD (will provision)')}")
    if config.get("domain"):
        print(f"  {WHITE}Domain:{RESET}   {config['domain']}")
    for k, v in config.items():
        if k not in ("deploy_id", "server_type", "provider", "target_host",
                      "domain", "api_token", "aws_access_key", "aws_secret_key",
                      "ssh_key", "ssh_user", "timestamp"):
            print(f"  {WHITE}{k}:{RESET} {v}")
    print(f"{CYAN}{'─' * 60}{RESET}")

    confirm = input(f"\n  {MAGENTA}Deploy? [y/N]:{RESET} ").strip().lower()
    if confirm != "y":
        warn("Deployment cancelled.")
        return

    # Generate SSH key if needed
    if config.get("provider") not in ("local",) and not config.get("ssh_key"):
        config["ssh_key"] = generate_ssh_key(deploy_id)

    # Provision if cloud provider
    if config.get("provider") in ("linode", "aws"):
        provider_playbook = PROVIDERS_DIR / f"{config['provider']}.yml"
        # Tell the provider playbook where to write the provisioned IP
        host_file = LOGS_DIR / deploy_id / "provisioned_host"
        config["_host_output_file"] = str(host_file)
        info(f"Provisioning {config['provider']} instance...")
        if not run_playbook(provider_playbook, config):
            err("Provisioning failed.")
            return
        # Read back the provisioned host IP
        if host_file.exists():
            config["target_host"] = host_file.read_text().strip()
            ok(f"Provisioned server: {config['target_host']}")
        else:
            err("Provisioning completed but no host IP was returned.")
            return

    # Base hardening
    info("Applying base hardening...")
    if not run_playbook(PLAYBOOKS_DIR / "common/base_hardening.yml", config):
        err("Base hardening failed — aborting deployment.")
        return

    # Service-specific playbook
    playbook_map = {
        "matrix": PLAYBOOKS_DIR / "matrix/main.yml",
        "vpn": PLAYBOOKS_DIR / "vpn/main.yml",
        "dns": PLAYBOOKS_DIR / "dns/main.yml",
        "cloud": PLAYBOOKS_DIR / "cloud/main.yml",
        "vault": PLAYBOOKS_DIR / "vault/main.yml",
        "media": PLAYBOOKS_DIR / "media/main.yml",
        "email": PLAYBOOKS_DIR / "email/main.yml",
        "all_in_one": PLAYBOOKS_DIR / "all_in_one/main.yml",
    }

    playbook = playbook_map.get(server_type)
    if playbook:
        info(f"Configuring {server_type}...")
        if run_playbook(playbook, config):
            ok(f"Deployment complete: {deploy_id}")
        else:
            err(f"Service configuration failed for {server_type}")
            return

    # Save info and offer SSH
    save_deploy_info(config)
    ssh_connect(config)


# ─── Main Menu ──────────────────────────────────────────────────────────────

MENU_ITEMS = [
    ("1", "Matrix + Element", "matrix", "Encrypted messaging homeserver"),
    ("2", "WireGuard VPN", "vpn", "Private VPN server"),
    ("3", "Pi-hole DNS", "dns", "Ad-blocking DNS server"),
    ("4", "Nextcloud", "cloud", "Self-hosted file sync (coming soon)"),
    ("5", "Vaultwarden", "vault", "Password manager (coming soon)"),
    ("6", "Jellyfin", "media", "Media server (coming soon)"),
    ("7", "Mail-in-a-Box", "email", "Email server (coming soon)"),
    ("8", "All-in-One", "all_in_one", "Multiple services on one server"),
    ("0", "Exit", None, None),
]


def main_menu():
    banner()

    while True:
        print(f"\n{CYAN}  ┌─ Deploy a Privacy Server ──────────────────────────┐{RESET}")
        for num, label, _, desc in MENU_ITEMS:
            if desc:
                print(f"  {CYAN}│{RESET}  {WHITE}{num}{RESET}) {label:<20} {GREY}{desc}{RESET}")
            else:
                print(f"  {CYAN}│{RESET}  {WHITE}{num}{RESET}) {label}")
        print(f"  {CYAN}└─────────────────────────────────────────────────────┘{RESET}")

        choice = input(f"\n  {MAGENTA}>{RESET} ").strip()

        if choice == "0":
            print(f"\n{GREY}  Goodbye.{RESET}\n")
            break

        # Find matching menu item
        selected = None
        for num, label, stype, _ in MENU_ITEMS:
            if choice == num and stype:
                selected = stype
                break

        if not selected:
            warn("Invalid selection.")
            continue

        # Import the module
        try:
            mod = __import__(f"modules.{selected}", fromlist=[selected])
        except ImportError as e:
            err(f"Module not found: {selected} ({e})")
            continue

        # Select provider
        provider = select_provider()
        if not provider:
            warn("Invalid provider selection.")
            continue

        config = {"deploy_id": generate_id()}

        if not gather_credentials(provider, config):
            continue

        # Gather service-specific config
        if hasattr(mod, "gather_config"):
            config = mod.gather_config(config)
            if config is None:
                continue

        # Deploy
        deploy(selected, config)


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] in ("--help", "-h"):
        print("Usage: python3 phantom.py")
        print("  Interactive privacy server deployer.")
        print("  Supports Matrix, WireGuard, Pi-hole, and more.")
        print("  Run without arguments to launch the interactive menu.")
        sys.exit(0)
    try:
        main_menu()
    except KeyboardInterrupt:
        print(f"\n{GREY}  Interrupted.{RESET}\n")
