#!/bin/bash
# 🦉 Kiro Gateway - Terminal Launcher & Controller
set -euo pipefail

GATEWAY_DIR="/home/x1/Documents/proxy/kiro-gateway"
VENV_PYTHON="$GATEWAY_DIR/.venv/bin/python"
MAIN_PY="$GATEWAY_DIR/main.py"
DEFAULT_PORT=8333

# Check if target main.py exists
if [[ ! -f "$MAIN_PY" ]]; then
    echo "Error: Kiro Gateway main.py not found at $MAIN_PY" >&2
    exit 1
fi

# Function to check if background service is active
check_service() {
    if systemctl --user is-active --quiet kiro-gateway.service; then
        echo "⚠️  Kiro Gateway is currently running in the background as a systemd service." >&2
        echo "   To run it in the foreground, stop the background service first:" >&2
        echo "   $ systemctl --user stop kiro-gateway.service" >&2
        echo "" >&2
        echo "   Showing current background logs (Ctrl+C to exit):" >&2
        exec journalctl --user -u kiro-gateway.service -f -n 20
    fi
}

# If no arguments are passed, do a quick service check
if [[ $# -eq 0 ]]; then
    check_service
fi

# Run the python gateway main script
echo "➜ Launching Kiro Gateway manually..."
exec "$VENV_PYTHON" "$MAIN_PY" "$@"
