const std = @import("std");
const storage = @import("storage.zig");

const NodeRecord = struct {
    qid: []u8,
    label: []u8,
    properties_json: []u8,
    /// Position in creation order, from 1. Kept when the node is rewritten.
    seq: u64,
    /// Lexical index for this node. Empty when the node is not searchable.
    index: IndexedText = .{},
    /// This node's value of each `storage.indexed_properties` entry, so
    /// `findNodes` compares strings instead of parsing JSON.
    indexed: storage.IndexedValues = @splat(null),

    fn deinit(self: NodeRecord, allocator: std.mem.Allocator) void {
        allocator.free(self.qid);
        allocator.free(self.label);
        allocator.free(self.properties_json);
        self.index.deinit(allocator);
        storage.freeIndexedValues(allocator, self.indexed);
    }
};

/// Tokenized index text for one node. `terms` slices point into `buffer`.
const IndexedText = struct {
    buffer: []u8 = &.{},
    terms: []const []const u8 = &.{},

    fn deinit(self: IndexedText, allocator: std.mem.Allocator) void {
        if (self.terms.len > 0) allocator.free(self.terms);
        if (self.buffer.len > 0) allocator.free(self.buffer);
    }
};

const bm25_k1: f32 = 1.2;
const bm25_b: f32 = 0.75;

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

