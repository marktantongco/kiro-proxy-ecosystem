#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
#  🦉 OWL-AGENT UNIFIED INSTALLER v5.0 — self-contained
#
#  One script that installs the complete OWL-AGENT v4.5 stack:
#    • Core engine   — owl_server.py (:60000 API + :9091 Prometheus),
#                      proxy_defense.py (v4.5 ML + A/B + plugins),
#                      ml_models.py, plugin_loader.py
#    • Launcher      — run.sh (server / fetch / status / health / stats /
#                      doctor / registry / dns-channel)
#    • Systemd       — owl-agent.service (autostart + restart on failure)
#    • Port Guardian — port-guardian.sh + systemd timer (rogue-process eviction)
#    • Registries    — 7-format agent discovery files (SKILL.md, buff.yaml,
#                      jcode-skill.json, kiro-skill.toml, antigravity.json,
#                      opencode-skill.yaml, agent-manifest.json)
#    • kiro-cli      — native binary (arch/glibc auto-detect) + :60000 wrapper
#    • MCP server    — mcp-server.py + client config registration
#    • DNS channel   — HTTP-over-DNS tunnel client+server (self-contained)
#
#  All core scripts are EMBEDDED in this file (base64 payloads at the bottom).
#  No network dependency for the core stack; kiro-cli is downloaded from AWS S3.
#
#  Usage:
#    bash install_owl_agent.sh [command] [options]
#
#  Commands:
#    install   Install (default)
#    update    Re-apply embedded files + refresh deps + restart service
#    uninstall Remove ~/.owl-agent, service, timer, registry (asks first)
#    doctor    Diagnose the installation
#    status    Show service / port / health status
#
#  Options:
#    --home DIR             Install to DIR instead of $HOME/.owl-agent
#    --api-port N           API port (default 60000)
#    --metrics-port N       Prometheus port (default 9091)
#    --countries A B C      Country codes for proxy selection
#    --no-service           Do not install/start the systemd service
#    --no-deps              Skip pip dependency installation (fast tests)
#    --skip-kiro-cli        Do not install kiro-cli
#    --skip-dns             Do not install the DNS channel
#    --skip-mcp             Do not register the MCP server
#    --skip-registry        Do not write the 7-format agent registries
#    --skip-guardian        Do not install the port guardian
#    --yes                  Non-interactive (auto-confirm destructive steps)
#    --help                 Show this help
# ═══════════════════════════════════════════════════════════════════════

set -euo pipefail

# ── Version / configuration ────────────────────────────────────────────
OWL_VERSION="5.0"
CORE_VERSION="v4.5"
OWL_HOME="${OWL_HOME:-$HOME/.owl-agent}"
API_PORT="${OWL_API_PORT:-60000}"
METRICS_PORT="${OWL_METRICS_PORT:-9091}"
COUNTRIES=(US GB PH)
VENV_DIR="$OWL_HOME/venv"
PYTHON_CMD="$VENV_DIR/bin/python"
PIP_CMD="$VENV_DIR/bin/pip"
GITHUB_REPO="https://github.com/marktantongco/owl-agent"
KIRO_MANIFEST_URL="https://prod.download.cli.kiro.dev/stable/latest/manifest.json"
KIRO_BASE_URL="https://prod.download.cli.kiro.dev/stable"

# ── Flags ──────────────────────────────────────────────────────────────
CMD="${1:-install}"
DO_SERVICE=true
DO_DEPS=true
DO_KIRO=true
DO_DNS=true
DO_MCP=true
DO_REGISTRY=true
DO_GUARDIAN=true
ASSUME_YES=false

# ── Colors ─────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ── Logging helpers ───────────────────────────────────────────────────
log_info()  { echo -e "${GREEN}[INFO]${NC}  $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()  { echo -e "${BLUE}[STEP]${NC}  $1"; }
log_ok()    { echo -e "${GREEN}${BOLD}[OK]${NC}    $1"; }

# ── Arg parsing ────────────────────────────────────────────────────────
parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      install|update|uninstall|doctor|status) CMD="$1"; shift ;;
      --home) OWL_HOME="$2"; shift 2 ;;
      --api-port) API_PORT="$2"; shift 2 ;;
      --metrics-port) METRICS_PORT="$2"; shift 2 ;;
      --countries) COUNTRIES=("${@:2}"); break ;;
      --no-service) DO_SERVICE=false; shift ;;
      --no-deps) DO_DEPS=false; shift ;;
      --skip-kiro-cli) DO_KIRO=false; shift ;;
      --skip-dns) DO_DNS=false; shift ;;
      --skip-mcp) DO_MCP=false; shift ;;
      --skip-registry) DO_REGISTRY=false; shift ;;
      --skip-guardian) DO_GUARDIAN=false; shift ;;
      --yes) ASSUME_YES=true; shift ;;
      --help|-h) usage; exit 0 ;;
      *) log_warn "Unknown option: $1"; shift ;;
    esac
  done
  VENV_DIR="$OWL_HOME/venv"
  PYTHON_CMD="$VENV_DIR/bin/python"
  PIP_CMD="$VENV_DIR/bin/pip"
}

usage() {
  sed -n '2,48p' "$0" | sed 's/^# \{0,1\}//'
}

confirm() { # $1 = prompt
  if [ "$ASSUME_YES" = true ]; then return 0; fi
  echo -e "${YELLOW}⚠  $1 [y/N]${NC} "
  read -r REPLY
  [[ "$REPLY" =~ ^[Yy] ]]
}

# ── Helpers ────────────────────────────────────────────────────────────
gen_api_key() {
  if command -v openssl &>/dev/null; then
    openssl rand -hex 32
  else
    head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n'
  fi
}

install_file_b64() { # $1 target  $2 base64 data
  mkdir -p "$(dirname "$1")"
  if command -v base64 &>/dev/null; then
    printf '%s' "$2" | base64 -d > "$1"
  else
    python3 -c 'import base64,sys; open(sys.argv[1],"wb").write(base64.b64decode(sys.argv[2]))' "$1" "$2"
  fi
  chmod +x "$1" 2>/dev/null || true
}

# ═══════════════════════════════════════════════════════════════════════
# STEP 1 — System dependencies
# ═══════════════════════════════════════════════════════════════════════
step_system_deps() {
  log_step "1/9  System dependencies"
  local missing=()
  for c in python3 git curl; do
    command -v "$c" &>/dev/null || missing+=("$c")
  done
  if [ ${#missing[@]} -gt 0 ]; then
    log_warn "Missing: ${missing[*]} — attempting apt install"
    if command -v apt-get &>/dev/null; then
      sudo apt-get update -qq
      sudo apt-get install -y -qq python3 python3-pip python3-venv git curl
    else
      log_error "No apt-get available; please install ${missing[*]} manually."
      exit 1
    fi
  fi
  local pyver
  pyver=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
  if [[ "$(printf '%s\n' '3.10' "$pyver" | sort -V | head -n1)" != '3.10' ]]; then
    log_error "Python 3.10+ required (found $pyver)."
    exit 1
  fi
  log_ok "Python $pyver, git, curl ready"
}

# ═══════════════════════════════════════════════════════════════════════
# STEP 2 — Directory structure
# ═══════════════════════════════════════════════════════════════════════
step_dirs() {
  log_step "2/9  Directories under $OWL_HOME"
  mkdir -p "$OWL_HOME/cache/http" "$OWL_HOME/cache/proxy" "$OWL_HOME/cache/models"
  mkdir -p "$OWL_HOME/config" "$OWL_HOME/plugins" "$OWL_HOME/registry" "$OWL_HOME/mcp"
  log_ok "cache/ config/ plugins/ registry/ mcp/ ready"
}

# ═══════════════════════════════════════════════════════════════════════
# STEP 3 — Virtual environment + dependencies
# ═══════════════════════════════════════════════════════════════════════
step_venv() {
  log_step "3/9  Python virtual environment"
  if [ -x "$PYTHON_CMD" ]; then
    log_info "Reusing existing venv at $VENV_DIR"
  else
    python3 -m venv "$VENV_DIR"
  fi
  if [ "$DO_DEPS" = true ]; then
    "$PIP_CMD" install --quiet --upgrade pip wheel setuptools
    local retries=3 attempt=1
    while [ $attempt -le $retries ]; do
      log_info "Installing Python dependencies (attempt $attempt/$retries)..."
      if "$PIP_CMD" install --quiet -r "$OWL_HOME/requirements.txt"; then
        break
      fi
      attempt=$((attempt + 1))
      [ $attempt -le $retries ] && { log_warn "pip failed — retrying in 5s"; sleep 5; }
    done
    if [ $attempt -gt $retries ]; then
      log_warn "pip install failed after $retries attempts — continuing (imports may fail)"
    fi
  else
    log_warn "--no-deps set — skipping pip install"
  fi
  log_ok "venv ready at $VENV_DIR"
}

# ═══════════════════════════════════════════════════════════════════════
# STEP 4 — Core Python scripts (embedded payloads)
# ═══════════════════════════════════════════════════════════════════════
step_core_scripts() {
  log_step "4/9  Core engine scripts"
  install_file_b64 "$OWL_HOME/owl_server.py"      "$_EMBED_owl_server_py"
  install_file_b64 "$OWL_HOME/proxy_defense.py"   "$_EMBED_proxy_defense_py"
  install_file_b64 "$OWL_HOME/ml_models.py"       "$_EMBED_ml_models_py"
  install_file_b64 "$OWL_HOME/plugin_loader.py"   "$_EMBED_plugin_loader_py"
  install_file_b64 "$OWL_HOME/mcp-server.py"      "$_EMBED_mcp_server_py"

  # Make the MCP server resolve its own directory portably (was hardcoded).
  sed -i 's|sys.path.insert(0, "/home/ubuntu/.owl-agent")|sys.path.insert(0, os.environ.get("OWL_HOME", os.path.dirname(os.path.abspath(__file__))))|' \
    "$OWL_HOME/mcp-server.py" 2>/dev/null || true
  # mcp-server.py does not import os upstream — add it so the fix above works
  if ! grep -q '^import os' "$OWL_HOME/mcp-server.py" 2>/dev/null; then
    sed -i '1iimport os' "$OWL_HOME/mcp-server.py"
  fi

  # DNS channel (authored inline)
  cat > "$OWL_HOME/dns_channel.py" << 'DNSEOF'
#!/usr/bin/env python3
"""
🦉 OWL-AGENT DNS Channel — minimal HTTP-over-DNS TXT tunnel (client).

Sends a single HTTP request encoded into a DNS TXT query name (split across
63-char labels) and reads the response back from the TXT answer records.
Works when plain HTTP(S) egress is blocked but DNS is allowed.

Usage:
  python dns_channel.py --server 127.0.0.1 --port 5353 --domain owl.local \\
      --method GET --url https://example.com
"""
import argparse
import base64
import json
import sys
import time

LABEL_CHUNK = 55          # stay under the 63-char DNS label limit
MAX_B64 = 200             # keep the full DNS query name under the 255-octet limit


def _load_resolver(server, port, timeout):
    try:
        import dns.resolver

        r = dns.resolver.Resolver(configure=False)
        r.nameservers = [server]
        r.port = int(port)
        r.timeout = float(timeout)
        r.lifetime = float(timeout)
        return r
    except ImportError:
        sys.stderr.write(
            "ERROR: dnspython is required for the DNS channel. "
            "Run: pip install dnspython\n"
        )
        raise


def encode_qname(b64, domain):
    """Split the base64 payload into DNS labels, one chunk per label."""
    chunks = [b64[i:i + LABEL_CHUNK] for i in range(0, len(b64), LABEL_CHUNK)]
    return "r." + ".".join(chunks) + "." + domain


def fetch_over_dns(resolver, domain, method, url, headers=None, timeout=8, retries=3):
    payload = json.dumps({
        "method": method.upper(),
        "url": url,
        "headers": headers or {},
        "body": "",
    }).encode("utf-8")
    b64 = base64.urlsafe_b64encode(payload).decode().rstrip("=")
    if len(b64) > MAX_B64:
        raise RuntimeError(
            f"Request too large for DNS channel ({len(b64)} > {MAX_B64} chars). "
            "Use the HTTP channel for large requests."
        )
    qname = encode_qname(b64, domain)

    last_err = None
    for _ in range(retries):
        try:
            answers = resolver.resolve(qname, "TXT", raise_on_no_answer=True)
            parts = []
            for ans in answers:
                for txt in ans.strings:
                    parts.append(txt.decode("utf-8", errors="replace"))
            raw = "".join(parts)
            if not raw:
                continue
            return json.loads(raw)
        except Exception as exc:  # noqa: BLE001 — surfaced below
            last_err = exc
            time.sleep(0.5)
    raise RuntimeError(f"DNS channel request failed: {last_err}")


def main():
    ap = argparse.ArgumentParser(description="OWL-AGENT DNS channel client")
    ap.add_argument("--server", default="127.0.0.1")
    ap.add_argument("--port", default="5353")
    ap.add_argument("--domain", default="owl.local")
    ap.add_argument("--method", default="GET")
    ap.add_argument("--url", required=True)
    ap.add_argument("--timeout", type=float, default=8)
    args = ap.parse_args()

    resolver = _load_resolver(args.server, args.port, args.timeout)
    data = fetch_over_dns(
        resolver, args.domain, args.method, args.url, timeout=args.timeout
    )
    print(json.dumps(data, indent=2))


if __name__ == "__main__":
    main()
DNSEOF
  chmod +x "$OWL_HOME/dns_channel.py"

  cat > "$OWL_HOME/dns_tunnel_server.py" << 'DNSSEOF'
#!/usr/bin/env python3
"""
🦉 OWL-AGENT DNS Channel — minimal HTTP-over-DNS TXT tunnel (server).

Listens for UDP DNS queries shaped like  r.<b64chunk>...<domain> , decodes the
encoded HTTP request, performs it, and answers with the JSON response split
across TXT records (max 250 bytes each).

Requires root to bind port 53; the default is port 5353.
"""
import argparse
import base64
import json
import socket
import struct
import threading
import urllib.request
import urllib.error

RESPONSE_CHUNK = 250


def parse_query_name(data):
    """Return (qname, offset_after_name) for the first question in a DNS packet."""
    offset = 12
    labels = []
    while True:
        length = data[offset]
        offset += 1
        if length == 0:
            break
        if (length & 0xC0) == 0xC0:  # compression pointer is invalid in questions
            raise ValueError("compressed question name")
        labels.append(data[offset:offset + length])
        offset += length
    return b".".join(labels).decode("ascii", errors="replace"), offset


def _qname_wire(qname):
    return b"".join(bytes([len(p)]) + p for p in qname.encode().split(b".")) + b"\x00"


def build_txt_response(query_id, qname, records):
    """Build a DNS response with TXT answer records (no compression)."""
    header = struct.pack(">HHHHHH", query_id, 0x8180, 1, len(records), 0, 0)
    question = _qname_wire(qname) + struct.pack(">HH", 16, 1)  # TXT, IN
    answers = b""
    for record in records:
        if isinstance(record, str):
            record = record.encode("utf-8")
        chunks = [record[i:i + 255] for i in range(0, len(record), 255)]
        rdlen = sum(1 + len(c) for c in chunks)
        rdata = b"".join(bytes([len(c)]) + c for c in chunks)
        answers += b"\xc0\x0c" + struct.pack(">HHIH", 16, 1, 60, rdlen) + rdata
    return header + question + answers


def build_error_response(query_id, qname, message):
    payload = json.dumps({"error": message, "status": 0}).encode("utf-8")
    records = [payload[i:i + RESPONSE_CHUNK] for i in range(0, len(payload), RESPONSE_CHUNK)]
    return build_txt_response(query_id, qname, records)


def decode_request(qname, domain):
    """Reconstruct the base64 payload from a multi-label query name."""
    labels = qname.split(".")
    if not labels or labels[0] != "r":
        return None
    ndom = len(domain.split("."))
    if len(labels) <= 1 + ndom:
        return None
    return "".join(labels[1:-ndom])


def do_http(method, url, headers):
    req = urllib.request.Request(url, method=method, headers=headers or {})
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            body = resp.read()
            text = ""
            try:
                text = body.decode("utf-8", errors="replace")
            except Exception:
                pass
            return {"status": resp.status, "url": url, "body": text[:20000]}
    except urllib.error.HTTPError as exc:
        return {"status": exc.code, "url": url, "error": str(exc)}
    except Exception as exc:  # noqa: BLE001
        return {"status": 0, "url": url, "error": str(exc)}


def handle_packet(data, addr, domain="owl.local"):
    query_id = 0
    try:
        if len(data) < 12:
            return None
        query_id = struct.unpack(">H", data[:2])[0]
        qname, _ = parse_query_name(data)
    except Exception as exc:  # noqa: BLE001
        return build_error_response(query_id, "unknown.local", f"malformed packet: {exc}")

    try:
        if not qname.startswith("r."):
            return build_txt_response(query_id, qname, [b"OWL-AGENT DNS channel: unknown query"])
        encoded = decode_request(qname, domain)
        if encoded is None:
            return build_error_response(query_id, qname, "malformed request name")
        payload = base64.urlsafe_b64decode(encoded + "=" * (-len(encoded) % 4))
        req = json.loads(payload.decode("utf-8"))
        result = do_http(req.get("method", "GET"), req.get("url", ""), req.get("headers", {}))
        raw = json.dumps(result).encode("utf-8")
        records = [raw[i:i + RESPONSE_CHUNK] for i in range(0, len(raw), RESPONSE_CHUNK)]
        return build_txt_response(query_id, qname, records)
    except Exception as exc:  # noqa: BLE001
        return build_error_response(query_id, qname, f"decode/forward failed: {exc}")


def main():
    ap = argparse.ArgumentParser(description="OWL-AGENT DNS tunnel server")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=5353)
    ap.add_argument("--domain", default="owl.local")
    args = ap.parse_args()

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind((args.host, args.port))
    print(
        f"🦉 OWL-AGENT DNS tunnel server listening on {args.host}:{args.port} "
        f"(domain {args.domain})",
        flush=True,
    )

    def worker(payload, addr):
        response = handle_packet(payload, addr, args.domain)
        if response is not None:
            try:
                sock.sendto(response, addr)
            except OSError:
                pass

    while True:
        data, addr = sock.recvfrom(4096)
        threading.Thread(target=worker, args=(data, addr), daemon=True).start()


if __name__ == "__main__":
    main()
DNSSEOF
  chmod +x "$OWL_HOME/dns_tunnel_server.py"

  log_ok "owl_server.py, proxy_defense.py, ml_models.py, plugin_loader.py"
  log_ok "mcp-server.py, dns_channel.py, dns_tunnel_server.py installed"
}

# ═══════════════════════════════════════════════════════════════════════
# STEP 5 — Unified launcher (run.sh)
# ═══════════════════════════════════════════════════════════════════════
step_launcher() {
  log_step "5/9  Unified launcher run.sh"
  cat > "$OWL_HOME/run.sh" << RUNEOF
#!/usr/bin/env bash
# 🦉 OWL-AGENT Unified launcher (generated by install_owl_agent.sh)
set -euo pipefail

OWL_DIR="\$(cd "\$(dirname "\$0")" && pwd)"
VENV="\$OWL_DIR/venv"
API="\${OWL_API_PORT:-$API_PORT}"
export SSL_CERT_FILE="\${SSL_CERT_FILE:-/etc/ssl/certs/ca-certificates.crt}"
export CURL_CA_BUNDLE="\${CURL_CA_BUNDLE:-/etc/ssl/certs/ca-certificates.crt}"
export PYTHONWARNINGS="ignore::DeprecationWarning"
export OWL_HOME="\$OWL_DIR"

usage() {
    cat <<'HELP'
🦉 OWL-AGENT v4.5 — Self-Optimising Proxy HTTP Client

USAGE:
  \$0 server [--port 60000] [--metrics-port 9090] [--countries US GB PH] [--ab-test] [--ml] [--ml-model auto] [--plugin-dir plugins]
  \$0 fetch   <url> [--method GET] [--browser] [--dns]
  \$0 dns-channel --url <url> [--server 127.0.0.1 --port 5353]
  \$0 status | health | stats
  \$0 doctor
  \$0 registry

COMMANDS:
  server        Start the HTTP API + Prometheus metrics server (default)
  fetch         One-shot fetch a URL and print response
  dns-channel   Fetch a URL over the DNS tunnel (HTTP egress blocked)
  status        Show proxy pool health
  health        Quick health check
  stats         Detailed stats including A/B test and ML data
  doctor        Diagnose the installation
  registry      List the installed agent-registry files

EXAMPLES:
  \$0 server --ab-test --ml --ml-model auto
  \$0 fetch https://api.github.com/users/octocat
  \$0 fetch https://example.com --dns
  \$0 dns-channel --url https://example.com
  \$0 doctor
HELP
    exit 0
}

CMD="\${1:-server}"
shift || true

case "\$CMD" in
    server)
        exec "\$VENV/bin/python" "\$OWL_DIR/owl_server.py" "\$@"
        ;;
    fetch)
        URL="\${1:-}"
        if [ -z "\$URL" ]; then
            echo "❌ Usage: \$0 fetch <url> [options]"; exit 1
        fi
        shift
        METHOD="GET"; BROWSER="false"; USE_DNS="false"
        while [ \$# -gt 0 ]; do
            case "\$1" in
                --method) METHOD="\$2"; shift 2 ;;
                --browser) BROWSER="true"; shift ;;
                --dns) USE_DNS="true"; shift ;;
                --geo) shift 2 ;;
                *) shift ;;
            esac
        done
        if [ "\$USE_DNS" = "true" ]; then
            exec "\$VENV/bin/python" "\$OWL_DIR/dns_channel.py" --method "\$METHOD" --url "\$URL"
        fi
        PAYLOAD="{\"url\": \"\$URL\", \"method\": \"\$METHOD\", \"browser\": \$BROWSER}"
        curl -s -X POST "http://127.0.0.1:\$API/fetch" -H 'Content-Type: application/json' -d "\$PAYLOAD" | python3 -m json.tool
        ;;
    dns-channel)
        shift || true
        exec "\$VENV/bin/python" "\$OWL_DIR/dns_channel.py" "\$@"
        ;;
    status|health|stats)
        curl -s "http://127.0.0.1:\$API/\$CMD" | python3 -m json.tool
        ;;
    doctor)
        echo "🦉 OWL-AGENT doctor"
        echo "  python:   \$(\$VENV/bin/python --version 2>&1 || echo MISSING)"
        "\$VENV/bin/python" - <<'PY'
import importlib
mods = ["aiohttp", "httpx", "proxy_defense", "owl_server"]
for m in mods:
    try:
        importlib.import_module(m)
        print(f"  import {m}: OK")
    except Exception as e:
        print(f"  import {m}: FAIL ({e})")
PY
        echo "  health:   \$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:\$API/health 2>/dev/null || echo down)"
        ;;
    registry)
        ls -1 "\$OWL_DIR/registry" 2>/dev/null | sed 's/^/  /' || echo "  (none — re-run installer without --skip-registry)"
        ;;
    --help|-h)
        usage
        ;;
    *)
        echo "❌ Unknown command: \$CMD"; usage
        ;;
esac
RUNEOF
  chmod +x "$OWL_HOME/run.sh"
  log_ok "run.sh installed at $OWL_HOME/run.sh"
}

# ═══════════════════════════════════════════════════════════════════════
# STEP 6 — Config + sample plugin + requirements
# ═══════════════════════════════════════════════════════════════════════
step_config() {
  log_step "6/9  Config, sample plugin, requirements"
  local api_key
  # Reuse an existing key so reinstalls/updates don't break running clients
  if [ -f "$OWL_HOME/config/api_key" ]; then
    api_key="$(cat "$OWL_HOME/config/api_key" 2>/dev/null)"
  else
    api_key="$(gen_api_key)"
  fi

  cat > "$OWL_HOME/config/config.json" << CFGEOF
{
  "cache_ttl": 300,
  "rate_limit": 1.0,
  "max_retries": 3,
  "countries": [$(printf '"%s",' "${COUNTRIES[@]}" | sed 's/,$//')],
  "use_curl_cffi": true,
  "use_redis": false,
  "redis_url": "redis://localhost:6379",
  "enable_ab_test": true,
  "enable_ml": true,
  "ml_model": "auto",
  "plugin_dir": "$OWL_HOME/plugins",
  "api_key": "$api_key",
  "dns_channel": {
    "enabled": $([ "$DO_DNS" = true ] && echo true || echo false),
    "server_host": "127.0.0.1",
    "server_port": 5353,
    "domain": "owl.local",
    "max_response": 8000
  }
}
CFGEOF
  echo "$api_key" > "$OWL_HOME/config/api_key"
  chmod 600 "$OWL_HOME/config/api_key"

  cat > "$OWL_HOME/plugins/example_logger.py" << 'PLUGEOF'
"""Example plugin: logs all requests and responses."""
import logging

logger = logging.getLogger("owl-agent.plugin.example")


def on_request(method, url, **kwargs):
    logger.info("[Plugin] Request: %s %s", method, url)


def on_response(response, **kwargs):
    logger.info("[Plugin] Response: status=%s", response.status)


def on_error(error, attempt, url, **kwargs):
    logger.warning("[Plugin] Error on %s (attempt %s): %s", url, attempt, error)
PLUGEOF

  cat > "$OWL_HOME/requirements.txt" << 'REQEOF'
# OWL-AGENT v4.5 - Python Dependencies
# Core HTTP & Networking
httpx[socks]>=0.25.0
aiohttp>=3.9.0
aiofiles>=23.0.0
proxybroker2>=0.4.0
litproxy>=0.1.0
resilient-httpx>=0.1.0
circuitbreaker>=2.0.0
curl_cffi>=0.5.0
redis>=5.0.0

# Monitoring
prometheus-client>=0.19.0

# ML & Feature Engineering
scikit-learn>=1.3.0
numpy>=1.24.0
xgboost>=2.0.0
joblib>=1.3.0

# Plugin System
watchdog>=3.0.0

# DNS Channel
dnspython>=2.4.0
REQEOF
  log_ok "config.json (+api key), sample plugin, requirements.txt"
}

# ═══════════════════════════════════════════════════════════════════════
# STEP 7 — Systemd service
# ═══════════════════════════════════════════════════════════════════════
step_systemd() {
  log_step "7/12  Systemd service"
  if [ "$DO_SERVICE" != true ]; then
    log_warn "--no-service set — writing service file only (not enabling)"
  fi
  if ! command -v systemctl &>/dev/null; then
    log_warn "systemctl not found — service file written, not installed"
    DO_SERVICE=false
  fi
  local api_key
  api_key="$(cat "$OWL_HOME/config/api_key" 2>/dev/null || gen_api_key)"

  cat > "$OWL_HOME/owl-agent.service" << SVCEOF
[Unit]
Description=🦉 OWL-AGENT v$CORE_VERSION — Advanced ML + Self-Healing Plugins (unified installer $OWL_VERSION)
Documentation=$GITHUB_REPO
After=network.target

[Service]
Type=simple
User=$(id -un)
Group=$(id -gn)
WorkingDirectory=$OWL_HOME

Environment=SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
Environment=CURL_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt
Environment=PYTHONWARNINGS=ignore::DeprecationWarning
Environment=OWL_USE_REDIS=false
Environment=OWL_HOME=$OWL_HOME
Environment=OWL_API_KEY=$api_key

ExecStart=$PYTHON_CMD $OWL_HOME/owl_server.py \\
    --host 0.0.0.0 \\
    --api-port $API_PORT \\
    --metrics-port $METRICS_PORT \\
    --countries $(printf '%s ' "${COUNTRIES[@]}") \\
    --ab-test \\
    --ml \\
    --ml-model auto \\
    --plugin-dir $OWL_HOME/plugins

Restart=always
RestartSec=10

ProtectHome=false
NoNewPrivileges=true
PrivateDevices=true
ProtectSystem=full
CapabilityBoundingSet=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
SVCEOF

  if [ "$DO_SERVICE" = true ]; then
    sudo cp "$OWL_HOME/owl-agent.service" /etc/systemd/system/owl-agent.service
    sudo systemctl daemon-reload
    sudo systemctl enable owl-agent.service
    sudo systemctl restart owl-agent.service
    sleep 3
    if sudo systemctl is-active --quiet owl-agent.service; then
      log_ok "owl-agent.service active (ports $API_PORT / $METRICS_PORT)"
    else
      log_warn "Service failed to start — see: journalctl -u owl-agent.service -n 50"
    fi
  else
    log_warn "Service file written to $OWL_HOME/owl-agent.service (install manually if desired)"
  fi
}

# ═══════════════════════════════════════════════════════════════════════
# STEP 8 — Port guardian
# ═══════════════════════════════════════════════════════════════════════
step_guardian() {
  if [ "$DO_GUARDIAN" != true ]; then
    log_step "8/12  Port guardian — skipped (--skip-guardian)"
    return 0
  fi
  log_step "8/12  Port guardian"
  cat > "$OWL_HOME/port-guardian.sh" << 'GUARDEOF'
#!/usr/bin/env bash
# 🛡️ OWL-AGENT PORT GUARDIAN — evicts rogue processes stealing our ports.
# Runs every 60s via systemd timer (as root). Extend GUARDS with
# "service|port" pairs.
set -u

LOG_TAG="port-guardian"
GUARDS=(
  "owl-agent.service|__API_PORT__"
)
# Optional extra guards (uncomment or append):
# GUARDS+=("freebuff-node.service|8090")

log() { logger -t "$LOG_TAG" "$1"; echo "[$(date '+%F %T')] $1"; }

for pair in "${GUARDS[@]}"; do
  SVC="${pair%%|*}"
  PORT="${pair##*|}"

  if ! systemctl is-active --quiet "$SVC"; then
    log "⚠️  $SVC is DOWN — restarting"
    systemctl restart "$SVC"
    sleep 2
    if systemctl is-active --quiet "$SVC"; then
      log "✅ $SVC restarted successfully"
    else
      log "❌ $SVC FAILED to start (will retry next cycle)"
    fi
    continue
  fi

  HOLDER_PIDS=$(ss -tlnpH "sport = :$PORT" 2>/dev/null | grep -oP 'pid=\K[0-9]+' | sort -un | tr '\n' ' ')
  [ -z "$HOLDER_PIDS" ] && continue

  MAIN_PID=$(systemctl show -p MainPID --value "$SVC")
  ROGUE_PIDS=""
  for HOLDER_PID in $HOLDER_PIDS; do
    if [ -n "$MAIN_PID" ] && [ "$MAIN_PID" != "0" ] && [ "$HOLDER_PID" = "$MAIN_PID" ]; then
      continue
    fi
    CHILD_OF_SVC=$(ps -o ppid= -p "$HOLDER_PID" 2>/dev/null | tr -d ' ')
    if [ -n "$MAIN_PID" ] && [ "$MAIN_PID" != "0" ] && [ "$CHILD_OF_SVC" = "$MAIN_PID" ]; then
      continue
    fi
    ROGUE_PIDS="$ROGUE_PIDS $HOLDER_PID"
  done

  if [ -n "$ROGUE_PIDS" ]; then
    log "🚨 ROGUE pid=[${ROGUE_PIDS}] hold port $PORT ($SVC pid=$MAIN_PID) — KILLING"
    for R in $ROGUE_PIDS; do
      kill -9 "$R" 2>/dev/null && log "💀 Killed rogue pid=$R on port $PORT"
    done
    sleep 1
    log "🔄 Restarting $SVC to rebind port $PORT"
    systemctl restart "$SVC"
    sleep 2
    systemctl is-active --quiet "$SVC" && log "✅ $SVC healthy after rogue eviction" \
      || log "❌ $SVC failed after rogue eviction"
  fi
done
exit 0
GUARDEOF
  chmod +x "$OWL_HOME/port-guardian.sh"
  sed -i "s|__API_PORT__|$API_PORT|" "$OWL_HOME/port-guardian.sh"

  cat > "$OWL_HOME/port-guardian.timer" << 'TIMEREOF'
[Unit]
Description=OWL-AGENT port guardian — every 60s

[Timer]
OnBootSec=60
OnUnitActiveSec=60
AccuracySec=5

[Install]
WantedBy=timers.target
TIMEREOF

  cat > "$OWL_HOME/owl-port-guardian.service" << 'GSVCEOF'
[Unit]
Description=OWL-AGENT port guardian run (oneshot)
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/owl-port-guardian.sh
GSVCEOF

  if command -v systemctl &>/dev/null; then
    sudo cp "$OWL_HOME/port-guardian.sh" /usr/local/sbin/owl-port-guardian.sh
    sudo chmod +x /usr/local/sbin/owl-port-guardian.sh
    sudo cp "$OWL_HOME/port-guardian.timer" /etc/systemd/system/owl-port-guardian.timer
    sudo cp "$OWL_HOME/owl-port-guardian.service" /etc/systemd/system/owl-port-guardian.service
    sudo systemctl daemon-reload
    sudo systemctl enable owl-port-guardian.timer
    sudo systemctl start owl-port-guardian.timer
    log_ok "port-guardian timer installed"
  else
    log_warn "No systemctl — port-guardian.sh written to $OWL_HOME (run manually via cron if desired)"
  fi
}

# ═══════════════════════════════════════════════════════════════════════
# STEP 9 — 7-format agent registry
# ═══════════════════════════════════════════════════════════════════════
step_registry() {
  if [ "$DO_REGISTRY" != true ]; then
    log_step "9/12  Agent registries — skipped (--skip-registry)"
    return 0
  fi
  log_step "9/12  7-format agent registries"
  local REG="$OWL_HOME/registry"
  mkdir -p "$REG"

  cat > "$REG/SKILL.md" << 'SKEOF'
---
name: owl-agent
description: Resilient proxy-rotation HTTP client with ML scoring, plugins, DNS-tunnel fallback, and a Prometheus metrics server. Use for scraping, fetching URLs through rotating proxies, and bypassing blocked egress.
version: 4.5.0
tags: [scraping, proxy, http, dns]
---

# OWL-AGENT

Self-optimising proxy HTTP client: weighted proxy pool with per-domain circuit
breakers, A/B-tested strategies, ML-based proxy selection, plugin hooks, and a
DNS-channel fallback when HTTP egress is blocked.

## Usage

```bash
~/.owl-agent/run.sh fetch <url>
~/.owl-agent/run.sh fetch <url> --dns
~/.owl-agent/run.sh server --ab-test --ml
~/.owl-agent/run.sh doctor
```
SKEOF

  cat > "$REG/buff.yaml" << 'BUFFEOF'
name: owl-agent
description: Resilient proxy-rotation HTTP client (ML scoring, plugins, DNS tunnel fallback, Prometheus metrics)
version: 4.5.0
entry: ~/.owl-agent/run.sh
commands:
  fetch: "~/.owl-agent/run.sh fetch <url>"
  fetch-dns: "~/.owl-agent/run.sh fetch <url> --dns"
  status: "~/.owl-agent/run.sh status"
  doctor: "~/.owl-agent/run.sh doctor"
ports:
  api: 60000
  metrics: 9091
BUFFEOF

  cat > "$REG/jcode-skill.json" << 'JCEOF'
{
  "name": "owl-agent",
  "version": "4.5.0",
  "description": "Resilient proxy-rotation HTTP client with ML scoring, plugins, DNS-tunnel fallback",
  "entry": "~/.owl-agent/run.sh",
  "commands": {
    "owl-fetch": "~/.owl-agent/run.sh fetch",
    "owl-fetch-dns": "~/.owl-agent/run.sh fetch --dns",
    "owl-status": "~/.owl-agent/run.sh status",
    "owl-doctor": "~/.owl-agent/run.sh doctor"
  }
}
JCEOF

  cat > "$REG/kiro-skill.toml" << 'KIROEOF'
name = "owl-agent"
version = "4.5.0"
description = "Resilient proxy-rotation HTTP client with ML scoring, plugins, DNS-tunnel fallback"
entry = "~/.owl-agent/run.sh"

[commands]
owl-fetch = "~/.owl-agent/run.sh fetch"
owl-fetch-dns = "~/.owl-agent/run.sh fetch --dns"
owl-status = "~/.owl-agent/run.sh status"
KIROEOF

  cat > "$REG/antigravity.json" << 'AGEOF'
{
  "name": "owl-agent",
  "version": "4.5.0",
  "description": "Resilient proxy-rotation HTTP client (ML scoring, plugins, DNS tunnel fallback)",
  "entry": "~/.owl-agent/run.sh",
  "capabilities": ["fetch", "dns-channel", "status", "doctor"]
}
AGEOF

  cat > "$REG/opencode-skill.yaml" << 'OCEOF'
name: owl-agent
version: 4.5.0
description: Resilient proxy-rotation HTTP client with ML scoring, plugins, DNS-tunnel fallback
entry: ~/.owl-agent/run.sh
commands:
  - name: fetch
    run: "~/.owl-agent/run.sh fetch <url>"
  - name: fetch-dns
    run: "~/.owl-agent/run.sh fetch <url> --dns"
  - name: status
    run: "~/.owl-agent/run.sh status"
OCEOF

  cat > "$REG/agent-manifest.json" << 'MANEOF'
{
  "agent": "owl-agent",
  "version": "4.5.0",
  "type": "http-client",
  "entry": "~/.owl-agent/run.sh",
  "discovery": {
    "registry_formats": ["SKILL.md", "buff.yaml", "jcode-skill.json", "kiro-skill.toml", "antigravity.json", "opencode-skill.yaml", "agent-manifest.json"]
  },
  "endpoints": {
    "api": "http://127.0.0.1:60000",
    "metrics": "http://127.0.0.1:9091/metrics"
  }
}
MANEOF

  log_ok "registries written to $REG (7 formats)"
}

# ═══════════════════════════════════════════════════════════════════════
# STEP 10 — kiro-cli integration (native binary from AWS S3)
# ═══════════════════════════════════════════════════════════════════════
step_kiro_cli() {
  if [ "$DO_KIRO" != true ]; then
    log_step "10/12  kiro-cli — skipped (--skip-kiro-cli)"
    return 0
  fi
  log_step "10/12  kiro-cli native binary"
  local arch libc triple
  case "$(uname -m)" in
    x86_64|amd64) arch="x86_64" ;;
    aarch64|arm64) arch="aarch64" ;;
    *) log_warn "Unsupported arch $(uname -m) — skipping kiro-cli"; return 0 ;;
  esac
  libc="glibc"
  if command -v ldd &>/dev/null; then
    local gver
    gver=$(ldd --version 2>/dev/null | head -n1 | grep -oP '\d+\.\d+' | head -n1 || true)
    if [ -n "$gver" ] && ! awk "BEGIN {exit !($gver >= 2.34)}"; then
      libc="musl"
    fi
  else
    libc="musl"
  fi
  triple="${arch}-unknown-linux-$([ "$libc" = "musl" ] && echo musl || echo gnu)"
  log_info "Detected ${arch} / ${libc} (triple ${triple})"

  local tar_name version url tarpath
  tar_name="kirocli-${arch}-linux.tar.gz"
  [ "$libc" = "musl" ] && tar_name="kirocli-${arch}-linux-musl.tar.gz"
  version=$(curl -sfL "$KIRO_MANIFEST_URL" 2>/dev/null | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    print(''); sys.exit(0)
triple = '$triple'
for pkg in data.get('packages', []):
    if pkg.get('targetTriple') == triple and pkg.get('fileType') == 'tarGz' and pkg.get('variant') == 'headless':
        print(pkg['download']); sys.exit(0)
print('')
" 2>/dev/null || echo "$tar_name")
  url="$KIRO_BASE_URL/$version"
  tarpath="/tmp/kirocli_owl_$$.tar.gz"

  local ok=0 attempt=0
  while [ $attempt -lt 3 ]; do
    attempt=$((attempt + 1))
    log_info "Downloading kiro-cli (attempt $attempt/3)..."
    if curl -fsSL -C - --connect-timeout 15 --max-time 300 "$url" -o "$tarpath" 2>/dev/null; then
      ok=1; break
    fi
    sleep 5
  done
  if [ "$ok" != 1 ]; then
    log_warn "kiro-cli download failed — skipping (install manually from $url)"
    return 0
  fi

  rm -rf /tmp/kirocli_extracted_owl
  mkdir -p /tmp/kirocli_extracted_owl
  tar -xzf "$tarpath" -C /tmp/kirocli_extracted_owl
  local srcdir
  srcdir="$(find /tmp/kirocli_extracted_owl -type d -name bin | head -n1)"
  if [ -z "$srcdir" ]; then
    log_warn "kiro-cli archive layout unexpected — skipping"
    rm -f "$tarpath"; rm -rf /tmp/kirocli_extracted_owl
    return 0
  fi

  mkdir -p "$HOME/.local/bin"
  for bin in kiro-cli kiro-cli-chat kiro-cli-term q qchat; do
    if [ -f "$srcdir/$bin" ]; then
      install -m 755 "$srcdir/$bin" "$HOME/.local/bin/$bin"
      [ -f "$srcdir/$bin" ] && cp "$srcdir/$bin" "$VENV_DIR/bin/$bin" 2>/dev/null || true
      log_ok "$bin -> $HOME/.local/bin"
    fi
  done

  # kiro-cli wrapper that routes through the OWL-AGENT forward proxy
  cat > "$OWL_HOME/kiro-cli" << 'KIROWRAP'
#!/bin/bash
# 🦉 Route kiro-cli through the OWL-AGENT proxy (:60000)
export HTTP_PROXY="http://127.0.0.1:60000"
export HTTPS_PROXY="http://127.0.0.1:60000"
export NO_PROXY="localhost,127.0.0.1,.local,.localdomain,::1"
exec "$HOME/.local/bin/kiro-cli" "$@"
KIROWRAP
  chmod +x "$OWL_HOME/kiro-cli"

  # Initialize a valid blank SQLite DB so kiro-cli works before login
  local db="$HOME/.local/share/kiro-cli/data.sqlite3"
  if [ ! -f "$db" ]; then
    mkdir -p "$(dirname "$db")"
    python3 - << 'SQLPY'
import sqlite3, os, time
db = os.path.expanduser("~/.local/share/kiro-cli/data.sqlite3")
os.makedirs(os.path.dirname(db), exist_ok=True)
conn = sqlite3.connect(db)
c = conn.cursor()
c.executescript("""
CREATE TABLE IF NOT EXISTS auth_kv (key TEXT PRIMARY KEY, value TEXT);
CREATE TABLE IF NOT EXISTS state (key TEXT PRIMARY KEY, value BLOB);
CREATE TABLE IF NOT EXISTS migrations (id INTEGER PRIMARY KEY, version INTEGER NOT NULL, migration_time INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS history (id INTEGER PRIMARY KEY, command TEXT, shell TEXT, pid INTEGER, session_id TEXT, cwd TEXT, start_time INTEGER, hostname TEXT, exit_code INTEGER, end_time INTEGER, duration INTEGER);
CREATE TABLE IF NOT EXISTS conversations (key TEXT PRIMARY KEY, value TEXT);
CREATE TABLE IF NOT EXISTS conversations_v2 (key TEXT NOT NULL, conversation_id TEXT NOT NULL, value TEXT NOT NULL, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL, PRIMARY KEY (key, conversation_id));
""")
conn.commit(); conn.close()
print("initialized", db)
SQLPY
    log_ok "blank kiro-cli DB initialized at $db"
  fi

  rm -f "$tarpath"; rm -rf /tmp/kirocli_extracted_owl
  log_ok "kiro-cli integration complete (run 'kiro-cli setup' to authenticate)"
}

# ═══════════════════════════════════════════════════════════════════════
# STEP 11 — MCP server registration
# ═══════════════════════════════════════════════════════════════════════
step_mcp() {
  if [ "$DO_MCP" != true ]; then
    log_step "11/12  MCP server — skipped (--skip-mcp)"
    return 0
  fi
  log_step "11/12  MCP server registration"

  cat > "$OWL_HOME/mcp/config.json" << 'MCPEOF'
{
  "mcpServers": {
    "owl-agent": {
      "command": "PYTHON_CMD_PLACEHOLDER",
      "args": ["MCP_SERVER_PLACEHOLDER"],
      "env": {
        "OWL_HOME": "OWL_HOME_PLACEHOLDER",
        "OWL_API_KEY": "OWL_API_KEY_PLACEHOLDER"
      },
      "disabled": false,
      "autoApprove": ["*"]
    }
  }
}
MCPEOF
  local key
  key="$(cat "$OWL_HOME/config/api_key" 2>/dev/null || gen_api_key)"
  python3 - "$OWL_HOME/mcp/config.json" "$PYTHON_CMD" "$OWL_HOME/mcp-server.py" "$OWL_HOME" "$key" << 'MCPPLACE'
import sys
path, py, server, owl_home, key = sys.argv[1:6]
with open(path) as f:
    raw = f.read()
for token, value in (("PYTHON_CMD_PLACEHOLDER", py),
                     ("MCP_SERVER_PLACEHOLDER", server),
                     ("OWL_HOME_PLACEHOLDER", owl_home),
                     ("OWL_API_KEY_PLACEHOLDER", key)):
    raw = raw.replace(token, value)
with open(path, "w") as f:
    f.write(raw)
print("mcp config templated")
MCPPLACE

  # Register with Kiro CLI if its MCP settings exist
  local kiro_mcp="$HOME/.kiro/settings/mcp.json"
  if [ -f "$kiro_mcp" ]; then
    if python3 - "$kiro_mcp" "$PYTHON_CMD" "$OWL_HOME/mcp-server.py" "$OWL_HOME" << 'MCPPY'
import json, sys, os
path, py, server, owl_home = sys.argv[1:5]
try:
    with open(path) as f:
        cfg = json.load(f)
except Exception:
    cfg = {}
servers = cfg.setdefault("mcpServers", {})
servers["owl-agent"] = {
    "command": py,
    "args": [server],
    "env": {"OWL_HOME": owl_home},
    "disabled": False,
    "autoApprove": ["*"],
}
with open(path, "w") as f:
    json.dump(cfg, f, indent=2)
print("registered owl-agent in", path)
MCPPY
    then
      log_ok "owl-agent MCP server registered in $kiro_mcp"
    else
      log_warn "Could not merge MCP config at $kiro_mcp"
    fi
  else
    log_info "No ~/.kiro/settings/mcp.json — MCP config written to $OWL_HOME/mcp/config.json"
  fi
  log_ok "MCP server file: $OWL_HOME/mcp-server.py"
}

# ═══════════════════════════════════════════════════════════════════════
# STEP 12 — DNS channel launcher script
# ═══════════════════════════════════════════════════════════════════════
step_dns() {
  if [ "$DO_DNS" != true ]; then
    log_step "12/12  DNS channel — skipped (--skip-dns)"
    return 0
  fi
  log_step "12/12  DNS channel launcher"

  cat > "$OWL_HOME/start-dns-server.sh" << 'DNSSH'
#!/usr/bin/env bash
# 🦉 Start the OWL-AGENT DNS tunnel server.
# NOTE: port 53 requires root; default is 5353 (no root needed).
set -euo pipefail
PORT="${1:-5353}"
HOST="${OWL_DNS_HOST:-127.0.0.1}"
exec "$HOME/.owl-agent/venv/bin/python" "$HOME/.owl-agent/dns_tunnel_server.py" --host "$HOST" --port "$PORT"
DNSSH
  chmod +x "$OWL_HOME/start-dns-server.sh"

  log_info "DNS tunnel server: $OWL_HOME/start-dns-server.sh [port]"
  log_info "Client usage:      $OWL_HOME/run.sh fetch <url> --dns"
}

# ═══════════════════════════════════════════════════════════════════════
# STEP 13 — Verification
# ═══════════════════════════════════════════════════════════════════════
step_verify() {
  log_step "Verification"
  if [ -x "$PYTHON_CMD" ]; then
    if "$PYTHON_CMD" -c "
import importlib
for m in ['proxy_defense', 'owl_server', 'ml_models', 'plugin_loader']:
    importlib.import_module(m)
print('core imports OK')
" 2>/dev/null; then
      log_ok "Core engine imports verified"
    else
      log_warn "Import test had issues — deps may be incomplete (check: $PYTHON_CMD -m pip install -r $OWL_HOME/requirements.txt)"
    fi
  fi
  if [ "$DO_SERVICE" = true ]; then
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "http://127.0.0.1:$API_PORT/health" 2>/dev/null || echo 000)
    if [ "$code" = "200" ]; then
      log_ok "Health check http://127.0.0.1:$API_PORT/health -> 200"
    else
      log_warn "Health check returned $code (service not running? start with: sudo systemctl start owl-agent.service)"
    fi
  else
    log_warn "--no-service — skipping health check"
  fi
}

# ═══════════════════════════════════════════════════════════════════════
# COMMANDS
# ═══════════════════════════════════════════════════════════════════════
cmd_install() {
  echo -e "${CYAN}${BOLD}════════════════════════════════════════════════════════${NC}"
  echo -e "${CYAN}${BOLD}  🦉 OWL-AGENT Unified Installer v${OWL_VERSION}${NC}"
  echo -e "${CYAN}${BOLD}  Target: ${OWL_HOME}   API :${API_PORT}  Metrics :${METRICS_PORT}${NC}"
  echo -e "${CYAN}${BOLD}════════════════════════════════════════════════════════${NC}"
  echo ""

  step_system_deps
  step_dirs
  step_venv
  step_core_scripts
  step_launcher
  step_config
  step_systemd
  step_guardian
  step_registry
  step_kiro_cli
  step_mcp
  step_dns
  step_verify

  echo ""
  log_ok "OWL-AGENT ${CORE_VERSION} installed at $OWL_HOME"
  echo "  Launcher:    $OWL_HOME/run.sh"
  echo "  Health:      curl http://127.0.0.1:$API_PORT/health"
  echo "  Fetch:       $OWL_HOME/run.sh fetch https://example.com"
  echo "  DNS fetch:   $OWL_HOME/run.sh fetch https://example.com --dns"
  echo "  Service:     sudo systemctl status owl-agent.service"
  echo "  Doctor:      $OWL_HOME/run.sh doctor"
  echo ""
}

cmd_update() {
  log_info "Updating OWL-AGENT at $OWL_HOME (re-applying embedded files + refreshing deps)"
  step_dirs
  step_venv
  step_core_scripts
  step_launcher
  step_config
  step_systemd
  step_guardian
  step_registry
  step_dns
  step_verify
  log_ok "Update complete"
}

cmd_uninstall() {
  echo "🦉 OWL-AGENT uninstall"
  echo "  Will remove: $OWL_HOME, systemd service + timer, port-guardian, registries."
  # Safety guard: never allow destructive removal of critical paths
  if [ -z "$OWL_HOME" ] || [ "$OWL_HOME" = "/" ] || [ "$OWL_HOME" = "$HOME" ]; then
    log_error "Refusing to remove '$OWL_HOME' (path guard)."
    exit 1
  fi
  confirm "Continue?" || { echo "Aborted."; exit 0; }

  if command -v systemctl &>/dev/null; then
    sudo systemctl stop owl-agent.service 2>/dev/null || true
    sudo systemctl disable owl-agent.service 2>/dev/null || true
    sudo rm -f /etc/systemd/system/owl-agent.service
    sudo systemctl stop owl-port-guardian.timer 2>/dev/null || true
    sudo systemctl disable owl-port-guardian.timer 2>/dev/null || true
    sudo rm -f /etc/systemd/system/owl-port-guardian.timer /etc/systemd/system/owl-port-guardian.service
    sudo rm -f /usr/local/sbin/owl-port-guardian.sh
    sudo systemctl daemon-reload
  fi

  # Remove the owl-agent MCP registration (avoid dangling server entry)
  local kiro_mcp="$HOME/.kiro/settings/mcp.json"
  if [ -f "$kiro_mcp" ]; then
    python3 - "$kiro_mcp" << 'MCPUN'
import json, sys
path = sys.argv[1]
try:
    with open(path) as f:
        cfg = json.load(f)
except Exception:
    sys.exit(0)
servers = cfg.get("mcpServers", {})
if "owl-agent" in servers:
    del servers["owl-agent"]
    with open(path, "w") as f:
        json.dump(cfg, f, indent=2)
    print("removed owl-agent MCP entry from", path)
MCPUN
  fi

  if confirm "Remove $OWL_HOME entirely? (config, cache, venv, logs)"; then
    if [ -z "$OWL_HOME" ] || [ "$OWL_HOME" = "/" ]; then
      log_error "Path guard: refusing rm -rf of '$OWL_HOME'"
    else
      rm -rf "$OWL_HOME"
      log_ok "Removed $OWL_HOME"
    fi
  else
    log_info "Keeping $OWL_HOME"
  fi

  rm -f "$HOME/.local/bin/owl-fetch" 2>/dev/null || true
  log_ok "Uninstall complete (system kiro-cli left in place — shared tool)"
}

cmd_doctor() {
  echo "🦉 OWL-AGENT doctor"
  echo "  Home:      $OWL_HOME"
  [ -d "$OWL_HOME" ] && echo "  exists:    yes" || { echo "  exists:    NO — not installed"; exit 1; }
  [ -x "$PYTHON_CMD" ] && echo "  python:    $("$PYTHON_CMD" --version 2>&1)" || echo "  python:    MISSING"
  for f in owl_server.py proxy_defense.py ml_models.py plugin_loader.py mcp-server.py run.sh; do
    [ -f "$OWL_HOME/$f" ] && echo "  file:      $f ok" || echo "  file:      $f MISSING"
  done
  if command -v systemctl &>/dev/null && sudo systemctl is-active --quiet owl-agent.service 2>/dev/null; then
    echo "  service:   active"
  else
    echo "  service:   not active"
  fi
  local code
  code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "http://127.0.0.1:$API_PORT/health" 2>/dev/null || echo 000)
  echo "  health:    HTTP $code"
  command -v kiro-cli >/dev/null 2>&1 && echo "  kiro-cli:  $HOME/.local/bin/kiro-cli" || echo "  kiro-cli:  not installed"
  echo "  registry:  $(ls "$OWL_HOME/registry" 2>/dev/null | wc -l) files"
  echo "  dns chan:  $([ "$DO_DNS" = true ] && ls "$OWL_HOME/dns_channel.py" >/dev/null 2>&1 && echo ready || echo n/a)"
}

cmd_status() {
  if command -v systemctl &>/dev/null; then
    sudo systemctl status owl-agent.service --no-pager 2>/dev/null | head -8 || true
  fi
  local code
  code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "http://127.0.0.1:$API_PORT/health" 2>/dev/null || echo 000)
  echo ""
  echo "  API :$API_PORT      health HTTP $code"
  echo "  Metrics :$METRICS_PORT  $(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:$METRICS_PORT/metrics 2>/dev/null || echo down)"
}

# ═══════════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════════
main() {
  parse_args "$@"
  case "$CMD" in
    install)   cmd_install ;;
    update)    cmd_update ;;
    uninstall) cmd_uninstall ;;
    doctor)    cmd_doctor ;;
    status)    cmd_status ;;
    *)         usage; exit 1 ;;
  esac
}

# ── EMBEDDED PAYLOADS (generated — do not edit) ────────────────────────
_EMBED_owl_server_py="IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiIK8J+miSBPV0wtQUdFTlQgdjQuNSAtIEhUVFAgQVBJIFNlcnZlcgo9PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT0KV3JhcHMgUmVzaWxpZW50Q2xpZW50IGluIGEgcHJvZHVjdGlvbiBhc3luYyBIVFRQIHNlcnZlci4KLSAvZmV0Y2ggICBQT1NUICAgRmV0Y2ggYSBVUkwgdGhyb3VnaCB0aGUgaW50ZWxsaWdlbnQgcHJveHkgcG9vbAotIC9icm93c2VyIFBPU1QgICBGZXRjaCB2aWEgYWdlbnQtYnJvd3NlciBoZWFkbGVzcyBicm93c2VyCi0gL2hlYWx0aCAgR0VUICAgIEhlYWx0aCBjaGVjawotIC9zdGF0cyAgIEdFVCAgICBQcm94eSBwb29sIHN0YXRzCi0gL21ldHJpY3MgR0VUICAgIFByb21ldGhldXMgbWV0cmljcyAocG9ydCA5MDkwKQoiIiIKCmltcG9ydCBhc3luY2lvCmltcG9ydCBobWFjCmltcG9ydCBqc29uCmltcG9ydCBvcwppbXBvcnQgc2VjcmV0cwppbXBvcnQgdGltZQppbXBvcnQgbG9nZ2luZwpmcm9tIHBhdGhsaWIgaW1wb3J0IFBhdGgKZnJvbSB0eXBpbmcgaW1wb3J0IE9wdGlvbmFsCgppbXBvcnQgYWlvaHR0cApmcm9tIGFpb2h0dHAgaW1wb3J0IHdlYgoKIyBQcm9tZXRoZXVzIG1ldHJpY3MKZnJvbSBwcm9tZXRoZXVzX2NsaWVudCBpbXBvcnQgQ291bnRlciwgR2F1Z2UsIEhpc3RvZ3JhbSwgZ2VuZXJhdGVfbGF0ZXN0LCBSRUdJU1RSWSwgQ09OVEVOVF9UWVBFX0xBVEVTVAoKZnJvbSBwcm94eV9kZWZlbnNlIGltcG9ydCBSZXNpbGllbnRDbGllbnQsIENhY2hlZFJlc3BvbnNlLCBsb2dnZXIKCiMg4pSA4pSA4pSAIFByb21ldGhldXMgTWV0cmljcyDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIAKUkVRVUVTVFNfVE9UQUwgPSBDb3VudGVyKAogICAgIm93bF9yZXF1ZXN0c190b3RhbCIsICJUb3RhbCByZXF1ZXN0cyBwcm9jZXNzZWQiLCBbIm1ldGhvZCIsICJzdGF0dXMiXQopClBST1hZX1BPT0xfU0laRSA9IEdhdWdlKCJvd2xfcHJveHlfcG9vbF9zaXplIiwgIk51bWJlciBvZiBwcm94aWVzIGluIHBvb2wiKQpQUk9YWV9IRUFMVEhZID0gR2F1Z2UoIm93bF9wcm94eV9oZWFsdGh5IiwgIk51bWJlciBvZiBoZWFsdGh5IHByb3hpZXMiKQpSRVFVRVNUX0xBVEVOQ1kgPSBIaXN0b2dyYW0oCiAgICAib3dsX3JlcXVlc3RfbGF0ZW5jeV9zZWNvbmRzIiwgIlJlcXVlc3QgbGF0ZW5jeSBpbiBzZWNvbmRzIiwKICAgIGJ1Y2tldHM9WzAuMSwgMC41LCAxLjAsIDIuMCwgNS4wLCAxMC4wLCAzMC4wLCA2MC4wXQopCkNBQ0hFX0hJVFMgPSBDb3VudGVyKCJvd2xfY2FjaGVfaGl0c190b3RhbCIsICJDYWNoZSBoaXQgY291bnQiKQpDQUNIRV9NSVNTRVMgPSBDb3VudGVyKCJvd2xfY2FjaGVfbWlzc2VzX3RvdGFsIiwgIkNhY2hlIG1pc3MgY291bnQiKQpQT09MX1JFRlJFU0hfQ09VTlQgPSBDb3VudGVyKCJvd2xfcG9vbF9yZWZyZXNoX3RvdGFsIiwgIlByb3h5IHBvb2wgcmVmcmVzaCBjeWNsZXMiKQoKIyDilIDilIDilIAgQXV0aCBNaWRkbGV3YXJlIOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgAoKZGVmIGNyZWF0ZV9hdXRoX21pZGRsZXdhcmUoYXBpX2tleTogc3RyKToKICAgICIiIlJlcXVpcmUgQVBJIGtleSBvbiBhbGwgZW5kcG9pbnRzIGV4Y2VwdCAvaGVhbHRoLgoKICAgIEFjY2VwdHMgZWl0aGVyIGBBdXRob3JpemF0aW9uOiBCZWFyZXIgPGtleT5gIG9yIGBYLUFQSS1LZXk6IDxrZXk+YC4KICAgIC9oZWFsdGggaXMgbGVmdCBvcGVuIHNvIG9yY2hlc3RyYXRvcnMvc3lzdGVtZCBjYW4gcHJvYmUgbGl2ZW5lc3MuCiAgICAiIiIKICAgIEB3ZWIubWlkZGxld2FyZQogICAgYXN5bmMgZGVmIGF1dGhfbWlkZGxld2FyZShyZXF1ZXN0OiB3ZWIuUmVxdWVzdCwgaGFuZGxlcik6CiAgICAgICAgaWYgcmVxdWVzdC5wYXRoID09ICIvaGVhbHRoIjoKICAgICAgICAgICAgcmV0dXJuIGF3YWl0IGhhbmRsZXIocmVxdWVzdCkKICAgICAgICBoZWFkZXIgPSByZXF1ZXN0LmhlYWRlcnMuZ2V0KCJBdXRob3JpemF0aW9uIiwgIiIpCiAgICAgICAgaWYgaGVhZGVyLnN0YXJ0c3dpdGgoIkJlYXJlciAiKToKICAgICAgICAgICAgaGVhZGVyID0gaGVhZGVyWzc6XQogICAgICAgIGVsaWYgcmVxdWVzdC5oZWFkZXJzLmdldCgiWC1BUEktS2V5Iik6CiAgICAgICAgICAgIGhlYWRlciA9IHJlcXVlc3QuaGVhZGVycy5nZXQoIlgtQVBJLUtleSIpCiAgICAgICAgaWYgbm90IGhlYWRlciBvciBub3QgYXBpX2tleSBvciBub3QgaG1hYy5jb21wYXJlX2RpZ2VzdChoZWFkZXIuZW5jb2RlKCksIGFwaV9rZXkuZW5jb2RlKCkpOgogICAgICAgICAgICByZXR1cm4gd2ViLmpzb25fcmVzcG9uc2UoCiAgICAgICAgICAgICAgICB7ImVycm9yIjogIlVuYXV0aG9yaXplZCAtIG1pc3Npbmcgb3IgaW52YWxpZCBBUEkga2V5In0sCiAgICAgICAgICAgICAgICBzdGF0dXM9NDAxLAogICAgICAgICAgICApCiAgICAgICAgcmV0dXJuIGF3YWl0IGhhbmRsZXIocmVxdWVzdCkKICAgIHJldHVybiBhdXRoX21pZGRsZXdhcmUKCgojIOKUgOKUgOKUgCBIVFRQIEFQSSBIYW5kbGVycyDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIAKCmNsYXNzIE93bFNlcnZlcjoKICAgIGRlZiBfX2luaXRfXyhzZWxmLCBob3N0OiBzdHIgPSAiMC4wLjAuMCIsIGFwaV9wb3J0OiBpbnQgPSA2MDAwMCwKICAgICAgICAgICAgICAgICBtZXRyaWNzX3BvcnQ6IGludCA9IDkwOTAsIGFwaV9rZXk6IE9wdGlvbmFsW3N0cl0gPSBOb25lLAogICAgICAgICAgICAgICAgICoqY2xpZW50X2t3YXJncyk6CiAgICAgICAgc2VsZi5ob3N0ID0gaG9zdAogICAgICAgIHNlbGYuYXBpX3BvcnQgPSBhcGlfcG9ydAogICAgICAgIHNlbGYubWV0cmljc19wb3J0ID0gbWV0cmljc19wb3J0CiAgICAgICAgc2VsZi5hcGlfa2V5ID0gYXBpX2tleQogICAgICAgIHNlbGYuY2xpZW50X2t3YXJncyA9IGNsaWVudF9rd2FyZ3MKICAgICAgICBzZWxmLmNsaWVudDogT3B0aW9uYWxbUmVzaWxpZW50Q2xpZW50XSA9IE5vbmUKICAgICAgICBzZWxmLl9hcGlfcnVubmVyOiBPcHRpb25hbFt3ZWIuQXBwUnVubmVyXSA9IE5vbmUKICAgICAgICBzZWxmLl9tZXRyaWNzX3NpdGU6IE9wdGlvbmFsW2FzeW5jaW8uQWJzdHJhY3RTZXJ2ZXJdID0gTm9uZQogICAgICAgIHNlbGYuX3N0YXJ0X3RpbWU6IGZsb2F0ID0gMC4wCgogICAgYXN5bmMgZGVmIHN0YXJ0KHNlbGYpOgogICAgICAgICIiIlN0YXJ0IHRoZSBBUEkgc2VydmVyIGFuZCBtZXRyaWNzIGVuZHBvaW50LiIiIgogICAgICAgIHNlbGYuY2xpZW50ID0gUmVzaWxpZW50Q2xpZW50KCoqc2VsZi5jbGllbnRfa3dhcmdzKQogICAgICAgIGF3YWl0IHNlbGYuY2xpZW50Ll9fYWVudGVyX18oKQoKICAgICAgICAjIFN0YXJ0IHBsdWdpbiBsb2FkZXIgZGlzY292ZXJ5CiAgICAgICAgaWYgc2VsZi5jbGllbnQucGx1Z2luX2xvYWRlcjoKICAgICAgICAgICAgYXdhaXQgc2VsZi5jbGllbnQucGx1Z2luX2xvYWRlci5zdGFydCgpCiAgICAgICAgICAgIHN0YXRzID0gc2VsZi5jbGllbnQucGx1Z2luX2xvYWRlci5nZXRfc3RhdHMoKQogICAgICAgICAgICBsb2dnZXIuaW5mbyhmIvCflIwgUGx1Z2lucyBsb2FkZWQ6IHtzdGF0c1sndG90YWwnXX0gKHsnLCAnLmpvaW4oc3RhdHNbJ3BsdWdpbnMnXS5rZXlzKCkpIGlmIHN0YXRzWydwbHVnaW5zJ10gZWxzZSAnbm9uZSd9KSIpCgogICAgICAgICMgQVBJIHNlcnZlciAocG9ydCA2MDAwMCkKICAgICAgICBhcHAgPSB3ZWIuQXBwbGljYXRpb24obWlkZGxld2FyZXM9W2NyZWF0ZV9hdXRoX21pZGRsZXdhcmUoc2VsZi5hcGlfa2V5KV0pCiAgICAgICAgYXBwLnJvdXRlci5hZGRfcG9zdCgiL2ZldGNoIiwgc2VsZi5oYW5kbGVfZmV0Y2gpCiAgICAgICAgYXBwLnJvdXRlci5hZGRfcG9zdCgiL2Jyb3dzZXIiLCBzZWxmLmhhbmRsZV9icm93c2VyKQogICAgICAgIGFwcC5yb3V0ZXIuYWRkX2dldCgiL2hlYWx0aCIsIHNlbGYuaGFuZGxlX2hlYWx0aCkKICAgICAgICBhcHAucm91dGVyLmFkZF9nZXQoIi9zdGF0cyIsIHNlbGYuaGFuZGxlX3N0YXRzKQoKICAgICAgICAjIE9wZW5BSS1jb21wYXRpYmxlIGVuZHBvaW50cyAoZm9yIG9wZW5jb2RlIENMSSBpbnRlZ3JhdGlvbikKICAgICAgICBhcHAucm91dGVyLmFkZF9wb3N0KCIvdjEvY2hhdC9jb21wbGV0aW9ucyIsIHNlbGYuaGFuZGxlX29wZW5haV9jaGF0KQogICAgICAgIGFwcC5yb3V0ZXIuYWRkX2dldCgiL3YxL21vZGVscyIsIHNlbGYuaGFuZGxlX29wZW5haV9tb2RlbHMpCiAgICAgICAgYXBwLnJvdXRlci5hZGRfcG9zdCgiL3YxL21lc3NhZ2VzIiwgc2VsZi5oYW5kbGVfY2xhdWRlX21lc3NhZ2VzKQogICAgICAgIGFwcC5yb3V0ZXIuYWRkX3Bvc3QoIi92MS9tZXNzYWdlcy9jb3VudF90b2tlbnMiLCBzZWxmLmhhbmRsZV9jbGF1ZGVfY291bnRfdG9rZW5zKQoKICAgICAgICBhcHAub25fc2h1dGRvd24uYXBwZW5kKHNlbGYuX29uX3NodXRkb3duKQoKICAgICAgICBzZWxmLl9hcGlfcnVubmVyID0gd2ViLkFwcFJ1bm5lcihhcHApCiAgICAgICAgYXdhaXQgc2VsZi5fYXBpX3J1bm5lci5zZXR1cCgpCiAgICAgICAgc2l0ZSA9IHdlYi5UQ1BTaXRlKHNlbGYuX2FwaV9ydW5uZXIsIHNlbGYuaG9zdCwgc2VsZi5hcGlfcG9ydCkKICAgICAgICBhd2FpdCBzaXRlLnN0YXJ0KCkKICAgICAgICBsb2dnZXIuaW5mbyhmIvCfpokgT1dMLUFHRU5UIEFQSSBsaXN0ZW5pbmcgb24gaHR0cDovL3tzZWxmLmhvc3R9OntzZWxmLmFwaV9wb3J0fSIpCgogICAgICAgICMgTWV0cmljcyBzZXJ2ZXIgKHBvcnQgOTA5MCkKICAgICAgICBtZXRyaWNzX2FwcCA9IHdlYi5BcHBsaWNhdGlvbigpCiAgICAgICAgbWV0cmljc19hcHAucm91dGVyLmFkZF9nZXQoIi9tZXRyaWNzIiwgc2VsZi5oYW5kbGVfbWV0cmljcykKICAgICAgICBzZWxmLl9tZXRyaWNzX3J1bm5lciA9IHdlYi5BcHBSdW5uZXIobWV0cmljc19hcHApCiAgICAgICAgYXdhaXQgc2VsZi5fbWV0cmljc19ydW5uZXIuc2V0dXAoKQogICAgICAgIG1ldHJpY3Nfc2l0ZSA9IHdlYi5UQ1BTaXRlKHNlbGYuX21ldHJpY3NfcnVubmVyLCBzZWxmLmhvc3QsIHNlbGYubWV0cmljc19wb3J0KQogICAgICAgIGF3YWl0IG1ldHJpY3Nfc2l0ZS5zdGFydCgpCiAgICAgICAgbG9nZ2VyLmluZm8oZiLwn5OKIFByb21ldGhldXMgbWV0cmljcyBhdCBodHRwOi8ve3NlbGYuaG9zdH06e3NlbGYubWV0cmljc19wb3J0fS9tZXRyaWNzIikKCiAgICAgICAgIyBCYWNrZ3JvdW5kIHByb3h5IHBvb2wgbWV0cmljcyB1cGRhdGVyCiAgICAgICAgYXN5bmNpby5jcmVhdGVfdGFzayhzZWxmLl91cGRhdGVfbWV0cmljc19sb29wKCkpCgogICAgYXN5bmMgZGVmIHN0b3Aoc2VsZik6CiAgICAgICAgIiIiR3JhY2VmdWwgc2h1dGRvd24uIiIiCiAgICAgICAgaWYgc2VsZi5fYXBpX3J1bm5lcjoKICAgICAgICAgICAgYXdhaXQgc2VsZi5fYXBpX3J1bm5lci5jbGVhbnVwKCkKICAgICAgICBpZiBzZWxmLl9tZXRyaWNzX3J1bm5lcjoKICAgICAgICAgICAgYXdhaXQgc2VsZi5fbWV0cmljc19ydW5uZXIuY2xlYW51cCgpCiAgICAgICAgaWYgc2VsZi5jbGllbnQ6CiAgICAgICAgICAgIGF3YWl0IHNlbGYuY2xpZW50Ll9fYWV4aXRfXyhOb25lLCBOb25lLCBOb25lKQoKICAgIGFzeW5jIGRlZiBfb25fc2h1dGRvd24oc2VsZiwgYXBwKToKICAgICAgICBsb2dnZXIuaW5mbygiU2h1dHRpbmcgZG93bi4uLiIpCgogICAgYXN5bmMgZGVmIF91cGRhdGVfbWV0cmljc19sb29wKHNlbGYpOgogICAgICAgICIiIlBlcmlvZGljYWxseSB1cGRhdGUgR2F1Z2UgbWV0cmljcyBmcm9tIHRoZSBwcm94eSBwb29sLiIiIgogICAgICAgIHdoaWxlIFRydWU6CiAgICAgICAgICAgIHRyeToKICAgICAgICAgICAgICAgIGlmIHNlbGYuY2xpZW50OgogICAgICAgICAgICAgICAgICAgIFBST1hZX1BPT0xfU0laRS5zZXQobGVuKHNlbGYuY2xpZW50LnBvb2xfbWFuYWdlci5fcHJveGllcykpCiAgICAgICAgICAgICAgICAgICAgUFJPWFlfSEVBTFRIWS5zZXQoCiAgICAgICAgICAgICAgICAgICAgICAgIHN1bSgxIGZvciBwIGluIHNlbGYuY2xpZW50LnBvb2xfbWFuYWdlci5fcHJveGllcwogICAgICAgICAgICAgICAgICAgICAgICAgICAgaWYgcC5oZWFsdGh5IGFuZCBub3QgcC5pc19iYW5uZWQoKSkKICAgICAgICAgICAgICAgICAgICApCiAgICAgICAgICAgIGV4Y2VwdCBFeGNlcHRpb246CiAgICAgICAgICAgICAgICBwYXNzCiAgICAgICAgICAgIGF3YWl0IGFzeW5jaW8uc2xlZXAoMTUpCgogICAgYXN5bmMgZGVmIGhhbmRsZV9mZXRjaChzZWxmLCByZXF1ZXN0OiB3ZWIuUmVxdWVzdCkgLT4gd2ViLlJlc3BvbnNlOgogICAgICAgICIiIlBPU1QgL2ZldGNoIOKAlCBGZXRjaCBhIFVSTCB0aHJvdWdoIHRoZSBwcm94eSBwb29sLgoKICAgICAgICBCb2R5IChKU09OKToKICAgICAgICB7CiAgICAgICAgICAgICJ1cmwiOiAiaHR0cHM6Ly9leGFtcGxlLmNvbSIsCiAgICAgICAgICAgICJtZXRob2QiOiAiR0VUIiwgICAgICAgICAgIyBvcHRpb25hbCwgZGVmYXVsdCBHRVQKICAgICAgICAgICAgImhlYWRlcnMiOiB7fSwgICAgICAgICAgICAjIG9wdGlvbmFsCiAgICAgICAgICAgICJicm93c2VyIjogZmFsc2UsICAgICAgICAgIyBvcHRpb25hbCwgdXNlIGFnZW50LWJyb3dzZXIKICAgICAgICAgICAgIndhaXRfZm9yIjogIi5zZWxlY3RvciIsICAjIG9wdGlvbmFsLCBmb3IgYnJvd3NlciBtb2RlCiAgICAgICAgICAgICJ0aW1lb3V0IjogMzAgICAgICAgICAgICAgIyBvcHRpb25hbAogICAgICAgIH0KICAgICAgICAiIiIKICAgICAgICBzdGFydCA9IHRpbWUudGltZSgpCiAgICAgICAgdHJ5OgogICAgICAgICAgICBib2R5ID0gYXdhaXQgcmVxdWVzdC5qc29uKCkKICAgICAgICBleGNlcHQgRXhjZXB0aW9uOgogICAgICAgICAgICByZXR1cm4gd2ViLmpzb25fcmVzcG9uc2UoeyJlcnJvciI6ICJJbnZhbGlkIEpTT04gYm9keSJ9LCBzdGF0dXM9NDAwKQoKICAgICAgICB1cmwgPSBib2R5LmdldCgidXJsIikKICAgICAgICBpZiBub3QgdXJsOgogICAgICAgICAgICByZXR1cm4gd2ViLmpzb25fcmVzcG9uc2UoeyJlcnJvciI6ICJNaXNzaW5nICd1cmwnIGZpZWxkIn0sIHN0YXR1cz00MDApCgogICAgICAgIG1ldGhvZCA9IGJvZHkuZ2V0KCJtZXRob2QiLCAiR0VUIikudXBwZXIoKQogICAgICAgIGhlYWRlcnMgPSBib2R5LmdldCgiaGVhZGVycyIpIG9yIHt9CiAgICAgICAgYnJvd3NlciA9IGJvZHkuZ2V0KCJicm93c2VyIiwgRmFsc2UpCiAgICAgICAgd2FpdF9mb3IgPSBib2R5LmdldCgid2FpdF9mb3IiKQogICAgICAgIHRpbWVvdXQgPSBib2R5LmdldCgidGltZW91dCIsIDMwKQoKICAgICAgICAjIExvZyBwbHVnaW4gaG9vayBleGVjdXRpb24gZm9yIGRlYnVnZ2luZwogICAgICAgIHBsdWdpbl9jb3VudCA9IDAKICAgICAgICBpZiBzZWxmLmNsaWVudCBhbmQgc2VsZi5jbGllbnQucGx1Z2luX2xvYWRlcjoKICAgICAgICAgICAgc3RhdHMgPSBzZWxmLmNsaWVudC5wbHVnaW5fbG9hZGVyLmdldF9zdGF0cygpCiAgICAgICAgICAgIHBsdWdpbl9jb3VudCA9IHN0YXRzLmdldCgidG90YWwiLCAwKQogICAgICAgICAgICBpZiBwbHVnaW5fY291bnQgPiAwOgogICAgICAgICAgICAgICAgcGx1Z2luX25hbWVzID0gbGlzdChzdGF0cy5nZXQoInBsdWdpbnMiLCB7fSkua2V5cygpKQogICAgICAgICAgICAgICAgbG9nZ2VyLmRlYnVnKGYiW1BsdWdpbl0ge3BsdWdpbl9jb3VudH0gcGx1Z2luKHMpIGFjdGl2ZTogeycsICcuam9pbihwbHVnaW5fbmFtZXMpfSIpCgogICAgICAgIHRyeToKICAgICAgICAgICAgcmVzcDogQ2FjaGVkUmVzcG9uc2UgPSBhd2FpdCBzZWxmLmNsaWVudC5yZXF1ZXN0KAogICAgICAgICAgICAgICAgbWV0aG9kPW1ldGhvZCwKICAgICAgICAgICAgICAgIHVybD11cmwsCiAgICAgICAgICAgICAgICBoZWFkZXJzPWhlYWRlcnMsCiAgICAgICAgICAgICAgICBicm93c2VyPWJyb3dzZXIsCiAgICAgICAgICAgICAgICB3YWl0X2Zvcj13YWl0X2ZvciwKICAgICAgICAgICAgICAgIHRpbWVvdXQ9dGltZW91dCwKICAgICAgICAgICAgKQogICAgICAgICAgICBsYXRlbmN5ID0gdGltZS50aW1lKCkgLSBzdGFydAogICAgICAgICAgICBSRVFVRVNUU19UT1RBTC5sYWJlbHMobWV0aG9kPW1ldGhvZCwgc3RhdHVzPXN0cihyZXNwLnN0YXR1cykpLmluYygpCiAgICAgICAgICAgIFJFUVVFU1RfTEFURU5DWS5vYnNlcnZlKGxhdGVuY3kpCgogICAgICAgICAgICAjIExvZyByZXF1ZXN0IGNvbXBsZXRpb24gd2l0aCBwbHVnaW4gaW5mbwogICAgICAgICAgICBpZiBwbHVnaW5fY291bnQgPiAwOgogICAgICAgICAgICAgICAgbG9nZ2VyLmRlYnVnKGYiW1BsdWdpbl0gUmVxdWVzdCBjb21wbGV0ZWQ6IHttZXRob2R9IHt1cmx9IC0+IHtyZXNwLnN0YXR1c30gKHtsYXRlbmN5Oi4yZn1zLCB7cGx1Z2luX2NvdW50fSBwbHVnaW4ocykpIikKCiAgICAgICAgICAgIHJldHVybiB3ZWIuanNvbl9yZXNwb25zZSgKICAgICAgICAgICAgICAgIHsKICAgICAgICAgICAgICAgICAgICAic3RhdHVzIjogcmVzcC5zdGF0dXMsCiAgICAgICAgICAgICAgICAgICAgImhlYWRlcnMiOiByZXNwLmhlYWRlcnMsCiAgICAgICAgICAgICAgICAgICAgImNvbnRlbnRfbGVuZ3RoIjogbGVuKHJlc3AuY29udGVudCksCiAgICAgICAgICAgICAgICAgICAgImNvbnRlbnQiOiByZXNwLmNvbnRlbnQuZGVjb2RlKCJ1dGYtOCIsIGVycm9ycz0icmVwbGFjZSIpLAogICAgICAgICAgICAgICAgICAgICJsYXRlbmN5X3NlY29uZHMiOiByb3VuZChsYXRlbmN5LCAzKSwKICAgICAgICAgICAgICAgICAgICAiZnJvbV9jYWNoZSI6IHJlc3AuaXNfZnJlc2goKSBhbmQgKHRpbWUudGltZSgpIC0gcmVzcC50aW1lc3RhbXApIDwgcmVzcC50dGwsCiAgICAgICAgICAgICAgICAgICAgInBsdWdpbnNfbG9hZGVkIjogcGx1Z2luX2NvdW50LAogICAgICAgICAgICAgICAgfQogICAgICAgICAgICApCiAgICAgICAgZXhjZXB0IEV4Y2VwdGlvbiBhcyBlOgogICAgICAgICAgICBSRVFVRVNUU19UT1RBTC5sYWJlbHMobWV0aG9kPW1ldGhvZCwgc3RhdHVzPSJlcnJvciIpLmluYygpCiAgICAgICAgICAgIGxvZ2dlci5lcnJvcihmIltQbHVnaW5dIFJlcXVlc3QgZmFpbGVkOiB7bWV0aG9kfSB7dXJsfSAtPiB7ZX0iKQogICAgICAgICAgICByZXR1cm4gd2ViLmpzb25fcmVzcG9uc2UoeyJlcnJvciI6IHN0cihlKX0sIHN0YXR1cz01MDIpCgogICAgYXN5bmMgZGVmIGhhbmRsZV9icm93c2VyKHNlbGYsIHJlcXVlc3Q6IHdlYi5SZXF1ZXN0KSAtPiB3ZWIuUmVzcG9uc2U6CiAgICAgICAgIiIiUE9TVCAvYnJvd3NlciDigJQgRmV0Y2ggdmlhIGFnZW50LWJyb3dzZXIgKEpTIHJlbmRlcmluZykuIiIiCiAgICAgICAgYm9keSA9IGF3YWl0IHJlcXVlc3QuanNvbigpCiAgICAgICAgdXJsID0gYm9keS5nZXQoInVybCIpCiAgICAgICAgaWYgbm90IHVybDoKICAgICAgICAgICAgcmV0dXJuIHdlYi5qc29uX3Jlc3BvbnNlKHsiZXJyb3IiOiAiTWlzc2luZyAndXJsJyBmaWVsZCJ9LCBzdGF0dXM9NDAwKQogICAgICAgIHdhaXRfZm9yID0gYm9keS5nZXQoIndhaXRfZm9yIikKICAgICAgICB0aW1lb3V0ID0gYm9keS5nZXQoInRpbWVvdXQiLCAzMCkKICAgICAgICB0cnk6CiAgICAgICAgICAgIGNvbnRlbnQgPSBhd2FpdCBzZWxmLmNsaWVudC5yZXF1ZXN0KAogICAgICAgICAgICAgICAgIkdFVCIsIHVybCwgYnJvd3Nlcj1UcnVlLCB3YWl0X2Zvcj13YWl0X2ZvciwgdGltZW91dD10aW1lb3V0CiAgICAgICAgICAgICkKICAgICAgICAgICAgcmV0dXJuIHdlYi5qc29uX3Jlc3BvbnNlKAogICAgICAgICAgICAgICAgewogICAgICAgICAgICAgICAgICAgICJzdGF0dXMiOiBjb250ZW50LnN0YXR1cywKICAgICAgICAgICAgICAgICAgICAiY29udGVudF9sZW5ndGgiOiBsZW4oY29udGVudC5jb250ZW50KSwKICAgICAgICAgICAgICAgICAgICAiY29udGVudCI6IGNvbnRlbnQuY29udGVudC5kZWNvZGUoInV0Zi04IiwgZXJyb3JzPSJyZXBsYWNlIiksCiAgICAgICAgICAgICAgICB9CiAgICAgICAgICAgICkKICAgICAgICBleGNlcHQgRXhjZXB0aW9uIGFzIGU6CiAgICAgICAgICAgIHJldHVybiB3ZWIuanNvbl9yZXNwb25zZSh7ImVycm9yIjogc3RyKGUpfSwgc3RhdHVzPTUwMikKCiAgICBhc3luYyBkZWYgaGFuZGxlX2hlYWx0aChzZWxmLCByZXF1ZXN0OiB3ZWIuUmVxdWVzdCkgLT4gd2ViLlJlc3BvbnNlOgogICAgICAgICIiIkdFVCAvaGVhbHRoIOKAlCBIZWFsdGggY2hlY2suIiIiCiAgICAgICAgaWYgbm90IHNlbGYuY2xpZW50OgogICAgICAgICAgICByZXR1cm4gd2ViLmpzb25fcmVzcG9uc2UoeyJzdGF0dXMiOiAibm90X3JlYWR5In0sIHN0YXR1cz01MDMpCiAgICAgICAgc3RhdHMgPSBhd2FpdCBzZWxmLmNsaWVudC5nZXRfc3RhdHMoKQogICAgICAgIHJldHVybiB3ZWIuanNvbl9yZXNwb25zZSh7CiAgICAgICAgICAgICJzdGF0dXMiOiAib2siLAogICAgICAgICAgICAicHJveGllc190b3RhbCI6IHN0YXRzWyJwcm94aWVzX3RvdGFsIl0sCiAgICAgICAgICAgICJwcm94aWVzX2hlYWx0aHkiOiBzdGF0c1sicHJveGllc19oZWFsdGh5Il0sCiAgICAgICAgICAgICJ1cHRpbWUiOiB0aW1lLnRpbWUoKSAtIHNlbGYuX3N0YXJ0X3RpbWUgaWYgaGFzYXR0cihzZWxmLCAnX3N0YXJ0X3RpbWUnKSBlbHNlIDAsCiAgICAgICAgfSkKCiAgICBhc3luYyBkZWYgaGFuZGxlX3N0YXRzKHNlbGYsIHJlcXVlc3Q6IHdlYi5SZXF1ZXN0KSAtPiB3ZWIuUmVzcG9uc2U6CiAgICAgICAgIiIiR0VUIC9zdGF0cyDigJQgRGV0YWlsZWQgcHJveHkgcG9vbCBhbmQgcmF0ZSBsaW1pdGVyIHN0YXRzLiIiIgogICAgICAgIGlmIG5vdCBzZWxmLmNsaWVudDoKICAgICAgICAgICAgcmV0dXJuIHdlYi5qc29uX3Jlc3BvbnNlKHsic3RhdHVzIjogIm5vdF9yZWFkeSJ9LCBzdGF0dXM9NTAzKQogICAgICAgIHN0YXRzID0gYXdhaXQgc2VsZi5jbGllbnQuZ2V0X3N0YXRzKCkKICAgICAgICByZXR1cm4gd2ViLmpzb25fcmVzcG9uc2Uoc3RhdHMpCgogICAgYXN5bmMgZGVmIGhhbmRsZV9vcGVuYWlfY2hhdChzZWxmLCByZXF1ZXN0OiB3ZWIuUmVxdWVzdCkgLT4gd2ViLlJlc3BvbnNlOgogICAgICAgICIiIlBPU1QgL3YxL2NoYXQvY29tcGxldGlvbnMg4oCUIE9wZW5BSSBjaGF0IGNvbXBsZXRpb25zIHZpYSBmcmVlYnVmZi1ub2RlLgoKICAgICAgICBQcm94aWVzIE9wZW5BSS1mb3JtYXQgcmVxdWVzdHMgdG8gZnJlZWJ1ZmYtbm9kZSwgYWRkaW5nCiAgICAgICAgT1dMLUFHRU5UJ3MgSFRUUCBjYWNoZSBhbmQgbWV0cmljcyBvbiB0b3AuCiAgICAgICAgIiIiCiAgICAgICAgc3RhcnQgPSB0aW1lLnRpbWUoKQogICAgICAgIHRyeToKICAgICAgICAgICAgYm9keSA9IGF3YWl0IHJlcXVlc3QuanNvbigpCiAgICAgICAgZXhjZXB0IEV4Y2VwdGlvbjoKICAgICAgICAgICAgcmV0dXJuIHdlYi5qc29uX3Jlc3BvbnNlKHsiZXJyb3IiOiAiSW52YWxpZCBKU09OIGJvZHkifSwgc3RhdHVzPTQwMCkKCiAgICAgICAgdHJ5OgogICAgICAgICAgICBhc3luYyB3aXRoIGFpb2h0dHAuQ2xpZW50U2Vzc2lvbigpIGFzIHNlc3Npb246CiAgICAgICAgICAgICAgICBhc3luYyB3aXRoIHNlc3Npb24ucG9zdCgKICAgICAgICAgICAgICAgICAgICAiaHR0cDovLzEyNy4wLjAuMTo4MDkwL3YxL2NoYXQvY29tcGxldGlvbnMiLAogICAgICAgICAgICAgICAgICAgIGpzb249Ym9keSwKICAgICAgICAgICAgICAgICAgICB0aW1lb3V0PWFpb2h0dHAuQ2xpZW50VGltZW91dCh0b3RhbD0xMjApLAogICAgICAgICAgICAgICAgKSBhcyByZXNwOgogICAgICAgICAgICAgICAgICAgIGxhdGVuY3kgPSB0aW1lLnRpbWUoKSAtIHN0YXJ0CiAgICAgICAgICAgICAgICAgICAgY29udGVudCA9IGF3YWl0IHJlc3AucmVhZCgpCiAgICAgICAgICAgICAgICAgICAgUkVRVUVTVFNfVE9UQUwubGFiZWxzKG1ldGhvZD0iUE9TVCIsIHN0YXR1cz1zdHIocmVzcC5zdGF0dXMpKS5pbmMoKQogICAgICAgICAgICAgICAgICAgIFJFUVVFU1RfTEFURU5DWS5vYnNlcnZlKGxhdGVuY3kpCiAgICAgICAgICAgICAgICAgICAgY29udGVudF90eXBlID0gInRleHQvZXZlbnQtc3RyZWFtIiBpZiBib2R5LmdldCgic3RyZWFtIikgZWxzZSAiYXBwbGljYXRpb24vanNvbiIKICAgICAgICAgICAgICAgICAgICByZXR1cm4gd2ViLlJlc3BvbnNlKAogICAgICAgICAgICAgICAgICAgICAgICBib2R5PWNvbnRlbnQsCiAgICAgICAgICAgICAgICAgICAgICAgIHN0YXR1cz1yZXNwLnN0YXR1cywKICAgICAgICAgICAgICAgICAgICAgICAgaGVhZGVycz17CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAiQ29udGVudC1UeXBlIjogY29udGVudF90eXBlLAogICAgICAgICAgICAgICAgICAgICAgICAgICAgIlgtT1dMLVByb3h5IjogInRydWUiLAogICAgICAgICAgICAgICAgICAgICAgICAgICAgIlgtUmVzcG9uc2UtVGltZSI6IGYie2xhdGVuY3k6LjNmfXMiLAogICAgICAgICAgICAgICAgICAgICAgICB9LAogICAgICAgICAgICAgICAgICAgICkKICAgICAgICBleGNlcHQgRXhjZXB0aW9uIGFzIGU6CiAgICAgICAgICAgIFJFUVVFU1RTX1RPVEFMLmxhYmVscyhtZXRob2Q9IlBPU1QiLCBzdGF0dXM9ImVycm9yIikuaW5jKCkKICAgICAgICAgICAgbG9nZ2VyLmVycm9yKGYiT3BlbkFJIGNoYXQgZXJyb3I6IHtlfSIpCiAgICAgICAgICAgIHJldHVybiB3ZWIuanNvbl9yZXNwb25zZSh7ImVycm9yIjogc3RyKGUpfSwgc3RhdHVzPTUwMikKCiAgICBhc3luYyBkZWYgaGFuZGxlX29wZW5haV9tb2RlbHMoc2VsZiwgcmVxdWVzdDogd2ViLlJlcXVlc3QpIC0+IHdlYi5SZXNwb25zZToKICAgICAgICAiIiJHRVQgL3YxL21vZGVscyDigJQgUmV0dXJuIGF2YWlsYWJsZSBtb2RlbHMgZnJvbSBmcmVlYnVmZi1ub2RlLiIiIgogICAgICAgIHRyeToKICAgICAgICAgICAgYXN5bmMgd2l0aCBhaW9odHRwLkNsaWVudFNlc3Npb24oKSBhcyBzZXNzaW9uOgogICAgICAgICAgICAgICAgYXN5bmMgd2l0aCBzZXNzaW9uLmdldCgKICAgICAgICAgICAgICAgICAgICAiaHR0cDovLzEyNy4wLjAuMTo4MDkwL3YxL21vZGVscyIsCiAgICAgICAgICAgICAgICAgICAgdGltZW91dD1haW9odHRwLkNsaWVudFRpbWVvdXQodG90YWw9MTUpLAogICAgICAgICAgICAgICAgKSBhcyByZXNwOgogICAgICAgICAgICAgICAgICAgIGNvbnRlbnQgPSBhd2FpdCByZXNwLnJlYWQoKQogICAgICAgICAgICAgICAgICAgIHJldHVybiB3ZWIuUmVzcG9uc2UoCiAgICAgICAgICAgICAgICAgICAgICAgIGJvZHk9Y29udGVudCwKICAgICAgICAgICAgICAgICAgICAgICAgc3RhdHVzPXJlc3Auc3RhdHVzLAogICAgICAgICAgICAgICAgICAgICAgICBoZWFkZXJzPXsiQ29udGVudC1UeXBlIjogImFwcGxpY2F0aW9uL2pzb24iLCAiWC1PV0wtUHJveHkiOiAidHJ1ZSJ9LAogICAgICAgICAgICAgICAgICAgICkKICAgICAgICBleGNlcHQgRXhjZXB0aW9uIGFzIGU6CiAgICAgICAgICAgIHJldHVybiB3ZWIuanNvbl9yZXNwb25zZSh7ImVycm9yIjogc3RyKGUpfSwgc3RhdHVzPTUwMikKCiAgICBhc3luYyBkZWYgaGFuZGxlX2NsYXVkZV9tZXNzYWdlcyhzZWxmLCByZXF1ZXN0OiB3ZWIuUmVxdWVzdCkgLT4gd2ViLlJlc3BvbnNlOgogICAgICAgICIiIlBPU1QgL3YxL21lc3NhZ2VzIOKAlCBDbGF1ZGUtZm9ybWF0IG1lc3NhZ2VzIHZpYSBmcmVlYnVmZi1ub2RlLiIiIgogICAgICAgIHN0YXJ0ID0gdGltZS50aW1lKCkKICAgICAgICB0cnk6CiAgICAgICAgICAgIGJvZHkgPSBhd2FpdCByZXF1ZXN0Lmpzb24oKQogICAgICAgIGV4Y2VwdCBFeGNlcHRpb246CiAgICAgICAgICAgIHJldHVybiB3ZWIuanNvbl9yZXNwb25zZSh7ImVycm9yIjogIkludmFsaWQgSlNPTiBib2R5In0sIHN0YXR1cz00MDApCgogICAgICAgIHRyeToKICAgICAgICAgICAgYXN5bmMgd2l0aCBhaW9odHRwLkNsaWVudFNlc3Npb24oKSBhcyBzZXNzaW9uOgogICAgICAgICAgICAgICAgYXN5bmMgd2l0aCBzZXNzaW9uLnBvc3QoCiAgICAgICAgICAgICAgICAgICAgImh0dHA6Ly8xMjcuMC4wLjE6ODA5MC92MS9tZXNzYWdlcyIsCiAgICAgICAgICAgICAgICAgICAganNvbj1ib2R5LAogICAgICAgICAgICAgICAgICAgIHRpbWVvdXQ9YWlvaHR0cC5DbGllbnRUaW1lb3V0KHRvdGFsPTEyMCksCiAgICAgICAgICAgICAgICApIGFzIHJlc3A6CiAgICAgICAgICAgICAgICAgICAgbGF0ZW5jeSA9IHRpbWUudGltZSgpIC0gc3RhcnQKICAgICAgICAgICAgICAgICAgICBjb250ZW50ID0gYXdhaXQgcmVzcC5yZWFkKCkKICAgICAgICAgICAgICAgICAgICBSRVFVRVNUU19UT1RBTC5sYWJlbHMobWV0aG9kPSJQT1NUIiwgc3RhdHVzPXN0cihyZXNwLnN0YXR1cykpLmluYygpCiAgICAgICAgICAgICAgICAgICAgUkVRVUVTVF9MQVRFTkNZLm9ic2VydmUobGF0ZW5jeSkKICAgICAgICAgICAgICAgICAgICByZXR1cm4gd2ViLlJlc3BvbnNlKAogICAgICAgICAgICAgICAgICAgICAgICBib2R5PWNvbnRlbnQsCiAgICAgICAgICAgICAgICAgICAgICAgIHN0YXR1cz1yZXNwLnN0YXR1cywKICAgICAgICAgICAgICAgICAgICAgICAgaGVhZGVycz17IkNvbnRlbnQtVHlwZSI6ICJhcHBsaWNhdGlvbi9qc29uIiwgIlgtT1dMLVByb3h5IjogInRydWUiLCAiWC1SZXNwb25zZS1UaW1lIjogZiJ7bGF0ZW5jeTouM2Z9cyJ9LAogICAgICAgICAgICAgICAgICAgICkKICAgICAgICBleGNlcHQgRXhjZXB0aW9uIGFzIGU6CiAgICAgICAgICAgIFJFUVVFU1RTX1RPVEFMLmxhYmVscyhtZXRob2Q9IlBPU1QiLCBzdGF0dXM9ImVycm9yIikuaW5jKCkKICAgICAgICAgICAgbG9nZ2VyLmVycm9yKGYiQ2xhdWRlIG1lc3NhZ2VzIGVycm9yOiB7ZX0iKQogICAgICAgICAgICByZXR1cm4gd2ViLmpzb25fcmVzcG9uc2UoeyJlcnJvciI6IHN0cihlKX0sIHN0YXR1cz01MDIpCgogICAgYXN5bmMgZGVmIGhhbmRsZV9jbGF1ZGVfY291bnRfdG9rZW5zKHNlbGYsIHJlcXVlc3Q6IHdlYi5SZXF1ZXN0KSAtPiB3ZWIuUmVzcG9uc2U6CiAgICAgICAgIiIiUE9TVCAvdjEvbWVzc2FnZXMvY291bnRfdG9rZW5zIOKAlCBDb3VudCB0b2tlbnMgdmlhIGZyZWVidWZmLW5vZGUuIiIiCiAgICAgICAgdHJ5OgogICAgICAgICAgICBib2R5ID0gYXdhaXQgcmVxdWVzdC5qc29uKCkKICAgICAgICBleGNlcHQgRXhjZXB0aW9uOgogICAgICAgICAgICByZXR1cm4gd2ViLmpzb25fcmVzcG9uc2UoeyJlcnJvciI6ICJJbnZhbGlkIEpTT04gYm9keSJ9LCBzdGF0dXM9NDAwKQoKICAgICAgICB0cnk6CiAgICAgICAgICAgIGFzeW5jIHdpdGggYWlvaHR0cC5DbGllbnRTZXNzaW9uKCkgYXMgc2Vzc2lvbjoKICAgICAgICAgICAgICAgIGFzeW5jIHdpdGggc2Vzc2lvbi5wb3N0KAogICAgICAgICAgICAgICAgICAgICJodHRwOi8vMTI3LjAuMC4xOjgwOTAvdjEvbWVzc2FnZXMvY291bnRfdG9rZW5zIiwKICAgICAgICAgICAgICAgICAgICBqc29uPWJvZHksCiAgICAgICAgICAgICAgICAgICAgdGltZW91dD1haW9odHRwLkNsaWVudFRpbWVvdXQodG90YWw9MTUpLAogICAgICAgICAgICAgICAgKSBhcyByZXNwOgogICAgICAgICAgICAgICAgICAgIGNvbnRlbnQgPSBhd2FpdCByZXNwLnJlYWQoKQogICAgICAgICAgICAgICAgICAgIHJldHVybiB3ZWIuUmVzcG9uc2UoCiAgICAgICAgICAgICAgICAgICAgICAgIGJvZHk9Y29udGVudCwKICAgICAgICAgICAgICAgICAgICAgICAgc3RhdHVzPXJlc3Auc3RhdHVzLAogICAgICAgICAgICAgICAgICAgICAgICBoZWFkZXJzPXsiQ29udGVudC1UeXBlIjogImFwcGxpY2F0aW9uL2pzb24iLCAiWC1PV0wtUHJveHkiOiAidHJ1ZSJ9LAogICAgICAgICAgICAgICAgICAgICkKICAgICAgICBleGNlcHQgRXhjZXB0aW9uIGFzIGU6CiAgICAgICAgICAgIHJldHVybiB3ZWIuanNvbl9yZXNwb25zZSh7ImVycm9yIjogc3RyKGUpfSwgc3RhdHVzPTUwMikKICAgICAgICAgICAgcmV0dXJuIHdlYi5qc29uX3Jlc3BvbnNlKHsiZXJyb3IiOiBzdHIoZSl9LCBzdGF0dXM9NTAyKQogICAgICAgICAgICByZXR1cm4gd2ViLmpzb25fcmVzcG9uc2UoeyJlcnJvciI6IHN0cihlKX0sIHN0YXR1cz01MDIpCgogICAgYXN5bmMgZGVmIGhhbmRsZV9tZXRyaWNzKHNlbGYsIHJlcXVlc3Q6IHdlYi5SZXF1ZXN0KSAtPiB3ZWIuUmVzcG9uc2U6CiAgICAgICAgIiIiR0VUIC9tZXRyaWNzIOKAlCBQcm9tZXRoZXVzIG1ldHJpY3MuIiIiCiAgICAgICAgcmV0dXJuIHdlYi5SZXNwb25zZSgKICAgICAgICAgICAgYm9keT1nZW5lcmF0ZV9sYXRlc3QoUkVHSVNUUlkpLAogICAgICAgICAgICBjb250ZW50X3R5cGU9InRleHQvcGxhaW47IHZlcnNpb249MC4wLjQiLAogICAgICAgICkKCgojIOKUgOKUgOKUgCBNYWluIOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgAphc3luYyBkZWYgbWFpbigpOgogICAgaW1wb3J0IGFyZ3BhcnNlCiAgICBwYXJzZXIgPSBhcmdwYXJzZS5Bcmd1bWVudFBhcnNlcihkZXNjcmlwdGlvbj0i8J+miSBPV0wtQUdFTlQgdjQuNSBTZXJ2ZXIiKQogICAgcGFyc2VyLmFkZF9hcmd1bWVudCgiLS1ob3N0IiwgZGVmYXVsdD0iMC4wLjAuMCIsIGhlbHA9IkJpbmQgYWRkcmVzcyIpCiAgICBwYXJzZXIuYWRkX2FyZ3VtZW50KCItLWFwaS1wb3J0IiwgdHlwZT1pbnQsIGRlZmF1bHQ9NjAwMDAsIGhlbHA9IkFQSSBwb3J0IikKICAgIHBhcnNlci5hZGRfYXJndW1lbnQoIi0tbWV0cmljcy1wb3J0IiwgdHlwZT1pbnQsIGRlZmF1bHQ9OTA5MCwgaGVscD0iUHJvbWV0aGV1cyBwb3J0IikKICAgIHBhcnNlci5hZGRfYXJndW1lbnQoIi0tY291bnRyaWVzIiwgbmFyZ3M9IisiLCBkZWZhdWx0PVsiVVMiLCAiR0IiLCAiUEgiXSwKICAgICAgICAgICAgICAgICAgICAgICAgaGVscD0iUHJlZmVycmVkIHByb3h5IGNvdW50cmllcyIpCiAgICBwYXJzZXIuYWRkX2FyZ3VtZW50KCItLXJlZGlzIiwgYWN0aW9uPSJzdG9yZV90cnVlIiwgaGVscD0iRW5hYmxlIFJlZGlzIHN0YXRlIHNoYXJpbmciKQogICAgcGFyc2VyLmFkZF9hcmd1bWVudCgiLS1yZWRpcy11cmwiLCBkZWZhdWx0PSJyZWRpczovL2xvY2FsaG9zdDo2Mzc5IiwgaGVscD0iUmVkaXMgVVJMIikKICAgIHBhcnNlci5hZGRfYXJndW1lbnQoIi0tbm8tY3VybC1jZmZpIiwgYWN0aW9uPSJzdG9yZV90cnVlIiwgaGVscD0iRGlzYWJsZSBjdXJsX2NmZmkiKQogICAgcGFyc2VyLmFkZF9hcmd1bWVudCgiLS1hYi10ZXN0IiwgYWN0aW9uPSJzdG9yZV90cnVlIiwgaGVscD0iRW5hYmxlIEEvQiB0ZXN0aW5nIGZvciBwcm94eSBzdHJhdGVnaWVzIikKICAgIHBhcnNlci5hZGRfYXJndW1lbnQoIi0tbWwiLCBhY3Rpb249InN0b3JlX3RydWUiLCBoZWxwPSJFbmFibGUgTUwgcHJlZGljdG9yIGZvciBwcm94eSBzZWxlY3Rpb24iKQogICAgcGFyc2VyLmFkZF9hcmd1bWVudCgiLS1tbC1tb2RlbCIsIGRlZmF1bHQ9ImF1dG8iLCBjaG9pY2VzPVsiYXV0byIsICJsb2dpc3RpYyIsICJ4Z2Jvb3N0IiwgIm1scCJdLAogICAgICAgICAgICAgICAgICAgICAgICBoZWxwPSJNTCBtb2RlbCB0eXBlIChkZWZhdWx0OiBhdXRvKSIpCiAgICBwYXJzZXIuYWRkX2FyZ3VtZW50KCItLXBsdWdpbi1kaXIiLCBkZWZhdWx0PSJ+Ly5vd2wtYWdlbnQvcGx1Z2lucyIsCiAgICAgICAgICAgICAgICAgICAgICAgIGhlbHA9IlBsdWdpbiBkaXJlY3RvcnkgZm9yIGF1dG8tZGlzY292ZXJ5IikKICAgIHBhcnNlci5hZGRfYXJndW1lbnQoIi0tYXBpLWtleSIsIGRlZmF1bHQ9Tm9uZSwKICAgICAgICAgICAgICAgICAgICAgICAgaGVscD0iQVBJIGtleSBmb3IgYXV0aCAoZGVmYXVsdDogT1dMX0FQSV9LRVkgZW52LCBvciBhdXRvLWdlbmVyYXRlZCkiKQogICAgYXJncyA9IHBhcnNlci5wYXJzZV9hcmdzKCkKCiAgICAjIFJlc29sdmUgQVBJIGtleTogQ0xJIGFyZyA+IGVudiB2YXIgPiBwZXJzaXN0ZWQga2V5IGZpbGUgPiBhdXRvLWdlbmVyYXRlCiAgICBhcGlfa2V5ID0gYXJncy5hcGlfa2V5IG9yIG9zLmVudmlyb24uZ2V0KCJPV0xfQVBJX0tFWSIpCiAgICBpZiBub3QgYXBpX2tleToKICAgICAgICBrZXlfZmlsZSA9IFBhdGguaG9tZSgpIC8gIi5vd2wtYWdlbnQiIC8gImNvbmZpZyIgLyAiYXBpX2tleS50eHQiCiAgICAgICAgaWYga2V5X2ZpbGUuZXhpc3RzKCk6CiAgICAgICAgICAgIGFwaV9rZXkgPSBrZXlfZmlsZS5yZWFkX3RleHQoKS5zdHJpcCgpCiAgICAgICAgZWxzZToKICAgICAgICAgICAgYXBpX2tleSA9IHNlY3JldHMudG9rZW5faGV4KDMyKQogICAgICAgICAgICBrZXlfZmlsZS5wYXJlbnQubWtkaXIocGFyZW50cz1UcnVlLCBleGlzdF9vaz1UcnVlKQogICAgICAgICAgICBrZXlfZmlsZS53cml0ZV90ZXh0KGFwaV9rZXkgKyAiXG4iKQogICAgICAgICAgICBvcy5jaG1vZChrZXlfZmlsZSwgMG82MDApICAjIFJlc3RyaWN0IGtleSBmaWxlIHRvIG93bmVyIG9ubHkKICAgICAgICAgICAgcHJpbnQoZiLwn5SRIEdlbmVyYXRlZCBBUEkga2V5IHNhdmVkIHRvIHtrZXlfZmlsZX0iKQoKICAgIHNlcnZlciA9IE93bFNlcnZlcigKICAgICAgICBob3N0PWFyZ3MuaG9zdCwKICAgICAgICBhcGlfcG9ydD1hcmdzLmFwaV9wb3J0LAogICAgICAgIG1ldHJpY3NfcG9ydD1hcmdzLm1ldHJpY3NfcG9ydCwKICAgICAgICBhcGlfa2V5PWFwaV9rZXksCiAgICAgICAgdXNlX2N1cmxfY2ZmaT1ub3QgYXJncy5ub19jdXJsX2NmZmksCiAgICAgICAgZW5hYmxlX2FiX3Rlc3Q9YXJncy5hYl90ZXN0LAogICAgICAgIGVuYWJsZV9tbD1hcmdzLm1sLAogICAgICAgIG1sX21vZGVsPWFyZ3MubWxfbW9kZWwsCiAgICAgICAgcGx1Z2luX2Rpcj1hcmdzLnBsdWdpbl9kaXIsCiAgICAgICAgY291bnRyaWVzPWFyZ3MuY291bnRyaWVzLAogICAgICAgIHVzZV9yZWRpcz1hcmdzLnJlZGlzLAogICAgICAgIHJlZGlzX3VybD1hcmdzLnJlZGlzX3VybCwKICAgICkKICAgIHNlcnZlci5fc3RhcnRfdGltZSA9IHRpbWUudGltZSgpCgogICAgcHJpbnQoZiIiIgrwn6aJIE9XTC1BR0VOVCB2NC41IFNlcnZlcgp7Jz0nICogNTV9CiAgQVBJOiAgICAgICBodHRwOi8ve2FyZ3MuaG9zdH06e2FyZ3MuYXBpX3BvcnR9CiAgTWV0cmljczogICBodHRwOi8ve2FyZ3MuaG9zdH06e2FyZ3MubWV0cmljc19wb3J0fS9tZXRyaWNzCiAgQ291bnRyaWVzOiB7JywgJy5qb2luKGFyZ3MuY291bnRyaWVzKX0KICBSZWRpczogICAgIHsnZW5hYmxlZCcgaWYgYXJncy5yZWRpcyBlbHNlICdkaXNhYmxlZCd9CiAgY3VybF9jZmZpOiAgeydlbmFibGVkJyBpZiBub3QgYXJncy5ub19jdXJsX2NmZmkgZWxzZSAnZGlzYWJsZWQnfQogIEEvQiBUZXN0OiAgeydlbmFibGVkJyBpZiBhcmdzLmFiX3Rlc3QgZWxzZSAnZGlzYWJsZWQnfQogIE1MOiAgICAgICAgeydlbmFibGVkJyBpZiBhcmdzLm1sIGVsc2UgJ2Rpc2FibGVkJ30KICBBdXRoOiAgICAgIEJlYXJlciBrZXkgcmVxdWlyZWQgKGV4Y2VwdCAvaGVhbHRoKQp7Jz0nICogNTV9CiAgICAiIiIpCiAgICBwcmludChmIvCflJEgQVBJIGtleSAobGFzdCA0KTogLi4ue2FwaV9rZXlbLTQ6XX0g4oCUIHNlbmQgYXMgJ0F1dGhvcml6YXRpb246IEJlYXJlciA8a2V5Picgb3IgJ1gtQVBJLUtleTogPGtleT4nIikKCiAgICBhd2FpdCBzZXJ2ZXIuc3RhcnQoKQoKICAgIHRyeToKICAgICAgICAjIEtlZXAgcnVubmluZyB1bnRpbCBTSUdJTlQvU0lHVEVSTQogICAgICAgIGF3YWl0IGFzeW5jaW8uRXZlbnQoKS53YWl0KCkKICAgIGV4Y2VwdCBhc3luY2lvLkNhbmNlbGxlZEVycm9yOgogICAgICAgIHBhc3MKICAgIGZpbmFsbHk6CiAgICAgICAgYXdhaXQgc2VydmVyLnN0b3AoKQoKCmlmIF9fbmFtZV9fID09ICJfX21haW5fXyI6CiAgICBhc3luY2lvLnJ1bihtYWluKCkpCg=="
_EMBED_proxy_defense_py="IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiIK8J+miSBPV0wtQUdFTlQgUFJPWFkgREVGRU5TRSBTVEFDSyB2NC4zCi0gUHJveHlCcm9rZXIyIHdpdGggY291bnRyeSBmaWx0ZXJpbmcKLSBRdWFsaXR5IHNjb3JpbmcgKHdlaWdodGVkIHN1Y2Nlc3MvbGF0ZW5jeSkKLSBBZGFwdGl2ZSByYXRlIGxpbWl0aW5nIChwZXItZG9tYWluKQotIFJlZGlzIHN0YXRlIHNoYXJpbmcgKG9wdGlvbmFsKQotIGN1cmxfY2ZmaSBDaHJvbWUgZmluZ2VycHJpbnRpbmcKLSBSZXRyeS1BZnRlciBwYXJzaW5nCi0gQ2lyY3VpdCBicmVha2VyCi0gYWdlbnQtYnJvd3NlciBpbnRlZ3JhdGlvbgotIExSVSBjYWNoZSwgZGVkdXAsIGRpcmVjdCBmYWxsYmFjawotIFBsdWdpbiBTeXN0ZW0gKHJlcXVlc3QvcmVzcG9uc2UgaG9va3MpCi0gQS9CIFRlc3RpbmcgKHN0cmF0ZWd5IGNvbXBhcmlzb24gcGVyIGRvbWFpbikKLSBNTCBQcmVkaWN0b3IgKGxvZ2lzdGljIHJlZ3Jlc3Npb24gcHJveHkgc2VsZWN0aW9uKQoiIiIKCmltcG9ydCBhc3luY2lvCmltcG9ydCBoYXNobGliCmltcG9ydCBpbnNwZWN0CmltcG9ydCBqc29uCmltcG9ydCB0aW1lCmltcG9ydCBsb2dnaW5nCmltcG9ydCBzdWJwcm9jZXNzCmltcG9ydCByYW5kb20KaW1wb3J0IHN0YXRpc3RpY3MKaW1wb3J0IGVtYWlsLnV0aWxzCmltcG9ydCBkYXRldGltZQppbXBvcnQgc3lzCmltcG9ydCB3YXJuaW5ncwpmcm9tIGRhdGFjbGFzc2VzIGltcG9ydCBkYXRhY2xhc3MsIGZpZWxkCmZyb20gdHlwaW5nIGltcG9ydCBPcHRpb25hbCwgRGljdCwgQW55LCBDYWxsYWJsZSwgQXdhaXRhYmxlLCBMaXN0LCBTZXQKZnJvbSBwYXRobGliIGltcG9ydCBQYXRoCmZyb20gdXJsbGliLnBhcnNlIGltcG9ydCB1cmxwYXJzZQpmcm9tIGNvbGxlY3Rpb25zIGltcG9ydCBPcmRlcmVkRGljdCwgZGVmYXVsdGRpY3QKCmltcG9ydCBhaW9odHRwCmltcG9ydCBhaW9maWxlcwppbXBvcnQgaHR0cHgKZnJvbSBjaXJjdWl0YnJlYWtlciBpbXBvcnQgQ2lyY3VpdEJyZWFrZXIKCiMg4pSA4pSA4pSAIFB5dGhvbiAzLjE0KyBjb21wYXRpYmlsaXR5OiBtb25rZXktcGF0Y2ggYXN5bmNpby5nZXRfZXZlbnRfbG9vcCDilIDilIDilIAKIyBQcm94eUJyb2tlcjIgY2FsbHMgYXN5bmNpby5nZXRfZXZlbnRfbG9vcCgpIGF0IG1vZHVsZSBpbXBvcnQgdGltZS4KIyBQeXRob24gMy4xNCBjaGFuZ2VkIGdldF9ldmVudF9sb29wKCkgdG8gcmFpc2UgUnVudGltZUVycm9yIGluc3RlYWQgb2YKIyBjcmVhdGluZyBhIG5ldyBsb29wLCB3aGljaCBicmVha3MgcHJveHlicm9rZXIyIGVudGlyZWx5LgojIFRoaXMgcGF0Y2ggcmVzdG9yZXMgdGhlIG9sZCBiZWhhdmlvciBzbyBwcm94eWJyb2tlcjIgY2FuIGJlIGltcG9ydGVkLgppZiBzeXMudmVyc2lvbl9pbmZvID49ICgzLCAxMik6CiAgICBfb3JpZ2luYWxfZ2V0X2V2ZW50X2xvb3AgPSBhc3luY2lvLmdldF9ldmVudF9sb29wCgogICAgZGVmIF9wYXRjaGVkX2dldF9ldmVudF9sb29wKCk6CiAgICAgICAgdHJ5OgogICAgICAgICAgICByZXR1cm4gX29yaWdpbmFsX2dldF9ldmVudF9sb29wKCkKICAgICAgICBleGNlcHQgUnVudGltZUVycm9yOgogICAgICAgICAgICBsb29wID0gYXN5bmNpby5uZXdfZXZlbnRfbG9vcCgpCiAgICAgICAgICAgIGFzeW5jaW8uc2V0X2V2ZW50X2xvb3AobG9vcCkKICAgICAgICAgICAgcmV0dXJuIGxvb3AKCiAgICBhc3luY2lvLmdldF9ldmVudF9sb29wID0gX3BhdGNoZWRfZ2V0X2V2ZW50X2xvb3AKICAgICMgU3VwcHJlc3MgdGhlIGRlcHJlY2F0aW9uIHdhcm5pbmcgZm9yIGdldF9ldmVudF9sb29wX3BvbGljeQogICAgd2FybmluZ3MuZmlsdGVyd2FybmluZ3MoJ2lnbm9yZScsIG1lc3NhZ2U9Ii4qZ2V0X2V2ZW50X2xvb3BfcG9saWN5LioiKQogICAgd2FybmluZ3MuZmlsdGVyd2FybmluZ3MoJ2lnbm9yZScsIG1lc3NhZ2U9Ii4qZ2V0X2V2ZW50X2xvb3AuKmRlcHJlY2F0ZWQuKiIpCgojIOKUgOKUgOKUgCBjdXJsX2NmZmkgU1NMIGNlcnQgcGF0aCDilIDilIDilIAgTVVTVCBiZSBzZXQgQkVGT1JFIGN1cmxfY2ZmaSBpbXBvcnQg4pSA4pSA4pSACl9DQV9CVU5ETEUgPSAiL2V0Yy9zc2wvY2VydHMvY2EtY2VydGlmaWNhdGVzLmNydCIKaWYgUGF0aChfQ0FfQlVORExFKS5leGlzdHMoKToKICAgIGltcG9ydCBvcyBhcyBfb3MKICAgIF9vcy5lbnZpcm9uLnNldGRlZmF1bHQoIlNTTF9DRVJUX0ZJTEUiLCBfQ0FfQlVORExFKQogICAgX29zLmVudmlyb24uc2V0ZGVmYXVsdCgiQ1VSTF9DQV9CVU5ETEUiLCBfQ0FfQlVORExFKQoKIyBPcHRpb25hbCBjdXJsX2NmZmkKdHJ5OgogICAgZnJvbSBjdXJsX2NmZmkucmVxdWVzdHMgaW1wb3J0IEFzeW5jU2Vzc2lvbiBhcyBDdXJsQXN5bmNTZXNzaW9uCiAgICBDVVJMX0NGRklfQVZBSUxBQkxFID0gVHJ1ZQpleGNlcHQgSW1wb3J0RXJyb3I6CiAgICBDVVJMX0NGRklfQVZBSUxBQkxFID0gRmFsc2UKCiMgT3B0aW9uYWwgUmVkaXMKdHJ5OgogICAgaW1wb3J0IHJlZGlzLmFzeW5jaW8gYXMgcmVkaXMKICAgIFJFRElTX0FWQUlMQUJMRSA9IFRydWUKZXhjZXB0IEltcG9ydEVycm9yOgogICAgUkVESVNfQVZBSUxBQkxFID0gRmFsc2UKCiMgT3B0aW9uYWwgTUwgZGVwZW5kZW5jaWVzCnRyeToKICAgIGZyb20gc2tsZWFybi5saW5lYXJfbW9kZWwgaW1wb3J0IExvZ2lzdGljUmVncmVzc2lvbgogICAgZnJvbSBza2xlYXJuLnByZXByb2Nlc3NpbmcgaW1wb3J0IFN0YW5kYXJkU2NhbGVyCiAgICBmcm9tIHNrbGVhcm4ubW9kZWxfc2VsZWN0aW9uIGltcG9ydCBjcm9zc192YWxfc2NvcmUKICAgIGltcG9ydCBudW1weSBhcyBucAogICAgU0tMRUFSTl9BVkFJTEFCTEUgPSBUcnVlCmV4Y2VwdCBJbXBvcnRFcnJvcjoKICAgIFNLTEVBUk5fQVZBSUxBQkxFID0gRmFsc2UKCiMgdjQuNDogQWR2YW5jZWQgTUwgbW9kZWxzCnRyeToKICAgIGZyb20gbWxfbW9kZWxzIGltcG9ydCBBZHZhbmNlZE1MUHJlZGljdG9yLCBYR0JfQVZBSUxBQkxFCmV4Y2VwdCBJbXBvcnRFcnJvcjoKICAgIEFkdmFuY2VkTUxQcmVkaWN0b3IgPSBOb25lCiAgICBYR0JfQVZBSUxBQkxFID0gRmFsc2UKCiMgdjQuNTogU2VsZi1oZWFsaW5nIHBsdWdpbiBsb2FkZXIKdHJ5OgogICAgZnJvbSBwbHVnaW5fbG9hZGVyIGltcG9ydCBQbHVnaW5Mb2FkZXIKZXhjZXB0IEltcG9ydEVycm9yOgogICAgUGx1Z2luTG9hZGVyID0gTm9uZQoKIyDilIDilIDilIAgUGF0aHMg4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSACkNBQ0hFX0RJUiA9IFBhdGguaG9tZSgpIC8gIi5vd2wtYWdlbnQiIC8gImNhY2hlIiAvICJodHRwIgpDT05GSUdfRElSID0gUGF0aC5ob21lKCkgLyAiLm93bC1hZ2VudCIgLyAiY29uZmlnIgpQUk9YWV9DQUNIRV9GSUxFID0gQ09ORklHX0RJUiAvICJwcm94eV9jYWNoZS5qc29uIgoKQ0FDSEVfRElSLm1rZGlyKHBhcmVudHM9VHJ1ZSwgZXhpc3Rfb2s9VHJ1ZSkKQ09ORklHX0RJUi5ta2RpcihwYXJlbnRzPVRydWUsIGV4aXN0X29rPVRydWUpCgojIOKUgOKUgOKUgCBDb25zdGFudHMg4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSACkRFRkFVTFRfVFRMID0gMzAwCkRFRkFVTFRfUkFURSA9IDEuMApNQVhfUkVUUklFUyA9IDMKTUFYX0NBQ0hFRF9SRVNQT05TRVMgPSAxMDAwCk1BWF9QUk9YWV9DQUNIRSA9IDEwMApNQVhfU0VTU0lPTlMgPSAyMApNQVhfRE9NQUlOU19SQVRFX0xJTUlUID0gMTAwMApDSVJDVUlUX0JSRUFLRVJfRkFJTFVSRV9USFJFU0hPTEQgPSA1CkNJUkNVSVRfQlJFQUtFUl9SRUNPVkVSWV9USU1FT1VUID0gMzAKREVGQVVMVF9DT1VOVFJJRVMgPSBbIlVTIiwgIkdCIiwgIkRFIiwgIkZSIiwgIkNBIl0KUVVBTElUWV9ERUNBWSA9IDAuOQpBREFQVElWRV9NSU5fUkFURSA9IDAuMQpBREFQVElWRV9NQVhfUkFURSA9IDUuMApBQl9NSU5fU0FNUExFX1NJWkUgPSAxMDAKTUxfTUlOX1NBTVBMRVMgPSAyMApNTF9NQVhfU0FNUExFUyA9IDEwMDAKTUxfU1RBTEVORVNTX1RIUkVTSE9MRCA9IDAuNiAgIyBNaW5pbXVtIENWIHNjb3JlIHRvIGNvbnNpZGVyIG1vZGVsIHZhbGlkCgpsb2dnaW5nLmJhc2ljQ29uZmlnKGxldmVsPWxvZ2dpbmcuSU5GTywgZm9ybWF0PSclKGFzY3RpbWUpcyBbJShsZXZlbG5hbWUpc10gJShuYW1lKXM6ICUobWVzc2FnZSlzJykKbG9nZ2VyID0gbG9nZ2luZy5nZXRMb2dnZXIoIm93bC1hZ2VudC5wcm94eSIpCgojIOKUgOKUgOKUgCBEYXRhIENsYXNzZXMgKG1lbW9yeS1vcHRpbWlzZWQpIOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgApAZGF0YWNsYXNzKHNsb3RzPVRydWUpCmNsYXNzIENhY2hlZFJlc3BvbnNlOgogICAgc3RhdHVzOiBpbnQKICAgIGNvbnRlbnQ6IGJ5dGVzCiAgICBoZWFkZXJzOiBEaWN0W3N0ciwgc3RyXQogICAgdGltZXN0YW1wOiBmbG9hdAogICAgdHRsOiBpbnQKICAgIHByb3RvY29sOiBzdHIgPSAiaHR0cC8xLjEiCiAgICBkZWYgaXNfZnJlc2goc2VsZikgLT4gYm9vbDoKICAgICAgICByZXR1cm4gdGltZS50aW1lKCkgLSBzZWxmLnRpbWVzdGFtcCA8IHNlbGYudHRsCgpAZGF0YWNsYXNzKHNsb3RzPVRydWUpCmNsYXNzIFRva2VuQnVja2V0OgogICAgcmF0ZTogZmxvYXQKICAgIGNhcGFjaXR5OiBmbG9hdAogICAgdG9rZW5zOiBmbG9hdCA9IDAuMAogICAgbGFzdF91cGRhdGU6IGZsb2F0ID0gZmllbGQoZGVmYXVsdF9mYWN0b3J5PXRpbWUudGltZSkKICAgIGxvY2s6IGFzeW5jaW8uTG9jayA9IGZpZWxkKGRlZmF1bHRfZmFjdG9yeT1hc3luY2lvLkxvY2spCiAgICBhc3luYyBkZWYgX3JlcGxlbmlzaChzZWxmKToKICAgICAgICBub3cgPSB0aW1lLnRpbWUoKQogICAgICAgIGVsYXBzZWQgPSBub3cgLSBzZWxmLmxhc3RfdXBkYXRlCiAgICAgICAgYXN5bmMgd2l0aCBzZWxmLmxvY2s6CiAgICAgICAgICAgIHNlbGYudG9rZW5zID0gbWluKHNlbGYuY2FwYWNpdHksIHNlbGYudG9rZW5zICsgZWxhcHNlZCAqIHNlbGYucmF0ZSkKICAgICAgICAgICAgc2VsZi5sYXN0X3VwZGF0ZSA9IG5vdwogICAgYXN5bmMgZGVmIGFjcXVpcmUoc2VsZiwgdG9rZW5zOiBmbG9hdCA9IDEuMCkgLT4gYm9vbDoKICAgICAgICBhd2FpdCBzZWxmLl9yZXBsZW5pc2goKQogICAgICAgIGFzeW5jIHdpdGggc2VsZi5sb2NrOgogICAgICAgICAgICBpZiBzZWxmLnRva2VucyA+PSB0b2tlbnM6CiAgICAgICAgICAgICAgICBzZWxmLnRva2VucyAtPSB0b2tlbnMKICAgICAgICAgICAgICAgIHJldHVybiBUcnVlCiAgICAgICAgd2FpdF90aW1lID0gKHRva2VucyAtIHNlbGYudG9rZW5zKSAvIHNlbGYucmF0ZQogICAgICAgIGF3YWl0IGFzeW5jaW8uc2xlZXAod2FpdF90aW1lKQogICAgICAgIHJldHVybiBhd2FpdCBzZWxmLmFjcXVpcmUodG9rZW5zKQoKQGRhdGFjbGFzcyhzbG90cz1UcnVlKQpjbGFzcyBQcm94eUVudHJ5OgogICAgdXJsOiBzdHIKICAgIGhlYWx0aHk6IGJvb2wgPSBUcnVlCiAgICBsYXN0X2NoZWNrOiBmbG9hdCA9IDAuMAogICAgZmFpbF9jb3VudDogaW50ID0gMAogICAgYmFuX3VudGlsOiBmbG9hdCA9IDAuMAogICAgZGVmIGlzX2Jhbm5lZChzZWxmKSAtPiBib29sOgogICAgICAgIHJldHVybiB0aW1lLnRpbWUoKSA8IHNlbGYuYmFuX3VudGlsCiAgICBkZWYgbWFya19mYWlsZWQoc2VsZik6CiAgICAgICAgc2VsZi5mYWlsX2NvdW50ICs9IDEKICAgICAgICBzZWxmLmJhbl91bnRpbCA9IHRpbWUudGltZSgpICsgNjAKICAgICAgICBzZWxmLmhlYWx0aHkgPSBGYWxzZQogICAgICAgIGxvZ2dlci53YXJuaW5nKGYiUHJveHkgYmFubmVkICg2MHMpOiB7c2VsZi51cmx9IikKICAgIGRlZiBtYXJrX3N1Y2Nlc3Moc2VsZik6CiAgICAgICAgc2VsZi5mYWlsX2NvdW50ID0gMAogICAgICAgIHNlbGYuaGVhbHRoeSA9IFRydWUKICAgICAgICBzZWxmLmxhc3RfY2hlY2sgPSB0aW1lLnRpbWUoKQoKIyDilIDilIDilIAgSFRUUENhY2hlIChMUlUgKyBwZXJpb2RpYyBjbGVhbnVwKSDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIAKY2xhc3MgSFRUUENhY2hlOgogICAgZGVmIF9faW5pdF9fKHNlbGYsIHR0bDogaW50ID0gREVGQVVMVF9UVEwsIG1heF9zaXplOiBpbnQgPSBNQVhfQ0FDSEVEX1JFU1BPTlNFUyk6CiAgICAgICAgc2VsZi50dGwgPSB0dGwKICAgICAgICBzZWxmLl9tYXhfc2l6ZSA9IG1heF9zaXplCiAgICAgICAgc2VsZi5fbWVtb3J5OiBEaWN0W3N0ciwgQ2FjaGVkUmVzcG9uc2VdID0ge30KICAgICAgICBzZWxmLl9sb2NrID0gYXN5bmNpby5Mb2NrKCkKICAgICAgICBzZWxmLl9jbGVhbnVwX3Rhc2s6IE9wdGlvbmFsW2FzeW5jaW8uVGFza10gPSBOb25lCgogICAgYXN5bmMgZGVmIHN0YXJ0X2NsZWFuZXIoc2VsZik6CiAgICAgICAgaWYgc2VsZi5fY2xlYW51cF90YXNrIGlzIE5vbmUgb3Igc2VsZi5fY2xlYW51cF90YXNrLmRvbmUoKToKICAgICAgICAgICAgc2VsZi5fY2xlYW51cF90YXNrID0gYXN5bmNpby5jcmVhdGVfdGFzayhzZWxmLl9jbGVhbnVwX2xvb3AoKSkKCiAgICBhc3luYyBkZWYgX2NsZWFudXBfbG9vcChzZWxmKToKICAgICAgICB3aGlsZSBUcnVlOgogICAgICAgICAgICBhd2FpdCBhc3luY2lvLnNsZWVwKDYwKQogICAgICAgICAgICBub3cgPSB0aW1lLnRpbWUoKQogICAgICAgICAgICBhc3luYyB3aXRoIHNlbGYuX2xvY2s6CiAgICAgICAgICAgICAgICBleHBpcmVkID0gW2sgZm9yIGssIHYgaW4gc2VsZi5fbWVtb3J5Lml0ZW1zKCkgaWYgbm90IHYuaXNfZnJlc2goKV0KICAgICAgICAgICAgICAgIGZvciBrIGluIGV4cGlyZWQ6CiAgICAgICAgICAgICAgICAgICAgZGVsIHNlbGYuX21lbW9yeVtrXQogICAgICAgICAgICAgICAgaWYgbGVuKHNlbGYuX21lbW9yeSkgPiBzZWxmLl9tYXhfc2l6ZToKICAgICAgICAgICAgICAgICAgICBzb3J0ZWRfaXRlbXMgPSBzb3J0ZWQoc2VsZi5fbWVtb3J5Lml0ZW1zKCksIGtleT1sYW1iZGEgeDogeFsxXS50aW1lc3RhbXApCiAgICAgICAgICAgICAgICAgICAgZm9yIGssIF8gaW4gc29ydGVkX2l0ZW1zWzpsZW4oc2VsZi5fbWVtb3J5KS1zZWxmLl9tYXhfc2l6ZV06CiAgICAgICAgICAgICAgICAgICAgICAgIGRlbCBzZWxmLl9tZW1vcnlba10KCiAgICBkZWYgX2tleShzZWxmLCBtZXRob2Q6IHN0ciwgdXJsOiBzdHIsIHBhcmFtczogT3B0aW9uYWxbRGljdF0gPSBOb25lLCBwcm90b2NvbDogc3RyID0gImh0dHAvMS4xIikgLT4gc3RyOgogICAgICAgIHJldHVybiBoYXNobGliLnNoYTI1NihmInttZXRob2R9Ont1cmx9Ontqc29uLmR1bXBzKHBhcmFtcyBvciB7fSwgc29ydF9rZXlzPVRydWUpfTp7cHJvdG9jb2x9Ii5lbmNvZGUoKSkuaGV4ZGlnZXN0KCkKCiAgICBhc3luYyBkZWYgZ2V0KHNlbGYsIG1ldGhvZDogc3RyLCB1cmw6IHN0ciwgcGFyYW1zOiBPcHRpb25hbFtEaWN0XSA9IE5vbmUsIHByb3RvY29sOiBzdHIgPSAiaHR0cC8xLjEiKSAtPiBPcHRpb25hbFtDYWNoZWRSZXNwb25zZV06CiAgICAgICAga2V5ID0gc2VsZi5fa2V5KG1ldGhvZCwgdXJsLCBwYXJhbXMsIHByb3RvY29sKQogICAgICAgIGlmIGtleSBpbiBzZWxmLl9tZW1vcnkgYW5kIHNlbGYuX21lbW9yeVtrZXldLmlzX2ZyZXNoKCk6CiAgICAgICAgICAgIHJldHVybiBzZWxmLl9tZW1vcnlba2V5XQogICAgICAgIHBhdGggPSBDQUNIRV9ESVIgLyBmIntrZXl9Lmpzb24iCiAgICAgICAgaWYgcGF0aC5leGlzdHMoKToKICAgICAgICAgICAgdHJ5OgogICAgICAgICAgICAgICAgYXN5bmMgd2l0aCBhaW9maWxlcy5vcGVuKHBhdGgsICdyJykgYXMgZjoKICAgICAgICAgICAgICAgICAgICBkYXRhID0ganNvbi5sb2Fkcyhhd2FpdCBmLnJlYWQoKSkKICAgICAgICAgICAgICAgIGNhY2hlZCA9IENhY2hlZFJlc3BvbnNlKAogICAgICAgICAgICAgICAgICAgIHN0YXR1cz1kYXRhWyJzdGF0dXMiXSwgY29udGVudD1kYXRhWyJjb250ZW50Il0uZW5jb2RlKCd1dGYtOCcsIGVycm9ycz0ncmVwbGFjZScpLAogICAgICAgICAgICAgICAgICAgIGhlYWRlcnM9ZGF0YVsiaGVhZGVycyJdLCB0aW1lc3RhbXA9ZGF0YVsidGltZXN0YW1wIl0sIHR0bD1kYXRhWyJ0dGwiXSwgcHJvdG9jb2w9ZGF0YS5nZXQoInByb3RvY29sIiwgImh0dHAvMS4xIikKICAgICAgICAgICAgICAgICkKICAgICAgICAgICAgICAgIGlmIGNhY2hlZC5pc19mcmVzaCgpOgogICAgICAgICAgICAgICAgICAgIGFzeW5jIHdpdGggc2VsZi5fbG9jazoKICAgICAgICAgICAgICAgICAgICAgICAgc2VsZi5fbWVtb3J5W2tleV0gPSBjYWNoZWQKICAgICAgICAgICAgICAgICAgICByZXR1cm4gY2FjaGVkCiAgICAgICAgICAgICAgICBlbHNlOgogICAgICAgICAgICAgICAgICAgIHBhdGgudW5saW5rKCkKICAgICAgICAgICAgZXhjZXB0IEV4Y2VwdGlvbjoKICAgICAgICAgICAgICAgIHBhc3MKICAgICAgICByZXR1cm4gTm9uZQoKICAgIGFzeW5jIGRlZiBzZXQoc2VsZiwgbWV0aG9kOiBzdHIsIHVybDogc3RyLCByZXNwb25zZTogQ2FjaGVkUmVzcG9uc2UsIHBhcmFtczogT3B0aW9uYWxbRGljdF0gPSBOb25lKToKICAgICAgICBrZXkgPSBzZWxmLl9rZXkobWV0aG9kLCB1cmwsIHBhcmFtcywgcmVzcG9uc2UucHJvdG9jb2wpCiAgICAgICAgYXN5bmMgd2l0aCBzZWxmLl9sb2NrOgogICAgICAgICAgICBzZWxmLl9tZW1vcnlba2V5XSA9IHJlc3BvbnNlCiAgICAgICAgcGF0aCA9IENBQ0hFX0RJUiAvIGYie2tleX0uanNvbiIKICAgICAgICBkYXRhID0geyJzdGF0dXMiOiByZXNwb25zZS5zdGF0dXMsICJjb250ZW50IjogcmVzcG9uc2UuY29udGVudC5kZWNvZGUoJ3V0Zi04JywgZXJyb3JzPSdyZXBsYWNlJyksICJoZWFkZXJzIjogcmVzcG9uc2UuaGVhZGVycywKICAgICAgICAgICAgICAgICJ0aW1lc3RhbXAiOiByZXNwb25zZS50aW1lc3RhbXAsICJ0dGwiOiByZXNwb25zZS50dGwsICJwcm90b2NvbCI6IHJlc3BvbnNlLnByb3RvY29sfQogICAgICAgIGFzeW5jIHdpdGggYWlvZmlsZXMub3BlbihwYXRoLCAndycpIGFzIGY6CiAgICAgICAgICAgIGF3YWl0IGYud3JpdGUoanNvbi5kdW1wcyhkYXRhKSkKCiMg4pSA4pSA4pSAIFJlcXVlc3REZWR1cGxpY2F0b3Ig4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSACmNsYXNzIFJlcXVlc3REZWR1cGxpY2F0b3I6CiAgICBkZWYgX19pbml0X18oc2VsZik6CiAgICAgICAgc2VsZi5faW5fZmxpZ2h0OiBEaWN0W3N0ciwgYXN5bmNpby5GdXR1cmVdID0ge30KICAgICAgICBzZWxmLl9sb2NrID0gYXN5bmNpby5Mb2NrKCkKICAgIGRlZiBfa2V5KHNlbGYsIG1ldGhvZDogc3RyLCB1cmw6IHN0ciwgcGFyYW1zOiBPcHRpb25hbFtEaWN0XSA9IE5vbmUsIHByb3RvY29sOiBzdHIgPSAiaHR0cC8xLjEiKSAtPiBzdHI6CiAgICAgICAgcmV0dXJuIGhhc2hsaWIuc2hhMjU2KGYie21ldGhvZH06e3VybH06e2pzb24uZHVtcHMocGFyYW1zIG9yIHt9LCBzb3J0X2tleXM9VHJ1ZSl9Ontwcm90b2NvbH0iLmVuY29kZSgpKS5oZXhkaWdlc3QoKQogICAgYXN5bmMgZGVmIGV4ZWN1dGUoc2VsZiwgbWV0aG9kOiBzdHIsIHVybDogc3RyLCBwYXJhbXM6IE9wdGlvbmFsW0RpY3RdLCBwcm90b2NvbDogc3RyLCBmYWN0b3J5OiBDYWxsYWJsZVtbXSwgQXdhaXRhYmxlW0NhY2hlZFJlc3BvbnNlXV0pIC0+IENhY2hlZFJlc3BvbnNlOgogICAgICAgIGtleSA9IHNlbGYuX2tleShtZXRob2QsIHVybCwgcGFyYW1zLCBwcm90b2NvbCkKICAgICAgICBhc3luYyB3aXRoIHNlbGYuX2xvY2s6CiAgICAgICAgICAgIGlmIGtleSBpbiBzZWxmLl9pbl9mbGlnaHQ6CiAgICAgICAgICAgICAgICByZXR1cm4gYXdhaXQgc2VsZi5faW5fZmxpZ2h0W2tleV0KICAgICAgICAgICAgZnV0dXJlID0gYXN5bmNpby5GdXR1cmUoKQogICAgICAgICAgICBzZWxmLl9pbl9mbGlnaHRba2V5XSA9IGZ1dHVyZQogICAgICAgIHRyeToKICAgICAgICAgICAgcmVzdWx0ID0gYXdhaXQgZmFjdG9yeSgpCiAgICAgICAgICAgIGZ1dHVyZS5zZXRfcmVzdWx0KHJlc3VsdCkKICAgICAgICAgICAgcmV0dXJuIHJlc3VsdAogICAgICAgIGV4Y2VwdCBFeGNlcHRpb24gYXMgZToKICAgICAgICAgICAgZnV0dXJlLnNldF9leGNlcHRpb24oZSkKICAgICAgICAgICAgcmFpc2UKICAgICAgICBmaW5hbGx5OgogICAgICAgICAgICBhc3luYyB3aXRoIHNlbGYuX2xvY2s6CiAgICAgICAgICAgICAgICBzZWxmLl9pbl9mbGlnaHQucG9wKGtleSwgTm9uZSkKCiMg4pSA4pSA4pSAIFF1YWxpdHlTY29yZXIg4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSACmNsYXNzIFF1YWxpdHlTY29yZXI6CiAgICAiIiJXZWlnaHRlZCBzY29yaW5nIGZvciBwcm94aWVzIGJhc2VkIG9uIHN1Y2Nlc3MgcmF0ZSBhbmQgbGF0ZW5jeS4iIiIKICAgIGRlZiBfX2luaXRfXyhzZWxmLCBkZWNheV9mYWN0b3I6IGZsb2F0ID0gUVVBTElUWV9ERUNBWSk6CiAgICAgICAgc2VsZi5fc2NvcmVzOiBEaWN0W3N0ciwgZmxvYXRdID0ge30KICAgICAgICBzZWxmLl9oaXN0b3J5OiBEaWN0W3N0ciwgTGlzdFtmbG9hdF1dID0ge30KICAgICAgICBzZWxmLl9kZWNheSA9IGRlY2F5X2ZhY3RvcgoKICAgIGRlZiB1cGRhdGUoc2VsZiwgcHJveHlfdXJsOiBzdHIsIHN1Y2Nlc3M6IGJvb2wsIGxhdGVuY3lfbXM6IGZsb2F0ID0gOTk5OS4wKToKICAgICAgICBvbGRfc2NvcmUgPSBzZWxmLl9zY29yZXMuZ2V0KHByb3h5X3VybCwgMC41KQogICAgICAgIG5ld19zY29yZSA9IG9sZF9zY29yZSAqIHNlbGYuX2RlY2F5ICsgKDEuMCBpZiBzdWNjZXNzIGVsc2UgMC4wKSAqICgxIC0gc2VsZi5fZGVjYXkpCiAgICAgICAgc2VsZi5fc2NvcmVzW3Byb3h5X3VybF0gPSBuZXdfc2NvcmUKICAgICAgICBpZiBwcm94eV91cmwgbm90IGluIHNlbGYuX2hpc3Rvcnk6CiAgICAgICAgICAgIHNlbGYuX2hpc3RvcnlbcHJveHlfdXJsXSA9IFtdCiAgICAgICAgc2VsZi5faGlzdG9yeVtwcm94eV91cmxdLmFwcGVuZChsYXRlbmN5X21zKQogICAgICAgIGlmIGxlbihzZWxmLl9oaXN0b3J5W3Byb3h5X3VybF0pID4gMTAwOgogICAgICAgICAgICBzZWxmLl9oaXN0b3J5W3Byb3h5X3VybF0gPSBzZWxmLl9oaXN0b3J5W3Byb3h5X3VybF1bLTEwMDpdCgogICAgZGVmIGdldF9zY29yZShzZWxmLCBwcm94eV91cmw6IHN0cikgLT4gZmxvYXQ6CiAgICAgICAgcmV0dXJuIHNlbGYuX3Njb3Jlcy5nZXQocHJveHlfdXJsLCAwLjUpCgogICAgZGVmIGdldF9iZXN0X3Byb3h5KHNlbGYsIHByb3hpZXM6IExpc3Rbc3RyXSkgLT4gT3B0aW9uYWxbc3RyXToKICAgICAgICBpZiBub3QgcHJveGllczoKICAgICAgICAgICAgcmV0dXJuIE5vbmUKICAgICAgICByZXR1cm4gbWF4KHByb3hpZXMsIGtleT1sYW1iZGEgcDogc2VsZi5nZXRfc2NvcmUocCkpCgogICAgZGVmIGdldF9yZWNlbnRfc3VjY2Vzc19yYXRlKHNlbGYsIHByb3h5X3VybDogc3RyLCB3aW5kb3c6IGludCA9IDEwKSAtPiBmbG9hdDoKICAgICAgICAiIiJHZXQgc3VjY2VzcyByYXRlIGZyb20gbGFzdCBOIGVudHJpZXMgaW4gaGlzdG9yeS4iIiIKICAgICAgICBoaXN0b3J5ID0gc2VsZi5faGlzdG9yeS5nZXQocHJveHlfdXJsKQogICAgICAgIGlmIG5vdCBoaXN0b3J5IG9yIGxlbihoaXN0b3J5KSA9PSAwOgogICAgICAgICAgICByZXR1cm4gMC41CiAgICAgICAgcmVjZW50ID0gaGlzdG9yeVstd2luZG93Ol0KICAgICAgICByZXR1cm4gc3VtKHJlY2VudCkgLyBsZW4ocmVjZW50KSBpZiByZWNlbnQgZWxzZSAwLjUKCiAgICBkZWYgZ2V0X2F2Z19sYXRlbmN5KHNlbGYsIHByb3h5X3VybDogc3RyLCB3aW5kb3c6IGludCA9IDEwKSAtPiBmbG9hdDoKICAgICAgICAiIiJHZXQgYXZlcmFnZSBsYXRlbmN5IChtcykgZnJvbSBsYXN0IE4gZW50cmllcyBpbiBoaXN0b3J5LgoKICAgICAgICBQdWJsaWMgQVBJIHNvIE1MIHByZWRpY3RvciBkb2Vzbid0IGFjY2VzcyBfaGlzdG9yeSBkaXJlY3RseS4KICAgICAgICBSZXR1cm5zIDUwMC4wIChkZWZhdWx0KSBpZiBubyBkYXRhIGF2YWlsYWJsZS4KICAgICAgICAiIiIKICAgICAgICBoaXN0b3J5ID0gc2VsZi5faGlzdG9yeS5nZXQocHJveHlfdXJsKQogICAgICAgIGlmIG5vdCBoaXN0b3J5OgogICAgICAgICAgICByZXR1cm4gNTAwLjAKICAgICAgICByZWNlbnQgPSBoaXN0b3J5Wy13aW5kb3c6XQogICAgICAgIHJldHVybiBzdW0ocmVjZW50KSAvIGxlbihyZWNlbnQpIGlmIHJlY2VudCBlbHNlIDUwMC4wCgogICAgZGVmIGdldF9hbGxfc2NvcmVzKHNlbGYpIC0+IERpY3Rbc3RyLCBmbG9hdF06CiAgICAgICAgcmV0dXJuIHNlbGYuX3Njb3Jlcy5jb3B5KCkKCiMg4pSA4pSA4pSAIEFkYXB0aXZlUmF0ZUxpbWl0ZXIg4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSACmNsYXNzIEFkYXB0aXZlUmF0ZUxpbWl0ZXI6CiAgICAiIiJEeW5hbWljYWxseSBhZGp1c3RzIHBlci1kb21haW4gcmVxdWVzdCByYXRlIGJhc2VkIG9uIHJlc3BvbnNlIGNvZGVzLiIiIgogICAgZGVmIF9faW5pdF9fKHNlbGYsIGJhc2VfcmF0ZTogZmxvYXQgPSBERUZBVUxUX1JBVEUsCiAgICAgICAgICAgICAgICAgbWluX3JhdGU6IGZsb2F0ID0gQURBUFRJVkVfTUlOX1JBVEUsCiAgICAgICAgICAgICAgICAgbWF4X3JhdGU6IGZsb2F0ID0gQURBUFRJVkVfTUFYX1JBVEUpOgogICAgICAgIHNlbGYuYmFzZV9yYXRlID0gYmFzZV9yYXRlCiAgICAgICAgc2VsZi5taW5fcmF0ZSA9IG1pbl9yYXRlCiAgICAgICAgc2VsZi5tYXhfcmF0ZSA9IG1heF9yYXRlCiAgICAgICAgc2VsZi5fcmF0ZXM6IERpY3Rbc3RyLCBmbG9hdF0gPSB7fQogICAgICAgIHNlbGYuX2xvY2sgPSBhc3luY2lvLkxvY2soKQoKICAgIGFzeW5jIGRlZiBhZGp1c3Qoc2VsZiwgZG9tYWluOiBzdHIsIHN0YXR1czogaW50KToKICAgICAgICBhc3luYyB3aXRoIHNlbGYuX2xvY2s6CiAgICAgICAgICAgIGN1cnJlbnQgPSBzZWxmLl9yYXRlcy5nZXQoZG9tYWluLCBzZWxmLmJhc2VfcmF0ZSkKICAgICAgICAgICAgaWYgc3RhdHVzIGluICg0MjksIDUwMyk6CiAgICAgICAgICAgICAgICBuZXdfcmF0ZSA9IG1heChzZWxmLm1pbl9yYXRlLCBjdXJyZW50ICogMC41KQogICAgICAgICAgICBlbGlmIDIwMCA8PSBzdGF0dXMgPCAzMDA6CiAgICAgICAgICAgICAgICBuZXdfcmF0ZSA9IG1pbihzZWxmLm1heF9yYXRlLCBjdXJyZW50ICogMS4xKQogICAgICAgICAgICBlbHNlOgogICAgICAgICAgICAgICAgbmV3X3JhdGUgPSBjdXJyZW50CiAgICAgICAgICAgIHNlbGYuX3JhdGVzW2RvbWFpbl0gPSBuZXdfcmF0ZQogICAgICAgICAgICBsb2dnZXIuZGVidWcoZiJSYXRlIGZvciB7ZG9tYWlufToge25ld19yYXRlOi4yZn0gcmVxL3MiKQoKICAgIGFzeW5jIGRlZiBnZXRfcmF0ZShzZWxmLCBkb21haW46IHN0cikgLT4gZmxvYXQ6CiAgICAgICAgcmV0dXJuIHNlbGYuX3JhdGVzLmdldChkb21haW4sIHNlbGYuYmFzZV9yYXRlKQoKICAgIGFzeW5jIGRlZiBnZXRfYWxsX3JhdGVzKHNlbGYpIC0+IERpY3Rbc3RyLCBmbG9hdF06CiAgICAgICAgcmV0dXJuIHNlbGYuX3JhdGVzLmNvcHkoKQoKIyDilIDilIDilIAgUmVkaXNTdG9yZSAob3B0aW9uYWwpIOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgApjbGFzcyBSZWRpc1N0b3JlOgogICAgIiIiUGVyc2lzdGVudCBzdGF0ZSBzdG9yYWdlIHVzaW5nIFJlZGlzLiIiIgogICAgZGVmIF9faW5pdF9fKHNlbGYsIHVybDogc3RyID0gInJlZGlzOi8vbG9jYWxob3N0OjYzNzkiLCBwcmVmaXg6IHN0ciA9ICJvd2w6Iik6CiAgICAgICAgc2VsZi51cmwgPSB1cmwKICAgICAgICBzZWxmLnByZWZpeCA9IHByZWZpeAogICAgICAgIHNlbGYuX3JlZGlzID0gTm9uZQogICAgICAgIHNlbGYuX2VuYWJsZWQgPSBGYWxzZQoKICAgIGFzeW5jIGRlZiBjb25uZWN0KHNlbGYpOgogICAgICAgIGlmIG5vdCBSRURJU19BVkFJTEFCTEU6CiAgICAgICAgICAgIGxvZ2dlci53YXJuaW5nKCJSZWRpcyBub3QgaW5zdGFsbGVkIC0tIGZhbGxpbmcgYmFjayB0byBtZW1vcnkiKQogICAgICAgICAgICByZXR1cm4KICAgICAgICB0cnk6CiAgICAgICAgICAgIHNlbGYuX3JlZGlzID0gcmVkaXMuZnJvbV91cmwoc2VsZi51cmwsIGRlY29kZV9yZXNwb25zZXM9VHJ1ZSkKICAgICAgICAgICAgYXdhaXQgc2VsZi5fcmVkaXMucGluZygpCiAgICAgICAgICAgIHNlbGYuX2VuYWJsZWQgPSBUcnVlCiAgICAgICAgICAgIGxvZ2dlci5pbmZvKCJSZWRpcyBjb25uZWN0ZWQiKQogICAgICAgIGV4Y2VwdCBFeGNlcHRpb24gYXMgZToKICAgICAgICAgICAgbG9nZ2VyLndhcm5pbmcoZiJSZWRpcyB1bmF2YWlsYWJsZToge2V9IC0tIGZhbGxpbmcgYmFjayB0byBtZW1vcnkiKQogICAgICAgICAgICBzZWxmLl9lbmFibGVkID0gRmFsc2UKCiAgICBhc3luYyBkZWYgc2V0KHNlbGYsIGtleTogc3RyLCB2YWx1ZTogQW55LCB0dGw6IE9wdGlvbmFsW2ludF0gPSBOb25lKToKICAgICAgICBpZiBzZWxmLl9lbmFibGVkOgogICAgICAgICAgICBhd2FpdCBzZWxmLl9yZWRpcy5zZXQoc2VsZi5wcmVmaXggKyBrZXksIGpzb24uZHVtcHModmFsdWUpLCBleD10dGwpCgogICAgYXN5bmMgZGVmIGdldChzZWxmLCBrZXk6IHN0cikgLT4gT3B0aW9uYWxbQW55XToKICAgICAgICBpZiBub3Qgc2VsZi5fZW5hYmxlZDoKICAgICAgICAgICAgcmV0dXJuIE5vbmUKICAgICAgICBkYXRhID0gYXdhaXQgc2VsZi5fcmVkaXMuZ2V0KHNlbGYucHJlZml4ICsga2V5KQogICAgICAgIGlmIGRhdGE6CiAgICAgICAgICAgIHJldHVybiBqc29uLmxvYWRzKGRhdGEpCiAgICAgICAgcmV0dXJuIE5vbmUKCiAgICBhc3luYyBkZWYgZGVsZXRlKHNlbGYsIGtleTogc3RyKToKICAgICAgICBpZiBzZWxmLl9lbmFibGVkOgogICAgICAgICAgICBhd2FpdCBzZWxmLl9yZWRpcy5kZWxldGUoc2VsZi5wcmVmaXggKyBrZXkpCgogICAgYXN5bmMgZGVmIGtleXMoc2VsZiwgcGF0dGVybjogc3RyKSAtPiBMaXN0W3N0cl06CiAgICAgICAgaWYgbm90IHNlbGYuX2VuYWJsZWQ6CiAgICAgICAgICAgIHJldHVybiBbXQogICAgICAgIHJldHVybiBhd2FpdCBzZWxmLl9yZWRpcy5rZXlzKHNlbGYucHJlZml4ICsgcGF0dGVybikKCiMg4pSA4pSA4pSAIFByb3h5UG9vbE1hbmFnZXIgd2l0aCBjb3VudHJ5IGZpbHRlcmluZyDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIAKY2xhc3MgUHJveHlQb29sTWFuYWdlcjoKICAgIGRlZiBfX2luaXRfXyhzZWxmLCBtYXhfcXVldWU6IGludCA9IDUwLCBjYWNoZV9maWxlOiBQYXRoID0gUFJPWFlfQ0FDSEVfRklMRSwKICAgICAgICAgICAgICAgICBjYWNoZV9tYXg6IGludCA9IE1BWF9QUk9YWV9DQUNIRSwgY291bnRyaWVzOiBPcHRpb25hbFtMaXN0W3N0cl1dID0gTm9uZSk6CiAgICAgICAgc2VsZi5xdWV1ZTogYXN5bmNpby5RdWV1ZSA9IGFzeW5jaW8uUXVldWUobWF4c2l6ZT1tYXhfcXVldWUpCiAgICAgICAgc2VsZi5fbG9jayA9IGFzeW5jaW8uTG9jaygpCiAgICAgICAgc2VsZi5fcnVubmluZyA9IEZhbHNlCiAgICAgICAgc2VsZi5fY2FjaGVfZmlsZSA9IGNhY2hlX2ZpbGUKICAgICAgICBzZWxmLl9jYWNoZV9tYXggPSBjYWNoZV9tYXgKICAgICAgICBzZWxmLl9wcm94aWVzOiBMaXN0W1Byb3h5RW50cnldID0gW10KICAgICAgICBzZWxmLl91cmxfc2V0OiBTZXRbc3RyXSA9IHNldCgpCiAgICAgICAgc2VsZi5fdXJsX21hcDogRGljdFtzdHIsIFByb3h5RW50cnldID0ge30gICMgTygxKSBsb29rdXAgYnkgVVJMCiAgICAgICAgIyBCcm9rZXIgaW5pdGlhbGl6ZWQgbGF6aWx5IGluIHN0YXJ0KCkgd2hlbiB3ZSdyZSBpbiBhbiBhc3luYyBjb250ZXh0CiAgICAgICAgc2VsZi5fYnJva2VyID0gTm9uZQogICAgICAgIHNlbGYuY291bnRyaWVzID0gY291bnRyaWVzIG9yIERFRkFVTFRfQ09VTlRSSUVTCgogICAgYXN5bmMgZGVmIHN0YXJ0KHNlbGYpOgogICAgICAgIHNlbGYuX3J1bm5pbmcgPSBUcnVlCiAgICAgICAgc2VsZi5fbG9hZF9jYWNoZSgpCgogICAgICAgICMgSWYgbm8gY2FjaGVkIHByb3hpZXMsIHRyeSB0byBmZXRjaCBmcm9tIHB1YmxpYyBwcm94eSBsaXN0cwogICAgICAgIGlmIG5vdCBzZWxmLl9wcm94aWVzOgogICAgICAgICAgICBhd2FpdCBzZWxmLl9mZXRjaF9wdWJsaWNfcHJveGllcygpCgogICAgICAgIGZvciBwIGluIHNlbGYuX3Byb3hpZXM6CiAgICAgICAgICAgIGlmIHAuaGVhbHRoeSBhbmQgbm90IHAuaXNfYmFubmVkKCk6CiAgICAgICAgICAgICAgICB0cnk6CiAgICAgICAgICAgICAgICAgICAgc2VsZi5xdWV1ZS5wdXRfbm93YWl0KHAudXJsKQogICAgICAgICAgICAgICAgZXhjZXB0IGFzeW5jaW8uUXVldWVGdWxsOgogICAgICAgICAgICAgICAgICAgIGJyZWFrCgogICAgICAgICMgQWx3YXlzIHNjaGVkdWxlIGRpc2NvdmVyeSDigJQgdGhlIGxhenkgaW5pdCBpbnNpZGUgaGFuZGxlcyBpbXBvcnQgZmFpbHVyZXMKICAgICAgICBhc3luY2lvLmNyZWF0ZV90YXNrKHNlbGYuX2Rpc2NvdmVyeV9sb29wKCkpCgogICAgICAgIGxvZ2dlci5pbmZvKGYiUHJveHkgcG9vbDoge2xlbihzZWxmLl9wcm94aWVzKX0gcHJveGllcyBsb2FkZWQsIHtzZWxmLnF1ZXVlLnFzaXplKCl9IGluIHF1ZXVlIikKCiAgICBkZWYgX2xvYWRfY2FjaGUoc2VsZik6CiAgICAgICAgaWYgbm90IHNlbGYuX2NhY2hlX2ZpbGUuZXhpc3RzKCk6CiAgICAgICAgICAgIHJldHVybgogICAgICAgIHRyeToKICAgICAgICAgICAgd2l0aCBvcGVuKHNlbGYuX2NhY2hlX2ZpbGUsICdyJykgYXMgZjoKICAgICAgICAgICAgICAgIGRhdGEgPSBqc29uLmxvYWQoZikKICAgICAgICAgICAgZm9yIGl0ZW0gaW4gZGF0YS5nZXQoInByb3hpZXMiLCBbXSk6CiAgICAgICAgICAgICAgICBwID0gUHJveHlFbnRyeSgKICAgICAgICAgICAgICAgICAgICB1cmw9aXRlbVsidXJsIl0sCiAgICAgICAgICAgICAgICAgICAgaGVhbHRoeT1pdGVtLmdldCgiaGVhbHRoeSIsIFRydWUpLAogICAgICAgICAgICAgICAgICAgIGxhc3RfY2hlY2s9aXRlbS5nZXQoImxhc3RfY2hlY2siLCAwLjApLAogICAgICAgICAgICAgICAgICAgIGZhaWxfY291bnQ9aXRlbS5nZXQoImZhaWxfY291bnQiLCAwKSwKICAgICAgICAgICAgICAgICAgICBiYW5fdW50aWw9aXRlbS5nZXQoImJhbl91bnRpbCIsIDAuMCkKICAgICAgICAgICAgICAgICkKICAgICAgICAgICAgICAgIHNlbGYuX3Byb3hpZXMuYXBwZW5kKHApCiAgICAgICAgICAgICAgICBzZWxmLl91cmxfc2V0LmFkZChwLnVybCkKICAgICAgICAgICAgICAgIHNlbGYuX3VybF9tYXBbcC51cmxdID0gcAogICAgICAgICAgICBpZiBsZW4oc2VsZi5fcHJveGllcykgPiBzZWxmLl9jYWNoZV9tYXg6CiAgICAgICAgICAgICAgICBzZWxmLl9wcm94aWVzID0gc2VsZi5fcHJveGllc1stc2VsZi5fY2FjaGVfbWF4Ol0KICAgICAgICAgICAgICAgIHNlbGYuX3VybF9zZXQgPSB7cC51cmwgZm9yIHAgaW4gc2VsZi5fcHJveGllc30KICAgICAgICAgICAgICAgIHNlbGYuX3VybF9tYXAgPSB7cC51cmw6IHAgZm9yIHAgaW4gc2VsZi5fcHJveGllc30KICAgICAgICAgICAgbG9nZ2VyLmluZm8oZiJMb2FkZWQge2xlbihzZWxmLl9wcm94aWVzKX0gcHJveGllcyBmcm9tIGNhY2hlIikKICAgICAgICBleGNlcHQgRXhjZXB0aW9uIGFzIGU6CiAgICAgICAgICAgIGxvZ2dlci53YXJuaW5nKGYiRmFpbGVkIHRvIGxvYWQgcHJveHkgY2FjaGU6IHtlfSIpCgogICAgZGVmIF9zYXZlX2NhY2hlKHNlbGYpOgogICAgICAgIGRhdGEgPSB7CiAgICAgICAgICAgICJwcm94aWVzIjogWwogICAgICAgICAgICAgICAgewogICAgICAgICAgICAgICAgICAgICJ1cmwiOiBwLnVybCwKICAgICAgICAgICAgICAgICAgICAiaGVhbHRoeSI6IHAuaGVhbHRoeSwKICAgICAgICAgICAgICAgICAgICAibGFzdF9jaGVjayI6IHAubGFzdF9jaGVjaywKICAgICAgICAgICAgICAgICAgICAiZmFpbF9jb3VudCI6IHAuZmFpbF9jb3VudCwKICAgICAgICAgICAgICAgICAgICAiYmFuX3VudGlsIjogcC5iYW5fdW50aWwKICAgICAgICAgICAgICAgIH0gZm9yIHAgaW4gc2VsZi5fcHJveGllcwogICAgICAgICAgICBdCiAgICAgICAgfQogICAgICAgIHRyeToKICAgICAgICAgICAgd2l0aCBvcGVuKHNlbGYuX2NhY2hlX2ZpbGUsICd3JykgYXMgZjoKICAgICAgICAgICAgICAgIGpzb24uZHVtcChkYXRhLCBmLCBpbmRlbnQ9MikKICAgICAgICBleGNlcHQgRXhjZXB0aW9uIGFzIGU6CiAgICAgICAgICAgIGxvZ2dlci53YXJuaW5nKGYiRmFpbGVkIHRvIHNhdmUgcHJveHkgY2FjaGU6IHtlfSIpCgogICAgZGVmIF9wcm94eWJyb2tlcjJfcHJveHlfdXJsKHNlbGYsIHByb3h5KSAtPiBPcHRpb25hbFtzdHJdOgogICAgICAgICIiIlNhZmVseSBleHRyYWN0IFVSTCBmcm9tIGEgUHJveHlCcm9rZXIyIFByb3h5IG9iamVjdC4KCiAgICAgICAgUHJveHlCcm9rZXIyJ3MgUHJveHkgY2xhc3MgbWF5IHVzZSBkaWZmZXJlbnQgYXR0cmlidXRlIG5hbWVzCiAgICAgICAgZGVwZW5kaW5nIG9uIHRoZSB2ZXJzaW9uLiBUaGlzIGhhbmRsZXMgYm90aCBvbGQgYW5kIG5ldyBBUElzLgogICAgICAgICIiIgogICAgICAgIHRyeToKICAgICAgICAgICAgaG9zdCA9IGdldGF0dHIocHJveHksICdob3N0JywgTm9uZSkKICAgICAgICAgICAgcG9ydCA9IGdldGF0dHIocHJveHksICdwb3J0JywgTm9uZSkKICAgICAgICAgICAgaWYgbm90IGhvc3Qgb3Igbm90IHBvcnQ6CiAgICAgICAgICAgICAgICByZXR1cm4gTm9uZQoKICAgICAgICAgICAgIyBUcnkgbXVsdGlwbGUgYXR0cmlidXRlIG5hbWVzIGZvciBwcm90b2NvbCAodmFyaWVzIGJ5IHZlcnNpb24pCiAgICAgICAgICAgIHByb3RvID0gZ2V0YXR0cihwcm94eSwgJ3Byb3RvY29sJywgTm9uZSkgb3IgXAogICAgICAgICAgICAgICAgICAgIGdldGF0dHIocHJveHksICdwcm90bycsIE5vbmUpIG9yIFwKICAgICAgICAgICAgICAgICAgICBnZXRhdHRyKHByb3h5LCAndHlwZScsIE5vbmUpIG9yICdIVFRQJwoKICAgICAgICAgICAgcHJvdG8gPSBwcm90by51cHBlcigpIGlmIHByb3RvIGVsc2UgJ0hUVFAnCgogICAgICAgICAgICAjIE1hcCBjb21tb24gcHJvdG9jb2wgbmFtZXMgdG8gVVJMIHNjaGVtZXMKICAgICAgICAgICAgc2NoZW1lX21hcCA9IHsKICAgICAgICAgICAgICAgICdIVFRQJzogJ2h0dHAnLCAnSFRUUFMnOiAnaHR0cHMnLAogICAgICAgICAgICAgICAgJ1NPQ0tTNCc6ICdzb2NrczQnLCAnU09DS1M1JzogJ3NvY2tzNScsCiAgICAgICAgICAgICAgICAnU09DS1MnOiAnc29ja3M1JywgJ0NPTk5FQ1QnOiAnaHR0cCcsCiAgICAgICAgICAgIH0KICAgICAgICAgICAgc2NoZW1lID0gc2NoZW1lX21hcC5nZXQocHJvdG8sICdodHRwJykKCiAgICAgICAgICAgIHJldHVybiBmIntzY2hlbWV9Oi8ve2hvc3R9Ontwb3J0fSIKICAgICAgICBleGNlcHQgRXhjZXB0aW9uIGFzIGU6CiAgICAgICAgICAgIGxvZ2dlci5kZWJ1ZyhmIkZhaWxlZCB0byBleHRyYWN0IHByb3h5IFVSTCBmcm9tIHt0eXBlKHByb3h5KS5fX25hbWVfX306IHtlfSIpCiAgICAgICAgICAgIHJldHVybiBOb25lCgogICAgYXN5bmMgZGVmIF9mZXRjaF9wdWJsaWNfcHJveGllcyhzZWxmKToKICAgICAgICAiIiJGZXRjaCBwcm94aWVzIGZyb20gcHVibGljIEdpdEh1YiByYXcgcHJveHkgbGlzdHMgd2hlbiBjYWNoZSBpcyBlbXB0eS4iIiIKICAgICAgICBwcm94eV9saXN0X3VybHMgPSBbCiAgICAgICAgICAgICJodHRwczovL3Jhdy5naXRodWJ1c2VyY29udGVudC5jb20vVGhlU3BlZWRYL1NPQ0tTLUxpc3QvbWFzdGVyL2h0dHAudHh0IiwKICAgICAgICAgICAgImh0dHBzOi8vcmF3LmdpdGh1YnVzZXJjb250ZW50LmNvbS9TaGlmdHlUUi9Qcm94eS1MaXN0L21hc3Rlci9odHRwcy50eHQiLAogICAgICAgICAgICAiaHR0cHM6Ly9yYXcuZ2l0aHVidXNlcmNvbnRlbnQuY29tL21tcHgxMi9wcm94eS1saXN0L21hc3Rlci9odHRwcy50eHQiLAogICAgICAgICAgICAiaHR0cHM6Ly9yYXcuZ2l0aHVidXNlcmNvbnRlbnQuY29tL21tcHgxMi9wcm94eS1saXN0L21hc3Rlci9odHRwLnR4dCIsCiAgICAgICAgICAgICJodHRwczovL3Jhdy5naXRodWJ1c2VyY29udGVudC5jb20vbW9ub3NhbnMvcHJveHktbGlzdC9tYWluL3Byb3hpZXMvaHR0cC50eHQiLAogICAgICAgICAgICAiaHR0cHM6Ly9yYXcuZ2l0aHVidXNlcmNvbnRlbnQuY29tL21vbm9zYW5zL3Byb3h5LWxpc3QvbWFpbi9wcm94aWVzL3NvY2tzNS50eHQiLAogICAgICAgICAgICAiaHR0cHM6Ly9hcGkucHJveHlzY3JhcGUuY29tL3Y0L2ZyZWUtcHJveHktbGlzdC9nZXQ/cmVxdWVzdD1kaXNwbGF5X3Byb3hpZXMmcHJveHlfZm9ybWF0PXByb3RvY29saXBwb3J0JmZvcm1hdD10ZXh0JmxpbWl0PTUwIiwKICAgICAgICBdCgogICAgICAgIGxvZ2dlci5pbmZvKCJGZXRjaGluZyBwcm94aWVzIGZyb20gcHVibGljIHByb3h5IGxpc3RzLi4uIikKICAgICAgICBhc3luYyB3aXRoIGh0dHB4LkFzeW5jQ2xpZW50KHRpbWVvdXQ9MTAsIGZvbGxvd19yZWRpcmVjdHM9VHJ1ZSkgYXMgY2xpZW50OgogICAgICAgICAgICBmb3IgdXJsIGluIHByb3h5X2xpc3RfdXJsczoKICAgICAgICAgICAgICAgIGlmIGxlbihzZWxmLl9wcm94aWVzKSA+PSBzZWxmLl9jYWNoZV9tYXg6CiAgICAgICAgICAgICAgICAgICAgYnJlYWsKICAgICAgICAgICAgICAgIHRyeToKICAgICAgICAgICAgICAgICAgICByZXNwID0gYXdhaXQgY2xpZW50LmdldCh1cmwpCiAgICAgICAgICAgICAgICAgICAgaWYgcmVzcC5zdGF0dXNfY29kZSA9PSAyMDA6CiAgICAgICAgICAgICAgICAgICAgICAgIGxpbmVzID0gcmVzcC50ZXh0LnN0cmlwKCkuc3BsaXQoJ1xuJykKICAgICAgICAgICAgICAgICAgICAgICAgY291bnQgPSAwCiAgICAgICAgICAgICAgICAgICAgICAgIG1heF9wZXJfc291cmNlID0gbWluKDIwLCBzZWxmLl9jYWNoZV9tYXggLSBsZW4oc2VsZi5fcHJveGllcykpCiAgICAgICAgICAgICAgICAgICAgICAgIGZvciBsaW5lIGluIGxpbmVzWzptYXhfcGVyX3NvdXJjZV06CiAgICAgICAgICAgICAgICAgICAgICAgICAgICBsaW5lID0gbGluZS5zdHJpcCgpCiAgICAgICAgICAgICAgICAgICAgICAgICAgICBpZiBub3QgbGluZSBvciAnOicgbm90IGluIGxpbmU6CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgY29udGludWUKICAgICAgICAgICAgICAgICAgICAgICAgICAgIGlmICdzb2NrczUnIGluIHVybC5sb3dlcigpOgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIHByb3h5X3VybCA9IGYic29ja3M1Oi8ve2xpbmV9IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgZWxpZiAnaHR0cHMnIGluIHVybC5sb3dlcigpOgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIHByb3h5X3VybCA9IGYiaHR0cHM6Ly97bGluZX0iCiAgICAgICAgICAgICAgICAgICAgICAgICAgICBlbHNlOgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIHByb3h5X3VybCA9IGYiaHR0cDovL3tsaW5lfSIKICAgICAgICAgICAgICAgICAgICAgICAgICAgIGlmIHByb3h5X3VybCBub3QgaW4gc2VsZi5fdXJsX3NldDoKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBuZXdfZW50cnkgPSBQcm94eUVudHJ5KHVybD1wcm94eV91cmwpCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgc2VsZi5fcHJveGllcy5hcHBlbmQobmV3X2VudHJ5KQogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIHNlbGYuX3VybF9zZXQuYWRkKHByb3h5X3VybCkKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBzZWxmLl91cmxfbWFwW3Byb3h5X3VybF0gPSBuZXdfZW50cnkKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBjb3VudCArPSAxCiAgICAgICAgICAgICAgICAgICAgICAgIGlmIGNvdW50ID4gMDoKICAgICAgICAgICAgICAgICAgICAgICAgICAgIHNvdXJjZV9uYW1lID0gdXJsLnNwbGl0KCcvJylbLTFdCiAgICAgICAgICAgICAgICAgICAgICAgICAgICBsb2dnZXIuaW5mbyhmIiAgRmV0Y2hlZCB7Y291bnR9IHByb3hpZXMgZnJvbSB7c291cmNlX25hbWV9IikKICAgICAgICAgICAgICAgIGV4Y2VwdCBFeGNlcHRpb24gYXMgZToKICAgICAgICAgICAgICAgICAgICBsb2dnZXIuZGVidWcoZiIgIEZhaWxlZCB0byBmZXRjaCBmcm9tIHt1cmwuc3BsaXQoJy8nKVstMV19OiB7ZX0iKQogICAgICAgICAgICAgICAgICAgIGNvbnRpbnVlCgogICAgICAgIGlmIHNlbGYuX3Byb3hpZXM6CiAgICAgICAgICAgIGlmIGxlbihzZWxmLl9wcm94aWVzKSA+IHNlbGYuX2NhY2hlX21heDoKICAgICAgICAgICAgICAgIHNlbGYuX3Byb3hpZXMgPSBzZWxmLl9wcm94aWVzWy1zZWxmLl9jYWNoZV9tYXg6XQogICAgICAgICAgICAgICAgc2VsZi5fdXJsX3NldCA9IHtwLnVybCBmb3IgcCBpbiBzZWxmLl9wcm94aWVzfQogICAgICAgICAgICBzZWxmLl9zYXZlX2NhY2hlKCkKICAgICAgICAgICAgbG9nZ2VyLmluZm8oZiJUb3RhbCBwcm94aWVzIGxvYWRlZCBmcm9tIHB1YmxpYyBsaXN0czoge2xlbihzZWxmLl9wcm94aWVzKX0iKQogICAgICAgIGVsc2U6CiAgICAgICAgICAgIGxvZ2dlci53YXJuaW5nKCJObyBwcm94aWVzIGNvdWxkIGJlIGZldGNoZWQgZnJvbSBwdWJsaWMgbGlzdHMiKQoKICAgIGFzeW5jIGRlZiBfZGlzY292ZXJ5X2xvb3Aoc2VsZik6CiAgICAgICAgIyBMYXp5IGluaXQgYnJva2VyIG5vdyB0aGF0IHdlJ3JlIGluIGFzeW5jIGNvbnRleHQKICAgICAgICBpZiBzZWxmLl9icm9rZXIgaXMgTm9uZToKICAgICAgICAgICAgdHJ5OgogICAgICAgICAgICAgICAgZnJvbSBwcm94eWJyb2tlcjIgaW1wb3J0IEJyb2tlciBhcyBfQnJva2VyCiAgICAgICAgICAgICAgICBzZWxmLl9icm9rZXIgPSBfQnJva2VyKCkKICAgICAgICAgICAgICAgIGxvZ2dlci5pbmZvKCJQcm94eUJyb2tlcjIgaW5pdGlhbGl6ZWQgZm9yIG9uZ29pbmcgZGlzY292ZXJ5IikKICAgICAgICAgICAgZXhjZXB0IChJbXBvcnRFcnJvciwgUnVudGltZUVycm9yKSBhcyBlOgogICAgICAgICAgICAgICAgbG9nZ2VyLndhcm5pbmcoZiJQcm94eUJyb2tlcjIgdW5hdmFpbGFibGU6IHtlfSDigJQgbm8gb25nb2luZyBkaXNjb3ZlcnkiKQogICAgICAgICAgICAgICAgcmV0dXJuCiAgICAgICAgd2hpbGUgc2VsZi5fcnVubmluZzoKICAgICAgICAgICAgdHJ5OgogICAgICAgICAgICAgICAgIyBmaW5kKCkgaXMgYSBjb3JvdXRpbmUgdGhhdCBzdGFydHMgZGlzY292ZXJ5OyBwcm94aWVzIGFwcGVhciBpbiBfYnJva2VyLl9wcm94aWVzIHF1ZXVlCiAgICAgICAgICAgICAgICBmaW5kX3Rhc2sgPSBhc3luY2lvLmNyZWF0ZV90YXNrKHNlbGYuX2Jyb2tlci5maW5kKAogICAgICAgICAgICAgICAgICAgIHR5cGVzPVsnSFRUUCcsICdIVFRQUycsICdTT0NLUzQnLCAnU09DS1M1J10sCiAgICAgICAgICAgICAgICAgICAgY291bnRyaWVzPXNlbGYuY291bnRyaWVzLAogICAgICAgICAgICAgICAgICAgIGxpbWl0PTAKICAgICAgICAgICAgICAgICkpCiAgICAgICAgICAgICAgICAjIFJlYWQgZGlzY292ZXJlZCBwcm94aWVzIGZyb20gdGhlIGJyb2tlcidzIGludGVybmFsIHF1ZXVlCiAgICAgICAgICAgICAgICB3aGlsZSBzZWxmLl9ydW5uaW5nOgogICAgICAgICAgICAgICAgICAgIHRyeToKICAgICAgICAgICAgICAgICAgICAgICAgcHJveHkgPSBhd2FpdCBhc3luY2lvLndhaXRfZm9yKAogICAgICAgICAgICAgICAgICAgICAgICAgICAgc2VsZi5fYnJva2VyLl9wcm94aWVzLmdldCgpLCB0aW1lb3V0PTUuMAogICAgICAgICAgICAgICAgICAgICAgICApCiAgICAgICAgICAgICAgICAgICAgZXhjZXB0IGFzeW5jaW8uVGltZW91dEVycm9yOgogICAgICAgICAgICAgICAgICAgICAgICAjIENoZWNrIGlmIGZpbmQgdGFzayBpcyBzdGlsbCBydW5uaW5nCiAgICAgICAgICAgICAgICAgICAgICAgIGlmIGZpbmRfdGFzay5kb25lKCk6CiAgICAgICAgICAgICAgICAgICAgICAgICAgICBicmVhawogICAgICAgICAgICAgICAgICAgICAgICBjb250aW51ZQogICAgICAgICAgICAgICAgICAgIHVybCA9IHNlbGYuX3Byb3h5YnJva2VyMl9wcm94eV91cmwocHJveHkpCiAgICAgICAgICAgICAgICAgICAgaWYgdXJsIGFuZCB1cmwgbm90IGluIHNlbGYuX3VybF9zZXQ6CiAgICAgICAgICAgICAgICAgICAgICAgIHAgPSBQcm94eUVudHJ5KHVybD11cmwpCiAgICAgICAgICAgICAgICAgICAgICAgIHNlbGYuX3Byb3hpZXMuYXBwZW5kKHApCiAgICAgICAgICAgICAgICAgICAgICAgIHNlbGYuX3VybF9zZXQuYWRkKHVybCkKICAgICAgICAgICAgICAgICAgICAgICAgc2VsZi5fdXJsX21hcFt1cmxdID0gcAogICAgICAgICAgICAgICAgICAgICAgICBhd2FpdCBzZWxmLnF1ZXVlLnB1dCh1cmwpCiAgICAgICAgICAgICAgICAgICAgICAgIGxvZ2dlci5kZWJ1ZyhmIkRpc2NvdmVyZWQgcHJveHk6IHt1cmx9IikKICAgICAgICAgICAgICAgICAgICAgICAgaWYgbGVuKHNlbGYuX3Byb3hpZXMpID4gc2VsZi5fY2FjaGVfbWF4OgogICAgICAgICAgICAgICAgICAgICAgICAgICAgc2VsZi5fcHJveGllcyA9IHNlbGYuX3Byb3hpZXNbLXNlbGYuX2NhY2hlX21heDpdCiAgICAgICAgICAgICAgICAgICAgICAgICAgICBzZWxmLl91cmxfc2V0ID0ge3AudXJsIGZvciBwIGluIHNlbGYuX3Byb3hpZXN9CiAgICAgICAgICAgICAgICAgICAgICAgICAgICBzZWxmLl91cmxfbWFwID0ge3AudXJsOiBwIGZvciBwIGluIHNlbGYuX3Byb3hpZXN9CiAgICAgICAgICAgICAgICAgICAgICAgIHNlbGYuX3NhdmVfY2FjaGUoKQogICAgICAgICAgICAgICAgICAgIGVsaWYgdXJsIGlzIE5vbmU6CiAgICAgICAgICAgICAgICAgICAgICAgIGxvZ2dlci5kZWJ1ZyhmIlNraXBwZWQgcHJveHkgKGNvdWxkIG5vdCBwYXJzZSk6IHt0eXBlKHByb3h5KS5fX25hbWVfX30iKQogICAgICAgICAgICBleGNlcHQgYXN5bmNpby5DYW5jZWxsZWRFcnJvcjoKICAgICAgICAgICAgICAgIGJyZWFrCiAgICAgICAgICAgIGV4Y2VwdCBBdHRyaWJ1dGVFcnJvciBhcyBlOgogICAgICAgICAgICAgICAgIyBQcm94eUJyb2tlcjIgQVBJIGluY29tcGF0aWJpbGl0eSAtIG9iamVjdCBtaXNzaW5nIGV4cGVjdGVkIGF0dHJpYnV0ZXMKICAgICAgICAgICAgICAgIGxvZ2dlci53YXJuaW5nKGYiUHJveHlCcm9rZXIyIEFQSSBpbmNvbXBhdGliaWxpdHk6IHtlfSIpCiAgICAgICAgICAgICAgICBsb2dnZXIuaW5mbygiUHJveHlCcm9rZXIyIGRpc2NvdmVyeSBkaXNhYmxlZC4gUHVibGljIHByb3h5IGxpc3RzIGFyZSBhY3RpdmUuIikKICAgICAgICAgICAgICAgICMgRG9uJ3QgcmV0cnkgLSB0aGUgQVBJIGlzIGluY29tcGF0aWJsZSwganVzdCBleGl0IHRoZSBsb29wCiAgICAgICAgICAgICAgICBicmVhawogICAgICAgICAgICBleGNlcHQgRXhjZXB0aW9uIGFzIGU6CiAgICAgICAgICAgICAgICBsb2dnZXIuZXJyb3IoZiJQcm94eUJyb2tlcjIgZGlzY292ZXJ5IGVycm9yOiB7ZX0iKQogICAgICAgICAgICAgICAgYXdhaXQgYXN5bmNpby5zbGVlcCgzMCkKCiAgICBhc3luYyBkZWYgZ2V0KHNlbGYpIC0+IE9wdGlvbmFsW3N0cl06CiAgICAgICAgdHJ5OgogICAgICAgICAgICB1cmwgPSBhd2FpdCBhc3luY2lvLndhaXRfZm9yKHNlbGYucXVldWUuZ2V0KCksIHRpbWVvdXQ9NS4wKQogICAgICAgICAgICByZXR1cm4gdXJsCiAgICAgICAgZXhjZXB0IGFzeW5jaW8uVGltZW91dEVycm9yOgogICAgICAgICAgICByZXR1cm4gTm9uZQoKICAgIGRlZiBnZXRfYWxsX3VybHMoc2VsZikgLT4gTGlzdFtzdHJdOgogICAgICAgIHJldHVybiBbcC51cmwgZm9yIHAgaW4gc2VsZi5fcHJveGllcyBpZiBwLmhlYWx0aHkgYW5kIG5vdCBwLmlzX2Jhbm5lZCgpXQoKICAgIGRlZiBnZXRfZW50cnkoc2VsZiwgdXJsOiBzdHIpIC0+IE9wdGlvbmFsW1Byb3h5RW50cnldOgogICAgICAgICIiIkdldCBQcm94eUVudHJ5IGJ5IFVSTCDigJQgTygxKSBkaWN0IGxvb2t1cC4iIiIKICAgICAgICByZXR1cm4gc2VsZi5fdXJsX21hcC5nZXQodXJsKQoKICAgIGRlZiBzdG9wKHNlbGYpOgogICAgICAgIHNlbGYuX3J1bm5pbmcgPSBGYWxzZQogICAgICAgIHNlbGYuX3NhdmVfY2FjaGUoKQoKIyDilIDilIDilIAgUGx1Z2luIFN5c3RlbSAodjQuMykg4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSACmNsYXNzIFBsdWdpbk1hbmFnZXI6CiAgICAiIiJNYW5hZ2VzIHJlcXVlc3QvcmVzcG9uc2UgbGlmZWN5Y2xlIHBsdWdpbnMuIiIiCiAgICBkZWYgX19pbml0X18oc2VsZiwgcGx1Z2luX2xvYWRlcj1Ob25lKToKICAgICAgICBzZWxmLl9ob29rczogRGljdFtzdHIsIExpc3RbQ2FsbGFibGVdXSA9IHsKICAgICAgICAgICAgInN0YXJ0IjogW10sICJyZXF1ZXN0IjogW10sICJyZXNwb25zZSI6IFtdLAogICAgICAgICAgICAiZXJyb3IiOiBbXSwgImNvbXBsZXRlIjogW10KICAgICAgICB9CiAgICAgICAgc2VsZi5fcGx1Z2luX2xvYWRlciA9IHBsdWdpbl9sb2FkZXIKCiAgICBkZWYgcmVnaXN0ZXIoc2VsZiwgaG9va190eXBlOiBzdHIsIGZ1bmM6IENhbGxhYmxlKToKICAgICAgICBpZiBob29rX3R5cGUgbm90IGluIHNlbGYuX2hvb2tzOgogICAgICAgICAgICByYWlzZSBWYWx1ZUVycm9yKGYiVW5rbm93biBob29rIHR5cGU6IHtob29rX3R5cGV9IikKICAgICAgICBzZWxmLl9ob29rc1tob29rX3R5cGVdLmFwcGVuZChmdW5jKQoKICAgIGRlZiBfZ2V0X2FsbF9ob29rcyhzZWxmLCBob29rX3R5cGU6IHN0cikgLT4gTGlzdFtDYWxsYWJsZV06CiAgICAgICAgIiIiTWVyZ2Ugc3RhdGljIGhvb2tzIHdpdGggZHluYW1pYyBob29rcyBmcm9tIFBsdWdpbkxvYWRlci4iIiIKICAgICAgICBob29rcyA9IGxpc3Qoc2VsZi5faG9va3MuZ2V0KGhvb2tfdHlwZSwgW10pKQogICAgICAgIGlmIHNlbGYuX3BsdWdpbl9sb2FkZXI6CiAgICAgICAgICAgIGhvb2tzLmV4dGVuZChzZWxmLl9wbHVnaW5fbG9hZGVyLmdldF9ob29rcyhob29rX3R5cGUpKQogICAgICAgIHJldHVybiBob29rcwoKICAgIGFzeW5jIGRlZiBydW5faG9va3Moc2VsZiwgaG9va190eXBlOiBzdHIsICphcmdzLCAqKmt3YXJncyk6CiAgICAgICAgZm9yIGhvb2sgaW4gc2VsZi5fZ2V0X2FsbF9ob29rcyhob29rX3R5cGUpOgogICAgICAgICAgICB0cnk6CiAgICAgICAgICAgICAgICBpZiBpbnNwZWN0LmlzY29yb3V0aW5lZnVuY3Rpb24oaG9vayk6CiAgICAgICAgICAgICAgICAgICAgYXdhaXQgaG9vaygqYXJncywgKiprd2FyZ3MpCiAgICAgICAgICAgICAgICBlbHNlOgogICAgICAgICAgICAgICAgICAgIGhvb2soKmFyZ3MsICoqa3dhcmdzKQogICAgICAgICAgICBleGNlcHQgRXhjZXB0aW9uIGFzIGU6CiAgICAgICAgICAgICAgICBsb2dnZXIuZXJyb3IoZiJQbHVnaW4gaG9vayB7aG9va190eXBlfSBmYWlsZWQ6IHtlfSIpCgoKIyDilIDilIDilIAgQS9CIFRlc3RpbmcgRW5naW5lICh2NC4zKSDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIAKY2xhc3MgQUJUZXN0TWFuYWdlcjoKICAgICIiIk1hbmFnZXMgQS9CIHRlc3RzIGZvciBwcm94eSBzdHJhdGVnaWVzIHBlciBkb21haW4uIiIiCiAgICBTVFJBVEVHSUVTID0gWyJiZXN0X3Njb3JlIiwgInJhbmRvbSIsICJyb3VuZF9yb2JpbiJdCgogICAgZGVmIF9faW5pdF9fKHNlbGYpOgogICAgICAgIHNlbGYuX2RvbWFpbl9zdHJhdGVneTogRGljdFtzdHIsIHN0cl0gPSB7fQogICAgICAgIHNlbGYuX2RvbWFpbl9zdGF0czogRGljdFtzdHIsIERpY3Rbc3RyLCBEaWN0W3N0ciwgaW50XV1dID0gZGVmYXVsdGRpY3QoCiAgICAgICAgICAgIGxhbWJkYToge3M6IHsic3VjY2VzcyI6IDAsICJ0b3RhbCI6IDB9IGZvciBzIGluIHNlbGYuU1RSQVRFR0lFU30KICAgICAgICApCiAgICAgICAgc2VsZi5fcm91bmRfcm9iaW5faW5kZXg6IERpY3Rbc3RyLCBpbnRdID0gZGVmYXVsdGRpY3QoaW50KQogICAgICAgIHNlbGYuX2xvY2sgPSBhc3luY2lvLkxvY2soKQogICAgICAgICMgUmFuZG9tbHkgYXNzaWduIDIwJSUgb2YgZG9tYWlucyB0byBhbHRlcm5hdGl2ZSBzdHJhdGVnaWVzIGF0IHN0YXJ0CiAgICAgICAgIyBzbyB3ZSBoYXZlIGNvbXBhcmlzb24gZGF0YSBmb3IgdGhlIHN3aXRjaGluZyBsb2dpYwogICAgICAgIHNlbGYuX2RlZmF1bHRfYWx0X3JhdGUgPSAwLjIKCiAgICBkZWYgZ2V0X3N0cmF0ZWd5KHNlbGYsIGRvbWFpbjogc3RyKSAtPiBzdHI6CiAgICAgICAgaWYgZG9tYWluIG5vdCBpbiBzZWxmLl9kb21haW5fc3RyYXRlZ3k6CiAgICAgICAgICAgICMgUmFuZG9tbHkgYXNzaWduIGFsdGVybmF0aXZlIHN0cmF0ZWd5IGZvciBuZXcgZG9tYWlucwogICAgICAgICAgICAjIHNvIEEvQiBjb21wYXJpc29uIGRhdGEgaXMgZ2VuZXJhdGVkCiAgICAgICAgICAgIGlmIHJhbmRvbS5yYW5kb20oKSA8IHNlbGYuX2RlZmF1bHRfYWx0X3JhdGU6CiAgICAgICAgICAgICAgICBhbHQgPSByYW5kb20uY2hvaWNlKFtzIGZvciBzIGluIHNlbGYuU1RSQVRFR0lFUyBpZiBzICE9ICJiZXN0X3Njb3JlIl0pCiAgICAgICAgICAgICAgICBzZWxmLl9kb21haW5fc3RyYXRlZ3lbZG9tYWluXSA9IGFsdAogICAgICAgICAgICBlbHNlOgogICAgICAgICAgICAgICAgc2VsZi5fZG9tYWluX3N0cmF0ZWd5W2RvbWFpbl0gPSAiYmVzdF9zY29yZSIKICAgICAgICByZXR1cm4gc2VsZi5fZG9tYWluX3N0cmF0ZWd5W2RvbWFpbl0KCiAgICBhc3luYyBkZWYgcmVjb3JkX3Jlc3VsdChzZWxmLCBkb21haW46IHN0ciwgc3RyYXRlZ3k6IHN0ciwgc3VjY2VzczogYm9vbCk6CiAgICAgICAgYXN5bmMgd2l0aCBzZWxmLl9sb2NrOgogICAgICAgICAgICBzdGF0cyA9IHNlbGYuX2RvbWFpbl9zdGF0c1tkb21haW5dW3N0cmF0ZWd5XQogICAgICAgICAgICBzdGF0c1sidG90YWwiXSArPSAxCiAgICAgICAgICAgIGlmIHN1Y2Nlc3M6CiAgICAgICAgICAgICAgICBzdGF0c1sic3VjY2VzcyJdICs9IDEKICAgICAgICAgICAgdG90YWwgPSBzdW0oc1sidG90YWwiXSBmb3IgcyBpbiBzZWxmLl9kb21haW5fc3RhdHNbZG9tYWluXS52YWx1ZXMoKSkKICAgICAgICAgICAgaWYgdG90YWwgPj0gMTAwOgogICAgICAgICAgICAgICAgYmVzdCA9IHNlbGYuX2V2YWx1YXRlX2Jlc3QoZG9tYWluKQogICAgICAgICAgICAgICAgaWYgYmVzdCBhbmQgYmVzdCAhPSBzZWxmLl9kb21haW5fc3RyYXRlZ3kuZ2V0KGRvbWFpbik6CiAgICAgICAgICAgICAgICAgICAgbG9nZ2VyLmluZm8oZiJBQjogU3dpdGNoaW5nIHtkb21haW59OiB7c2VsZi5fZG9tYWluX3N0cmF0ZWd5LmdldChkb21haW4pfSAtPiB7YmVzdH0iKQogICAgICAgICAgICAgICAgICAgIHNlbGYuX2RvbWFpbl9zdHJhdGVneVtkb21haW5dID0gYmVzdAoKICAgIGRlZiBfZXZhbHVhdGVfYmVzdChzZWxmLCBkb21haW46IHN0cikgLT4gT3B0aW9uYWxbc3RyXToKICAgICAgICBzdGF0cyA9IHNlbGYuX2RvbWFpbl9zdGF0c1tkb21haW5dCiAgICAgICAgYmVzdCwgYmVzdF9yYXRlID0gTm9uZSwgMC4wCiAgICAgICAgZm9yIHN0cmF0ZWd5LCBkYXRhIGluIHN0YXRzLml0ZW1zKCk6CiAgICAgICAgICAgIGlmIGRhdGFbInRvdGFsIl0gPiAwOgogICAgICAgICAgICAgICAgcmF0ZSA9IGRhdGFbInN1Y2Nlc3MiXSAvIGRhdGFbInRvdGFsIl0KICAgICAgICAgICAgICAgIGlmIHJhdGUgPiBiZXN0X3JhdGU6CiAgICAgICAgICAgICAgICAgICAgYmVzdF9yYXRlLCBiZXN0ID0gcmF0ZSwgc3RyYXRlZ3kKICAgICAgICByZXR1cm4gYmVzdAoKICAgIGRlZiBzZWxlY3RfcHJveHkoc2VsZiwgZG9tYWluOiBzdHIsIHByb3h5X3VybHM6IExpc3Rbc3RyXSwgc2NvcmVyOiAnUXVhbGl0eVNjb3JlcicpIC0+IE9wdGlvbmFsW3N0cl06CiAgICAgICAgaWYgbm90IHByb3h5X3VybHM6CiAgICAgICAgICAgIHJldHVybiBOb25lCiAgICAgICAgc3RyYXRlZ3kgPSBzZWxmLmdldF9zdHJhdGVneShkb21haW4pCiAgICAgICAgaWYgc3RyYXRlZ3kgPT0gImJlc3Rfc2NvcmUiOgogICAgICAgICAgICByZXR1cm4gc2NvcmVyLmdldF9iZXN0X3Byb3h5KHByb3h5X3VybHMpCiAgICAgICAgZWxpZiBzdHJhdGVneSA9PSAicmFuZG9tIjoKICAgICAgICAgICAgcmV0dXJuIHJhbmRvbS5jaG9pY2UocHJveHlfdXJscykKICAgICAgICBlbGlmIHN0cmF0ZWd5ID09ICJyb3VuZF9yb2JpbiI6CiAgICAgICAgICAgIGlkeCA9IHNlbGYuX3JvdW5kX3JvYmluX2luZGV4W2RvbWFpbl0gJSBsZW4ocHJveHlfdXJscykKICAgICAgICAgICAgc2VsZi5fcm91bmRfcm9iaW5faW5kZXhbZG9tYWluXSArPSAxCiAgICAgICAgICAgIHJldHVybiBwcm94eV91cmxzW2lkeF0KICAgICAgICByZXR1cm4gTm9uZQoKICAgIGRlZiBnZXRfc3RhdHMoc2VsZiwgZG9tYWluOiBPcHRpb25hbFtzdHJdID0gTm9uZSkgLT4gRGljdDoKICAgICAgICBpZiBkb21haW46CiAgICAgICAgICAgIGQgPSBzZWxmLl9kb21haW5fc3RhdHMuZ2V0KGRvbWFpbiwge30pCiAgICAgICAgICAgIHJldHVybiB7azogZGljdCh2KSBmb3IgaywgdiBpbiBkLml0ZW1zKCl9IGlmIGQgZWxzZSB7fQogICAgICAgICMgUmV0dXJuIGFsbCBkb21haW5zJyBzdGF0cyBhcyBwbGFpbiBkaWN0cyAoSlNPTi1zYWZlKQogICAgICAgIHJldHVybiB7ZG9tOiB7azogZGljdCh2KSBmb3IgaywgdiBpbiBzdHJhdHMuaXRlbXMoKX0KICAgICAgICAgICAgICAgIGZvciBkb20sIHN0cmF0cyBpbiBzZWxmLl9kb21haW5fc3RhdHMuaXRlbXMoKX0KCgojIOKUgOKUgOKUgCBNTCBQcmVkaWN0b3IgKHY0LjMpIOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgApjbGFzcyBNTFByZWRpY3RvcjoKICAgICIiIk9ubGluZSBNTCBwcmVkaWN0b3IgZm9yIHByb3h5IHN1Y2Nlc3MgdXNpbmcgbG9naXN0aWMgcmVncmVzc2lvbi4KCiAgICBPbiBzdGFydHVwLCB2YWxpZGF0ZXMgYW55IHBlcnNpc3RlZCBtb2RlbCdzIENWIHNjb3JlIGFnYWluc3QKICAgIE1MX1NUQUxFTkVTU19USFJFU0hPTEQuIElmIHRoZSBzY29yZSBpcyBiZWxvdyB0aHJlc2hvbGQsIHRoZSBtb2RlbAogICAgaXMgZGlzY2FyZGVkIGFuZCB3aWxsIGJlIHJldHJhaW5lZCBmcm9tIHNjcmF0Y2ggYWZ0ZXIgZW5vdWdoIGxpdmUKICAgIHNhbXBsZXMgYXJlIGNvbGxlY3RlZC4KICAgICIiIgogICAgZGVmIF9faW5pdF9fKHNlbGYsIG1heF9zYW1wbGVzOiBpbnQgPSAxMDAwKToKICAgICAgICBzZWxmLm1heF9zYW1wbGVzID0gbWF4X3NhbXBsZXMKICAgICAgICBzZWxmLl9mZWF0dXJlczogTGlzdFtMaXN0W2Zsb2F0XV0gPSBbXQogICAgICAgIHNlbGYuX2xhYmVsczogTGlzdFtpbnRdID0gW10KICAgICAgICBzZWxmLl9tb2RlbCA9IE5vbmUKICAgICAgICBzZWxmLl9zY2FsZXIgPSBOb25lCiAgICAgICAgc2VsZi5faXNfdHJhaW5lZF9mbGFnID0gRmFsc2UKICAgICAgICBzZWxmLl9jdl9zY29yZTogZmxvYXQgPSAwLjAKICAgICAgICBzZWxmLl9zYW1wbGVzX3NpbmNlX3RyYWluOiBpbnQgPSAwCiAgICAgICAgc2VsZi5fbG9jayA9IGFzeW5jaW8uTG9jaygpCgogICAgZGVmIGlzX3RyYWluZWQoc2VsZikgLT4gYm9vbDoKICAgICAgICByZXR1cm4gc2VsZi5faXNfdHJhaW5lZF9mbGFnCgogICAgZGVmIGdldF9pbmZvKHNlbGYpIC0+IERpY3Rbc3RyLCBBbnldOgogICAgICAgICIiIlJldHVybiBtb2RlbCBtZXRhZGF0YSBmb3IgL3N0YXRzIGVuZHBvaW50LiIiIgogICAgICAgIHJldHVybiB7CiAgICAgICAgICAgICJtb2RlbF9uYW1lIjogIkxvZ2lzdGljIiwKICAgICAgICAgICAgImN2X3Njb3JlIjogcm91bmQoc2VsZi5fY3Zfc2NvcmUsIDQpLAogICAgICAgICAgICAic2FtcGxlcyI6IGxlbihzZWxmLl9mZWF0dXJlcyksCiAgICAgICAgICAgICJpc190cmFpbmVkIjogc2VsZi5faXNfdHJhaW5lZF9mbGFnLAogICAgICAgICAgICAic3RhbGVuZXNzX3RocmVzaG9sZCI6IE1MX1NUQUxFTkVTU19USFJFU0hPTEQsCiAgICAgICAgICAgICJpc19zdGFsZSI6IHNlbGYuX2N2X3Njb3JlIDwgTUxfU1RBTEVORVNTX1RIUkVTSE9MRCBhbmQgc2VsZi5faXNfdHJhaW5lZF9mbGFnLAogICAgICAgIH0KCiAgICBkZWYgX2V4dHJhY3RfZmVhdHVyZXMoc2VsZiwgcHJveHlfdXJsOiBzdHIsIGxhdGVuY3lfbXM6IGZsb2F0KSAtPiBMaXN0W2Zsb2F0XToKICAgICAgICBwcm90b2NvbCA9IHByb3h5X3VybC5zcGxpdCgiOi8vIilbMF0gaWYgIjovLyIgaW4gcHJveHlfdXJsIGVsc2UgImh0dHAiCiAgICAgICAgcHJvdG9fbWFwID0geyJodHRwIjogMCwgImh0dHBzIjogMSwgInNvY2tzNCI6IDIsICJzb2NrczUiOiAzfQogICAgICAgICMgQWRkIHN1Y2Nlc3MgcmF0ZSBlc3RpbWF0ZSBmcm9tIHNjb3JlciB2aWEgcHVibGljIG1ldGhvZAogICAgICAgIHN1Y2Nlc3NfcmF0ZSA9IDAuNSAgIyBkZWZhdWx0CiAgICAgICAgaWYgc2VsZi5fc2NvcmVyX3JlZjoKICAgICAgICAgICAgc3VjY2Vzc19yYXRlID0gc2VsZi5fc2NvcmVyX3JlZi5nZXRfcmVjZW50X3N1Y2Nlc3NfcmF0ZShwcm94eV91cmwpCiAgICAgICAgcmV0dXJuIFtsYXRlbmN5X21zIC8gMTAwMC4wLCBmbG9hdChwcm90b19tYXAuZ2V0KHByb3RvY29sLCAwKSksIHN1Y2Nlc3NfcmF0ZV0KCiAgICBhc3luYyBkZWYgdXBkYXRlKHNlbGYsIHByb3h5X3VybDogc3RyLCBsYXRlbmN5X21zOiBmbG9hdCwgc3VjY2VzczogYm9vbCk6CiAgICAgICAgYXN5bmMgd2l0aCBzZWxmLl9sb2NrOgogICAgICAgICAgICBmZWF0dXJlcyA9IHNlbGYuX2V4dHJhY3RfZmVhdHVyZXMocHJveHlfdXJsLCBsYXRlbmN5X21zKQogICAgICAgICAgICBzZWxmLl9mZWF0dXJlcy5hcHBlbmQoZmVhdHVyZXMpCiAgICAgICAgICAgIHNlbGYuX2xhYmVscy5hcHBlbmQoMSBpZiBzdWNjZXNzIGVsc2UgMCkKICAgICAgICAgICAgaWYgbGVuKHNlbGYuX2ZlYXR1cmVzKSA+IHNlbGYubWF4X3NhbXBsZXM6CiAgICAgICAgICAgICAgICBzZWxmLl9mZWF0dXJlcyA9IHNlbGYuX2ZlYXR1cmVzWy1zZWxmLm1heF9zYW1wbGVzOl0KICAgICAgICAgICAgICAgIHNlbGYuX2xhYmVscyA9IHNlbGYuX2xhYmVsc1stc2VsZi5tYXhfc2FtcGxlczpdCiAgICAgICAgICAgIGlmIGxlbihzZWxmLl9mZWF0dXJlcykgPj0gMjA6CiAgICAgICAgICAgICAgICAjIEF0b21pYyBzd2FwOiB0cmFpbiBpbiB0aHJlYWQsIHRoZW4gc3dhcCBtb2RlbCBvdXRzaWRlIGxvY2sKICAgICAgICAgICAgICAgIGF3YWl0IGFzeW5jaW8udG9fdGhyZWFkKHNlbGYuX3RyYWluX2F0b21pYykKCiAgICBkZWYgX3RyYWluX2F0b21pYyhzZWxmKToKICAgICAgICAiIiJUcmFpbiBtb2RlbCwgdmFsaWRhdGUgd2l0aCBjcm9zcy12YWxpZGF0aW9uLCBhbmQgYXRvbWljYWxseSBzd2FwLgoKICAgICAgICBJZiB0aGUgQ1Ygc2NvcmUgZmFsbHMgYmVsb3cgTUxfU1RBTEVORVNTX1RIUkVTSE9MRCwgdGhlIG1vZGVsIGlzCiAgICAgICAgc3RpbGwgaW5zdGFsbGVkIGJ1dCBmbGFnZ2VkIGFzIHN0YWxlIHNvIGNhbGxlcnMga25vdyBpdCBuZWVkcyBtb3JlCiAgICAgICAgbGl2ZSBkYXRhIGJlZm9yZSBpdCBiZWNvbWVzIHJlbGlhYmxlLgogICAgICAgICIiIgogICAgICAgIGlmIG5vdCBTS0xFQVJOX0FWQUlMQUJMRToKICAgICAgICAgICAgcmV0dXJuCiAgICAgICAgdHJ5OgogICAgICAgICAgICBYID0gbnAuYXJyYXkoc2VsZi5fZmVhdHVyZXMpCiAgICAgICAgICAgIHkgPSBucC5hcnJheShzZWxmLl9sYWJlbHMpCiAgICAgICAgICAgIGlmIGxlbihzZXQoeSkpIDwgMjoKICAgICAgICAgICAgICAgIHJldHVybgogICAgICAgICAgICAjIE5lZWQgYXQgbGVhc3QgMiBzYW1wbGVzIHBlciBjbGFzcyBmb3IgY3Jvc3MtdmFsaWRhdGlvbgogICAgICAgICAgICBtaW5fY2xhc3NfY291bnQgPSBtaW4oMTAsIG1pbihucC5iaW5jb3VudCh5KSkgaWYgbGVuKHkpID49IDIwIGVsc2UgMikKICAgICAgICAgICAgaWYgbWluX2NsYXNzX2NvdW50IDwgMjoKICAgICAgICAgICAgICAgIGxvZ2dlci5kZWJ1ZygiTm90IGVub3VnaCBzYW1wbGVzIHBlciBjbGFzcyBmb3IgQ1YsIHNraXBwaW5nIHZhbGlkYXRpb24iKQogICAgICAgICAgICAgICAgY3Zfc2NvcmUgPSAwLjUKICAgICAgICAgICAgZWxzZToKICAgICAgICAgICAgICAgIGN2X2ZvbGRzID0gbWluKDMsIG1pbl9jbGFzc19jb3VudCkKICAgICAgICAgICAgICAgIHNjYWxlcl9jdiA9IFN0YW5kYXJkU2NhbGVyKCkKICAgICAgICAgICAgICAgIFhfY3YgPSBzY2FsZXJfY3YuZml0X3RyYW5zZm9ybShYKQogICAgICAgICAgICAgICAgbW9kZWxfY3YgPSBMb2dpc3RpY1JlZ3Jlc3Npb24obWF4X2l0ZXI9MTAwMCwgY2xhc3Nfd2VpZ2h0PSdiYWxhbmNlZCcpCiAgICAgICAgICAgICAgICBjdl9zY29yZXMgPSBjcm9zc192YWxfc2NvcmUobW9kZWxfY3YsIFhfY3YsIHksIGN2PWN2X2ZvbGRzLCBzY29yaW5nPSdhY2N1cmFjeScpCiAgICAgICAgICAgICAgICBjdl9zY29yZSA9IGZsb2F0KGN2X3Njb3Jlcy5tZWFuKCkpCgogICAgICAgICAgICAjIEZpdCBmaW5hbCBtb2RlbCBvbiBmdWxsIGRhdGEKICAgICAgICAgICAgc2NhbGVyID0gU3RhbmRhcmRTY2FsZXIoKQogICAgICAgICAgICBYX3NjYWxlZCA9IHNjYWxlci5maXRfdHJhbnNmb3JtKFgpCiAgICAgICAgICAgIG1vZGVsID0gTG9naXN0aWNSZWdyZXNzaW9uKG1heF9pdGVyPTEwMDAsIGNsYXNzX3dlaWdodD0nYmFsYW5jZWQnKQogICAgICAgICAgICBtb2RlbC5maXQoWF9zY2FsZWQsIHkpCgogICAgICAgICAgICAjIEF0b21pYyBzd2FwCiAgICAgICAgICAgIHNlbGYuX21vZGVsID0gbW9kZWwKICAgICAgICAgICAgc2VsZi5fc2NhbGVyID0gc2NhbGVyCiAgICAgICAgICAgIHNlbGYuX2N2X3Njb3JlID0gY3Zfc2NvcmUKICAgICAgICAgICAgc2VsZi5fc2FtcGxlc19zaW5jZV90cmFpbiA9IDAKICAgICAgICAgICAgc2VsZi5faXNfdHJhaW5lZF9mbGFnID0gVHJ1ZQoKICAgICAgICAgICAgaWYgY3Zfc2NvcmUgPCBNTF9TVEFMRU5FU1NfVEhSRVNIT0xEOgogICAgICAgICAgICAgICAgbG9nZ2VyLndhcm5pbmcoZiJNTCBtb2RlbCB0cmFpbmVkIGJ1dCBDViBzY29yZSB7Y3Zfc2NvcmU6LjNmfSA8IHRocmVzaG9sZCB7TUxfU1RBTEVORVNTX1RIUkVTSE9MRH0g4oCUIG1vZGVsIGlzIHN0YWxlLCB3aWxsIGltcHJvdmUgd2l0aCBtb3JlIGRhdGEiKQogICAgICAgICAgICBlbHNlOgogICAgICAgICAgICAgICAgbG9nZ2VyLmluZm8oZiJNTCBtb2RlbCB0cmFpbmVkOiBDViBzY29yZSB7Y3Zfc2NvcmU6LjNmfSwgc2FtcGxlcz17bGVuKHNlbGYuX2ZlYXR1cmVzKX0iKQogICAgICAgIGV4Y2VwdCBFeGNlcHRpb24gYXMgZToKICAgICAgICAgICAgbG9nZ2VyLndhcm5pbmcoZiJNTCB0cmFpbmluZyBmYWlsZWQ6IHtlfSIpCgogICAgYXN5bmMgZGVmIHByZWRpY3Qoc2VsZiwgcHJveHlfdXJsOiBzdHIsIGxhdGVuY3lfbXM6IGZsb2F0KSAtPiBmbG9hdDoKICAgICAgICBpZiBub3Qgc2VsZi5faXNfdHJhaW5lZF9mbGFnIG9yIG5vdCBTS0xFQVJOX0FWQUlMQUJMRToKICAgICAgICAgICAgcmV0dXJuIDAuNQogICAgICAgIGFzeW5jIHdpdGggc2VsZi5fbG9jazoKICAgICAgICAgICAgaWYgc2VsZi5fbW9kZWwgaXMgTm9uZSBvciBzZWxmLl9zY2FsZXIgaXMgTm9uZToKICAgICAgICAgICAgICAgIHJldHVybiAwLjUKICAgICAgICAgICAgdHJ5OgogICAgICAgICAgICAgICAgZmVhdHVyZXMgPSBzZWxmLl9leHRyYWN0X2ZlYXR1cmVzKHByb3h5X3VybCwgbGF0ZW5jeV9tcykKICAgICAgICAgICAgICAgIFggPSBucC5hcnJheShbZmVhdHVyZXNdKQogICAgICAgICAgICAgICAgWF9zY2FsZWQgPSBzZWxmLl9zY2FsZXIudHJhbnNmb3JtKFgpCiAgICAgICAgICAgICAgICByZXR1cm4gZmxvYXQoc2VsZi5fbW9kZWwucHJlZGljdF9wcm9iYShYX3NjYWxlZClbMF1bMV0pCiAgICAgICAgICAgIGV4Y2VwdCBFeGNlcHRpb24gYXMgZToKICAgICAgICAgICAgICAgIGxvZ2dlci53YXJuaW5nKGYiTUwgcHJlZGljdGlvbiBmYWlsZWQ6IHtlfSIpCiAgICAgICAgICAgICAgICByZXR1cm4gMC41CgoKIyDilIDilIDilIAgRG9tYWluQ2lyY3VpdEJyZWFrZXIg4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSACmNsYXNzIERvbWFpbkNpcmN1aXRCcmVha2VyOgogICAgZGVmIF9faW5pdF9fKHNlbGYsIGZhaWx1cmVfdGhyZXNob2xkPUNJUkNVSVRfQlJFQUtFUl9GQUlMVVJFX1RIUkVTSE9MRCwKICAgICAgICAgICAgICAgICByZWNvdmVyeV90aW1lb3V0PUNJUkNVSVRfQlJFQUtFUl9SRUNPVkVSWV9USU1FT1VUKToKICAgICAgICBzZWxmLl9icmVha2VyczogRGljdFtzdHIsIENpcmN1aXRCcmVha2VyXSA9IHt9CiAgICAgICAgc2VsZi5fZmFpbHVyZV90aHJlc2hvbGQgPSBmYWlsdXJlX3RocmVzaG9sZAogICAgICAgIHNlbGYuX3JlY292ZXJ5X3RpbWVvdXQgPSByZWNvdmVyeV90aW1lb3V0CgogICAgZGVmIGdldChzZWxmLCBkb21haW46IHN0cikgLT4gQ2lyY3VpdEJyZWFrZXI6CiAgICAgICAgaWYgZG9tYWluIG5vdCBpbiBzZWxmLl9icmVha2VyczoKICAgICAgICAgICAgc2VsZi5fYnJlYWtlcnNbZG9tYWluXSA9IENpcmN1aXRCcmVha2VyKAogICAgICAgICAgICAgICAgZmFpbHVyZV90aHJlc2hvbGQ9c2VsZi5fZmFpbHVyZV90aHJlc2hvbGQsCiAgICAgICAgICAgICAgICByZWNvdmVyeV90aW1lb3V0PXNlbGYuX3JlY292ZXJ5X3RpbWVvdXQKICAgICAgICAgICAgKQogICAgICAgIHJldHVybiBzZWxmLl9icmVha2Vyc1tkb21haW5dCgojIOKUgOKUgOKUgCBBZ2VudEJyb3dzZXJXcmFwcGVyIOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgApjbGFzcyBBZ2VudEJyb3dzZXJXcmFwcGVyOgogICAgZGVmIF9faW5pdF9fKHNlbGYsIHByb3h5X3VybDogT3B0aW9uYWxbc3RyXSA9IE5vbmUsIGhlYWRsZXNzOiBib29sID0gVHJ1ZSk6CiAgICAgICAgc2VsZi5wcm94eV91cmwgPSBwcm94eV91cmwKICAgICAgICBzZWxmLmhlYWRsZXNzID0gaGVhZGxlc3MKCiAgICBhc3luYyBkZWYgZmV0Y2hfcGFnZShzZWxmLCB1cmw6IHN0ciwgd2FpdF9mb3I6IE9wdGlvbmFsW3N0cl0gPSBOb25lLCB0aW1lb3V0OiBpbnQgPSAzMCkgLT4gc3RyOgogICAgICAgIGNtZCA9IFsiYWdlbnQtYnJvd3NlciIsICJmZXRjaCIsIHVybF0KICAgICAgICBpZiBzZWxmLnByb3h5X3VybDoKICAgICAgICAgICAgY21kLmV4dGVuZChbIi0tcHJveHkiLCBzZWxmLnByb3h5X3VybF0pCiAgICAgICAgaWYgc2VsZi5oZWFkbGVzczoKICAgICAgICAgICAgY21kLmFwcGVuZCgiLS1oZWFkbGVzcyIpCiAgICAgICAgaWYgd2FpdF9mb3I6CiAgICAgICAgICAgIGNtZC5leHRlbmQoWyItLXdhaXQiLCB3YWl0X2Zvcl0pCiAgICAgICAgY21kLmV4dGVuZChbIi0tdGltZW91dCIsIHN0cih0aW1lb3V0KV0pCiAgICAgICAgdHJ5OgogICAgICAgICAgICByZXN1bHQgPSBhd2FpdCBhc3luY2lvLmNyZWF0ZV9zdWJwcm9jZXNzX2V4ZWMoCiAgICAgICAgICAgICAgICAqY21kLAogICAgICAgICAgICAgICAgc3Rkb3V0PXN1YnByb2Nlc3MuUElQRSwKICAgICAgICAgICAgICAgIHN0ZGVycj1zdWJwcm9jZXNzLlBJUEUKICAgICAgICAgICAgKQogICAgICAgICAgICBzdGRvdXQsIHN0ZGVyciA9IGF3YWl0IHJlc3VsdC5jb21tdW5pY2F0ZSgpCiAgICAgICAgICAgIGlmIHJlc3VsdC5yZXR1cm5jb2RlICE9IDA6CiAgICAgICAgICAgICAgICBsb2dnZXIuZXJyb3IoZiJhZ2VudC1icm93c2VyIGVycm9yOiB7c3RkZXJyLmRlY29kZSgpfSIpCiAgICAgICAgICAgICAgICByYWlzZSBSdW50aW1lRXJyb3IoZiJhZ2VudC1icm93c2VyIGZhaWxlZDoge3N0ZGVyci5kZWNvZGUoKX0iKQogICAgICAgICAgICByZXR1cm4gc3Rkb3V0LmRlY29kZSgndXRmLTgnLCBlcnJvcnM9J3JlcGxhY2UnKQogICAgICAgIGV4Y2VwdCBGaWxlTm90Rm91bmRFcnJvcjoKICAgICAgICAgICAgcmFpc2UgUnVudGltZUVycm9yKCJhZ2VudC1icm93c2VyIG5vdCBpbnN0YWxsZWQuIFJ1bjogbnB4IHNraWxscyBhZGQgdmVyY2VsLWxhYnMvYWdlbnQtYnJvd3NlciIpCgojIOKUgOKUgOKUgCBSZXNpbGllbnRDbGllbnQgKFVuaWZpZWQpIOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgApjbGFzcyBSZXNpbGllbnRDbGllbnQ6CiAgICBkZWYgX19pbml0X18oc2VsZiwKICAgICAgICAgICAgICAgICBjYWNoZV90dGw6IGludCA9IERFRkFVTFRfVFRMLAogICAgICAgICAgICAgICAgIHJhdGVfbGltaXQ6IGZsb2F0ID0gREVGQVVMVF9SQVRFLAogICAgICAgICAgICAgICAgIG1heF9yZXRyaWVzOiBpbnQgPSBNQVhfUkVUUklFUywKICAgICAgICAgICAgICAgICB1c2VfY3VybF9jZmZpOiBib29sID0gRmFsc2UsCiAgICAgICAgICAgICAgICAgY291bnRyaWVzOiBPcHRpb25hbFtMaXN0W3N0cl1dID0gTm9uZSwKICAgICAgICAgICAgICAgICB1c2VfcmVkaXM6IGJvb2wgPSBGYWxzZSwKICAgICAgICAgICAgICAgICByZWRpc191cmw6IHN0ciA9ICJyZWRpczovL2xvY2FsaG9zdDo2Mzc5IiwKICAgICAgICAgICAgICAgICBlbmFibGVfYWJfdGVzdDogYm9vbCA9IEZhbHNlLAogICAgICAgICAgICAgICAgIGVuYWJsZV9tbDogYm9vbCA9IEZhbHNlLAogICAgICAgICAgICAgICAgIG1sX21vZGVsOiBzdHIgPSAiYXV0byIsCiAgICAgICAgICAgICAgICAgcGx1Z2luX2Rpcjogc3RyID0gIn4vLm93bC1hZ2VudC9wbHVnaW5zIik6CiAgICAgICAgc2VsZi5jYWNoZSA9IEhUVFBDYWNoZShjYWNoZV90dGwpCiAgICAgICAgc2VsZi5kZWR1cCA9IFJlcXVlc3REZWR1cGxpY2F0b3IoKQogICAgICAgIHNlbGYubGltaXRlciA9IEFkYXB0aXZlUmF0ZUxpbWl0ZXIoYmFzZV9yYXRlPXJhdGVfbGltaXQpCiAgICAgICAgc2VsZi5tYXhfcmV0cmllcyA9IG1heF9yZXRyaWVzCiAgICAgICAgc2VsZi5wb29sX21hbmFnZXIgPSBQcm94eVBvb2xNYW5hZ2VyKGNvdW50cmllcz1jb3VudHJpZXMpCiAgICAgICAgc2VsZi5jaXJjdWl0X2JyZWFrZXJzID0gRG9tYWluQ2lyY3VpdEJyZWFrZXIoKQogICAgICAgIHNlbGYuc2NvcmVyID0gUXVhbGl0eVNjb3JlcigpCiAgICAgICAgc2VsZi51c2VfY3VybF9jZmZpID0gdXNlX2N1cmxfY2ZmaSBhbmQgQ1VSTF9DRkZJX0FWQUlMQUJMRQogICAgICAgIGlmIHNlbGYudXNlX2N1cmxfY2ZmaToKICAgICAgICAgICAgbG9nZ2VyLmluZm8oIlVzaW5nIGN1cmxfY2ZmaSBmb3IgcmVxdWVzdHMgKENocm9tZSAxMTAgZmluZ2VycHJpbnQpIikKICAgICAgICBlbHNlOgogICAgICAgICAgICBsb2dnZXIuaW5mbygiVXNpbmcgaHR0cHggZm9yIHJlcXVlc3RzIikKICAgICAgICBzZWxmLnVzZV9yZWRpcyA9IHVzZV9yZWRpcwogICAgICAgIHNlbGYucmVkaXNfdXJsID0gcmVkaXNfdXJsCiAgICAgICAgc2VsZi5yZWRpc19zdG9yZSA9IE5vbmUKICAgICAgICBzZWxmLl9kaXJlY3Rfc2Vzc2lvbiA9IE5vbmUKICAgICAgICBzZWxmLl9wcm94eV9zZXNzaW9uczogRGljdFtzdHIsIGh0dHB4LkFzeW5jQ2xpZW50XSA9IHt9CiAgICAgICAgc2VsZi5fYnJvd3Nlcl93cmFwcGVyID0gTm9uZQogICAgICAgICMgdjQuNTogUGx1Z2luIGxvYWRlciAobXVzdCBiZSBiZWZvcmUgUGx1Z2luTWFuYWdlcikKICAgICAgICBzZWxmLnBsdWdpbl9sb2FkZXIgPSBQbHVnaW5Mb2FkZXIocGx1Z2luX2RpcikgaWYgUGx1Z2luTG9hZGVyIGVsc2UgTm9uZQogICAgICAgICMgdjQuMzogUGx1Z2luIHN5c3RlbSwgQS9CIHRlc3RpbmcsIE1MIHByZWRpY3RvcgogICAgICAgIHNlbGYucGx1Z2luX21hbmFnZXIgPSBQbHVnaW5NYW5hZ2VyKHNlbGYucGx1Z2luX2xvYWRlcikKICAgICAgICBzZWxmLmVuYWJsZV9hYl90ZXN0ID0gZW5hYmxlX2FiX3Rlc3QKICAgICAgICBzZWxmLmVuYWJsZV9tbCA9IGVuYWJsZV9tbCBhbmQgU0tMRUFSTl9BVkFJTEFCTEUKICAgICAgICBzZWxmLmFiX3Rlc3QgPSBBQlRlc3RNYW5hZ2VyKCkgaWYgc2VsZi5lbmFibGVfYWJfdGVzdCBlbHNlIE5vbmUKICAgICAgICAjIHY0LjQ6IEFkdmFuY2VkIE1MIHByZWRpY3RvcgogICAgICAgIGlmIHNlbGYuZW5hYmxlX21sIGFuZCBBZHZhbmNlZE1MUHJlZGljdG9yOgogICAgICAgICAgICBzZWxmLm1sX3ByZWRpY3RvciA9IEFkdmFuY2VkTUxQcmVkaWN0b3IobW9kZWxfdHlwZT1tbF9tb2RlbCkKICAgICAgICBlbHNlOgogICAgICAgICAgICBzZWxmLm1sX3ByZWRpY3RvciA9IE5vbmUKICAgICAgICBpZiBzZWxmLmVuYWJsZV9hYl90ZXN0OgogICAgICAgICAgICBsb2dnZXIuaW5mbygiQS9CIHRlc3RpbmcgZW5hYmxlZCIpCiAgICAgICAgaWYgc2VsZi5lbmFibGVfbWw6CiAgICAgICAgICAgIGxvZ2dlci5pbmZvKGYiTUwgcHJlZGljdG9yIGVuYWJsZWQgKG1vZGVsPXttbF9tb2RlbH0pIikKICAgICAgICBlbGlmIGVuYWJsZV9tbCBhbmQgbm90IFNLTEVBUk5fQVZBSUxBQkxFOgogICAgICAgICAgICBsb2dnZXIud2FybmluZygiTUwgcmVxdWVzdGVkIGJ1dCBzY2lraXQtbGVhcm4gbm90IGF2YWlsYWJsZSDigJQgZGlzYWJsZWQiKQogICAgICAgIGlmIHNlbGYucGx1Z2luX2xvYWRlcjoKICAgICAgICAgICAgbG9nZ2VyLmluZm8oZiJQbHVnaW4gbG9hZGVyIGVuYWJsZWQgKGRpcj17cGx1Z2luX2Rpcn0pIikKCiAgICBhc3luYyBkZWYgX19hZW50ZXJfXyhzZWxmKToKICAgICAgICBhd2FpdCBzZWxmLnBvb2xfbWFuYWdlci5zdGFydCgpCiAgICAgICAgYXdhaXQgc2VsZi5jYWNoZS5zdGFydF9jbGVhbmVyKCkKCiAgICAgICAgIyBhaW9odHRwIHNlc3Npb24gZm9yIGRpcmVjdCBjb25uZWN0aW9ucyAoaGFuZGxlcyBUTFMgYmV0dGVyIHRoYW4gY3VybF9jZmZpKQogICAgICAgIHNlbGYuX2Fpb2h0dHBfZGlyZWN0X3Nlc3Npb24gPSBhaW9odHRwLkNsaWVudFNlc3Npb24oCiAgICAgICAgICAgIHRpbWVvdXQ9YWlvaHR0cC5DbGllbnRUaW1lb3V0KHRvdGFsPTMwKQogICAgICAgICkKICAgICAgICBpZiBzZWxmLnVzZV9jdXJsX2NmZmk6CiAgICAgICAgICAgIHNlbGYuX2RpcmVjdF9zZXNzaW9uID0gQ3VybEFzeW5jU2Vzc2lvbigKICAgICAgICAgICAgICAgIGltcGVyc29uYXRlPSJjaHJvbWUxMTAiLAogICAgICAgICAgICAgICAgdGltZW91dD0zMCwKICAgICAgICAgICAgICAgIHZlcmlmeT1UcnVlCiAgICAgICAgICAgICkKICAgICAgICBlbHNlOgogICAgICAgICAgICBzZWxmLl9kaXJlY3Rfc2Vzc2lvbiA9IGh0dHB4LkFzeW5jQ2xpZW50KGh0dHAyPVRydWUpCgogICAgICAgICMgX3Byb3h5X3Nlc3Npb25zIGlzIHBvcHVsYXRlZCBsYXppbHkgcGVyLXByb3h5IGluIF9leGVjdXRlX3dpdGhfcmVzaWxpZW50X2NsaWVudAogICAgICAgIHNlbGYuX2Jyb3dzZXJfd3JhcHBlciA9IEFnZW50QnJvd3NlcldyYXBwZXIoKQoKICAgICAgICBpZiBzZWxmLnVzZV9yZWRpczoKICAgICAgICAgICAgc2VsZi5yZWRpc19zdG9yZSA9IFJlZGlzU3RvcmUoc2VsZi5yZWRpc191cmwpCiAgICAgICAgICAgIGF3YWl0IHNlbGYucmVkaXNfc3RvcmUuY29ubmVjdCgpCiAgICAgICAgICAgIGF3YWl0IHNlbGYuX2xvYWRfc3RhdGUoKQoKICAgICAgICByZXR1cm4gc2VsZgoKICAgIGFzeW5jIGRlZiBfX2FleGl0X18oc2VsZiwgKmFyZ3MpOgogICAgICAgIGlmIHNlbGYucGx1Z2luX2xvYWRlcjoKICAgICAgICAgICAgYXdhaXQgc2VsZi5wbHVnaW5fbG9hZGVyLnN0b3AoKQogICAgICAgIHNlbGYucG9vbF9tYW5hZ2VyLnN0b3AoKQogICAgICAgIGlmIHNlbGYuX2RpcmVjdF9zZXNzaW9uOgogICAgICAgICAgICBpZiBoYXNhdHRyKHNlbGYuX2RpcmVjdF9zZXNzaW9uLCAnYWNsb3NlJyk6CiAgICAgICAgICAgICAgICBhd2FpdCBzZWxmLl9kaXJlY3Rfc2Vzc2lvbi5hY2xvc2UoKQogICAgICAgICAgICBlbHNlOgogICAgICAgICAgICAgICAgIyBjdXJsX2NmZmkncyBBc3luY1Nlc3Npb24uY2xvc2UoKSBpcyBhIGNvcm91dGluZSBuYW1lZCBjbG9zZSgpLCBub3QgYWNsb3NlKCkKICAgICAgICAgICAgICAgIGNsb3NlX2ZuID0gc2VsZi5fZGlyZWN0X3Nlc3Npb24uY2xvc2UoKQogICAgICAgICAgICAgICAgaWYgaGFzYXR0cihjbG9zZV9mbiwgJ19fYXdhaXRfXycpIG9yIGFzeW5jaW8uaXNjb3JvdXRpbmUoY2xvc2VfZm4pOgogICAgICAgICAgICAgICAgICAgIGF3YWl0IGNsb3NlX2ZuCiAgICAgICAgYXdhaXQgc2VsZi5fYWlvaHR0cF9kaXJlY3Rfc2Vzc2lvbi5jbG9zZSgpCiAgICAgICAgZm9yIHByb3h5LCBzZXNzaW9uIGluIHNlbGYuX3Byb3h5X3Nlc3Npb25zLml0ZW1zKCk6CiAgICAgICAgICAgIGF3YWl0IHNlc3Npb24uYWNsb3NlKCkKICAgICAgICBzZWxmLl9wcm94eV9zZXNzaW9ucy5jbGVhcigpCgogICAgYXN5bmMgZGVmIF9sb2FkX3N0YXRlKHNlbGYpOgogICAgICAgIGlmIG5vdCBzZWxmLnJlZGlzX3N0b3JlIG9yIG5vdCBzZWxmLnJlZGlzX3N0b3JlLl9lbmFibGVkOgogICAgICAgICAgICByZXR1cm4KICAgICAgICB0cnk6CiAgICAgICAgICAgIGtleXMgPSBhd2FpdCBzZWxmLnJlZGlzX3N0b3JlLmtleXMoInNjb3JlOioiKQogICAgICAgICAgICBmb3Iga2V5IGluIGtleXM6CiAgICAgICAgICAgICAgICBwcm94eV91cmwgPSBrZXkuc3BsaXQoIjoiKVstMV0KICAgICAgICAgICAgICAgIHNjb3JlID0gYXdhaXQgc2VsZi5yZWRpc19zdG9yZS5nZXQoZiJzY29yZTp7cHJveHlfdXJsfSIpCiAgICAgICAgICAgICAgICBpZiBzY29yZSBpcyBub3QgTm9uZToKICAgICAgICAgICAgICAgICAgICBzZWxmLnNjb3Jlci5fc2NvcmVzW3Byb3h5X3VybF0gPSBmbG9hdChzY29yZSkKICAgICAgICAgICAga2V5cyA9IGF3YWl0IHNlbGYucmVkaXNfc3RvcmUua2V5cygicmF0ZToqIikKICAgICAgICAgICAgZm9yIGtleSBpbiBrZXlzOgogICAgICAgICAgICAgICAgZG9tYWluID0ga2V5LnNwbGl0KCI6IilbLTFdCiAgICAgICAgICAgICAgICByYXRlID0gYXdhaXQgc2VsZi5yZWRpc19zdG9yZS5nZXQoZiJyYXRlOntkb21haW59IikKICAgICAgICAgICAgICAgIGlmIHJhdGUgaXMgbm90IE5vbmU6CiAgICAgICAgICAgICAgICAgICAgc2VsZi5saW1pdGVyLl9yYXRlc1tkb21haW5dID0gZmxvYXQocmF0ZSkKICAgICAgICAgICAgbG9nZ2VyLmluZm8oIlN0YXRlIGxvYWRlZCBmcm9tIFJlZGlzIikKICAgICAgICBleGNlcHQgRXhjZXB0aW9uIGFzIGU6CiAgICAgICAgICAgIGxvZ2dlci53YXJuaW5nKGYiRmFpbGVkIHRvIGxvYWQgc3RhdGUgZnJvbSBSZWRpczoge2V9IikKCiAgICBhc3luYyBkZWYgX3NhdmVfc3RhdGUoc2VsZik6CiAgICAgICAgaWYgbm90IHNlbGYucmVkaXNfc3RvcmUgb3Igbm90IHNlbGYucmVkaXNfc3RvcmUuX2VuYWJsZWQ6CiAgICAgICAgICAgIHJldHVybgogICAgICAgIHRyeToKICAgICAgICAgICAgZm9yIHByb3h5X3VybCwgc2NvcmUgaW4gc2VsZi5zY29yZXIuZ2V0X2FsbF9zY29yZXMoKS5pdGVtcygpOgogICAgICAgICAgICAgICAgYXdhaXQgc2VsZi5yZWRpc19zdG9yZS5zZXQoZiJzY29yZTp7cHJveHlfdXJsfSIsIHNjb3JlLCB0dGw9MzYwMCkKICAgICAgICAgICAgZm9yIGRvbWFpbiwgcmF0ZSBpbiBhd2FpdCBzZWxmLmxpbWl0ZXIuZ2V0X2FsbF9yYXRlcygpLml0ZW1zKCk6CiAgICAgICAgICAgICAgICBhd2FpdCBzZWxmLnJlZGlzX3N0b3JlLnNldChmInJhdGU6e2RvbWFpbn0iLCByYXRlLCB0dGw9MzYwMCkKICAgICAgICBleGNlcHQgRXhjZXB0aW9uIGFzIGU6CiAgICAgICAgICAgIGxvZ2dlci53YXJuaW5nKGYiRmFpbGVkIHRvIHNhdmUgc3RhdGUgdG8gUmVkaXM6IHtlfSIpCgogICAgZGVmIF9lc3RpbWF0ZV9sYXRlbmN5KHNlbGYsIHByb3h5X3VybDogc3RyKSAtPiBmbG9hdDoKICAgICAgICAiIiJFc3RpbWF0ZSBwcm94eSBsYXRlbmN5IGZyb20gc2NvcmVyIGhpc3RvcnkuIiIiCiAgICAgICAgcmV0dXJuIHNlbGYuc2NvcmVyLmdldF9hdmdfbGF0ZW5jeShwcm94eV91cmwpCgogICAgYXN5bmMgZGVmIF9nZXRfYmVzdF9wcm94eShzZWxmLCBkb21haW46IE9wdGlvbmFsW3N0cl0gPSBOb25lKSAtPiBPcHRpb25hbFtzdHJdOgogICAgICAgICIiIkVuaGFuY2VkIHByb3h5IHNlbGVjdGlvbiB1c2luZyBBL0IgdGVzdCBhbmQgTUwgcHJlZGljdG9yLiIiIgogICAgICAgIGhlYWx0aHlfdXJscyA9IHNlbGYucG9vbF9tYW5hZ2VyLmdldF9hbGxfdXJscygpCiAgICAgICAgaWYgbm90IGhlYWx0aHlfdXJsczoKICAgICAgICAgICAgcmV0dXJuIE5vbmUKICAgICAgICAjIEEvQiB0ZXN0IHN0cmF0ZWd5IHNlbGVjdGlvbgogICAgICAgIGlmIHNlbGYuZW5hYmxlX2FiX3Rlc3QgYW5kIHNlbGYuYWJfdGVzdCBhbmQgZG9tYWluOgogICAgICAgICAgICBzZWxlY3RlZCA9IHNlbGYuYWJfdGVzdC5zZWxlY3RfcHJveHkoZG9tYWluLCBoZWFsdGh5X3VybHMsIHNlbGYuc2NvcmVyKQogICAgICAgICAgICBpZiBzZWxlY3RlZDoKICAgICAgICAgICAgICAgIHJldHVybiBzZWxlY3RlZAogICAgICAgICMgTUwgcHJlZGljdG9yIHNlbGVjdGlvbgogICAgICAgIGlmIHNlbGYuZW5hYmxlX21sIGFuZCBzZWxmLm1sX3ByZWRpY3RvciBhbmQgc2VsZi5tbF9wcmVkaWN0b3IuaXNfdHJhaW5lZCgpOgogICAgICAgICAgICBiZXN0X3VybCwgYmVzdF9wcm9iID0gTm9uZSwgLTEuMAogICAgICAgICAgICBmb3IgdSBpbiBoZWFsdGh5X3VybHM6CiAgICAgICAgICAgICAgICBsYXRlbmN5ID0gc2VsZi5fZXN0aW1hdGVfbGF0ZW5jeSh1KQogICAgICAgICAgICAgICAgZW50cnkgPSBzZWxmLnBvb2xfbWFuYWdlci5nZXRfZW50cnkodSkKICAgICAgICAgICAgICAgIHByb2IgPSBhd2FpdCBzZWxmLm1sX3ByZWRpY3Rvci5wcmVkaWN0KHUsIGxhdGVuY3ksIHByb3h5X2VudHJ5PWVudHJ5LCBzY29yZXI9c2VsZi5zY29yZXIpCiAgICAgICAgICAgICAgICBpZiBwcm9iID4gYmVzdF9wcm9iOgogICAgICAgICAgICAgICAgICAgIGJlc3RfcHJvYiwgYmVzdF91cmwgPSBwcm9iLCB1CiAgICAgICAgICAgIGlmIGJlc3RfdXJsOgogICAgICAgICAgICAgICAgcmV0dXJuIGJlc3RfdXJsCiAgICAgICAgIyBGYWxsYmFjayB0byBxdWFsaXR5IHNjb3JlcgogICAgICAgIHJldHVybiBzZWxmLnNjb3Jlci5nZXRfYmVzdF9wcm94eShoZWFsdGh5X3VybHMpCgogICAgYXN5bmMgZGVmIF9leGVjdXRlX3dpdGhfcmVzaWxpZW50X2NsaWVudChzZWxmLCBtZXRob2QsIHVybCwgcGFyYW1zLCBoZWFkZXJzLCAqKmt3YXJncyk6CiAgICAgICAgcHJveHlfdXJsID0gYXdhaXQgc2VsZi5fZ2V0X2Jlc3RfcHJveHkoKQogICAgICAgIGlmIHByb3h5X3VybDoKICAgICAgICAgICAgaWYgc2VsZi51c2VfY3VybF9jZmZpOgogICAgICAgICAgICAgICAgcHJveGllcyA9IHsiaHR0cCI6IHByb3h5X3VybCwgImh0dHBzIjogcHJveHlfdXJsfQogICAgICAgICAgICAgICAgcmVzcG9uc2UgPSBhd2FpdCBzZWxmLl9kaXJlY3Rfc2Vzc2lvbi5yZXF1ZXN0KAogICAgICAgICAgICAgICAgICAgIG1ldGhvZCwgdXJsLCBwYXJhbXM9cGFyYW1zLCBoZWFkZXJzPWhlYWRlcnMsIHByb3hpZXM9cHJveGllcywgKiprd2FyZ3MKICAgICAgICAgICAgICAgICkKICAgICAgICAgICAgICAgIHJldHVybiByZXNwb25zZQogICAgICAgICAgICBlbHNlOgogICAgICAgICAgICAgICAgIyBVc2UgY2FjaGVkIGh0dHB4IHNlc3Npb24gd2l0aCBwcm94eSAocmVwbGFjZXMgYnJva2VuIHJlc2lsaWVudF9odHRweCArIGxpdHByb3h5KQogICAgICAgICAgICAgICAgaWYgcHJveHlfdXJsIG5vdCBpbiBzZWxmLl9wcm94eV9zZXNzaW9uczoKICAgICAgICAgICAgICAgICAgICBzZWxmLl9wcm94eV9zZXNzaW9uc1twcm94eV91cmxdID0gaHR0cHguQXN5bmNDbGllbnQoCiAgICAgICAgICAgICAgICAgICAgICAgIHByb3h5PXByb3h5X3VybCwgaHR0cDI9VHJ1ZSwgdGltZW91dD0zMC4wCiAgICAgICAgICAgICAgICAgICAgKQogICAgICAgICAgICAgICAgcmVzcG9uc2UgPSBhd2FpdCBzZWxmLl9wcm94eV9zZXNzaW9uc1twcm94eV91cmxdLnJlcXVlc3QoCiAgICAgICAgICAgICAgICAgICAgbWV0aG9kLCB1cmwsIHBhcmFtcz1wYXJhbXMsIGhlYWRlcnM9aGVhZGVycywgKiprd2FyZ3MKICAgICAgICAgICAgICAgICkKICAgICAgICAgICAgICAgIHJldHVybiByZXNwb25zZQogICAgICAgIGVsc2U6CiAgICAgICAgICAgIHJlc3BvbnNlID0gYXdhaXQgc2VsZi5fZGlyZWN0X3Nlc3Npb24ucmVxdWVzdCgKICAgICAgICAgICAgICAgIG1ldGhvZCwgdXJsLCBwYXJhbXM9cGFyYW1zLCBoZWFkZXJzPWhlYWRlcnMsICoqa3dhcmdzCiAgICAgICAgICAgICkKICAgICAgICAgICAgcmV0dXJuIHJlc3BvbnNlCgogICAgYXN5bmMgZGVmIF9mZXRjaF93aXRoX2Jyb3dzZXIoc2VsZiwgdXJsOiBzdHIsIHdhaXRfZm9yOiBPcHRpb25hbFtzdHJdID0gTm9uZSwgdGltZW91dDogaW50ID0gMzApIC0+IHN0cjoKICAgICAgICBwcm94eSA9IGF3YWl0IHNlbGYuX2dldF9iZXN0X3Byb3h5KCkKICAgICAgICBicm93c2VyID0gQWdlbnRCcm93c2VyV3JhcHBlcihwcm94eV91cmw9cHJveHkpCiAgICAgICAgcmV0dXJuIGF3YWl0IGJyb3dzZXIuZmV0Y2hfcGFnZSh1cmwsIHdhaXRfZm9yLCB0aW1lb3V0KQoKICAgIGFzeW5jIGRlZiByZXF1ZXN0KHNlbGYsIG1ldGhvZDogc3RyLCB1cmw6IHN0ciwgcGFyYW1zOiBPcHRpb25hbFtEaWN0XSA9IE5vbmUsCiAgICAgICAgICAgICAgICAgICAgICBoZWFkZXJzOiBPcHRpb25hbFtEaWN0XSA9IE5vbmUsIGJyb3dzZXI6IGJvb2wgPSBGYWxzZSwKICAgICAgICAgICAgICAgICAgICAgIHdhaXRfZm9yOiBPcHRpb25hbFtzdHJdID0gTm9uZSwgdGltZW91dDogaW50ID0gMzAsICoqa3dhcmdzKSAtPiBDYWNoZWRSZXNwb25zZToKICAgICAgICBpZiBicm93c2VyOgogICAgICAgICAgICBjb250ZW50ID0gYXdhaXQgc2VsZi5fZmV0Y2hfd2l0aF9icm93c2VyKHVybCwgd2FpdF9mb3IsIHRpbWVvdXQpCiAgICAgICAgICAgIHJldHVybiBDYWNoZWRSZXNwb25zZSgKICAgICAgICAgICAgICAgIHN0YXR1cz0yMDAsCiAgICAgICAgICAgICAgICBjb250ZW50PWNvbnRlbnQuZW5jb2RlKCd1dGYtOCcpLAogICAgICAgICAgICAgICAgaGVhZGVycz17IkNvbnRlbnQtVHlwZSI6ICJ0ZXh0L2h0bWwifSwKICAgICAgICAgICAgICAgIHRpbWVzdGFtcD10aW1lLnRpbWUoKSwKICAgICAgICAgICAgICAgIHR0bD1zZWxmLmNhY2hlLnR0bAogICAgICAgICAgICApCgogICAgICAgIGNhY2hlZCA9IGF3YWl0IHNlbGYuY2FjaGUuZ2V0KG1ldGhvZCwgdXJsLCBwYXJhbXMpCiAgICAgICAgaWYgY2FjaGVkOgogICAgICAgICAgICByZXR1cm4gY2FjaGVkCgogICAgICAgICMgSFRUUFMgVVJMcyBieXBhc3MgcHJveHkgcG9vbCBlbnRpcmVseSAoZnJlZSBwcm94aWVzIGNhbid0IHR1bm5lbCBIVFRQUykKICAgICAgICBpZiB1cmwuc3RhcnRzd2l0aCgiaHR0cHM6Ly8iKToKICAgICAgICAgICAgbG9nZ2VyLmluZm8oZiJIVFRQUyBVUkw6IGRpcmVjdCBjb25uZWN0aW9uIChubyBwcm94eSk6IHt1cmx9IikKICAgICAgICAgICAgdHJ5OgogICAgICAgICAgICAgICAgcmVxX3RpbWVvdXQgPSBhaW9odHRwLkNsaWVudFRpbWVvdXQodG90YWw9dGltZW91dCkKICAgICAgICAgICAgICAgIGFzeW5jIHdpdGggc2VsZi5fYWlvaHR0cF9kaXJlY3Rfc2Vzc2lvbi5yZXF1ZXN0KG1ldGhvZCwgdXJsLCBwYXJhbXM9cGFyYW1zLCBoZWFkZXJzPWhlYWRlcnMsIHRpbWVvdXQ9cmVxX3RpbWVvdXQsICoqa3dhcmdzKSBhcyByZXNwOgogICAgICAgICAgICAgICAgICAgIGNvbnRlbnQgPSBhd2FpdCByZXNwLnJlYWQoKQogICAgICAgICAgICAgICAgICAgIHJldHVybiBDYWNoZWRSZXNwb25zZSgKICAgICAgICAgICAgICAgICAgICAgICAgc3RhdHVzPXJlc3Auc3RhdHVzLAogICAgICAgICAgICAgICAgICAgICAgICBjb250ZW50PWNvbnRlbnQsCiAgICAgICAgICAgICAgICAgICAgICAgIGhlYWRlcnM9ZGljdChyZXNwLmhlYWRlcnMpLAogICAgICAgICAgICAgICAgICAgICAgICB0aW1lc3RhbXA9dGltZS50aW1lKCksCiAgICAgICAgICAgICAgICAgICAgICAgIHR0bD1zZWxmLmNhY2hlLnR0bCwKICAgICAgICAgICAgICAgICAgICApCiAgICAgICAgICAgIGV4Y2VwdCBFeGNlcHRpb24gYXMgZToKICAgICAgICAgICAgICAgIGxvZ2dlci53YXJuaW5nKGYiRGlyZWN0IEhUVFBTIGNvbm5lY3Rpb24gZmFpbGVkOiB7ZX0iKQogICAgICAgICAgICAgICAgcmFpc2UgUnVudGltZUVycm9yKGYiRGlyZWN0IEhUVFBTIGNvbm5lY3Rpb24gZmFpbGVkOiB7ZX0iKQoKICAgICAgICBhc3luYyBkZWYgZmFjdG9yeSgpOgogICAgICAgICAgICByZXR1cm4gYXdhaXQgc2VsZi5fZXhlY3V0ZV93aXRoX3JldHJ5KG1ldGhvZCwgdXJsLCBwYXJhbXMsIGhlYWRlcnMsIHRpbWVvdXQ9dGltZW91dCwgKiprd2FyZ3MpCiAgICAgICAgcmV0dXJuIGF3YWl0IHNlbGYuZGVkdXAuZXhlY3V0ZShtZXRob2QsIHVybCwgcGFyYW1zLCAiaHR0cC8xLjEiLCBmYWN0b3J5KQoKICAgIGFzeW5jIGRlZiBfZXhlY3V0ZV93aXRoX3JldHJ5KHNlbGYsIG1ldGhvZCwgdXJsLCBwYXJhbXMsIGhlYWRlcnMsIHRpbWVvdXQ9MzAsICoqa3dhcmdzKToKICAgICAgICBkb21haW4gPSB1cmxwYXJzZSh1cmwpLm5ldGxvYwogICAgICAgIGJyZWFrZXIgPSBzZWxmLmNpcmN1aXRfYnJlYWtlcnMuZ2V0KGRvbWFpbikKCiAgICAgICAgaWYgYnJlYWtlci5vcGVuZWQ6CiAgICAgICAgICAgIHJhaXNlIFJ1bnRpbWVFcnJvcihmIkNpcmN1aXQgYnJlYWtlciBvcGVuIGZvciB7ZG9tYWlufSIpCgogICAgICAgICMgdjQuMzogUnVuIHN0YXJ0IGhvb2tzCiAgICAgICAgYXdhaXQgc2VsZi5wbHVnaW5fbWFuYWdlci5ydW5faG9va3MoInN0YXJ0IiwgbWV0aG9kPW1ldGhvZCwgdXJsPXVybCwgZG9tYWluPWRvbWFpbikKCiAgICAgICAgZm9yIGF0dGVtcHQgaW4gcmFuZ2Uoc2VsZi5tYXhfcmV0cmllcyk6CiAgICAgICAgICAgIHN0YXJ0ID0gdGltZS50aW1lKCkKICAgICAgICAgICAgcHJveHlfdXJsID0gTm9uZQogICAgICAgICAgICB0cnk6CiAgICAgICAgICAgICAgICAjIFNlbGVjdCBwcm94eSAodmlhIEFCIHRlc3QgLyBNTCAvIHNjb3JlcikKICAgICAgICAgICAgICAgIHByb3h5X3VybCA9IGF3YWl0IHNlbGYuX2dldF9iZXN0X3Byb3h5KGRvbWFpbikKICAgICAgICAgICAgICAgICMgTm90ZTogcHJveHlfdXJsIGlzIE5PVCBhZGRlZCB0byBrd2FyZ3MgdG8gYXZvaWQgbGVha2luZyBpdCB0byBodHRweC9haW9odHRwCgogICAgICAgICAgICAgICAgIyB2NC4zOiBSdW4gcmVxdWVzdCBob29rcwogICAgICAgICAgICAgICAgYXdhaXQgc2VsZi5wbHVnaW5fbWFuYWdlci5ydW5faG9va3MoInJlcXVlc3QiLCBtZXRob2Q9bWV0aG9kLCB1cmw9dXJsLAogICAgICAgICAgICAgICAgICAgIHByb3h5PXByb3h5X3VybCwgYXR0ZW1wdD1hdHRlbXB0KQoKICAgICAgICAgICAgICAgIHJlc3BvbnNlID0gYXdhaXQgc2VsZi5fZXhlY3V0ZV93aXRoX3Jlc2lsaWVudF9jbGllbnQobWV0aG9kLCB1cmwsIHBhcmFtcywgaGVhZGVycywgKiprd2FyZ3MpCgogICAgICAgICAgICAgICAgaWYgc2VsZi51c2VfY3VybF9jZmZpOgogICAgICAgICAgICAgICAgICAgIHJlc3BfY29udGVudCA9IHJlc3BvbnNlLmNvbnRlbnQKICAgICAgICAgICAgICAgICAgICBzdGF0dXMgPSByZXNwb25zZS5zdGF0dXNfY29kZQogICAgICAgICAgICAgICAgICAgIHJlc3BfaGVhZGVycyA9IGRpY3QocmVzcG9uc2UuaGVhZGVycykKICAgICAgICAgICAgICAgIGVsc2U6CiAgICAgICAgICAgICAgICAgICAgcmVzcF9jb250ZW50ID0gYXdhaXQgcmVzcG9uc2UuYXJlYWQoKQogICAgICAgICAgICAgICAgICAgIHN0YXR1cyA9IHJlc3BvbnNlLnN0YXR1c19jb2RlCiAgICAgICAgICAgICAgICAgICAgcmVzcF9oZWFkZXJzID0gZGljdChyZXNwb25zZS5oZWFkZXJzKQoKICAgICAgICAgICAgICAgIGxhdGVuY3kgPSAodGltZS50aW1lKCkgLSBzdGFydCkgKiAxMDAwCgogICAgICAgICAgICAgICAgY2FjaGVkX3Jlc3BvbnNlID0gQ2FjaGVkUmVzcG9uc2UoCiAgICAgICAgICAgICAgICAgICAgc3RhdHVzPXN0YXR1cywKICAgICAgICAgICAgICAgICAgICBjb250ZW50PXJlc3BfY29udGVudCwKICAgICAgICAgICAgICAgICAgICBoZWFkZXJzPXJlc3BfaGVhZGVycywKICAgICAgICAgICAgICAgICAgICB0aW1lc3RhbXA9dGltZS50aW1lKCksCiAgICAgICAgICAgICAgICAgICAgdHRsPXNlbGYuY2FjaGUudHRsCiAgICAgICAgICAgICAgICApCgogICAgICAgICAgICAgICAgIyBVcGRhdGUgc2NvcmVyCiAgICAgICAgICAgICAgICBpZiBwcm94eV91cmw6CiAgICAgICAgICAgICAgICAgICAgc2VsZi5zY29yZXIudXBkYXRlKHByb3h5X3VybCwgc3VjY2Vzcz1UcnVlLCBsYXRlbmN5X21zPWxhdGVuY3kpCgogICAgICAgICAgICAgICAgIyB2NC40OiBVcGRhdGUgTUwgcHJlZGljdG9yIHdpdGggY29udGV4dCArIFByb3h5RW50cnkKICAgICAgICAgICAgICAgIGlmIHNlbGYuZW5hYmxlX21sIGFuZCBzZWxmLm1sX3ByZWRpY3RvciBhbmQgcHJveHlfdXJsOgogICAgICAgICAgICAgICAgICAgIGNvbnRleHQgPSB7InVybCI6IHVybCwgIm1ldGhvZCI6IG1ldGhvZCwgImRvbWFpbiI6IGRvbWFpbn0KICAgICAgICAgICAgICAgICAgICBlbnRyeSA9IHNlbGYucG9vbF9tYW5hZ2VyLmdldF9lbnRyeShwcm94eV91cmwpCiAgICAgICAgICAgICAgICAgICAgYXdhaXQgc2VsZi5tbF9wcmVkaWN0b3IudXBkYXRlKHByb3h5X3VybCwgbGF0ZW5jeSwgVHJ1ZSwgY29udGV4dCwgc2VsZi5zY29yZXIsIGVudHJ5KQoKICAgICAgICAgICAgICAgIGF3YWl0IHNlbGYubGltaXRlci5hZGp1c3QoZG9tYWluLCBzdGF0dXMpCgogICAgICAgICAgICAgICAgYnJlYWtlci5yZXNldCgpCgogICAgICAgICAgICAgICAgIyB2NC4zOiBSZWNvcmQgQUIgdGVzdCByZXN1bHQKICAgICAgICAgICAgICAgIGlmIHNlbGYuZW5hYmxlX2FiX3Rlc3QgYW5kIHNlbGYuYWJfdGVzdDoKICAgICAgICAgICAgICAgICAgICBzdHJhdGVneSA9IHNlbGYuYWJfdGVzdC5nZXRfc3RyYXRlZ3koZG9tYWluKQogICAgICAgICAgICAgICAgICAgIGF3YWl0IHNlbGYuYWJfdGVzdC5yZWNvcmRfcmVzdWx0KGRvbWFpbiwgc3RyYXRlZ3ksIHN1Y2Nlc3M9VHJ1ZSkKCiAgICAgICAgICAgICAgICAjIFJldHJ5LUFmdGVyIGhhbmRsaW5nCiAgICAgICAgICAgICAgICBpZiBzdGF0dXMgaW4gKDQyOSwgNTAzKSBhbmQgJ3JldHJ5LWFmdGVyJyBpbiByZXNwX2hlYWRlcnM6CiAgICAgICAgICAgICAgICAgICAgcmV0cnlfYWZ0ZXIgPSByZXNwX2hlYWRlcnNbJ3JldHJ5LWFmdGVyJ10KICAgICAgICAgICAgICAgICAgICB0cnk6CiAgICAgICAgICAgICAgICAgICAgICAgIHNlY29uZHMgPSBpbnQocmV0cnlfYWZ0ZXIpCiAgICAgICAgICAgICAgICAgICAgZXhjZXB0IFZhbHVlRXJyb3I6CiAgICAgICAgICAgICAgICAgICAgICAgIHRyeToKICAgICAgICAgICAgICAgICAgICAgICAgICAgIHJldHJ5X2RhdGUgPSBlbWFpbC51dGlscy5wYXJzZWRhdGVfdG9fZGF0ZXRpbWUocmV0cnlfYWZ0ZXIpCiAgICAgICAgICAgICAgICAgICAgICAgICAgICBzZWNvbmRzID0gbWF4KDAsIChyZXRyeV9kYXRlIC0gZGF0ZXRpbWUuZGF0ZXRpbWUubm93KGRhdGV0aW1lLnRpbWV6b25lLnV0YykpLnRvdGFsX3NlY29uZHMoKSkKICAgICAgICAgICAgICAgICAgICAgICAgZXhjZXB0IEV4Y2VwdGlvbjoKICAgICAgICAgICAgICAgICAgICAgICAgICAgIHNlY29uZHMgPSA1CiAgICAgICAgICAgICAgICAgICAgbG9nZ2VyLmluZm8oZiJSZXRyeS1BZnRlcjogc2xlZXBpbmcge3NlY29uZHN9cyBiZWZvcmUgcmV0cnkiKQogICAgICAgICAgICAgICAgICAgIGF3YWl0IGFzeW5jaW8uc2xlZXAoc2Vjb25kcykKICAgICAgICAgICAgICAgICAgICBjb250aW51ZQoKICAgICAgICAgICAgICAgICMgdjQuMzogUnVuIHJlc3BvbnNlIGhvb2tzCiAgICAgICAgICAgICAgICBhd2FpdCBzZWxmLnBsdWdpbl9tYW5hZ2VyLnJ1bl9ob29rcygicmVzcG9uc2UiLCByZXNwb25zZT1jYWNoZWRfcmVzcG9uc2UpCgogICAgICAgICAgICAgICAgYXdhaXQgc2VsZi5jYWNoZS5zZXQobWV0aG9kLCB1cmwsIGNhY2hlZF9yZXNwb25zZSwgcGFyYW1zKQogICAgICAgICAgICAgICAgYXdhaXQgc2VsZi5fc2F2ZV9zdGF0ZSgpCgogICAgICAgICAgICAgICAgIyB2NC4zOiBSdW4gY29tcGxldGUgaG9va3MKICAgICAgICAgICAgICAgIGF3YWl0IHNlbGYucGx1Z2luX21hbmFnZXIucnVuX2hvb2tzKCJjb21wbGV0ZSIsIHVybD11cmwsIHN0YXR1cz1zdGF0dXMsIGxhdGVuY3lfbXM9bGF0ZW5jeSkKICAgICAgICAgICAgICAgIHJldHVybiBjYWNoZWRfcmVzcG9uc2UKCiAgICAgICAgICAgIGV4Y2VwdCBFeGNlcHRpb24gYXMgZToKICAgICAgICAgICAgICAgIGlmIHByb3h5X3VybDoKICAgICAgICAgICAgICAgICAgICBzZWxmLnNjb3Jlci51cGRhdGUocHJveHlfdXJsLCBzdWNjZXNzPUZhbHNlKQogICAgICAgICAgICAgICAgICAgICMgdjQuMzogVXBkYXRlIE1MIHByZWRpY3RvciBvbiBmYWlsdXJlIHdpdGggUHJveHlFbnRyeQogICAgICAgICAgICAgICAgICAgIGlmIHNlbGYuZW5hYmxlX21sIGFuZCBzZWxmLm1sX3ByZWRpY3RvcjoKICAgICAgICAgICAgICAgICAgICAgICAgZW50cnkgPSBzZWxmLnBvb2xfbWFuYWdlci5nZXRfZW50cnkocHJveHlfdXJsKQogICAgICAgICAgICAgICAgICAgICAgICBhd2FpdCBzZWxmLm1sX3ByZWRpY3Rvci51cGRhdGUocHJveHlfdXJsLCA5OTk5LjAsIHN1Y2Nlc3M9RmFsc2UsIHByb3h5X2VudHJ5PWVudHJ5KQogICAgICAgICAgICAgICAgYXdhaXQgc2VsZi5saW1pdGVyLmFkanVzdChkb21haW4sIDUwMCkKCiAgICAgICAgICAgICAgICAjIHY0LjM6IFJlY29yZCBBQiB0ZXN0IGZhaWx1cmUKICAgICAgICAgICAgICAgIGlmIHNlbGYuZW5hYmxlX2FiX3Rlc3QgYW5kIHNlbGYuYWJfdGVzdDoKICAgICAgICAgICAgICAgICAgICBzdHJhdGVneSA9IHNlbGYuYWJfdGVzdC5nZXRfc3RyYXRlZ3koZG9tYWluKQogICAgICAgICAgICAgICAgICAgIGF3YWl0IHNlbGYuYWJfdGVzdC5yZWNvcmRfcmVzdWx0KGRvbWFpbiwgc3RyYXRlZ3ksIHN1Y2Nlc3M9RmFsc2UpCgogICAgICAgICAgICAgICAgIyB2NC4zOiBSdW4gZXJyb3IgaG9va3MKICAgICAgICAgICAgICAgIGF3YWl0IHNlbGYucGx1Z2luX21hbmFnZXIucnVuX2hvb2tzKCJlcnJvciIsIGVycm9yPWUsIGF0dGVtcHQ9YXR0ZW1wdCwgdXJsPXVybCkKICAgICAgICAgICAgICAgIGxvZ2dlci53YXJuaW5nKGYiUmVxdWVzdCBmYWlsZWQgKGF0dGVtcHQge2F0dGVtcHQrMX0ve3NlbGYubWF4X3JldHJpZXN9KToge2V9IikKICAgICAgICAgICAgICAgIGNvbnRpbnVlCgogICAgICAgICMgRGlyZWN0IGZhbGxiYWNrIC0gdXNlIGFpb2h0dHAgdG8gYXZvaWQgY3VybF9jZmZpIFRMUyBpc3N1ZXMKICAgICAgICBsb2dnZXIuaW5mbygiQWxsIHByb3hpZXMgZXhoYXVzdGVkLCBhdHRlbXB0aW5nIGRpcmVjdCBjb25uZWN0aW9uIHZpYSBhaW9odHRwLi4uIikKICAgICAgICB0cnk6CiAgICAgICAgICAgIHJlcV90aW1lb3V0ID0gYWlvaHR0cC5DbGllbnRUaW1lb3V0KHRvdGFsPXRpbWVvdXQpCiAgICAgICAgICAgIGFzeW5jIHdpdGggc2VsZi5fYWlvaHR0cF9kaXJlY3Rfc2Vzc2lvbi5yZXF1ZXN0KG1ldGhvZCwgdXJsLCBwYXJhbXM9cGFyYW1zLCBoZWFkZXJzPWhlYWRlcnMsIHRpbWVvdXQ9cmVxX3RpbWVvdXQsICoqa3dhcmdzKSBhcyByZXNwOgogICAgICAgICAgICAgICAgY29udGVudCA9IGF3YWl0IHJlc3AucmVhZCgpCiAgICAgICAgICAgICAgICBzdGF0dXMgPSByZXNwLnN0YXR1cwogICAgICAgICAgICAgICAgcmVzcF9oZWFkZXJzID0gZGljdChyZXNwLmhlYWRlcnMpCiAgICAgICAgICAgIGNhY2hlZF9yZXNwb25zZSA9IENhY2hlZFJlc3BvbnNlKAogICAgICAgICAgICAgICAgc3RhdHVzPXN0YXR1cywKICAgICAgICAgICAgICAgIGNvbnRlbnQ9Y29udGVudCwKICAgICAgICAgICAgICAgIGhlYWRlcnM9cmVzcF9oZWFkZXJzLAogICAgICAgICAgICAgICAgdGltZXN0YW1wPXRpbWUudGltZSgpLAogICAgICAgICAgICAgICAgdHRsPXNlbGYuY2FjaGUudHRsCiAgICAgICAgICAgICkKICAgICAgICAgICAgYXdhaXQgc2VsZi5jYWNoZS5zZXQobWV0aG9kLCB1cmwsIGNhY2hlZF9yZXNwb25zZSwgcGFyYW1zKQogICAgICAgICAgICByZXR1cm4gY2FjaGVkX3Jlc3BvbnNlCiAgICAgICAgZXhjZXB0IEV4Y2VwdGlvbiBhcyBlOgogICAgICAgICAgICByYWlzZSBSdW50aW1lRXJyb3IoZiJEaXJlY3QgY29ubmVjdGlvbiBhbHNvIGZhaWxlZDoge2V9IikKCiAgICBhc3luYyBkZWYgZ2V0X3N0YXRzKHNlbGYpOgogICAgICAgIHRvdGFsID0gbGVuKHNlbGYucG9vbF9tYW5hZ2VyLl9wcm94aWVzKQogICAgICAgIGhlYWx0aHkgPSBzdW0oMSBmb3IgcCBpbiBzZWxmLnBvb2xfbWFuYWdlci5fcHJveGllcyBpZiBwLmhlYWx0aHkgYW5kIG5vdCBwLmlzX2Jhbm5lZCgpKQogICAgICAgIHNjb3JlcyA9IHNlbGYuc2NvcmVyLmdldF9hbGxfc2NvcmVzKCkKICAgICAgICByYXRlcyA9IGF3YWl0IHNlbGYubGltaXRlci5nZXRfYWxsX3JhdGVzKCkKICAgICAgICBzdGF0cyA9IHsKICAgICAgICAgICAgInByb3hpZXNfdG90YWwiOiB0b3RhbCwKICAgICAgICAgICAgInByb3hpZXNfaGVhbHRoeSI6IGhlYWx0aHksCiAgICAgICAgICAgICJzY29yZXMiOiBzY29yZXMsCiAgICAgICAgICAgICJyYXRlcyI6IHJhdGVzLAogICAgICAgICAgICAidmVyc2lvbiI6IHNlbGYudmVyc2lvbiBpZiBoYXNhdHRyKHNlbGYsICd2ZXJzaW9uJykgZWxzZSAiNC41IiwKICAgICAgICB9CiAgICAgICAgaWYgc2VsZi5lbmFibGVfYWJfdGVzdCBhbmQgc2VsZi5hYl90ZXN0OgogICAgICAgICAgICBzdGF0c1siYWJfdGVzdCJdID0gc2VsZi5hYl90ZXN0LmdldF9zdGF0cygpCiAgICAgICAgaWYgc2VsZi5lbmFibGVfbWwgYW5kIHNlbGYubWxfcHJlZGljdG9yOgogICAgICAgICAgICBzdGF0c1sibWxfdHJhaW5lZCJdID0gc2VsZi5tbF9wcmVkaWN0b3IuaXNfdHJhaW5lZCgpCiAgICAgICAgICAgIGlmIGhhc2F0dHIoc2VsZi5tbF9wcmVkaWN0b3IsICdnZXRfaW5mbycpOgogICAgICAgICAgICAgICAgc3RhdHNbIm1sX21vZGVsIl0gPSBzZWxmLm1sX3ByZWRpY3Rvci5nZXRfaW5mbygpCiAgICAgICAgaWYgc2VsZi5wbHVnaW5fbG9hZGVyOgogICAgICAgICAgICBzdGF0c1sicGx1Z2lucyJdID0gc2VsZi5wbHVnaW5fbG9hZGVyLmdldF9zdGF0cygpCiAgICAgICAgcmV0dXJuIHN0YXRzCgojIOKUgOKUgOKUgCBNYWluICh0ZXN0KSDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIAKYXN5bmMgZGVmIG1haW4oKToKICAgIHByaW50KCLwn6aJIE9XTC1BR0VOVCB2NC41IChBZHZhbmNlZCBNTCArIFNlbGYtSGVhbGluZyBQbHVnaW5zKSIpCiAgICBwcmludCgiPSIgKiA1MCkKICAgIGFzeW5jIHdpdGggUmVzaWxpZW50Q2xpZW50KHVzZV9jdXJsX2NmZmk9VHJ1ZSwgY291bnRyaWVzPVsiVVMiLCAiR0IiXSwgdXNlX3JlZGlzPUZhbHNlKSBhcyBjbGllbnQ6CiAgICAgICAgc3RhdHMgPSBhd2FpdCBjbGllbnQuZ2V0X3N0YXRzKCkKICAgICAgICBwcmludChmIlByb3h5IHBvb2w6IHtzdGF0c1sncHJveGllc190b3RhbCddfSB0b3RhbCwge3N0YXRzWydwcm94aWVzX2hlYWx0aHknXX0gaGVhbHRoeSIpCiAgICAgICAgcHJpbnQoZiJRdWFsaXR5IHNjb3Jlczoge3N0YXRzWydzY29yZXMnXX0iKQogICAgICAgIHByaW50KGYiQWRhcHRpdmUgcmF0ZXM6IHtzdGF0c1sncmF0ZXMnXX0iKQogICAgICAgIHByaW50KCkKICAgICAgICB0cnk6CiAgICAgICAgICAgIHJlc3AgPSBhd2FpdCBjbGllbnQucmVxdWVzdCgiR0VUIiwgImh0dHBzOi8vYXBpLmdpdGh1Yi5jb20vdXNlcnMvb2N0b2NhdCIpCiAgICAgICAgICAgIHByaW50KGYi4pyFIFN1Y2Nlc3MhIFN0YXR1czoge3Jlc3Auc3RhdHVzfSwgY29udGVudCBsZW5ndGg6IHtsZW4ocmVzcC5jb250ZW50KX0gYnl0ZXMiKQogICAgICAgICAgICBpZiByZXNwLnN0YXR1cyA9PSAyMDA6CiAgICAgICAgICAgICAgICBkYXRhID0ganNvbi5sb2FkcyhyZXNwLmNvbnRlbnQpCiAgICAgICAgICAgICAgICBwcmludChmIiAgIFVzZXI6IHtkYXRhLmdldCgnbG9naW4nKX0gLSB7ZGF0YS5nZXQoJ25hbWUnKX0iKQogICAgICAgIGV4Y2VwdCBFeGNlcHRpb24gYXMgZToKICAgICAgICAgICAgcHJpbnQoZiLinYwgQWxsIGF0dGVtcHRzIGZhaWxlZDoge2V9IikKICAgICAgICBwcmludCgpCiAgICAgICAgcHJpbnQoIvCfpokgT1dMLUFHRU5UIHY0LjMgcnVubmluZyBvbiBodHRwOi8vMTI3LjAuMC4xOjYwMDAwIikKICAgICAgICBwcmludCgiUHJlc3MgQ3RybCtDIHRvIHN0b3AuIikKCmlmIF9fbmFtZV9fID09ICJfX21haW5fXyI6CiAgICBhc3luY2lvLnJ1bihtYWluKCkpCg=="
_EMBED_ml_models_py="IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiIK8J+miSBPV0wtQUdFTlQgdjQuNCDigJQgQWR2YW5jZWQgTUwgUHJlZGljdG9yCk11bHRpcGxlIG1vZGVsIGJhY2tlbmRzIChMb2dpc3RpYywgWEdCb29zdCwgTUxQKSB3aXRoIGNyb3NzLXZhbGlkYXRpb24KbW9kZWwgc2VsZWN0aW9uIGFuZCByaWNoIGZlYXR1cmUgZW5naW5lZXJpbmcuCiIiIgoKaW1wb3J0IGFzeW5jaW8KaW1wb3J0IHRpbWUKaW1wb3J0IGxvZ2dpbmcKaW1wb3J0IG9zCmZyb20gdHlwaW5nIGltcG9ydCBPcHRpb25hbCwgRGljdCwgQW55LCBMaXN0CmZyb20gcGF0aGxpYiBpbXBvcnQgUGF0aAoKaW1wb3J0IG51bXB5IGFzIG5wCmZyb20gc2tsZWFybi5saW5lYXJfbW9kZWwgaW1wb3J0IExvZ2lzdGljUmVncmVzc2lvbgpmcm9tIHNrbGVhcm4ubmV1cmFsX25ldHdvcmsgaW1wb3J0IE1MUENsYXNzaWZpZXIKZnJvbSBza2xlYXJuLnByZXByb2Nlc3NpbmcgaW1wb3J0IFN0YW5kYXJkU2NhbGVyCmZyb20gc2tsZWFybi5tb2RlbF9zZWxlY3Rpb24gaW1wb3J0IGNyb3NzX3ZhbF9zY29yZQppbXBvcnQgam9ibGliCgp0cnk6CiAgICBpbXBvcnQgeGdib29zdCBhcyB4Z2IKICAgIFhHQl9BVkFJTEFCTEUgPSBUcnVlCmV4Y2VwdCBJbXBvcnRFcnJvcjoKICAgIFhHQl9BVkFJTEFCTEUgPSBGYWxzZQoKbG9nZ2VyID0gbG9nZ2luZy5nZXRMb2dnZXIoIm93bC1hZ2VudC5tbCIpCgojIOKUgOKUgOKUgCBNb2RlbCBjYWNoZSBkaXJlY3Rvcnkg4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSACk1PREVMX0RJUiA9IFBhdGguaG9tZSgpIC8gIi5vd2wtYWdlbnQiIC8gImNhY2hlIiAvICJtb2RlbHMiCk1PREVMX0RJUi5ta2RpcihwYXJlbnRzPVRydWUsIGV4aXN0X29rPVRydWUpCgoKY2xhc3MgQWR2YW5jZWRNTFByZWRpY3RvcjoKICAgICIiIkFkdmFuY2VkIE1MIHByZWRpY3RvciB3aXRoIG11bHRpcGxlIGJhY2tlbmRzIGFuZCByaWNoIGZlYXR1cmVzLgoKICAgIFN1cHBvcnRzOiBMb2dpc3RpYyBSZWdyZXNzaW9uLCBYR0Jvb3N0LCBNTFAgKG5ldXJhbCBuZXR3b3JrKS4KICAgIEF1dG9tYXRpY2FsbHkgc2VsZWN0cyB0aGUgYmVzdCBtb2RlbCB2aWEgY3Jvc3MtdmFsaWRhdGlvbi4KICAgICIiIgoKICAgIGRlZiBfX2luaXRfXyhzZWxmLCBtb2RlbF90eXBlOiBzdHIgPSAiYXV0byIsIG1heF9zYW1wbGVzOiBpbnQgPSAyMDAwLAogICAgICAgICAgICAgICAgIHJldHJhaW5faW50ZXJ2YWw6IGludCA9IDUwKToKICAgICAgICAiIiIKICAgICAgICBBcmdzOgogICAgICAgICAgICBtb2RlbF90eXBlOiAiYXV0byIsICJsb2dpc3RpYyIsICJ4Z2Jvb3N0IiwgIm1scCIKICAgICAgICAgICAgbWF4X3NhbXBsZXM6IE1heCB0cmFpbmluZyBzYW1wbGVzIHRvIGtlZXAKICAgICAgICAgICAgcmV0cmFpbl9pbnRlcnZhbDogUmV0cmFpbiBldmVyeSBOIG5ldyBzYW1wbGVzCiAgICAgICAgIiIiCiAgICAgICAgc2VsZi5tb2RlbF90eXBlID0gbW9kZWxfdHlwZQogICAgICAgIHNlbGYubWF4X3NhbXBsZXMgPSBtYXhfc2FtcGxlcwogICAgICAgIHNlbGYucmV0cmFpbl9pbnRlcnZhbCA9IHJldHJhaW5faW50ZXJ2YWwKICAgICAgICBzZWxmLl9mZWF0dXJlczogTGlzdFtMaXN0W2Zsb2F0XV0gPSBbXQogICAgICAgIHNlbGYuX2xhYmVsczogTGlzdFtpbnRdID0gW10KICAgICAgICBzZWxmLl9tb2RlbCA9IE5vbmUKICAgICAgICBzZWxmLl9zY2FsZXIgPSBTdGFuZGFyZFNjYWxlcigpCiAgICAgICAgc2VsZi5faXNfdHJhaW5lZCA9IEZhbHNlCiAgICAgICAgc2VsZi5fbW9kZWxfbmFtZTogT3B0aW9uYWxbc3RyXSA9IE5vbmUKICAgICAgICBzZWxmLl9jdl9zY29yZTogZmxvYXQgPSAwLjAKICAgICAgICBzZWxmLl9zYW1wbGVzX3NpbmNlX3RyYWluOiBpbnQgPSAwCiAgICAgICAgc2VsZi5fbG9jayA9IGFzeW5jaW8uTG9jaygpCiAgICAgICAgc2VsZi5fdHJhaW5pbmc6IGJvb2wgPSBGYWxzZQoKICAgICAgICAjIEZlYXR1cmUgbmFtZXMgZm9yIGxvZ2dpbmcgKG11c3QgbWF0Y2ggX2V4dHJhY3RfZmVhdHVyZXMgb3V0cHV0IGV4YWN0bHkpCiAgICAgICAgc2VsZi5mZWF0dXJlX25hbWVzID0gWwogICAgICAgICAgICAiZmFpbF9jb3VudCIsICJoZWFsdGh5IiwgImF2Z19sYXRlbmN5IiwKICAgICAgICAgICAgInRpbWVfc2luY2Vfc3VjY2VzcyIsICJpc19iYW5uZWQiLAogICAgICAgICAgICAicmVjZW50X3N1Y2Nlc3NfcmF0ZSIsCiAgICAgICAgICAgICJwcm90b2NvbCIsICJjb3VudHJ5X2hhc2giLCAidXJsX2xlbmd0aCIsCiAgICAgICAgICAgICJpc19wb3N0IiwgImhvdXJfb2ZfZGF5IiwgImRheV9vZl93ZWVrIgogICAgICAgIF0KCiAgICAgICAgIyBMb2FkIHBlcnNpc3RlZCBtb2RlbCBpZiBhdmFpbGFibGUKICAgICAgICBzZWxmLl9sb2FkX21vZGVsKCkKCiAgICBkZWYgaXNfdHJhaW5lZChzZWxmKSAtPiBib29sOgogICAgICAgIHJldHVybiBzZWxmLl9pc190cmFpbmVkCgogICAgQHByb3BlcnR5CiAgICBkZWYgbW9kZWxfbmFtZShzZWxmKSAtPiBPcHRpb25hbFtzdHJdOgogICAgICAgIHJldHVybiBzZWxmLl9tb2RlbF9uYW1lCgogICAgQHByb3BlcnR5CiAgICBkZWYgY3Zfc2NvcmUoc2VsZikgLT4gZmxvYXQ6CiAgICAgICAgcmV0dXJuIHNlbGYuX2N2X3Njb3JlCgogICAgZGVmIF9leHRyYWN0X2ZlYXR1cmVzKHNlbGYsIHByb3h5X3VybDogc3RyLCBsYXRlbmN5X21zOiBmbG9hdCwKICAgICAgICAgICAgICAgICAgICAgICAgICByZXF1ZXN0X2NvbnRleHQ6IE9wdGlvbmFsW0RpY3RdID0gTm9uZSwKICAgICAgICAgICAgICAgICAgICAgICAgICBwcm94eV9lbnRyeT1Ob25lKSAtPiBMaXN0W2Zsb2F0XToKICAgICAgICAiIiJFeHRyYWN0IHJpY2ggZmVhdHVyZSB2ZWN0b3IgZm9yIHByb3h5IHN1Y2Nlc3MgcHJlZGljdGlvbi4KCiAgICAgICAgQXJnczoKICAgICAgICAgICAgcHJveHlfdXJsOiBQcm94eSBVUkwgc3RyaW5nCiAgICAgICAgICAgIGxhdGVuY3lfbXM6IFJlcXVlc3QgbGF0ZW5jeSBpbiBtaWxsaXNlY29uZHMKICAgICAgICAgICAgcmVxdWVzdF9jb250ZXh0OiBPcHRpb25hbCBkaWN0IHdpdGggdXJsLCBtZXRob2QsIGRvbWFpbiwgY291bnRyeQogICAgICAgICAgICBwcm94eV9lbnRyeTogT3B0aW9uYWwgUHJveHlFbnRyeSBvYmplY3QgZm9yIHJlYWwgcHJveHktbGV2ZWwgZGF0YQogICAgICAgICAgICAgICAgKGZhaWxfY291bnQsIGhlYWx0aHksIGxhc3RfY2hlY2ssIGJhbl91bnRpbCkKICAgICAgICAiIiIKICAgICAgICBjdHggPSByZXF1ZXN0X2NvbnRleHQgb3Ige30KICAgICAgICBmID0gW10KCiAgICAgICAgIyAtLS0gUHJveHktbGV2ZWwgZmVhdHVyZXMgKGZyb20gUHJveHlFbnRyeSB3aGVuIGF2YWlsYWJsZSkgLS0tCiAgICAgICAgaWYgcHJveHlfZW50cnkgaXMgbm90IE5vbmU6CiAgICAgICAgICAgICMgRmFpbCBjb3VudCAoY2FwcGVkIGF0IDEwMCkKICAgICAgICAgICAgZi5hcHBlbmQobWluKGdldGF0dHIocHJveHlfZW50cnksICdmYWlsX2NvdW50JywgMCksIDEwMCkgLyAxMDAuMCkKCiAgICAgICAgICAgICMgSGVhbHRoeSBmbGFnICgxLjAgaWYgaGVhbHRoeSwgMC4wIGlmIG5vdCkKICAgICAgICAgICAgZi5hcHBlbmQoMS4wIGlmIGdldGF0dHIocHJveHlfZW50cnksICdoZWFsdGh5JywgVHJ1ZSkgZWxzZSAwLjApCgogICAgICAgICAgICAjIEF2ZXJhZ2UgbGF0ZW5jeSBmcm9tIHNjb3JlciBoaXN0b3J5CiAgICAgICAgICAgIGF2Z19sYXQgPSBjdHguZ2V0KCJhdmdfbGF0ZW5jeSIsIGxhdGVuY3lfbXMpCiAgICAgICAgICAgIGYuYXBwZW5kKGF2Z19sYXQgLyAxMDAwLjApCgogICAgICAgICAgICAjIFRpbWUgc2luY2UgbGFzdCBzdWNjZXNzIChzZWNvbmRzIHNpbmNlIGxhc3RfY2hlY2ssIGNhcHBlZCBhdCAzMDApCiAgICAgICAgICAgIGxhc3RfY2hlY2sgPSBnZXRhdHRyKHByb3h5X2VudHJ5LCAnbGFzdF9jaGVjaycsIDAuMCkKICAgICAgICAgICAgdGltZV9zaW5jZSA9IG1pbih0aW1lLnRpbWUoKSAtIGxhc3RfY2hlY2ssIDMwMC4wKSBpZiBsYXN0X2NoZWNrID4gMCBlbHNlIDYwLjAKICAgICAgICAgICAgZi5hcHBlbmQodGltZV9zaW5jZSAvIDMwMC4wKQoKICAgICAgICAgICAgIyBJcyBjdXJyZW50bHkgYmFubmVkCiAgICAgICAgICAgIGYuYXBwZW5kKDEuMCBpZiBnZXRhdHRyKHByb3h5X2VudHJ5LCAnYmFuX3VudGlsJywgMC4wKSA+IHRpbWUudGltZSgpIGVsc2UgMC4wKQogICAgICAgIGVsc2U6CiAgICAgICAgICAgICMgRmFsbGJhY2sgZGVmYXVsdHMgd2hlbiBubyBQcm94eUVudHJ5IGF2YWlsYWJsZQogICAgICAgICAgICBmLmFwcGVuZCgwLjApICAgIyBmYWlsX2NvdW50CiAgICAgICAgICAgIGYuYXBwZW5kKDEuMCkgICAjIGhlYWx0aHkgKGFzc3VtZSB5ZXMpCiAgICAgICAgICAgIGYuYXBwZW5kKGxhdGVuY3lfbXMgLyAxMDAwLjApICAjIGF2Z19sYXRlbmN5CiAgICAgICAgICAgIGYuYXBwZW5kKDYwLjAgLyAzMDAuMCkgICMgdGltZV9zaW5jZV9zdWNjZXNzCiAgICAgICAgICAgIGYuYXBwZW5kKDAuMCkgICAjIGlzX2Jhbm5lZAoKICAgICAgICAjIFJlY2VudCBzdWNjZXNzIHJhdGUgKGZyb20gc2NvcmVyKQogICAgICAgIHJlY2VudF9zdWNjZXNzX3JhdGUgPSBjdHguZ2V0KCJzdWNjZXNzX3JhdGUiLCAwLjUpCiAgICAgICAgZi5hcHBlbmQocmVjZW50X3N1Y2Nlc3NfcmF0ZSkKCiAgICAgICAgIyAtLS0gUHJvdG9jb2wgZmVhdHVyZSAtLS0KICAgICAgICBwcm90b2NvbCA9IHByb3h5X3VybC5zcGxpdCgiOi8vIilbMF0gaWYgIjovLyIgaW4gcHJveHlfdXJsIGVsc2UgImh0dHAiCiAgICAgICAgcHJvdG9fbWFwID0geyJodHRwIjogMCwgImh0dHBzIjogMSwgInNvY2tzNCI6IDIsICJzb2NrczUiOiAzfQogICAgICAgIGYuYXBwZW5kKHByb3RvX21hcC5nZXQocHJvdG9jb2wsIDApIC8gMy4wKQoKICAgICAgICAjIC0tLSBDb3VudHJ5IGZlYXR1cmUgKGhhc2gtYmFzZWQpIC0tLQogICAgICAgIGNvdW50cnkgPSBjdHguZ2V0KCJjb3VudHJ5IiwgIlVTIikKICAgICAgICBmLmFwcGVuZCgoaGFzaChjb3VudHJ5KSAlIDEwMCkgLyAxMDAuMCkKCiAgICAgICAgIyAtLS0gUmVxdWVzdC1sZXZlbCBmZWF0dXJlcyAtLS0KICAgICAgICB1cmwgPSBjdHguZ2V0KCJ1cmwiLCAiIikKICAgICAgICBmLmFwcGVuZChtaW4obGVuKHVybCksIDUwMCkgLyA1MDAuMCkgICMgVVJMIGxlbmd0aCwgY2FwcGVkCgogICAgICAgIG1ldGhvZCA9IGN0eC5nZXQoIm1ldGhvZCIsICJHRVQiKQogICAgICAgIGYuYXBwZW5kKDEuMCBpZiBtZXRob2QgPT0gIlBPU1QiIGVsc2UgMC4wKQoKICAgICAgICAjIC0tLSBUaW1lIGZlYXR1cmVzIC0tLQogICAgICAgIG5vdyA9IHRpbWUubG9jYWx0aW1lKCkKICAgICAgICBmLmFwcGVuZChub3cudG1faG91ciAvIDI0LjApCiAgICAgICAgZi5hcHBlbmQobm93LnRtX3dkYXkgLyA3LjApCgogICAgICAgIHJldHVybiBmCgogICAgYXN5bmMgZGVmIHVwZGF0ZShzZWxmLCBwcm94eV91cmw6IHN0ciwgbGF0ZW5jeV9tczogZmxvYXQsIHN1Y2Nlc3M6IGJvb2wsCiAgICAgICAgICAgICAgICAgICAgIHJlcXVlc3RfY29udGV4dDogT3B0aW9uYWxbRGljdF0gPSBOb25lLAogICAgICAgICAgICAgICAgICAgICBzY29yZXI9Tm9uZSwgcHJveHlfZW50cnk9Tm9uZSk6CiAgICAgICAgIiIiUmVjb3JkIGEgbmV3IHRyYWluaW5nIHNhbXBsZSBhbmQgdHJpZ2dlciByZXRyYWluaW5nIGlmIG5lZWRlZC4KCiAgICAgICAgQXJnczoKICAgICAgICAgICAgcHJveHlfdXJsOiBQcm94eSBVUkwgc3RyaW5nCiAgICAgICAgICAgIGxhdGVuY3lfbXM6IFJlcXVlc3QgbGF0ZW5jeSBpbiBtaWxsaXNlY29uZHMKICAgICAgICAgICAgc3VjY2VzczogV2hldGhlciB0aGUgcmVxdWVzdCBzdWNjZWVkZWQKICAgICAgICAgICAgcmVxdWVzdF9jb250ZXh0OiBPcHRpb25hbCBkaWN0IHdpdGggdXJsLCBtZXRob2QsIGRvbWFpbiwgY291bnRyeQogICAgICAgICAgICBzY29yZXI6IE9wdGlvbmFsIFF1YWxpdHlTY29yZXIgZm9yIHN1Y2Nlc3MgcmF0ZSBkYXRhCiAgICAgICAgICAgIHByb3h5X2VudHJ5OiBPcHRpb25hbCBQcm94eUVudHJ5IGZvciByZWFsIHByb3h5LWxldmVsIGZlYXR1cmVzCiAgICAgICAgIiIiCiAgICAgICAgIyBFbnJpY2ggY29udGV4dCB3aXRoIHJlYWwgZGF0YSBmcm9tIHNjb3JlciBhbmQgcHJveHkgZW50cnkKICAgICAgICBjdHggPSByZXF1ZXN0X2NvbnRleHQgb3Ige30KICAgICAgICBpZiBzY29yZXI6CiAgICAgICAgICAgIGN0eFsic3VjY2Vzc19yYXRlIl0gPSBzY29yZXIuZ2V0X3JlY2VudF9zdWNjZXNzX3JhdGUocHJveHlfdXJsKQogICAgICAgICAgICBjdHhbImF2Z19sYXRlbmN5Il0gPSBzY29yZXIuZ2V0X2F2Z19sYXRlbmN5KHByb3h5X3VybCkKICAgICAgICBpZiBwcm94eV9lbnRyeSBpcyBub3QgTm9uZToKICAgICAgICAgICAgY3R4WyJjb3VudHJ5Il0gPSBjdHguZ2V0KCJjb3VudHJ5IiwgIlVTIikKCiAgICAgICAgYXN5bmMgd2l0aCBzZWxmLl9sb2NrOgogICAgICAgICAgICBmZWF0dXJlcyA9IHNlbGYuX2V4dHJhY3RfZmVhdHVyZXMocHJveHlfdXJsLCBsYXRlbmN5X21zLCBjdHgsIHByb3h5X2VudHJ5KQogICAgICAgICAgICBzZWxmLl9mZWF0dXJlcy5hcHBlbmQoZmVhdHVyZXMpCiAgICAgICAgICAgIHNlbGYuX2xhYmVscy5hcHBlbmQoMSBpZiBzdWNjZXNzIGVsc2UgMCkKCiAgICAgICAgICAgICMgVHJpbSB0byBtYXhfc2FtcGxlcwogICAgICAgICAgICBpZiBsZW4oc2VsZi5fZmVhdHVyZXMpID4gc2VsZi5tYXhfc2FtcGxlczoKICAgICAgICAgICAgICAgIHNlbGYuX2ZlYXR1cmVzID0gc2VsZi5fZmVhdHVyZXNbLXNlbGYubWF4X3NhbXBsZXM6XQogICAgICAgICAgICAgICAgc2VsZi5fbGFiZWxzID0gc2VsZi5fbGFiZWxzWy1zZWxmLm1heF9zYW1wbGVzOl0KCiAgICAgICAgICAgIHNlbGYuX3NhbXBsZXNfc2luY2VfdHJhaW4gKz0gMQoKICAgICAgICAgICAgIyBSZXRyYWluIHBlcmlvZGljYWxseSAoRklYICM0OiBzZXQgX3RyYWluaW5nIGZsYWcgQkVGT1JFIHRvX3RocmVhZCkKICAgICAgICAgICAgaWYgKGxlbihzZWxmLl9mZWF0dXJlcykgPj0gNTAgYW5kCiAgICAgICAgICAgICAgICAgICAgc2VsZi5fc2FtcGxlc19zaW5jZV90cmFpbiA+PSBzZWxmLnJldHJhaW5faW50ZXJ2YWwpOgogICAgICAgICAgICAgICAgc2VsZi5fc2FtcGxlc19zaW5jZV90cmFpbiA9IDAKICAgICAgICAgICAgICAgIGlmIG5vdCBzZWxmLl90cmFpbmluZzogICMgUmFjZSBjb25kaXRpb24gZ3VhcmQKICAgICAgICAgICAgICAgICAgICBzZWxmLl90cmFpbmluZyA9IFRydWUKICAgICAgICAgICAgICAgICAgICBhd2FpdCBhc3luY2lvLnRvX3RocmVhZChzZWxmLl90cmFpbikKCiAgICBkZWYgX3RyYWluKHNlbGYpOgogICAgICAgICIiIlRyYWluIG1vZGVscyBhbmQgc2VsZWN0IHRoZSBiZXN0IHZpYSBjcm9zcy12YWxpZGF0aW9uLgoKICAgICAgICBSZXNwZWN0cyBzZWxmLm1vZGVsX3R5cGU6ICJhdXRvIiB0cmFpbnMgYWxsIGNhbmRpZGF0ZXMsIG90aGVyd2lzZQogICAgICAgIG9ubHkgdHJhaW5zIHRoZSBzcGVjaWZpZWQgbW9kZWwgdHlwZS4gRmFsbHMgYmFjayB0byBMb2dpc3RpYyBpZiB0aGUKICAgICAgICByZXF1ZXN0ZWQgbW9kZWwgdHlwZSBpcyB1bmF2YWlsYWJsZS4KICAgICAgICAiIiIKICAgICAgICB0cnk6CiAgICAgICAgICAgIFggPSBucC5hcnJheShzZWxmLl9mZWF0dXJlcykKICAgICAgICAgICAgeSA9IG5wLmFycmF5KHNlbGYuX2xhYmVscykKCiAgICAgICAgICAgICMgRklYICMzOiBNaW5pbXVtIHNhbXBsZSBndWFyZCDigJQgc2tpcCBpZiB0b28gZmV3IHNhbXBsZXMKICAgICAgICAgICAgaWYgbGVuKHkpIDwgMTA6CiAgICAgICAgICAgICAgICBsb2dnZXIuZGVidWcoZiJTa2lwcGluZyB0cmFpbmluZzogb25seSB7bGVuKHkpfSBzYW1wbGVzIChuZWVkID49IDEwKSIpCiAgICAgICAgICAgICAgICByZXR1cm4KCiAgICAgICAgICAgIGlmIGxlbihzZXQoeSkpIDwgMjoKICAgICAgICAgICAgICAgIGxvZ2dlci5kZWJ1ZygiTm90IGVub3VnaCBjbGFzc2VzIGZvciB0cmFpbmluZyIpCiAgICAgICAgICAgICAgICByZXR1cm4KCiAgICAgICAgICAgIFhfc2NhbGVkID0gc2VsZi5fc2NhbGVyLmZpdF90cmFuc2Zvcm0oWCkKICAgICAgICAgICAgYmVzdF9zY29yZSA9IC0xCiAgICAgICAgICAgIGJlc3RfbW9kZWwgPSBOb25lCiAgICAgICAgICAgIGJlc3RfbmFtZSA9IE5vbmUKICAgICAgICAgICAgY3YgPSBtaW4oMywgbGVuKHNldCh5KSkpICAjIENyb3NzLXZhbGlkYXRpb24gZm9sZHMKCiAgICAgICAgICAgICMgRklYICMyOiBGaWx0ZXIgbW9kZWxzIGJhc2VkIG9uIG1vZGVsX3R5cGUKICAgICAgICAgICAgIyBGSVggKGhhcmRlbmluZyk6IGZhbGwgYmFjayB0byBsb2dpc3RpYyBpZiByZXF1ZXN0ZWQgbW9kZWwgdW5hdmFpbGFibGUKICAgICAgICAgICAgdHJhaW5fbG9naXN0aWMgPSBzZWxmLm1vZGVsX3R5cGUgaW4gKCJhdXRvIiwgImxvZ2lzdGljIikKICAgICAgICAgICAgdHJhaW5fbWxwID0gc2VsZi5tb2RlbF90eXBlIGluICgiYXV0byIsICJtbHAiKQogICAgICAgICAgICB0cmFpbl94Z2IgPSBzZWxmLm1vZGVsX3R5cGUgaW4gKCJhdXRvIiwgInhnYm9vc3QiKSBhbmQgWEdCX0FWQUlMQUJMRQoKICAgICAgICAgICAgaWYgc2VsZi5tb2RlbF90eXBlID09ICJ4Z2Jvb3N0IiBhbmQgbm90IFhHQl9BVkFJTEFCTEU6CiAgICAgICAgICAgICAgICBsb2dnZXIud2FybmluZygiWEdCb29zdCBub3QgaW5zdGFsbGVkIOKAlCBmYWxsaW5nIGJhY2sgdG8gTG9naXN0aWMiKQogICAgICAgICAgICAgICAgdHJhaW5fbG9naXN0aWMgPSBUcnVlCiAgICAgICAgICAgIGVsaWYgc2VsZi5tb2RlbF90eXBlID09ICJ4Z2Jvb3N0IiBhbmQgbm90IHRyYWluX2xvZ2lzdGljIGFuZCBub3QgdHJhaW5fbWxwOgogICAgICAgICAgICAgICAgIyBPbmx5IFhHQiB3YXMgcmVxdWVzdGVkIGFuZCBpdCBJUyBhdmFpbGFibGUsIGJ1dCB3ZSBzdGlsbCB3YW50IGEgZmFsbGJhY2sKICAgICAgICAgICAgICAgIHRyYWluX2xvZ2lzdGljID0gVHJ1ZSAgIyBBbHdheXMgaGF2ZSBsb2dpc3RpYyBhcyBzYWZldHkgbmV0CgogICAgICAgICAgICAjIC0tLSBMb2dpc3RpYyBSZWdyZXNzaW9uIChmYXN0IGZhbGxiYWNrKSAtLS0KICAgICAgICAgICAgaWYgdHJhaW5fbG9naXN0aWM6CiAgICAgICAgICAgICAgICB0cnk6CiAgICAgICAgICAgICAgICAgICAgbHIgPSBMb2dpc3RpY1JlZ3Jlc3Npb24obWF4X2l0ZXI9MTAwMCwgY2xhc3Nfd2VpZ2h0PSdiYWxhbmNlZCcsCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgcmFuZG9tX3N0YXRlPTQyKQogICAgICAgICAgICAgICAgICAgIHNjb3JlID0gY3Jvc3NfdmFsX3Njb3JlKGxyLCBYX3NjYWxlZCwgeSwgY3Y9Y3YpLm1lYW4oKQogICAgICAgICAgICAgICAgICAgIGlmIHNjb3JlID4gYmVzdF9zY29yZToKICAgICAgICAgICAgICAgICAgICAgICAgYmVzdF9zY29yZSwgYmVzdF9tb2RlbCwgYmVzdF9uYW1lID0gc2NvcmUsIGxyLCAiTG9naXN0aWMiCiAgICAgICAgICAgICAgICBleGNlcHQgRXhjZXB0aW9uIGFzIGU6CiAgICAgICAgICAgICAgICAgICAgbG9nZ2VyLmRlYnVnKGYiTG9naXN0aWMgdHJhaW5pbmcgZmFpbGVkOiB7ZX0iKQoKICAgICAgICAgICAgIyAtLS0gTUxQIE5ldXJhbCBOZXR3b3JrIC0tLQogICAgICAgICAgICBpZiB0cmFpbl9tbHA6CiAgICAgICAgICAgICAgICB0cnk6CiAgICAgICAgICAgICAgICAgICAgbWxwID0gTUxQQ2xhc3NpZmllcigKICAgICAgICAgICAgICAgICAgICAgICAgaGlkZGVuX2xheWVyX3NpemVzPSg2NCwgMzIpLAogICAgICAgICAgICAgICAgICAgICAgICBtYXhfaXRlcj01MDAsCiAgICAgICAgICAgICAgICAgICAgICAgIGVhcmx5X3N0b3BwaW5nPVRydWUsCiAgICAgICAgICAgICAgICAgICAgICAgIHJhbmRvbV9zdGF0ZT00MgogICAgICAgICAgICAgICAgICAgICkKICAgICAgICAgICAgICAgICAgICBzY29yZSA9IGNyb3NzX3ZhbF9zY29yZShtbHAsIFhfc2NhbGVkLCB5LCBjdj1jdikubWVhbigpCiAgICAgICAgICAgICAgICAgICAgaWYgc2NvcmUgPiBiZXN0X3Njb3JlOgogICAgICAgICAgICAgICAgICAgICAgICBiZXN0X3Njb3JlLCBiZXN0X21vZGVsLCBiZXN0X25hbWUgPSBzY29yZSwgbWxwLCAiTUxQIgogICAgICAgICAgICAgICAgZXhjZXB0IEV4Y2VwdGlvbiBhcyBlOgogICAgICAgICAgICAgICAgICAgIGxvZ2dlci5kZWJ1ZyhmIk1MUCB0cmFpbmluZyBmYWlsZWQ6IHtlfSIpCgogICAgICAgICAgICAjIC0tLSBYR0Jvb3N0IChpZiBhdmFpbGFibGUgYW5kIHJlcXVlc3RlZCkgLS0tCiAgICAgICAgICAgIGlmIHRyYWluX3hnYjoKICAgICAgICAgICAgICAgIHRyeToKICAgICAgICAgICAgICAgICAgICB4Z2JfbW9kZWwgPSB4Z2IuWEdCQ2xhc3NpZmllcigKICAgICAgICAgICAgICAgICAgICAgICAgbl9lc3RpbWF0b3JzPTEwMCwKICAgICAgICAgICAgICAgICAgICAgICAgbWF4X2RlcHRoPTQsCiAgICAgICAgICAgICAgICAgICAgICAgIGV2YWxfbWV0cmljPSdsb2dsb3NzJywKICAgICAgICAgICAgICAgICAgICAgICAgcmFuZG9tX3N0YXRlPTQyLAogICAgICAgICAgICAgICAgICAgICAgICB1c2VfbGFiZWxfZW5jb2Rlcj1GYWxzZQogICAgICAgICAgICAgICAgICAgICkKICAgICAgICAgICAgICAgICAgICBzY29yZSA9IGNyb3NzX3ZhbF9zY29yZSh4Z2JfbW9kZWwsIFhfc2NhbGVkLCB5LCBjdj1jdikubWVhbigpCiAgICAgICAgICAgICAgICAgICAgaWYgc2NvcmUgPiBiZXN0X3Njb3JlOgogICAgICAgICAgICAgICAgICAgICAgICBiZXN0X3Njb3JlLCBiZXN0X21vZGVsLCBiZXN0X25hbWUgPSBzY29yZSwgeGdiX21vZGVsLCAiWEdCb29zdCIKICAgICAgICAgICAgICAgIGV4Y2VwdCBFeGNlcHRpb24gYXMgZToKICAgICAgICAgICAgICAgICAgICBsb2dnZXIuZGVidWcoZiJYR0Jvb3N0IHRyYWluaW5nIGZhaWxlZDoge2V9IikKCiAgICAgICAgICAgIGlmIGJlc3RfbW9kZWw6CiAgICAgICAgICAgICAgICBiZXN0X21vZGVsLmZpdChYX3NjYWxlZCwgeSkKICAgICAgICAgICAgICAgIHNlbGYuX21vZGVsID0gYmVzdF9tb2RlbAogICAgICAgICAgICAgICAgc2VsZi5fbW9kZWxfbmFtZSA9IGJlc3RfbmFtZQogICAgICAgICAgICAgICAgc2VsZi5fY3Zfc2NvcmUgPSBiZXN0X3Njb3JlCiAgICAgICAgICAgICAgICBzZWxmLl9pc190cmFpbmVkID0gVHJ1ZQogICAgICAgICAgICAgICAgbG9nZ2VyLmluZm8oZiLinIUgVHJhaW5lZCB7YmVzdF9uYW1lfSBtb2RlbCAoQ1Ygc2NvcmU6IHtiZXN0X3Njb3JlOi4zZn0pIikKICAgICAgICAgICAgICAgIHNlbGYuX3NhdmVfbW9kZWwoKQoKICAgICAgICBleGNlcHQgRXhjZXB0aW9uIGFzIGU6CiAgICAgICAgICAgIGxvZ2dlci53YXJuaW5nKGYiTUwgdHJhaW5pbmcgZmFpbGVkOiB7ZX0iKQogICAgICAgIGZpbmFsbHk6CiAgICAgICAgICAgIHNlbGYuX3RyYWluaW5nID0gRmFsc2UKCiAgICBhc3luYyBkZWYgcHJlZGljdChzZWxmLCBwcm94eV91cmw6IHN0ciwgbGF0ZW5jeV9tczogZmxvYXQsCiAgICAgICAgICAgICAgICAgICAgICByZXF1ZXN0X2NvbnRleHQ6IE9wdGlvbmFsW0RpY3RdID0gTm9uZSwKICAgICAgICAgICAgICAgICAgICAgIHNjb3Jlcj1Ob25lLCBwcm94eV9lbnRyeT1Ob25lKSAtPiBmbG9hdDoKICAgICAgICAiIiJQcmVkaWN0IHByb2JhYmlsaXR5IG9mIHN1Y2Nlc3NmdWwgcmVxdWVzdCAoMC4wIC0gMS4wKS4KCiAgICAgICAgQXJnczoKICAgICAgICAgICAgcHJveHlfdXJsOiBQcm94eSBVUkwgc3RyaW5nCiAgICAgICAgICAgIGxhdGVuY3lfbXM6IFJlcXVlc3QgbGF0ZW5jeSBpbiBtaWxsaXNlY29uZHMKICAgICAgICAgICAgcmVxdWVzdF9jb250ZXh0OiBPcHRpb25hbCBkaWN0IHdpdGggdXJsLCBtZXRob2QsIGRvbWFpbiwgY291bnRyeQogICAgICAgICAgICBzY29yZXI6IE9wdGlvbmFsIFF1YWxpdHlTY29yZXIgZm9yIHN1Y2Nlc3MgcmF0ZSBkYXRhCiAgICAgICAgICAgIHByb3h5X2VudHJ5OiBPcHRpb25hbCBQcm94eUVudHJ5IGZvciByZWFsIHByb3h5LWxldmVsIGZlYXR1cmVzCiAgICAgICAgIiIiCiAgICAgICAgaWYgbm90IHNlbGYuX2lzX3RyYWluZWQgb3Igc2VsZi5fbW9kZWwgaXMgTm9uZToKICAgICAgICAgICAgcmV0dXJuIDAuNQoKICAgICAgICBjdHggPSByZXF1ZXN0X2NvbnRleHQgb3Ige30KICAgICAgICBpZiBzY29yZXI6CiAgICAgICAgICAgIGN0eFsic3VjY2Vzc19yYXRlIl0gPSBzY29yZXIuZ2V0X3JlY2VudF9zdWNjZXNzX3JhdGUocHJveHlfdXJsKQogICAgICAgICAgICBjdHhbImF2Z19sYXRlbmN5Il0gPSBzY29yZXIuZ2V0X2F2Z19sYXRlbmN5KHByb3h5X3VybCkKCiAgICAgICAgYXN5bmMgd2l0aCBzZWxmLl9sb2NrOgogICAgICAgICAgICB0cnk6CiAgICAgICAgICAgICAgICBmZWF0dXJlcyA9IHNlbGYuX2V4dHJhY3RfZmVhdHVyZXMocHJveHlfdXJsLCBsYXRlbmN5X21zLCBjdHgsIHByb3h5X2VudHJ5KQogICAgICAgICAgICAgICAgWCA9IG5wLmFycmF5KFtmZWF0dXJlc10pCiAgICAgICAgICAgICAgICBYX3NjYWxlZCA9IHNlbGYuX3NjYWxlci50cmFuc2Zvcm0oWCkKICAgICAgICAgICAgICAgIHByb2IgPSBzZWxmLl9tb2RlbC5wcmVkaWN0X3Byb2JhKFhfc2NhbGVkKVswXVsxXQogICAgICAgICAgICAgICAgcmV0dXJuIGZsb2F0KHByb2IpCiAgICAgICAgICAgIGV4Y2VwdCBFeGNlcHRpb24gYXMgZToKICAgICAgICAgICAgICAgIGxvZ2dlci5kZWJ1ZyhmIlByZWRpY3Rpb24gZmFpbGVkOiB7ZX0iKQogICAgICAgICAgICAgICAgcmV0dXJuIDAuNQoKICAgIGRlZiBfc2F2ZV9tb2RlbChzZWxmKToKICAgICAgICAiIiJQZXJzaXN0IHRyYWluZWQgbW9kZWwgdG8gZGlzay4iIiIKICAgICAgICB0cnk6CiAgICAgICAgICAgIHBhdGggPSBNT0RFTF9ESVIgLyAicHJveHlfcHJlZGljdG9yLmpvYmxpYiIKICAgICAgICAgICAgam9ibGliLmR1bXAoewogICAgICAgICAgICAgICAgJ21vZGVsJzogc2VsZi5fbW9kZWwsCiAgICAgICAgICAgICAgICAnc2NhbGVyJzogc2VsZi5fc2NhbGVyLAogICAgICAgICAgICAgICAgJ21vZGVsX25hbWUnOiBzZWxmLl9tb2RlbF9uYW1lLAogICAgICAgICAgICAgICAgJ2N2X3Njb3JlJzogc2VsZi5fY3Zfc2NvcmUsCiAgICAgICAgICAgIH0sIHBhdGgpCiAgICAgICAgICAgIGxvZ2dlci5kZWJ1ZyhmIk1vZGVsIHNhdmVkIHRvIHtwYXRofSIpCiAgICAgICAgZXhjZXB0IEV4Y2VwdGlvbiBhcyBlOgogICAgICAgICAgICBsb2dnZXIuZGVidWcoZiJGYWlsZWQgdG8gc2F2ZSBtb2RlbDoge2V9IikKCiAgICBkZWYgX2xvYWRfbW9kZWwoc2VsZik6CiAgICAgICAgIiIiTG9hZCBwZXJzaXN0ZWQgbW9kZWwgZnJvbSBkaXNrLgoKICAgICAgICBWYWxpZGF0ZXMgZmVhdHVyZSBkaW1lbnNpb24gdG8gZGlzY2FyZCBzdGFsZSBtb2RlbHMgdGhhdCB3ZXJlCiAgICAgICAgdHJhaW5lZCB3aXRoIGEgZGlmZmVyZW50IGZlYXR1cmUgc2V0IChlLmcuIDExIHZzIDEyIGZlYXR1cmVzKS4KICAgICAgICAiIiIKICAgICAgICB0cnk6CiAgICAgICAgICAgIHBhdGggPSBNT0RFTF9ESVIgLyAicHJveHlfcHJlZGljdG9yLmpvYmxpYiIKICAgICAgICAgICAgaWYgcGF0aC5leGlzdHMoKToKICAgICAgICAgICAgICAgIGRhdGEgPSBqb2JsaWIubG9hZChwYXRoKQogICAgICAgICAgICAgICAgc2NhbGVyID0gZGF0YS5nZXQoJ3NjYWxlcicpCiAgICAgICAgICAgICAgICBtb2RlbF9uYW1lID0gZGF0YS5nZXQoJ21vZGVsX25hbWUnLCAndW5rbm93bicpCgogICAgICAgICAgICAgICAgIyBWYWxpZGF0ZSBmZWF0dXJlIGRpbWVuc2lvbiDigJQgZGlzY2FyZCBzdGFsZSBtb2RlbHMKICAgICAgICAgICAgICAgIGV4cGVjdGVkX2ZlYXR1cmVzID0gbGVuKHNlbGYuZmVhdHVyZV9uYW1lcykKICAgICAgICAgICAgICAgIGlmIHNjYWxlciBpcyBub3QgTm9uZSBhbmQgaGFzYXR0cihzY2FsZXIsICduX2ZlYXR1cmVzX2luXycpOgogICAgICAgICAgICAgICAgICAgIGFjdHVhbF9mZWF0dXJlcyA9IHNjYWxlci5uX2ZlYXR1cmVzX2luXwogICAgICAgICAgICAgICAgICAgIGlmIGFjdHVhbF9mZWF0dXJlcyAhPSBleHBlY3RlZF9mZWF0dXJlczoKICAgICAgICAgICAgICAgICAgICAgICAgbG9nZ2VyLndhcm5pbmcoCiAgICAgICAgICAgICAgICAgICAgICAgICAgICBmIlN0YWxlIG1vZGVsICd7bW9kZWxfbmFtZX0nIGV4cGVjdHMge2FjdHVhbF9mZWF0dXJlc30gZmVhdHVyZXMsICIKICAgICAgICAgICAgICAgICAgICAgICAgICAgIGYiYnV0IGN1cnJlbnQgZmVhdHVyZSBzZXQgaGFzIHtleHBlY3RlZF9mZWF0dXJlc30uICIKICAgICAgICAgICAgICAgICAgICAgICAgICAgIGYiRGVsZXRpbmcgY2FjaGVkIG1vZGVsIGFuZCByZXRyYWluaW5nIGxhdGVyLiIKICAgICAgICAgICAgICAgICAgICAgICAgKQogICAgICAgICAgICAgICAgICAgICAgICBwYXRoLnVubGluayhtaXNzaW5nX29rPVRydWUpCiAgICAgICAgICAgICAgICAgICAgICAgIHJldHVybgoKICAgICAgICAgICAgICAgIHNlbGYuX21vZGVsID0gZGF0YS5nZXQoJ21vZGVsJykKICAgICAgICAgICAgICAgIHNlbGYuX3NjYWxlciA9IHNjYWxlcgogICAgICAgICAgICAgICAgc2VsZi5fbW9kZWxfbmFtZSA9IG1vZGVsX25hbWUKICAgICAgICAgICAgICAgIHNlbGYuX2N2X3Njb3JlID0gZGF0YS5nZXQoJ2N2X3Njb3JlJywgMC4wKQogICAgICAgICAgICAgICAgc2VsZi5faXNfdHJhaW5lZCA9IFRydWUKICAgICAgICAgICAgICAgIGxvZ2dlci5pbmZvKGYiTG9hZGVkIHBlcnNpc3RlZCBtb2RlbDoge3NlbGYuX21vZGVsX25hbWV9ICIKICAgICAgICAgICAgICAgICAgICAgICAgICAgZiIoQ1Ygc2NvcmU6IHtzZWxmLl9jdl9zY29yZTouM2Z9KSIpCiAgICAgICAgZXhjZXB0IEV4Y2VwdGlvbiBhcyBlOgogICAgICAgICAgICBsb2dnZXIuZGVidWcoZiJGYWlsZWQgdG8gbG9hZCBtb2RlbDoge2V9IikKCiAgICBkZWYgZ2V0X2luZm8oc2VsZikgLT4gRGljdFtzdHIsIEFueV06CiAgICAgICAgIiIiUmV0dXJuIG1vZGVsIGluZm8gZm9yIHN0YXRzIGVuZHBvaW50LiIiIgogICAgICAgIHJldHVybiB7CiAgICAgICAgICAgICJtb2RlbF9uYW1lIjogc2VsZi5fbW9kZWxfbmFtZSwKICAgICAgICAgICAgImN2X3Njb3JlIjogcm91bmQoc2VsZi5fY3Zfc2NvcmUsIDQpLAogICAgICAgICAgICAic2FtcGxlcyI6IGxlbihzZWxmLl9mZWF0dXJlcyksCiAgICAgICAgICAgICJpc190cmFpbmVkIjogc2VsZi5faXNfdHJhaW5lZCwKICAgICAgICAgICAgInhnYm9vc3RfYXZhaWxhYmxlIjogWEdCX0FWQUlMQUJMRSwKICAgICAgICB9Cg=="
_EMBED_plugin_loader_py="IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiIK8J+miSBPV0wtQUdFTlQgdjQuNSDigJQgU2VsZi1IZWFsaW5nIFBsdWdpbiBMb2FkZXIKQXV0b21hdGljYWxseSBkaXNjb3ZlcnMsIGxvYWRzLCBhbmQgcmVsb2FkcyBwbHVnaW5zIGZyb20gYSBkZXNpZ25hdGVkIGRpcmVjdG9yeS4KIiIiCgppbXBvcnQgaW1wb3J0bGliCmltcG9ydCBpbXBvcnRsaWIudXRpbAppbXBvcnQgc3lzCmltcG9ydCBvcwppbXBvcnQgdGltZQppbXBvcnQgbG9nZ2luZwppbXBvcnQgYXN5bmNpbwpmcm9tIHBhdGhsaWIgaW1wb3J0IFBhdGgKZnJvbSB0eXBpbmcgaW1wb3J0IERpY3QsIExpc3QsIENhbGxhYmxlLCBPcHRpb25hbAoKbG9nZ2VyID0gbG9nZ2luZy5nZXRMb2dnZXIoIm93bC1hZ2VudC5wbHVnaW4iKQoKCmNsYXNzIFBsdWdpbkxvYWRlcjoKICAgICIiIkF1dG8tZGlzY292ZXJzIGFuZCBob3QtcmVsb2FkcyBwbHVnaW5zIGZyb20gYSBkaXJlY3RvcnkuCgogICAgUGx1Z2lucyBhcmUgUHl0aG9uIGZpbGVzIGluIHRoZSBwbHVnaW4gZGlyZWN0b3J5IHRoYXQgZGVmaW5lCiAgICBob29rIGZ1bmN0aW9uczogb25fcmVxdWVzdCwgb25fcmVzcG9uc2UsIG9uX2Vycm9yLCBvbl9zdGFydCwgb25fY29tcGxldGUuCgogICAgRmVhdHVyZXM6CiAgICAtIEF1dG9tYXRpYyBkaXNjb3Zlcnkgb24gc3RhcnR1cAogICAgLSBIb3QtcmVsb2FkIHdoZW4gZmlsZXMgY2hhbmdlIChwZXJpb2RpYyBzY2FuKQogICAgLSBTZWxmLWhlYWxpbmc6IGRpc2FibGVzIGZhaWxlZCBwbHVnaW5zLCByZXRyaWVzIGxhdGVyCiAgICAtIElzb2xhdGlvbjogcGx1Z2luIGVycm9ycyBkb24ndCBjcmFzaCB0aGUgZW5naW5lCiAgICAiIiIKCiAgICBIT09LX1RZUEVTID0gWyJzdGFydCIsICJyZXF1ZXN0IiwgInJlc3BvbnNlIiwgImVycm9yIiwgImNvbXBsZXRlIl0KCiAgICBkZWYgX19pbml0X18oc2VsZiwgcGx1Z2luX2Rpcjogc3RyID0gIn4vLm93bC1hZ2VudC9wbHVnaW5zIiwKICAgICAgICAgICAgICAgICB3YXRjaF9pbnRlcnZhbDogaW50ID0gMTApOgogICAgICAgIHNlbGYucGx1Z2luX2RpciA9IFBhdGgocGx1Z2luX2RpcikuZXhwYW5kdXNlcigpCiAgICAgICAgc2VsZi5wbHVnaW5fZGlyLm1rZGlyKHBhcmVudHM9VHJ1ZSwgZXhpc3Rfb2s9VHJ1ZSkKICAgICAgICBzZWxmLndhdGNoX2ludGVydmFsID0gd2F0Y2hfaW50ZXJ2YWwKICAgICAgICBzZWxmLl9sb2FkZWRfcGx1Z2luczogRGljdFtzdHIsIERpY3Rbc3RyLCBDYWxsYWJsZV1dID0ge30KICAgICAgICBzZWxmLl9lbmFibGVkOiBEaWN0W3N0ciwgYm9vbF0gPSB7fQogICAgICAgIHNlbGYuX2ZhaWxlZDogRGljdFtzdHIsIGludF0gPSB7fSAgIyBuYW1lIC0+IGZhaWwgY291bnQKICAgICAgICBzZWxmLl9sYXN0X21vZGlmaWVkOiBEaWN0W3N0ciwgZmxvYXRdID0ge30KICAgICAgICBzZWxmLl9sb2NrID0gYXN5bmNpby5Mb2NrKCkKICAgICAgICBzZWxmLl93YXRjaF90YXNrOiBPcHRpb25hbFthc3luY2lvLlRhc2tdID0gTm9uZQogICAgICAgIHNlbGYuX3J1bm5pbmcgPSBGYWxzZQoKICAgIGFzeW5jIGRlZiBzdGFydChzZWxmKToKICAgICAgICAiIiJTdGFydCB0aGUgcGx1Z2luIGxvYWRlcjogc2NhbiBvbmNlLCB0aGVuIHdhdGNoLiIiIgogICAgICAgIHNlbGYuX3J1bm5pbmcgPSBUcnVlCiAgICAgICAgc2VsZi5fc2Nhbl9hbGxfcGx1Z2lucygpCiAgICAgICAgc2VsZi5fd2F0Y2hfdGFzayA9IGFzeW5jaW8uY3JlYXRlX3Rhc2soc2VsZi5fd2F0Y2hfbG9vcCgpKQogICAgICAgIGxvZ2dlci5pbmZvKGYi8J+UjCBQbHVnaW4gbG9hZGVyIHN0YXJ0ZWQgKGRpcjoge3NlbGYucGx1Z2luX2Rpcn0pIikKCiAgICBhc3luYyBkZWYgc3RvcChzZWxmKToKICAgICAgICAiIiJTdG9wIHRoZSBwbHVnaW4gbG9hZGVyLiIiIgogICAgICAgIHNlbGYuX3J1bm5pbmcgPSBGYWxzZQogICAgICAgIGlmIHNlbGYuX3dhdGNoX3Rhc2s6CiAgICAgICAgICAgIHNlbGYuX3dhdGNoX3Rhc2suY2FuY2VsKCkKICAgICAgICAgICAgdHJ5OgogICAgICAgICAgICAgICAgYXdhaXQgc2VsZi5fd2F0Y2hfdGFzawogICAgICAgICAgICBleGNlcHQgYXN5bmNpby5DYW5jZWxsZWRFcnJvcjoKICAgICAgICAgICAgICAgIHBhc3MKCiAgICBhc3luYyBkZWYgX3dhdGNoX2xvb3Aoc2VsZik6CiAgICAgICAgIiIiUGVyaW9kaWNhbGx5IHNjYW4gZm9yIG5ldy9jaGFuZ2VkIHBsdWdpbnMuIiIiCiAgICAgICAgd2hpbGUgc2VsZi5fcnVubmluZzoKICAgICAgICAgICAgdHJ5OgogICAgICAgICAgICAgICAgYXdhaXQgYXN5bmNpby5zbGVlcChzZWxmLndhdGNoX2ludGVydmFsKQogICAgICAgICAgICAgICAgYXdhaXQgc2VsZi5fc2Nhbl9hbmRfcmVsb2FkKCkKICAgICAgICAgICAgZXhjZXB0IGFzeW5jaW8uQ2FuY2VsbGVkRXJyb3I6CiAgICAgICAgICAgICAgICBicmVhawogICAgICAgICAgICBleGNlcHQgRXhjZXB0aW9uIGFzIGU6CiAgICAgICAgICAgICAgICBsb2dnZXIuZXJyb3IoZiJQbHVnaW4gd2F0Y2ggZXJyb3I6IHtlfSIpCiAgICAgICAgICAgICAgICBhd2FpdCBhc3luY2lvLnNsZWVwKHNlbGYud2F0Y2hfaW50ZXJ2YWwpCgogICAgZGVmIF9zY2FuX2FsbF9wbHVnaW5zKHNlbGYpOgogICAgICAgICIiIkluaXRpYWwgc2NhbiBvZiBhbGwgcGx1Z2lucy4iIiIKICAgICAgICBmb3IgZmlsZV9wYXRoIGluIHNlbGYucGx1Z2luX2Rpci5nbG9iKCIqLnB5Iik6CiAgICAgICAgICAgIGlmIGZpbGVfcGF0aC5uYW1lLnN0YXJ0c3dpdGgoIl8iKToKICAgICAgICAgICAgICAgIGNvbnRpbnVlICAjIFNraXAgcHJpdmF0ZSBmaWxlcwogICAgICAgICAgICB0cnk6CiAgICAgICAgICAgICAgICBzZWxmLl9sb2FkX3BsdWdpbl9maWxlKGZpbGVfcGF0aCkKICAgICAgICAgICAgZXhjZXB0IEV4Y2VwdGlvbiBhcyBlOgogICAgICAgICAgICAgICAgbG9nZ2VyLmVycm9yKGYiRmFpbGVkIHRvIGxvYWQgcGx1Z2luIHtmaWxlX3BhdGgubmFtZX06IHtlfSIpCgogICAgYXN5bmMgZGVmIF9zY2FuX2FuZF9yZWxvYWQoc2VsZik6CiAgICAgICAgIiIiU2NhbiBmb3IgY2hhbmdlZCBwbHVnaW5zIGFuZCByZWxvYWQgdGhlbS4iIiIKICAgICAgICBmb3IgZmlsZV9wYXRoIGluIHNlbGYucGx1Z2luX2Rpci5nbG9iKCIqLnB5Iik6CiAgICAgICAgICAgIGlmIGZpbGVfcGF0aC5uYW1lLnN0YXJ0c3dpdGgoIl8iKToKICAgICAgICAgICAgICAgIGNvbnRpbnVlCiAgICAgICAgICAgIHRyeToKICAgICAgICAgICAgICAgIG1vZF90aW1lID0gZmlsZV9wYXRoLnN0YXQoKS5zdF9tdGltZQogICAgICAgICAgICAgICAgaWYgc2VsZi5fbGFzdF9tb2RpZmllZC5nZXQoc3RyKGZpbGVfcGF0aCksIDApIDwgbW9kX3RpbWU6CiAgICAgICAgICAgICAgICAgICAgYXdhaXQgc2VsZi5fcmVsb2FkX3BsdWdpbl9maWxlKGZpbGVfcGF0aCkKICAgICAgICAgICAgZXhjZXB0IEV4Y2VwdGlvbiBhcyBlOgogICAgICAgICAgICAgICAgbG9nZ2VyLmRlYnVnKGYiRXJyb3IgY2hlY2tpbmcgcGx1Z2luIHtmaWxlX3BhdGgubmFtZX06IHtlfSIpCgogICAgZGVmIF9sb2FkX3BsdWdpbl9maWxlKHNlbGYsIGZpbGVfcGF0aDogUGF0aCk6CiAgICAgICAgIiIiTG9hZCBhIHBsdWdpbiBmaWxlIGFuZCByZWdpc3RlciBpdHMgaG9va3MuIiIiCiAgICAgICAgdHJ5OgogICAgICAgICAgICBzcGVjID0gaW1wb3J0bGliLnV0aWwuc3BlY19mcm9tX2ZpbGVfbG9jYXRpb24oCiAgICAgICAgICAgICAgICBmaWxlX3BhdGguc3RlbSwgZmlsZV9wYXRoCiAgICAgICAgICAgICkKICAgICAgICAgICAgaWYgc3BlYyBpcyBOb25lIG9yIHNwZWMubG9hZGVyIGlzIE5vbmU6CiAgICAgICAgICAgICAgICBsb2dnZXIud2FybmluZyhmIkNhbm5vdCBsb2FkIHBsdWdpbiBzcGVjOiB7ZmlsZV9wYXRoLm5hbWV9IikKICAgICAgICAgICAgICAgIHJldHVybgoKICAgICAgICAgICAgbW9kdWxlID0gaW1wb3J0bGliLnV0aWwubW9kdWxlX2Zyb21fc3BlYyhzcGVjKQogICAgICAgICAgICBzcGVjLmxvYWRlci5leGVjX21vZHVsZShtb2R1bGUpCgogICAgICAgICAgICBob29rcyA9IHNlbGYuX2V4dHJhY3RfaG9va3MobW9kdWxlKQogICAgICAgICAgICBpZiBob29rczoKICAgICAgICAgICAgICAgIHNlbGYuX2xvYWRlZF9wbHVnaW5zW2ZpbGVfcGF0aC5zdGVtXSA9IGhvb2tzCiAgICAgICAgICAgICAgICBzZWxmLl9lbmFibGVkW2ZpbGVfcGF0aC5zdGVtXSA9IFRydWUKICAgICAgICAgICAgICAgIHNlbGYuX2ZhaWxlZFtmaWxlX3BhdGguc3RlbV0gPSAwCiAgICAgICAgICAgICAgICBzZWxmLl9sYXN0X21vZGlmaWVkW3N0cihmaWxlX3BhdGgpXSA9IGZpbGVfcGF0aC5zdGF0KCkuc3RfbXRpbWUKICAgICAgICAgICAgICAgIGxvZ2dlci5pbmZvKGYi8J+UjCBMb2FkZWQgcGx1Z2luOiB7ZmlsZV9wYXRoLnN0ZW19ICIKICAgICAgICAgICAgICAgICAgICAgICAgICBmIih7JywgJy5qb2luKGhvb2tzLmtleXMoKSl9KSIpCiAgICAgICAgICAgIGVsc2U6CiAgICAgICAgICAgICAgICBsb2dnZXIuZGVidWcoZiJQbHVnaW4ge2ZpbGVfcGF0aC5zdGVtfSBoYXMgbm8gaG9vayBmdW5jdGlvbnMiKQogICAgICAgIGV4Y2VwdCBFeGNlcHRpb24gYXMgZToKICAgICAgICAgICAgbG9nZ2VyLmVycm9yKGYiRmFpbGVkIHRvIGxvYWQgcGx1Z2luIHtmaWxlX3BhdGgubmFtZX06IHtlfSIpCiAgICAgICAgICAgIHNlbGYuX2ZhaWxlZFtmaWxlX3BhdGguc3RlbV0gPSBzZWxmLl9mYWlsZWQuZ2V0KGZpbGVfcGF0aC5zdGVtLCAwKSArIDEKCiAgICBhc3luYyBkZWYgX3JlbG9hZF9wbHVnaW5fZmlsZShzZWxmLCBmaWxlX3BhdGg6IFBhdGgpOgogICAgICAgICIiIkhvdC1yZWxvYWQgYSBjaGFuZ2VkIHBsdWdpbiBmaWxlLiIiIgogICAgICAgIG5hbWUgPSBmaWxlX3BhdGguc3RlbQogICAgICAgIGxvZ2dlci5pbmZvKGYi8J+UhCBSZWxvYWRpbmcgcGx1Z2luOiB7bmFtZX0iKQogICAgICAgIHRyeToKICAgICAgICAgICAgIyBSZW1vdmUgZnJvbSBzeXMubW9kdWxlcyBpZiBwcmV2aW91c2x5IGxvYWRlZAogICAgICAgICAgICBpZiBuYW1lIGluIHN5cy5tb2R1bGVzOgogICAgICAgICAgICAgICAgZGVsIHN5cy5tb2R1bGVzW25hbWVdCgogICAgICAgICAgICBzcGVjID0gaW1wb3J0bGliLnV0aWwuc3BlY19mcm9tX2ZpbGVfbG9jYXRpb24obmFtZSwgZmlsZV9wYXRoKQogICAgICAgICAgICBpZiBzcGVjIGlzIE5vbmUgb3Igc3BlYy5sb2FkZXIgaXMgTm9uZToKICAgICAgICAgICAgICAgIHJldHVybgoKICAgICAgICAgICAgbW9kdWxlID0gaW1wb3J0bGliLnV0aWwubW9kdWxlX2Zyb21fc3BlYyhzcGVjKQogICAgICAgICAgICBzcGVjLmxvYWRlci5leGVjX21vZHVsZShtb2R1bGUpCgogICAgICAgICAgICBob29rcyA9IHNlbGYuX2V4dHJhY3RfaG9va3MobW9kdWxlKQogICAgICAgICAgICBhc3luYyB3aXRoIHNlbGYuX2xvY2s6CiAgICAgICAgICAgICAgICBpZiBob29rczoKICAgICAgICAgICAgICAgICAgICBzZWxmLl9sb2FkZWRfcGx1Z2luc1tuYW1lXSA9IGhvb2tzCiAgICAgICAgICAgICAgICAgICAgc2VsZi5fZW5hYmxlZFtuYW1lXSA9IFRydWUKICAgICAgICAgICAgICAgICAgICBzZWxmLl9mYWlsZWRbbmFtZV0gPSAwCiAgICAgICAgICAgICAgICAgICAgc2VsZi5fbGFzdF9tb2RpZmllZFtzdHIoZmlsZV9wYXRoKV0gPSBmaWxlX3BhdGguc3RhdCgpLnN0X210aW1lCiAgICAgICAgICAgICAgICAgICAgbG9nZ2VyLmluZm8oZiLinIUgUmVsb2FkZWQgcGx1Z2luOiB7bmFtZX0gIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICBmIih7JywgJy5qb2luKGhvb2tzLmtleXMoKSl9KSIpCiAgICAgICAgICAgICAgICBlbHNlOgogICAgICAgICAgICAgICAgICAgICMgUGx1Z2luIGxvc3QgaXRzIGhvb2tzIC0gZGlzYWJsZSBpdAogICAgICAgICAgICAgICAgICAgIHNlbGYuX2VuYWJsZWRbbmFtZV0gPSBGYWxzZQogICAgICAgICAgICAgICAgICAgIGxvZ2dlci53YXJuaW5nKGYiUGx1Z2luIHtuYW1lfSBsb3N0IGhvb2tzIGFmdGVyIHJlbG9hZCwgZGlzYWJsZWQiKQogICAgICAgIGV4Y2VwdCBFeGNlcHRpb24gYXMgZToKICAgICAgICAgICAgbG9nZ2VyLmVycm9yKGYiRmFpbGVkIHRvIHJlbG9hZCBwbHVnaW4ge25hbWV9OiB7ZX0iKQogICAgICAgICAgICBzZWxmLl9mYWlsZWRbbmFtZV0gPSBzZWxmLl9mYWlsZWQuZ2V0KG5hbWUsIDApICsgMQogICAgICAgICAgICAjIFNlbGYtaGVhbGluZzogZGlzYWJsZSBhZnRlciAzIGNvbnNlY3V0aXZlIGZhaWx1cmVzCiAgICAgICAgICAgIGlmIHNlbGYuX2ZhaWxlZFtuYW1lXSA+PSAzOgogICAgICAgICAgICAgICAgc2VsZi5fZW5hYmxlZFtuYW1lXSA9IEZhbHNlCiAgICAgICAgICAgICAgICBsb2dnZXIud2FybmluZyhmIlBsdWdpbiB7bmFtZX0gZGlzYWJsZWQgYWZ0ZXIgMyBmYWlsdXJlcyIpCgogICAgZGVmIF9leHRyYWN0X2hvb2tzKHNlbGYsIG1vZHVsZSkgLT4gRGljdFtzdHIsIENhbGxhYmxlXToKICAgICAgICAiIiJFeHRyYWN0IGhvb2sgZnVuY3Rpb25zIGZyb20gYSBtb2R1bGUuIiIiCiAgICAgICAgaG9va3MgPSB7fQogICAgICAgIGZvciBob29rX3R5cGUgaW4gc2VsZi5IT09LX1RZUEVTOgogICAgICAgICAgICBmdW5jID0gZ2V0YXR0cihtb2R1bGUsIGYib25fe2hvb2tfdHlwZX0iLCBOb25lKQogICAgICAgICAgICBpZiBmdW5jIGFuZCBjYWxsYWJsZShmdW5jKToKICAgICAgICAgICAgICAgIGhvb2tzW2hvb2tfdHlwZV0gPSBmdW5jCiAgICAgICAgcmV0dXJuIGhvb2tzCgogICAgZGVmIGdldF9ob29rcyhzZWxmLCBob29rX3R5cGU6IHN0cikgLT4gTGlzdFtDYWxsYWJsZV06CiAgICAgICAgIiIiUmV0dXJuIGFsbCBlbmFibGVkIGhvb2sgZnVuY3Rpb25zIGZvciBhIGdpdmVuIHR5cGUuIiIiCiAgICAgICAgZnVuY3MgPSBbXQogICAgICAgIGZvciBuYW1lLCBob29rcyBpbiBzZWxmLl9sb2FkZWRfcGx1Z2lucy5pdGVtcygpOgogICAgICAgICAgICBpZiBzZWxmLl9lbmFibGVkLmdldChuYW1lLCBGYWxzZSkgYW5kIGhvb2tfdHlwZSBpbiBob29rczoKICAgICAgICAgICAgICAgIGZ1bmNzLmFwcGVuZChob29rc1tob29rX3R5cGVdKQogICAgICAgIHJldHVybiBmdW5jcwoKICAgIGRlZiBkaXNhYmxlX3BsdWdpbihzZWxmLCBuYW1lOiBzdHIpOgogICAgICAgICIiIk1hbnVhbGx5IGRpc2FibGUgYSBwbHVnaW4uIiIiCiAgICAgICAgc2VsZi5fZW5hYmxlZFtuYW1lXSA9IEZhbHNlCiAgICAgICAgbG9nZ2VyLmluZm8oZiJQbHVnaW4ge25hbWV9IGRpc2FibGVkIikKCiAgICBkZWYgZW5hYmxlX3BsdWdpbihzZWxmLCBuYW1lOiBzdHIpOgogICAgICAgICIiIk1hbnVhbGx5IGVuYWJsZSBhIHBsdWdpbi4iIiIKICAgICAgICBpZiBuYW1lIGluIHNlbGYuX2xvYWRlZF9wbHVnaW5zOgogICAgICAgICAgICBzZWxmLl9lbmFibGVkW25hbWVdID0gVHJ1ZQogICAgICAgICAgICBzZWxmLl9mYWlsZWRbbmFtZV0gPSAwCiAgICAgICAgICAgIGxvZ2dlci5pbmZvKGYiUGx1Z2luIHtuYW1lfSBlbmFibGVkIikKCiAgICBkZWYgZ2V0X3N0YXRzKHNlbGYpIC0+IERpY3Q6CiAgICAgICAgIiIiUmV0dXJuIHBsdWdpbiBzdGF0aXN0aWNzLiIiIgogICAgICAgIHJldHVybiB7CiAgICAgICAgICAgICJ0b3RhbCI6IGxlbihzZWxmLl9sb2FkZWRfcGx1Z2lucyksCiAgICAgICAgICAgICJlbmFibGVkIjogc3VtKDEgZm9yIHYgaW4gc2VsZi5fZW5hYmxlZC52YWx1ZXMoKSBpZiB2KSwKICAgICAgICAgICAgImZhaWxlZCI6IHN1bSgxIGZvciB2IGluIHNlbGYuX2ZhaWxlZC52YWx1ZXMoKSBpZiB2ID49IDMpLAogICAgICAgICAgICAicGx1Z2lucyI6IHsKICAgICAgICAgICAgICAgIG5hbWU6IHsKICAgICAgICAgICAgICAgICAgICAiZW5hYmxlZCI6IHNlbGYuX2VuYWJsZWQuZ2V0KG5hbWUsIEZhbHNlKSwKICAgICAgICAgICAgICAgICAgICAiaG9va3MiOiBsaXN0KGhvb2tzLmtleXMoKSksCiAgICAgICAgICAgICAgICAgICAgImZhaWx1cmVzIjogc2VsZi5fZmFpbGVkLmdldChuYW1lLCAwKSwKICAgICAgICAgICAgICAgIH0KICAgICAgICAgICAgICAgIGZvciBuYW1lLCBob29rcyBpbiBzZWxmLl9sb2FkZWRfcGx1Z2lucy5pdGVtcygpCiAgICAgICAgICAgIH0KICAgICAgICB9Cg=="
_EMBED_mcp_server_py="IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiIK8J+miSBPV0wtQUdFTlQgTUNQIFNlcnZlcgpNb2RlbCBDb250ZXh0IFByb3RvY29sIHNlcnZlciBmb3IgQ2xpbmUgaW50ZWdyYXRpb24KIiIiCgppbXBvcnQgYXN5bmNpbwppbXBvcnQganNvbgppbXBvcnQgc3lzCmZyb20gdHlwaW5nIGltcG9ydCBBbnksIERpY3QsIExpc3QsIE9wdGlvbmFsCgojIE1DUCBQcm90b2NvbCBpbXBsZW1lbnRhdGlvbgpjbGFzcyBNQ1BTZXJ2ZXI6CiAgICBkZWYgX19pbml0X18oc2VsZik6CiAgICAgICAgc2VsZi50b29scyA9IHt9CiAgICAgICAgc2VsZi5yZXNvdXJjZXMgPSB7fQoKICAgIGRlZiB0b29sKHNlbGYsIG5hbWU6IHN0ciwgZGVzY3JpcHRpb246IHN0cik6CiAgICAgICAgZGVmIGRlY29yYXRvcihmdW5jKToKICAgICAgICAgICAgc2VsZi50b29sc1tuYW1lXSA9IHsKICAgICAgICAgICAgICAgICJuYW1lIjogbmFtZSwKICAgICAgICAgICAgICAgICJkZXNjcmlwdGlvbiI6IGRlc2NyaXB0aW9uLAogICAgICAgICAgICAgICAgImhhbmRsZXIiOiBmdW5jCiAgICAgICAgICAgIH0KICAgICAgICAgICAgcmV0dXJuIGZ1bmMKICAgICAgICByZXR1cm4gZGVjb3JhdG9yCgogICAgZGVmIHJlc291cmNlKHNlbGYsIHVyaTogc3RyLCBuYW1lOiBzdHIsIGRlc2NyaXB0aW9uOiBzdHIpOgogICAgICAgIGRlZiBkZWNvcmF0b3IoZnVuYyk6CiAgICAgICAgICAgIHNlbGYucmVzb3VyY2VzW3VyaV0gPSB7CiAgICAgICAgICAgICAgICAidXJpIjogdXJpLAogICAgICAgICAgICAgICAgIm5hbWUiOiBuYW1lLAogICAgICAgICAgICAgICAgImRlc2NyaXB0aW9uIjogZGVzY3JpcHRpb24sCiAgICAgICAgICAgICAgICAiaGFuZGxlciI6IGZ1bmMKICAgICAgICAgICAgfQogICAgICAgICAgICByZXR1cm4gZnVuYwogICAgICAgIHJldHVybiBkZWNvcmF0b3IKCiAgICBhc3luYyBkZWYgaGFuZGxlX3JlcXVlc3Qoc2VsZiwgcmVxdWVzdDogRGljdCkgLT4gRGljdDoKICAgICAgICBtZXRob2QgPSByZXF1ZXN0LmdldCgibWV0aG9kIiwgIiIpCiAgICAgICAgcGFyYW1zID0gcmVxdWVzdC5nZXQoInBhcmFtcyIsIHt9KQogICAgICAgIHJlcV9pZCA9IHJlcXVlc3QuZ2V0KCJpZCIsIDEpCgogICAgICAgIGlmIG1ldGhvZCA9PSAiaW5pdGlhbGl6ZSI6CiAgICAgICAgICAgIHJldHVybiBhd2FpdCBzZWxmLl9oYW5kbGVfaW5pdGlhbGl6ZShyZXFfaWQsIHBhcmFtcykKICAgICAgICBlbGlmIG1ldGhvZCA9PSAidG9vbHMvbGlzdCI6CiAgICAgICAgICAgIHJldHVybiBhd2FpdCBzZWxmLl9oYW5kbGVfdG9vbHNfbGlzdChyZXFfaWQpCiAgICAgICAgZWxpZiBtZXRob2QgPT0gInRvb2xzL2NhbGwiOgogICAgICAgICAgICByZXR1cm4gYXdhaXQgc2VsZi5faGFuZGxlX3Rvb2xfY2FsbChyZXFfaWQsIHBhcmFtcykKICAgICAgICBlbGlmIG1ldGhvZCA9PSAicmVzb3VyY2VzL2xpc3QiOgogICAgICAgICAgICByZXR1cm4gYXdhaXQgc2VsZi5faGFuZGxlX3Jlc291cmNlc19saXN0KHJlcV9pZCkKICAgICAgICBlbGlmIG1ldGhvZCA9PSAicmVzb3VyY2VzL3JlYWQiOgogICAgICAgICAgICByZXR1cm4gYXdhaXQgc2VsZi5faGFuZGxlX3Jlc291cmNlX3JlYWQocmVxX2lkLCBwYXJhbXMpCiAgICAgICAgZWxzZToKICAgICAgICAgICAgcmV0dXJuIHsianNvbnJwYyI6ICIyLjAiLCAiaWQiOiByZXFfaWQsICJlcnJvciI6IHsiY29kZSI6IC0zMjYwMSwgIm1lc3NhZ2UiOiBmIk1ldGhvZCBub3QgZm91bmQ6IHttZXRob2R9In19CgogICAgYXN5bmMgZGVmIF9oYW5kbGVfaW5pdGlhbGl6ZShzZWxmLCByZXFfaWQ6IGludCwgcGFyYW1zOiBEaWN0KSAtPiBEaWN0OgogICAgICAgIHJldHVybiB7CiAgICAgICAgICAgICJqc29ucnBjIjogIjIuMCIsCiAgICAgICAgICAgICJpZCI6IHJlcV9pZCwKICAgICAgICAgICAgInJlc3VsdCI6IHsKICAgICAgICAgICAgICAgICJwcm90b2NvbFZlcnNpb24iOiAiMjAyNC0xMS0wNSIsCiAgICAgICAgICAgICAgICAiY2FwYWJpbGl0aWVzIjogewogICAgICAgICAgICAgICAgICAgICJ0b29scyI6IHt9LAogICAgICAgICAgICAgICAgICAgICJyZXNvdXJjZXMiOiB7fQogICAgICAgICAgICAgICAgfSwKICAgICAgICAgICAgICAgICJzZXJ2ZXJJbmZvIjogewogICAgICAgICAgICAgICAgICAgICJuYW1lIjogIm93bC1hZ2VudCIsCiAgICAgICAgICAgICAgICAgICAgInZlcnNpb24iOiAiNC4yLjAiCiAgICAgICAgICAgICAgICB9CiAgICAgICAgICAgIH0KICAgICAgICB9CgogICAgYXN5bmMgZGVmIF9oYW5kbGVfdG9vbHNfbGlzdChzZWxmLCByZXFfaWQ6IGludCkgLT4gRGljdDoKICAgICAgICB0b29scyA9IFtdCiAgICAgICAgZm9yIG5hbWUsIHRvb2wgaW4gc2VsZi50b29scy5pdGVtcygpOgogICAgICAgICAgICB0b29scy5hcHBlbmQoewogICAgICAgICAgICAgICAgIm5hbWUiOiB0b29sWyJuYW1lIl0sCiAgICAgICAgICAgICAgICAiZGVzY3JpcHRpb24iOiB0b29sWyJkZXNjcmlwdGlvbiJdLAogICAgICAgICAgICAgICAgImlucHV0U2NoZW1hIjogewogICAgICAgICAgICAgICAgICAgICJ0eXBlIjogIm9iamVjdCIsCiAgICAgICAgICAgICAgICAgICAgInByb3BlcnRpZXMiOiB7fSwKICAgICAgICAgICAgICAgICAgICAicmVxdWlyZWQiOiBbXQogICAgICAgICAgICAgICAgfQogICAgICAgICAgICB9KQogICAgICAgIHJldHVybiB7Impzb25ycGMiOiAiMi4wIiwgImlkIjogcmVxX2lkLCAicmVzdWx0IjogeyJ0b29scyI6IHRvb2xzfX0KCiAgICBhc3luYyBkZWYgX2hhbmRsZV90b29sX2NhbGwoc2VsZiwgcmVxX2lkOiBpbnQsIHBhcmFtczogRGljdCkgLT4gRGljdDoKICAgICAgICB0b29sX25hbWUgPSBwYXJhbXMuZ2V0KCJuYW1lIiwgIiIpCiAgICAgICAgYXJndW1lbnRzID0gcGFyYW1zLmdldCgiYXJndW1lbnRzIiwge30pCgogICAgICAgIGlmIHRvb2xfbmFtZSBub3QgaW4gc2VsZi50b29sczoKICAgICAgICAgICAgcmV0dXJuIHsianNvbnJwYyI6ICIyLjAiLCAiaWQiOiByZXFfaWQsICJlcnJvciI6IHsiY29kZSI6IC0zMjYwMiwgIm1lc3NhZ2UiOiBmIlRvb2wgbm90IGZvdW5kOiB7dG9vbF9uYW1lfSJ9fQoKICAgICAgICB0cnk6CiAgICAgICAgICAgIHJlc3VsdCA9IGF3YWl0IHNlbGYudG9vbHNbdG9vbF9uYW1lXVsiaGFuZGxlciJdKGFyZ3VtZW50cykKICAgICAgICAgICAgcmV0dXJuIHsianNvbnJwYyI6ICIyLjAiLCAiaWQiOiByZXFfaWQsICJyZXN1bHQiOiB7ImNvbnRlbnQiOiBbeyJ0eXBlIjogInRleHQiLCAidGV4dCI6IGpzb24uZHVtcHMocmVzdWx0KX1dfX0KICAgICAgICBleGNlcHQgRXhjZXB0aW9uIGFzIGU6CiAgICAgICAgICAgIHJldHVybiB7Impzb25ycGMiOiAiMi4wIiwgImlkIjogcmVxX2lkLCAiZXJyb3IiOiB7ImNvZGUiOiAtMzIwMDAsICJtZXNzYWdlIjogc3RyKGUpfX0KCiAgICBhc3luYyBkZWYgX2hhbmRsZV9yZXNvdXJjZXNfbGlzdChzZWxmLCByZXFfaWQ6IGludCkgLT4gRGljdDoKICAgICAgICByZXNvdXJjZXMgPSBbXQogICAgICAgIGZvciB1cmksIHJlc291cmNlIGluIHNlbGYucmVzb3VyY2VzLml0ZW1zKCk6CiAgICAgICAgICAgIHJlc291cmNlcy5hcHBlbmQoewogICAgICAgICAgICAgICAgInVyaSI6IHVyaSwKICAgICAgICAgICAgICAgICJuYW1lIjogcmVzb3VyY2VbIm5hbWUiXSwKICAgICAgICAgICAgICAgICJkZXNjcmlwdGlvbiI6IHJlc291cmNlWyJkZXNjcmlwdGlvbiJdLAogICAgICAgICAgICAgICAgIm1pbWVUeXBlIjogImFwcGxpY2F0aW9uL2pzb24iCiAgICAgICAgICAgIH0pCiAgICAgICAgcmV0dXJuIHsianNvbnJwYyI6ICIyLjAiLCAiaWQiOiByZXFfaWQsICJyZXN1bHQiOiB7InJlc291cmNlcyI6IHJlc291cmNlc319CgogICAgYXN5bmMgZGVmIF9oYW5kbGVfcmVzb3VyY2VfcmVhZChzZWxmLCByZXFfaWQ6IGludCwgcGFyYW1zOiBEaWN0KSAtPiBEaWN0OgogICAgICAgIHVyaSA9IHBhcmFtcy5nZXQoInVyaSIsICIiKQogICAgICAgIGlmIHVyaSBub3QgaW4gc2VsZi5yZXNvdXJjZXM6CiAgICAgICAgICAgIHJldHVybiB7Impzb25ycGMiOiAiMi4wIiwgImlkIjogcmVxX2lkLCAiZXJyb3IiOiB7ImNvZGUiOiAtMzI2MDIsICJtZXNzYWdlIjogZiJSZXNvdXJjZSBub3QgZm91bmQ6IHt1cml9In19CgogICAgICAgIHRyeToKICAgICAgICAgICAgY29udGVudCA9IGF3YWl0IHNlbGYucmVzb3VyY2VzW3VyaV1bImhhbmRsZXIiXSgpCiAgICAgICAgICAgIHJldHVybiB7Impzb25ycGMiOiAiMi4wIiwgImlkIjogcmVxX2lkLCAicmVzdWx0IjogeyJjb250ZW50cyI6IFt7InVyaSI6IHVyaSwgIm1pbWVUeXBlIjogImFwcGxpY2F0aW9uL2pzb24iLCAidGV4dCI6IGpzb24uZHVtcHMoY29udGVudCl9XX19CiAgICAgICAgZXhjZXB0IEV4Y2VwdGlvbiBhcyBlOgogICAgICAgICAgICByZXR1cm4geyJqc29ucnBjIjogIjIuMCIsICJpZCI6IHJlcV9pZCwgImVycm9yIjogeyJjb2RlIjogLTMyMDAwLCAibWVzc2FnZSI6IHN0cihlKX19CgojIEluaXRpYWxpemUgc2VydmVyCnNlcnZlciA9IE1DUFNlcnZlcigpCgojIEltcG9ydCBPV0wtQUdFTlQKc3lzLnBhdGguaW5zZXJ0KDAsICIvaG9tZS91YnVudHUvLm93bC1hZ2VudCIpCmZyb20gcHJveHlfZGVmZW5zZSBpbXBvcnQgUmVzaWxpZW50Q2xpZW50CgojIENsaWVudCBpbnN0YW5jZQpfY2xpZW50ID0gTm9uZQoKYXN5bmMgZGVmIGdldF9jbGllbnQoKToKICAgIGdsb2JhbCBfY2xpZW50CiAgICBpZiBfY2xpZW50IGlzIE5vbmU6CiAgICAgICAgX2NsaWVudCA9IFJlc2lsaWVudENsaWVudCh1c2VfY3VybF9jZmZpPVRydWUpCiAgICAgICAgYXdhaXQgX2NsaWVudC5fX2FlbnRlcl9fKCkKICAgIHJldHVybiBfY2xpZW50CgojIFJlZ2lzdGVyIHRvb2xzCkBzZXJ2ZXIudG9vbCgib3dsX2ZldGNoIiwgIkZldGNoIGEgVVJMIHZpYSB0aGUgcmVzaWxpZW50IGNsaWVudCB3aXRoIHByb3h5IHJvdGF0aW9uIGFuZCBxdWFsaXR5IHNjb3JpbmciKQphc3luYyBkZWYgaGFuZGxlX2ZldGNoKGFyZ3M6IERpY3QpIC0+IEFueToKICAgIHVybCA9IGFyZ3MuZ2V0KCJ1cmwiKQogICAgaWYgbm90IHVybDoKICAgICAgICByZXR1cm4geyJlcnJvciI6ICJNaXNzaW5nIHVybCBwYXJhbWV0ZXIifQoKICAgIGNsaWVudCA9IGF3YWl0IGdldF9jbGllbnQoKQogICAgcmVzcCA9IGF3YWl0IGNsaWVudC5yZXF1ZXN0KCJHRVQiLCB1cmwpCiAgICByZXR1cm4gewogICAgICAgICJzdGF0dXMiOiByZXNwLnN0YXR1cywKICAgICAgICAiY29udGVudF9sZW5ndGgiOiBsZW4ocmVzcC5jb250ZW50KSwKICAgICAgICAiY29udGVudCI6IHJlc3AuY29udGVudC5kZWNvZGUoJ3V0Zi04JywgZXJyb3JzPSdyZXBsYWNlJylbOjUwMDBdLAogICAgICAgICJoZWFkZXJzIjogcmVzcC5oZWFkZXJzCiAgICB9CgpAc2VydmVyLnRvb2woIm93bF9zdGF0cyIsICJHZXQgcHJveHkgcG9vbCBzdGF0aXN0aWNzIGluY2x1ZGluZyBoZWFsdGh5IHByb3h5IGNvdW50IGFuZCBxdWFsaXR5IHNjb3JlcyIpCmFzeW5jIGRlZiBoYW5kbGVfc3RhdHMoYXJnczogRGljdCkgLT4gQW55OgogICAgY2xpZW50ID0gYXdhaXQgZ2V0X2NsaWVudCgpCiAgICByZXR1cm4gYXdhaXQgY2xpZW50LmdldF9zdGF0cygpCgpAc2VydmVyLnRvb2woIm93bF9mZXRjaF9icm93c2VyIiwgIkZldGNoIGEgVVJMIHVzaW5nIGhlYWRsZXNzIGJyb3dzZXIgZm9yIEphdmFTY3JpcHQtcmVuZGVyZWQgY29udGVudCIpCmFzeW5jIGRlZiBoYW5kbGVfZmV0Y2hfYnJvd3NlcihhcmdzOiBEaWN0KSAtPiBBbnk6CiAgICB1cmwgPSBhcmdzLmdldCgidXJsIikKICAgIGlmIG5vdCB1cmw6CiAgICAgICAgcmV0dXJuIHsiZXJyb3IiOiAiTWlzc2luZyB1cmwgcGFyYW1ldGVyIn0KCiAgICBjbGllbnQgPSBhd2FpdCBnZXRfY2xpZW50KCkKICAgIHJlc3AgPSBhd2FpdCBjbGllbnQucmVxdWVzdCgiR0VUIiwgdXJsLCBicm93c2VyPVRydWUpCiAgICByZXR1cm4gewogICAgICAgICJzdGF0dXMiOiByZXNwLnN0YXR1cywKICAgICAgICAiY29udGVudF9sZW5ndGgiOiBsZW4ocmVzcC5jb250ZW50KSwKICAgICAgICAiY29udGVudCI6IHJlc3AuY29udGVudC5kZWNvZGUoJ3V0Zi04JywgZXJyb3JzPSdyZXBsYWNlJylbOjUwMDBdCiAgICB9CgojIFJlZ2lzdGVyIHJlc291cmNlcwpAc2VydmVyLnJlc291cmNlKCJvd2w6Ly9wcm94eS1wb29sIiwgIlByb3h5IFBvb2wiLCAiQ3VycmVudCBwcm94eSBwb29sIHN0YXR1cyBhbmQgaGVhbHRoIikKYXN5bmMgZGVmIGdldF9wcm94eV9wb29sKCk6CiAgICBjbGllbnQgPSBhd2FpdCBnZXRfY2xpZW50KCkKICAgIHN0YXRzID0gYXdhaXQgY2xpZW50LmdldF9zdGF0cygpCiAgICByZXR1cm4gewogICAgICAgICJ0b3RhbCI6IHN0YXRzWyJwcm94aWVzX3RvdGFsIl0sCiAgICAgICAgImhlYWx0aHkiOiBzdGF0c1sicHJveGllc19oZWFsdGh5Il0sCiAgICAgICAgInNjb3JlcyI6IHN0YXRzWyJzY29yZXMiXQogICAgfQoKQHNlcnZlci5yZXNvdXJjZSgib3dsOi8vY29uZmlnIiwgIkNvbmZpZ3VyYXRpb24iLCAiT1dMLUFHRU5UIGNvbmZpZ3VyYXRpb24iKQphc3luYyBkZWYgZ2V0X2NvbmZpZygpOgogICAgcmV0dXJuIHsKICAgICAgICAidmVyc2lvbiI6ICI0LjIuMCIsCiAgICAgICAgImN1cmxfY2ZmaSI6IFRydWUsCiAgICAgICAgInJlZGlzIjogRmFsc2UsCiAgICAgICAgImNvdW50cmllcyI6IFsiVVMiLCAiR0IiLCAiREUiLCAiRlIiLCAiQ0EiXSwKICAgICAgICAidHRsIjogMzAwLAogICAgICAgICJyYXRlIjogMS4wCiAgICB9CgojIE1haW4KYXN5bmMgZGVmIG1haW4oKToKICAgICIiIlJ1biBNQ1Agc2VydmVyIHZpYSBzdGRpbyIiIgogICAgcmVhZGVyID0gYXN5bmNpby5TdHJlYW1SZWFkZXIoKQogICAgcHJvdG9jb2wgPSBhc3luY2lvLlN0cmVhbVJlYWRlclByb3RvY29sKHJlYWRlcikKICAgIGF3YWl0IGFzeW5jaW8uZ2V0X2V2ZW50X2xvb3AoKS5jb25uZWN0X3JlYWRfcGlwZShsYW1iZGE6IHByb3RvY29sLCBzeXMuc3RkaW4uYnVmZmVyKQoKICAgIHdoaWxlIFRydWU6CiAgICAgICAgbGluZSA9IGF3YWl0IHJlYWRlci5yZWFkbGluZSgpCiAgICAgICAgaWYgbm90IGxpbmU6CiAgICAgICAgICAgIGJyZWFrCgogICAgICAgIHRyeToKICAgICAgICAgICAgcmVxdWVzdCA9IGpzb24ubG9hZHMobGluZS5kZWNvZGUoKS5zdHJpcCgpKQogICAgICAgICAgICByZXNwb25zZSA9IGF3YWl0IHNlcnZlci5oYW5kbGVfcmVxdWVzdChyZXF1ZXN0KQogICAgICAgICAgICBwcmludChqc29uLmR1bXBzKHJlc3BvbnNlKSwgZmx1c2g9VHJ1ZSkKICAgICAgICBleGNlcHQgRXhjZXB0aW9uIGFzIGU6CiAgICAgICAgICAgIHByaW50KGpzb24uZHVtcHMoeyJqc29ucnBjIjogIjIuMCIsICJpZCI6IDEsICJlcnJvciI6IHsiY29kZSI6IC0zMjYwMywgIm1lc3NhZ2UiOiBzdHIoZSl9fSksIGZsdXNoPVRydWUpCgppZiBfX25hbWVfXyA9PSAiX19tYWluX18iOgogICAgYXN5bmNpby5ydW4obWFpbigpKQo="

main "$@"
