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
            self.allocator.free(entry.key_ptr.*);
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
        const key = try self.allocator.dupe(u8, node.qid);
        errdefer self.allocator.free(key);
        const record = NodeRecord{
            .qid = try self.allocator.dupe(u8, node.qid),
            .label = try self.allocator.dupe(u8, node.label),
            .properties_json = try self.allocator.dupe(u8, node.properties_json),
        };
        errdefer record.deinit(self.allocator);

        const entry = try self.nodes.getOrPut(key);
        if (entry.found_existing) {
            self.allocator.free(key);
            entry.value_ptr.deinit(self.allocator);
        }
        entry.value_ptr.* = record;
    }

    fn getNode(context: *anyopaque, allocator: std.mem.Allocator, qid: []const u8) !?storage.Node {
        const self = ctx(context);
        const record = self.nodes.get(qid) orelse return null;
        return .{
            .qid = try allocator.dupe(u8, record.qid),
            .label = try allocator.dupe(u8, record.label),
            .properties_json = try allocator.dupe(u8, record.properties_json),
        };
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
            const score = scoreRecord(entry.value_ptr.*, query.text);
            if (score > 0) {
                try hits.append(allocator, .{
                    .qid = try allocator.dupe(u8, entry.value_ptr.qid),
                    .score = score,
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
        errdefer freeIssues(allocator, issues.items);
        errdefer issues.deinit(allocator);

        for (self.edges.items) |edge| {
            if (!self.nodes.contains(edge.from_qid)) {
                try appendIssue(allocator, &issues, "missing_edge_source", "edge source node is missing", edge.qid);
            }
            if (!self.nodes.contains(edge.to_qid)) {
                try appendIssue(allocator, &issues, "missing_edge_target", "edge target node is missing", edge.qid);
            }
        }

        var node_it = self.nodes.iterator();
        while (node_it.next()) |entry| {
            const node = entry.value_ptr.*;
            if (isDerivedLabel(node.label)) {
                try verifyDerivedNode(self, allocator, &issues, node);
            }
            if (propertyBool(allocator, node.properties_json, "deleted")) {
                try verifyDeletedEvidenceClosure(self, allocator, &issues, node.qid);
            }
        }

        return issues.toOwnedSlice(allocator);
    }

    fn verifyDerivedNode(
        self: *InMemoryAdapter,
        allocator: std.mem.Allocator,
        issues: *std.ArrayList(storage.VerificationIssue),
        node: NodeRecord,
    ) !void {
        if (propertyBool(allocator, node.properties_json, "deleted")) return;

        const state = try readOptionalString(allocator, node.properties_json, "state");
        defer if (state) |value| allocator.free(value);
        if (state == null or (!std.mem.eql(u8, state.?, "current") and !std.mem.eql(u8, state.?, "superseded") and !std.mem.eql(u8, state.?, "historical"))) {
            try appendIssue(allocator, issues, "invalid_derived_state", "active derived node has invalid state", node.qid);
        }

        const valid_from = try readOptionalString(allocator, node.properties_json, "validFrom");
        defer if (valid_from) |value| allocator.free(value);
        const valid_to = try readOptionalString(allocator, node.properties_json, "validTo");
        defer if (valid_to) |value| allocator.free(value);
        if (state) |value| {
            if (std.mem.eql(u8, value, "current") and valid_to != null) {
                try appendIssue(allocator, issues, "current_derived_has_valid_to", "current derived node must not have validTo", node.qid);
            }
            if (std.mem.eql(u8, value, "superseded") and valid_to == null) {
                try appendIssue(allocator, issues, "superseded_derived_missing_valid_to", "superseded derived node must have validTo", node.qid);
            }
        }
        if (valid_from != null and valid_to != null and std.mem.order(u8, valid_to.?, valid_from.?) == .lt) {
            try appendIssue(allocator, issues, "invalid_temporal_window", "derived node validTo is before validFrom", node.qid);
        }

        const evidence_qid = try readOptionalString(allocator, node.properties_json, "evidenceQid");
        defer if (evidence_qid) |value| allocator.free(value);
        if (evidence_qid == null) {
            try appendIssue(allocator, issues, "missing_evidence_qid", "active derived node is missing evidenceQid", node.qid);
            return;
        }

        _ = self.nodes.get(evidence_qid.?) orelse {
            try appendIssue(allocator, issues, "missing_evidence_node", "active derived node references missing evidence", node.qid);
            return;
        };
    }

    fn verifyDeletedEvidenceClosure(
        self: *InMemoryAdapter,
        allocator: std.mem.Allocator,
        issues: *std.ArrayList(storage.VerificationIssue),
        evidence_qid: []const u8,
    ) !void {
        var node_it = self.nodes.iterator();
        while (node_it.next()) |entry| {
            const node = entry.value_ptr.*;
            if (!isDerivedLabel(node.label)) continue;
            if (propertyBool(allocator, node.properties_json, "deleted")) continue;
            const evidence = try readOptionalString(allocator, node.properties_json, "evidenceQid");
            defer if (evidence) |value| allocator.free(value);
            if (evidence) |qid| {
                if (std.mem.eql(u8, qid, evidence_qid)) {
                    try appendIssue(allocator, issues, "active_derived_from_deleted_evidence", "active derived node references deleted evidence", node.qid);
                }
            }
        }
    }

    fn scoreRecord(record: NodeRecord, query: []const u8) f32 {
        if (query.len == 0) return 1.0;

        var score: f32 = 0;
        var tokens = std.mem.tokenizeAny(u8, query, " \t\r\n.,?!:;\"'()[]{}<>/\\|");
        while (tokens.next()) |token| {
            if (token.len < 2) continue;
            if (containsIgnoreCase(record.properties_json, token) or containsIgnoreCase(record.label, token)) {
                score += 1.0;
            }
        }
        return score;
    }

    fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
        if (needle.len == 0) return true;
        if (needle.len > haystack.len) return false;
        var index: usize = 0;
        while (index + needle.len <= haystack.len) : (index += 1) {
            if (std.ascii.eqlIgnoreCase(haystack[index .. index + needle.len], needle)) return true;
        }
        return false;
    }

    fn appendIssue(
        allocator: std.mem.Allocator,
        issues: *std.ArrayList(storage.VerificationIssue),
        code: []const u8,
        message: []const u8,
        qid: []const u8,
    ) !void {
        const issue_qid = try allocator.dupe(u8, qid);
        errdefer allocator.free(issue_qid);
        try issues.append(allocator, .{
            .code = code,
            .message = message,
            .qid = issue_qid,
        });
    }

    fn freeIssues(allocator: std.mem.Allocator, issues: []const storage.VerificationIssue) void {
        for (issues) |issue| {
            if (issue.qid) |qid| allocator.free(qid);
        }
    }

    fn isDerivedLabel(label: []const u8) bool {
        return std.mem.eql(u8, label, "Fact") or std.mem.eql(u8, label, "Procedure");
    }

    fn readOptionalString(allocator: std.mem.Allocator, properties_json: []const u8, key: []const u8) !?[]u8 {
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, properties_json, .{});
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

    fn propertyBool(allocator: std.mem.Allocator, properties_json: []const u8, key: []const u8) bool {
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, properties_json, .{}) catch return false;
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

    fn ctx(context: *anyopaque) *InMemoryAdapter {
        return @ptrCast(@alignCast(context));
    }

    const vtable = storage.Adapter.VTable{
        .put_node = putNode,
        .get_node = getNode,
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

test "in-memory verification reports missing derived evidence" {
    var adapter_state = InMemoryAdapter.init(std.testing.allocator);
    defer adapter_state.deinit();
    const adapter = adapter_state.adapter();

    try adapter.putNode(.{
        .qid = "q_fact_1",
        .label = "Fact",
        .properties_json = "{\"kind\":\"fact\",\"text\":\"The repo uses pnpm.\",\"slotKey\":\"project.package_manager\",\"value\":\"pnpm\",\"state\":\"current\",\"validFrom\":\"2026-01-01T00:00:00Z\",\"validTo\":null,\"evidenceQid\":\"q_msg_missing\",\"deleted\":false}",
    });

    const issues = try adapter.verify(std.testing.allocator);
    defer freeVerificationIssues(std.testing.allocator, issues);

    try std.testing.expect(hasIssueCode(issues, "missing_evidence_node"));
}

test "in-memory verification reports active derived memory from deleted evidence" {
    var adapter_state = InMemoryAdapter.init(std.testing.allocator);
    defer adapter_state.deinit();
    const adapter = adapter_state.adapter();

    try adapter.putNode(.{
        .qid = "q_msg_1",
        .label = "Message",
        .properties_json = "{\"kind\":\"tombstone\",\"deleted\":true,\"state\":\"deleted\",\"previousLabel\":\"Message\"}",
    });
    try adapter.putNode(.{
        .qid = "q_fact_1",
        .label = "Fact",
        .properties_json = "{\"kind\":\"fact\",\"text\":\"The repo uses pnpm.\",\"slotKey\":\"project.package_manager\",\"value\":\"pnpm\",\"state\":\"current\",\"validFrom\":\"2026-01-01T00:00:00Z\",\"validTo\":null,\"evidenceQid\":\"q_msg_1\",\"deleted\":false}",
    });

    const issues = try adapter.verify(std.testing.allocator);
    defer freeVerificationIssues(std.testing.allocator, issues);

    try std.testing.expect(hasIssueCode(issues, "active_derived_from_deleted_evidence"));
}

fn hasIssueCode(issues: []const storage.VerificationIssue, code: []const u8) bool {
    for (issues) |issue| {
        if (std.mem.eql(u8, issue.code, code)) return true;
    }
    return false;
}

fn freeVerificationIssues(allocator: std.mem.Allocator, issues: []const storage.VerificationIssue) void {
    for (issues) |issue| {
        if (issue.qid) |qid| allocator.free(qid);
    }
    allocator.free(issues);
}