fn freeEdge(allocator: std.mem.Allocator, edge: storage.Edge) void {
    allocator.free(edge.qid);
    allocator.free(edge.from_qid);
    allocator.free(edge.to_qid);
    allocator.free(edge.edge_type);
    allocator.free(edge.properties_json);
}

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
    /// Qid to position in `records`. Keys are owned.
    nodes: std.StringHashMap(usize),
    /// Nodes in creation order; a node's `seq` is its position plus one.
    /// Nodes are rewritten in place and never removed.
    records: std.ArrayList(NodeRecord),
    edges: std.ArrayList(EdgeRecord),
    /// Edge qid to position in `edges`. Keys are owned.
    edge_index: std.StringHashMapUnmanaged(usize) = .empty,
    /// Positions in `edges` by endpoint, in creation order. Keys are owned.
    edges_from: std.StringHashMapUnmanaged(std.ArrayList(usize)) = .empty,
    edges_to: std.StringHashMapUnmanaged(std.ArrayList(usize)) = .empty,
    streams: std.ArrayList(StreamRecord),
    next_tx_id: u64 = 1,
    next_sequence: u64 = 1,

    pub fn init(allocator: std.mem.Allocator) InMemoryAdapter {
        return .{
            .allocator = allocator,
            .nodes = std.StringHashMap(usize).init(allocator),
            .records = std.ArrayList(NodeRecord).empty,
            .edges = std.ArrayList(EdgeRecord).empty,
            .streams = std.ArrayList(StreamRecord).empty,
        };
    }

    pub fn deinit(self: *InMemoryAdapter) void {
        var key_it = self.nodes.keyIterator();
        while (key_it.next()) |key| self.allocator.free(key.*);
        self.nodes.deinit();
        for (self.records.items) |record| record.deinit(self.allocator);
        self.records.deinit(self.allocator);

        for (self.edges.items) |edge| {
            edge.deinit(self.allocator);
        }
        self.edges.deinit(self.allocator);
        var edge_key_it = self.edge_index.keyIterator();
        while (edge_key_it.next()) |key| self.allocator.free(key.*);
        self.edge_index.deinit(self.allocator);
        deinitAdjacency(self.allocator, &self.edges_from);
        deinitAdjacency(self.allocator, &self.edges_to);

        for (self.streams.items) |entry| {
            entry.deinit(self.allocator);
        }
        self.streams.deinit(self.allocator);
    }

    fn deinitAdjacency(allocator: std.mem.Allocator, map: *std.StringHashMapUnmanaged(std.ArrayList(usize))) void {
        var it = map.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(allocator);
        }
        map.deinit(allocator);
    }

    pub fn adapter(self: *InMemoryAdapter) storage.Adapter {
        return .{
            .context = self,
            .vtable = &vtable,
        };
    }

    fn capabilities(_: *anyopaque) storage.Capabilities {
        return .{
            .backend = "memory",
            .durable = false,
            .full_text = true,
            .vector = false,
            .streams = true,
            .transactions = true,
            .verification = true,
        };
    }

    fn recordFor(self: *InMemoryAdapter, qid: []const u8) ?*NodeRecord {
        const position = self.nodes.get(qid) orelse return null;
        return &self.records.items[position];
    }

    fn putNode(context: *anyopaque, node: storage.Node) !void {
        const self = ctx(context);
        const index = try buildIndex(self.allocator, node.label, node.properties_json);
        errdefer index.deinit(self.allocator);
        const indexed = try storage.indexedValues(self.allocator, node.properties_json);
        errdefer storage.freeIndexedValues(self.allocator, indexed);
        const owned_qid = try self.allocator.dupe(u8, node.qid);
        errdefer self.allocator.free(owned_qid);
        const owned_label = try self.allocator.dupe(u8, node.label);
        errdefer self.allocator.free(owned_label);
        const owned_properties = try self.allocator.dupe(u8, node.properties_json);
        errdefer self.allocator.free(owned_properties);
        var new_record = NodeRecord{
            .qid = owned_qid,
            .label = owned_label,
            .properties_json = owned_properties,
            .seq = 0,
            .index = index,
            .indexed = indexed,
        };

        if (self.recordFor(node.qid)) |existing| {
            new_record.seq = existing.seq;
            existing.deinit(self.allocator);
            existing.* = new_record;
            return;
        }
        const key = try self.allocator.dupe(u8, node.qid);
        errdefer self.allocator.free(key);
        try self.records.ensureUnusedCapacity(self.allocator, 1);
        try self.nodes.put(key, self.records.items.len);
        new_record.seq = self.records.items.len + 1;
        self.records.appendAssumeCapacity(new_record);
    }

    fn getNode(context: *anyopaque, allocator: std.mem.Allocator, qid: []const u8) !?storage.Node {
        const self = ctx(context);
        const found = self.recordFor(qid) orelse return null;
        const owned_qid = try allocator.dupe(u8, found.qid);
        errdefer allocator.free(owned_qid);
        const owned_label = try allocator.dupe(u8, found.label);
        errdefer allocator.free(owned_label);
        return .{
            .qid = owned_qid,
            .label = owned_label,
            .properties_json = try allocator.dupe(u8, found.properties_json),
        };
    }

    fn putEdge(context: *anyopaque, edge: storage.Edge) !void {
        const self = ctx(context);
        const new_record = EdgeRecord{
            .qid = try self.allocator.dupe(u8, edge.qid),
            .from_qid = try self.allocator.dupe(u8, edge.from_qid),
            .to_qid = try self.allocator.dupe(u8, edge.to_qid),
            .edge_type = try self.allocator.dupe(u8, edge.edge_type),
            .properties_json = try self.allocator.dupe(u8, edge.properties_json),
        };
        errdefer new_record.deinit(self.allocator);

        if (self.edge_index.get(edge.qid)) |position| {
            const existing = &self.edges.items[position];
            if (!std.mem.eql(u8, existing.from_qid, edge.from_qid) or !std.mem.eql(u8, existing.to_qid, edge.to_qid)) {
                try self.addAdjacency(&self.edges_from, edge.from_qid, position);
                try self.addAdjacency(&self.edges_to, edge.to_qid, position);
                removeAdjacency(&self.edges_from, existing.from_qid, position);
                removeAdjacency(&self.edges_to, existing.to_qid, position);
            }
            existing.deinit(self.allocator);
            existing.* = new_record;
            return;
        }

        const position = self.edges.items.len;
        const key = try self.allocator.dupe(u8, edge.qid);
        errdefer self.allocator.free(key);
        try self.edges.ensureUnusedCapacity(self.allocator, 1);
        try self.edge_index.put(self.allocator, key, position);
        errdefer _ = self.edge_index.remove(key);
        try self.addAdjacency(&self.edges_from, edge.from_qid, position);
        errdefer removeAdjacency(&self.edges_from, edge.from_qid, position);
        try self.addAdjacency(&self.edges_to, edge.to_qid, position);
        self.edges.appendAssumeCapacity(new_record);
    }

    fn addAdjacency(self: *InMemoryAdapter, map: *std.StringHashMapUnmanaged(std.ArrayList(usize)), qid: []const u8, position: usize) !void {
        const entry = try map.getOrPut(self.allocator, qid);
        if (!entry.found_existing) {
            entry.key_ptr.* = self.allocator.dupe(u8, qid) catch |err| {
                map.removeByPtr(entry.key_ptr);
                return err;
            };
            entry.value_ptr.* = .empty;
        }
        try entry.value_ptr.append(self.allocator, position);
    }

    fn removeAdjacency(map: *std.StringHashMapUnmanaged(std.ArrayList(usize)), qid: []const u8, position: usize) void {
        const list = map.getPtr(qid) orelse return;
        for (list.items, 0..) |item, index| {
            if (item == position) {
                _ = list.orderedRemove(index);
                return;
            }
        }
    }

    /// Served from the endpoint indexes when either endpoint is given, in
    /// creation order.
    fn findEdges(context: *anyopaque, allocator: std.mem.Allocator, query: storage.EdgeQuery) ![]storage.Edge {
        const self = ctx(context);
        var edges = std.ArrayList(storage.Edge).empty;
        errdefer {
            for (edges.items) |edge| freeEdge(allocator, edge);
            edges.deinit(allocator);
        }
        if (query.limit == 0) return edges.toOwnedSlice(allocator);
        const positions: ?[]const usize = if (query.from_qid) |from_qid|
            (if (self.edges_from.get(from_qid)) |list| list.items else &.{})
        else if (query.to_qid) |to_qid|
            (if (self.edges_to.get(to_qid)) |list| list.items else &.{})
        else
            null;
        const count = if (positions) |list| list.len else self.edges.items.len;
        for (0..count) |index| {
            const edge = self.edges.items[if (positions) |list| list[index] else index];
            if (query.from_qid) |from_qid| {
                if (!std.mem.eql(u8, edge.from_qid, from_qid)) continue;
            }
            if (query.to_qid) |to_qid| {
                if (!std.mem.eql(u8, edge.to_qid, to_qid)) continue;
            }
            if (query.edge_type) |edge_type| {
                if (!std.mem.eql(u8, edge.edge_type, edge_type)) continue;
            }
            try edges.ensureUnusedCapacity(allocator, 1);
            const owned_qid = try allocator.dupe(u8, edge.qid);
            errdefer allocator.free(owned_qid);
            const owned_from = try allocator.dupe(u8, edge.from_qid);
            errdefer allocator.free(owned_from);
            const owned_to = try allocator.dupe(u8, edge.to_qid);
            errdefer allocator.free(owned_to);
            const owned_type = try allocator.dupe(u8, edge.edge_type);
            errdefer allocator.free(owned_type);
            edges.appendAssumeCapacity(.{
                .qid = owned_qid,
                .from_qid = owned_from,
                .to_qid = owned_to,
                .edge_type = owned_type,
                .properties_json = try allocator.dupe(u8, edge.properties_json),
            });
            if (edges.items.len >= query.limit) break;
        }
        return edges.toOwnedSlice(allocator);
    }

    /// Scans nodes in creation order. Indexed properties compare the values
    /// cached at write time; other properties parse each node's JSON.
    fn findNodes(context: *anyopaque, allocator: std.mem.Allocator, query: storage.NodeQuery) !storage.NodePage {
        const self = ctx(context);
        var qids = std.ArrayList([]u8).empty;
        errdefer {
            for (qids.items) |qid| allocator.free(qid);
            qids.deinit(allocator);
        }
        for (query.where) |match| {
            if (match.value.len == 0) return .{ .qids = try qids.toOwnedSlice(allocator) };
        }
        if (query.limit == 0) return .{ .qids = try qids.toOwnedSlice(allocator) };

        const total: u64 = self.records.items.len;
        var next: ?u64 = null;
        switch (query.order) {
            .oldest_first => {
                var seq: u64 = (query.after orelse 0) + 1;
                while (seq <= total) : (seq += 1) {
                    const candidate = &self.records.items[seq - 1];
                    if (!try recordMatches(allocator, candidate, query)) continue;
                    try qids.ensureUnusedCapacity(allocator, 1);
                    qids.appendAssumeCapacity(try allocator.dupe(u8, candidate.qid));
                    if (qids.items.len >= query.limit) {
                        next = seq;
                        break;
                    }
                }
            },
            .newest_first => {
                var seq: u64 = if (query.after) |after| @min(after -| 1, total) else total;
                while (seq >= 1) : (seq -= 1) {
                    const candidate = &self.records.items[seq - 1];
                    if (!try recordMatches(allocator, candidate, query)) continue;
                    try qids.ensureUnusedCapacity(allocator, 1);
                    qids.appendAssumeCapacity(try allocator.dupe(u8, candidate.qid));
                    if (qids.items.len >= query.limit) {
                        next = seq;
                        break;
                    }
                }
            },
        }
        return .{ .qids = try qids.toOwnedSlice(allocator), .next = next };
    }

    fn recordMatches(allocator: std.mem.Allocator, candidate: *const NodeRecord, query: storage.NodeQuery) !bool {
        if (query.label) |label| {
            if (!std.mem.eql(u8, candidate.label, label)) return false;
        }
        for (query.where) |match| {
            if (storage.indexedPropertyIndex(match.name)) |index| {
                const value = candidate.indexed[index] orelse return false;
                if (!std.mem.eql(u8, value, match.value)) return false;
            } else if (!try storage.propertyStringEquals(allocator, candidate.properties_json, match.name, match.value)) {
                return false;
            }
        }
        return true;
    }

    /// BM25 (k1=1.2, b=0.75) over each searchable node's index text.
    /// An empty query enumerates every node, including unsearchable ones, in
    /// creation order.
    fn fullTextSearch(context: *anyopaque, allocator: std.mem.Allocator, query: storage.FullTextQuery) ![]storage.SearchHit {
        const self = ctx(context);
        var hits = std.ArrayList(storage.SearchHit).empty;
        errdefer {
            for (hits.items) |hit| allocator.free(hit.qid);
            hits.deinit(allocator);
        }
        if (query.limit == 0) return hits.toOwnedSlice(allocator);

        if (query.text.len == 0) {
            for (self.records.items) |entry| {
                try hits.append(allocator, .{
                    .qid = try allocator.dupe(u8, entry.qid),
                    .score = 1.0,
                });
                if (hits.items.len >= query.limit) break;
            }
            return hits.toOwnedSlice(allocator);
        }

        const query_index = try tokenize(allocator, query.text);
        defer query_index.deinit(allocator);
        const query_terms = try uniqueTerms(allocator, query_index.terms);
        defer allocator.free(query_terms);
        if (query_terms.len == 0) return hits.toOwnedSlice(allocator);

        // Pass 1: corpus statistics and per-document term frequencies.
        const term_count = query_terms.len;
        var records = std.ArrayList(*const NodeRecord).empty;
        defer records.deinit(allocator);
        var frequencies = std.ArrayList(u32).empty;
        defer frequencies.deinit(allocator);
        const document_frequency = try allocator.alloc(u32, term_count);
        defer allocator.free(document_frequency);
        @memset(document_frequency, 0);
        var corpus_size: usize = 0;
        var total_length: usize = 0;

        for (self.records.items) |*record| {
            const terms = record.index.terms;
            if (terms.len == 0) continue;
            corpus_size += 1;
            total_length += terms.len;

            const start = frequencies.items.len;
            try frequencies.appendNTimes(allocator, 0, term_count);
            const row = frequencies.items[start..];
            var matched = false;
            for (terms) |term| {
                for (query_terms, 0..) |query_term, term_index| {
                    if (std.mem.eql(u8, term, query_term)) {
                        row[term_index] += 1;
                        matched = true;
                        break;
                    }
                }
            }
            if (!matched) {
                frequencies.shrinkRetainingCapacity(start);
                continue;
            }
            for (row, 0..) |count, term_index| {
                if (count > 0) document_frequency[term_index] += 1;
            }
            try records.append(allocator, record);
        }
        if (records.items.len == 0) return hits.toOwnedSlice(allocator);

        // Pass 2: score matching documents.
        const n: f32 = @floatFromInt(corpus_size);
        const average_length: f32 = @as(f32, @floatFromInt(total_length)) / n;
        const idf = try allocator.alloc(f32, term_count);
        defer allocator.free(idf);
        for (document_frequency, 0..) |df_count, term_index| {
            const df: f32 = @floatFromInt(df_count);
            idf[term_index] = @log(1.0 + (n - df + 0.5) / (df + 0.5));
        }
        for (records.items, 0..) |record, record_index| {
            const row = frequencies.items[record_index * term_count .. (record_index + 1) * term_count];
            const length: f32 = @floatFromInt(record.index.terms.len);
            const norm = bm25_k1 * (1.0 - bm25_b + bm25_b * length / average_length);
            var score: f32 = 0;
            for (row, 0..) |count, term_index| {
                if (count == 0) continue;
                const tf: f32 = @floatFromInt(count);
                score += idf[term_index] * tf * (bm25_k1 + 1.0) / (tf + norm);
            }
            if (score <= 0) continue;
            try hits.append(allocator, .{
                .qid = try allocator.dupe(u8, record.qid),
                .score = score,
            });
        }

        std.mem.sort(storage.SearchHit, hits.items, {}, hitRanksBefore);
        if (hits.items.len > query.limit) {
            for (hits.items[query.limit..]) |hit| allocator.free(hit.qid);
            hits.shrinkRetainingCapacity(query.limit);
        }
        return hits.toOwnedSlice(allocator);
    }

    fn hitRanksBefore(_: void, left: storage.SearchHit, right: storage.SearchHit) bool {
        if (left.score != right.score) return left.score > right.score;
        return std.mem.order(u8, left.qid, right.qid) == .lt;
    }

    fn vectorSearch(_: *anyopaque, allocator: std.mem.Allocator, _: storage.VectorQuery) ![]storage.SearchHit {
        return allocator.alloc(storage.SearchHit, 0);
    }

    fn embedText(_: *anyopaque, _: std.mem.Allocator, _: []const u8) ![]f32 {
        return error.Unsupported;
    }

    /// No embeddings, so nothing to prefetch.
    fn prefetchEmbeddings(_: *anyopaque, _: []const []const u8) !void {}

    fn clearPrefetchedEmbeddings(_: *anyopaque) void {}

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

        for (self.records.items) |node| {
            if (isDerivedLabel(node.label)) {
                try verifyDerivedNode(self, allocator, &issues, node);
                try verifyEvidenceNotDeleted(self, allocator, &issues, node);
            }
        }

        return issues.toOwnedSlice(allocator);
    }

    /// One pass: a live derived node whose evidence is a tombstone.
    fn verifyEvidenceNotDeleted(
        self: *InMemoryAdapter,
        allocator: std.mem.Allocator,
        issues: *std.ArrayList(storage.VerificationIssue),
        node: NodeRecord,
    ) !void {
        const evidence_qid = node.indexed[storage.indexedPropertyIndex("evidenceQid").?] orelse return;
        const evidence = self.recordFor(evidence_qid) orelse return;
        if (!propertyBool(allocator, evidence.properties_json, "deleted")) return;
        if (propertyBool(allocator, node.properties_json, "deleted")) return;
        try appendIssue(allocator, issues, "active_derived_from_deleted_evidence", "active derived node references deleted evidence", node.qid);
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

        const slot_key = try readOptionalString(allocator, node.properties_json, "slotKey");
        defer if (slot_key) |value| allocator.free(value);
        if (slot_key == null) {
            try appendIssue(allocator, issues, "missing_slot_key", "active derived node is missing slotKey", node.qid);
        } else if (!slotAllowedForLabel(node.label, slot_key.?)) {
            try appendIssue(allocator, issues, "slot_label_mismatch", "active derived node slotKey does not match label", node.qid);
        }

        const valid_from = try readOptionalString(allocator, node.properties_json, "validFrom");
        defer if (valid_from) |value| allocator.free(value);
        const valid_to = try readOptionalString(allocator, node.properties_json, "validTo");
        defer if (valid_to) |value| allocator.free(value);
        if (state) |value| {
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
        return std.mem.eql(u8, label, "Fact") or std.mem.eql(u8, label, "Preference") or std.mem.eql(u8, label, "Procedure");
    }

    fn slotAllowedForLabel(label: []const u8, slot_key: []const u8) bool {
        if (std.mem.eql(u8, label, "Fact")) return std.mem.eql(u8, slot_key, "project.package_manager") or
            std.mem.eql(u8, slot_key, "project.repo_style") or
            std.mem.eql(u8, slot_key, "project.constraint") or
            std.mem.startsWith(u8, slot_key, "trip.") or
            std.mem.startsWith(u8, slot_key, "workspace.") or
            std.mem.startsWith(u8, slot_key, "temporal.") or
            std.mem.startsWith(u8, slot_key, "counts.") or
            std.mem.startsWith(u8, slot_key, "abstain.") or
            std.mem.startsWith(u8, slot_key, "assistant.") or
            std.mem.startsWith(u8, slot_key, "alias.") or
            std.mem.startsWith(u8, slot_key, "scope.") or
            std.mem.startsWith(u8, slot_key, "allergy.") or
            std.mem.startsWith(u8, slot_key, "archive.") or
            std.mem.startsWith(u8, slot_key, "release.");
        if (std.mem.eql(u8, label, "Preference")) return std.mem.eql(u8, slot_key, "user.response_style") or
            std.mem.startsWith(u8, slot_key, "pref.") or
            std.mem.startsWith(u8, slot_key, "scope.");
        if (std.mem.eql(u8, label, "Procedure")) return std.mem.eql(u8, slot_key, "project.test_command");
        return false;
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
        .capabilities = capabilities,
        .put_node = putNode,
        .get_node = getNode,
        .put_edge = putEdge,
        .find_edges = findEdges,
        .find_nodes = findNodes,
        .full_text_search = fullTextSearch,
        .embed_text = embedText,
        .prefetch_embeddings = prefetchEmbeddings,
        .clear_prefetched_embeddings = clearPrefetchedEmbeddings,
        .vector_search = vectorSearch,
        .append_stream = appendStream,
        .read_stream = readStream,
        .begin_transaction = beginTransaction,
        .commit_transaction = commitTransaction,
        .rollback_transaction = rollbackTransaction,
        .verify = verify,
    };
};

