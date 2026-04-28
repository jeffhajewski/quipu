from __future__ import annotations

from dataclasses import dataclass, field
import json
import subprocess
from typing import Any, Callable, Dict, Mapping, Optional, Sequence


JsonRpcTransport = Callable[[Mapping[str, Any]], Mapping[str, Any]]

ERROR_CODES = {
    "invalid_request",
    "unauthorized",
    "forbidden",
    "not_found",
    "conflict",
    "provider_error",
    "embedding_error",
    "llm_error",
    "storage_error",
    "schema_error",
    "migration_required",
    "version_mismatch",
    "rate_limited",
    "cancelled",
    "internal_error",
}

SUPPORTED_METHODS = {
    "system.health",
    "memory.remember",
    "memory.retrieve",
    "memory.search",
    "memory.inspect",
    "memory.forget",
    "memory.feedback",
    "memory.core.get",
    "memory.core.update",
}

SCOPE_KEYS = {"tenantId", "userId", "agentId", "projectId"}
MESSAGE_ROLES = {"system", "developer", "user", "assistant", "tool"}
NEEDS = {"core", "current_facts", "preferences", "procedural", "recent_episodes", "raw"}


class QuipuProtocolError(ValueError):
    """Raised when client input does not match the public protocol shape."""


class QuipuRpcError(RuntimeError):
    """Raised when the daemon returns a JSON-RPC error response."""

    def __init__(self, code: str, message: str, details: Optional[Mapping[str, Any]] = None) -> None:
        super().__init__(message)
        self.code = code
        self.details = dict(details or {})


class QuipuStdioTransport:
    """Persistent NDJSON transport for a local `quipu serve-stdio` process."""

    def __init__(self, command: Sequence[str]) -> None:
        self.command = list(command)
        self.process: Optional[subprocess.Popen[str]] = None

    def __call__(self, request: Mapping[str, Any]) -> Mapping[str, Any]:
        process = self._ensure_process()
        if process.stdin is None or process.stdout is None:
            raise RuntimeError("Quipu process stdio is unavailable")
        process.stdin.write(json.dumps(request, separators=(",", ":")) + "\n")
        process.stdin.flush()
        line = process.stdout.readline()
        if not line:
            stderr = process.stderr.read() if process.stderr is not None else ""
            raise RuntimeError(f"Quipu process exited without a response: {stderr}")
        response = json.loads(line)
        if not isinstance(response, Mapping):
            raise RuntimeError("Quipu process returned a non-object response")
        return response

    def close(self) -> None:
        if self.process is None:
            return
        if self.process.stdin is not None:
            self.process.stdin.close()
        try:
            self.process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            self.process.terminate()
            self.process.wait(timeout=2)
        if self.process.stdout is not None:
            self.process.stdout.close()
        if self.process.stderr is not None:
            self.process.stderr.close()
        self.process = None

    def _ensure_process(self) -> subprocess.Popen[str]:
        if self.process is None:
            self.process = subprocess.Popen(
                self.command,
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                bufsize=1,
            )
        return self.process


def _ensure_object(value: Any, label: str) -> Mapping[str, Any]:
    if not isinstance(value, Mapping):
        raise QuipuProtocolError(f"{label} must be an object")
    return value


def _reject_extra(value: Mapping[str, Any], allowed: set[str], label: str) -> None:
    extras = sorted(set(value) - allowed)
    if extras:
        raise QuipuProtocolError(f"{label} has unsupported field(s): {', '.join(extras)}")


def _require_non_empty_string(value: Any, label: str) -> None:
    if not isinstance(value, str) or not value:
        raise QuipuProtocolError(f"{label} must be a non-empty string")


def _optional_string(value: Mapping[str, Any], key: str, label: str) -> None:
    if key in value and value[key] is not None and not isinstance(value[key], str):
        raise QuipuProtocolError(f"{label}.{key} must be a string or null")


def _optional_bool(value: Mapping[str, Any], key: str, label: str) -> None:
    if key in value and not isinstance(value[key], bool):
        raise QuipuProtocolError(f"{label}.{key} must be a boolean")


def _validate_scope(value: Any, label: str = "scope") -> None:
    scope = _ensure_object(value, label)
    _reject_extra(scope, SCOPE_KEYS, label)
    for key in SCOPE_KEYS:
        _optional_string(scope, key, label)


def _validate_qid(value: Any, label: str) -> None:
    if not isinstance(value, str) or not value.startswith("q_"):
        raise QuipuProtocolError(f"{label} must be a qid string")


