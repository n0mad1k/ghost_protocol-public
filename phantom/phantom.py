#!/usr/bin/env python3
"""phantom — Privacy Server Deployer

Deploy self-hosted privacy infrastructure with a single command.
Supports Matrix, WireGuard VPN, Pi-hole DNS, Nextcloud, and more.

Providers: Linode, AWS, FlokiNET, or local/existing server.
"""

import json
import os
import random
import shutil
import subprocess
import sys
import time
from pathlib import Path

# Allow modules to import from phantom
sys.path.insert(0, os.path.dirname(__file__))

# Kill stale bytecode cache on every run
for _d in [Path(__file__).resolve().parent / "__pycache__",
           Path(__file__).resolve().parent / "modules" / "__pycache__"]:
    if _d.exists():
        shutil.rmtree(_d, ignore_errors=True)

BASE_DIR = Path(__file__).resolve().parent
PLAYBOOKS_DIR = BASE_DIR / "playbooks"
PROVIDERS_DIR = BASE_DIR / "providers"

# Working artifacts (vars.yaml, inventory, deploy_info.json) — always local
WORK_DIR = BASE_DIR / "logs"
WORK_DIR.mkdir(exist_ok=True)

# Mode-aware log directory: only use c2itall logs when launched FROM c2itall
# c2itall sets C2ITALL_INTEGRATED=1 when invoking phantom through its menu
C2_ROOT = Path.home() / "tools" / "c2itall"
C2_INTEGRATED = os.environ.get("C2ITALL_INTEGRATED") == "1"

if C2_INTEGRATED:
    PHANTOM_LOGS = C2_ROOT / "logs"       # central c2itall logs
else:
    PHANTOM_LOGS = BASE_DIR / "logs"      # standalone phantom logs

PHANTOM_LOGS.mkdir(parents=True, exist_ok=True)

SSH_DIR = Path.home() / ".ssh"

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
# Uses c2itall's verb+animal naming convention for consistency

INSTANCE_PREFIX = "ph"  # phantom privacy server prefix

def generate_id():
    """Generate a deployment ID using verb+animal format (matches c2itall)."""
    # Try to import c2itall's name generator
    c2_gen = Path.home() / "tools" / "c2itall" / "utils" / "name_generator.py"
    if c2_gen.exists():
        try:
            import importlib.util
            spec = importlib.util.spec_from_file_location("name_generator", c2_gen)
            mod = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(mod)
            return mod.generate_deployment_id()
        except Exception:
            pass

    # Fallback — same word lists as c2itall
    verbs = [
        "blazing", "soaring", "charging", "prowling", "hunting", "stalking",
        "striking", "rushing", "dashing", "racing", "flying", "diving",
        "leaping", "climbing", "sliding", "spinning", "rolling", "sneaking",
        "roaming", "wandering", "running", "jumping", "swimming", "crawling",
        "fighting", "defending", "attacking", "scanning", "searching", "finding",
    ]
    animals = [
        "wolf", "eagle", "tiger", "falcon", "bear", "lion", "shark", "hawk",
        "panther", "cobra", "viper", "rhino", "bull", "fox", "raven", "crow",
        "spider", "scorpion", "mantis", "dragon", "phoenix", "griffin",
        "badger", "wolverine", "lynx", "jaguar", "cheetah", "leopard",
    ]
    return f"{random.choice(verbs)}{random.choice(animals)}"


def instance_label(deployment_id):
    """Generate cloud instance label: ph-{deployment_id}."""
    return f"{INSTANCE_PREFIX}-{deployment_id}"


# ─── SSH Key Paths ─────────────────────────────────────────────────────────

def _ssh_key_path(deployment_id):
    """Return the standard SSH key path for a deployment."""
    return SSH_DIR / f"c2deploy_ph-{deployment_id}"


def _ssh_known_hosts_path(deployment_id):
    """Return the per-deployment known_hosts path."""
    return SSH_DIR / f"c2deploy_ph-{deployment_id}_known_hosts"


# ─── SSH Key Migration ─────────────────────────────────────────────────────

def _migrate_ssh_keys():
    """Migrate SSH keys from old phantom/logs/{id}/ to ~/.ssh/c2deploy_ph-{id}.

    Scans WORK_DIR for deploy_info.json files with old-style key paths.
    If found and no key at the new path, copies over and updates the JSON.
    """
    migrated = []
    for json_file in WORK_DIR.glob("*/deploy_info.json"):
        try:
            with open(json_file) as f:
                data = json.load(f)
        except (json.JSONDecodeError, OSError):
            continue

        dep_id = data.get("deployment_id") or data.get("deploy_id")
        old_key = data.get("ssh_key", "")
        if not dep_id or not old_key:
            continue

        old_key_path = Path(old_key)
        new_key_path = _ssh_key_path(dep_id)

        # Skip if key is already at new location
        if str(old_key_path) == str(new_key_path):
            continue

        # Skip if old key doesn't exist
        if not old_key_path.exists():
            continue

        # Skip if new key already exists
        if new_key_path.exists():
            continue

        # Copy key pair to new location
        shutil.copy2(old_key_path, new_key_path)
        os.chmod(new_key_path, 0o600)
        old_pub = Path(f"{old_key}.pub")
        new_pub = Path(f"{new_key_path}.pub")
        if old_pub.exists():
            shutil.copy2(old_pub, new_pub)

        # Update JSON config in-place
        data["ssh_key"] = str(new_key_path)
        # Migrate deploy_id → deployment_id while we're here
        if "deploy_id" in data and "deployment_id" not in data:
            data["deployment_id"] = data.pop("deploy_id")
        with open(json_file, "w") as f:
            json.dump(data, f, indent=2, default=str)
        os.chmod(json_file, 0o600)

        migrated.append(dep_id)

    if migrated:
        warn(f"Migrated SSH keys for {len(migrated)} deployment(s) to ~/.ssh/:")
        for dep_id in migrated:
            dim(f"c2deploy_ph-{dep_id}")


# ─── SSH Key Generation ─────────────────────────────────────────────────────

def generate_ssh_key(deployment_id, comment=None):
    """Generate an RSA 4096 SSH keypair at ~/.ssh/c2deploy_ph-{id}."""
    SSH_DIR.mkdir(mode=0o700, exist_ok=True)
    key_path = _ssh_key_path(deployment_id)

    if key_path.exists():
        info(f"SSH key already exists: {key_path}")
        return str(key_path)

    if comment is None:
        comment = f"c2deploy-ph-{deployment_id}"

    info(f"Generating SSH key: {key_path}")
    subprocess.run(
        ["ssh-keygen", "-t", "rsa", "-b", "4096", "-f", str(key_path),
         "-N", "", "-C", comment],
        check=True, capture_output=True,
    )
    os.chmod(key_path, 0o600)
    ok(f"SSH key generated: {key_path}")
    return str(key_path)


# ─── Ansible Playbook Execution ─────────────────────────────────────────────

# Lines to show on console during ansible streaming
_ANSIBLE_SHOW = ("TASK [", "PLAY [", "ok:", "changed:", "failed:", "fatal:", "PLAY RECAP")


def _redact_cmd(cmd):
    """Redact sensitive values from ansible command for logging."""
    _SENSITIVE_PREFIXES = ("api_token=", "relay_api_token=", "aws_secret_key=",
                           "become_password=", "smtp_password=", "voip_sip_password=",
                           "email_relay_password=", "email_admin_password=",
                           "email_first_password=", "relay_psk=", "mailcow_pubkey=")
    redacted = []
    for part in cmd:
        for prefix in _SENSITIVE_PREFIXES:
            if prefix in part:
                key = part.split("=", 1)[0]
                part = f"{key}=REDACTED"
                break
        redacted.append(part)
    return " ".join(redacted)


