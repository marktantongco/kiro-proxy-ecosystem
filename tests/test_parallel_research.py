#!/usr/bin/env python3
"""
Comparative benchmark: Hermes agent parallel research with vs without OWL resilient middleware.

Simulates what Hermes agents do during parallel research:
  - Multiple concurrent HTTP requests to various APIs
  - Mix of unique and duplicate URLs (to test dedup/cache)
  - One deliberately flaky endpoint (to test degradation/queue)
  - Schema validation on structured responses

Output: side-by-side comparison of success rate, latency, degradation behavior.
"""

import json
import os
import subprocess
import sys
import time
import threading
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime
from typing import List, Tuple, Optional

import httpx


# ─── Test Configuration ────────────────────────────────────────────────────

RESEARCH_URLS = [
    # Unique GitHub API calls — simulates agent researching different topics
    ("GET", "https://api.github.com/zen", {}),
    ("GET", "https://api.github.com/rate_limit", {}),
    ("GET", "https://api.github.com/users/octocat", {}),
    ("GET", "https://api.github.com/repos/psf/requests", {}),
    ("GET", "https://api.github.com/search/code?q=addClass+user:mozilla", {}),
    # Duplicate URL — tests caching/dedup
    ("GET", "https://api.github.com/zen", {}),
    ("GET", "https://api.github.com/rate_limit", {}),
    # Flaky target — tests graceful degradation
    ("GET", "https://httpbin.org/delay/5", {"timeout": 3}),
    # Schema validation target
    ("GET", "https://api.github.com/users/octocat", {"schema": {"expect_json_fields": ["login", "id", "public_repos"]}}),
]

PARALLELISM = 5  # Hermes subagent count


# ─── Direct HTTP (Without OWL) ──────────────────────────────────────────────

def fetch_direct(method: str, url: str, extra: dict) -> dict:
    """Direct HTTP fetch — no resilience middleware."""
    start = time.time()
    timeout = extra.get("timeout", 10)
    schema = extra.get("schema")
    result = {
        "method": method,
        "url": url,
        "started_at": start,
    }
    client: Optional[httpx.Client] = None
    try:
        client = httpx.Client(timeout=timeout, follow_redirects=True)
        resp = client.request(method, url)
        latency = (time.time() - start) * 1000
        content_text = resp.text
        result.update({
            "status": resp.status_code,
            "success": resp.status_code < 500,
            "latency_ms": round(latency, 1),
            "content_length": len(content_text),
            "error": None,
            "degraded": False,
            "cached": False,
        })
        # Schema validation
        if schema:
            errors = []
            for field in schema.get("expect_json_fields", []):
                try:
                    data = json.loads(content_text)
                    parts = field.split(".")
                    val = data
                    for p in parts:
                        if isinstance(val, dict):
                            val = val.get(p, "_MISSING_")
                        else:
                            val = "_MISSING_"
                            break
                    if val == "_MISSING_":
                        errors.append(f"Missing: {field}")
                except Exception:
                    errors.append("Invalid JSON")
            result["validation_errors"] = errors
            result["validation_passed"] = len(errors) == 0
    except Exception as e:
        result.update({
            "status": None,
            "success": False,
            "latency_ms": round((time.time() - start) * 1000, 1),
            "error": str(e),
            "degraded": False,
            "cached": False,
        })
    finally:
        if client is not None:
            client.close()
    return result


# ─── Through OWL MCP (With Middleware) ──────────────────────────────────────

OWL_SERVER_SCRIPT = "/home/x1/Documents/owl-agent-installer/owl_resilient_mcp.py"


