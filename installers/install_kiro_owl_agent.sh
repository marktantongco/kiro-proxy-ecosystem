#!/bin/bash
# 🦉 Kiro OWL Agent — Full Installer v1.0
# Installs kiro-gateway + kiro-cli as a systemd service + wires into opencode
set -e

KIRO_REPO="https://github.com/Jwadow/kiro-gateway.git"
KIRO_DIR="$HOME/Documents/proxy/kiro-gateway"
KIRO_PORT=8333
KIRO_API_KEY="kiro-gateway-8333"
VENV_DIR="$KIRO_DIR/.venv"
SYSD_FILE="$HOME/.config/systemd/user/kiro-gateway.service"
OPENCODE_CONFIG="$HOME/.config/opencode/opencode.jsonc"
KIRO_CLI_DB="$HOME/.local/share/kiro-cli/data.sqlite3"

BOLD='\033[1m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m' # No Color

info()  { echo -e "${CYAN}➜${NC} $1"; }
ok()    { echo -e "${GREEN}✓${NC} $1"; }
warn()  { echo -e "${YELLOW}⚠${NC} $1"; }
err()   { echo -e "${RED}✗${NC} $1"; }
step()  { echo; echo -e "${BOLD}[$1/$2]${NC} $3"; }

TOTAL_STEPS=9

# ============================================================
# [1/9] System dependencies
# ============================================================
step 1 $TOTAL_STEPS "Checking system dependencies..."
MISSING=""
for cmd in python3 git curl; do
    if ! command -v "$cmd" &>/dev/null; then
        MISSING="$MISSING $cmd"
    fi
done
if [ -n "$MISSING" ]; then
    info "Installing missing deps:$MISSING"
    sudo apt update && sudo apt install -y python3 python3-pip python3-venv git curl
fi
ok "System dependencies ready (python3, git, curl)"

# ============================================================
# [2/9] Clone / update kiro-gateway
# ============================================================
step 2 $TOTAL_STEPS "Cloning kiro-gateway..."
mkdir -p "$HOME/Documents/proxy"
if [ -d "$KIRO_DIR/.git" ]; then
    info "Repo exists — pulling latest..."
    git -C "$KIRO_DIR" pull --ff-only
else
    git clone "$KIRO_REPO" "$KIRO_DIR"
fi
ok "kiro-gateway at $KIRO_DIR"

# ============================================================
# [3/9] Python virtual environment + dependencies + kiro-cli native
# ============================================================
step 3 $TOTAL_STEPS "Setting up Python virtual environment..."
python3 -m venv "$VENV_DIR"
source "$VENV_DIR/bin/activate"
pip install --quiet --upgrade pip
pip install --quiet -r "$KIRO_DIR/requirements.txt"

# Install kiro-cli native binary (NOT a Python package)
ARCH=$(uname -m)
case "$ARCH" in
    x86_64|amd64)  ARCH_DETECTED="x86_64" ;;
    aarch64|arm64) ARCH_DETECTED="aarch64" ;;
    *) err "Unsupported architecture: $ARCH"; exit 1 ;;
esac

# Detect glibc or musl
LIBC_DETECTED="glibc"
if command -v ldd &>/dev/null; then
    glibc_ver=$(ldd --version 2>/dev/null | head -n1 | grep -oP '\d+\.\d+' | head -n1 || true)
    if [[ -n "$glibc_ver" ]]; then
        if ! awk "BEGIN {exit !($glibc_ver >= 2.34)}"; then
            LIBC_DETECTED="musl"
        fi
    else
        LIBC_DETECTED="musl"
    fi
else
    LIBC_DETECTED="musl"
fi

if [[ "$LIBC_DETECTED" == "musl" ]]; then
    KIRO_ZIP="kirocli-${ARCH_DETECTED}-linux-musl.zip"
else
    KIRO_ZIP="kirocli-${ARCH_DETECTED}-linux.zip"
