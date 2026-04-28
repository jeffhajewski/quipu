const std = @import("std");
const storage = @import("storage.zig");

const NodeRecord = struct {
    qid: []u8,
    label: []u8,
    properties_json: []u8,

    fn deinit(self: NodeRecord, allocator: std.mem.Allocator) void {
        allocator.free(self.qid);
        allocator.free(self.label);
        allocator.free(self.properties_json);
    }
};

const EdgeRecord = struct {
    qid: []u8,
    from_qid: []u8,
    to_qid: []u8,
    edge_type: []u8,
    properties_json: []u8,

    fn deinit(self: EdgeRecord, allocator: std.mem.Allocator) void {
        allocator.free(self.qid);
        allocator.free(self.from_qid);
        allocator.free(self.to_qid);
        allocator.free(self.edge_type);
        allocator.free(self.properties_json);
    }
};

const StreamRecord = struct {
    stream: []u8,
    sequence: u64,
    payload_json: []u8,

    fn deinit(self: StreamRecord, allocator: std.mem.Allocator) void {
        allocator.free(self.stream);
        allocator.free(self.payload_json);
    }
};

pub const InMemoryAdapter = struct {
    allocator: std.mem.Allocator,
    nodes: std.StringHashMap(NodeRecord),
    edges: std.ArrayList(EdgeRecord),
    streams: std.ArrayList(StreamRecord),
    next_tx_id: u64 = 1,
    next_sequence: u64 = 1,

    pub fn init(allocator: std.mem.Allocator) InMemoryAdapter {
        return .{
            .allocator = allocator,
            .nodes = std.StringHashMap(NodeRecord).init(allocator),
            .edges = std.ArrayList(EdgeRecord).empty,
            .streams = std.ArrayList(StreamRecord).empty,
        };
    }

    pub fn deinit(self: *InMemoryAdapter) void {
        var node_it = self.nodes.iterator();
        while (node_it.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.nodes.deinit();

        for (self.edges.items) |edge| {
            edge.deinit(self.allocator);
        }
        self.edges.deinit(self.allocator);

        for (self.streams.items) |entry| {
            entry.deinit(self.allocator);
        }
        self.streams.deinit(self.allocator);
    }

    pub fn adapter(self: *InMemoryAdapter) storage.Adapter {
        return .{
            .context = self,
            .vtable = &vtable,
        };
    }

    fn putNode(context: *anyopaque, node: storage.Node) !void {
        const self = ctx(context);
        const record = NodeRecord{
            .qid = try self.allocator.dupe(u8, node.qid),
            .label = try self.allocator.dupe(u8, node.label),
            .properties_json = try self.allocator.dupe(u8, node.properties_json),
        };
        if (try self.nodes.fetchPut(record.qid, record)) |old| {
            old.value.deinit(self.allocator);
        }
    }

    fn putEdge(context: *anyopaque, edge: storage.Edge) !void {
        const self = ctx(context);
        try self.edges.append(self.allocator, .{
            .qid = try self.allocator.dupe(u8, edge.qid),
            .from_qid = try self.allocator.dupe(u8, edge.from_qid),
            .to_qid = try self.allocator.dupe(u8, edge.to_qid),
            .edge_type = try self.allocator.dupe(u8, edge.edge_type),
            .properties_json = try self.allocator.dupe(u8, edge.properties_json),
        });
    }

    fn fullTextSearch(context: *anyopaque, allocator: std.mem.Allocator, query: storage.FullTextQuery) ![]storage.SearchHit {
        const self = ctx(context);
        var hits = std.ArrayList(storage.SearchHit).empty;
        var node_it = self.nodes.iterator();
        while (node_it.next()) |entry| {
            if (query.text.len == 0 or contains(entry.value_ptr.properties_json, query.text) or contains(entry.value_ptr.label, query.text)) {
                try hits.append(allocator, .{
                    .qid = try allocator.dupe(u8, entry.value_ptr.qid),
                    .score = 1.0,
                });
                if (hits.items.len >= query.limit) break;
            }
        }
        return hits.toOwnedSlice(allocator);
    }

    fn vectorSearch(_: *anyopaque, allocator: std.mem.Allocator, _: storage.VectorQuery) ![]storage.SearchHit {
        return allocator.alloc(storage.SearchHit, 0);
    }

    fn appendStream(context: *anyopaque, stream: []const u8, payload_json: []const u8) !storage.StreamEntry {
        const self = ctx(context);
        const sequence = self.next_sequence;
        self.next_sequence += 1;
        const record = StreamRecord{
            .stream = try self.allocator.dupe(u8, stream),
            .sequence = sequence,
            .payload_json = try self.allocator.dupe(u8, payload_json),
        };
        try self.streams.append(self.allocator, record);
        return .{
            .stream = record.stream,
            .sequence = record.sequence,
            .payload_json = record.payload_json,
        };
    }

    fn readStream(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        stream: []const u8,
        after_sequence: u64,
        limit: usize,
    ) ![]storage.StreamEntry {
        const self = ctx(context);
        var entries = std.ArrayList(storage.StreamEntry).empty;
        for (self.streams.items) |entry| {
            if (std.mem.eql(u8, entry.stream, stream) and entry.sequence > after_sequence) {
                try entries.append(allocator, .{
                    .stream = try allocator.dupe(u8, entry.stream),
                    .sequence = entry.sequence,
                    .payload_json = try allocator.dupe(u8, entry.payload_json),
                });
                if (entries.items.len >= limit) break;
            }
        }
        return entries.toOwnedSlice(allocator);
    }

    fn beginTransaction(context: *anyopaque) !storage.Transaction {
        const self = ctx(context);
        const tx = storage.Transaction{ .id = self.next_tx_id };
        self.next_tx_id += 1;
        return tx;
    }

    fn commitTransaction(_: *anyopaque, _: storage.Transaction) !void {}

    fn rollbackTransaction(_: *anyopaque, _: storage.Transaction) !void {}

    fn verify(context: *anyopaque, allocator: std.mem.Allocator) ![]storage.VerificationIssue {
        const self = ctx(context);
        var issues = std.ArrayList(storage.VerificationIssue).empty;
        for (self.edges.items) |edge| {
            if (!self.nodes.contains(edge.from_qid)) {
                try issues.append(allocator, .{
                    .code = "missing_edge_source",
                    .message = "edge source node is missing",
                    .qid = try allocator.dupe(u8, edge.qid),
                });
            }
            if (!self.nodes.contains(edge.to_qid)) {
                try issues.append(allocator, .{
                    .code = "missing_edge_target",
                    .message = "edge target node is missing",
                    .qid = try allocator.dupe(u8, edge.qid),
                });
            }
        }
        return issues.toOwnedSlice(allocator);
    }

    fn contains(haystack: []const u8, needle: []const u8) bool {
        return std.mem.indexOf(u8, haystack, needle) != null;
    }

    fn ctx(context: *anyopaque) *InMemoryAdapter {
        return @ptrCast(@alignCast(context));
    }

    const vtable = storage.Adapter.VTable{
        .put_node = putNode,
        .put_edge = putEdge,
        .full_text_search = fullTextSearch,
        .vector_search = vectorSearch,
        .append_stream = appendStream,
        .read_stream = readStream,
        .begin_transaction = beginTransaction,
        .commit_transaction = commitTransaction,
        .rollback_transaction = rollbackTransaction,
        .verify = verify,
    };
};

test "in-memory adapter stores nodes and searches text" {
    var adapter_state = InMemoryAdapter.init(std.testing.allocator);
    defer adapter_state.deinit();
    const adapter = adapter_state.adapter();

    try adapter.putNode(.{
        .qid = "q_msg_1",
        .label = "Message",
        .properties_json = "{\"text\":\"Use pnpm\"}",
    });

    const hits = try adapter.fullTextSearch(std.testing.allocator, .{ .text = "pnpm", .limit = 10 });
    defer {
        for (hits) |hit| std.testing.allocator.free(hit.qid);
        std.testing.allocator.free(hits);
    }

    try std.testing.expectEqual(@as(usize, 1), hits.len);
    try std.testing.expectEqualStrings("q_msg_1", hits[0].qid);
}

test "in-memory verification reports dangling edges" {
    var adapter_state = InMemoryAdapter.init(std.testing.allocator);
    defer adapter_state.deinit();
    const adapter = adapter_state.adapter();

    try adapter.putEdge(.{
        .qid = "q_edge_1",
        .from_qid = "q_missing_source",
        .to_qid = "q_missing_target",
        .edge_type = "EVIDENCED_BY",
        .properties_json = "{}",
    });

    const issues = try adapter.verify(std.testing.allocator);
    defer {
        for (issues) |issue| {
            if (issue.qid) |qid| std.testing.allocator.free(qid);
        }
        std.testing.allocator.free(issues);
    }

    try std.testing.expectEqual(@as(usize, 2), issues.len);
}
