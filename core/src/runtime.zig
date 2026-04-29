const std = @import("std");
const extractor = @import("extractor.zig");
const jobs = @import("jobs.zig");
const protocol = @import("protocol.zig");
const storage = @import("storage.zig");
const streams = @import("streams.zig");

const ObjectMap = std.json.ObjectMap;
const Value = std.json.Value;

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
    candidateCount: usize,
    keptCount: usize,
    droppedForNeeds: usize,
    droppedForBudget: usize,
    tokenEstimate: usize,
    validAt: ?[]const u8 = null,
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

pub const Runtime = struct {
    store: storage.Adapter,
    health: protocol.Health,
    next_id: u64 = 1,

    pub fn init(store: storage.Adapter, health: protocol.Health) Runtime {
        return .{ .store = store, .health = health };
    }

    pub fn initWithNextId(store: storage.Adapter, health: protocol.Health, next_id: u64) Runtime {
        return .{ .store = store, .health = health, .next_id = @max(next_id, 1) };
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
        if (std.mem.eql(u8, method, "memory.inspect")) return self.memoryInspect(allocator, id, &params);
        if (std.mem.eql(u8, method, "memory.forget")) return self.memoryForget(allocator, id, &params);
        if (std.mem.eql(u8, method, "memory.feedback")) return self.memoryFeedback(allocator, id, &params);
        if (std.mem.eql(u8, method, "memory.core.get")) return self.memoryCoreGet(allocator, id, &params);
        if (std.mem.eql(u8, method, "memory.core.update")) return self.memoryCoreUpdate(allocator, id, &params);

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
                },
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

            const message_props = try stringifyAlloc(allocator, .{
                .kind = "message",
                .role = role,
                .content = content,
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

        var results = try self.collectItems(allocator, query, mode, @intCast(limit), scope, include_deleted, params.get("labels"), null, .{}, true);
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

        var results = try self.collectItems(allocator, query, .fts, 40, scope, false, null, valid_at, event_window, include_evidence);
        defer results.deinit();
        if (needsIncludes(needs_value, "core")) {
            try self.appendCoreItems(allocator, &results, scope, include_evidence);
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

        var context = try OwnedContextPacket.fromItems(allocator, results.items.items, warnings.items);
        defer context.deinit();

        const retrieval_id = try self.nextQid(allocator, "retr");
        defer allocator.free(retrieval_id);
        const prompt = try promptFromContext(allocator, context.view());
        defer allocator.free(prompt);
        const token_estimate = @max(@as(usize, 1), prompt.len / 4);
        const trace = RetrievalTrace{
            .query = query,
            .requestedNeedsCount = needsCount(needs_value),
            .budgetTokens = budget,
            .candidateCount = candidate_count,
            .keptCount = results.items.items.len,
            .droppedForNeeds = dropped_for_needs,
            .droppedForBudget = dropped_for_budget,
            .tokenEstimate = token_estimate,
            .validAt = valid_at,
        };

        const event_payload = try stringifyAlloc(allocator, .{
            .method = "memory.retrieve",
            .retrievalId = retrieval_id,
            .query = query,
            .itemCount = results.items.items.len,
            .items = results.items.items,
            .tokenEstimate = token_estimate,
            .warnings = warnings.items,
            .trace = trace,
        });
        defer allocator.free(event_payload);
        _ = try self.publishEvent(streams.retrieval_logged, event_payload);
        _ = try self.publishEvent(streams.audit, event_payload);

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
        const qids = arrayValue(selector.get("qids")) orelse {
            return errorResponse(allocator, id, "invalid_request", "selector.qids is required for the in-memory adapter");
        };
        const mode = stringField(params, "mode") orelse {
            return errorResponse(allocator, id, "invalid_request", "mode is required");
        };
        if (!std.mem.eql(u8, mode, "hard_delete") and !std.mem.eql(u8, mode, "redact") and !std.mem.eql(u8, mode, "expire")) {
            return errorResponse(allocator, id, "invalid_request", "mode must be hard_delete, redact, or expire");
        }
        const dry_run = boolField(params, "dryRun") orelse false;
        const reason = stringField(params, "reason") orelse "unspecified";

        var roots_matched: usize = 0;
        var nodes_deleted: usize = 0;
        var nodes_redacted: usize = 0;
        var facts_invalidated: usize = 0;
        var report = OwnedForgetReport{ .allocator = allocator };
        defer report.deinit();

        const root_action: []const u8 = if (dry_run)
            if (std.mem.eql(u8, mode, "redact")) "would_redact" else "would_delete"
        else if (std.mem.eql(u8, mode, "redact"))
            "redacted"
        else
            "deleted";
        const dependent_action: []const u8 = if (dry_run) "would_invalidate" else "invalidated";

        for (qids.items) |qid_value| {
            const qid = stringValue(qid_value) orelse continue;
            const node = (try self.store.getNode(allocator, qid)) orelse continue;
            defer self.store.freeNode(allocator, node);
            roots_matched += 1;
            try report.append(allocator, qid, labelType(node.label), root_action);

            var dependents = try self.derivedRefsByEvidence(allocator, qid);
            defer dependents.deinit();
            for (dependents.items.items) |dependent| {
                if (isFactLikeType(dependent.type)) facts_invalidated += 1;
            }
            for (dependents.items.items) |dependent| {
                try report.append(allocator, dependent.qid, dependent.type, dependent_action);
            }

            if (!dry_run) {
                try self.tombstoneNode(allocator, qid, node.label, reason, mode);
                if (std.mem.eql(u8, mode, "redact")) {
                    nodes_redacted += 1;
                } else {
                    nodes_deleted += 1;
                }
                _ = try self.tombstoneDerivedByEvidence(allocator, qid, reason, "hard_delete");
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
                .summariesContaminated = @as(usize, 0),
                .jobsQueued = &[_][]const u8{},
                .report = report.items.items,
            },
        };
        return stringifyAlloc(allocator, response);
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
            try blocks.append(allocator, .{
                .qid = try allocator.dupe(u8, node.qid),
                .blockKey = block_key,
                .scope = scope.json(),
                .text = text,
                .managedBy = managed_by,
            });
        }

        const response = .{
            .jsonrpc = "2.0",
            .id = id,
            .result = .{ .blocks = blocks.items },
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
        const extracted = extractor.DeterministicExtractor.extract(content);
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
        try self.supersedeCurrentSlot(allocator, scope, candidate.slot_key, created_at);
        const qid = try self.nextQid(allocator, extractor.qidPrefix(candidate.label));
        defer allocator.free(qid);
        const props = try stringifyAlloc(allocator, .{
            .kind = labelType(label),
            .text = candidate.text,
            .slotKey = candidate.slot_key,
            .value = candidate.value,
            .state = "current",
            .validFrom = created_at,
            .validTo = @as(?[]const u8, null),
            .evidenceQid = message_qid,
            .quote = quote,
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
        const props = try stringifyAlloc(allocator, .{
            .kind = "memory_card",
            .qtype = "memory_card",
            .cardKind = memoryCardKind(candidate.label),
            .text = candidate.text,
            .contextDescription = "Deterministic extraction from raw message.",
            .slotKey = candidate.slot_key,
            .value = candidate.value,
            .state = "current",
            .validFrom = created_at,
            .validTo = @as(?[]const u8, null),
            .evidenceQid = message_qid,
            .quote = quote,
            .tenantId = scope.tenant_id,
            .userId = scope.user_id,
            .agentId = scope.agent_id,
            .projectId = scope.project_id,
            .deleted = false,
        });
        defer allocator.free(props);
        try self.store.putNode(.{ .qid = card_qid, .label = "MemoryCard", .properties_json = props });
        try self.putDeterministicEdge(allocator, card_qid, message_qid, "EVIDENCED_BY");
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
        const props = try stringifyAlloc(allocator, .{
            .kind = "episode",
            .qtype = "episode",
            .episodeType = "conversation",
            .sessionQid = session_qid,
            .turnQid = turn_qid,
            .summary = summary,
            .text = summary,
            .eventTime = created_at,
            .state = "current",
            .evidenceQid = if (message_qids.len > 0) message_qids[0] else null,
            .quote = summary,
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
        const value = try readPropertyString(allocator, node.properties_json, "value");
        defer allocator.free(value);
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
            .value = value,
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
            if (!labelAllowed(node.label, labels_value)) continue;
            if (!try nodeWithinEventWindow(allocator, node, event_window)) continue;
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
            });
            if (owned.items.items.len >= limit) break;
        }
        return owned;
    }

    fn collectSearchHits(self: *Runtime, allocator: std.mem.Allocator, query: []const u8, mode: SearchMode, limit: usize) ![]storage.SearchHit {
        return switch (mode) {
            .fts, .graph => self.store.fullTextSearch(allocator, .{ .text = query, .limit = limit }),
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
        try appendMergedHits(allocator, &merged, fts_hits);
        try appendMergedHits(allocator, &merged, vector_hits);
        if (merged.items.len > limit) {
            for (merged.items[limit..]) |hit| allocator.free(hit.qid);
            merged.shrinkRetainingCapacity(limit);
        }
        return merged.toOwnedSlice(allocator);
    }

    fn appendCoreItems(self: *Runtime, allocator: std.mem.Allocator, owned: *OwnedItems, scope: Scope, include_evidence: bool) !void {
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

    fn freeItem(self: *OwnedItems, item: MessageResult) void {
        self.allocator.free(item.qid);
        self.allocator.free(item.text);
        self.allocator.free(item.state);
        if (item.validFrom) |value| self.allocator.free(value);
        if (item.validTo) |value| self.allocator.free(value);
        freeEvidence(self.allocator, item.evidence);
    }
};

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

fn parseSearchMode(value: ?[]const u8) ?SearchMode {
    const mode = value orelse return .fts;
    if (std.mem.eql(u8, mode, "fts")) return .fts;
    if (std.mem.eql(u8, mode, "vector")) return .vector;
    if (std.mem.eql(u8, mode, "hybrid")) return .hybrid;
    if (std.mem.eql(u8, mode, "graph")) return .graph;
    return null;
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

fn textForNode(allocator: std.mem.Allocator, node: storage.Node) ![]u8 {
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
    if (std.mem.eql(u8, node.label, "Feedback")) {
        return readPropertyString(allocator, node.properties_json, "rating");
    }
    return allocator.dupe(u8, node.label);
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

fn isFactLikeType(node_type: []const u8) bool {
    return std.mem.eql(u8, node_type, "fact") or std.mem.eql(u8, node_type, "preference") or std.mem.eql(u8, node_type, "procedure");
}

fn isInternalLabel(label: []const u8) bool {
    return std.mem.eql(u8, label, "Job") or std.mem.eql(u8, label, "Idempotency");
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
    if (isDerivedLabel(node.label)) {
        return readOptionalPropertyString(allocator, node.properties_json, "validFrom");
    }
    return null;
}

fn validFromForNode(allocator: std.mem.Allocator, node: storage.Node) !?[]u8 {
    if (std.mem.eql(u8, node.label, "Message")) {
        return readOptionalPropertyString(allocator, node.properties_json, "createdAt");
    }
    if (isDerivedLabel(node.label)) {
        return readOptionalPropertyString(allocator, node.properties_json, "validFrom");
    }
    return null;
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
    if (!isDerivedLabel(node.label)) {
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

fn estimateItemTokens(item: MessageResult) usize {
    return @max(@as(usize, 1), item.text.len / 4 + 8);
}

fn promptFromContext(allocator: std.mem.Allocator, context: ContextPacket) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    try writer.writer.writeAll("<memory>");
    try writePromptSection(&writer.writer, "core", context.core);
    try writePromptSection(&writer.writer, "facts", context.currentFacts);
    try writePromptSection(&writer.writer, "preferences", context.preferences);
    try writePromptSection(&writer.writer, "procedures", context.procedural);
    try writePromptSection(&writer.writer, "episodes", context.episodes);
    try writer.writer.writeAll("\n</memory>");
    return writer.toOwnedSlice();
}

fn writePromptSection(writer: *std.Io.Writer, name: []const u8, items: []const MessageResult) !void {
    if (items.len == 0) return;
    try writer.print("\n<{s}>", .{name});
    for (items) |item| {
        try writer.print("\n- ({s}) {s}", .{ item.qid, item.text });
    }
    try writer.print("\n</{s}>", .{name});
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

fn memoryCardKind(label: extractor.Label) []const u8 {
    return switch (label) {
        .fact => "semantic",
        .preference => "preference",
        .procedure => "procedural",
    };
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

fn appendMergedHits(allocator: std.mem.Allocator, merged: *std.ArrayList(storage.SearchHit), hits: []const storage.SearchHit) !void {
    for (hits) |hit| {
        if (indexOfHit(merged.items, hit.qid)) |index| {
            merged.items[index].score += hit.score;
            continue;
        }
        const qid = try allocator.dupe(u8, hit.qid);
        errdefer allocator.free(qid);
        try merged.append(allocator, .{ .qid = qid, .score = hit.score });
    }
}

fn indexOfHit(hits: []const storage.SearchHit, qid: []const u8) ?usize {
    for (hits, 0..) |hit, index| {
        if (std.mem.eql(u8, hit.qid, qid)) return index;
    }
    return null;
}

fn stringifyAlloc(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    try std.json.Stringify.value(value, .{}, &writer.writer);
    return writer.toOwnedSlice();
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

test "runtime remembers and searches scoped raw messages" {
    const in_memory = @import("in_memory_storage.zig");
    var adapter_state = in_memory.InMemoryAdapter.init(std.testing.allocator);
    defer adapter_state.deinit();
    var runtime = Runtime.init(adapter_state.adapter(), protocol.Health.default());

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
    const in_memory = @import("in_memory_storage.zig");
    var adapter_state = in_memory.InMemoryAdapter.init(std.testing.allocator);
    defer adapter_state.deinit();
    var runtime = Runtime.init(adapter_state.adapter(), protocol.Health.default());

    const health = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"h1\",\"method\":\"system.health\",\"params\":{}}",
    );
    defer std.testing.allocator.free(health);

    try std.testing.expect(std.mem.indexOf(u8, health, "\"storage\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, health, "\"backend\":\"memory\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, health, "\"vector\":false") != null);
}

test "runtime publishes audit stream entries for mutations" {
    const in_memory = @import("in_memory_storage.zig");
    var adapter_state = in_memory.InMemoryAdapter.init(std.testing.allocator);
    defer adapter_state.deinit();
    const adapter = adapter_state.adapter();
    var runtime = Runtime.init(adapter, protocol.Health.default());

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
    const in_memory = @import("in_memory_storage.zig");
    var adapter_state = in_memory.InMemoryAdapter.init(std.testing.allocator);
    defer adapter_state.deinit();
    var runtime = Runtime.init(adapter_state.adapter(), protocol.Health.default());

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
    const in_memory = @import("in_memory_storage.zig");
    var adapter_state = in_memory.InMemoryAdapter.init(std.testing.allocator);
    defer adapter_state.deinit();
    const adapter = adapter_state.adapter();
    var runtime = Runtime.init(adapter, protocol.Health.default());

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
    const in_memory = @import("in_memory_storage.zig");
    var adapter_state = in_memory.InMemoryAdapter.init(std.testing.allocator);
    defer adapter_state.deinit();
    var runtime = Runtime.init(adapter_state.adapter(), protocol.Health.default());

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
    const in_memory = @import("in_memory_storage.zig");
    var adapter_state = in_memory.InMemoryAdapter.init(std.testing.allocator);
    defer adapter_state.deinit();
    var runtime = Runtime.init(adapter_state.adapter(), protocol.Health.default());

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

test "runtime stores and replaces core blocks" {
    const in_memory = @import("in_memory_storage.zig");
    var adapter_state = in_memory.InMemoryAdapter.init(std.testing.allocator);
    defer adapter_state.deinit();
    var runtime = Runtime.init(adapter_state.adapter(), protocol.Health.default());

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

test "runtime extracts current package manager facts" {
    const in_memory = @import("in_memory_storage.zig");
    var adapter_state = in_memory.InMemoryAdapter.init(std.testing.allocator);
    defer adapter_state.deinit();
    var runtime = Runtime.init(adapter_state.adapter(), protocol.Health.default());

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

test "runtime retrieve assembles categorized context and trace" {
    const in_memory = @import("in_memory_storage.zig");
    var adapter_state = in_memory.InMemoryAdapter.init(std.testing.allocator);
    defer adapter_state.deinit();
    var runtime = Runtime.init(adapter_state.adapter(), protocol.Health.default());

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

    const no_evidence = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"q2\",\"method\":\"memory.retrieve\",\"params\":{\"query\":\"package manager\",\"scope\":{\"projectId\":\"repo:test\"},\"needs\":[\"current_facts\"],\"options\":{\"includeEvidence\":false}}}",
    );
    defer std.testing.allocator.free(no_evidence);
    try std.testing.expect(std.mem.indexOf(u8, no_evidence, "\"evidence\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, no_evidence, "\"quote\"") == null);
}

test "runtime retrieve filters event windows and token budgets" {
    const in_memory = @import("in_memory_storage.zig");
    var adapter_state = in_memory.InMemoryAdapter.init(std.testing.allocator);
    defer adapter_state.deinit();
    var runtime = Runtime.init(adapter_state.adapter(), protocol.Health.default());

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

test "runtime extracts preference memories with temporal supersession" {
    const in_memory = @import("in_memory_storage.zig");
    var adapter_state = in_memory.InMemoryAdapter.init(std.testing.allocator);
    defer adapter_state.deinit();
    var runtime = Runtime.init(adapter_state.adapter(), protocol.Health.default());

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
    const in_memory = @import("in_memory_storage.zig");
    var adapter_state = in_memory.InMemoryAdapter.init(std.testing.allocator);
    defer adapter_state.deinit();
    var runtime = Runtime.init(adapter_state.adapter(), protocol.Health.default());

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
    const in_memory = @import("in_memory_storage.zig");
    var adapter_state = in_memory.InMemoryAdapter.init(std.testing.allocator);
    defer adapter_state.deinit();
    var runtime = Runtime.init(adapter_state.adapter(), protocol.Health.default());

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

    const issues = try adapter_state.adapter().verify(std.testing.allocator);
    defer freeVerificationIssues(std.testing.allocator, issues);
    try std.testing.expectEqual(@as(usize, 0), issues.len);
}

test "runtime forget supports redaction state" {
    const in_memory = @import("in_memory_storage.zig");
    var adapter_state = in_memory.InMemoryAdapter.init(std.testing.allocator);
    defer adapter_state.deinit();
    var runtime = Runtime.init(adapter_state.adapter(), protocol.Health.default());

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

    const issues = try adapter_state.adapter().verify(std.testing.allocator);
    defer freeVerificationIssues(std.testing.allocator, issues);
    try std.testing.expectEqual(@as(usize, 0), issues.len);
}

fn freeVerificationIssues(allocator: std.mem.Allocator, issues: []const storage.VerificationIssue) void {
    for (issues) |issue| {
        if (issue.qid) |qid| allocator.free(qid);
    }
    allocator.free(issues);
}
