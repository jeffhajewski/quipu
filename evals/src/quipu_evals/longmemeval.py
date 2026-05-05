from __future__ import annotations

from dataclasses import asdict
from datetime import datetime, timedelta, timezone
import json
import re
from pathlib import Path
from typing import Any, Iterable, Mapping
from urllib.request import urlopen

from .scenarios import Event, Message, Query, Scenario, Suite


LONGMEMEVAL_BASE_URL = "https://huggingface.co/datasets/xiaowu0162/longmemeval-cleaned/resolve/main"
LONGMEMEVAL_FILES = {
    "oracle": "longmemeval_oracle.json",
    "s": "longmemeval_s_cleaned.json",
    "m": "longmemeval_m_cleaned.json",
}
LONGMEMEVAL_LICENSE = "MIT"
ROLE_ALIASES = {
    "human": "user",
    "ai": "assistant",
    "bot": "assistant",
    "gpt": "assistant",
}
MESSAGE_ROLES = {"system", "developer", "user", "assistant", "tool"}


def download_longmemeval(cache_dir: str | Path, *, variant: str = "oracle", url: str | None = None) -> Path:
    variant = _variant(variant)
    cache_path = Path(cache_dir)
    cache_path.mkdir(parents=True, exist_ok=True)
    filename = LONGMEMEVAL_FILES[variant]
    output = cache_path / filename
    if output.exists():
        return output
    with urlopen(url or f"{LONGMEMEVAL_BASE_URL}/{filename}", timeout=120) as response:
        output.write_bytes(response.read())
    return output


def load_longmemeval_suite(
    path: str | Path,
    *,
    variant: str = "oracle",
    max_conversations: int | None = None,
    max_sessions_per_conversation: int | None = None,
    include_question_types: Iterable[str] | None = None,
) -> Suite:
    dataset_path = Path(path)
    raw = json.loads(dataset_path.read_text())
    if not isinstance(raw, list):
        raise ValueError("LongMemEval dataset must be a list of question instances")

    allowed_types = {item for item in include_question_types or [] if item}
    scenarios: list[Scenario] = []
    for index, item in enumerate(raw):
        if max_conversations is not None and len(scenarios) >= max_conversations:
            break
        if not isinstance(item, Mapping):
            raise ValueError(f"LongMemEval item {index} must be an object")
        category = _query_category(item)
        if allowed_types and category not in allowed_types and str(item.get("question_type") or "") not in allowed_types:
            continue
        scenarios.append(
            _item_to_scenario(
                item,
                item_index=index,
                variant=variant,
                max_sessions=max_sessions_per_conversation,
            )
        )

    tasks = sorted({query.category for scenario in scenarios for query in scenario.queries})
    full_dataset = (
        max_conversations is None
        and max_sessions_per_conversation is None
        and not allowed_types
        and len(raw) >= 500
    )
    return Suite(
        name="longmemeval",
        version=f"real-2025-cleaned-{_variant(variant)}",
        suites=["longmemeval", "external"],
        metadata={
            "format": "quipu.external.scenario.v1",
            "benchmark": "longmemeval",
            "datasetName": "LongMemEval",
            "datasetVersion": f"xiaowu0162/longmemeval-cleaned {LONGMEMEVAL_FILES[_variant(variant)]}",
            "source": str(dataset_path),
            "license": LONGMEMEVAL_LICENSE,
            "downloadUrl": f"{LONGMEMEVAL_BASE_URL}/{LONGMEMEVAL_FILES[_variant(variant)]}",
            "tasks": tasks,
            "fullDataset": full_dataset,
            "limits": {
                "maxConversations": max_conversations,
                "maxSessionsPerConversation": max_sessions_per_conversation,
                "includeQuestionTypes": sorted(allowed_types),
                "variant": _variant(variant),
            },
        },
        scenarios=scenarios,
    )


