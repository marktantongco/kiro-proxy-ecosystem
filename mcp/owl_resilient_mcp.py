#!/usr/bin/env python3
"""
🦉 OWL-RESILIENT-HTTP MCP Server v1.0

HTTP resilience middleware for AI agents.
  - HTTP response caching with stale-if-fail
  - Request deduplication (coalesce concurrent identical fetches)
  - Per-domain circuit breaker with half-open recovery
  - Per-domain token-bucket rate limiting
  - Multi-target health checking (3 diverse endpoints)
  - Response schema validation (optional per-request)
  - Offline priority queue with automatic replay
  - Graceful degradation: cache → stale → degraded → queue

Exposed as OpenCode MCP tools:
  fetch_resilient(method, url, headers, body, cache_ttl, schema)
  fetch_status()         — cache/circuit/queue stats
  fetch_clear_cache()    — flush all cached responses
  health_check()         — check all health targets
  queue_status()         — inspect pending/replaying/completed queue

Usage:
  Add to ~/.opencode/mcp.json:
    "owl-resilient-http": {
      "command": "python3",
      "args": ["/path/to/owl_resilient_mcp.py"]
    }
"""

import hashlib
import json
import os
import sys
import time
import threading
import heapq
from collections import defaultdict
from dataclasses import dataclass, field
from typing import Optional, Dict, Any, List, Tuple, Callable
from urllib.parse import urlparse
from pathlib import Path

import httpx

# ─── Configuration ──────────────────────────────────────────────────────────

CACHE_DIR = Path.home() / ".owl-agent" / "cache" / "mcp"
CACHE_DIR.mkdir(parents=True, exist_ok=True)

DEFAULT_TTL = 300           # 5 minutes
DEFAULT_RATE = 2.0          # 2 req/s per domain default
MAX_RETRIES = 2
CB_THRESHOLD = 5            # failures before circuit opens
CB_TIMEOUT = 60             # seconds before half-open
QUEUE_REPLAY_INTERVAL = 15  # seconds between queue replay sweeps
STALE_TTL_MULTIPLIER = 12   # stale responses kept for 12x TTL

HEALTH_TARGETS = [
    {"name": "httpbin", "url": "https://httpbin.org/ip",        "desc": "General internet connectivity (IP echo)"},
    {"name": "github",  "url": "https://api.github.com/zen",    "desc": "API endpoint (common Hermes target)"},
    {"name": "google",  "url": "https://www.google.com/generate_204", "desc": "Internet backbone (lightweight 204)"},
]

# ─── Data Types ─────────────────────────────────────────────────────────────

@dataclass
class CachedResponse:
    status: int
    content: bytes
    content_text: str
    headers: Dict[str, str]
    timestamp: float
    ttl: int
    validated: bool = True
    validation_errors: List[str] = field(default_factory=list)

    def is_fresh(self) -> bool:
        return time.time() - self.timestamp < self.ttl

    def is_stale(self) -> bool:
        return time.time() - self.timestamp < self.ttl * STALE_TTL_MULTIPLIER

    def age_seconds(self) -> float:
        return time.time() - self.timestamp


@dataclass
class QueuedRequest:
    method: str
    url: str
    headers: Optional[Dict[str, str]]
    body: Optional[str]
    priority: int           # 0=HIGH, 1=MEDIUM, 2=LOW
    timestamp: float
    retry_count: int = 0
    max_retries: int = 3
    error: Optional[str] = None

    def __lt__(self, other: "QueuedRequest") -> bool:
        # Higher priority (lower number) first, then older first
        if self.priority != other.priority:
            return self.priority < other.priority
        return self.timestamp < other.timestamp


@dataclass
class SchemaSpec:
    """Describes expected response schema for validation."""
    expect_status: Optional[int] = None
    expect_json_fields: Optional[List[str]] = None
    expect_content_type: Optional[str] = None
    expect_body_contains: Optional[List[str]] = None

    @classmethod
    def from_dict(cls, d: dict) -> "SchemaSpec":
        return cls(
            expect_status=d.get("expect_status"),
            expect_json_fields=d.get("expect_json_fields"),
            expect_content_type=d.get("expect_content_type"),
            expect_body_contains=d.get("expect_body_contains"),
        )


