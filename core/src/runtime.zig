const std = @import("std");
const answer_synthesis = @import("answer_synthesis.zig");
const build_options = @import("build_options");
const extractor = @import("extractor.zig");
const forgetting = @import("forgetting.zig");
const in_memory_storage = if (build_options.enable_lattice) struct {} else @import("in_memory_storage.zig");
const jobs = @import("jobs.zig");
const lattice_storage = if (build_options.enable_lattice) @import("lattice_storage.zig") else struct {};
const protocol = @import("protocol.zig");
const providers = @import("providers.zig");
const schema = @import("schema.zig");
const storage = @import("storage.zig");
const streams = @import("streams.zig");
const temporal = @import("temporal.zig");

const ObjectMap = std.json.ObjectMap;
const Value = std.json.Value;

const card_keywords_package_manager = [_][]const u8{ "package-manager", "dependency-tool" };
const card_keywords_test_command = [_][]const u8{ "test-command", "verification" };
const card_keywords_repo_style = [_][]const u8{ "repo-style", "implementation-style" };
const card_keywords_project_constraint = [_][]const u8{ "project-constraint", "invariant" };
const card_keywords_response_style = [_][]const u8{ "response-style", "communication" };
const card_keywords_generic = [_][]const u8{"memory-card"};
const card_tags_fact = [_][]const u8{ "fact", "project" };
const card_tags_preference = [_][]const u8{ "preference", "user" };
const card_tags_procedure = [_][]const u8{ "procedure", "project" };
/// LatticeDB 0.15 stores large values; 64 KiB round-trips in the adapter tests.
/// Longer message text still survives intact across its Chunk nodes.
const property_text_max_bytes = 64 * 1024;
const property_truncation_marker = "…";
/// Messages longer than this many bytes are split into Chunk nodes.
const message_chunk_max_bytes = 1200;
/// Boundary search looks back this many bytes from the hard chunk limit.
const message_chunk_boundary_window = 200;
const default_budget_tokens: i64 = 4096;
/// Candidate items kept per retrieval; enough chunks to fill the default budget.
const retrieval_candidate_limit: usize = 80;
/// Leading candidates sent to a configured reranker (`options.rerankCandidates`).
const default_rerank_candidates: usize = 50;
/// Rerank scores listed in the retrieval trace.
const rerank_trace_top_scores: usize = 10;
/// Audit events read per stream page by memory.inspect.
const audit_page_size: usize = 1000;
/// Related cards a new memory card links to.
const related_card_limit: usize = 8;

const Scope = struct {
    tenant_id: ?[]const u8 = null,
    user_id: ?[]const u8 = null,
    agent_id: ?[]const u8 = null,
    project_id: ?[]const u8 = null,

    fn json(self: Scope) ScopeJson {
        return .{
            .tenantId = self.tenant_id,
            .userId = self.user_id,
            .agentId = self.agent_id,
            .projectId = self.project_id,
        };
    }

    fn matchesNode(self: Scope, allocator: std.mem.Allocator, node: storage.Node) !bool {
        if (self.tenant_id) |expected| {
            if (!try propertyEquals(allocator, node.properties_json, "tenantId", expected)) return false;
        }
        if (self.user_id) |expected| {
            if (!try propertyEquals(allocator, node.properties_json, "userId", expected)) return false;
        }
        if (self.agent_id) |expected| {
            if (!try propertyEquals(allocator, node.properties_json, "agentId", expected)) return false;
        }
        if (self.project_id) |expected| {
            if (!try propertyEquals(allocator, node.properties_json, "projectId", expected)) return false;
        }
        return true;
    }
};

const ScopeJson = struct {
    tenantId: ?[]const u8 = null,
    userId: ?[]const u8 = null,
    agentId: ?[]const u8 = null,
    projectId: ?[]const u8 = null,
};

const MessageResult = struct {
    qid: []const u8,
    type: []const u8,
    text: []const u8,
    score: f32,
    confidence: f32 = 1.0,
    state: []const u8 = "current",
    validFrom: ?[]const u8 = null,
    validTo: ?[]const u8 = null,
    evidence: []const EvidenceResult = &.{},
    includeDebug: bool = false,
    slotKey: ?[]const u8 = null,
    subject: ?[]const u8 = null,
    attribute: ?[]const u8 = null,
    value: ?[]const u8 = null,
    numericValue: ?i64 = null,
    unit: ?[]const u8 = null,
    aggregationMode: ?[]const u8 = null,
    /// Source metadata for raw evidence items (Message and Chunk nodes).
    /// Not serialized; renderers read it from the item directly.
    raw_source: ?RawSource = null,

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("qid");
        try jw.write(self.qid);
        try jw.objectField("type");
        try jw.write(self.type);
        try jw.objectField("text");
        try jw.write(self.text);
        try jw.objectField("score");
        try jw.write(self.score);
        try jw.objectField("confidence");
        try jw.write(self.confidence);
        try jw.objectField("state");
        try jw.write(self.state);
        try jw.objectField("validFrom");
        try jw.write(self.validFrom);
        try jw.objectField("validTo");
        try jw.write(self.validTo);
        try jw.objectField("evidence");
        try jw.write(self.evidence);
        if (self.includeDebug) {
            if (self.slotKey) |slot_key| {
                try jw.objectField("slotKey");
                try jw.write(slot_key);
            }
            if (self.subject) |subject| {
                try jw.objectField("subject");
                try jw.write(subject);
            }
            if (self.attribute) |attribute| {
                try jw.objectField("attribute");
                try jw.write(attribute);
            }
            if (self.value) |value| {
                try jw.objectField("value");
                try jw.write(value);
            }
            if (self.numericValue) |numeric_value| {
                try jw.objectField("numericValue");
                try jw.write(numeric_value);
            }
            if (self.unit) |unit| {
                try jw.objectField("unit");
                try jw.write(unit);
            }
            if (self.aggregationMode) |aggregation_mode| {
                try jw.objectField("aggregationMode");
                try jw.write(aggregation_mode);
            }
        }
        try jw.endObject();
    }
};

/// Where a raw evidence item came from. All strings are owned by the item.
const RawSource = struct {
    role: ?[]const u8 = null,
    created_at: ?[]const u8 = null,
    /// Caller-provided session id from memory.remember, when present.
    session_id: ?[]const u8 = null,
    session_qid: ?[]const u8 = null,
    turn_qid: ?[]const u8 = null,
    /// Parent message qid; equals the item qid for unchunked messages.
    message_qid: []const u8,
    /// 0-based position of the message in its memory.remember call.
    message_index: ?i64 = null,
    /// 0-based chunk position; null when the item is a whole message.
    chunk_index: ?i64 = null,
    chunk_count: ?i64 = null,
    /// Slot keys of memories evidenced by this message that are stale at
    /// query time (filled only when the packet holds slot memories).
    stale_slot_keys: []const []const u8 = &.{},

    fn deinit(self: RawSource, allocator: std.mem.Allocator) void {
        if (self.role) |value| allocator.free(value);
        if (self.created_at) |value| allocator.free(value);
        if (self.session_id) |value| allocator.free(value);
        if (self.session_qid) |value| allocator.free(value);
        if (self.turn_qid) |value| allocator.free(value);
        allocator.free(self.message_qid);
        for (self.stale_slot_keys) |key| allocator.free(key);
        if (self.stale_slot_keys.len > 0) allocator.free(self.stale_slot_keys);
    }
};

const EvidenceResult = struct {
    qid: []const u8,
    quote: []const u8,
    timestamp: ?[]const u8 = null,
};

const ContextPacket = struct {
    core: []const MessageResult = &.{},
    currentFacts: []const MessageResult = &.{},
    preferences: []const MessageResult = &.{},
    procedural: []const MessageResult = &.{},
    episodes: []const MessageResult = &.{},
    warnings: []const []const u8 = &.{},
};

const RetrievalTrace = struct {
    query: []const u8,
    requestedNeedsCount: usize,
    budgetTokens: i64,
    candidateSources: CandidateSources = .{},
    candidateCount: usize,
    keptCount: usize,
    droppedForNeeds: usize,
    droppedForBudget: usize,
    tokenEstimate: usize,
    validAt: ?[]const u8 = null,
    scoreBreakdowns: []const ScoreBreakdown = &.{},
    scoringDetails: []const ScoringDetail = &.{},
    droppedItemReasons: []const DroppedItemReason = &.{},
    /// Present only when a reranker is configured.
    rerank: ?RerankTrace = null,

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        try jw.beginObject();
        inline for (std.meta.fields(@This())) |field| {
            const value = @field(self, field.name);
            if (comptime std.mem.eql(u8, field.name, "rerank")) {
                if (value) |rerank| {
                    try jw.objectField(field.name);
                    try jw.write(rerank);
                }
            } else {
                try jw.objectField(field.name);
                try jw.write(value);
            }
        }
        try jw.endObject();
    }
};

const RerankTrace = struct {
    model: ?[]const u8,
    /// `applied`, `failed` (fused order kept), `disabled` (`options.rerank`
    /// false), or `skipped` (no candidates).
    status: []const u8,
    /// Leading candidates sent to the reranker.
    windowSize: usize = 0,
    /// Candidates the reranker returned a score for.
    rerankedCount: usize = 0,
    latencyMs: f64 = 0,
    /// Best scores first, at most `rerank_trace_top_scores`.
    topScores: []const RerankScore = &.{},
    @"error": ?[]const u8 = null,
};

const RerankScore = struct {
    qid: []const u8,
    score: f64,
};

const CandidateSources = struct {
    fts: usize = 0,
    vector: usize = 0,
    hybrid: usize = 0,
    graph: usize = 0,
    core: usize = 0,
};

const ScoreBreakdown = struct {
    qid: []const u8,
    type: []const u8,
    score: f32,
    lexical: f32,
    temporal: f32,
    scope: f32,
    confidence: f32,
    recency: f32,
};

const ScoringDetail = struct {
    qid: []const u8,
    type: []const u8,
    finalScore: f32,
    lexical: f32,
    temporal: f32,
    scope: f32,
    confidence: f32,
    recency: f32,
    formula: []const u8 = "lexical + temporal + scope + confidence + recency",
};

const DroppedItemReason = struct {
    reason: []const u8,
    count: usize,
};

const MessageMeta = struct {
    scope: Scope,
    role: []const u8,
    created_at: ?[]const u8,
    session_qid: []const u8,
    session_id: ?[]const u8,
    turn_qid: []const u8,
    message_qid: []const u8,
    message_index: usize,
    privacy_class: []const u8,
};

const EventWindow = struct {
    start: ?[]const u8 = null,
    end: ?[]const u8 = null,

    fn active(self: EventWindow) bool {
        return self.start != null or self.end != null;
    }
};

const SearchMode = enum {
    fts,
    vector,
    hybrid,
    graph,
};

const CoreBlockResult = struct {
    qid: []const u8,
    blockKey: []const u8,
    scope: ScopeJson,
    text: []const u8,
    managedBy: []const u8,
    evidenceQids: []const []const u8 = &.{},
};

const NodeRefResult = struct {
    qid: []const u8,
    type: []const u8,
    relation: []const u8,
};

const ForgetReportItem = struct {
    qid: []const u8,
    type: []const u8,
    action: []const u8,
};

const AuditEventResult = struct {
    stream: []const u8,
    sequence: u64,
    rawJson: []const u8,
};

pub const EntityJobRunResult = struct {
    materializedCount: usize,
    leasedCount: usize,
    succeededCount: usize,
    failedCount: usize,
    lastError: ?[]const u8 = null,
};

pub const RuntimeOptions = struct {
    io: ?std.Io = null,
    answer_provider: providers.ProviderEndpoint = .{},
    entity_provider: providers.ProviderEndpoint = .{},
    /// Optional cross-encoder stage of memory.retrieve and memory.answer.
    reranker: providers.ProviderEndpoint = .{},
};

