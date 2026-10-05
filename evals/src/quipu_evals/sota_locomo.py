"""LoCoMo harness for the Quipu daemon (SOTA sprint).

Subcommands:

- ``download``: fetch ``locomo10.json`` and the locomo-audit ``errors.json`` at
  pinned commits, verify their SHA256, and write ``provenance.json``.
- ``run``: one daemon and fresh store per conversation. Each session is one
  ``memory.remember``; every question goes through ``memory.answer`` and is
  graded by the Mem0 LoCoMo judge. JSON + Markdown report.

The daemon owns retrieval and answering. This harness replays the public
LoCoMo sessions, asks the questions, and grades the returned answers. The
daemon client, caching proxy, coverage mapping and summary statistics are
shared with ``sota_longmemeval``.
"""
from __future__ import annotations

import argparse
from collections import Counter
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timedelta, timezone
import json
import os
from pathlib import Path
import queue
import re
import shutil
import sys
import tempfile
import threading
import time
from typing import Any, Callable, Iterable, Mapping, Sequence
import urllib.error
import urllib.request

from .locomo import _parse_locomo_datetime
from .representation_experiment import digest, write_json
from .sota_longmemeval import (
    DEFAULT_ARTIFACTS, EMBED_MODEL, READER_MODEL, ROOT, TOKENIZER, Daemon, DaemonError, coverage, daemon_command,
    daemon_env, fmt, git_identity, item_turns, linked_message_qids, mean, parse_answer_options, percentile,
    reader_context, sha256_file, summarize_calls, summarize_rows, tokenizer_counter,
)

# ---------------------------------------------------------------------------
# Pinned sources

LOCOMO_COMMIT = "3eb6f2c585f5e1699204e3c3bdf7adc5c28cb376"
LOCOMO_URL = f"https://raw.githubusercontent.com/snap-research/locomo/{LOCOMO_COMMIT}/data/locomo10.json"
LOCOMO_SHA256 = "79fa87e90f04081343b8c8debecb80a9a6842b76a7aa537dc9fdf651ea698ff4"
AUDIT_COMMIT = "9493fb4b4af4256ed17a18e8fd0b3cfdeec29539"
AUDIT_ERRORS_URL = f"https://raw.githubusercontent.com/dial481/locomo-audit/{AUDIT_COMMIT}/errors.json"
AUDIT_ERRORS_SHA256 = "f298ef46263fada20688a1d672be37d4f488c6da3b19343eea55ae5c1b5fe55e"
DEFAULT_DIR = DEFAULT_ARTIFACTS / "benchmarks/locomo"
DEFAULT_DATASET = DEFAULT_DIR / "locomo10.json"
DEFAULT_AUDIT = DEFAULT_DIR / "locomo-audit-errors.json"

# JSON ``category`` ids, per the official evaluation code and the locomo-audit
# "Note on Category ID Mapping" (the paper's prose enumeration differs).
CATEGORY_NAMES = {1: "multi-hop", 2: "temporal", 3: "open-domain", 4: "single-hop", 5: "adversarial"}
HEADLINE_CATEGORIES = (1, 2, 3, 4)
ADVERSARIAL = 5
# Category 5 asks about things never said (often about the other speaker). The
# original LoCoMo evaluation scores it as correct when the answer says the
# information is not mentioned; the judge sees that statement as the gold.
ADVERSARIAL_GOLD = "Not mentioned in the conversation"
# validAt is set this long after the last message of the last session.
QUESTION_DELAY = timedelta(minutes=1)
SPEAKER_MODES = ("role", "prefix")

# The LLM judge from the Mem0 paper's LoCoMo evaluation, verbatim (including
# its curly quotes and trailing spaces), at mem0ai/mem0@aae5989
# evaluation/metrics/llm_judge.py. Mem0 sends it as one user message with
# temperature 0 and a JSON response format, then reads ``label``.
JUDGE_MODEL = "openai/gpt-4o-mini-2024-07-18"
JUDGE_SOURCE = "mem0ai/mem0@aae5989e78a6188b3b047c104d960c9ad0927e75 evaluation/metrics/llm_judge.py ACCURACY_PROMPT"
ACCURACY_PROMPT = "\n".join((
    "",
    "Your task is to label an answer to a question as ’CORRECT’ or ’WRONG’. "
    "You will be given the following data:",
    "    (1) a question (posed by one user to another user), ",
    "    (2) a ’gold’ (ground truth) answer, ",
    "    (3) a generated answer",
    "which you will score as CORRECT/WRONG.",
    "",
    "The point of the question is to ask about something one user should know about the other user based on "
    "their prior conversations.",
    "The gold answer will usually be a concise and short answer that includes the referenced topic, for example:",
    "Question: Do you remember what I got the last time I went to Hawaii?",
    "Gold answer: A shell necklace",
    "The generated answer might be much longer, but you should be generous with your grading - as long as it "
    "touches on the same topic as the gold answer, it should be counted as CORRECT. ",
    "",
    "For time related questions, the gold answer will be a specific date, month, year, etc. The generated answer "
    "might be much longer or use relative time references (like \"last Tuesday\" or \"next month\"), but you should "
    "be generous with your grading - as long as it refers to the same date or time period as the gold answer, it "
    "should be counted as CORRECT. Even if the format differs (e.g., \"May 7th\" vs \"7 May\"), consider it CORRECT "
    "if it's the same date.",
    "",
    "Now it's time for the real question:",
    "Question: {question}",
    "Gold answer: {gold_answer}",
    "Generated answer: {generated_answer}",
    "",
    "First, provide a short (one sentence) explanation of your reasoning, then finish with CORRECT or WRONG. ",
    "Do NOT include both CORRECT and WRONG in your response, or it will break the evaluation script.",
    "",
    "Just return the label CORRECT or WRONG in a json format with the key as \"label\".",
    "",
))
# sha256 of the upstream ACCURACY_PROMPT string; a unit test pins ACCURACY_PROMPT to it.
ACCURACY_PROMPT_SHA256 = "62395dd312a631dfd9355026a0b69cc936018274c3198b6365b5c2a5c9bca9e0"


# ---------------------------------------------------------------------------
# Conversations: sessions -> memory.remember calls

_SESSION_KEY = re.compile(r"^session_(\d+)$")
_EVIDENCE_ID = re.compile(r"D:?(\d+):(\d+)")


def iso(value: datetime) -> str:
    return value.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def parse_iso(value: str) -> datetime:
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def session_numbers(conversation: Mapping[str, Any]) -> list[int]:
    """Sessions that have turns. Some samples carry date-times for sessions that do not exist."""
    numbers = []
    for key, value in conversation.items():
        match = _SESSION_KEY.match(str(key))
        if match and isinstance(value, list):
            numbers.append(int(match.group(1)))
    return sorted(numbers)


