"""Caching OpenAI-compatible proxy for daemon evals (stdlib only).

The daemon's answer and embedding providers point at this proxy, e.g.
``http://127.0.0.1:PORT/q/<tag>/v1/chat/completions``. Each request is
forwarded to OpenRouter unless an identical request body is already cached.
Every request is logged with its tag, usage, observed provider cost and latency
so runs can attribute spend and LLM calls per question.

The cache key is a hash of the endpoint and the canonical JSON request body. It
never includes the tag, port, or credentials, so identical requests made for
different questions or on different runs share one cached response.
"""
from __future__ import annotations

import argparse
from collections import defaultdict
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import re
import threading
import time
from typing import Any, Mapping
import urllib.error
import urllib.request

UPSTREAM = "https://openrouter.ai/api/v1"
ENDPOINTS = ("chat/completions", "embeddings")
_PATH = re.compile(r"^(?:/q/(?P<tag>[A-Za-z0-9_.:@+-]{1,200}))?/v1/(?P<endpoint>chat/completions|embeddings)/?$")


def parse_path(path: str) -> tuple[str, str]:
    """Return (tag, endpoint) for a proxied path; raise ValueError otherwise."""
    match = _PATH.match(path.split("?", 1)[0])
    if not match:
        raise ValueError(f"unsupported proxy path: {path}")
    return match.group("tag") or "untagged", match.group("endpoint")


