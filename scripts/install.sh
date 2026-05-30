#!/bin/bash
# 🦉 Kiro Stack — Unified Installer v1.1
# Installs: kiro-gateway (Python proxy) + kirolink (Go token/proxy) + kiro-cli auth
# Target: opencode TUI with direct kiro-gateway access + Claude Code via kirolink
set -euo pipefail

# ── Configuration ──────────────────────────────────────────────────────────
KIRO_GATEWAY_REPO="https://github.com/marktantongco/kiro-gateway.git"
KIROLINK_REPO="https://github.com/alexandeism/kirolink.git"

KIRO_DIR="$HOME/Documents/proxy/kiro-gateway"
KIROLINK_DIR="$HOME/Documents/proxy/kirolink"
KIRO_PORT=8333
KIROLINK_PORT=8080
KIRO_API_KEY="kiro-gateway-8333"
VENV_DIR="$KIRO_DIR/.venv"
SYSD_DIR="$HOME/.config/systemd/user"
GATEWAY_SERVICE="kiro-gateway.service"
KIROLINK_SERVICE="kirolink.service"
REFRESH_SERVICE="kiro-auth-refresh.service"
REFRESH_TIMER="kiro-auth-refresh.timer"
OPENCODE_CONFIG="$HOME/.config/opencode/opencode.jsonc"
KIRO_CLI_DB="$HOME/.local/share/kiro-cli/data.sqlite3"
TOKEN_FILE="$HOME/.aws/sso/cache/kiro-auth-token.json"
CUSTOM_MODELS="auto-kiro claude-sonnet-4.5 claude-haiku-4.5 claude-sonnet-4 deepseek-3.2 glm-5 minimax-m2.5 minimax-m2.1 qwen3-coder-next"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VENDOR_DIR="$SCRIPT_DIR/vendor"

# ── Argument defaults ──────────────────────────────────────────────────────
NON_INTERACTIVE=false
FLAG_KIROLINK_SERVICE=false
FLAG_SKIP_LOGIN=false
FLAG_SKIP_OPENCODE=false

# ── Terminal formatting ────────────────────────────────────────────────────
BOLD='\033[1m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

info()  { echo -e "${CYAN}➜${NC} $1"; }
ok()    { echo -e "${GREEN}✓${NC} $1"; }
warn()  { echo -e "${YELLOW}⚠${NC} $1"; }
err()   { echo -e "${RED}✗${NC} $1"; fail=1; }
step()  { echo; echo -e "${BOLD}[$1/$2]${NC} $3"; }
fail=0

TOTAL_STEPS=13

# ── Help ───────────────────────────────────────────────────────────────────
show_help() {
    echo "Usage: ./install.sh [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --non-interactive   Run without prompts (uses defaults: no kirolink service,"
    echo "                      reuse existing login, wire opencode)"
    echo "  --kirolink-service  Install kirolink as a systemd service (implies non-interactive"
    echo "                      for that prompt only)"
    echo "  --skip-login        Skip kiro-cli login step (use existing session)"
    echo "  --skip-opencode     Skip opencode.jsonc wiring"
    echo "  -h, --help          Show this message"
    echo ""
    echo "Environment variables:"
    echo "  KIRO_GATEWAY_REPO   Override kiro-gateway git URL"
    echo "  KIROLINK_REPO       Override kirolink git URL"
    echo "  KIRO_PORT           Gateway port (default: 8333)"
    echo "  KIRO_API_KEY        Gateway API key (default: kiro-gateway-8333)"
    echo ""
    echo "Vendor fallback:"
    echo "  If git clone fails, the installer falls back to vendored source in"
    echo "  vendor/kiro-gateway/ and vendor/kirolink/."
    echo ""
    echo "Examples:"
    echo "  ./install.sh                                          # Full interactive"
    echo "  ./install.sh --non-interactive --kirolink-service      # Headless full install"
    echo "  ./install.sh --skip-login --skip-opencode              # Quick reinstall"
    exit 0
}