def turn_message(turn: Mapping[str, Any], *, speaker_mode: str = "role", captions: bool = True) -> dict[str, str] | None:
    """One LoCoMo turn as a daemon message; None when it has no text and no caption.

    The speaker's name is the message role (``role`` mode), so the daemon
    renders ``[qid] Caroline: ...``. Neither speaker is ever ``assistant``.
    ``prefix`` mode is a diagnostic: role ``user`` and ``Caroline: ...`` content.
    An image's BLIP caption is appended as ``[shares image: caption]``; the
    crawler ``query`` field is annotator metadata and is never used.
    """
    if speaker_mode not in SPEAKER_MODES:
        raise ValueError(f"speaker_mode must be one of {SPEAKER_MODES}")
    speaker = str(turn.get("speaker") or "").strip() or "unknown"
    text = str(turn.get("text") or "").strip()
    caption = str(turn.get("blip_caption") or "").strip() if captions else ""
    parts = [text] if text else []
    if caption:
        parts.append(f"[shares image: {caption}]")
    if not parts:
        return None
    content = " ".join(parts)
    if speaker_mode == "prefix":
        return {"role": "user", "content": f"{speaker}: {content}"}
    return {"role": speaker, "content": content}


def build_conversation(sample: Mapping[str, Any], index: int, *, speaker_mode: str = "role",
                       captions: bool = True) -> dict[str, Any]:
    """Daemon-ready sessions for one LoCoMo sample.

    Sessions run in date order (ties by number) as ``s01``, ``s02``… after
    their LoCoMo number. Every message carries its session's date-time plus
    its turn position in seconds, so order survives. ``diaToTurn`` maps each
    LoCoMo ``dia_id`` to (session, message index) for evidence coverage.
    """
    conversation = sample["conversation"]
    sample_id = str(sample.get("sample_id") or f"conv-{index}")
    numbers = session_numbers(conversation)
    times = {}
    for number in numbers:
        raw = conversation.get(f"session_{number}_date_time")
        if not isinstance(raw, str):
            raise ValueError(f"{sample_id} session_{number} has no date_time")
        times[number] = _parse_locomo_datetime(raw)
    sessions, dia_to_turn, dropped = [], {}, []
    for number in sorted(numbers, key=lambda n: (times[n], n)):
        session_id = f"s{number:02d}"
        messages = []
        for position, turn in enumerate(conversation[f"session_{number}"]):
            if not isinstance(turn, Mapping):
                continue
            dia_id = str(turn.get("dia_id") or f"D{number}:{position + 1}")
            message = turn_message(turn, speaker_mode=speaker_mode, captions=captions)
            if message is None:
                dropped.append(dia_id)
                continue
            dia_to_turn[dia_id] = [session_id, len(messages)]
            messages.append({**message, "createdAt": iso(times[number] + timedelta(seconds=position))})
        if messages:
            sessions.append({"sessionId": session_id, "sessionNumber": number, "time": iso(times[number]),
                             "dateTime": conversation[f"session_{number}_date_time"], "messages": messages})
    if not sessions:
        raise ValueError(f"{sample_id} has no messages")
    last = max(parse_iso(message["createdAt"]) for session in sessions for message in session["messages"])
    return {
        "sampleId": sample_id, "conversationIndex": index,
        "speakers": [conversation.get("speaker_a"), conversation.get("speaker_b")],
        "scope": {"tenantId": "sota-locomo", "projectId": f"locomo-{sample_id}"},
        "sessions": sessions, "diaToTurn": dia_to_turn, "droppedTurns": dropped,
        "questionTime": iso(last + QUESTION_DELAY),
        "messageCount": sum(len(session["messages"]) for session in sessions),
    }


# ---------------------------------------------------------------------------
# Questions, evidence and the audit key


def parse_evidence(values: Iterable[Any] | None) -> tuple[list[str], list[str]]:
    """Normalize LoCoMo evidence strings to ``D<session>:<turn>`` ids.

    A few entries pack several ids into one string (``"D8:6; D9:17"``) or are
    malformed (``"D:11:26"``); both are recovered. Strings with no id at all
    are returned separately as unparseable.
    """
    ids: list[str] = []
    unparseable: list[str] = []
    for value in values or []:
        found = _EVIDENCE_ID.findall(str(value))
        if not found:
            unparseable.append(str(value))
        for session, turn in found:
            dia_id = f"D{int(session)}:{int(turn)}"
            if dia_id not in ids:
                ids.append(dia_id)
    return ids, unparseable


def resolve_evidence(dia_ids: Iterable[str], dia_to_turn: Mapping[str, Sequence[Any]]) -> tuple[list[list[Any]], list[str]]:
    """(session, message index) for each dia id; ids with no remembered message are returned apart."""
    turns, unresolved = [], []
    for dia_id in dia_ids:
        if dia_id in dia_to_turn:
            session, index = dia_to_turn[dia_id]
            turns.append([session, int(index)])
        else:
            unresolved.append(dia_id)
    return turns, unresolved


def load_audit(path: Path) -> dict[str, dict[str, Any]]:
    """locomo-audit ``errors.json`` keyed by its question id (``locomo_<conv>_qa<index>``, 0-based).

    Only score-corrupting entries (every type except ``WRONG_CITATION``)
    change the answer; every entry's ``correct_evidence`` is the audited
    evidence for that question.
    """
    entries = json.loads(Path(path).read_text())
    if not isinstance(entries, list):
        raise ValueError("audit errors file must be a list")
    audit = {}
    for entry in entries:
        corrupting = entry.get("error_type") != "WRONG_CITATION"
        audit[str(entry["question_id"])] = {
            "errorType": entry.get("error_type"),
            "question": entry.get("question"),
            "goldenAnswer": entry.get("golden_answer"),
            "answer": str(entry["correct_answer"]) if corrupting else None,
            "evidence": [str(value) for value in entry.get("correct_evidence") or []],
        }
    return audit


def question_id(conversation_index: int, qa_index: int) -> str:
    """The locomo-audit id scheme, so rows join to the audit's errors without a lookup table."""
    return f"locomo_{conversation_index}_qa{qa_index}"


def build_questions(sample: Mapping[str, Any], conversation: Mapping[str, Any], *,
                    audit: Mapping[str, Mapping[str, Any]] | None = None,
                    categories: Iterable[int] | None = None, limit: int | None = None) -> list[dict[str, Any]]:
    """Questions of one conversation in dataset order, filtered by category then limited."""
    allowed = set(categories) if categories else set(CATEGORY_NAMES)
    questions = []
    for qa_index, qa in enumerate(sample.get("qa") or []):
        category = int(qa.get("category") or 0)
        if category not in allowed:
            continue
        qid = question_id(conversation["conversationIndex"], qa_index)
        adversarial = category == ADVERSARIAL
        if adversarial:
            reference = ADVERSARIAL_GOLD
        elif qa.get("answer") is None:
            raise ValueError(f"{qid} (category {category}) has no answer")
        else:
            reference = str(qa["answer"])
        evidence, unparseable = parse_evidence(qa.get("evidence"))
        gold_turns, unresolved = resolve_evidence(evidence, conversation["diaToTurn"])
        entry = (audit or {}).get(qid)
        if entry is not None and entry.get("question") not in (None, qa.get("question")):
            raise ValueError(f"audit entry {qid} does not match the dataset question")
        audit_evidence = parse_evidence(entry["evidence"])[0] if entry else evidence
        audit_turns, _ = resolve_evidence(audit_evidence, conversation["diaToTurn"])
        questions.append({
            "questionId": qid, "sampleId": conversation["sampleId"],
            "conversationIndex": conversation["conversationIndex"], "qaIndex": qa_index,
            "category": category, "categoryName": CATEGORY_NAMES.get(category, f"category-{category}"),
            "question": str(qa.get("question") or ""), "reference": reference,
            "officialAnswer": qa.get("answer"), "adversarialAnswer": qa.get("adversarial_answer"),
            "auditReference": entry["answer"] if entry and entry.get("answer") is not None and not adversarial else None,
            "auditErrorType": entry.get("errorType") if entry else None,
            "evidence": evidence, "unparseableEvidence": unparseable, "unresolvedEvidence": unresolved,
            "goldTurns": gold_turns, "auditGoldTurns": audit_turns,
        })
        if limit is not None and len(questions) >= limit:
            break
    return questions