pub const Runtime = struct {
    store: storage.Adapter,
    health: protocol.Health,
    options: RuntimeOptions = .{},
    next_id: u64 = 1,

    pub fn init(store: storage.Adapter, health: protocol.Health) Runtime {
        return .{ .store = store, .health = health };
    }

    pub fn initWithOptions(store: storage.Adapter, health: protocol.Health, options: RuntimeOptions) Runtime {
        return .{ .store = store, .health = health, .options = options };
    }

    pub fn initWithNextId(store: storage.Adapter, health: protocol.Health, next_id: u64) Runtime {
        return .{
            .store = store,
            .health = health,
            .next_id = @max(next_id, 1),
        };
    }

    pub fn initWithNextIdAndOptions(store: storage.Adapter, health: protocol.Health, next_id: u64, options: RuntimeOptions) Runtime {
        return .{
            .store = store,
            .health = health,
            .options = options,
            .next_id = @max(next_id, 1),
        };
    }

    pub fn deinit(self: *Runtime) void {
        _ = self;
    }

    pub fn dispatch(self: *Runtime, allocator: std.mem.Allocator, request_json: []const u8) ![]u8 {
        var parsed = std.json.parseFromSlice(Value, allocator, request_json, .{}) catch {
            return errorResponse(allocator, null, "invalid_request", "request body must be valid JSON");
        };
        defer parsed.deinit();

        const root = switch (parsed.value) {
            .object => |object| object,
            else => return errorResponse(allocator, null, "invalid_request", "request must be a JSON object"),
        };

        const id = jsonRpcId(root.get("id"));
        const jsonrpc = stringValue(root.get("jsonrpc")) orelse {
            return errorResponse(allocator, id, "invalid_request", "jsonrpc is required");
        };
        if (!std.mem.eql(u8, jsonrpc, "2.0")) {
            return errorResponse(allocator, id, "invalid_request", "jsonrpc must be 2.0");
        }
        const method = stringValue(root.get("method")) orelse {
            return errorResponse(allocator, id, "invalid_request", "method is required");
        };
        const params = paramsObject(root.get("params")) catch {
            return errorResponse(allocator, id, "invalid_request", "params must be an object");
        };

        if (std.mem.eql(u8, method, "system.health")) return self.systemHealth(allocator, id);
        if (std.mem.eql(u8, method, "memory.remember")) return self.memoryRemember(allocator, id, &params);
        if (std.mem.eql(u8, method, "memory.search")) return self.memorySearch(allocator, id, &params);
        if (std.mem.eql(u8, method, "memory.retrieve")) return self.memoryRetrieve(allocator, id, &params);
        if (std.mem.eql(u8, method, "memory.answer")) return self.memoryAnswer(allocator, id, &params);
        if (std.mem.eql(u8, method, "memory.inspect")) return self.memoryInspect(allocator, id, &params);
        if (std.mem.eql(u8, method, "memory.forget")) return self.memoryForget(allocator, id, &params);
        if (std.mem.eql(u8, method, "memory.feedback")) return self.memoryFeedback(allocator, id, &params);
        if (std.mem.eql(u8, method, "memory.entityResolve.run")) return self.memoryEntityResolveRun(allocator, id, &params);
        if (std.mem.eql(u8, method, "memory.core.get")) return self.memoryCoreGet(allocator, id, &params);
        if (std.mem.eql(u8, method, "memory.core.update")) return self.memoryCoreUpdate(allocator, id, &params);
        if (std.mem.eql(u8, method, "memory.core.consolidate")) return self.memoryCoreConsolidate(allocator, id, &params);

        return errorResponse(allocator, id, "not_found", "unsupported method");
    }

    fn systemHealth(self: *Runtime, allocator: std.mem.Allocator, id: ?[]const u8) ![]u8 {
        const response = .{
            .jsonrpc = "2.0",
            .id = id,
            .result = .{
                .status = "ok",
                .version = self.health.version,
                .protocolVersion = self.health.protocol_version,
                .dbPath = self.health.db_path,
                .latticeVersion = self.health.lattice_version,
                .schemaVersion = self.health.schema_version,
                .storage = storageHealth(self.store.capabilities()),
                .workers = .{
                    .extractor = "unavailable",
                    .consolidator = "unavailable",
                    .entityResolver = if (self.options.entity_provider.kind == .none) "unavailable" else "running",
                    .answerer = if (self.options.answer_provider.kind == .none) "unavailable" else "running",
                },
                .capabilities = .{
                    .reranker = .{
                        .configured = self.options.reranker.kind != .none,
                        .model = if (self.options.reranker.kind != .none) self.options.reranker.model else null,
                    },
                },
            },
        };
        return stringifyAlloc(allocator, response);
    }

    fn memoryEntityResolveRun(self: *Runtime, allocator: std.mem.Allocator, id: ?[]const u8, params: *const ObjectMap) ![]u8 {
        const owner = stringField(params, "owner") orelse "eval-runner";
        const requested_limit = integerField(params, "limit") orelse 100000;
        if (requested_limit < 1) {
            return errorResponse(allocator, id, "invalid_request", "limit must be positive");
        }
        const result = try self.runEntityResolveJobs(allocator, owner, @intCast(requested_limit));
        const response = .{
            .jsonrpc = "2.0",
            .id = id,
            .result = .{
                .materializedCount = result.materializedCount,
                .leasedCount = result.leasedCount,
                .succeededCount = result.succeededCount,
                .failedCount = result.failedCount,
                .lastError = result.lastError,
            },
        };
        return stringifyAlloc(allocator, response);
    }

    fn memoryRemember(self: *Runtime, allocator: std.mem.Allocator, id: ?[]const u8, params: *const ObjectMap) ![]u8 {
        const messages = arrayValue(params.get("messages")) orelse {
            return errorResponse(allocator, id, "invalid_request", "messages must be a non-empty array");
        };
        if (messages.items.len == 0) {
            return errorResponse(allocator, id, "invalid_request", "messages must be a non-empty array");
        }

        if (stringField(params, "idempotencyKey")) |key| {
            const idem_qid = try idempotencyQid(allocator, key);
            defer allocator.free(idem_qid);
            if (try self.store.getNode(allocator, idem_qid)) |node| {
                defer self.store.freeNode(allocator, node);
                const session_qid = try readPropertyString(allocator, node.properties_json, "sessionQid");
                defer allocator.free(session_qid);
                const turn_qid = try readPropertyString(allocator, node.properties_json, "turnQid");
                defer allocator.free(turn_qid);
                const message_qid = try readPropertyString(allocator, node.properties_json, "messageQid");
                defer allocator.free(message_qid);
                const response = .{
                    .jsonrpc = "2.0",
                    .id = id,
                    .result = .{
                        .sessionQid = session_qid,
                        .turnQid = turn_qid,
                        .messageQids = &[_][]const u8{message_qid},
                        .queuedJobs = &[_][]const u8{},
                        .status = "duplicate",
                    },
                };
                return stringifyAlloc(allocator, response);
            }
        }

        const scope = parseScope(params);
        const session_qid = try self.nextQid(allocator, "sess");
        defer allocator.free(session_qid);
        const turn_qid = try self.nextQid(allocator, "turn");
        defer allocator.free(turn_qid);

        const session_id = stringField(params, "sessionId");
        const session_props = try stringifyAlloc(allocator, .{
            .kind = "session",
            .sessionId = session_id,
            .tenantId = scope.tenant_id,
            .userId = scope.user_id,
            .agentId = scope.agent_id,
            .projectId = scope.project_id,
            .deleted = false,
        });
        defer allocator.free(session_props);
        try self.store.putNode(.{ .qid = session_qid, .label = "Session", .properties_json = session_props });

        const turn_props = try stringifyAlloc(allocator, .{
            .kind = "turn",
            .sessionQid = session_qid,
            .tenantId = scope.tenant_id,
            .userId = scope.user_id,
            .agentId = scope.agent_id,
            .projectId = scope.project_id,
            .deleted = false,
        });
        defer allocator.free(turn_props);
        try self.store.putNode(.{ .qid = turn_qid, .label = "Turn", .properties_json = turn_props });
        try self.putEdge(allocator, session_qid, turn_qid, "HAS_TURN");

        var message_qids = std.ArrayList([]const u8).empty;
        defer {
            for (message_qids.items) |qid| allocator.free(qid);
            message_qids.deinit(allocator);
        }
        var first_message_content: ?[]const u8 = null;
        var first_message_created_at: ?[]const u8 = null;

        const extract_enabled = boolField(params, "extract") orelse true;
        var derived_count: usize = 0;

        try self.prefetchRememberEmbeddings(allocator, messages.items, extract_enabled);
        defer self.store.clearPrefetchedEmbeddings();

        for (messages.items, 0..) |message_value, message_index| {
            const message = objectValue(message_value) orelse {
                return errorResponse(allocator, id, "invalid_request", "each message must be an object");
            };
            const role = stringField(&message, "role") orelse {
                return errorResponse(allocator, id, "invalid_request", "message.role is required");
            };
            const content = stringField(&message, "content") orelse {
                return errorResponse(allocator, id, "invalid_request", "message.content is required");
            };
            if (content.len == 0) {
                return errorResponse(allocator, id, "invalid_request", "message.content is required");
            }
            if (first_message_content == null) {
                first_message_content = content;
                first_message_created_at = stringField(&message, "createdAt");
            }
            const message_qid = try self.nextQid(allocator, "msg");
            try message_qids.append(allocator, message_qid);

            const meta = MessageMeta{
                .scope = scope,
                .role = role,
                .created_at = stringField(&message, "createdAt"),
                .session_qid = session_qid,
                .session_id = session_id,
                .turn_qid = turn_qid,
                .message_qid = message_qid,
                .message_index = message_index,
                .privacy_class = stringField(params, "privacyClass") orelse "normal",
            };
            const chunk_ends = try messageChunkEnds(allocator, content);
            defer allocator.free(chunk_ends);
            const chunked = chunk_ends.len > 1;

            // A chunked message keeps a clamped copy of its content but is
            // searched through its chunks, which together hold the full text.
            const content_for_props = try clampPropertyText(allocator, content);
            defer allocator.free(content_for_props);
            const message_props = try stringifyAlloc(allocator, .{
                .kind = "message",
                .role = role,
                .content = content_for_props,
                .createdAt = meta.created_at,
                .sessionQid = session_qid,
                .sessionId = session_id,
                .turnQid = turn_qid,
                .messageIndex = message_index,
                .searchable = !chunked,
                .chunkCount = if (chunked) chunk_ends.len else 0,
                .tenantId = scope.tenant_id,
                .userId = scope.user_id,
                .agentId = scope.agent_id,
                .projectId = scope.project_id,
                .privacyClass = meta.privacy_class,
                .deleted = false,
            });
            defer allocator.free(message_props);
            try self.store.putNode(.{ .qid = message_qid, .label = "Message", .properties_json = message_props });
            try self.putEdge(allocator, turn_qid, message_qid, "HAS_MESSAGE");
            if (chunked) {
                try self.writeMessageChunks(allocator, meta, content, chunk_ends);
            }
            if (extract_enabled) {
                derived_count += try self.extractFromMessage(
                    allocator,
                    scope,
                    message_qid,
                    content,
                    stringField(&message, "createdAt"),
                );
            }
        }

        const episode_qid = if (extract_enabled and message_qids.items.len > 0)
            try self.writeEpisodeForTurn(allocator, scope, session_qid, turn_qid, message_qids.items, first_message_content orelse "", first_message_created_at)
        else
            null;
        defer if (episode_qid) |qid| allocator.free(qid);

        const tool_call_count = try self.writeToolCalls(allocator, params, scope, turn_qid);
        const observation_count = try self.writeObservations(allocator, params, scope, turn_qid);

        if (stringField(params, "idempotencyKey")) |key| {
            const idem_qid = try idempotencyQid(allocator, key);
            defer allocator.free(idem_qid);
            const first_message_qid = if (message_qids.items.len > 0) message_qids.items[0] else "";
            const idem_props = try stringifyAlloc(allocator, .{
                .kind = "idempotency",
                .idempotencyKey = key,
                .sessionQid = session_qid,
                .turnQid = turn_qid,
                .messageQid = first_message_qid,
                .deleted = false,
            });
            defer allocator.free(idem_props);
            try self.store.putNode(.{ .qid = idem_qid, .label = "Idempotency", .properties_json = idem_props });
        }

        var queued_jobs = std.ArrayList([]const u8).empty;
        defer {
            for (queued_jobs.items) |qid| allocator.free(qid);
            queued_jobs.deinit(allocator);
        }
        if (extract_enabled) {
            const extract_payload = try stringifyAlloc(allocator, .{
                .method = "memory.extract.requested",
                .sourceMethod = "memory.remember",
                .sessionQid = session_qid,
                .turnQid = turn_qid,
                .messageQids = message_qids.items,
                .scope = scope.json(),
                .inlineDerivedCount = derived_count,
            });
            defer allocator.free(extract_payload);
            const extract_event = try self.publishEvent(streams.extract_requested, extract_payload);
            const extract_job_qid = try jobs.jobQid(
                allocator,
                streams.extract_requested,
                extract_event.sequence,
                streams.workerKindForStream(streams.extract_requested),
            );
            errdefer allocator.free(extract_job_qid);
            _ = try jobs.materializeStream(allocator, self.store, streams.extract_requested, streams.workerKindForStream(streams.extract_requested), .{
                .after_sequence = if (extract_event.sequence > 0) extract_event.sequence - 1 else 0,
                .limit = 1,
            });
            try queued_jobs.append(allocator, extract_job_qid);
        }
        if (self.options.entity_provider.kind != .none and message_qids.items.len > 0) {
            const entity_payload = try stringifyAlloc(allocator, .{
                .method = "memory.entity.resolve.requested",
                .sourceMethod = "memory.remember",
                .sessionQid = session_qid,
                .turnQid = turn_qid,
                .messageQids = message_qids.items,
                .scope = scope.json(),
                .provider = self.options.entity_provider.name,
            });
            defer allocator.free(entity_payload);
            const entity_event = try self.publishEvent(streams.entity_resolve_requested, entity_payload);
            const entity_job_qid = try jobs.jobQid(
                allocator,
                streams.entity_resolve_requested,
                entity_event.sequence,
                streams.workerKindForStream(streams.entity_resolve_requested),
            );
            errdefer allocator.free(entity_job_qid);
            _ = try jobs.materializeStream(allocator, self.store, streams.entity_resolve_requested, streams.workerKindForStream(streams.entity_resolve_requested), .{
                .after_sequence = if (entity_event.sequence > 0) entity_event.sequence - 1 else 0,
                .limit = 1,
            });
            try queued_jobs.append(allocator, entity_job_qid);
        }

        const event_payload = try stringifyAlloc(allocator, .{
            .method = "memory.remember",
            .status = "stored",
            .sessionQid = session_qid,
            .turnQid = turn_qid,
            .messageQids = message_qids.items,
            .queuedJobs = queued_jobs.items,
            .derivedCount = derived_count,
            .episodeQid = episode_qid,
            .toolCallCount = tool_call_count,
            .observationCount = observation_count,
        });
        defer allocator.free(event_payload);
        _ = try self.publishEvent(streams.raw_event, event_payload);
        _ = try self.publishEvent(streams.audit, event_payload);

        const response = .{
            .jsonrpc = "2.0",
            .id = id,
            .result = .{
                .sessionQid = session_qid,
                .turnQid = turn_qid,
                .messageQids = message_qids.items,
                .queuedJobs = queued_jobs.items,
                .status = "stored",
            },
        };
        return stringifyAlloc(allocator, response);
    }

    fn memorySearch(self: *Runtime, allocator: std.mem.Allocator, id: ?[]const u8, params: *const ObjectMap) ![]u8 {
        const query = stringField(params, "query") orelse {
            return errorResponse(allocator, id, "invalid_request", "query must be a non-empty string");
        };
        if (query.len == 0) {
            return errorResponse(allocator, id, "invalid_request", "query must be a non-empty string");
        }
        const limit = integerField(params, "limit") orelse 20;
        const include_deleted = boolField(params, "includeDeleted") orelse false;
        const scope = parseScope(params);
        const mode = parseSearchMode(stringField(params, "mode")) orelse {
            return errorResponse(allocator, id, "invalid_request", "mode must be fts, vector, hybrid, or graph");
        };

        var results = try self.collectItems(allocator, query, mode, @intCast(limit), scope, include_deleted, params.get("labels"), null, .{}, true, false);
        defer results.deinit();

        const response = .{
            .jsonrpc = "2.0",
            .id = id,
            .result = .{ .results = results.items.items },
        };
        return stringifyAlloc(allocator, response);
    }

    fn memoryRetrieve(self: *Runtime, allocator: std.mem.Allocator, id: ?[]const u8, params: *const ObjectMap) ![]u8 {
        const query = stringField(params, "query") orelse {
            return errorResponse(allocator, id, "invalid_request", "query must be a non-empty string");
        };
        if (query.len == 0) {
            return errorResponse(allocator, id, "invalid_request", "query must be a non-empty string");
        }
        const budget = integerField(params, "budgetTokens") orelse default_budget_tokens;
        if (budget < 1) {
            return errorResponse(allocator, id, "invalid_request", "budgetTokens must be positive");
        }

        const scope = parseScope(params);
        const valid_at = parseValidAt(params);
        const event_window = parseEventWindow(params);
        const needs_value = params.get("needs");
        const options = objectField(params, "options");
        const include_evidence = if (options) |opts| boolField(&opts, "includeEvidence") orelse true else true;
        const include_trace = if (options) |opts| (boolField(&opts, "includeDebug") orelse false) or (boolField(&opts, "logTrace") orelse false) else false;
        const log_retrieval = if (options) |opts| boolField(&opts, "logRetrieval") orelse (boolField(&opts, "logTrace") orelse true) else true;
        const log_audit = if (options) |opts| boolField(&opts, "logAudit") orelse true else true;
        const temporal_hints = if (options) |opts| boolField(&opts, "temporalHints") orelse false else false;
        const retrieve_mode = parseRetrieveMode(stringField(params, "mode"), self.store.capabilities()) orelse {
            return errorResponse(allocator, id, "invalid_request", "mode must be fts, vector, hybrid, or graph");
        };
        const rerank_settings = parseRerankSettings(options) orelse {
            return errorResponse(allocator, id, "invalid_request", "options.rerankCandidates must be a positive integer");
        };

        var results = try self.collectItems(allocator, query, retrieve_mode, retrieval_candidate_limit, scope, false, null, valid_at, event_window, include_evidence, include_trace);
        defer results.deinit();
        if (needsIncludes(needs_value, "core")) {
            try self.appendCoreItems(allocator, &results, scope, include_evidence, include_trace);
        }
        const candidate_count = results.items.items.len;
        const dropped_for_needs = results.filterByNeeds(needs_value);
        results.applyRawEvidencePolicy();
        var rerank = try self.rerankItems(allocator, query, &results, rerank_settings);
        defer if (rerank) |*stage| stage.deinit();
        const dropped_for_budget = results.applyTokenBudget(@intCast(budget));

        var warnings = std.ArrayList([]const u8).empty;
        defer warnings.deinit(allocator);
        if (dropped_for_budget > 0) {
            try warnings.append(allocator, "token_budget_truncated");
        }
        if (results.items.items.len == 0) {
            try warnings.append(allocator, "no_memory_items");
        }
        if (rerank) |*stage| {
            if (stage.failed()) try warnings.append(allocator, "rerank_failed");
        }
        try appendRetrievalWarnings(allocator, &warnings, results.items.items, include_evidence);

        var context = try OwnedContextPacket.fromItems(allocator, results.items.items, warnings.items);
        defer context.deinit();

        const retrieval_id = try self.nextQid(allocator, "retr");
        defer allocator.free(retrieval_id);
        const hint_date = temporalHintDate(temporal_hints, valid_at);
        const time_references = try timeReferencesForQuery(allocator, query, hint_date);
        defer if (time_references) |text| allocator.free(text);
        const prompt = try promptFromContext(allocator, self.store, context.view(), .{
            .current_date = valid_at,
            .hint_date = hint_date,
            .time_references = time_references,
        });
        defer allocator.free(prompt);
        const token_estimate = estimatePromptTokens(prompt);
        const score_breakdowns = try buildScoreBreakdowns(allocator, results.items.items);
        defer allocator.free(score_breakdowns);
        const scoring_details = try buildScoringDetails(allocator, results.items.items);
        defer allocator.free(scoring_details);
        const dropped_item_reasons = try buildDroppedItemReasons(allocator, dropped_for_needs, dropped_for_budget);
        defer allocator.free(dropped_item_reasons);
        const trace = RetrievalTrace{
            .query = query,
            .requestedNeedsCount = needsCount(needs_value),
            .budgetTokens = budget,
            .candidateSources = retrievalCandidateSources(retrieve_mode, candidate_count, context.core.items.len),
            .candidateCount = candidate_count,
            .keptCount = results.items.items.len,
            .droppedForNeeds = dropped_for_needs,
            .droppedForBudget = dropped_for_budget,
            .tokenEstimate = token_estimate,
            .validAt = valid_at,
            .scoreBreakdowns = score_breakdowns,
            .scoringDetails = scoring_details,
            .droppedItemReasons = dropped_item_reasons,
            .rerank = if (rerank) |*stage| stage.view() else null,
        };

        const item_qids = try allocator.alloc([]const u8, results.items.items.len);
        defer allocator.free(item_qids);
        for (results.items.items, 0..) |item, index| {
            item_qids[index] = item.qid;
        }

        const event_payload = try stringifyAlloc(allocator, .{
            .method = "memory.retrieve",
            .retrievalId = retrieval_id,
            .query = query,
            .itemCount = results.items.items.len,
            .itemQids = item_qids,
            .tokenEstimate = token_estimate,
            .warnings = warnings.items,
            .traceLogged = log_retrieval,
        });
        defer allocator.free(event_payload);
        if (log_retrieval) {
            if (self.publishEvent(streams.retrieval_logged, event_payload)) |_| {} else |_| {
                if (!containsWarning(warnings.items, "retrieval_stream_write_failed")) {
                    try warnings.append(allocator, "retrieval_stream_write_failed");
                }
            }
        }
        if (log_audit) {
            if (self.publishEvent(streams.audit, event_payload)) |_| {} else |_| {
                if (!containsWarning(warnings.items, "retrieval_stream_write_failed")) {
                    try warnings.append(allocator, "retrieval_stream_write_failed");
                }
            }
        }

        const response = .{
            .jsonrpc = "2.0",
            .id = id,
            .result = .{
                .retrievalId = retrieval_id,
                .prompt = prompt,
                .context = context.view(),
                .items = results.items.items,
                .tokenEstimate = token_estimate,
                .confidence = if (results.items.items.len > 0) @as(f32, 0.72) else @as(f32, 0.0),
                .warnings = warnings.items,
                .trace = if (include_trace) trace else null,
            },
        };
        return stringifyAlloc(allocator, response);
    }

    fn memoryAnswer(self: *Runtime, allocator: std.mem.Allocator, id: ?[]const u8, params: *const ObjectMap) ![]u8 {
        const query = stringField(params, "query") orelse {
            return errorResponse(allocator, id, "invalid_request", "query must be a non-empty string");
        };
        if (query.len == 0) {
            return errorResponse(allocator, id, "invalid_request", "query must be a non-empty string");
        }
        const budget = integerField(params, "budgetTokens") orelse default_budget_tokens;
        if (budget < 1) {
            return errorResponse(allocator, id, "invalid_request", "budgetTokens must be positive");
        }

        const scope = parseScope(params);
        const valid_at = parseValidAt(params);
        const event_window = parseEventWindow(params);
        const needs_value = params.get("needs");
        const options = objectField(params, "options");
        const include_evidence = if (options) |opts| boolField(&opts, "includeEvidence") orelse true else true;
        const include_trace = if (options) |opts| (boolField(&opts, "includeDebug") orelse false) or (boolField(&opts, "logTrace") orelse false) else false;
        const abstain_if_weak = if (options) |opts| boolField(&opts, "abstainIfWeak") orelse false else false;
        const reader_reasoning = if (options) |opts| boolField(&opts, "readerReasoning") orelse false else false;
        const temporal_hints = if (options) |opts| boolField(&opts, "temporalHints") orelse false else false;
        const log_retrieval = if (options) |opts| boolField(&opts, "logRetrieval") orelse (boolField(&opts, "logTrace") orelse true) else true;
        const retrieve_mode = parseRetrieveMode(stringField(params, "mode"), self.store.capabilities()) orelse {
            return errorResponse(allocator, id, "invalid_request", "mode must be fts, vector, hybrid, or graph");
        };
        const rerank_settings = parseRerankSettings(options) orelse {
            return errorResponse(allocator, id, "invalid_request", "options.rerankCandidates must be a positive integer");
        };

        var results = try self.collectItems(allocator, query, retrieve_mode, retrieval_candidate_limit, scope, false, null, valid_at, event_window, include_evidence, include_trace);
        defer results.deinit();
        if (needsIncludes(needs_value, "core")) {
            try self.appendCoreItems(allocator, &results, scope, include_evidence, include_trace);
        }
        const candidate_count = results.items.items.len;
        const dropped_for_needs = results.filterByNeeds(needs_value);
        results.applyRawEvidencePolicy();
        var rerank = try self.rerankItems(allocator, query, &results, rerank_settings);
        defer if (rerank) |*stage| stage.deinit();
        const dropped_for_budget = results.applyTokenBudget(@intCast(budget));

        var warnings = std.ArrayList([]const u8).empty;
        defer warnings.deinit(allocator);
        if (dropped_for_budget > 0) try warnings.append(allocator, "token_budget_truncated");
        if (results.items.items.len == 0) try warnings.append(allocator, "no_memory_items");
        if (rerank) |*stage| {
            if (stage.failed()) try warnings.append(allocator, "rerank_failed");
        }

        try appendRetrievalWarnings(allocator, &warnings, results.items.items, include_evidence);

        // Reserve room for answer warnings so the context packet's view of
        // `warnings.items` is never invalidated by a later append.
        try warnings.ensureUnusedCapacity(allocator, 8);
        var context = try OwnedContextPacket.fromItems(allocator, results.items.items, warnings.items);
        defer context.deinit();

        const retrieval_id = try self.nextQid(allocator, "retr");
        defer allocator.free(retrieval_id);
        // The question date (and, with temporal hints, the query's resolved
        // time references) travels in the reader's user turn, not inside the
        // untrusted memory block.
        const hint_date = temporalHintDate(temporal_hints, valid_at);
        const time_references = try timeReferencesForQuery(allocator, query, hint_date);
        defer if (time_references) |text| allocator.free(text);
        const prompt = try promptFromContext(allocator, self.store, context.view(), .{ .hint_date = hint_date });
        defer allocator.free(prompt);
        const token_estimate = estimatePromptTokens(prompt);
        const score_breakdowns = try buildScoreBreakdowns(allocator, results.items.items);
        defer allocator.free(score_breakdowns);
        const scoring_details = try buildScoringDetails(allocator, results.items.items);
        defer allocator.free(scoring_details);
        const dropped_item_reasons = try buildDroppedItemReasons(allocator, dropped_for_needs, dropped_for_budget);
        defer allocator.free(dropped_item_reasons);
        const trace = RetrievalTrace{
            .query = query,
            .requestedNeedsCount = needsCount(needs_value),
            .budgetTokens = budget,
            .candidateSources = retrievalCandidateSources(retrieve_mode, candidate_count, context.core.items.len),
            .candidateCount = candidate_count,
            .keptCount = results.items.items.len,
            .droppedForNeeds = dropped_for_needs,
            .droppedForBudget = dropped_for_budget,
            .tokenEstimate = token_estimate,
            .validAt = valid_at,
            .scoreBreakdowns = score_breakdowns,
            .scoringDetails = scoring_details,
            .droppedItemReasons = dropped_item_reasons,
            .rerank = if (rerank) |*stage| stage.view() else null,
        };

        // One answer path: with a reader configured, every non-empty context
        // goes to it; with no evidence nothing is called and the answer abstains;
        // with no reader the synthesizer uses its deterministic fallback.
        const endpoint = if (self.options.answer_provider.kind == .none)
            providers.ProviderEndpoint{ .kind = .deterministic, .name = "deterministic_prompt" }
        else
            self.options.answer_provider;
        const reader_configured = endpoint.kind != .none and endpoint.kind != .deterministic;
        const current_date = if (valid_at) |timestamp| try formatCurrentDate(allocator, timestamp) else null;
        defer if (current_date) |value| allocator.free(value);
        const raw_provider_answer = if (!reader_configured or results.items.items.len == 0)
            null
        else
            providers.generateAnswer(allocator, self.options.io, endpoint, .{
                .question = query,
                .context = prompt,
                .current_date = current_date,
                .time_references = time_references,
                .reasoning = reader_reasoning,
            }) catch |err| {
                const message = if (err == error.MissingProviderApiKey)
                    try std.fmt.allocPrint(
                        allocator,
                        "answer provider '{s}' is missing an API key; set {s} or QUIPU_LLM_API_KEY",
                        .{ endpoint.name, providers.apiKeyEnvName(endpoint.name) orelse "QUIPU_LLM_API_KEY" },
                    )
                else if (err == error.InvalidProviderConfig)
                    try std.fmt.allocPrint(allocator, "answer provider '{s}' is not fully configured; set --llm-provider, --llm-model, and --llm-base-url as needed", .{endpoint.name})
                else
                    try std.fmt.allocPrint(allocator, "answer provider '{s}' failed: {s}", .{ endpoint.name, @errorName(err) });
                defer allocator.free(message);
                return errorResponse(allocator, id, "provider_error", message);
            };
        defer if (raw_provider_answer) |value| allocator.free(value);

        const evidence_packet = try buildAnswerEvidencePacket(allocator, results.items.items);
        defer freeAnswerEvidencePacket(allocator, evidence_packet);
        var synthesized = try answer_synthesis.synthesize(allocator, evidence_packet, raw_provider_answer, .{
            .abstain_if_weak = abstain_if_weak,
            .reader_reasoning = reader_reasoning,
        });
        defer synthesized.deinit();
        synthesized.trace.temporalHints = hint_date != null;
        synthesized.trace.timeReferences = time_references;
        for (synthesized.trace.validation.warnings) |warning| {
            if (!containsWarning(warnings.items, warning)) try warnings.append(allocator, warning);
        }

        const item_qids = try allocator.alloc([]const u8, results.items.items.len);
        defer allocator.free(item_qids);
        for (results.items.items, 0..) |item, index| {
            item_qids[index] = item.qid;
        }
        if (log_retrieval) {
            const event_payload = try stringifyAlloc(allocator, .{
                .method = "memory.answer",
                .retrievalId = retrieval_id,
                .query = query,
                .itemCount = results.items.items.len,
                .itemQids = item_qids,
                .tokenEstimate = token_estimate,
                .provider = endpoint.name,
                .model = endpoint.model,
                .strategy = synthesized.trace.strategy,
                .answerable = synthesized.trace.answerable,
                .supportValid = synthesized.trace.supportValid,
            });
            defer allocator.free(event_payload);
            if (self.publishEvent(streams.retrieval_logged, event_payload)) |_| {} else |_| {
                if (!containsWarning(warnings.items, "retrieval_stream_write_failed")) {
                    try warnings.append(allocator, "retrieval_stream_write_failed");
                }
            }
        }

        const include_debug = if (options) |opts| boolField(&opts, "includeDebug") orelse false else false;
        const response = .{
            .jsonrpc = "2.0",
            .id = id,
            .result = .{
                .retrievalId = retrieval_id,
                .answer = synthesized.answer,
                .provider = endpoint.name,
                .model = endpoint.model,
                .prompt = if (include_debug) prompt else null,
                .context = context.view(),
                .items = results.items.items,
                .tokenEstimate = token_estimate,
                .confidence = synthesized.confidence,
                .warnings = warnings.items,
                .trace = if (include_trace) trace else null,
                .answerTrace = if (include_trace) synthesized.trace else null,
            },
        };
        return stringifyAlloc(allocator, response);
    }

    fn memoryInspect(self: *Runtime, allocator: std.mem.Allocator, id: ?[]const u8, params: *const ObjectMap) ![]u8 {
        const qid = stringField(params, "qid") orelse {
            return errorResponse(allocator, id, "invalid_request", "qid is required");
        };
        const node = (try self.store.getNode(allocator, qid)) orelse {
            return errorResponse(allocator, id, "not_found", "memory not found");
        };
        defer self.store.freeNode(allocator, node);

        var provenance = try self.provenanceRefsForNode(allocator, node);
        defer provenance.deinit();
        var dependents = try self.derivedRefsByEvidence(allocator, qid);
        defer dependents.deinit();
        var audit = try self.auditEventsForQid(allocator, qid);
        defer audit.deinit();

        const response = .{
            .jsonrpc = "2.0",
            .id = id,
            .result = .{
                .node = .{
                    .qid = node.qid,
                    .type = labelType(node.label),
                    .properties = .{ .rawJson = node.properties_json },
                },
                .provenance = provenance.items.items,
                .dependents = dependents.items.items,
                .audit = audit.items.items,
            },
        };
        return stringifyAlloc(allocator, response);
    }

    fn memoryForget(self: *Runtime, allocator: std.mem.Allocator, id: ?[]const u8, params: *const ObjectMap) ![]u8 {
        const selector = objectField(params, "selector") orelse {
            return errorResponse(allocator, id, "invalid_request", "selector is required");
        };
        const mode = stringField(params, "mode") orelse {
            return errorResponse(allocator, id, "invalid_request", "mode is required");
        };
        if (!std.mem.eql(u8, mode, "hard_delete") and !std.mem.eql(u8, mode, "redact") and !std.mem.eql(u8, mode, "expire")) {
            return errorResponse(allocator, id, "invalid_request", "mode must be hard_delete, redact, or expire");
        }
        const dry_run = boolField(params, "dryRun") orelse false;
        const propagate = boolField(params, "propagate") orelse true;
        const reason = stringField(params, "reason") orelse "unspecified";
        const selector_scope = parseScope(&selector);
        const selector_window = parseSelectorTimeWindow(&selector);
        if (arrayValue(selector.get("qids")) == null and stringField(&selector, "query") == null) {
            return errorResponse(allocator, id, "invalid_request", "selector.qids or selector.query is required");
        }

        var selected_qids = OwnedQids{ .allocator = allocator };
        defer selected_qids.deinit();
        try self.collectForgetRoots(allocator, &selector, selector_scope, selector_window, &selected_qids);

        var roots_matched: usize = 0;
        var nodes_deleted: usize = 0;
        var nodes_redacted: usize = 0;
        var facts_invalidated: usize = 0;
        var summaries_contaminated: usize = 0;
        var report = OwnedForgetReport{ .allocator = allocator };
        defer report.deinit();
        var contaminated_core_qids = OwnedQids{ .allocator = allocator };
        defer contaminated_core_qids.deinit();
        // Every node this request forgets, so one reached from several roots
        // is reported and tombstoned once.
        var handled = forgetting.QidList.init(allocator);
        defer handled.deinit();
        for (selected_qids.items.items) |qid| _ = try handled.appendUnique(qid);

        const root_action: []const u8 = if (dry_run)
            if (std.mem.eql(u8, mode, "redact")) "would_redact" else "would_delete"
        else if (std.mem.eql(u8, mode, "redact"))
            "redacted"
        else
            "deleted";
        const dependent_action: []const u8 = if (dry_run) "would_invalidate" else "invalidated";
        const core_action: []const u8 = if (dry_run) "would_contaminate" else "contaminated";

        for (selected_qids.items.items) |qid| {
            const node = (try self.store.getNode(allocator, qid)) orelse continue;
            defer self.store.freeNode(allocator, node);
            roots_matched += 1;
            try report.append(allocator, qid, labelType(node.label), root_action);

            // The root and its chunks: the evidence the closure starts from.
            var forgotten = forgetting.QidList.init(allocator);
            defer forgotten.deinit();
            _ = try forgotten.appendUnique(qid);
            // Chunks hold the message's raw text, so they are forgotten with
            // it regardless of `propagate`.
            const chunk_count = if (std.mem.eql(u8, node.label, "Message"))
                try self.forgetMessageChunks(allocator, qid, reason, mode, dry_run, &report, root_action, &handled, &forgotten)
            else
                0;

            if (!dry_run) {
                try self.tombstoneNode(allocator, node, reason, mode);
                if (std.mem.eql(u8, mode, "redact")) {
                    nodes_redacted += 1 + chunk_count;
                } else {
                    nodes_deleted += 1 + chunk_count;
                }
            }
            if (!propagate) continue;

            var dependents = try self.dependentClosure(allocator, forgotten.items.items, &handled);
            defer dependents.deinit();
            try self.appendOrphanedEntities(allocator, forgotten.items.items, &handled, &dependents);
            for (dependents.items.items) |dependent| {
                if (isFactLikeType(dependent.type)) facts_invalidated += 1;
                try report.append(allocator, dependent.qid, dependent.type, dependent_action);
            }
            for (forgotten.items.items) |source| {
                try self.appendCoreClosureRefs(allocator, source, &contaminated_core_qids, &handled, &report, core_action);
            }
            for (dependents.items.items) |dependent| {
                try self.appendCoreClosureRefs(allocator, dependent.qid, &contaminated_core_qids, &handled, &report, core_action);
            }
            if (!dry_run) {
                for (dependents.items.items) |dependent| {
                    try self.tombstoneQid(allocator, dependent.qid, reason, "hard_delete");
                }
            }
        }
        summaries_contaminated = contaminated_core_qids.items.items.len;
        if (!dry_run and propagate) {
            for (contaminated_core_qids.items.items) |core_qid| {
                try self.tombstoneQid(allocator, core_qid, reason, mode);
            }
        }

        const deletion_qid = try self.nextQid(allocator, "del");
        defer allocator.free(deletion_qid);
        const status = if (dry_run) "planned" else "completed";
        const event_payload = try stringifyAlloc(allocator, .{
            .method = "memory.forget",
            .deletionRequestQid = deletion_qid,
            .status = status,
            .dryRun = dry_run,
            .rootsMatched = roots_matched,
            .nodesDeleted = nodes_deleted,
            .nodesRedacted = nodes_redacted,
            .factsInvalidated = facts_invalidated,
            .summariesContaminated = summaries_contaminated,
            .reason = reason,
            .report = report.items.items,
        });
        defer allocator.free(event_payload);
        _ = try self.publishEvent(streams.forget_completed, event_payload);
        _ = try self.publishEvent(streams.audit, event_payload);

        const response = .{
            .jsonrpc = "2.0",
            .id = id,
            .result = .{
                .deletionRequestQid = deletion_qid,
                .status = status,
                .dryRun = dry_run,
                .rootsMatched = roots_matched,
                .nodesDeleted = nodes_deleted,
                .nodesRedacted = nodes_redacted,
                .factsInvalidated = facts_invalidated,
                .summariesContaminated = summaries_contaminated,
                .jobsQueued = &[_][]const u8{},
                .report = report.items.items,
            },
        };
        return stringifyAlloc(allocator, response);
    }

    fn collectForgetRoots(
        self: *Runtime,
        allocator: std.mem.Allocator,
        selector: *const ObjectMap,
        scope: Scope,
        window: EventWindow,
        selected_qids: *OwnedQids,
    ) !void {
        if (arrayValue(selector.get("qids"))) |qids| {
            for (qids.items) |qid_value| {
                const qid = stringValue(qid_value) orelse continue;
                try self.selectForgetRoot(allocator, qid, scope, window, selected_qids, false);
            }
        }

        const query = stringField(selector, "query") orelse return;
        if (query.len == 0) return;
        // Every match, not a top-k: a forget selector must not miss evidence
        // because it ranked low.
        const hits = try self.store.fullTextSearch(allocator, .{ .text = query, .limit = storage.unlimited });
        defer freeHits(allocator, hits);
        for (hits) |hit| {
            try self.selectForgetRoot(allocator, hit.qid, scope, window, selected_qids, true);
        }
    }

    /// Adds `qid` as a forget root. A chunk resolves to its parent message so
    /// the whole message and all of its chunks are forgotten together, and a
    /// Session or Turn root also selects the messages it contains.
    fn selectForgetRoot(
        self: *Runtime,
        allocator: std.mem.Allocator,
        qid: []const u8,
        scope: Scope,
        window: EventWindow,
        selected_qids: *OwnedQids,
        from_query: bool,
    ) !void {
        var node = (try self.store.getNode(allocator, qid)) orelse return;
        defer self.store.freeNode(allocator, node);
        if (std.mem.eql(u8, node.label, "Chunk")) {
            const parent_qid = (try readOptionalPropertyString(allocator, node.properties_json, "messageQid")) orelse return;
            defer allocator.free(parent_qid);
            const parent = (try self.store.getNode(allocator, parent_qid)) orelse return;
            self.store.freeNode(allocator, node);
            node = parent;
        }
        if (from_query and isInternalLabel(node.label)) return;
        if (try propertyBool(allocator, node.properties_json, "deleted")) return;
        if (!try scope.matchesNode(allocator, node)) return;
        if (!try nodeWithinEventWindow(allocator, node, window)) return;
        try selected_qids.appendUnique(allocator, node.qid);

        if (std.mem.eql(u8, node.label, "Session")) {
            const turn_edges = try self.store.findEdges(allocator, .{ .from_qid = node.qid, .edge_type = "HAS_TURN", .limit = storage.unlimited });
            defer self.store.freeEdges(allocator, turn_edges);
            for (turn_edges) |edge| {
                try self.selectTurnMessages(allocator, edge.to_qid, selected_qids);
            }
        } else if (std.mem.eql(u8, node.label, "Turn")) {
            try self.selectTurnMessages(allocator, node.qid, selected_qids);
        }
    }

    fn selectTurnMessages(self: *Runtime, allocator: std.mem.Allocator, turn_qid: []const u8, selected_qids: *OwnedQids) !void {
        const message_edges = try self.store.findEdges(allocator, .{ .from_qid = turn_qid, .edge_type = "HAS_MESSAGE", .limit = storage.unlimited });
        defer self.store.freeEdges(allocator, message_edges);
        for (message_edges) |edge| {
            const message = (try self.store.getNode(allocator, edge.to_qid)) orelse continue;
            defer self.store.freeNode(allocator, message);
            if (!std.mem.eql(u8, message.label, "Message")) continue;
            if (try propertyBool(allocator, message.properties_json, "deleted")) continue;
            try selected_qids.appendUnique(allocator, message.qid);
        }
    }

    /// Tombstones (or, on a dry run, only reports) every live chunk of a
    /// message, and adds each to `forgotten`. Uses HAS_CHUNK edges rather
    /// than node enumeration.
    fn forgetMessageChunks(
        self: *Runtime,
        allocator: std.mem.Allocator,
        message_qid: []const u8,
        reason: []const u8,
        mode: []const u8,
        dry_run: bool,
        report: *OwnedForgetReport,
        action: []const u8,
        handled: *forgetting.QidList,
        forgotten: *forgetting.QidList,
    ) !usize {
        const chunk_edges = try self.store.findEdges(allocator, .{ .from_qid = message_qid, .edge_type = "HAS_CHUNK", .limit = storage.unlimited });
        defer self.store.freeEdges(allocator, chunk_edges);
        var count: usize = 0;
        for (chunk_edges) |edge| {
            const chunk = (try self.store.getNode(allocator, edge.to_qid)) orelse continue;
            defer self.store.freeNode(allocator, chunk);
            if (!std.mem.eql(u8, chunk.label, "Chunk")) continue;
            if (try propertyBool(allocator, chunk.properties_json, "deleted")) continue;
            _ = try forgotten.appendUnique(chunk.qid);
            if (!try handled.appendUnique(chunk.qid)) continue;
            try report.append(allocator, chunk.qid, "chunk", action);
            if (!dry_run) try self.tombstoneNode(allocator, chunk, reason, mode);
            count += 1;
        }
        return count;
    }

    /// Live nodes derived from any of `seeds`, transitively and whatever their
    /// label: anything with an EVIDENCED_BY or DERIVED_FROM edge (or an
    /// `evidenceQid`) to forgotten evidence, then anything derived from those.
    /// Chunks are raw parts of their message, forgotten with it, so they are
    /// never dependents. Skips and records nodes in `handled`.
    fn dependentClosure(
        self: *Runtime,
        allocator: std.mem.Allocator,
        seeds: []const []const u8,
        handled: *forgetting.QidList,
    ) !OwnedNodeRefs {
        var refs = OwnedNodeRefs{ .allocator = allocator };
        errdefer refs.deinit();
        var queue = forgetting.QidList.init(allocator);
        defer queue.deinit();
        for (seeds) |seed| _ = try queue.appendUnique(seed);

        var position: usize = 0;
        while (position < queue.items.items.len) : (position += 1) {
            var direct = try forgetting.dependentQids(allocator, self.store, queue.items.items[position]);
            defer direct.deinit();
            for (direct.items.items) |dependent_qid| {
                if (handled.contains(dependent_qid)) continue;
                const node = (try self.store.getNode(allocator, dependent_qid)) orelse continue;
                defer self.store.freeNode(allocator, node);
                if (std.mem.eql(u8, node.label, "Chunk")) continue;
                if (try propertyBool(allocator, node.properties_json, "deleted")) continue;
                _ = try handled.appendUnique(dependent_qid);
                try refs.append(allocator, dependent_qid, labelType(node.label), "derived_from");
                _ = try queue.appendUnique(dependent_qid);
            }
        }
        return refs;
    }

    /// Adds to `dependents` each live entity that `sources` mention and that
    /// no node outside this request mentions: its name came only from
    /// forgotten text.
    fn appendOrphanedEntities(
        self: *Runtime,
        allocator: std.mem.Allocator,
        sources: []const []const u8,
        handled: *forgetting.QidList,
        dependents: *OwnedNodeRefs,
    ) !void {
        const Context = struct {
            handled: *const forgetting.QidList,

            fn isForgotten(context: @This(), inner_allocator: std.mem.Allocator, store: storage.Adapter, qid: []const u8) !bool {
                if (context.handled.contains(qid)) return true;
                const node = (try store.getNode(inner_allocator, qid)) orelse return true;
                defer store.freeNode(inner_allocator, node);
                return propertyBool(inner_allocator, node.properties_json, "deleted");
            }
        };
        for (sources) |source| {
            var entities = try forgetting.orphanedEntityQids(allocator, self.store, source, Context{ .handled = handled }, Context.isForgotten);
            defer entities.deinit();
            for (entities.items.items) |entity_qid| {
                if (handled.contains(entity_qid)) continue;
                const node = (try self.store.getNode(allocator, entity_qid)) orelse continue;
                defer self.store.freeNode(allocator, node);
                if (try propertyBool(allocator, node.properties_json, "deleted")) continue;
                _ = try handled.appendUnique(entity_qid);
                try dependents.append(allocator, entity_qid, labelType(node.label), "mentioned_by");
            }
        }
    }

    /// Adds every live node compiled from `source_qid` (core blocks, through
    /// COMPILED_FROM edges) to the contaminated set.
    fn appendCoreClosureRefs(
        self: *Runtime,
        allocator: std.mem.Allocator,
        source_qid: []const u8,
        contaminated_core_qids: *OwnedQids,
        handled: *const forgetting.QidList,
        report: *OwnedForgetReport,
        action: []const u8,
    ) !void {
        var blocks = try forgetting.compiledFromQids(allocator, self.store, source_qid);
        defer blocks.deinit();
        for (blocks.items.items) |block_qid| {
            if (contaminated_core_qids.contains(block_qid) or handled.contains(block_qid)) continue;
            const node = (try self.store.getNode(allocator, block_qid)) orelse continue;
            defer self.store.freeNode(allocator, node);
            if (try propertyBool(allocator, node.properties_json, "deleted")) continue;
            try contaminated_core_qids.appendUnique(allocator, block_qid);
            try report.append(allocator, block_qid, labelType(node.label), action);
        }
    }

    fn memoryFeedback(self: *Runtime, allocator: std.mem.Allocator, id: ?[]const u8, params: *const ObjectMap) ![]u8 {
        const retrieval_id = stringField(params, "retrievalId") orelse {
            return errorResponse(allocator, id, "invalid_request", "retrievalId is required");
        };
        const rating = stringField(params, "rating") orelse {
            return errorResponse(allocator, id, "invalid_request", "rating is required");
        };
        const feedback_qid = try self.nextQid(allocator, "fb");
        defer allocator.free(feedback_qid);
        const props = try stringifyAlloc(allocator, .{
            .kind = "feedback",
            .retrievalId = retrieval_id,
            .rating = rating,
            .deleted = false,
        });
        defer allocator.free(props);
        try self.store.putNode(.{ .qid = feedback_qid, .label = "Feedback", .properties_json = props });

        const event_payload = try stringifyAlloc(allocator, .{
            .method = "memory.feedback",
            .status = "stored",
            .feedbackQid = feedback_qid,
            .retrievalId = retrieval_id,
            .rating = rating,
        });
        defer allocator.free(event_payload);
        _ = try self.publishEvent(streams.feedback_received, event_payload);
        _ = try self.publishEvent(streams.audit, event_payload);

        const response = .{
            .jsonrpc = "2.0",
            .id = id,
            .result = .{
                .feedbackQid = feedback_qid,
                .queuedJobs = &[_][]const u8{},
                .status = "stored",
            },
        };
        return stringifyAlloc(allocator, response);
    }

    fn memoryCoreUpdate(self: *Runtime, allocator: std.mem.Allocator, id: ?[]const u8, params: *const ObjectMap) ![]u8 {
        const block_key = stringField(params, "blockKey") orelse {
            return errorResponse(allocator, id, "invalid_request", "blockKey is required");
        };
        const text = stringField(params, "text") orelse {
            return errorResponse(allocator, id, "invalid_request", "text is required");
        };
        const mode = stringField(params, "mode") orelse "replace";
        const managed_by = stringField(params, "managedBy") orelse "user";
        const scope = parseScope(params);

        var status: []const u8 = "stored";
        const existing_qid = if (std.mem.eql(u8, mode, "replace")) try self.findCoreBlockQid(allocator, scope, block_key) else null;
        defer if (existing_qid) |qid| allocator.free(qid);

        const block_qid = if (existing_qid) |qid| try allocator.dupe(u8, qid) else try self.nextQid(allocator, "core");
        defer allocator.free(block_qid);
        if (existing_qid != null) status = "updated";

        const props = try stringifyAlloc(allocator, .{
            .kind = "core",
            .blockKey = block_key,
            .text = text,
            .managedBy = managed_by,
            .tenantId = scope.tenant_id,
            .userId = scope.user_id,
            .agentId = scope.agent_id,
            .projectId = scope.project_id,
            .deleted = false,
        });
        defer allocator.free(props);
        try self.store.putNode(.{ .qid = block_qid, .label = "Core", .properties_json = props });

        const event_payload = try stringifyAlloc(allocator, .{
            .method = "memory.core.update",
            .status = status,
            .blockQid = block_qid,
            .blockKey = block_key,
            .managedBy = managed_by,
        });
        defer allocator.free(event_payload);
        _ = try self.publishEvent(streams.audit, event_payload);

        const response = .{
            .jsonrpc = "2.0",
            .id = id,
            .result = .{
                .blockQid = block_qid,
                .status = status,
            },
        };
        return stringifyAlloc(allocator, response);
    }

    fn memoryCoreGet(self: *Runtime, allocator: std.mem.Allocator, id: ?[]const u8, params: *const ObjectMap) ![]u8 {
        const scope = parseScope(params);
        const requested_key = stringField(params, "blockKey");
        const key_match = [_]storage.PropertyMatch{.{ .name = "blockKey", .value = requested_key orelse "" }};
        var core_nodes = self.store.iterateNodes(allocator, .{
            .label = "Core",
            .where = if (requested_key != null) &key_match else &.{},
        });
        defer core_nodes.deinit();

        var blocks = std.ArrayList(CoreBlockResult).empty;
        defer {
            for (blocks.items) |block| {
                allocator.free(block.qid);
                allocator.free(block.blockKey);
                allocator.free(block.text);
                allocator.free(block.managedBy);
                for (block.evidenceQids) |qid| allocator.free(qid);
                allocator.free(block.evidenceQids);
            }
            blocks.deinit(allocator);
        }

        while (try core_nodes.next()) |core_qid| {
            const node = (try self.store.getNode(allocator, core_qid)) orelse continue;
            defer self.store.freeNode(allocator, node);
            if (!std.mem.eql(u8, node.label, "Core")) continue;
            if (try propertyBool(allocator, node.properties_json, "deleted")) continue;
            if (!try scope.matchesNode(allocator, node)) continue;
            const block_key = try readPropertyString(allocator, node.properties_json, "blockKey");
            errdefer allocator.free(block_key);
            if (requested_key) |wanted| {
                if (!std.mem.eql(u8, wanted, block_key)) {
                    allocator.free(block_key);
                    continue;
                }
            }
            const text = try readPropertyString(allocator, node.properties_json, "text");
            errdefer allocator.free(text);
            const managed_by = try readPropertyString(allocator, node.properties_json, "managedBy");
            errdefer allocator.free(managed_by);
            const evidence_qids = try readStringArrayProperty(allocator, node.properties_json, "evidenceQids");
            errdefer {
                for (evidence_qids) |qid| allocator.free(qid);
                allocator.free(evidence_qids);
            }
            try blocks.append(allocator, .{
                .qid = try allocator.dupe(u8, node.qid),
                .blockKey = block_key,
                .scope = scope.json(),
                .text = text,
                .managedBy = managed_by,
                .evidenceQids = evidence_qids,
            });
        }

        const response = .{
            .jsonrpc = "2.0",
            .id = id,
            .result = .{ .blocks = blocks.items },
        };
        return stringifyAlloc(allocator, response);
    }

    fn memoryCoreConsolidate(self: *Runtime, allocator: std.mem.Allocator, id: ?[]const u8, params: *const ObjectMap) ![]u8 {
        const scope = parseScope(params);
        const block_key = stringField(params, "blockKey") orelse "project_summary";
        const requested_limit = integerField(params, "limit") orelse 50;
        if (requested_limit <= 0) {
            return errorResponse(allocator, id, "invalid_request", "limit must be greater than zero");
        }
        const limit = @as(usize, @intCast(requested_limit));

        var summary_writer: std.Io.Writer.Allocating = .init(allocator);
        defer summary_writer.deinit();
        try summary_writer.writer.writeAll("Consolidated memory:");

        var evidence_qids = std.ArrayList([]const u8).empty;
        defer {
            for (evidence_qids.items) |qid| allocator.free(qid);
            evidence_qids.deinit(allocator);
        }

        // Oldest first across the whole store, paged, until `limit` sources.
        var candidates = self.store.iterateNodes(allocator, .{});
        defer candidates.deinit();
        while (try candidates.next()) |candidate_qid| {
            if (evidence_qids.items.len >= limit) break;
            const node = (try self.store.getNode(allocator, candidate_qid)) orelse continue;
            defer self.store.freeNode(allocator, node);
            if (!isConsolidatableLabel(node.label)) continue;
            if (try propertyBool(allocator, node.properties_json, "deleted")) continue;
            if (!try scope.matchesNode(allocator, node)) continue;
            if (isDerivedLabel(node.label) and !try propertyEquals(allocator, node.properties_json, "state", "current")) continue;
            const text = textForNode(allocator, node) catch continue;
            defer allocator.free(text);
            try summary_writer.writer.print("\n- ({s}) {s}", .{ node.qid, text });
            try evidence_qids.append(allocator, try allocator.dupe(u8, node.qid));
        }

        const existing_qid = try self.findCoreBlockQid(allocator, scope, block_key);
        defer if (existing_qid) |qid| allocator.free(qid);
        const block_qid = if (existing_qid) |qid| try allocator.dupe(u8, qid) else try self.nextQid(allocator, "core");
        defer allocator.free(block_qid);
        const status: []const u8 = if (existing_qid == null) "stored" else "updated";

        const summary_text = try summary_writer.toOwnedSlice();
        defer allocator.free(summary_text);
        const props = try stringifyAlloc(allocator, .{
            .kind = "core",
            .qtype = "core",
            .blockKey = block_key,
            .text = summary_text,
            .managedBy = "agent",
            .evidenceQids = evidence_qids.items,
            .tenantId = scope.tenant_id,
            .userId = scope.user_id,
            .agentId = scope.agent_id,
            .projectId = scope.project_id,
            .deleted = false,
        });
        defer allocator.free(props);
        try self.store.putNode(.{ .qid = block_qid, .label = "Core", .properties_json = props });

        for (evidence_qids.items) |source_qid| {
            try self.putDeterministicEdge(allocator, block_qid, source_qid, "COMPILED_FROM");
        }

        const event_payload = try stringifyAlloc(allocator, .{
            .method = "memory.core.consolidate",
            .status = status,
            .blockQid = block_qid,
            .blockKey = block_key,
            .sourceCount = evidence_qids.items.len,
        });
        defer allocator.free(event_payload);
        _ = try self.publishEvent(streams.consolidate_completed, event_payload);
        _ = try self.publishEvent(streams.audit, event_payload);

        const response = .{
            .jsonrpc = "2.0",
            .id = id,
            .result = .{
                .blockQid = block_qid,
                .blockKey = block_key,
                .status = status,
                .sourceCount = evidence_qids.items.len,
            },
        };
        return stringifyAlloc(allocator, response);
    }

    fn putEdge(self: *Runtime, allocator: std.mem.Allocator, from_qid: []const u8, to_qid: []const u8, edge_type: []const u8) !void {
        const edge_qid = try self.nextQid(allocator, "edge");
        defer allocator.free(edge_qid);
        try self.store.putEdge(.{
            .qid = edge_qid,
            .from_qid = from_qid,
            .to_qid = to_qid,
            .edge_type = edge_type,
            .properties_json = "{}",
        });
    }

    fn putDeterministicEdge(self: *Runtime, allocator: std.mem.Allocator, from_qid: []const u8, to_qid: []const u8, edge_type: []const u8) !void {
        const key = try std.fmt.allocPrint(allocator, "{s}:{s}:{s}", .{ from_qid, edge_type, to_qid });
        defer allocator.free(key);
        const edge_qid = try hashQid(allocator, "edge", key);
        defer allocator.free(edge_qid);
        try self.store.putEdge(.{
            .qid = edge_qid,
            .from_qid = from_qid,
            .to_qid = to_qid,
            .edge_type = edge_type,
            .properties_json = "{}",
        });
    }

    fn publishEvent(self: *Runtime, stream: []const u8, payload_json: []const u8) !storage.StreamEntry {
        return self.store.appendStream(stream, payload_json);
    }

    /// Every audit event whose payload names `qid` as a JSON string, read a
    /// page at a time to the end of the stream.
    fn auditEventsForQid(self: *Runtime, allocator: std.mem.Allocator, qid: []const u8) !OwnedAuditEvents {
        const needle = try std.fmt.allocPrint(allocator, "\"{s}\"", .{qid});
        defer allocator.free(needle);

        var audit = OwnedAuditEvents{ .allocator = allocator };
        errdefer audit.deinit();
        var after: u64 = 0;
        while (true) {
            const entries = try self.store.readStream(allocator, streams.audit, after, audit_page_size);
            defer freeStreamEntries(allocator, entries);
            if (entries.len == 0) break;
            for (entries) |entry| {
                after = @max(after, entry.sequence);
                if (std.mem.indexOf(u8, entry.payload_json, needle) == null) continue;
                try audit.append(allocator, entry.stream, entry.sequence, entry.payload_json);
            }
            if (entries.len < audit_page_size) break;
        }
        return audit;
    }

    fn extractFromMessage(
        self: *Runtime,
        allocator: std.mem.Allocator,
        scope: Scope,
        message_qid: []const u8,
        content: []const u8,
        created_at: ?[]const u8,
    ) !usize {
        const plugin = providers.deterministicExtractor();
        const extracted = plugin.extract(content);
        var written: usize = 0;
        for (extracted.items[0..extracted.len]) |candidate| {
            self.writeExtractedMemory(allocator, scope, message_qid, content, created_at, candidate) catch |err| switch (err) {
                error.InvalidExtractionCandidate => continue,
                else => return err,
            };
            written += 1;
        }
        return written;
    }

    fn writeExtractedMemory(
        self: *Runtime,
        allocator: std.mem.Allocator,
        scope: Scope,
        message_qid: []const u8,
        quote: []const u8,
        created_at: ?[]const u8,
        candidate: extractor.Candidate,
    ) !void {
        extractor.validateCandidate(candidate) catch {
            return error.InvalidExtractionCandidate;
        };

        const label = extractor.labelName(candidate.label);
        if (std.mem.eql(u8, candidate.aggregation_mode, "single_value")) {
            try self.supersedeCurrentSlot(allocator, scope, candidate.slot_key, candidate.valid_from orelse created_at);
        }
        const qid = try self.nextQid(allocator, extractor.qidPrefix(candidate.label));
        defer allocator.free(qid);
        const quote_for_props = try clampPropertyText(allocator, quote);
        defer allocator.free(quote_for_props);
        const valid_from = candidate.valid_from orelse created_at;
        const props = try stringifyAlloc(allocator, .{
            .kind = labelType(label),
            .text = candidate.text,
            .slotKey = candidate.slot_key,
            .subject = candidate.subject,
            .attribute = candidate.attribute,
            .value = candidate.value,
            .numericValue = candidate.numeric_value,
            .unit = candidate.unit,
            .aggregationMode = candidate.aggregation_mode,
            .state = "current",
            .validFrom = valid_from,
            .validTo = candidate.valid_to,
            .evidenceQid = message_qid,
            .quote = quote_for_props,
            .tenantId = scope.tenant_id,
            .userId = scope.user_id,
            .agentId = scope.agent_id,
            .projectId = scope.project_id,
            .deleted = false,
        });
        defer allocator.free(props);
        try self.store.putNode(.{ .qid = qid, .label = label, .properties_json = props });
        try self.putEdge(allocator, qid, message_qid, "EVIDENCED_BY");
        try self.writeMemoryCardForCandidate(allocator, scope, message_qid, quote, created_at, candidate);
    }

    fn writeMemoryCardForCandidate(
        self: *Runtime,
        allocator: std.mem.Allocator,
        scope: Scope,
        message_qid: []const u8,
        quote: []const u8,
        created_at: ?[]const u8,
        candidate: extractor.Candidate,
    ) !void {
        const key = try std.fmt.allocPrint(allocator, "{s}:{s}:{s}", .{ message_qid, candidate.slot_key, candidate.value });
        defer allocator.free(key);
        const card_qid = try hashQid(allocator, "card", key);
        defer allocator.free(card_qid);
        const related_card_qids = try self.relatedCardQidsForCandidate(allocator, scope, card_qid, candidate);
        defer {
            for (related_card_qids) |qid| allocator.free(qid);
            allocator.free(related_card_qids);
        }
        const quote_for_props = try clampPropertyText(allocator, quote);
        defer allocator.free(quote_for_props);
        const props = try stringifyAlloc(allocator, .{
            .kind = "memory_card",
            .qtype = "memory_card",
            .cardKind = memoryCardKind(candidate.label),
            .text = candidate.text,
            .contextDescription = "Deterministic extraction from raw message.",
            .contextualDescription = cardContextualDescription(candidate),
            .keywords = cardKeywords(candidate),
            .tags = cardTags(candidate),
            .importance = cardImportance(candidate),
            .utility = @as(f32, 0.5),
            .relatedCardQids = related_card_qids,
            .slotKey = candidate.slot_key,
            .subject = candidate.subject,
            .attribute = candidate.attribute,
            .value = candidate.value,
            .numericValue = candidate.numeric_value,
            .unit = candidate.unit,
            .aggregationMode = candidate.aggregation_mode,
            .state = "current",
            .validFrom = candidate.valid_from orelse created_at,
            .validTo = candidate.valid_to,
            .evidenceQid = message_qid,
            .quote = quote_for_props,
            .tenantId = scope.tenant_id,
            .userId = scope.user_id,
            .agentId = scope.agent_id,
            .projectId = scope.project_id,
            .deleted = false,
        });
        defer allocator.free(props);
        try self.store.putNode(.{ .qid = card_qid, .label = "MemoryCard", .properties_json = props });
        try self.putDeterministicEdge(allocator, card_qid, message_qid, "EVIDENCED_BY");
        for (related_card_qids) |related_qid| {
            try self.putDeterministicEdge(allocator, card_qid, related_qid, "RELATED_TO");
        }
    }

    /// Up to `related_card_limit` live cards in scope that share the
    /// candidate's slot, newest first, then cards of the same kind, newest
    /// first.
    fn relatedCardQidsForCandidate(
        self: *Runtime,
        allocator: std.mem.Allocator,
        scope: Scope,
        card_qid: []const u8,
        candidate: extractor.Candidate,
    ) ![]const []const u8 {
        var related = std.ArrayList([]const u8).empty;
        errdefer {
            for (related.items) |qid| allocator.free(qid);
            related.deinit(allocator);
        }
        const lookups = [_]storage.PropertyMatch{
            .{ .name = "slotKey", .value = candidate.slot_key },
            .{ .name = "cardKind", .value = memoryCardKind(candidate.label) },
        };
        for (lookups) |match| {
            const where = [_]storage.PropertyMatch{match};
            var cards = self.store.iterateNodes(allocator, .{
                .label = "MemoryCard",
                .where = &where,
                .order = .newest_first,
                .limit = 64,
            });
            defer cards.deinit();
            while (try cards.next()) |qid| {
                if (related.items.len >= related_card_limit) break;
                if (std.mem.eql(u8, qid, card_qid) or stringListContains(related.items, qid)) continue;
                const node = (try self.store.getNode(allocator, qid)) orelse continue;
                defer self.store.freeNode(allocator, node);
                if (try propertyBool(allocator, node.properties_json, "deleted")) continue;
                if (!try scope.matchesNode(allocator, node)) continue;
                try related.append(allocator, try allocator.dupe(u8, node.qid));
            }
        }
        return related.toOwnedSlice(allocator);
    }

    /// Embeds, in batched requests, the index text of each vector-indexed node
    /// memory.remember will write for `messages`: unchunked messages, the
    /// chunks of long ones and deterministic extractions. Stops at the first
    /// invalid message, where the write loop stops too. Best effort: putNode
    /// embeds any text the prefetch missed.
    fn prefetchRememberEmbeddings(
        self: *Runtime,
        allocator: std.mem.Allocator,
        messages: []const Value,
        extract_enabled: bool,
    ) !void {
        var texts = std.ArrayList([]const u8).empty;
        defer texts.deinit(allocator);
        for (messages) |message_value| {
            const message = objectValue(message_value) orelse break;
            if (stringField(&message, "role") == null) break;
            const content = stringField(&message, "content") orelse break;
            if (content.len == 0) break;

            const chunk_ends = try messageChunkEnds(allocator, content);
            defer allocator.free(chunk_ends);
            if (chunk_ends.len > 1) {
                var start: usize = 0;
                for (chunk_ends) |end| {
                    try texts.append(allocator, content[start..end]);
                    start = end;
                }
            } else {
                try texts.append(allocator, content);
            }

            if (extract_enabled) {
                const extracted = providers.deterministicExtractor().extract(content);
                for (extracted.items[0..extracted.len]) |candidate| {
                    extractor.validateCandidate(candidate) catch continue;
                    try texts.append(allocator, candidate.text);
                }
            }
        }
        self.store.prefetchEmbeddings(texts.items) catch {};
    }

    /// Writes one Chunk node per slice of `content`, linked by
    /// Message-[HAS_CHUNK]->Chunk and Chunk-[EVIDENCED_BY]->Message.
    /// Chunk qids and edges are deterministic so they do not consume runtime ids.
    fn writeMessageChunks(
        self: *Runtime,
        allocator: std.mem.Allocator,
        meta: MessageMeta,
        content: []const u8,
        chunk_ends: []const usize,
    ) !void {
        var start: usize = 0;
        for (chunk_ends, 0..) |end, chunk_index| {
            const chunk_qid = try chunkQid(allocator, meta.message_qid, chunk_index);
            defer allocator.free(chunk_qid);
            const props = try stringifyAlloc(allocator, .{
                .kind = "chunk",
                .content = content[start..end],
                .role = meta.role,
                .createdAt = meta.created_at,
                .messageQid = meta.message_qid,
                .chunkIndex = chunk_index,
                .chunkCount = chunk_ends.len,
                .sessionQid = meta.session_qid,
                .sessionId = meta.session_id,
                .turnQid = meta.turn_qid,
                .messageIndex = meta.message_index,
                .tenantId = meta.scope.tenant_id,
                .userId = meta.scope.user_id,
                .agentId = meta.scope.agent_id,
                .projectId = meta.scope.project_id,
                .privacyClass = meta.privacy_class,
                .deleted = false,
            });
            defer allocator.free(props);
            try self.store.putNode(.{ .qid = chunk_qid, .label = "Chunk", .properties_json = props });
            try self.putDeterministicEdge(allocator, meta.message_qid, chunk_qid, "HAS_CHUNK");
            try self.putDeterministicEdge(allocator, chunk_qid, meta.message_qid, "EVIDENCED_BY");
            start = end;
        }
    }

    fn writeEpisodeForTurn(
        self: *Runtime,
        allocator: std.mem.Allocator,
        scope: Scope,
        session_qid: []const u8,
        turn_qid: []const u8,
        message_qids: []const []const u8,
        summary: []const u8,
        created_at: ?[]const u8,
    ) ![]u8 {
        const episode_qid = try hashQid(allocator, "ep", turn_qid);
        errdefer allocator.free(episode_qid);
        const episode_summary = summary[0..utf8PrefixLen(summary, 1024)];
        // While the episode only copies the first message it would duplicate
        // raw evidence in search, so it is kept out of the lexical/vector index.
        const props = try stringifyAlloc(allocator, .{
            .kind = "episode",
            .qtype = "episode",
            .episodeType = "conversation",
            .searchable = false,
            .sessionQid = session_qid,
            .turnQid = turn_qid,
            .summary = episode_summary,
            .text = episode_summary,
            .eventTime = created_at,
            .state = "current",
            .evidenceQid = if (message_qids.len > 0) message_qids[0] else null,
            .quote = episode_summary,
            .tenantId = scope.tenant_id,
            .userId = scope.user_id,
            .agentId = scope.agent_id,
            .projectId = scope.project_id,
            .evidenceQids = message_qids,
            .deleted = false,
        });
        defer allocator.free(props);
        try self.store.putNode(.{ .qid = episode_qid, .label = "Episode", .properties_json = props });
        try self.putDeterministicEdge(allocator, episode_qid, turn_qid, "DERIVED_FROM");
        for (message_qids) |message_qid| {
            try self.putDeterministicEdge(allocator, episode_qid, message_qid, "DERIVED_FROM");
        }
        return episode_qid;
    }

    fn writeToolCalls(self: *Runtime, allocator: std.mem.Allocator, params: *const ObjectMap, scope: Scope, turn_qid: []const u8) !usize {
        const calls = arrayValue(params.get("toolCalls")) orelse return 0;
        var written: usize = 0;
        for (calls.items) |call_value| {
            const call = objectValue(call_value) orelse return error.InvalidRequest;
            const tool_name = stringField(&call, "toolName") orelse stringField(&call, "name") orelse return error.InvalidRequest;
            const call_qid = try self.nextQid(allocator, "tool");
            defer allocator.free(call_qid);
            const props = try stringifyAlloc(allocator, .{
                .kind = "tool_call",
                .qtype = "tool_call",
                .toolName = tool_name,
                .inputJson = stringField(&call, "inputJson") orelse "{}",
                .outputJson = stringField(&call, "outputJson") orelse "{}",
                .status = stringField(&call, "status") orelse "success",
                .errorText = stringField(&call, "errorText"),
                .tenantId = scope.tenant_id,
                .userId = scope.user_id,
                .agentId = scope.agent_id,
                .projectId = scope.project_id,
                .deleted = false,
            });
            defer allocator.free(props);
            try self.store.putNode(.{ .qid = call_qid, .label = "ToolCall", .properties_json = props });
            try self.putEdge(allocator, turn_qid, call_qid, "HAS_TOOL_CALL");
            written += 1;
        }
        return written;
    }

    fn writeObservations(self: *Runtime, allocator: std.mem.Allocator, params: *const ObjectMap, scope: Scope, turn_qid: []const u8) !usize {
        const observations = arrayValue(params.get("observations")) orelse return 0;
        var written: usize = 0;
        for (observations.items) |observation_value| {
            const observation = objectValue(observation_value) orelse return error.InvalidRequest;
            const content = stringField(&observation, "content") orelse stringField(&observation, "text") orelse return error.InvalidRequest;
            const observation_qid = try self.nextQid(allocator, "obs");
            defer allocator.free(observation_qid);
            const props = try stringifyAlloc(allocator, .{
                .kind = "observation",
                .qtype = "observation",
                .observationType = stringField(&observation, "type") orelse "generic",
                .content = content,
                .text = content,
                .createdAt = stringField(&observation, "createdAt"),
                .tenantId = scope.tenant_id,
                .userId = scope.user_id,
                .agentId = scope.agent_id,
                .projectId = scope.project_id,
                .deleted = false,
            });
            defer allocator.free(props);
            try self.store.putNode(.{ .qid = observation_qid, .label = "Observation", .properties_json = props });
            try self.putEdge(allocator, turn_qid, observation_qid, "HAS_OBSERVATION");
            written += 1;
        }
        return written;
    }

    /// Marks every current slot memory with `slot_key` in `scope` superseded.
    /// The slot and state indexes find them wherever they sit in the store.
    fn supersedeCurrentSlot(self: *Runtime, allocator: std.mem.Allocator, scope: Scope, slot_key: []const u8, valid_to: ?[]const u8) !void {
        const where = [_]storage.PropertyMatch{
            .{ .name = "slotKey", .value = slot_key },
            .{ .name = "state", .value = "current" },
        };
        var current = self.store.iterateNodes(allocator, .{ .where = &where });
        defer current.deinit();
        while (try current.next()) |qid| {
            const node = (try self.store.getNode(allocator, qid)) orelse continue;
            defer self.store.freeNode(allocator, node);
            if (!isSlotMemoryLabel(node.label)) continue;
            if (!try scope.matchesNode(allocator, node)) continue;
            if (try propertyBool(allocator, node.properties_json, "deleted")) continue;
            if (!try propertyEquals(allocator, node.properties_json, "slotKey", slot_key)) continue;
            if (!try propertyEquals(allocator, node.properties_json, "state", "current")) continue;
            try self.rewriteDerivedState(allocator, node, "superseded", valid_to);
        }
    }

    /// Sets `state` and `validTo` and keeps every other property, so a
    /// superseded card keeps its card fields and any label's extra fields
    /// survive.
    fn rewriteDerivedState(
        self: *Runtime,
        allocator: std.mem.Allocator,
        node: storage.Node,
        state: []const u8,
        valid_to: ?[]const u8,
    ) !void {
        var parsed = try std.json.parseFromSlice(Value, allocator, node.properties_json, .{});
        defer parsed.deinit();
        const arena = parsed.arena.allocator();
        switch (parsed.value) {
            .object => |*object| {
                try object.put(arena, "state", .{ .string = state });
                try object.put(arena, "validTo", if (valid_to) |value| .{ .string = value } else .null);
            },
            else => return error.InvalidRequest,
        }
        const props = try stringifyAlloc(allocator, parsed.value);
        defer allocator.free(props);
        try self.store.putNode(.{ .qid = node.qid, .label = node.label, .properties_json = props });
    }

    /// What `node` was derived or compiled from: the targets of its
    /// EVIDENCED_BY, DERIVED_FROM and COMPILED_FROM edges, plus the node its
    /// `evidenceQid` (or a chunk's `messageQid`) names when no edge records it.
    fn provenanceRefsForNode(self: *Runtime, allocator: std.mem.Allocator, node: storage.Node) !OwnedNodeRefs {
        var refs = OwnedNodeRefs{ .allocator = allocator };
        errdefer refs.deinit();
        var seen = forgetting.QidList.init(allocator);
        defer seen.deinit();

        const relations = [_][2][]const u8{
            .{ "EVIDENCED_BY", "evidenced_by" },
            .{ "DERIVED_FROM", "derived_from" },
            .{ forgetting.compiled_edge_type, "compiled_from" },
        };
        for (relations) |relation| {
            const edges = try self.store.findEdges(allocator, .{ .from_qid = node.qid, .edge_type = relation[0], .limit = storage.unlimited });
            defer self.store.freeEdges(allocator, edges);
            for (edges) |edge| {
                if (seen.contains(edge.to_qid)) continue;
                const target = (try self.store.getNode(allocator, edge.to_qid)) orelse continue;
                defer self.store.freeNode(allocator, target);
                _ = try seen.appendUnique(edge.to_qid);
                try refs.append(allocator, edge.to_qid, labelType(target.label), relation[1]);
            }
        }

        const property_key: []const u8 = if (std.mem.eql(u8, node.label, "Chunk")) "messageQid" else "evidenceQid";
        const evidence_qid = (try readOptionalPropertyString(allocator, node.properties_json, property_key)) orelse return refs;
        defer allocator.free(evidence_qid);
        if (seen.contains(evidence_qid)) return refs;
        const evidence_node = (try self.store.getNode(allocator, evidence_qid)) orelse return refs;
        defer self.store.freeNode(allocator, evidence_node);
        try refs.append(allocator, evidence_qid, labelType(evidence_node.label), "evidenced_by");
        return refs;
    }

    /// Live nodes derived directly from `evidence_qid`, whatever their label.
    /// Chunks are parts of their message, not derived memory.
    fn derivedRefsByEvidence(self: *Runtime, allocator: std.mem.Allocator, evidence_qid: []const u8) !OwnedNodeRefs {
        var direct = try forgetting.dependentQids(allocator, self.store, evidence_qid);
        defer direct.deinit();

        var refs = OwnedNodeRefs{ .allocator = allocator };
        errdefer refs.deinit();
        for (direct.items.items) |dependent_qid| {
            const node = (try self.store.getNode(allocator, dependent_qid)) orelse continue;
            defer self.store.freeNode(allocator, node);
            if (std.mem.eql(u8, node.label, "Chunk")) continue;
            if (try propertyBool(allocator, node.properties_json, "deleted")) continue;
            try refs.append(allocator, node.qid, labelType(node.label), "derived_from");
        }
        return refs;
    }

    fn tombstoneQid(self: *Runtime, allocator: std.mem.Allocator, qid: []const u8, reason: []const u8, mode: []const u8) !void {
        const node = (try self.store.getNode(allocator, qid)) orelse return;
        defer self.store.freeNode(allocator, node);
        try self.tombstoneNode(allocator, node, reason, mode);
    }

    /// Replaces a node's properties with a tombstone, which leaves every
    /// search and vector index. Raw text survives only as fingerprints for
    /// `verify leaks`. An existing tombstone is left as it is.
    fn tombstoneNode(self: *Runtime, allocator: std.mem.Allocator, node: storage.Node, reason: []const u8, mode: []const u8) !void {
        if (try propertyBool(allocator, node.properties_json, "deleted")) return;
        const fingerprints = try forgetting.fingerprintNode(allocator, node.label, node.properties_json);
        defer forgetting.freeFingerprints(allocator, fingerprints);
        const tombstone = try stringifyAlloc(allocator, .{
            .kind = "tombstone",
            .deleted = true,
            .state = if (std.mem.eql(u8, mode, "redact")) "redacted" else "deleted",
            .mode = mode,
            .reason = reason,
            .previousLabel = node.label,
            .leakFingerprints = fingerprints,
        });
        defer allocator.free(tombstone);
        try self.store.putNode(.{ .qid = node.qid, .label = node.label, .properties_json = tombstone });
    }

    fn nextQid(self: *Runtime, allocator: std.mem.Allocator, prefix: []const u8) ![]u8 {
        const id = self.next_id;
        self.next_id += 1;
        return std.fmt.allocPrint(allocator, "q_{s}_{d}", .{ prefix, id });
    }

    /// Optional cross-encoder stage between the raw-evidence policy and budget
    /// packing. The leading `settings.window` items go to the reranker and are
    /// reordered by descending relevance (ties keep fused order); window items
    /// the reranker did not score follow, then the rest in fused order. A
    /// failed call keeps the fused order. Returns null when no reranker is
    /// configured, so the response is unchanged.
    fn rerankItems(
        self: *Runtime,
        allocator: std.mem.Allocator,
        query: []const u8,
        results: *OwnedItems,
        settings: RerankSettings,
    ) !?OwnedRerankTrace {
        const endpoint = self.options.reranker;
        if (endpoint.kind == .none) return null;
        var stage = OwnedRerankTrace{ .allocator = allocator, .trace = .{ .model = endpoint.model, .status = "applied" } };
        errdefer stage.deinit();
        if (!settings.enabled) {
            stage.trace.status = "disabled";
            return stage;
        }
        const window = @min(settings.window, results.items.items.len);
        stage.trace.windowSize = window;
        if (window == 0) {
            stage.trace.status = "skipped";
            return stage;
        }

        const documents = try allocator.alloc([]const u8, window);
        var built: usize = 0;
        defer {
            for (documents[0..built]) |document| allocator.free(document);
            allocator.free(documents);
        }
        for (results.items.items[0..window]) |item| {
            documents[built] = try rerankDocument(allocator, item);
            built += 1;
        }

        const started = if (self.options.io) |io| std.Io.Timestamp.now(io, .awake) else null;
        const reranked = providers.rerank(allocator, self.options.io, endpoint, .{
            .query = query,
            .documents = documents,
            .top_n = window,
        });
        if (started) |timestamp| {
            const elapsed_ns: f64 = @floatFromInt(timestamp.untilNow(self.options.io.?, .awake).toNanoseconds());
            stage.trace.latencyMs = @round(elapsed_ns / 1000) / 1000;
        }
        const scores = reranked catch |err| {
            if (err == error.OutOfMemory) return err;
            stage.trace.status = "failed";
            stage.trace.@"error" = @errorName(err);
            return stage;
        };
        defer allocator.free(scores);
        stage.trace.rerankedCount = scores.len;

        const order = try rerankOrder(allocator, window, scores);
        defer allocator.free(order);
        const score_by_index = try allocator.alloc(f64, window);
        defer allocator.free(score_by_index);
        for (scores) |score| score_by_index[score.index] = score.relevance_score;
        for (order[0..@min(scores.len, rerank_trace_top_scores)]) |index| {
            const qid = try allocator.dupe(u8, results.items.items[index].qid);
            errdefer allocator.free(qid);
            try stage.top_scores.append(allocator, .{ .qid = qid, .score = score_by_index[index] });
        }
        try applyItemOrder(allocator, results.items.items[0..window], order);
        return stage;
    }

    fn collectItems(
        self: *Runtime,
        allocator: std.mem.Allocator,
        query: []const u8,
        mode: SearchMode,
        limit: usize,
        scope: Scope,
        include_deleted: bool,
        labels_value: ?Value,
        valid_at: ?[]const u8,
        event_window: EventWindow,
        include_evidence: bool,
        include_debug: bool,
    ) !OwnedItems {
        const hits = try self.collectSearchHits(allocator, query, mode, @max(limit * 4, limit));
        defer freeHits(allocator, hits);

        var owned = OwnedItems{ .allocator = allocator };
        errdefer owned.deinit();
        for (hits) |hit| {
            const node = (try self.store.getNode(allocator, hit.qid)) orelse continue;
            defer self.store.freeNode(allocator, node);
            if (!include_deleted and try propertyBool(allocator, node.properties_json, "deleted")) continue;
            if (!try scope.matchesNode(allocator, node)) continue;
            if (isInternalLabel(node.label) and !labelRequestedExplicitly(node.label, labels_value)) continue;
            if (isStructuralLabel(node.label) and !labelRequestedExplicitly(node.label, labels_value)) continue;
            if (isHiddenSearchLabel(node.label) and !labelRequestedExplicitly(node.label, labels_value)) continue;
            if (!labelAllowed(node.label, labels_value)) continue;
            // Chunked messages and copy-only episodes are reached through
            // their chunks/messages; never surface them as items themselves.
            if (try propertyIsFalse(allocator, node.properties_json, "searchable")) continue;
            if (!try nodeWithinEventWindow(allocator, node, event_window)) continue;
            if (!include_deleted and valid_at != null) {
                if (!try nodeActiveAt(allocator, node, valid_at.?)) continue;
            }
            if (!include_deleted and valid_at == null and isSlotMemoryLabel(node.label)) {
                if (!try propertyEquals(allocator, node.properties_json, "state", "current")) continue;
            }
            if (!include_deleted and isDerivedLabel(node.label)) {
                if (valid_at) |timestamp| {
                    if (!try derivedActiveAt(allocator, node, timestamp)) continue;
                } else {
                    if (!try propertyEquals(allocator, node.properties_json, "state", "current")) continue;
                }
            }

            const text = itemTextForNode(allocator, node) catch continue;
            errdefer allocator.free(text);
            const raw_source = try rawSourceForNode(allocator, node);
            errdefer if (raw_source) |source| source.deinit(allocator);
            const evidence = if (!include_evidence)
                try allocator.alloc(EvidenceResult, 0)
            else if (std.mem.eql(u8, node.label, "Chunk"))
                try chunkEvidence(allocator, node, raw_source)
            else
                try evidenceForNode(allocator, node);
            errdefer freeEvidence(allocator, evidence);
            const state = try stateForNode(allocator, node);
            errdefer allocator.free(state);
            const valid_from = try validFromForNode(allocator, node);
            errdefer if (valid_from) |value_to_free| allocator.free(value_to_free);
            const valid_to = try readOptionalPropertyString(allocator, node.properties_json, "validTo");
            errdefer if (valid_to) |value_to_free| allocator.free(value_to_free);
            const slot_metadata = try slotMetadataForNode(allocator, node);
            errdefer slot_metadata.deinit(allocator);
            const result_qid = try allocator.dupe(u8, node.qid);
            errdefer allocator.free(result_qid);
            try owned.items.append(allocator, .{
                .qid = result_qid,
                .type = labelType(node.label),
                .text = text,
                .score = hit.score,
                .state = state,
                .validFrom = valid_from,
                .validTo = valid_to,
                .evidence = evidence,
                .includeDebug = include_debug,
                .slotKey = slot_metadata.slot_key,
                .subject = slot_metadata.subject,
                .attribute = slot_metadata.attribute,
                .value = slot_metadata.value,
                .numericValue = slot_metadata.numeric_value,
                .unit = slot_metadata.unit,
                .aggregationMode = slot_metadata.aggregation_mode,
                .raw_source = raw_source,
            });
            if (owned.items.items.len >= limit) break;
        }
        sortItemsByScore(&owned);
        try self.markStaleRawEvidence(allocator, &owned, valid_at);
        return owned;
    }

    /// Records, on each raw item, the slot keys of memories evidenced by its
    /// message that are not active at query time. Only runs when the packet
    /// holds slot memories, since the raw-evidence policy needs a current
    /// version of the slot in the same packet before dropping anything.
    fn markStaleRawEvidence(self: *Runtime, allocator: std.mem.Allocator, owned: *OwnedItems, valid_at: ?[]const u8) !void {
        var has_slot_item = false;
        for (owned.items.items) |item| {
            if (item.raw_source == null and item.slotKey != null) {
                has_slot_item = true;
                break;
            }
        }
        if (!has_slot_item) return;
        for (owned.items.items) |*item| {
            if (item.raw_source) |*source| {
                source.stale_slot_keys = try self.staleSlotKeysForMessage(allocator, source.message_qid, valid_at);
            }
        }
    }

    fn staleSlotKeysForMessage(self: *Runtime, allocator: std.mem.Allocator, message_qid: []const u8, valid_at: ?[]const u8) ![]const []const u8 {
        const edges = try self.store.findEdges(allocator, .{ .to_qid = message_qid, .edge_type = "EVIDENCED_BY", .limit = storage.unlimited });
        defer self.store.freeEdges(allocator, edges);

        var stale = OwnedQids{ .allocator = allocator };
        defer stale.deinit();
        var active = OwnedQids{ .allocator = allocator };
        defer active.deinit();
        for (edges) |edge| {
            const node = (try self.store.getNode(allocator, edge.from_qid)) orelse continue;
            defer self.store.freeNode(allocator, node);
            if (!isSlotMemoryLabel(node.label)) continue;
            if (try propertyBool(allocator, node.properties_json, "deleted")) continue;
            const slot_key = (try readOptionalPropertyString(allocator, node.properties_json, "slotKey")) orelse continue;
            defer allocator.free(slot_key);
            const is_active = if (valid_at) |timestamp|
                try derivedActiveAt(allocator, node, timestamp)
            else
                try propertyEquals(allocator, node.properties_json, "state", "current");
            if (is_active) {
                try active.appendUnique(allocator, slot_key);
            } else {
                try stale.appendUnique(allocator, slot_key);
            }
        }

        var keys = std.ArrayList([]const u8).empty;
        errdefer {
            for (keys.items) |key| allocator.free(key);
            keys.deinit(allocator);
        }
        for (stale.items.items) |key| {
            // A message that also evidences the active version stays relevant.
            if (active.contains(key)) continue;
            try keys.append(allocator, try allocator.dupe(u8, key));
        }
        return keys.toOwnedSlice(allocator);
    }

    /// Every mode returns hits sorted by descending score.
    fn collectSearchHits(self: *Runtime, allocator: std.mem.Allocator, query: []const u8, mode: SearchMode, limit: usize) ![]storage.SearchHit {
        const hits = switch (mode) {
            .fts => try self.store.fullTextSearch(allocator, .{ .text = query, .limit = limit }),
            .graph => try self.graphSearch(allocator, query, limit),
            .vector => self.vectorTextSearch(allocator, query, limit) catch |err| switch (err) {
                error.Unsupported => try allocator.alloc(storage.SearchHit, 0),
                else => |e| return e,
            },
            .hybrid => try self.hybridSearch(allocator, query, limit),
        };
        sortHitsByScore(hits);
        return hits;
    }

    fn vectorTextSearch(self: *Runtime, allocator: std.mem.Allocator, query: []const u8, limit: usize) ![]storage.SearchHit {
        const vector = try self.store.embedText(allocator, query);
        defer allocator.free(vector);
        return self.store.vectorSearch(allocator, .{ .vector = vector, .limit = limit });
    }

    fn hybridSearch(self: *Runtime, allocator: std.mem.Allocator, query: []const u8, limit: usize) ![]storage.SearchHit {
        const fts_hits = try self.store.fullTextSearch(allocator, .{ .text = query, .limit = limit });
        defer freeHits(allocator, fts_hits);
        const vector_hits = self.vectorTextSearch(allocator, query, limit) catch |err| switch (err) {
            error.Unsupported => try allocator.alloc(storage.SearchHit, 0),
            else => |e| return e,
        };
        defer freeHits(allocator, vector_hits);
        return fuseRankedHits(allocator, &.{ fts_hits, vector_hits }, limit);
    }

    fn graphSearch(self: *Runtime, allocator: std.mem.Allocator, query: []const u8, limit: usize) ![]storage.SearchHit {
        const base_hits = if (self.store.capabilities().vector)
            try self.hybridSearch(allocator, query, @max(limit * 2, limit))
        else
            try self.store.fullTextSearch(allocator, .{ .text = query, .limit = @max(limit * 2, limit) });
        defer freeHits(allocator, base_hits);
        sortHitsByScore(base_hits);

        var merged = std.ArrayList(storage.SearchHit).empty;
        errdefer {
            for (merged.items) |hit| allocator.free(hit.qid);
            merged.deinit(allocator);
        }
        try appendRrfHits(allocator, &merged, base_hits, 1.0);

        for (base_hits, 0..) |hit, rank| {
            try self.appendGraphNeighborsForHit(allocator, &merged, hit.qid, reciprocalRank(rank) * 0.75);
        }

        const entity_hits = try self.store.fullTextSearch(allocator, .{ .text = query, .limit = @max(limit * 2, limit) });
        defer freeHits(allocator, entity_hits);
        sortHitsByScore(entity_hits);
        for (entity_hits, 0..) |hit, rank| {
            const node = (try self.store.getNode(allocator, hit.qid)) orelse continue;
            defer self.store.freeNode(allocator, node);
            if (!std.mem.eql(u8, node.label, "Entity")) continue;
            try self.appendMemoryHitsForEntity(allocator, &merged, node.qid, reciprocalRank(rank) * 0.9);
        }

        sortHitsByScore(merged.items);
        if (merged.items.len > limit) {
            for (merged.items[limit..]) |hit| allocator.free(hit.qid);
            merged.shrinkRetainingCapacity(limit);
        }
        return merged.toOwnedSlice(allocator);
    }

    fn appendGraphNeighborsForHit(
        self: *Runtime,
        allocator: std.mem.Allocator,
        merged: *std.ArrayList(storage.SearchHit),
        qid: []const u8,
        score: f32,
    ) !void {
        const node = (try self.store.getNode(allocator, qid)) orelse return;
        defer self.store.freeNode(allocator, node);
        if (std.mem.eql(u8, node.label, "Entity")) {
            try self.appendMemoryHitsForEntity(allocator, merged, qid, score);
            return;
        }

        // Entity mentions are recorded on messages, so chunk hits expand
        // through their parent message.
        const parent_qid = if (std.mem.eql(u8, node.label, "Chunk"))
            try readOptionalPropertyString(allocator, node.properties_json, "messageQid")
        else
            null;
        defer if (parent_qid) |value| allocator.free(value);
        const mention_edges = try self.store.findEdges(allocator, .{
            .from_qid = parent_qid orelse qid,
            .edge_type = "MENTIONS",
            .limit = 32,
        });
        defer self.store.freeEdges(allocator, mention_edges);
        for (mention_edges) |edge| {
            try self.appendMemoryHitsForEntity(allocator, merged, edge.to_qid, score * 0.7);
        }
    }

    fn appendMemoryHitsForEntity(
        self: *Runtime,
        allocator: std.mem.Allocator,
        merged: *std.ArrayList(storage.SearchHit),
        entity_qid: []const u8,
        score: f32,
    ) !void {
        const incoming = try self.store.findEdges(allocator, .{
            .to_qid = entity_qid,
            .edge_type = "MENTIONS",
            .limit = 128,
        });
        defer self.store.freeEdges(allocator, incoming);
        for (incoming) |edge| {
            const node = (try self.store.getNode(allocator, edge.from_qid)) orelse continue;
            defer self.store.freeNode(allocator, node);
            if (std.mem.eql(u8, node.label, "Entity")) continue;
            try self.appendNodeHitScore(allocator, merged, node, score);
        }

        const outgoing = try self.store.findEdges(allocator, .{
            .from_qid = entity_qid,
            .edge_type = "MENTIONED_IN",
            .limit = 128,
        });
        defer self.store.freeEdges(allocator, outgoing);
        for (outgoing) |edge| {
            const node = (try self.store.getNode(allocator, edge.to_qid)) orelse continue;
            defer self.store.freeNode(allocator, node);
            if (std.mem.eql(u8, node.label, "Entity")) continue;
            try self.appendNodeHitScore(allocator, merged, node, score);
        }
    }

    /// Adds a graph hit for `node`, or for each of its chunks when the node is
    /// a chunked (unsearchable) message.
    fn appendNodeHitScore(
        self: *Runtime,
        allocator: std.mem.Allocator,
        merged: *std.ArrayList(storage.SearchHit),
        node: storage.Node,
        score: f32,
    ) !void {
        if (std.mem.eql(u8, node.label, "Message") and try propertyIsFalse(allocator, node.properties_json, "searchable")) {
            const chunk_edges = try self.store.findEdges(allocator, .{ .from_qid = node.qid, .edge_type = "HAS_CHUNK", .limit = 100_000 });
            defer self.store.freeEdges(allocator, chunk_edges);
            for (chunk_edges) |edge| {
                try appendHitScore(allocator, merged, edge.to_qid, score);
            }
            return;
        }
        try appendHitScore(allocator, merged, node.qid, score);
    }

    fn appendCoreItems(self: *Runtime, allocator: std.mem.Allocator, owned: *OwnedItems, scope: Scope, include_evidence: bool, include_debug: bool) !void {
        var core_nodes = self.store.iterateNodes(allocator, .{ .label = "Core" });
        defer core_nodes.deinit();

        while (try core_nodes.next()) |core_qid| {
            const node = (try self.store.getNode(allocator, core_qid)) orelse continue;
            defer self.store.freeNode(allocator, node);
            if (!std.mem.eql(u8, node.label, "Core")) continue;
            if (try propertyBool(allocator, node.properties_json, "deleted")) continue;
            if (!try scope.matchesNode(allocator, node)) continue;
            if (owned.containsQid(node.qid)) continue;

            const text = textForNode(allocator, node) catch continue;
            errdefer allocator.free(text);
            const evidence = if (include_evidence) try evidenceForNode(allocator, node) else try allocator.alloc(EvidenceResult, 0);
            errdefer freeEvidence(allocator, evidence);
            const state = try stateForNode(allocator, node);
            errdefer allocator.free(state);
            const result_qid = try allocator.dupe(u8, node.qid);
            errdefer allocator.free(result_qid);
            try owned.items.append(allocator, .{
                .qid = result_qid,
                .type = "core",
                .text = text,
                .score = 1.0,
                .state = state,
                .evidence = evidence,
                .includeDebug = include_debug,
            });
        }
    }

    fn findCoreBlockQid(self: *Runtime, allocator: std.mem.Allocator, scope: Scope, block_key: []const u8) !?[]u8 {
        const where = [_]storage.PropertyMatch{.{ .name = "blockKey", .value = block_key }};
        var blocks = self.store.iterateNodes(allocator, .{ .label = "Core", .where = &where });
        defer blocks.deinit();

        while (try blocks.next()) |block_qid| {
            const node = (try self.store.getNode(allocator, block_qid)) orelse continue;
            defer self.store.freeNode(allocator, node);
            if (!std.mem.eql(u8, node.label, "Core")) continue;
            if (try propertyBool(allocator, node.properties_json, "deleted")) continue;
            if (!try scope.matchesNode(allocator, node)) continue;
            if (try propertyEquals(allocator, node.properties_json, "blockKey", block_key)) {
                const qid = try allocator.dupe(u8, node.qid);
                return qid;
            }
        }
        return null;
    }

    pub fn runEntityResolveJobs(self: *Runtime, allocator: std.mem.Allocator, owner: []const u8, limit: usize) !EntityJobRunResult {
        const materialized = try jobs.materializeStream(
            allocator,
            self.store,
            streams.entity_resolve_requested,
            streams.workerKindForStream(streams.entity_resolve_requested),
            .{ .limit = limit },
        );
        const leases = try jobs.leasePendingJobs(allocator, self.store, .{
            .worker_kind = streams.workerKindForStream(streams.entity_resolve_requested),
            .owner = owner,
            .limit = limit,
        });
        defer jobs.freeLeaseResults(allocator, leases);

        var succeeded: usize = 0;
        var failed: usize = 0;
        var last_error: ?[]const u8 = null;
        for (leases) |lease| {
            self.processEntityResolveLease(allocator, lease) catch |err| {
                last_error = @errorName(err);
                const error_json = try std.fmt.allocPrint(allocator, "{{\"error\":\"{s}\"}}", .{@errorName(err)});
                defer allocator.free(error_json);
                _ = jobs.failJob(allocator, self.store, lease.qid, error_json, 0) catch {};
                failed += 1;
                continue;
            };
            try jobs.completeJob(allocator, self.store, lease.qid, 0);
            succeeded += 1;
        }

        return .{
            .materializedCount = materialized.createdCount,
            .leasedCount = leases.len,
            .succeededCount = succeeded,
            .failedCount = failed,
            .lastError = last_error,
        };
    }

    fn processEntityResolveLease(self: *Runtime, allocator: std.mem.Allocator, lease: jobs.LeaseResult) !void {
        if (self.options.entity_provider.kind == .none) return error.ProviderUnavailable;
        const payload_json = try self.payloadJsonForLease(allocator, lease);
        defer allocator.free(payload_json);

        var parsed = try std.json.parseFromSlice(Value, allocator, payload_json, .{});
        defer parsed.deinit();
        const payload = switch (parsed.value) {
            .object => |object| object,
            else => return error.InvalidRequest,
        };
        const scope = parseScope(&payload);
        const message_qids = arrayValue(payload.get("messageQids")) orelse return error.InvalidRequest;
        for (message_qids.items) |qid_value| {
            const message_qid = stringValue(qid_value) orelse continue;
            const node = (try self.store.getNode(allocator, message_qid)) orelse continue;
            defer self.store.freeNode(allocator, node);
            if (!std.mem.eql(u8, node.label, "Message")) continue;
            if (try propertyBool(allocator, node.properties_json, "deleted")) continue;
            const text = textForNode(allocator, node) catch continue;
            defer allocator.free(text);
            var entities = try providers.resolveEntities(allocator, self.options.io, self.options.entity_provider, text);
            defer entities.deinit();
            try self.writeEntityMentions(allocator, scope, message_qid, entities.items.items);
        }
    }

    fn payloadJsonForLease(self: *Runtime, allocator: std.mem.Allocator, lease: jobs.LeaseResult) ![]u8 {
        if (try self.store.getNode(allocator, lease.qid)) |job_node| {
            defer self.store.freeNode(allocator, job_node);
            if (try readOptionalPropertyString(allocator, job_node.properties_json, "payloadJson")) |payload_json| {
                return payload_json;
            }
        }
        const entries = try self.store.readStream(
            allocator,
            lease.stream,
            if (lease.sequence > 0) lease.sequence - 1 else 0,
            1,
        );
        defer freeStreamEntries(allocator, entries);
        if (entries.len == 0 or entries[0].sequence != lease.sequence) return error.NotFound;
        return allocator.dupe(u8, entries[0].payload_json);
    }

    fn writeEntityMentions(self: *Runtime, allocator: std.mem.Allocator, scope: Scope, source_qid: []const u8, entities: []const providers.ResolvedEntity) !void {
        for (entities) |entity| {
            const entity_qid = try entityQid(allocator, scope, entity);
            defer allocator.free(entity_qid);
            // Index text for graph seeding: the canonical name plus aliases.
            const search_text = try entitySearchText(allocator, entity);
            defer allocator.free(search_text);
            const props = try stringifyAlloc(allocator, .{
                .kind = "entity",
                .qtype = "entity",
                .searchText = search_text,
                .canonicalName = entity.name,
                .entityType = entity.entity_type,
                .aliases = entity.aliases,
                .state = "current",
                .tenantId = scope.tenant_id,
                .userId = scope.user_id,
                .agentId = scope.agent_id,
                .projectId = scope.project_id,
                .deleted = false,
            });
            defer allocator.free(props);
            if (try self.store.getNode(allocator, entity_qid)) |existing| {
                self.store.freeNode(allocator, existing);
            } else {
                try self.store.putNode(.{ .qid = entity_qid, .label = "Entity", .properties_json = props });
            }
            try self.putDeterministicEdge(allocator, source_qid, entity_qid, "MENTIONS");
        }
    }
};

