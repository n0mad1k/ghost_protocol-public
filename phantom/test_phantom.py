#!/usr/bin/env python3
"""Phantom test runner — exercises all modules, playbooks, and deployment flows.

Runs as a simulated user through every service type without actual deployment.
Tests: imports, module configs, playbook syntax, deploy pipeline (dry run).
"""

import getpass
import importlib
import json
import os
import subprocess
import sys
import tempfile
import unittest
import yaml
from io import StringIO
from pathlib import Path
from unittest.mock import patch, MagicMock

# Setup path
sys.path.insert(0, os.path.dirname(__file__))

BASE_DIR = Path(__file__).resolve().parent
PLAYBOOKS_DIR = BASE_DIR / "playbooks"


# ─── Colors ──────────────────────────────────────────────────────────────────

RESET = "\033[0m"
BOLD = "\033[1m"
GREEN = "\033[38;5;49m"
RED = "\033[38;5;196m"
CYAN = "\033[38;5;51m"
YELLOW = "\033[38;5;214m"
GREY = "\033[38;5;244m"
MAGENTA = "\033[38;5;201m"


def header(msg):
    print(f"\n{CYAN}{'═' * 60}{RESET}")
    print(f"{MAGENTA}  {msg}{RESET}")
    print(f"{CYAN}{'═' * 60}{RESET}")


def passed(msg):
    print(f"  {GREEN}✓{RESET} {msg}")


def failed(msg):
    print(f"  {RED}✗{RESET} {msg}")


def skipped(msg):
    print(f"  {YELLOW}○{RESET} {msg}")


# ─── Test 1: Module Imports ──────────────────────────────────────────────────

def test_imports():
    header("Test 1: Module Imports")
    modules = ["matrix", "vpn", "dns", "cloud", "vault", "media", "email", "all_in_one"]
    results = {"pass": 0, "fail": 0}

    for mod_name in modules:
        try:
            mod = importlib.import_module(f"modules.{mod_name}")
            if hasattr(mod, "gather_config"):
                passed(f"modules.{mod_name} — imported, gather_config() present")
            else:
                failed(f"modules.{mod_name} — imported but no gather_config()")
                results["fail"] += 1
                continue
            results["pass"] += 1
        except Exception as e:
            failed(f"modules.{mod_name} — import failed: {e}")
            results["fail"] += 1

    # Import phantom itself
    try:
        import phantom
        for fn in ["generate_id", "instance_label", "generate_ssh_key",
                    "run_playbook", "deploy", "save_deploy_info", "main_menu",
                    "manage_menu", "_migrate_ssh_keys", "_archive_deployment"]:
            assert hasattr(phantom, fn), f"missing {fn}"
        passed(f"phantom.py — imported, all core functions present")
        results["pass"] += 1
    except Exception as e:
        failed(f"phantom.py — import failed: {e}")
        results["fail"] += 1

    return results


# ─── Test 2: Deployment ID Generation ────────────────────────────────────────

def test_id_generation():
    header("Test 2: Deployment ID Generation")
    import phantom
    results = {"pass": 0, "fail": 0}

    ids = set()
    for _ in range(100):
        deployment_id = phantom.generate_id()
        ids.add(deployment_id)
        # verb+animal format: all lowercase, no dashes, no digits
        if not deployment_id.isalpha() or not deployment_id.islower():
            failed(f"Bad ID format: {deployment_id} (expected verbanimal, e.g. blazingwolf)")
            results["fail"] += 1
            return results

    if len(ids) >= 50:  # verb+animal combos have ~840 possibilities
        passed(f"Generated 100 IDs, {len(ids)} unique — good entropy")
        results["pass"] += 1
    else:
        failed(f"Only {len(ids)}/100 unique IDs — poor entropy")
        results["fail"] += 1

    # Verify instance_label format
    sample_id = phantom.generate_id()
    label = phantom.instance_label(sample_id)
    if label == f"ph-{sample_id}":
        passed(f"Instance label format correct: {label}")
        results["pass"] += 1
    else:
        failed(f"Bad label: {label} (expected ph-{sample_id})")
        results["fail"] += 1

    # Sample output
    sample = list(ids)[:5]
    for s in sample:
        print(f"    {GREY}sample: {s} → ph-{s}{RESET}")

    return results


