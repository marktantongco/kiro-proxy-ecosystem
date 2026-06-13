#!/bin/bash
# 🦉 Kiro OWL Agent — Updater v1.0
# Updates kiro-gateway + OWL agent files + kiro-cli, restarts service, verifies health
# Designed as companion to install_kiro_owl_agent.sh
set -e

KIRO_REPO="https://github.com/Jwadow/kiro-gateway.git"
KIRO_DIR="$HOME/Documents/proxy/kiro-gateway"
KIRO_PORT=8333
KIRO_API_KEY="kiro-gateway-8333"
VENV_DIR="$KIRO_DIR/.venv"
SYSD_FILE="$HOME/.config/systemd/user/kiro-gateway.service"
OPENCODE_CONFIG="$HOME/.config/opencode/opencode.jsonc"
KIRO_CLI_DB="$HOME/.local/share/kiro-cli/data.sqlite3"
OWL_AGENT_DIR="$HOME/.owl-agent"
ECOSYSTEM_DIR="$HOME/Documents/projects/kiro-proxy-ecosystem"

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
step()  { echo; echo -e "${BOLD}[$1/$2]${NC} $3"; }

TOTAL_STEPS=9

echo ""
echo -e "${BOLD}  🦉 Kiro OWL Agent — Update${NC}"
echo "  $(date)"
echo ""

# ============================================================
# [1/9] System checks
# ============================================================
step 1 $TOTAL_STEPS "Pre-flight checks..."

MISSING=""
for cmd in python3 git curl unzip; do
    if ! command -v "$cmd" &>/dev/null; then
        MISSING="$MISSING $cmd"
    fi
done
if [ -n "$MISSING" ]; then
    err "Missing deps:$MISSING — run installer first"
    exit 1
fi

if [ ! -d "$KIRO_DIR" ]; then
    err "kiro-gateway not found at $KIRO_DIR — run install_kiro_owl_agent.sh first"
    exit 1
fi

SERVICE_EXISTS=false
if systemctl --user --quiet is-enabled kiro-gateway.service 2>/dev/null; then
    SERVICE_EXISTS=true
fi

ok "Pre-flight: all checks passed"
[ "$SERVICE_EXISTS" = true ] && ok "kiro-gateway.service is installed"
[ "$SERVICE_EXISTS" = false ] && warn "kiro-gateway.service not found — will reinstall"

# ============================================================
# [2/9] Pull latest kiro-gateway
# ============================================================
step 2 $TOTAL_STEPS "Pulling latest kiro-gateway..."

if [ -d "$KIRO_DIR/.git" ]; then
    git -C "$KIRO_DIR" fetch --tags --force
    CURRENT_HASH=$(git -C "$KIRO_DIR" rev-parse HEAD)
    git -C "$KIRO_DIR" pull --ff-only
    NEW_HASH=$(git -C "$KIRO_DIR" rev-parse HEAD)
    if [ "$CURRENT_HASH" = "$NEW_HASH" ]; then
        ok "Already up to date (${CURRENT_HASH:0:8})"
    else
        ok "Updated: ${CURRENT_HASH:0:8} → ${NEW_HASH:0:8}"
        git -C "$KIRO_DIR" log --oneline "$CURRENT_HASH..$NEW_HASH" 2>/dev/null | head -20
    fi
else
    err "kiro-gateway is not a git repository — cannot update"
    info "Clone fresh: git clone $KIRO_REPO $KIRO_DIR"
    exit 1
fi

# ============================================================
# [3/9] Update Python venv dependencies
# ============================================================
step 3 $TOTAL_STEPS "Updating Python virtual environment..."

if [ ! -d "$VENV_DIR" ]; then
    info "Creating fresh virtual environment..."
    python3 -m venv "$VENV_DIR"
fi

source "$VENV_DIR/bin/activate"
pip install --quiet --upgrade pip

if [ -f "$KIRO_DIR/requirements.txt" ]; then
    pip install --quiet --upgrade -r "$KIRO_DIR/requirements.txt"
    ok "Python dependencies updated"
else
    warn "No requirements.txt found — skipping pip install"
fi

# Update OWL agent Python dependencies if requirements.txt exists
if [ -f "$OWL_AGENT_DIR/requirements.txt" ]; then
    pip install --quiet --upgrade -r "$OWL_AGENT_DIR/requirements.txt"
    ok "OWL agent Python dependencies updated"
fi

deactivate
ok "Virtual environment up to date"

