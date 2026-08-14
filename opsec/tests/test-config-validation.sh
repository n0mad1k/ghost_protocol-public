#!/bin/bash

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
. "$ROOT/lib/opsec-lib.sh"

accept() { opsec_validate_config_value "$1" "$2" || { echo "FAIL accept: $1=$2" >&2; exit 1; }; }
reject() { ! opsec_validate_config_value "$1" "$2" || { echo "FAIL reject: $1=$2" >&2; exit 1; }; }

accept TOR_SOCKS_PORT 9050
accept TOR_CIRCUIT_ROTATION ""
accept TOR_BLACKLIST ""
accept TOR_BLACKLIST us,de
accept KILLSWITCH_EXTRA_PORTS tcp:443,udp:53
accept HOSTNAME_CUSTOM_PREFIX public-client
accept MAC_INTERFACES auto
accept MAC_INTERFACES enp1s0,wlan0
accept TOR_BRIDGE_RELAY 'obfs4 192.0.2.1:443 ABC cert=xyz iat-mode=0'

reject TOR_SOCKS_PORT 0
reject TOR_DNS_PORT 65536
reject TOR_CIRCUIT_ROTATION 2
reject TOR_BLACKLIST 'us,{de}'
reject KILLSWITCH_EXTRA_PORTS 'tcp:443;accept'
reject KILLSWITCH_EXTRA_PORTS udp:70000
reject HOSTNAME_CUSTOM_PREFIX '-bad'
reject HOSTNAME_CUSTOM_PREFIX 'bad prefix'
reject MAC_INTERFACES 'wlan0;reboot'
reject TOR_BRIDGE_RELAY $'bridge\nSocksPort 0.0.0.0:9050'
reject UNKNOWN_KEY value

echo "PASS: semantic configuration validation"