# ─── Test 3: Ansible Playbook Syntax ─────────────────────────────────────────

def test_playbook_syntax():
    header("Test 3: Ansible Playbook Syntax Check")
    results = {"pass": 0, "fail": 0}

    playbooks = [
        PLAYBOOKS_DIR / "common/base_hardening.yml",
        PLAYBOOKS_DIR / "matrix/main.yml",
        PLAYBOOKS_DIR / "vpn/main.yml",
        PLAYBOOKS_DIR / "dns/main.yml",
        PLAYBOOKS_DIR / "cloud/main.yml",
        PLAYBOOKS_DIR / "vault/main.yml",
        PLAYBOOKS_DIR / "media/main.yml",
        PLAYBOOKS_DIR / "email/main.yml",
        PLAYBOOKS_DIR / "all_in_one/main.yml",
    ]

    # Also check provider playbooks
    for p in (BASE_DIR / "providers").glob("*.yml"):
        playbooks.append(p)

    for pb in playbooks:
        rel = pb.relative_to(BASE_DIR)
        if not pb.exists():
            failed(f"{rel} — file missing")
            results["fail"] += 1
            continue

        result = subprocess.run(
            ["ansible-playbook", "--syntax-check", str(pb),
             "-i", "localhost,", "--connection", "local"],
            capture_output=True, text=True
        )
        if result.returncode == 0:
            passed(f"{rel}")
            results["pass"] += 1
        else:
            # Show first line of error
            err_line = result.stderr.strip().split("\n")[0] if result.stderr else result.stdout.strip().split("\n")[0]
            failed(f"{rel} — {err_line}")
            results["fail"] += 1

    sensitive = {
        "Generate server private key", "Save server private key",
        "Read server private key", "Generate server public key",
        "Generate client keys", "Build WireGuard server config",
        "Verify WireGuard config", "Generate client config files",
    }
    vpn_tasks = []
    for path in (PLAYBOOKS_DIR / "vpn/tasks/install.yml",
                 PLAYBOOKS_DIR / "vpn/tasks/configure.yml"):
        vpn_tasks.extend(yaml.safe_load(path.read_text()))
    found = {task.get("name") for task in vpn_tasks if task.get("name") in sensitive}
    protected = {task.get("name") for task in vpn_tasks
                 if task.get("name") in sensitive and task.get("no_log") is True}
    has_debug = any("debug" in task for task in vpn_tasks)
    if found == sensitive and protected == sensitive and not has_debug:
        passed("playbooks/vpn — key-bearing tasks suppress Ansible output")
        results["pass"] += 1
    else:
        failed("playbooks/vpn — key-bearing task output is not fully suppressed")
        results["fail"] += 1

    synapse_tasks = yaml.safe_load(
        (PLAYBOOKS_DIR / "matrix/tasks/synapse.yml").read_text())
    admin_task = next(
        (task for task in synapse_tasks if task.get("name") == "Create admin user"),
        {},
    )
    failure_checks = " ".join(admin_task.get("failed_when", []))
    if admin_task.get("no_log") is True \
            and "User ID already taken" in failure_checks \
            and "admin_create.stdout" in failure_checks \
            and "admin_create.stderr" in failure_checks \
            and admin_task.get("changed_when") == "admin_create.rc == 0":
        passed("playbooks/matrix — existing admin is an idempotent, redacted success")
        results["pass"] += 1
    else:
        failed("playbooks/matrix — admin creation is not safely idempotent")
        results["fail"] += 1

    dns_install = (PLAYBOOKS_DIR / "dns/tasks/install.yml").read_text()
    dns_configure = (PLAYBOOKS_DIR / "dns/tasks/configure.yml").read_text()
    if ("DNSMASQ_LISTENING=all" in dns_install
            and 'from_ip: "{{ operator_ip }}"' in dns_install
            and "dns.listeningMode ALL" in dns_configure
            and "meta: flush_handlers" in dns_configure
            and "Restrict saved Pi-hole admin password" in dns_configure
            and 'mode: "0600"' in dns_configure
            and dns_configure.index("meta: flush_handlers")
                < dns_configure.index("Restrict saved Pi-hole admin password")):
        passed("playbooks/dns — remote queries and saved credentials are restricted")
        results["pass"] += 1
    else:
        failed("playbooks/dns — Azure-safe network or credential restrictions are incomplete")
        results["fail"] += 1

    return results


