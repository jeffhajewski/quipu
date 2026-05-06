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
class ProviderProfile:
    provider: str
    format: str
    base_url: str
    answer_model: str
    judge_model: str
    api_key_env: str | None
    embedding_model: str | None = None
    embedding_base_url: str | None = None
    embedding_batch_size: int = 32


PROVIDER_PROFILES: dict[str, ProviderProfile] = {
    "openai": ProviderProfile(
        provider="openai",
        format="openai_compatible",
        base_url="https://api.openai.com/v1",
        answer_model="gpt-4o",
        judge_model="gpt-4o",
        api_key_env="OPENAI_API_KEY",
        embedding_model="text-embedding-3-small",
    ),
    "anthropic": ProviderProfile(
        provider="anthropic",
        format="anthropic_messages",
        base_url="https://api.anthropic.com/v1",
        answer_model="claude-sonnet-4-20250514",
        judge_model="claude-sonnet-4-20250514",
        api_key_env="ANTHROPIC_API_KEY",
    ),
    "google": ProviderProfile(
        provider="google",
        format="google_gemini",
        base_url="https://generativelanguage.googleapis.com/v1beta",
        answer_model="gemini-2.0-flash",
        judge_model="gemini-2.0-flash",
        api_key_env="GOOGLE_API_KEY",
    ),
    "gemini": ProviderProfile(
        provider="google",
        format="google_gemini",
        base_url="https://generativelanguage.googleapis.com/v1beta",
        answer_model="gemini-2.0-flash",
        judge_model="gemini-2.0-flash",
        api_key_env="GOOGLE_API_KEY",
    ),
    "openrouter": ProviderProfile(
        provider="openrouter",
        format="openai_compatible",
        base_url=DEFAULT_OPENROUTER_BASE_URL,
        answer_model=DEFAULT_OPENROUTER_ANSWER_MODEL,
        judge_model=DEFAULT_OPENROUTER_JUDGE_MODEL,
        api_key_env="OPENROUTER_API_KEY",
        embedding_model=DEFAULT_OPENROUTER_EMBEDDING_MODEL,
    ),
    "azure": ProviderProfile(
        provider="azure",
        format="openai_compatible",
        base_url="",
        answer_model="gpt-4o",
        judge_model="gpt-4o",
        api_key_env="AZURE_OPENAI_API_KEY",
    ),
    "groq": ProviderProfile(
        provider="groq",
        format="openai_compatible",
        base_url="https://api.groq.com/openai/v1",
        answer_model="llama-3.3-70b-versatile",
        judge_model="llama-3.3-70b-versatile",
        api_key_env="GROQ_API_KEY",
    ),
    "ollama": ProviderProfile(
        provider="ollama",
        format="openai_compatible",
        base_url="http://localhost:11434/v1",
        answer_model="llama3.3",
        judge_model="llama3.3",
        api_key_env=None,
    ),
    "together": ProviderProfile(
        provider="together",
        format="openai_compatible",
        base_url="https://api.together.xyz/v1",
        answer_model="meta-llama/Llama-3.3-70B-Instruct-Turbo",
        judge_model="meta-llama/Llama-3.3-70B-Instruct-Turbo",
        api_key_env="TOGETHER_API_KEY",
    ),
    "mistral": ProviderProfile(
        provider="mistral",
        format="openai_compatible",
        base_url="https://api.mistral.ai/v1",
        answer_model="mistral-large-latest",
        judge_model="mistral-large-latest",
        api_key_env="MISTRAL_API_KEY",
    ),
    "deepseek": ProviderProfile(
        provider="deepseek",
        format="openai_compatible",
        base_url="https://api.deepseek.com",
        answer_model="deepseek-chat",
        judge_model="deepseek-chat",
        api_key_env="DEEPSEEK_API_KEY",
    ),
    "kimi": ProviderProfile(
        provider="kimi",
        format="openai_compatible",
        base_url="https://api.moonshot.ai/v1",
        answer_model="kimi-latest",
        judge_model="kimi-latest",
        api_key_env="MOONSHOT_API_KEY",
    ),
    "moonshot": ProviderProfile(
        provider="kimi",
        format="openai_compatible",
        base_url="https://api.moonshot.ai/v1",
        answer_model="kimi-latest",
        judge_model="kimi-latest",
        api_key_env="MOONSHOT_API_KEY",
    ),
    "cohere": ProviderProfile(
        provider="cohere",
        format="cohere_chat",
        base_url="https://api.cohere.com/v2",
        answer_model="command-a-03-2025",
        judge_model="command-a-03-2025",
        api_key_env="COHERE_API_KEY",
    ),
    "custom": ProviderProfile(
        provider="custom",
        format="openai_compatible",
        base_url="",
        answer_model="model",
        judge_model="model",
        api_key_env="QUIPU_LLM_API_KEY",
    ),
}


