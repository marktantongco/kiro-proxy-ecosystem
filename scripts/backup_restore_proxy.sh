#!/usr/bin/env bash
# 🦉 Kiro/OWL Proxy Stack - Auto-Backup & Restore Utility
# Created at: 2026-06-14
set -euo pipefail

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

TOTAL_STEPS=6

step "1" "$TOTAL_STEPS" "Initializing backup paths..."
KIRO_GATEWAY_SERVICE="$HOME/.config/systemd/user/kiro-gateway.service"
OWL_FORWARD_SERVICE="$HOME/.config/systemd/user/owl-forward-proxy.service"
AGY_WRAPPER="$HOME/.local/bin/agy"
HERMES_WRAPPER="$HOME/.local/bin/hermes"
KIRO_CLI_WRAPPER="$HOME/.owl-agent/kiro-cli"
KIRO_CLI_DB="$HOME/.local/share/kiro-cli/data.sqlite3"

step "2" "$TOTAL_STEPS" "Restoring Systemd Services..."
mkdir -p "$(dirname "$KIRO_GATEWAY_SERVICE")"

info "Restoring $KIRO_GATEWAY_SERVICE..."
cat > "$KIRO_GATEWAY_SERVICE" << 'EOF'
[Unit]
Description=Kiro Gateway (OWL Agent) — Anthropic/OpenAI proxy for Kiro API
After=network.target

[Service]
Type=simple
ExecStart=/home/x1/Documents/proxy/kiro-gateway/.venv/bin/python main.py --port 8333
WorkingDirectory=/home/x1/Documents/proxy/kiro-gateway
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF
ok "Kiro Gateway service file restored."

info "Restoring $OWL_FORWARD_SERVICE..."
cat > "$OWL_FORWARD_SERVICE" << 'EOF'
[Unit]
Description=OWL Forward Proxy v3.1 (Auto-Tune enabled)
After=network.target

[Service]
Type=simple
ExecStart=/home/x1/.owl-agent/venv/bin/python /home/x1/.owl-agent/forward_proxy.py
Restart=on-failure
RestartSec=3
StandardOutput=append:/home/x1/.owl-agent/logs/forward-proxy.log
StandardError=append:/home/x1/.owl-agent/logs/forward-proxy.log
Environment=OWL_PROXY_HOST=127.0.0.1
Environment=OWL_PROXY_PORT=60000
Environment=OWL_MAX_CONNECTIONS=5
Environment=OWL_CACHE_MAX_ENTRIES=200
MemoryMax=512M
MemoryHigh=384M
OOMPolicy=stop

[Install]
WantedBy=default.target
EOF
ok "OWL Forward Proxy service file restored."

step "3" "$TOTAL_STEPS" "Restoring Executable Wrappers..."
mkdir -p "$(dirname "$AGY_WRAPPER")"
mkdir -p "$(dirname "$KIRO_CLI_WRAPPER")"

info "Restoring $AGY_WRAPPER..."
cat > "$AGY_WRAPPER" << 'EOF'
#!/usr/bin/env bash
# agy wrapper for the opencode/OWL proxy stack
# Makes bypass the default for auth steps (Google token exchange for antigravity).
# Unsets proxy env vars so no proxyconnect errors during OAuth.
# If you want the proxy stack for non-auth agy use, set env before calling or modify this.
export PATH="$HOME/.local/bin:$HOME/.opencode/bin:$PATH"
unset HTTP_PROXY HTTPS_PROXY http_proxy https_proxy
exec ~/.local/bin/agy.real "$@"
EOF
chmod +x "$AGY_WRAPPER"
ok "agy wrapper restored and set executable."

info "Restoring $HERMES_WRAPPER..."
cat > "$HERMES_WRAPPER" << 'EOF'
#!/bin/bash
export HTTP_PROXY="http://127.0.0.1:60000" HTTPS_PROXY="http://127.0.0.1:60000"
export NO_PROXY="localhost,127.0.0.1,.local,::1"
exec "$@"
EOF
chmod +x "$HERMES_WRAPPER"
ok "hermes wrapper restored and set executable."

info "Restoring $KIRO_CLI_WRAPPER..."
cat > "$KIRO_CLI_WRAPPER" << 'EOF'
#!/bin/bash
# 🦉 Explicitly route kiro-cli through the OWL Agent Forward Proxy & Clash
export HTTP_PROXY="http://127.0.0.1:60000"
export HTTPS_PROXY="http://127.0.0.1:60000"
export NO_PROXY="localhost,127.0.0.1,.local,.localdomain,::1"

source "$HOME/.owl-agent/venv/bin/activate"
exec kiro-cli "$@"
EOF
chmod +x "$KIRO_CLI_WRAPPER"
ok "kiro-cli wrapper restored and set executable."

step "4" "$TOTAL_STEPS" "Initializing Empty Database if Missing..."
if [ ! -f "$KIRO_CLI_DB" ]; then
    info "SQLite DB missing. Initializing valid schema blank database at $KIRO_CLI_DB..."
    mkdir -p "$(dirname "$KIRO_CLI_DB")"
    python3 -c "import sqlite3; conn = sqlite3.connect('$KIRO_CLI_DB'); cursor = conn.cursor(); cursor.execute('CREATE TABLE IF NOT EXISTS auth_kv (key TEXT PRIMARY KEY, value TEXT)'); cursor.execute('CREATE TABLE IF NOT EXISTS state (key TEXT PRIMARY KEY, value BLOB)'); cursor.execute('CREATE TABLE IF NOT EXISTS migrations (id INTEGER PRIMARY KEY, version INTEGER NOT NULL, migration_time INTEGER NOT NULL)'); cursor.execute('CREATE TABLE IF NOT EXISTS history (id INTEGER PRIMARY KEY, command TEXT, shell TEXT, pid INTEGER, session_id TEXT, cwd TEXT, start_time INTEGER, hostname TEXT, exit_code INTEGER, end_time INTEGER, duration INTEGER)'); cursor.execute('CREATE TABLE IF NOT EXISTS conversations (key TEXT PRIMARY KEY, value TEXT)'); cursor.execute('CREATE TABLE IF NOT EXISTS conversations_v2 (key TEXT NOT NULL, conversation_id TEXT NOT NULL, value TEXT NOT NULL, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL, PRIMARY KEY (key, conversation_id))'); conn.commit(); conn.close()"
    ok "Database fully schema-initialized."
else
    ok "Existing SQLite database found at $KIRO_CLI_DB."
fi

step "5" "$TOTAL_STEPS" "Activating Systemd Services..."
info "Reloading systemd user daemon..."
systemctl --user daemon-reload
info "Enabling services..."
systemctl --user enable kiro-gateway.service owl-forward-proxy.service 2>/dev/null || true
info "Restarting services..."
systemctl --user restart owl-forward-proxy.service kiro-gateway.service
ok "Systemd services started successfully."

step "6" "$TOTAL_STEPS" "Verifying Installation Health..."
sleep 1
if systemctl --user is-active --quiet kiro-gateway.service; then
    ok "kiro-gateway.service is running."
else
    warn "kiro-gateway.service failed to start. Run: journalctl --user -u kiro-gateway.service"
fi

if systemctl --user is-active --quiet owl-forward-proxy.service; then
    ok "owl-forward-proxy.service is running."
else
    warn "owl-forward-proxy.service is not active (may need upstream Clash port 7890 active)."
fi

echo ""
echo -e "${GREEN}${BOLD}  🦉 Proxy Ecosystem Restore Complete!${NC}"
echo ""
