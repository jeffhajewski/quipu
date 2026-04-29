from __future__ import annotations

from dataclasses import dataclass
from collections import Counter, defaultdict
import hashlib
import math
import re
from typing import Iterable, Optional, Protocol, Sequence

from .scenarios import Event, ForgetOp, Query, Scope

try:
    import numpy as np
except ImportError:  # pragma: no cover - exercised only when numpy is absent.
    np = None


@dataclass(frozen=True)
class FakeRetrieval:
    answer: str
    evidence_event_ids: list[str]
    item_texts: list[str]
    item_scopes: list[Scope]


class EmbeddingProvider(Protocol):
    def embed_texts(self, texts: Sequence[str]) -> list[list[float]]:
        pass


class AnswerProvider(Protocol):
    def generate_answer(self, question: str, contexts: Sequence[str]) -> str:
        pass


@dataclass
class ProviderVectorIndex:
    event_ids: list[str]
    matrix: object
    vectors: list[list[float]]


@dataclass
class StoredEvent:
    event: Event
    deleted: bool = False


@dataclass(frozen=True)
class BaselineConfig:
    baseline_id: str
    mode: str
    top_k: int | None = 1
    materialization: str = "raw"
    use_scope: bool = True
    use_temporal: bool = True
    use_forgetting: bool = True
    suppress_superseded: bool = False
    recency_weight: float = 0.0


BASELINE_CONFIGS: dict[str, BaselineConfig] = {
    "q0_raw_only_fake": BaselineConfig("q0_raw_only_fake", "lexical_overlap"),
    "full_context": BaselineConfig("full_context", "full_context", top_k=None),
    "recent_only": BaselineConfig("recent_only", "recent", top_k=3),
    "bm25": BaselineConfig("bm25", "bm25", top_k=5),
    "vector_rag": BaselineConfig("vector_rag", "vector", top_k=5),
    "hybrid_bm25_vector": BaselineConfig("hybrid_bm25_vector", "hybrid", top_k=5),
    "summary_only": BaselineConfig("summary_only", "bm25", top_k=5, materialization="summary"),
    "memory_cards_only": BaselineConfig("memory_cards_only", "bm25", top_k=5, materialization="memory_card"),
    "graph_only": BaselineConfig("graph_only", "graph", top_k=5),
    "Q0": BaselineConfig("Q0", "lexical_overlap"),
    "Q1": BaselineConfig("Q1", "bm25", top_k=5, materialization="memory_card"),
    "Q2": BaselineConfig("Q2", "bm25", top_k=5, materialization="fact"),
    "Q3": BaselineConfig("Q3", "vector", top_k=5),
    "Q4": BaselineConfig("Q4", "bm25", top_k=5),
    "Q5": BaselineConfig("Q5", "hybrid", top_k=5),
    "Q6": BaselineConfig("Q6", "graph", top_k=5),
    "Q7": BaselineConfig("Q7", "graph", top_k=5, recency_weight=0.15),
    "Q8": BaselineConfig("Q8", "bm25", top_k=5, use_temporal=True),
    "Q9": BaselineConfig("Q9", "hybrid", top_k=3, suppress_superseded=True),
    "Q10": BaselineConfig("Q10", "hybrid", top_k=3, recency_weight=0.05),
    "Q11": BaselineConfig("Q11", "hybrid", top_k=3, recency_weight=0.1),
    "Q12": BaselineConfig("Q12", "hybrid", top_k=5, materialization="summary"),
    "Q13": BaselineConfig("Q13", "hybrid", top_k=3, suppress_superseded=True, use_forgetting=True),
    "full_quipu": BaselineConfig("full_quipu", "hybrid", top_k=3, materialization="memory_card", suppress_superseded=True, recency_weight=0.1),
}


@dataclass(frozen=True)
class Candidate:
    stored: StoredEvent
    text: str
    score: float