const RerankSettings = struct {
    enabled: bool = true,
    window: usize = default_rerank_candidates,
};

/// `options.rerank` (default true) and `options.rerankCandidates` (default
/// 50). Null when `rerankCandidates` is not a positive integer.
fn parseRerankSettings(options: ?ObjectMap) ?RerankSettings {
    var settings = RerankSettings{};
    const opts = options orelse return settings;
    if (boolField(&opts, "rerank")) |enabled| settings.enabled = enabled;
    if (opts.get("rerankCandidates")) |value| switch (value) {
        .null => {},
        .integer => |count| {
            if (count < 1) return null;
            settings.window = std.math.cast(usize, count) orelse return null;
        },
        else => return null,
    };
    return settings;
}

/// What the reranker scores for one item: raw evidence as
/// `YYYY-MM-DD role: text` from its raw source, so the cross-encoder sees when
/// and who; derived memory as its text.
fn rerankDocument(allocator: std.mem.Allocator, item: MessageResult) ![]u8 {
    const source = item.raw_source orelse return allocator.dupe(u8, item.text);
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    if (source.created_at) |created_at| {
        if (parseIsoDate(created_at)) |_| {
            try writer.writer.print("{s} ", .{created_at[0..10]});
        } else |_| {}
    }
    if (source.role) |role| try writer.writer.print("{s}: ", .{role});
    try writer.writer.writeAll(item.text);
    return writer.toOwnedSlice();
}