class OWLClient:
    """Talk to the OWL MCP server via stdio. Thread-safe with response routing."""

    def __init__(self):
        self.proc = subprocess.Popen(
            ["python3", OWL_SERVER_SCRIPT],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True, bufsize=1,
        )
        self._req_id = 0
        self._req_lock = threading.Lock()
        # Pending responses: req_id -> {"event": threading.Event, "response": None}
        self._pending: dict = {}
        self._pending_lock = threading.Lock()

        # Start background reader thread
        self._reader_stop = threading.Event()
        self._reader = threading.Thread(target=self._reader_loop, daemon=True)
        self._reader.start()

        # Initialize
        init_resp = self._send_and_wait(
            {"jsonrpc": "2.0", "id": self._next_id(), "method": "initialize"}, timeout=10
        )

    def _reader_loop(self):
        """Background: continuously read stdout lines and route responses by id."""
        while not self._reader_stop.is_set():
            try:
                line = self.proc.stdout.readline()
                if not line:
                    time.sleep(0.01)
                    continue
                resp = json.loads(line.strip())
                req_id = resp.get("id")
                if req_id is not None:
                    with self._pending_lock:
                        entry = self._pending.get(req_id)
                        if entry:
                            entry["response"] = resp
                            entry["event"].set()
            except (json.JSONDecodeError, EOFError):
                time.sleep(0.01)
            except Exception:
                time.sleep(0.01)

    def _next_id(self) -> int:
        with self._req_lock:
            self._req_id += 1
            return self._req_id

    def _send_and_wait(self, msg: dict, timeout: float = 30.0) -> dict:
        req_id = msg.get("id")
        event = threading.Event()
        with self._pending_lock:
            self._pending[req_id] = {"event": event, "response": None}

        # Send the request
        line = json.dumps(msg) + "\n"
        self.proc.stdin.write(line)
        self.proc.stdin.flush()

        # Wait for the matching response
        if not event.wait(timeout):
            with self._pending_lock:
                self._pending.pop(req_id, None)
            raise TimeoutError(f"No response for request {req_id} within {timeout}s")

        with self._pending_lock:
            entry = self._pending.pop(req_id, None)
            resp = entry["response"] if entry else None
        if resp is None:
            raise RuntimeError(f"Response lost for request {req_id}")
        return resp

    def fetch_resilient(self, method: str, url: str,
                        timeout: Optional[int] = None,
                        schema: Optional[dict] = None) -> dict:
        args = {"method": method, "url": url}
        if timeout:
            args["cache_ttl"] = timeout
        if schema:
            args["schema"] = schema
        resp = self._send_and_wait({
            "jsonrpc": "2.0",
            "id": self._next_id(),
            "method": "tools/call",
            "params": {"name": "fetch_resilient", "arguments": args},
        })
        if "error" in resp:
            return {"success": False, "error": resp["error"].get("message", str(resp["error"]))}
        content = resp.get("result", {}).get("content", [{}])[0].get("text", "{}")
        return json.loads(content)

    def get_status(self) -> dict:
        resp = self._send_and_wait({
            "jsonrpc": "2.0",
            "id": self._next_id(),
            "method": "tools/call",
            "params": {"name": "fetch_status", "arguments": {}},
        })
        content = resp.get("result", {}).get("content", [{}])[0].get("text", "{}")
        return json.loads(content)

    def close(self):
        self._reader_stop.set()
        self.proc.terminate()
        self.proc.wait()


def fetch_via_owl(method: str, url: str, extra: dict, owl_client: OWLClient) -> dict:
    """Fetch through OWL resilient middleware."""
    start = time.time()
    schema = extra.get("schema")
    timeout = extra.get("timeout")
    try:
        result = owl_client.fetch_resilient(method, url, timeout=timeout, schema=schema)
        result["started_at"] = start
        if result.get("error"):
            result["success"] = False
        else:
            result["success"] = result.get("status") is not None and result.get("status", 0) < 500
        if result.get("latency_ms") is None:
            result["latency_ms"] = round((time.time() - start) * 1000, 1)
        return result
    except Exception as e:
        return {
            "method": method,
            "url": url,
            "success": False,
            "error": str(e),
            "latency_ms": round((time.time() - start) * 1000, 1),
            "degraded": False,
            "cached": False,
        }


# ─── Test Runner ────────────────────────────────────────────────────────────

