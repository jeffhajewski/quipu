"""LongMemEval-S dev-slice harness for the Quipu daemon (SOTA sprint).

Subcommands:

- ``select``: freeze the 70-question dev slice (IDs only) disjoint from E1.
- ``build``: build a daemon binary from a core checkout into an output prefix.
- ``run``: one daemon process per question, all provider traffic through the
  caching proxy, official LongMemEval judge, JSON + Markdown report.
- ``summarize-e1``: render an E1 ``longmemeval_study`` report in the same tables.
- ``compare``: paired comparison of two runs on the same questions.

The daemon owns retrieval and answering; this harness only replays public
LongMemEval-S sessions, asks the question, and grades the returned answer.
"""
from __future__ import annotations

import argparse
from collections import Counter, defaultdict
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import queue
import random
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from types import SimpleNamespace
from typing import Any, Callable, Iterable, Mapping, Sequence
import urllib.parse
import urllib.request

from .core_client import render_context
from .longmemeval import _parse_datetime, _role
from .representation_experiment import digest, write_json

ROOT = Path(__file__).resolve().parents[3]
SEED = "quipu-sota-dev-20261001"
CATEGORIES = (
    "abstention", "knowledge-update", "multi-session", "single-session-assistant",
    "single-session-preference", "single-session-user", "temporal-reasoning",
)
READER_MODEL = "openai/gpt-4o-mini-2024-07-18"
JUDGE_MODEL = "openai/gpt-4o-2024-08-06"
EMBED_MODEL = "openai/text-embedding-3-small"
TOKENIZER = "o200k_base"
DEFAULT_ARTIFACTS = Path(os.environ.get("QUIPU_ARTIFACTS", ROOT / "artifacts"))
DEFAULT_DATASET = DEFAULT_ARTIFACTS / "experiments/upstream/longmemeval_s_cleaned.json"
DEFAULT_E1_SELECTION = DEFAULT_ARTIFACTS / "experiments/e1-study-splits/selection.json"
DEFAULT_UPSTREAM = DEFAULT_ARTIFACTS / "experiments/LongMemEval-upstream/src/evaluation/evaluate_qa.py"
DEFAULT_SELECTION = ROOT / "evals/experiments/sota-dev-selection.json"
# Only these variables reach the daemon; provider keys never do (the proxy injects them).
DAEMON_ENV_PASSTHROUGH = ("PATH", "LANG", "LC_ALL", "TMPDIR", "DYLD_LIBRARY_PATH",
                          "DYLD_FALLBACK_LIBRARY_PATH", "LD_LIBRARY_PATH")
PROXY_KEY_PLACEHOLDER = "sk-quipu-eval-proxy-injects-real-key"


# ---------------------------------------------------------------------------
# Selection


def category_of(item: Mapping[str, Any]) -> str:
    """E1's categorization: `_abs` questions are abstention, else question_type."""
    question_id = str(item["question_id"])
    return "abstention" if question_id.endswith("_abs") else str(item.get("question_type") or "unknown")


def family_of(question_id: str) -> str:
    return question_id.removesuffix("_abs")


def select_dev(items: Sequence[Mapping[str, Any]], excluded_ids: Iterable[str], *, seed: str = SEED,
               per_category: int = 10, categories: Sequence[str] = CATEGORIES) -> list[dict[str, str]]:
    """Deterministic category-balanced selection.

    Every excluded question blocks its whole ordinary/``_abs`` family, and the
    selection itself takes at most one question per family. Within a category,
    candidates are ordered by sha256 of ``[seed, question_id]``; categories are
    filled in sorted order so the result depends only on the inputs.
    """
    used = {family_of(question_id) for question_id in excluded_ids}
    by_category: dict[str, list[str]] = defaultdict(list)
    for item in items:
        by_category[category_of(item)].append(str(item["question_id"]))
    chosen: list[dict[str, str]] = []
    for category in sorted(categories):
        picked = []
        for question_id in sorted(by_category[category], key=lambda value: digest([seed, value])):
            if family_of(question_id) in used:
                continue
            picked.append(question_id)
            used.add(family_of(question_id))
            if len(picked) == per_category:
                break
        if len(picked) != per_category:
            raise ValueError(f"only {len(picked)} eligible {category} questions; need {per_category}")
        chosen.extend({"id": question_id, "category": category} for question_id in picked)
    return chosen


def e1_question_ids(path: Path) -> list[str]:
    manifest = json.loads(path.read_text())
    return [entry["id"] for split in manifest.values() for entry in split]


def load_selection(path: Path) -> list[str]:
    payload = json.loads(path.read_text())
    ids = payload["questionIds"] if isinstance(payload, Mapping) else payload
    if not isinstance(ids, list) or not all(isinstance(value, str) for value in ids) or len(set(ids)) != len(ids):
        raise ValueError("selection must contain a list of unique question IDs")
    return ids


def cmd_select(args: argparse.Namespace) -> int:
    data = json.loads(args.dataset.read_text())
    excluded = e1_question_ids(args.e1_selection)
    chosen = select_dev(data, excluded, seed=args.seed, per_category=args.per_category)
    payload = {
        "name": "sota-dev",
        "seed": args.seed,
        "source": "xiaowu0162/longmemeval-cleaned longmemeval_s_cleaned.json",
        "sourceSha256": hashlib.sha256(args.dataset.read_bytes()).hexdigest(),
        "perCategory": args.per_category,
        "categories": sorted(CATEGORIES),
        "excludedE1Questions": len(excluded),
        "e1SelectionSha256": hashlib.sha256(args.e1_selection.read_bytes()).hexdigest(),
        "procedure": ("quipu_evals.sota_longmemeval select: exclude E1 dev+heldout IDs and their "
                      "ordinary/_abs families; per category (sorted), order by sha256([seed, id]); take "
                      "the first N whose family is unused; at most one question per family."),
        "questionIds": [entry["id"] for entry in chosen],
    }
    write_json(args.output, payload)
    print(json.dumps({"selected": len(chosen), "byCategory": Counter(e["category"] for e in chosen),
                      "excluded": len(excluded), "output": str(args.output)}, indent=2))
    return 0


# ---------------------------------------------------------------------------
# Cases: anonymized, date-ordered sessions with gold coordinates


def iso_time(value: str) -> str:
    return _parse_datetime(value).isoformat().replace("+00:00", "Z")


def build_case(item: Mapping[str, Any]) -> dict[str, Any]:
    """Convert one LongMemEval item into daemon-ready sessions.

    Sessions are ordered by date (ties keep dataset order) and renamed ``s01``…
    because upstream session IDs reveal evidence sessions. Messages keep their
    order, are stripped like E1's loader, and empty turns are dropped (the
    daemon rejects empty content). Gold turns use post-filter message indices.
    """
    ids, dates, sessions = item["haystack_session_ids"], item["haystack_dates"], item["haystack_sessions"]
    order = sorted(range(len(sessions)), key=lambda index: (_parse_datetime(dates[index]), index))
    width = max(2, len(str(len(order))))
    anonymous = {index: f"s{rank:0{width}d}" for rank, index in enumerate(order, 1)}
    answer_sessions = set(item.get("answer_session_ids") or [])
    case_sessions, gold_turns = [], []
    for index in order:
        created_at = iso_time(dates[index])
        messages = []
        for turn in sessions[index]:
            content = str(turn.get("content") or "").strip()
            if not content:
                continue
            if turn.get("has_answer"):
                gold_turns.append([anonymous[index], len(messages)])
            messages.append({"role": _role(str(turn.get("role") or "user")), "content": content,
                             "createdAt": created_at})
        if messages:
            case_sessions.append({"sessionId": anonymous[index], "time": created_at, "messages": messages})
    question_id = str(item["question_id"])
    return {
        "questionId": question_id,
        "category": category_of(item),
        "questionType": str(item.get("question_type") or ""),
        "question": str(item["question"]),
        "answer": str(item["answer"]),
        "questionTime": iso_time(item["question_date"]),
        "abstention": question_id.endswith("_abs"),
        "scope": {"tenantId": "sota-dev", "projectId": "case-" + digest(question_id)[:16]},
        "sessions": case_sessions,
        "evidenceSessions": sorted(anonymous[i] for i, sid in enumerate(ids) if sid in answer_sessions),
        "goldTurns": gold_turns,
    }


