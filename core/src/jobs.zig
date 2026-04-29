const std = @import("std");
const storage = @import("storage.zig");
const streams = @import("streams.zig");

pub const MaterializeOptions = struct {
    after_sequence: u64 = 0,
    limit: usize = 1000,
    max_attempts: u32 = 3,
};

pub const MaterializeSummary = struct {
    stream: []const u8,
    workerKind: []const u8,
    readCount: usize,
    createdCount: usize,
    existingCount: usize,
    lastSequence: u64,
};

pub const LeaseOptions = struct {
    worker_kind: []const u8,
    owner: []const u8,
    now_ms: i64 = 0,
    ttl_ms: i64 = 300_000,
    limit: usize = 10,
};

pub const LeaseResult = struct {
    qid: []const u8,
    workerKind: []const u8,
    stream: []const u8,
    sequence: u64,
    leaseOwner: []const u8,
    leaseUntilMs: i64,
};

const JobView = struct {
    job_type: []const u8,
    stream_name: []const u8,
    stream_sequence: u64,
    attempts: u32,
    max_attempts: u32,
    payload_hash: []const u8,
    payload_bytes: usize,
};

pub fn materializeDefaultStreams(
    allocator: std.mem.Allocator,
    store: storage.Adapter,
    options: MaterializeOptions,
) ![]MaterializeSummary {
    var summaries = std.ArrayList(MaterializeSummary).empty;
    errdefer summaries.deinit(allocator);
    for (streams.materialized_streams) |spec| {
        try summaries.append(allocator, try materializeStream(allocator, store, spec.name, spec.worker_kind, options));
    }
    return summaries.toOwnedSlice(allocator);
}

pub fn materializeNamedStreams(
    allocator: std.mem.Allocator,
    store: storage.Adapter,
    names: []const []const u8,
    options: MaterializeOptions,
) ![]MaterializeSummary {
    var summaries = std.ArrayList(MaterializeSummary).empty;
    errdefer summaries.deinit(allocator);
    for (names) |name| {
        try summaries.append(allocator, try materializeStream(allocator, store, name, streams.workerKindForStream(name), options));
    }
    return summaries.toOwnedSlice(allocator);
}

pub fn materializeStream(
    allocator: std.mem.Allocator,
    store: storage.Adapter,
    stream: []const u8,
    worker_kind: []const u8,
    options: MaterializeOptions,
) !MaterializeSummary {
    const entries = try store.readStream(allocator, stream, options.after_sequence, options.limit);
    defer freeStreamEntries(allocator, entries);

    var summary = MaterializeSummary{
        .stream = stream,
        .workerKind = worker_kind,
        .readCount = entries.len,
        .createdCount = 0,
        .existingCount = 0,
        .lastSequence = options.after_sequence,
    };

    for (entries) |entry| {
        summary.lastSequence = @max(summary.lastSequence, entry.sequence);
        const qid = try jobQid(allocator, entry.stream, entry.sequence, worker_kind);
        defer allocator.free(qid);
        if (try store.getNode(allocator, qid)) |node| {
            store.freeNode(allocator, node);
            summary.existingCount += 1;
            continue;
        }

        const payload_hash = try payloadHash(allocator, entry.payload_json);
        defer allocator.free(payload_hash);
        const props = try stringifyAlloc(allocator, .{
            .kind = "job",
            .qtype = "job",
            .jobType = worker_kind,
            .worker_kind = worker_kind,
            .streamName = entry.stream,
            .stream_name = entry.stream,
            .streamSequence = entry.sequence,
            .stream_sequence = entry.sequence,
            .status = "pending",
            .attempts = @as(u32, 0),
            .maxAttempts = options.max_attempts,
            .max_attempts = options.max_attempts,
            .leaseOwner = @as(?[]const u8, null),
            .lease_owner = @as(?[]const u8, null),
            .leaseUntilMs = @as(?i64, null),
            .lease_until_ms = @as(?i64, null),
            .startedAtMs = @as(?i64, null),
            .started_at_ms = @as(?i64, null),
            .completedAtMs = @as(?i64, null),
            .completed_at_ms = @as(?i64, null),
            .errorJson = @as(?[]const u8, null),
            .error_json = @as(?[]const u8, null),
            .payloadHash = payload_hash,
            .payload_hash = payload_hash,
            .payloadBytes = entry.payload_json.len,
            .payload_bytes = entry.payload_json.len,
            .payloadInlined = false,
            .payload_inlined = false,
            .payloadJson = @as(?[]const u8, null),
            .payload_json = @as(?[]const u8, null),
            .deleted = false,
        });
        defer allocator.free(props);
        try store.putNode(.{
            .qid = qid,
            .label = "Job",
            .properties_json = props,
        });
        summary.createdCount += 1;
    }

    return summary;
}