def run_playbook(playbook_path, config, extra_vars=None):
    """Execute an Ansible playbook with streaming output and log capture.

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

    deployment_id = config["deployment_id"]
    cmd = ["ansible-playbook", str(playbook_path)]

    # Build vars file in work dir
    vars_file = WORK_DIR / deployment_id / "vars.yaml"
    vars_file.parent.mkdir(parents=True, exist_ok=True)

    # Secrets excluded from vars.yaml (file on disk) but passed via --extra-vars
    _exclude_from_vars = {"become_password", "voip_sip_password", "smtp_password",
                          "relay_api_token", "email_relay_password", "email_admin_password",
                          "email_first_password", "relay_psk"}
    _secret_vars = {k for k in _exclude_from_vars if k != "become_password" and config.get(k)}
    vars_config = {k: v for k, v in config.items() if k not in _exclude_from_vars}

    try:
        import yaml  # noqa: optional dependency
        with open(vars_file, "w") as f:
            yaml.dump(vars_config, f, default_flow_style=False)
    except ImportError:
        with open(vars_file, "w") as f:
            for k, v in vars_config.items():
                f.write(f"{k}: {json.dumps(v)}\n")

    cmd.extend(["-e", f"@{vars_file}"])

    # Pass excluded secrets directly via --extra-vars (not written to disk)
    for secret_key in _secret_vars:
        cmd.extend(["-e", f"{secret_key}={config[secret_key]}"])

    if extra_vars:
        for k, v in extra_vars.items():
            cmd.extend(["-e", f"{k}={v}"])

    # Set inventory
    target = config.get("target_host", "localhost")
    if target == "localhost":
        cmd.extend(["-i", "localhost,", "--connection", "local"])
    else:
        inv_file = WORK_DIR / deployment_id / "inventory"
        ssh_key = config.get("ssh_key", "")
        ssh_user = config.get("ssh_user", "root")
        known_hosts = str(_ssh_known_hosts_path(deployment_id))

        ssh_args = (
            f"-o StrictHostKeyChecking=accept-new "
            f"-o IdentitiesOnly=yes "
            f"-o UserKnownHostsFile={known_hosts}"
        )
        line = f"{target} ansible_user={ssh_user} ansible_ssh_common_args='{ssh_args}'"
        if ssh_key:
            line += f" ansible_ssh_private_key_file={ssh_key}"
        if ssh_user != "root":
            become_pass = config.get("become_password", "")
            line += " ansible_become=true"
            if become_pass:
                line += f" ansible_become_password={become_pass}"
        with open(inv_file, "w") as f:
            f.write(f"[servers]\n{line}\n")
        inv_file.chmod(0o600)
        cmd.extend(["-i", str(inv_file)])

    # Log file for full ansible output
    log_file = PHANTOM_LOGS / f"deployment_{deployment_id}.log"

    info(f"Running: {playbook_path.name}")
    dim(f"Log: {log_file}")

    # Stream output — show filtered lines on console, full output to log
    try:
        with open(log_file, "a") as lf:
            lf.write(f"\n{'=' * 60}\n")
            lf.write(f"Playbook: {playbook_path}\n")
            lf.write(f"Time: {time.strftime('%Y-%m-%dT%H:%M:%S%z')}\n")
            lf.write(f"Command: {_redact_cmd(cmd)}\n")
            lf.write(f"{'=' * 60}\n\n")

            proc = subprocess.Popen(
                cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                bufsize=1,
            )
            for line in proc.stdout:
                lf.write(line)
                stripped = line.strip()
                if stripped and any(stripped.startswith(prefix) for prefix in _ANSIBLE_SHOW):
                    print(f"  {GREY}{stripped}{RESET}")
            proc.wait()

            lf.write(f"\nExit code: {proc.returncode}\n")

        if proc.returncode != 0:
            err(f"Playbook failed (rc={proc.returncode})")
            warn(f"Full log: {log_file}")
        return proc.returncode == 0

    except Exception as e:
        err(f"Playbook execution error: {e}")
        return False


# ─── Deployment Info Logging ────────────────────────────────────────────────

def _recover_generated_creds(config):
    """SSH to target and read back any auto-generated passwords.

    Some services (e.g. Mailcow) generate passwords on the server when none
    are provided.  This function fetches those generated values so they can
    be included in deploy_info.json and the terminal summary.
    """
    target = config.get("target_host", "localhost")
    if target == "localhost":
        return

    deployment_id = config["deployment_id"]
    ssh_key = config.get("ssh_key", "")
    ssh_user = config.get("ssh_user", "root")
    known_hosts = str(_ssh_known_hosts_path(deployment_id))

    ssh_base = [
        "ssh", "-o", "StrictHostKeyChecking=accept-new",
        "-o", "IdentitiesOnly=yes",
        "-o", f"UserKnownHostsFile={known_hosts}",
        "-o", "ConnectTimeout=10",
    ]
    if ssh_key:
        ssh_base.extend(["-i", ssh_key])
    ssh_base.append(f"{ssh_user}@{target}")

    server_type = config.get("server_type", "")

    # Map: server_type → list of (config_key, remote_file)
    _CRED_FILES = {
        "email": [
            ("email_admin_password", "/root/.mailcow_admin_password"),
            ("email_first_password", "/root/.mailcow_user_password"),
        ],
    }

    become_password = config.get("become_password", "")
    need_sudo = ssh_user != "root"

    for key, remote_file in _CRED_FILES.get(server_type, []):
        if not config.get(key):
            try:
                if need_sudo and become_password:
                    cmd = ssh_base + [
                        f"echo '{become_password}' | sudo -S cat {remote_file} 2>/dev/null"
                    ]
                elif need_sudo:
                    cmd = ssh_base + [f"sudo cat {remote_file}"]
                else:
                    cmd = ssh_base + [f"cat {remote_file}"]
                result = subprocess.run(
                    cmd, capture_output=True, text=True, timeout=15,
                )
                if result.returncode == 0 and result.stdout.strip():
                    config[key] = result.stdout.strip()
            except (subprocess.TimeoutExpired, OSError):
                pass


def save_deploy_info(config):
    """Save deployment info — mode-aware output location.

    Saves:
      PHANTOM_LOGS/deployment_info_{id}.txt  — human-readable info + creds
      WORK_DIR/{id}/deploy_info.json         — local JSON backup
    """
    deployment_id = config["deployment_id"]
    deploy_dir = WORK_DIR / deployment_id
    deploy_dir.mkdir(parents=True, exist_ok=True)
    config["timestamp"] = time.strftime("%Y-%m-%dT%H:%M:%S%z")

    target = config.get("target_host", "localhost")
    ssh_key = config.get("ssh_key", "")
    ssh_user = config.get("ssh_user", "root")
    label = instance_label(deployment_id)
    known_hosts = str(_ssh_known_hosts_path(deployment_id))

    # Build SSH command
    ssh_parts = ["ssh", "-o", "StrictHostKeyChecking=accept-new",
                 "-o", "IdentitiesOnly=yes",
                 "-o", f"UserKnownHostsFile={known_hosts}"]
    if ssh_key:
        ssh_parts.extend(["-i", ssh_key])
    ssh_parts.append(f"{ssh_user}@{target}")
    ssh_cmd = " ".join(ssh_parts)

    # ── Deployment info file (written to PHANTOM_LOGS) ────────────────────
    info_file = PHANTOM_LOGS / f"deployment_info_{deployment_id}.txt"
    _write_info_file(info_file, config, deployment_id, label, target, ssh_key,
                     ssh_user, ssh_cmd)
    os.chmod(info_file, 0o600)

    # ── JSON config (local backup in work dir) ────────────────────────────
    # Filter secrets from JSON dump (C-006)
    _SECRETS_KEYS = {"api_token", "relay_api_token", "aws_secret_key", "become_password",
                     "smtp_password", "voip_sip_password", "email_relay_password",
                     "email_admin_password", "email_first_password", "relay_psk"}
    json_file = deploy_dir / "deploy_info.json"
    safe_config = {k: v for k, v in config.items() if k not in _SECRETS_KEYS}
    with open(json_file, "w") as f:
        json.dump(safe_config, f, indent=2, default=str)
    os.chmod(json_file, 0o600)

    # ── Terminal summary ──────────────────────────────────────────────────
    print(f"\n{CYAN}{'═' * 60}{RESET}")
    print(f"{GREEN}  Phantom Privacy Server — Deployed!{RESET}")
    print(f"{CYAN}{'═' * 60}{RESET}")
    print(f"  {WHITE}Instance:{RESET}  {label}")
    print(f"  {WHITE}IP:{RESET}        {target}")
    if config.get("domain"):
        print(f"  {WHITE}Domain:{RESET}    {config['domain']}")
    print(f"  {WHITE}SSH:{RESET}       {ssh_cmd}")
    qs = _quick_start(config, target)
    if qs:
        print(f"\n  {CYAN}── Quick Start ──{RESET}")
        for lbl, val in qs:
            print(f"  {WHITE}{lbl}:{RESET}  {val}")
    print(f"\n  {CYAN}Credentials saved to:{RESET} {info_file}")
    if C2_INTEGRATED:
        dim("(c2itall integrated mode)")
    print(f"{CYAN}{'═' * 60}{RESET}")

    ok(f"Deployment info saved: {info_file}")


def _quick_start(config, target):
    """Return per-service Quick Start lines as list of (label, value) tuples."""
    domain = config.get("domain", target)
    stype = config.get("server_type", "")
    qs = []
    if stype == "matrix":
        qs.append(("Web UI", f"https://{domain}"))
        if config.get("matrix_element_web"):
            qs.append(("Element", f"https://element.{domain}"))
        if config.get("matrix_admin_user"):
            qs.append(("Admin", config["matrix_admin_user"]))
        if config.get("matrix_admin_password"):
            qs.append(("Password", config["matrix_admin_password"]))
        qs.append(("Next step", "Log in to Element and start messaging"))
    elif stype == "vpn":
        qs.append(("Port", f"{config.get('vpn_port', '51820')}/UDP"))
        qs.append(("Clients", str(config.get("vpn_client_count", 1))))
        qs.append(("Configs", "/etc/wireguard/client_*.conf on server"))
        qs.append(("Next step", "SCP client configs, import into WireGuard app"))
    elif stype == "dns":
        if domain and domain != target:
            qs.append(("Admin UI", f"https://{domain}"))
        else:
            qs.append(("Admin UI", f"http://{target}:3000"))
        if config.get("dns_admin_user"):
            qs.append(("Admin", config["dns_admin_user"]))
        if config.get("dns_admin_password"):
            qs.append(("Password", config["dns_admin_password"]))
        qs.append(("Next step", "Point devices to this server's IP for DNS"))
    elif stype == "cloud":
        qs.append(("Web UI", f"https://{domain}"))
        if config.get("cloud_admin_user"):
            qs.append(("Admin", config["cloud_admin_user"]))
        if config.get("cloud_admin_password"):
            qs.append(("Password", config["cloud_admin_password"]))
        qs.append(("Next step", "Log in, install Nextcloud desktop/mobile clients"))
    elif stype == "vault":
        qs.append(("Web UI", f"https://{domain}"))
        qs.append(("Admin panel", f"https://{domain}/admin"))
        if config.get("vault_admin_token"):
            qs.append(("Admin token", config["vault_admin_token"]))
        qs.append(("Signups", str(config.get("vault_signups_allowed", False))))
        qs.append(("Next step", "Visit /admin to configure, then create account at main URL"))
    elif stype == "media":
        qs.append(("Web UI", f"https://{domain}"))
        if config.get("media_library_path"):
            qs.append(("Library", config["media_library_path"]))
        qs.append(("Next step", "Complete setup wizard in browser, add media libraries"))
    elif stype == "email":
        email_host = config.get("email_hostname", domain)
        qs.append(("Webmail", f"https://{email_host}/SOGo"))
        qs.append(("Admin", f"https://{email_host}/admin"))
        if config.get("email_admin_password"):
            qs.append(("Admin pass", config["email_admin_password"]))
        if config.get("email_first_user"):
            qs.append(("First user", config["email_first_user"]))
        if config.get("email_first_password"):
            qs.append(("User pass", config["email_first_password"]))
        if config.get("email_relay_mode") == "smarthost" and config.get("email_relay_host"):
            qs.append(("Smarthost", f"{config['email_relay_host']}:{config.get('email_relay_port', '587')}"))
        qs.append(("Next step", "Log into admin panel to manage domains and mailboxes"))
        if config.get("email_relay_mode") == "vps" and config.get("relay_vps_ip"):
            qs.append(("Relay VPS", config["relay_vps_ip"]))
            email_host = config.get("email_hostname", domain)
            qs.append(("IMPORTANT", f"MX and A records for {email_host} must point to {config['relay_vps_ip']}"))
    elif stype == "git":
        platform = config.get("git_platform", "forgejo")
        qs.append(("Platform", platform.title()))
        qs.append(("Web UI", f"https://{domain}"))
        if config.get("git_admin_user"):
            qs.append(("Admin", config["git_admin_user"]))
        if config.get("git_admin_password"):
            qs.append(("Password", config["git_admin_password"]))
        if config.get("git_ssh_port"):
            qs.append(("Git SSH", f"ssh://git@{domain}:{config['git_ssh_port']}/user/repo.git"))
        qs.append(("Next step", "Log into web UI, create first repository"))
    elif stype == "voip":
        voip_host = config.get("voip_hostname", domain)
        qs.append(("PBX Admin", f"https://{voip_host}"))
        qs.append(("Admin user", "admin"))
        qs.append(("Admin pass", "see /root/.izpbx_admin_password on server"))
        if config.get("voip_provider") and config["voip_provider"] != "skip":
            qs.append(("SIP Provider", config["voip_provider"]))
        if config.get("voip_sip_host"):
            qs.append(("SIP Host", f"{config['voip_sip_host']}:{config.get('voip_sip_port', '5060')}"))
        qs.append(("Next step", "Log into FreePBX, create extensions, register SIP phones"))
    if config.get("cf_tunnel_token"):
        qs.append(("CF Tunnel", "configured"))
    return qs


def _write_info_file(info_file, config, deployment_id, label, target, ssh_key,
                     ssh_user, ssh_cmd):
    """Write deployment info in c2itall's standard format."""
    with open(info_file, "w") as f:
        f.write(f"Deployment Information\n")
        f.write(f"{'=' * 50}\n")
        f.write(f"Deployment ID: {deployment_id}\n")
        f.write(f"Provider: {config.get('provider', 'unknown')}\n")
        f.write(f"Deployment Type: phantom_{config.get('server_type', 'unknown')}\n")
        f.write(f"\n")
        f.write(f"Configuration:\n")
        f.write(f"{'-' * 30}\n")
        f.write(f"provider: {config.get('provider', 'unknown')}\n")
        f.write(f"deployment_id: {deployment_id}\n")
        f.write(f"deployment_type: phantom_{config.get('server_type', 'unknown')}\n")
        f.write(f"instance_name: {label}\n")
        if config.get("domain"):
            f.write(f"domain: {config['domain']}\n")
        if config.get("region"):
            f.write(f"linode_region: {config['region']}\n")
        if ssh_key:
            f.write(f"ssh_key_path: {ssh_key}\n")
        f.write(f"\n")
        f.write(f"Access Information:\n")
        f.write(f"{'-' * 30}\n")
        f.write(f"Instance IP: {target}\n")
        if ssh_key:
            f.write(f"SSH Key: {ssh_key}\n")
        f.write(f"SSH Command: {ssh_cmd}\n")
        qs = _quick_start(config, target)
        if qs:
            f.write(f"\nQuick Start:\n")
            f.write(f"{'-' * 30}\n")
            for lbl, val in qs:
                f.write(f"{lbl}: {val}\n")
        f.write(f"\nGenerated at: {config['timestamp']}\n")