HEALTH_TARGETS = [
    {"name": "httpbin", "url": "https://httpbin.org/ip",        "desc": "General internet connectivity (IP echo)"},
    {"name": "github",  "url": "https://api.github.com/zen",    "desc": "API endpoint (common Hermes target)"},
    {"name": "google",  "url": "https://www.google.com/generate_204", "desc": "Internet backbone (lightweight 204)"},
]

# ─── Token Bucket Rate Limiter ──────────────────────────────────────────────

class TokenBucket:
    """Thread-safe token bucket for rate limiting."""
    def __init__(self, rate: float, capacity: float):
        self.rate = rate
        self.capacity = capacity
        self.tokens = capacity
        self.last_update = time.time()
        self._lock = threading.Lock()

    def _replenish(self):
        now = time.time()
        elapsed = now - self.last_update
        with self._lock:
            self.tokens = min(self.capacity, self.tokens + elapsed * self.rate)
            self.last_update = now

    def acquire(self, tokens: float = 1.0) -> float:
        """Try to acquire tokens. Returns wait time in seconds (0 = can proceed)."""
        self._replenish()
        with self._lock:
            if self.tokens >= tokens:
                self.tokens -= tokens
                return 0.0
            deficit = tokens - self.tokens
            return deficit / self.rate

    def wait_time(self) -> float:
        """Return seconds until a single token is available."""
        self._replenish()
        with self._lock:
            if self.tokens >= 1.0:
                return 0.0
            return (1.0 - self.tokens) / self.rate


class DomainRateLimiter:
    """Per-domain rate limiter with auto-creation."""
    def __init__(self, default_rate: float = DEFAULT_RATE):
        self.default_rate = default_rate
        self._buckets: Dict[str, TokenBucket] = {}
        self._lock = threading.Lock()

    def _get_domain(self, url: str) -> str:
        return urlparse(url).netloc or url

    def acquire(self, url: str, tokens: float = 1.0) -> float:
        domain = self._get_domain(url)
        with self._lock:
            if domain not in self._buckets:
                self._buckets[domain] = TokenBucket(rate=self.default_rate, capacity=5.0)
        return self._buckets[domain].acquire(tokens)

    def stats(self) -> Dict[str, Dict[str, float]]:
        with self._lock:
            return {
                domain: {
                    "tokens": round(b.tokens, 2),
                    "rate": b.rate,
                    "capacity": b.capacity,
                    "wait_seconds": round(b.wait_time(), 3),
                }
                for domain, b in self._buckets.items()
            }


# ─── In-Memory HTTP Cache ──────────────────────────────────────────────────

class HTTPCache:
    """In-memory HTTP response cache with TTL support."""
    def __init__(self, ttl: int = DEFAULT_TTL):
        self.ttl = ttl
        self._memory: Dict[str, CachedResponse] = {}
        self._lock = threading.Lock()

    def _key(self, method: str, url: str, params: Optional[Dict] = None) -> str:
        return hashlib.sha256(
            f"{method}:{url}:{json.dumps(params or {}, sort_keys=True)}".encode()
        ).hexdigest()

    def get(self, method: str, url: str, params: Optional[Dict] = None,
            allow_stale: bool = False) -> Optional[CachedResponse]:
        key = self._key(method, url, params)
        with self._lock:
            entry = self._memory.get(key)
            if entry is None:
                return None
            if entry.is_fresh():
                return entry
            if allow_stale and entry.is_stale():
                return entry
            if not entry.is_stale():
                # Too old, remove
                del self._memory[key]
            return None

    def set(self, method: str, url: str, response: CachedResponse,
            params: Optional[Dict] = None):
        key = self._key(method, url, params)
        with self._lock:
            self._memory[key] = response

    def clear(self):
        with self._lock:
            count = len(self._memory)
            self._memory.clear()
            return count

    def stats(self) -> dict:
        with self._lock:
            fresh = sum(1 for r in self._memory.values() if r.is_fresh())
            stale = sum(1 for r in self._memory.values() if not r.is_fresh() and r.is_stale())
            return {"entries": len(self._memory), "fresh": fresh, "stale": stale}


# ─── Request Deduplicator ───────────────────────────────────────────────────

