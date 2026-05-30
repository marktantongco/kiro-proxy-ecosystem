#!/bin/bash
# 🦉 Kiro/OWL Proxy Ecosystem - Validator & Auto-Patch Script
# Audits port bindings, detects duplicate processes, validates systemd units, and self-heals alignment issues.
set -euo pipefail

# Style Definitions
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
step()  { echo; echo -e "${BOLD}[$1]${NC} $2"; }

echo ""
echo -e "${BOLD}  🦉 Proxy Ecosystem - System Diagnostic & Self-Healing Patch${NC}"
echo "  ───────────────────────────────────────────────────────────────"

# ═══════════════════════════════════════════════════════════════════════════
# [1/5] Audit Active Shell Environment Variables
# ═══════════════════════════════════════════════════════════════════════════
step "1" "Auditing Shell Proxy Environment Variables..."

# Lowercase conflicts check
DEAD_PORT=2080
for var in http_proxy https_proxy all_proxy; do
    if env | grep -qi "^${var}="; then
        val=$(env | grep -i "^${var}=" | cut -d= -f2)
        if [[ "$val" == *"$DEAD_PORT"* ]]; then
            warn "Found conflicting lowercase '$var' pointing to dead port $DEAD_PORT!"
            warn "  Current value: $val"
            warn "  Recommended action: Unset or point to OWL proxy (port 60000) or Clash (port 7890)."
        else
            ok "Lowercase variable '$var' is clean (does not point to dead port $DEAD_PORT)."
        fi
    fi
done

# Enforce active uppercase variables
if env | grep -q "^HTTP_PROXY="; then
    ok "HTTP_PROXY is defined: $(env | grep "^HTTP_PROXY=" | cut -d= -f2)"
else
    warn "HTTP_PROXY environment variable is missing in this terminal shell!"
fi
if env | grep -q "^HTTPS_PROXY="; then
    ok "HTTPS_PROXY is defined: $(env | grep "^HTTPS_PROXY=" | cut -d= -f2)"
else
    warn "HTTPS_PROXY environment variable is missing in this terminal shell!"
fi

# ═══════════════════════════════════════════════════════════════════════════
# [2/5] Audit Port Bindings & Triage Duplicate Processes
# ═══════════════════════════════════════════════════════════════════════════
step "2" "Auditing Active Port Bindings & Process Health..."

# Clash (mihomo) check
if ss -tulpn | grep -q ":7890 "; then
    ok "Clash core (mihomo) is listening on port 7890."
else
    warn "Clash core (mihomo) is NOT listening on port 7890! Geo-routing upstream will fail."
fi

# OWL Forward Proxy duplicate check
if ss -tulpn | grep -q ":60000 "; then
    ok "OWL Forward Proxy is bound to port 60000."
    # Check if run manually or by systemd
    PID=$(pgrep -f "forward_proxy.py" | head -n1 || true)
    if [[ -n "$PID" ]]; then
        PARENT_PID=$(ps -p "$PID" -o ppid= | tr -d ' ' || true)
        PARENT_COMM=$(ps -o comm= -p "$PARENT_PID" 2>/dev/null | tr -d ' ' || true)
        if [[ "$PARENT_COMM" != "systemd" ]]; then
            warn "OWL Forward Proxy process (PID $PID) appears to be running manually!"
        fi
    fi
else
    warn "OWL Forward Proxy is NOT listening on port 60000!"
fi

# Kiro Gateway duplicate check
if ss -tulpn | grep -q ":8333 "; then
    ok "Kiro Gateway is bound to port 8333."
    # Find duplicate python processes that aren't systemd units
    PID=$(ss -tulpn | grep ":8333 " | grep -oP 'pid=\d+' | cut -d= -f2 || true)
    if [[ -n "$PID" ]]; then
        # Check if the parent is systemd or manual
        PARENT_PID=$(ps -p "$PID" -o ppid= | tr -d ' ' || true)
        PARENT_COMM=$(ps -o comm= -p "$PARENT_PID" 2>/dev/null | tr -d ' ' || true)
        if [[ "$PARENT_COMM" != "systemd" ]]; then
            warn "Duplicate manual Kiro Gateway detected! (PID: $PID, Parent COMM: $PARENT_COMM)"
            info "Killing manual process (PID $PID) to allow clean systemd service control..."
            kill -9 "$PID" || true
            ok "Duplicate process terminated."
        else
            ok "Kiro Gateway is running cleanly under systemd management (PID $PID)."
        fi
    fi
else
    warn "Kiro Gateway is NOT listening on port 8333! Background service may have crashed."
fi

# ═══════════════════════════════════════════════════════════════════════════
# [3/5] Validate and Align Systemd User Units
# ═══════════════════════════════════════════════════════════════════════════
step "3" "Validating & Repairing systemd Service Alignments..."

