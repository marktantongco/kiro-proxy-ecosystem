#!/bin/bash
# 🦉 OWL-AGENT Proxy Defense Stack + kiro-cli Installer v3.3 (robust retries)
set -e

echo "============================================="
echo "🦉 OWL-AGENT Proxy Defense Stack + kiro-cli v3.3"
echo "============================================="

INSTALL_DIR="$HOME/.owl-agent"
VENV_DIR="$INSTALL_DIR/venv"
CONFIG_DIR="$INSTALL_DIR/config"
CACHE_DIR="$INSTALL_DIR/cache/http"

# ---- warn if root ----
if [ "$EUID" -eq 0 ]; then
    echo "⚠️  You are running as root. Installation will go to /root/.owl-agent."
    echo "   Press Ctrl+C now to cancel, or wait 5 seconds to continue."
    sleep 5
fi

# ---- [1/5] System dependencies ----
echo ""
echo "[1/5] Installing minimal system dependencies..."
sudo apt update
sudo apt install -y python3-pip python3-venv python3-dev libffi-dev libssl-dev build-essential curl wget

# ---- [2/5] Directory structure ----
echo ""
echo "[2/5] Creating directories..."
mkdir -p "$INSTALL_DIR" "$CONFIG_DIR" "$CACHE_DIR"

# ---- [3/5] Proxy defense script ----
echo ""
echo "[3/5] Writing patched proxy_defense_fixed_v3.py ..."
cat > "$INSTALL_DIR/proxy_defense_fixed_v3.py" << 'EOF'
#!/usr/bin/env python3
"""
🦉 OWL-AGENT PROXY DEFENSE STACK v3.2
- Config loading and auth injection
- Health check pipeline
- Weighted proxy selection
- Per-domain circuit breaker
"""

import asyncio
import hashlib
import json
import time
import random
import logging
import os
from collections import defaultdict
from dataclasses import dataclass, field
from typing import Optional, Dict, Any, Callable, Awaitable, List
from pathlib import Path
from urllib.parse import urlparse

import aiohttp
import aiofiles

CACHE_DIR = Path.home() / ".owl-agent" / "cache" / "http"
CACHE_DIR.mkdir(parents=True, exist_ok=True)

CONFIG_DIR = Path.home() / ".owl-agent" / "config"
PROXY_POOL_FILE = CONFIG_DIR / "proxy_pool.json"
PROXY_CREDS_FILE = CONFIG_DIR / "proxy_credentials.json"

DEFAULT_TTL = 300
DEFAULT_RATE = 1.0
MAX_RETRIES = 3

logging.basicConfig(level=logging.INFO, format='%(asctime)s [%(levelname)s] %(name)s: %(message)s')
logger = logging.getLogger("owl-agent.proxy")

@dataclass
class CachedResponse:
    status: int
    content: bytes
    headers: Dict[str, str]
    timestamp: float
    ttl: int
    protocol: str = "http/1.1"
    def is_fresh(self) -> bool:
        return time.time() - self.timestamp < self.ttl

@dataclass
class TokenBucket:
    rate: float
    capacity: float
    tokens: float = 0.0
    last_update: float = field(default_factory=time.time)
    lock: asyncio.Lock = field(default_factory=asyncio.Lock)
    async def _replenish(self):
        now = time.time()
        elapsed = now - self.last_update
        async with self.lock:
            self.tokens = min(self.capacity, self.tokens + elapsed * self.rate)
            self.last_update = now
    async def acquire(self, tokens: float = 1.0) -> bool:
        await self._replenish()
        async with self.lock:
            if self.tokens >= tokens:
                self.tokens -= tokens
                return True
        wait_time = (tokens - self.tokens) / self.rate
        await asyncio.sleep(wait_time)
        return await self.acquire(tokens)