class RequestDeduplicator:
    """Coalesce concurrent identical requests so only one hits the network."""
    def __init__(self):
        self._in_flight: Dict[str, dict] = {}
        self._lock = threading.Lock()
        self._condition = threading.Condition(self._lock)

    def _key(self, method: str, url: str, params: Optional[Dict] = None) -> str:
        return hashlib.sha256(
            f"{method}:{url}:{json.dumps(params or {}, sort_keys=True)}".encode()
        ).hexdigest()

    def execute(self, method: str, url: str, params: Optional[Dict],
                factory: Callable[[], Any]) -> Any:
        key = self._key(method, url, params)
        with self._condition:
            if key in self._in_flight:
                # Another thread is already fetching — wait for result
                while self._in_flight.get(key, {}).get("status") == "pending":
                    self._condition.wait(30)
                result = self._in_flight.get(key, {}).get("result")
                error = self._in_flight.get(key, {}).get("error")
                if error:
                    raise RuntimeError(error)
                return result
            self._in_flight[key] = {"status": "pending", "result": None, "error": None}

        try:
            result = factory()
            with self._condition:
                self._in_flight[key] = {"status": "done", "result": result, "error": None}
                self._condition.notify_all()
            return result
        except Exception as e:
            with self._condition:
                self._in_flight[key] = {"status": "done", "result": None, "error": str(e)}
                self._condition.notify_all()
            raise
        finally:
            # Clean up after a short delay so late waiters can still read
            def _cleanup():
                time.sleep(0.5)
                with self._condition:
                    self._in_flight.pop(key, None)
            threading.Thread(target=_cleanup, daemon=True).start()

    def stats(self) -> dict:
        with self._lock:
            in_flight = sum(1 for v in self._in_flight.values() if v["status"] == "pending")
            completed = sum(1 for v in self._in_flight.values() if v["status"] == "done")
            return {"in_flight": in_flight, "cached_keys": len(self._in_flight)}


# ─── Domain Circuit Breaker ────────────────────────────────────────────────

class DomainCircuitBreaker:
    """
    Per-domain circuit breaker.
    States: CLOSED (normal) → OPEN (failures ≥ threshold) → HALF-OPEN (after timeout)
    """
    CLOSED = "CLOSED"
    OPEN = "OPEN"
    HALF_OPEN = "HALF_OPEN"

    def __init__(self, failure_threshold: int = CB_THRESHOLD, recovery_timeout: int = CB_TIMEOUT):
        self.failure_threshold = failure_threshold
        self.recovery_timeout = recovery_timeout
        self.failures: Dict[str, int] = defaultdict(int)
        self.open_until: Dict[str, float] = {}
        self.state_lock = threading.Lock()

    def get_state(self, domain: str) -> str:
        with self.state_lock:
            if domain not in self.open_until:
                return self.CLOSED
            if time.time() > self.open_until[domain]:
                return self.HALF_OPEN
            return self.OPEN

    def record_failure(self, domain: str) -> str:
        """Returns the new state."""
        with self.state_lock:
            self.failures[domain] += 1
            if self.failures[domain] >= self.failure_threshold:
                self.open_until[domain] = time.time() + self.recovery_timeout
                return self.OPEN
            return self.CLOSED

    def record_success(self, domain: str):
        with self.state_lock:
            self.failures[domain] = 0
            self.open_until.pop(domain, None)

    def can_request(self, domain: str) -> Tuple[bool, str]:
        """Returns (can_proceed, state)."""
        state = self.get_state(domain)
        if state == self.CLOSED:
            return True, state
        if state == self.HALF_OPEN:
            return True, state
        return False, state

    def stats(self) -> dict:
        with self.state_lock:
            return {
                domain: {
                    "state": self.get_state(domain),
                    "failures": count,
                    "opens_in": max(0, round(self.open_until.get(domain, 0) - time.time(), 1))
                    if domain in self.open_until else 0,
                }
                for domain, count in dict(self.failures).items()
            }


# ─── Multi-Target Health Checker ───────────────────────────────────────────

