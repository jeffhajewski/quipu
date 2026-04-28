from __future__ import annotations

from dataclasses import dataclass
import re
from typing import Iterable, Optional

from .scenarios import Event, ForgetOp, Query, Scope


@dataclass(frozen=True)
class FakeRetrieval:
    answer: str
    evidence_event_ids: list[str]
    item_texts: list[str]
    item_scopes: list[Scope]


@dataclass
class StoredEvent:
    event: Event
    deleted: bool = False


class FakeQuipuClient:
    """Raw-only in-memory client for eval harness smoke tests."""

    def __init__(self) -> None:
        self._events: list[StoredEvent] = []

    def remember_event(self, event: Event) -> None:
        self._events.append(StoredEvent(event=event))

    def retrieve(self, query: Query) -> FakeRetrieval:
        candidates = [
            stored
            for stored in self._events
            if not stored.deleted
            and stored.event.time <= query.time
            and _scope_matches(stored.event.scope, query.scope)
        ]
        scored = sorted(
            ((self._score(query.query, stored.event), stored) for stored in candidates),
            key=lambda item: (item[0], item[1].event.time),
            reverse=True,
        )
        if not scored or scored[0][0] == 0:
            return FakeRetrieval(answer="", evidence_event_ids=[], item_texts=[], item_scopes=[])

        best = scored[0][1].event
        text = _event_text(best)
        return FakeRetrieval(
            answer=_answer_from_text(text),
            evidence_event_ids=[best.event_id],
            item_texts=[text],
            item_scopes=[best.scope],
        )

    def forget(self, op: ForgetOp) -> int:
        selector_event_ids = set(op.selector.get("eventIds", []))
        deleted = 0
        for stored in self._events:
            if stored.event.event_id in selector_event_ids and not stored.deleted:
                stored.deleted = True
                deleted += 1
        return deleted

    def visible_texts(self) -> list[str]:
        return [_event_text(stored.event) for stored in self._events if not stored.deleted]

    @staticmethod
    def _score(query: str, event: Event) -> int:
        query_tokens = _tokens(query)
        text_tokens = _tokens(_event_text(event))
        return len(query_tokens & text_tokens)


Q0RawOnlyBaseline = FakeQuipuClient


def _scope_matches(event_scope: Scope, query_scope: Scope) -> bool:
    for key, value in query_scope.items():
        if event_scope.get(key) != value:
            return False
    return True


def _event_text(event: Event) -> str:
    return " ".join(message.content for message in event.messages)


def _tokens(text: str) -> set[str]:
    return {_stem(token) for token in re.findall(r"[a-z0-9]+", text.lower())}


def _stem(token: str) -> str:
    if len(token) > 3 and token.endswith("s"):
        return token[:-1]
    return token


def _answer_from_text(text: str) -> str:
    lower = text.lower()
    command = _extract_command(lower)
    if command:
        return command
    if "pnpm" in lower:
        return "pnpm"
    if "npm" in lower:
        return "npm"
    return text


def _extract_command(text: str) -> Optional[str]:
    for command in ("just test", "npm test", "pnpm test"):
        if command in text:
            return command
    return None