def supported_llm_provider_ids() -> list[str]:
    return sorted(PROVIDER_PROFILES)


@dataclass(frozen=True)
class LlmSettings:
    provider: str
    api_key: str | None
    base_url: str
    answer_model: str
    judge_model: str
    embedding_model: str | None = None
    embedding_base_url: str | None = None
    embedding_batch_size: int = 32
    app_title: str = "Quipu Evals"
    app_url: str | None = None

    @classmethod
    def from_env(cls, provider: str | None = None) -> "LlmSettings":
        provider_id = provider or _detect_provider_from_env() or "openrouter"
        profile = _profile(provider_id)
        prefix = profile.provider.upper()
        api_key = os.environ.get("QUIPU_LLM_API_KEY")
        if api_key is None and profile.api_key_env:
            api_key = os.environ.get(profile.api_key_env)
        if profile.api_key_env and not api_key:
            raise ProviderError(f"{profile.api_key_env} or QUIPU_LLM_API_KEY is required for {profile.provider}")
        base_url = (
            os.environ.get("QUIPU_LLM_BASE_URL")
            or os.environ.get(f"{prefix}_BASE_URL")
            or os.environ.get(f"{prefix}_CHAT_URL")
            or profile.base_url
        ).rstrip("/")
        return cls(
            provider=profile.provider,
            api_key=api_key,
            base_url=base_url,
            answer_model=os.environ.get("QUIPU_LLM_MODEL")
            or os.environ.get(f"{prefix}_ANSWER_MODEL")
            or os.environ.get(f"{prefix}_MODEL")
            or profile.answer_model,
            judge_model=os.environ.get("QUIPU_JUDGE_MODEL")
            or os.environ.get(f"{prefix}_JUDGE_MODEL")
            or os.environ.get(f"{prefix}_MODEL")
            or profile.judge_model,
            embedding_model=os.environ.get(f"{prefix}_EMBEDDING_MODEL") or profile.embedding_model,
            embedding_base_url=(os.environ.get(f"{prefix}_EMBEDDING_BASE_URL") or profile.embedding_base_url or base_url).rstrip("/"),
            embedding_batch_size=int(os.environ.get(f"{prefix}_EMBEDDING_BATCH_SIZE", str(profile.embedding_batch_size))),
            app_title=os.environ.get("OPENROUTER_APP_TITLE", "Quipu Evals"),
            app_url=os.environ.get("OPENROUTER_APP_URL"),
        )


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


