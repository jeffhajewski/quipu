const std = @import("std");
const answer_synthesis = @import("answer_synthesis.zig");
const build_options = @import("build_options");
const extractor = @import("extractor.zig");
const in_memory_storage = if (build_options.enable_lattice) struct {} else @import("in_memory_storage.zig");
const jobs = @import("jobs.zig");
const lattice_storage = if (build_options.enable_lattice) @import("lattice_storage.zig") else struct {};
const protocol = @import("protocol.zig");
const providers = @import("providers.zig");
const schema = @import("schema.zig");
const storage = @import("storage.zig");
const streams = @import("streams.zig");

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
const property_text_max_bytes = 4096;
const property_truncation_marker = "…";

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

const CachedRawMessage = struct {
    qid: []const u8,
    properties_json: []const u8,
    text: []const u8,
    tokens: []const []const u8,
    deleted: bool = false,
};

const RawMessageCache = struct {
    allocator: ?std.mem.Allocator = null,
    complete: bool = false,
    items: std.ArrayList(CachedRawMessage) = .empty,

    fn append(self: *RawMessageCache, allocator: std.mem.Allocator, qid: []const u8, properties_json: []const u8, text: []const u8) !void {
        if (self.indexOf(qid)) |index| {
            self.items.items[index].deleted = false;
            return;
        }
        if (self.allocator == null) self.allocator = allocator;
        const owned_qid = try allocator.dupe(u8, qid);
        errdefer allocator.free(owned_qid);
        const owned_properties = try allocator.dupe(u8, properties_json);
        errdefer allocator.free(owned_properties);
        const owned_text = try rawMessageText(allocator, text, properties_json);
        errdefer allocator.free(owned_text);
        const owned_tokens = try normalizedTokens(allocator, owned_text);
        errdefer freeStringList(allocator, owned_tokens);
        try self.items.append(allocator, .{
            .qid = owned_qid,
            .properties_json = owned_properties,
            .text = owned_text,
            .tokens = owned_tokens,
        });
    }

    fn appendNode(self: *RawMessageCache, allocator: std.mem.Allocator, node: storage.Node) !void {
        const text = try textForNode(allocator, node);
        defer allocator.free(text);
        try self.append(allocator, node.qid, node.properties_json, text);
    }

    fn markDeleted(self: *RawMessageCache, qid: []const u8) void {
        if (self.indexOf(qid)) |index| {
            self.items.items[index].deleted = true;
        }
    }

    fn indexOf(self: *const RawMessageCache, qid: []const u8) ?usize {
        for (self.items.items, 0..) |item, index| {
            if (std.mem.eql(u8, item.qid, qid)) return index;
        }
        return null;
    }

    fn deinit(self: *RawMessageCache) void {
        const allocator = self.allocator orelse return;
        for (self.items.items) |item| {
            allocator.free(item.qid);
            allocator.free(item.properties_json);
            allocator.free(item.text);
            freeStringList(allocator, item.tokens);
        }
        self.items.deinit(allocator);
        self.* = .{};
    }
};

pub const RuntimeOptions = struct {
    io: ?std.Io = null,
    answer_provider: providers.ProviderEndpoint = .{},
    entity_provider: providers.ProviderEndpoint = .{},
};

