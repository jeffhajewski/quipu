export type JsonValue =
  | null
  | boolean
  | number
  | string
  | JsonValue[]
  | { [key: string]: JsonValue };

export type JsonObject = { [key: string]: JsonValue };
export type JsonRpcId = string | number | null;

export type QuipuScope = {
  tenantId?: string | null;
  userId?: string | null;
  agentId?: string | null;
  projectId?: string | null;
};

export type QuipuMethod =
  | "system.health"
  | "memory.remember"
  | "memory.retrieve"
  | "memory.search"
  | "memory.inspect"
  | "memory.forget"
  | "memory.feedback"
  | "memory.core.get"
  | "memory.core.update";

export type JsonRpcRequest = {
  jsonrpc: "2.0";
  id: JsonRpcId;
  method: QuipuMethod;
  params: JsonObject;
};

export type JsonRpcError = {
  code: string;
  message: string;
  details?: JsonObject;
};

export type JsonRpcResponse =
  | { jsonrpc: "2.0"; id: JsonRpcId; result: JsonObject }
  | { jsonrpc: "2.0"; id: JsonRpcId; error: JsonRpcError };

export type QuipuTransport = (request: JsonRpcRequest) => Promise<JsonRpcResponse> | JsonRpcResponse;

export type RememberRequest = {
  sessionId?: string;
  scope?: QuipuScope;
  messages: Array<{ role: string; content: string; createdAt?: string }>;
  toolCalls?: JsonValue[];
  observations?: JsonValue[];
  metadata?: JsonObject;
  extract?: boolean;
  importanceHint?: number;
  privacyClass?: "public" | "normal" | "private" | "secret";
  idempotencyKey?: string;
};

export type RetrieveRequest = {
  query: string;
  task?: string;
  scope?: QuipuScope;
  budgetTokens?: number;
  needs?: string[];
  time?: {
    validAt?: string | null;
    eventWindowStart?: string | null;
    eventWindowEnd?: string | null;
  };
  options?: {
    includeEvidence?: boolean;
    includeDebug?: boolean;
    logTrace?: boolean;
    abstainIfWeak?: boolean;
    format?: "prompt" | "json";
  };
};

const ERROR_CODES = new Set([
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
]);

export const SUPPORTED_METHODS: QuipuMethod[] = [
  "system.health",
  "memory.remember",
  "memory.retrieve",
  "memory.search",
  "memory.inspect",
  "memory.forget",
  "memory.feedback",
  "memory.core.get",
  "memory.core.update",
];

const METHOD_SET = new Set<string>(SUPPORTED_METHODS);
const SCOPE_KEYS = new Set(["tenantId", "userId", "agentId", "projectId"]);
const MESSAGE_ROLES = new Set(["system", "developer", "user", "assistant", "tool"]);
const NEEDS = new Set(["core", "current_facts", "preferences", "procedural", "recent_episodes", "raw"]);

export class QuipuProtocolError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "QuipuProtocolError";
  }
}

export class QuipuRpcError extends Error {
  readonly code: string;
  readonly details?: JsonObject;

  constructor(code: string, message: string, details?: JsonObject) {
    super(message);
    this.name = "QuipuRpcError";
    this.code = code;
    this.details = details;
  }
}

function assertObject(value: unknown, label: string): asserts value is Record<string, unknown> {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw new QuipuProtocolError(`${label} must be an object`);
  }
}

function rejectExtra(value: Record<string, unknown>, allowed: Set<string>, label: string): void {
  const extras = Object.keys(value).filter((key) => !allowed.has(key));
  if (extras.length > 0) {
    throw new QuipuProtocolError(`${label} has unsupported field(s): ${extras.join(", ")}`);
  }
}

function requireNonEmptyString(value: unknown, label: string): void {
  if (typeof value !== "string" || value.length === 0) {
    throw new QuipuProtocolError(`${label} must be a non-empty string`);
  }
}

function optionalString(value: Record<string, unknown>, key: string, label: string): void {
  if (key in value && value[key] !== null && typeof value[key] !== "string") {
    throw new QuipuProtocolError(`${label}.${key} must be a string or null`);
  }
}

function optionalBoolean(value: Record<string, unknown>, key: string, label: string): void {
  if (key in value && typeof value[key] !== "boolean") {
    throw new QuipuProtocolError(`${label}.${key} must be a boolean`);
  }
}

function validateScope(value: unknown, label = "scope"): void {
  assertObject(value, label);
  rejectExtra(value, SCOPE_KEYS, label);
  for (const key of SCOPE_KEYS) {
    optionalString(value, key, label);
  }
}