/// Labels that are never full-text hits: bookkeeping nodes and the
/// Session/Turn containers, which carry no searchable text of their own.
fn isExcludedSearchLabel(label: []const u8) bool {
    const excluded = [_][]const u8{ "Job", "Idempotency", "Schema", "Migration", "Session", "Turn" };
    for (excluded) |name| {
        if (std.mem.eql(u8, label, name)) return true;
    }
    return false;
}

/// Index text is `searchText` ?? `content` ?? `text` ?? `name` from the
/// properties JSON; nodes with `searchable:false` and excluded labels get none.
fn buildIndex(allocator: std.mem.Allocator, label: []const u8, properties_json: []const u8) !IndexedText {
    if (isExcludedSearchLabel(label)) return .{};
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, properties_json, .{}) catch return .{};
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |object| object,
        else => return .{},
    };
    if (object.get("searchable")) |value| {
        switch (value) {
            .bool => |searchable| if (!searchable) return .{},
            else => {},
        }
    }
    const fields = [_][]const u8{ "searchText", "content", "text", "name" };
    for (fields) |field| {
        const value = object.get(field) orelse continue;
        switch (value) {
            .string => |text| return tokenize(allocator, text),
            else => continue,
        }
    }
    return .{};
}

/// Lowercased alphanumeric tokens (non-ASCII bytes stay inside tokens so
/// UTF-8 words are kept whole), minus a small stopword list.
fn tokenize(allocator: std.mem.Allocator, text: []const u8) !IndexedText {
    const buffer = try allocator.alloc(u8, text.len);
    errdefer allocator.free(buffer);
    for (text, 0..) |byte, index| buffer[index] = std.ascii.toLower(byte);

    var terms = std.ArrayList([]const u8).empty;
    errdefer terms.deinit(allocator);
    var start: ?usize = null;
    for (buffer, 0..) |byte, index| {
        if (isTokenByte(byte)) {
            if (start == null) start = index;
            continue;
        }
        if (start) |token_start| {
            try appendTerm(allocator, &terms, buffer[token_start..index]);
            start = null;
        }
    }
    if (start) |token_start| {
        try appendTerm(allocator, &terms, buffer[token_start..]);
    }
    if (terms.items.len == 0) {
        terms.deinit(allocator);
        allocator.free(buffer);
        return .{};
    }
    return .{ .buffer = buffer, .terms = try terms.toOwnedSlice(allocator) };
}