def evidence_coverage(gold_turns: Sequence[Sequence[Any]], turns: set[tuple[str, int]]) -> dict[str, Any]:
    """Gold-turn/session coverage of the reader context; all None without resolvable evidence."""
    sessions = sorted({str(session) for session, _ in gold_turns})
    return coverage({"goldTurns": gold_turns, "evidenceSessions": sessions, "abstention": not gold_turns}, turns)


# ---------------------------------------------------------------------------
# Judge


def judge_request(question: str, gold: str, generated: str, *, model: str = JUDGE_MODEL) -> dict[str, Any]:
    """Mem0's judge call: one user message, temperature 0, JSON response format."""
    content = ACCURACY_PROMPT.format(question=question, gold_answer=gold, generated_answer=generated)
    return {"model": model, "messages": [{"role": "user", "content": content}],
            "response_format": {"type": "json_object"}, "temperature": 0.0}


def parse_judge_label(text: str) -> str:
    """``CORRECT`` or ``WRONG`` from the judge's JSON (code fences tolerated, as Mem0's extract_json does)."""
    stripped = text.strip()
    fenced = re.search(r"```(?:json)?\s*(.*?)\s*```", stripped, re.DOTALL)
    candidate = fenced.group(1) if fenced else stripped
    try:
        payload = json.loads(candidate)
    except ValueError:
        payload = None
    label = payload.get("label") if isinstance(payload, Mapping) else None
    if label is None:
        match = re.search(r'"label"\s*:\s*"([A-Za-z]+)"', stripped)
        label = match.group(1) if match else stripped
    if isinstance(label, str) and label.strip().upper() in ("CORRECT", "WRONG"):
        return label.strip().upper()
    raise ValueError(f"unparseable judge response: {text[:200]!r}")


Poster = Callable[[str, Mapping[str, Any]], Mapping[str, Any]]


def judge_answer(post: Poster, tag: str, question: str, gold: str, generated: str, *,
                 model: str = JUDGE_MODEL) -> dict[str, Any]:
    response = post(tag, judge_request(question, gold, generated, model=model))
    text = str(response["choices"][0]["message"]["content"])
    label = parse_judge_label(text)
    return {"correct": label == "CORRECT", "label": label, "gold": gold, "response": text,
            "responseModel": response.get("model")}