def _validate_qid_list(value: Any, label: str) -> None:
    if not isinstance(value, list):
        raise QuipuProtocolError(f"{label} must be a list")
    for index, qid in enumerate(value):
        _validate_qid(qid, f"{label}[{index}]")


def _validate_metadata(value: Any, label: str) -> None:
    _ensure_object(value, label)


def _validate_system_health(params: Mapping[str, Any]) -> None:
    if params:
        raise QuipuProtocolError("system.health params must be empty")


def _validate_remember(params: Mapping[str, Any]) -> None:
    allowed = {
        "sessionId",
        "scope",
        "messages",
        "toolCalls",
        "observations",
        "metadata",
        "extract",
        "importanceHint",
        "privacyClass",
        "idempotencyKey",
    }
    _reject_extra(params, allowed, "memory.remember params")
    if "messages" not in params or not isinstance(params["messages"], list) or not params["messages"]:
        raise QuipuProtocolError("memory.remember messages must be a non-empty list")
    _optional_string(params, "sessionId", "memory.remember params")
    _optional_string(params, "idempotencyKey", "memory.remember params")
    _optional_bool(params, "extract", "memory.remember params")
    if "scope" in params:
        _validate_scope(params["scope"])
    if "metadata" in params:
        _validate_metadata(params["metadata"], "metadata")
    if "toolCalls" in params and not isinstance(params["toolCalls"], list):
        raise QuipuProtocolError("toolCalls must be a list")
    if "observations" in params and not isinstance(params["observations"], list):
        raise QuipuProtocolError("observations must be a list")
    if "importanceHint" in params:
        hint = params["importanceHint"]
        if not isinstance(hint, (int, float)) or hint < 0 or hint > 1:
            raise QuipuProtocolError("importanceHint must be between 0 and 1")
    if "privacyClass" in params and params["privacyClass"] not in {"public", "normal", "private", "secret"}:
        raise QuipuProtocolError("privacyClass is invalid")
    for index, message in enumerate(params["messages"]):
        label = f"messages[{index}]"
        message_obj = _ensure_object(message, label)
        _reject_extra(message_obj, {"role", "content", "createdAt"}, label)
        if message_obj.get("role") not in MESSAGE_ROLES:
            raise QuipuProtocolError(f"{label}.role is invalid")
        _require_non_empty_string(message_obj.get("content"), f"{label}.content")
        _optional_string(message_obj, "createdAt", label)


def _validate_retrieve(params: Mapping[str, Any]) -> None:
    allowed = {"query", "task", "scope", "budgetTokens", "needs", "time", "options"}
    _reject_extra(params, allowed, "memory.retrieve params")
    _require_non_empty_string(params.get("query"), "query")
    _optional_string(params, "task", "memory.retrieve params")
    if "scope" in params:
        _validate_scope(params["scope"])
    if "budgetTokens" in params:
        budget = params["budgetTokens"]
        if not isinstance(budget, int) or budget < 1:
            raise QuipuProtocolError("budgetTokens must be a positive integer")
    if "needs" in params:
        needs = params["needs"]
        if not isinstance(needs, list) or any(need not in NEEDS for need in needs):
            raise QuipuProtocolError("needs contains an unsupported value")
    if "time" in params:
        time = _ensure_object(params["time"], "time")
        _reject_extra(time, {"validAt", "eventWindowStart", "eventWindowEnd"}, "time")
        for key in ("validAt", "eventWindowStart", "eventWindowEnd"):
            _optional_string(time, key, "time")
    if "options" in params:
        options = _ensure_object(params["options"], "options")
        _reject_extra(
            options,
            {"includeEvidence", "includeDebug", "logTrace", "abstainIfWeak", "format"},
            "options",
        )
        for key in ("includeEvidence", "includeDebug", "logTrace", "abstainIfWeak"):
            _optional_bool(options, key, "options")
        if "format" in options and options["format"] not in {"prompt", "json"}:
            raise QuipuProtocolError("options.format is invalid")


def _validate_search(params: Mapping[str, Any]) -> None:
    allowed = {"query", "mode", "labels", "scope", "limit", "includeDeleted"}
    _reject_extra(params, allowed, "memory.search params")
    _require_non_empty_string(params.get("query"), "query")
    if "mode" in params and params["mode"] not in {"fts", "vector", "hybrid", "graph"}:
        raise QuipuProtocolError("mode is invalid")
    if "labels" in params and not isinstance(params["labels"], list):
        raise QuipuProtocolError("labels must be a list")
    if "scope" in params:
        _validate_scope(params["scope"])
    if "limit" in params:
        limit = params["limit"]
        if not isinstance(limit, int) or limit < 1 or limit > 100:
            raise QuipuProtocolError("limit must be between 1 and 100")
    _optional_bool(params, "includeDeleted", "memory.search params")