# ─── SSH Connect ────────────────────────────────────────────────────────────

def ssh_connect(config):
    """Offer to SSH into the deployed server."""
    target = config.get("target_host", "")
    if not target or target == "localhost":
        return

    deployment_id = config["deployment_id"]
    ssh_key = config.get("ssh_key", "")
    ssh_user = config.get("ssh_user", "root")
    known_hosts = str(_ssh_known_hosts_path(deployment_id))

    cmd = ["ssh", "-o", "StrictHostKeyChecking=accept-new",
           "-o", f"UserKnownHostsFile={known_hosts}",
           "-o", "IdentitiesOnly=yes"]
    if ssh_key:
        cmd.extend(["-i", ssh_key])
    cmd.append(f"{ssh_user}@{target}")

    print()
    resp = input(f"{CYAN}[?]{RESET} SSH into {target}? [y/N] ").strip().lower()
    if resp == "y":
        os.execvp("ssh", cmd)


# ─── Provider Credential Loading ───────────────────────────────────────────

def _load_dotenv():
    """Load phantom/.env if it exists (standalone credential storage)."""
    env_file = BASE_DIR / ".env"
    if not env_file.exists():
        return
    with open(env_file) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if "=" not in line:
                continue
            key, _, value = line.partition("=")
            key = key.strip()
            value = value.strip().strip("'\"")
            # Don't overwrite existing env vars
            if key and key not in os.environ:
                os.environ[key] = value


def _load_provider_defaults():
    """Load provider credentials from .env, env vars, or c2itall vars files.

    Priority: env vars > .env file > c2itall vars files > prompt
    """
    _load_dotenv()

    defaults = {}
    c2itall_base = Path.home() / "tools" / "c2itall" / "providers"

    # Linode — check env first, then c2itall vars file
    linode_token = os.environ.get("LINODE_TOKEN", "")
    linode_vars = c2itall_base / "Linode" / "vars.yaml"
    if linode_token or linode_vars.exists():
        d = {"api_token": linode_token,
             "region": os.environ.get("LINODE_REGION", "us-east"),
             "plan": os.environ.get("LINODE_PLAN", "g6-nanode-1")}
        if linode_vars.exists():
            try:
                import yaml
                with open(linode_vars) as f:
                    data = yaml.safe_load(f) or {}
                d["api_token"] = d["api_token"] or data.get("linode_token", "")
                regions = data.get("region_choices", [])
                if regions:
                    d["region"] = regions[0]
                d["plan"] = data.get("linode_instance_type", d["plan"])
            except Exception:
                pass
        if d["api_token"]:
            defaults["linode"] = d

    # AWS — check env first, then c2itall vars file
    aws_key = os.environ.get("AWS_ACCESS_KEY_ID", "")
    aws_secret = os.environ.get("AWS_SECRET_ACCESS_KEY", "")
    aws_vars = c2itall_base / "AWS" / "c2-vars-template.yaml"
    if aws_key or aws_vars.exists():
        d = {"aws_access_key": aws_key, "aws_secret_key": aws_secret,
             "region": os.environ.get("AWS_REGION", "us-east-1"),
             "instance_type": os.environ.get("AWS_INSTANCE_TYPE", "t3.micro")}
        if aws_vars.exists():
            try:
                import yaml
                with open(aws_vars) as f:
                    data = yaml.safe_load(f) or {}
                ak = data.get("aws_access_key", "")
                sk = data.get("aws_secret_key", "")
                if ak and "YOUR_" not in ak:
                    d["aws_access_key"] = d["aws_access_key"] or ak
                    d["aws_secret_key"] = d["aws_secret_key"] or sk
                    d["region"] = data.get("region", d["region"])
                    d["instance_type"] = data.get("instance_type", d["instance_type"])
            except Exception:
                pass
        if d["aws_access_key"]:
            defaults["aws"] = d

    return defaults


