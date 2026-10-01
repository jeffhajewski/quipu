"""Cohere/Jina-compatible cross-encoder rerank server for daemon evals.

The daemon's ``--reranker-url`` points here, e.g.
``http://127.0.0.1:7341/v1/rerank``. One request scores every document
against the query:

    POST /v1/rerank
    {"model": "...", "query": "...", "documents": ["...", ...], "top_n": 50, "return_documents": false}
    -> {"model": "...", "results": [{"index": 3, "relevance_score": 0.97}, ...], "meta": {...}}

Results are sorted by descending score (ties by index) and cut to ``top_n``.
A request naming a different model than the one loaded is refused, so a run
cannot record one model while scoring with another.

Scores come from ``sentence_transformers.CrossEncoder`` (imported lazily, so
this module and its tests need no torch). The device is picked automatically
(mps, cuda, then cpu) and one lock serializes ``predict``. Scores are cached
on disk in an append-only JSONL file keyed by sha256 of the model identity
(name and max length), query and document, so repeated runs only score new
pairs.

Run it from the prepared venv::

    HF_HOME=artifacts/sota/hf-cache artifacts/sota/rerank-venv/bin/python \\
        -m quipu_evals.rerank_server --port 7341 --cache-dir artifacts/sota/cache/rerank
"""
from __future__ import annotations

import argparse
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import sys
import threading
import time
from typing import Any, Callable, Mapping, Sequence

DEFAULT_MODEL = "BAAI/bge-reranker-v2-m3"
DEFAULT_PORT = 7341
DEFAULT_MAX_LENGTH = 512
CACHE_FILE = "scores.jsonl"

# Scores (query, document) pairs; returns one float per pair, in order.
Scorer = Callable[[Sequence[tuple[str, str]]], Sequence[float]]


class RerankRequestError(ValueError):
    """The request body is not a valid rerank request."""


def model_identity(model: str, max_length: int) -> str:
    """Everything besides the pair that changes a score."""
    return f"{model}@max_length={max_length}"


def cache_key(identity: str, query: str, document: str) -> str:
    """sha256 of (model identity, query, document); JSON framing keeps fields unambiguous."""
    framed = json.dumps([identity, query, document], ensure_ascii=False, separators=(",", ":"))
    return hashlib.sha256(framed.encode("utf-8")).hexdigest()


def parse_request(body: Mapping[str, Any]) -> tuple[str | None, str, list[str], int, bool]:
    """Validate a Cohere-style body; return (model, query, documents, top_n, return_documents)."""
    if not isinstance(body, Mapping):
        raise RerankRequestError("request body must be a JSON object")
    model = body.get("model")
    if model is not None and not isinstance(model, str):
        raise RerankRequestError("model must be a string")
    query = body.get("query")
    if not isinstance(query, str) or not query:
        raise RerankRequestError("query must be a non-empty string")
    documents = body.get("documents")
    if not isinstance(documents, list):
        raise RerankRequestError("documents must be a list")
    texts = []
    for index, document in enumerate(documents):
        # Cohere also accepts {"text": ...} objects.
        if isinstance(document, Mapping) and isinstance(document.get("text"), str):
            document = document["text"]
        if not isinstance(document, str):
            raise RerankRequestError(f"documents[{index}] must be a string")
        texts.append(document)
    top_n = body.get("top_n", len(texts))
    if top_n is None:
        top_n = len(texts)
    if isinstance(top_n, bool) or not isinstance(top_n, int) or top_n < 1:
        raise RerankRequestError("top_n must be a positive integer")
    return_documents = body.get("return_documents", False)
    if not isinstance(return_documents, bool):
        raise RerankRequestError("return_documents must be a boolean")
    return model, query, texts, top_n, return_documents


class ScoreCache:
    """Append-only JSONL of ``{"key": sha256, "score": float}`` loaded at start."""

    def __init__(self, directory: Path | None) -> None:
        self.path = directory / CACHE_FILE if directory is not None else None
        self._scores: dict[str, float] = {}
        self._lock = threading.Lock()
        if self.path is not None and self.path.exists():
            with self.path.open() as handle:
                for line in handle:
                    try:
                        entry = json.loads(line)
                        self._scores[entry["key"]] = float(entry["score"])
                    except (ValueError, KeyError, TypeError):
                        continue  # A torn last line from an interrupted run.

    def __len__(self) -> int:
        return len(self._scores)

    def get(self, key: str) -> float | None:
        return self._scores.get(key)

    def put_many(self, entries: Mapping[str, float]) -> None:
        with self._lock:
            fresh = {key: score for key, score in entries.items() if key not in self._scores}
            self._scores.update(fresh)
            if self.path is None or not fresh:
                return
            self.path.parent.mkdir(parents=True, exist_ok=True)
            with self.path.open("a") as handle:
                handle.write("".join(json.dumps({"key": key, "score": score}) + "\n" for key, score in fresh.items()))