/// New order of the first `window` items: scored items by descending score,
/// ties in fused order, then unscored items in fused order. `scores` must be
/// validated (unique indices below `window`).
fn rerankOrder(allocator: std.mem.Allocator, window: usize, scores: []const providers.RerankResult) ![]usize {
    const ranked = try allocator.dupe(providers.RerankResult, scores);
    defer allocator.free(ranked);
    std.mem.sort(providers.RerankResult, ranked, {}, rerankRanksBefore);
    const placed = try allocator.alloc(bool, window);
    defer allocator.free(placed);
    @memset(placed, false);
    const order = try allocator.alloc(usize, window);
    errdefer allocator.free(order);
    var next: usize = 0;
    for (ranked) |result| {
        order[next] = result.index;
        placed[result.index] = true;
        next += 1;
    }
    for (placed, 0..) |was_placed, index| {
        if (was_placed) continue;
        order[next] = index;
        next += 1;
    }
    return order;
}

fn rerankRanksBefore(_: void, left: providers.RerankResult, right: providers.RerankResult) bool {
    if (left.relevance_score != right.relevance_score) return left.relevance_score > right.relevance_score;
    return left.index < right.index;
}

/// Rearranges `items` so position `i` holds the item previously at `order[i]`.
fn applyItemOrder(allocator: std.mem.Allocator, items: []MessageResult, order: []const usize) !void {
    const reordered = try allocator.alloc(MessageResult, order.len);
    defer allocator.free(reordered);
    for (order, 0..) |source, target| reordered[target] = items[source];
    @memcpy(items[0..order.len], reordered);
}

/// The rerank stage's trace; owns the qids in its top scores.
const OwnedRerankTrace = struct {
    allocator: std.mem.Allocator,
    trace: RerankTrace,
    top_scores: std.ArrayList(RerankScore) = .empty,

    fn failed(self: *const OwnedRerankTrace) bool {
        return std.mem.eql(u8, self.trace.status, "failed");
    }

    fn view(self: *const OwnedRerankTrace) RerankTrace {
        var trace = self.trace;
        trace.topScores = self.top_scores.items;
        return trace;
    }

    fn deinit(self: *OwnedRerankTrace) void {
        for (self.top_scores.items) |entry| self.allocator.free(entry.qid);
        self.top_scores.deinit(self.allocator);
    }
};

const OwnedItems = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(MessageResult) = .empty,

    fn deinit(self: *OwnedItems) void {
        for (self.items.items) |item| {
            self.freeItem(item);
        }
        self.items.deinit(self.allocator);
    }

    /// Raw evidence competes by rank alongside derived memory. A raw item is
    /// dropped only when its message evidences a slot memory that is stale at
    /// query time and the packet already holds the active version of that
    /// slot (stale "uses npm" evidence must not sit next to "uses pnpm").
    /// Memory cards that restate a fact/preference/procedure slot already in
    /// the packet are dropped as duplicates.
    fn applyRawEvidencePolicy(self: *OwnedItems) void {
        var write_index: usize = 0;
        for (self.items.items) |item| {
            if (self.isStaleRawEvidence(item) or self.isDuplicateCard(item)) {
                self.freeItem(item);
                continue;
            }
            self.items.items[write_index] = item;
            write_index += 1;
        }
        self.items.items.len = write_index;
    }

    fn isStaleRawEvidence(self: *const OwnedItems, item: MessageResult) bool {
        const source = item.raw_source orelse return false;
        for (source.stale_slot_keys) |slot_key| {
            if (self.containsSlotItem(slot_key, false)) return true;
        }
        return false;
    }

    fn isDuplicateCard(self: *const OwnedItems, item: MessageResult) bool {
        if (!std.mem.eql(u8, item.type, "memory_card")) return false;
        const slot_key = item.slotKey orelse return false;
        return self.containsSlotItem(slot_key, true);
    }

    fn containsSlotItem(self: *const OwnedItems, slot_key: []const u8, derived_only: bool) bool {
        for (self.items.items) |item| {
            if (item.raw_source != null) continue;
            const item_slot = item.slotKey orelse continue;
            if (!std.mem.eql(u8, item_slot, slot_key)) continue;
            if (derived_only and !isFactLikeType(item.type)) continue;
            return true;
        }
        return false;
    }

    fn filterByNeeds(self: *OwnedItems, needs_value: ?Value) usize {
        if (needsCount(needs_value) == 0) return 0;

        var dropped: usize = 0;
        var write_index: usize = 0;
        for (self.items.items) |item| {
            if (!itemAllowedByNeeds(item, needs_value)) {
                self.freeItem(item);
                dropped += 1;
                continue;
            }
            self.items.items[write_index] = item;
            write_index += 1;
        }
        self.items.items.len = write_index;
        return dropped;
    }

    fn applyTokenBudget(self: *OwnedItems, budget: usize) usize {
        var dropped: usize = 0;
        var used: usize = 0;
        var write_index: usize = 0;
        for (self.items.items) |item| {
            const item_tokens = estimateItemTokens(item);
            if (used + item_tokens > budget) {
                self.freeItem(item);
                dropped += 1;
                continue;
            }
            used += item_tokens;
            self.items.items[write_index] = item;
            write_index += 1;
        }
        self.items.items.len = write_index;
        return dropped;
    }

    fn containsQid(self: *const OwnedItems, qid: []const u8) bool {
        for (self.items.items) |item| {
            if (std.mem.eql(u8, item.qid, qid)) return true;
        }
        return false;
    }

    fn filterByQids(self: *OwnedItems, kept_qids: []const []const u8) usize {
        var dropped: usize = 0;
        var write_index: usize = 0;
        for (self.items.items) |item| {
            if (!stringListContains(kept_qids, item.qid)) {
                self.freeItem(item);
                dropped += 1;
                continue;
            }
            self.items.items[write_index] = item;
            write_index += 1;
        }
        self.items.items.len = write_index;
        return dropped;
    }

    fn freeItem(self: *OwnedItems, item: MessageResult) void {
        self.allocator.free(item.qid);
        self.allocator.free(item.text);
        self.allocator.free(item.state);
        if (item.validFrom) |value| self.allocator.free(value);
        if (item.validTo) |value| self.allocator.free(value);
        if (item.slotKey) |value| self.allocator.free(value);
        if (item.subject) |value| self.allocator.free(value);
        if (item.attribute) |value| self.allocator.free(value);
        if (item.value) |value| self.allocator.free(value);
        if (item.unit) |value| self.allocator.free(value);
        if (item.aggregationMode) |value| self.allocator.free(value);
        if (item.raw_source) |source| source.deinit(self.allocator);
        freeEvidence(self.allocator, item.evidence);
    }
};

/// Evidence handed to answer synthesis, in retrieval rank order. Strings are
/// borrowed from `items` and must not outlive them; `evidenceQids` let readers
/// cite either a chunk/derived qid or its parent message.
fn buildAnswerEvidencePacket(allocator: std.mem.Allocator, items: []const MessageResult) ![]answer_synthesis.EvidenceItem {
    const packet = try allocator.alloc(answer_synthesis.EvidenceItem, items.len);
    errdefer allocator.free(packet);
    var written: usize = 0;
    errdefer {
        for (packet[0..written]) |item| allocator.free(item.evidenceQids);
    }
    for (items, 0..) |item, index| {
        const evidence_qids = try allocator.alloc([]const u8, item.evidence.len);
        for (item.evidence, 0..) |evidence, evidence_index| {
            evidence_qids[evidence_index] = evidence.qid;
        }
        packet[index] = .{
            .qid = item.qid,
            .type = item.type,
            .text = std.mem.trim(u8, item.text, " \t\r\n"),
            .state = item.state,
            .value = item.value,
            .evidenceQids = evidence_qids,
        };
        written += 1;
    }
    return packet;
}

fn freeAnswerEvidencePacket(allocator: std.mem.Allocator, packet: []answer_synthesis.EvidenceItem) void {
    for (packet) |item| allocator.free(item.evidenceQids);
    allocator.free(packet);
}

/// Stable sort by descending score; equal scores put newer items first.
fn sortItemsByScore(owned: *OwnedItems) void {
    std.mem.sort(MessageResult, owned.items.items, {}, itemRanksBefore);
}

fn itemRanksBefore(_: void, left: MessageResult, right: MessageResult) bool {
    if (left.score != right.score) return left.score > right.score;
    return std.mem.order(u8, left.validFrom orelse "", right.validFrom orelse "") == .gt;
}

const OwnedContextPacket = struct {
    allocator: std.mem.Allocator,
    core: std.ArrayList(MessageResult) = .empty,
    current_facts: std.ArrayList(MessageResult) = .empty,
    preferences: std.ArrayList(MessageResult) = .empty,
    procedural: std.ArrayList(MessageResult) = .empty,
    episodes: std.ArrayList(MessageResult) = .empty,
    warnings: []const []const u8 = &.{},

    fn fromItems(allocator: std.mem.Allocator, items: []const MessageResult, warnings: []const []const u8) !OwnedContextPacket {
        var context = OwnedContextPacket{ .allocator = allocator, .warnings = warnings };
        errdefer context.deinit();
        for (items) |item| {
            if (std.mem.eql(u8, item.type, "core")) {
                try context.core.append(allocator, item);
            } else if (std.mem.eql(u8, item.type, "fact")) {
                try context.current_facts.append(allocator, item);
            } else if (std.mem.eql(u8, item.type, "preference")) {
                try context.preferences.append(allocator, item);
            } else if (std.mem.eql(u8, item.type, "procedure")) {
                try context.procedural.append(allocator, item);
            } else {
                try context.episodes.append(allocator, item);
            }
        }
        return context;
    }

    fn view(self: *const OwnedContextPacket) ContextPacket {
        return .{
            .core = self.core.items,
            .currentFacts = self.current_facts.items,
            .preferences = self.preferences.items,
            .procedural = self.procedural.items,
            .episodes = self.episodes.items,
            .warnings = self.warnings,
        };
    }

    fn deinit(self: *OwnedContextPacket) void {
        self.core.deinit(self.allocator);
        self.current_facts.deinit(self.allocator);
        self.preferences.deinit(self.allocator);
        self.procedural.deinit(self.allocator);
        self.episodes.deinit(self.allocator);
    }
};

const OwnedNodeRefs = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(NodeRefResult) = .empty,

    fn append(self: *OwnedNodeRefs, allocator: std.mem.Allocator, qid: []const u8, node_type: []const u8, relation: []const u8) !void {
        const owned_qid = try allocator.dupe(u8, qid);
        errdefer allocator.free(owned_qid);
        try self.items.append(allocator, .{
            .qid = owned_qid,
            .type = node_type,
            .relation = relation,
        });
    }

    fn deinit(self: *OwnedNodeRefs) void {
        for (self.items.items) |item| {
            self.allocator.free(item.qid);
        }
        self.items.deinit(self.allocator);
    }
};

const OwnedForgetReport = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(ForgetReportItem) = .empty,

    fn append(self: *OwnedForgetReport, allocator: std.mem.Allocator, qid: []const u8, node_type: []const u8, action: []const u8) !void {
        const owned_qid = try allocator.dupe(u8, qid);
        errdefer allocator.free(owned_qid);
        try self.items.append(allocator, .{
            .qid = owned_qid,
            .type = node_type,
            .action = action,
        });
    }

    fn deinit(self: *OwnedForgetReport) void {
        for (self.items.items) |item| {
            self.allocator.free(item.qid);
        }
        self.items.deinit(self.allocator);
    }
};

const OwnedQids = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList([]const u8) = .empty,

    fn appendUnique(self: *OwnedQids, allocator: std.mem.Allocator, qid: []const u8) !void {
        if (self.contains(qid)) return;
        const owned_qid = try allocator.dupe(u8, qid);
        errdefer allocator.free(owned_qid);
        try self.items.append(allocator, owned_qid);
    }

    fn contains(self: *const OwnedQids, qid: []const u8) bool {
        for (self.items.items) |existing| {
            if (std.mem.eql(u8, existing, qid)) return true;
        }
        return false;
    }

    fn deinit(self: *OwnedQids) void {
        for (self.items.items) |qid| {
            self.allocator.free(qid);
        }
        self.items.deinit(self.allocator);
    }
};

const OwnedAuditEvents = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(AuditEventResult) = .empty,

    fn append(
        self: *OwnedAuditEvents,
        allocator: std.mem.Allocator,
        stream: []const u8,
        sequence: u64,
        raw_json: []const u8,
    ) !void {
        const owned_stream = try allocator.dupe(u8, stream);
        errdefer allocator.free(owned_stream);
        const owned_json = try allocator.dupe(u8, raw_json);
        errdefer allocator.free(owned_json);
        try self.items.append(allocator, .{
            .stream = owned_stream,
            .sequence = sequence,
            .rawJson = owned_json,
        });
    }

    fn deinit(self: *OwnedAuditEvents) void {
        for (self.items.items) |item| {
            self.allocator.free(item.stream);
            self.allocator.free(item.rawJson);
        }
        self.items.deinit(self.allocator);
    }
};

const SlotMetadata = struct {
    slot_key: ?[]u8 = null,
    subject: ?[]u8 = null,
    attribute: ?[]u8 = null,
    value: ?[]u8 = null,
    numeric_value: ?i64 = null,
    unit: ?[]u8 = null,
    aggregation_mode: ?[]u8 = null,

    fn deinit(self: SlotMetadata, allocator: std.mem.Allocator) void {
        if (self.slot_key) |value| allocator.free(value);
        if (self.subject) |value| allocator.free(value);
        if (self.attribute) |value| allocator.free(value);
        if (self.value) |value| allocator.free(value);
        if (self.unit) |value| allocator.free(value);
        if (self.aggregation_mode) |value| allocator.free(value);
    }
};

fn parseScope(params: *const ObjectMap) Scope {
    const scope_obj = objectField(params, "scope") orelse return .{};
    return .{
        .tenant_id = optionalStringField(&scope_obj, "tenantId"),
        .user_id = optionalStringField(&scope_obj, "userId"),
        .agent_id = optionalStringField(&scope_obj, "agentId"),
        .project_id = optionalStringField(&scope_obj, "projectId"),
    };
}

fn parseValidAt(params: *const ObjectMap) ?[]const u8 {
    const time_obj = objectField(params, "time") orelse return null;
    return optionalStringField(&time_obj, "validAt");
}

fn parseEventWindow(params: *const ObjectMap) EventWindow {
    const time_obj = objectField(params, "time") orelse return .{};
    return .{
        .start = optionalStringField(&time_obj, "eventWindowStart"),
        .end = optionalStringField(&time_obj, "eventWindowEnd"),
    };
}

fn parseSelectorTimeWindow(selector: *const ObjectMap) EventWindow {
    const time_obj = objectField(selector, "timeWindow") orelse return .{};
    return .{
        .start = optionalStringField(&time_obj, "start"),
        .end = optionalStringField(&time_obj, "end"),
    };
}

fn parseSearchMode(value: ?[]const u8) ?SearchMode {
    const mode = value orelse return .fts;
    if (std.mem.eql(u8, mode, "fts")) return .fts;
    if (std.mem.eql(u8, mode, "vector")) return .vector;
    if (std.mem.eql(u8, mode, "hybrid")) return .hybrid;
    if (std.mem.eql(u8, mode, "graph")) return .graph;
    return null;
}

fn parseRetrieveMode(value: ?[]const u8, capabilities: storage.Capabilities) ?SearchMode {
    if (value) |mode| return parseSearchMode(mode);
    if (capabilities.vector and capabilities.embedding_model != null and !std.mem.eql(u8, capabilities.embedding_model.?, "lattice_hash_embed")) {
        return .hybrid;
    }
    return .fts;
}

fn retrievalCandidateSources(mode: SearchMode, candidate_count: usize, core_count: usize) CandidateSources {
    var sources = CandidateSources{ .core = core_count };
    switch (mode) {
        .fts => sources.fts = candidate_count,
        .vector => sources.vector = candidate_count,
        .hybrid => sources.hybrid = candidate_count,
        .graph => sources.graph = candidate_count,
    }
    return sources;
}

fn storageHealth(capabilities: storage.Capabilities) protocol.StorageHealth {
    return .{
        .backend = capabilities.backend,
        .durable = capabilities.durable,
        .fullText = capabilities.full_text,
        .vector = capabilities.vector,
        .streams = capabilities.streams,
        .transactions = capabilities.transactions,
        .verification = capabilities.verification,
        .vectorDimensions = capabilities.vector_dimensions,
        .embeddingModel = capabilities.embedding_model,
    };
}

fn needsCount(needs_value: ?Value) usize {
    const needs = arrayValue(needs_value) orelse return 0;
    var count: usize = 0;
    for (needs.items) |need_value| {
        if (stringValue(need_value) != null) count += 1;
    }
    return count;
}

fn needsIncludes(needs_value: ?Value, expected: []const u8) bool {
    const needs = arrayValue(needs_value) orelse return false;
    for (needs.items) |need_value| {
        const need = stringValue(need_value) orelse continue;
        if (std.mem.eql(u8, need, expected)) return true;
    }
    return false;
}

fn freeStringList(allocator: std.mem.Allocator, tokens: []const []const u8) void {
    for (tokens) |token| {
        allocator.free(token);
    }
    allocator.free(tokens);
}

fn paramsObject(value: ?Value) !ObjectMap {
    const present = value orelse return ObjectMap.empty;
    return switch (present) {
        .object => |object| object,
        else => error.InvalidParams,
    };
}

fn objectField(object: *const ObjectMap, key: []const u8) ?ObjectMap {
    const value = object.get(key) orelse return null;
    return objectValue(value);
}

fn objectValue(value: Value) ?ObjectMap {
    return switch (value) {
        .object => |object| object,
        else => null,
    };
}

fn arrayValue(value: ?Value) ?std.json.Array {
    const present = value orelse return null;
    return switch (present) {
        .array => |array| array,
        else => null,
    };
}

fn stringField(object: *const ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    return stringValue(value);
}

fn optionalStringField(object: *const ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .null => null,
        .string => |string| string,
        else => null,
    };
}

fn boolField(object: *const ObjectMap, key: []const u8) ?bool {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .bool => |boolean| boolean,
        else => null,
    };
}

fn integerField(object: *const ObjectMap, key: []const u8) ?i64 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .integer => |integer| integer,
        else => null,
    };
}

fn stringValue(value: ?Value) ?[]const u8 {
    const present = value orelse return null;
    return switch (present) {
        .string => |string| string,
        else => null,
    };
}

fn jsonRpcId(value: ?Value) ?[]const u8 {
    const present = value orelse return null;
    return switch (present) {
        .string => |string| string,
        else => null,
    };
}

fn readPropertyString(allocator: std.mem.Allocator, properties_json: []const u8, key: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(Value, allocator, properties_json, .{});
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |object| object,
        else => return error.InvalidProperties,
    };
    const value = object.get(key) orelse return error.MissingProperty;
    return switch (value) {
        .string => |string| allocator.dupe(u8, string),
        else => error.InvalidProperties,
    };
}

fn readOptionalPropertyString(allocator: std.mem.Allocator, properties_json: []const u8, key: []const u8) !?[]u8 {
    var parsed = try std.json.parseFromSlice(Value, allocator, properties_json, .{});
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |object| object,
        else => return null,
    };
    const value = object.get(key) orelse return null;
    return switch (value) {
        .null => null,
        .string => |string| try allocator.dupe(u8, string),
        else => null,
    };
}

fn readOptionalPropertyInt(allocator: std.mem.Allocator, properties_json: []const u8, key: []const u8) !?i64 {
    var parsed = try std.json.parseFromSlice(Value, allocator, properties_json, .{});
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |object| object,
        else => return null,
    };
    const value = object.get(key) orelse return null;
    return switch (value) {
        .null => null,
        .integer => |integer| integer,
        else => null,
    };
}

fn slotMetadataForNode(allocator: std.mem.Allocator, node: storage.Node) !SlotMetadata {
    return .{
        .slot_key = try readOptionalPropertyString(allocator, node.properties_json, "slotKey"),
        .subject = try readOptionalPropertyString(allocator, node.properties_json, "subject"),
        .attribute = try readOptionalPropertyString(allocator, node.properties_json, "attribute"),
        .value = try readOptionalPropertyString(allocator, node.properties_json, "value"),
        .numeric_value = try readOptionalPropertyInt(allocator, node.properties_json, "numericValue"),
        .unit = try readOptionalPropertyString(allocator, node.properties_json, "unit"),
        .aggregation_mode = try readOptionalPropertyString(allocator, node.properties_json, "aggregationMode"),
    };
}

fn readStringArrayProperty(allocator: std.mem.Allocator, properties_json: []const u8, key: []const u8) ![][]const u8 {
    var parsed = try std.json.parseFromSlice(Value, allocator, properties_json, .{});
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |object| object,
        else => return allocator.alloc([]const u8, 0),
    };
    const array = arrayValue(object.get(key)) orelse return allocator.alloc([]const u8, 0);
    var values = std.ArrayList([]const u8).empty;
    errdefer {
        for (values.items) |value| allocator.free(value);
        values.deinit(allocator);
    }
    for (array.items) |item| {
        const value = stringValue(item) orelse continue;
        try values.append(allocator, try allocator.dupe(u8, value));
    }
    return values.toOwnedSlice(allocator);
}

fn propertyEquals(allocator: std.mem.Allocator, properties_json: []const u8, key: []const u8, expected: []const u8) !bool {
    var parsed = try std.json.parseFromSlice(Value, allocator, properties_json, .{});
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |object| object,
        else => return false,
    };
    const value = object.get(key) orelse return false;
    return switch (value) {
        .string => |string| std.mem.eql(u8, string, expected),
        else => false,
    };
}

fn propertyBool(allocator: std.mem.Allocator, properties_json: []const u8, key: []const u8) !bool {
    var parsed = try std.json.parseFromSlice(Value, allocator, properties_json, .{});
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |object| object,
        else => return false,
    };
    const value = object.get(key) orelse return false;
    return switch (value) {
        .bool => |boolean| boolean,
        else => false,
    };
}

/// True only when `key` is present and explicitly `false`.
fn propertyIsFalse(allocator: std.mem.Allocator, properties_json: []const u8, key: []const u8) !bool {
    var parsed = try std.json.parseFromSlice(Value, allocator, properties_json, .{});
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |object| object,
        else => return false,
    };
    const value = object.get(key) orelse return false;
    return switch (value) {
        .bool => |boolean| !boolean,
        else => false,
    };
}

fn textForNode(allocator: std.mem.Allocator, node: storage.Node) ![]u8 {
    // Session and Turn nodes are structure, not memory text; callers skip them
    // instead of surfacing "Session"/"Turn" placeholders.
    if (std.mem.eql(u8, node.label, "Session") or std.mem.eql(u8, node.label, "Turn")) {
        return error.NoRenderableText;
    }
    if (std.mem.eql(u8, node.label, "Core")) {
        return readPropertyString(allocator, node.properties_json, "text");
    }
    if (std.mem.eql(u8, node.label, "Episode")) {
        return readPropertyString(allocator, node.properties_json, "summary");
    }
    if (std.mem.eql(u8, node.label, "MemoryCard")) {
        return readPropertyString(allocator, node.properties_json, "text");
    }
    if (isDerivedLabel(node.label)) {
        return readPropertyString(allocator, node.properties_json, "text");
    }
    if (std.mem.eql(u8, node.label, "Message")) {
        return readPropertyString(allocator, node.properties_json, "content");
    }
    if (std.mem.eql(u8, node.label, "ToolCall")) {
        return readPropertyString(allocator, node.properties_json, "toolName");
    }
    if (std.mem.eql(u8, node.label, "Observation")) {
        return readPropertyString(allocator, node.properties_json, "content");
    }
    if (std.mem.eql(u8, node.label, "Entity")) {
        return readPropertyString(allocator, node.properties_json, "canonicalName");
    }
    if (std.mem.eql(u8, node.label, "Feedback")) {
        return readPropertyString(allocator, node.properties_json, "rating");
    }
    return allocator.dupe(u8, node.label);
}

const parseIsoDate = temporal.parseIsoDate;
const weekdayName = temporal.weekdayName;

/// `YYYY-MM-DD (Weekday)` for a trusted current-date line; unparseable
/// timestamps are passed through unchanged.
fn formatCurrentDate(allocator: std.mem.Allocator, timestamp: []const u8) ![]u8 {
    const date = parseIsoDate(timestamp) catch return allocator.dupe(u8, timestamp);
    return std.fmt.allocPrint(allocator, "{s} ({s})", .{ timestamp[0..10], weekdayName(date) });
}

/// `options.temporalHints`: the trusted question date (`time.validAt`) the
/// hints are computed against, or null when hints are off or the date is
/// missing or unparseable.
fn temporalHintDate(enabled: bool, valid_at: ?[]const u8) ?temporal.CivilDate {
    if (!enabled) return null;
    return parseIsoDate(valid_at orelse return null) catch null;
}

/// Relative time expressions in the query resolved against the hint date, or
/// null when hints are off or nothing matches.
fn timeReferencesForQuery(allocator: std.mem.Allocator, query: []const u8, hint_date: ?temporal.CivilDate) !?[]u8 {
    return temporal.resolveTimeReferences(allocator, query, hint_date orelse return null);
}

fn stateForNode(allocator: std.mem.Allocator, node: storage.Node) ![]u8 {
    if (try readOptionalPropertyString(allocator, node.properties_json, "state")) |state| {
        return state;
    }
    if (try propertyBool(allocator, node.properties_json, "deleted")) return allocator.dupe(u8, "deleted");
    return allocator.dupe(u8, "current");
}

fn labelType(label: []const u8) []const u8 {
    if (std.mem.eql(u8, label, "Message")) return "message";
    if (std.mem.eql(u8, label, "Chunk")) return "message";
    if (std.mem.eql(u8, label, "Fact")) return "fact";
    if (std.mem.eql(u8, label, "Preference")) return "preference";
    if (std.mem.eql(u8, label, "Procedure")) return "procedure";
    if (std.mem.eql(u8, label, "Episode")) return "episode";
    if (std.mem.eql(u8, label, "MemoryCard")) return "memory_card";
    if (std.mem.eql(u8, label, "Session")) return "raw";
    if (std.mem.eql(u8, label, "Turn")) return "raw";
    if (std.mem.eql(u8, label, "ToolCall")) return "raw";
    if (std.mem.eql(u8, label, "Observation")) return "raw";
    if (std.mem.eql(u8, label, "Entity")) return "entity";
    if (std.mem.eql(u8, label, "Core")) return "core";
    if (std.mem.eql(u8, label, "Feedback")) return "raw";
    return "raw";
}

fn isDerivedLabel(label: []const u8) bool {
    return std.mem.eql(u8, label, "Fact") or std.mem.eql(u8, label, "Preference") or std.mem.eql(u8, label, "Procedure");
}

fn isSlotMemoryLabel(label: []const u8) bool {
    return isDerivedLabel(label) or std.mem.eql(u8, label, "MemoryCard");
}

fn isEvidenceLinkedLabel(label: []const u8) bool {
    return isDerivedLabel(label) or std.mem.eql(u8, label, "MemoryCard") or std.mem.eql(u8, label, "Episode");
}

fn isConsolidatableLabel(label: []const u8) bool {
    return isDerivedLabel(label) or std.mem.eql(u8, label, "MemoryCard") or std.mem.eql(u8, label, "Episode");
}

fn isFactLikeType(node_type: []const u8) bool {
    return std.mem.eql(u8, node_type, "fact") or std.mem.eql(u8, node_type, "preference") or std.mem.eql(u8, node_type, "procedure");
}

fn isInternalLabel(label: []const u8) bool {
    return std.mem.eql(u8, label, "Job") or std.mem.eql(u8, label, "Idempotency") or std.mem.eql(u8, label, "Schema") or std.mem.eql(u8, label, "Migration");
}

/// Session and Turn are containers with no text; they are never retrieval
/// items unless a caller explicitly asks for the label.
fn isStructuralLabel(label: []const u8) bool {
    return std.mem.eql(u8, label, "Session") or std.mem.eql(u8, label, "Turn");
}

fn isHiddenSearchLabel(label: []const u8) bool {
    return std.mem.eql(u8, label, "Entity");
}

fn labelRequestedExplicitly(label: []const u8, labels_value: ?Value) bool {
    const labels = arrayValue(labels_value) orelse return false;
    for (labels.items) |label_value| {
        const wanted = stringValue(label_value) orelse continue;
        if (std.mem.eql(u8, wanted, label)) return true;
    }
    return false;
}

fn labelAllowed(label: []const u8, labels_value: ?Value) bool {
    const labels = arrayValue(labels_value) orelse return true;
    for (labels.items) |label_value| {
        const wanted = stringValue(label_value) orelse continue;
        if (std.mem.eql(u8, wanted, label) or std.mem.eql(u8, wanted, labelType(label))) return true;
        // Long messages are searched through their chunks.
        if (std.mem.eql(u8, label, "Chunk") and std.mem.eql(u8, wanted, "Message")) return true;
    }
    return false;
}

fn itemAllowedByNeeds(item: MessageResult, needs_value: ?Value) bool {
    if (needsCount(needs_value) == 0) return true;
    if (std.mem.eql(u8, item.type, "core")) return needsIncludes(needs_value, "core");
    if (std.mem.eql(u8, item.type, "fact")) return needsIncludes(needs_value, "current_facts");
    if (std.mem.eql(u8, item.type, "preference")) return needsIncludes(needs_value, "preferences");
    if (std.mem.eql(u8, item.type, "procedure")) return needsIncludes(needs_value, "procedural");
    if (std.mem.eql(u8, item.type, "memory_card")) {
        return needsIncludes(needs_value, "recent_episodes") or needsIncludes(needs_value, "raw");
    }
    if (std.mem.eql(u8, item.type, "message") or std.mem.eql(u8, item.type, "episode")) {
        return needsIncludes(needs_value, "recent_episodes") or needsIncludes(needs_value, "raw");
    }
    if (std.mem.eql(u8, item.type, "raw")) return needsIncludes(needs_value, "raw");
    return true;
}

fn nodeWithinEventWindow(allocator: std.mem.Allocator, node: storage.Node, window: EventWindow) !bool {
    if (!window.active()) return true;
    const timestamp = try eventTimestampForNode(allocator, node);
    defer if (timestamp) |value_to_free| allocator.free(value_to_free);
    const present = timestamp orelse return false;
    if (window.start) |start| {
        if (timestampBefore(present, start)) return false;
    }
    if (window.end) |end| {
        if (timestampAtOrAfter(present, end)) return false;
    }
    return true;
}

