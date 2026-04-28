from __future__ import annotations

from dataclasses import dataclass, field
import json
from pathlib import Path
from typing import Any, Mapping, Optional, Union


Scope = dict[str, str]


@dataclass(frozen=True)
class Message:
    role: str
    content: str


@dataclass(frozen=True)
class Event:
    event_id: str
    time: str
    type: str
    messages: list[Message]
    scope: Scope
    ground_truth_memories: list[str] = field(default_factory=list)


@dataclass(frozen=True)
class Query:
    query_id: str
    time: str
    query: str
    scope: Scope
    expected_answer: str
    expected_evidence_event_ids: list[str]
    must_not_use_event_ids: list[str]
    category: str
    should_abstain: bool = False


@dataclass(frozen=True)
class ForgetOp:
    forget_id: str
    after_event_id: Optional[str]
    selector: Mapping[str, Any]
    mode: str
    expected_not_retrievable_text: list[str]


@dataclass(frozen=True)
class Scenario:
    scenario_id: str
    metadata: Mapping[str, Any]
    actors: list[Mapping[str, Any]]
    events: list[Event]
    queries: list[Query]
    forget_ops: list[ForgetOp]


@dataclass(frozen=True)
class Suite:
    name: str
    version: str
    suites: list[str]
    scenarios: list[Scenario]


def load_suite(path: Union[str, Path]) -> Suite:
    """Load a suite from JSON-compatible YAML.

    The current scaffold keeps suite files in the JSON subset of YAML so they
    can be parsed with the Python standard library. A future loader can add
    PyYAML support without changing the internal scenario dataclasses.
    """

    suite_path = Path(path)
    raw = json.loads(suite_path.read_text())
    return Suite(
        name=_require_string(raw, "name"),
        version=_require_string(raw, "version"),
        suites=_require_string_list(raw, "suites"),
        scenarios=[_parse_scenario(item) for item in _require_list(raw, "scenarios")],
    )


def _parse_scenario(raw: Mapping[str, Any]) -> Scenario:
    return Scenario(
        scenario_id=_require_string(raw, "scenarioId"),
        metadata=_require_mapping(raw, "metadata"),
        actors=list(_require_list(raw, "actors")),
        events=[_parse_event(item) for item in _require_list(raw, "events")],
        queries=[_parse_query(item) for item in _require_list(raw, "queries")],
        forget_ops=[_parse_forget(item) for item in raw.get("forgetOps", [])],
    )


def _parse_event(raw: Mapping[str, Any]) -> Event:
    return Event(
        event_id=_require_string(raw, "eventId"),
        time=_require_string(raw, "time"),
        type=_require_string(raw, "type"),
        messages=[
            Message(role=_require_string(message, "role"), content=_require_string(message, "content"))
            for message in _require_list(raw, "messages")
        ],
        scope=dict(_require_mapping(raw, "scope")),
        ground_truth_memories=_require_string_list(raw, "groundTruthMemories"),
    )


def _parse_query(raw: Mapping[str, Any]) -> Query:
    return Query(
        query_id=_require_string(raw, "queryId"),
        time=_require_string(raw, "time"),
        query=_require_string(raw, "query"),
        scope=dict(_require_mapping(raw, "scope")),
        expected_answer=_require_string(raw, "expectedAnswer"),
        expected_evidence_event_ids=_require_string_list(raw, "expectedEvidenceEventIds"),
        must_not_use_event_ids=_require_string_list(raw, "mustNotUseEventIds"),
        category=_require_string(raw, "category"),
        should_abstain=bool(raw.get("shouldAbstain", False)),
    )


def _parse_forget(raw: Mapping[str, Any]) -> ForgetOp:
    return ForgetOp(
        forget_id=_require_string(raw, "forgetId"),
        after_event_id=raw.get("afterEventId"),
        selector=_require_mapping(raw, "selector"),
        mode=_require_string(raw, "mode"),
        expected_not_retrievable_text=_require_string_list(raw, "expectedNotRetrievableText"),
    )


def _require_mapping(raw: Mapping[str, Any], key: str) -> Mapping[str, Any]:
    value = raw.get(key)
    if not isinstance(value, Mapping):
        raise ValueError(f"{key} must be an object")
    return value


def _require_list(raw: Mapping[str, Any], key: str) -> list[Any]:
    value = raw.get(key)
    if not isinstance(value, list):
        raise ValueError(f"{key} must be a list")
    return value


def _require_string(raw: Mapping[str, Any], key: str) -> str:
    value = raw.get(key)
    if not isinstance(value, str) or not value:
        raise ValueError(f"{key} must be a non-empty string")
    return value


def _require_string_list(raw: Mapping[str, Any], key: str) -> list[str]:
    values = _require_list(raw, key)
    if any(not isinstance(value, str) for value in values):
        raise ValueError(f"{key} must contain only strings")
    return list(values)