# ─── Test 4: Module gather_config Flows ──────────────────────────────────────

def test_gather_config():
    header("Test 4: Module gather_config() — Simulated User Input")
    results = {"pass": 0, "fail": 0}

    # Input sequences for each module (what a user would type)
    test_inputs = {
        "matrix": [
            "matrix.test.local",   # domain
            "admin",               # admin user
            "testpass123",         # admin password (getpass)
            "n",                   # registration
            "y",                   # element web
        ],
        "vpn": [
            "",   # port (default 51820)
            "3",  # client configs
            "",   # dns (default)
            "",   # allowed IPs (default)
            "",   # subnet (default)
        ],
        "dns": [
            "1",    # upstream DNS (Quad9)
            "",     # admin domain (optional)
            "1",    # blocklist (standard)
        ],
        "cloud": [
            "cloud.test.local",  # domain
            "admin",             # admin user
            "10",                # storage GB
        ],
        "vault": [
            "vault.test.local",  # domain
            "",                  # admin token (auto-generate)
            "n",                 # signups
        ],
        "media": [
            "media.test.local",  # domain
            "/srv/media",        # library path
        ],
        "email": [
            "mail.test.local",          # domain
            "admin@test.local",         # first user
        ],
        "all_in_one": [
            "y",                 # acknowledge single-server risks
            "2,5",               # WireGuard + Vaultwarden
            "all.test.local",    # base domain
            "",                  # WireGuard port
            "1",                 # WireGuard client count
            "",                  # WireGuard DNS
            "",                  # WireGuard allowed IPs
            "",                  # WireGuard subnet
            "",                  # Vaultwarden token (auto-generate)
            "n",                 # Vaultwarden signups
        ],
    }

    for mod_name, inputs in test_inputs.items():
        try:
            mod = importlib.import_module(f"modules.{mod_name}")
            config = {"deployment_id": f"test-{mod_name}-01"}

            # Mock input() and getpass.getpass() to feed our test inputs
            input_iter = iter(inputs)

            def mock_input(prompt=""):
                try:
                    val = next(input_iter)
                    print(f"    {GREY}→ {prompt.strip()[:50]} {CYAN}{val or '(default)'}{RESET}")
                    return val
                except StopIteration:
                    return ""

            def mock_getpass(prompt=""):
                return mock_input(prompt)

            with patch("builtins.input", mock_input), \
                 patch("getpass.getpass", mock_getpass):
                # Some modules import getpass at module level
                if hasattr(mod, "getpass"):
                    with patch.object(mod, "getpass", MagicMock(getpass=mock_getpass)):
                        result = mod.gather_config(config)
                else:
                    # For modules that use getpass.getpass directly
                    import modules
                    result = mod.gather_config(config)

            if result is not None:
                if mod_name == "all_in_one":
                    assert result["services"] == ["vpn", "vault"]
                    assert result["domain"] == "all.test.local"
                    assert result["service_domains"]["vault"] == "vault.all.test.local"
                keys = [k for k in result.keys() if k != "deployment_id"]
                passed(f"{mod_name} — config collected: {', '.join(keys[:6])}")
                results["pass"] += 1
            else:
                failed(f"{mod_name} — gather_config returned None")
                results["fail"] += 1

        except Exception as e:
            failed(f"{mod_name} — {type(e).__name__}: {e}")
            results["fail"] += 1

    return results


# ─── Test 5: Deploy Pipeline (Dry Run) ──────────────────────────────────────

def test_deploy_pipeline():
    header("Test 5: Deploy Pipeline — Dry Run (Cancel Before Execute)")
    import phantom
    results = {"pass": 0, "fail": 0}

    services = ["matrix", "vpn", "dns", "cloud", "vault", "media", "email"]

    for svc in services:
        config = {
            "deployment_id": f"dryrun-{svc}-99",
            "provider": "local",
            "target_host": "localhost",
            "ssh_user": os.getenv("USER", "root"),
            "domain": f"{svc}.test.local",
        }

        # Capture deploy() output — answer "n" to the deploy confirmation
        def mock_input(prompt=""):
            return "n"

        try:
            with patch("builtins.input", mock_input), \
                 patch("sys.stdout", new_callable=StringIO) as mock_stdout:
                phantom.deploy(svc, config)

            output = mock_stdout.getvalue()
            if "Deployment cancelled" in output and config["deployment_id"] in output:
                passed(f"{svc} — summary displayed, deploy cancelled correctly")
                results["pass"] += 1
            else:
                failed(f"{svc} — unexpected output")
                results["fail"] += 1

        except Exception as e:
            failed(f"{svc} — {type(e).__name__}: {e}")
            results["fail"] += 1

    return results