def run_parallel_fetches(fetcher, urls: list, max_workers: int,
                         owl_client: Optional[OWLClient] = None) -> List[dict]:
    """Run fetches in parallel to simulate Hermes subagent research."""
    results = []
    with ThreadPoolExecutor(max_workers=max_workers) as executor:
        futures = {}
        for method, url, extra in urls:
            if owl_client:
                future = executor.submit(fetch_via_owl, method, url, extra, owl_client)
            else:
                future = executor.submit(fetch_direct, method, url, extra)
            futures[future] = url

        for future in as_completed(futures):
            url = futures[future]
            try:
                result = future.result()
                result["url"] = url
                results.append(result)
            except Exception as e:
                results.append({"url": url, "success": False, "error": str(e)})
    return results


def print_comparison(direct_results: List[dict], owl_results: List[dict],
                     owl_status_before: dict, owl_status_after: dict):
    """Side-by-side comparison of results."""

    print("=" * 100)
    print("  HERMES PARALLEL RESEARCH — WITH vs WITHOUT OWL RESILIENT MIDDLEWARE")
    print("=" * 100)
    print(f"\n  Test: {len(RESEARCH_URLS)} requests, {PARALLELISM} parallel workers")
    print(f"  Time: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    print()

    # ── Aggregate stats ──
    def agg(results):
        total = len(results)
        success = sum(1 for r in results if r.get("success"))
        degraded = sum(1 for r in results if r.get("degraded"))
        cached = sum(1 for r in results if r.get("cached"))
        errors = [r.get("error") for r in results if r.get("error")]
        latencies = [r.get("latency_ms", 0) for r in results if r.get("latency_ms")]
        avg_latency = sum(latencies) / len(latencies) if latencies else 0
        return {
            "total": total, "success": success, "degraded": degraded, "cached": cached,
            "failed": total - success, "errors": errors, "avg_latency_ms": round(avg_latency, 1),
            "latencies": latencies,
        }

    a = agg(direct_results)
    b = agg(owl_results)

    print("  ┌──────────────────────────┬─────────────────────┬─────────────────────┐")
    print("  │ Metric                   │ Without OWL         │ With OWL            │")
    print("  ├──────────────────────────┼─────────────────────┼─────────────────────┤")
    print(f"  │ Requests                 │ {a['total']:>19} │ {b['total']:>19} │")
    print(f"  │ Successful               │ {a['success']:>19} │ {b['success']:>19} │")
    print(f"  │ Failed                   │ {a['failed']:>19} │ {b['failed']:>19} │")
    print(f"  │ Avg latency (ms)         │ {a['avg_latency_ms']:>19.1f} │ {b['avg_latency_ms']:>19.1f} │")
    print(f"  │ Cached responses         │ {a['cached']:>19} │ {b['cached']:>19} │")
    print(f"  │ Degraded gracefully      │ {a['degraded']:>19} │ {b['degraded']:>19} │")
    print("  └──────────────────────────┴─────────────────────┴─────────────────────┘")
    print()

    # ── Per-request comparison ──
    print("  ── Per-Request Detail ──")
    print(f"  {'URL':<50} {'Without':<22} {'With OWL':<22}")
    print(f"  {'─'*48} {'─'*22} {'─'*22}")

    # Map OWL results by URL for side-by-side
    owl_by_url = {}
    for r in owl_results:
        url = r.get("url", "")
        owl_by_url[url] = r

    for r in direct_results:
        url = r.get("url", "")
        owl_r = owl_by_url.get(url, {})
        dw = f"{'OK' if r.get('success') else 'FAIL'} {r.get('latency_ms','?')}ms{' C' if r.get('cached') else ''}"
        ow = f"{'OK' if owl_r.get('success') else 'FAIL'} {owl_r.get('latency_ms','?')}ms{' C' if owl_r.get('cached') else ''}{' D' if owl_r.get('degraded') else ''}"
        url_short = url[:48] if len(url) > 48 else url
        print(f"  {url_short:<50} {dw:<22} {ow:<22}")

    print()
    print("  ── OWL Internal Metrics (Post-Test) ──")
    if owl_status_after:
        print(f"  Cache entries: {owl_status_after.get('cache', {}).get('entries', '?')}")
        print(f"  Cache fresh: {owl_status_after.get('cache', {}).get('fresh', '?')}")
        print(f"  Cache stale: {owl_status_after.get('cache', {}).get('stale', '?')}")
        print(f"  Queue pending: {owl_status_after.get('queue', {}).get('pending', '?')}")
        print(f"  Circuits open: {owl_status_after.get('circuits_open', '?')}")
        print(f"  Requests total: {owl_status_after.get('requests_total', '?')}")
        print(f"  Cache hits: {owl_status_after.get('cache_hits', '?')}")
        print(f"  Network ok: {owl_status_after.get('network_ok', '?')}")
        print(f"  Degraded: {owl_status_after.get('degraded', '?')}")
        print(f"  Queued: {owl_status_after.get('queued', '?')}")

    # ── Schema validation ──
    print()
    val_direct = [r for r in direct_results if "validation_errors" in r]
    val_owl = [r for r in owl_results if "validation" in r]
    if val_direct or val_owl:
        print("  ── Schema Validation ──")
        if val_direct:
            for r in val_direct:
                print(f"  Direct:  {r['url']} → passed={r.get('validation_passed')} errors={r.get('validation_errors', [])}")
        if val_owl:
            for r in val_owl:
                print(f"  OWL:     {r['url']} → errors={r.get('validation', [])}")

    # ── Key Insights ──
    print()
    print("  ── Key Insights ──")
    insights = []

    if b['cached'] > a['cached']:
        insights.append(f"✅ OWL cached {b['cached']} duplicate requests (vs {a['cached']} without) — "
                        f"eliminated redundant network calls")
    if b['degraded'] > 0:
        insights.append(f"✅ OWL gracefully degraded {b['degraded']} requests instead of failing "
                        f"— returned stale cache / queued for replay")
    if b['success'] > a['success']:
        insights.append(f"✅ OWL completed {b['success'] - a['success']} more requests successfully "
                        f"— resilience layers absorbed failures")
    if b['avg_latency_ms'] < a['avg_latency_ms'] and a['avg_latency_ms'] > 0:
        pct = round((1 - b['avg_latency_ms'] / a['avg_latency_ms']) * 100, 1)
        insights.append(f"⚡ OWL reduced average latency by {pct}% — "
                        f"cache hits served without network calls")
    if b['failed'] < a['failed']:
        insights.append(f"✅ OWL converted {a['failed'] - b['failed']} failures into "
                        f"degraded/queued responses")
    if b['cached'] > 0:
        insights.append(f"📦 OWL cached {b['cached']} responses — "
                        f"subsequent identical requests served instantly")

    for ins in insights:
        print(f"  {ins}")
    if not insights:
        print(f"  No significant difference — test conditions may need more diverse traffic patterns.")

    print()
    print("=" * 100)


# ─── Main ───────────────────────────────────────────────────────────────────

def main():
    print("Starting OWL vs Direct comparison test...")
    print(f"  Research URLs: {len(RESEARCH_URLS)}")
    print(f"  Parallel workers: {PARALLELISM}")
    print()

    # ── Without OWL ──
    print("[1/4] Running WITHOUT OWL (direct HTTP) ...")
    start = time.time()
    direct_results = run_parallel_fetches(None, RESEARCH_URLS, PARALLELISM)
    direct_time = time.time() - start
    print(f"      Done in {direct_time:.1f}s")

    # ── With OWL ──
    print("[2/4] Starting OWL MCP server ...")
    owl = OWLClient()
    owl_status_before = owl.get_status()

    print("[3/4] Running WITH OWL (resilient middleware) ...")
    start = time.time()
    owl_results = run_parallel_fetches(fetch_via_owl, RESEARCH_URLS, PARALLELISM, owl)
    owl_time = time.time() - start
    print(f"      Done in {owl_time:.1f}s")

    owl_status_after = owl.get_status()
    owl.close()

    # ── Compare ──
    print("[4/4] Printing comparison ...")
    print()
    print_comparison(direct_results, owl_results, owl_status_before, owl_status_after)


if __name__ == "__main__":
    main()