def _mask(token):
    """Mask a token for display: show first 4 and last 4 chars."""
    if not token or len(token) < 12:
        return token
    return token[:4] + "…" + token[-4:]


# Per-service recommended instance sizes — minimum viable for each workload
SERVICE_PLANS = {
    #                  Linode plan        AWS type     Notes
    "vpn":       {"linode": "g6-nanode-1",   "aws": "t3.micro"},    # ~64MB RAM usage
    "dns":       {"linode": "g6-nanode-1",   "aws": "t3.micro"},    # Pi-hole is tiny
    "vault":     {"linode": "g6-nanode-1",   "aws": "t3.micro"},    # Vaultwarden ~50MB
    "cloud":     {"linode": "g6-standard-1", "aws": "t3.small"},    # Nextcloud + MariaDB + Redis
    "matrix":    {"linode": "g6-standard-2", "aws": "t3.medium"},   # Synapse + Postgres + Element (memory hungry)
    "media":     {"linode": "g6-standard-1", "aws": "t3.small"},    # Jellyfin transcoding benefits from RAM
    "email":     {"linode": "g6-standard-2", "aws": "t3.medium"},   # Mailcow dockerized (needs 4GB+ RAM)
    "git":       {"linode": "g6-nanode-1",   "aws": "t3.micro"},    # Forgejo ~200MB; GitLab needs g6-standard-2/t3.medium
    "voip":      {"linode": "g6-standard-1", "aws": "t3.small"},   # izPBX FreePBX+Asterisk (2GB RAM sufficient)
    "all_in_one": {"linode": "g6-standard-2", "aws": "t3.medium"}, # Multiple services
}


# ─── .env → Config Mapping ─────────────────────────────────────────────────

_ENV_CONFIG_MAP = {
    # Provider credentials (no PHANTOM_ prefix — shared with cloud CLIs)
    "LINODE_TOKEN": "api_token",
    "LINODE_REGION": "region",
    "LINODE_PLAN": "plan",
    "AWS_ACCESS_KEY_ID": "aws_access_key",
    "AWS_SECRET_ACCESS_KEY": "aws_secret_key",
    "AWS_REGION": "region",
    "AWS_INSTANCE_TYPE": "instance_type",
    # Common — PHANTOM_ prefix (matches .env)
    "PHANTOM_DOMAIN": "domain",
    "PHANTOM_PROVIDER": "provider",
    "PHANTOM_TARGET_HOST": "target_host",
    "PHANTOM_SSH_USER": "ssh_user",
    "PHANTOM_SSH_KEY": "ssh_key",
    "PHANTOM_BECOME_PASSWORD": "become_password",
    "PHANTOM_DEPLOYMENT_ID": "deployment_id",
    # Cloudflare — accept both PHANTOM_ prefixed and bare
    "PHANTOM_CF_TUNNEL_TOKEN": "cf_tunnel_token",
    "CF_TUNNEL_TOKEN": "cf_tunnel_token",
    # Matrix — accept both PHANTOM_ prefixed and bare
    "PHANTOM_MATRIX_ADMIN_USER": "matrix_admin_user",
    "PHANTOM_MATRIX_ADMIN_PASSWORD": "matrix_admin_password",
    "PHANTOM_MATRIX_REGISTRATION": "matrix_registration",
    "PHANTOM_MATRIX_ELEMENT_WEB": "matrix_element_web",
    "MATRIX_ADMIN_USER": "matrix_admin_user",
    "MATRIX_ADMIN_PASSWORD": "matrix_admin_password",
    "MATRIX_REGISTRATION": "matrix_registration",
    "MATRIX_ELEMENT_WEB": "matrix_element_web",
    # VPN — accept both PHANTOM_ prefixed and bare
    "PHANTOM_VPN_PORT": "vpn_port",
    "PHANTOM_VPN_CLIENT_COUNT": "vpn_client_count",
    "PHANTOM_VPN_DNS": "vpn_dns",
    "PHANTOM_VPN_ALLOWED_IPS": "vpn_allowed_ips",
    "PHANTOM_VPN_SUBNET": "vpn_subnet",
    "VPN_PORT": "vpn_port",
    "VPN_CLIENT_COUNT": "vpn_client_count",
    "VPN_DNS": "vpn_dns",
    "VPN_ALLOWED_IPS": "vpn_allowed_ips",
    "VPN_SUBNET": "vpn_subnet",
    # DNS — accept both PHANTOM_ prefixed and bare
    "PHANTOM_DNS_UPSTREAM": "dns_upstream",
    "PHANTOM_DNS_BLOCKLIST": "dns_blocklist",
    "PHANTOM_DNS_DOMAIN": "dns_domain",
    "PHANTOM_DNS_ADMIN_USER": "dns_admin_user",
    "PHANTOM_DNS_ADMIN_PASSWORD": "dns_admin_password",
    "DNS_UPSTREAM": "dns_upstream",
    "DNS_BLOCKLIST": "dns_blocklist",
    "DNS_DOMAIN": "dns_domain",
    "DNS_ADMIN_USER": "dns_admin_user",
    "DNS_ADMIN_PASSWORD": "dns_admin_password",
    # Cloud (Nextcloud) — accept both PHANTOM_ prefixed and bare
    "PHANTOM_CLOUD_ADMIN_USER": "cloud_admin_user",
    "PHANTOM_CLOUD_ADMIN_PASSWORD": "cloud_admin_password",
    "PHANTOM_CLOUD_STORAGE_GB": "cloud_storage_gb",
    "CLOUD_ADMIN_USER": "cloud_admin_user",
    "CLOUD_ADMIN_PASSWORD": "cloud_admin_password",
    "CLOUD_STORAGE_GB": "cloud_storage_gb",
    # Vault — accept both PHANTOM_ prefixed and bare
    "PHANTOM_VAULT_ADMIN_TOKEN": "vault_admin_token",
    "PHANTOM_VAULT_SIGNUPS_ALLOWED": "vault_signups_allowed",
    "VAULT_ADMIN_TOKEN": "vault_admin_token",
    "VAULT_SIGNUPS_ALLOWED": "vault_signups_allowed",
    # Media — accept both PHANTOM_ prefixed and bare
    "PHANTOM_MEDIA_LIBRARY_PATH": "media_library_path",
    "MEDIA_LIBRARY_PATH": "media_library_path",
    # Email — accept both PHANTOM_ prefixed and bare
    "PHANTOM_EMAIL_HOSTNAME": "email_hostname",
    "PHANTOM_EMAIL_TIMEZONE": "email_timezone",
    "PHANTOM_EMAIL_DOMAIN": "domain",
    "PHANTOM_EMAIL_ADMIN_PASSWORD": "email_admin_password",
    "PHANTOM_EMAIL_FIRST_USER": "email_first_user",
    "PHANTOM_EMAIL_FIRST_PASSWORD": "email_first_password",
    "EMAIL_HOSTNAME": "email_hostname",
    "EMAIL_DOMAIN": "domain",
    "EMAIL_ADMIN_PASSWORD": "email_admin_password",
    "EMAIL_FIRST_USER": "email_first_user",
    "EMAIL_FIRST_PASSWORD": "email_first_password",
    # Email relay/smarthost — accept both PHANTOM_ prefixed and bare
    "PHANTOM_EMAIL_RELAY_HOST": "email_relay_host",
    "PHANTOM_EMAIL_RELAY_PORT": "email_relay_port",
    "PHANTOM_EMAIL_RELAY_USER": "email_relay_user",
    "PHANTOM_EMAIL_RELAY_PASSWORD": "email_relay_password",
    "EMAIL_RELAY_HOST": "email_relay_host",
    "EMAIL_RELAY_PORT": "email_relay_port",
    "EMAIL_RELAY_USER": "email_relay_user",
    "EMAIL_RELAY_PASSWORD": "email_relay_password",
    # Email relay VPS mode
    "PHANTOM_EMAIL_RELAY_MODE": "email_relay_mode",
    "PHANTOM_RELAY_PROVIDER": "relay_provider",
    "PHANTOM_RELAY_API_TOKEN": "relay_api_token",
    "PHANTOM_RELAY_REGION": "relay_region",
    "EMAIL_RELAY_MODE": "email_relay_mode",
    "RELAY_PROVIDER": "relay_provider",
    "RELAY_API_TOKEN": "relay_api_token",
    "RELAY_REGION": "relay_region",
    # Git — accept both PHANTOM_ prefixed and bare
    "PHANTOM_GIT_PLATFORM": "git_platform",
    "PHANTOM_GIT_SSH_PORT": "git_ssh_port",
    "PHANTOM_GIT_ADMIN_USER": "git_admin_user",
    "PHANTOM_GIT_ADMIN_PASSWORD": "git_admin_password",
    "PHANTOM_GIT_ADMIN_EMAIL": "git_admin_email",
    "GIT_PLATFORM": "git_platform",
    "GIT_SSH_PORT": "git_ssh_port",
    "GIT_ADMIN_USER": "git_admin_user",
    "GIT_ADMIN_PASSWORD": "git_admin_password",
    "GIT_ADMIN_EMAIL": "git_admin_email",
    # VOIP — accept both PHANTOM_ prefixed and bare
    "PHANTOM_VOIP_HOSTNAME": "voip_hostname",
    "PHANTOM_VOIP_ADMIN_PASSWORD": "voip_admin_password",
    "PHANTOM_VOIP_PROVIDER": "voip_provider",
    "PHANTOM_VOIP_SIP_HOST": "voip_sip_host",
    "PHANTOM_VOIP_SIP_PORT": "voip_sip_port",
    "PHANTOM_VOIP_SIP_USERNAME": "voip_sip_username",
    "PHANTOM_VOIP_SIP_PASSWORD": "voip_sip_password",
    "PHANTOM_VOIP_SIP_TRANSPORT": "voip_sip_transport",
    "PHANTOM_VOIP_TIMEZONE": "voip_timezone",
    "VOIP_HOSTNAME": "voip_hostname",
    "VOIP_ADMIN_PASSWORD": "voip_admin_password",
    "VOIP_PROVIDER": "voip_provider",
    "VOIP_SIP_HOST": "voip_sip_host",
    "VOIP_SIP_PORT": "voip_sip_port",
    "VOIP_SIP_USERNAME": "voip_sip_username",
    "VOIP_SIP_PASSWORD": "voip_sip_password",
    "VOIP_SIP_TRANSPORT": "voip_sip_transport",
    "VOIP_TIMEZONE": "voip_timezone",
    # All-in-One
    "PHANTOM_SERVICES": "services",
    "PHANTOM_CERTBOT_EMAIL": "certbot_email",
    # Maintenance Reports (SMTP)
    "PHANTOM_SMTP_HOST": "smtp_host",
    "PHANTOM_SMTP_PORT": "smtp_port",
    "PHANTOM_SMTP_USER": "smtp_user",
    "PHANTOM_SMTP_PASSWORD": "smtp_password",
    "PHANTOM_SMTP_FROM": "smtp_from",
    "PHANTOM_REPORT_EMAIL": "report_email",
}