def test_integrated_provider_dispatch():
    header("Test 5b: Integrated Provider Dispatch")
    import phantom
    results = {"pass": 0, "fail": 0}
    adapter = MagicMock()
    adapter.gather_config.return_value = {
        "azure_subscription_id": "00000000-0000-0000-0000-000000000000",
        "azure_location": "eastus", "azure_vm_size": "Standard_D2as_v4",
        "operator_ip": "8.8.8.8",
    }

    def available(workload, legacy_fallback=False):
        if workload == "phantom" and legacy_fallback:
            return ["aws", "linode", "flokinet", "azure"]
        return []

    with patch.object(phantom, "_integrated_provider_tools",
                      return_value=(available, MagicMock())), \
         patch("builtins.input", return_value="4"), \
         patch("sys.stdout", new_callable=StringIO):
        selected = phantom.select_provider()
    if selected == "azure":
        passed("Azure is offered after legacy providers in integrated mode")
        results["pass"] += 1
    else:
        failed(f"Integrated provider selection returned {selected}")
        results["fail"] += 1

    config = {"deployment_id": "dispatchtest", "server_type": "vpn"}
    with patch.object(phantom, "_provider_adapter", return_value=adapter):
        gathered = phantom.gather_credentials("azure", config, service_type="vpn")
    if gathered and config.get("provider_workload") == "phantom":
        passed("Registered adapter gathers provider configuration")
        results["pass"] += 1
    else:
        failed("Registered adapter configuration was not used")
        results["fail"] += 1

    adapter.deploy.side_effect = lambda value: value.update(
        target_host="1.1.1.1", ssh_user="azureuser", ssh_key="/tmp/key") or True
    config.update(provider="azure", ssh_after_deploy=False)
    with patch.object(phantom, "_provider_adapter", return_value=adapter), \
         patch.object(phantom, "run_playbook", return_value=True) as playbook, \
         patch.object(phantom, "save_deploy_info") as saved, \
         patch.object(phantom, "ssh_connect") as ssh, \
         patch("builtins.input", return_value="y"), \
         patch("sys.stdout", new_callable=StringIO):
        deployed = phantom.deploy("vpn", config)
    if deployed and playbook.call_count == 2 and saved.called and not ssh.called:
        passed("Adapter provisioning enters the existing service pipeline")
        results["pass"] += 1
    else:
        failed("Adapter deployment did not preserve the service pipeline")
        results["fail"] += 1

    class TransitionBridge:
        def __init__(self):
            self.calls = 0

        def deploy_with_legacy(self, value, legacy):
            self.calls += 1
            value.setdefault("region", value["aws_region"])
            return legacy(value)

    bridge = TransitionBridge()
    bridge_config = {
        "provider": "aws", "provider_workload": "phantom",
        "deployment_id": "bridgetest", "server_type": "vpn",
        "aws_region": "us-east-1", "ssh_after_deploy": False,
    }

    def bridge_playbook(playbook_path, value):
        if Path(playbook_path).parent == phantom.PROVIDERS_DIR:
            output = Path(value["_host_output_file"])
            output.parent.mkdir(parents=True, exist_ok=True)
            output.write_text("1.1.1.2")
        return True

    with tempfile.TemporaryDirectory() as temporary, \
         patch.object(phantom, "WORK_DIR", Path(temporary)), \
         patch.object(phantom, "_provider_adapter", return_value=bridge), \
         patch.object(phantom, "generate_ssh_key", return_value="/tmp/bridge-key"), \
         patch.object(phantom, "run_playbook", side_effect=bridge_playbook) as legacy, \
         patch.object(phantom, "save_deploy_info"), \
         patch("builtins.input", return_value="y"), \
         patch("sys.stdout", new_callable=StringIO):
        bridged = phantom.deploy("vpn", bridge_config)
    if (bridged and bridge.calls == 1 and legacy.call_count == 3 and
            bridge_config.get("target_host") == "1.1.1.2"):
        passed("Transition adapter calls the preserved provider playbook once")
        results["pass"] += 1
    else:
        failed("Transition adapter did not preserve the provider lifecycle")
        results["fail"] += 1

    adapter.cleanup.return_value = True
    with patch.object(phantom, "_provider_adapter", return_value=adapter), \
         patch.object(phantom, "_archive_deployment") as archive, \
         patch("sys.stdout", new_callable=StringIO):
        cleaned = phantom.teardown_instance(config)
    if cleaned and adapter.cleanup.called and archive.called:
        passed("Adapter cleanup is used before Phantom archival")
        results["pass"] += 1
    else:
        failed("Adapter cleanup path was not used")
        results["fail"] += 1

    return results