@dataclass
class ProxyEntry:
    url: str
    proxy_type: str
    protocol: str
    source: str
    tier: int
    auth_ref: Optional[str] = None
    healthy: bool = True
    last_check: float = 0.0
    fail_count: int = 0
    ban_until: float = 0.0
    latency_ms: float = 9999.0
    success_count: int = 0
    
    def is_banned(self) -> bool:
        return time.time() < self.ban_until
        
    def mark_failed(self):
        self.fail_count += 1
        # Exponential backoff: 60 * (2 ^ (fail_count - 1))
        backoff = 60 * (2 ** min(self.fail_count - 1, 6))
        self.ban_until = time.time() + backoff
        self.healthy = False
        logger.warning(f"Proxy banned ({backoff}s): {self.url}")
        
    def mark_success(self, latency_ms: float):
        self.fail_count = 0
        self.healthy = True
        self.latency_ms = (self.latency_ms * 0.7) + (latency_ms * 0.3) if self.success_count > 0 else latency_ms
        self.last_check = time.time()
        self.success_count += 1
        
    def get_score(self) -> float:
        if not self.healthy or self.is_banned():
            return 0.0
        # Score based on latency and success
        base_score = 10000 / max(self.latency_ms, 1)
        tier_multiplier = {1: 1.5, 2: 1.0, 3: 0.5}.get(self.tier, 1.0)
        success_bonus = min(self.success_count, 10) * 0.1
        return base_score * tier_multiplier * (1 + success_bonus)

class ProxyPoolLoader:
    def __init__(self, pool_file: Path = PROXY_POOL_FILE, creds_file: Path = PROXY_CREDS_FILE):
        self.pool_file = pool_file
        self.creds_file = creds_file
        
    def _load_credentials(self) -> dict:
        if not self.creds_file.exists():
            return {}
        try:
            with open(self.creds_file) as f:
                data = json.load(f)
                return data.get("providers", {})
        except Exception as e:
            logger.error(f"Failed to load credentials: {e}")
            return {}

    def _inject_auth(self, url: str, auth_ref: str, credentials: dict) -> str:
        if not auth_ref or auth_ref not in credentials:
            return url
        creds = credentials[auth_ref]
        username = os.getenv(f"PROXY_{auth_ref.upper()}_USERNAME", creds.get("username", ""))
        password = os.getenv(f"PROXY_{auth_ref.upper()}_PASSWORD", creds.get("password", ""))
        
        if not username or not password:
            return url
            
        parsed = urlparse(url)
        return f"{parsed.scheme}://{username}:{password}@{parsed.netloc}"

    def load(self) -> List[ProxyEntry]:
        if not self.pool_file.exists():
            return []
        
        credentials = self._load_credentials()
            
        try:
            with open(self.pool_file) as f:
                config = json.load(f)
        except Exception:
            return []
            
        proxies = []
        for provider in config.get("tier_1_managed_free", {}).get("providers", []):
            provider_auth_ref = provider.get("auth_ref")
            for proxy in provider.get("proxies", []):
                auth_ref = proxy.get("auth_ref", provider_auth_ref)
                
                # Default Webshare IP rotation formatting
                url = proxy["url"]
                if auth_ref == "webshare" and credentials.get("webshare", {}).get("backbone_prefix"):
                    creds = credentials["webshare"]
                    if creds.get("username") and creds.get("password") and proxy.get("backbone_id"):
                        username = f"{creds['username']}-{creds['backbone_prefix']}{proxy['backbone_id']}"
                        parsed = urlparse(url)
                        url = f"{parsed.scheme}://{username}:{creds['password']}@{parsed.netloc}"
                elif auth_ref:
                    url = self._inject_auth(url, auth_ref, credentials)

                proxies.append(ProxyEntry(
                    url=url,
                    proxy_type=proxy.get("type", "datacenter"),
                    protocol=proxy.get("protocols", ["HTTP"])[0].lower(),
                    source=provider["name"],
                    tier=1,
                    auth_ref=auth_ref
                ))
        return proxies

    async def fetch_worldpool_proxies(self, session: aiohttp.ClientSession) -> List[ProxyEntry]:
        # Dummy fetch for Worldpool as per plan
        return []
        
    async def fetch_github_proxies(self, session: aiohttp.ClientSession) -> List[ProxyEntry]:
        proxies = []
        sources = [("https://cdn.jsdelivr.net/gh/proxifly/free-proxy-list@main/proxies/all/data.json", "json")]
        for url, fmt in sources:
            try:
                async with session.get(url, timeout=10) as resp:
                    if resp.status != 200: continue
                    if fmt == "json":
                        data = await resp.json()
                        items = data.get("data", []) if isinstance(data, dict) else data
                        for item in items[:50]:
                            ip = item.get("ip", item.get("host", ""))
                            port = item.get("port", "")
                            if ip and port:
                                proxies.append(ProxyEntry(
                                    url=f"http://{ip}:{port}", proxy_type="public", protocol=item.get("protocol", "http").lower(),
                                    source="github", tier=2
                                ))
                    else:
                        text = await resp.text()
                        for line in text.strip().split("\n")[:50]:
                            if ":" in line and not line.startswith("#"):
                                proxies.append(ProxyEntry(url=f"http://{line.strip()}", proxy_type="public", protocol="http", source="github", tier=2))
                break
            except Exception as e:
                logger.debug(f"GitHub fetch failed: {e}")
        return proxies