function validateQid(value: unknown, label: string): void {
  if (typeof value !== "string" || !value.startsWith("q_")) {
    throw new QuipuProtocolError(`${label} must be a qid string`);
  }
}

function validateQidList(value: unknown, label: string): void {
  if (!Array.isArray(value)) {
    throw new QuipuProtocolError(`${label} must be a list`);
  }
  value.forEach((qid, index) => validateQid(qid, `${label}[${index}]`));
}

function validateMetadata(value: unknown, label: string): void {
  assertObject(value, label);
}

function validateSystemHealth(params: Record<string, unknown>): void {
  if (Object.keys(params).length !== 0) {
    throw new QuipuProtocolError("system.health params must be empty");
  }
}

function validateRemember(params: Record<string, unknown>): void {
  rejectExtra(
    params,
    new Set([
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
    ]),
    "memory.remember params",
  );
  const messages = params.messages;
  if (!Array.isArray(messages) || messages.length === 0) {
    throw new QuipuProtocolError("memory.remember messages must be a non-empty list");
  }
  optionalString(params, "sessionId", "memory.remember params");
  optionalString(params, "idempotencyKey", "memory.remember params");
  optionalBoolean(params, "extract", "memory.remember params");
  if ("scope" in params) validateScope(params.scope);
  if ("metadata" in params) validateMetadata(params.metadata, "metadata");
  if ("toolCalls" in params && !Array.isArray(params.toolCalls)) {
    throw new QuipuProtocolError("toolCalls must be a list");
  }
  if ("observations" in params && !Array.isArray(params.observations)) {
    throw new QuipuProtocolError("observations must be a list");
  }
  if ("importanceHint" in params) {
    const hint = params.importanceHint;
    if (typeof hint !== "number" || hint < 0 || hint > 1) {
      throw new QuipuProtocolError("importanceHint must be between 0 and 1");
    }
  }
  if (
    "privacyClass" in params &&
    !["public", "normal", "private", "secret"].includes(String(params.privacyClass))
  ) {
    throw new QuipuProtocolError("privacyClass is invalid");
  }
  messages.forEach((message, index) => {
    const label = `messages[${index}]`;
    assertObject(message, label);
    rejectExtra(message, new Set(["role", "content", "createdAt"]), label);
    if (!MESSAGE_ROLES.has(String(message.role))) {
      throw new QuipuProtocolError(`${label}.role is invalid`);
    }
    requireNonEmptyString(message.content, `${label}.content`);
    optionalString(message, "createdAt", label);
  });
}

function validateRetrieve(params: Record<string, unknown>): void {
  rejectExtra(params, new Set(["query", "task", "scope", "budgetTokens", "needs", "time", "options"]), "memory.retrieve params");
  requireNonEmptyString(params.query, "query");
  optionalString(params, "task", "memory.retrieve params");
  if ("scope" in params) validateScope(params.scope);
  if ("budgetTokens" in params) {
    const budget = params.budgetTokens;
    if (!Number.isInteger(budget) || Number(budget) < 1) {
      throw new QuipuProtocolError("budgetTokens must be a positive integer");
    }
  }
  if ("needs" in params) {
    if (!Array.isArray(params.needs) || params.needs.some((need) => !NEEDS.has(String(need)))) {
      throw new QuipuProtocolError("needs contains an unsupported value");
    }
  }
  if ("time" in params) {
    assertObject(params.time, "time");
    rejectExtra(params.time, new Set(["validAt", "eventWindowStart", "eventWindowEnd"]), "time");
    optionalString(params.time, "validAt", "time");
    optionalString(params.time, "eventWindowStart", "time");
    optionalString(params.time, "eventWindowEnd", "time");
  }
  if ("options" in params) {
    assertObject(params.options, "options");
    rejectExtra(
      params.options,
      new Set(["includeEvidence", "includeDebug", "logTrace", "abstainIfWeak", "format"]),
      "options",
    );
    for (const key of ["includeEvidence", "includeDebug", "logTrace", "abstainIfWeak"]) {
      optionalBoolean(params.options, key, "options");
    }
    if ("format" in params.options && !["prompt", "json"].includes(String(params.options.format))) {
      throw new QuipuProtocolError("options.format is invalid");
    }
  }
}