/// Drops stopwords and folds simple plurals ("responses" -> "response").
fn appendTerm(allocator: std.mem.Allocator, terms: *std.ArrayList([]const u8), token: []const u8) !void {
    if (isStopWord(token)) return;
    var term = token;
    if (term.len > 3 and term[term.len - 1] == 's' and term[term.len - 2] != 's') {
        term = term[0 .. term.len - 1];
    }
    try terms.append(allocator, term);
}

fn isTokenByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte >= 0x80;
}

fn uniqueTerms(allocator: std.mem.Allocator, terms: []const []const u8) ![]const []const u8 {
    var unique = std.ArrayList([]const u8).empty;
    errdefer unique.deinit(allocator);
    outer: for (terms) |term| {
        for (unique.items) |existing| {
            if (std.mem.eql(u8, existing, term)) continue :outer;
        }
        try unique.append(allocator, term);
    }
    return unique.toOwnedSlice(allocator);
}

fn isStopWord(token: []const u8) bool {
    const stop_words = [_][]const u8{
        "a",   "an",  "and",  "as",     "at",    "be",    "before", "did",
        "do",  "for", "her",  "his",    "i",     "in",    "is",     "it",
        "of",  "on",  "or",   "should", "that",  "the",   "this",   "to",
        "was", "we",  "what", "when",   "where", "which", "who",    "with",
    };
    for (stop_words) |word| {
        if (std.mem.eql(u8, token, word)) return true;
    }
    return false;
}

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