_BOOL_KEYS = {"matrix_registration", "matrix_element_web", "vault_signups_allowed"}
_INT_KEYS = {"vpn_port", "vpn_client_count", "cloud_storage_gb", "git_ssh_port"}


def _populate_config_from_env(config):
    """Populate config dict from environment variables via _ENV_CONFIG_MAP."""
    _load_dotenv()
    for env_key, config_key in _ENV_CONFIG_MAP.items():
        val = os.environ.get(env_key, "")
        if val and config_key not in config:
            if config_key in _BOOL_KEYS:
                config[config_key] = val.lower() in ("true", "yes", "1", "y")
            elif config_key in _INT_KEYS:
                try:
                    config[config_key] = int(val)
                except ValueError:
                    config[config_key] = val
            else:
                config[config_key] = val
    return config


# ─── Provider Selection ─────────────────────────────────────────────────────

def select_provider():
    """Select deployment target: cloud provider or local/existing server.

    If PHANTOM_PROVIDER is set in env/.env, auto-selects the provider.
    """
    _load_dotenv()
    env_provider = os.environ.get("PHANTOM_PROVIDER", "").lower()
    if env_provider in ("linode", "aws", "flokinet", "existing", "local"):
        ok(f"Provider from .env: {env_provider}")
        return env_provider

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


def gather_credentials(provider, config, service_type=None):
    """Gather provider-specific credentials.

    Loads defaults from c2itall vars files or environment variables.
    Uses per-service recommended plans when available.
    Press Enter at any prompt to accept the stored default.
    """
    _populate_config_from_env(config)
    defaults = _load_provider_defaults()

    if provider == "linode":
        config["provider"] = "linode"
        d = defaults.get("linode", {})
        stored_token = d.get("api_token", "")
        default_region = d.get("region", "us-east")
        # Per-service plan takes priority over provider-level default
        svc_plans = SERVICE_PLANS.get(service_type, {})
        default_plan = svc_plans.get("linode", d.get("plan", "g6-nanode-1"))

        if stored_token:
            ok(f"Linode token loaded: {_mask(stored_token)}")
            override = input(f"  {CYAN}Use stored token? [Y/n]:{RESET} ").strip().lower()
            config["api_token"] = stored_token if override != "n" else input(f"  {CYAN}Linode API token:{RESET} ").strip()
        else:
            config["api_token"] = input(f"  {CYAN}Linode API token:{RESET} ").strip()

        config["region"] = input(f"  {CYAN}Region [{WHITE}{default_region}{RESET}]: ").strip() or default_region
        config["plan"] = input(f"  {CYAN}Plan [{WHITE}{default_plan}{RESET}]: ").strip() or default_plan

    elif provider == "aws":
        config["provider"] = "aws"
        d = defaults.get("aws", {})
        stored_key = d.get("aws_access_key", "")
        stored_secret = d.get("aws_secret_key", "")
        default_region = d.get("region", "us-east-1")
        # Per-service instance type takes priority over provider-level default
        svc_plans = SERVICE_PLANS.get(service_type, {})
        default_type = svc_plans.get("aws", d.get("instance_type", "t3.micro"))

        if stored_key:
            ok(f"AWS credentials loaded: {_mask(stored_key)}")
            override = input(f"  {CYAN}Use stored credentials? [Y/n]:{RESET} ").strip().lower()
            if override != "n":
                config["aws_access_key"] = stored_key
                config["aws_secret_key"] = stored_secret
            else:
                config["aws_access_key"] = input(f"  {CYAN}AWS Access Key ID:{RESET} ").strip()
                config["aws_secret_key"] = input(f"  {CYAN}AWS Secret Access Key:{RESET} ").strip()
        else:
            config["aws_access_key"] = input(f"  {CYAN}AWS Access Key ID:{RESET} ").strip()
            config["aws_secret_key"] = input(f"  {CYAN}AWS Secret Access Key:{RESET} ").strip()

        config["region"] = input(f"  {CYAN}Region [{WHITE}{default_region}{RESET}]: ").strip() or default_region
        config["instance_type"] = input(f"  {CYAN}Instance type [{WHITE}{default_type}{RESET}]: ").strip() or default_type

    elif provider == "flokinet":
        config["provider"] = "flokinet"
        if config.get("target_host"):
            ok(f"Server IP from .env: {config['target_host']}")
        else:
            config["target_host"] = input(f"  {CYAN}Server IP:{RESET} ").strip()
        if config.get("ssh_user"):
            ok(f"SSH user from .env: {config['ssh_user']}")
        else:
            config["ssh_user"] = input(f"  {CYAN}SSH user [{WHITE}root{RESET}]: ").strip() or "root"

    elif provider == "existing":
        config["provider"] = "existing"
        if config.get("target_host"):
            ok(f"Server IP from .env: {config['target_host']}")
        else:
            config["target_host"] = input(f"  {CYAN}Server IP/hostname:{RESET} ").strip()
        if config.get("ssh_user"):
            ok(f"SSH user from .env: {config['ssh_user']}")
        else:
            config["ssh_user"] = input(f"  {CYAN}SSH user [{WHITE}root{RESET}]: ").strip() or "root"
        if config.get("ssh_key"):
            ok(f"SSH key from .env: {config['ssh_key']}")
        else:
            existing_key = input(f"  {CYAN}SSH key path (blank to generate):{RESET} ").strip()
            if existing_key:
                config["ssh_key"] = str(Path(existing_key).expanduser().resolve())
        if config.get("become_password"):
            ok("Sudo password loaded from .env")
        elif config.get("ssh_user", "root") != "root":
            import getpass
            sudo_pass = getpass.getpass(f"  {CYAN}Sudo password (blank if NOPASSWD):{RESET} ")
            if sudo_pass:
                config["become_password"] = sudo_pass

    elif provider == "local":
        config["provider"] = "local"
        config["target_host"] = "localhost"
        config["ssh_user"] = os.getenv("USER", "root")
        warn("Local deployment will install services directly on this machine.")
        confirm = input(f"  {YELLOW}Continue? [y/N]:{RESET} ").strip().lower()
        if confirm != "y":
            return False

    return True


# ─── Teardown ──────────────────────────────────────────────────────────────

