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

fn payloadHash(allocator: std.mem.Allocator, payload_json: []const u8) ![]u8 {
    const hash = std.hash.Wyhash.hash(1, payload_json);
    return std.fmt.allocPrint(allocator, "{x}", .{hash});
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