test "in-memory search indexes text fields, not property keys" {
    var adapter_state = InMemoryAdapter.init(std.testing.allocator);
    defer adapter_state.deinit();
    const adapter = adapter_state.adapter();

    try adapter.putNode(.{
        .qid = "q_msg_1",
        .label = "Message",
        .properties_json = "{\"kind\":\"message\",\"content\":\"Bring the snacks\",\"sessionQid\":\"q_sess_1\"}",
    });
    try adapter.putNode(.{
        .qid = "q_note_1",
        .label = "Observation",
        .properties_json = "{\"searchText\":\"zulu\",\"content\":\"yankee\"}",
    });

    for ([_][]const u8{ "kind", "session", "message", "yankee" }) |text| {
        const hits = try adapter.fullTextSearch(std.testing.allocator, .{ .text = text, .limit = 10 });
        defer freeTestHits(hits);
        try std.testing.expectEqual(@as(usize, 0), hits.len);
    }
    const snack_hits = try adapter.fullTextSearch(std.testing.allocator, .{ .text = "snack", .limit = 10 });
    defer freeTestHits(snack_hits);
    try std.testing.expectEqual(@as(usize, 1), snack_hits.len);
    try std.testing.expectEqualStrings("q_msg_1", snack_hits[0].qid);
    const zulu_hits = try adapter.fullTextSearch(std.testing.allocator, .{ .text = "zulu", .limit = 10 });
    defer freeTestHits(zulu_hits);
    try std.testing.expectEqual(@as(usize, 1), zulu_hits.len);
    try std.testing.expectEqualStrings("q_note_1", zulu_hits[0].qid);
}