fn eventTimestampForNode(allocator: std.mem.Allocator, node: storage.Node) !?[]u8 {
    if (std.mem.eql(u8, node.label, "Message") or std.mem.eql(u8, node.label, "Chunk")) {
        return readOptionalPropertyString(allocator, node.properties_json, "createdAt");
    }
    if (std.mem.eql(u8, node.label, "Episode")) {
        return readOptionalPropertyString(allocator, node.properties_json, "eventTime");
    }
    if (std.mem.eql(u8, node.label, "Observation")) {
        return readOptionalPropertyString(allocator, node.properties_json, "createdAt");
    }
    if (isSlotMemoryLabel(node.label)) {
        return readOptionalPropertyString(allocator, node.properties_json, "validFrom");
    }
    return null;
}

fn validFromForNode(allocator: std.mem.Allocator, node: storage.Node) !?[]u8 {
    if (std.mem.eql(u8, node.label, "Message") or std.mem.eql(u8, node.label, "Chunk")) {
        return readOptionalPropertyString(allocator, node.properties_json, "createdAt");
    }
    if (std.mem.eql(u8, node.label, "Episode")) {
        return readOptionalPropertyString(allocator, node.properties_json, "eventTime");
    }
    if (std.mem.eql(u8, node.label, "Observation")) {
        return readOptionalPropertyString(allocator, node.properties_json, "createdAt");
    }
    if (isSlotMemoryLabel(node.label)) {
        return readOptionalPropertyString(allocator, node.properties_json, "validFrom");
    }
    return null;
}

fn nodeActiveAt(allocator: std.mem.Allocator, node: storage.Node, valid_at: []const u8) !bool {
    if (isSlotMemoryLabel(node.label)) {
        return derivedActiveAt(allocator, node, valid_at);
    }
    const timestamp = try eventTimestampForNode(allocator, node);
    defer if (timestamp) |value_to_free| allocator.free(value_to_free);
    if (timestamp) |value| {
        return !timestampBefore(valid_at, value);
    }
    return true;
}

fn derivedActiveAt(allocator: std.mem.Allocator, node: storage.Node, valid_at: []const u8) !bool {
    const valid_from = try readOptionalPropertyString(allocator, node.properties_json, "validFrom");
    defer if (valid_from) |value_to_free| allocator.free(value_to_free);
    const valid_to = try readOptionalPropertyString(allocator, node.properties_json, "validTo");
    defer if (valid_to) |value_to_free| allocator.free(value_to_free);

    if (valid_from) |timestamp| {
        if (timestampBefore(valid_at, timestamp)) return false;
    }
    if (valid_to) |timestamp| {
        if (timestampAtOrAfter(valid_at, timestamp)) return false;
    }
    return true;
}

fn timestampBefore(left: []const u8, right: []const u8) bool {
    return std.mem.order(u8, left, right) == .lt;
}

fn timestampAtOrAfter(left: []const u8, right: []const u8) bool {
    const order = std.mem.order(u8, left, right);
    return order == .eq or order == .gt;
}

/// Item text for retrieval; chunks carry their slice of the message content.
fn itemTextForNode(allocator: std.mem.Allocator, node: storage.Node) ![]u8 {
    if (std.mem.eql(u8, node.label, "Chunk")) {
        return readPropertyString(allocator, node.properties_json, "content");
    }
    return textForNode(allocator, node);
}

/// Raw-source metadata for Message and Chunk nodes; null for anything else.
fn rawSourceForNode(allocator: std.mem.Allocator, node: storage.Node) !?RawSource {
    const is_chunk = std.mem.eql(u8, node.label, "Chunk");
    if (!is_chunk and !std.mem.eql(u8, node.label, "Message")) return null;

    var parsed = try std.json.parseFromSlice(Value, allocator, node.properties_json, .{});
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |object| object,
        else => return null,
    };

    const message_qid = try allocator.dupe(u8, if (is_chunk) optionalStringField(&object, "messageQid") orelse node.qid else node.qid);
    errdefer allocator.free(message_qid);
    const role = try dupeOptional(allocator, optionalStringField(&object, "role"));
    errdefer if (role) |value| allocator.free(value);
    const created_at = try dupeOptional(allocator, optionalStringField(&object, "createdAt"));
    errdefer if (created_at) |value| allocator.free(value);
    const session_id = try dupeOptional(allocator, optionalStringField(&object, "sessionId"));
    errdefer if (session_id) |value| allocator.free(value);
    const session_qid = try dupeOptional(allocator, optionalStringField(&object, "sessionQid"));
    errdefer if (session_qid) |value| allocator.free(value);
    const turn_qid = try dupeOptional(allocator, optionalStringField(&object, "turnQid"));
    return .{
        .role = role,
        .created_at = created_at,
        .session_id = session_id,
        .session_qid = session_qid,
        .turn_qid = turn_qid,
        .message_qid = message_qid,
        .message_index = integerField(&object, "messageIndex"),
        .chunk_index = if (is_chunk) integerField(&object, "chunkIndex") else null,
        .chunk_count = if (is_chunk) integerField(&object, "chunkCount") else null,
    };
}

/// A chunk's evidence is its parent message; the quote is the chunk text.
fn chunkEvidence(allocator: std.mem.Allocator, node: storage.Node, raw_source: ?RawSource) ![]EvidenceResult {
    const source = raw_source orelse return allocator.alloc(EvidenceResult, 0);
    const evidence_qid = try allocator.dupe(u8, source.message_qid);
    errdefer allocator.free(evidence_qid);
    const quote = try readPropertyString(allocator, node.properties_json, "content");
    errdefer allocator.free(quote);
    const timestamp = try dupeOptional(allocator, source.created_at);
    errdefer if (timestamp) |value| allocator.free(value);
    const evidence = try allocator.alloc(EvidenceResult, 1);
    evidence[0] = .{ .qid = evidence_qid, .quote = quote, .timestamp = timestamp };
    return evidence;
}

fn dupeOptional(allocator: std.mem.Allocator, value: ?[]const u8) !?[]u8 {
    const present = value orelse return null;
    return try allocator.dupe(u8, present);
}

fn evidenceForNode(allocator: std.mem.Allocator, node: storage.Node) ![]EvidenceResult {
    if (!isEvidenceLinkedLabel(node.label)) {
        return allocator.alloc(EvidenceResult, 0);
    }
    const evidence_qid = readPropertyString(allocator, node.properties_json, "evidenceQid") catch {
        return allocator.alloc(EvidenceResult, 0);
    };
    errdefer allocator.free(evidence_qid);
    const quote = readPropertyString(allocator, node.properties_json, "quote") catch {
        allocator.free(evidence_qid);
        return allocator.alloc(EvidenceResult, 0);
    };
    errdefer allocator.free(quote);
    const timestamp = try readOptionalPropertyString(allocator, node.properties_json, "validFrom");
    errdefer if (timestamp) |value_to_free| allocator.free(value_to_free);
    const evidence = try allocator.alloc(EvidenceResult, 1);
    evidence[0] = .{
        .qid = evidence_qid,
        .quote = quote,
        .timestamp = timestamp,
    };
    return evidence;
}

fn freeEvidence(allocator: std.mem.Allocator, evidence: []const EvidenceResult) void {
    for (evidence) |item| {
        allocator.free(item.qid);
        allocator.free(item.quote);
        if (item.timestamp) |timestamp| allocator.free(timestamp);
    }
    allocator.free(evidence);
}

fn appendRetrievalWarnings(
    allocator: std.mem.Allocator,
    warnings: *std.ArrayList([]const u8),
    items: []const MessageResult,
    include_evidence: bool,
) !void {
    var weak_evidence = false;
    var historical = false;
    for (items) |item| {
        if (include_evidence and evidenceExpected(item.type) and item.evidence.len == 0) {
            weak_evidence = true;
        }
        if (item.validTo != null or std.mem.eql(u8, item.state, "superseded") or std.mem.eql(u8, item.state, "historical")) {
            historical = true;
        }
    }
    if (weak_evidence and !containsWarning(warnings.items, "weak_evidence")) {
        try warnings.append(allocator, "weak_evidence");
    }
    if (historical and !containsWarning(warnings.items, "historical_memory")) {
        try warnings.append(allocator, "historical_memory");
    }
}

fn buildScoreBreakdowns(allocator: std.mem.Allocator, items: []const MessageResult) ![]ScoreBreakdown {
    const breakdowns = try allocator.alloc(ScoreBreakdown, items.len);
    for (items, 0..) |item, index| {
        breakdowns[index] = .{
            .qid = item.qid,
            .type = item.type,
            .score = item.score,
            .lexical = normalizeScore(item.score),
            .temporal = temporalScore(item),
            .scope = 1.0,
            .confidence = item.confidence,
            .recency = recencyScore(item),
        };
    }
    return breakdowns;
}

fn buildScoringDetails(allocator: std.mem.Allocator, items: []const MessageResult) ![]ScoringDetail {
    const details = try allocator.alloc(ScoringDetail, items.len);
    for (items, 0..) |item, index| {
        details[index] = .{
            .qid = item.qid,
            .type = item.type,
            .finalScore = item.score,
            .lexical = normalizeScore(item.score),
            .temporal = temporalScore(item),
            .scope = 1.0,
            .confidence = item.confidence,
            .recency = recencyScore(item),
        };
    }
    return details;
}

fn buildDroppedItemReasons(allocator: std.mem.Allocator, dropped_for_needs: usize, dropped_for_budget: usize) ![]DroppedItemReason {
    var reasons = std.ArrayList(DroppedItemReason).empty;
    errdefer reasons.deinit(allocator);
    if (dropped_for_needs > 0) {
        try reasons.append(allocator, .{ .reason = "filtered_by_requested_needs", .count = dropped_for_needs });
    }
    if (dropped_for_budget > 0) {
        try reasons.append(allocator, .{ .reason = "dropped_for_token_budget", .count = dropped_for_budget });
    }
    return reasons.toOwnedSlice(allocator);
}

fn evidenceExpected(item_type: []const u8) bool {
    return std.mem.eql(u8, item_type, "fact") or
        std.mem.eql(u8, item_type, "preference") or
        std.mem.eql(u8, item_type, "procedure") or
        std.mem.eql(u8, item_type, "memory_card");
}

fn containsWarning(warnings: []const []const u8, expected: []const u8) bool {
    for (warnings) |warning| {
        if (std.mem.eql(u8, warning, expected)) return true;
    }
    return false;
}

fn stringListContains(values: []const []const u8, expected: []const u8) bool {
    for (values) |value| {
        if (std.mem.eql(u8, value, expected)) return true;
    }
    return false;
}

fn normalizeScore(score: f32) f32 {
    if (score <= 0) return 0;
    return score / (score + 1.0);
}

fn temporalScore(item: MessageResult) f32 {
    if (std.mem.eql(u8, item.state, "current")) return 1.0;
    if (std.mem.eql(u8, item.state, "superseded") or std.mem.eql(u8, item.state, "historical")) return 0.5;
    return 0.0;
}

fn recencyScore(item: MessageResult) f32 {
    return if (item.validFrom != null) 0.75 else 0.5;
}

/// ceil(text_bytes / 4.2) plus 16 tokens for the rendered line prefix, date
/// and speaker tags, and amortized session headers. Conversational English
/// averages about 4.5 bytes per o200k token on LongMemEval-S; 3.5 left a 4K
/// budget about a quarter empty.
fn estimateItemTokens(item: MessageResult) usize {
    return (item.text.len * 5 + 20) / 21 + 16;
}

/// ceil(prompt_bytes / 4.2): the item estimator's rate applied to the rendered
/// prompt, whose bytes already include line prefixes and session headers.
fn estimatePromptTokens(prompt: []const u8) usize {
    return @max(@as(usize, 1), (prompt.len * 5 + 20) / 21);
}

const PromptOptions = struct {
    /// Trusted question date (`time.validAt`). When set, a `Current date:` line
    /// is rendered above the untrusted memory block.
    current_date: ?[]const u8 = null,
    /// Temporal hints: each dated session header gains its offset from this
    /// date (`## session s07 2023-05-20 (Sat), 10 days ago`).
    hint_date: ?temporal.CivilDate = null,
    /// Temporal hints: resolved time references from the query, rendered as a
    /// `Time references:` line after `Current date:` (retrieve only; the
    /// answer path puts them in the reader's user turn).
    time_references: ?[]const u8 = null,
};

/// Per-item rendering metadata read from the item's node. Every field is
/// optional so older nodes (no session or index properties) still render.
const RenderMeta = struct {
    role: ?[]const u8 = null,
    created_at: ?[]const u8 = null,
    session_qid: ?[]const u8 = null,
    session_id: ?[]const u8 = null,
    message_index: ?i64 = null,
    chunk_index: ?i64 = null,
    chunk_count: ?i64 = null,
};

const RenderEntry = struct {
    item: MessageResult,
    rank: usize,
    meta: RenderMeta = .{},
};

const RenderGroup = struct {
    key: ?[]const u8,
    members: std.ArrayList(usize) = .empty,
    date: ?[]const u8 = null,
    first_session_qid: ?[]const u8 = null,
    first_rank: usize,
};

/// Renders the reader-facing memory context. Derived memory (core, facts,
/// preferences, procedures) gets its own sections with state and validity
/// dates; raw evidence is grouped by session, sessions in chronological order,
/// items by message index then chunk index. Output is deterministic for a
/// given context. `store` supplies session/role/index metadata; without it the
/// renderer falls back to what the items carry.
fn promptFromContext(allocator: std.mem.Allocator, store: ?storage.Adapter, context: ContextPacket, options: PromptOptions) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const entries = try arena.alloc(RenderEntry, context.episodes.len);
    var session_ids = std.StringHashMap(?[]const u8).init(arena);
    for (context.episodes, 0..) |item, rank| {
        entries[rank] = .{
            .item = item,
            .rank = rank,
            .meta = if (store) |adapter| try loadRenderMeta(arena, adapter, item, &session_ids) else .{ .created_at = item.validFrom },
        };
    }
    return renderPrompt(allocator, arena, context, entries, options);
}

fn renderPrompt(
    allocator: std.mem.Allocator,
    arena: std.mem.Allocator,
    context: ContextPacket,
    entries: []const RenderEntry,
    options: PromptOptions,
) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    const out = &writer.writer;
    if (options.current_date) |timestamp| {
        const formatted = try formatCurrentDate(arena, timestamp);
        try out.print("Current date: {s}\n", .{formatted});
        if (options.time_references) |references| try out.print("Time references: {s}\n", .{references});
    }
    try out.writeAll("<memory>");
    try writePromptSection(arena, out, "core", context.core);
    try writePromptSection(arena, out, "facts", context.currentFacts);
    try writePromptSection(arena, out, "preferences", context.preferences);
    try writePromptSection(arena, out, "procedures", context.procedural);
    try writeSessionSection(arena, out, entries, options.hint_date);
    try out.writeAll("\n</memory>");
    return writer.toOwnedSlice();
}

/// Derived items: `[qid] (state, from A to B) text`, oldest validity first.
fn writePromptSection(arena: std.mem.Allocator, out: *std.Io.Writer, name: []const u8, items: []const MessageResult) !void {
    if (items.len == 0) return;
    const order = try arena.alloc(usize, items.len);
    for (order, 0..) |*slot, index| slot.* = index;
    std.mem.sort(usize, order, items, derivedRendersBefore);

    try out.print("\n<{s}>", .{name});
    for (order) |index| {
        const item = items[index];
        try out.print("\n[{s}] ({s}", .{ item.qid, item.state });
        if (item.validFrom) |from| {
            if (item.validTo) |to| {
                try out.print(", {s} to {s}", .{ dateKey(from), dateKey(to) });
            } else {
                try out.print(", from {s}", .{dateKey(from)});
            }
        } else if (item.validTo) |to| {
            try out.print(", until {s}", .{dateKey(to)});
        }
        try out.writeAll(") ");
        try writeItemText(out, item.text);
    }
    try out.print("\n</{s}>", .{name});
}

fn derivedRendersBefore(items: []const MessageResult, left: usize, right: usize) bool {
    const left_from = items[left].validFrom;
    const right_from = items[right].validFrom;
    if (left_from == null and right_from != null) return true;
    if (left_from != null and right_from == null) return false;
    if (left_from != null and right_from != null and !std.mem.eql(u8, left_from.?, right_from.?)) {
        return std.mem.order(u8, left_from.?, right_from.?) == .lt;
    }
    return left < right;
}

/// Raw evidence grouped by session:
/// `## session <id> YYYY-MM-DD (Ddd)` then `[qid] speaker: text` lines. A line
/// repeats its date only when it differs from the session date. Items without
/// a session go last under `## other`. With a `hint_date`, a dated header ends
/// with its offset from that date (`, 10 days ago`).
fn writeSessionSection(arena: std.mem.Allocator, out: *std.Io.Writer, entries: []const RenderEntry, hint_date: ?temporal.CivilDate) !void {
    if (entries.len == 0) return;
    var groups = std.ArrayList(RenderGroup).empty;
    for (entries, 0..) |entry, index| {
        const key = entry.meta.session_id orelse entry.meta.session_qid;
        const group = for (groups.items) |*existing| {
            if (optionalStringsEqual(existing.key, key)) break existing;
        } else blk: {
            try groups.append(arena, .{ .key = key, .first_rank = entry.rank });
            break :blk &groups.items[groups.items.len - 1];
        };
        try group.members.append(arena, index);
        group.first_rank = @min(group.first_rank, entry.rank);
        if (entry.meta.created_at) |created_at| {
            if (group.date == null or std.mem.order(u8, created_at, group.date.?) == .lt) group.date = created_at;
        }
        if (entry.meta.session_qid) |session_qid| {
            if (group.first_session_qid == null or naturalQidOrder(session_qid, group.first_session_qid.?) == .lt) {
                group.first_session_qid = session_qid;
            }
        }
    }
    for (groups.items) |group| {
        std.mem.sort(usize, group.members.items, entries, entryRendersBefore);
    }
    std.mem.sort(RenderGroup, groups.items, {}, groupRendersBefore);

    try out.writeAll("\n<sessions>");
    for (groups.items) |group| {
        const header_date: ?[]const u8 = if (group.date) |date| dateKey(date) else null;
        if (group.key) |key| {
            try out.print("\n## session {s}", .{key});
            if (group.date) |date| {
                if (parseIsoDate(date)) |civil| {
                    try out.print(" {s} ({s})", .{ dateKey(date), weekdayName(civil)[0..3] });
                    if (hint_date) |current| {
                        try out.writeAll(", ");
                        try temporal.writeOffset(out, civil, current);
                    }
                } else |_| {
                    try out.print(" {s}", .{date});
                }
            }
        } else {
            try out.writeAll("\n## other");
        }
        for (group.members.items) |index| {
            const entry = entries[index];
            try out.print("\n[{s}]", .{entry.item.qid});
            var labelled = false;
            if (entry.meta.created_at) |created_at| {
                const line_date = dateKey(created_at);
                if (group.key == null or header_date == null or !std.mem.eql(u8, line_date, header_date.?)) {
                    try out.print(" {s}", .{line_date});
                    labelled = true;
                }
            }
            if (entry.meta.role) |role| {
                try out.print(" {s}", .{role});
                labelled = true;
            }
            if (entry.meta.chunk_count) |count| {
                if (count > 1) {
                    if (entry.meta.chunk_index) |chunk_index| {
                        try out.print(" ({d}/{d})", .{ chunk_index + 1, count });
                        labelled = true;
                    }
                }
            }
            try out.writeAll(if (labelled) ": " else " ");
            try writeItemText(out, entry.item.text);
        }
    }
    try out.writeAll("\n</sessions>");
}

fn entryRendersBefore(entries: []const RenderEntry, left_index: usize, right_index: usize) bool {
    const left = entries[left_index];
    const right = entries[right_index];
    if (orderOptionalQid(left.meta.session_qid, right.meta.session_qid)) |order| return order == .lt;
    if (orderOptionalInt(left.meta.message_index, right.meta.message_index)) |order| return order == .lt;
    if (orderOptionalInt(left.meta.chunk_index, right.meta.chunk_index)) |order| return order == .lt;
    if (orderOptionalString(left.meta.created_at, right.meta.created_at)) |order| return order == .lt;
    const qid_order = naturalQidOrder(left.item.qid, right.item.qid);
    if (qid_order != .eq) return qid_order == .lt;
    return left.rank < right.rank;
}

fn groupRendersBefore(_: void, left: RenderGroup, right: RenderGroup) bool {
    if ((left.key == null) != (right.key == null)) return right.key == null;
    if (orderOptionalString(left.date, right.date)) |order| return order == .lt;
    if (orderOptionalQid(left.first_session_qid, right.first_session_qid)) |order| return order == .lt;
    if (orderOptionalString(left.key, right.key)) |order| return order == .lt;
    return left.first_rank < right.first_rank;
}

/// Present values sort before missing ones; null means "tied".
fn orderOptionalString(left: ?[]const u8, right: ?[]const u8) ?std.math.Order {
    if (left == null and right == null) return null;
    if (left == null) return .gt;
    if (right == null) return .lt;
    const order = std.mem.order(u8, left.?, right.?);
    return if (order == .eq) null else order;
}

fn orderOptionalQid(left: ?[]const u8, right: ?[]const u8) ?std.math.Order {
    if (left == null and right == null) return null;
    if (left == null) return .gt;
    if (right == null) return .lt;
    const order = naturalQidOrder(left.?, right.?);
    return if (order == .eq) null else order;
}

fn orderOptionalInt(left: ?i64, right: ?i64) ?std.math.Order {
    if (left == null and right == null) return null;
    if (left == null) return .gt;
    if (right == null) return .lt;
    const order = std.math.order(left.?, right.?);
    return if (order == .eq) null else order;
}

/// Natural order: digit runs compare numerically, so `q_msg_9` sorts before
/// `q_msg_10` and `q_chunk_9_1` before `q_chunk_10_0`.
fn naturalQidOrder(left: []const u8, right: []const u8) std.math.Order {
    var i: usize = 0;
    var j: usize = 0;
    while (i < left.len and j < right.len) {
        if (std.ascii.isDigit(left[i]) and std.ascii.isDigit(right[j])) {
            const left_end = digitRunEnd(left, i);
            const right_end = digitRunEnd(right, j);
            const left_digits = std.mem.trimStart(u8, left[i..left_end], "0");
            const right_digits = std.mem.trimStart(u8, right[j..right_end], "0");
            if (left_digits.len != right_digits.len) return std.math.order(left_digits.len, right_digits.len);
            const digit_order = std.mem.order(u8, left_digits, right_digits);
            if (digit_order != .eq) return digit_order;
            i = left_end;
            j = right_end;
            continue;
        }
        if (left[i] != right[j]) return std.math.order(left[i], right[j]);
        i += 1;
        j += 1;
    }
    const tail_order = std.math.order(left.len - i, right.len - j);
    if (tail_order != .eq) return tail_order;
    return std.mem.order(u8, left, right);
}

fn digitRunEnd(text: []const u8, start: usize) usize {
    var index = start;
    while (index < text.len and std.ascii.isDigit(text[index])) : (index += 1) {}
    return index;
}

fn optionalStringsEqual(left: ?[]const u8, right: ?[]const u8) bool {
    if (left == null or right == null) return left == null and right == null;
    return std.mem.eql(u8, left.?, right.?);
}

/// `YYYY-MM-DD` when the timestamp starts with a valid ISO date, else as given.
fn dateKey(timestamp: []const u8) []const u8 {
    _ = parseIsoDate(timestamp) catch return timestamp;
    return timestamp[0..10];
}

/// Writes item text on one line: whitespace runs collapse to a single space
/// and context section tags inside memory text are defanged so stored text
/// cannot close or forge a section.
fn writeItemText(out: *std.Io.Writer, raw: []const u8) !void {
    const text = std.mem.trim(u8, raw, " \t\r\n");
    var pending_space = false;
    var index: usize = 0;
    while (index < text.len) {
        const byte = text[index];
        if (byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n') {
            pending_space = true;
            index += 1;
            continue;
        }
        if (pending_space) {
            try out.writeByte(' ');
            pending_space = false;
        }
        if (byte == '<') {
            if (contextTagLength(text[index..])) |tag_len| {
                try out.writeByte('[');
                try out.writeAll(text[index + 1 .. index + tag_len - 1]);
                try out.writeByte(']');
                index += tag_len;
                continue;
            }
        }
        try out.writeByte(byte);
        index += 1;
    }
}

fn contextTagLength(text: []const u8) ?usize {
    const names = [_][]const u8{ "memory", "sessions", "core", "facts", "preferences", "procedures" };
    var cursor: usize = 1;
    if (cursor < text.len and text[cursor] == '/') cursor += 1;
    for (names) |name| {
        const end = cursor + name.len;
        if (end < text.len and std.ascii.eqlIgnoreCase(text[cursor..end], name) and text[end] == '>') return end + 1;
    }
    return null;
}

fn loadRenderMeta(
    arena: std.mem.Allocator,
    store: storage.Adapter,
    item: MessageResult,
    session_ids: *std.StringHashMap(?[]const u8),
) !RenderMeta {
    var meta = RenderMeta{ .created_at = item.validFrom };
    if (item.raw_source) |source| {
        // Message and chunk items carry their source fields; no node lookup.
        meta.role = source.role;
        meta.created_at = source.created_at orelse item.validFrom;
        meta.session_id = source.session_id;
        meta.session_qid = source.session_qid orelse
            sessionQidFromTurn(arena, store, source.turn_qid) orelse
            sessionQidFromEdges(arena, store, source.message_qid);
        meta.message_index = source.message_index;
        meta.chunk_index = source.chunk_index;
        meta.chunk_count = source.chunk_count;
    } else {
        const node = (store.getNode(arena, item.qid) catch null) orelse return meta;
        meta.role = defaultRoleForLabel(node.label);
        const props = parsePropertiesObject(arena, node.properties_json) orelse return meta;
        meta.role = jsonObjectString(props, "role") orelse meta.role;
        meta.created_at = jsonObjectString(props, "createdAt") orelse jsonObjectString(props, "eventTime") orelse item.validFrom;
        meta.session_id = jsonObjectString(props, "sessionId");
        meta.message_index = jsonObjectInt(props, "messageIndex");
        meta.chunk_index = jsonObjectInt(props, "chunkIndex");
        meta.chunk_count = jsonObjectInt(props, "chunkCount");
        meta.session_qid = jsonObjectString(props, "sessionQid") orelse
            sessionQidFromTurn(arena, store, jsonObjectString(props, "turnQid")) orelse
            sessionQidFromEdges(arena, store, node.qid);
    }
    if (meta.session_id == null) {
        if (meta.session_qid) |session_qid| {
            if (session_ids.get(session_qid)) |cached| {
                meta.session_id = cached;
            } else {
                const session_props = nodeProperties(arena, store, session_qid);
                meta.session_id = if (session_props) |session| jsonObjectString(session, "sessionId") else null;
                try session_ids.put(session_qid, meta.session_id);
            }
        }
    }
    return meta;
}

fn sessionQidFromTurn(arena: std.mem.Allocator, store: storage.Adapter, turn_qid: ?[]const u8) ?[]const u8 {
    const qid = turn_qid orelse return null;
    const turn_props = nodeProperties(arena, store, qid) orelse return null;
    return jsonObjectString(turn_props, "sessionQid");
}

/// Nodes written before session properties existed: follow the Turn that owns
/// them through a HAS_* edge.
fn sessionQidFromEdges(arena: std.mem.Allocator, store: storage.Adapter, qid: []const u8) ?[]const u8 {
    const edges = store.findEdges(arena, .{ .to_qid = qid, .limit = 64 }) catch return null;
    for (edges) |edge| {
        if (!std.mem.eql(u8, edge.edge_type, "HAS_MESSAGE") and
            !std.mem.eql(u8, edge.edge_type, "HAS_TOOL_CALL") and
            !std.mem.eql(u8, edge.edge_type, "HAS_OBSERVATION")) continue;
        if (sessionQidFromTurn(arena, store, edge.from_qid)) |session_qid| return session_qid;
    }
    return null;
}

fn nodeProperties(arena: std.mem.Allocator, store: storage.Adapter, qid: []const u8) ?std.json.ObjectMap {
    const node = (store.getNode(arena, qid) catch return null) orelse return null;
    return parsePropertiesObject(arena, node.properties_json);
}

fn parsePropertiesObject(arena: std.mem.Allocator, properties_json: []const u8) ?std.json.ObjectMap {
    const value = std.json.parseFromSliceLeaky(Value, arena, properties_json, .{}) catch return null;
    return switch (value) {
        .object => |object| object,
        else => null,
    };
}

fn jsonObjectString(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    return switch (object.get(key) orelse return null) {
        .string => |string| if (string.len > 0) string else null,
        else => null,
    };
}

fn jsonObjectInt(object: std.json.ObjectMap, key: []const u8) ?i64 {
    return switch (object.get(key) orelse return null) {
        .integer => |integer| integer,
        else => null,
    };
}

fn defaultRoleForLabel(label: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, label, "Episode")) return "summary";
    if (std.mem.eql(u8, label, "MemoryCard")) return "note";
    if (std.mem.eql(u8, label, "ToolCall")) return "tool";
    if (std.mem.eql(u8, label, "Observation")) return "observation";
    if (std.mem.eql(u8, label, "Feedback")) return "feedback";
    return null;
}

fn idempotencyQid(allocator: std.mem.Allocator, key: []const u8) ![]u8 {
    var out = try allocator.alloc(u8, "q_idem_".len + key.len);
    @memcpy(out[0.."q_idem_".len], "q_idem_");
    for (key, 0..) |byte, index| {
        out["q_idem_".len + index] = if (std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-') byte else '_';
    }
    return out;
}

fn hashQid(allocator: std.mem.Allocator, prefix: []const u8, key: []const u8) ![]u8 {
    const hash = std.hash.Wyhash.hash(2, key);
    return std.fmt.allocPrint(allocator, "q_{s}_{x}", .{ prefix, hash });
}

fn entityQid(allocator: std.mem.Allocator, scope: Scope, entity: providers.ResolvedEntity) ![]u8 {
    const normalized_name = try normalizedEntityKey(allocator, entity.name);
    defer allocator.free(normalized_name);
    const normalized_type = try normalizedEntityKey(allocator, entity.entity_type);
    defer allocator.free(normalized_type);
    const key = try std.fmt.allocPrint(
        allocator,
        "tenant={s}|user={s}|agent={s}|project={s}|type={s}|name={s}",
        .{
            scope.tenant_id orelse "",
            scope.user_id orelse "",
            scope.agent_id orelse "",
            scope.project_id orelse "",
            normalized_type,
            normalized_name,
        },
    );
    defer allocator.free(key);
    return hashQid(allocator, "ent", key);
}

fn entitySearchText(allocator: std.mem.Allocator, entity: providers.ResolvedEntity) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    try writer.writer.writeAll(entity.name);
    for (entity.aliases) |alias| {
        try writer.writer.writeByte(' ');
        try writer.writer.writeAll(alias);
    }
    return writer.toOwnedSlice();
}

fn normalizedEntityKey(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    var wrote_any = false;
    var pending_separator = false;
    for (raw) |byte| {
        if (std.ascii.isAlphanumeric(byte)) {
            if (pending_separator and wrote_any) {
                try writer.writer.writeByte('_');
            }
            try writer.writer.writeByte(std.ascii.toLower(byte));
            wrote_any = true;
            pending_separator = false;
        } else {
            pending_separator = true;
        }
    }
    return writer.toOwnedSlice();
}

fn memoryCardKind(label: extractor.Label) []const u8 {
    return switch (label) {
        .fact => "semantic",
        .preference => "preference",
        .procedure => "procedural",
    };
}

fn cardContextualDescription(candidate: extractor.Candidate) []const u8 {
    if (std.mem.eql(u8, candidate.slot_key, "project.package_manager")) {
        return "Repository package manager preference extracted from user-provided project evidence.";
    }
    if (std.mem.eql(u8, candidate.slot_key, "project.test_command")) {
        return "Repository verification command extracted from user-provided project evidence.";
    }
    if (std.mem.eql(u8, candidate.slot_key, "project.repo_style")) {
        return "Repository implementation style extracted from project guidance.";
    }
    if (std.mem.eql(u8, candidate.slot_key, "project.constraint")) {
        return "Project invariant extracted from contributor or user guidance.";
    }
    if (std.mem.eql(u8, candidate.slot_key, "user.response_style")) {
        return "User communication preference extracted from conversation evidence.";
    }
    return "Memory card generated from evidence-linked deterministic extraction.";
}

fn cardKeywords(candidate: extractor.Candidate) []const []const u8 {
    if (std.mem.eql(u8, candidate.slot_key, "project.package_manager")) return &card_keywords_package_manager;
    if (std.mem.eql(u8, candidate.slot_key, "project.test_command")) return &card_keywords_test_command;
    if (std.mem.eql(u8, candidate.slot_key, "project.repo_style")) return &card_keywords_repo_style;
    if (std.mem.eql(u8, candidate.slot_key, "project.constraint")) return &card_keywords_project_constraint;
    if (std.mem.eql(u8, candidate.slot_key, "user.response_style")) return &card_keywords_response_style;
    return &card_keywords_generic;
}

fn cardTags(candidate: extractor.Candidate) []const []const u8 {
    return switch (candidate.label) {
        .fact => &card_tags_fact,
        .preference => &card_tags_preference,
        .procedure => &card_tags_procedure,
    };
}

fn cardImportance(candidate: extractor.Candidate) f32 {
    if (std.mem.eql(u8, candidate.slot_key, "project.constraint")) return 0.9;
    if (std.mem.eql(u8, candidate.slot_key, "project.test_command")) return 0.8;
    if (std.mem.eql(u8, candidate.slot_key, "project.package_manager")) return 0.75;
    if (std.mem.eql(u8, candidate.slot_key, "user.response_style")) return 0.65;
    return 0.6;
}

fn freeHits(allocator: std.mem.Allocator, hits: []storage.SearchHit) void {
    for (hits) |hit| allocator.free(hit.qid);
    allocator.free(hits);
}

fn freeStreamEntries(allocator: std.mem.Allocator, entries: []storage.StreamEntry) void {
    for (entries) |entry| {
        allocator.free(entry.stream);
        allocator.free(entry.payload_json);
    }
    allocator.free(entries);
}

/// Reciprocal-rank fusion (k = 60) of several channels. RRF is rank based,
/// so each channel is put in descending score order before its ranks count.
/// Returns at most `limit` fused hits, sorted by fused score.
fn fuseRankedHits(allocator: std.mem.Allocator, channels: []const []storage.SearchHit, limit: usize) ![]storage.SearchHit {
    var merged = std.ArrayList(storage.SearchHit).empty;
    errdefer {
        for (merged.items) |hit| allocator.free(hit.qid);
        merged.deinit(allocator);
    }
    for (channels) |channel| {
        sortHitsByScore(channel);
        try appendRrfHits(allocator, &merged, channel, 1.0);
    }
    sortHitsByScore(merged.items);
    if (merged.items.len > limit) {
        for (merged.items[limit..]) |hit| allocator.free(hit.qid);
        merged.shrinkRetainingCapacity(limit);
    }
    return merged.toOwnedSlice(allocator);
}

fn appendRrfHits(allocator: std.mem.Allocator, merged: *std.ArrayList(storage.SearchHit), hits: []const storage.SearchHit, weight: f32) !void {
    for (hits, 0..) |hit, rank| {
        const fused_score = weight * reciprocalRank(rank);
        try appendHitScore(allocator, merged, hit.qid, fused_score);
    }
}

fn appendHitScore(allocator: std.mem.Allocator, merged: *std.ArrayList(storage.SearchHit), qid_value: []const u8, score: f32) !void {
    if (indexOfHit(merged.items, qid_value)) |index| {
        merged.items[index].score += score;
        return;
    }
    const qid = try allocator.dupe(u8, qid_value);
    errdefer allocator.free(qid);
    try merged.append(allocator, .{ .qid = qid, .score = score });
}

fn indexOfHit(hits: []const storage.SearchHit, qid: []const u8) ?usize {
    for (hits, 0..) |hit, index| {
        if (std.mem.eql(u8, hit.qid, qid)) return index;
    }
    return null;
}

fn reciprocalRank(rank: usize) f32 {
    return 1.0 / @as(f32, @floatFromInt(60 + rank + 1));
}

/// Stable sort by descending score, so ties keep their incoming order.
fn sortHitsByScore(hits: []storage.SearchHit) void {
    std.mem.sort(storage.SearchHit, hits, {}, hitRanksBefore);
}

fn hitRanksBefore(_: void, left: storage.SearchHit, right: storage.SearchHit) bool {
    return left.score > right.score;
}

fn stringifyAlloc(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    try std.json.Stringify.value(value, .{}, &writer.writer);
    return writer.toOwnedSlice();
}