class HealthChecker:
    """Check multiple diverse endpoints to gauge connectivity health."""
    def __init__(self):
        self._cache: Dict[str, dict] = {}
        self._cache_lock = threading.Lock()

    def check_all(self) -> List[dict]:
        results = []
        for target in HEALTH_TARGETS:
            results.append(self._check_one(target))
        return results

    def _check_one(self, target: dict) -> dict:
        try:
            start = time.time()
            resp = httpx.get(target["url"], timeout=5.0)
            latency_ms = round((time.time() - start) * 1000, 1)
            ok = resp.status_code < 500
            result = {
                "name": target["name"],
                "url": target["url"],
                "description": target["desc"],
                "reachable": ok,
                "status_code": resp.status_code,
                "latency_ms": latency_ms,
                "error": None,
            }
        except Exception as e:
            result = {
                "name": target["name"],
                "url": target["url"],
                "description": target["desc"],
                "reachable": False,
                "status_code": None,
                "latency_ms": None,
                "error": str(e),
            }
        with self._cache_lock:
            self._cache[target["name"]] = {**result, "checked_at": time.time()}
        return result

    def last_results(self) -> List[dict]:
        with self._cache_lock:
            return list(self._cache.values())


# ─── Response Schema Validator ──────────────────────────────────────────────

class ResponseValidator:
    """Validate HTTP responses against expected schemas. Non-blocking."""

    @staticmethod
    def validate(response: CachedResponse, schema: Optional[SchemaSpec]) -> List[str]:
        """Returns list of validation errors. Empty = valid."""
        if schema is None:
            return []

        errors = []

        if schema.expect_status is not None and response.status != schema.expect_status:
            errors.append(f"Expected status {schema.expect_status}, got {response.status}")

        if schema.expect_content_type is not None:
            ct = response.headers.get("content-type", "")
            if schema.expect_content_type not in ct:
                errors.append(f"Expected content-type containing '{schema.expect_content_type}', got '{ct}'")

        body: str = ""
        if schema.expect_json_fields or schema.expect_body_contains:
            try:
                body = response.content_text
            except Exception:
                body = ""

        if schema.expect_json_fields:
            try:
                data = json.loads(body) if body else {}
                for field in schema.expect_json_fields:
                    # Support dotted paths eg "data.user.name"
                    parts = field.split(".")
                    val = data
                    for part in parts:
                        if isinstance(val, dict):
                            val = val.get(part, "_MISSING_")
                        else:
                            val = "_MISSING_"
                            break
                    if val == "_MISSING_":
                        errors.append(f"Missing expected JSON field: '{field}'")
            except json.JSONDecodeError:
                errors.append("Response is not valid JSON (expected JSON with fields)")

        if schema.expect_body_contains:
            for snippet in schema.expect_body_contains:
                if snippet not in body:
                    errors.append(f"Body does not contain expected text: '{snippet}'")

        return errors


# ─── Offline Priority Queue ─────────────────────────────────────────────────

QueueEntry = Tuple[int, float, str, "QueuedRequest"]