function validateSearch(params: Record<string, unknown>): void {
  rejectExtra(params, new Set(["query", "mode", "labels", "scope", "limit", "includeDeleted"]), "memory.search params");
  requireNonEmptyString(params.query, "query");
  if ("mode" in params && !["fts", "vector", "hybrid", "graph"].includes(String(params.mode))) {
    throw new QuipuProtocolError("mode is invalid");
  }
  if ("labels" in params && !Array.isArray(params.labels)) {
    throw new QuipuProtocolError("labels must be a list");
  }
  if ("scope" in params) validateScope(params.scope);
  if ("limit" in params && (!Number.isInteger(params.limit) || Number(params.limit) < 1 || Number(params.limit) > 100)) {
    throw new QuipuProtocolError("limit must be between 1 and 100");
  }
  optionalBoolean(params, "includeDeleted", "memory.search params");
}

function validateInspect(params: Record<string, unknown>): void {
  rejectExtra(params, new Set(["qid", "includeProvenance", "includeDependents", "includeRaw"]), "memory.inspect params");
  validateQid(params.qid, "qid");
  for (const key of ["includeProvenance", "includeDependents", "includeRaw"]) {
    optionalBoolean(params, key, "memory.inspect params");
  }
}

function validateForget(params: Record<string, unknown>): void {
  rejectExtra(params, new Set(["mode", "selector", "propagate", "dryRun", "reason"]), "memory.forget params");
  if (!["hard_delete", "redact", "expire"].includes(String(params.mode))) {
    throw new QuipuProtocolError("mode is invalid");
  }
  assertObject(params.selector, "selector");
  rejectExtra(params.selector, new Set(["qids", "query", "scope", "timeWindow"]), "selector");
  if ("qids" in params.selector) validateQidList(params.selector.qids, "selector.qids");
  optionalString(params.selector, "query", "selector");
  if ("scope" in params.selector) validateScope(params.selector.scope);
  if ("timeWindow" in params.selector && params.selector.timeWindow !== null) {
    assertObject(params.selector.timeWindow, "timeWindow");
    rejectExtra(params.selector.timeWindow, new Set(["start", "end"]), "timeWindow");
    optionalString(params.selector.timeWindow, "start", "timeWindow");
    optionalString(params.selector.timeWindow, "end", "timeWindow");
  }
  optionalBoolean(params, "propagate", "memory.forget params");
  optionalBoolean(params, "dryRun", "memory.forget params");
  optionalString(params, "reason", "memory.forget params");
}

function validateFeedback(params: Record<string, unknown>): void {
  rejectExtra(
    params,
    new Set(["retrievalId", "rating", "usedItemQids", "ignoredItemQids", "corrections", "metadata"]),
    "memory.feedback params",
  );
  validateQid(params.retrievalId, "retrievalId");
  if (!["helpful", "not_helpful", "harmful"].includes(String(params.rating))) {
    throw new QuipuProtocolError("rating is invalid");
  }
  if ("usedItemQids" in params) validateQidList(params.usedItemQids, "usedItemQids");
  if ("ignoredItemQids" in params) validateQidList(params.ignoredItemQids, "ignoredItemQids");
  if ("corrections" in params) {
    if (!Array.isArray(params.corrections)) {
      throw new QuipuProtocolError("corrections must be a list");
    }
    params.corrections.forEach((correction, index) => {
      const label = `corrections[${index}]`;
      assertObject(correction, label);
      rejectExtra(correction, new Set(["type", "text"]), label);
      requireNonEmptyString(correction.type, `${label}.type`);
      requireNonEmptyString(correction.text, `${label}.text`);
    });
  }
  if ("metadata" in params) validateMetadata(params.metadata, "metadata");
}

function validateCoreGet(params: Record<string, unknown>): void {
  rejectExtra(params, new Set(["scope", "blockKey"]), "memory.core.get params");
  if (!("scope" in params)) throw new QuipuProtocolError("scope is required");
  validateScope(params.scope);
  optionalString(params, "blockKey", "memory.core.get params");
}

function validateCoreUpdate(params: Record<string, unknown>): void {
  rejectExtra(params, new Set(["blockKey", "scope", "text", "mode", "evidenceQids", "managedBy"]), "memory.core.update params");
  requireNonEmptyString(params.blockKey, "blockKey");
  if (!("scope" in params)) throw new QuipuProtocolError("scope is required");
  validateScope(params.scope);
  if (typeof params.text !== "string") throw new QuipuProtocolError("text must be a string");
  if (!["replace", "append"].includes(String(params.mode))) throw new QuipuProtocolError("mode is invalid");
  if (!["user", "system"].includes(String(params.managedBy))) throw new QuipuProtocolError("managedBy is invalid");
  if ("evidenceQids" in params) validateQidList(params.evidenceQids, "evidenceQids");
}