def teardown_instance(config_or_id):
    """Tear down a provisioned cloud instance.

    Accepts either a full config dict OR a deployment_id string.
    If string: loads config from WORK_DIR/{id}/deploy_info.json.
    After successful teardown: archives info file, cleans SSH keys.
    """
    # Resolve config from string ID
    if isinstance(config_or_id, str):
        deployment_id = config_or_id
        json_file = WORK_DIR / deployment_id / "deploy_info.json"
        if json_file.exists():
            with open(json_file) as f:
                config = json.load(f)
            # Normalize key name
            if "deploy_id" in config and "deployment_id" not in config:
                config["deployment_id"] = config.pop("deploy_id")
        else:
            err(f"No deploy_info.json found for {deployment_id}")
            return False

        # May need API credentials — check env / provider defaults / prompt
        provider = config.get("provider")
        if provider == "linode" and not config.get("api_token"):
            defaults = _load_provider_defaults()
            config["api_token"] = defaults.get("linode", {}).get("api_token", "")
            if not config["api_token"]:
                config["api_token"] = input(f"  {CYAN}Linode API token for teardown:{RESET} ").strip()
        elif provider == "aws" and not config.get("aws_access_key"):
            defaults = _load_provider_defaults()
            aws = defaults.get("aws", {})
            config["aws_access_key"] = aws.get("aws_access_key", "")
            config["aws_secret_key"] = aws.get("aws_secret_key", "")
            if not config["aws_access_key"]:
                config["aws_access_key"] = input(f"  {CYAN}AWS Access Key for teardown:{RESET} ").strip()
                config["aws_secret_key"] = input(f"  {CYAN}AWS Secret Key for teardown:{RESET} ").strip()
    else:
        config = config_or_id

    provider = config.get("provider")
    deployment_id = config.get("deployment_id")
    label = instance_label(deployment_id)

    cleanup_map = {
        "linode": PROVIDERS_DIR / "linode_cleanup.yml",
        "aws": PROVIDERS_DIR / "aws_cleanup.yml",
    }

    playbook = cleanup_map.get(provider)
    if not playbook or not playbook.exists():
        err(f"No cleanup playbook for provider: {provider}")
        warn(f"Manually delete instance labeled '{label}' from your provider dashboard.")
        return False

    warn(f"Tearing down {provider} instance: {label}")

    # Build teardown vars — pass instance_label + credentials
    teardown_vars = {"instance_label": label}
    for key in ("api_token", "aws_access_key", "aws_secret_key", "region"):
        if config.get(key):
            teardown_vars[key] = config[key]

    cmd = [
        "ansible-playbook", str(playbook),
        "-i", "localhost,", "--connection", "local",
    ]
    for k, v in teardown_vars.items():
        cmd.extend(["-e", f"{k}={v}"])

    info(f"Running: {' '.join(cmd)}")
    try:
        result = subprocess.run(cmd, timeout=120)
        if result.returncode == 0:
            ok(f"Instance {label} destroyed.")
            _archive_deployment(deployment_id)
            return True
        else:
            err(f"Cleanup playbook failed (rc={result.returncode})")
            warn(f"Manually delete instance '{label}' from your provider dashboard.")
            return False
    except Exception as e:
        err(f"Teardown failed: {e}")
        warn(f"Manually delete instance '{label}' from your provider dashboard.")
        return False


def _archive_deployment(deployment_id):
    """Archive deployment info file and clean SSH keys after teardown."""
    # Archive info file
    info_file = PHANTOM_LOGS / f"deployment_info_{deployment_id}.txt"
    if info_file.exists():
        archive_dir = PHANTOM_LOGS / "archive"
        archive_dir.mkdir(exist_ok=True)
        shutil.move(str(info_file), str(archive_dir / info_file.name))
        dim(f"Archived: {info_file.name}")

    # Archive ansible log
    log_file = PHANTOM_LOGS / f"deployment_{deployment_id}.log"
    if log_file.exists():
        archive_dir = PHANTOM_LOGS / "archive"
        archive_dir.mkdir(exist_ok=True)
        shutil.move(str(log_file), str(archive_dir / log_file.name))

    # Clean SSH keys
    key_path = _ssh_key_path(deployment_id)
    for f in [key_path, Path(f"{key_path}.pub"), _ssh_known_hosts_path(deployment_id)]:
        if f.exists():
            f.unlink()
            dim(f"Removed: {f.name}")


# ─── Manage Existing Deployments ───────────────────────────────────────────

def _parse_deployment_info(info_file):
    """Parse a deployment_info_*.txt file and return key fields."""
    data = {}
    try:
        text = info_file.read_text()
        for line in text.splitlines():
            line = line.strip()
            if line.startswith("Deployment ID:"):
                data["deployment_id"] = line.split(":", 1)[1].strip()
            elif line.startswith("Deployment Type:"):
                data["deployment_type"] = line.split(":", 1)[1].strip()
            elif line.startswith("Instance IP:"):
                data["ip"] = line.split(":", 1)[1].strip()
            elif line.startswith("domain:"):
                data["domain"] = line.split(":", 1)[1].strip()
            elif line.startswith("SSH Key:"):
                data["ssh_key"] = line.split(":", 1)[1].strip()
            elif line.startswith("Provider:"):
                data["provider"] = line.split(":", 1)[1].strip()
    except OSError:
        pass
    return data


def run_maintenance(dep):
    """Run maintenance routine on a deployed server via SSH.

    Checks that the maintenance script exists on the server, then runs it
    with live output streaming. Reports success/warning/failure based on exit code.
    """
    dep_id = dep.get("deployment_id", "")
    ip = dep.get("ip", "")
    ssh_key = dep.get("ssh_key", str(_ssh_key_path(dep_id)))
    known_hosts = str(_ssh_known_hosts_path(dep_id))

    if not ip:
        err("No IP address found for this deployment.")
        return

    # Load full config from deploy_info.json for ssh_user
    json_file = WORK_DIR / dep_id / "deploy_info.json"
    ssh_user = "root"
    if json_file.exists():
        try:
            with open(json_file) as f:
                full_config = json.load(f)
            ssh_user = full_config.get("ssh_user", "root")
        except (json.JSONDecodeError, OSError):
            pass

    ssh_base = [
        "ssh", "-o", "StrictHostKeyChecking=accept-new",
        "-o", "IdentitiesOnly=yes",
        "-o", f"UserKnownHostsFile={known_hosts}",
        "-o", "ConnectTimeout=15",
    ]
    if ssh_key and Path(ssh_key).exists():
        ssh_base.extend(["-i", ssh_key])
    ssh_base.append(f"{ssh_user}@{ip}")

    # Check if maintenance script exists on server
    info(f"Checking maintenance script on {ip}...")
    check_cmd = ssh_base + ["test -f /opt/phantom-maint/maint.sh && echo OK"]
    try:
        result = subprocess.run(check_cmd, capture_output=True, text=True, timeout=15)
        if "OK" not in result.stdout:
            err("Maintenance script not found at /opt/phantom-maint/maint.sh")
            warn("This server may have been deployed before maintenance was added.")
            warn("Re-deploy or manually copy the script to the server.")
            return
    except (subprocess.TimeoutExpired, OSError) as e:
        err(f"SSH connection failed: {e}")
        return

    # Run maintenance with live output
    info(f"Running maintenance on {ip}...")
    print(f"{CYAN}{'─' * 60}{RESET}")

    run_cmd = ssh_base + ["sudo /opt/phantom-maint/maint.sh"]
    try:
        proc = subprocess.Popen(
            run_cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
        )
        for line in proc.stdout:
            print(f"  {GREY}{line.rstrip()}{RESET}")
        proc.wait()

        print(f"{CYAN}{'─' * 60}{RESET}")
        if proc.returncode == 0:
            ok("Maintenance completed successfully.")
        elif proc.returncode == 1:
            warn("Maintenance completed with warnings.")
        else:
            err(f"Maintenance reported critical issues (exit code {proc.returncode}).")

    except (subprocess.TimeoutExpired, OSError) as e:
        err(f"Maintenance execution failed: {e}")


