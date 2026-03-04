#!/bin/bash
# OPSEC Status Check

echo "===== OPSEC Status Check ====="
echo ""

# Check for running VPN
echo "[*] VPN Status:"
if pgrep -x openvpn > /dev/null; then
    echo "    [+] OpenVPN is running"
else
    echo "    [-] OpenVPN is NOT running"
fi

# Check for Tor
echo ""
echo "[*] Tor Status:"
if systemctl is-active tor >/dev/null 2>&1; then
    echo "    [+] Tor is running"
else
    echo "    [-] Tor is NOT running"
fi

# Check current connections
echo ""
echo "[*] Active Connections:"
CONNECTIONS=$(ss -tupn | grep ESTAB | wc -l)
echo "    [*] $CONNECTIONS established connections"

# Check listening services
echo ""
echo "[*] Listening Services:"
LISTENERS=$(ss -tupln | grep LISTEN | wc -l)
echo "    [*] $LISTENERS listening services"

# Check DNS
echo ""
echo "[*] DNS Configuration:"
grep "nameserver" /etc/resolv.conf | head -3

# Check for history files
echo ""
echo "[*] History Files:"
for hist in ~/.bash_history ~/.zsh_history ~/.python_history ~/.mysql_history; do
    if [ -f "$hist" ]; then
        SIZE=$(stat -c%s "$hist" 2>/dev/null)
        echo "    [!] $hist exists (size: $SIZE bytes)"
    fi
done

# Check MAC address
echo ""
echo "[*] Network Interfaces:"
for iface in $(ip -o link show | awk -F': ' '{print $2}' | grep -v lo); do
    MAC=$(ip link show $iface | awk '/ether/ {print $2}')
    echo "    [*] $iface: $MAC"
done

# Check timezone
echo ""
echo "[*] System Timezone:"
echo "    [*] $(timedatectl | grep "Time zone" | awk '{print $3}')"

# Check for running security tools
echo ""
echo "[*] Running Security Tools:"
# Tool inventory is configurable via OPSEC_TOOL_CHECK in opsec.conf
OPSEC_TOOL_CHECK="${OPSEC_TOOL_CHECK:-curl wget openssl gpg tor}"
for tool in $OPSEC_TOOL_CHECK; do
    if pgrep -f $tool > /dev/null; then
        echo "    [!] $tool is running"
    fi
done

echo ""
echo "===== Check Complete ====="