class LlmClient:
    def __init__(
        self,
        provider: str = "openrouter",
        model: str | None = None,
        api_key: str | None = None,
        base_url: str | None = None,
        judge_model: str | None = None,
        embedding_model: str | None = None,
        settings: LlmSettings | None = None,
    ) -> None:
        profile = _profile(provider)
        self.profile = profile
        if settings is None:
            try:
                env_settings = LlmSettings.from_env(provider)
            except ProviderError:
                if api_key is None and profile.api_key_env:
                    raise
                env_settings = LlmSettings(
                    provider=profile.provider,
                    api_key=None,
                    base_url=profile.base_url,
                    answer_model=profile.answer_model,
                    judge_model=profile.judge_model,
                    embedding_model=profile.embedding_model,
                    embedding_base_url=profile.embedding_base_url or profile.base_url,
                    embedding_batch_size=profile.embedding_batch_size,
                )
            settings = LlmSettings(
                provider=profile.provider,
                api_key=api_key if api_key is not None else env_settings.api_key,
                base_url=(base_url or env_settings.base_url or profile.base_url).rstrip("/"),
                answer_model=model or env_settings.answer_model or profile.answer_model,
                judge_model=judge_model or env_settings.judge_model or profile.judge_model,
                embedding_model=embedding_model or env_settings.embedding_model or profile.embedding_model,
                embedding_base_url=env_settings.embedding_base_url,
                embedding_batch_size=env_settings.embedding_batch_size,
                app_title=env_settings.app_title,
                app_url=env_settings.app_url,
            )
        self.settings = settings
        self._judge_cache_path = _judge_cache_path(self.settings)
        self._judge_cache = _load_judge_cache(self._judge_cache_path)

    def chat_completion(
        self,
        system: str,
        user: str,
        context: str | Sequence[str] | None = None,
        *,
        temperature: float = 0.1,
        json_mode: bool = False,
        model: str | None = None,
    ) -> str:
        user_content = _join_user_context(user, context)
        payload = self._chat_payload(system, user_content, model or self.settings.answer_model, temperature, json_mode)
        response = self._post(_chat_path(self.profile, self.settings.base_url, model or self.settings.answer_model), payload)
        return _parse_chat_content(self.profile.format, response)

    def embed_batch(self, texts: Sequence[str]) -> list[list[float]]:
        return self.embed_texts(texts)

    def embed_texts(self, texts: Sequence[str]) -> list[list[float]]:
        if self.profile.format != "openai_compatible" or not self.settings.embedding_model:
            raise ProviderError(f"{self.profile.provider} does not expose an eval embedding endpoint")
        vectors: list[list[float]] = []
        batch_size = max(self.settings.embedding_batch_size, 1)
        for start in range(0, len(texts), batch_size):
            batch = list(texts[start : start + batch_size])
            if not batch:
                continue
            payload = self._post(
                _join_url(self.settings.embedding_base_url or self.settings.base_url, "/embeddings"),
                {"model": self.settings.embedding_model, "input": batch},
            )
            data = payload.get("data")
            if not isinstance(data, list):
                raise ProviderError(f"{self.profile.provider} embeddings response missing data list")
            by_index: dict[int, list[float]] = {}
            for item in data:
                if not isinstance(item, Mapping):
                    continue
                index = int(item.get("index", len(by_index)))
                embedding = item.get("embedding")
                if not isinstance(embedding, list):
                    raise ProviderError(f"{self.profile.provider} embeddings response item missing embedding")
                by_index[index] = [float(value) for value in embedding]
            if len(by_index) != len(batch):
                raise ProviderError(f"{self.profile.provider} embeddings response count did not match request")
            vectors.extend(by_index[index] for index in range(len(batch)))
        return vectors

    def generate_answer(self, question: str, contexts: Sequence[str]) -> str:
        context = "\n\n".join(f"[{index + 1}] {text}" for index, text in enumerate(contexts))
        return self.chat_completion(
            "Answer the question using only the provided retrieved memory context. "
            "Return a concise answer. If the answer is not present, return: I don't know.",
            question,
            context,
            temperature=0,
        )

    def judge_answer(self, question: str, expected_answer: str, actual_answer: str) -> LlmJudgeResult:
        cache_key = _judge_cache_key(self.settings, question, expected_answer, actual_answer)
        if cache_key in self._judge_cache:
            return self._judge_cache[cache_key]
        payload = self._chat_payload(
            "You are grading a memory benchmark answer. Return only JSON with keys "
            "correct (boolean), score (number from 0 to 1), and reason (short string).",
            f"Question: {question}\nGround truth answer: {expected_answer}\nCandidate answer: {actual_answer}",
            self.settings.judge_model,
            0,
            True,
        )
        response = self._post(_chat_path(self.profile, self.settings.base_url, self.settings.judge_model), payload)
        parsed = _parse_json_object(_parse_chat_content(self.profile.format, response))
        result = LlmJudgeResult(
            passed=bool(parsed.get("correct")),
            score=float(parsed.get("score", 1.0 if parsed.get("correct") else 0.0)),
            reason=str(parsed.get("reason", "")),
            model=self.settings.judge_model,
        )
        self._judge_cache[cache_key] = result
        _append_judge_cache(self._judge_cache_path, cache_key, result)
        return result

    def _chat_payload(self, system: str, user: str, model: str, temperature: float, json_mode: bool) -> Mapping[str, Any]:
        if self.profile.format == "anthropic_messages":
            return {
                "model": model,
                "system": system,
                "messages": [{"role": "user", "content": user}],
                "temperature": temperature,
                "max_tokens": 4096,
            }
        if self.profile.format == "google_gemini":
            return {
                "system_instruction": {"parts": [{"text": system}]},
                "contents": [{"role": "user", "parts": [{"text": user}]}],
                "generationConfig": {"temperature": temperature},
            }
        if self.profile.format == "cohere_chat":
            return {
                "model": model,
                "messages": [{"role": "system", "content": system}, {"role": "user", "content": user}],
                "temperature": temperature,
            }
        payload: dict[str, Any] = {
            "model": model,
            "messages": [{"role": "system", "content": system}, {"role": "user", "content": user}],
            "temperature": temperature,
        }
        if json_mode:
            payload["response_format"] = {"type": "json_object"}
        return payload

    def _post(self, url: str, payload: Mapping[str, Any]) -> Mapping[str, Any]:
        headers = {
            "Content-Type": "application/json",
            "User-Agent": "quipu-evals/0.1.0",
        }
        if self.profile.format == "anthropic_messages":
            headers["anthropic-version"] = "2023-06-01"
            if self.settings.api_key:
                headers["x-api-key"] = self.settings.api_key
        elif self.profile.format == "google_gemini":
            if self.settings.api_key:
                headers["x-goog-api-key"] = self.settings.api_key
        elif self.profile.provider == "azure":
            if self.settings.api_key:
                headers["api-key"] = self.settings.api_key
        elif self.settings.api_key:
            headers["Authorization"] = f"Bearer {self.settings.api_key}"
        if self.profile.provider == "openrouter":
            headers["X-Title"] = self.settings.app_title
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
            raise ProviderError(f"{self.profile.provider} request failed with HTTP {exc.code}: {body}") from exc
        except urllib.error.URLError as exc:
            raise ProviderError(f"{self.profile.provider} request failed: {exc.reason}") from exc