pub fn jobQid(allocator: std.mem.Allocator, stream: []const u8, sequence: u64, worker_kind: []const u8) ![]u8 {
    const key = try std.fmt.allocPrint(allocator, "{s}:{d}:{s}", .{ stream, sequence, worker_kind });
    defer allocator.free(key);
    const hash = std.hash.Wyhash.hash(0, key);
    return std.fmt.allocPrint(allocator, "q_job_{x}", .{hash});
}

pub fn leasePendingJobs(allocator: std.mem.Allocator, store: storage.Adapter, options: LeaseOptions) ![]LeaseResult {
    const hits = try store.fullTextSearch(allocator, .{ .text = "Job", .limit = 1000 });
    defer freeHits(allocator, hits);

    var leased = std.ArrayList(LeaseResult).empty;
    errdefer {
        freeLeaseResults(allocator, leased.items);
        leased.deinit(allocator);
    }

    for (hits) |hit| {
        if (leased.items.len >= options.limit) break;
        const node = (try store.getNode(allocator, hit.qid)) orelse continue;
        defer store.freeNode(allocator, node);
        if (!std.mem.eql(u8, node.label, "Job")) continue;
        if (!try propertyEquals(allocator, node.properties_json, "status", "pending")) continue;
        if (!try propertyEquals(allocator, node.properties_json, "jobType", options.worker_kind)) continue;

        const view = try readJobView(allocator, node.properties_json);
        defer freeJobView(allocator, view);
        const lease_until = options.now_ms + options.ttl_ms;
        try writeJobState(allocator, store, node.qid, view, .{
            .status = "leased",
            .attempts = view.attempts,
            .lease_owner = options.owner,
            .lease_until_ms = lease_until,
            .started_at_ms = options.now_ms,
            .completed_at_ms = null,
            .error_json = null,
        });
        try leased.append(allocator, .{
            .qid = try allocator.dupe(u8, node.qid),
            .workerKind = try allocator.dupe(u8, view.job_type),
            .stream = try allocator.dupe(u8, view.stream_name),
            .sequence = view.stream_sequence,
            .leaseOwner = try allocator.dupe(u8, options.owner),
            .leaseUntilMs = lease_until,
        });
    }

    return leased.toOwnedSlice(allocator);
}

pub fn completeJob(allocator: std.mem.Allocator, store: storage.Adapter, qid: []const u8, now_ms: i64) !void {
    const node = (try store.getNode(allocator, qid)) orelse return error.NotFound;
    defer store.freeNode(allocator, node);
    const view = try readJobView(allocator, node.properties_json);
    defer freeJobView(allocator, view);
    try writeJobState(allocator, store, node.qid, view, .{
        .status = "succeeded",
        .attempts = view.attempts,
        .lease_owner = null,
        .lease_until_ms = null,
        .started_at_ms = null,
        .completed_at_ms = now_ms,
        .error_json = null,
    });
}

pub fn failJob(allocator: std.mem.Allocator, store: storage.Adapter, qid: []const u8, error_json: []const u8, now_ms: i64) ![]const u8 {
    const node = (try store.getNode(allocator, qid)) orelse return error.NotFound;
    defer store.freeNode(allocator, node);
    const view = try readJobView(allocator, node.properties_json);
    defer freeJobView(allocator, view);
    const attempts = view.attempts + 1;
    const deadletter = attempts >= view.max_attempts;
    const status: []const u8 = if (deadletter) "deadlettered" else "pending";
    try writeJobState(allocator, store, node.qid, view, .{
        .status = status,
        .attempts = attempts,
        .lease_owner = null,
        .lease_until_ms = null,
        .started_at_ms = null,
        .completed_at_ms = if (deadletter) now_ms else null,
        .error_json = error_json,
    });
    if (deadletter) {
        const payload = try stringifyAlloc(allocator, .{
            .jobQid = qid,
            .workerKind = view.job_type,
            .stream = view.stream_name,
            .sequence = view.stream_sequence,
            .attempts = attempts,
            .errorJson = error_json,
        });
        defer allocator.free(payload);
        _ = try store.appendStream(streams.deadletter, payload);
    }
    return status;
}