class HTTPCache:
    def __init__(self, ttl: int = DEFAULT_TTL):
        self.ttl = ttl
        self._memory: Dict[str, CachedResponse] = {}
        self._lock = asyncio.Lock()
    def _key(self, method: str, url: str, params: Optional[Dict] = None, protocol: str = "http/1.1") -> str:
        return hashlib.sha256(f"{method}:{url}:{json.dumps(params or {}, sort_keys=True)}:{protocol}".encode()).hexdigest()
    async def get(self, method: str, url: str, params: Optional[Dict] = None, protocol: str = "http/1.1") -> Optional[CachedResponse]:
        key = self._key(method, url, params, protocol)
        if key in self._memory and self._memory[key].is_fresh():
            return self._memory[key]
        return None
    async def set(self, method: str, url: str, response: CachedResponse, params: Optional[Dict] = None):
        key = self._key(method, url, params, response.protocol)
        async with self._lock:
            self._memory[key] = response

class RequestDeduplicator:
    def __init__(self):
        self._in_flight: Dict[str, asyncio.Future] = {}
        self._lock = asyncio.Lock()
    def _key(self, method: str, url: str, params: Optional[Dict] = None, protocol: str = "http/1.1") -> str:
        return hashlib.sha256(f"{method}:{url}:{json.dumps(params or {}, sort_keys=True)}:{protocol}".encode()).hexdigest()
    async def execute(self, method: str, url: str, params: Optional[Dict], protocol: str, factory: Callable[[], Awaitable[CachedResponse]]) -> CachedResponse:
        key = self._key(method, url, params, protocol)
        async with self._lock:
            if key in self._in_flight:
                return await self._in_flight[key]
            future = asyncio.Future()
            self._in_flight[key] = future
        try:
            result = await factory()
            future.set_result(result)
            return result
        except Exception as e:
            future.set_exception(e)
            raise
        finally:
            async with self._lock:
                self._in_flight.pop(key, None)

class DomainRateLimiter:
    def __init__(self, default_rate: float = DEFAULT_RATE):
        self.default_rate = default_rate
        self._buckets: Dict[str, TokenBucket] = {}
        self._lock = asyncio.Lock()
    async def acquire(self, url: str, tokens: float = 1.0):
        domain = urlparse(url).netloc or url
        async with self._lock:
            if domain not in self._buckets:
                self._buckets[domain] = TokenBucket(rate=self.default_rate, capacity=5.0, tokens=5.0)
        await self._buckets[domain].acquire(tokens)

class HealthChecker:
    @staticmethod
    async def check(session: aiohttp.ClientSession, proxy: ProxyEntry) -> bool:
        try:
            start = time.time()
            async with session.get("http://httpbin.org/ip", proxy=proxy.url, timeout=aiohttp.ClientTimeout(total=10)) as resp:
                if resp.status == 200:
                    proxy.mark_success((time.time() - start) * 1000)
                    return True
        except Exception:
            pass
        proxy.mark_failed()
        return False

class ProxyRotator:
    def __init__(self):
        self.proxies: List[ProxyEntry] = []
        self._lock = asyncio.Lock()
        self._loader = ProxyPoolLoader()
        
    async def load_all_sources(self, session: aiohttp.ClientSession):
        self.proxies = self._loader.load()
        self.proxies.extend(await self._loader.fetch_github_proxies(session))
        # Pre-validate some proxies
        tasks = [HealthChecker.check(session, p) for p in self.proxies[:20]]
        await asyncio.gather(*tasks)
        logger.info(f"Loaded {len(self.proxies)} proxies")
        
    async def get_proxy(self) -> Optional[ProxyEntry]:
        async with self._lock:
            healthy = [p for p in self.proxies if not p.is_banned()]
            if not healthy:
                return None
            
            # Weighted random selection based on score
            scores = [p.get_score() for p in healthy]
            total = sum(scores)
            if total == 0:
                return random.choice(healthy)
                
            r = random.uniform(0, total)
            current = 0
            for p, score in zip(healthy, scores):
                current += score
                if r <= current:
                    return p
            return healthy[-1]
            
    async def mark_banned(self, proxy: ProxyEntry):
        proxy.mark_failed()