def manage_menu():
    """Manage existing phantom deployments: SSH, teardown."""
    # Discover deployments from info files
    deployments = []
    for info_file in sorted(PHANTOM_LOGS.glob("deployment_info_*.txt")):
        data = _parse_deployment_info(info_file)
        dep_type = data.get("deployment_type", "")
        if dep_type.startswith("phantom_"):
            data["_info_file"] = info_file
            deployments.append(data)

    if not deployments:
        warn("No phantom deployments found.")
        return

    print(f"\n{CYAN}  ┌─ Existing Deployments ────────────────────────────────┐{RESET}")
    for i, dep in enumerate(deployments, 1):
        dep_type = dep.get("deployment_type", "unknown").replace("phantom_", "")
        ip = dep.get("ip", "?")
        domain = dep.get("domain", "")
        dep_id = dep.get("deployment_id", "?")
        domain_str = f" ({domain})" if domain else ""
        print(f"  {CYAN}│{RESET}  {WHITE}{i}{RESET}) {dep_id:<25} {GREY}{dep_type:<12} {ip}{domain_str}{RESET}")
    print(f"  {CYAN}│{RESET}  {WHITE}0{RESET}) Return")
    print(f"  {CYAN}└─────────────────────────────────────────────────────────┘{RESET}")

    choice = input(f"\n  {MAGENTA}>{RESET} ").strip()
    if choice == "0" or not choice:
        return

    try:
        idx = int(choice) - 1
        if idx < 0 or idx >= len(deployments):
            warn("Invalid selection.")
            return
    except ValueError:
        warn("Invalid selection.")
        return

    dep = deployments[idx]
    dep_id = dep.get("deployment_id", "")

    print(f"\n{CYAN}  ┌─ {dep_id} ─────────────────────────────────────────┐{RESET}")
    print(f"  {CYAN}│{RESET}  {WHITE}1{RESET}) SSH into server")
    print(f"  {CYAN}│{RESET}  {WHITE}2{RESET}) Run Maintenance")
    print(f"  {CYAN}│{RESET}  {WHITE}3{RESET}) Teardown")
    print(f"  {CYAN}│{RESET}  {WHITE}4{RESET}) Return")
    print(f"  {CYAN}└─────────────────────────────────────────────────────────┘{RESET}")

    action = input(f"\n  {MAGENTA}>{RESET} ").strip()

    if action == "1":
        # SSH into server
        ip = dep.get("ip", "")
        ssh_key = dep.get("ssh_key", str(_ssh_key_path(dep_id)))
        known_hosts = str(_ssh_known_hosts_path(dep_id))

        if not ip:
            err("No IP address found for this deployment.")
            return

        cmd = ["ssh", "-o", "StrictHostKeyChecking=accept-new",
               "-o", f"UserKnownHostsFile={known_hosts}",
               "-o", "IdentitiesOnly=yes"]
        if ssh_key and Path(ssh_key).exists():
            cmd.extend(["-i", ssh_key])
        cmd.append(f"root@{ip}")

        info(f"Connecting to {ip}...")
        os.execvp("ssh", cmd)

    elif action == "2":
        # Run maintenance
        run_maintenance(dep)

    elif action == "3":
        # Teardown
        confirm = input(f"  {RED}Destroy {dep_id}? [y/N]:{RESET} ").strip().lower()
        if confirm == "y":
            teardown_instance(dep_id)

    # action == "4" or anything else: return


# ─── SMTP Config for Maintenance Reports ──────────────────────────────────

def _gather_smtp_config(config):
    """Gather SMTP settings for maintenance report emails.

    Skips all prompts if smtp_host is already in config (from .env).
    If user enters blank SMTP host, skips remaining SMTP prompts.
    """
    if config.get("smtp_host"):
        ok(f"SMTP config from .env: {config['smtp_host']}")
        return

    import getpass
    print(f"\n{CYAN}  ┌─ Maintenance Reports (SMTP) ──────────────────────┐{RESET}")
    print(f"  {CYAN}│{RESET}  {GREY}Email health reports after weekly maintenance{RESET}")

    smtp_host = input(f"  {CYAN}│{RESET}  SMTP host [{WHITE}skip{RESET}]: ").strip()
    if not smtp_host:
        print(f"  {CYAN}│{RESET}  {GREY}Skipping — reports will only log to /var/log/phantom-maint.log{RESET}")
        print(f"  {CYAN}└─────────────────────────────────────────────────────┘{RESET}")
        return

    config["smtp_host"] = smtp_host
    config["smtp_port"] = input(f"  {CYAN}│{RESET}  SMTP port [{WHITE}587{RESET}]: ").strip() or "587"
    config["smtp_user"] = input(f"  {CYAN}│{RESET}  SMTP user: ").strip()
    config["smtp_password"] = getpass.getpass(f"  {CYAN}│{RESET}  SMTP password: ")
    config["smtp_from"] = input(f"  {CYAN}│{RESET}  From address: ").strip()
    config["report_email"] = input(f"  {CYAN}│{RESET}  Report recipient: ").strip()

    print(f"  {CYAN}└─────────────────────────────────────────────────────┘{RESET}")


# ─── Email Relay VPS Orchestration ────────────────────────────────────────

def _deploy_email_relay(config):
    """Provision relay VPS, configure WireGuard relay, return relay info."""
    relay_id = config["deployment_id"] + "-relay"
    relay_config = {
        "deployment_id": relay_id,
        "provider": config.get("relay_provider") or config["provider"],
        "api_token": config.get("relay_api_token") or config.get("api_token", ""),
        "region": config.get("relay_region") or config.get("region", "us-east"),
        "plan": "g6-nanode-1",  # relay is lightweight
        "server_type": "email_relay",
    }

    # Generate SSH key with neutral comment (C-021)
    relay_config["ssh_key"] = generate_ssh_key(relay_id, comment="")

    # Override instance label for OPSEC (C-022)
    relay_config["instance_label_override"] = f"mail-relay-{relay_id[-8:]}"

    # AWS needs additional credentials
    if relay_config["provider"] == "aws":
        relay_config["aws_access_key"] = config.get("aws_access_key", "")
        relay_config["aws_secret_key"] = config.get("aws_secret_key", "")
        relay_config["instance_type"] = "t3.nano"

    # 1. Provision relay nanode
    provider_playbook = PROVIDERS_DIR / f"{relay_config['provider']}.yml"
    host_file = WORK_DIR / relay_id / "provisioned_host"
    host_file.parent.mkdir(parents=True, exist_ok=True)
    relay_config["_host_output_file"] = str(host_file)

    info("Provisioning relay VPS (nanode)...")
    if not run_playbook(provider_playbook, relay_config):
        err("Relay VPS provisioning failed")
        return False

    if not host_file.exists():
        err("Relay provisioned but no host IP returned")
        return False

    relay_ip = host_file.read_text().strip()
    relay_config["target_host"] = relay_ip
    relay_config["ssh_user"] = "root"
    ok(f"Relay VPS provisioned: {relay_ip}")

    # Save relay info immediately for teardown (C-007)
    config["relay_vps_ip"] = relay_ip
    config["relay_deployment_id"] = relay_id
    config["relay_provider"] = relay_config["provider"]

    # 2. Base hardening on relay
    info("Hardening relay VPS...")
    run_playbook(PLAYBOOKS_DIR / "common" / "base_hardening.yml", relay_config)

    # 3. Run relay_main.yml on relay VPS
    relay_config["email_hostname"] = config.get("email_hostname", "")
    info("Configuring WireGuard relay...")
    if not run_playbook(PLAYBOOKS_DIR / "email" / "relay_main.yml", relay_config):
        err("Relay WireGuard configuration failed")
        teardown_instance(relay_id)
        return False

    # 4. SSH read-back: get relay pubkey, PSK, endpoint (C-008)
    relay_info = _ssh_read_relay_info(relay_config)
    if not relay_info:
        err("Failed to read relay WireGuard keys")
        teardown_instance(relay_id)
        return False

    config["relay_pubkey"] = relay_info["pubkey"]
    config["relay_psk"] = relay_info["psk"]
    config["relay_endpoint"] = f"{relay_ip}:51820"
    ok("Relay WireGuard keys retrieved")

    return True


def _ssh_read_relay_info(config):
    """Read WireGuard pubkey and PSK from relay VPS via SSH."""
    target = config.get("target_host", "")
    deployment_id = config["deployment_id"]
    ssh_key = config.get("ssh_key", "")
    known_hosts = str(_ssh_known_hosts_path(deployment_id))

    ssh_base = [
        "ssh", "-o", "StrictHostKeyChecking=accept-new",
        "-o", "IdentitiesOnly=yes",
        "-o", f"UserKnownHostsFile={known_hosts}",
        "-o", "ConnectTimeout=15",
    ]
    if ssh_key:
        ssh_base.extend(["-i", ssh_key])
    ssh_base.append(f"root@{target}")

    try:
        # Read public key
        result = subprocess.run(
            ssh_base + ["cat /etc/wireguard/relay_public.key"],
            capture_output=True, text=True, timeout=30,
        )
        if result.returncode != 0:
            return None
        pubkey = result.stdout.strip()

        # Read PSK
        result = subprocess.run(
            ssh_base + ["cat /etc/wireguard/relay_psk.key"],
            capture_output=True, text=True, timeout=30,
        )
        if result.returncode != 0:
            return None
        psk = result.stdout.strip()

        if not pubkey or not psk:
            return None

        return {"pubkey": pubkey, "psk": psk}

    except (subprocess.TimeoutExpired, OSError):
        return None


def _finalize_email_relay(config):
    """Inject Mailcow pubkey into relay VPS and start tunnel."""
    relay_id = config.get("relay_deployment_id", "")
    relay_ip = config.get("relay_vps_ip", "")
    target = config.get("target_host", "")
    deployment_id = config["deployment_id"]

    if not relay_id or not relay_ip:
        err("Relay info missing — cannot finalize tunnel")
        return False

    # 1. SSH to Mailcow, read WG public key
    ssh_key = config.get("ssh_key", "")
    ssh_user = config.get("ssh_user", "root")
    known_hosts = str(_ssh_known_hosts_path(deployment_id))

    ssh_mc = [
        "ssh", "-o", "StrictHostKeyChecking=accept-new",
        "-o", "IdentitiesOnly=yes",
        "-o", f"UserKnownHostsFile={known_hosts}",
        "-o", "ConnectTimeout=15",
    ]
    if ssh_key:
        ssh_mc.extend(["-i", ssh_key])
    ssh_mc.append(f"{ssh_user}@{target}")

    try:
        result = subprocess.run(
            ssh_mc + ["cat /etc/wireguard/mailcow_public.key"],
            capture_output=True, text=True, timeout=30,
        )
        if result.returncode != 0 or not result.stdout.strip():
            err("Could not read Mailcow WireGuard public key")
            return False
        mailcow_pubkey = result.stdout.strip()
    except (subprocess.TimeoutExpired, OSError) as e:
        err(f"SSH to Mailcow failed: {e}")
        return False

    # 2. Run relay_finalize.yml on relay VPS
    relay_config = {
        "deployment_id": relay_id,
        "target_host": relay_ip,
        "ssh_key": str(_ssh_key_path(relay_id)),
        "ssh_user": "root",
    }

    info(f"Injecting Mailcow peer key into relay VPS...")
    if not run_playbook(
        _relay_finalize_playbook(),
        relay_config,
        extra_vars={"mailcow_pubkey": mailcow_pubkey},
    ):
        err("Relay finalization playbook failed")
        return False

    ok("Relay tunnel established and verified")
    return True