def _validate_inspect(params: Mapping[str, Any]) -> None:
    allowed = {"qid", "includeProvenance", "includeDependents", "includeRaw"}
    _reject_extra(params, allowed, "memory.inspect params")
    _validate_qid(params.get("qid"), "qid")
    for key in ("includeProvenance", "includeDependents", "includeRaw"):
        _optional_bool(params, key, "memory.inspect params")


def _validate_forget(params: Mapping[str, Any]) -> None:
    allowed = {"mode", "selector", "propagate", "dryRun", "reason"}
    _reject_extra(params, allowed, "memory.forget params")
    if params.get("mode") not in {"hard_delete", "redact", "expire"}:
        raise QuipuProtocolError("mode is invalid")
    selector = _ensure_object(params.get("selector"), "selector")
    _reject_extra(selector, {"qids", "query", "scope", "timeWindow"}, "selector")
    if "qids" in selector:
        _validate_qid_list(selector["qids"], "selector.qids")
    _optional_string(selector, "query", "selector")
    if "scope" in selector:
        _validate_scope(selector["scope"])
    if "timeWindow" in selector and selector["timeWindow"] is not None:
        window = _ensure_object(selector["timeWindow"], "timeWindow")
        _reject_extra(window, {"start", "end"}, "timeWindow")
        _optional_string(window, "start", "timeWindow")
        _optional_string(window, "end", "timeWindow")
    _optional_bool(params, "propagate", "memory.forget params")
    _optional_bool(params, "dryRun", "memory.forget params")
    _optional_string(params, "reason", "memory.forget params")


def _validate_feedback(params: Mapping[str, Any]) -> None:
    allowed = {"retrievalId", "rating", "usedItemQids", "ignoredItemQids", "corrections", "metadata"}
    _reject_extra(params, allowed, "memory.feedback params")
    _validate_qid(params.get("retrievalId"), "retrievalId")
    if params.get("rating") not in {"helpful", "not_helpful", "harmful"}:
        raise QuipuProtocolError("rating is invalid")
    for key in ("usedItemQids", "ignoredItemQids"):
        if key in params:
            _validate_qid_list(params[key], key)
    if "corrections" in params:
        corrections = params["corrections"]
        if not isinstance(corrections, list):
            raise QuipuProtocolError("corrections must be a list")
        for index, correction in enumerate(corrections):
            item = _ensure_object(correction, f"corrections[{index}]")
            _reject_extra(item, {"type", "text"}, f"corrections[{index}]")
            _require_non_empty_string(item.get("type"), f"corrections[{index}].type")
            _require_non_empty_string(item.get("text"), f"corrections[{index}].text")
    if "metadata" in params:
        _validate_metadata(params["metadata"], "metadata")


def _validate_core_get(params: Mapping[str, Any]) -> None:
    allowed = {"scope", "blockKey"}
    _reject_extra(params, allowed, "memory.core.get params")
    if "scope" not in params:
        raise QuipuProtocolError("scope is required")
    _validate_scope(params["scope"])
    _optional_string(params, "blockKey", "memory.core.get params")


def _validate_core_update(params: Mapping[str, Any]) -> None:
    allowed = {"blockKey", "scope", "text", "mode", "evidenceQids", "managedBy"}
    _reject_extra(params, allowed, "memory.core.update params")
    _require_non_empty_string(params.get("blockKey"), "blockKey")
    if "scope" not in params:
        raise QuipuProtocolError("scope is required")
    _validate_scope(params["scope"])
    if not isinstance(params.get("text"), str):
        raise QuipuProtocolError("text must be a string")
    if params.get("mode") not in {"replace", "append"}:
        raise QuipuProtocolError("mode is invalid")
    if params.get("managedBy") not in {"user", "system"}:
        raise QuipuProtocolError("managedBy is invalid")
    if "evidenceQids" in params:
        _validate_qid_list(params["evidenceQids"], "evidenceQids")


VALIDATORS = {
    "system.health": _validate_system_health,
    "memory.remember": _validate_remember,
    "memory.retrieve": _validate_retrieve,
    "memory.search": _validate_search,
    "memory.inspect": _validate_inspect,
    "memory.forget": _validate_forget,
    "memory.feedback": _validate_feedback,
    "memory.core.get": _validate_core_get,
    "memory.core.update": _validate_core_update,
}