pub fn freeLeaseResults(allocator: std.mem.Allocator, results: []const LeaseResult) void {
    for (results) |result| {
        allocator.free(result.qid);
        allocator.free(result.workerKind);
        allocator.free(result.stream);
        allocator.free(result.leaseOwner);
    }
    allocator.free(results);
}

fn payloadHash(allocator: std.mem.Allocator, payload_json: []const u8) ![]u8 {
    const hash = std.hash.Wyhash.hash(1, payload_json);
    return std.fmt.allocPrint(allocator, "{x}", .{hash});
}

const JobStateUpdate = struct {
    status: []const u8,
    attempts: u32,
    lease_owner: ?[]const u8,
    lease_until_ms: ?i64,
    started_at_ms: ?i64,
    completed_at_ms: ?i64,
    error_json: ?[]const u8,
};

fn readJobView(allocator: std.mem.Allocator, properties_json: []const u8) !JobView {
    return .{
        .job_type = try readPropertyString(allocator, properties_json, "jobType"),
        .stream_name = try readPropertyString(allocator, properties_json, "streamName"),
        .stream_sequence = @intCast(try readPropertyInt(allocator, properties_json, "streamSequence")),
        .attempts = @intCast(try readPropertyInt(allocator, properties_json, "attempts")),
        .max_attempts = @intCast(try readPropertyInt(allocator, properties_json, "maxAttempts")),
        .payload_hash = try readPropertyString(allocator, properties_json, "payloadHash"),
        .payload_bytes = @intCast(try readPropertyInt(allocator, properties_json, "payloadBytes")),
    };
}

fn freeJobView(allocator: std.mem.Allocator, view: JobView) void {
    allocator.free(view.job_type);
    allocator.free(view.stream_name);
    allocator.free(view.payload_hash);
}

fn writeJobState(allocator: std.mem.Allocator, store: storage.Adapter, qid: []const u8, view: JobView, update: JobStateUpdate) !void {
    const props = try stringifyAlloc(allocator, .{
        .kind = "job",
        .qtype = "job",
        .jobType = view.job_type,
        .worker_kind = view.job_type,
        .streamName = view.stream_name,
        .stream_name = view.stream_name,
        .streamSequence = view.stream_sequence,
        .stream_sequence = view.stream_sequence,
        .status = update.status,
        .attempts = update.attempts,
        .maxAttempts = view.max_attempts,
        .max_attempts = view.max_attempts,
        .leaseOwner = update.lease_owner,
        .lease_owner = update.lease_owner,
        .leaseUntilMs = update.lease_until_ms,
        .lease_until_ms = update.lease_until_ms,
        .startedAtMs = update.started_at_ms,
        .started_at_ms = update.started_at_ms,
        .completedAtMs = update.completed_at_ms,
        .completed_at_ms = update.completed_at_ms,
        .errorJson = update.error_json,
        .error_json = update.error_json,
        .payloadHash = view.payload_hash,
        .payload_hash = view.payload_hash,
        .payloadBytes = view.payload_bytes,
        .payload_bytes = view.payload_bytes,
        .payloadInlined = false,
        .payload_inlined = false,
        .payloadJson = @as(?[]const u8, null),
        .payload_json = @as(?[]const u8, null),
        .deleted = false,
    });
    defer allocator.free(props);
    try store.putNode(.{ .qid = qid, .label = "Job", .properties_json = props });
}

fn readPropertyString(allocator: std.mem.Allocator, properties_json: []const u8, key: []const u8) ![]const u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, properties_json, .{});
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |object| object,
        else => return error.InvalidJob,
    };
    const value = object.get(key) orelse return error.InvalidJob;
    return switch (value) {
        .string => |string| try allocator.dupe(u8, string),
        else => error.InvalidJob,
    };
}