class OfflineQueue:
    """
    Priority queue for requests accumulated during circuit breaker downtime.
    Automatically replays when circuit breaker recovers.
    """
    def __init__(self, replay_interval: int = QUEUE_REPLAY_INTERVAL):
        self._queue: List[QueueEntry] = []              # min-heap: (priority, ts, id, req)
        self._completed: List[dict] = []                 # history (bounded to 100)
        self._lock = threading.Lock()
        self._replay_interval = replay_interval
        self._replay_thread: Optional[threading.Thread] = None
        self._stop_event = threading.Event()
        self._client: Optional[httpx.Client] = None

    def set_client(self, client: httpx.Client):
        self._client = client

    def _next_id(self) -> str:
        return hashlib.md5(
            f"{time.time()}:{threading.get_ident()}:{id(self)}".encode()
        ).hexdigest()[:12]

    def enqueue(self, method: str, url: str,
                headers: Optional[dict] = None,
                body: Optional[str] = None,
                priority: int = 1) -> str:
        """Enqueue a request. Returns a queue_id for tracking."""
        queue_id = self._next_id()
        req = QueuedRequest(
            method=method, url=url, headers=headers, body=body,
            priority=priority, timestamp=time.time(),
        )
        entry: QueueEntry = (priority, req.timestamp, queue_id, req)
        with self._lock:
            heapq.heappush(self._queue, entry)
        return queue_id

    def _pop_for_domain(self, domain: str) -> Optional[QueueEntry]:
        """Pop the highest-priority entry matching domain. O(n) scan but queue is small."""
        with self._lock:
            idx = None
            for i, (p, ts, qid, req) in enumerate(self._queue):
                if urlparse(req.url).netloc == domain:
                    idx = i
                    break
            if idx is None:
                return None
            entry = self._queue.pop(idx)
            heapq.heapify(self._queue)  # restore heap invariant
            return entry

    def replay_one(self, domain: str, circuit_breaker: DomainCircuitBreaker) -> bool:
        """Try to replay one queued request for the given domain. Returns True if any was replayed."""
        found = self._pop_for_domain(domain)
        if found is None:
            return False

        _p, _ts, qid, req = found
        try:
            client = self._client or httpx.Client(timeout=30)
            resp = client.request(req.method, req.url, headers=req.headers, content=req.body)
            ok = resp.status_code < 500
            result = {
                "queue_id": qid,
                "url": req.url,
                "status": resp.status_code,
                "success": ok,
                "replayed_at": time.time(),
            }
            if ok:
                circuit_breaker.record_success(domain)
            else:
                circuit_breaker.record_failure(domain)
        except Exception as e:
            result = {
                "queue_id": qid,
                "url": req.url,
                "status": None,
                "success": False,
                "error": str(e),
                "replayed_at": time.time(),
            }
        with self._lock:
            self._completed.append(result)
            self._completed = self._completed[-100:]
        return True

    def start_replay_loop(self, circuit_breaker: DomainCircuitBreaker):
        """Background thread: periodically try to replay queued requests."""
        if self._replay_thread and self._replay_thread.is_alive():
            return

        def _loop():
            while not self._stop_event.is_set():
                time.sleep(self._replay_interval)
                domains = set()
                with self._lock:
                    for _p, _ts, _qid, req in self._queue:
                        domains.add(urlparse(req.url).netloc)
                for domain in domains:
                    can_proceed, _state = circuit_breaker.can_request(domain)
                    if can_proceed:
                        while self.replay_one(domain, circuit_breaker):
                            pass

        self._stop_event.clear()
        self._replay_thread = threading.Thread(target=_loop, daemon=True)
        self._replay_thread.start()

    def stop_replay_loop(self):
        self._stop_event.set()

    def stats(self) -> dict:
        with self._lock:
            priorities = {"high": 0, "medium": 0, "low": 0}
            for _p, _ts, _qid, req in self._queue:
                if req.priority == 0:
                    priorities["high"] += 1
                elif req.priority == 1:
                    priorities["medium"] += 1
                else:
                    priorities["low"] += 1
            recent = self._completed[-10:] if self._completed else []
            return {
                "pending": len(self._queue),
                "completed_total": len(self._completed),
                "priority_breakdown": priorities,
                "recently_completed": recent,
            }


# ─── Resilient HTTP Client ──────────────────────────────────────────────────

