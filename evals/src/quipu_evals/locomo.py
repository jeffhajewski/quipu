from __future__ import annotations

from dataclasses import asdict
from datetime import datetime, timedelta, timezone
import json
import re
from pathlib import Path
from typing import Any, Iterable, Mapping
from urllib.request import urlopen

from .scenarios import Event, ForgetOp, Message, Query, Scenario, Suite


LOCOMO_URL = "https://raw.githubusercontent.com/snap-research/locomo/main/data/locomo10.json"
CATEGORY_NAMES = {
    1: "single_hop",
    2: "temporal",
    3: "multi_hop",
    4: "open_domain",
    5: "adversarial",
}
DEFAULT_TASKS = ["single_hop", "multi_hop", "temporal", "open_domain", "adversarial"]


def download_locomo(cache_dir: str | Path, *, url: str = LOCOMO_URL) -> Path:
    cache_path = Path(cache_dir)
    cache_path.mkdir(parents=True, exist_ok=True)
    output = cache_path / "locomo10.json"
    if output.exists():
        return output
    with urlopen(url, timeout=60) as response:
        output.write_bytes(response.read())
    return output


def load_locomo_suite(
    path: str | Path,
    *,
    max_conversations: int | None = None,
    max_questions_per_conversation: int | None = None,
    include_categories: Iterable[int] | None = None,
    include_event_summaries: bool = False,
) -> Suite:
    dataset_path = Path(path)
    raw = json.loads(dataset_path.read_text())
    if not isinstance(raw, list):
        raise ValueError("LoCoMo dataset must be a list of conversation samples")

    allowed_categories = set(include_categories or CATEGORY_NAMES)
    full_dataset = (
        max_conversations is None
        and max_questions_per_conversation is None
        and allowed_categories == set(CATEGORY_NAMES)
    )
    scenarios = []
    for sample_index, sample in enumerate(raw):
        if max_conversations is not None and len(scenarios) >= max_conversations:
            break
        if not isinstance(sample, Mapping):
            raise ValueError(f"LoCoMo sample {sample_index} must be an object")
        scenarios.append(
            _sample_to_scenario(
                sample,
                sample_index=sample_index,
                allowed_categories=allowed_categories,
                max_questions=max_questions_per_conversation,
                include_event_summaries=include_event_summaries,
            )
        )

    present_tasks = {
        query.category
        for scenario in scenarios
        for query in scenario.queries
        if query.category != "event_summary"
    }
    tasks = [CATEGORY_NAMES[category] for category in sorted(allowed_categories) if CATEGORY_NAMES.get(category) in present_tasks]
    if include_event_summaries:
        tasks.append("event_summary")
    return Suite(
        name="locomo",
        version="real-2024-snap-locomo10",
        suites=["locomo", "external"],
        metadata={
            "format": "quipu.external.scenario.v1",
            "benchmark": "locomo",
            "datasetName": "LoCoMo",
            "datasetVersion": "snap-research/locomo data/locomo10.json",
            "source": str(dataset_path),
            "license": "LoCoMo upstream license",
            "downloadUrl": LOCOMO_URL,
            "tasks": tasks,
            "fullDataset": full_dataset,
            "limits": {
                "maxConversations": max_conversations,
                "maxQuestionsPerConversation": max_questions_per_conversation,
                "includeCategories": sorted(allowed_categories),
            },
        },
        scenarios=scenarios,
    )


def write_suite(path: str | Path, suite: Suite) -> None:
    output = Path(path)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(suite_to_json(suite), indent=2, sort_keys=True) + "\n")


def suite_to_json(suite: Suite) -> dict[str, Any]:
    return {
        "name": suite.name,
        "version": suite.version,
        "metadata": dict(suite.metadata),
        "suites": list(suite.suites),
        "scenarios": [_scenario_to_json(scenario) for scenario in suite.scenarios],
    }


def _sample_to_scenario(
    sample: Mapping[str, Any],
    *,
    sample_index: int,
    allowed_categories: set[int],
    max_questions: int | None,
    include_event_summaries: bool,
) -> Scenario:
    sample_id = str(sample.get("sample_id") or f"sample-{sample_index + 1}")
    conversation = _require_mapping(sample, "conversation")
    scope = {"tenantId": "benchmark:locomo", "projectId": f"locomo:{sample_id}"}
    session_times = _session_times(conversation)

    events: list[Event] = []
    session_turn_ids: dict[int, dict[str, list[str]]] = {}
    for session_number in sorted(session_times):
        session_key = f"session_{session_number}"
        turns = conversation.get(session_key)
        if not isinstance(turns, list):
            continue
        speaker_turn_ids: dict[str, list[str]] = {}
        for turn_index, turn in enumerate(turns):
            if not isinstance(turn, Mapping):
                continue
            dia_id = str(turn.get("dia_id") or f"D{session_number}:{turn_index + 1}")
            speaker = str(turn.get("speaker") or "speaker")
            speaker_turn_ids.setdefault(speaker, []).append(dia_id)
            events.append(
                Event(
                    event_id=dia_id,
                    time=(session_times[session_number] + timedelta(seconds=turn_index)).isoformat().replace("+00:00", "Z"),
                    type="message",
                    messages=[Message(role="user", content=_turn_text(turn))],
                    scope=scope,
                    ground_truth_memories=[f"locomo:{sample_id}:{dia_id}"],
                )
            )
        session_turn_ids[session_number] = speaker_turn_ids

    query_time = _query_time(session_times)
    queries = _qa_queries(
        sample,
        sample_id=sample_id,
        scope=scope,
        query_time=query_time,
        allowed_categories=allowed_categories,
        max_questions=max_questions,
    )
    if include_event_summaries:
        queries.extend(
            _event_summary_queries(
                sample,
                sample_id=sample_id,
                scope=scope,
                query_time=query_time,
                session_turn_ids=session_turn_ids,
            )
        )

    return Scenario(
        scenario_id=f"locomo_{_slug(sample_id)}",
        metadata={
            "source": "locomo",
            "license": "LoCoMo upstream license",
            "sampleId": sample_id,
            "suite": "locomo",
        },
        actors=_actors(conversation),
        events=events,
        queries=queries,
        forget_ops=[],
    )