/// End offset of each chunk of `content`. Chunks are contiguous, so slicing at
/// these offsets reassembles the original bytes exactly. Content at or under
/// `message_chunk_max_bytes` yields a single end (no chunking).
fn messageChunkEnds(allocator: std.mem.Allocator, content: []const u8) ![]usize {
    var ends = std.ArrayList(usize).empty;
    errdefer ends.deinit(allocator);
    var start: usize = 0;
    while (content.len - start > message_chunk_max_bytes) {
        const end = chunkBoundary(content, start);
        try ends.append(allocator, end);
        start = end;
    }
    try ends.append(allocator, content.len);
    return ends.toOwnedSlice(allocator);
}

/// Picks a chunk end within the last `message_chunk_boundary_window` bytes
/// before the hard limit, preferring a paragraph break, then a sentence or
/// line end, then whitespace. Never splits a UTF-8 codepoint. Requires
/// `content.len - start > message_chunk_max_bytes`.
fn chunkBoundary(content: []const u8, start: usize) usize {
    var hard_end = start + message_chunk_max_bytes;
    var backoff: usize = 0;
    while (backoff < 3 and hard_end > start + 1 and isUtf8Continuation(content[hard_end])) : (backoff += 1) {
        hard_end -= 1;
    }
    const window_start = if (hard_end - start > message_chunk_boundary_window)
        hard_end - message_chunk_boundary_window
    else
        start + 1;
    const window = content[window_start..hard_end];

    if (std.mem.lastIndexOf(u8, window, "\n\n")) |index| return window_start + index + 2;

    var index = window.len;
    while (index > 0) {
        index -= 1;
        const byte = window[index];
        if (byte == '\n') return window_start + index + 1;
        if ((byte == '.' or byte == '!' or byte == '?') and index + 1 < window.len and isAsciiWhitespace(window[index + 1])) {
            return window_start + index + 2;
        }
    }

    index = window.len;
    while (index > 0) {
        index -= 1;
        if (isAsciiWhitespace(window[index])) return window_start + index + 1;
    }
    return hard_end;
}

fn isUtf8Continuation(byte: u8) bool {
    return byte & 0xC0 == 0x80;
}

fn isAsciiWhitespace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r';
}

fn chunkQid(allocator: std.mem.Allocator, message_qid: []const u8, chunk_index: usize) ![]u8 {
    const suffix = if (std.mem.startsWith(u8, message_qid, "q_msg_")) message_qid["q_msg_".len..] else message_qid;
    return std.fmt.allocPrint(allocator, "q_chunk_{s}_{d}", .{ suffix, chunk_index });
}

fn clampPropertyText(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    if (value.len <= property_text_max_bytes) return allocator.dupe(u8, value);

    const prefix_limit = property_text_max_bytes - property_truncation_marker.len;
    const prefix_len = utf8PrefixLen(value, prefix_limit);
    const clamped = try allocator.alloc(u8, prefix_len + property_truncation_marker.len);
    @memcpy(clamped[0..prefix_len], value[0..prefix_len]);
    @memcpy(clamped[prefix_len..], property_truncation_marker);
    return clamped;
}

fn utf8PrefixLen(value: []const u8, max_bytes: usize) usize {
    var index: usize = 0;
    while (index < value.len and index < max_bytes) {
        const codepoint_len = std.unicode.utf8ByteSequenceLength(value[index]) catch return index;
        if (index + codepoint_len > max_bytes or index + codepoint_len > value.len) break;
        index += codepoint_len;
    }
    return index;
}

fn errorResponse(allocator: std.mem.Allocator, id: ?[]const u8, code: []const u8, message: []const u8) ![]u8 {
    const response = .{
        .jsonrpc = "2.0",
        .id = id,
        .@"error" = .{
            .code = code,
            .message = message,
            .details = .{},
        },
    };
    return stringifyAlloc(allocator, response);
}

var runtime_test_db_counter = std.atomic.Value(u64).init(0);

const RuntimeTestHarness = if (build_options.enable_lattice) struct {
    allocator: std.mem.Allocator,
    tmp_dir: std.testing.TmpDir,
    db_path: []u8,
    adapter_state: lattice_storage.LatticeAdapter,
    health_value: protocol.Health,

    fn init(allocator: std.mem.Allocator) !RuntimeTestHarness {
        var tmp_dir = std.testing.tmpDir(.{});
        errdefer tmp_dir.cleanup();
        const id = runtime_test_db_counter.fetchAdd(1, .monotonic);
        const db_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/quipu-runtime-test-{d}.lattice", .{ tmp_dir.sub_path[0..], id });
        errdefer allocator.free(db_path);

        var adapter_state = try lattice_storage.LatticeAdapter.open(allocator, db_path, .{ .io = std.testing.io });
        errdefer adapter_state.deinit();
        try schema.ensure(allocator, adapter_state.adapter());

        var health_value = protocol.Health.default();
        health_value.db_path = db_path;
        health_value.lattice_version = lattice_storage.LatticeAdapter.latticeVersion();
        return .{
            .allocator = allocator,
            .tmp_dir = tmp_dir,
            .db_path = db_path,
            .adapter_state = adapter_state,
            .health_value = health_value,
        };
    }

    fn deinit(self: *RuntimeTestHarness) void {
        self.adapter_state.deinit();
        self.tmp_dir.cleanup();
        self.allocator.free(self.db_path);
    }

    fn adapter(self: *RuntimeTestHarness) storage.Adapter {
        return self.adapter_state.adapter();
    }

    fn health(self: *RuntimeTestHarness) protocol.Health {
        return self.health_value;
    }
} else struct {
    adapter_state: in_memory_storage.InMemoryAdapter,

    fn init(allocator: std.mem.Allocator) !RuntimeTestHarness {
        return .{ .adapter_state = in_memory_storage.InMemoryAdapter.init(allocator) };
    }

    fn deinit(self: *RuntimeTestHarness) void {
        self.adapter_state.deinit();
    }

    fn adapter(self: *RuntimeTestHarness) storage.Adapter {
        return self.adapter_state.adapter();
    }

    fn health(_: *RuntimeTestHarness) protocol.Health {
        return protocol.Health.default();
    }
};

test "runtime remembers and searches scoped raw messages" {
    var harness = try RuntimeTestHarness.init(std.testing.allocator);
    defer harness.deinit();
    var runtime = Runtime.init(harness.adapter(), harness.health());
    defer runtime.deinit();

    const remember = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"r1\",\"method\":\"memory.remember\",\"params\":{\"scope\":{\"projectId\":\"repo:test\"},\"messages\":[{\"role\":\"user\",\"content\":\"Use pnpm for this repo.\"}],\"extract\":false}}",
    );
    defer std.testing.allocator.free(remember);
    try std.testing.expect(std.mem.indexOf(u8, remember, "\"status\":\"stored\"") != null);

    const search = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"s1\",\"method\":\"memory.search\",\"params\":{\"query\":\"pnpm\",\"scope\":{\"projectId\":\"repo:test\"}}}",
    );
    defer std.testing.allocator.free(search);
    try std.testing.expect(std.mem.indexOf(u8, search, "Use pnpm for this repo.") != null);
}

test "runtime health includes storage capabilities" {
    var harness = try RuntimeTestHarness.init(std.testing.allocator);
    defer harness.deinit();
    var runtime = Runtime.init(harness.adapter(), harness.health());
    defer runtime.deinit();

    const health = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"h1\",\"method\":\"system.health\",\"params\":{}}",
    );
    defer std.testing.allocator.free(health);

    try std.testing.expect(std.mem.indexOf(u8, health, "\"storage\"") != null);
    if (build_options.enable_lattice) {
        try std.testing.expect(std.mem.indexOf(u8, health, "\"backend\":\"lattice\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, health, "\"durable\":true") != null);
        try std.testing.expect(std.mem.indexOf(u8, health, "\"vector\":true") != null);
    } else {
        try std.testing.expect(std.mem.indexOf(u8, health, "\"backend\":\"memory\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, health, "\"vector\":false") != null);
    }
}

test "runtime publishes audit stream entries for mutations" {
    var harness = try RuntimeTestHarness.init(std.testing.allocator);
    defer harness.deinit();
    const adapter = harness.adapter();
    var runtime = Runtime.init(adapter, harness.health());
    defer runtime.deinit();

    const remember = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"r1\",\"method\":\"memory.remember\",\"params\":{\"scope\":{\"projectId\":\"repo:test\"},\"messages\":[{\"role\":\"user\",\"content\":\"Audit this memory.\"}],\"extract\":false}}",
    );
    defer std.testing.allocator.free(remember);

    const feedback = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"f1\",\"method\":\"memory.feedback\",\"params\":{\"retrievalId\":\"q_retr_1\",\"rating\":\"useful\"}}",
    );
    defer std.testing.allocator.free(feedback);

    const entries = try adapter.readStream(std.testing.allocator, streams.audit, 0, 10);
    defer freeStreamEntries(std.testing.allocator, entries);

    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expect(std.mem.indexOf(u8, entries[0].payload_json, "\"method\":\"memory.remember\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, entries[1].payload_json, "\"method\":\"memory.feedback\"") != null);
}

test "runtime stores tool calls observations episodes and memory cards" {
    var harness = try RuntimeTestHarness.init(std.testing.allocator);
    defer harness.deinit();
    var runtime = Runtime.init(harness.adapter(), harness.health());
    defer runtime.deinit();

    const remember = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"r1\",\"method\":\"memory.remember\",\"params\":{\"scope\":{\"projectId\":\"repo:test\"},\"messages\":[{\"role\":\"user\",\"content\":\"This repo uses pnpm.\",\"createdAt\":\"2026-04-01T10:00:00Z\"}],\"toolCalls\":[{\"toolName\":\"shell\",\"inputJson\":\"{\\\"cmd\\\":\\\"pnpm test\\\"}\",\"outputJson\":\"{\\\"status\\\":\\\"ok\\\"}\",\"status\":\"success\"}],\"observations\":[{\"type\":\"tool_result\",\"content\":\"pnpm test passed\",\"createdAt\":\"2026-04-01T10:01:00Z\"}]}}",
    );
    defer std.testing.allocator.free(remember);

    const cards = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"s1\",\"method\":\"memory.search\",\"params\":{\"query\":\"package manager\",\"scope\":{\"projectId\":\"repo:test\"},\"labels\":[\"MemoryCard\"],\"limit\":5}}",
    );
    defer std.testing.allocator.free(cards);
    try std.testing.expect(std.mem.indexOf(u8, cards, "\"type\":\"memory_card\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, cards, "The repo uses pnpm as its package manager.") != null);

    const episodes = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"s2\",\"method\":\"memory.retrieve\",\"params\":{\"query\":\"repo uses pnpm\",\"scope\":{\"projectId\":\"repo:test\"},\"needs\":[\"recent_episodes\"]}}",
    );
    defer std.testing.allocator.free(episodes);
    // The episode only copies the first message, so it is unsearchable and
    // recent_episodes is served by the raw message itself.
    try std.testing.expect(std.mem.indexOf(u8, episodes, "\"type\":\"episode\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, episodes, "\"type\":\"message\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, episodes, "This repo uses pnpm.") != null);

    const episode_qid = try hashQid(std.testing.allocator, "ep", "q_turn_2");
    defer std.testing.allocator.free(episode_qid);
    const inspect_request = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":\"i1\",\"method\":\"memory.inspect\",\"params\":{{\"qid\":\"{s}\"}}}}",
        .{episode_qid},
    );
    defer std.testing.allocator.free(inspect_request);
    const episode = try runtime.dispatch(std.testing.allocator, inspect_request);
    defer std.testing.allocator.free(episode);
    try std.testing.expect(std.mem.indexOf(u8, episode, "\"type\":\"episode\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, episode, "\\\"searchable\\\":false") != null);

    const observations = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"s3\",\"method\":\"memory.search\",\"params\":{\"query\":\"pnpm test passed\",\"scope\":{\"projectId\":\"repo:test\"},\"labels\":[\"Observation\"],\"limit\":5}}",
    );
    defer std.testing.allocator.free(observations);
    try std.testing.expect(std.mem.indexOf(u8, observations, "pnpm test passed") != null);
}

test "runtime queues extract jobs from durable stream events" {
    var harness = try RuntimeTestHarness.init(std.testing.allocator);
    defer harness.deinit();
    const adapter = harness.adapter();
    var runtime = Runtime.init(adapter, harness.health());
    defer runtime.deinit();

    const remember = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"r1\",\"method\":\"memory.remember\",\"params\":{\"scope\":{\"projectId\":\"repo:test\"},\"messages\":[{\"role\":\"user\",\"content\":\"This repo uses pnpm.\"}]}}",
    );
    defer std.testing.allocator.free(remember);

    try std.testing.expect(std.mem.indexOf(u8, remember, "\"queuedJobs\":[\"q_job_") != null);

    const entries = try adapter.readStream(std.testing.allocator, streams.extract_requested, 0, 10);
    defer freeStreamEntries(std.testing.allocator, entries);
    try std.testing.expectEqual(@as(usize, 1), entries.len);

    const job_qid = try jobs.jobQid(std.testing.allocator, streams.extract_requested, entries[0].sequence, streams.workerKindForStream(streams.extract_requested));
    defer std.testing.allocator.free(job_qid);
    const job = (try adapter.getNode(std.testing.allocator, job_qid)) orelse return error.TestUnexpectedResult;
    defer adapter.freeNode(std.testing.allocator, job);
    try std.testing.expectEqualStrings("Job", job.label);
    try std.testing.expect(std.mem.indexOf(u8, job.properties_json, "\"status\":\"pending\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, job.properties_json, "\"streamName\":\"quipu.extract.requested\"") != null);
}

test "runtime logs retrievals and returns inspect audit events" {
    var harness = try RuntimeTestHarness.init(std.testing.allocator);
    defer harness.deinit();
    var runtime = Runtime.init(harness.adapter(), harness.health());
    defer runtime.deinit();

    const remember = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"r1\",\"method\":\"memory.remember\",\"params\":{\"scope\":{\"projectId\":\"repo:test\"},\"messages\":[{\"role\":\"user\",\"content\":\"Inspect audit target.\"}],\"extract\":false}}",
    );
    defer std.testing.allocator.free(remember);

    const retrieve = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"ret1\",\"method\":\"memory.retrieve\",\"params\":{\"query\":\"audit target\",\"scope\":{\"projectId\":\"repo:test\"}}}",
    );
    defer std.testing.allocator.free(retrieve);

    const inspect = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"i1\",\"method\":\"memory.inspect\",\"params\":{\"qid\":\"q_msg_4\"}}",
    );
    defer std.testing.allocator.free(inspect);

    try std.testing.expect(std.mem.indexOf(u8, inspect, "\"audit\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, inspect, "memory.remember") != null);
    try std.testing.expect(std.mem.indexOf(u8, inspect, "memory.retrieve") != null);
}

test "runtime forget suppresses retrieval" {
    var harness = try RuntimeTestHarness.init(std.testing.allocator);
    defer harness.deinit();
    var runtime = Runtime.init(harness.adapter(), harness.health());
    defer runtime.deinit();

    const remember = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"r1\",\"method\":\"memory.remember\",\"params\":{\"scope\":{\"projectId\":\"repo:test\"},\"messages\":[{\"role\":\"user\",\"content\":\"Delete this exact string.\"}]}}",
    );
    defer std.testing.allocator.free(remember);

    const forget = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"f1\",\"method\":\"memory.forget\",\"params\":{\"mode\":\"hard_delete\",\"selector\":{\"qids\":[\"q_msg_4\"]},\"dryRun\":false,\"reason\":\"test\"}}",
    );
    defer std.testing.allocator.free(forget);
    try std.testing.expect(std.mem.indexOf(u8, forget, "\"nodesDeleted\":1") != null);

    const retrieve = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"q1\",\"method\":\"memory.retrieve\",\"params\":{\"query\":\"exact string\",\"scope\":{\"projectId\":\"repo:test\"}}}",
    );
    defer std.testing.allocator.free(retrieve);
    try std.testing.expect(std.mem.indexOf(u8, retrieve, "Delete this exact string.") == null);
}

test "runtime forget supports query selectors with scope filters" {
    var harness = try RuntimeTestHarness.init(std.testing.allocator);
    defer harness.deinit();
    var runtime = Runtime.init(harness.adapter(), harness.health());
    defer runtime.deinit();

    const alpha = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"r1\",\"method\":\"memory.remember\",\"params\":{\"scope\":{\"projectId\":\"repo:alpha\"},\"messages\":[{\"role\":\"user\",\"content\":\"Scoped deletion token belongs to alpha.\"}],\"extract\":false}}",
    );
    defer std.testing.allocator.free(alpha);
    const beta = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"r2\",\"method\":\"memory.remember\",\"params\":{\"scope\":{\"projectId\":\"repo:beta\"},\"messages\":[{\"role\":\"user\",\"content\":\"Scoped deletion token belongs to beta.\"}],\"extract\":false}}",
    );
    defer std.testing.allocator.free(beta);

    const forget = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"f1\",\"method\":\"memory.forget\",\"params\":{\"mode\":\"hard_delete\",\"selector\":{\"query\":\"Scoped deletion token\",\"scope\":{\"projectId\":\"repo:alpha\"}},\"dryRun\":false,\"reason\":\"test\"}}",
    );
    defer std.testing.allocator.free(forget);
    try std.testing.expect(std.mem.indexOf(u8, forget, "\"rootsMatched\":1") != null);

    const alpha_retrieve = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"q1\",\"method\":\"memory.retrieve\",\"params\":{\"query\":\"Scoped deletion token\",\"scope\":{\"projectId\":\"repo:alpha\"},\"needs\":[\"raw\"]}}",
    );
    defer std.testing.allocator.free(alpha_retrieve);
    try std.testing.expect(std.mem.indexOf(u8, alpha_retrieve, "belongs to alpha") == null);

    const beta_retrieve = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"q2\",\"method\":\"memory.retrieve\",\"params\":{\"query\":\"Scoped deletion token\",\"scope\":{\"projectId\":\"repo:beta\"},\"needs\":[\"raw\"]}}",
    );
    defer std.testing.allocator.free(beta_retrieve);
    try std.testing.expect(std.mem.indexOf(u8, beta_retrieve, "belongs to beta") != null);
}

test "runtime forget contaminates compiled core summaries" {
    var harness = try RuntimeTestHarness.init(std.testing.allocator);
    defer harness.deinit();
    var runtime = Runtime.init(harness.adapter(), harness.health());
    defer runtime.deinit();

    const remember = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"r1\",\"method\":\"memory.remember\",\"params\":{\"scope\":{\"projectId\":\"repo:test\"},\"messages\":[{\"role\":\"user\",\"content\":\"This repo uses pnpm. Run just test before committing.\",\"createdAt\":\"2026-04-01T10:00:00Z\"}]}}",
    );
    defer std.testing.allocator.free(remember);

    const consolidate = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"c1\",\"method\":\"memory.core.consolidate\",\"params\":{\"scope\":{\"projectId\":\"repo:test\"},\"blockKey\":\"project_summary\"}}",
    );
    defer std.testing.allocator.free(consolidate);

    const forget = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"f1\",\"method\":\"memory.forget\",\"params\":{\"mode\":\"hard_delete\",\"selector\":{\"qids\":[\"q_msg_4\"]},\"dryRun\":false,\"reason\":\"test\"}}",
    );
    defer std.testing.allocator.free(forget);
    try std.testing.expect(std.mem.indexOf(u8, forget, "\"summariesContaminated\":1") != null);

    const retrieve = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"q1\",\"method\":\"memory.retrieve\",\"params\":{\"query\":\"pnpm\",\"scope\":{\"projectId\":\"repo:test\"},\"needs\":[\"core\"]}}",
    );
    defer std.testing.allocator.free(retrieve);
    try std.testing.expect(std.mem.indexOf(u8, retrieve, "Consolidated memory:") == null);
    try std.testing.expect(std.mem.indexOf(u8, retrieve, "The repo uses pnpm as its package manager.") == null);
}

test "runtime stores and replaces core blocks" {
    var harness = try RuntimeTestHarness.init(std.testing.allocator);
    defer harness.deinit();
    var runtime = Runtime.init(harness.adapter(), harness.health());
    defer runtime.deinit();

    const update = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"c1\",\"method\":\"memory.core.update\",\"params\":{\"blockKey\":\"project_state\",\"scope\":{\"projectId\":\"repo:test\"},\"text\":\"Use Zig 0.16.\",\"mode\":\"replace\",\"managedBy\":\"user\"}}",
    );
    defer std.testing.allocator.free(update);
    try std.testing.expect(std.mem.indexOf(u8, update, "\"status\":\"stored\"") != null);

    const replace = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"c2\",\"method\":\"memory.core.update\",\"params\":{\"blockKey\":\"project_state\",\"scope\":{\"projectId\":\"repo:test\"},\"text\":\"Use Zig 0.16 and run zig build test.\",\"mode\":\"replace\",\"managedBy\":\"user\"}}",
    );
    defer std.testing.allocator.free(replace);
    try std.testing.expect(std.mem.indexOf(u8, replace, "\"status\":\"updated\"") != null);

    const get = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"c3\",\"method\":\"memory.core.get\",\"params\":{\"scope\":{\"projectId\":\"repo:test\"},\"blockKey\":\"project_state\"}}",
    );
    defer std.testing.allocator.free(get);
    try std.testing.expect(std.mem.indexOf(u8, get, "run zig build test") != null);
}

test "runtime consolidates derived memory into a core block" {
    var harness = try RuntimeTestHarness.init(std.testing.allocator);
    defer harness.deinit();
    var runtime = Runtime.init(harness.adapter(), harness.health());
    defer runtime.deinit();

    const remember = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"r1\",\"method\":\"memory.remember\",\"params\":{\"scope\":{\"projectId\":\"repo:test\"},\"messages\":[{\"role\":\"user\",\"content\":\"This repo uses pnpm. Run just test before committing.\",\"createdAt\":\"2026-04-01T10:00:00Z\"}]}}",
    );
    defer std.testing.allocator.free(remember);

    const consolidate = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"c1\",\"method\":\"memory.core.consolidate\",\"params\":{\"scope\":{\"projectId\":\"repo:test\"},\"blockKey\":\"project_summary\"}}",
    );
    defer std.testing.allocator.free(consolidate);
    try std.testing.expect(std.mem.indexOf(u8, consolidate, "\"sourceCount\"") != null);

    const retrieve = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"q1\",\"method\":\"memory.retrieve\",\"params\":{\"query\":\"Consolidated pnpm\",\"scope\":{\"projectId\":\"repo:test\"},\"needs\":[\"core\"]}}",
    );
    defer std.testing.allocator.free(retrieve);
    try std.testing.expect(std.mem.indexOf(u8, retrieve, "Consolidated memory:") != null);
    try std.testing.expect(std.mem.indexOf(u8, retrieve, "The repo uses pnpm as its package manager.") != null);
}

test "runtime extracts current package manager facts" {
    var harness = try RuntimeTestHarness.init(std.testing.allocator);
    defer harness.deinit();
    var runtime = Runtime.init(harness.adapter(), harness.health());
    defer runtime.deinit();

    const first = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"r1\",\"method\":\"memory.remember\",\"params\":{\"scope\":{\"projectId\":\"repo:test\"},\"messages\":[{\"role\":\"user\",\"content\":\"This repo uses npm.\",\"createdAt\":\"2026-01-01T10:00:00Z\"}]}}",
    );
    defer std.testing.allocator.free(first);

    const second = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"r2\",\"method\":\"memory.remember\",\"params\":{\"scope\":{\"projectId\":\"repo:test\"},\"messages\":[{\"role\":\"user\",\"content\":\"We migrated this repo to pnpm. Use pnpm now.\",\"createdAt\":\"2026-02-01T10:00:00Z\"}]}}",
    );
    defer std.testing.allocator.free(second);

    const retrieve = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"q1\",\"method\":\"memory.retrieve\",\"params\":{\"query\":\"package manager\",\"scope\":{\"projectId\":\"repo:test\"}}}",
    );
    defer std.testing.allocator.free(retrieve);

    try std.testing.expect(std.mem.indexOf(u8, retrieve, "The repo uses pnpm as its package manager.") != null);
    try std.testing.expect(std.mem.indexOf(u8, retrieve, "The repo uses npm as its package manager.") == null);

    const historical = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"q2\",\"method\":\"memory.retrieve\",\"params\":{\"query\":\"package manager\",\"scope\":{\"projectId\":\"repo:test\"},\"time\":{\"validAt\":\"2026-01-15T10:00:00Z\"}}}",
    );
    defer std.testing.allocator.free(historical);
    try std.testing.expect(std.mem.indexOf(u8, historical, "The repo uses npm as its package manager.") != null);
    try std.testing.expect(std.mem.indexOf(u8, historical, "The repo uses pnpm as its package manager.") == null);
}

test "runtime answer deterministic fallback returns the current derived fact" {
    var harness = try RuntimeTestHarness.init(std.testing.allocator);
    defer harness.deinit();
    var runtime = Runtime.init(harness.adapter(), harness.health());
    defer runtime.deinit();

    const first = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"r1\",\"method\":\"memory.remember\",\"params\":{\"scope\":{\"projectId\":\"repo:test\"},\"messages\":[{\"role\":\"user\",\"content\":\"This repo uses npm.\",\"createdAt\":\"2026-01-01T10:00:00Z\"}]}}",
    );
    defer std.testing.allocator.free(first);
    const second = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"r2\",\"method\":\"memory.remember\",\"params\":{\"scope\":{\"projectId\":\"repo:test\"},\"messages\":[{\"role\":\"user\",\"content\":\"We migrated this repo to pnpm. Use pnpm now.\",\"createdAt\":\"2026-02-01T10:00:00Z\"}]}}",
    );
    defer std.testing.allocator.free(second);

    const answer = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"a1\",\"method\":\"memory.answer\",\"params\":{\"query\":\"Which package manager does this repo use?\",\"scope\":{\"projectId\":\"repo:test\"},\"options\":{\"includeDebug\":true,\"logRetrieval\":false}}}",
    );
    defer std.testing.allocator.free(answer);
    try std.testing.expect(std.mem.indexOf(u8, answer, "\"answer\":\"pnpm\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, answer, "\"strategy\":\"deterministic_fallback\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, answer, "\"supportValid\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, answer, "\"confidence\":0.5") != null);
}

const TestReader = struct {
    calls: usize = 0,
    last_user: ?[]u8 = null,
    last_system: []const u8 = "",
    last_min_output_tokens: ?u32 = null,
    cite_invalid: bool = false,
    /// Reply with a leading `reasoning` field, as reasoning mode asks.
    with_reasoning: bool = false,

    fn endpoint(self: *TestReader) providers.ProviderEndpoint {
        return .{
            .kind = .callback,
            .name = "test-reader",
            .model = "test-model",
            .callback = .{ .context = self, .respond = respond },
        };
    }

    fn respond(context: ?*anyopaque, allocator: std.mem.Allocator, turn: providers.ChatTurn) anyerror![]u8 {
        const self: *TestReader = @ptrCast(@alignCast(context.?));
        self.calls += 1;
        if (self.last_user) |previous| std.testing.allocator.free(previous);
        self.last_user = try std.testing.allocator.dupe(u8, turn.user_content);
        self.last_system = turn.system_prompt;
        self.last_min_output_tokens = turn.min_output_tokens;
        const qid = if (self.cite_invalid) "q_msg_999" else lineQid(turn.user_content, "I adopted a cat") orelse "q_missing";
        return std.fmt.allocPrint(
            allocator,
            "{{{s}\"answer\":\"Miso\",\"answerable\":true,\"supportQids\":[\"{s}\"],\"confidence\":0.75}}",
            .{ if (self.with_reasoning) "\"reasoning\":\"[cat line] 2023-05-22 user adopted a cat named Miso.\"," else "", qid },
        );
    }

    fn deinit(self: *TestReader) void {
        if (self.last_user) |previous| std.testing.allocator.free(previous);
    }
};

/// The bracketed qid at the start of the line that contains `needle`.
fn lineQid(text: []const u8, needle: []const u8) ?[]const u8 {
    const at = std.mem.indexOf(u8, text, needle) orelse return null;
    const line_start = std.mem.lastIndexOfScalar(u8, text[0..at], '\n') orelse 0;
    const open = std.mem.indexOfScalarPos(u8, text, line_start, '[') orelse return null;
    const close = std.mem.indexOfScalarPos(u8, text, open, ']') orelse return null;
    return text[open + 1 .. close];
}

fn rememberPetSessions(runtime: *Runtime) !void {
    const late = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"r1\",\"method\":\"memory.remember\",\"params\":{\"scope\":{\"userId\":\"u1\"},\"sessionId\":\"s-late\",\"extract\":false,\"messages\":[{\"role\":\"user\",\"content\":\"I adopted a cat named Miso.\",\"createdAt\":\"2023-05-22T10:00:00Z\"},{\"role\":\"assistant\",\"content\":\"Miso is a lovely name for a cat.\",\"createdAt\":\"2023-05-22T10:00:00Z\"}]}}",
    );
    defer std.testing.allocator.free(late);
    const early = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"r2\",\"method\":\"memory.remember\",\"params\":{\"scope\":{\"userId\":\"u1\"},\"sessionId\":\"s-early\",\"extract\":false,\"messages\":[{\"role\":\"user\",\"content\":\"My dog Rex likes the park.\",\"createdAt\":\"2023-05-20T09:00:00Z\"},{\"role\":\"assistant\",\"content\":\"Parks are great for dogs like Rex.\",\"createdAt\":\"2023-05-20T09:00:00Z\"}]}}",
    );
    defer std.testing.allocator.free(early);
}

fn resultStringField(allocator: std.mem.Allocator, response: []const u8, key: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(Value, allocator, response, .{});
    defer parsed.deinit();
    const result = parsed.value.object.get("result").?.object;
    return allocator.dupe(u8, result.get(key).?.string);
}

fn expectInOrder(text: []const u8, needles: []const []const u8) !void {
    var cursor: usize = 0;
    for (needles) |needle| {
        const index = std.mem.indexOfPos(u8, text, cursor, needle) orelse {
            std.debug.print("missing in order: {s}\n--- text ---\n{s}\n", .{ needle, text });
            return error.TestUnexpectedResult;
        };
        cursor = index + needle.len;
    }
}

test "runtime retrieve prompt groups sessions chronologically with dates and speakers" {
    var harness = try RuntimeTestHarness.init(std.testing.allocator);
    defer harness.deinit();
    var runtime = Runtime.init(harness.adapter(), harness.health());
    defer runtime.deinit();
    try rememberPetSessions(&runtime);

    const retrieve = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"q1\",\"method\":\"memory.retrieve\",\"params\":{\"query\":\"cat dog Miso Rex\",\"scope\":{\"userId\":\"u1\"},\"needs\":[\"raw\"],\"time\":{\"validAt\":\"2023-05-30T23:40:00Z\"},\"options\":{\"logRetrieval\":false,\"logAudit\":false}}}",
    );
    defer std.testing.allocator.free(retrieve);
    const prompt = try resultStringField(std.testing.allocator, retrieve, "prompt");
    defer std.testing.allocator.free(prompt);

    try std.testing.expect(std.mem.startsWith(u8, prompt, "Current date: 2023-05-30 (Tuesday)\n<memory>\n<sessions>\n## session s-early 2023-05-20 (Sat)\n[q_msg_"));
    try expectInOrder(prompt, &.{
        "## session s-early 2023-05-20 (Sat)\n",
        "] user: My dog Rex likes the park.\n",
        "] assistant: Parks are great for dogs like Rex.\n",
        "## session s-late 2023-05-22 (Mon)\n",
        "] user: I adopted a cat named Miso.\n",
        "] assistant: Miso is a lovely name for a cat.\n",
        "</sessions>\n</memory>",
    });

    // Structural Session/Turn nodes never surface as placeholder items.
    const structural = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"q2\",\"method\":\"memory.retrieve\",\"params\":{\"query\":\"session turn Miso\",\"scope\":{\"userId\":\"u1\"},\"options\":{\"logRetrieval\":false,\"logAudit\":false}}}",
    );
    defer std.testing.allocator.free(structural);
    try std.testing.expect(std.mem.indexOf(u8, structural, "\"text\":\"Session\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, structural, "\"text\":\"Turn\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, structural, "I adopted a cat named Miso.") != null);
}

test "runtime answer sends the rendered context and question date to the reader" {
    var harness = try RuntimeTestHarness.init(std.testing.allocator);
    defer harness.deinit();
    var reader = TestReader{};
    defer reader.deinit();
    var runtime = Runtime.initWithOptions(harness.adapter(), harness.health(), .{ .answer_provider = reader.endpoint() });
    defer runtime.deinit();
    try rememberPetSessions(&runtime);

    const answer = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"a1\",\"method\":\"memory.answer\",\"params\":{\"query\":\"What are my cat and dog called?\",\"scope\":{\"userId\":\"u1\"},\"needs\":[\"raw\"],\"time\":{\"validAt\":\"2023-05-30T23:40:00Z\"},\"options\":{\"includeDebug\":true,\"logRetrieval\":false}}}",
    );
    defer std.testing.allocator.free(answer);

    try std.testing.expectEqual(@as(usize, 1), reader.calls);
    try std.testing.expect(std.mem.indexOf(u8, answer, "\"answer\":\"Miso\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, answer, "\"provider\":\"test-reader\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, answer, "\"strategy\":\"llm_reader\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, answer, "\"supportValid\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, answer, "\"confidence\":0.75") != null);

    const prompt = try resultStringField(std.testing.allocator, answer, "prompt");
    defer std.testing.allocator.free(prompt);
    try std.testing.expect(std.mem.startsWith(u8, prompt, "<memory>\n<sessions>\n## session s-early 2023-05-20 (Sat)\n"));
    try expectInOrder(prompt, &.{ "## session s-late 2023-05-22 (Mon)\n", "] user: I adopted a cat named Miso.\n" });
    const user_turn = reader.last_user.?;
    try std.testing.expect(std.mem.startsWith(u8, user_turn, "Current date: 2023-05-30 (Tuesday)\n\nQuestion:\nWhat are my cat and dog called?\n\nMemory context:\n"));
    // `prompt` is exactly the memory context the reader received.
    try std.testing.expect(std.mem.endsWith(u8, user_turn, prompt));
    // Defaults: the direct prompt, no output floor, no temporal hints.
    try std.testing.expectEqualStrings(providers.answer_system_prompt, reader.last_system);
    try std.testing.expect(reader.last_min_output_tokens == null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, " ago") == null);
    try std.testing.expect(std.mem.indexOf(u8, answer, "\"readerMode\":\"direct\",\"temporalHints\":false,\"timeReferences\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, answer, "\"reasoning\":null") != null);

    const quiet = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"a2\",\"method\":\"memory.answer\",\"params\":{\"query\":\"What are my cat and dog called?\",\"scope\":{\"userId\":\"u1\"},\"needs\":[\"raw\"],\"options\":{\"logRetrieval\":false}}}",
    );
    defer std.testing.allocator.free(quiet);
    try std.testing.expect(std.mem.indexOf(u8, quiet, "\"prompt\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, reader.last_user.?, "Current date:") == null);
}

test "runtime answer reasoning and temporal hints reach the reader and the trace" {
    var harness = try RuntimeTestHarness.init(std.testing.allocator);
    defer harness.deinit();
    var reader = TestReader{ .with_reasoning = true };
    defer reader.deinit();
    var runtime = Runtime.initWithOptions(harness.adapter(), harness.health(), .{ .answer_provider = reader.endpoint() });
    defer runtime.deinit();
    try rememberPetSessions(&runtime);

    const answer = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"a1\",\"method\":\"memory.answer\",\"params\":{\"query\":\"What cat and dog did I mention last week?\",\"scope\":{\"userId\":\"u1\"},\"needs\":[\"raw\"],\"time\":{\"validAt\":\"2023-05-30T23:40:00Z\"},\"options\":{\"includeDebug\":true,\"logRetrieval\":false,\"readerReasoning\":true,\"temporalHints\":true}}}",
    );
    defer std.testing.allocator.free(answer);

    try std.testing.expectEqualStrings(providers.answer_reasoning_system_prompt, reader.last_system);
    try std.testing.expectEqual(@as(?u32, providers.reasoning_min_output_tokens), reader.last_min_output_tokens);
    const prompt = try resultStringField(std.testing.allocator, answer, "prompt");
    defer std.testing.allocator.free(prompt);
    try std.testing.expect(std.mem.startsWith(u8, prompt, "<memory>\n<sessions>\n## session s-early 2023-05-20 (Sat), 10 days ago\n"));
    try expectInOrder(prompt, &.{ "## session s-late 2023-05-22 (Mon), 8 days ago\n", "] user: I adopted a cat named Miso.\n" });
    try std.testing.expect(std.mem.startsWith(
        u8,
        reader.last_user.?,
        "Current date: 2023-05-30 (Tuesday)\nTime references: \"last week\" = 2023-05-22 to 2023-05-28\n\nQuestion:\nWhat cat and dog did I mention last week?\n\nMemory context:\n<memory>",
    ));
    try std.testing.expect(std.mem.endsWith(u8, reader.last_user.?, prompt));

    var parsed = try std.json.parseFromSlice(Value, std.testing.allocator, answer, .{});
    defer parsed.deinit();
    const result = parsed.value.object.get("result").?.object;
    try std.testing.expectEqualStrings("Miso", result.get("answer").?.string);
    const trace = result.get("answerTrace").?.object;
    try std.testing.expectEqualStrings("reasoning", trace.get("readerMode").?.string);
    try std.testing.expect(trace.get("temporalHints").?.bool);
    try std.testing.expectEqualStrings("\"last week\" = 2023-05-22 to 2023-05-28", trace.get("timeReferences").?.string);
    try std.testing.expectEqualStrings("[cat line] 2023-05-22 user adopted a cat named Miso.", trace.get("reasoning").?.string);
    try std.testing.expect(trace.get("supportValid").?.bool);
    try std.testing.expectEqual(@as(usize, 0), result.get("warnings").?.array.items.len);

    // A reader that skips the reasoning keeps its answer and adds a warning.
    reader.with_reasoning = false;
    const bare = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"a2\",\"method\":\"memory.answer\",\"params\":{\"query\":\"What is my cat called?\",\"scope\":{\"userId\":\"u1\"},\"needs\":[\"raw\"],\"options\":{\"includeDebug\":true,\"logRetrieval\":false,\"readerReasoning\":true,\"temporalHints\":true}}}",
    );
    defer std.testing.allocator.free(bare);
    try std.testing.expect(std.mem.indexOf(u8, bare, "\"answer\":\"Miso\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bare, "\"warnings\":[\"missing_reasoning\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, bare, "\"readerMode\":\"reasoning\"") != null);
    // Without time.validAt there is no date to hint against.
    try std.testing.expect(std.mem.indexOf(u8, bare, "\"temporalHints\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, bare, " ago") == null);
    try std.testing.expect(std.mem.indexOf(u8, reader.last_user.?, "Time references:") == null);
}

test "runtime retrieve renders temporal hints only when requested" {
    var harness = try RuntimeTestHarness.init(std.testing.allocator);
    defer harness.deinit();
    var runtime = Runtime.init(harness.adapter(), harness.health());
    defer runtime.deinit();
    try rememberPetSessions(&runtime);

    const hinted = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"q1\",\"method\":\"memory.retrieve\",\"params\":{\"query\":\"cat dog Miso Rex since the start of the year\",\"scope\":{\"userId\":\"u1\"},\"needs\":[\"raw\"],\"time\":{\"validAt\":\"2023-08-28T10:00:00Z\"},\"options\":{\"logRetrieval\":false,\"logAudit\":false,\"temporalHints\":true}}}",
    );
    defer std.testing.allocator.free(hinted);
    const prompt = try resultStringField(std.testing.allocator, hinted, "prompt");
    defer std.testing.allocator.free(prompt);
    try std.testing.expect(std.mem.startsWith(
        u8,
        prompt,
        "Current date: 2023-08-28 (Monday)\nTime references: \"since the start of the year\" = 2023-01-01 to 2023-08-28\n<memory>\n<sessions>\n## session s-early 2023-05-20 (Sat), ~3 months (100 days) ago\n",
    ));
    try expectInOrder(prompt, &.{"## session s-late 2023-05-22 (Mon), ~3 months (98 days) ago\n"});

    const plain = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"q2\",\"method\":\"memory.retrieve\",\"params\":{\"query\":\"cat dog Miso Rex since the start of the year\",\"scope\":{\"userId\":\"u1\"},\"needs\":[\"raw\"],\"time\":{\"validAt\":\"2023-08-28T10:00:00Z\"},\"options\":{\"logRetrieval\":false,\"logAudit\":false}}}",
    );
    defer std.testing.allocator.free(plain);
    const plain_prompt = try resultStringField(std.testing.allocator, plain, "prompt");
    defer std.testing.allocator.free(plain_prompt);
    try std.testing.expect(std.mem.startsWith(u8, plain_prompt, "Current date: 2023-08-28 (Monday)\n<memory>\n<sessions>\n## session s-early 2023-05-20 (Sat)\n"));
}