def proxy_poster(proxy: Any, timeout: float = 180.0) -> Poster:
    """POST a chat completion through the caching proxy (it injects the key, caches and enforces the cap)."""
    def post(tag: str, body: Mapping[str, Any]) -> Mapping[str, Any]:
        request = urllib.request.Request(proxy.url(tag, "chat/completions"), data=json.dumps(body).encode(),
                                         method="POST", headers={"Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                return json.loads(response.read())
        except urllib.error.HTTPError as exc:
            raise RuntimeError(f"judge request failed: {exc.code} {exc.read()[:300]!r}") from exc
    return post


# ---------------------------------------------------------------------------
# Per-question answering


def answer_params(question: Mapping[str, Any], conversation: Mapping[str, Any], config: Mapping[str, Any],
                  budget: int) -> dict[str, Any]:
    """memory.answer request. Retrieval logging is off so answers never write to the shared store."""
    params: dict[str, Any] = {
        "query": question["question"], "scope": conversation["scope"],
        "time": {"validAt": conversation["questionTime"]}, "budgetTokens": budget,
        "options": {"logRetrieval": False, **(config.get("answerOptions") or {}),
                    "includeDebug": True, "includeEvidence": True},
    }
    if config.get("needs"):
        params["needs"] = config["needs"]
    if config.get("mode"):
        params["mode"] = config["mode"]
    return params


def error_row(question: Mapping[str, Any], budget: int, stage: str, error: str, **extra: Any) -> dict[str, Any]:
    return {"questionId": question["questionId"], "sampleId": question["sampleId"],
            "category": question["category"], "categoryName": question["categoryName"], "budget": budget,
            "status": "error", "errorStage": stage, "error": error[:1000], "correct": None, "correctAudit": None,
            **extra}


def question_record(question: Mapping[str, Any]) -> dict[str, Any]:
    return {**question, "rows": [], "status": "ok"}


def answer_question(daemon: Any, tag: str, question: Mapping[str, Any], conversation: Mapping[str, Any],
                    qid_to_turn: Mapping[str, Sequence[Any]], config: Mapping[str, Any], proxy: Any,
                    post: Poster, count: Callable[[str], int]) -> dict[str, Any]:
    record = question_record(question)
    qid = question["questionId"]
    budgets = config["budgets"]
    for position, budget in enumerate(budgets):
        mark = proxy.state.mark()
        started = time.perf_counter()
        try:
            result = daemon.call("memory.answer", answer_params(question, conversation, config, budget),
                                 timeout=config["answerTimeout"])
        except DaemonError as exc:
            record["rows"].append(error_row(question, budget, "answer", str(exc),
                                            answerLatencyMs=(time.perf_counter() - started) * 1000,
                                            calls=summarize_calls(proxy.state.records_for(tag, mark))))
            if daemon.process.poll() is not None:
                record["rows"] += [error_row(question, b, "answer", f"daemon exited: {exc}") for b in budgets[position + 1:]]
                break
            continue
        latency = (time.perf_counter() - started) * 1000
        calls = summarize_calls(proxy.state.records_for(tag, mark))
        context, source = reader_context(result)
        items = [item for item in result.get("items") or [] if isinstance(item, Mapping)]
        turns = item_turns(items, qid_to_turn)
        answer_text = str(result.get("answer") or "")
        trace = result.get("answerTrace") if isinstance(result.get("answerTrace"), Mapping) else {}
        row: dict[str, Any] = {
            "questionId": qid, "sampleId": question["sampleId"], "category": question["category"],
            "categoryName": question["categoryName"], "budget": budget, "status": "ok", "answer": answer_text,
            "answerLatencyMs": latency, "calls": calls, "llmAnswered": calls["chatCalls"] > 0,
            "strategy": trace.get("strategy"), "answerable": trace.get("answerable"),
            "supportValid": trace.get("supportValid"),
            "contextSource": source, "contextTokens": count(context), "contextChars": len(context),
            "readerPromptTokens": calls["readerPromptTokens"] or None,
            "items": len(items), "itemTypes": dict(Counter(str(item.get("type")) for item in items)),
            "unmappedItems": sum(1 for item in items if not any(q in qid_to_turn for q in linked_message_qids(item))),
            **evidence_coverage(question["goldTurns"], turns),
            "auditEvidence": evidence_coverage(question["auditGoldTurns"], turns),
            "rawOnly": evidence_coverage(question["goldTurns"], item_turns(items, qid_to_turn, raw_only=True)),
            "warnings": result.get("warnings"), "tokenEstimate": result.get("tokenEstimate"),
            "context": context,
            "itemRefs": [{"qid": item.get("qid"), "type": item.get("type"), "score": item.get("score"),
                          "turns": sorted(item_turns([item], qid_to_turn))} for item in items],
            "answerTrace": trace,
        }
        judge_tag = f"{qid}.b{budget}.judge"
        audit_tag = f"{judge_tag}.audit"
        mark = proxy.state.mark()
        try:
            judgment = judge_answer(post, judge_tag, question["question"], question["reference"], answer_text,
                                    model=config["judgeModel"])
            row.update(judgment=judgment, correct=judgment["correct"], correctAudit=judgment["correct"])
            if question.get("auditReference") is not None:
                audit_judgment = judge_answer(post, audit_tag, question["question"], question["auditReference"],
                                              answer_text, model=config["judgeModel"])
                row.update(judgmentAudit=audit_judgment, correctAudit=audit_judgment["correct"])
        except Exception as exc:  # Judge failures are errors, never wrong answers.
            row.update(status="error", errorStage="judge", error=str(exc)[:1000], correct=None, correctAudit=None)
        judge_calls = summarize_calls(proxy.state.records_for(judge_tag, mark) + proxy.state.records_for(audit_tag, mark))
        row.update(judgeCalls=judge_calls["chatCalls"], judgeCostUsd=judge_calls["costUsd"],
                   judgeNominalCostUsd=judge_calls["nominalCostUsd"])
        record["rows"].append(row)
    if any(row["status"] != "ok" for row in record["rows"]):
        record["status"] = "error"
    return record


# ---------------------------------------------------------------------------
# Per-conversation run: ingest once, answer from one or more daemons


def start_daemon(config: Mapping[str, Any], proxy: Any, tag: str, db_path: Path | None, home: Path,
                 stderr_path: Path) -> tuple[Any, list[str]]:
    command = daemon_command(
        config, answer_url=proxy.url(tag, "chat/completions"),
        embedding_url=proxy.url(tag, "embeddings") if config["embeddingViaProxy"] else None, db_path=db_path)
    redacted = [part.replace(proxy.base_url, "<proxy>") for part in command]
    return Daemon(command, env=daemon_env(home), cwd=home, stderr_path=stderr_path), redacted


def ingest_conversation(daemon: Any, conversation: Mapping[str, Any], config: Mapping[str, Any], proxy: Any,
                        tag: str) -> tuple[dict[str, Any], dict[str, tuple[str, int]]]:
    """One memory.remember per session, in date order."""
    qid_to_turn: dict[str, tuple[str, int]] = {}
    mark = proxy.state.mark()
    started = time.perf_counter()
    warnings, latencies = [], []
    for session in conversation["sessions"]:
        call_started = time.perf_counter()
        result = daemon.call("memory.remember", {
            "scope": conversation["scope"], "sessionId": session["sessionId"],
            "messages": session["messages"], "extract": config["extract"],
        }, timeout=config["rememberTimeout"])
        latencies.append((time.perf_counter() - call_started) * 1000)
        message_qids = list(result.get("messageQids") or [])
        if len(message_qids) != len(session["messages"]):
            warnings.append(f"{session['sessionId']}: {len(message_qids)} qids for "
                            f"{len(session['messages'])} messages ({result.get('status')})")
        for index, qid in enumerate(message_qids):
            qid_to_turn[qid] = (session["sessionId"], index)
    ingest = {
        "seconds": time.perf_counter() - started, "sessions": len(conversation["sessions"]),
        "messages": conversation["messageCount"], "messageQids": len(qid_to_turn), "warnings": warnings,
        "rememberMsP50": percentile(latencies, .5), "rememberMsP95": percentile(latencies, .95),
        "calls": summarize_calls(proxy.state.records_for(tag, mark)),
    }
    return ingest, qid_to_turn


def reusable(path: Path, config_hash: str) -> dict[str, Any] | None:
    if not path.exists():
        return None
    previous = json.loads(path.read_text())
    return previous if previous.get("configHash") == config_hash and previous.get("status") == "ok" else None


def run_conversation(conversation: Mapping[str, Any], questions: Sequence[Mapping[str, Any]],
                     config: Mapping[str, Any], proxy: Any, post: Poster, count: Callable[[str], int],
                     run_dir: Path, config_hash: str, *, fresh: bool = False, replicas: int = 1,
                     on_done: Callable[[Mapping[str, Any]], None] = lambda record: None) -> dict[str, Any]:
    """Ingest the conversation into a fresh store, then answer every question.

    ``memory.answer`` runs with retrieval logging off, so it does not change
    the store. With Lattice, the ingest daemon is closed and ``replicas``
    daemons answer in parallel, each over its own copy of the ingested store
    (``serve-stdio`` handles one request at a time). The in-memory build cannot
    reopen its store, so it answers on the ingest daemon.
    """
    sample = conversation["sampleId"]
    case_dir = run_dir / "cases" / sample
    conversation_path = run_dir / "conversations" / f"{sample}.json"
    records: list[dict[str, Any]] = []
    todo = []
    for question in questions:
        previous = None if fresh else reusable(case_dir / f"{question['questionId']}.json", config_hash)
        if previous is not None:
            records.append(previous)
        else:
            todo.append(question)
    summary: dict[str, Any] = {"sampleId": sample, "reused": len(records), "questions": records}
    if not todo:
        previous = None if fresh else reusable(conversation_path, config_hash)
        summary["ingest"] = previous.get("ingest") if previous else None
        return summary
    lock = threading.Lock()

    def finish(record: dict[str, Any]) -> None:
        record["configHash"] = config_hash
        write_json(case_dir / f"{record['questionId']}.json", record)
        with lock:
            records.append(record)
        on_done(record)

    def fail_all(pending: Iterable[Mapping[str, Any]], stage: str, error: str) -> None:
        for question in pending:
            record = question_record(question)
            record["status"] = "error"
            record["rows"] = [error_row(question, budget, stage, error) for budget in config["budgets"]]
            finish(record)

    logs = run_dir / "logs"
    with tempfile.TemporaryDirectory(prefix="quipu-locomo-") as temporary:
        root = Path(temporary)
        home = root / "home"
        home.mkdir()
        db_path = None
        if config["lattice"]:
            base = Path(config["dbDir"]) / sample if config.get("dbDir") else root / "db"
            if base.exists():
                shutil.rmtree(base)
            base.mkdir(parents=True)
            db_path = base / "conversation.lattice"
        tag = f"{sample}.ingest"
        daemon, command = start_daemon(config, proxy, tag, db_path, home, logs / f"{sample}.ingest.stderr")
        summary["daemonCommand"] = command
        answerers: list[tuple[Any, str]] = []
        try:
            try:
                ingest, qid_to_turn = ingest_conversation(daemon, conversation, config, proxy, tag)
            except (DaemonError, ValueError) as exc:
                summary["ingest"] = {"error": str(exc)[:1000]}
                fail_all(todo, "ingest", str(exc))
                return summary
            summary["ingest"] = ingest
            write_json(conversation_path, {"configHash": config_hash, "status": "ok", "sampleId": sample,
                                           "ingest": ingest, "daemonCommand": command,
                                           "qidToTurn": {qid: list(turn) for qid, turn in qid_to_turn.items()},
                                           "diaToTurn": conversation["diaToTurn"]})
            if db_path is None:
                answerers = [(daemon, tag)]
            else:
                daemon.close()
                count_replicas = max(1, min(replicas, len(todo)))
                paths = [db_path]
                for index in range(1, count_replicas):
                    copy = root / f"replica-{index}"
                    shutil.copytree(db_path.parent, copy)
                    paths.append(copy / db_path.name)
                for index, path in enumerate(paths):
                    replica_tag = f"{sample}.r{index}"
                    replica, _ = start_daemon(config, proxy, replica_tag, path, home,
                                              logs / f"{sample}.r{index}.stderr")
                    answerers.append((replica, replica_tag))
            work: queue.Queue[Mapping[str, Any]] = queue.Queue()
            for question in todo:
                work.put(question)

            def worker(answerer: Any, answer_tag: str) -> None:
                while answerer.process.poll() is None:
                    try:
                        question = work.get_nowait()
                    except queue.Empty:
                        return
                    try:
                        record = answer_question(answerer, answer_tag, question, conversation, qid_to_turn,
                                                 config, proxy, post, count)
                    except Exception as exc:  # Harness bug: record and continue.
                        record = question_record(question)
                        record["status"] = "error"
                        record["rows"] = [error_row(question, budget, "harness", f"{type(exc).__name__}: {exc}")
                                          for budget in config["budgets"]]
                    finish(record)

            threads = [threading.Thread(target=worker, args=pair, daemon=True) for pair in answerers]
            for thread in threads:
                thread.start()
            for thread in threads:
                thread.join()
            leftover = []
            while not work.empty():
                leftover.append(work.get_nowait())
            if leftover:
                fail_all(leftover, "answer", "no live daemon for this conversation")
        finally:
            for answerer, _ in answerers:
                answerer.close()
            if not answerers:
                daemon.close()
    return summary


# ---------------------------------------------------------------------------
# Aggregation and reporting


def with_key(rows: Sequence[Mapping[str, Any]], key: str) -> list[dict[str, Any]]:
    """Rows graded against the ``official`` or ``audit`` answer key."""
    if key == "official":
        return [dict(row) for row in rows]
    return [{**row, "correct": row.get("correctAudit")} for row in rows]


def summarize(rows: Sequence[Mapping[str, Any]]) -> dict[str, Any]:
    ok = [row for row in rows if row.get("status") == "ok"]
    summary = summarize_rows(rows)
    answered = [row for row in ok if row.get("readerPromptTokens")]
    summary.update({
        "goldTurnCoverageAuditEvidence": mean((row.get("auditEvidence") or {}).get("goldTurnCoverage") for row in ok),
        "allGoldTurnsRateAuditEvidence": mean(
            None if (row.get("auditEvidence") or {}).get("allGoldTurns") is None
            else float(row["auditEvidence"]["allGoldTurns"]) for row in ok),
        "notAnswerableRate": mean(float(row.get("answerable") is False) for row in ok) if ok else None,
        "readerPromptTokensMean": mean(row.get("readerPromptTokens") for row in answered),
        "contextTokensP95": percentile((row.get("contextTokens") for row in ok), .95),
        "answerNominalCostPerQuestionUsd": (summary["answerNominalCostUsd"] / len(rows)) if rows else None,
    })
    return summary


def failure_breakdown(rows: Sequence[Mapping[str, Any]]) -> dict[str, Any]:
    """Wrong answers by evidence coverage of the reader context (official evidence ids)."""
    buckets: Counter[str] = Counter()
    full_not_answerable = 0
    for row in rows:
        if row.get("status") != "ok" or row.get("correct"):
            continue
        if row.get("llmAnswered") is False:
            bucket = "no_llm_call"
        elif row.get("goldTurnCoverage") is None:
            bucket = "no_resolvable_evidence"
        elif row["goldTurnCoverage"] == 0:
            bucket = "retrieval_miss"
        elif row["goldTurnCoverage"] < 1:
            bucket = "partial_retrieval"
        else:
            bucket = "full_coverage_reader_wrong"
            full_not_answerable += row.get("answerable") is False
        buckets[bucket] += 1
    return {"wrongByCause": dict(buckets), "fullCoverageNotAnswerable": full_not_answerable,
            "strategies": dict(Counter(str(row.get("strategy")) for row in rows if row.get("status") == "ok"))}


def aggregate(rows: Sequence[Mapping[str, Any]], budgets: Sequence[int]) -> dict[str, Any]:
    """Categories 1–4 overall and per category under both keys; category 5 on its own."""
    summary: dict[str, Any] = {}
    by_category: dict[str, Any] = {}
    adversarial: dict[str, Any] = {}
    failures: dict[str, Any] = {}
    for budget in budgets:
        group = [row for row in rows if row["budget"] == budget]
        headline = [row for row in group if row["category"] in HEADLINE_CATEGORIES]
        summary[str(budget)] = {key: summarize(with_key(headline, key)) for key in ("official", "audit")}
        by_category[str(budget)] = {
            CATEGORY_NAMES[category]: {key: summarize(with_key([r for r in headline if r["category"] == category], key))
                                       for key in ("official", "audit")}
            for category in HEADLINE_CATEGORIES if any(r["category"] == category for r in headline)}
        flagged = [row for row in headline if row.get("judgmentAudit") is not None]
        summary[str(budget)]["auditCorrectedQuestions"] = {
            "n": len(flagged), "officialCorrect": sum(bool(row.get("correct")) for row in flagged),
            "auditCorrect": sum(bool(row.get("correctAudit")) for row in flagged)}
        cat5 = [row for row in group if row["category"] == ADVERSARIAL]
        if cat5:
            adversarial[str(budget)] = summarize(cat5)
        failures[str(budget)] = failure_breakdown(headline)
    return {"summary": summary, "byCategory": by_category, "adversarial": adversarial, "failures": failures}


def summarize_ingest(conversations: Sequence[Mapping[str, Any]]) -> dict[str, Any]:
    ingests = [c["ingest"] for c in conversations if isinstance(c.get("ingest"), Mapping)]
    ok = [i for i in ingests if "error" not in i]
    calls = [i.get("calls") or {} for i in ok]
    return {
        "conversations": len(conversations), "ingestErrors": len(conversations) - len(ok),
        "secondsMean": mean(i["seconds"] for i in ok), "secondsMax": max((i["seconds"] for i in ok), default=None),
        "messagesTotal": sum(i.get("messages") or 0 for i in ok),
        "rememberMsP50Mean": mean(i.get("rememberMsP50") for i in ok),
        "embeddingCalls": sum(c.get("embeddingCalls", 0) for c in calls),
        "chatCalls": sum(c.get("chatCalls", 0) for c in calls),
        "costUsd": sum(c.get("costUsd", 0.0) for c in calls),
        "nominalCostUsd": sum(c.get("nominalCostUsd", 0.0) for c in calls),
    }


def protocol_note(identity: Mapping[str, Any]) -> str:
    audit = ("an audit-corrected key (dial481/locomo-audit@9493fb4 `errors.json`: the score-corrupting entries' "
             "`correct_answer` replaces the gold) is shown beside it as a sensitivity check only"
             if identity.get("auditSha256") else "the audit-corrected key was not available for this run")
    return (
        "**Protocol.** LoCoMo-10 (`snap-research/locomo@3eb6f2c` `data/locomo10.json`, sha256 "
        f"`{str(identity.get('datasetSha256'))[:12]}…`). Headline accuracy covers categories 1–4 (multi-hop, "
        "temporal, open-domain, single-hop); category 5 (adversarial) is reported separately, judged against "
        f"\"{ADVERSARIAL_GOLD}\". Judge: the Mem0 LoCoMo `ACCURACY_PROMPT` (mem0ai/mem0@aae5989) with "
        f"`{identity.get('judgeModel')}`, temperature 0, one run. Answers are graded against the official key; {audit}. "
        "About 6.4% of the official key is wrong (audit ceiling ≈93.6% on categories 1–4), and this judge is "
        "lenient. Published systems differ in reader, prompts, judge runs and category handling, so these "
        "numbers are not an apples-to-apples leaderboard comparison.")


def markdown(report: Mapping[str, Any]) -> str:
    identity = report["identity"]
    lines = [f"# {report['title']}", "", protocol_note(identity), "", "| Field | Value |", "| --- | --- |"]
    for key, value in identity.items():
        if isinstance(value, (dict, list)):
            value = json.dumps(value, sort_keys=True)
        lines.append(f"| {key} | `{value}` |")
    lines += ["", "## Categories 1–4", "",
              "| Budget | Key | Correct | Accuracy (completed) | Completion | Gold-session cov. | Gold-turn cov. | "
              "All gold turns | Gold-turn cov. (audit evidence) | Context tokens (mean / p95) | Answer p50 / p95 ms | "
              "Not answerable | Answer cost (nominal / question) | Judge cost |",
              "| ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |"]
    for budget, keys in report["summary"].items():
        for key in ("official", "audit"):
            s = keys[key]
            lines.append(
                f"| {budget} | {key} | {s['correct']}/{s['n']} | {fmt(s['accuracy'], 'pct')} | "
                f"{fmt(s['completionRate'], 'pct')} | {fmt(s['goldSessionCoverage'], 'pct')} | "
                f"{fmt(s['goldTurnCoverage'], 'pct')} | {fmt(s['allGoldTurnsRate'], 'pct')} | "
                f"{fmt(s['goldTurnCoverageAuditEvidence'], 'pct')} | {fmt(s['contextTokensMean'])} / "
                f"{fmt(s['contextTokensP95'])} | {fmt(s['answerLatencyMsP50'], 'ms')} / {fmt(s['answerLatencyMsP95'], 'ms')} | "
                f"{fmt(s['notAnswerableRate'], 'pct')} | {fmt(s['answerNominalCostPerQuestionUsd'], 'usd')} | "
                f"{fmt(s['judgeCostUsd'], 'usd')} |")
    flagged = {budget: keys.get("auditCorrectedQuestions") for budget, keys in report["summary"].items()}
    if any(f and f["n"] for f in flagged.values()):
        lines += ["", "Questions whose answer the audit corrects (categories 1–4): "
                  + "; ".join(f"{budget}: {f['officialCorrect']}/{f['n']} official, {f['auditCorrect']}/{f['n']} audit"
                              for budget, f in flagged.items() if f)]
    for budget, categories in report["byCategory"].items():
        lines += ["", f"## By category, {budget} tokens", "",
                  "| Category | n | Correct | Accuracy | Accuracy (audit key) | Errors | Gold-session cov. | "
                  "Gold-turn cov. | All gold turns | Context tokens | Answer p50 ms |",
                  "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |"]
        for name, keys in categories.items():
            s, a = keys["official"], keys["audit"]
            lines.append(f"| {name} | {s['n']} | {s['correct']} | {fmt(s['accuracy'], 'pct')} | {fmt(a['accuracy'], 'pct')} | "
                         f"{s['errors']} | {fmt(s['goldSessionCoverage'], 'pct')} | {fmt(s['goldTurnCoverage'], 'pct')} | "
                         f"{fmt(s['allGoldTurnsRate'], 'pct')} | {fmt(s['contextTokensMean'])} | "
                         f"{fmt(s['answerLatencyMsP50'], 'ms')} |")
    if report.get("adversarial"):
        lines += ["", "## Category 5 (adversarial), reported separately", "",
                  f"Gold is \"{ADVERSARIAL_GOLD}\"; not part of the headline.", "",
                  "| Budget | Correct | Accuracy | Errors | Not answerable | Context tokens | Answer p50 ms |",
                  "| ---: | ---: | ---: | ---: | ---: | ---: | ---: |"]
        for budget, s in report["adversarial"].items():
            lines.append(f"| {budget} | {s['correct']}/{s['n']} | {fmt(s['accuracy'], 'pct')} | {s['errors']} | "
                         f"{fmt(s['notAnswerableRate'], 'pct')} | {fmt(s['contextTokensMean'])} | "
                         f"{fmt(s['answerLatencyMsP50'], 'ms')} |")
    if report.get("failures"):
        lines += ["", "## Wrong-answer attribution, categories 1–4 (official key)", "",
                  "Coverage is a message-level proxy from LoCoMo evidence dialog ids, not semantic sufficiency.", "",
                  "| Budget | Wrong by cause | Full coverage, not answerable | Strategies |", "| ---: | --- | ---: | --- |"]
        for budget, f in report["failures"].items():
            lines.append(f"| {budget} | {json.dumps(f['wrongByCause'], sort_keys=True)} | "
                         f"{f['fullCoverageNotAnswerable']} | {json.dumps(f['strategies'], sort_keys=True)} |")
    if report.get("ingest"):
        i = report["ingest"]
        lines += ["", "## Ingest", "",
                  f"Conversations {i['conversations']}, errors {i['ingestErrors']}, messages {i['messagesTotal']}; "
                  f"seconds mean {fmt(i['secondsMean'])}, max {fmt(i['secondsMax'])}; remember p50 (mean over "
                  f"conversations) {fmt(i['rememberMsP50Mean'], 'ms')} ms; embedding calls {i['embeddingCalls']}, "
                  f"cost {fmt(i['costUsd'], 'usd')} (nominal {fmt(i['nominalCostUsd'], 'usd')})."]
    if report.get("spend"):
        lines += ["", "## Spend", "", "```json", json.dumps(report["spend"], indent=2, sort_keys=True), "```"]
    if report.get("errors"):
        lines += ["", "## Errors", ""] + [
            f"- `{e['questionId']}` @{e['budget']} ({e.get('errorStage')}): {e.get('error', '')[:200]}"
            for e in report["errors"][:100]]
    return "\n".join(lines) + "\n"


# ---------------------------------------------------------------------------
# download


def fetch(url: str, path: Path, expected_sha256: str, *, force: bool = False) -> dict[str, Any]:
    if force or not path.exists():
        path.parent.mkdir(parents=True, exist_ok=True)
        temporary = path.with_suffix(path.suffix + ".part")
        with urllib.request.urlopen(url, timeout=120) as response:
            temporary.write_bytes(response.read())
        temporary.replace(path)
    actual = sha256_file(path)
    return {"path": str(path), "url": url, "sha256": actual, "expectedSha256": expected_sha256,
            "matches": actual == expected_sha256}


def cmd_download(args: argparse.Namespace) -> int:
    entries = {
        "dataset": {**fetch(LOCOMO_URL, args.output_dir / "locomo10.json", LOCOMO_SHA256, force=args.force),
                    "repository": "snap-research/locomo", "commit": LOCOMO_COMMIT, "license": "CC BY-NC 4.0"},
        "audit": {**fetch(AUDIT_ERRORS_URL, args.output_dir / "locomo-audit-errors.json", AUDIT_ERRORS_SHA256,
                          force=args.force),
                  "repository": "dial481/locomo-audit", "commit": AUDIT_COMMIT, "license": "CC BY-NC 4.0"},
    }
    write_json(args.output_dir / "provenance.json", {"downloadedAt": datetime.now(timezone.utc).isoformat(), **entries})
    print(json.dumps(entries, indent=2))
    return 0 if all(entry["matches"] for entry in entries.values()) else 1


# ---------------------------------------------------------------------------
# run


def parse_categories(value: str) -> list[int]:
    categories = sorted({int(part) for part in value.split(",") if part.strip()})
    if not categories or any(category not in CATEGORY_NAMES for category in categories):
        raise argparse.ArgumentTypeError(f"categories must be drawn from {sorted(CATEGORY_NAMES)}")
    return categories


def plan_parallelism(workers: int, conversations: int, replicas: int | None, lattice: bool) -> tuple[int, int]:
    """(conversations in parallel, answering daemons per conversation) for ``workers`` daemons in total."""
    parallel = max(1, min(workers, conversations))
    if not lattice:
        return parallel, 1
    return parallel, max(1, replicas if replicas else workers // parallel)


def cmd_run(args: argparse.Namespace) -> int:
    from .caching_proxy import CachingProxy, ProxyState, summarize_records
    if not os.environ.get("OPENROUTER_API_KEY") and not args.offline:
        print("OPENROUTER_API_KEY is required (or pass --offline to serve cache hits only)", file=sys.stderr)
        return 2
    run_dir = args.artifacts / args.run_name
    run_dir.mkdir(parents=True, exist_ok=True)
    data = json.loads(args.dataset.read_text())
    dataset_sha = sha256_file(args.dataset)
    if dataset_sha != LOCOMO_SHA256:
        print(f"warning: {args.dataset} sha256 {dataset_sha} differs from the pinned {LOCOMO_SHA256}", file=sys.stderr)
    audit, audit_sha = None, None
    if args.audit_errors and args.audit_errors.exists():
        audit, audit_sha = load_audit(args.audit_errors), sha256_file(args.audit_errors)
    else:
        print("warning: no audit errors file; the audit-corrected key equals the official key", file=sys.stderr)
    samples = list(enumerate(data))[:args.limit_conversations] if args.limit_conversations else list(enumerate(data))
    if args.conversations:
        samples = [(i, s) for i, s in samples if s.get("sample_id") in set(args.conversations)]
    plan = []
    for index, sample in samples:
        conversation = build_conversation(sample, index, speaker_mode=args.speaker_mode, captions=not args.no_captions)
        questions = build_questions(sample, conversation, audit=audit, categories=args.categories,
                                    limit=args.limit_questions)
        if args.questions:
            questions = [q for q in questions if q["questionId"] in set(args.questions)]
        if questions:
            plan.append((conversation, questions))
    binary = Path(args.daemon_binary).resolve()
    build_info_path = binary.parent.parent / "build-info.json"
    config = {
        "daemonBinary": str(binary), "lattice": args.lattice,
        "dbDir": str(args.db_dir) if args.db_dir else None,
        "embeddingViaProxy": args.embedding_provider_via_proxy, "embeddingModel": args.embedding_model,
        "vectorDimensions": args.vector_dimensions, "readerModel": args.reader_model, "judgeModel": args.judge_model,
        "budgets": args.budgets, "extract": not args.no_extract, "needs": args.needs, "mode": args.mode,
        "daemonArgs": args.daemon_arg or [], "answerOptions": parse_answer_options(args.answer_option),
        "rerankerUrl": args.reranker_url, "rerankerModel": args.reranker_model,
        "speakerMode": args.speaker_mode, "captions": not args.no_captions,
        "rememberTimeout": args.remember_timeout, "answerTimeout": args.answer_timeout,
    }
    parallel, replicas = plan_parallelism(args.workers, len(plan), args.answer_replicas, args.lattice)
    identity = {
        "runName": args.run_name, "startedAt": datetime.now(timezone.utc).isoformat(),
        "harnessGit": git_identity(ROOT), "binary": str(binary), "binarySha256": sha256_file(binary),
        "binaryBuildInfo": json.loads(build_info_path.read_text()) if build_info_path.exists() else None,
        "readerModel": args.reader_model, "judgeModel": args.judge_model, "judge": JUDGE_SOURCE,
        "judgePromptSha256": ACCURACY_PROMPT_SHA256, "adversarialGold": ADVERSARIAL_GOLD,
        "embeddingModel": args.embedding_model if args.embedding_provider_via_proxy else None,
        "tokenizer": TOKENIZER, "budgets": args.budgets,
        "dataset": str(args.dataset), "datasetSha256": dataset_sha, "datasetCommit": LOCOMO_COMMIT,
        "datasetMatchesPinned": dataset_sha == LOCOMO_SHA256,
        "auditErrors": str(args.audit_errors) if audit else None, "auditSha256": audit_sha,
        "auditCommit": AUDIT_COMMIT if audit else None,
        "categories": args.categories, "conversations": len(plan),
        "questions": sum(len(questions) for _, questions in plan),
        "limits": {"conversations": args.limit_conversations, "questionsPerConversation": args.limit_questions,
                   "questionIds": args.questions, "sampleIds": args.conversations},
        "parallelism": {"conversations": parallel, "answerDaemonsPerConversation": replicas},
        "speakerMode": args.speaker_mode, "captions": not args.no_captions,
        "questionTime": f"last message of the last session + {int(QUESTION_DELAY.total_seconds())} s",
        "daemonConfig": {k: v for k, v in config.items() if k != "daemonBinary"},
    }
    config_hash = digest([identity["binarySha256"], dataset_sha, audit_sha, ACCURACY_PROMPT_SHA256, ADVERSARIAL_GOLD,
                          QUESTION_DELAY.total_seconds(),
                          {k: v for k, v in config.items()
                           if k not in ("dbDir", "rememberTimeout", "answerTimeout", "rerankerUrl")}])
    identity["configHash"] = config_hash
    write_json(run_dir / "manifest.json", identity)
    count = tokenizer_counter(TOKENIZER)
    state = ProxyState(args.proxy_cache, run_dir / "proxy.jsonl", max_spend_usd=args.max_spend_usd,
                       offline=args.offline)
    total = identity["questions"]
    progress = {"done": 0}
    progress_lock = threading.Lock()

    def on_done(record: Mapping[str, Any]) -> None:
        with progress_lock:
            progress["done"] += 1
            marks = " ".join(f"{row['budget']}:{'ERR' if row['status'] != 'ok' else ('Y' if row['correct'] else 'n')}"
                             for row in record["rows"])
            print(f"[{progress['done']}] {record['questionId']} (cat {record['category']}) {marks} "
                  f"spent=${state.spent_usd:.4f}", flush=True)

    print(f"{len(plan)} conversations, {total} questions; {parallel} conversations in parallel, "
          f"{replicas} answering daemon(s) each", flush=True)
    started = time.perf_counter()
    conversations: list[dict[str, Any]] = []
    with CachingProxy(state) as proxy, ThreadPoolExecutor(max_workers=parallel) as executor:
        post = proxy_poster(proxy)
        futures = {executor.submit(run_conversation, conversation, questions, config, proxy, post, count, run_dir,
                                   config_hash, fresh=args.fresh, replicas=replicas, on_done=on_done):
                   (conversation, questions) for conversation, questions in plan}
        for future in as_completed(futures):
            conversation, questions = futures[future]
            try:
                conversations.append(future.result())
            except Exception as exc:  # Harness bug: keep going, record as runtime errors.
                records = []
                for question in questions:
                    record = question_record(question)
                    record["status"] = "error"
                    record["rows"] = [error_row(question, b, "harness", f"{type(exc).__name__}: {exc}")
                                      for b in args.budgets]
                    records.append(record)
                conversations.append({"sampleId": conversation["sampleId"], "ingest": {"error": str(exc)[:1000]},
                                      "questions": records})
            done = conversations[-1]
            print(f"conversation {done['sampleId']} finished ({done.get('reused', 0)} reused)", flush=True)
        proxy_totals = summarize_records(state.records)
    records = sorted((record for c in conversations for record in c["questions"]),
                     key=lambda r: (r["conversationIndex"], r["qaIndex"]))
    rows = [row for record in records for row in sorted(record["rows"], key=lambda row: row["budget"])]
    judge_fresh = sum(row.get("judgeCostUsd") or 0.0 for row in rows)
    report = {
        "title": f"Quipu daemon on LoCoMo: {args.run_name}",
        "identity": identity, "elapsedSeconds": time.perf_counter() - started,
        **aggregate(rows, args.budgets), "ingest": summarize_ingest(conversations),
        "spend": {"thisInvocationProxy": proxy_totals, "judgeFreshUsdThisInvocationRows": judge_fresh,
                  "note": "proxy costUsd is new spend (reader, embeddings and judge all go through the proxy); "
                          "nominal includes cache hits' original cost"},
        "errors": [row for row in rows if row["status"] != "ok"],
        "rows": [{k: v for k, v in row.items() if k not in ("context", "itemRefs", "answerTrace")} for row in rows],
    }
    write_json(run_dir / "report.json", report)
    (run_dir / "report.md").write_text(markdown(report))
    print(markdown(report))
    return 0


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    download = sub.add_parser("download", help="fetch the pinned dataset and audit errors; verify sha256")
    download.add_argument("--output-dir", type=Path, default=DEFAULT_DIR)
    download.add_argument("--force", action="store_true", help="re-download even if the files exist")
    download.set_defaults(func=cmd_download)

    run = sub.add_parser("run", help="run the daemon on LoCoMo")
    run.add_argument("--daemon-binary", required=True)
    run.add_argument("--run-name", required=True)
    run.add_argument("--budgets", type=lambda value: [int(v) for v in value.split(",")], default=[1024, 4096])
    run.add_argument("--reader-model", default=READER_MODEL)
    run.add_argument("--judge-model", default=JUDGE_MODEL)
    run.add_argument("--workers", type=int, default=10,
                     help="answering daemons in total: conversations run in parallel, and leftover workers become "
                          "extra answering daemons per conversation (Lattice only)")
    run.add_argument("--answer-replicas", type=int,
                     help="answering daemons per conversation, each over a copy of the ingested store "
                          "(default: workers // parallel conversations)")
    run.add_argument("--lattice", action="store_true", help="binary is a Lattice build; fresh --db per conversation")
    run.add_argument("--db-dir", type=Path, help="keep per-conversation Lattice DBs here (default: temp dirs)")
    run.add_argument("--embedding-provider-via-proxy", action="store_true",
                     help="configure the daemon's OpenRouter embedding provider through the proxy")
    run.add_argument("--embedding-model", default=EMBED_MODEL)
    run.add_argument("--vector-dimensions", type=int)
    run.add_argument("--categories", type=parse_categories, default=sorted(CATEGORY_NAMES),
                     help="comma-separated LoCoMo category ids (default 1,2,3,4,5; 5 is reported separately)")
    run.add_argument("--limit-conversations", type=int, help="first N conversations")
    run.add_argument("--limit-questions", type=int, help="first N questions per conversation, after the category filter")
    run.add_argument("--conversations", nargs="+", help="subset of sample ids, e.g. conv-26")
    run.add_argument("--questions", nargs="+", help="subset of question ids, e.g. locomo_0_qa12")
    run.add_argument("--speaker-mode", choices=SPEAKER_MODES, default="role",
                     help="role: speaker name is the message role (default); prefix: role user, 'Name: ' content")
    run.add_argument("--no-captions", action="store_true", help="drop BLIP image captions")
    run.add_argument("--no-extract", action="store_true", help="remember with extract=false (default: daemon default true)")
    run.add_argument("--needs", nargs="+", help="memory.answer needs (default: omitted)")
    run.add_argument("--mode", choices=["fts", "vector", "hybrid", "graph"], help="memory.answer mode (default: omitted)")
    run.add_argument("--daemon-arg", action="append", help="extra daemon CLI argument (repeatable)")
    run.add_argument("--answer-option", action="append", metavar="KEY=JSON",
                     help="extra memory.answer option, value parsed as JSON (repeatable)")
    run.add_argument("--reranker-url", help="Cohere-compatible rerank endpoint for the daemon")
    run.add_argument("--reranker-model", help="model sent to the reranker")
    run.add_argument("--fresh", action="store_true", help="ignore matching per-question results")
    run.add_argument("--artifacts", type=Path, default=DEFAULT_ARTIFACTS / "sota/locomo")
    run.add_argument("--dataset", type=Path, default=DEFAULT_DATASET)
    run.add_argument("--audit-errors", type=Path, default=DEFAULT_AUDIT)
    run.add_argument("--proxy-cache", type=Path, default=DEFAULT_ARTIFACTS / "sota/cache/proxy")
    run.add_argument("--max-spend-usd", type=float, default=4.0, help="proxy refuses new upstream calls past this")
    run.add_argument("--offline", action="store_true", help="proxy serves cache hits only")
    run.add_argument("--remember-timeout", type=float, default=300)
    run.add_argument("--answer-timeout", type=float, default=600)
    run.set_defaults(func=cmd_run)

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