SYSTEMCTL_CMD="systemctl --user"
if [[ "$EUID" -eq 0 ]]; then
    SYSTEMCTL_CMD="sudo -u x1 systemctl --user"
fi

# 1. OWL Forward Proxy Service
if ! $SYSTEMCTL_CMD is-active --quiet owl-forward-proxy.service; then
    warn "owl-forward-proxy.service is inactive or failed! Attempting restart..."
    $SYSTEMCTL_CMD daemon-reload
    $SYSTEMCTL_CMD restart owl-forward-proxy.service
    sleep 1
    if $SYSTEMCTL_CMD is-active --quiet owl-forward-proxy.service; then
        ok "owl-forward-proxy.service successfully aligned and started."
    else
        err "Failed to align owl-forward-proxy.service! Verify logs: journalctl --user -u owl-forward-proxy.service"
    fi
else
    ok "owl-forward-proxy.service is active and healthy."
fi

# 2. Kiro Gateway Service
if ! $SYSTEMCTL_CMD is-active --quiet kiro-gateway.service; then
    warn "kiro-gateway.service is inactive or failed! Attempting restart..."
    $SYSTEMCTL_CMD daemon-reload
    $SYSTEMCTL_CMD restart kiro-gateway.service
    sleep 1
    if $SYSTEMCTL_CMD is-active --quiet kiro-gateway.service; then
        ok "kiro-gateway.service successfully aligned and started."
    else
        err "Failed to align kiro-gateway.service! Verify logs: journalctl --user -u kiro-gateway.service"
    fi
else
    ok "kiro-gateway.service is active and healthy."
fi

# ═══════════════════════════════════════════════════════════════════════════
# [4/5] Check & Verify Launcher Wrappers
# ═══════════════════════════════════════════════════════════════════════════
step "4" "Verifying Terminal Wrapper Configurations..."

# hermes wrapper check
HERMES_WRAP="/home/x1/.local/bin/hermes"
if [[ -f "$HERMES_WRAP" ]]; then
    if grep -q "export HTTP_PROXY=" "$HERMES_WRAP"; then
        ok "hermes wrapper is correctly synchronized to secure proxy (port 60000)."
    else
        warn "hermes wrapper is missing proxy variables! Patching now..."
        sed -i 's/# ── 3. Enforce Proxy Environment/export HTTP_PROXY="http:\/\/127.0.0.1:60000"\nexport HTTPS_PROXY="http:\/\/127.0.0.1:60000"\nexport NO_PROXY="localhost,127.0.0.1,.local,.localdomain,::1"\n# ── 3. Enforce Proxy/g' "$HERMES_WRAP"
        ok "hermes wrapper patched."
    fi
else
    warn "hermes wrapper not found at $HERMES_WRAP!"
fi

# antigravity wrapper check
AGY_WRAP="/home/x1/.local/bin/agy"
if [[ -f "$AGY_WRAP" ]]; then
    if grep -q "export HTTP_PROXY=" "$AGY_WRAP"; then
        ok "antigravity (agy) wrapper is correctly synchronized to secure proxy (port 60000)."
    else
        warn "antigravity (agy) wrapper is missing proxy variables! Please ensure it enforces proxy env."
    fi
else
    warn "antigravity (agy) wrapper not found at $AGY_WRAP!"
fi

# kiro-cli wrapper check
KIRO_WRAP="/home/x1/.owl-agent/kiro-cli"
if [[ -f "$KIRO_WRAP" ]]; then
    if grep -q "export HTTP_PROXY=" "$KIRO_WRAP"; then
        ok "kiro-cli wrapper is correctly synchronized to secure proxy (port 60000)."
    else
        warn "kiro-cli wrapper is missing proxy variables! Patching now..."
        sed -i '/#!/a export HTTP_PROXY="http://127.0.0.1:60000"\nexport HTTPS_PROXY="http://127.0.0.1:60000"\nexport NO_PROXY="localhost,127.0.0.1,.local,.localdomain,::1"\n' "$KIRO_WRAP"
        ok "kiro-cli wrapper patched."
    fi
else
    warn "kiro-cli wrapper not found at $KIRO_WRAP!"
fi

# ═══════════════════════════════════════════════════════════════════════════
# [5/5] Verify Connection Health (Active Ping)
# ═══════════════════════════════════════════════════════════════════════════
step "5" "Running End-to-End Active Connection Check..."

if curl -sf -I -x http://127.0.0.1:60000 https://www.google.com >/dev/null 2>&1; then
    ok "Active check: HTTP tunnel through OWL Proxy -> Clash -> Outside World is fully OPERATIONAL!"
else
    err "Active check: HTTP tunnel failed! Check your Clash (mihomo) connection."
fi

echo ""
echo "============================================="
echo -e "${GREEN}${BOLD}✅ Diagnostics & Healing Completed!${NC}"
echo "============================================="
echo "  Run this script at any time to self-heal your proxy stack."
echo "============================================="
echo ""