def test_secret_display_redaction():
    header("Test 5c: Secret Display Redaction")
    import phantom
    results = {"pass": 0, "fail": 0}
    secret = "matrix-password-must-not-print"
    config = {
        "provider": "existing", "deployment_id": "redactiontest",
        "target_host": "192.0.2.10", "ssh_key": "/tmp/test-key",
        "matrix_admin_password": secret, "matrix_signing_key": "signing-secret",
        "matrix_form_secret": "form-secret", "matrix_macaroon_secret": "macaroon-secret",
        "tailscale_auth_key": "tskey-auth-must-not-print",
    }
    with patch.object(phantom, "_provider_adapter", return_value=None), \
         patch("builtins.input", return_value="n"), \
         patch("sys.stdout", new_callable=StringIO) as output:
        deployed = phantom.deploy("matrix", config)
    rendered = output.getvalue()
    if not deployed and secret not in rendered and "signing-secret" not in rendered \
            and "tskey-auth-must-not-print" not in rendered \
            and rendered.count("<redacted>") >= 5:
        passed("Deployment summaries redact Matrix credentials, auth keys and secrets")
        results["pass"] += 1
    else:
        failed("Deployment summary exposed a Matrix credential or secret")
        results["fail"] += 1
    return results


# ─── Test 6: SSH Key Generation ──────────────────────────────────────────────

def test_ssh_keygen():
    header("Test 6: SSH Key Generation (new ~/.ssh/ path)")
    import phantom
    results = {"pass": 0, "fail": 0}

    test_id = "testkeygen00"
    try:
        key_path = phantom.generate_ssh_key(test_id)
        key_file = Path(key_path)
        pub_file = Path(f"{key_path}.pub")

        # Verify key is at ~/.ssh/c2deploy_ph-{id}
        expected_path = Path.home() / ".ssh" / f"c2deploy_ph-{test_id}"
        if key_file == expected_path:
            passed(f"Key at correct path: ~/.ssh/c2deploy_ph-{test_id}")
            results["pass"] += 1
        else:
            failed(f"Key at wrong path: {key_file} (expected {expected_path})")
            results["fail"] += 1

        if key_file.exists() and pub_file.exists():
            # Check permissions
            mode = oct(key_file.stat().st_mode)[-3:]
            if mode == "600":
                passed(f"Key generated: {key_file.name} (mode 0600)")
                results["pass"] += 1
            else:
                failed(f"Key permissions wrong: {mode} (expected 600)")
                results["fail"] += 1

            # Verify key format
            pub_content = pub_file.read_text()
            if pub_content.startswith("ssh-rsa"):
                passed(f"RSA 4096 public key valid")
                results["pass"] += 1
            else:
                failed(f"Unexpected key format")
                results["fail"] += 1
        else:
            failed("Key files not created")
            results["fail"] += 1

    except Exception as e:
        failed(f"Key generation failed: {e}")
        results["fail"] += 1
    finally:
        # Cleanup — remove from ~/.ssh/
        for suffix in ["", ".pub"]:
            f = Path.home() / ".ssh" / f"c2deploy_ph-{test_id}{suffix}"
            if f.exists():
                f.unlink()
        kh = Path.home() / ".ssh" / f"c2deploy_ph-{test_id}_known_hosts"
        if kh.exists():
            kh.unlink()
        print(f"    {GREY}cleaned up test keys{RESET}")

    return results