test "runtime answer abstains without calling the reader when nothing is retrieved" {
    var harness = try RuntimeTestHarness.init(std.testing.allocator);
    defer harness.deinit();
    var reader = TestReader{};
    defer reader.deinit();
    var runtime = Runtime.initWithOptions(harness.adapter(), harness.health(), .{ .answer_provider = reader.endpoint() });
    defer runtime.deinit();
    try rememberPetSessions(&runtime);

    const answer = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"a1\",\"method\":\"memory.answer\",\"params\":{\"query\":\"zebra quantum\",\"scope\":{\"userId\":\"u1\"},\"needs\":[\"raw\"],\"options\":{\"includeDebug\":true,\"logRetrieval\":false}}}",
    );
    defer std.testing.allocator.free(answer);
    try std.testing.expectEqual(@as(usize, 0), reader.calls);
    try std.testing.expect(std.mem.indexOf(u8, answer, "\"answer\":\"[abstain]\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, answer, "\"strategy\":\"abstain\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, answer, "\"confidence\":0") != null);
}

test "runtime answer keeps reader answers with invalid support unless abstainIfWeak" {
    var harness = try RuntimeTestHarness.init(std.testing.allocator);
    defer harness.deinit();
    var reader = TestReader{ .cite_invalid = true };
    defer reader.deinit();
    var runtime = Runtime.initWithOptions(harness.adapter(), harness.health(), .{ .answer_provider = reader.endpoint() });
    defer runtime.deinit();
    try rememberPetSessions(&runtime);

    const kept = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"a1\",\"method\":\"memory.answer\",\"params\":{\"query\":\"What is my cat's name?\",\"scope\":{\"userId\":\"u1\"},\"needs\":[\"raw\"],\"options\":{\"includeDebug\":true,\"logRetrieval\":false}}}",
    );
    defer std.testing.allocator.free(kept);
    try std.testing.expect(std.mem.indexOf(u8, kept, "\"answer\":\"Miso\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, kept, "\"supportValid\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, kept, "\"invalid_support\"") != null);
    // The invented qid stays only in the raw reader output, never in support.
    try std.testing.expect(std.mem.indexOf(u8, kept, "\"supportQids\":[]") != null);

    const abstained = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"a2\",\"method\":\"memory.answer\",\"params\":{\"query\":\"What is my cat's name?\",\"scope\":{\"userId\":\"u1\"},\"needs\":[\"raw\"],\"options\":{\"includeDebug\":true,\"abstainIfWeak\":true,\"logRetrieval\":false}}}",
    );
    defer std.testing.allocator.free(abstained);
    try std.testing.expect(std.mem.indexOf(u8, abstained, "\"answer\":\"[abstain]\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, abstained, "\"status\":\"abstained\"") != null);
}

/// In-process cross-encoder for rerank tests. Scores rise with fused
/// position, so a fully reranked window comes back reversed.
const TestReranker = struct {
    calls: usize = 0,
    fail: bool = false,
    last_top_n: usize = 0,
    documents: std.ArrayList([]u8) = .empty,

    fn endpoint(self: *TestReranker) providers.ProviderEndpoint {
        return .{
            .kind = .callback,
            .name = "test-reranker",
            .model = "test-cross-encoder",
            .rerank_callback = .{ .context = self, .rerank = rerank },
        };
    }

    fn rerank(context: ?*anyopaque, allocator: std.mem.Allocator, request: providers.RerankRequest) anyerror![]providers.RerankResult {
        const self: *TestReranker = @ptrCast(@alignCast(context.?));
        self.calls += 1;
        self.clearDocuments();
        for (request.documents) |document| {
            try self.documents.append(std.testing.allocator, try std.testing.allocator.dupe(u8, document));
        }
        self.last_top_n = request.top_n;
        if (self.fail) return error.ProviderRequestFailed;
        const results = try allocator.alloc(providers.RerankResult, request.documents.len);
        for (results, 0..) |*result, index| result.* = .{ .index = index, .relevance_score = @floatFromInt(index) };
        return results;
    }

    fn clearDocuments(self: *TestReranker) void {
        for (self.documents.items) |document| std.testing.allocator.free(document);
        self.documents.clearRetainingCapacity();
    }

    fn deinit(self: *TestReranker) void {
        self.clearDocuments();
        self.documents.deinit(std.testing.allocator);
    }
};

const ResponseQids = struct {
    parsed: std.json.Parsed(Value),
    qids: [][]const u8,

    fn deinit(self: *ResponseQids) void {
        std.testing.allocator.free(self.qids);
        self.parsed.deinit();
    }
};

/// Item qids of a retrieve/answer response, in rank order.
fn responseItemQids(response: []const u8) !ResponseQids {
    var parsed = try std.json.parseFromSlice(Value, std.testing.allocator, response, .{});
    errdefer parsed.deinit();
    const items = parsed.value.object.get("result").?.object.get("items").?.array.items;
    const qids = try std.testing.allocator.alloc([]const u8, items.len);
    for (items, 0..) |item, index| qids[index] = item.object.get("qid").?.string;
    return .{ .parsed = parsed, .qids = qids };
}

fn retrievePets(runtime: *Runtime, options_json: []const u8) ![]u8 {
    const request = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":\"q\",\"method\":\"memory.retrieve\",\"params\":{{\"query\":\"cat dog Miso Rex\",\"scope\":{{\"userId\":\"u1\"}},\"needs\":[\"raw\"],\"options\":{{\"includeDebug\":true,\"logRetrieval\":false,\"logAudit\":false{s}}}}}}}",
        .{options_json},
    );
    defer std.testing.allocator.free(request);
    return runtime.dispatch(std.testing.allocator, request);
}

test "rerank order sorts scored items by score with ties in fused order" {
    const scores = [_]providers.RerankResult{
        .{ .index = 3, .relevance_score = 0.2 },
        .{ .index = 1, .relevance_score = 0.9 },
        .{ .index = 0, .relevance_score = 0.2 },
    };
    // Index 2 was not scored: it follows the scored items.
    const order = try rerankOrder(std.testing.allocator, 4, &scores);
    defer std.testing.allocator.free(order);
    try std.testing.expectEqualSlices(usize, &.{ 1, 0, 3, 2 }, order);
}

test "runtime rerank reorders the candidate window before budget packing" {
    var harness = try RuntimeTestHarness.init(std.testing.allocator);
    defer harness.deinit();
    var reranker = TestReranker{};
    defer reranker.deinit();
    var runtime = Runtime.initWithOptions(harness.adapter(), harness.health(), .{ .io = std.testing.io, .reranker = reranker.endpoint() });
    defer runtime.deinit();
    try rememberPetSessions(&runtime);

    const bypass = try retrievePets(&runtime, ",\"rerank\":false");
    defer std.testing.allocator.free(bypass);
    try std.testing.expectEqual(@as(usize, 0), reranker.calls);
    try std.testing.expect(std.mem.indexOf(u8, bypass, "\"rerank\":{\"model\":\"test-cross-encoder\",\"status\":\"disabled\",\"windowSize\":0,\"rerankedCount\":0") != null);
    var fused = try responseItemQids(bypass);
    defer fused.deinit();
    const count = fused.qids.len;
    try std.testing.expect(count >= 3);

    const full = try retrievePets(&runtime, "");
    defer std.testing.allocator.free(full);
    try std.testing.expectEqual(@as(usize, 1), reranker.calls);
    try std.testing.expectEqual(count, reranker.last_top_n);
    try std.testing.expectEqual(count, reranker.documents.items.len);
    var reranked = try responseItemQids(full);
    defer reranked.deinit();
    try std.testing.expectEqual(count, reranked.qids.len);
    for (reranked.qids, 0..) |qid, index| try std.testing.expectEqualStrings(fused.qids[count - 1 - index], qid);
    try std.testing.expect(std.mem.indexOf(u8, full, "\"warnings\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, full, "\"status\":\"applied\"") != null);
    const top = try std.fmt.allocPrint(std.testing.allocator, "\"topScores\":[{{\"qid\":\"{s}\",\"score\":{d}}}", .{ fused.qids[count - 1], count - 1 });
    defer std.testing.allocator.free(top);
    try std.testing.expect(std.mem.indexOf(u8, full, top) != null);

    // Raw evidence is scored as `YYYY-MM-DD role: text`.
    var saw_document = false;
    for (reranker.documents.items) |document| {
        if (std.mem.eql(u8, document, "2023-05-22 user: I adopted a cat named Miso.")) saw_document = true;
    }
    try std.testing.expect(saw_document);

    // Only the window is reordered; later items keep fused order.
    const windowed = try retrievePets(&runtime, ",\"rerankCandidates\":2");
    defer std.testing.allocator.free(windowed);
    try std.testing.expectEqual(@as(usize, 2), reranker.last_top_n);
    var window_qids = try responseItemQids(windowed);
    defer window_qids.deinit();
    try std.testing.expectEqualStrings(fused.qids[1], window_qids.qids[0]);
    try std.testing.expectEqualStrings(fused.qids[0], window_qids.qids[1]);
    for (2..count) |index| try std.testing.expectEqualStrings(fused.qids[index], window_qids.qids[index]);
    try std.testing.expect(std.mem.indexOf(u8, windowed, "\"windowSize\":2,\"rerankedCount\":2") != null);

    const invalid = try retrievePets(&runtime, ",\"rerankCandidates\":0");
    defer std.testing.allocator.free(invalid);
    try std.testing.expect(std.mem.indexOf(u8, invalid, "\"code\":\"invalid_request\"") != null);
}

test "runtime rerank failure keeps fused order and warns" {
    var harness = try RuntimeTestHarness.init(std.testing.allocator);
    defer harness.deinit();
    var reranker = TestReranker{ .fail = true };
    defer reranker.deinit();
    var reader = TestReader{};
    defer reader.deinit();
    var runtime = Runtime.initWithOptions(harness.adapter(), harness.health(), .{
        .answer_provider = reader.endpoint(),
        .reranker = reranker.endpoint(),
    });
    defer runtime.deinit();
    try rememberPetSessions(&runtime);

    const bypass = try retrievePets(&runtime, ",\"rerank\":false");
    defer std.testing.allocator.free(bypass);
    var fused = try responseItemQids(bypass);
    defer fused.deinit();

    const failed = try retrievePets(&runtime, "");
    defer std.testing.allocator.free(failed);
    try std.testing.expectEqual(@as(usize, 1), reranker.calls);
    var kept = try responseItemQids(failed);
    defer kept.deinit();
    try std.testing.expectEqual(fused.qids.len, kept.qids.len);
    for (fused.qids, kept.qids) |expected, actual| try std.testing.expectEqualStrings(expected, actual);
    try std.testing.expect(std.mem.indexOf(u8, failed, "\"warnings\":[\"rerank_failed\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, failed, "\"status\":\"failed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, failed, "\"error\":\"ProviderRequestFailed\"") != null);

    // memory.answer reranks too, and a failed rerank never fails the answer.
    const answer = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"a1\",\"method\":\"memory.answer\",\"params\":{\"query\":\"What is my cat called?\",\"scope\":{\"userId\":\"u1\"},\"needs\":[\"raw\"],\"options\":{\"includeDebug\":true,\"logRetrieval\":false}}}",
    );
    defer std.testing.allocator.free(answer);
    try std.testing.expectEqual(@as(usize, 2), reranker.calls);
    try std.testing.expectEqual(@as(usize, 1), reader.calls);
    try std.testing.expect(std.mem.indexOf(u8, answer, "\"answer\":\"Miso\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, answer, "\"rerank_failed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, answer, "\"status\":\"failed\"") != null);

    reranker.fail = false;
    const reranked_answer = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"a2\",\"method\":\"memory.answer\",\"params\":{\"query\":\"What is my cat called?\",\"scope\":{\"userId\":\"u1\"},\"needs\":[\"raw\"],\"options\":{\"includeDebug\":true,\"logRetrieval\":false,\"rerankCandidates\":1}}}",
    );
    defer std.testing.allocator.free(reranked_answer);
    try std.testing.expectEqual(@as(usize, 3), reranker.calls);
    try std.testing.expect(std.mem.indexOf(u8, reranked_answer, "\"rerank_failed\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, reranked_answer, "\"status\":\"applied\",\"windowSize\":1,\"rerankedCount\":1") != null);
}

test "runtime without a reranker leaves retrieval unchanged" {
    var harness = try RuntimeTestHarness.init(std.testing.allocator);
    defer harness.deinit();
    var runtime = Runtime.init(harness.adapter(), harness.health());
    defer runtime.deinit();
    try rememberPetSessions(&runtime);

    const plain = try retrievePets(&runtime, "");
    defer std.testing.allocator.free(plain);
    try std.testing.expect(std.mem.indexOf(u8, plain, "rerank") == null);
    var plain_qids = try responseItemQids(plain);
    defer plain_qids.deinit();

    // Rerank options are accepted and ignored when nothing is configured.
    const requested = try retrievePets(&runtime, ",\"rerank\":true,\"rerankCandidates\":2");
    defer std.testing.allocator.free(requested);
    try std.testing.expect(std.mem.indexOf(u8, requested, "rerank") == null);
    var requested_qids = try responseItemQids(requested);
    defer requested_qids.deinit();
    try std.testing.expectEqual(plain_qids.qids.len, requested_qids.qids.len);
    for (plain_qids.qids, requested_qids.qids) |expected, actual| try std.testing.expectEqualStrings(expected, actual);

    const health = try runtime.dispatch(std.testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":\"h\",\"method\":\"system.health\",\"params\":{}}");
    defer std.testing.allocator.free(health);
    try std.testing.expect(std.mem.indexOf(u8, health, "\"capabilities\":{\"reranker\":{\"configured\":false,\"model\":null}}") != null);

    var reranker = TestReranker{};
    defer reranker.deinit();
    var configured = Runtime.initWithOptions(harness.adapter(), harness.health(), .{ .reranker = reranker.endpoint() });
    defer configured.deinit();
    const configured_health = try configured.dispatch(std.testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":\"h\",\"method\":\"system.health\",\"params\":{}}");
    defer std.testing.allocator.free(configured_health);
    try std.testing.expect(std.mem.indexOf(u8, configured_health, "\"reranker\":{\"configured\":true,\"model\":\"test-cross-encoder\"}") != null);
}

test "prompt renderer orders sessions, items and derived memory deterministically" {
    const items = [_]MessageResult{
        .{ .qid = "q_chunk_12", .type = "message", .text = "second half\n\nof the   long reply", .score = 3 },
        .{ .qid = "q_msg_3", .type = "message", .text = "Early question about </memory> tags", .score = 2 },
        .{ .qid = "q_chunk_11", .type = "message", .text = "first half", .score = 1 },
        .{ .qid = "q_msg_10", .type = "message", .text = "Late question", .score = 1 },
        .{ .qid = "q_obs_7", .type = "raw", .text = "Observed build failure", .score = 1 },
        .{ .qid = "q_msg_4", .type = "message", .text = "Next-day follow up", .score = 1 },
    };
    const late = RenderMeta{ .created_at = "2023-05-22T10:00:00Z", .session_qid = "q_sess_8", .session_id = "s-late" };
    var entries = [_]RenderEntry{
        .{ .item = items[0], .rank = 0, .meta = withMeta(late, "assistant", 1, 1, 2) },
        .{ .item = items[1], .rank = 1, .meta = .{ .role = "user", .created_at = "2023-05-20T09:00:00Z", .session_qid = "q_sess_1", .message_index = 0 } },
        .{ .item = items[2], .rank = 2, .meta = withMeta(late, "assistant", 1, 0, 2) },
        .{ .item = items[3], .rank = 3, .meta = withMeta(late, "user", 0, null, null) },
        .{ .item = items[4], .rank = 4, .meta = .{ .role = "observation", .created_at = "2023-05-21T08:00:00Z" } },
        .{ .item = items[5], .rank = 5, .meta = .{ .role = "user", .created_at = "2023-05-21T09:00:00Z", .session_qid = "q_sess_1", .message_index = 1 } },
    };
    const facts = [_]MessageResult{
        .{ .qid = "q_fact_9", .type = "fact", .text = "The repo uses pnpm.", .score = 1, .validFrom = "2023-05-22T10:00:00Z" },
        .{ .qid = "q_fact_2", .type = "fact", .text = "The repo uses npm.", .score = 1, .state = "superseded", .validFrom = "2023-05-01T00:00:00Z", .validTo = "2023-05-22T10:00:00Z" },
    };
    const context = ContextPacket{ .currentFacts = &facts, .episodes = &items };
    const expected =
        \\Current date: 2023-05-30 (Tuesday)
        \\<memory>
        \\<facts>
        \\[q_fact_2] (superseded, 2023-05-01 to 2023-05-22) The repo uses npm.
        \\[q_fact_9] (current, from 2023-05-22) The repo uses pnpm.
        \\</facts>
        \\<sessions>
        \\## session q_sess_1 2023-05-20 (Sat)
        \\[q_msg_3] user: Early question about [/memory] tags
        \\[q_msg_4] 2023-05-21 user: Next-day follow up
        \\## session s-late 2023-05-22 (Mon)
        \\[q_msg_10] user: Late question
        \\[q_chunk_11] assistant (1/2): first half
        \\[q_chunk_12] assistant (2/2): second half of the long reply
        \\## other
        \\[q_obs_7] 2023-05-21 observation: Observed build failure
        \\</sessions>
        \\</memory>
    ;

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const prompt = try renderPrompt(std.testing.allocator, arena_state.allocator(), context, &entries, .{ .current_date = "2023-05-30T23:40:00Z" });
    defer std.testing.allocator.free(prompt);
    try std.testing.expectEqualStrings(expected, prompt);

    // Retrieval rank order does not change the rendering.
    std.mem.reverse(RenderEntry, &entries);
    for (&entries, 0..) |*entry, rank| entry.rank = rank;
    const reversed = try renderPrompt(std.testing.allocator, arena_state.allocator(), context, &entries, .{ .current_date = "2023-05-30T23:40:00Z" });
    defer std.testing.allocator.free(reversed);
    try std.testing.expectEqualStrings(expected, reversed);
}

test "prompt renderer appends session offsets from the hint date" {
    const items = [_]MessageResult{
        .{ .qid = "q_msg_1", .type = "message", .text = "Old trip.", .score = 1 },
        .{ .qid = "q_msg_2", .type = "message", .text = "Recent run.", .score = 1 },
        .{ .qid = "q_obs_3", .type = "raw", .text = "Loose note.", .score = 1 },
        .{ .qid = "q_msg_4", .type = "message", .text = "Same-day plan.", .score = 1 },
    };
    const entries = [_]RenderEntry{
        .{ .item = items[0], .rank = 0, .meta = .{ .role = "user", .created_at = "2021-02-28T09:00:00Z", .session_id = "s-old" } },
        .{ .item = items[1], .rank = 1, .meta = .{ .role = "user", .created_at = "2024-02-28T09:00:00Z", .session_id = "s-feb" } },
        .{ .item = items[2], .rank = 2, .meta = .{ .role = "observation", .created_at = "2024-02-01T08:00:00Z" } },
        .{ .item = items[3], .rank = 3, .meta = .{ .role = "user", .created_at = "2024-03-01T07:00:00Z", .session_id = "s-today" } },
    };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const prompt = try renderPrompt(std.testing.allocator, arena_state.allocator(), .{ .episodes = &items }, &entries, .{
        .current_date = "2024-03-01T12:00:00Z",
        .hint_date = try parseIsoDate("2024-03-01"),
        .time_references = "\"yesterday\" = 2024-02-29 (Thu)",
    });
    defer std.testing.allocator.free(prompt);
    try std.testing.expectEqualStrings(
        \\Current date: 2024-03-01 (Friday)
        \\Time references: "yesterday" = 2024-02-29 (Thu)
        \\<memory>
        \\<sessions>
        \\## session s-old 2021-02-28 (Sun), ~3 years (1097 days) ago
        \\[q_msg_1] user: Old trip.
        \\## session s-feb 2024-02-28 (Wed), 2 days ago
        \\[q_msg_2] user: Recent run.
        \\## session s-today 2024-03-01 (Fri), today
        \\[q_msg_4] user: Same-day plan.
        \\## other
        \\[q_obs_3] 2024-02-01 observation: Loose note.
        \\</sessions>
        \\</memory>
    ,
        prompt,
    );
}

fn withMeta(base: RenderMeta, role: []const u8, message_index: ?i64, chunk_index: ?i64, chunk_count: ?i64) RenderMeta {
    var meta = base;
    meta.role = role;
    meta.message_index = message_index;
    meta.chunk_index = chunk_index;
    meta.chunk_count = chunk_count;
    return meta;
}

test "prompt renderer resolves sessions from raw sources and legacy nodes" {
    var harness = try RuntimeTestHarness.init(std.testing.allocator);
    defer harness.deinit();
    const store = harness.adapter();
    try store.putNode(.{ .qid = "q_sess_1", .label = "Session", .properties_json = "{\"kind\":\"session\",\"sessionId\":\"lme-7\",\"deleted\":false}" });
    try store.putNode(.{ .qid = "q_turn_2", .label = "Turn", .properties_json = "{\"kind\":\"turn\",\"sessionQid\":\"q_sess_1\",\"deleted\":false}" });
    try store.putNode(.{ .qid = "q_msg_3", .label = "Message", .properties_json = "{\"kind\":\"message\",\"role\":\"user\",\"content\":\"Legacy note.\",\"createdAt\":\"2024-02-28T08:00:00Z\",\"deleted\":false}" });
    try store.putEdge(.{ .qid = "q_edge_1", .from_qid = "q_turn_2", .to_qid = "q_msg_3", .edge_type = "HAS_MESSAGE", .properties_json = "{}" });
    try store.putNode(.{ .qid = "q_sess_5", .label = "Session", .properties_json = "{\"kind\":\"session\",\"sessionId\":\"s-2\",\"deleted\":false}" });

    try std.testing.expectError(error.NoRenderableText, textForNode(std.testing.allocator, .{ .qid = "q_sess_1", .label = "Session", .properties_json = "{}" }));

    const items = [_]MessageResult{
        // Chunk item: raw source names the session qid; the caller id comes from the Session node.
        .{ .qid = "q_chunk_6_1", .type = "message", .text = "tail part", .score = 2, .raw_source = .{
            .role = "assistant",
            .created_at = "2024-02-29T08:00:00Z",
            .session_qid = "q_sess_5",
            .message_qid = "q_msg_6",
            .message_index = 0,
            .chunk_index = 1,
            .chunk_count = 2,
        } },
        // Legacy message without session fields: resolved through its Turn edge.
        .{ .qid = "q_msg_3", .type = "message", .text = "Legacy note.", .score = 1, .raw_source = .{
            .role = "user",
            .created_at = "2024-02-28T08:00:00Z",
            .message_qid = "q_msg_3",
        } },
        .{ .qid = "q_unknown_9", .type = "message", .text = "No node behind this item.", .score = 1, .validFrom = "2024-03-01T00:00:00Z" },
    };
    const prompt = try promptFromContext(std.testing.allocator, store, .{ .episodes = &items }, .{});
    defer std.testing.allocator.free(prompt);
    try std.testing.expectEqualStrings(
        "<memory>\n<sessions>\n## session lme-7 2024-02-28 (Wed)\n[q_msg_3] user: Legacy note.\n## session s-2 2024-02-29 (Thu)\n[q_chunk_6_1] assistant (2/2): tail part\n## other\n[q_unknown_9] 2024-03-01: No node behind this item.\n</sessions>\n</memory>",
        prompt,
    );
    try std.testing.expectEqual(std.math.Order.lt, naturalQidOrder("q_chunk_9_1", "q_chunk_10_0"));
    try std.testing.expectEqual(std.math.Order.lt, naturalQidOrder("q_msg_9", "q_msg_10"));
}

test "runtime retrieve assembles categorized context and trace" {
    var harness = try RuntimeTestHarness.init(std.testing.allocator);
    defer harness.deinit();
    var runtime = Runtime.init(harness.adapter(), harness.health());
    defer runtime.deinit();

    const remember = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"r1\",\"method\":\"memory.remember\",\"params\":{\"scope\":{\"projectId\":\"repo:test\"},\"messages\":[{\"role\":\"user\",\"content\":\"This repo uses pnpm. Run just test before committing.\",\"createdAt\":\"2026-04-01T10:00:00Z\"}]}}",
    );
    defer std.testing.allocator.free(remember);

    const core = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"c1\",\"method\":\"memory.core.update\",\"params\":{\"blockKey\":\"project_state\",\"scope\":{\"projectId\":\"repo:test\"},\"text\":\"Prefer small focused patches.\",\"mode\":\"replace\",\"managedBy\":\"user\"}}",
    );
    defer std.testing.allocator.free(core);

    const retrieve = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"q1\",\"method\":\"memory.retrieve\",\"params\":{\"query\":\"package manager test command\",\"scope\":{\"projectId\":\"repo:test\"},\"needs\":[\"core\",\"current_facts\",\"procedural\"],\"options\":{\"includeDebug\":true}}}",
    );
    defer std.testing.allocator.free(retrieve);

    try std.testing.expect(std.mem.indexOf(u8, retrieve, "\"core\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, retrieve, "\"currentFacts\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, retrieve, "\"procedural\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, retrieve, "Prefer small focused patches.") != null);
    try std.testing.expect(std.mem.indexOf(u8, retrieve, "The repo uses pnpm as its package manager.") != null);
    try std.testing.expect(std.mem.indexOf(u8, retrieve, "Run just test before committing.") != null);
    try std.testing.expect(std.mem.indexOf(u8, retrieve, "\"trace\":{") != null);
    try std.testing.expect(std.mem.indexOf(u8, retrieve, "\"requestedNeedsCount\":3") != null);
    try std.testing.expect(std.mem.indexOf(u8, retrieve, "\"candidateSources\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, retrieve, "\"scoreBreakdowns\"") != null);

    const no_evidence = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"q2\",\"method\":\"memory.retrieve\",\"params\":{\"query\":\"package manager\",\"scope\":{\"projectId\":\"repo:test\"},\"needs\":[\"current_facts\"],\"options\":{\"includeEvidence\":false}}}",
    );
    defer std.testing.allocator.free(no_evidence);
    try std.testing.expect(std.mem.indexOf(u8, no_evidence, "\"evidence\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, no_evidence, "\"quote\"") == null);
}

test "runtime retrieve filters event windows and token budgets" {
    var harness = try RuntimeTestHarness.init(std.testing.allocator);
    defer harness.deinit();
    var runtime = Runtime.init(harness.adapter(), harness.health());
    defer runtime.deinit();

    const old = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"r1\",\"method\":\"memory.remember\",\"params\":{\"scope\":{\"projectId\":\"repo:test\"},\"messages\":[{\"role\":\"user\",\"content\":\"Window marker old note.\",\"createdAt\":\"2026-01-01T10:00:00Z\"}],\"extract\":false}}",
    );
    defer std.testing.allocator.free(old);
    const fresh = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"r2\",\"method\":\"memory.remember\",\"params\":{\"scope\":{\"projectId\":\"repo:test\"},\"messages\":[{\"role\":\"user\",\"content\":\"Window marker fresh note.\",\"createdAt\":\"2026-02-01T10:00:00Z\"}],\"extract\":false}}",
    );
    defer std.testing.allocator.free(fresh);

    const windowed = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"q1\",\"method\":\"memory.retrieve\",\"params\":{\"query\":\"window marker\",\"scope\":{\"projectId\":\"repo:test\"},\"needs\":[\"raw\"],\"time\":{\"eventWindowStart\":\"2026-01-15T00:00:00Z\"}}}",
    );
    defer std.testing.allocator.free(windowed);
    try std.testing.expect(std.mem.indexOf(u8, windowed, "Window marker fresh note.") != null);
    try std.testing.expect(std.mem.indexOf(u8, windowed, "Window marker old note.") == null);

    const budgeted = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"q2\",\"method\":\"memory.retrieve\",\"params\":{\"query\":\"window marker\",\"scope\":{\"projectId\":\"repo:test\"},\"needs\":[\"raw\"],\"budgetTokens\":1,\"options\":{\"includeDebug\":true}}}",
    );
    defer std.testing.allocator.free(budgeted);
    try std.testing.expect(std.mem.indexOf(u8, budgeted, "\"token_budget_truncated\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, budgeted, "\"no_memory_items\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, budgeted, "\"droppedForBudget\":2") != null);
}

test "runtime validAt excludes future raw messages" {
    var harness = try RuntimeTestHarness.init(std.testing.allocator);
    defer harness.deinit();
    var runtime = Runtime.init(harness.adapter(), harness.health());
    defer runtime.deinit();

    const old = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"r1\",\"method\":\"memory.remember\",\"params\":{\"scope\":{\"projectId\":\"repo:test\"},\"messages\":[{\"role\":\"user\",\"content\":\"Temporal raw old marker.\",\"createdAt\":\"2026-01-01T10:00:00Z\"}],\"extract\":false}}",
    );
    defer std.testing.allocator.free(old);
    const future = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"r2\",\"method\":\"memory.remember\",\"params\":{\"scope\":{\"projectId\":\"repo:test\"},\"messages\":[{\"role\":\"user\",\"content\":\"Temporal raw future marker.\",\"createdAt\":\"2026-03-01T10:00:00Z\"}],\"extract\":false}}",
    );
    defer std.testing.allocator.free(future);

    const retrieve = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"q1\",\"method\":\"memory.retrieve\",\"params\":{\"query\":\"Temporal raw marker\",\"scope\":{\"projectId\":\"repo:test\"},\"needs\":[\"raw\"],\"time\":{\"validAt\":\"2026-02-01T00:00:00Z\"}}}",
    );
    defer std.testing.allocator.free(retrieve);
    try std.testing.expect(std.mem.indexOf(u8, retrieve, "Temporal raw old marker.") != null);
    try std.testing.expect(std.mem.indexOf(u8, retrieve, "Temporal raw future marker.") == null);
}

test "runtime graph retrieve expands through resolved entities" {
    var harness = try RuntimeTestHarness.init(std.testing.allocator);
    defer harness.deinit();
    var runtime = Runtime.init(harness.adapter(), harness.health());
    defer runtime.deinit();

    const first = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"r1\",\"method\":\"memory.remember\",\"params\":{\"scope\":{\"userId\":\"locomo-user\"},\"messages\":[{\"role\":\"user\",\"content\":\"Alice likes ramen.\"}],\"extract\":false}}",
    );
    defer std.testing.allocator.free(first);
    const second = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"r2\",\"method\":\"memory.remember\",\"params\":{\"scope\":{\"userId\":\"locomo-user\"},\"messages\":[{\"role\":\"user\",\"content\":\"She moved to Lisbon.\"}],\"extract\":false}}",
    );
    defer std.testing.allocator.free(second);

    const aliases = [_][]const u8{"Alice"};
    const entity = providers.ResolvedEntity{
        .name = "Alice Smith",
        .entity_type = "person",
        .aliases = &aliases,
    };
    const entities = [_]providers.ResolvedEntity{entity};
    try runtime.writeEntityMentions(std.testing.allocator, .{ .user_id = "locomo-user" }, "q_msg_4", &entities);
    try runtime.writeEntityMentions(std.testing.allocator, .{ .user_id = "locomo-user" }, "q_msg_9", &entities);

    const graph = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"q1\",\"method\":\"memory.retrieve\",\"params\":{\"query\":\"Alice Smith\",\"mode\":\"graph\",\"scope\":{\"userId\":\"locomo-user\"},\"needs\":[\"raw\"]}}",
    );
    defer std.testing.allocator.free(graph);

    try std.testing.expect(std.mem.indexOf(u8, graph, "Alice likes ramen.") != null);
    try std.testing.expect(std.mem.indexOf(u8, graph, "She moved to Lisbon.") != null);
}

test "runtime answer uses retrieved context with deterministic provider fallback" {
    var harness = try RuntimeTestHarness.init(std.testing.allocator);
    defer harness.deinit();
    var runtime = Runtime.init(harness.adapter(), harness.health());
    defer runtime.deinit();

    const remember = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"r1\",\"method\":\"memory.remember\",\"params\":{\"scope\":{\"projectId\":\"repo:test\"},\"messages\":[{\"role\":\"user\",\"content\":\"Run just test before committing.\"}],\"extract\":false}}",
    );
    defer std.testing.allocator.free(remember);

    const answer = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"a1\",\"method\":\"memory.answer\",\"params\":{\"query\":\"What should I run before committing?\",\"scope\":{\"projectId\":\"repo:test\"},\"needs\":[\"raw\"],\"options\":{\"includeDebug\":true,\"logRetrieval\":false}}}",
    );
    defer std.testing.allocator.free(answer);

    try std.testing.expect(std.mem.indexOf(u8, answer, "\"answer\":\"Run just test before committing.\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, answer, "\"provider\":\"deterministic_prompt\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, answer, "\"strategy\":\"deterministic_fallback\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, answer, "\"trace\":{") != null);
}