# ---------------------------------------------------------------------------
# Mapping returned items back to (session, turn)


def linked_message_qids(item: Mapping[str, Any]) -> list[str]:
    """An item's own qid plus every evidence qid (chunks/derived items cite parents)."""
    qids = [item["qid"]] if isinstance(item.get("qid"), str) else []
    for evidence in item.get("evidence") or []:
        if isinstance(evidence, Mapping) and isinstance(evidence.get("qid"), str):
            qids.append(evidence["qid"])
    return qids


def item_turns(items: Sequence[Mapping[str, Any]], qid_to_turn: Mapping[str, Sequence[Any]],
               *, raw_only: bool = False) -> set[tuple[str, int]]:
    """(session, turn) coordinates reachable from the returned items.

    ``raw_only`` keeps only message/chunk items (type ``message``), whose text
    is source evidence rather than a derived memory.
    """
    found = set()
    for item in items:
        if not isinstance(item, Mapping) or (raw_only and item.get("type") != "message"):
            continue
        for qid in linked_message_qids(item):
            if qid in qid_to_turn:
                session, turn = qid_to_turn[qid]
                found.add((str(session), int(turn)))
    return found


def coverage(case: Mapping[str, Any], turns: set[tuple[str, int]]) -> dict[str, Any]:
    gold = {(str(s), int(t)) for s, t in case["goldTurns"]}
    sessions = {session for session, _ in turns}
    evidence = set(case["evidenceSessions"])
    answerable = not case["abstention"]
    return {
        "goldTurnCoverage": len(turns & gold) / len(gold) if gold and answerable else None,
        "allGoldTurns": gold <= turns if gold and answerable else None,
        "goldSessionCoverage": len(sessions & evidence) / len(evidence) if evidence and answerable else None,
        "missingGoldTurns": sorted(gold - turns) if answerable else [],
    }


def reader_context(result: Mapping[str, Any]) -> tuple[str, str]:
    """The exact memory context sent to the reader when the daemon exposes it."""
    if isinstance(result.get("prompt"), str):
        return result["prompt"], "prompt"
    if isinstance(result.get("context"), Mapping):
        return render_context(result["context"]), "context_render"
    return "\n".join(str(item.get("text", "")) for item in result.get("items") or [] if isinstance(item, Mapping)), "item_texts"


# ---------------------------------------------------------------------------
# Daemon process


class DaemonError(RuntimeError):
    pass


class Daemon:
    """NDJSON JSON-RPC client with per-call timeouts; stderr goes to a file."""

    def __init__(self, command: Sequence[str], *, env: Mapping[str, str], cwd: Path, stderr_path: Path) -> None:
        stderr_path.parent.mkdir(parents=True, exist_ok=True)
        self._stderr = stderr_path.open("w")
        self.stderr_path = stderr_path
        self.process = subprocess.Popen(list(command), stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=self._stderr, env=dict(env), cwd=str(cwd), text=True, bufsize=1)
        self._lines: queue.Queue[str | None] = queue.Queue()
        self._reader = threading.Thread(target=self._read, daemon=True)
        self._reader.start()
        self._next = 0

    def _read(self) -> None:
        assert self.process.stdout is not None
        for line in self.process.stdout:
            self._lines.put(line)
        self._lines.put(None)

    def call(self, method: str, params: Mapping[str, Any], timeout: float) -> Mapping[str, Any]:
        self._next += 1
        request_id = f"sota_{self._next}"
        assert self.process.stdin is not None
        try:
            self.process.stdin.write(json.dumps({"jsonrpc": "2.0", "id": request_id, "method": method,
                                                 "params": params}, separators=(",", ":")) + "\n")
            self.process.stdin.flush()
        except (BrokenPipeError, OSError) as exc:
            raise DaemonError(f"daemon exited before {method}: {self.stderr_tail()}") from exc
        try:
            line = self._lines.get(timeout=timeout)
        except queue.Empty as exc:
            self.kill()
            raise DaemonError(f"{method} timed out after {timeout}s") from exc
        if line is None:
            raise DaemonError(f"daemon exited during {method}: {self.stderr_tail()}")
        response = json.loads(line)
        if response.get("id") != request_id:
            raise DaemonError(f"response id mismatch for {method}")
        if "error" in response:
            error = response["error"]
            raise DaemonError(f"{method} failed: {error.get('code')} {error.get('message')}")
        return response["result"]

    def stderr_tail(self, limit: int = 600) -> str:
        try:
            self._stderr.flush()
            return self.stderr_path.read_text(errors="replace")[-limit:]
        except OSError:
            return ""

    def kill(self) -> None:
        if self.process.poll() is None:
            self.process.kill()

    def close(self) -> None:
        if self.process.stdin is not None:
            try:
                self.process.stdin.close()
            except OSError:
                pass
        try:
            self.process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait(timeout=10)
        self._stderr.close()


def daemon_env(home: Path) -> dict[str, str]:
    env = {key: os.environ[key] for key in DAEMON_ENV_PASSTHROUGH if key in os.environ}
    # HOME/cwd isolation avoids ~/.quipu/config.yaml, ./quipu.yaml and the shared default DB.
    env.update({"HOME": str(home), "OPENROUTER_API_KEY": PROXY_KEY_PLACEHOLDER})
    return env


def daemon_command(config: Mapping[str, Any], *, answer_url: str, embedding_url: str | None,
                   db_path: Path | None) -> list[str]:
    command = [str(config["daemonBinary"])]
    if db_path is not None:
        command += ["--db", str(db_path)]
    command += ["--answer-provider", "openrouter", "--answer-url", answer_url,
                "--answer-model", config["readerModel"], "--entity-provider", "none"]
    if embedding_url is not None:
        command += ["--embedding-provider", "openrouter", "--embedding-url", embedding_url,
                    "--embedding-model", config["embeddingModel"]]
    if config.get("vectorDimensions"):
        command += ["--vector-dimensions", str(config["vectorDimensions"])]
    if config.get("rerankerUrl"):
        command += ["--reranker-url", config["rerankerUrl"]]
        if config.get("rerankerModel"):
            command += ["--reranker-model", config["rerankerModel"]]
    command += list(config.get("daemonArgs") or [])
    return [*command, "serve-stdio"]