class ResilientHTTPClient:
    """
    Core resilient HTTP client combining all middleware layers.
    Graceful degradation path: fresh cache → stale cache → network → queue.
    """
    def __init__(self, cache_ttl: int = DEFAULT_TTL, rate_limit: float = DEFAULT_RATE):
        self.cache = HTTPCache(cache_ttl)
        self.dedup = RequestDeduplicator()
        self.limiter = DomainRateLimiter(rate_limit)
        self.circuit_breaker = DomainCircuitBreaker()
        self.health_checker = HealthChecker()
        self.response_validator = ResponseValidator()
        self.offline_queue = OfflineQueue()
        self._client = httpx.Client(
            timeout=30.0,
            follow_redirects=True,
            headers={"User-Agent": "owl-resilient-http/1.0"},
        )
        self.offline_queue.set_client(self._client)
        self.offline_queue.start_replay_loop(self.circuit_breaker)
        self._stats = {
            "requests_total": 0,
            "cache_hits": 0,
            "cache_stale_hits": 0,
            "network_ok": 0,
            "network_failed": 0,
            "queued": 0,
            "degraded": 0,
        }
        self._stats_lock = threading.Lock()

    def _inc_stat(self, key: str, delta: int = 1):
        with self._stats_lock:
            self._stats[key] = self._stats.get(key, 0) + delta

    def fetch(self, method: str, url: str,
              headers: Optional[Dict[str, str]] = None,
              body: Optional[str] = None,
              cache_ttl: Optional[int] = None,
              schema: Optional[SchemaSpec] = None,
              priority: int = 1) -> dict:
        """
        Main fetch method. Returns a dict with content, cache info, validation.

        Graceful degradation flow:
          1. Try fresh cache → return immediately
          2. Check circuit breaker → if open, go to 5
          3. Acquire rate limiter tokens (may wait)
          4. Try network via dedup → cache + return
          5. Try stale cache → return with stale flag
          6. Queue for later replay → return degraded response
        """
        self._inc_stat("requests_total")
        domain = urlparse(url).netloc or url

        # ── Step 1: Fresh cache ──
        cached = self.cache.get(method, url)
        if cached:
            self._inc_stat("cache_hits")
            result = self._build_result(cached, cached=True, fresh=True)
            if schema:
                result["validation"] = self.response_validator.validate(cached, schema)
            return result

        # ── Step 2: Circuit breaker check ──
        can_proceed, cb_state = self.circuit_breaker.can_request(domain)

        if not can_proceed:
            # Circuit is OPEN — try stale cache
            stale = self.cache.get(method, url, allow_stale=True)
            if stale:
                self._inc_stat("cache_stale_hits")
                result = self._build_result(stale, cached=True, fresh=False, degraded=True)
                result["circuit_breaker"] = {"state": cb_state, "domain": domain}
                result["note"] = "Circuit breaker open — returned stale cached response"
                if schema:
                    result["validation"] = self.response_validator.validate(stale, schema)
                return result

            # No cache at all — queue it
            qid = self.offline_queue.enqueue(method, url, headers, body, priority)
            self._inc_stat("queued")
            return self._build_degraded(
                domain, cb_state, qid,
                "Circuit breaker open — request queued for replay when service recovers",
            )

        # ── Step 3: Rate limiter ──
        wait = self.limiter.acquire(url)
        if wait > 0:
            time.sleep(wait)

        # ── Step 4: Network fetch via dedup ──
        def _do_fetch() -> CachedResponse:
            return self._fetch_with_retry(method, url, headers, body, domain)

        try:
            response = self.dedup.execute(method, url, None, _do_fetch)
            self._inc_stat("network_ok")
            self.circuit_breaker.record_success(domain)

            # Cache the response
            self.cache.set(method, url, response)

            result = self._build_result(response, cached=False, fresh=False)
            if schema:
                result["validation"] = self.response_validator.validate(response, schema)
            return result

        except Exception as e:
            self._inc_stat("network_failed")

            # ── Step 5: Stale cache fallback ──
            stale = self.cache.get(method, url, allow_stale=True)
            if stale:
                self._inc_stat("cache_stale_hits")
                self.circuit_breaker.record_failure(domain)
                result = self._build_result(stale, cached=True, fresh=False, degraded=True)
                result["note"] = f"Network failed ({e}) — returned stale cached response"
                result["error"] = str(e)
                return result

            # ── Step 6: Queue for later ──
            cb_state = self.circuit_breaker.record_failure(domain)
            qid = self.offline_queue.enqueue(method, url, headers, body, priority)
            self._inc_stat("queued")
            return self._build_degraded(
                domain, cb_state, qid,
                f"Network error ({e}) — request queued for replay",
                error=str(e),
            )

    def _fetch_with_retry(self, method: str, url: str,
                          headers: Optional[dict],
                          body: Optional[str],
                          domain: str) -> CachedResponse:
        for attempt in range(MAX_RETRIES + 1):
            try:
                resp = self._client.request(
                    method=method,
                    url=url,
                    headers=headers,
                    content=body,
                )
                content = resp.content
                content_text = resp.text
                response = CachedResponse(
                    status=resp.status_code,
                    content=content,
                    content_text=content_text,
                    headers=dict(resp.headers),
                    timestamp=time.time(),
                    ttl=DEFAULT_TTL,
                )
                # Cache 4xx/5xx too? No — only cache successes and redirects
                if resp.status_code >= 400:
                    # Don't cache errors, but still return
                    pass
                return response
            except (httpx.ConnectError, httpx.ConnectTimeout, httpx.ReadTimeout,
                    httpx.RemoteProtocolError, httpx.TransportError) as e:
                if attempt < MAX_RETRIES:
                    time.sleep(1 * (attempt + 1))  # linear backoff
                    continue
                raise RuntimeError(f"HTTP fetch failed after {MAX_RETRIES + 1} attempts: {e}")
        raise RuntimeError("Unexpected: fetch loop exhausted")

    def _build_result(self, response: CachedResponse,
                      cached: bool, fresh: bool,
                      degraded: bool = False) -> dict:
        return {
            "status": response.status,
            "content": response.content_text,
            "content_length": len(response.content),
            "headers": response.headers,
            "cached": cached,
            "fresh": fresh,
            "degraded": degraded,
            "age_seconds": round(response.age_seconds(), 1),
            "ttl_seconds": response.ttl,
            "timestamp": response.timestamp,
        }

    def _build_degraded(self, domain: str, cb_state: str,
                        queue_id: str, note: str,
                        error: Optional[str] = None) -> dict:
        self._inc_stat("degraded")
        return {
            "status": None,
            "content": None,
            "cached": False,
            "fresh": False,
            "degraded": True,
            "queued": True,
            "queue_id": queue_id,
            "note": note,
            "circuit_breaker": {"state": cb_state, "domain": domain},
            "error": error,
        }

    def get_stats(self) -> dict:
        with self._stats_lock:
            stats: dict = dict(self._stats)
        stats["cache"] = self.cache.stats()
        stats["dedup"] = self.dedup.stats()
        stats["circuit_breaker"] = self.circuit_breaker.stats()
        stats["rate_limiter"] = self.limiter.stats()
        stats["queue"] = self.offline_queue.stats()
        # Count open circuits
        cb_states = self.circuit_breaker.stats()
        stats["circuits_open"] = sum(
            1 for s in cb_states.values() if s["state"] == "OPEN"
        )
        return stats

    def clear_cache(self) -> dict:
        cleared = self.cache.clear()
        return {"cleared": cleared, "note": f"Removed {cleared} cached entries"}

    def health(self) -> List[dict]:
        return self.health_checker.check_all()

    def close(self):
        self.offline_queue.stop_replay_loop()
        self._client.close()


