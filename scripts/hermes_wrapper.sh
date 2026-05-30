#!/bin/bash
# 🦉 Hermes Agent - Secure Proxy Launcher Wrapper
set -euo pipefail

# Configuration (Change these to match your Hermes codebase paths)
HERMES_DIR="/home/x1/Documents/ubuntu-obsidian"
HERMES_CMD="python3" 
HERMES_SCRIPT="agent.py" # Replace with your primary Hermes execution script (e.g. main.py, cli.js, etc.)

# Styling
BOLD='\033[1m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

info()  { echo -e "${CYAN}➜${NC} $1"; }
ok()    { echo -e "${GREEN}✓${NC} $1"; }
warn()  { echo -e "${YELLOW}⚠${NC} $1"; }
err()   { echo -e "${RED}✗${NC} $1"; }

# ── 1. Resolve systemd command based on privilege level ────────────────────
SYSTEMCTL_CMD="systemctl --user"
CURL_PING_CMD="curl -sf"

if [[ "$EUID" -eq 0 ]]; then
    # If running under sudo/root, query systemd user services as the standard user
    SYSTEMCTL_CMD="sudo -u x1 systemctl --user"
fi

# ── 2. Check Background Proxy Dependency ───────────────────────────────────
if ! $SYSTEMCTL_CMD is-active --quiet owl-forward-proxy.service; then
    warn "OWL Forward Proxy service is not active. Attempting to start..."
    if ! $SYSTEMCTL_CMD start owl-forward-proxy.service; then
        err "Failed to start owl-forward-proxy.service! Verify configuration."
        exit 1
    fi
    sleep 1.5
fi

# ── 3. Verify Proxy Connection Health ──────────────────────────────────────
if ! $CURL_PING_CMD http://127.0.0.1:60000/_ping >/dev/null 2>&1; then
    err "OWL Forward Proxy is running but failed to respond to health ping on port 60000!"
    err "Please check status: $SYSTEMCTL_CMD status owl-forward-proxy.service"
    exit 1
fi

# ── 3. Enforce Proxy Environment (Isolated) ────────────────────────────────
info "Enforcing isolated OWL Proxy environment..."
export HTTP_PROXY="http://127.0.0.1:60000"
export HTTPS_PROXY="http://127.0.0.1:60000"
export NO_PROXY="localhost,127.0.0.1,.local,.localdomain,::1"

# ── 5. Verify Upstream Kiro Health (Optional Alert) ───────────────────────
if ! curl -sf http://127.0.0.1:8333/health >/dev/null 2>&1; then
    warn "Local Kiro Gateway (port 8333) is unreachable! Some Anthropic model endpoints may fail."
    warn "Start it with: $SYSTEMCTL_CMD start kiro-gateway.service"
fi

# ── 5. Delegate Execution to Hermes Agent ─────────────────────────────────
info "Delegating execution to Hermes Agent..."
echo "  Command: $HERMES_CMD $HERMES_DIR/$HERMES_SCRIPT $*"
echo ""

# Navigate to target directory to preserve relative file paths in Obsidian
cd "$HERMES_DIR"

if [[ -f "$HERMES_SCRIPT" ]]; then
    exec "$HERMES_CMD" "$HERMES_SCRIPT" "$@"
else
    # Fallback to general execution if no specific script matches
    warn "Specified script '$HERMES_SCRIPT' not found in $HERMES_DIR. Running fallback shell..."
    echo "  Hint: Edit /home/x1/.local/bin/hermes to specify your exact startup script."
    echo ""
    exec bash
fi
