#!/bin/bash
# 🦉 Antigravity Agent - Secure Proxy Launcher Wrapper
set -euo pipefail

# Configuration
AGY_REAL_PATH="/home/x1/.local/bin/agy.real"

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

# ── 4. Enforce Proxy Environment (Isolated) ────────────────────────────────
info "Enforcing isolated OWL Proxy environment for Antigravity..."
export HTTP_PROXY="http://127.0.0.1:60000"
export HTTPS_PROXY="http://127.0.0.1:60000"
export NO_PROXY="localhost,127.0.0.1,.local,.localdomain,::1"

# ── 5. Verify Upstream Kiro Health (Optional Alert) ───────────────────────
if ! curl -sf http://127.0.0.1:8333/health >/dev/null 2>&1; then
    warn "Local Kiro Gateway (port 8333) is unreachable! Some model translation endpoints may fail."
    warn "Start it with: $SYSTEMCTL_CMD start kiro-gateway.service"
fi

# ── 6. Delegate Execution to Antigravity CLI ──────────────────────────────
info "Delegating execution to Antigravity Real Binary..."

if [[ -f "$AGY_REAL_PATH" ]]; then
    exec "$AGY_REAL_PATH" "$@"
else
    err "Real Antigravity binary not found at $AGY_REAL_PATH!"
    err "Please ensure you have renamed the original 'agy' binary to 'agy.real'."
    exit 1
fi