class OpenRouterClient(LlmClient):
    def __init__(self, settings: OpenRouterSettings | None = None) -> None:
        if settings is None:
            settings = OpenRouterSettings.from_env()
        super().__init__(
            "openrouter",
            settings=LlmSettings(
                provider="openrouter",
                api_key=settings.api_key,
                base_url=settings.base_url,
                answer_model=settings.answer_model,
                judge_model=settings.judge_model,
                embedding_model=settings.embedding_model,
                embedding_base_url=settings.base_url,
                embedding_batch_size=settings.embedding_batch_size,
                app_title=settings.app_title,
                app_url=settings.app_url,
            ),
        )


def _judge_cache_path(settings: LlmSettings) -> Path | None:
    explicit = os.environ.get("QUIPU_JUDGE_CACHE")
    if explicit:
        return Path(explicit)
    if os.environ.get("QUIPU_DISABLE_JUDGE_CACHE"):
        return None
    model_slug = re.sub(r"[^A-Za-z0-9_.-]+", "_", settings.judge_model).strip("_") or "model"
    return Path("artifacts/provider-cache") / f"{settings.provider}-{model_slug}-judge.jsonl"


def _load_judge_cache(path: Path | None) -> dict[str, LlmJudgeResult]:
    if path is None or not path.exists():
        return {}
    cache: dict[str, LlmJudgeResult] = {}
    with path.open() as handle:
        for line in handle:
            try:
                item = json.loads(line)
                key = str(item["key"])
                cache[key] = LlmJudgeResult(
                    passed=bool(item["passed"]),
                    score=float(item["score"]),
                    reason=str(item.get("reason", "")),
                    model=str(item["model"]),
                )
            except (KeyError, TypeError, ValueError, json.JSONDecodeError):
                continue
    return cache


def _judge_cache_key(settings: LlmSettings, question: str, expected_answer: str, actual_answer: str) -> str:
    payload = {
        "provider": settings.provider,
        "model": settings.judge_model,
        "question": question,
        "expectedAnswer": expected_answer,
        "actualAnswer": actual_answer,
    }
    return hashlib.sha256(json.dumps(payload, sort_keys=True, separators=(",", ":")).encode("utf-8")).hexdigest()