def _relay_finalize_playbook():
    """Return path to the relay finalize wrapper playbook, creating if needed."""
    path = PLAYBOOKS_DIR / "email" / "relay_finalize.yml"
    if not path.exists():
        # Create wrapper inline — tasks file is at tasks/relay_finalize.yml
        path.write_text(
            "---\n"
            "- name: Finalize WireGuard Mail Relay\n"
            "  hosts: all\n"
            "  become: true\n"
            "  tasks:\n"
            "    - name: Include relay finalize tasks\n"
            "      include_tasks: tasks/relay_finalize.yml\n"
        )
    return path


# ─── Deployment Orchestration ───────────────────────────────────────────────

def deploy(server_type, config):
    """Full deployment pipeline: summarize -> confirm -> provision -> configure.

    Follows c2itall pattern: on ANY failure after provisioning, auto-teardown.
    """
    config["server_type"] = server_type
    config.setdefault("deployment_id", generate_id())
    deployment_id = config["deployment_id"]
    is_cloud = config.get("provider") in ("linode", "aws")

    # Summary
    print(f"\n{CYAN}{'─' * 60}{RESET}")
    print(f"{MAGENTA}  Deployment Summary{RESET}")
    print(f"{CYAN}{'─' * 60}{RESET}")
    print(f"  {WHITE}ID:{RESET}       {deployment_id}")
    if is_cloud:
        print(f"  {WHITE}Label:{RESET}    {instance_label(deployment_id)}")
    print(f"  {WHITE}Type:{RESET}     {server_type}")
    print(f"  {WHITE}Provider:{RESET} {config.get('provider', 'unknown')}")
    print(f"  {WHITE}Target:{RESET}   {config.get('target_host', 'TBD (will provision)')}")
    if config.get("domain"):
        print(f"  {WHITE}Domain:{RESET}   {config['domain']}")
    for k, v in config.items():
        if k not in ("deployment_id", "server_type", "provider", "target_host",
                      "domain", "api_token", "aws_access_key", "aws_secret_key",
                      "ssh_key", "ssh_user", "timestamp", "become_password",
                      "cf_tunnel_token"):
            print(f"  {WHITE}{k}:{RESET} {v}")
    print(f"{CYAN}{'─' * 60}{RESET}")

    confirm = input(f"\n  {MAGENTA}Deploy? [y/N]:{RESET} ").strip().lower()
    if confirm != "y":
        warn("Deployment cancelled.")
        return

    # Generate SSH key if needed
    if config.get("provider") not in ("local",) and not config.get("ssh_key"):
        config["ssh_key"] = generate_ssh_key(deployment_id)

    # ── Provision cloud instance ──────────────────────────────────────────
    if is_cloud:
        provider_playbook = PROVIDERS_DIR / f"{config['provider']}.yml"
        host_file = WORK_DIR / deployment_id / "provisioned_host"
        config["_host_output_file"] = str(host_file)
        info(f"Provisioning {config['provider']} instance...")
        if not run_playbook(provider_playbook, config):
            err("Provisioning failed.")
            # Instance may already exist (API call succeeded, SSH wait timed out)
            # Always attempt teardown — cleanup playbook uses ignore_errors
            warn("Attempting teardown in case instance was created...")
            teardown_instance(config)
            return
        # Read back the provisioned host IP
        if host_file.exists():
            config["target_host"] = host_file.read_text().strip()
            ok(f"Provisioned server: {config['target_host']}")
        else:
            err("Provisioning completed but no host IP was returned.")
            teardown_instance(config)
            return

    # ── Post-provisioning: hardening + service config ─────────────────────
    # Any failure here tears down the cloud instance (matches c2itall pattern)
    try:
        # Base hardening
        info("Applying base hardening...")
        if not run_playbook(PLAYBOOKS_DIR / "common/base_hardening.yml", config):
            raise RuntimeError("Base hardening failed")

        # ── Email relay VPS provisioning (before main service) ─────────
        if server_type == "email" and config.get("email_relay_mode") == "vps":
            info("Provisioning email relay VPS...")
            if not _deploy_email_relay(config):
                raise RuntimeError("Email relay provisioning failed")

        # Service-specific playbook
        playbook_map = {
            "matrix": PLAYBOOKS_DIR / "matrix/main.yml",
            "vpn": PLAYBOOKS_DIR / "vpn/main.yml",
            "dns": PLAYBOOKS_DIR / "dns/main.yml",
            "cloud": PLAYBOOKS_DIR / "cloud/main.yml",
            "vault": PLAYBOOKS_DIR / "vault/main.yml",
            "media": PLAYBOOKS_DIR / "media/main.yml",
            "email": PLAYBOOKS_DIR / "email/main.yml",
            "git": PLAYBOOKS_DIR / "git/main.yml",
            "voip": PLAYBOOKS_DIR / "voip/main.yml",
            "all_in_one": PLAYBOOKS_DIR / "all_in_one/main.yml",
        }

        playbook = playbook_map.get(server_type)
        if playbook:
            info(f"Configuring {server_type}...")
            if not run_playbook(playbook, config):
                raise RuntimeError(f"Service configuration failed for {server_type}")

        # ── Finalize email relay tunnel ────────────────────────────────
        if server_type == "email" and config.get("email_relay_mode") == "vps":
            info("Finalizing relay tunnel...")
            if not _finalize_email_relay(config):
                warn("Relay tunnel finalization failed — may need manual WG peer setup")

        # Post-deploy: unattended upgrades (non-fatal)
        post_deploy = PLAYBOOKS_DIR / "common/post_deploy.yml"
        if post_deploy.exists():
            info("Applying post-deployment setup (unattended upgrades)...")
            run_playbook(post_deploy, config)

        ok(f"Deployment complete: {deployment_id}")
        _recover_generated_creds(config)
        save_deploy_info(config)
        ssh_connect(config)

    except Exception as e:
        import traceback
        err(str(e))
        log_file = PHANTOM_LOGS / f"deployment_{deployment_id}.log"
        try:
            with open(log_file, "a") as lf:
                lf.write(f"\n{'=' * 60}\n")
                lf.write(f"EXCEPTION during deployment\n")
                lf.write(f"{'=' * 60}\n")
                traceback.print_exc(file=lf)
        except OSError:
            pass
        # Tear down relay VPS if it was provisioned (C-007)
        relay_id = config.get("relay_deployment_id")
        if relay_id:
            warn("Tearing down relay VPS...")
            teardown_instance(relay_id)
        if is_cloud:
            warn("Tearing down provisioned instance...")
            teardown_instance(config)
        return


# ─── Main Menu ──────────────────────────────────────────────────────────────

MENU_ITEMS = [
    ("1", "Matrix + Element", "matrix", "Encrypted messaging homeserver"),
    ("2", "WireGuard VPN", "vpn", "Private VPN server"),
    ("3", "AdGuard Home", "dns", "Ad-blocking DNS server"),
    ("4", "Nextcloud", "cloud", "Self-hosted file sync"),
    ("5", "Vaultwarden", "vault", "Password manager"),
    ("6", "Jellyfin", "media", "Media server"),
    ("7", "Mailcow", "email", "Email server"),
    ("8", "Git Server", "git", "Forgejo or GitLab CE"),
    ("9", "VOIP (izPBX)", "voip", "FreePBX + Asterisk PBX"),
    ("a", "All-in-One", "all_in_one", "Multiple services on one server"),
    ("m", "Manage Deployment", None, "SSH, teardown existing"),
    ("0", "Exit", None, None),
]


def main_menu():
    banner()

    # Migrate old SSH keys on startup
    _migrate_ssh_keys()

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

        if choice == "m":
            manage_menu()
            continue

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

        config = {}
        _populate_config_from_env(config)
        if "deployment_id" not in config:
            config["deployment_id"] = generate_id()

        if not gather_credentials(provider, config, service_type=selected):
            continue

        # Gather service-specific config
        if hasattr(mod, "gather_config"):
            config = mod.gather_config(config)
            if config is None:
                continue

        # Gather SMTP config for maintenance reports
        _gather_smtp_config(config)

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