test "in-memory BM25 ranks rare and dense matches first and truncates after sorting" {
    var adapter_state = InMemoryAdapter.init(std.testing.allocator);
    defer adapter_state.deinit();
    const adapter = adapter_state.adapter();

    const docs = [_][2][]const u8{
        .{ "q_doc_1", "apple pie recipe from grandma" },
        .{ "q_doc_2", "apple tart" },
        .{ "q_doc_3", "apple juice" },
        .{ "q_doc_4", "zebra crossing near the market" },
        .{ "q_doc_5", "pie" },
    };
    for (docs) |doc| {
        const props = try std.fmt.allocPrint(std.testing.allocator, "{{\"content\":\"{s}\"}}", .{doc[1]});
        defer std.testing.allocator.free(props);
        try adapter.putNode(.{ .qid = doc[0], .label = "Message", .properties_json = props });
    }

    const all = try adapter.fullTextSearch(std.testing.allocator, .{ .text = "apple zebra", .limit = 10 });
    defer freeTestHits(all);
    try std.testing.expectEqual(@as(usize, 4), all.len);
    try std.testing.expectEqualStrings("q_doc_4", all[0].qid);
    for (all[1..], 1..) |hit, index| {
        try std.testing.expect(hit.score <= all[index - 1].score);
    }

    const top = try adapter.fullTextSearch(std.testing.allocator, .{ .text = "apple zebra", .limit = 1 });
    defer freeTestHits(top);
    try std.testing.expectEqual(@as(usize, 1), top.len);
    try std.testing.expectEqualStrings("q_doc_4", top[0].qid);

    const pie = try adapter.fullTextSearch(std.testing.allocator, .{ .text = "pie", .limit = 10 });
    defer freeTestHits(pie);
    try std.testing.expectEqual(@as(usize, 2), pie.len);
    try std.testing.expectEqualStrings("q_doc_5", pie[0].qid);
    try std.testing.expect(pie[0].score > pie[1].score);
}

