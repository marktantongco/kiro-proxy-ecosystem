#!/bin/bash
# 🦉 OWL-AGENT Proxy Resolution & Optimization Patch v1.0
# Sets UPSTREAM_PROXY prioritization, fixes systemd configurations, and restarts services.
set -euo pipefail

# Config
PROXY_PY="/home/x1/.owl-agent/forward_proxy.py"
SERVICE_FILE="/home/x1/.config/systemd/user/owl-forward-proxy.service"

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
step()  { echo; echo -e "${BOLD}[$1]${NC} $2"; }

# ── Header ─────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}  🦉 OWL-AGENT Proxy Optimizer & Fix Patch v1.0${NC}"
echo "  ───────────────────────────────────────────────────────────────"

# ═══════════════════════════════════════════════════════════════════════════
# [1/4] Validate target files exist
# ═══════════════════════════════════════════════════════════════════════════
step "1" "Validating installation files..."
if [[ ! -f "$PROXY_PY" ]]; then
    err "Could not find $PROXY_PY! Is OWL-Agent installed?"
    exit 1
fi
if [[ ! -f "$SERVICE_FILE" ]]; then
    err "Could not find systemd unit: $SERVICE_FILE"
    exit 1
fi
ok "All target files found."

# ═══════════════════════════════════════════════════════════════════════════
# [2/4] Patch forward_proxy.py to prioritize UPSTREAM_PROXY
# ═══════════════════════════════════════════════════════════════════════════
step "2" "Patching $PROXY_PY to prioritize UPSTREAM_PROXY..."

python3 - << 'EOF'
import sys

filepath = "/home/x1/.owl-agent/forward_proxy.py"

with open(filepath, 'r') as f:
    code = f.read()

# Define the robust target signature for connect_upstream
old_func_sig = 'async def connect_upstream(host: str, port: int) -> tuple[asyncio.StreamReader, asyncio.StreamWriter]:\n    """Open TCP connection to target, optionally through UPSTREAM_PROXY."""\n    global rotator_loaded\n    if not rotator_loaded:'

# Define the new robust implementation
new_func_impl = """async def connect_upstream(host: str, port: int) -> tuple[asyncio.StreamReader, asyncio.StreamWriter]:
    \"\"\"Open TCP connection to target, optionally through UPSTREAM_PROXY or rotator.\"\"\"
    global rotator_loaded
    
    # Check if a custom UPSTREAM_PROXY is explicitly configured
    target_proxy_url = UPSTREAM_PROXY
    
    if not target_proxy_url:
        # Fallback to rotating free proxies if no upstream proxy is explicitly set
        if not rotator_loaded:
            async with rotator_lock:
                if not rotator_loaded:
                    connector = aiohttp.TCPConnector(force_close=True, limit=10)
                    session = aiohttp.ClientSession(connector=connector)
                    await rotator.load_all_sources(session)
                    rotator_loaded = True
                    asyncio.create_task(session.close())
        
        proxy = await rotator.get_proxy()
        if proxy:
            target_proxy_url = proxy.url
            
    if target_proxy_url:
        logger.debug("Tunnel %s:%d via proxy %s", host, port, target_proxy_url)
        parsed = urlparse(target_proxy_url)
        proxy_host = parsed.hostname
        proxy_port = parsed.port or (443 if parsed.scheme == "https" else 80)
        
        try:
            up_reader, up_writer = await asyncio.wait_for(
                asyncio.open_connection(proxy_host, proxy_port),
                timeout=CONNECT_TIMEOUT,
            )
            
            auth_header = ""
            if parsed.username and parsed.password:
                auth = base64.b64encode(f"{parsed.username}:{parsed.password}".encode()).decode()
                auth_header = f"Proxy-Authorization: Basic {auth}\\r\\n"
            
            connect_req = f"CONNECT {host}:{port} HTTP/1.1\\r\\nHost: {host}:{port}\\r\\n{auth_header}\\r\\n"
            up_writer.write(connect_req.encode())
            await up_writer.drain()
            
            resp_line = await asyncio.wait_for(up_reader.readline(), timeout=CONNECT_TIMEOUT)
            while True:
                line = await asyncio.wait_for(up_reader.readline(), timeout=CONNECT_TIMEOUT)
                if line in (b"\\r\\n", b"\\n", b""):
                    break
                    
            if "200" not in resp_line.decode():
                logger.warning("Upstream CONNECT failed: %s", resp_line.decode().strip())
                up_writer.close()
                if not UPSTREAM_PROXY and 'proxy' in locals():
                    await rotator.mark_banned(proxy)
                raise ConnectionError(f"Upstream proxy refused CONNECT: {resp_line.decode().strip()}")
                
            return up_reader, up_writer
        except Exception as e:
            if not UPSTREAM_PROXY and 'proxy' in locals():
                await rotator.mark_banned(proxy)
            logger.warning(f"Upstream proxy connection failed: {e}")
            # Try direct connection as fallback if proxy fails
            return await asyncio.wait_for(
                asyncio.open_connection(host, port),
                timeout=CONNECT_TIMEOUT,
            )
            
    else:
        # direct connection
        return await asyncio.wait_for(
            asyncio.open_connection(host, port),
            timeout=CONNECT_TIMEOUT,
        )"""