class RerankService:
    """Scores requests through the cache; only uncached pairs reach the scorer."""

    def __init__(self, model: str, scorer: Scorer, cache: ScoreCache, *, max_length: int = DEFAULT_MAX_LENGTH,
                 device: str | None = None) -> None:
        self.model = model
        self.max_length = max_length
        self.device = device
        self.identity = model_identity(model, max_length)
        self.cache = cache
        self._scorer = scorer
        self._predict_lock = threading.Lock()

    def rerank(self, body: Mapping[str, Any]) -> dict[str, Any]:
        started = time.perf_counter()
        model, query, documents, top_n, return_documents = parse_request(body)
        if model is not None and model != self.model:
            raise RerankRequestError(f"this server scores with {self.model!r}, not {model!r}")
        keys = [cache_key(self.identity, query, document) for document in documents]
        scores: list[float | None] = [self.cache.get(key) for key in keys]
        missing = [index for index, score in enumerate(scores) if score is None]
        if missing:
            with self._predict_lock:
                fresh = [float(score) for score in self._scorer([(query, documents[index]) for index in missing])]
            if len(fresh) != len(missing):
                raise RuntimeError(f"scorer returned {len(fresh)} scores for {len(missing)} pairs")
            for index, score in zip(missing, fresh):
                scores[index] = score
            self.cache.put_many({keys[index]: score for index, score in zip(missing, fresh)})
        ranked = sorted(range(len(documents)), key=lambda index: (-scores[index], index))[:top_n]
        results = []
        for index in ranked:
            result: dict[str, Any] = {"index": index, "relevance_score": scores[index]}
            if return_documents:
                result["document"] = {"text": documents[index]}
            results.append(result)
        return {"model": self.model, "results": results,
                "meta": {"documents": len(documents), "scored": len(missing), "cached": len(documents) - len(missing),
                         "latencyMs": round((time.perf_counter() - started) * 1000, 3)}}


def _handler(service: RerankService, log: Callable[[str], None]):
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *args: Any) -> None:  # One summary line per request instead.
            return

        def _send(self, status: int, payload: Mapping[str, Any]) -> None:
            body = json.dumps(payload).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self) -> None:  # noqa: N802
            if self.path.split("?", 1)[0].rstrip("/") == "/health":
                self._send(200, {"status": "ok", "model": service.model, "maxLength": service.max_length,
                                 "device": service.device, "cacheEntries": len(service.cache)})
            else:
                self._send(404, {"message": "not found"})

        def do_POST(self) -> None:  # noqa: N802
            raw = self.rfile.read(int(self.headers.get("Content-Length") or 0))
            if self.path.split("?", 1)[0].rstrip("/") not in ("/v1/rerank", "/rerank"):
                self._send(404, {"message": "not found"})
                return
            try:
                response = service.rerank(json.loads(raw))
            except (RerankRequestError, ValueError) as exc:
                log(f"400 {exc}")
                self._send(400, {"message": str(exc)})
                return
            except Exception as exc:  # The daemon falls back to fused order on any error.
                log(f"500 {type(exc).__name__}: {exc}")
                self._send(500, {"message": f"{type(exc).__name__}: {exc}"})
                return
            meta = response["meta"]
            log(f"200 docs={meta['documents']} scored={meta['scored']} cached={meta['cached']} ms={meta['latencyMs']:.0f}")
            self._send(200, response)

    return Handler


class RerankServer:
    """Serve a ``RerankService`` on a background thread (port 0 picks a free port)."""

    def __init__(self, service: RerankService, host: str = "127.0.0.1", port: int = 0,
                 log: Callable[[str], None] | None = None) -> None:
        self.service = service
        self.server = ThreadingHTTPServer((host, port), _handler(service, log or (lambda _message: None)))
        self.server.daemon_threads = True
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)

    @property
    def url(self) -> str:
        host, port = self.server.server_address[:2]
        return f"http://{host}:{port}/v1/rerank"

    def __enter__(self) -> "RerankServer":
        self.thread.start()
        return self

    def __exit__(self, *exc: object) -> None:
        self.server.shutdown()
        self.server.server_close()


def pick_device() -> str:
    import torch
    if torch.backends.mps.is_available():
        return "mps"
    if torch.cuda.is_available():
        return "cuda"
    return "cpu"


def cross_encoder_scorer(model: str, max_length: int, device: str, batch_size: int) -> Scorer:
    from sentence_transformers import CrossEncoder
    encoder = CrossEncoder(model, max_length=max_length, device=device)

    def score(pairs: Sequence[tuple[str, str]]) -> list[float]:
        values = encoder.predict(list(pairs), batch_size=batch_size, show_progress_bar=False)
        return [float(value) for value in values]

    return score


def main(argv: Sequence[str] | None = None) -> int:
    default_cache = Path(os.environ.get("QUIPU_ARTIFACTS", Path(__file__).resolve().parents[3] / "artifacts")) / "sota/cache/rerank"
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT)
    parser.add_argument("--model", default=DEFAULT_MODEL)
    parser.add_argument("--max-length", type=int, default=DEFAULT_MAX_LENGTH)
    parser.add_argument("--batch-size", type=int, default=32)
    parser.add_argument("--device", default="auto", help="auto, mps, cuda or cpu")
    parser.add_argument("--cache-dir", type=Path, default=default_cache)
    parser.add_argument("--no-cache", action="store_true", help="score every pair; keep nothing on disk")
    args = parser.parse_args(argv)

    def log(message: str) -> None:
        print(f"[rerank] {message}", file=sys.stderr, flush=True)

    device = pick_device() if args.device == "auto" else args.device
    log(f"loading {args.model} (max_length={args.max_length}) on {device}")
    scorer = cross_encoder_scorer(args.model, args.max_length, device, args.batch_size)
    cache = ScoreCache(None if args.no_cache else args.cache_dir)
    service = RerankService(args.model, scorer, cache, max_length=args.max_length, device=device)
    with RerankServer(service, args.host, args.port, log) as server:
        log(f"listening on {server.url}; {len(cache)} cached scores in {cache.path}")
        try:
            server.thread.join()
        except KeyboardInterrupt:
            pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