test "in-memory search skips unsearchable nodes but empty query enumerates them" {
    var adapter_state = InMemoryAdapter.init(std.testing.allocator);
    defer adapter_state.deinit();
    const adapter = adapter_state.adapter();

    try adapter.putNode(.{ .qid = "q_msg_1", .label = "Message", .properties_json = "{\"content\":\"alpha long message\",\"searchable\":false}" });
    try adapter.putNode(.{ .qid = "q_chunk_1_0", .label = "Chunk", .properties_json = "{\"content\":\"alpha chunk\"}" });
    try adapter.putNode(.{ .qid = "q_sess_1", .label = "Session", .properties_json = "{\"content\":\"alpha\"}" });
    try adapter.putNode(.{ .qid = "q_turn_1", .label = "Turn", .properties_json = "{\"text\":\"alpha\"}" });
    try adapter.putNode(.{ .qid = "q_job_1", .label = "Job", .properties_json = "{\"text\":\"alpha\"}" });

    const hits = try adapter.fullTextSearch(std.testing.allocator, .{ .text = "alpha", .limit = 10 });
    defer freeTestHits(hits);
    try std.testing.expectEqual(@as(usize, 1), hits.len);
    try std.testing.expectEqualStrings("q_chunk_1_0", hits[0].qid);

    const all = try adapter.fullTextSearch(std.testing.allocator, .{ .text = "", .limit = 100 });
    defer freeTestHits(all);
    try std.testing.expectEqual(@as(usize, 5), all.len);

    const stop_only = try adapter.fullTextSearch(std.testing.allocator, .{ .text = "what is the", .limit = 10 });
    defer freeTestHits(stop_only);
    try std.testing.expectEqual(@as(usize, 0), stop_only.len);
}