# ── Argument parsing ───────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --non-interactive) NON_INTERACTIVE=true ;;
        --kirolink-service) FLAG_KIROLINK_SERVICE=true ;;
        --skip-login) FLAG_SKIP_LOGIN=true ;;
        --skip-opencode) FLAG_SKIP_OPENCODE=true ;;
        -h|--help) show_help ;;
        --dry-run)
            # Dry-run mode: just validate syntax and config, don't execute
            info "Dry-run mode: validating configuration"
            echo "  KIRO_DIR=$KIRO_DIR"
            echo "  KIROLINK_DIR=$KIROLINK_DIR"
            echo "  KIRO_PORT=$KIRO_PORT"
            echo "  SYSD_DIR=$SYSD_DIR"
            echo "  VENDOR_DIR=$VENDOR_DIR"
            echo "  NON_INTERACTIVE=$NON_INTERACTIVE"
            echo "  FLAG_KIROLINK_SERVICE=$FLAG_KIROLINK_SERVICE"
            echo "  FLAG_SKIP_LOGIN=$FLAG_SKIP_LOGIN"
            echo "  FLAG_SKIP_OPENCODE=$FLAG_SKIP_OPENCODE"
            exit 0
            ;;
        *) err "Unknown option: $1"; echo "  Use --help for usage."; exit 1 ;;
    esac
    shift
done

# ── Header ─────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}  🦉 Kiro Stack — Unified Installer v1.1${NC}"
echo "  kiro-gateway (Python proxy) + kirolink (Go token/proxy) + kiro-cli"
echo "  ───────────────────────────────────────────────────────────────"
if [ "$NON_INTERACTIVE" = true ]; then
    echo -e "  ${CYAN}Non-interactive mode${NC} (prompts skipped, defaults used)"
fi
echo ""

# ═══════════════════════════════════════════════════════════════════════════
# [1/13] System dependencies
# ═══════════════════════════════════════════════════════════════════════════
step 1 $TOTAL_STEPS "Checking system dependencies..."
MISSING=""
for cmd in python3 go git curl; do
    if ! command -v "$cmd" &>/dev/null; then
        MISSING="$MISSING $cmd"
    fi
done

if [ -n "$MISSING" ]; then
    if [ "$NON_INTERACTIVE" = true ]; then
        info "Installing missing deps:$MISSING (non-interactive)"
        sudo apt update && sudo apt install -y python3 python3-pip python3-venv golang-go git curl
    else
        info "Missing:$MISSING"
        echo -n "  Install them? [Y/n] "
        read -r INSTALL_DEPS
        if [[ ! "$INSTALL_DEPS" =~ ^[Nn] ]]; then
            sudo apt update && sudo apt install -y python3 python3-pip python3-venv golang-go git curl
        else
            err "Missing dependencies — cannot continue"
            exit 1
        fi
    fi
fi

# Verify versions
PYV=$(python3 --version 2>&1 | awk '{print $2}')
GOV=$(go version 2>&1 | awk '{print $3}')
ok "Python $PYV | Go $GOV | git $(git --version 2>&1 | awk '{print $3}') | curl $(curl --version 2>&1 | head -1 | awk '{print $2}')"

# ═══════════════════════════════════════════════════════════════════════════
# [2/13] Clone / update kiro-gateway (Python proxy)
# ═══════════════════════════════════════════════════════════════════════════
step 2 $TOTAL_STEPS "Cloning kiro-gateway..."
mkdir -p "$HOME/Documents/proxy"
if [ -d "$KIRO_DIR/.git" ]; then
    info "Repo exists at $KIRO_DIR — pulling latest..."
    git -C "$KIRO_DIR" pull --ff-only || warn "Could not pull (you may have local changes)"