pub const Runtime = struct {
    store: storage.Adapter,
    health: protocol.Health,
    options: RuntimeOptions = .{},
    next_id: u64 = 1,
    raw_messages: RawMessageCache = .{},
    raw_cache_complete_from_remember: bool = true,

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
            .raw_cache_complete_from_remember = next_id <= 1,
        };
    }

    pub fn initWithNextIdAndOptions(store: storage.Adapter, health: protocol.Health, next_id: u64, options: RuntimeOptions) Runtime {
        return .{
            .store = store,
            .health = health,
            .options = options,
            .next_id = @max(next_id, 1),
            .raw_cache_complete_from_remember = next_id <= 1,
        };
    }

    pub fn deinit(self: *Runtime) void {
        self.raw_messages.deinit();
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

        for (messages.items) |message_value| {
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

            const content_for_props = try clampPropertyText(allocator, content);
            defer allocator.free(content_for_props);
            const message_props = try stringifyAlloc(allocator, .{
                .kind = "message",
                .role = role,
                .content = content_for_props,
                .createdAt = stringField(&message, "createdAt"),
                .tenantId = scope.tenant_id,
                .userId = scope.user_id,
                .agentId = scope.agent_id,
                .projectId = scope.project_id,
                .privacyClass = stringField(params, "privacyClass") orelse "normal",
                .deleted = false,
            });
            defer allocator.free(message_props);
            try self.store.putNode(.{ .qid = message_qid, .label = "Message", .properties_json = message_props });
            try self.raw_messages.append(allocator, message_qid, message_props, content);
            if (self.raw_cache_complete_from_remember) {
                self.raw_messages.complete = true;
            }
            try self.putEdge(allocator, turn_qid, message_qid, "HAS_MESSAGE");
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
        const budget = integerField(params, "budgetTokens") orelse 1200;
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
        const retrieve_mode = parseRetrieveMode(stringField(params, "mode"), self.store.capabilities()) orelse {
            return errorResponse(allocator, id, "invalid_request", "mode must be fts, vector, hybrid, or graph");
        };

        const raw_only = needsCount(needs_value) == 1 and needsIncludes(needs_value, "raw");
        var results = if (raw_only and retrieve_mode == .fts)
            try self.collectRawLexicalItems(allocator, query, 40, scope, valid_at, event_window, include_evidence, include_trace)
        else
            try self.collectItems(allocator, query, retrieve_mode, 40, scope, false, null, valid_at, event_window, include_evidence, include_trace);
        defer results.deinit();
        if (needsIncludes(needs_value, "core")) {
            try self.appendCoreItems(allocator, &results, scope, include_evidence, include_trace);
        }
        const candidate_count = results.items.items.len;
        const dropped_for_needs = results.filterByNeeds(needs_value);
        if (!needsIncludes(needs_value, "raw")) {
            results.suppressRawIfDerived(needs_value);
        }
        const dropped_for_budget = results.applyTokenBudget(@intCast(budget));

        var warnings = std.ArrayList([]const u8).empty;
        defer warnings.deinit(allocator);
        if (dropped_for_budget > 0) {
            try warnings.append(allocator, "token_budget_truncated");
        }
        if (results.items.items.len == 0) {
            try warnings.append(allocator, "no_memory_items");
        }
        try appendRetrievalWarnings(allocator, &warnings, results.items.items, include_evidence);

        var context = try OwnedContextPacket.fromItems(allocator, results.items.items, warnings.items);
        defer context.deinit();

        const retrieval_id = try self.nextQid(allocator, "retr");
        defer allocator.free(retrieval_id);
        const prompt = try promptFromContext(allocator, self.store, context.view(), .{ .current_date = valid_at });
        defer allocator.free(prompt);
        const token_estimate = @max(@as(usize, 1), prompt.len / 4);
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
        const budget = integerField(params, "budgetTokens") orelse 1200;
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
        const log_retrieval = if (options) |opts| boolField(&opts, "logRetrieval") orelse (boolField(&opts, "logTrace") orelse true) else true;
        const retrieve_mode = parseRetrieveMode(stringField(params, "mode"), self.store.capabilities()) orelse {
            return errorResponse(allocator, id, "invalid_request", "mode must be fts, vector, hybrid, or graph");
        };

        const raw_only = needsCount(needs_value) == 1 and needsIncludes(needs_value, "raw");
        var results = if (raw_only and retrieve_mode == .fts)
            try self.collectRawLexicalItems(allocator, query, 40, scope, valid_at, event_window, include_evidence, include_trace)
        else
            try self.collectItems(allocator, query, retrieve_mode, 40, scope, false, null, valid_at, event_window, include_evidence, include_trace);
        defer results.deinit();
        if (needsIncludes(needs_value, "core")) {
            try self.appendCoreItems(allocator, &results, scope, include_evidence, include_trace);
        }
        const candidate_count = results.items.items.len;
        const dropped_for_needs = results.filterByNeeds(needs_value);
        if (!needsIncludes(needs_value, "raw")) {
            results.suppressRawIfDerived(needs_value);
        }
        const dropped_for_budget = results.applyTokenBudget(@intCast(budget));

        var warnings = std.ArrayList([]const u8).empty;
        defer warnings.deinit(allocator);
        if (dropped_for_budget > 0) try warnings.append(allocator, "token_budget_truncated");
        if (results.items.items.len == 0) try warnings.append(allocator, "no_memory_items");

        try appendRetrievalWarnings(allocator, &warnings, results.items.items, include_evidence);

        // Reserve room for answer warnings so the context packet's view of
        // `warnings.items` is never invalidated by a later append.
        try warnings.ensureUnusedCapacity(allocator, 8);
        var context = try OwnedContextPacket.fromItems(allocator, results.items.items, warnings.items);
        defer context.deinit();

        const retrieval_id = try self.nextQid(allocator, "retr");
        defer allocator.free(retrieval_id);
        // The question date travels in the reader's user turn, not inside the
        // untrusted memory block.
        const prompt = try promptFromContext(allocator, self.store, context.view(), .{});
        defer allocator.free(prompt);
        const token_estimate = @max(@as(usize, 1), prompt.len / 4);
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
        });
        defer synthesized.deinit();
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

            if (propagate) {
                var dependents = try self.derivedRefsByEvidence(allocator, qid);
                defer dependents.deinit();
                for (dependents.items.items) |dependent| {
                    if (isFactLikeType(dependent.type)) facts_invalidated += 1;
                }
                for (dependents.items.items) |dependent| {
                    try report.append(allocator, dependent.qid, dependent.type, dependent_action);
                }

                try self.appendCoreClosureRefs(allocator, qid, &contaminated_core_qids, &report, core_action);
                for (dependents.items.items) |dependent| {
                    try self.appendCoreClosureRefs(allocator, dependent.qid, &contaminated_core_qids, &report, core_action);
                }
            }

            if (!dry_run) {
                try self.tombstoneNode(allocator, qid, node.label, reason, mode);
                if (std.mem.eql(u8, node.label, "Message")) {
                    self.raw_messages.markDeleted(qid);
                }
                if (std.mem.eql(u8, mode, "redact")) {
                    nodes_redacted += 1;
                } else {
                    nodes_deleted += 1;
                }
                if (propagate) _ = try self.tombstoneDerivedByEvidence(allocator, qid, reason, "hard_delete");
            }
        }
        summaries_contaminated = contaminated_core_qids.items.items.len;
        if (!dry_run and propagate) {
            for (contaminated_core_qids.items.items) |core_qid| {
                const core_node = (try self.store.getNode(allocator, core_qid)) orelse continue;
                defer self.store.freeNode(allocator, core_node);
                try self.tombstoneNode(allocator, core_qid, core_node.label, reason, mode);
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
                const node = (try self.store.getNode(allocator, qid)) orelse continue;
                defer self.store.freeNode(allocator, node);
                if (try propertyBool(allocator, node.properties_json, "deleted")) continue;
                if (!try scope.matchesNode(allocator, node)) continue;
                if (!try nodeWithinEventWindow(allocator, node, window)) continue;
                try selected_qids.appendUnique(allocator, qid);
            }
        }

        const query = stringField(selector, "query") orelse return;
        if (query.len == 0) return;
        const hits = try self.store.fullTextSearch(allocator, .{ .text = query, .limit = 1000 });
        defer freeHits(allocator, hits);
        for (hits) |hit| {
            const node = (try self.store.getNode(allocator, hit.qid)) orelse continue;
            defer self.store.freeNode(allocator, node);
            if (isInternalLabel(node.label)) continue;
            if (try propertyBool(allocator, node.properties_json, "deleted")) continue;
            if (!try scope.matchesNode(allocator, node)) continue;
            if (!try nodeWithinEventWindow(allocator, node, window)) continue;
            try selected_qids.appendUnique(allocator, node.qid);
        }
    }

    fn appendCoreClosureRefs(
        self: *Runtime,
        allocator: std.mem.Allocator,
        source_qid: []const u8,
        contaminated_core_qids: *OwnedQids,
        report: *OwnedForgetReport,
        action: []const u8,
    ) !void {
        const hits = try self.store.fullTextSearch(allocator, .{ .text = "", .limit = 1000 });
        defer freeHits(allocator, hits);
        for (hits) |hit| {
            const node = (try self.store.getNode(allocator, hit.qid)) orelse continue;
            defer self.store.freeNode(allocator, node);
            if (!std.mem.eql(u8, node.label, "Core")) continue;
            if (try propertyBool(allocator, node.properties_json, "deleted")) continue;
            if (!try propertyStringArrayContains(allocator, node.properties_json, "evidenceQids", source_qid)) continue;
            const already_seen = contaminated_core_qids.contains(node.qid);
            try contaminated_core_qids.appendUnique(allocator, node.qid);
            if (!already_seen) {
                try report.append(allocator, node.qid, "core", action);
            }
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
        const hits = try self.store.fullTextSearch(allocator, .{ .text = "", .limit = 1000 });
        defer freeHits(allocator, hits);

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

        for (hits) |hit| {
            const node = (try self.store.getNode(allocator, hit.qid)) orelse continue;
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

        const hits = try self.store.fullTextSearch(allocator, .{ .text = "", .limit = 1000 });
        defer freeHits(allocator, hits);
        for (hits) |hit| {
            if (evidence_qids.items.len >= limit) break;
            const node = (try self.store.getNode(allocator, hit.qid)) orelse continue;
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

    fn auditEventsForQid(self: *Runtime, allocator: std.mem.Allocator, qid: []const u8) !OwnedAuditEvents {
        const entries = try self.store.readStream(allocator, streams.audit, 0, 1000);
        defer freeStreamEntries(allocator, entries);

        var audit = OwnedAuditEvents{ .allocator = allocator };
        errdefer audit.deinit();
        for (entries) |entry| {
            if (std.mem.indexOf(u8, entry.payload_json, qid) == null) continue;
            try audit.append(allocator, entry.stream, entry.sequence, entry.payload_json);
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

    fn relatedCardQidsForCandidate(
        self: *Runtime,
        allocator: std.mem.Allocator,
        scope: Scope,
        card_qid: []const u8,
        candidate: extractor.Candidate,
    ) ![]const []const u8 {
        const hits = try self.store.fullTextSearch(allocator, .{ .text = "", .limit = 1000 });
        defer freeHits(allocator, hits);
        var related = std.ArrayList([]const u8).empty;
        errdefer {
            for (related.items) |qid| allocator.free(qid);
            related.deinit(allocator);
        }
        for (hits) |hit| {
            if (related.items.len >= 8) break;
            if (std.mem.eql(u8, hit.qid, card_qid)) continue;
            const node = (try self.store.getNode(allocator, hit.qid)) orelse continue;
            defer self.store.freeNode(allocator, node);
            if (!std.mem.eql(u8, node.label, "MemoryCard")) continue;
            if (try propertyBool(allocator, node.properties_json, "deleted")) continue;
            if (!try scope.matchesNode(allocator, node)) continue;
            const same_slot = try propertyEquals(allocator, node.properties_json, "slotKey", candidate.slot_key);
            const same_kind = try propertyEquals(allocator, node.properties_json, "cardKind", memoryCardKind(candidate.label));
            if (!same_slot and !same_kind) continue;
            try related.append(allocator, try allocator.dupe(u8, node.qid));
        }
        return related.toOwnedSlice(allocator);
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
        const episode_summary = if (summary.len > 1024) summary[0..1024] else summary;
        const props = try stringifyAlloc(allocator, .{
            .kind = "episode",
            .qtype = "episode",
            .episodeType = "conversation",
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

    fn supersedeCurrentSlot(self: *Runtime, allocator: std.mem.Allocator, scope: Scope, slot_key: []const u8, valid_to: ?[]const u8) !void {
        const hits = try self.store.fullTextSearch(allocator, .{ .text = "", .limit = 1000 });
        defer freeHits(allocator, hits);

        for (hits) |hit| {
            const node = (try self.store.getNode(allocator, hit.qid)) orelse continue;
            defer self.store.freeNode(allocator, node);
            if (!isSlotMemoryLabel(node.label)) continue;
            if (!try scope.matchesNode(allocator, node)) continue;
            if (try propertyBool(allocator, node.properties_json, "deleted")) continue;
            if (!try propertyEquals(allocator, node.properties_json, "slotKey", slot_key)) continue;
            if (!try propertyEquals(allocator, node.properties_json, "state", "current")) continue;
            try self.rewriteDerivedState(allocator, node, "superseded", valid_to);
        }
    }

    fn rewriteDerivedState(
        self: *Runtime,
        allocator: std.mem.Allocator,
        node: storage.Node,
        state: []const u8,
        valid_to: ?[]const u8,
    ) !void {
        const text = try readPropertyString(allocator, node.properties_json, "text");
        defer allocator.free(text);
        const slot_key = try readPropertyString(allocator, node.properties_json, "slotKey");
        defer allocator.free(slot_key);
        const subject = try readOptionalPropertyString(allocator, node.properties_json, "subject");
        defer if (subject) |value_to_free| allocator.free(value_to_free);
        const attribute = try readOptionalPropertyString(allocator, node.properties_json, "attribute");
        defer if (attribute) |value_to_free| allocator.free(value_to_free);
        const value = try readPropertyString(allocator, node.properties_json, "value");
        defer allocator.free(value);
        const numeric_value = try readOptionalPropertyInt(allocator, node.properties_json, "numericValue");
        const unit = try readOptionalPropertyString(allocator, node.properties_json, "unit");
        defer if (unit) |value_to_free| allocator.free(value_to_free);
        const aggregation_mode = try readOptionalPropertyString(allocator, node.properties_json, "aggregationMode");
        defer if (aggregation_mode) |value_to_free| allocator.free(value_to_free);
        const evidence_qid = try readPropertyString(allocator, node.properties_json, "evidenceQid");
        defer allocator.free(evidence_qid);
        const quote = try readPropertyString(allocator, node.properties_json, "quote");
        defer allocator.free(quote);
        const valid_from = try readOptionalPropertyString(allocator, node.properties_json, "validFrom");
        defer if (valid_from) |value_to_free| allocator.free(value_to_free);
        const tenant_id = try readOptionalPropertyString(allocator, node.properties_json, "tenantId");
        defer if (tenant_id) |value_to_free| allocator.free(value_to_free);
        const user_id = try readOptionalPropertyString(allocator, node.properties_json, "userId");
        defer if (user_id) |value_to_free| allocator.free(value_to_free);
        const agent_id = try readOptionalPropertyString(allocator, node.properties_json, "agentId");
        defer if (agent_id) |value_to_free| allocator.free(value_to_free);
        const project_id = try readOptionalPropertyString(allocator, node.properties_json, "projectId");
        defer if (project_id) |value_to_free| allocator.free(value_to_free);

        const props = try stringifyAlloc(allocator, .{
            .kind = labelType(node.label),
            .text = text,
            .slotKey = slot_key,
            .subject = subject,
            .attribute = attribute,
            .value = value,
            .numericValue = numeric_value,
            .unit = unit,
            .aggregationMode = aggregation_mode orelse "single_value",
            .state = state,
            .validFrom = valid_from,
            .validTo = valid_to,
            .evidenceQid = evidence_qid,
            .quote = quote,
            .tenantId = tenant_id,
            .userId = user_id,
            .agentId = agent_id,
            .projectId = project_id,
            .deleted = false,
        });
        defer allocator.free(props);
        try self.store.putNode(.{ .qid = node.qid, .label = node.label, .properties_json = props });
    }

    fn provenanceRefsForNode(self: *Runtime, allocator: std.mem.Allocator, node: storage.Node) !OwnedNodeRefs {
        var refs = OwnedNodeRefs{ .allocator = allocator };
        errdefer refs.deinit();

        if (!isEvidenceLinkedLabel(node.label)) return refs;
        const evidence_qid = try readOptionalPropertyString(allocator, node.properties_json, "evidenceQid");
        defer if (evidence_qid) |qid| allocator.free(qid);
        if (evidence_qid) |qid| {
            const evidence_node = (try self.store.getNode(allocator, qid)) orelse return refs;
            defer self.store.freeNode(allocator, evidence_node);
            try refs.append(allocator, qid, labelType(evidence_node.label), "evidenced_by");
        }
        return refs;
    }

    fn derivedRefsByEvidence(self: *Runtime, allocator: std.mem.Allocator, evidence_qid: []const u8) !OwnedNodeRefs {
        const hits = try self.store.fullTextSearch(allocator, .{ .text = "", .limit = 1000 });
        defer freeHits(allocator, hits);

        var refs = OwnedNodeRefs{ .allocator = allocator };
        errdefer refs.deinit();
        for (hits) |hit| {
            const node = (try self.store.getNode(allocator, hit.qid)) orelse continue;
            defer self.store.freeNode(allocator, node);
            if (!isEvidenceLinkedLabel(node.label)) continue;
            if (try propertyBool(allocator, node.properties_json, "deleted")) continue;
            if (!try propertyEquals(allocator, node.properties_json, "evidenceQid", evidence_qid)) continue;
            try refs.append(allocator, node.qid, labelType(node.label), "derived_from");
        }
        return refs;
    }

    fn tombstoneDerivedByEvidence(self: *Runtime, allocator: std.mem.Allocator, evidence_qid: []const u8, reason: []const u8, mode: []const u8) !usize {
        const hits = try self.store.fullTextSearch(allocator, .{ .text = "", .limit = 1000 });
        defer freeHits(allocator, hits);
        var invalidated: usize = 0;
        for (hits) |hit| {
            const node = (try self.store.getNode(allocator, hit.qid)) orelse continue;
            defer self.store.freeNode(allocator, node);
            if (!isEvidenceLinkedLabel(node.label)) continue;
            if (try propertyBool(allocator, node.properties_json, "deleted")) continue;
            if (!try propertyEquals(allocator, node.properties_json, "evidenceQid", evidence_qid)) continue;
            try self.tombstoneNode(allocator, node.qid, node.label, reason, mode);
            invalidated += 1;
        }
        return invalidated;
    }

    fn tombstoneNode(self: *Runtime, allocator: std.mem.Allocator, qid: []const u8, label: []const u8, reason: []const u8, mode: []const u8) !void {
        const tombstone = try stringifyAlloc(allocator, .{
            .kind = "tombstone",
            .deleted = true,
            .state = if (std.mem.eql(u8, mode, "redact")) "redacted" else "deleted",
            .mode = mode,
            .reason = reason,
            .previousLabel = label,
        });
        defer allocator.free(tombstone);
        try self.store.putNode(.{ .qid = qid, .label = label, .properties_json = tombstone });
    }

    fn nextQid(self: *Runtime, allocator: std.mem.Allocator, prefix: []const u8) ![]u8 {
        const id = self.next_id;
        self.next_id += 1;
        return std.fmt.allocPrint(allocator, "q_{s}_{d}", .{ prefix, id });
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
            if (isHiddenSearchLabel(node.label) and !labelRequestedExplicitly(node.label, labels_value)) continue;
            if (!labelAllowed(node.label, labels_value)) continue;
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

            const text = textForNode(allocator, node) catch continue;
            errdefer allocator.free(text);
            const evidence = if (include_evidence) try evidenceForNode(allocator, node) else try allocator.alloc(EvidenceResult, 0);
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
            });
            if (owned.items.items.len >= limit) break;
        }
        return owned;
    }

    fn collectRawLexicalItems(
        self: *Runtime,
        allocator: std.mem.Allocator,
        query: []const u8,
        limit: usize,
        scope: Scope,
        valid_at: ?[]const u8,
        event_window: EventWindow,
        include_evidence: bool,
        include_debug: bool,
    ) !OwnedItems {
        const query_terms = try normalizedTokens(allocator, query);
        defer freeStringList(allocator, query_terms);

        try self.ensureRawMessageCache(allocator);

        var owned = OwnedItems{ .allocator = allocator };
        errdefer owned.deinit();
        for (self.raw_messages.items.items) |entry| {
            if (entry.deleted) continue;
            const node = storage.Node{ .qid = entry.qid, .label = "Message", .properties_json = entry.properties_json };
            if (try propertyBool(allocator, node.properties_json, "deleted")) continue;
            if (!try scope.matchesNode(allocator, node)) continue;
            if (!try nodeWithinEventWindow(allocator, node, event_window)) continue;
            if (valid_at) |timestamp| {
                if (!try nodeActiveAt(allocator, node, timestamp)) continue;
            }

            const text = try allocator.dupe(u8, entry.text);
            errdefer allocator.free(text);
            const score = if (query_terms.len == 0) 1.0 else lexicalCachedTermFrequencyScore(query_terms, entry.tokens);
            if (score <= 0) {
                allocator.free(text);
                continue;
            }
            const evidence = if (include_evidence) try evidenceForNode(allocator, node) else try allocator.alloc(EvidenceResult, 0);
            errdefer freeEvidence(allocator, evidence);
            const state = try stateForNode(allocator, node);
            errdefer allocator.free(state);
            const valid_from = try validFromForNode(allocator, node);
            errdefer if (valid_from) |value_to_free| allocator.free(value_to_free);
            const valid_to = try readOptionalPropertyString(allocator, node.properties_json, "validTo");
            errdefer if (valid_to) |value_to_free| allocator.free(value_to_free);
            const result_qid = try allocator.dupe(u8, node.qid);
            errdefer allocator.free(result_qid);
            try owned.items.append(allocator, .{
                .qid = result_qid,
                .type = "message",
                .text = text,
                .score = score,
                .state = state,
                .validFrom = valid_from,
                .validTo = valid_to,
                .evidence = evidence,
                .includeDebug = include_debug,
            });
        }
        sortItemsByScore(&owned);
        if (owned.items.items.len > limit) {
            for (owned.items.items[limit..]) |item| {
                owned.freeItem(item);
            }
            owned.items.shrinkRetainingCapacity(limit);
        }
        return owned;
    }

    fn ensureRawMessageCache(self: *Runtime, allocator: std.mem.Allocator) !void {
        if (self.raw_messages.complete) return;
        const candidate_hits = try self.store.fullTextSearch(allocator, .{ .text = "Message", .limit = 100_000 });
        defer freeHits(allocator, candidate_hits);
        for (candidate_hits) |hit| {
            const node = (try self.store.getNode(allocator, hit.qid)) orelse continue;
            defer self.store.freeNode(allocator, node);
            if (!std.mem.eql(u8, node.label, "Message")) continue;
            if (try propertyBool(allocator, node.properties_json, "deleted")) continue;
            try self.raw_messages.appendNode(allocator, node);
        }
        self.raw_messages.complete = true;
    }

    fn collectSearchHits(self: *Runtime, allocator: std.mem.Allocator, query: []const u8, mode: SearchMode, limit: usize) ![]storage.SearchHit {
        return switch (mode) {
            .fts => self.store.fullTextSearch(allocator, .{ .text = query, .limit = limit }),
            .graph => self.graphSearch(allocator, query, limit),
            .vector => self.vectorTextSearch(allocator, query, limit) catch |err| switch (err) {
                error.Unsupported => allocator.alloc(storage.SearchHit, 0),
                else => |e| return e,
            },
            .hybrid => self.hybridSearch(allocator, query, limit),
        };
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

        var merged = std.ArrayList(storage.SearchHit).empty;
        errdefer {
            for (merged.items) |hit| allocator.free(hit.qid);
            merged.deinit(allocator);
        }
        try appendRrfHits(allocator, &merged, fts_hits, 1.0);
        try appendRrfHits(allocator, &merged, vector_hits, 1.0);
        sortHitsByScore(merged.items);
        if (merged.items.len > limit) {
            for (merged.items[limit..]) |hit| allocator.free(hit.qid);
            merged.shrinkRetainingCapacity(limit);
        }
        return merged.toOwnedSlice(allocator);
    }

    fn graphSearch(self: *Runtime, allocator: std.mem.Allocator, query: []const u8, limit: usize) ![]storage.SearchHit {
        const base_hits = if (self.store.capabilities().vector)
            try self.hybridSearch(allocator, query, @max(limit * 2, limit))
        else
            try self.store.fullTextSearch(allocator, .{ .text = query, .limit = @max(limit * 2, limit) });
        defer freeHits(allocator, base_hits);

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

        const mention_edges = try self.store.findEdges(allocator, .{
            .from_qid = qid,
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
            try appendHitScore(allocator, merged, edge.from_qid, score);
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
            try appendHitScore(allocator, merged, edge.to_qid, score);
        }
    }

    fn appendCoreItems(self: *Runtime, allocator: std.mem.Allocator, owned: *OwnedItems, scope: Scope, include_evidence: bool, include_debug: bool) !void {
        const hits = try self.store.fullTextSearch(allocator, .{ .text = "", .limit = 1000 });
        defer freeHits(allocator, hits);

        for (hits) |hit| {
            const node = (try self.store.getNode(allocator, hit.qid)) orelse continue;
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
                .score = hit.score,
                .state = state,
                .evidence = evidence,
                .includeDebug = include_debug,
            });
        }
    }

    fn findCoreBlockQid(self: *Runtime, allocator: std.mem.Allocator, scope: Scope, block_key: []const u8) !?[]u8 {
        const hits = try self.store.fullTextSearch(allocator, .{ .text = "", .limit = 1000 });
        defer freeHits(allocator, hits);

        for (hits) |hit| {
            const node = (try self.store.getNode(allocator, hit.qid)) orelse continue;
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
            const props = try stringifyAlloc(allocator, .{
                .kind = "entity",
                .qtype = "entity",
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

const OwnedItems = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(MessageResult) = .empty,

    fn deinit(self: *OwnedItems) void {
        for (self.items.items) |item| {
            self.freeItem(item);
        }
        self.items.deinit(self.allocator);
    }

    fn suppressRawIfDerived(self: *OwnedItems, needs_value: ?Value) void {
        var has_derived = false;
        for (self.items.items) |item| {
            if (std.mem.eql(u8, item.type, "fact") or std.mem.eql(u8, item.type, "preference") or std.mem.eql(u8, item.type, "procedure") or std.mem.eql(u8, item.type, "core")) {
                has_derived = true;
                break;
            }
        }
        if (!has_derived) return;

        var write_index: usize = 0;
        for (self.items.items) |item| {
            const suppress_episode_like = !needsIncludes(needs_value, "recent_episodes") and (std.mem.eql(u8, item.type, "episode") or std.mem.eql(u8, item.type, "memory_card"));
            if (std.mem.eql(u8, item.type, "message") or std.mem.eql(u8, item.type, "raw") or suppress_episode_like) {
                self.freeItem(item);
                continue;
            }
            self.items.items[write_index] = item;
            write_index += 1;
        }
        self.items.items.len = write_index;
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
        freeEvidence(self.allocator, item.evidence);
    }
};

/// Evidence handed to answer synthesis, in retrieval rank order. Texts are the
/// same strings the renderer shows (minus raw-cache date annotations) and
/// `evidenceQids` let readers cite either a chunk/derived qid or its source.
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
            .text = std.mem.trim(u8, stripRawDateAnnotation(item.text), " \t\r\n"),
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

fn sortItemsByScore(owned: *OwnedItems) void {
    var index: usize = 1;
    while (index < owned.items.items.len) : (index += 1) {
        var cursor = index;
        while (cursor > 0 and itemRanksBefore(owned.items.items[cursor], owned.items.items[cursor - 1])) : (cursor -= 1) {
            std.mem.swap(MessageResult, &owned.items.items[cursor], &owned.items.items[cursor - 1]);
        }
    }
}

fn itemRanksBefore(left: MessageResult, right: MessageResult) bool {
    if (left.score != right.score) return left.score > right.score;
    return timestampAtOrAfter(left.validFrom orelse "", right.validFrom orelse "");
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

fn normalizedTokens(allocator: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    var tokens = std.ArrayList([]const u8).empty;
    errdefer {
        for (tokens.items) |token| {
            allocator.free(token);
        }
        tokens.deinit(allocator);
    }

    var start: ?usize = null;
    for (text, 0..) |byte, index| {
        if (std.ascii.isAlphanumeric(byte)) {
            if (start == null) start = index;
            continue;
        }
        if (start) |token_start| {
            try appendNormalizedToken(allocator, &tokens, text[token_start..index]);
            start = null;
        }
    }
    if (start) |token_start| {
        try appendNormalizedToken(allocator, &tokens, text[token_start..]);
    }
    return tokens.toOwnedSlice(allocator);
}

fn appendNormalizedToken(allocator: std.mem.Allocator, tokens: *std.ArrayList([]const u8), raw: []const u8) !void {
    if (raw.len == 0) return;
    var normalized = try allocator.alloc(u8, raw.len);
    errdefer allocator.free(normalized);
    for (raw, 0..) |byte, index| {
        normalized[index] = std.ascii.toLower(byte);
    }
    var length = normalized.len;
    if (length > 3 and normalized[length - 1] == 's') {
        length -= 1;
    }
    if (length < normalized.len) {
        normalized = try allocator.realloc(normalized, length);
    }
    if (isStopWord(normalized)) {
        allocator.free(normalized);
        return;
    }
    try tokens.append(allocator, normalized);
}

fn lexicalTermFrequencyScore(allocator: std.mem.Allocator, query_terms: []const []const u8, text: []const u8) !f32 {
    if (query_terms.len == 0) return 0;
    const document_terms = try normalizedTokens(allocator, text);
    defer freeStringList(allocator, document_terms);
    return lexicalCachedTermFrequencyScore(query_terms, document_terms);
}

fn lexicalCachedTermFrequencyScore(query_terms: []const []const u8, document_terms: []const []const u8) f32 {
    var score: f32 = 0;
    for (query_terms) |query_term| {
        for (document_terms) |document_term| {
            if (std.mem.eql(u8, query_term, document_term)) {
                score += 1;
            }
        }
    }
    return score;
}

fn isStopWord(token: []const u8) bool {
    const stop_words = [_][]const u8{
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
        "when",
        "where",
        "which",
        "who",
        "with",
    };
    for (stop_words) |word| {
        if (std.mem.eql(u8, token, word)) return true;
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

fn propertyStringArrayContains(allocator: std.mem.Allocator, properties_json: []const u8, key: []const u8, expected: []const u8) !bool {
    var parsed = try std.json.parseFromSlice(Value, allocator, properties_json, .{});
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |object| object,
        else => return false,
    };
    const array = arrayValue(object.get(key)) orelse return false;
    for (array.items) |item| {
        const value = stringValue(item) orelse continue;
        if (std.mem.eql(u8, value, expected)) return true;
    }
    return false;
}

fn textForNode(allocator: std.mem.Allocator, node: storage.Node) ![]u8 {
    // Session and Turn nodes are structure, not memory text; callers skip them
    // instead of surfacing "Session"/"Turn" placeholders.
    if (std.mem.eql(u8, node.label, "Session") or std.mem.eql(u8, node.label, "Turn")) {
        return error.NoRenderableText;
    }
    if (std.mem.eql(u8, node.label, "Chunk")) {
        return readPropertyString(allocator, node.properties_json, "content");
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

const CivilDate = struct {
    year: i32,
    month: u8,
    day: u8,
};

/// Raw-cache text appends this annotation so date words are lexically
/// searchable; the prompt renderer strips it because session headers carry the date.
const raw_date_annotation_prefix = " [message date: ";

fn rawMessageText(allocator: std.mem.Allocator, content: []const u8, properties_json: []const u8) ![]u8 {
    const created_at = try readOptionalPropertyString(allocator, properties_json, "createdAt");
    defer if (created_at) |value| allocator.free(value);
    const timestamp = created_at orelse return allocator.dupe(u8, content);
    const date = parseIsoDate(timestamp) catch return allocator.dupe(u8, content);

    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    try writer.writer.writeAll(content);

    const message_date = try formatHumanDate(allocator, date);
    defer allocator.free(message_date);
    try writer.writer.print(raw_date_annotation_prefix ++ "{s}", .{message_date});
    if (containsWordIgnoreCase(content, "today")) {
        try appendTemporalAnnotation(&writer.writer, allocator, "today", date);
    }
    if (containsWordIgnoreCase(content, "yesterday")) {
        try appendTemporalAnnotation(&writer.writer, allocator, "yesterday", shiftCivilDate(date, -1));
    }
    if (containsWordIgnoreCase(content, "tomorrow")) {
        try appendTemporalAnnotation(&writer.writer, allocator, "tomorrow", shiftCivilDate(date, 1));
    }
    try writer.writer.writeAll("]");
    return writer.toOwnedSlice();
}

fn appendTemporalAnnotation(writer: *std.Io.Writer, allocator: std.mem.Allocator, label: []const u8, date: CivilDate) !void {
    const formatted = try formatHumanDate(allocator, date);
    defer allocator.free(formatted);
    try writer.print("; {s}: {s}", .{ label, formatted });
}

fn parseIsoDate(timestamp: []const u8) !CivilDate {
    if (timestamp.len < 10 or timestamp[4] != '-' or timestamp[7] != '-') return error.InvalidDate;
    const year = try std.fmt.parseInt(i32, timestamp[0..4], 10);
    const month = try std.fmt.parseInt(u8, timestamp[5..7], 10);
    const day = try std.fmt.parseInt(u8, timestamp[8..10], 10);
    if (month < 1 or month > 12) return error.InvalidDate;
    if (day < 1 or day > daysInMonth(year, month)) return error.InvalidDate;
    return .{ .year = year, .month = month, .day = day };
}

fn formatHumanDate(allocator: std.mem.Allocator, date: CivilDate) ![]u8 {
    return std.fmt.allocPrint(allocator, "{d} {s} {d}", .{ date.day, monthName(date.month), date.year });
}

/// `YYYY-MM-DD (Weekday)` for a trusted current-date line; unparseable
/// timestamps are passed through unchanged.
fn formatCurrentDate(allocator: std.mem.Allocator, timestamp: []const u8) ![]u8 {
    const date = parseIsoDate(timestamp) catch return allocator.dupe(u8, timestamp);
    return std.fmt.allocPrint(allocator, "{s} ({s})", .{ timestamp[0..10], weekdayName(date) });
}

/// Days since 1970-01-01 in the proleptic Gregorian calendar.
fn daysFromCivil(date: CivilDate) i64 {
    const month: i64 = date.month;
    const year: i64 = if (month <= 2) @as(i64, date.year) - 1 else date.year;
    const era = @divFloor(year, 400);
    const year_of_era = year - era * 400;
    const shifted_month = @mod(month + 9, 12);
    const day_of_year = @divFloor(153 * shifted_month + 2, 5) + @as(i64, date.day) - 1;
    const day_of_era = year_of_era * 365 + @divFloor(year_of_era, 4) - @divFloor(year_of_era, 100) + day_of_year;
    return era * 146097 + day_of_era - 719468;
}

fn weekdayName(date: CivilDate) []const u8 {
    const names = [_][]const u8{ "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" };
    // 1970-01-01 was a Thursday.
    return names[@intCast(@mod(daysFromCivil(date) + 4, 7))];
}

fn shiftCivilDate(date: CivilDate, delta_days: i32) CivilDate {
    var shifted = date;
    var remaining = delta_days;
    while (remaining > 0) : (remaining -= 1) {
        const max_day = daysInMonth(shifted.year, shifted.month);
        if (shifted.day < max_day) {
            shifted.day += 1;
        } else if (shifted.month < 12) {
            shifted.month += 1;
            shifted.day = 1;
        } else {
            shifted.year += 1;
            shifted.month = 1;
            shifted.day = 1;
        }
    }
    while (remaining < 0) : (remaining += 1) {
        if (shifted.day > 1) {
            shifted.day -= 1;
        } else if (shifted.month > 1) {
            shifted.month -= 1;
            shifted.day = daysInMonth(shifted.year, shifted.month);
        } else {
            shifted.year -= 1;
            shifted.month = 12;
            shifted.day = 31;
        }
    }
    return shifted;
}

fn daysInMonth(year: i32, month: u8) u8 {
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (isLeapYear(year)) 29 else 28,
        else => 30,
    };
}

fn isLeapYear(year: i32) bool {
    return @mod(year, 4) == 0 and (@mod(year, 100) != 0 or @mod(year, 400) == 0);
}

fn monthName(month: u8) []const u8 {
    return switch (month) {
        1 => "January",
        2 => "February",
        3 => "March",
        4 => "April",
        5 => "May",
        6 => "June",
        7 => "July",
        8 => "August",
        9 => "September",
        10 => "October",
        11 => "November",
        12 => "December",
        else => "Unknown",
    };
}

fn containsWordIgnoreCase(text: []const u8, expected: []const u8) bool {
    var tokens = std.mem.tokenizeAny(u8, text, " \t\r\n.,?!:;\"'()[]{}<>/\\|");
    while (tokens.next()) |token| {
        if (std.ascii.eqlIgnoreCase(token, expected)) return true;
    }
    return false;
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
    if (std.mem.eql(u8, node.label, "Message")) {
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
    if (std.mem.eql(u8, node.label, "Message")) {
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

fn estimateItemTokens(item: MessageResult) usize {
    return @max(@as(usize, 1), item.text.len / 4 + 8);
}

const PromptOptions = struct {
    /// Trusted question date (`time.validAt`). When set, a `Current date:` line
    /// is rendered above the untrusted memory block.
    current_date: ?[]const u8 = null,
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
    }
    try out.writeAll("<memory>");
    try writePromptSection(arena, out, "core", context.core);
    try writePromptSection(arena, out, "facts", context.currentFacts);
    try writePromptSection(arena, out, "preferences", context.preferences);
    try writePromptSection(arena, out, "procedures", context.procedural);
    try writeSessionSection(arena, out, entries);
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
/// a session go last under `## other`.
fn writeSessionSection(arena: std.mem.Allocator, out: *std.Io.Writer, entries: []const RenderEntry) !void {
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

/// Orders qids such as `q_msg_9` before `q_msg_10` by comparing the trailing
/// counter numerically.
fn naturalQidOrder(left: []const u8, right: []const u8) std.math.Order {
    const left_split = trailingDigitStart(left);
    const right_split = trailingDigitStart(right);
    const prefix_order = std.mem.order(u8, left[0..left_split], right[0..right_split]);
    if (prefix_order != .eq) return prefix_order;
    const left_digits = std.mem.trimStart(u8, left[left_split..], "0");
    const right_digits = std.mem.trimStart(u8, right[right_split..], "0");
    if (left_digits.len != right_digits.len) return std.math.order(left_digits.len, right_digits.len);
    const digit_order = std.mem.order(u8, left_digits, right_digits);
    if (digit_order != .eq) return digit_order;
    return std.mem.order(u8, left, right);
}

fn trailingDigitStart(text: []const u8) usize {
    var index = text.len;
    while (index > 0 and std.ascii.isDigit(text[index - 1])) : (index -= 1) {}
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

/// Writes item text on one line: whitespace runs collapse to a single space,
/// raw-cache date annotations are dropped (the session header carries the
/// date), and context section tags inside memory text are defanged so stored
/// text cannot close or forge a section.
fn writeItemText(out: *std.Io.Writer, raw: []const u8) !void {
    const text = std.mem.trim(u8, stripRawDateAnnotation(raw), " \t\r\n");
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

fn stripRawDateAnnotation(text: []const u8) []const u8 {
    const index = std.mem.lastIndexOf(u8, text, raw_date_annotation_prefix) orelse return text;
    if (!std.mem.endsWith(u8, text, "]")) return text;
    return text[0..index];
}

fn loadRenderMeta(
    arena: std.mem.Allocator,
    store: storage.Adapter,
    item: MessageResult,
    session_ids: *std.StringHashMap(?[]const u8),
) !RenderMeta {
    var meta = RenderMeta{ .created_at = item.validFrom };
    const node = (store.getNode(arena, item.qid) catch null) orelse return meta;
    meta.role = defaultRoleForLabel(node.label);
    const props = parsePropertiesObject(arena, node.properties_json) orelse return meta;
    meta.role = jsonObjectString(props, "role") orelse meta.role;
    meta.created_at = jsonObjectString(props, "createdAt") orelse jsonObjectString(props, "eventTime") orelse item.validFrom;
    meta.session_id = jsonObjectString(props, "sessionId");
    meta.message_index = jsonObjectInt(props, "messageIndex");
    meta.chunk_index = jsonObjectInt(props, "chunkIndex");
    meta.chunk_count = jsonObjectInt(props, "chunkCount");
    meta.session_qid = sessionQidForNode(arena, store, node.qid, props, 1);
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

/// Session of a raw node: its own `sessionQid`, its turn's, its parent
/// message's (chunks), or, for nodes written before those properties existed,
/// the turn that owns it through a HAS_* edge.
fn sessionQidForNode(arena: std.mem.Allocator, store: storage.Adapter, qid: []const u8, props: std.json.ObjectMap, depth: u8) ?[]const u8 {
    if (jsonObjectString(props, "sessionQid")) |session_qid| return session_qid;
    if (jsonObjectString(props, "turnQid")) |turn_qid| {
        if (nodeProperties(arena, store, turn_qid)) |turn_props| {
            if (jsonObjectString(turn_props, "sessionQid")) |session_qid| return session_qid;
        }
    }
    if (depth > 0) {
        if (jsonObjectString(props, "messageQid")) |message_qid| {
            if (nodeProperties(arena, store, message_qid)) |message_props| {
                return sessionQidForNode(arena, store, message_qid, message_props, depth - 1);
            }
        }
    }
    const edges = store.findEdges(arena, .{ .to_qid = qid, .limit = 64 }) catch return null;
    for (edges) |edge| {
        if (!std.mem.eql(u8, edge.edge_type, "HAS_MESSAGE") and
            !std.mem.eql(u8, edge.edge_type, "HAS_TOOL_CALL") and
            !std.mem.eql(u8, edge.edge_type, "HAS_OBSERVATION")) continue;
        const turn_props = nodeProperties(arena, store, edge.from_qid) orelse continue;
        if (jsonObjectString(turn_props, "sessionQid")) |session_qid| return session_qid;
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

fn sortHitsByScore(hits: []storage.SearchHit) void {
    var index: usize = 1;
    while (index < hits.len) : (index += 1) {
        var cursor = index;
        while (cursor > 0 and hits[cursor].score > hits[cursor - 1].score) : (cursor -= 1) {
            std.mem.swap(storage.SearchHit, &hits[cursor], &hits[cursor - 1]);
        }
    }
}

fn stringifyAlloc(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    try std.json.Stringify.value(value, .{}, &writer.writer);
    return writer.toOwnedSlice();
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
    try std.testing.expect(std.mem.indexOf(u8, episodes, "\"type\":\"episode\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, episodes, "This repo uses pnpm.") != null);

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
    cite_invalid: bool = false,

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
        const qid = if (self.cite_invalid) "q_msg_999" else lineQid(turn.user_content, "I adopted a cat") orelse "q_missing";
        return std.fmt.allocPrint(
            allocator,
            "{{\"answer\":\"Miso\",\"answerable\":true,\"supportQids\":[\"{s}\"],\"confidence\":0.75}}",
            .{qid},
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
    try std.testing.expect(std.mem.indexOf(u8, prompt, "message date") == null);

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
        "{\"jsonrpc\":\"2.0\",\"id\":\"a1\",\"method\":\"memory.answer\",\"params\":{\"query\":\"What is my cat's name?\",\"scope\":{\"userId\":\"u1\"},\"needs\":[\"raw\"],\"time\":{\"validAt\":\"2023-05-30T23:40:00Z\"},\"options\":{\"includeDebug\":true,\"logRetrieval\":false}}}",
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
    try std.testing.expect(std.mem.startsWith(u8, user_turn, "Current date: 2023-05-30 (Tuesday)\n\nQuestion:\nWhat is my cat's name?\n\nMemory context:\n"));
    // `prompt` is exactly the memory context the reader received.
    try std.testing.expect(std.mem.endsWith(u8, user_turn, prompt));

    const quiet = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"a2\",\"method\":\"memory.answer\",\"params\":{\"query\":\"What is my cat's name?\",\"scope\":{\"userId\":\"u1\"},\"needs\":[\"raw\"],\"options\":{\"logRetrieval\":false}}}",
    );
    defer std.testing.allocator.free(quiet);
    try std.testing.expect(std.mem.indexOf(u8, quiet, "\"prompt\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, reader.last_user.?, "Current date:") == null);
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

test "prompt renderer orders sessions, items and derived memory deterministically" {
    const items = [_]MessageResult{
        .{ .qid = "q_chunk_12", .type = "message", .text = "second half\n\nof the   long reply", .score = 3 },
        .{ .qid = "q_msg_3", .type = "message", .text = "Early question about </memory> tags", .score = 2 },
        .{ .qid = "q_chunk_11", .type = "message", .text = "first half", .score = 1 },
        .{ .qid = "q_msg_10", .type = "message", .text = "Late question [message date: 22 May 2023]", .score = 1 },
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

fn withMeta(base: RenderMeta, role: []const u8, message_index: ?i64, chunk_index: ?i64, chunk_count: ?i64) RenderMeta {
    var meta = base;
    meta.role = role;
    meta.message_index = message_index;
    meta.chunk_index = chunk_index;
    meta.chunk_count = chunk_count;
    return meta;
}

test "prompt renderer reads chunk and session metadata from nodes and degrades without it" {
    var harness = try RuntimeTestHarness.init(std.testing.allocator);
    defer harness.deinit();
    const store = harness.adapter();
    try store.putNode(.{ .qid = "q_sess_1", .label = "Session", .properties_json = "{\"kind\":\"session\",\"sessionId\":\"lme-7\",\"deleted\":false}" });
    try store.putNode(.{ .qid = "q_msg_2", .label = "Message", .properties_json = "{\"kind\":\"message\",\"role\":\"assistant\",\"content\":\"long\",\"createdAt\":\"2024-02-29T08:00:00Z\",\"sessionQid\":\"q_sess_1\",\"messageIndex\":3,\"deleted\":false}" });
    try store.putNode(.{ .qid = "q_chunk_3", .label = "Chunk", .properties_json = "{\"kind\":\"chunk\",\"content\":\"tail part\",\"role\":\"assistant\",\"createdAt\":\"2024-02-29T08:00:00Z\",\"messageQid\":\"q_msg_2\",\"chunkIndex\":1,\"chunkCount\":2,\"messageIndex\":3,\"deleted\":false}" });

    const chunk_text = try textForNode(std.testing.allocator, .{ .qid = "q_chunk_3", .label = "Chunk", .properties_json = "{\"content\":\"tail part\"}" });
    defer std.testing.allocator.free(chunk_text);
    try std.testing.expectEqualStrings("tail part", chunk_text);
    try std.testing.expectError(error.NoRenderableText, textForNode(std.testing.allocator, .{ .qid = "q_sess_1", .label = "Session", .properties_json = "{}" }));

    const items = [_]MessageResult{
        .{ .qid = "q_chunk_3", .type = "message", .text = "tail part", .score = 1 },
        .{ .qid = "q_unknown_9", .type = "message", .text = "No node behind this item.", .score = 1, .validFrom = "2024-03-01T00:00:00Z" },
    };
    const prompt = try promptFromContext(std.testing.allocator, store, .{ .episodes = &items }, .{});
    defer std.testing.allocator.free(prompt);
    try std.testing.expectEqualStrings(
        "<memory>\n<sessions>\n## session lme-7 2024-02-29 (Thu)\n[q_chunk_3] assistant (2/2): tail part\n## other\n[q_unknown_9] 2024-03-01: No node behind this item.\n</sessions>\n</memory>",
        prompt,
    );
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

test "runtime raw retrieve indexes message date annotations" {
    var harness = try RuntimeTestHarness.init(std.testing.allocator);
    defer harness.deinit();
    var runtime = Runtime.init(harness.adapter(), harness.health());
    defer runtime.deinit();

    const remember = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"r1\",\"method\":\"memory.remember\",\"params\":{\"scope\":{\"projectId\":\"repo:test\"},\"messages\":[{\"role\":\"user\",\"content\":\"Today I rescheduled the dentist appointment.\",\"createdAt\":\"2026-02-01T10:00:00Z\"}],\"extract\":false}}",
    );
    defer std.testing.allocator.free(remember);

    const retrieve = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"q1\",\"method\":\"memory.retrieve\",\"params\":{\"query\":\"1 February 2026\",\"scope\":{\"projectId\":\"repo:test\"},\"needs\":[\"raw\"],\"options\":{\"includeDebug\":true,\"logTrace\":false,\"logAudit\":false}}}",
    );
    defer std.testing.allocator.free(retrieve);
    try std.testing.expect(std.mem.indexOf(u8, retrieve, "Today I rescheduled the dentist appointment.") != null);
    try std.testing.expect(std.mem.indexOf(u8, retrieve, "today: 1 February 2026") != null);
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

fn freeVerificationIssues(allocator: std.mem.Allocator, issues: []const storage.VerificationIssue) void {
    for (issues) |issue| {
        if (issue.qid) |qid| allocator.free(qid);
    }
    allocator.free(issues);
}