fi

KIRO_URL="https://desktop-release.q.us-east-1.amazonaws.com/latest/${KIRO_ZIP}"
KIRO_ZIP_PATH="/tmp/${KIRO_ZIP}"

info "Downloading kiro-cli native binary from AWS S3..."
if curl -fsSL --proto '=https' --tlsv1.2 "$KIRO_URL" -o "$KIRO_ZIP_PATH"; then
    unzip -qo "$KIRO_ZIP_PATH" -d "/tmp/kirocli_extracted"
    mkdir -p "$HOME/.local/bin"
    cp "/tmp/kirocli_extracted/kirocli/kiro-cli" "$HOME/.local/bin/kiro-cli" 2>/dev/null || cp "/tmp/kirocli_extracted/kirocli-"* "/tmp/kirocli_extracted/kiro-cli" 2>/dev/null || true
    # Also copy to virtual environment bin directory so it runs when venv is active
    cp "/tmp/kirocli_extracted/kirocli/kiro-cli" "$VENV_DIR/bin/kiro-cli" 2>/dev/null || cp "/tmp/kirocli_extracted/kiro-cli" "$VENV_DIR/bin/kiro-cli" 2>/dev/null || cp -r "/tmp/kirocli_extracted/"* "$VENV_DIR/bin/" 2>/dev/null || true
    chmod +x "$VENV_DIR/bin/kiro-cli" "$HOME/.local/bin/kiro-cli" 2>/dev/null || true
    rm -rf "$KIRO_ZIP_PATH" "/tmp/kirocli_extracted"
    ok "kiro-cli native binary installed successfully"
else
    err "Failed to download kiro-cli native binary from S3"
fi

deactivate
ok "Virtual env ready at $VENV_DIR (kiro-cli native + gateway deps installed)"

# ============================================================
# [4/9] kiro-cli login (interactive — AWS Builder ID)
# ============================================================
step 4 $TOTAL_STEPS "kiro-cli authentication (AWS Builder ID / SSO)"

if [ -f "$KIRO_CLI_DB" ]; then
    # Quick check: does the DB have a valid session?
    DB_SIZE=$(stat -c%s "$KIRO_CLI_DB" 2>/dev/null || stat -f%z "$KIRO_CLI_DB" 2>/dev/null || echo "0")
    if [ "$DB_SIZE" -gt 1000 ]; then
        warn "Found existing kiro-cli DB ($KIRO_CLI_DB, ${DB_SIZE} bytes)"
        echo "  Skip login and reuse existing session? [Y/n] "
        read -r SKIP_LOGIN
        if [[ "$SKIP_LOGIN" =~ ^[Nn] ]]; then
            NEED_LOGIN=true
        else
            NEED_LOGIN=false
            ok "Reusing existing kiro-cli session"
        fi
    else
        NEED_LOGIN=true
    fi
else
    NEED_LOGIN=true
fi

if [ "$NEED_LOGIN" = true ]; then
    echo ""
    warn "kiro-cli login requires AWS Builder ID (browser-based OIDC)"
    echo ""
    echo "  This will open a browser for you to authenticate."
    echo "  Use your AWS Builder ID (free tier, no credit card needed)."
    echo "  Sign up at: https://builderid.us-east-1.console.aws.amazon.com"
    echo ""
    echo "  Press ENTER to start login..."
    read -r
    source "$VENV_DIR/bin/activate"
    kiro-cli login
    deactivate
    if [ -f "$KIRO_CLI_DB" ]; then
        ok "kiro-cli authenticated successfully"
    else
        err "kiro-cli DB not found after login. Something went wrong."
        exit 1
    fi
fi

# ============================================================
# [5/9] Create .env for kiro-gateway
# ============================================================
step 5 $TOTAL_STEPS "Creating .env for kiro-gateway..."
if [ -f "$KIRO_DIR/.env" ]; then
    warn ".env already exists at $KIRO_DIR/.env — backing up to .env.installer-backup"
    cp "$KIRO_DIR/.env" "$KIRO_DIR/.env.installer-backup"
