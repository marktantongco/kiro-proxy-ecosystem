#!/usr/bin/env bash
# 🦉 OWL-AGENT & OpenCode Proxy Diagnostic & Recovery Tool
# This script rules out routing, port conflicts, socket mismatches, and proxy locks.

set -u

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0;3m' # No Color
BOLD='\033[1m'

echo -e "${BLUE}${BOLD}================================================================${NC}"
echo -e "${BLUE}${BOLD}🦉 OWL-AGENT & OpenCode Proxy Diagnostic & Recovery Tool v1.0${NC}"
echo -e "${BLUE}${BOLD}================================================================${NC}"

# ---- Helper: Check if port is listening ----
check_port() {
    local port=$1
    local name=$2
    if ss -tulpn 2>/dev/null | grep -q ":$port "; then
        echo -e "  [${GREEN}ONLINE${NC}] Port ${BOLD}$port${NC} ($name)"
        return 0
    else
        echo -e "  [${RED}OFFLINE${NC}] Port ${BOLD}$port${NC} ($name)"
        return 1
    fi
}

# ---- Helper: Run curl check through proxy ----
check_curl() {
    local url=$1
    local proxy=$2
    local name=$3
    
    echo -n "  Testing $name ($url)... "
    local code
    if [ -n "$proxy" ]; then
        code=$(curl -s -o /dev/null -w "%{http_code}" -x "$proxy" --connect-timeout 5 "$url" 2>/dev/null || echo "FAILED")
    else
        code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 "$url" 2>/dev/null || echo "FAILED")
    fi
    
    if [ "$code" = "200" ] || [ "$code" = "401" ] || [ "$code" = "402" ] || [ "$code" = "403" ] || [ "$code" = "301" ] || [ "$code" = "302" ]; then
        echo -e "[${GREEN}PASS${NC}] (HTTP Status: $code)"
        return 0
    else
        echo -e "[${RED}FAIL${NC}] (HTTP Status: $code)"
        return 1
    fi
}

# ==============================================================================
# STAGE 1: PORT AND SERVICE CHECKS
# ==============================================================================
echo -e "\n${BOLD}[1/4] Checking Core Services & Listening Ports:${NC}"
SERVICES_OK=0

check_port 60000 "OWL Forward Proxy" || SERVICES_OK=1
check_port 7890 "Mihomo/Clash Upstream" || SERVICES_OK=1
check_port 20128 "9Router Free AI Gateway" || SERVICES_OK=1
check_port 8082 "FCC (Free Claude Code Proxy)" || SERVICES_OK=1
check_port 8333 "Kiro Gateway" || SERVICES_OK=1
check_port 48321 "Kiro Token Refresh Daemon" || SERVICES_OK=1

if [ $SERVICES_OK -ne 0 ]; then
    echo -e "${YELLOW}⚠️  Some background services are offline. Attempting automated restart...${NC}"
    systemctl --user daemon-reload
    systemctl --user restart owl-forward-proxy 9router fcc kiro-tokend kiro-gateway 2>/dev/null
    sleep 2
    echo -e "${BLUE}Re-evaluating services...${NC}"
    SERVICES_OK=0
    check_port 60000 "OWL Forward Proxy" || SERVICES_OK=1
    check_port 7890 "Mihomo/Clash Upstream" || SERVICES_OK=1
    check_port 20128 "9Router" || SERVICES_OK=1
fi

# ==============================================================================
# STAGE 2: UNIX DOMAIN SOCKET HEALTH
# ==============================================================================
echo -e "\n${BOLD}[2/4] Checking Terminal Unix Sockets (Kiro Integration):${NC}"
SOCKET_DIR="/run/user/$(id -u)/kirorun/t"

if [ -n "${QTERM_SESSION_ID:-}" ]; then
    echo -e "  Current Shell Session ID: ${BOLD}$QTERM_SESSION_ID${NC}"
    EXPECTED_SOCKET="$SOCKET_DIR/$QTERM_SESSION_ID.sock"
    if [ -S "$EXPECTED_SOCKET" ]; then
        echo -e "  [${GREEN}OK${NC}] Active Unix socket found at: $EXPECTED_SOCKET"
    else
        echo -e "  [${RED}FAIL${NC}] Socket file NOT found: $EXPECTED_SOCKET"
        echo -e "  ${YELLOW}→ Root Cause: Your shell has a stale/orphaned session ID.${NC}"
        echo -e "  ${YELLOW}→ Resolution: Please open a NEW terminal window/tab to re-bind Kiro-CLI.${NC}"
    fi
else
    echo -e "  [${YELLOW}INFO${NC}] QTERM_SESSION_ID is not set in this environment (Normal for non-interactive runners)."
fi

# Show any active sockets that exist
echo "  Active mounted sockets in directory:"
ls -la "$SOCKET_DIR" 2>/dev/null | grep ".sock" || echo "  (None found)"

# ==============================================================================
# STAGE 3: INTERNET & MODEL PROVIDER CONNECTIVITY
# ==============================================================================
echo -e "\n${BOLD}[3/4] Testing HTTP/HTTPS Tunneling & Bypass Routing:${NC}"
CONNECT_OK=0

# Test general connectivity through proxy
check_curl "https://www.google.com" "http://127.0.0.1:60000" "Google Connect" || CONNECT_OK=1

# Test NVIDIA NIM bypass routing (ensuring it avoids Mihomo/Clash)
check_curl "https://integrate.api.nvidia.com/v1/models" "http://127.0.0.1:60000" "NVIDIA Bypass Route" || CONNECT_OK=1

# Test OpenCode Zen bypass routing (ensuring it avoids Mihomo/Clash)
check_curl "https://opencode.ai/zen/v1/models" "http://127.0.0.1:60000" "OpenCode Zen Bypass Route" || CONNECT_OK=1

if [ $CONNECT_OK -eq 0 ]; then
    echo -e "\n${GREEN}${BOLD}🎉 ALL SYSTEMS GREEN! The proxy stack is working flawlessly.${NC}"
else
    echo -e "\n${RED}${BOLD}❌ Connection tests failed. Check forward-proxy logs for traceback:${NC}"
    tail -n 20 "$HOME/.owl-agent/logs/forward-proxy.log"
fi

# ==============================================================================
# STAGE 4: ENV AND CONFIG AUDIT
# ==============================================================================
echo -e "\n${BOLD}[4/4] Auditing Environment Variables:${NC}"
echo "  HTTP_PROXY=${HTTP_PROXY:-Unset}"
echo "  HTTPS_PROXY=${HTTPS_PROXY:-Unset}"
echo "  NO_PROXY=${NO_PROXY:-Unset}"

# Verify NO_PROXY remains clean to avoid leaks
if [[ "${NO_PROXY:-}" != "localhost,127.0.0.1,.local,.localdomain,::1" ]]; then
    echo -e "  [${YELLOW}WARNING${NC}] NO_PROXY is modified. Keep it clean to prevent leaks."
fi

echo -e "${BLUE}${BOLD}================================================================${NC}"