fn readPropertyInt(allocator: std.mem.Allocator, properties_json: []const u8, key: []const u8) !i64 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, properties_json, .{});
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |object| object,
        else => return error.InvalidJob,
    };
    const value = object.get(key) orelse return error.InvalidJob;
    return switch (value) {
        .integer => |integer| integer,
        else => error.InvalidJob,
    };
}

fn propertyEquals(allocator: std.mem.Allocator, properties_json: []const u8, key: []const u8, expected: []const u8) !bool {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, properties_json, .{});
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

fn stringifyAlloc(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    try std.json.Stringify.value(value, .{}, &writer.writer);
    return writer.toOwnedSlice();
}

test "materializes stream entries into idempotent job nodes" {
    const in_memory = @import("in_memory_storage.zig");
    var adapter_state = in_memory.InMemoryAdapter.init(std.testing.allocator);
    defer adapter_state.deinit();
    const store = adapter_state.adapter();

    _ = try store.appendStream(streams.retrieval_logged, "{\"retrievalId\":\"q_retr_1\"}");
    const first = try materializeStream(std.testing.allocator, store, streams.retrieval_logged, "retrieval_log", .{});
    try std.testing.expectEqual(@as(usize, 1), first.readCount);
    try std.testing.expectEqual(@as(usize, 1), first.createdCount);
    try std.testing.expectEqual(@as(usize, 0), first.existingCount);

    const qid = try jobQid(std.testing.allocator, streams.retrieval_logged, 1, "retrieval_log");
    defer std.testing.allocator.free(qid);
    const node = (try store.getNode(std.testing.allocator, qid)) orelse return error.TestUnexpectedResult;
    defer store.freeNode(std.testing.allocator, node);
    try std.testing.expectEqualStrings("Job", node.label);
    try std.testing.expect(std.mem.indexOf(u8, node.properties_json, "\"status\":\"pending\"") != null);

    const second = try materializeStream(std.testing.allocator, store, streams.retrieval_logged, "retrieval_log", .{});
    try std.testing.expectEqual(@as(usize, 1), second.readCount);
    try std.testing.expectEqual(@as(usize, 0), second.createdCount);
    try std.testing.expectEqual(@as(usize, 1), second.existingCount);
}

test "leases completes and deadletters jobs" {
    const in_memory = @import("in_memory_storage.zig");
    var adapter_state = in_memory.InMemoryAdapter.init(std.testing.allocator);
    defer adapter_state.deinit();
    const store = adapter_state.adapter();

    _ = try store.appendStream(streams.extract_requested, "{\"turnQid\":\"q_turn_1\"}");
    _ = try materializeStream(std.testing.allocator, store, streams.extract_requested, "extract", .{ .max_attempts = 1 });

    const leases = try leasePendingJobs(std.testing.allocator, store, .{
        .worker_kind = "extract",
        .owner = "worker-1",
        .now_ms = 100,
        .ttl_ms = 500,
        .limit = 1,
    });
    defer freeLeaseResults(std.testing.allocator, leases);
    try std.testing.expectEqual(@as(usize, 1), leases.len);
    try std.testing.expectEqualStrings("worker-1", leases[0].leaseOwner);
    try std.testing.expectEqual(@as(i64, 600), leases[0].leaseUntilMs);

    const leased_node = (try store.getNode(std.testing.allocator, leases[0].qid)) orelse return error.TestUnexpectedResult;
    defer store.freeNode(std.testing.allocator, leased_node);
    try std.testing.expect(std.mem.indexOf(u8, leased_node.properties_json, "\"status\":\"leased\"") != null);

    const status = try failJob(std.testing.allocator, store, leases[0].qid, "{\"message\":\"boom\"}", 700);
    try std.testing.expectEqualStrings("deadlettered", status);
    const deadletters = try store.readStream(std.testing.allocator, streams.deadletter, 0, 10);
    defer freeStreamEntries(std.testing.allocator, deadletters);
    try std.testing.expectEqual(@as(usize, 1), deadletters.len);
    try std.testing.expect(std.mem.indexOf(u8, deadletters[0].payload_json, "\"attempts\":1") != null);
}