# ─── Global Client ──────────────────────────────────────────────────────────

_client: Optional[ResilientHTTPClient] = None


def get_client() -> ResilientHTTPClient:
    global _client
    if _client is None:
        _client = ResilientHTTPClient()
    return _client


# ─── MCP Protocol Handlers ──────────────────────────────────────────────────

TOOLS = [
    {
        "name": "fetch_resilient",
        "description": (
            "Fetch a URL with resilience middleware: cache, circuit breaker, "
            "rate limiter, request dedup, graceful degradation, offline queue. "
            "Automatically falls back to stale cache or queues requests when "
            "services are unreachable. Accepts optional schema validation."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "method": {
                    "type": "string",
                    "enum": ["GET", "POST", "PUT", "DELETE", "HEAD"],
                    "description": "HTTP method (default: GET)",
                    "default": "GET",
                },
                "url": {
                    "type": "string",
                    "description": "Full URL to fetch",
                },
                "headers": {
                    "type": "object",
                    "description": "Optional HTTP headers as dict",
                },
                "body": {
                    "type": "string",
                    "description": "Request body (for POST/PUT)",
                },
                "cache_ttl": {
                    "type": "integer",
                    "description": "Cache TTL in seconds (default: 300)",
                    "default": 300,
                },
                "priority": {
                    "type": "integer",
                    "description": "Queue priority: 0=HIGH, 1=MEDIUM, 2=LOW (used when queued)",
                    "default": 1,
                },
                "schema": {
                    "type": "object",
                    "description": "Optional response schema validation. Fields: expect_status (int), expect_json_fields (list of strings), expect_content_type (string), expect_body_contains (list of strings)",
                    "properties": {
                        "expect_status": {"type": "integer"},
                        "expect_json_fields": {
                            "type": "array",
                            "items": {"type": "string"},
                        },
                        "expect_content_type": {"type": "string"},
                        "expect_body_contains": {
                            "type": "array",
                            "items": {"type": "string"},
                        },
                    },
                },
            },
            "required": ["url"],
        },
    },
    {
        "name": "fetch_status",
        "description": "Get live stats: cache hits, circuit breaker state, rate limiter status, queue depth, request counts.",
        "inputSchema": {"type": "object", "properties": {}, "required": []},
    },
    {
        "name": "fetch_clear_cache",
        "description": "Flush all cached responses. Use after stale data concerns.",
        "inputSchema": {"type": "object", "properties": {}, "required": []},
    },
    {
        "name": "health_check",
        "description": "Check connectivity against 3 diverse health targets (httpbin, GitHub API, Google). Returns latency and status for each.",
        "inputSchema": {"type": "object", "properties": {}, "required": []},
    },
    {
        "name": "queue_status",
        "description": "Inspect the offline priority queue: pending count, priority breakdown, recently completed replays.",
        "inputSchema": {"type": "object", "properties": {}, "required": []},
    },
]