class DomainCircuitBreaker:
    def __init__(self, failure_threshold: int = 5, recovery_timeout: int = 60):
        self.failure_threshold = failure_threshold
        self.recovery_timeout = recovery_timeout
        self.failures: Dict[str, int] = defaultdict(int)
        self.open_until: Dict[str, float] = {}
        
    def record_failure(self, domain: str):
        self.failures[domain] += 1
        if self.failures[domain] >= self.failure_threshold:
            self.open_until[domain] = time.time() + self.recovery_timeout
            logger.warning(f"Circuit breaker OPEN for {domain}")
            
    def record_success(self, domain: str):
        self.failures[domain] = 0
        if domain in self.open_until:
            del self.open_until[domain]
            logger.info(f"Circuit breaker CLOSED for {domain}")
            
    def can_request(self, domain: str) -> bool:
        if domain in self.open_until:
            if time.time() > self.open_until[domain]:
                # Half-open state
                return True
            return False
        return True

class ResilientClient:
    def __init__(self, cache_ttl: int = DEFAULT_TTL, rate_limit: float = DEFAULT_RATE, max_retries: int = MAX_RETRIES):
        self.cache = HTTPCache(cache_ttl)
        self.dedup = RequestDeduplicator()
        self.limiter = DomainRateLimiter(rate_limit)
        self.rotator = ProxyRotator()
        self.circuit_breaker = DomainCircuitBreaker()
        self.max_retries = max_retries
        self._session: Optional[aiohttp.ClientSession] = None

    async def __aenter__(self):
        connector = aiohttp.TCPConnector(force_close=True, enable_cleanup_closed=True, limit=10)
        self._session = aiohttp.ClientSession(connector=connector)
        await self.rotator.load_all_sources(self._session)
        return self

    async def __aexit__(self, *args):
        if self._session:
            await self._session.close()

    async def request(self, method: str, url: str, params: Optional[Dict] = None, headers: Optional[Dict] = None, **kwargs) -> CachedResponse:
        cached = await self.cache.get(method, url, params)
        if cached:
            return cached
            
        domain = urlparse(url).netloc or url
        if not self.circuit_breaker.can_request(domain):
            raise RuntimeError(f"Circuit breaker open for {domain}")

        async def factory():
            return await self._execute_with_retry(method, url, params, headers, domain, **kwargs)
        return await self.dedup.execute(method, url, params, "http/1.1", factory)

    async def _execute_with_retry(self, method, url, params, headers, domain, **kwargs):
        # Try proxies up to max_retries
        for attempt in range(self.max_retries):
            await self.limiter.acquire(url)
            proxy = await self.rotator.get_proxy()
            proxy_url = proxy.url if proxy else None
            
            try:
                start = time.time()
                async with self._session.request(method, url, params=params, headers=headers,
                                                 proxy=proxy_url, timeout=aiohttp.ClientTimeout(total=30), **kwargs) as resp:
                    content = await resp.read()
                latency = (time.time() - start) * 1000
                response = CachedResponse(status=resp.status, content=content, headers=dict(resp.headers), timestamp=time.time(), ttl=self.cache.ttl)
                
                if proxy:
                    proxy.mark_success(latency)
                self.circuit_breaker.record_success(domain)
                
                await self.cache.set(method, url, response, params)
                
                if resp.status in (429, 403, 407):
                    if proxy:
                        await self.rotator.mark_banned(proxy)
                    continue
                return response
                
            except (aiohttp.ClientOSError, aiohttp.ClientProxyConnectionError, aiohttp.ServerDisconnectedError, ConnectionResetError) as e:
                if proxy:
                    await self.rotator.mark_banned(proxy)
                logger.warning(f"Proxy failed: {e}, retry {attempt+1}/{self.max_retries}")
                continue
            except Exception as e:
                if proxy:
                    await self.rotator.mark_banned(proxy)
                logger.warning(f"Error with proxy: {e}, retrying")
                continue

        self.circuit_breaker.record_failure(domain)

        # --- All proxies failed, try direct connection ---
        logger.info("All proxies exhausted, attempting direct connection...")
        try:
            async with self._session.request(method, url, params=params, headers=headers,
                                             timeout=aiohttp.ClientTimeout(total=30)) as resp:
                content = await resp.read()
            response = CachedResponse(status=resp.status, content=content, headers=dict(resp.headers), timestamp=time.time(), ttl=self.cache.ttl)
            await self.cache.set(method, url, response, params)
            self.circuit_breaker.record_success(domain)
            return response
        except Exception as e:
            self.circuit_breaker.record_failure(domain)
            raise RuntimeError(f"Direct connection also failed: {e}")

    async def get_stats(self):
        healthy = sum(1 for p in self.rotator.proxies if not p.is_banned())
        return {"proxies_total": len(self.rotator.proxies), "proxies_healthy": healthy}

