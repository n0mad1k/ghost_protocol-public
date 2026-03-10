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

def generate_ssh_key(deployment_id):
    """Generate an RSA 4096 SSH keypair at ~/.ssh/c2deploy_ph-{id}."""
    SSH_DIR.mkdir(mode=0o700, exist_ok=True)
    key_path = _ssh_key_path(deployment_id)

    if key_path.exists():
        info(f"SSH key already exists: {key_path}")
        return str(key_path)

    info(f"Generating SSH key: {key_path}")
    subprocess.run(
        ["ssh-keygen", "-t", "rsa", "-b", "4096", "-f", str(key_path),
         "-N", "", "-C", f"c2deploy-ph-{deployment_id}"],
        check=True, capture_output=True,
    )
    os.chmod(key_path, 0o600)
    ok(f"SSH key generated: {key_path}")
    return str(key_path)


# ─── Ansible Playbook Execution ─────────────────────────────────────────────

# Lines to show on console during ansible streaming
_ANSIBLE_SHOW = ("TASK [", "PLAY [", "ok:", "changed:", "failed:", "fatal:", "PLAY RECAP")


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
            lf.write(f"Command: {' '.join(cmd)}\n")
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
    json_file = deploy_dir / "deploy_info.json"
    with open(json_file, "w") as f:
        json.dump(config, f, indent=2, default=str)
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
    if config.get("matrix_admin_user"):
        print(f"  {WHITE}Admin:{RESET}     {config['matrix_admin_user']}")
    if config.get("matrix_admin_password"):
        print(f"  {WHITE}Password:{RESET}  {config['matrix_admin_password']}")
    if config.get("cloud_admin_user"):
        print(f"  {WHITE}Admin:{RESET}     {config['cloud_admin_user']}")
    if config.get("vault_admin_token"):
        print(f"  {WHITE}Token:{RESET}     {config['vault_admin_token']}")
    print(f"\n  {CYAN}Credentials saved to:{RESET} {info_file}")
    if C2_INTEGRATED:
        dim("(c2itall integrated mode)")
    print(f"{CYAN}{'═' * 60}{RESET}")

    ok(f"Deployment info saved: {info_file}")


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
        if config.get("matrix_admin_user"):
            f.write(f"Matrix Admin: {config['matrix_admin_user']}\n")
        if config.get("matrix_admin_password"):
            f.write(f"Matrix Password: {config['matrix_admin_password']}\n")
        if config.get("cloud_admin_user"):
            f.write(f"Nextcloud Admin: {config['cloud_admin_user']}\n")
        if config.get("vault_admin_token"):
            f.write(f"Vaultwarden Token: {config['vault_admin_token']}\n")
        if config.get("email_first_user"):
            f.write(f"Email User: {config['email_first_user']}\n")
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
    "email":     {"linode": "g6-standard-1", "aws": "t3.small"},    # Mail-in-a-Box full stack
    "all_in_one": {"linode": "g6-standard-2", "aws": "t3.medium"}, # Multiple services
}


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


def gather_credentials(provider, config, service_type=None):
    """Gather provider-specific credentials.

    Loads defaults from c2itall vars files or environment variables.
    Uses per-service recommended plans when available.
    Press Enter at any prompt to accept the stored default.
    """
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
        config["target_host"] = input(f"  {CYAN}Server IP:{RESET} ").strip()
        config["ssh_user"] = input(f"  {CYAN}SSH user [{WHITE}root{RESET}]: ").strip() or "root"

    elif provider == "existing":
        config["provider"] = "existing"
        config["target_host"] = input(f"  {CYAN}Server IP/hostname:{RESET} ").strip()
        config["ssh_user"] = input(f"  {CYAN}SSH user [{WHITE}root{RESET}]: ").strip() or "root"
        existing_key = input(f"  {CYAN}SSH key path (blank to generate):{RESET} ").strip()
        if existing_key:
            config["ssh_key"] = existing_key
        if config["ssh_user"] != "root":
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
    print(f"  {CYAN}│{RESET}  {WHITE}2{RESET}) Teardown")
    print(f"  {CYAN}│{RESET}  {WHITE}3{RESET}) Return")
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
        # Teardown
        confirm = input(f"  {RED}Destroy {dep_id}? [y/N]:{RESET} ").strip().lower()
        if confirm == "y":
            teardown_instance(dep_id)

    # action == "3" or anything else: return


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
                      "ssh_key", "ssh_user", "timestamp"):
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
            if not run_playbook(playbook, config):
                raise RuntimeError(f"Service configuration failed for {server_type}")

        ok(f"Deployment complete: {deployment_id}")
        save_deploy_info(config)
        ssh_connect(config)

    except Exception as e:
        err(str(e))
        if is_cloud:
            warn("Tearing down provisioned instance...")
            teardown_instance(config)
        return


# ─── Main Menu ──────────────────────────────────────────────────────────────

MENU_ITEMS = [
    ("1", "Matrix + Element", "matrix", "Encrypted messaging homeserver"),
    ("2", "WireGuard VPN", "vpn", "Private VPN server"),
    ("3", "Pi-hole DNS", "dns", "Ad-blocking DNS server"),
    ("4", "Nextcloud", "cloud", "Self-hosted file sync"),
    ("5", "Vaultwarden", "vault", "Password manager"),
    ("6", "Jellyfin", "media", "Media server"),
    ("7", "Mail-in-a-Box", "email", "Email server"),
    ("8", "All-in-One", "all_in_one", "Multiple services on one server"),
    ("9", "Manage Deployment", None, "SSH, teardown existing"),
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

        if choice == "9":
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

        config = {"deployment_id": generate_id()}

        if not gather_credentials(provider, config, service_type=selected):
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