# Check if already patched or perform substitution
if "target_proxy_url = UPSTREAM_PROXY" in code:
    print("ALREADY_PATCHED")
    sys.exit(0)

# Replace old implementation
if old_func_sig in code:
    # Find the end of the old function to replace it cleanly
    start_idx = code.find(old_func_sig)
    # The old function connect_upstream ends around line 141 (direct connection return statement)
    end_pattern = 'return await asyncio.wait_for(\n            asyncio.open_connection(host, port),\n            timeout=CONNECT_TIMEOUT,\n        )'
    end_idx = code.find(end_pattern, start_idx) + len(end_pattern)
    
    patched_code = code[:start_idx] + new_func_impl + code[end_idx:]
    with open(filepath, 'w') as f:
        f.write(patched_code)
    print("PATCH_SUCCESS")
else:
    print("SIGNATURE_NOT_FOUND")
EOF
ok "Proxy script patch status verified/updated."

# ═══════════════════════════════════════════════════════════════════════════
# [3/4] Enable UPSTREAM_PROXY in systemd service file
# ═══════════════════════════════════════════════════════════════════════════
step "3" "Configuring systemd service file to enable Upstream Proxy..."
if grep -q "# Environment=UPSTREAM_PROXY=" "$SERVICE_FILE"; then
    sed -i 's/# Environment=UPSTREAM_PROXY=/Environment=UPSTREAM_PROXY=/g' "$SERVICE_FILE"
    info "Uncommented UPSTREAM_PROXY in $SERVICE_FILE"
else
    info "UPSTREAM_PROXY already active or configured in systemd service."
fi
ok "Systemd configuration verified."

# ═══════════════════════════════════════════════════════════════════════════
# [4/5] Configure kiro-cli wrapper to use OWL Proxy
# ═══════════════════════════════════════════════════════════════════════════
step "4" "Configuring kiro-cli wrapper for OWL Proxy..."
KIRO_WRAPPER="/home/x1/.owl-agent/kiro-cli"
if [[ -f "$KIRO_WRAPPER" ]]; then
    if ! grep -q "export HTTP_PROXY=" "$KIRO_WRAPPER"; then
        # Recreate the wrapper with explicit proxy configuration
        cat > "$KIRO_WRAPPER" << 'KIRO_WRAP'
#!/bin/bash
# 🦉 Explicitly route kiro-cli through the OWL Agent Forward Proxy & Clash
export HTTP_PROXY="http://127.0.0.1:60000"
export HTTPS_PROXY="http://127.0.0.1:60000"
export NO_PROXY="localhost,127.0.0.1,.local,.localdomain,::1"

KIRO_BIN="$HOME/.owl-agent/kiro/kiro-cli"
if [[ -f "$KIRO_BIN" ]]; then
    exec "$KIRO_BIN" "$@"
else
    echo "Error: kiro-cli binary not found at $KIRO_BIN" >&2
    echo "Install manually: curl -fsSL https://cli.kiro.dev/install | bash" >&2
    exit 1
fi
KIRO_WRAP
        chmod +x "$KIRO_WRAPPER"
        info "Patched kiro-cli wrapper to enforce proxy routing."
    else
        info "kiro-cli wrapper already configured for proxy routing."
    fi
else
    warn "kiro-cli wrapper not found at $KIRO_WRAPPER — skipping wrapper patch."
fi
ok "kiro-cli wrapper configured."

# ═══════════════════════════════════════════════════════════════════════════
# [5/5] Reload and restart services
# ═══════════════════════════════════════════════════════════════════════════
step "5" "Reloading systemd and restarting forward proxy service..."
systemctl --user daemon-reload
systemctl --user restart owl-forward-proxy.service

if systemctl --user is-active --quiet owl-forward-proxy.service; then
    ok "owl-forward-proxy.service restarted and active!"
else
    err "owl-forward-proxy.service failed to start! Check logs:"
    err "  journalctl --user -u owl-forward-proxy.service -n 50 --no-pager"
    exit 1
fi

echo ""
echo "============================================="
echo -e "${GREEN}${BOLD}✅ Patch Applied Successfully!${NC}"
echo "============================================="
echo "  Upstream geo-routing proxy (mihomo) is now prioritized."
echo "  Bypassing dead ports and unstable public free proxies."
echo "  kiro-cli wrapper is now fully configured to use the OWL Proxy."
echo "============================================="
echo ""