# ============================================================
# [4/9] Update kiro-cli native binary
# ============================================================
step 4 $TOTAL_STEPS "Updating kiro-cli native binary..."

ARCH=$(uname -m)
case "$ARCH" in
    x86_64|amd64)  ARCH_DETECTED="x86_64" ;;
    aarch64|arm64) ARCH_DETECTED="aarch64" ;;
    *) err "Unsupported architecture: $ARCH"; exit 1 ;;
esac

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

info "Downloading latest kiro-cli from AWS S3..."
if curl -fsSL --proto '=https' --tlsv1.2 "$KIRO_URL" -o "$KIRO_ZIP_PATH"; then
    unzip -qo "$KIRO_ZIP_PATH" -d "/tmp/kirocli_extracted"
    mkdir -p "$HOME/.local/bin" "$VENV_DIR/bin"

    # Copy to both system and venv paths
    for target in "$HOME/.local/bin/kiro-cli" "$VENV_DIR/bin/kiro-cli"; do
        cp "/tmp/kirocli_extracted/kirocli/kiro-cli" "$target" 2>/dev/null ||
        cp "/tmp/kirocli_extracted/kiro-cli" "$target" 2>/dev/null ||
        true
        chmod +x "$target" 2>/dev/null || true
    done

    rm -rf "$KIRO_ZIP_PATH" "/tmp/kirocli_extracted"

    if command -v kiro-cli &>/dev/null; then
        KIRO_CLI_VER=$(kiro-cli --version 2>/dev/null || echo "unknown")
        ok "kiro-cli updated ($KIRO_CLI_VER)"
    else
        ok "kiro-cli binary downloaded (check PATH if not found)"
    fi
else
    warn "Failed to download latest kiro-cli — keeping current version"
fi

# ============================================================
# [5/9] Update OWL agent files from ecosystem
# ============================================================
step 5 $TOTAL_STEPS "Syncing OWL agent files..."

if [ -d "$ECOSYSTEM_DIR/.agents" ]; then
    # Sync .agents directory
    rsync -a --delete "$ECOSYSTEM_DIR/.agents/" "$OWL_AGENT_DIR/repo/.agents/" 2>/dev/null || {
        mkdir -p "$OWL_AGENT_DIR/repo"
        cp -r "$ECOSYSTEM_DIR/.agents" "$OWL_AGENT_DIR/repo/"
    }
    ok "Ecosystem agents synced"
else
    warn "No .agents/ in ecosystem project — skipping"
fi

# Update diagnose script if newer
if [ -f "$ECOSYSTEM_DIR/scripts/diagnose_opencode.sh" ]; then
    cp "$ECOSYSTEM_DIR/scripts/diagnose_opencode.sh" "$OWL_AGENT_DIR/diagnose_opencode.sh"
    chmod +x "$OWL_AGENT_DIR/diagnose_opencode.sh"
    ok "Diagnose script updated"
fi

# Sync config templates
if [ -d "$ECOSYSTEM_DIR/configs" ]; then
    rsync -a "$ECOSYSTEM_DIR/configs/" "$OWL_AGENT_DIR/config/" 2>/dev/null || true
    ok "Config templates synced"
fi

# ============================================================
# [6/9] Update .env if missing keys
# ============================================================
step 6 $TOTAL_STEPS "Checking configuration..."

if [ ! -f "$KIRO_DIR/.env" ]; then
    info "Creating .env from defaults..."
    cat > "$KIRO_DIR/.env" << ENVEOF
# Kiro Gateway — updated by update.sh $(date)
PROXY_API_KEY=$KIRO_API_KEY
SERVER_PORT=$KIRO_PORT
ACCOUNT_SYSTEM=true
KIRO_CLI_DB_FILE=$KIRO_CLI_DB
KIRO_USE_LEGACY_ENDPOINT=true
LOG_LEVEL=INFO
ENVEOF
    ok ".env created"
else
    # Ensure key vars are present (don't overwrite existing values)
    for var in "PROXY_API_KEY=$KIRO_API_KEY" "SERVER_PORT=$KIRO_PORT"; do
        key="${var%%=*}"
        if ! grep -q "^${key}=" "$KIRO_DIR/.env" 2>/dev/null; then
            echo "$var" >> "$KIRO_DIR/.env"
            info "Added $key to .env"
        fi
    done
    ok ".env intact"
fi

# ============================================================
# [7/9] Restart service
# ============================================================
step 7 $TOTAL_STEPS "Restarting kiro-gateway service..."