async def main():
    print("🦉 OWL-AGENT Proxy Defense Stack v3.2 (Auth Injection Enabled)")
    async with ResilientClient() as client:
        stats = await client.get_stats()
        print(f"Proxy pool: {stats['proxies_total']} total, {stats['proxies_healthy']} healthy (non-banned)")
        try:
            resp = await client.request("GET", "https://api.github.com/users/octocat")
            print(f"✅ Success! Status: {resp.status}, content length: {len(resp.content)} bytes")
            if resp.status == 200:
                data = json.loads(resp.content)
                print(f"   User: {data.get('login')} - {data.get('name')}")
        except Exception as e:
            print(f"❌ All attempts failed, including direct: {e}")

if __name__ == "__main__":
    asyncio.run(main())
EOF

# ---- [4/5] Python environment and packages (with retries) ----
echo ""
echo "[4/5] Creating virtual environment and installing Python packages..."
python3 -m venv "$VENV_DIR"
source "$VENV_DIR/bin/activate"
pip install --upgrade pip

# Helper: install package with retries for transient network errors
install_with_retry() {
    local pkg="$1"
    local max_attempts=3
    local attempt=1
    while [ $attempt -le $max_attempts ]; do
        echo "   Installing $pkg (attempt $attempt/$max_attempts)..."
        if pip install "$pkg"; then
            echo "   ✅ $pkg installed successfully."
            return 0
        fi
        echo "   ⚠️  Failed. Waiting 5 seconds before retry..."
        sleep 5
        attempt=$((attempt + 1))
    done
    echo "   ❌ Failed to install $pkg after $max_attempts attempts."
    return 1
}

# Core dependencies (always needed)
install_with_retry 'httpx[http2]' || true
install_with_retry aiohttp || true
install_with_retry aiohttp-socks || true
install_with_retry aiofiles || true
install_with_retry curl_cffi || true

# kiro-cli – the tool that caused the DNS hiccup
echo ""
echo "   → Installing kiro-cli native binary (with retries for network glitches)..."

ARCH=$(uname -m)
case "$ARCH" in
    x86_64|amd64)  ARCH_DETECTED="x86_64" ;;
    aarch64|arm64) ARCH_DETECTED="aarch64" ;;
    *) echo "Unsupported architecture: $ARCH"; exit 1 ;;
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

if curl -fsSL --proto '=https' --tlsv1.2 "$KIRO_URL" -o "$KIRO_ZIP_PATH"; then
    unzip -qo "$KIRO_ZIP_PATH" -d "/tmp/kirocli_extracted"
    mkdir -p "$HOME/.local/bin"
    cp "/tmp/kirocli_extracted/kirocli/kiro-cli" "$HOME/.local/bin/kiro-cli" 2>/dev/null || cp "/tmp/kirocli_extracted/kirocli-"* "/tmp/kirocli_extracted/kiro-cli" 2>/dev/null || true
    # Also copy to virtual environment bin directory
    cp "/tmp/kirocli_extracted/kirocli/kiro-cli" "$VENV_DIR/bin/kiro-cli" 2>/dev/null || cp "/tmp/kirocli_extracted/kiro-cli" "$VENV_DIR/bin/kiro-cli" 2>/dev/null || cp -r "/tmp/kirocli_extracted/"* "$VENV_DIR/bin/" 2>/dev/null || true
    chmod +x "$VENV_DIR/bin/kiro-cli" "$HOME/.local/bin/kiro-cli" 2>/dev/null || true
    rm -rf "$KIRO_ZIP_PATH" "/tmp/kirocli_extracted"
    echo "   🎉 kiro-cli ready."
