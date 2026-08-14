#!/bin/bash
# Standalone Ghost Protocol OPSEC installer.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec "$SCRIPT_DIR/scripts/opsec-install.sh" "$@"