mkdir -p "$HOME/.config/systemd/user"

if [ ! -f "$SYSD_FILE" ]; then
    info "Creating systemd service file..."
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
    ok "Systemd service created and enabled"
fi

systemctl --user daemon-reload
systemctl --user restart kiro-gateway.service || {
    err "Service failed to restart"
    info "Check: journalctl --user -u kiro-gateway.service --no-pager -n 30"
    exit 1
}
ok "kiro-gateway.service restarted"

# Wait for service to come up
sleep 5
if ! systemctl --user is-active --quiet kiro-gateway.service; then
    err "Service not active after restart"
    systemctl --user status kiro-gateway.service --no-pager -n 15
    journalctl --user -u kiro-gateway.service --no-pager -n 20
    exit 1
fi
ok "kiro-gateway.service is active (running)"

# ============================================================
# [8/9] Health checks
# ============================================================
step 8 $TOTAL_STEPS "Running health checks..."

ALL_OK=true

# HTTP health endpoint
HEALTH=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 http://localhost:$KIRO_PORT/health 2>/dev/null || echo "000")
if [ "$HEALTH" = "200" ]; then
    ok "Health check: HTTP 200"
else
    warn "Health check failed (HTTP $HEALTH)"
    ALL_OK=false
fi

# Models endpoint
MODEL_COUNT=$(curl -s http://localhost:$KIRO_PORT/v1/models \
    -H "Authorization: Bearer $KIRO_API_KEY" \
    --max-time 10 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('data',[])))" 2>/dev/null || echo "0")
if [ "$MODEL_COUNT" -gt 0 ]; then
    ok "$MODEL_COUNT models available"
else
    warn "Model list returned 0 models — auth may need refresh"
    ALL_OK=false
fi