def validate_rpc_params(method: str, params: Optional[Mapping[str, Any]] = None) -> None:
    if method not in VALIDATORS:
        raise QuipuProtocolError(f"unsupported method: {method}")
    VALIDATORS[method](_ensure_object(params or {}, "params"))


def validate_json_rpc_request(request: Mapping[str, Any]) -> None:
    envelope = _ensure_object(request, "request")
    _reject_extra(envelope, {"jsonrpc", "id", "method", "params"}, "request")
    if envelope.get("jsonrpc") != "2.0":
        raise QuipuProtocolError("request.jsonrpc must be 2.0")
    if "id" not in envelope:
        raise QuipuProtocolError("request.id is required")
    method = envelope.get("method")
    if not isinstance(method, str):
        raise QuipuProtocolError("request.method must be a string")
    validate_rpc_params(method, envelope.get("params", {}))


def validate_json_rpc_response(response: Mapping[str, Any]) -> None:
    envelope = _ensure_object(response, "response")
    _reject_extra(envelope, {"jsonrpc", "id", "result", "error"}, "response")
    if envelope.get("jsonrpc") != "2.0":
        raise QuipuProtocolError("response.jsonrpc must be 2.0")
    if "id" not in envelope:
        raise QuipuProtocolError("response.id is required")
    has_result = "result" in envelope
    has_error = "error" in envelope
    if has_result == has_error:
        raise QuipuProtocolError("response must contain exactly one of result or error")
    if has_result:
        _ensure_object(envelope["result"], "result")
    if has_error:
        error = _ensure_object(envelope["error"], "error")
        _reject_extra(error, {"code", "message", "details"}, "error")
        if error.get("code") not in ERROR_CODES:
            raise QuipuProtocolError("error.code is invalid")
        _require_non_empty_string(error.get("message"), "error.message")
        if "details" in error:
            _ensure_object(error["details"], "error.details")


@dataclass
class Quipu:
    """Thin Quipu SDK client that validates protocol shape and calls a transport."""

    transport: Optional[JsonRpcTransport] = None
    _next_id: int = field(default=1, init=False, repr=False)

    @classmethod
    def local(cls, command: Optional[Sequence[str]] = None) -> "Quipu":
        if command is None:
            return cls()
        return cls.stdio(command)

    @classmethod
    def stdio(cls, command: Sequence[str]) -> "Quipu":
        return cls(transport=QuipuStdioTransport(command))

    def close(self) -> None:
        close = getattr(self.transport, "close", None)
        if callable(close):
            close()

    def __enter__(self) -> "Quipu":
        return self

    def __exit__(self, exc_type: object, exc: object, tb: object) -> None:
        self.close()

    def call(self, method: str, params: Optional[Mapping[str, Any]] = None) -> Mapping[str, Any]:
        validate_rpc_params(method, params or {})
        if self.transport is None:
            raise NotImplementedError("TODO: connect to Quipu daemon")
        request: Dict[str, Any] = {
            "jsonrpc": "2.0",
            "id": f"py_{self._next_id}",
            "method": method,
            "params": dict(params or {}),
        }
        self._next_id += 1
        response = self.transport(request)
        validate_json_rpc_response(response)
        if "error" in response:
            error = response["error"]
            raise QuipuRpcError(error["code"], error["message"], error.get("details"))
        return response["result"]

    def health(self) -> Mapping[str, Any]:
        return self.call("system.health", {})

    def remember(self, **kwargs: Any) -> Mapping[str, Any]:
        return self.call("memory.remember", kwargs)

    def retrieve(self, **kwargs: Any) -> Mapping[str, Any]:
        return self.call("memory.retrieve", kwargs)

    def search(self, **kwargs: Any) -> Mapping[str, Any]:
        return self.call("memory.search", kwargs)

    def inspect(self, **kwargs: Any) -> Mapping[str, Any]:
        return self.call("memory.inspect", kwargs)

    def forget(self, **kwargs: Any) -> Mapping[str, Any]:
        return self.call("memory.forget", kwargs)

    def feedback(self, **kwargs: Any) -> Mapping[str, Any]:
        return self.call("memory.feedback", kwargs)

    def core_get(self, **kwargs: Any) -> Mapping[str, Any]:
        return self.call("memory.core.get", kwargs)

    def core_update(self, **kwargs: Any) -> Mapping[str, Any]:
        return self.call("memory.core.update", kwargs)


__all__ = [
    "Quipu",
    "QuipuProtocolError",
    "QuipuRpcError",
    "QuipuStdioTransport",
    "SUPPORTED_METHODS",
    "validate_json_rpc_request",
    "validate_json_rpc_response",
    "validate_rpc_params",
]