else
    echo "⚠️  kiro-cli native binary installation failed."
fi

# ---- [5/5] Config and launchers ----
echo ""
echo "[5/5] Creating configuration and launcher scripts..."

# Default proxy pool
if [ ! -f "$CONFIG_DIR/proxy_pool.json" ]; then
    cat > "$CONFIG_DIR/proxy_pool.json" << 'CONFIG'
{
  "tier_1_managed_free": { "providers": [] },
  "comment": "Add your own proxies here or rely on auto-fetched ones."
}
CONFIG
fi

# Runner for proxy defense stack
cat > "$INSTALL_DIR/run.sh" << 'RUNNER'
#!/bin/bash
source "$HOME/.owl-agent/venv/bin/activate"
cd "$HOME/.owl-agent"
python proxy_defense_fixed_v3.py "$@"
RUNNER
chmod +x "$INSTALL_DIR/run.sh"

# Wrapper for kiro-cli
cat > "$INSTALL_DIR/kiro-cli" << 'KIRO_WRAP'
#!/bin/bash
# 🦉 Explicitly route kiro-cli through the OWL Agent Forward Proxy & Clash
export HTTP_PROXY="http://127.0.0.1:60000"
export HTTPS_PROXY="http://127.0.0.1:60000"
export NO_PROXY="localhost,127.0.0.1,.local,.localdomain,::1"

source "$HOME/.owl-agent/venv/bin/activate"
exec kiro-cli "$@"
KIRO_WRAP
chmod +x "$INSTALL_DIR/kiro-cli"

# ---- [6/5] Deploy Diagnostics & Self-Healing Tool ----
echo ""
echo "[6/5] Deploying diagnose_opencode.sh self-healing tool..."
cat > "$INSTALL_DIR/diagnose_opencode.sh" << 'DIAGNOSTICS'
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
DIAGNOSTICS
chmod +x "$INSTALL_DIR/diagnose_opencode.sh"

# Auto-Register Alias in ~/.bashrc
if ! grep -q "alias owl-check=" "$HOME/.bashrc" 2>/dev/null; then
    echo "" >> "$HOME/.bashrc"
    echo "# 🦉 OWL-AGENT Proxy Diagnostics & Self-Healing Suite Shortcut" >> "$HOME/.bashrc"
    echo "alias owl-check='$INSTALL_DIR/diagnose_opencode.sh'" >> "$HOME/.bashrc"
    echo "✅ Registered 'owl-check' shortcut alias in ~/.bashrc"
fi

# ---- Final messages ----
echo ""
echo "============================================="
echo "✅ Installation complete!"
echo "============================================="
echo ""
echo "▶️  Run the proxy defense stack:"
echo "   $INSTALL_DIR/run.sh"
echo ""
echo "▶️  Run diagnostic self-healing suite:"
echo "   owl-check"
echo "   (or: $INSTALL_DIR/diagnose_opencode.sh)"
echo ""
echo "▶️  Use kiro-cli:"
echo "   $INSTALL_DIR/kiro-cli [arguments]"
echo ""
echo "   Add ~/.owl-agent to your PATH for convenience:"
echo "   export PATH=\"\$HOME/.owl-agent:\$PATH\""
echo ""
if [ "$EUID" -eq 0 ]; then
    echo "⚠️  Installed as root. All files are in /root/.owl-agent."
    echo "   You must prefix commands with sudo, e.g.:"
    echo "   sudo $INSTALL_DIR/run.sh"
    echo "   sudo $INSTALL_DIR/kiro-cli"
else
    echo "✅ Installed under your home directory. No sudo needed to run."
fi
echo ""
echo "🔧 The proxy script automatically falls back to direct connection when all proxies fail."
echo "   You can add your own proxies in $CONFIG_DIR/proxy_pool.json"
echo "============================================="