const VALIDATORS: Record<QuipuMethod, (params: Record<string, unknown>) => void> = {
  "system.health": validateSystemHealth,
  "memory.remember": validateRemember,
  "memory.retrieve": validateRetrieve,
  "memory.search": validateSearch,
  "memory.inspect": validateInspect,
  "memory.forget": validateForget,
  "memory.feedback": validateFeedback,
  "memory.core.get": validateCoreGet,
  "memory.core.update": validateCoreUpdate,
};

export function validateRpcParams(method: string, params: unknown = {}): asserts method is QuipuMethod {
  if (!METHOD_SET.has(method)) {
    throw new QuipuProtocolError(`unsupported method: ${method}`);
  }
  assertObject(params, "params");
  VALIDATORS[method as QuipuMethod](params);
}

export function validateJsonRpcRequest(request: unknown): asserts request is JsonRpcRequest {
  assertObject(request, "request");
  rejectExtra(request, new Set(["jsonrpc", "id", "method", "params"]), "request");
  if (request.jsonrpc !== "2.0") {
    throw new QuipuProtocolError("request.jsonrpc must be 2.0");
  }
  if (!("id" in request)) {
    throw new QuipuProtocolError("request.id is required");
  }
  if (typeof request.method !== "string") {
    throw new QuipuProtocolError("request.method must be a string");
  }
  validateRpcParams(request.method, request.params ?? {});
}

export function validateJsonRpcResponse(response: unknown): asserts response is JsonRpcResponse {
  assertObject(response, "response");
  rejectExtra(response, new Set(["jsonrpc", "id", "result", "error"]), "response");
  if (response.jsonrpc !== "2.0") {
    throw new QuipuProtocolError("response.jsonrpc must be 2.0");
  }
  if (!("id" in response)) {
    throw new QuipuProtocolError("response.id is required");
  }
  const hasResult = "result" in response;
  const hasError = "error" in response;
  if (hasResult === hasError) {
    throw new QuipuProtocolError("response must contain exactly one of result or error");
  }
  if (hasResult) {
    assertObject(response.result, "result");
  }
  if (hasError) {
    assertObject(response.error, "error");
    rejectExtra(response.error, new Set(["code", "message", "details"]), "error");
    if (!ERROR_CODES.has(String(response.error.code))) {
      throw new QuipuProtocolError("error.code is invalid");
    }
    requireNonEmptyString(response.error.message, "error.message");
    if ("details" in response.error) {
      assertObject(response.error.details, "error.details");
    }
  }
}

function jsonParams(params: Record<string, unknown>): JsonObject {
  return params as JsonObject;
}

export class Quipu {
  private transport?: QuipuTransport;
  private nextId = 1;

  constructor(transport?: QuipuTransport) {
    this.transport = transport;
  }

  static async local(): Promise<Quipu> {
    return new Quipu();
  }

  async call<T extends JsonObject = JsonObject>(method: QuipuMethod, params: Record<string, unknown> = {}): Promise<T> {
    validateRpcParams(method, params);
    if (!this.transport) {
      throw new Error("TODO: connect to Quipu daemon");
    }
    const request: JsonRpcRequest = {
      jsonrpc: "2.0",
      id: `ts_${this.nextId}`,
      method,
      params: jsonParams(params),
    };
    this.nextId += 1;
    const response = await this.transport(request);
    validateJsonRpcResponse(response);
    if ("error" in response) {
      throw new QuipuRpcError(response.error.code, response.error.message, response.error.details);
    }
    return response.result as T;
  }

  health(): Promise<JsonObject> {
    return this.call("system.health", {});
  }

  remember(request: RememberRequest): Promise<JsonObject> {
    return this.call("memory.remember", request as Record<string, unknown>);
  }

  retrieve(request: RetrieveRequest): Promise<JsonObject> {
    return this.call("memory.retrieve", request as Record<string, unknown>);
  }

  search(request: Record<string, unknown>): Promise<JsonObject> {
    return this.call("memory.search", request);
  }

  inspect(request: Record<string, unknown>): Promise<JsonObject> {
    return this.call("memory.inspect", request);
  }

  forget(request: Record<string, unknown>): Promise<JsonObject> {
    return this.call("memory.forget", request);
  }

  feedback(request: Record<string, unknown>): Promise<JsonObject> {
    return this.call("memory.feedback", request);
  }

  coreGet(request: Record<string, unknown>): Promise<JsonObject> {
    return this.call("memory.core.get", request);
  }

  coreUpdate(request: Record<string, unknown>): Promise<JsonObject> {
    return this.call("memory.core.update", request);
  }
}