def _qa_queries(
    sample: Mapping[str, Any],
    *,
    sample_id: str,
    scope: dict[str, str],
    query_time: str,
    allowed_categories: set[int],
    max_questions: int | None,
) -> list[Query]:
    queries: list[Query] = []
    for index, raw_query in enumerate(sample.get("qa", [])):
        if not isinstance(raw_query, Mapping):
            continue
        category = int(raw_query.get("category", 0) or 0)
        if category not in allowed_categories:
            continue
        expected = raw_query.get("answer")
        if expected is None:
            expected = raw_query.get("adversarial_answer")
        expected_answer = str(expected) if expected is not None else "[abstain]"
        evidence = [str(item) for item in raw_query.get("evidence", []) if item is not None]
        queries.append(
            Query(
                query_id=f"{sample_id}_qa_{index + 1:04d}",
                time=query_time,
                query=str(raw_query.get("question") or ""),
                scope=scope,
                expected_answer=expected_answer,
                expected_evidence_event_ids=evidence,
                must_not_use_event_ids=[],
                category=CATEGORY_NAMES.get(category, f"category_{category}"),
                should_abstain=expected is None,
            )
        )
        if max_questions is not None and len(queries) >= max_questions:
            break
    return queries


def _event_summary_queries(
    sample: Mapping[str, Any],
    *,
    sample_id: str,
    scope: dict[str, str],
    query_time: str,
    session_turn_ids: Mapping[int, Mapping[str, list[str]]],
) -> list[Query]:
    summaries = sample.get("event_summary", {})
    if not isinstance(summaries, Mapping):
        return []
    queries: list[Query] = []
    for key, value in summaries.items():
        match = re.fullmatch(r"events_session_(\d+)", str(key))
        if not match or not isinstance(value, Mapping):
            continue
        session_number = int(match.group(1))
        for speaker, events in value.items():
            if speaker == "date" or not isinstance(events, list) or not events:
                continue
            expected = "; ".join(str(item) for item in events)
            queries.append(
                Query(
                    query_id=f"{sample_id}_event_summary_{session_number}_{_slug(str(speaker))}",
                    time=query_time,
                    query=f"What significant events should be summarized for {speaker} in session {session_number}?",
                    scope=scope,
                    expected_answer=expected,
                    expected_evidence_event_ids=list(session_turn_ids.get(session_number, {}).get(str(speaker), [])),
                    must_not_use_event_ids=[],
                    category="event_summary",
                    should_abstain=False,
                )
            )
    return queries


def _session_times(conversation: Mapping[str, Any]) -> dict[int, datetime]:
    result: dict[int, datetime] = {}
    for key, value in conversation.items():
        match = re.fullmatch(r"session_(\d+)_date_time", str(key))
        if match and isinstance(value, str):
            result[int(match.group(1))] = _parse_locomo_datetime(value)
    if not result:
        raise ValueError("LoCoMo conversation has no session timestamps")
    return result


def _parse_locomo_datetime(value: str) -> datetime:
    parsed = datetime.strptime(value, "%I:%M %p on %d %B, %Y")
    return parsed.replace(tzinfo=timezone.utc)


def _query_time(session_times: Mapping[int, datetime]) -> str:
    latest = max(session_times.values())
    return (latest + timedelta(days=1)).isoformat().replace("+00:00", "Z")


def _turn_text(turn: Mapping[str, Any]) -> str:
    speaker = str(turn.get("speaker") or "speaker")
    text = str(turn.get("text") or "")
    parts = [f"{speaker}: {text}"]
    caption = turn.get("blip_caption")
    if isinstance(caption, str) and caption:
        parts.append(f"Image caption: {caption}")
    return " ".join(parts)


def _actors(conversation: Mapping[str, Any]) -> list[Mapping[str, Any]]:
    actors = []
    for key in ("speaker_a", "speaker_b"):
        value = conversation.get(key)
        if isinstance(value, str) and value:
            actors.append({"id": _slug(value), "type": "user", "name": value})
    actors.append({"id": "assistant", "type": "agent", "name": "Assistant"})
    return actors


def _require_mapping(raw: Mapping[str, Any], key: str) -> Mapping[str, Any]:
    value = raw.get(key)
    if not isinstance(value, Mapping):
        raise ValueError(f"{key} must be an object")
    return value


def _scenario_to_json(scenario: Scenario) -> dict[str, Any]:
    return {
        "scenarioId": scenario.scenario_id,
        "metadata": dict(scenario.metadata),
        "actors": [dict(actor) for actor in scenario.actors],
        "events": [_event_to_json(event) for event in scenario.events],
        "queries": [_query_to_json(query) for query in scenario.queries],
        "forgetOps": [_forget_to_json(op) for op in scenario.forget_ops],
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


def _forget_to_json(op: ForgetOp) -> dict[str, Any]:
    return {
        "forgetId": op.forget_id,
        "afterEventId": op.after_event_id,
        "selector": dict(op.selector),
        "mode": op.mode,
        "expectedNotRetrievableText": list(op.expected_not_retrievable_text),
    }


def _slug(value: str) -> str:
    slug = re.sub(r"[^a-zA-Z0-9_-]+", "-", value.strip()).strip("-").lower()
    return slug or "unknown"