def suite_to_json(suite: Suite) -> dict[str, Any]:
    return {
        "name": suite.name,
        "version": suite.version,
        "metadata": dict(suite.metadata),
        "suites": list(suite.suites),
        "scenarios": [_scenario_to_json(scenario) for scenario in suite.scenarios],
    }


def write_suite(path: str | Path, suite: Suite) -> None:
    output = Path(path)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(suite_to_json(suite), indent=2, sort_keys=True) + "\n")


def _item_to_scenario(
    item: Mapping[str, Any],
    *,
    item_index: int,
    variant: str,
    max_sessions: int | None,
) -> Scenario:
    question_id = str(item.get("question_id") or f"question-{item_index + 1}")
    scope = {
        "tenantId": "benchmark:longmemeval",
        "projectId": f"longmemeval:{_slug(question_id)}",
    }
    session_ids = _string_list(item.get("haystack_session_ids"))
    dates = _string_list(item.get("haystack_dates"))
    sessions = item.get("haystack_sessions")
    if not isinstance(sessions, list):
        raise ValueError(f"LongMemEval item {question_id} has no haystack_sessions list")

    events: list[Event] = []
    for index, session in enumerate(sessions):
        if max_sessions is not None and len(events) >= max_sessions:
            break
        if not isinstance(session, list):
            continue
        session_id = session_ids[index] if index < len(session_ids) else f"{question_id}_session_{index + 1}"
        messages = _session_messages(session)
        if not messages:
            continue
        events.append(
            Event(
                event_id=session_id,
                time=_session_time(dates, index),
                type="message",
                messages=messages,
                scope=scope,
                ground_truth_memories=[f"longmemeval:{question_id}:{session_id}"],
            )
        )

    expected_evidence = _expected_evidence(item, events)
    should_abstain = _should_abstain(item)
    answer = "[abstain]" if should_abstain else _answer_text(item.get("answer"))
    query = Query(
        query_id=question_id,
        time=_query_time(item, events),
        query=str(item.get("question") or ""),
        scope=scope,
        expected_answer=answer,
        expected_evidence_event_ids=expected_evidence,
        must_not_use_event_ids=[],
        category=_query_category(item),
        should_abstain=should_abstain,
    )
    return Scenario(
        scenario_id=f"longmemeval_{_slug(question_id)}",
        metadata={
            "source": "longmemeval",
            "license": LONGMEMEVAL_LICENSE,
            "questionId": question_id,
            "questionType": str(item.get("question_type") or ""),
            "variant": _variant(variant),
            "suite": "longmemeval",
        },
        actors=[
            {"id": "user", "type": "user", "name": "User"},
            {"id": "assistant", "type": "agent", "name": "Assistant"},
        ],
        events=events,
        queries=[query],
        forget_ops=[],
    )


def _session_messages(session: list[Any]) -> list[Message]:
    messages: list[Message] = []
    for turn in session:
        if not isinstance(turn, Mapping):
            continue
        content = str(turn.get("content") or turn.get("text") or "").strip()
        if not content:
            continue
        role = _role(str(turn.get("role") or "user"))
        messages.append(Message(role=role, content=content))
    return messages


def _expected_evidence(item: Mapping[str, Any], events: list[Event]) -> list[str]:
    answer_session_ids = _string_list(item.get("answer_session_ids"))
    if answer_session_ids:
        return [event.event_id for event in events if event.event_id in set(answer_session_ids)]
    evidence: list[str] = []
    event_ids = {event.event_id for event in events}
    session_ids = _string_list(item.get("haystack_session_ids"))
    sessions = item.get("haystack_sessions")
    if not isinstance(sessions, list):
        return evidence
    for index, session in enumerate(sessions):
        if not isinstance(session, list):
            continue
        event_id = session_ids[index] if index < len(session_ids) else ""
        if event_id not in event_ids:
            continue
        if any(isinstance(turn, Mapping) and bool(turn.get("has_answer")) for turn in session):
            evidence.append(event_id)
    return evidence