test "in-memory adapter finds nodes by label and property in creation order" {
    var adapter_state = InMemoryAdapter.init(std.testing.allocator);
    defer adapter_state.deinit();
    try storage.expectFindNodesContract(adapter_state.adapter());
}

test "in-memory adapter reports storage capabilities" {
    var adapter_state = InMemoryAdapter.init(std.testing.allocator);
    defer adapter_state.deinit();
    const adapter = adapter_state.adapter();
    const caps = adapter.capabilities();

    try std.testing.expectEqualStrings("memory", caps.backend);
    try std.testing.expect(!caps.durable);
    try std.testing.expect(caps.full_text);
    try std.testing.expect(!caps.vector);
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

test "in-memory verification reports derived slot label mismatch" {
    var adapter_state = InMemoryAdapter.init(std.testing.allocator);
    defer adapter_state.deinit();
    const adapter = adapter_state.adapter();

    try adapter.putNode(.{
        .qid = "q_msg_1",
        .label = "Message",
        .properties_json = "{\"kind\":\"message\",\"content\":\"Please be concise.\",\"deleted\":false}",
    });
    try adapter.putNode(.{
        .qid = "q_fact_1",
        .label = "Fact",
        .properties_json = "{\"kind\":\"fact\",\"text\":\"The user prefers concise responses.\",\"slotKey\":\"user.response_style\",\"value\":\"concise\",\"state\":\"current\",\"validFrom\":\"2026-01-01T00:00:00Z\",\"validTo\":null,\"evidenceQid\":\"q_msg_1\",\"deleted\":false}",
    });

    const issues = try adapter.verify(std.testing.allocator);
    defer freeVerificationIssues(std.testing.allocator, issues);

    try std.testing.expect(hasIssueCode(issues, "slot_label_mismatch"));
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

fn freeTestHits(hits: []const storage.SearchHit) void {
    for (hits) |hit| std.testing.allocator.free(hit.qid);
    std.testing.allocator.free(hits);
}