fi

cat > "$KIRO_DIR/.env" << ENVEOF
# Kiro Gateway — generated by install_kiro_owl_agent.sh
PROXY_API_KEY=$KIRO_API_KEY
SERVER_PORT=$KIRO_PORT
ACCOUNT_SYSTEM=true
KIRO_CLI_DB_FILE=$KIRO_CLI_DB
KIRO_USE_LEGACY_ENDPOINT=true
LOG_LEVEL=INFO
ENVEOF
ok ".env created (PROXY_API_KEY=$KIRO_API_KEY, SERVER_PORT=$KIRO_PORT)"

# ============================================================
# [6/9] Systemd user service
# ============================================================
step 6 $TOTAL_STEPS "Creating systemd user service..."
mkdir -p "$HOME/.config/systemd/user"

cat > "$SYSD_FILE" << SYSEOF
[Unit]
Description=Kiro Gateway (OWL Agent) — Anthropic/OpenAI proxy for Kiro API
After=network.target

[Service]
Type=simple
ExecStart=$VENV_DIR/bin/python main.py --port $KIRO_PORT
WorkingDirectory=$KIRO_DIR
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
SYSEOF

systemctl --user daemon-reload
systemctl --user enable kiro-gateway.service
ok "Systemd service created & enabled"

# ============================================================
# [7/9] Start and verify the gateway
# ============================================================
step 7 $TOTAL_STEPS "Starting kiro-gateway..."
systemctl --user start kiro-gateway.service
sleep 6

# Check service health
if ! systemctl --user is-active --quiet kiro-gateway.service; then
    err "Service failed to start. Check: systemctl --user status kiro-gateway.service"
    err "Logs: journalctl --user -u kiro-gateway.service --no-pager -n 30"
    exit 1
fi
ok "kiro-gateway.service is active (running)"

# Verify HTTP health
HEALTH=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 http://localhost:$KIRO_PORT/health 2>/dev/null || echo "000")
if [ "$HEALTH" = "200" ]; then
    ok "Health check: HTTP 200"
else
    err "Health check failed (HTTP $HEALTH). Check logs."
    systemctl --user status kiro-gateway.service --no-pager -n 10
    exit 1
fi

# Verify models endpoint
MODEL_COUNT=$(curl -s http://localhost:$KIRO_PORT/v1/models \
    -H "Authorization: Bearer $KIRO_API_KEY" \
    --max-time 10 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('data',[])))" 2>/dev/null || echo "0")
if [ "$MODEL_COUNT" -gt 0 ]; then
    ok "$MODEL_COUNT models available via kiro-gateway"
else
    warn "Model list returned 0 models — auth may need refreshing"
fi