def _mcp_response(id_: Any, result: Any) -> str:
    return json.dumps({"jsonrpc": "2.0", "id": id_, "result": result})


def _mcp_error(id_: Any, msg: str, code: int = -32000) -> str:
    return json.dumps({"jsonrpc": "2.0", "id": id_, "error": {"code": code, "message": msg}})


def handle_tool_call(name: str, args: dict) -> dict:
    client = get_client()

    if name == "fetch_resilient":
        method = args.get("method", "GET")
        url = args["url"]
        headers = args.get("headers")
        body = args.get("body")
        cache_ttl = args.get("cache_ttl", DEFAULT_TTL)
        priority = args.get("priority", 1)
        schema_raw = args.get("schema")
        schema = SchemaSpec.from_dict(schema_raw) if schema_raw else None

        # Clamp priority
        priority = max(0, min(2, priority))

        result = client.fetch(
            method=method, url=url,
            headers=headers, body=body,
            cache_ttl=cache_ttl,
            schema=schema,
            priority=priority,
        )
        return {"content": [{"type": "text", "text": json.dumps(result, indent=2)}]}

    elif name == "fetch_status":
        stats = client.get_stats()
        return {"content": [{"type": "text", "text": json.dumps(stats, indent=2)}]}

    elif name == "fetch_clear_cache":
        result = client.clear_cache()
        return {"content": [{"type": "text", "text": json.dumps(result, indent=2)}]}

    elif name == "health_check":
        results = client.health()
        return {"content": [{"type": "text", "text": json.dumps(results, indent=2)}]}

    elif name == "queue_status":
        stats = client.offline_queue.stats()
        return {"content": [{"type": "text", "text": json.dumps(stats, indent=2)}]}

    raise ValueError(f"Unknown tool: {name}")


def handle_request(req: dict) -> Optional[str]:
    method = req.get("method")
    id_ = req.get("id")

    if method == "initialize":
        return _mcp_response(id_, {
            "protocolVersion": "2024-11-05",
            "capabilities": {"tools": {}},
            "serverInfo": {"name": "owl-resilient-http", "version": "1.0.0"},
        })

    if method == "tools/list":
        return _mcp_response(id_, {"tools": TOOLS})

    if method == "tools/call":
        name = req.get("params", {}).get("name")
        args = req.get("params", {}).get("arguments", {})
        try:
            result = handle_tool_call(name, args)
            return _mcp_response(id_, result)
        except Exception as e:
            return _mcp_error(id_, f"Tool call failed: {e}")

    # Notifications (no id) — silently ignore
    if id_ is None:
        return ""

    return _mcp_error(id_, f"Unknown method: {method}")


def main():
    """Read JSON-RPC requests from stdin, write responses to stdout."""
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except json.JSONDecodeError:
            continue
        try:
            response = handle_request(req)
            if response:
                print(response, flush=True)
        except Exception as e:
            err = _mcp_error(req.get("id"), f"Server error: {e}")
            if err:
                print(err, flush=True)


if __name__ == "__main__":
    main()