def cache_key(endpoint: str, body: bytes) -> str:
    """Hash endpoint + canonical request body.

    Bodies that parse as JSON are canonicalized (sorted keys, compact
    separators) so semantically identical requests share a key regardless of
    key order or whitespace. Anything else is hashed byte-for-byte.
    """
    if endpoint not in ENDPOINTS:
        raise ValueError(f"unsupported endpoint: {endpoint}")
    try:
        canonical = json.dumps(json.loads(body), sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
        kind = b"json"
    except (ValueError, UnicodeDecodeError):
        canonical, kind = body, b"bytes"
    return hashlib.sha256(endpoint.encode() + b"\0" + kind + b"\0" + canonical).hexdigest()


def response_cost(response: Mapping[str, Any]) -> float | None:
    usage = response.get("usage") if isinstance(response, Mapping) else None
    cost = usage.get("cost") if isinstance(usage, Mapping) else None
    return float(cost) if isinstance(cost, (int, float)) else None


def cacheable(endpoint: str, response: Any) -> bool:
    if not isinstance(response, Mapping) or "error" in response:
        return False
    if endpoint == "embeddings":
        return isinstance(response.get("data"), list) and bool(response["data"])
    choices = response.get("choices")
    return isinstance(choices, list) and bool(choices)


class SpendCapExceeded(RuntimeError):
    pass


class ProxyState:
    """Disk cache, upstream forwarding, and an append-only request log."""

    def __init__(self, cache_dir: Path, log_path: Path | None = None, *, upstream: str = UPSTREAM,
                 api_key: str | None = None, max_spend_usd: float | None = None,
                 offline: bool = False, timeout: float = 180.0) -> None:
        self.cache_dir = Path(cache_dir)
        self.cache_dir.mkdir(parents=True, exist_ok=True)
        self.log_path = log_path
        if log_path is not None:
            log_path.parent.mkdir(parents=True, exist_ok=True)
        self.upstream = upstream.rstrip("/")
        self.api_key = api_key if api_key is not None else os.environ.get("OPENROUTER_API_KEY")
        self.max_spend_usd = max_spend_usd
        self.offline = offline
        self.timeout = timeout
        self.records: list[dict[str, Any]] = []
        self._lock = threading.Lock()
        self._key_locks: dict[str, threading.Lock] = defaultdict(threading.Lock)
        self.spent_usd = 0.0

    # Cache --------------------------------------------------------------
    def _path(self, key: str) -> Path:
        return self.cache_dir / key[:2] / f"{key}.json"

    def _read(self, key: str) -> Mapping[str, Any] | None:
        path = self._path(key)
        if not path.exists():
            return None
        entry = json.loads(path.read_text())
        if entry.get("key") != key:
            raise ValueError(f"cache identity mismatch for {key}")
        return entry

    def _write(self, key: str, endpoint: str, response: Mapping[str, Any]) -> None:
        path = self._path(key)
        path.parent.mkdir(parents=True, exist_ok=True)
        temporary = path.with_suffix(".tmp")
        temporary.write_text(json.dumps({"key": key, "endpoint": endpoint, "response": response,
                                         "storedAt": time.time()}, ensure_ascii=False))
        temporary.replace(path)

    # Upstream -----------------------------------------------------------
    def _forward(self, endpoint: str, body: bytes) -> tuple[int, bytes]:
        if self.offline:
            raise RuntimeError("proxy is offline and request is not cached")
        if not self.api_key:
            raise RuntimeError("OPENROUTER_API_KEY is required for uncached proxy requests")
        if self.max_spend_usd is not None and self.spent_usd >= self.max_spend_usd:
            raise SpendCapExceeded(f"spend cap ${self.max_spend_usd:.2f} reached")
        request = urllib.request.Request(
            f"{self.upstream}/{endpoint}", data=body, method="POST",
            headers={"Content-Type": "application/json", "Authorization": f"Bearer {self.api_key}",
                     "User-Agent": "quipu-evals-proxy/0.1", "X-Title": "Quipu SOTA evals"},
        )
        last: tuple[int, bytes] = (502, b'{"error":{"message":"no upstream attempt"}}')
        for attempt in range(4):
            try:
                with urllib.request.urlopen(request, timeout=self.timeout) as response:
                    return response.status, response.read()
            except urllib.error.HTTPError as exc:
                last = (exc.code, exc.read())
                if exc.code not in (408, 409, 429, 500, 502, 503, 504):
                    return last
            except (urllib.error.URLError, TimeoutError, ConnectionError) as exc:
                last = (502, json.dumps({"error": {"message": f"upstream unreachable: {exc}"}}).encode())
            time.sleep(min(20, 2 ** attempt))
        return last

    def handle(self, tag: str, endpoint: str, body: bytes) -> tuple[int, bytes, dict[str, Any]]:
        """Serve one request; returns (status, response bytes, log record)."""
        key = cache_key(endpoint, body)
        try:
            payload = json.loads(body)
        except ValueError:
            payload = {}
        started = time.perf_counter()
        record: dict[str, Any] = {
            "tag": tag, "endpoint": endpoint, "key": key,
            "model": payload.get("model") if isinstance(payload, Mapping) else None,
            "startedAt": time.time(),
        }
        with self._lock:
            key_lock = self._key_locks[key]
        with key_lock:
            entry = self._read(key)
            if entry is not None:
                response = entry["response"]
                status, raw, cached = 200, json.dumps(response).encode(), True
            else:
                cached = False
                try:
                    status, raw = self._forward(endpoint, body)
                except SpendCapExceeded as exc:
                    status, raw = 402, json.dumps({"error": {"message": str(exc)}}).encode()
                except RuntimeError as exc:
                    status, raw = 503, json.dumps({"error": {"message": str(exc)}}).encode()
                try:
                    response = json.loads(raw)
                except ValueError:
                    response = None
                if status == 200 and cacheable(endpoint, response):
                    self._write(key, endpoint, response)
                elif status == 200:
                    status = 502  # Never hand an uncacheable error body to the daemon as success.
        usage = response.get("usage") if isinstance(response, Mapping) else None
        cost = response_cost(response) if isinstance(response, Mapping) else None
        record.update({
            "status": status, "cached": cached,
            "latencyMs": (time.perf_counter() - started) * 1000,
            "promptTokens": (usage or {}).get("prompt_tokens") if isinstance(usage, Mapping) else None,
            "completionTokens": (usage or {}).get("completion_tokens") if isinstance(usage, Mapping) else None,
            # costUsd is new spend; nominalCostUsd is the original cost even when served from cache.
            "costUsd": 0.0 if cached else (cost or 0.0),
            "nominalCostUsd": cost,
            "responseModel": response.get("model") if isinstance(response, Mapping) else None,
        })
        if status != 200:
            record["error"] = raw[:500].decode("utf-8", errors="replace")
        with self._lock:
            if not cached and cost:
                self.spent_usd += cost
            self.records.append(record)
            if self.log_path is not None:
                with self.log_path.open("a") as handle:
                    handle.write(json.dumps(record) + "\n")
        return status, raw, record

    def records_for(self, tag: str, start: int = 0) -> list[dict[str, Any]]:
        with self._lock:
            return [r for r in self.records[start:] if r["tag"] == tag]

    def mark(self) -> int:
        with self._lock:
            return len(self.records)

    def totals(self) -> dict[str, Any]:
        with self._lock:
            records = list(self.records)
        return summarize_records(records)


def summarize_records(records: list[Mapping[str, Any]]) -> dict[str, Any]:
    by_endpoint: dict[str, dict[str, Any]] = {}
    for record in records:
        group = by_endpoint.setdefault(record["endpoint"], {
            "requests": 0, "cached": 0, "errors": 0, "costUsd": 0.0, "nominalCostUsd": 0.0,
            "promptTokens": 0, "completionTokens": 0, "missingCost": 0})
        group["requests"] += 1
        group["cached"] += bool(record.get("cached"))
        group["errors"] += record.get("status") != 200
        group["costUsd"] += record.get("costUsd") or 0.0
        if record.get("nominalCostUsd") is None and record.get("status") == 200:
            group["missingCost"] += 1
        group["nominalCostUsd"] += record.get("nominalCostUsd") or 0.0
        group["promptTokens"] += record.get("promptTokens") or 0
        group["completionTokens"] += record.get("completionTokens") or 0
    return {"byEndpoint": by_endpoint,
            "costUsd": sum(g["costUsd"] for g in by_endpoint.values()),
            "nominalCostUsd": sum(g["nominalCostUsd"] for g in by_endpoint.values()),
            "requests": sum(g["requests"] for g in by_endpoint.values())}


def _handler(state: ProxyState):
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *args: Any) -> None:  # Keep stderr quiet; the JSONL log is authoritative.
            return

        def _send(self, status: int, body: bytes) -> None:
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def _body(self) -> bytes:
            if self.headers.get("Transfer-Encoding", "").lower() == "chunked":
                chunks = []
                while True:
                    size = int(self.rfile.readline().strip().split(b";")[0], 16)
                    if size == 0:
                        self.rfile.readline()
                        return b"".join(chunks)
                    chunks.append(self.rfile.read(size))
                    self.rfile.readline()
            return self.rfile.read(int(self.headers.get("Content-Length") or 0))

        def do_GET(self) -> None:  # noqa: N802
            if self.path.rstrip("/") == "/_stats":
                self._send(200, json.dumps(state.totals()).encode())
            else:
                self._send(404, b'{"error":{"message":"not found"}}')

        def do_POST(self) -> None:  # noqa: N802
            body = self._body()
            try:
                tag, endpoint = parse_path(self.path)
            except ValueError as exc:
                self._send(404, json.dumps({"error": {"message": str(exc)}}).encode())
                return
            status, raw, _ = state.handle(tag, endpoint, body)
            self._send(status, raw)

    return Handler


