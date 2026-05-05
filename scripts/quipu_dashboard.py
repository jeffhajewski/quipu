#!/usr/bin/env python3
from __future__ import annotations

import argparse
from html import escape
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
from urllib.parse import parse_qs, urlparse
import sys
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "sdk" / "python" / "src"))

from quipu import Quipu  # noqa: E402


HTML = """<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Quipu Dashboard</title>
  <style>
    body { margin: 0; font-family: ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; background: #f7f7f4; color: #1e2320; }
    header { padding: 24px 32px; border-bottom: 1px solid #d9ddd5; background: #ffffff; }
    main { display: grid; grid-template-columns: minmax(260px, 360px) 1fr; gap: 20px; padding: 24px 32px; }
    h1 { margin: 0; font-size: 24px; letter-spacing: 0; }
    h2 { margin: 0 0 12px; font-size: 15px; letter-spacing: 0; }
    section { border: 1px solid #d9ddd5; background: #ffffff; border-radius: 8px; padding: 16px; }
    label { display: block; font-size: 12px; color: #596059; margin: 12px 0 6px; }
    input { width: 100%; box-sizing: border-box; border: 1px solid #c8cdc5; border-radius: 6px; padding: 9px 10px; font: inherit; }
    button { margin-top: 12px; border: 1px solid #1e2320; background: #1e2320; color: #ffffff; border-radius: 6px; padding: 9px 12px; font: inherit; cursor: pointer; }
    pre { white-space: pre-wrap; overflow-wrap: anywhere; background: #f2f3ef; border-radius: 6px; padding: 12px; min-height: 120px; }
    .grid { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 20px; }
    .muted { color: #596059; font-size: 13px; }
    @media (max-width: 820px) { main, .grid { grid-template-columns: 1fr; } }
  </style>
</head>
<body>
  <header>
    <h1>Quipu Dashboard</h1>
    <div class="muted">Read-only local memory inspection</div>
  </header>
  <main>
    <section>
      <h2>Query</h2>
      <label for="query">Search text</label>
      <input id="query" value="pnpm">
      <label for="project">Project ID</label>
      <input id="project" placeholder="repo:quipu">
      <label for="user">User ID</label>
      <input id="user" placeholder="local-user">
      <button onclick="refresh()">Refresh</button>
    </section>
    <div class="grid">
      <section><h2>Health</h2><pre id="health"></pre></section>
      <section><h2>Search</h2><pre id="search"></pre></section>
      <section><h2>Core Blocks</h2><pre id="core"></pre></section>
      <section><h2>Retrieval Trace</h2><pre id="trace"></pre></section>
    </div>
  </main>
  <script>
    const qs = () => new URLSearchParams({
      q: document.getElementById('query').value,
      projectId: document.getElementById('project').value,
      userId: document.getElementById('user').value,
    });
    async function show(id, url) {
      const res = await fetch(url);
      document.getElementById(id).textContent = JSON.stringify(await res.json(), null, 2);
    }
    async function refresh() {
      await show('health', '/api/health');
      await show('search', '/api/search?' + qs());
      await show('core', '/api/core?' + qs());
      await show('trace', '/api/retrieve?' + qs());
    }
    refresh();
  </script>
</body>
</html>
"""


class State:
    def __init__(self, memory: Quipu) -> None:
        self.memory = memory


class Handler(BaseHTTPRequestHandler):
    server_version = "QuipuDashboard/0.1"

    def do_GET(self) -> None:
        parsed = urlparse(self.path)
        try:
            if parsed.path == "/":
                self._html(HTML)
            elif parsed.path == "/api/health":
                self._json(200, self.state.memory.health())
            elif parsed.path == "/api/search":
                self._json(200, self._search(parsed.query))
            elif parsed.path == "/api/retrieve":
                self._json(200, self._retrieve(parsed.query))
            elif parsed.path == "/api/core":
                self._json(200, self._core(parsed.query))
            else:
                self._json(404, {"error": "not found"})
        except Exception as exc:  # pragma: no cover - defensive server boundary
            self._json(500, {"error": str(exc)})

    @property
    def state(self) -> State:
        return self.server.state  # type: ignore[attr-defined]

    def _search(self, query_string: str) -> dict[str, Any]:
        params = parse_qs(query_string)
        query = first(params, "q") or ""
        return dict(self.state.memory.search(query=query or " ", mode="fts", scope=scope(params), limit=20))

    def _retrieve(self, query_string: str) -> dict[str, Any]:
        params = parse_qs(query_string)
        query = first(params, "q") or "memory"
        retrieved = self.state.memory.retrieve(
            query=query,
            scope=scope(params),
            budgetTokens=1200,
            options={"includeDebug": True, "includeEvidence": True},
        )
        return {"retrievalId": retrieved.get("retrievalId"), "warnings": retrieved.get("warnings"), "trace": retrieved.get("trace")}

    def _core(self, query_string: str) -> dict[str, Any]:
        params = parse_qs(query_string)
        return dict(self.state.memory.core_get(scope=scope(params)))

    def _json(self, status: int, payload: Any) -> None:
        body = json.dumps(payload, indent=2).encode()
        self.send_response(status)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _html(self, payload: str) -> None:
        body = payload.encode()
        self.send_response(200)
        self.send_header("content-type", "text/html; charset=utf-8")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt: str, *args: Any) -> None:
        if os.environ.get("QUIPU_DASHBOARD_LOG") == "1":
            super().log_message(fmt, *args)


def first(params: dict[str, list[str]], key: str) -> str | None:
    values = params.get(key)
    return values[0] if values and values[0] else None


def scope(params: dict[str, list[str]]) -> dict[str, str]:
    result: dict[str, str] = {}
    for key in ("tenantId", "userId", "agentId", "projectId"):
        value = first(params, key)
        if value:
            result[key] = value
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=7338)
    args = parser.parse_args()

    local_binary = ROOT / "core" / "zig-out" / "bin" / "quipu"
    if "QUIPU_CORE_BINARY" not in os.environ and local_binary.exists():
        os.environ["QUIPU_CORE_BINARY"] = str(local_binary)

    with Quipu() as memory:
        server = ThreadingHTTPServer((args.host, args.port), Handler)
        server.state = State(memory)  # type: ignore[attr-defined]
        print(f"quipu dashboard listening on http://{escape(args.host)}:{args.port}", flush=True)
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            return 0
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