# ─── Test 7: Full Interactive Flow Simulation ────────────────────────────────

def test_interactive_flow():
    header("Test 7: Full Menu Flow — Matrix Deploy (Simulated)")
    import phantom
    results = {"pass": 0, "fail": 0}

    # Simulate: select Matrix (1), Local provider (5), confirm local (y),
    # fill config, cancel deploy (n), exit (0)
    inputs = iter([
        "1",                    # Menu: Matrix
        "5",                    # Provider: Local
        "y",                    # Confirm local
        "matrix.test.local",    # Domain
        "admin",                # Admin user
        "testpass123",          # Admin password
        "n",                    # Registration
        "y",                    # Element web
        "n",                    # Deploy? No
        "0",                    # Exit menu
    ])

    def mock_input(prompt=""):
        try:
            val = next(inputs)
            short_prompt = prompt.strip()[:60].replace("\033[38;5;51m", "").replace("\033[0m", "").replace("\033[38;5;201m", "").replace("\033[38;5;255m", "").replace("\033[38;5;214m", "")
            print(f"    {GREY}→ {short_prompt} {CYAN}{val}{RESET}")
            return val
        except StopIteration:
            return "0"

    def mock_getpass(prompt=""):
        return mock_input(prompt)

    try:
        with patch("builtins.input", mock_input), \
             patch("getpass.getpass", mock_getpass), \
             patch("sys.stdout", new_callable=StringIO):
            phantom.main_menu()

        passed("Full interactive flow completed without errors")
        results["pass"] += 1
    except SystemExit:
        passed("Full interactive flow completed (sys.exit)")
        results["pass"] += 1
    except StopIteration:
        passed("Full interactive flow completed (all inputs consumed)")
        results["pass"] += 1
    except Exception as e:
        failed(f"Interactive flow failed: {type(e).__name__}: {e}")
        results["fail"] += 1

    return results


# ─── Test 8: Deployment Discovery (manage_menu) ─────────────────────────────

def test_deployment_discovery():
    header("Test 8: Deployment Discovery")
    import phantom
    results = {"pass": 0, "fail": 0}

    # Create a temporary deployment info file
    test_id = "testdiscovery01"
    info_file = phantom.PHANTOM_LOGS / f"deployment_info_{test_id}.txt"
    try:
        with open(info_file, "w") as f:
            f.write("Deployment Information\n")
            f.write("=" * 50 + "\n")
            f.write(f"Deployment ID: {test_id}\n")
            f.write("Provider: linode\n")
            f.write("Deployment Type: phantom_matrix\n")
            f.write("\nConfiguration:\n")
            f.write("-" * 30 + "\n")
            f.write("domain: test.example.com\n")
            f.write("\nAccess Information:\n")
            f.write("-" * 30 + "\n")
            f.write("Instance IP: 10.0.0.99\n")

        # Test parsing
        data = phantom._parse_deployment_info(info_file)
        checks = [
            ("deployment_id", test_id),
            ("deployment_type", "phantom_matrix"),
            ("ip", "10.0.0.99"),
            ("domain", "test.example.com"),
        ]
        for field, expected in checks:
            if data.get(field) == expected:
                passed(f"Parsed {field}: {expected}")
                results["pass"] += 1
            else:
                failed(f"Parse {field}: got '{data.get(field)}', expected '{expected}'")
                results["fail"] += 1

    except Exception as e:
        failed(f"Discovery test failed: {e}")
        results["fail"] += 1
    finally:
        if info_file.exists():
            info_file.unlink()
        print(f"    {GREY}cleaned up test info file{RESET}")

    return results


# ─── Test 9: Mode-Aware Log Paths ───────────────────────────────────────────

