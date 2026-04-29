from __future__ import annotations

from dataclasses import dataclass
import hashlib
import json
import os
from pathlib import Path
import re
from typing import Any, Mapping, Sequence
import urllib.error
import urllib.request


DEFAULT_OPENROUTER_BASE_URL = "https://openrouter.ai/api/v1"
DEFAULT_OPENROUTER_EMBEDDING_MODEL = "openai/text-embedding-3-small"
DEFAULT_OPENROUTER_ANSWER_MODEL = "openai/gpt-4o"
DEFAULT_OPENROUTER_JUDGE_MODEL = "openai/gpt-4o"


class ProviderError(RuntimeError):
    pass


@dataclass(frozen=True)
class LlmJudgeResult:
    passed: bool
    score: float
    reason: str
    model: str


@dataclass(frozen=True)
class OpenRouterSettings:
    api_key: str
    base_url: str = DEFAULT_OPENROUTER_BASE_URL
    embedding_model: str = DEFAULT_OPENROUTER_EMBEDDING_MODEL
    answer_model: str = DEFAULT_OPENROUTER_ANSWER_MODEL
    judge_model: str = DEFAULT_OPENROUTER_JUDGE_MODEL
    embedding_batch_size: int = 32
    app_title: str = "Quipu Evals"
    app_url: str | None = None

    @classmethod
    def from_env(cls) -> "OpenRouterSettings":
        api_key = os.environ.get("OPENROUTER_API_KEY")
        if not api_key:
            raise ProviderError("OPENROUTER_API_KEY is required for OpenRouter-backed eval providers")
        return cls(
            api_key=api_key,
            base_url=os.environ.get("OPENROUTER_BASE_URL", DEFAULT_OPENROUTER_BASE_URL).rstrip("/"),
            embedding_model=os.environ.get("OPENROUTER_EMBEDDING_MODEL", DEFAULT_OPENROUTER_EMBEDDING_MODEL),
            answer_model=os.environ.get("OPENROUTER_ANSWER_MODEL", DEFAULT_OPENROUTER_ANSWER_MODEL),
            judge_model=os.environ.get("OPENROUTER_JUDGE_MODEL", DEFAULT_OPENROUTER_JUDGE_MODEL),
            embedding_batch_size=int(os.environ.get("OPENROUTER_EMBEDDING_BATCH_SIZE", "32")),
            app_title=os.environ.get("OPENROUTER_APP_TITLE", "Quipu Evals"),
            app_url=os.environ.get("OPENROUTER_APP_URL"),
        )


class OpenRouterClient:
    def __init__(self, settings: OpenRouterSettings | None = None) -> None:
        self.settings = settings or OpenRouterSettings.from_env()

    def embed_texts(self, texts: Sequence[str]) -> list[list[float]]:
        vectors: list[list[float]] = []
        batch_size = max(self.settings.embedding_batch_size, 1)
        for start in range(0, len(texts), batch_size):
            batch = list(texts[start : start + batch_size])
            if not batch:
                continue
            payload = self._post(
                "/embeddings",
                {
                    "model": self.settings.embedding_model,
                    "input": batch,
                },
            )
            data = payload.get("data")
            if not isinstance(data, list):
                raise ProviderError("OpenRouter embeddings response missing data list")
            by_index: dict[int, list[float]] = {}
            for item in data:
                if not isinstance(item, Mapping):
                    continue
                index = int(item.get("index", len(by_index)))
                embedding = item.get("embedding")
                if not isinstance(embedding, list):
                    raise ProviderError("OpenRouter embeddings response item missing embedding")
                by_index[index] = [float(value) for value in embedding]
            if len(by_index) != len(batch):
                raise ProviderError("OpenRouter embeddings response count did not match request")
            vectors.extend(by_index[index] for index in range(len(batch)))
        return vectors

    def generate_answer(self, question: str, contexts: Sequence[str]) -> str:
        context = "\n\n".join(f"[{index + 1}] {text}" for index, text in enumerate(contexts))
        payload = self._post(
            "/chat/completions",
            {
                "model": self.settings.answer_model,
                "temperature": 0,
                "messages": [
                    {
                        "role": "system",
                        "content": (
                            "Answer the question using only the provided retrieved memory context. "
                            "Return a concise answer. If the answer is not present, return: I don't know."
                        ),
                    },
                    {
                        "role": "user",
                        "content": f"Question:\n{question}\n\nRetrieved memory context:\n{context}",
                    },
                ],
            },
        )
        return _chat_content(payload)

    def judge_answer(self, question: str, expected_answer: str, actual_answer: str) -> LlmJudgeResult:
        payload = self._post(
            "/chat/completions",
            {
                "model": self.settings.judge_model,
                "temperature": 0,
                "messages": [
                    {
                        "role": "system",
                        "content": (
                            "You are grading a memory benchmark answer. Return only JSON with keys "
                            "correct (boolean), score (number from 0 to 1), and reason (short string)."
                        ),
                    },
                    {
                        "role": "user",
                        "content": (
                            f"Question: {question}\n"
                            f"Ground truth answer: {expected_answer}\n"
                            f"Candidate answer: {actual_answer}"
                        ),
                    },
                ],
            },
        )
        parsed = _parse_json_object(_chat_content(payload))
        return LlmJudgeResult(
            passed=bool(parsed.get("correct")),
            score=float(parsed.get("score", 1.0 if parsed.get("correct") else 0.0)),
            reason=str(parsed.get("reason", "")),
            model=self.settings.judge_model,
        )

    def _post(self, path: str, payload: Mapping[str, Any]) -> Mapping[str, Any]:
        url = f"{self.settings.base_url}{path}"
        headers = {
            "Authorization": f"Bearer {self.settings.api_key}",
            "Content-Type": "application/json",
            "X-Title": self.settings.app_title,
        }
        if self.settings.app_url:
            headers["HTTP-Referer"] = self.settings.app_url
        request = urllib.request.Request(
            url,
            data=json.dumps(payload).encode("utf-8"),
            headers=headers,
            method="POST",
        )
        try:
            with urllib.request.urlopen(request, timeout=120) as response:
                return json.loads(response.read().decode("utf-8"))
        except urllib.error.HTTPError as exc:
            body = exc.read().decode("utf-8", errors="replace")
            raise ProviderError(f"OpenRouter request failed with HTTP {exc.code}: {body}") from exc
        except urllib.error.URLError as exc:
            raise ProviderError(f"OpenRouter request failed: {exc.reason}") from exc