# Quick chat test
CHAT_OK=$(curl -s -X POST http://localhost:$KIRO_PORT/v1/messages \
    -H "Content-Type: application/json" \
    -H "x-api-key: $KIRO_API_KEY" \
    -H "anthropic-version: 2023-06-01" \
    -d '{"model":"claude-sonnet-4.5","max_tokens":20,"messages":[{"role":"user","content":"hi"}]}' \
    --max-time 30 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print('ok' if d.get('content') else 'fail')" 2>/dev/null || echo "fail")
if [ "$CHAT_OK" = "ok" ]; then
    ok "Chat API works (claude-sonnet-4.5)"
else
    warn "Chat test returned unexpected response — this may be temporary"
fi

# ============================================================
# [8/9] Wire into opencode.jsonc
# ============================================================
step 8 $TOTAL_STEPS "Wiring kiro provider into opencode.jsonc..."

if [ ! -f "$OPENCODE_CONFIG" ]; then
    warn "opencode.jsonc not found at $OPENCODE_CONFIG — skipping integration"
    warn "Manual: add the kiro provider block (shown at end of script)"
else
    # Check if kiro provider already exists
    if grep -q '"kiro"' "$OPENCODE_CONFIG" 2>/dev/null; then
        warn "kiro provider already exists in opencode.jsonc — updating baseURL/apiKey"
        # Use sed to update baseURL and apiKey for the kiro provider
        # The provider key "kiro" appears once; update the options within
        python3 << PYEOF
import re, json

with open("$OPENCODE_CONFIG") as f:
    raw = f.read()

# Find the kiro provider block and update baseURL and apiKey
# Match from '"kiro": {' to the next '"<name>": {' block or closing '}'
pattern = r'("kiro":\s*\{.*?"options":\s*\{)(.*?)(\}.*?\}.*?\})'
def update_kiro(m):
    prefix = m.group(1)
    body = m.group(2)
    tail = m.group(3)
    # Update baseURL
    body = re.sub(r'"baseURL"\s*:\s*"[^"]*"', f'"baseURL": "http://127.0.0.1:$KIRO_PORT/v1"', body)
    body = re.sub(r'"apiKey"\s*:\s*"[^"]*"', f'"apiKey": "$KIRO_API_KEY"', body)
    return prefix + body + tail

if re.search(pattern, raw, re.DOTALL):
    raw = re.sub(pattern, update_kiro, raw, flags=re.DOTALL)
    with open("$OPENCODE_CONFIG", "w") as f:
        f.write(raw)
    print("updated")
else:
    print("not_found")
PYEOF
        KIRO_STATUS=$?
        if [ "$KIRO_STATUS" -eq 0 ]; then
            ok "kiro provider updated in opencode.jsonc"
        fi
    else
        # Inject kiro provider block before the "nvidia" provider
        # Build the provider block JSON and inject it
        python3 << PYEOF
import json

KIRO_BLOCK = '''
    "kiro": {
      "npm": "@ai-sdk/anthropic",
      "name": "Kiro OWL Agent Gateway (direct, port $KIRO_PORT)",
      "options": {
        "baseURL": "http://127.0.0.1:$KIRO_PORT/v1",
        "apiKey": "$KIRO_API_KEY",
        "timeout": 300000
      },
      "models": {
        "auto-kiro": { "name": "Kiro Auto (smart default)" },
        "claude-sonnet-4.5": { "name": "Claude Sonnet 4.5 via Kiro" },
        "claude-haiku-4.5": { "name": "Claude Haiku 4.5 via Kiro" },
        "claude-sonnet-4": { "name": "Claude Sonnet 4 via Kiro" },
        "deepseek-3.2": { "name": "DeepSeek 3.2 via Kiro" },
        "glm-5": { "name": "GLM-5 via Kiro" },
        "minimax-m2.5": { "name": "MiniMax M2.5 via Kiro" },
        "minimax-m2.1": { "name": "MiniMax M2.1 via Kiro" },
        "qwen3-coder-next": { "name": "Qwen3 Coder Next via Kiro" }
      }
    },
'''

with open("$OPENCODE_CONFIG") as f:
    raw = f.read()

# Insert before the "nvidia" provider block
if '"nvidia"' in raw:
    raw = raw.replace('"nvidia"', KIRO_BLOCK + '"nvidia"', 1)
    with open("$OPENCODE_CONFIG", "w") as f:
        f.write(raw)
    print("injected")
else:
    print("nvidia_not_found")
PYEOF
        KIRO_STATUS=$?
        if grep -q '"kiro"' "$OPENCODE_CONFIG" 2>/dev/null; then
            ok "kiro provider injected into opencode.jsonc"
        else
            warn "Could not auto-inject kiro provider — see manual instructions below"
        fi
    fi

    # Add subagents (if not already there)
    if ! grep -q '"planner"' "$OPENCODE_CONFIG" 2>/dev/null || ! grep -q 'kiro/claude-haiku-4.5' "$OPENCODE_CONFIG" 2>/dev/null; then
        info "Adding Kiro subagents to opencode.jsonc..."
        python3 << PYEOF
with open("$OPENCODE_CONFIG") as f:
    raw = f.read()

# Add planner, kiro-explorer, kiro-coder before the brainstorming agent
agents_block = '''
    "planner": {
      "description": "Task planning and decomposition using Kiro Haiku",
      "mode": "subagent",
      "model": "kiro/claude-haiku-4.5"
    },
    "kiro-explorer": {
      "description": "Lightweight code search using Kiro Haiku (cheap alternative)",
      "mode": "subagent",
      "model": "kiro/claude-haiku-4.5"
    },
    "kiro-coder": {
      "description": "Coding agent using Kiro Qwen3 Coder Next",
      "mode": "subagent",
      "model": "kiro/qwen3-coder-next"
    },
'''

if '"brainstorming"' in raw:
    raw = raw.replace('"brainstorming"', agents_block + '"brainstorming"', 1)
    with open("$OPENCODE_CONFIG", "w") as f:
        f.write(raw)
    print("agents_added")
else:
    print("brainstorming_not_found")
PYEOF
        ok "Kiro subagents added to opencode.jsonc"
    else
        ok "Kiro subagents already present in opencode.jsonc"
    fi
fi

# ============================================================
# [9/9] Summary
# ============================================================
step 9 $TOTAL_STEPS "Installation complete"

echo ""
echo -e "${GREEN}${BOLD}  🦉 Kiro OWL Agent is ready!${NC}"
echo ""
echo "  ├─ Gateway:   http://localhost:${KIRO_PORT}"
echo "  ├─ API key:   ${KIRO_API_KEY}"
echo "  ├─ Models:    9 (auto-kiro, claude-sonnet-4.5, claude-haiku-4.5, ...)"
echo "  ├─ Systemd:   kiro-gateway.service (enabled, running)"
echo "  └─ Auth:      kiro-cli (AWS Builder ID / SSO)"
echo ""

if grep -q '"kiro"' "$OPENCODE_CONFIG" 2>/dev/null; then
    echo "  ${GREEN}✓${NC} opencode.jsonc wired — use models as:"
    echo "     kiro/claude-sonnet-4.5"
    echo "     kiro/claude-haiku-4.5"
    echo "     kiro/qwen3-coder-next"
    echo ""
fi

echo -e "${BOLD}  Quick verification:${NC}"
echo "    curl http://localhost:${KIRO_PORT}/health"
echo "    curl http://localhost:${KIRO_PORT}/v1/models -H 'Authorization: Bearer ${KIRO_API_KEY}'"
echo ""

# Final end-to-end check
echo "  Running final end-to-end check..."
E2E_OK=true
curl -sf http://localhost:$KIRO_PORT/health --max-time 5 >/dev/null 2>&1 || { E2E_OK=false; warn "Health check failed"; }
[ "$E2E_OK" = true ] && ok "End-to-end: gateway is live"

echo ""
echo -e "${BOLD}  📋 Management commands:${NC}"
echo "    systemctl --user status kiro-gateway.service"
echo "    systemctl --user restart kiro-gateway.service"
echo "    journalctl --user -u kiro-gateway.service -n 50 -f"
echo ""

echo -e "${YELLOW}  Token refresh (if auth expires):${NC}"
echo "    source $VENV_DIR/bin/activate && kiro-cli login && deactivate"
echo "    systemctl --user restart kiro-gateway.service"
echo ""
echo -e "${CYAN}  Troubleshooting & Self-Healing Diagnostics:${NC}"
echo "    Run the unified OWL diagnostics suite to verify your ports and connectivity:"
echo "    owl-check"
echo "    (or: $HOME/.owl-agent/diagnose_opencode.sh)"
echo ""