test "runtime raw retrieve exposes message source metadata" {
    var harness = try RuntimeTestHarness.init(std.testing.allocator);
    defer harness.deinit();
    var runtime = Runtime.init(harness.adapter(), harness.health());
    defer runtime.deinit();

    const remember = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"r1\",\"method\":\"memory.remember\",\"params\":{\"scope\":{\"projectId\":\"repo:test\"},\"sessionId\":\"sess-a\",\"messages\":[{\"role\":\"user\",\"content\":\"Hello there.\",\"createdAt\":\"2026-02-01T10:00:00Z\"},{\"role\":\"assistant\",\"content\":\"Today I rescheduled the dentist appointment.\",\"createdAt\":\"2026-02-01T10:00:00Z\"}],\"extract\":false}}",
    );
    defer std.testing.allocator.free(remember);

    const retrieve = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"q1\",\"method\":\"memory.retrieve\",\"params\":{\"query\":\"dentist appointment\",\"scope\":{\"projectId\":\"repo:test\"},\"needs\":[\"raw\"],\"options\":{\"includeDebug\":true,\"logTrace\":false,\"logAudit\":false}}}",
    );
    defer std.testing.allocator.free(retrieve);
    try std.testing.expect(std.mem.indexOf(u8, retrieve, "Today I rescheduled the dentist appointment.") != null);
    try std.testing.expect(std.mem.indexOf(u8, retrieve, "\"validFrom\":\"2026-02-01T10:00:00Z\"") != null);

    var items = try runtime.collectItems(std.testing.allocator, "dentist appointment", .fts, 10, .{ .project_id = "repo:test" }, false, null, null, .{}, true, false);
    defer items.deinit();
    try std.testing.expectEqual(@as(usize, 1), items.items.items.len);
    const source = items.items.items[0].raw_source orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("assistant", source.role.?);
    try std.testing.expectEqualStrings("2026-02-01T10:00:00Z", source.created_at.?);
    try std.testing.expectEqualStrings("sess-a", source.session_id.?);
    try std.testing.expectEqualStrings("q_sess_1", source.session_qid.?);
    try std.testing.expectEqualStrings("q_turn_2", source.turn_qid.?);
    try std.testing.expectEqualStrings(items.items.items[0].qid, source.message_qid);
    try std.testing.expectEqual(@as(?i64, 1), source.message_index);
    try std.testing.expectEqual(@as(?i64, null), source.chunk_index);
}

test "runtime extracts preference memories with temporal supersession" {
    var harness = try RuntimeTestHarness.init(std.testing.allocator);
    defer harness.deinit();
    var runtime = Runtime.init(harness.adapter(), harness.health());
    defer runtime.deinit();

    const concise = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"r1\",\"method\":\"memory.remember\",\"params\":{\"scope\":{\"userId\":\"user-local\"},\"messages\":[{\"role\":\"user\",\"content\":\"Please be concise in future responses.\",\"createdAt\":\"2026-01-01T10:00:00Z\"}]}}",
    );
    defer std.testing.allocator.free(concise);

    const detailed = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"r2\",\"method\":\"memory.remember\",\"params\":{\"scope\":{\"userId\":\"user-local\"},\"messages\":[{\"role\":\"user\",\"content\":\"I prefer detailed responses now.\",\"createdAt\":\"2026-02-01T10:00:00Z\"}]}}",
    );
    defer std.testing.allocator.free(detailed);

    const current = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"q1\",\"method\":\"memory.retrieve\",\"params\":{\"query\":\"response style\",\"scope\":{\"userId\":\"user-local\"},\"needs\":[\"preferences\"]}}",
    );
    defer std.testing.allocator.free(current);
    try std.testing.expect(std.mem.indexOf(u8, current, "\"preferences\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, current, "The user prefers detailed responses.") != null);
    try std.testing.expect(std.mem.indexOf(u8, current, "The user prefers concise responses.") == null);

    const historical = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"q2\",\"method\":\"memory.retrieve\",\"params\":{\"query\":\"response style\",\"scope\":{\"userId\":\"user-local\"},\"needs\":[\"preferences\"],\"time\":{\"validAt\":\"2026-01-15T10:00:00Z\"}}}",
    );
    defer std.testing.allocator.free(historical);
    try std.testing.expect(std.mem.indexOf(u8, historical, "The user prefers concise responses.") != null);
    try std.testing.expect(std.mem.indexOf(u8, historical, "The user prefers detailed responses.") == null);

    const inspect = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"i1\",\"method\":\"memory.inspect\",\"params\":{\"qid\":\"q_pref_6\",\"includeProvenance\":true}}",
    );
    defer std.testing.allocator.free(inspect);
    try std.testing.expect(std.mem.indexOf(u8, inspect, "\"relation\":\"evidenced_by\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, inspect, "\"qid\":\"q_msg_4\"") != null);
}

test "runtime rejects invalid extractor candidates before writes" {
    var harness = try RuntimeTestHarness.init(std.testing.allocator);
    defer harness.deinit();
    var runtime = Runtime.init(harness.adapter(), harness.health());
    defer runtime.deinit();

    const invalid = extractor.Candidate{
        .label = .fact,
        .slot_key = "user.response_style",
        .value = "concise",
        .text = "The user prefers concise responses.",
    };
    try std.testing.expectError(
        error.InvalidExtractionCandidate,
        runtime.writeExtractedMemory(std.testing.allocator, .{}, "q_msg_missing", "bad candidate", "2026-01-01T10:00:00Z", invalid),
    );

    const search = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"s1\",\"method\":\"memory.search\",\"params\":{\"query\":\"concise\",\"scope\":{}}}",
    );
    defer std.testing.allocator.free(search);
    try std.testing.expect(std.mem.indexOf(u8, search, "The user prefers concise responses.") == null);
}

test "runtime forgetting raw evidence invalidates derived facts" {
    var harness = try RuntimeTestHarness.init(std.testing.allocator);
    defer harness.deinit();
    var runtime = Runtime.init(harness.adapter(), harness.health());
    defer runtime.deinit();

    const remember = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"r1\",\"method\":\"memory.remember\",\"params\":{\"scope\":{\"projectId\":\"repo:test\"},\"messages\":[{\"role\":\"user\",\"content\":\"This repo uses pnpm.\"}]}}",
    );
    defer std.testing.allocator.free(remember);

    const inspect_message = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"i1\",\"method\":\"memory.inspect\",\"params\":{\"qid\":\"q_msg_4\",\"includeDependents\":true}}",
    );
    defer std.testing.allocator.free(inspect_message);
    try std.testing.expect(std.mem.indexOf(u8, inspect_message, "\"relation\":\"derived_from\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, inspect_message, "\"qid\":\"q_fact_6\"") != null);

    const inspect_fact = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"i2\",\"method\":\"memory.inspect\",\"params\":{\"qid\":\"q_fact_6\",\"includeProvenance\":true}}",
    );
    defer std.testing.allocator.free(inspect_fact);
    try std.testing.expect(std.mem.indexOf(u8, inspect_fact, "\"relation\":\"evidenced_by\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, inspect_fact, "\"qid\":\"q_msg_4\"") != null);

    const dry_run = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"f0\",\"method\":\"memory.forget\",\"params\":{\"mode\":\"hard_delete\",\"selector\":{\"qids\":[\"q_msg_4\"]},\"dryRun\":true,\"reason\":\"test\"}}",
    );
    defer std.testing.allocator.free(dry_run);
    try std.testing.expect(std.mem.indexOf(u8, dry_run, "\"status\":\"planned\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, dry_run, "\"nodesDeleted\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, dry_run, "\"factsInvalidated\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, dry_run, "\"action\":\"would_invalidate\"") != null);

    const forget = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"f1\",\"method\":\"memory.forget\",\"params\":{\"mode\":\"hard_delete\",\"selector\":{\"qids\":[\"q_msg_4\"]},\"dryRun\":false,\"reason\":\"test\"}}",
    );
    defer std.testing.allocator.free(forget);
    try std.testing.expect(std.mem.indexOf(u8, forget, "\"factsInvalidated\":1") != null);

    const retrieve = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"q1\",\"method\":\"memory.retrieve\",\"params\":{\"query\":\"package manager\",\"scope\":{\"projectId\":\"repo:test\"}}}",
    );
    defer std.testing.allocator.free(retrieve);
    try std.testing.expect(std.mem.indexOf(u8, retrieve, "The repo uses pnpm as its package manager.") == null);

    const issues = try harness.adapter().verify(std.testing.allocator);
    defer freeVerificationIssues(std.testing.allocator, issues);
    try std.testing.expectEqual(@as(usize, 0), issues.len);
}

test "runtime forget supports redaction state" {
    var harness = try RuntimeTestHarness.init(std.testing.allocator);
    defer harness.deinit();
    var runtime = Runtime.init(harness.adapter(), harness.health());
    defer runtime.deinit();

    const remember = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"r1\",\"method\":\"memory.remember\",\"params\":{\"scope\":{\"projectId\":\"repo:test\"},\"messages\":[{\"role\":\"user\",\"content\":\"Redact this private note.\"}],\"extract\":false}}",
    );
    defer std.testing.allocator.free(remember);

    const forget = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"f1\",\"method\":\"memory.forget\",\"params\":{\"mode\":\"redact\",\"selector\":{\"qids\":[\"q_msg_4\"]},\"dryRun\":false,\"reason\":\"test\"}}",
    );
    defer std.testing.allocator.free(forget);
    try std.testing.expect(std.mem.indexOf(u8, forget, "\"nodesDeleted\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, forget, "\"nodesRedacted\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, forget, "\"action\":\"redacted\"") != null);

    const inspect = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"i1\",\"method\":\"memory.inspect\",\"params\":{\"qid\":\"q_msg_4\"}}",
    );
    defer std.testing.allocator.free(inspect);
    try std.testing.expect(std.mem.indexOf(u8, inspect, "\\\"state\\\":\\\"redacted\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, inspect, "Redact this private note.") == null);

    const issues = try harness.adapter().verify(std.testing.allocator);
    defer freeVerificationIssues(std.testing.allocator, issues);
    try std.testing.expectEqual(@as(usize, 0), issues.len);
}

test "message chunk boundaries reassemble exactly and prefer natural breaks" {
    const allocator = std.testing.allocator;

    const short = "short message";
    const short_ends = try messageChunkEnds(allocator, short);
    defer allocator.free(short_ends);
    try std.testing.expectEqual(@as(usize, 1), short_ends.len);
    try std.testing.expectEqual(short.len, short_ends[0]);

    const exact = "x" ** message_chunk_max_bytes;
    const exact_ends = try messageChunkEnds(allocator, exact);
    defer allocator.free(exact_ends);
    try std.testing.expectEqual(@as(usize, 1), exact_ends.len);

    const Case = struct { content: []const u8, first_end: usize };
    const cases = [_]Case{
        // Paragraph break wins over the later sentence end.
        .{ .content = "a" ** 1000 ++ "\n\n" ++ "b" ** 100 ++ ". " ++ "c" ** 400, .first_end = 1002 },
        // Sentence end wins over later whitespace.
        .{ .content = "a" ** 1100 ++ ". " ++ "b" ** 50 ++ " " ++ "c" ** 400, .first_end = 1102 },
        // Whitespace when there is no sentence or paragraph break.
        .{ .content = "a" ** 1150 ++ " " ++ "b" ** 400, .first_end = 1151 },
        // A break before the boundary window is ignored: hard cut at the limit.
        .{ .content = "a" ** 900 ++ " " ++ "b" ** 900, .first_end = 1200 },
    };
    for (cases) |case| {
        const ends = try messageChunkEnds(allocator, case.content);
        defer allocator.free(ends);
        try std.testing.expect(ends.len >= 2);
        try std.testing.expectEqual(case.first_end, ends[0]);
        try expectChunksReassemble(allocator, case.content, ends);
    }
}

test "message chunk boundaries never split a UTF-8 codepoint" {
    const allocator = std.testing.allocator;
    const contents = [_][]const u8{
        "a" ++ "€" ** 1000, // 3-byte codepoints straddling the limit
        "ab" ++ "😀" ** 800, // 4-byte codepoints straddling the limit
        "é" ** 1500,
    };
    for (contents) |content| {
        const ends = try messageChunkEnds(allocator, content);
        defer allocator.free(ends);
        try std.testing.expect(ends.len >= 2);
        var start: usize = 0;
        for (ends) |end| {
            try std.testing.expect(end - start <= message_chunk_max_bytes);
            try std.testing.expect(std.unicode.utf8ValidateSlice(content[start..end]));
            start = end;
        }
        try expectChunksReassemble(allocator, content, ends);
    }
}

fn expectChunksReassemble(allocator: std.mem.Allocator, content: []const u8, ends: []const usize) !void {
    var rebuilt = std.ArrayList(u8).empty;
    defer rebuilt.deinit(allocator);
    var start: usize = 0;
    for (ends) |end| {
        try std.testing.expect(end > start);
        try rebuilt.appendSlice(allocator, content[start..end]);
        start = end;
    }
    try std.testing.expectEqualStrings(content, rebuilt.items);
}

test "rrf fuses channels by rank after sorting each by score" {
    const allocator = std.testing.allocator;
    // Channels arrive out of score order; fusion must rank by score, not position.
    var lexical = [_]storage.SearchHit{
        .{ .qid = "b", .score = 1.0 },
        .{ .qid = "a", .score = 9.0 },
        .{ .qid = "c", .score = 4.0 },
    };
    var semantic = [_]storage.SearchHit{
        .{ .qid = "c", .score = 0.4 },
        .{ .qid = "a", .score = 0.9 },
    };
    const fused = try fuseRankedHits(allocator, &.{ &lexical, &semantic }, 10);
    defer freeHits(allocator, fused);
    try std.testing.expectEqual(@as(usize, 3), fused.len);
    try std.testing.expectEqualStrings("a", fused[0].qid);
    try std.testing.expectEqualStrings("c", fused[1].qid);
    try std.testing.expectEqualStrings("b", fused[2].qid);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0 / 61.0), fused[0].score, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0 / 62.0), fused[1].score, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0 / 63.0), fused[2].score, 1e-6);

    const top = try fuseRankedHits(allocator, &.{ &lexical, &semantic }, 1);
    defer freeHits(allocator, top);
    try std.testing.expectEqual(@as(usize, 1), top.len);
    try std.testing.expectEqualStrings("a", top[0].qid);
}

test "estimate item tokens uses bytes over 4.2 plus line overhead" {
    try std.testing.expectEqual(@as(usize, 16), estimateItemTokens(.{ .qid = "q", .type = "message", .text = "", .score = 1 }));
    try std.testing.expectEqual(@as(usize, 17), estimateItemTokens(.{ .qid = "q", .type = "message", .text = "abc", .score = 1 }));
    try std.testing.expectEqual(@as(usize, 18), estimateItemTokens(.{ .qid = "q", .type = "message", .text = "abcdefg", .score = 1 }));
    try std.testing.expectEqual(@as(usize, 1016), estimateItemTokens(.{ .qid = "q", .type = "message", .text = "a" ** 4200, .score = 1 }));
}

/// About 3 KB of sentences: "quokka" opens the first chunk and "zanzibar"
/// closes the last one.
fn testLongContent(allocator: std.mem.Allocator) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    try writer.writer.writeAll("The quokka sanctuary visit was lovely. ");
    var index: usize = 0;
    while (index < 60) : (index += 1) {
        try writer.writer.print("Filler sentence number {d} talks about the weather. ", .{index});
    }
    try writer.writer.writeAll("We finally booked the zanzibar ferry for June.");
    return writer.toOwnedSlice();
}

fn rememberLongMessage(runtime: *Runtime, allocator: std.mem.Allocator, content: []const u8) !void {
    const request = try std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":\"r1\",\"method\":\"memory.remember\",\"params\":{{\"scope\":{{\"projectId\":\"repo:test\"}},\"sessionId\":\"sess-long\",\"messages\":[{{\"role\":\"user\",\"content\":\"{s}\",\"createdAt\":\"2026-03-01T10:00:00Z\"}},{{\"role\":\"assistant\",\"content\":\"Noted the short reply.\",\"createdAt\":\"2026-03-01T10:00:05Z\"}}],\"extract\":false}}}}",
        .{content},
    );
    defer allocator.free(request);
    const response = try runtime.dispatch(allocator, request);
    defer allocator.free(response);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"messageQids\":[\"q_msg_4\",\"q_msg_6\"]") != null);
}

fn testChunkCount(store: storage.Adapter, allocator: std.mem.Allocator, message_qid: []const u8) !usize {
    const node = (try store.getNode(allocator, message_qid)) orelse return error.TestUnexpectedResult;
    defer store.freeNode(allocator, node);
    const count = (try readOptionalPropertyInt(allocator, node.properties_json, "chunkCount")) orelse return error.TestUnexpectedResult;
    return @intCast(count);
}

test "runtime chunks long messages and maps chunk hits to the parent message" {
    const allocator = std.testing.allocator;
    var harness = try RuntimeTestHarness.init(allocator);
    defer harness.deinit();
    const store = harness.adapter();
    var runtime = Runtime.init(store, harness.health());
    defer runtime.deinit();

    const content = try testLongContent(allocator);
    defer allocator.free(content);
    try rememberLongMessage(&runtime, allocator, content);

    const message = (try store.getNode(allocator, "q_msg_4")) orelse return error.TestUnexpectedResult;
    defer store.freeNode(allocator, message);
    try std.testing.expect(try propertyIsFalse(allocator, message.properties_json, "searchable"));
    try std.testing.expect(try propertyEquals(allocator, message.properties_json, "sessionId", "sess-long"));
    try std.testing.expectEqual(@as(?i64, 0), try readOptionalPropertyInt(allocator, message.properties_json, "messageIndex"));
    const short = (try store.getNode(allocator, "q_msg_6")) orelse return error.TestUnexpectedResult;
    defer store.freeNode(allocator, short);
    try std.testing.expect(!try propertyIsFalse(allocator, short.properties_json, "searchable"));
    try std.testing.expectEqual(@as(?i64, 1), try readOptionalPropertyInt(allocator, short.properties_json, "messageIndex"));

    // Chunks hold the full raw text, linked both ways to the message.
    const chunk_count = try testChunkCount(store, allocator, "q_msg_4");
    try std.testing.expectEqual(@as(usize, 3), chunk_count);
    var rebuilt = std.ArrayList(u8).empty;
    defer rebuilt.deinit(allocator);
    for (0..chunk_count) |index| {
        const qid = try chunkQid(allocator, "q_msg_4", index);
        defer allocator.free(qid);
        const chunk = (try store.getNode(allocator, qid)) orelse return error.TestUnexpectedResult;
        defer store.freeNode(allocator, chunk);
        try std.testing.expectEqualStrings("Chunk", chunk.label);
        try std.testing.expect(try propertyEquals(allocator, chunk.properties_json, "messageQid", "q_msg_4"));
        try std.testing.expect(try propertyEquals(allocator, chunk.properties_json, "turnQid", "q_turn_2"));
        const text = try readPropertyString(allocator, chunk.properties_json, "content");
        defer allocator.free(text);
        try rebuilt.appendSlice(allocator, text);
    }
    try std.testing.expectEqualStrings(content, rebuilt.items);
    const has_chunk = try store.findEdges(allocator, .{ .from_qid = "q_msg_4", .edge_type = "HAS_CHUNK" });
    defer store.freeEdges(allocator, has_chunk);
    try std.testing.expectEqual(chunk_count, has_chunk.len);
    const evidenced_by = try store.findEdges(allocator, .{ .to_qid = "q_msg_4", .edge_type = "EVIDENCED_BY" });
    defer store.freeEdges(allocator, evidenced_by);
    try std.testing.expectEqual(chunk_count, evidenced_by.len);

    // A hit in the last chunk is a raw message item whose evidence is the parent.
    const search = try runtime.dispatch(
        allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"s1\",\"method\":\"memory.search\",\"params\":{\"query\":\"zanzibar ferry\",\"scope\":{\"projectId\":\"repo:test\"}}}",
    );
    defer allocator.free(search);
    try std.testing.expect(std.mem.indexOf(u8, search, "\"qid\":\"q_chunk_4_2\",\"type\":\"message\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, search, "\"evidence\":[{\"qid\":\"q_msg_4\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, search, "\"qid\":\"q_msg_4\",\"type\"") == null);

    var items = try runtime.collectItems(allocator, "zanzibar ferry", .fts, 10, .{ .project_id = "repo:test" }, false, null, null, .{}, true, false);
    defer items.deinit();
    try std.testing.expectEqual(@as(usize, 1), items.items.items.len);
    const source = items.items.items[0].raw_source orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("q_msg_4", source.message_qid);
    try std.testing.expectEqual(@as(?i64, 2), source.chunk_index);
    try std.testing.expectEqual(@as(?i64, 3), source.chunk_count);
    try std.testing.expectEqual(@as(?i64, 0), source.message_index);
    try std.testing.expectEqualStrings("user", source.role.?);
    try std.testing.expectEqualStrings("sess-long", source.session_id.?);

    // Session and Turn containers never surface as items.
    const retrieve = try runtime.dispatch(
        allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"q1\",\"method\":\"memory.retrieve\",\"params\":{\"query\":\"quokka sanctuary short reply\",\"scope\":{\"projectId\":\"repo:test\"},\"options\":{\"logRetrieval\":false,\"logAudit\":false}}}",
    );
    defer allocator.free(retrieve);
    try std.testing.expect(std.mem.indexOf(u8, retrieve, "\"qid\":\"q_chunk_4_0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, retrieve, "Noted the short reply.") != null);
    try std.testing.expect(std.mem.indexOf(u8, retrieve, "\"text\":\"Session\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, retrieve, "\"text\":\"Turn\"") == null);

    // Graph expansion through an entity mentioned by a chunked message lands on its chunks.
    const entity = providers.ResolvedEntity{ .name = "Quokka Sanctuary", .entity_type = "place", .aliases = &.{} };
    try runtime.writeEntityMentions(allocator, .{ .project_id = "repo:test" }, "q_msg_4", &[_]providers.ResolvedEntity{entity});
    var graph_items = try runtime.collectItems(allocator, "Quokka Sanctuary", .graph, 10, .{ .project_id = "repo:test" }, false, null, null, .{}, true, false);
    defer graph_items.deinit();
    var graph_chunks: usize = 0;
    for (graph_items.items.items) |item| {
        try std.testing.expect(!std.mem.eql(u8, item.qid, "q_msg_4"));
        if (std.mem.startsWith(u8, item.qid, "q_chunk_4_")) graph_chunks += 1;
    }
    try std.testing.expectEqual(chunk_count, graph_chunks);
}

test "runtime retrieve sorts lexical candidates by BM25 score" {
    var harness = try RuntimeTestHarness.init(std.testing.allocator);
    defer harness.deinit();
    var runtime = Runtime.init(harness.adapter(), harness.health());
    defer runtime.deinit();

    const remember = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"r1\",\"method\":\"memory.remember\",\"params\":{\"scope\":{\"projectId\":\"repo:rank\"},\"messages\":[{\"role\":\"user\",\"content\":\"I baked an apple pie with grandma on Sunday.\"},{\"role\":\"user\",\"content\":\"The apple tart was too sweet.\"},{\"role\":\"user\",\"content\":\"A zebra apple is a rare heirloom variety.\"}],\"extract\":false}}",
    );
    defer std.testing.allocator.free(remember);

    var items = try runtime.collectItems(std.testing.allocator, "zebra apple", .fts, 10, .{ .project_id = "repo:rank" }, false, null, null, .{}, true, false);
    defer items.deinit();
    try std.testing.expectEqual(@as(usize, 3), items.items.items.len);
    try std.testing.expectEqualStrings("A zebra apple is a rare heirloom variety.", items.items.items[0].text);
    for (items.items.items[1..], 1..) |item, index| {
        try std.testing.expect(item.score <= items.items.items[index - 1].score);
    }
}

test "runtime raw evidence competes with derived memory and only stale evidence is dropped" {
    var harness = try RuntimeTestHarness.init(std.testing.allocator);
    defer harness.deinit();
    var runtime = Runtime.init(harness.adapter(), harness.health());
    defer runtime.deinit();

    const requests = [_][]const u8{
        "{\"jsonrpc\":\"2.0\",\"id\":\"r1\",\"method\":\"memory.remember\",\"params\":{\"scope\":{\"projectId\":\"repo:test\"},\"messages\":[{\"role\":\"user\",\"content\":\"This repo uses npm.\",\"createdAt\":\"2026-01-01T10:00:00Z\"}]}}",
        "{\"jsonrpc\":\"2.0\",\"id\":\"r2\",\"method\":\"memory.remember\",\"params\":{\"scope\":{\"projectId\":\"repo:test\"},\"messages\":[{\"role\":\"user\",\"content\":\"We migrated this repo to pnpm. Use pnpm now.\",\"createdAt\":\"2026-02-01T10:00:00Z\"}]}}",
        "{\"jsonrpc\":\"2.0\",\"id\":\"r3\",\"method\":\"memory.remember\",\"params\":{\"scope\":{\"projectId\":\"repo:test\"},\"messages\":[{\"role\":\"user\",\"content\":\"My cat is named Biscuit.\",\"createdAt\":\"2026-02-02T10:00:00Z\"}]}}",
    };
    for (requests) |request| {
        const response = try runtime.dispatch(std.testing.allocator, request);
        std.testing.allocator.free(response);
    }

    // Raw evidence stays next to the current fact; the superseded npm
    // evidence is dropped because the current slot version is present.
    const current = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"q1\",\"method\":\"memory.retrieve\",\"params\":{\"query\":\"Which package manager does this repo use: npm or pnpm?\",\"scope\":{\"projectId\":\"repo:test\"},\"options\":{\"logRetrieval\":false,\"logAudit\":false}}}",
    );
    defer std.testing.allocator.free(current);
    try std.testing.expect(std.mem.indexOf(u8, current, "The repo uses pnpm as its package manager.") != null);
    try std.testing.expect(std.mem.indexOf(u8, current, "We migrated this repo to pnpm. Use pnpm now.") != null);
    try std.testing.expect(std.mem.indexOf(u8, current, "This repo uses npm.") == null);
    try std.testing.expect(std.mem.indexOf(u8, current, "\"type\":\"memory_card\"") == null);

    // An unrelated derived item no longer suppresses raw evidence.
    const unrelated = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"q2\",\"method\":\"memory.retrieve\",\"params\":{\"query\":\"package manager cat Biscuit\",\"scope\":{\"projectId\":\"repo:test\"},\"options\":{\"logRetrieval\":false,\"logAudit\":false}}}",
    );
    defer std.testing.allocator.free(unrelated);
    try std.testing.expect(std.mem.indexOf(u8, unrelated, "The repo uses pnpm as its package manager.") != null);
    try std.testing.expect(std.mem.indexOf(u8, unrelated, "My cat is named Biscuit.") != null);

    // At a time when npm was current, its evidence is not stale.
    const historical = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"q3\",\"method\":\"memory.retrieve\",\"params\":{\"query\":\"Which package manager does this repo use: npm or pnpm?\",\"scope\":{\"projectId\":\"repo:test\"},\"time\":{\"validAt\":\"2026-01-15T10:00:00Z\"},\"options\":{\"logRetrieval\":false,\"logAudit\":false}}}",
    );
    defer std.testing.allocator.free(historical);
    try std.testing.expect(std.mem.indexOf(u8, historical, "The repo uses npm as its package manager.") != null);
    try std.testing.expect(std.mem.indexOf(u8, historical, "This repo uses npm.") != null);
    try std.testing.expect(std.mem.indexOf(u8, historical, "pnpm") == null);
}

test "runtime retrieve defaults to a 4096 token budget" {
    var harness = try RuntimeTestHarness.init(std.testing.allocator);
    defer harness.deinit();
    var runtime = Runtime.init(harness.adapter(), harness.health());
    defer runtime.deinit();

    const remember = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"r1\",\"method\":\"memory.remember\",\"params\":{\"messages\":[{\"role\":\"user\",\"content\":\"Budget marker note.\"}],\"extract\":false}}",
    );
    defer std.testing.allocator.free(remember);
    const retrieve = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"q1\",\"method\":\"memory.retrieve\",\"params\":{\"query\":\"budget marker\",\"options\":{\"includeDebug\":true,\"logRetrieval\":false,\"logAudit\":false}}}",
    );
    defer std.testing.allocator.free(retrieve);
    try std.testing.expect(std.mem.indexOf(u8, retrieve, "\"budgetTokens\":4096") != null);
    try std.testing.expect(std.mem.indexOf(u8, retrieve, "Budget marker note.") != null);
}

const forgotten_sentence = "We finally booked the zanzibar ferry for June.";

fn expectLongMessageForgotten(runtime: *Runtime, store: storage.Adapter, allocator: std.mem.Allocator, chunk_count: usize) !void {
    for (0..chunk_count) |index| {
        const qid = try chunkQid(allocator, "q_msg_4", index);
        defer allocator.free(qid);
        const chunk = (try store.getNode(allocator, qid)) orelse return error.TestUnexpectedResult;
        defer store.freeNode(allocator, chunk);
        try std.testing.expect(try propertyBool(allocator, chunk.properties_json, "deleted"));
        try std.testing.expect(std.mem.indexOf(u8, chunk.properties_json, "content") == null);
    }
    const message = (try store.getNode(allocator, "q_msg_4")) orelse return error.TestUnexpectedResult;
    defer store.freeNode(allocator, message);
    try std.testing.expect(try propertyBool(allocator, message.properties_json, "deleted"));

    const requests = [_][]const u8{
        "{\"jsonrpc\":\"2.0\",\"id\":\"s1\",\"method\":\"memory.search\",\"params\":{\"query\":\"zanzibar ferry quokka\",\"scope\":{\"projectId\":\"repo:test\"}}}",
        "{\"jsonrpc\":\"2.0\",\"id\":\"q1\",\"method\":\"memory.retrieve\",\"params\":{\"query\":\"zanzibar ferry quokka\",\"scope\":{\"projectId\":\"repo:test\"},\"options\":{\"logRetrieval\":false,\"logAudit\":false}}}",
        "{\"jsonrpc\":\"2.0\",\"id\":\"q2\",\"method\":\"memory.retrieve\",\"params\":{\"query\":\"zanzibar ferry quokka\",\"scope\":{\"projectId\":\"repo:test\"},\"needs\":[\"raw\"],\"mode\":\"graph\",\"options\":{\"logRetrieval\":false,\"logAudit\":false}}}",
        "{\"jsonrpc\":\"2.0\",\"id\":\"a1\",\"method\":\"memory.answer\",\"params\":{\"query\":\"When is the zanzibar ferry booked?\",\"scope\":{\"projectId\":\"repo:test\"},\"options\":{\"logRetrieval\":false}}}",
    };
    for (requests) |request| {
        const response = try runtime.dispatch(allocator, request);
        defer allocator.free(response);
        try std.testing.expect(std.mem.indexOf(u8, response, "\"error\"") == null);
        try std.testing.expect(std.mem.indexOf(u8, response, forgotten_sentence) == null);
        try std.testing.expect(std.mem.indexOf(u8, response, "quokka sanctuary") == null);
        try std.testing.expect(std.mem.indexOf(u8, response, "Filler sentence") == null);
    }
}

test "runtime forgetting a message by qid forgets all of its chunks" {
    const allocator = std.testing.allocator;
    var harness = try RuntimeTestHarness.init(allocator);
    defer harness.deinit();
    const store = harness.adapter();
    var runtime = Runtime.init(store, harness.health());
    defer runtime.deinit();

    const content = try testLongContent(allocator);
    defer allocator.free(content);
    try rememberLongMessage(&runtime, allocator, content);
    const chunk_count = try testChunkCount(store, allocator, "q_msg_4");

    const dry_run = try runtime.dispatch(
        allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"f0\",\"method\":\"memory.forget\",\"params\":{\"mode\":\"hard_delete\",\"selector\":{\"qids\":[\"q_msg_4\"]},\"dryRun\":true,\"reason\":\"test\"}}",
    );
    defer allocator.free(dry_run);
    try std.testing.expect(std.mem.indexOf(u8, dry_run, "{\"qid\":\"q_chunk_4_2\",\"type\":\"chunk\",\"action\":\"would_delete\"}") != null);

    const forget = try runtime.dispatch(
        allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"f1\",\"method\":\"memory.forget\",\"params\":{\"mode\":\"hard_delete\",\"selector\":{\"qids\":[\"q_msg_4\"]},\"dryRun\":false,\"reason\":\"test\"}}",
    );
    defer allocator.free(forget);
    try std.testing.expect(std.mem.indexOf(u8, forget, "\"rootsMatched\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, forget, "\"nodesDeleted\":4") != null);
    try std.testing.expect(std.mem.indexOf(u8, forget, "{\"qid\":\"q_chunk_4_0\",\"type\":\"chunk\",\"action\":\"deleted\"}") != null);
    try expectLongMessageForgotten(&runtime, store, allocator, chunk_count);

    // The sibling message in the same turn is untouched.
    const sibling = try runtime.dispatch(
        allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"s2\",\"method\":\"memory.search\",\"params\":{\"query\":\"short reply\",\"scope\":{\"projectId\":\"repo:test\"}}}",
    );
    defer allocator.free(sibling);
    try std.testing.expect(std.mem.indexOf(u8, sibling, "Noted the short reply.") != null);

    const issues = try store.verify(allocator);
    defer freeVerificationIssues(allocator, issues);
    try std.testing.expectEqual(@as(usize, 0), issues.len);
}

test "runtime forget query hitting a chunk forgets the whole parent message" {
    const allocator = std.testing.allocator;
    var harness = try RuntimeTestHarness.init(allocator);
    defer harness.deinit();
    const store = harness.adapter();
    var runtime = Runtime.init(store, harness.health());
    defer runtime.deinit();

    const content = try testLongContent(allocator);
    defer allocator.free(content);
    try rememberLongMessage(&runtime, allocator, content);
    const chunk_count = try testChunkCount(store, allocator, "q_msg_4");

    const forget = try runtime.dispatch(
        allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"f1\",\"method\":\"memory.forget\",\"params\":{\"mode\":\"redact\",\"selector\":{\"query\":\"zanzibar ferry\",\"scope\":{\"projectId\":\"repo:test\"}},\"dryRun\":false,\"reason\":\"test\"}}",
    );
    defer allocator.free(forget);
    try std.testing.expect(std.mem.indexOf(u8, forget, "\"rootsMatched\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, forget, "\"nodesRedacted\":4") != null);
    try std.testing.expect(std.mem.indexOf(u8, forget, "{\"qid\":\"q_msg_4\",\"type\":\"message\",\"action\":\"redacted\"}") != null);
    try expectLongMessageForgotten(&runtime, store, allocator, chunk_count);
}

test "runtime forgetting a session forgets its messages and their chunks" {
    const allocator = std.testing.allocator;
    var harness = try RuntimeTestHarness.init(allocator);
    defer harness.deinit();
    const store = harness.adapter();
    var runtime = Runtime.init(store, harness.health());
    defer runtime.deinit();

    const content = try testLongContent(allocator);
    defer allocator.free(content);
    try rememberLongMessage(&runtime, allocator, content);
    const chunk_count = try testChunkCount(store, allocator, "q_msg_4");

    const forget = try runtime.dispatch(
        allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"f1\",\"method\":\"memory.forget\",\"params\":{\"mode\":\"hard_delete\",\"selector\":{\"qids\":[\"q_sess_1\"]},\"dryRun\":false,\"reason\":\"test\"}}",
    );
    defer allocator.free(forget);
    try std.testing.expect(std.mem.indexOf(u8, forget, "\"rootsMatched\":3") != null);
    try expectLongMessageForgotten(&runtime, store, allocator, chunk_count);

    const sibling = try runtime.dispatch(
        allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"s2\",\"method\":\"memory.search\",\"params\":{\"query\":\"short reply\",\"scope\":{\"projectId\":\"repo:test\"}}}",
    );
    defer allocator.free(sibling);
    try std.testing.expect(std.mem.indexOf(u8, sibling, "Noted the short reply.") == null);
}

fn freeVerificationIssues(allocator: std.mem.Allocator, issues: []const storage.VerificationIssue) void {
    for (issues) |issue| {
        if (issue.qid) |qid| allocator.free(qid);
    }
    allocator.free(issues);
}