class CachedEmbeddingProvider:
    def __init__(self, client: OpenRouterClient, cache_path: str | Path | None = None) -> None:
        self.client = client
        self.model = client.settings.embedding_model
        self.cache_path = Path(cache_path) if cache_path else None
        self._cache: dict[str, list[float]] = {}
        if self.cache_path and self.cache_path.exists():
            with self.cache_path.open() as handle:
                for line in handle:
                    if not line.strip():
                        continue
                    item = json.loads(line)
                    key = item.get("key")
                    vector = item.get("embedding")
                    if isinstance(key, str) and isinstance(vector, list):
                        self._cache[key] = [float(value) for value in vector]

    def embed_texts(self, texts: Sequence[str]) -> list[list[float]]:
        keys = [self._key(text) for text in texts]
        missing_texts: list[str] = []
        missing_keys: list[str] = []
        seen_missing: set[str] = set()
        for key, text in zip(keys, texts):
            if key in self._cache or key in seen_missing:
                continue
            seen_missing.add(key)
            missing_keys.append(key)
            missing_texts.append(text)
        if missing_texts:
            vectors = self.client.embed_texts(missing_texts)
            for key, vector in zip(missing_keys, vectors):
                self._cache[key] = vector
            self._append_cache(missing_keys)
        return [self._cache[key] for key in keys]

    def _key(self, text: str) -> str:
        digest = hashlib.sha256(text.encode("utf-8")).hexdigest()
        return f"{self.model}:{digest}"

    def _append_cache(self, keys: Sequence[str]) -> None:
        if not self.cache_path:
            return
        self.cache_path.parent.mkdir(parents=True, exist_ok=True)
        with self.cache_path.open("a") as handle:
            for key in keys:
                handle.write(json.dumps({"key": key, "embedding": self._cache[key]}, separators=(",", ":")) + "\n")


def openrouter_providers_from_env(cache_path: str | Path | None = None) -> tuple[CachedEmbeddingProvider, OpenRouterClient]:
    client = OpenRouterClient(OpenRouterSettings.from_env())
    return CachedEmbeddingProvider(client, cache_path=cache_path), client


def _chat_content(payload: Mapping[str, Any]) -> str:
    choices = payload.get("choices")
    if not isinstance(choices, list) or not choices:
        raise ProviderError("OpenRouter chat response missing choices")
    first = choices[0]
    if not isinstance(first, Mapping):
        raise ProviderError("OpenRouter chat response choice is invalid")
    message = first.get("message")
    if not isinstance(message, Mapping):
        raise ProviderError("OpenRouter chat response missing message")
    content = message.get("content")
    if not isinstance(content, str):
        raise ProviderError("OpenRouter chat response missing content")
    return content.strip()


def _parse_json_object(text: str) -> Mapping[str, Any]:
    stripped = text.strip()
    if stripped.startswith("```"):
        stripped = re.sub(r"^```(?:json)?\s*", "", stripped)
        stripped = re.sub(r"\s*```$", "", stripped)
    try:
        parsed = json.loads(stripped)
    except json.JSONDecodeError:
        match = re.search(r"\{.*\}", stripped, flags=re.DOTALL)
        if not match:
            raise ProviderError(f"Could not parse judge JSON: {text}")
        parsed = json.loads(match.group(0))
    if not isinstance(parsed, Mapping):
        raise ProviderError("Judge response JSON was not an object")
    return parsed