def _query_category(item: Mapping[str, Any]) -> str:
    if _should_abstain(item):
        return "abstention"
    raw = str(item.get("question_type") or "unknown").strip()
    return raw or "unknown"


def _should_abstain(item: Mapping[str, Any]) -> bool:
    question_id = str(item.get("question_id") or "")
    return question_id.endswith("_abs") or item.get("answer") is None


def _answer_text(value: Any) -> str:
    if value is None:
        return "[abstain]"
    if isinstance(value, str):
        return value
    return json.dumps(value, ensure_ascii=False, sort_keys=True)


def _query_time(item: Mapping[str, Any], events: list[Event]) -> str:
    raw = item.get("question_date")
    if isinstance(raw, str) and raw.strip():
        return _parse_datetime(raw).isoformat().replace("+00:00", "Z")
    if events:
        latest = max(_parse_datetime(event.time) for event in events)
        return (latest + timedelta(days=1)).isoformat().replace("+00:00", "Z")
    return datetime(1970, 1, 1, tzinfo=timezone.utc).isoformat().replace("+00:00", "Z")


def _session_time(dates: list[str], index: int) -> str:
    if index < len(dates) and dates[index]:
        return _parse_datetime(dates[index]).isoformat().replace("+00:00", "Z")
    return datetime(1970, 1, 1, tzinfo=timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def _parse_datetime(value: str) -> datetime:
    raw = value.strip()
    for fmt in ("%Y/%m/%d (%a) %H:%M", "%Y/%m/%d %H:%M", "%Y-%m-%dT%H:%M:%SZ", "%Y-%m-%dT%H:%M:%S%z"):
        try:
            parsed = datetime.strptime(raw, fmt)
        except ValueError:
            continue
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=timezone.utc)
        return parsed.astimezone(timezone.utc)
    try:
        parsed = datetime.fromisoformat(raw.replace("Z", "+00:00"))
    except ValueError as exc:
        raise ValueError(f"unsupported LongMemEval datetime: {value}") from exc
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


def _role(value: str) -> str:
    normalized = ROLE_ALIASES.get(value.strip().lower(), value.strip().lower())
    return normalized if normalized in MESSAGE_ROLES else "user"


def _string_list(value: Any) -> list[str]:
    if not isinstance(value, list):
        return []
    return [str(item) for item in value if item is not None]


def _variant(value: str) -> str:
    normalized = value.strip().lower()
    if normalized not in LONGMEMEVAL_FILES:
        raise ValueError(f"unsupported LongMemEval variant: {value}")
    return normalized


def _scenario_to_json(scenario: Scenario) -> dict[str, Any]:
    return {
        "scenarioId": scenario.scenario_id,
        "metadata": dict(scenario.metadata),
        "actors": [dict(actor) for actor in scenario.actors],
        "events": [_event_to_json(event) for event in scenario.events],
        "queries": [_query_to_json(query) for query in scenario.queries],
        "forgetOps": [],
    }


def _event_to_json(event: Event) -> dict[str, Any]:
    return {
        "eventId": event.event_id,
        "time": event.time,
        "type": event.type,
        "messages": [asdict(message) for message in event.messages],
        "scope": dict(event.scope),
        "groundTruthMemories": list(event.ground_truth_memories),
    }


def _query_to_json(query: Query) -> dict[str, Any]:
    return {
        "queryId": query.query_id,
        "time": query.time,
        "query": query.query,
        "scope": dict(query.scope),
        "expectedAnswer": query.expected_answer,
        "expectedEvidenceEventIds": list(query.expected_evidence_event_ids),
        "mustNotUseEventIds": list(query.must_not_use_event_ids),
        "category": query.category,
        "shouldAbstain": query.should_abstain,
    }


def _slug(value: str) -> str:
    slug = re.sub(r"[^a-zA-Z0-9_-]+", "-", value.strip()).strip("-").lower()
    return slug or "unknown"