def reranker_health(url: str | None, timeout: float = 5.0) -> dict[str, Any] | None:
    """``GET /health`` of a ``rerank_server`` (model, max length, device); None if absent."""
    if not url:
        return None
    parts = urllib.parse.urlsplit(url)
    health_url = urllib.parse.urlunsplit((parts.scheme, parts.netloc, "/health", "", ""))
    try:
        with urllib.request.urlopen(health_url, timeout=timeout) as response:
            info = json.loads(response.read())
    except (OSError, ValueError):
        return None
    return info if isinstance(info, dict) else None


def rerank_summary(trace: Any) -> dict[str, Any] | None:
    """The daemon's retrieval-trace rerank block, minus per-item scores."""
    rerank = trace.get("rerank") if isinstance(trace, Mapping) else None
    if not isinstance(rerank, Mapping):
        return None
    top = rerank.get("topScores") or []
    return {"status": rerank.get("status"), "model": rerank.get("model"), "windowSize": rerank.get("windowSize"),
            "rerankedCount": rerank.get("rerankedCount"), "latencyMs": rerank.get("latencyMs"),
            "topScore": top[0].get("score") if top and isinstance(top[0], Mapping) else None,
            "error": rerank.get("error")}


# ---------------------------------------------------------------------------
# Per-question run


def load_formatter(path: Path) -> Callable[..., str]:
    from .longmemeval_study import load_grader
    return load_grader(path)


def judge_answer(judge_client: Any, formatter: Callable[..., str], case: Mapping[str, Any], answer: str) -> dict[str, Any]:
    """E1's ``official_judge`` unchanged, fed the same fields E1's suites carry."""
    from .longmemeval_study import official_judge
    scenario = SimpleNamespace(
        metadata={"questionType": case["questionType"]},
        queries=[SimpleNamespace(query=case["question"], expected_answer=case["answer"],
                                 should_abstain=case["abstention"])],
    )
    return official_judge(judge_client, formatter, scenario, answer)


def summarize_calls(records: Sequence[Mapping[str, Any]]) -> dict[str, Any]:
    chat = [r for r in records if r["endpoint"] == "chat/completions"]
    embeddings = [r for r in records if r["endpoint"] == "embeddings"]
    return {
        "chatCalls": len(chat), "embeddingCalls": len(embeddings),
        "chatErrors": sum(r["status"] != 200 for r in chat),
        "embeddingErrors": sum(r["status"] != 200 for r in embeddings),
        "readerPromptTokens": sum(r.get("promptTokens") or 0 for r in chat),
        "readerCompletionTokens": sum(r.get("completionTokens") or 0 for r in chat),
        "costUsd": sum(r.get("costUsd") or 0.0 for r in records),
        "nominalCostUsd": sum(r.get("nominalCostUsd") or 0.0 for r in records),
        "providerLatencyMs": sum(r.get("latencyMs") or 0.0 for r in records),
    }


def judge_cost(calls: Sequence[Mapping[str, Any]]) -> tuple[float, float]:
    fresh = nominal = 0.0
    for call in calls:
        cost = (call.get("usage") or {}).get("cost")
        if isinstance(cost, (int, float)):
            nominal += cost
            if not call.get("cached"):
                fresh += cost
    return fresh, nominal


def run_question(case: Mapping[str, Any], config: Mapping[str, Any], proxy: Any,
                 formatter: Callable[..., str], judge_cache: Path, count: Callable[[str], int],
                 run_dir: Path) -> dict[str, Any]:
    from .longmemeval_study import client as study_client
    question_id = case["questionId"]
    tag = question_id
    record: dict[str, Any] = {"questionId": question_id, "category": case["category"],
                              "question": case["question"], "reference": case["answer"],
                              "questionTime": case["questionTime"], "sessions": len(case["sessions"]),
                              "messages": sum(len(s["messages"]) for s in case["sessions"]),
                              "goldTurns": case["goldTurns"], "evidenceSessions": case["evidenceSessions"],
                              "rows": [], "ingest": None, "status": "ok"}
    budgets = config["budgets"]

    def failed_rows(stage: str, error: str) -> list[dict[str, Any]]:
        return [{"questionId": question_id, "category": case["category"], "budget": budget,
                 "status": "error", "errorStage": stage, "error": error[:1000], "correct": None}
                for budget in budgets if budget not in {row["budget"] for row in record["rows"]}]

    with tempfile.TemporaryDirectory(prefix="quipu-sota-") as temporary:
        home = Path(temporary)
        db_path = None
        if config["lattice"]:
            base = Path(config["dbDir"]) / question_id if config.get("dbDir") else home / "db"
            if base.exists():
                shutil.rmtree(base)
            base.mkdir(parents=True)
            db_path = base / "q.lattice"
        command = daemon_command(
            config, answer_url=proxy.url(tag, "chat/completions"),
            embedding_url=proxy.url(tag, "embeddings") if config["embeddingViaProxy"] else None,
            db_path=db_path)
        record["daemonCommand"] = [part if "/q/" not in part else part.replace(proxy.base_url, "<proxy>")
                                   for part in command]
        daemon = Daemon(command, env=daemon_env(home), cwd=home,
                        stderr_path=run_dir / "logs" / f"{question_id}.stderr")
        try:
            # Ingest ---------------------------------------------------------
            qid_to_turn: dict[str, tuple[str, int]] = {}
            mark = proxy.state.mark()
            started = time.perf_counter()
            warnings = []
            try:
                for session in case["sessions"]:
                    result = daemon.call("memory.remember", {
                        "scope": case["scope"], "sessionId": session["sessionId"],
                        "messages": session["messages"], "extract": config["extract"],
                    }, timeout=config["rememberTimeout"])
                    message_qids = list(result.get("messageQids") or [])
                    if len(message_qids) != len(session["messages"]):
                        warnings.append(f"{session['sessionId']}: {len(message_qids)} qids for "
                                        f"{len(session['messages'])} messages ({result.get('status')})")
                    for index, qid in enumerate(message_qids):
                        qid_to_turn[qid] = (session["sessionId"], index)
            except (DaemonError, ValueError) as exc:
                record["status"] = "error"
                record["rows"] = failed_rows("ingest", str(exc))
                record["ingest"] = {"seconds": time.perf_counter() - started, "error": str(exc)[:1000]}
                return record
            record["ingest"] = {"seconds": time.perf_counter() - started, "warnings": warnings,
                                "messageQids": len(qid_to_turn),
                                "calls": summarize_calls(proxy.state.records_for(tag, mark))}

            # Answer + judge per budget ---------------------------------------
            for budget in budgets:
                params: dict[str, Any] = {
                    "query": case["question"], "scope": case["scope"],
                    "time": {"validAt": case["questionTime"]}, "budgetTokens": budget,
                    "options": {**(config.get("answerOptions") or {}),
                                "includeDebug": True, "includeEvidence": True},
                }
                if config.get("needs"):
                    params["needs"] = config["needs"]
                if config.get("mode"):
                    params["mode"] = config["mode"]
                mark = proxy.state.mark()
                started = time.perf_counter()
                try:
                    result = daemon.call("memory.answer", params, timeout=config["answerTimeout"])
                except DaemonError as exc:
                    calls = summarize_calls(proxy.state.records_for(tag, mark))
                    record["rows"].append({"questionId": question_id, "category": case["category"],
                                           "budget": budget, "status": "error", "errorStage": "answer",
                                           "error": str(exc)[:1000], "correct": None,
                                           "answerLatencyMs": (time.perf_counter() - started) * 1000,
                                           "calls": calls})
                    if daemon.process.poll() is not None:
                        record["rows"] += failed_rows("answer", f"daemon exited: {exc}")
                        break
                    continue
                latency = (time.perf_counter() - started) * 1000
                calls = summarize_calls(proxy.state.records_for(tag, mark))
                context, source = reader_context(result)
                items = [item for item in result.get("items") or [] if isinstance(item, Mapping)]
                all_turns = item_turns(items, qid_to_turn)
                raw_turns = item_turns(items, qid_to_turn, raw_only=True)
                answer_text = str(result.get("answer") or "")
                trace = result.get("answerTrace") if isinstance(result.get("answerTrace"), Mapping) else {}
                row = {
                    "questionId": question_id, "category": case["category"], "budget": budget,
                    "status": "ok", "answer": answer_text,
                    "answerLatencyMs": latency, "calls": calls,
                    "llmAnswered": calls["chatCalls"] > 0,
                    "strategy": trace.get("strategy"), "answerable": trace.get("answerable"),
                    "contextSource": source, "contextTokens": count(context),
                    "contextChars": len(context), "items": len(items),
                    "itemTypes": dict(Counter(str(item.get("type")) for item in items)),
                    "unmappedItems": sum(1 for item in items
                                         if not any(q in qid_to_turn for q in linked_message_qids(item))),
                    **coverage(case, all_turns),
                    "rawOnly": coverage(case, raw_turns),
                    "warnings": result.get("warnings"),
                    "rerank": rerank_summary(result.get("trace")),
                    "tokenEstimate": result.get("tokenEstimate"),
                    "context": context,
                    "itemRefs": [{"qid": item.get("qid"), "type": item.get("type"), "score": item.get("score"),
                                  "turns": sorted(item_turns([item], qid_to_turn))} for item in items],
                    "answerTrace": trace,
                }
                try:
                    judge_client = study_client(judge_cache)
                    judgment = judge_answer(judge_client, formatter, case, answer_text)
                    fresh, nominal = judge_cost(judge_client.calls)
                    row.update({"judgment": judgment, "correct": judgment["correct"],
                                "judgeCostUsd": fresh, "judgeNominalCostUsd": nominal})
                except Exception as exc:  # Judge failures are errors, never wrong answers.
                    row.update({"status": "error", "errorStage": "judge", "error": str(exc)[:1000],
                                "correct": None})
                record["rows"].append(row)
        finally:
            daemon.close()
    if any(row["status"] != "ok" for row in record["rows"]):
        record["status"] = "error"
    return record