def test_mode_aware_paths():
    header("Test 9: Mode-Aware Log Paths")
    import phantom
    results = {"pass": 0, "fail": 0}

    c2_root = Path.home() / "tools" / "c2itall"
    c2_integrated = os.environ.get("C2ITALL_INTEGRATED") == "1"

    if c2_integrated:
        expected_logs = c2_root / "logs"
        mode_desc = "c2itall integrated"
    else:
        expected_logs = phantom.BASE_DIR / "logs"
        mode_desc = "standalone"

    if phantom.PHANTOM_LOGS == expected_logs:
        passed(f"PHANTOM_LOGS correct for {mode_desc} mode: {expected_logs}")
        results["pass"] += 1
    else:
        failed(f"PHANTOM_LOGS wrong: {phantom.PHANTOM_LOGS} (expected {expected_logs})")
        results["fail"] += 1

    # WORK_DIR should always be local
    if phantom.WORK_DIR == phantom.BASE_DIR / "logs":
        passed(f"WORK_DIR correct: {phantom.WORK_DIR}")
        results["pass"] += 1
    else:
        failed(f"WORK_DIR wrong: {phantom.WORK_DIR}")
        results["fail"] += 1

    return results


# ─── Test 10: Config Key Rename ──────────────────────────────────────────────

def test_config_key_rename():
    header("Test 10: Config Key Rename (deployment_id)")
    import phantom
    results = {"pass": 0, "fail": 0}

    # deploy() should use deployment_id, not deploy_id
    config = {
        "deployment_id": "testrename01",
        "provider": "local",
        "target_host": "localhost",
        "ssh_user": os.getenv("USER", "root"),
    }

    def mock_input(prompt=""):
        return "n"

    try:
        with patch("builtins.input", mock_input), \
             patch("sys.stdout", new_callable=StringIO) as mock_stdout:
            phantom.deploy("vpn", config)

        output = mock_stdout.getvalue()
        if "testrename01" in output:
            passed("deploy() accepts deployment_id key")
            results["pass"] += 1
        else:
            failed("deploy() didn't use deployment_id")
            results["fail"] += 1

    except KeyError as e:
        if "deploy_id" in str(e):
            failed(f"deploy() still looking for old 'deploy_id' key: {e}")
        else:
            failed(f"Unexpected KeyError: {e}")
        results["fail"] += 1
    except Exception as e:
        failed(f"Config key rename test failed: {e}")
        results["fail"] += 1

    return results


# ─── Main ────────────────────────────────────────────────────────────────────

def main():
    print(f"""
{MAGENTA}    ██████╗ ██╗  ██╗ █████╗ ███╗   ██╗████████╗ ██████╗ ███╗   ███╗
    ██╔══██╗██║  ██║██╔══██╗████╗  ██║╚══██╔══╝██╔═══██╗████╗ ████║
    ██████╔╝███████║███████║██╔██╗ ██║   ██║   ██║   ██║██╔████╔██║
    ██╔═══╝ ██╔══██║██╔══██║██║╚██╗██║   ██║   ██║   ██║██║╚██╔╝██║
    ██║     ██║  ██║██║  ██║██║ ╚████║   ██║   ╚██████╔╝██║ ╚═╝ ██║
    ╚═╝     ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝   ╚═╝    ╚═════╝ ╚═╝     ╚═╝{RESET}
{CYAN}                      Test Suite{RESET}
""")

    all_results = {"pass": 0, "fail": 0}

    tests = [
        test_imports,
        test_id_generation,
        test_playbook_syntax,
        test_gather_config,
        test_deploy_pipeline,
        test_integrated_provider_dispatch,
        test_secret_display_redaction,
        test_ssh_keygen,
        test_interactive_flow,
        test_deployment_discovery,
        test_mode_aware_paths,
        test_config_key_rename,
    ]

    for test_fn in tests:
        try:
            r = test_fn()
            all_results["pass"] += r["pass"]
            all_results["fail"] += r["fail"]
        except Exception as e:
            print(f"\n  {RED}✗ {test_fn.__name__} crashed: {e}{RESET}")
            all_results["fail"] += 1

    # Summary
    total = all_results["pass"] + all_results["fail"]
    header("Results")
    print(f"  {GREEN}Passed: {all_results['pass']}{RESET}")
    if all_results["fail"]:
        print(f"  {RED}Failed: {all_results['fail']}{RESET}")
    else:
        print(f"  {GREY}Failed: 0{RESET}")
    print(f"  {CYAN}Total:  {total}{RESET}")

    if all_results["fail"] == 0:
        print(f"\n  {GREEN}{BOLD}ALL TESTS PASSED{RESET}\n")
    else:
        print(f"\n  {RED}{BOLD}{all_results['fail']} TEST(S) FAILED{RESET}\n")

    return 0 if all_results["fail"] == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