class CachingProxy:
    """Run the proxy on a background thread (port 0 picks a free port)."""

    def __init__(self, state: ProxyState, host: str = "127.0.0.1", port: int = 0) -> None:
        self.state = state
        self.server = ThreadingHTTPServer((host, port), _handler(state))
        self.server.daemon_threads = True
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)

    @property
    def base_url(self) -> str:
        host, port = self.server.server_address[:2]
        return f"http://{host}:{port}"

    def url(self, tag: str, endpoint: str) -> str:
        return f"{self.base_url}/q/{tag}/v1/{endpoint}"

    def __enter__(self) -> "CachingProxy":
        self.thread.start()
        return self

    def __exit__(self, *exc: object) -> None:
        self.server.shutdown()
        self.server.server_close()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cache", type=Path, required=True)
    parser.add_argument("--log", type=Path, required=True)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8788)
    parser.add_argument("--max-spend-usd", type=float)
    parser.add_argument("--offline", action="store_true", help="serve cache hits only")
    args = parser.parse_args()
    state = ProxyState(args.cache, args.log, max_spend_usd=args.max_spend_usd, offline=args.offline)
    with CachingProxy(state, args.host, args.port) as proxy:
        print(f"proxy listening on {proxy.base_url}", flush=True)
        try:
            proxy.thread.join()
        except KeyboardInterrupt:
            pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