# ---------------------------------------------------------------------------
# Aggregation and reporting


def mean(values: Iterable[Any]) -> float | None:
    present = [float(value) for value in values if value is not None]
    return sum(present) / len(present) if present else None


def percentile(values: Iterable[float], q: float) -> float | None:
    ordered = sorted(float(value) for value in values if value is not None)
    if not ordered:
        return None
    rank = max(1, min(len(ordered), int(-(-q * len(ordered) // 1))))  # nearest-rank
    return ordered[rank - 1]


def summarize_rows(rows: Sequence[Mapping[str, Any]]) -> dict[str, Any]:
    ok = [row for row in rows if row.get("status") == "ok"]
    correct = sum(bool(row.get("correct")) for row in ok)
    calls = [row.get("calls") or {} for row in rows]
    llm_rows = [row for row in ok if row.get("llmAnswered") is not None]
    return {
        "n": len(rows), "completed": len(ok), "errors": len(rows) - len(ok),
        "completionRate": len(ok) / len(rows) if rows else None,
        "correct": correct,
        "accuracy": correct / len(ok) if ok else None,
        "accuracyAllQuestions": correct / len(rows) if rows else None,
        "goldSessionCoverage": mean(row.get("goldSessionCoverage") for row in ok),
        "goldTurnCoverage": mean(row.get("goldTurnCoverage") for row in ok),
        "allGoldTurnsRate": mean(None if row.get("allGoldTurns") is None else float(row["allGoldTurns"]) for row in ok),
        "goldTurnCoverageRawItems": mean((row.get("rawOnly") or {}).get("goldTurnCoverage") for row in ok),
        "contextTokensMean": mean(row.get("contextTokens") for row in ok),
        "contextTokensP50": percentile((row.get("contextTokens") for row in ok), .5),
        "contextTokensMax": max((row.get("contextTokens") or 0 for row in ok), default=None),
        "answerLatencyMsP50": percentile((row.get("answerLatencyMs") for row in ok), .5),
        "answerLatencyMsP95": percentile((row.get("answerLatencyMs") for row in ok), .95),
        "llmAnsweredRate": mean(float(row["llmAnswered"]) for row in llm_rows) if llm_rows else None,
        "chatCalls": sum(call.get("chatCalls", 0) for call in calls),
        "answerCostUsd": sum(call.get("costUsd", 0.0) for call in calls),
        "answerNominalCostUsd": sum(call.get("nominalCostUsd", 0.0) for call in calls),
        "judgeCostUsd": sum(row.get("judgeCostUsd") or 0.0 for row in rows),
        "judgeNominalCostUsd": sum(row.get("judgeNominalCostUsd") or 0.0 for row in rows),
        **summarize_rerank(ok),
    }


def summarize_rerank(rows: Sequence[Mapping[str, Any]]) -> dict[str, Any]:
    """Rerank stage outcomes; empty when no row carries a rerank trace."""
    reranks = [row["rerank"] for row in rows if isinstance(row.get("rerank"), Mapping)]
    if not reranks:
        return {}
    applied = [r for r in reranks if r.get("status") == "applied"]
    return {"rerankStatuses": dict(Counter(str(r.get("status")) for r in reranks)),
            "rerankLatencyMsP50": percentile((r.get("latencyMs") for r in applied if r.get("latencyMs") is not None), .5),
            "rerankLatencyMsP95": percentile((r.get("latencyMs") for r in applied if r.get("latencyMs") is not None), .95)}


def summarize_ingest(records: Sequence[Mapping[str, Any]]) -> dict[str, Any]:
    ingests = [r["ingest"] for r in records if isinstance(r.get("ingest"), Mapping)]
    ok = [i for i in ingests if "error" not in i]
    calls = [i.get("calls") or {} for i in ok]
    return {
        "questions": len(records), "ingestErrors": len(ingests) - len(ok) + (len(records) - len(ingests)),
        "secondsMean": mean(i["seconds"] for i in ok), "secondsP50": percentile((i["seconds"] for i in ok), .5),
        "secondsP95": percentile((i["seconds"] for i in ok), .95), "secondsTotal": sum(i["seconds"] for i in ok),
        "embeddingCalls": sum(c.get("embeddingCalls", 0) for c in calls),
        "chatCalls": sum(c.get("chatCalls", 0) for c in calls),
        "costUsd": sum(c.get("costUsd", 0.0) for c in calls),
        "nominalCostUsd": sum(c.get("nominalCostUsd", 0.0) for c in calls),
        "sessionsMean": mean(r.get("sessions") for r in records),
        "messagesMean": mean(r.get("messages") for r in records),
    }


def failure_breakdown(rows: Sequence[Mapping[str, Any]]) -> dict[str, Any]:
    """Coarse attribution of wrong answers (answerable questions only)."""
    buckets: Counter[str] = Counter()
    for row in rows:
        if row.get("status") != "ok" or row.get("correct"):
            continue
        if row.get("goldTurnCoverage") is None:
            bucket = "abstention_wrong"
        elif row.get("llmAnswered") is False:
            bucket = "no_llm_call"
        elif row["goldTurnCoverage"] == 0:
            bucket = "retrieval_miss"
        elif row["goldTurnCoverage"] < 1:
            bucket = "partial_retrieval"
        else:
            bucket = "full_coverage_reader_wrong"
        buckets[bucket] += 1
    no_llm = [row for row in rows if row.get("status") == "ok" and row.get("llmAnswered") is False]
    return {"wrongByCause": dict(buckets),
            "noLlmAnswers": len(no_llm), "noLlmCorrect": sum(bool(row.get("correct")) for row in no_llm),
            "strategies": dict(Counter(str(row.get("strategy")) for row in rows if row.get("status") == "ok"))}


def aggregate(rows: Sequence[Mapping[str, Any]], budgets: Sequence[int]) -> dict[str, Any]:
    summary, by_category, failures = {}, {}, {}
    for budget in budgets:
        group = [row for row in rows if row["budget"] == budget]
        summary[str(budget)] = summarize_rows(group)
        failures[str(budget)] = failure_breakdown(group)
        by_category[str(budget)] = {category: summarize_rows([row for row in group if row["category"] == category])
                                    for category in sorted({row["category"] for row in group})}
    return {"summary": summary, "byCategory": by_category, "failures": failures}


def git_identity(path: Path) -> dict[str, Any]:
    """Commit of the checkout containing ``path``; dirty only counts files under ``path``."""
    def git(*args: str) -> str:
        return subprocess.run(["git", *args], cwd=str(path), capture_output=True, text=True).stdout.strip()
    return {"commit": git("rev-parse", "HEAD"), "branch": git("rev-parse", "--abbrev-ref", "HEAD"),
            "dirty": bool(git("status", "--porcelain", "--untracked-files=no", "--", "."))}


def sha256_file(path: Path) -> str:
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def fmt(value: Any, kind: str = "") -> str:
    if value is None:
        return "–"
    if kind == "pct":
        return f"{100 * value:.1f}%"
    if kind == "usd":
        return f"${value:.4f}"
    if kind == "ms":
        return f"{value:,.0f}"
    if isinstance(value, float):
        return f"{value:.2f}"
    return str(value)


def markdown(report: Mapping[str, Any]) -> str:
    identity = report["identity"]
    lines = [f"# {report['title']}", "",
             "Dev-slice measurement, not a leaderboard submission. Official LongMemEval judge only.", "",
             "| Field | Value |", "| --- | --- |"]
    for key, value in identity.items():
        if isinstance(value, (dict, list)):
            value = json.dumps(value, sort_keys=True)
        lines.append(f"| {key} | `{value}` |")
    lines += ["", "## Overall", "",
              "| Budget | Correct | Accuracy (completed) | Completion | Gold-session cov. | Gold-turn cov. | All gold turns | Context tokens (mean / max) | Answer p50 / p95 ms | LLM-answered | Answer cost | Judge cost |",
              "| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |"]
    for budget, s in report["summary"].items():
        lines.append(f"| {budget} | {s['correct']}/{s['n']} | {fmt(s['accuracy'], 'pct')} | {fmt(s['completionRate'], 'pct')} | "
                     f"{fmt(s['goldSessionCoverage'], 'pct')} | {fmt(s['goldTurnCoverage'], 'pct')} | {fmt(s['allGoldTurnsRate'], 'pct')} | "
                     f"{fmt(s['contextTokensMean'])} / {fmt(s['contextTokensMax'])} | {fmt(s['answerLatencyMsP50'], 'ms')} / {fmt(s['answerLatencyMsP95'], 'ms')} | "
                     f"{fmt(s['llmAnsweredRate'], 'pct')} | {fmt(s['answerCostUsd'], 'usd')} | {fmt(s['judgeCostUsd'], 'usd')} |")
    reranked = {budget: s for budget, s in report["summary"].items() if s.get("rerankStatuses")}
    if reranked:
        lines += ["", "## Rerank", "", "| Budget | Statuses | Rerank p50 / p95 ms |", "| ---: | --- | ---: |"]
        for budget, s in reranked.items():
            lines.append(f"| {budget} | {json.dumps(s['rerankStatuses'], sort_keys=True)} | "
                         f"{fmt(s.get('rerankLatencyMsP50'), 'ms')} / {fmt(s.get('rerankLatencyMsP95'), 'ms')} |")
    for budget, categories in report["byCategory"].items():
        lines += ["", f"## By category, {budget} tokens", "",
                  "| Category | Correct | Accuracy | Errors | Gold-session cov. | Gold-turn cov. | Context tokens | LLM-answered |",
                  "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |"]
        for category, s in categories.items():
            lines.append(f"| {category} | {s['correct']}/{s['n']} | {fmt(s['accuracy'], 'pct')} | {s['errors']} | "
                         f"{fmt(s['goldSessionCoverage'], 'pct')} | {fmt(s['goldTurnCoverage'], 'pct')} | "
                         f"{fmt(s['contextTokensMean'])} | {fmt(s['llmAnsweredRate'], 'pct')} |")
    if report.get("failures"):
        lines += ["", "## Wrong-answer attribution", "",
                  "Coverage is a message-level proxy from LongMemEval `has_answer` turns, not semantic sufficiency.", "",
                  "| Budget | Wrong by cause | No-LLM answers (correct) | Strategies |", "| ---: | --- | ---: | --- |"]
        for budget, f in report["failures"].items():
            lines.append(f"| {budget} | {json.dumps(f['wrongByCause'], sort_keys=True)} | "
                         f"{f['noLlmAnswers']} ({f['noLlmCorrect']}) | {json.dumps(f['strategies'], sort_keys=True)} |")
    if report.get("ingest"):
        i = report["ingest"]
        lines += ["", "## Ingest", "",
                  f"Questions {i['questions']}, errors {i['ingestErrors']}, mean sessions {fmt(i['sessionsMean'])}, "
                  f"mean messages {fmt(i['messagesMean'])}; seconds mean {fmt(i['secondsMean'])}, p50 {fmt(i['secondsP50'])}, "
                  f"p95 {fmt(i['secondsP95'])}; embedding calls {i['embeddingCalls']}, cost {fmt(i['costUsd'], 'usd')}."]
    if report.get("spend"):
        lines += ["", "## Spend", "", "```json", json.dumps(report["spend"], indent=2, sort_keys=True), "```"]
    if report.get("errors"):
        lines += ["", "## Errors", ""] + [f"- `{e['questionId']}` @{e['budget']} ({e.get('errorStage')}): {e.get('error', '')[:200]}"
                                          for e in report["errors"]]
    return "\n".join(lines) + "\n"


def write_report(run_dir: Path, report: Mapping[str, Any]) -> None:
    write_json(run_dir / "report.json", report)
    (run_dir / "report.md").write_text(markdown(report))


# ---------------------------------------------------------------------------
# run


def tokenizer_counter(name: str) -> Callable[[str], int]:
    import tiktoken
    encoder = tiktoken.get_encoding(name)
    return lambda text: len(encoder.encode(text, disallowed_special=()))


def cmd_run(args: argparse.Namespace) -> int:
    from .caching_proxy import CachingProxy, ProxyState, summarize_records
    if not os.environ.get("OPENROUTER_API_KEY") and not args.offline:
        print("OPENROUTER_API_KEY is required (or pass --offline to serve cache hits only)", file=sys.stderr)
        return 2
    if args.lattice and not args.db_dir:
        print("note: --lattice without --db-dir uses a fresh temporary DB per question", file=sys.stderr)
    run_dir = args.artifacts / args.run_name
    run_dir.mkdir(parents=True, exist_ok=True)
    data = {item["question_id"]: item for item in json.loads(args.dataset.read_text())}
    selection = load_selection(args.selection)
    if args.limit:
        selection = selection[:args.limit]
    if args.questions:
        wanted = set(args.questions)
        selection = [qid for qid in selection if qid in wanted]
    binary = Path(args.daemon_binary).resolve()
    build_info_path = binary.parent.parent / "build-info.json"
    config = {
        "daemonBinary": str(binary), "lattice": args.lattice,
        "dbDir": str(args.db_dir) if args.db_dir else None,
        "embeddingViaProxy": args.embedding_provider_via_proxy, "embeddingModel": args.embedding_model,
        "vectorDimensions": args.vector_dimensions, "readerModel": args.reader_model,
        "budgets": args.budgets, "extract": not args.no_extract, "needs": args.needs, "mode": args.mode,
        "daemonArgs": args.daemon_arg or [], "answerOptions": parse_answer_options(args.answer_option),
        "rerankerUrl": args.reranker_url, "rerankerModel": args.reranker_model,
        "rememberTimeout": args.remember_timeout,
        "answerTimeout": args.answer_timeout,
    }
    reranker = reranker_health(args.reranker_url)
    if args.reranker_url:
        if reranker is None:
            print(f"warning: no rerank_server health at {args.reranker_url}; "
                  "answers will carry rerank_failed if it is unreachable", file=sys.stderr)
        elif not args.reranker_model:
            config["rerankerModel"] = reranker.get("model")
        elif reranker.get("model") != args.reranker_model:
            print(f"--reranker-model {args.reranker_model!r} does not match the server's "
                  f"{reranker.get('model')!r}", file=sys.stderr)
            return 2
    identity = {
        "runName": args.run_name, "startedAt": datetime.now(timezone.utc).isoformat(),
        "harnessGit": git_identity(ROOT),
        "binary": str(binary), "binarySha256": sha256_file(binary),
        "binaryBuildInfo": json.loads(build_info_path.read_text()) if build_info_path.exists() else None,
        "readerModel": args.reader_model, "judgeModel": JUDGE_MODEL,
        "embeddingModel": args.embedding_model if args.embedding_provider_via_proxy else None,
        "rerankerModel": config["rerankerModel"] if args.reranker_url else None,
        "rerankerServer": ({k: reranker.get(k) for k in ("model", "maxLength", "device")} if reranker else None),
        "tokenizer": TOKENIZER, "budgets": args.budgets,
        "selection": str(args.selection), "selectionSha256": sha256_file(args.selection),
        "selectionSeed": json.loads(args.selection.read_text()).get("seed") if args.selection.suffix == ".json" else None,
        "questions": len(selection), "datasetSha256": sha256_file(args.dataset),
        "graderSha256": sha256_file(args.upstream),
        "judge": "official LongMemEval get_anscheck_prompt (upstream 9e0b455f), via longmemeval_study.official_judge",
        "daemonConfig": {k: v for k, v in config.items() if k not in ("daemonBinary",)},
    }
    # The reranker URL only locates the server; its model and max length decide the scores.
    config_hash = digest([identity["binarySha256"], identity["datasetSha256"], identity["graderSha256"],
                          {k: v for k, v in config.items()
                           if k not in ("dbDir", "rememberTimeout", "answerTimeout", "rerankerUrl")},
                          *([{"rerankerMaxLength": reranker.get("maxLength")}] if reranker else [])])
    identity["configHash"] = config_hash
    write_json(run_dir / "manifest.json", identity)
    formatter = load_formatter(args.upstream)
    count = tokenizer_counter(TOKENIZER)
    state = ProxyState(args.proxy_cache, run_dir / "proxy.jsonl", max_spend_usd=args.max_spend_usd,
                       offline=args.offline)
    records: list[dict[str, Any]] = []
    cases_dir = run_dir / "cases"
    todo = []
    for qid in selection:
        path = cases_dir / f"{qid}.json"
        if path.exists() and not args.fresh:
            previous = json.loads(path.read_text())
            if previous.get("configHash") == config_hash and previous.get("status") == "ok":
                records.append(previous)
                continue
        todo.append(qid)
    print(f"{len(selection)} questions; {len(records)} reused; {len(todo)} to run", flush=True)
    started = time.perf_counter()
    with CachingProxy(state) as proxy, ThreadPoolExecutor(max_workers=args.workers) as executor:
        futures = {executor.submit(run_question, build_case(data[qid]), config, proxy, formatter,
                                   args.judge_cache, count, run_dir): qid for qid in todo}
        for done, future in enumerate(as_completed(futures), 1):
            qid = futures[future]
            try:
                record = future.result()
            except Exception as exc:  # Harness bug: keep going, record as runtime error.
                record = {"questionId": qid, "category": category_of(data[qid]), "status": "error",
                          "ingest": None, "rows": [{"questionId": qid, "category": category_of(data[qid]),
                                                    "budget": b, "status": "error", "errorStage": "harness",
                                                    "error": f"{type(exc).__name__}: {exc}"[:1000], "correct": None}
                                                   for b in args.budgets]}
            record["configHash"] = config_hash
            write_json(cases_dir / f"{qid}.json", record)
            records.append(record)
            marks = " ".join(f"{row['budget']}:{'ERR' if row['status'] != 'ok' else ('Y' if row['correct'] else 'n')}"
                             for row in record["rows"])
            print(f"[{done}/{len(todo)}] {qid} ({record['category']}) {marks} spent=${state.spent_usd:.4f}", flush=True)
        proxy_totals = summarize_records(state.records)
    records.sort(key=lambda r: r["questionId"])
    rows = [row for record in records for row in record["rows"]]
    rows.sort(key=lambda row: (row["questionId"], row["budget"]))
    judge_fresh = sum(row.get("judgeCostUsd") or 0.0 for row in rows)
    judge_nominal = sum(row.get("judgeNominalCostUsd") or 0.0 for row in rows)
    report = {
        "title": f"Quipu daemon on LongMemEval-S dev slice: {args.run_name}",
        "identity": identity, "elapsedSeconds": time.perf_counter() - started,
        **aggregate(rows, args.budgets), "ingest": summarize_ingest(records),
        "spend": {"thisInvocationProxy": proxy_totals,
                  "judgeFreshUsdAllRows": judge_fresh, "judgeNominalUsdAllRows": judge_nominal,
                  "note": "proxy costUsd/judgeFresh are new spend; nominal includes cache hits' original cost"},
        "errors": [row for row in rows if row["status"] != "ok"],
        "rows": [{k: v for k, v in row.items() if k not in ("context", "itemRefs", "answerTrace")} for row in rows],
    }
    write_report(run_dir, report)
    print(markdown(report))
    return 0


# ---------------------------------------------------------------------------
# E1 reference summaries and paired comparison


def e1_rows(report_path: Path, arm: str = "raw") -> list[dict[str, Any]]:
    """Normalize an E1 longmemeval_study report into this harness's row shape."""
    report = json.loads(report_path.read_text())
    case_dir = report_path.parent / "cases"
    rows = []
    for row in report["rows"]:
        if row["arm"] != arm:
            continue
        calls = []
        case_path = case_dir / f"{row['queryId']}.json"
        if case_path.exists():
            calls = json.loads(case_path.read_text()).get("calls", [])
        # evaluate_one loops arms in CLI order, then budgets in CLI order; each
        # observation makes one successful reader call and one judge call.
        arms = list((report.get("config") or {}).get("arms") or [arm])
        budgets = list((report.get("config") or {}).get("budgets") or [row["budget"]])
        position = arms.index(arm) * len(budgets) + budgets.index(row["budget"])

        def nth(stage: str) -> Mapping[str, Any]:
            matching = [c for c in calls if c.get("stage") == stage and c.get("status", "ok") == "ok"]
            return matching[position] if position < len(matching) else {}

        def cost(call: Mapping[str, Any]) -> tuple[float, float]:
            value = (call.get("usage") or {}).get("cost") or 0.0
            return (0.0 if call.get("cached") else value), value

        reader_call, judge_call = nth("answer"), nth("official_judge")
        reader_fresh, reader_nominal = cost(reader_call)
        judge_fresh, judge_nominal = cost(judge_call)
        rows.append({
            "questionId": row["queryId"], "category": row["category"], "budget": row["budget"],
            "status": "ok", "correct": row["judgment"]["correct"], "answer": row["reader"]["answer"],
            "contextTokens": row["contextUnits"], "goldTurnCoverage": row.get("goldTurnRecall"),
            "goldSessionCoverage": row["evidence"]["sourceEventRecall"],
            "allGoldTurns": None if row.get("goldTurnRecall") is None else row["goldTurnRecall"] == 1,
            # E1 has no ingest phase: its retrievalMs embeds the whole haystack, so it is
            # kept separate; answer latency here is the reader call alone.
            "answerLatencyMs": reader_call.get("durationMs"), "retrievalMs": row.get("retrievalMs"),
            "llmAnswered": True,
            "calls": {"chatCalls": 1, "costUsd": reader_fresh, "nominalCostUsd": reader_nominal},
            "judgeCostUsd": judge_fresh, "judgeNominalCostUsd": judge_nominal,
        })
    return rows


def cmd_summarize_e1(args: argparse.Namespace) -> int:
    rows = e1_rows(args.report, args.arm)
    budgets = sorted({row["budget"] for row in rows})
    source = json.loads(args.report.read_text())
    cost = {"fresh": defaultdict(float), "nominal": defaultdict(float)}
    for path in sorted((args.report.parent / "cases").glob("*.json")):
        for call in json.loads(path.read_text()).get("calls", []):
            value = (call.get("usage") or {}).get("cost")
            if isinstance(value, (int, float)):
                cost["nominal"][call.get("stage", "unknown")] += value
                if not call.get("cached"):
                    cost["fresh"][call.get("stage", "unknown")] += value
    report = {
        "title": f"E1 {args.arm} reference: {args.report.parent.name}",
        "identity": {"source": str(args.report), "models": source.get("models"),
                     "suiteHash": source.get("suiteHash"), "codeHash": source.get("codeHash"),
                     "graderHash": source.get("graderHash"), "tokenizer": source.get("tokenizer"),
                     "budgets": budgets, "questions": len({row["questionId"] for row in rows}),
                     "e1Errors": len(source.get("errors") or []),
                     "retrievalMsP50IncludingHaystackEmbedding": percentile((r.get("retrievalMs") for r in rows), .5),
                     "latencyNote": "answer p50/p95 = reader call only; E1 embeds the haystack at query time"},
        **aggregate(rows, budgets),
        "spend": {"byStageFreshUsd": dict(cost["fresh"]), "byStageNominalUsd": dict(cost["nominal"]),
                  "freshTotalUsd": sum(cost["fresh"].values()), "nominalTotalUsd": sum(cost["nominal"].values()),
                  "note": "E1 calls from per-case files; embedding/judge stages included; cached calls cost $0 fresh"},
        "errors": [], "rows": rows,
    }
    report.pop("failures", None)
    out = args.output or args.report.parent
    write_json(out / "summary.json", report)
    (out / "summary.md").write_text(markdown(report))
    print(markdown(report))
    return 0


def load_run_rows(path: Path, arm: str = "raw") -> list[dict[str, Any]]:
    report = json.loads(path.read_text())
    if "rows" in report and report["rows"] and "arm" in report["rows"][0]:
        return e1_rows(path, arm)
    return list(report["rows"])


def paired_comparison(rows_a: Sequence[Mapping[str, Any]], rows_b: Sequence[Mapping[str, Any]],
                      *, repeats: int = 10000, seed: int = 20261001) -> list[dict[str, Any]]:
    """B versus A at each common budget, on questions both completed."""
    from .study_analysis import paired_with_exact_test
    index_a = {(r["questionId"], r["budget"]): r for r in rows_a}
    results = []
    for budget in sorted({r["budget"] for r in rows_b} & {r["budget"] for r in rows_a}):
        pairs, excluded = [], 0
        for row in rows_b:
            if row["budget"] != budget:
                continue
            other = index_a.get((row["questionId"], budget))
            if other is None:
                continue
            if row.get("status") != "ok" or other.get("status") != "ok":
                excluded += 1
                continue
            pairs.append((other, row))
        shaped = [{"queryId": b["questionId"], "arm": arm, "budget": budget, "judgment": {"correct": bool(x["correct"])}}
                  for a, b in pairs for arm, x in (("A", a), ("B", b))]
        if not shaped:
            continue
        result = paired_with_exact_test(shaped, reference="A", repeats=repeats, seed=seed)[0]
        categories: dict[str, dict[str, int]] = defaultdict(lambda: {"n": 0, "wins": 0, "losses": 0, "aCorrect": 0, "bCorrect": 0})
        for a, b in pairs:
            group = categories[b["category"]]
            group["n"] += 1
            group["aCorrect"] += bool(a["correct"])
            group["bCorrect"] += bool(b["correct"])
            group["wins"] += bool(b["correct"]) and not a["correct"]
            group["losses"] += bool(a["correct"]) and not b["correct"]
        results.append({**result, "budget": budget, "excludedForErrors": excluded,
                        "aCorrect": sum(bool(a["correct"]) for a, _ in pairs),
                        "bCorrect": sum(bool(b["correct"]) for _, b in pairs),
                        "winQuestions": sorted(b["questionId"] for a, b in pairs if b["correct"] and not a["correct"]),
                        "lossQuestions": sorted(b["questionId"] for a, b in pairs if a["correct"] and not b["correct"]),
                        "byCategory": dict(sorted(categories.items()))})
    return results


def cmd_compare(args: argparse.Namespace) -> int:
    rows_a = load_run_rows(args.a, args.arm_a)
    rows_b = load_run_rows(args.b, args.arm_b)
    results = paired_comparison(rows_a, rows_b, repeats=args.repeats)
    lines = [f"# Paired comparison", "", f"A = `{args.a}`", f"B = `{args.b}`", "",
             "Wins are questions B answers correctly and A does not. Exact two-sided McNemar p is unadjusted; "
             "the bootstrap interval is descriptive.", "",
             "| Budget | n | A correct | B correct | Wins / losses | Delta | Bootstrap 95% | McNemar p | Excluded (errors) |",
             "| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |"]
    for r in results:
        lines.append(f"| {r['budget']} | {r['n']} | {r['aCorrect']} | {r['bCorrect']} | {r['wins']} / {r['losses']} | "
                     f"{100 * r['delta']:+.1f} pp | [{100 * r['bootstrap95'][0]:+.1f}, {100 * r['bootstrap95'][1]:+.1f}] pp | "
                     f"{r['exactMcNemarPUnadjusted']:.3f} | {r['excludedForErrors']} |")
    for r in results:
        lines += ["", f"## {r['budget']} tokens by category", "", "| Category | n | A | B | Wins / losses |",
                  "| --- | ---: | ---: | ---: | ---: |"]
        for category, g in r["byCategory"].items():
            lines.append(f"| {category} | {g['n']} | {g['aCorrect']} | {g['bCorrect']} | {g['wins']} / {g['losses']} |")
    text = "\n".join(lines) + "\n"
    if args.output:
        write_json(args.output.with_suffix(".json"), {"a": str(args.a), "b": str(args.b), "results": results})
        args.output.with_suffix(".md").write_text(text)
    print(text)
    return 0


# ---------------------------------------------------------------------------
# build


def cmd_build(args: argparse.Namespace) -> int:
    command = ["zig", "build", f"-Denable-lattice={'true' if args.lattice else 'false'}",
               f"-Doptimize={args.optimize}", "-p", str(args.out)]
    if args.lattice_include:
        command.append(f"-Dlattice-include={args.lattice_include}")
    if args.lattice_lib:
        command.append(f"-Dlattice-lib={args.lattice_lib}")
    env = {**os.environ, "ZIG_GLOBAL_CACHE_DIR": os.environ.get("ZIG_GLOBAL_CACHE_DIR", "/tmp/quipu-zig-cache")}
    subprocess.run(command, cwd=str(args.core_dir), check=True, env=env)
    binary = args.out / "bin" / "quipu"
    info = {"coreGit": git_identity(args.core_dir), "command": command, "lattice": args.lattice,
            "optimize": args.optimize, "binarySha256": sha256_file(binary),
            "builtAt": datetime.now(timezone.utc).isoformat()}
    write_json(args.out / "build-info.json", info)
    print(json.dumps({"binary": str(binary), **info}, indent=2))
    return 0


def parse_answer_options(pairs: list[str] | None) -> dict[str, Any]:
    """Parse repeatable ``KEY=JSON`` flags into memory.answer options."""
    options: dict[str, Any] = {}
    for pair in pairs or []:
        key, sep, raw = pair.partition("=")
        if not sep or not key:
            raise SystemExit(f"--answer-option expects KEY=JSON, got {pair!r}")
        try:
            options[key] = json.loads(raw)
        except json.JSONDecodeError:
            options[key] = raw
    return options


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    select = sub.add_parser("select", help="freeze the dev slice (question IDs only)")
    select.add_argument("--dataset", type=Path, default=DEFAULT_DATASET)
    select.add_argument("--e1-selection", type=Path, default=DEFAULT_E1_SELECTION)
    select.add_argument("--seed", default=SEED)
    select.add_argument("--per-category", type=int, default=10)
    select.add_argument("--output", type=Path, default=DEFAULT_SELECTION)
    select.set_defaults(func=cmd_select)

    build = sub.add_parser("build", help="build a daemon binary into a prefix (writes build-info.json)")
    build.add_argument("--core-dir", type=Path, default=ROOT / "core")
    build.add_argument("--out", type=Path, required=True)
    build.add_argument("--lattice", action="store_true")
    build.add_argument("--lattice-include")
    build.add_argument("--lattice-lib")
    build.add_argument("--optimize", default="ReleaseSafe", choices=["Debug", "ReleaseSafe", "ReleaseFast", "ReleaseSmall"])
    build.set_defaults(func=cmd_build)

    run = sub.add_parser("run", help="run the daemon on the selection")
    run.add_argument("--daemon-binary", required=True)
    run.add_argument("--run-name", required=True)
    run.add_argument("--selection", type=Path, default=DEFAULT_SELECTION)
    run.add_argument("--budgets", type=lambda value: [int(v) for v in value.split(",")], default=[1024, 4096])
    run.add_argument("--reader-model", default=READER_MODEL)
    run.add_argument("--workers", type=int, default=8)
    run.add_argument("--lattice", action="store_true", help="binary is a Lattice build; use a fresh --db per question")
    run.add_argument("--db-dir", type=Path, help="keep per-question Lattice DBs here (default: temp dirs)")
    run.add_argument("--embedding-provider-via-proxy", action="store_true",
                     help="configure the daemon's OpenRouter embedding provider through the proxy")
    run.add_argument("--embedding-model", default=EMBED_MODEL)
    run.add_argument("--vector-dimensions", type=int)
    run.add_argument("--no-extract", action="store_true", help="remember with extract=false (default: daemon default true)")
    run.add_argument("--needs", nargs="+", help="memory.answer needs (default: omitted)")
    run.add_argument("--mode", choices=["fts", "vector", "hybrid", "graph"], help="memory.answer mode (default: omitted)")
    run.add_argument("--daemon-arg", action="append", help="extra daemon CLI argument (repeatable)")
    run.add_argument("--answer-option", action="append", metavar="KEY=JSON",
                     help="extra memory.answer option, value parsed as JSON (repeatable)")
    run.add_argument("--reranker-url", help="Cohere-compatible rerank endpoint for the daemon, "
                     "e.g. http://127.0.0.1:7341/v1/rerank (see quipu_evals.rerank_server)")
    run.add_argument("--reranker-model", help="model sent to the reranker (default: the rerank_server's model)")
    run.add_argument("--questions", nargs="+", help="subset of selected question IDs")
    run.add_argument("--limit", type=int)
    run.add_argument("--fresh", action="store_true", help="ignore matching per-question results")
    run.add_argument("--artifacts", type=Path, default=DEFAULT_ARTIFACTS / "sota")
    run.add_argument("--dataset", type=Path, default=DEFAULT_DATASET)
    run.add_argument("--upstream", type=Path, default=DEFAULT_UPSTREAM)
    run.add_argument("--proxy-cache", type=Path, default=DEFAULT_ARTIFACTS / "sota/cache/proxy")
    run.add_argument("--judge-cache", type=Path, default=DEFAULT_ARTIFACTS / "sota/cache/study")
    run.add_argument("--max-spend-usd", type=float, default=5.0, help="proxy refuses new upstream calls past this")
    run.add_argument("--offline", action="store_true", help="proxy serves cache hits only")
    run.add_argument("--remember-timeout", type=float, default=300)
    run.add_argument("--answer-timeout", type=float, default=600)
    run.set_defaults(func=cmd_run)

    summarize = sub.add_parser("summarize-e1", help="render an E1 study report in this harness's tables")
    summarize.add_argument("--report", type=Path, required=True)
    summarize.add_argument("--arm", default="raw")
    summarize.add_argument("--output", type=Path)
    summarize.set_defaults(func=cmd_summarize_e1)

    compare = sub.add_parser("compare", help="paired comparison of two runs (B versus A)")
    compare.add_argument("--a", type=Path, required=True, help="report.json (daemon run or E1 study report)")
    compare.add_argument("--b", type=Path, required=True)
    compare.add_argument("--arm-a", default="raw", help="arm to use when A is an E1 study report")
    compare.add_argument("--arm-b", default="raw")
    compare.add_argument("--repeats", type=int, default=10000)
    compare.add_argument("--output", type=Path, help="write <output>.json and <output>.md")
    compare.set_defaults(func=cmd_compare)

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