class FakeQuipuClient:
    """Raw-only in-memory client for eval harness smoke tests."""

    def __init__(
        self,
        config: BaselineConfig | str = "q0_raw_only_fake",
        *,
        embedding_provider: EmbeddingProvider | None = None,
        answer_provider: AnswerProvider | None = None,
    ) -> None:
        self.config = baseline_config(config)
        self._events: list[StoredEvent] = []
        self.embedding_provider = embedding_provider
        self.answer_provider = answer_provider
        self._provider_vector_indexes: dict[tuple[str, ...], ProviderVectorIndex] = {}

    def remember_event(self, event: Event) -> None:
        self._events.append(StoredEvent(event=event))

    def retrieve(self, query: Query) -> FakeRetrieval:
        candidates = [
            stored
            for stored in self._events
            if (not self.config.use_forgetting or not stored.deleted)
            and (not self.config.use_temporal or stored.event.time <= query.time)
            and (not self.config.use_scope or _scope_matches(stored.event.scope, query.scope))
        ]
        selected = self._select(query, candidates)
        if not selected:
            return FakeRetrieval(answer="", evidence_event_ids=[], item_texts=[], item_scopes=[])

        selected = self._suppress_superseded(selected) if self.config.suppress_superseded else selected
        texts = [candidate.text for candidate in selected]
        combined_text = " ".join(texts)
        answer = (
            self.answer_provider.generate_answer(query.query, texts)
            if self.answer_provider is not None
            else _answer_from_text(combined_text, query.expected_answer)
        )
        return FakeRetrieval(
            answer=answer,
            evidence_event_ids=[candidate.stored.event.event_id for candidate in selected],
            item_texts=texts,
            item_scopes=[candidate.stored.event.scope for candidate in selected],
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

    def _select(self, query: Query, stored_events: list[StoredEvent]) -> list[Candidate]:
        if not stored_events:
            return []
        docs = [(stored, _materialized_text(stored.event, self.config.materialization)) for stored in stored_events]
        if self.config.mode == "full_context":
            selected = [Candidate(stored, text, 1.0) for stored, text in sorted(docs, key=lambda item: item[0].event.time)]
            return self._limit(selected)
        if self.config.mode == "recent":
            selected = [
                Candidate(stored, text, float(len(stored_events) - index))
                for index, (stored, text) in enumerate(sorted(docs, key=lambda item: item[0].event.time, reverse=True))
            ]
            return self._limit(selected)

        scores = self._scores(query.query, docs)
        ranked = sorted(
            (Candidate(stored, text, scores.get(stored.event.event_id, 0.0)) for stored, text in docs),
            key=lambda item: (item.score, item.stored.event.time),
            reverse=True,
        )
        ranked = [candidate for candidate in ranked if candidate.score > 0]
        return self._limit(ranked)

    def _scores(self, query: str, docs: list[tuple[StoredEvent, str]]) -> dict[str, float]:
        if self.config.mode == "lexical_overlap":
            return {
                stored.event.event_id: float(len(_tokens(query) & _tokens(text)))
                for stored, text in docs
            }
        if self.config.mode == "bm25":
            return _bm25_scores(query, docs)
        if self.config.mode == "vector":
            if self.embedding_provider is not None:
                return self._provider_vector_scores(query, docs)
            return {
                stored.event.event_id: _cosine(_embedding(query), _embedding(text))
                for stored, text in docs
            }
        if self.config.mode == "hybrid":
            bm25 = _normalize(_bm25_scores(query, docs))
            vector = _normalize(self._provider_vector_scores(query, docs)) if self.embedding_provider is not None else _normalize(
                {stored.event.event_id: _cosine(_embedding(query), _embedding(text)) for stored, text in docs}
            )
            return {
                stored.event.event_id: bm25.get(stored.event.event_id, 0.0) * 0.6 + vector.get(stored.event.event_id, 0.0) * 0.4
                for stored, _ in docs
            }
        if self.config.mode == "graph":
            return _graph_scores(query, docs)
        raise ValueError(f"unknown baseline mode: {self.config.mode}")

    def _provider_vector_scores(self, query: str, docs: list[tuple[StoredEvent, str]]) -> dict[str, float]:
        if self.embedding_provider is None:
            return {}
        key = tuple(stored.event.event_id for stored, _ in docs)
        index = self._provider_vector_indexes.get(key)
        if index is None:
            vectors = self.embedding_provider.embed_texts([text for _, text in docs])
            if np is not None:
                matrix = np.asarray(vectors, dtype=np.float32)
                matrix = np.nan_to_num(matrix, nan=0.0, posinf=0.0, neginf=0.0)
                norms = np.linalg.norm(matrix, axis=1)
                norms[(norms == 0) | ~np.isfinite(norms)] = 1.0
                matrix = matrix / norms[:, None]
            else:
                matrix = None
            index = ProviderVectorIndex(
                event_ids=[stored.event.event_id for stored, _ in docs],
                matrix=matrix,
                vectors=vectors,
            )
            self._provider_vector_indexes[key] = index
        query_vector = self.embedding_provider.embed_texts([query])[0]
        if np is not None and index.matrix is not None:
            query_array = np.asarray(query_vector, dtype=np.float32)
            query_array = np.nan_to_num(query_array, nan=0.0, posinf=0.0, neginf=0.0)
            norm = float(np.linalg.norm(query_array))
            if norm == 0 or not math.isfinite(norm):
                return {event_id: 0.0 for event_id in index.event_ids}
            with np.errstate(divide="ignore", over="ignore", invalid="ignore"):
                scores = index.matrix @ (query_array / norm)
            scores = np.nan_to_num(scores, nan=0.0, posinf=0.0, neginf=0.0)
            return {event_id: float(score) for event_id, score in zip(index.event_ids, scores)}
        return {
            event_id: _cosine(query_vector, vector)
            for event_id, vector in zip(index.event_ids, index.vectors)
        }

    def _limit(self, candidates: list[Candidate]) -> list[Candidate]:
        if self.config.recency_weight:
            recency_rank = {
                candidate.stored.event.event_id: index
                for index, candidate in enumerate(sorted(candidates, key=lambda item: item.stored.event.time))
            }
            candidates = [
                Candidate(
                    candidate.stored,
                    candidate.text,
                    candidate.score + self.config.recency_weight * recency_rank.get(candidate.stored.event.event_id, 0),
                )
                for candidate in candidates
            ]
            candidates = sorted(candidates, key=lambda item: (item.score, item.stored.event.time), reverse=True)
        if self.config.top_k is None:
            return candidates
        return candidates[: self.config.top_k]

    @staticmethod
    def _suppress_superseded(candidates: list[Candidate]) -> list[Candidate]:
        latest_by_signal: dict[str, Candidate] = {}
        passthrough: list[Candidate] = []
        for candidate in sorted(candidates, key=lambda item: item.stored.event.time, reverse=True):
            signals = _supersession_signals(candidate.text)
            if not signals:
                passthrough.append(candidate)
                continue
            if any(signal in latest_by_signal for signal in signals):
                continue
            for signal in signals:
                latest_by_signal[signal] = candidate
            passthrough.append(candidate)
        return sorted(passthrough, key=lambda item: (item.score, item.stored.event.time), reverse=True)


Q0RawOnlyBaseline = FakeQuipuClient


def baseline_config(config: BaselineConfig | str) -> BaselineConfig:
    if isinstance(config, BaselineConfig):
        return config
    try:
        return BASELINE_CONFIGS[config]
    except KeyError as exc:
        raise ValueError(f"unknown deterministic baseline: {config}") from exc


def supported_baseline_ids() -> list[str]:
    return list(BASELINE_CONFIGS)


def _scope_matches(event_scope: Scope, query_scope: Scope) -> bool:
    for key, value in query_scope.items():
        if event_scope.get(key) != value:
            return False
    return True


def _event_text(event: Event) -> str:
    return " ".join(message.content for message in event.messages)


def _materialized_text(event: Event, materialization: str) -> str:
    text = _event_text(event)
    if materialization == "raw":
        return text
    if materialization == "summary":
        return f"Summary: {text}"
    if materialization == "memory_card":
        memories = " ".join(event.ground_truth_memories)
        return f"Memory card: {memories} {text}".strip()
    if materialization == "fact":
        return f"Fact: {text}"
    raise ValueError(f"unknown materialization: {materialization}")


def _tokens(text: str) -> set[str]:
    return set(_token_list(text))


def _token_list(text: str) -> list[str]:
    return [_stem(token) for token in re.findall(r"[a-z0-9]+", text.lower()) if token not in STOPWORDS]


def _stem(token: str) -> str:
    if len(token) > 3 and token.endswith("s"):
        return token[:-1]
    return token


def _answer_from_text(text: str, expected_answer: str = "") -> str:
    lower = text.lower()
    if expected_answer and expected_answer.lower() in lower:
        return expected_answer
    command = _extract_command(lower)
    if command:
        return command
    if "pnpm" in lower:
        return "pnpm"
    if "npm" in lower:
        return "npm"
    if "concise" in lower:
        return "concise"
    if "detailed" in lower:
        return "detailed"
    return text


def _extract_command(text: str) -> Optional[str]:
    for command in ("just test", "npm test", "pnpm test"):
        if command in text:
            return command
    return None


def _bm25_scores(query: str, docs: list[tuple[StoredEvent, str]]) -> dict[str, float]:
    query_terms = _token_list(query)
    if not query_terms:
        return {stored.event.event_id: 0.0 for stored, _ in docs}
    tokenized_docs = [(stored, _token_list(text)) for stored, text in docs]
    doc_count = len(tokenized_docs)
    avg_len = sum(len(tokens) for _, tokens in tokenized_docs) / doc_count if doc_count else 0.0
    doc_freq: Counter[str] = Counter()
    for _, tokens in tokenized_docs:
        doc_freq.update(set(tokens))

    k1 = 1.5
    b = 0.75
    scores: dict[str, float] = {}
    for stored, tokens in tokenized_docs:
        frequencies = Counter(tokens)
        doc_len = max(len(tokens), 1)
        score = 0.0
        for term in query_terms:
            frequency = frequencies.get(term, 0)
            if not frequency:
                continue
            idf = math.log(1 + (doc_count - doc_freq[term] + 0.5) / (doc_freq[term] + 0.5))
            denominator = frequency + k1 * (1 - b + b * doc_len / max(avg_len, 1.0))
            score += idf * (frequency * (k1 + 1)) / denominator
        scores[stored.event.event_id] = score
    return scores


def _embedding(text: str) -> list[float]:
    dimensions = 64
    vector = [0.0] * dimensions
    for token in _token_list(text):
        digest = hashlib.sha256(token.encode("utf-8")).digest()
        index = int.from_bytes(digest[:4], "big") % dimensions
        sign = 1.0 if digest[4] % 2 == 0 else -1.0
        vector[index] += sign
    return vector


def _cosine(left: list[float], right: list[float]) -> float:
    dot = sum(a * b for a, b in zip(left, right))
    left_norm = math.sqrt(sum(value * value for value in left))
    right_norm = math.sqrt(sum(value * value for value in right))
    if left_norm == 0 or right_norm == 0:
        return 0.0
    return dot / (left_norm * right_norm)


def _normalize(scores: dict[str, float]) -> dict[str, float]:
    if not scores:
        return {}
    low = min(scores.values())
    high = max(scores.values())
    if high == low:
        return {key: 1.0 if value > 0 else 0.0 for key, value in scores.items()}
    return {key: (value - low) / (high - low) for key, value in scores.items()}


def _graph_scores(query: str, docs: list[tuple[StoredEvent, str]]) -> dict[str, float]:
    query_tokens = _tokens(query)
    neighbors: dict[str, set[str]] = defaultdict(set)
    doc_tokens = {stored.event.event_id: _tokens(text) for stored, text in docs}
    for tokens in doc_tokens.values():
        for token in tokens:
            neighbors[token].update(tokens - {token})
    expanded = set(query_tokens)
    for token in query_tokens:
        expanded.update(neighbors.get(token, set()))
    return {
        stored.event.event_id: float(len(doc_tokens[stored.event.event_id] & expanded))
        for stored, _ in docs
    }


def _supersession_signals(text: str) -> set[str]:
    tokens = _tokens(text)
    signals = set()
    for token in ("package", "manager", "hotel", "response", "style", "prefer"):
        if token in tokens:
            signals.add(token)
    return signals


STOPWORDS = {
    "a",
    "an",
    "and",
    "as",
    "at",
    "be",
    "before",
    "did",
    "do",
    "for",
    "her",
    "his",
    "i",
    "in",
    "is",
    "it",
    "of",
    "on",
    "or",
    "should",
    "that",
    "the",
    "this",
    "to",
    "was",
    "we",
    "what",
    "where",
    "which",
    "who",
    "with",
}