# Quick chat test with a cheap model
CHAT_OK=$(curl -s -X POST http://localhost:$KIRO_PORT/v1/messages \
    -H "Content-Type: application/json" \
    -H "x-api-key: $KIRO_API_KEY" \
    -H "anthropic-version: 2023-06-01" \
    -d '{"model":"claude-haiku-4.5","max_tokens":20,"messages":[{"role":"user","content":"ping"}]}' \
    --max-time 30 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print('ok' if d.get('content') else 'fail')" 2>/dev/null || echo "fail")
if [ "$CHAT_OK" = "ok" ]; then
    ok "Chat API works (claude-haiku-4.5)"
else
    warn "Chat test returned unexpected response — may be temporary"
fi

if [ "$ALL_OK" = false ]; then
    echo ""
    warn "Some checks failed. Troubleshooting:"
    echo "  owl-check"
    echo "  $OWL_AGENT_DIR/diagnose_opencode.sh"
    echo "  journalctl --user -u kiro-gateway.service -n 50 --no-pager"
fi

# ============================================================
# [9/9] Verify opencode integration & summary
# ============================================================
step 9 $TOTAL_STEPS "Verifying opencode integration..."

if [ -f "$OPENCODE_CONFIG" ] && grep -q '"kiro"' "$OPENCODE_CONFIG" 2>/dev/null; then
    ok "kiro provider found in opencode.jsonc"
else
    warn "kiro provider not found in opencode.jsonc"
    info "Re-run: ~/install_kiro_owl_agent.sh or add manually"
fi

# Verify kiro-cli binary
if command -v kiro-cli &>/dev/null; then
    ok "kiro-cli available in PATH"
else
    warn "kiro-cli not in PATH — add \$HOME/.local/bin to your PATH"
fi

# Check kiro-cli auth session
if [ -f "$KIRO_CLI_DB" ]; then
    # Verify and auto-repair missing schema tables
    REPAIRED=$(python3 -c "
import sqlite3
conn = sqlite3.connect('$KIRO_CLI_DB')
cursor = conn.cursor()
tables = ['auth_kv', 'state', 'migrations', 'history', 'conversations', 'conversations_v2']
created = []
for t in tables:
    cursor.execute(f\"SELECT name FROM sqlite_master WHERE type='table' AND name='{t}'\")
    if not cursor.fetchone():
        if t == 'auth_kv':
            cursor.execute('CREATE TABLE auth_kv (key TEXT PRIMARY KEY, value TEXT)')
        elif t == 'state':
            cursor.execute('CREATE TABLE state (key TEXT PRIMARY KEY, value BLOB)')
        elif t == 'migrations':
            cursor.execute('CREATE TABLE migrations (id INTEGER PRIMARY KEY, version INTEGER NOT NULL, migration_time INTEGER NOT NULL)')
        elif t == 'history':
            cursor.execute('CREATE TABLE history (id INTEGER PRIMARY KEY, command TEXT, shell TEXT, pid INTEGER, session_id TEXT, cwd TEXT, start_time INTEGER, hostname TEXT, exit_code INTEGER, end_time INTEGER, duration INTEGER)')
        elif t == 'conversations':
            cursor.execute('CREATE TABLE conversations (key TEXT PRIMARY KEY, value TEXT)')
        elif t == 'conversations_v2':
            cursor.execute('CREATE TABLE conversations_v2 (key TEXT NOT NULL, conversation_id TEXT NOT NULL, value TEXT NOT NULL, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL, PRIMARY KEY (key, conversation_id))')
        created.append(t)
if created:
    conn.commit()
    print('yes')
else:
    print('no')
conn.close()
" 2>/dev/null || echo "error")

    if [ "$REPAIRED" = "yes" ]; then
        ok "Auto-repaired missing schema tables in $KIRO_CLI_DB"
    fi

    DB_SIZE=$(stat -c%s "$KIRO_CLI_DB" 2>/dev/null || stat -f%z "$KIRO_CLI_DB" 2>/dev/null || echo "0")
    if [ "$DB_SIZE" -gt 1000 ]; then
        ok "kiro-cli auth session found (${DB_SIZE} bytes)"
    else
        warn "kiro-cli auth session may be expired (${DB_SIZE} bytes)"
        info "Re-auth: source $VENV_DIR/bin/activate && kiro-cli login && deactivate"
    fi
else
    warn "kiro-cli database not found. Initializing a valid blank database..."
    mkdir -p "$(dirname "$KIRO_CLI_DB")"
    python3 -c "import sqlite3; conn = sqlite3.connect('$KIRO_CLI_DB'); cursor = conn.cursor(); cursor.execute('CREATE TABLE IF NOT EXISTS auth_kv (key TEXT PRIMARY KEY, value TEXT)'); cursor.execute('CREATE TABLE IF NOT EXISTS state (key TEXT PRIMARY KEY, value BLOB)'); cursor.execute('CREATE TABLE IF NOT EXISTS migrations (id INTEGER PRIMARY KEY, version INTEGER NOT NULL, migration_time INTEGER NOT NULL)'); cursor.execute('CREATE TABLE IF NOT EXISTS history (id INTEGER PRIMARY KEY, command TEXT, shell TEXT, pid INTEGER, session_id TEXT, cwd TEXT, start_time INTEGER, hostname TEXT, exit_code INTEGER, end_time INTEGER, duration INTEGER)'); cursor.execute('CREATE TABLE IF NOT EXISTS conversations (key TEXT PRIMARY KEY, value TEXT)'); cursor.execute('CREATE TABLE IF NOT EXISTS conversations_v2 (key TEXT NOT NULL, conversation_id TEXT NOT NULL, value TEXT NOT NULL, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL, PRIMARY KEY (key, conversation_id))'); conn.commit(); conn.close()"
    ok "Fully initialized blank SQLite database created successfully at $KIRO_CLI_DB"
fi

echo ""
echo -e "${GREEN}${BOLD}  🦉 Kiro OWL Agent update complete!${NC}"
echo ""
echo "  ├─ Gateway:      http://localhost:${KIRO_PORT}/health"
echo "  ├─ Git hash:     $(git -C "$KIRO_DIR" rev-parse --short HEAD 2>/dev/null || echo '?')"
echo "  ├─ Systemd:      kiro-gateway.service ($(systemctl --user is-active kiro-gateway.service 2>/dev/null || echo '?')$(systemctl --user is-enabled kiro-gateway.service 2>/dev/null | tr -d '\n'))"
echo "  ├─ Python venv:  $VENV_DIR"
echo "  └─ OWL agent:    $OWL_AGENT_DIR"
echo ""
echo -e "${BOLD}  Management:${NC}"
echo "    systemctl --user restart kiro-gateway.service"
echo "    journalctl --user -u kiro-gateway.service -n 50 -f"
echo "    curl http://localhost:${KIRO_PORT}/v1/models -H 'Authorization: Bearer ${KIRO_API_KEY}'"
echo ""
echo -e "${YELLOW}  Token refresh (if auth expires):${NC}"
echo "    source $VENV_DIR/bin/activate && kiro-cli login && deactivate"
echo "    systemctl --user restart kiro-gateway.service"
echo ""