def _append_judge_cache(path: Path | None, key: str, result: LlmJudgeResult) -> None:
    if path is None:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a") as handle:
        handle.write(
            json.dumps(
                {
                    "key": key,
                    "passed": result.passed,
                    "score": result.score,
                    "reason": result.reason,
                    "model": result.model,
                },
                separators=(",", ":"),
            )
            + "\n"
        )


class CachedEmbeddingProvider:
    def __init__(self, client: LlmClient, cache_path: str | Path | None = None) -> None:
        self.client = client
        self.model = client.settings.embedding_model or "embedding"
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


def _profile(provider: str) -> ProviderProfile:
    normalized = provider.lower().replace("_", "-")
    aliases = {
        "azure-openai": "azure",
        "openai-compatible": "custom",
        "http": "custom",
    }
    key = aliases.get(normalized, normalized)
    if key not in PROVIDER_PROFILES:
        raise ProviderError(f"Unsupported LLM provider: {provider}")
    return PROVIDER_PROFILES[key]


def _detect_provider_from_env() -> str | None:
    for provider in ("openai", "anthropic", "google", "openrouter", "azure", "groq", "mistral", "deepseek", "kimi", "cohere"):
        env_name = PROVIDER_PROFILES[provider].api_key_env
        if env_name and os.environ.get(env_name):
            return provider
    return None


def _join_user_context(user: str, context: str | Sequence[str] | None) -> str:
    if context is None or context == "":
        return user
    if isinstance(context, str):
        context_text = context
    else:
        context_text = "\n\n".join(str(item) for item in context)
    return f"Question:\n{user}\n\nRetrieved memory context:\n{context_text}"


def _chat_path(profile: ProviderProfile, base_url: str, model: str) -> str:
    if profile.format == "anthropic_messages":
        return _join_url(base_url, "/messages")
    if profile.format == "google_gemini":
        if ":generateContent" in base_url:
            return base_url
        return _join_url(base_url, f"/models/{model}:generateContent")
    if profile.format == "cohere_chat":
        return _join_url(base_url, "/chat")
    if "chat/completions" in base_url or profile.provider == "azure":
        return base_url
    return _join_url(base_url, "/chat/completions")


def _join_url(base_url: str, path: str) -> str:
    return f"{base_url.rstrip('/')}/{path.lstrip('/')}"


def _parse_chat_content(format_name: str, payload: Mapping[str, Any]) -> str:
    if format_name == "anthropic_messages":
        content = payload.get("content")
        if not isinstance(content, list):
            raise ProviderError("Anthropic chat response missing content")
        return "\n".join(str(block.get("text", "")) for block in content if isinstance(block, Mapping)).strip()
    if format_name == "google_gemini":
        candidates = payload.get("candidates")
        if not isinstance(candidates, list) or not candidates:
            raise ProviderError("Google chat response missing candidates")
        first = candidates[0]
        if not isinstance(first, Mapping):
            raise ProviderError("Google chat response candidate is invalid")
        content = first.get("content")
        if not isinstance(content, Mapping):
            raise ProviderError("Google chat response missing content")
        parts = content.get("parts")
        if not isinstance(parts, list):
            raise ProviderError("Google chat response missing parts")
        return "\n".join(str(part.get("text", "")) for part in parts if isinstance(part, Mapping)).strip()
    if format_name == "cohere_chat":
        message = payload.get("message")
        if not isinstance(message, Mapping):
            raise ProviderError("Cohere chat response missing message")
        content = message.get("content")
        if not isinstance(content, list):
            raise ProviderError("Cohere chat response missing content")
        return "\n".join(str(block.get("text", "")) for block in content if isinstance(block, Mapping)).strip()
    return _chat_content(payload)


def _chat_content(payload: Mapping[str, Any]) -> str:
    choices = payload.get("choices")
    if not isinstance(choices, list) or not choices:
        raise ProviderError("OpenAI-compatible chat response missing choices")
    first = choices[0]
    if not isinstance(first, Mapping):
        raise ProviderError("OpenAI-compatible chat response choice is invalid")
    message = first.get("message")
    if not isinstance(message, Mapping):
        raise ProviderError("OpenAI-compatible chat response missing message")
    content = message.get("content")
    if not isinstance(content, str):
        raise ProviderError("OpenAI-compatible chat response missing content")
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