elif [ -d "$VENDOR_DIR/kiro-gateway" ] && [ -f "$VENDOR_DIR/kiro-gateway/main.py" ]; then
    warn "Git clone not possible — using vendored source from $VENDOR_DIR/kiro-gateway"
    mkdir -p "$KIRO_DIR"
    cp -r "$VENDOR_DIR/kiro-gateway"/* "$KIRO_DIR/"
    cp -r "$VENDOR_DIR/kiro-gateway"/.[!.]* "$KIRO_DIR/" 2>/dev/null || true
else
    git clone "$KIRO_GATEWAY_REPO" "$KIRO_DIR" 2>/dev/null || {
        warn "Git clone failed — trying vendored fallback"
        if [ -d "$VENDOR_DIR/kiro-gateway" ] && [ -f "$VENDOR_DIR/kiro-gateway/main.py" ]; then
            cp -r "$VENDOR_DIR/kiro-gateway"/* "$KIRO_DIR/"
            cp -r "$VENDOR_DIR/kiro-gateway"/.[!.]* "$KIRO_DIR/" 2>/dev/null || true
        else
            err "Cannot fetch kiro-gateway — no network and no vendor source"
            exit 1
        fi
    }
fi
ok "kiro-gateway at $KIRO_DIR"

# ═══════════════════════════════════════════════════════════════════════════
# [3/13] Build kirolink (Go token/proxy binary)
# ═══════════════════════════════════════════════════════════════════════════
step 3 $TOTAL_STEPS "Building kirolink (Go binary)..."
if [ -d "$KIROLINK_DIR/.git" ]; then
    info "Repo exists at $KIROLINK_DIR — pulling latest..."
    git -C "$KIROLINK_DIR" pull --ff-only || warn "Could not pull"
elif [ -d "$VENDOR_DIR/kirolink" ] && [ -f "$VENDOR_DIR/kirolink/kirolink.go" ]; then
    warn "Git clone not possible — using vendored source from $VENDOR_DIR/kirolink"
    mkdir -p "$KIROLINK_DIR"
    cp -r "$VENDOR_DIR/kirolink"/* "$KIROLINK_DIR/"
    cp -r "$VENDOR_DIR/kirolink"/.[!.]* "$KIROLINK_DIR/" 2>/dev/null || true
else
    git clone "$KIROLINK_REPO" "$KIROLINK_DIR" 2>/dev/null || {
        warn "Git clone failed — trying vendored fallback"
        if [ -d "$VENDOR_DIR/kirolink" ] && [ -f "$VENDOR_DIR/kirolink/kirolink.go" ]; then
            cp -r "$VENDOR_DIR/kirolink"/* "$KIROLINK_DIR/"
            cp -r "$VENDOR_DIR/kirolink"/.[!.]* "$KIROLINK_DIR/" 2>/dev/null || true
        else
            err "Cannot fetch kirolink — no network and no vendor source"
            exit 1
        fi
    }
fi

cd "$KIROLINK_DIR"
go build -o kirolink kirolink.go 2>&1 || { err "go build failed"; warn "Check: go version, internet, deps"; }
if [ -f "$KIROLINK_DIR/kirolink" ]; then
    ok "kirolink binary built: $KIROLINK_DIR/kirolink"
    chmod +x "$KIROLINK_DIR/kirolink"
else
    err "kirolink binary not found after build"
fi
cd "$OLDPWD"

# ═══════════════════════════════════════════════════════════════════════════
# [4/13] Python virtual environment + dependencies + kiro-cli
# ═══════════════════════════════════════════════════════════════════════════
step 4 $TOTAL_STEPS "Setting up Python virtual environment..."
python3 -m venv "$VENV_DIR"
source "$VENV_DIR/bin/activate"
pip install --quiet --upgrade pip
if [ -f "$KIRO_DIR/requirements.txt" ]; then
    pip install --quiet -r "$KIRO_DIR/requirements.txt" || warn "pip install had warnings (see above)"
else
    warn "No requirements.txt found at $KIRO_DIR — skipping pip deps"
fi
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
    ok "Virtual env at $VENV_DIR (kiro-cli native + gateway deps)"

# ═══════════════════════════════════════════════════════════════════════════
# [5/13] kiro-cli login (interactive — AWS Builder ID / SSO)
# ═══════════════════════════════════════════════════════════════════════════
step 5 $TOTAL_STEPS "kiro-cli authentication (AWS Builder ID / SSO)"

NEED_LOGIN=true

# --skip-login flag overrides everything
if [ "$FLAG_SKIP_LOGIN" = true ]; then
    NEED_LOGIN=false
    ok "Skipping login (--skip-login)"
fi

# Check for existing session
if [ "$NEED_LOGIN" = true ] && [ -f "$KIRO_CLI_DB" ]; then
    DB_SIZE=$(stat -c%s "$KIRO_CLI_DB" 2>/dev/null || stat -f%z "$KIRO_CLI_DB" 2>/dev/null || echo "0")
    if [ "$DB_SIZE" -gt 1000 ]; then
        if [ "$NON_INTERACTIVE" = true ]; then
            NEED_LOGIN=false
            ok "Non-interactive: reusing existing kiro-cli session"
        else
            warn "Existing kiro-cli DB found ($DB_SIZE bytes)"
            echo -n "  Reuse existing session? [Y/n] "
            read -r SKIP_LOGIN
            if [[ ! "$SKIP_LOGIN" =~ ^[Nn] ]]; then
                NEED_LOGIN=false
                ok "Reusing existing kiro-cli session"
            fi
        fi
    fi
fi

if [ "$NEED_LOGIN" = true ]; then
    if [ "$NON_INTERACTIVE" = true ]; then
        err "kiro-cli login requires interactive browser — cannot run in non-interactive mode"
        err "  Run: source $VENV_DIR/bin/activate && kiro-cli login && deactivate"
        err "  Then re-run installer with --skip-login"
        exit 1
    fi
    echo ""
    warn "kiro-cli login requires AWS Builder ID (browser-based OIDC)"
    echo ""
    echo "  Step-by-step:"
    echo "    1. A browser will open to AWS IAM Identity Center"
    echo "    2. Sign in with your AWS Builder ID (free, no credit card)"
    echo "    3. Approve the device authorization request"
    echo "    4. Return to this terminal"
    echo ""
    echo "  Sign up: https://builderid.us-east-1.console.aws.amazon.com"
    echo ""
    echo -n "  Press ENTER to start login..."
    read -r _
    source "$VENV_DIR/bin/activate"
    kiro-cli login || { err "kiro-cli login failed"; deactivate; }
    deactivate
    if [ -f "$KIRO_CLI_DB" ]; then
        ok "kiro-cli authenticated"
    else
        err "kiro-cli DB not found after login"
    fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# [6/13] Kirolink data: token cache setup + verification
# ═══════════════════════════════════════════════════════════════════════════
step 6 $TOTAL_STEPS "Kirolink data — token cache setup"

# Ensure token directory exists
mkdir -p "$HOME/.aws/sso/cache"

# Refresh token from kiro-cli DB into the JSON token file
if [ -f "$KIRO_CLI_DB" ] && [ -f "$KIROLINK_DIR/kirolink" ]; then
    info "Syncing token from kiro-cli DB → $TOKEN_FILE"
    KIROLINK_OUTPUT=$("$KIROLINK_DIR/kirolink" refresh 2>&1) || true

    if echo "$KIROLINK_OUTPUT" | grep -qi "error\|failed\|not found"; then
        # Token may already exist — try reading
        if [ -f "$TOKEN_FILE" ]; then
            warn "kirolink refresh had warnings, but token file exists"
            "$KIROLINK_DIR/kirolink" read 2>&1 | head -5 || true
        else
            warn "kirolink refresh did not create token file"
            info "Attempting token sync via kiro-cli directly..."
            source "$VENV_DIR/bin/activate"
            kiro-cli chat --model claude-sonnet-4.5 --message "test" --max-tokens 10 2>&1 | head -3 || true
            deactivate
        fi
    else
        ok "Token refreshed via kirolink"
    fi
else
    warn "kirolink binary or kiro-cli DB not available — token sync deferred"
    info "Run later: cd $KIROLINK_DIR && ./kirolink refresh"
fi

# Verify token file
if [ -f "$TOKEN_FILE" ]; then
    TOKEN_SIZE=$(stat -c%s "$TOKEN_FILE" 2>/dev/null || stat -f%z "$TOKEN_FILE" 2>/dev/null || echo "0")
    if [ "$TOKEN_SIZE" -gt 50 ]; then
        ok "Token data: $TOKEN_FILE ($TOKEN_SIZE bytes)"
    else
        warn "Token file exists but seems small ($TOKEN_SIZE bytes)"
    fi
else
    warn "No token file at $TOKEN_FILE yet"
    info "Token will be created on first kiro-gateway API call"
fi

# ═══════════════════════════════════════════════════════════════════════════
# [7/13] Create .env for kiro-gateway
# ═══════════════════════════════════════════════════════════════════════════
step 7 $TOTAL_STEPS "Creating .env for kiro-gateway..."
if [ -f "$KIRO_DIR/.env" ]; then
    warn ".env exists — backing up to .env.bak"
    cp "$KIRO_DIR/.env" "$KIRO_DIR/.env.bak"
fi

cat > "$KIRO_DIR/.env" << ENVEOF
# Kiro Gateway — generated by kiro-stack installer
PROXY_API_KEY=$KIRO_API_KEY
SERVER_PORT=$KIRO_PORT
ACCOUNT_SYSTEM=true
KIRO_CLI_DB_FILE=$KIRO_CLI_DB
KIRO_USE_LEGACY_ENDPOINT=true
LOG_LEVEL=INFO
ENVEOF
ok ".env created (PROXY_API_KEY=$KIRO_API_KEY, SERVER_PORT=$KIRO_PORT)"

# ── Environment setup helper ───────────────────────────────────────────────
cat > "$HOME/.kiro-env" << KIROENV
# Kiro Stack environment — sourced by shell
export KIRO_API_KEY=$KIRO_API_KEY
export KIRO_BASE_URL=http://127.0.0.1:$KIRO_PORT/v1
export KIRO_GATEWAY_URL=http://127.0.0.1:$KIRO_PORT
export KIROLINK_BIN=$KIROLINK_DIR/kirolink
export KIROLINK_PORT=$KIROLINK_PORT
KIROENV
ok "Environment helper at \$HOME/.kiro-env (source for shell access)"

# ═══════════════════════════════════════════════════════════════════════════
# [8/13] Systemd service: kiro-gateway
# ═══════════════════════════════════════════════════════════════════════════
step 8 $TOTAL_STEPS "Creating systemd service: kiro-gateway (port $KIRO_PORT)..."
mkdir -p "$SYSD_DIR"

cat > "$SYSD_DIR/$GATEWAY_SERVICE" << SYSEOF
[Unit]
Description=Kiro Gateway (OWL Agent) — Anthropic proxy via CodeWhisperer
Documentation=https://github.com/Jwadow/kiro-gateway
After=network.target

[Service]
Type=simple
ExecStart=$VENV_DIR/bin/python main.py --port $KIRO_PORT
WorkingDirectory=$KIRO_DIR
Restart=on-failure
RestartSec=5
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=default.target
SYSEOF

systemctl --user daemon-reload
systemctl --user enable "$GATEWAY_SERVICE" 2>&1 || warn "systemd enable failed (user units may need login)"
ok "systemd: $GATEWAY_SERVICE enabled"

# ═══════════════════════════════════════════════════════════════════════════
# [9/13] (Optional) Systemd service: kirolink token proxy
# ═══════════════════════════════════════════════════════════════════════════
step 9 $TOTAL_STEPS "Creating systemd service: kirolink (port $KIROLINK_PORT)..."

INSTALL_KIROLINK_SERVICE=false
if [ "$FLAG_KIROLINK_SERVICE" = true ]; then
    INSTALL_KIROLINK_SERVICE=true
elif [ "$NON_INTERACTIVE" != true ]; then
    echo -n "  Install kirolink as a systemd service? [y/N] "
    read -r RESPONSE
    if [[ "$RESPONSE" =~ ^[Yy] ]]; then
        INSTALL_KIROLINK_SERVICE=true
    fi
fi

if [ "$INSTALL_KIROLINK_SERVICE" = true ]; then
    cat > "$SYSD_DIR/$KIROLINK_SERVICE" << SYSEOF
[Unit]
Description=Kirolink — Anthropic proxy via CodeWhisperer (token-managed)
Documentation=https://github.com/alexandeism/kirolink
After=network.target

[Service]
Type=simple
ExecStart=$KIROLINK_DIR/kirolink server $KIROLINK_PORT
WorkingDirectory=$KIROLINK_DIR
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
SYSEOF

    systemctl --user daemon-reload
    systemctl --user enable "$KIROLINK_SERVICE" 2>&1 || warn "systemd enable failed"
    ok "systemd: $KIROLINK_SERVICE enabled"
else
    warn "Skipping kirolink systemd service"
    [ "$NON_INTERACTIVE" != true ] && info "  Start manually: $KIROLINK_DIR/kirolink server $KIROLINK_PORT"
fi

# ═══════════════════════════════════════════════════════════════════════════
# [10/13] Systemd timer: hourly auth token refresh
# ═══════════════════════════════════════════════════════════════════════════
step 10 $TOTAL_STEPS "Creating systemd timer: kiro-auth-refresh (hourly)..."

INSTALL_REFRESH_TIMER=false
if [ "$NON_INTERACTIVE" = true ]; then
    INSTALL_REFRESH_TIMER=true
    info "Non-interactive: installing auth refresh timer by default"
else
    echo -n "  Install hourly auth refresh timer? (prevents 504 errors) [Y/n] "
    read -r RESPONSE
    if [[ ! "$RESPONSE" =~ ^[Nn] ]]; then
        INSTALL_REFRESH_TIMER=true
    fi
fi

if [ "$INSTALL_REFRESH_TIMER" = true ]; then
    # Oneshot service that runs kirolink refresh
    cat > "$SYSD_DIR/$REFRESH_SERVICE" << SYSEOF
[Unit]
Description=Kiro auth token refresh — syncs SSO token via kirolink
Documentation=https://github.com/alexandeism/kirolink
After=network.target

[Service]
Type=oneshot
ExecStart=$KIROLINK_DIR/kirolink refresh
WorkingDirectory=$KIROLINK_DIR
SYSEOF

    # Timer that fires hourly with randomized delay
    cat > "$SYSD_DIR/$REFRESH_TIMER" << SYSEOF
[Unit]
Description=Hourly Kiro auth token refresh
Documentation=https://github.com/alexandeism/kirolink
RefuseManualStart=no

[Timer]
OnCalendar=hourly
RandomizedDelaySec=600
Persistent=true

[Install]
WantedBy=timers.target
SYSEOF

    systemctl --user daemon-reload
    systemctl --user enable "$REFRESH_TIMER" 2>&1 || warn "systemd enable failed"
    systemctl --user start "$REFRESH_TIMER" 2>&1 || warn "systemd start failed"
    ok "systemd: $REFRESH_TIMER enabled and started (hourly refresh)"
else
    warn "Skipping auth refresh timer"
    info "  Install later: cp systemd/kiro-auth-refresh.* $SYSD_DIR/ && systemctl --user daemon-reload && systemctl --user enable --now kiro-auth-refresh.timer"
fi

# ═══════════════════════════════════════════════════════════════════════════
# [11/13] Start + verify kiro-gateway
# ═══════════════════════════════════════════════════════════════════════════
step 11 $TOTAL_STEPS "Starting kiro-gateway and verifying..."

systemctl --user start "$GATEWAY_SERVICE" || { err "Failed to start $GATEWAY_SERVICE"; }
sleep 6

# Service status
if systemctl --user is-active --quiet "$GATEWAY_SERVICE"; then
    ok "$GATEWAY_SERVICE is active (running)"
else
    err "$GATEWAY_SERVICE is not active"
    warn "Logs: journalctl --user -u $GATEWAY_SERVICE --no-pager -n 30"
fi

# HTTP health check
HEALTH=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 http://localhost:$KIRO_PORT/health 2>/dev/null || echo "000")
if [ "$HEALTH" = "200" ]; then
    ok "Health check: HTTP 200"
else
    warn "Health check returned HTTP $HEALTH (may be temporary)"
fi

# List models
MODEL_COUNT=$(curl -s http://localhost:$KIRO_PORT/v1/models \
    -H "Authorization: Bearer $KIRO_API_KEY" \
    --max-time 10 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('data',[])))" 2>/dev/null || echo "0")
if [ "$MODEL_COUNT" -gt 0 ]; then
    ok "$MODEL_COUNT models available"
else
    warn "Model list returned 0 models — auth may need refresh"
fi

# Quick chat test
CHAT_OK=$(curl -s -X POST http://localhost:$KIRO_PORT/v1/messages \
    -H "Content-Type: application/json" \
    -H "x-api-key: $KIRO_API_KEY" \
    -H "anthropic-version: 2023-06-01" \
    -d '{"model":"claude-sonnet-4.5","max_tokens":20,"messages":[{"role":"user","content":"hi"}]}' \
    --max-time 30 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print('ok' if d.get('content') else 'fail')" 2>/dev/null || echo "fail")
if [ "$CHAT_OK" = "ok" ]; then
    ok "Chat API verified (claude-sonnet-4.5)"
else
    warn "Chat test returned unexpected response — may need auth refresh"
    warn "  Fix: source $VENV_DIR/bin/activate && kiro-cli login && deactivate"
    warn "  Then: systemctl --user restart $GATEWAY_SERVICE"
fi

# ═══════════════════════════════════════════════════════════════════════════
# [12/13] Wire into opencode.jsonc
# ═══════════════════════════════════════════════════════════════════════════
step 12 $TOTAL_STEPS "Wiring into opencode.jsonc..."

if [ "$FLAG_SKIP_OPENCODE" = true ]; then
    warn "Skipping opencode wiring (--skip-opencode)"
elif [ ! -f "$OPENCODE_CONFIG" ]; then
    warn "opencode.jsonc not found at $OPENCODE_CONFIG — skipping"
else
    # Build models JSON for the kiro provider
    MODELS_JSON=""
    for m in $CUSTOM_MODELS; do
        NAME_DISPLAY=$(echo "$m" | sed 's/-/ /g' | sed 's/\b\(.\)/\u\1/g')
        [ -n "$MODELS_JSON" ] && MODELS_JSON="$MODELS_JSON,"
        MODELS_JSON="$MODELS_JSON\n        \"$m\": { \"name\": \"$NAME_DISPLAY via Kiro\" }"
    done

    python3 << PYEOF
import re, json

with open("$OPENCODE_CONFIG") as f:
    raw = f.read()

kiro_block = '''
    "kiro": {
      "npm": "@ai-sdk/anthropic",
      "name": "Kiro OWL Agent Gateway (direct, port $KIRO_PORT)",
      "options": {
        "baseURL": "http://127.0.0.1:$KIRO_PORT/v1",
        "apiKey": "$KIRO_API_KEY",
        "timeout": 300000
      },
      "models": {
$MODELS_JSON
      }
    },
'''

# Check if kiro provider already exists
if '"kiro"' in raw:
    # Update baseURL and apiKey
    raw = re.sub(
        r'("kiro"\s*:\s*\{.*?"options"\s*:\s*\{)(.*?)(\}.*?\}.*?\})',
        lambda m: re.sub(r'"baseURL"\s*:\s*"[^"]*"', f'"baseURL": "http://127.0.0.1:$KIRO_PORT/v1"',
                re.sub(r'"apiKey"\s*:\s*"[^"]*"', f'"apiKey": "$KIRO_API_KEY"', m.group(0))),
        raw,
        flags=re.DOTALL
    )
    print("kiro provider updated")
else:
    # Insert before nvidia
    if '"nvidia"' in raw:
        raw = raw.replace('"nvidia"', kiro_block + '"nvidia"', 1)
        print("kiro provider injected")
    else:
        print("nvidia provider not found — appending at end")
        raw = raw.rstrip().rstrip('}') + ',\n' + kiro_block.rstrip().rstrip(',').rstrip() + '\n}'

with open("$OPENCODE_CONFIG", "w") as f:
    f.write(raw)
PYEOF

    # Add subagents
    python3 << PYEOF
with open("$OPENCODE_CONFIG") as f:
    raw = f.read()

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

if '"planner"' in raw and 'kiro/claude-haiku-4.5' in raw:
    print("subagents_ok")
else:
    if '"brainstorming"' in raw:
        raw = raw.replace('"brainstorming"', agents_block + '"brainstorming"', 1)
        with open("$OPENCODE_CONFIG", "w") as f:
            f.write(raw)
        print("subagents_added")
    else:
        print("brainstorming_not_found — subagents not auto-injected")
PYEOF

    if grep -q '"kiro"' "$OPENCODE_CONFIG" 2>/dev/null; then
        ok "kiro provider wired in opencode.jsonc"
    else
        warn "kiro provider not found in opencode.jsonc — see manual instructions"
    fi

    # Restart opencode if running
    if pgrep -f "opencode" >/dev/null 2>&1; then
        warn "opencode is currently running — restart to pick up new config"
        warn "  Run: pkill opencode && opencode"
    fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# [13/13] Summary
# ═══════════════════════════════════════════════════════════════════════════
step 13 $TOTAL_STEPS "Installation complete"

echo ""
echo -e "${GREEN}${BOLD}  🦉 Kiro Stack is installed!${NC}"
echo ""

if [ "$fail" -gt 0 ]; then
    echo -e "${YELLOW}  ⚠ Completed with $fail warnings — review above.${NC}"
    echo ""
fi

echo -e "${BOLD}  ├─ Components${NC}"
echo "  │  ├─ kiro-gateway (Python proxy)     port $KIRO_PORT"
echo "  │  ├─ kirolink (Go token/proxy)        port $KIROLINK_PORT"
echo "  │  ├─ kirolink data (token cache)      $TOKEN_FILE"
echo "  │  └─ kiro-cli (auth)                  $KIRO_CLI_DB"
echo ""
echo -e "${BOLD}  ├─ Services${NC}"
STATUS=$(systemctl --user is-active "$GATEWAY_SERVICE" 2>/dev/null || echo "unknown")
echo "  │  ├─ $GATEWAY_SERVICE  [$STATUS]"
if [ "$INSTALL_KIROLINK_SERVICE" = true ] && [ -f "$SYSD_DIR/$KIROLINK_SERVICE" ]; then
    KSTATUS=$(systemctl --user is-active "$KIROLINK_SERVICE" 2>/dev/null || echo "stopped")
    echo "  │  ├─ $KIROLINK_SERVICE  [$KSTATUS]"
fi
if [ "$INSTALL_REFRESH_TIMER" = true ] && [ -f "$SYSD_DIR/$REFRESH_TIMER" ]; then
    TSTATUS=$(systemctl --user is-active "$REFRESH_TIMER" 2>/dev/null || echo "inactive")
    echo "  │  └─ $REFRESH_TIMER  [$TSTATUS] (hourly token refresh)"
fi
echo ""
echo -e "${BOLD}  ├─ Models in opencode${NC}"
echo "  │  ${CYAN}kiro/claude-sonnet-4.5${NC}  (full thinking, primary)"
echo "  │  ${CYAN}kiro/claude-haiku-4.5${NC}   (fast/cheap, subagents)"
echo "  │  ${CYAN}kiro/qwen3-coder-next${NC}   (coding)"
echo "  │  ${CYAN}kiro/claude-sonnet-4${NC}"
echo "  │  ${CYAN}kiro/deepseek-3.2${NC}"
echo "  │  ${CYAN}kiro/glm-5${NC}"
echo "  │  ${CYAN}kiro/minimax-m2.5${NC}"
echo "  │  ${CYAN}kiro/minimax-m2.1${NC}"
echo "  │  ${CYAN}kiro/auto-kiro${NC}          (smart default)"
echo ""
echo -e "${BOLD}  ├─ Management${NC}"
echo "  │  ├─ systemctl --user status $GATEWAY_SERVICE"
echo "  │  ├─ systemctl --user restart $GATEWAY_SERVICE"
echo "  │  ├─ journalctl --user -u $GATEWAY_SERVICE -n 50 -f"
echo "  │  ├─ systemctl --user status $REFRESH_TIMER"
echo "  │  └─ journalctl --user -u $REFRESH_SERVICE -n 50 -f"
echo ""
echo -e "${BOLD}  ├─ Quick verification${NC}"
echo "  │  ├─ curl http://localhost:$KIRO_PORT/health"
echo "  │  ├─ curl http://localhost:$KIRO_PORT/v1/models -H 'Authorization: Bearer $KIRO_API_KEY'"
echo "  │  └─ $KIROLINK_DIR/kirolink read"
echo ""
echo -e "${BOLD}  └─ Auth refresh (when tokens expire ~24h)${NC}"
echo "     $ source $VENV_DIR/bin/activate && kiro-cli login && deactivate"
echo "     $ systemctl --user restart $GATEWAY_SERVICE"
echo "     $ $KIROLINK_DIR/kirolink refresh"
echo "     Or rely on the systemd timer (runs hourly)"
echo ""

# Final end-to-end
echo "  Running final end-to-end check..."
if curl -sf http://localhost:$KIRO_PORT/health --max-time 5 >/dev/null 2>&1; then
    ok "End-to-end: kiro-gateway is live"
else
    warn "End-to-end: kiro-gateway not reachable"
    warn "  Wait a moment and retry: curl http://localhost:$KIRO_PORT/health"
fi

echo ""
exit $fail
