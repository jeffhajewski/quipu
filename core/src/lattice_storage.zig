const std = @import("std");
const storage = @import("storage.zig");

const c = @cImport({
    @cInclude("lattice.h");
});

const node_marker = "quipunodeall";
const edge_marker = "quipuedgeall";
const stream_marker = "quipustreamall";
const default_page_size: u32 = 4096;
const default_vector_dimensions: u16 = 128;
const default_embedding_model = "lattice_hash_embed";
const default_openrouter_embedding_url = "https://openrouter.ai/api/v1/embeddings";
const default_openrouter_embedding_model = "openai/text-embedding-3-small";

pub const EmbeddingProviderKind = enum {
    hash,
    openai_compatible,
};

pub const Options = struct {
    io: std.Io,
    page_size: u32 = default_page_size,
    vector_dimensions: u16 = default_vector_dimensions,
    embedding_provider: EmbeddingProviderKind = .hash,
    embedding_url: []const u8 = default_openrouter_embedding_url,
    embedding_model: []const u8 = default_embedding_model,
    embedding_api_key: ?[]const u8 = null,
    embedding_request_dimensions: bool = false,
};

const NodeIndex = struct {
    node_id: u64,
    label: []u8,

    fn deinit(self: NodeIndex, allocator: std.mem.Allocator) void {
        allocator.free(self.label);
    }
};

const LatticeHit = struct {
    node_id: u64,
    score: f32,
};

pub const LatticeAdapter = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    db: ?*c.lattice_database,
    path: []u8,
    qid_to_node: std.StringHashMap(NodeIndex),
    page_size: u32,
    vector_dimensions: u16,
    embedding_provider: EmbeddingProviderKind,
    embedding_url: [:0]u8,
    embedding_model: [:0]u8,
    embedding_api_key: ?[:0]u8,
    embedding_request_dimensions: bool,
    next_tx_id: u64 = 1,
    next_sequence: u64 = 1,
    next_runtime_id: u64 = 1,

    pub fn open(allocator: std.mem.Allocator, path: []const u8, options: Options) !LatticeAdapter {
        const owned_path = try allocator.dupe(u8, path);
        var owned_path_transferred = false;
        errdefer if (!owned_path_transferred) allocator.free(owned_path);
        const owned_embedding_url = try allocator.dupeZ(u8, options.embedding_url);
        var owned_embedding_url_transferred = false;
        errdefer if (!owned_embedding_url_transferred) allocator.free(owned_embedding_url);
        const owned_embedding_model = try allocator.dupeZ(u8, options.embedding_model);
        var owned_embedding_model_transferred = false;
        errdefer if (!owned_embedding_model_transferred) allocator.free(owned_embedding_model);
        const owned_embedding_api_key = if (options.embedding_api_key) |api_key| try allocator.dupeZ(u8, api_key) else null;
        var owned_embedding_api_key_transferred = false;
        errdefer if (!owned_embedding_api_key_transferred) if (owned_embedding_api_key) |api_key| allocator.free(api_key);

        const path_z = try allocator.dupeZ(u8, path);
        defer allocator.free(path_z);

        var opts = c.lattice_open_options{
            .create = true,
            .read_only = false,
            .cache_size_mb = 100,
            .page_size = options.page_size,
            .enable_vector = true,
            .vector_dimensions = options.vector_dimensions,
        };
        var db: ?*c.lattice_database = null;
        try check(c.lattice_open(path_z.ptr, &opts, &db));

        var self = LatticeAdapter{
            .allocator = allocator,
            .io = options.io,
            .db = db,
            .path = owned_path,
            .qid_to_node = std.StringHashMap(NodeIndex).init(allocator),
            .page_size = options.page_size,
            .vector_dimensions = options.vector_dimensions,
            .embedding_provider = options.embedding_provider,
            .embedding_url = owned_embedding_url,
            .embedding_model = owned_embedding_model,
            .embedding_api_key = owned_embedding_api_key,
            .embedding_request_dimensions = options.embedding_request_dimensions,
        };
        owned_path_transferred = true;
        owned_embedding_url_transferred = true;
        owned_embedding_model_transferred = true;
        owned_embedding_api_key_transferred = true;
        errdefer self.deinit();
        try self.loadIndexes();
        return self;
    }

    pub fn deinit(self: *LatticeAdapter) void {
        var it = self.qid_to_node.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.qid_to_node.deinit();
        if (self.db) |db| {
            _ = c.lattice_close(db);
            self.db = null;
        }
        self.allocator.free(self.path);
        self.allocator.free(self.embedding_url);
        self.allocator.free(self.embedding_model);
        if (self.embedding_api_key) |api_key| self.allocator.free(api_key);
    }

    pub fn adapter(self: *LatticeAdapter) storage.Adapter {
        return .{
            .context = self,
            .vtable = &vtable,
        };
    }

    pub fn latticeVersion() []const u8 {
        const version = c.lattice_version();
        if (version == null) return "unknown";
        return std.mem.span(version);
    }

    pub fn nextRuntimeId(self: *const LatticeAdapter) u64 {
        return @max(self.next_runtime_id, 1);
    }

    fn capabilities(context: *anyopaque) storage.Capabilities {
        const self = ctx(context);
        return .{
            .backend = "lattice",
            .durable = true,
            .full_text = true,
            .vector = true,
            .streams = true,
            .transactions = true,
            .verification = true,
            .vector_dimensions = self.vector_dimensions,
            .embedding_model = self.embedding_model,
        };
    }

    fn loadIndexes(self: *LatticeAdapter) !void {
        const hits = try self.searchNodeIds(self.allocator, node_marker, 1_000_000);
        defer self.allocator.free(hits);

        const tx = try self.beginRead();
        defer self.rollbackQuiet(tx);
        for (hits) |hit| {
            const qid = (try self.readStringPropertyInTxn(self.allocator, tx, hit.node_id, "qid")) orelse continue;
            defer self.allocator.free(qid);
            const label = (try self.readStringPropertyInTxn(self.allocator, tx, hit.node_id, "quipuLabel")) orelse continue;
            defer self.allocator.free(label);
            try self.indexNode(qid, hit.node_id, label);
            self.trackRuntimeId(qid);
        }

        const stream_hits = try self.searchNodeIds(self.allocator, stream_marker, 1_000_000);
        defer self.allocator.free(stream_hits);
        for (stream_hits) |hit| {
            if (try self.readIntPropertyInTxn(tx, hit.node_id, "sequence")) |sequence| {
                self.next_sequence = @max(self.next_sequence, @as(u64, @intCast(sequence + 1)));
            }
        }

        const edge_hits = try self.searchNodeIds(self.allocator, edge_marker, 1_000_000);
        defer self.allocator.free(edge_hits);
        for (edge_hits) |hit| {
            const qid = (try self.readStringPropertyInTxn(self.allocator, tx, hit.node_id, "qid")) orelse continue;
            defer self.allocator.free(qid);
            self.trackRuntimeId(qid);
        }
    }

    fn putNode(context: *anyopaque, node: storage.Node) !void {
        const self = ctx(context);
        const tx = try self.beginWrite();
        errdefer self.rollbackQuiet(tx);

        const node_id = if (self.qid_to_node.get(node.qid)) |entry|
            entry.node_id
        else blk: {
            const label_z = try self.allocator.dupeZ(u8, node.label);
            defer self.allocator.free(label_z);
            var created: c.lattice_node_id = 0;
            try check(c.lattice_node_create(tx, label_z.ptr, &created));
            break :blk @as(u64, @intCast(created));
        };

        try self.setStringProperty(tx, node_id, "qid", node.qid);
        try self.setStringProperty(tx, node_id, "quipuLabel", node.label);
        try self.setStringProperty(tx, node_id, "propertiesJson", node.properties_json);
        try self.setStringProperty(tx, node_id, "recordKind", "node");

        const searchable_properties = if (isInternalLabel(node.label)) "" else node.properties_json;
        const index_text = try self.indexText(self.allocator, node_marker, node.qid, node.label, searchable_properties);
        defer self.allocator.free(index_text);
        try check(c.lattice_fts_index(tx, @intCast(node_id), index_text.ptr, index_text.len));
        if (!isInternalLabel(node.label)) {
            try self.setNodeVector(tx, node_id, index_text);
        }
        try check(c.lattice_commit(tx));

        try self.indexNode(node.qid, node_id, node.label);
        self.trackRuntimeId(node.qid);
    }

    fn getNode(context: *anyopaque, allocator: std.mem.Allocator, qid: []const u8) !?storage.Node {
        const self = ctx(context);
        const index = self.qid_to_node.get(qid) orelse return null;
        const tx = try self.beginRead();
        defer self.rollbackQuiet(tx);

        const label = (try self.readStringPropertyInTxn(allocator, tx, index.node_id, "quipuLabel")) orelse return null;
        errdefer allocator.free(label);
        const properties_json = (try self.readStringPropertyInTxn(allocator, tx, index.node_id, "propertiesJson")) orelse {
            allocator.free(label);
            return null;
        };
        errdefer allocator.free(properties_json);
        return .{
            .qid = try allocator.dupe(u8, qid),
            .label = label,
            .properties_json = properties_json,
        };
    }

    fn putEdge(context: *anyopaque, edge: storage.Edge) !void {
        const self = ctx(context);
        const tx = try self.beginWrite();
        errdefer self.rollbackQuiet(tx);

        const from = self.qid_to_node.get(edge.from_qid);
        const to = self.qid_to_node.get(edge.to_qid);
        if (from != null and to != null) {
            const edge_type_z = try self.allocator.dupeZ(u8, edge.edge_type);
            defer self.allocator.free(edge_type_z);
            var edge_id: c.lattice_edge_id = 0;
            try check(c.lattice_edge_create(tx, @intCast(from.?.node_id), @intCast(to.?.node_id), edge_type_z.ptr, &edge_id));
            try self.setEdgeStringProperty(tx, @intCast(edge_id), "qid", edge.qid);
            try self.setEdgeStringProperty(tx, @intCast(edge_id), "propertiesJson", edge.properties_json);
        }

        try self.createEdgeRecord(tx, edge);
        try check(c.lattice_commit(tx));
        self.trackRuntimeId(edge.qid);
    }

    fn fullTextSearch(context: *anyopaque, allocator: std.mem.Allocator, query: storage.FullTextQuery) ![]storage.SearchHit {
        const self = ctx(context);
        const lattice_hits = if (query.text.len == 0)
            try self.searchNodeIds(allocator, node_marker, query.limit)
        else
            try self.searchQueryNodeIds(allocator, query.text, query.limit);
        defer allocator.free(lattice_hits);

        var hits = std.ArrayList(storage.SearchHit).empty;
        errdefer {
            for (hits.items) |hit| allocator.free(hit.qid);
            hits.deinit(allocator);
        }

        const tx = try self.beginRead();
        defer self.rollbackQuiet(tx);
        for (lattice_hits) |hit| {
            const qid = (try self.readStringPropertyInTxn(allocator, tx, hit.node_id, "qid")) orelse continue;
            errdefer allocator.free(qid);
            if (!self.qid_to_node.contains(qid)) {
                allocator.free(qid);
                continue;
            }
            if (indexOfQid(hits.items, qid)) |index| {
                hits.items[index].score += hit.score;
                allocator.free(qid);
                continue;
            }
            try hits.append(allocator, .{ .qid = qid, .score = hit.score });
        }
        return hits.toOwnedSlice(allocator);
    }

    fn vectorSearch(context: *anyopaque, allocator: std.mem.Allocator, query: storage.VectorQuery) ![]storage.SearchHit {
        const self = ctx(context);
        if (query.vector.len == 0) return allocator.alloc(storage.SearchHit, 0);

        var result: ?*c.lattice_vector_result = null;
        try check(c.lattice_vector_search(self.db, query.vector.ptr, @intCast(query.vector.len), @intCast(query.limit), 0, &result));
        defer if (result) |ptr| c.lattice_vector_result_free(ptr);

        const count = c.lattice_vector_result_count(result);
        var hits = std.ArrayList(storage.SearchHit).empty;
        errdefer {
            for (hits.items) |hit| allocator.free(hit.qid);
            hits.deinit(allocator);
        }

        const tx = try self.beginRead();
        defer self.rollbackQuiet(tx);
        var index: u32 = 0;
        while (index < count) : (index += 1) {
            var node_id: c.lattice_node_id = 0;
            var distance: f32 = 0;
            try check(c.lattice_vector_result_get(result, index, &node_id, &distance));
            const qid = (try self.readStringPropertyInTxn(allocator, tx, @intCast(node_id), "qid")) orelse continue;
            if (!self.qid_to_node.contains(qid)) {
                allocator.free(qid);
                continue;
            }
            try hits.append(allocator, .{ .qid = qid, .score = 1.0 / (1.0 + distance) });
        }
        return hits.toOwnedSlice(allocator);
    }

    fn embedText(context: *anyopaque, allocator: std.mem.Allocator, text: []const u8) ![]f32 {
        const self = ctx(context);
        return self.embed(allocator, text);
    }

    fn appendStream(context: *anyopaque, stream: []const u8, payload_json: []const u8) !storage.StreamEntry {
        const self = ctx(context);
        const tx = try self.beginWrite();
        errdefer self.rollbackQuiet(tx);
        var payload = stringValue(payload_json);
        try check(c.lattice_stream_publish(tx, stream.ptr, stream.len, "message", "message".len, &payload));
        try check(c.lattice_commit(tx));

        const sequence = try self.latestStreamSequence(stream);
        return .{ .stream = stream, .sequence = sequence, .payload_json = payload_json };
    }

    fn readStream(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        stream: []const u8,
        after_sequence: u64,
        limit: usize,
    ) ![]storage.StreamEntry {
        const self = ctx(context);
        return self.readNativeStream(allocator, stream, after_sequence, limit);
    }

    fn readNativeStream(
        self: *LatticeAdapter,
        allocator: std.mem.Allocator,
        stream: []const u8,
        after_sequence: u64,
        limit: usize,
    ) ![]storage.StreamEntry {
        if (limit == 0) return allocator.alloc(storage.StreamEntry, 0);
        var batch: ?*c.lattice_stream_batch = null;
        try check(c.lattice_stream_read(self.db, stream.ptr, stream.len, after_sequence, limit, 0, &batch));
        defer if (batch) |ptr| c.lattice_stream_batch_free(ptr);

        const ptr = batch orelse return allocator.alloc(storage.StreamEntry, 0);
        const count = c.lattice_stream_batch_count(ptr);
        var entries = std.ArrayList(storage.StreamEntry).empty;
        errdefer {
            for (entries.items) |entry| {
                allocator.free(entry.stream);
                allocator.free(entry.payload_json);
            }
            entries.deinit(allocator);
        }

        var index: usize = 0;
        while (index < count) : (index += 1) {
            var sequence: u64 = 0;
            var kind_ptr: [*c]const u8 = null;
            var kind_len: usize = 0;
            var payload_value: ?*const c.lattice_value = null;
            try check(c.lattice_stream_batch_get(ptr, index, &sequence, &kind_ptr, &kind_len, &payload_value));
            const value = payload_value orelse continue;
            if (value.type != c.LATTICE_VALUE_STRING) return error.InvalidLatticeValue;
            const string = value.data.string_val;
            if (string.len > 0 and string.ptr == null) return error.InvalidLatticeValue;
            const payload = if (string.len == 0)
                try allocator.dupe(u8, "")
            else
                try allocator.dupe(u8, string.ptr[0..string.len]);
            errdefer allocator.free(payload);
            try entries.append(allocator, .{
                .stream = try allocator.dupe(u8, stream),
                .sequence = sequence,
                .payload_json = payload,
            });
        }
        return entries.toOwnedSlice(allocator);
    }

    fn latestStreamSequence(self: *LatticeAdapter, stream: []const u8) !u64 {
        const entries = try self.readNativeStream(self.allocator, stream, 0, 1_000_000);
        defer freeStreamEntries(self.allocator, entries);
        var sequence: u64 = 0;
        for (entries) |entry| {
            sequence = @max(sequence, entry.sequence);
        }
        if (sequence == 0) return error.NotFound;
        return sequence;
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

        const tx = try self.beginRead();
        defer self.rollbackQuiet(tx);

        const edge_hits = try self.searchNodeIds(allocator, edge_marker, 1_000_000);
        defer allocator.free(edge_hits);
        for (edge_hits) |hit| {
            const edge_qid = (try self.readStringPropertyInTxn(allocator, tx, hit.node_id, "qid")) orelse continue;
            defer allocator.free(edge_qid);
            const from_qid = (try self.readStringPropertyInTxn(allocator, tx, hit.node_id, "fromQid")) orelse continue;
            defer allocator.free(from_qid);
            const to_qid = (try self.readStringPropertyInTxn(allocator, tx, hit.node_id, "toQid")) orelse continue;
            defer allocator.free(to_qid);
            if (!self.qid_to_node.contains(from_qid)) {
                try appendIssue(allocator, &issues, "missing_edge_source", "edge source node is missing", edge_qid);
            }
            if (!self.qid_to_node.contains(to_qid)) {
                try appendIssue(allocator, &issues, "missing_edge_target", "edge target node is missing", edge_qid);
            }
        }

        const node_hits = try self.searchNodeIds(allocator, node_marker, 1_000_000);
        defer allocator.free(node_hits);
        for (node_hits) |hit| {
            const qid = (try self.readStringPropertyInTxn(allocator, tx, hit.node_id, "qid")) orelse continue;
            defer allocator.free(qid);
            const label = (try self.readStringPropertyInTxn(allocator, tx, hit.node_id, "quipuLabel")) orelse continue;
            defer allocator.free(label);
            const properties_json = (try self.readStringPropertyInTxn(allocator, tx, hit.node_id, "propertiesJson")) orelse continue;
            defer allocator.free(properties_json);
            if (isDerivedLabel(label)) {
                try verifyDerivedNode(self, allocator, &issues, qid, label, properties_json);
            }
            if (propertyBool(allocator, properties_json, "deleted")) {
                try verifyDeletedEvidenceClosure(self, allocator, &issues, qid, node_hits, tx);
            }
        }

        return issues.toOwnedSlice(allocator);
    }

    fn createEdgeRecord(self: *LatticeAdapter, tx: *c.lattice_txn, edge: storage.Edge) !void {
        const label_z = try self.allocator.dupeZ(u8, "QuipuEdgeRecord");
        defer self.allocator.free(label_z);
        var node_id: c.lattice_node_id = 0;
        try check(c.lattice_node_create(tx, label_z.ptr, &node_id));
        try self.setStringProperty(tx, @intCast(node_id), "recordKind", "edge");
        try self.setStringProperty(tx, @intCast(node_id), "qid", edge.qid);
        try self.setStringProperty(tx, @intCast(node_id), "fromQid", edge.from_qid);
        try self.setStringProperty(tx, @intCast(node_id), "toQid", edge.to_qid);
        try self.setStringProperty(tx, @intCast(node_id), "edgeType", edge.edge_type);
        try self.setStringProperty(tx, @intCast(node_id), "propertiesJson", edge.properties_json);
        const index_text = try self.indexText(self.allocator, edge_marker, edge.qid, edge.edge_type, edge.properties_json);
        defer self.allocator.free(index_text);
        try check(c.lattice_fts_index(tx, node_id, index_text.ptr, index_text.len));
    }

    fn indexNode(self: *LatticeAdapter, qid: []const u8, node_id: u64, label: []const u8) !void {
        const key = try self.allocator.dupe(u8, qid);
        errdefer self.allocator.free(key);
        const label_copy = try self.allocator.dupe(u8, label);
        errdefer self.allocator.free(label_copy);

        const entry = try self.qid_to_node.getOrPut(key);
        if (entry.found_existing) {
            self.allocator.free(key);
            entry.value_ptr.deinit(self.allocator);
        }
        entry.value_ptr.* = .{ .node_id = node_id, .label = label_copy };
    }

    fn trackRuntimeId(self: *LatticeAdapter, qid: []const u8) void {
        var last_underscore: ?usize = null;
        for (qid, 0..) |byte, index| {
            if (byte == '_') last_underscore = index;
        }
        const start = (last_underscore orelse return) + 1;
        if (start >= qid.len) return;
        const parsed = std.fmt.parseInt(u64, qid[start..], 10) catch return;
        self.next_runtime_id = @max(self.next_runtime_id, parsed + 1);
    }

    fn beginRead(self: *LatticeAdapter) !*c.lattice_txn {
        var tx: ?*c.lattice_txn = null;
        try check(c.lattice_begin(self.db, c.LATTICE_TXN_READ_ONLY, &tx));
        return tx.?;
    }

    fn beginWrite(self: *LatticeAdapter) !*c.lattice_txn {
        var tx: ?*c.lattice_txn = null;
        try check(c.lattice_begin(self.db, c.LATTICE_TXN_READ_WRITE, &tx));
        return tx.?;
    }

    fn rollbackQuiet(_: *LatticeAdapter, tx: *c.lattice_txn) void {
        _ = c.lattice_rollback(tx);
    }

    fn searchNodeIds(self: *LatticeAdapter, allocator: std.mem.Allocator, text: []const u8, limit: usize) ![]LatticeHit {
        if (limit == 0) return allocator.alloc(LatticeHit, 0);
        const text_z = try allocator.dupeZ(u8, text);
        defer allocator.free(text_z);

        var result: ?*c.lattice_fts_result = null;
        try check(c.lattice_fts_search(self.db, text_z.ptr, text.len, @intCast(limit), &result));
        defer if (result) |ptr| c.lattice_fts_result_free(ptr);

        const count = c.lattice_fts_result_count(result);
        var hits = try allocator.alloc(LatticeHit, count);
        errdefer allocator.free(hits);

        var index: u32 = 0;
        while (index < count) : (index += 1) {
            var node_id: c.lattice_node_id = 0;
            var score: f32 = 0;
            try check(c.lattice_fts_result_get(result, index, &node_id, &score));
            hits[index] = .{ .node_id = @intCast(node_id), .score = score };
        }
        return hits;
    }

    fn searchQueryNodeIds(self: *LatticeAdapter, allocator: std.mem.Allocator, text: []const u8, limit: usize) ![]LatticeHit {
        const direct = try self.searchNodeIds(allocator, text, limit);
        var aggregate = std.ArrayList(LatticeHit).empty;
        errdefer aggregate.deinit(allocator);
        for (direct) |hit| {
            try aggregate.append(allocator, hit);
        }
        allocator.free(direct);

        var tokens = std.mem.tokenizeAny(u8, text, " \t\r\n.,?!:;\"'()[]{}<>/\\|");
        while (tokens.next()) |token| {
            if (token.len < 2) continue;
            try self.addTokenHits(allocator, &aggregate, token, limit);
            if (token[token.len - 1] != 's') {
                const plural = try std.fmt.allocPrint(allocator, "{s}s", .{token});
                defer allocator.free(plural);
                try self.addTokenHits(allocator, &aggregate, plural, limit);
            }
        }

        if (aggregate.items.len > limit) {
            aggregate.shrinkRetainingCapacity(limit);
        }
        return aggregate.toOwnedSlice(allocator);
    }

    fn addTokenHits(
        self: *LatticeAdapter,
        allocator: std.mem.Allocator,
        aggregate: *std.ArrayList(LatticeHit),
        token: []const u8,
        limit: usize,
    ) !void {
        const token_hits = try self.searchNodeIds(allocator, token, limit);
        defer allocator.free(token_hits);
        for (token_hits) |hit| {
            if (indexOfNodeId(aggregate.items, hit.node_id)) |index| {
                aggregate.items[index].score += @max(hit.score, 1.0);
            } else {
                try aggregate.append(allocator, .{ .node_id = hit.node_id, .score = @max(hit.score, 1.0) });
            }
        }
    }

    fn setStringProperty(self: *LatticeAdapter, tx: *c.lattice_txn, node_id: u64, key: [*:0]const u8, value: []const u8) !void {
        _ = self;
        var property = stringValue(value);
        try check(c.lattice_node_set_property(tx, @intCast(node_id), key, &property));
    }

    fn setIntProperty(self: *LatticeAdapter, tx: *c.lattice_txn, node_id: u64, key: [*:0]const u8, value: i64) !void {
        _ = self;
        var property = intValue(value);
        try check(c.lattice_node_set_property(tx, @intCast(node_id), key, &property));
    }

    fn setEdgeStringProperty(self: *LatticeAdapter, tx: *c.lattice_txn, edge_id: u64, key: [*:0]const u8, value: []const u8) !void {
        _ = self;
        var property = stringValue(value);
        try check(c.lattice_edge_set_property(tx, @intCast(edge_id), key, &property));
    }

    fn setNodeVector(self: *LatticeAdapter, tx: *c.lattice_txn, node_id: u64, text: []const u8) !void {
        const vector = try self.embed(self.allocator, text);
        defer self.allocator.free(vector);
        if (vector.len == 0) return;
        try check(c.lattice_node_set_vector(tx, @intCast(node_id), "embedding", vector.ptr, @intCast(vector.len)));
    }

    fn embed(self: *LatticeAdapter, allocator: std.mem.Allocator, text: []const u8) ![]f32 {
        return switch (self.embedding_provider) {
            .hash => hashEmbed(allocator, text, self.vector_dimensions),
            .openai_compatible => try self.openAiCompatibleEmbed(allocator, text),
        };
    }

    fn openAiCompatibleEmbed(self: *LatticeAdapter, allocator: std.mem.Allocator, text: []const u8) ![]f32 {
        const request_body = if (self.embedding_request_dimensions)
            try stringifyAlloc(allocator, .{
                .model = self.embedding_model,
                .input = text,
                .dimensions = self.vector_dimensions,
            })
        else
            try stringifyAlloc(allocator, .{
                .model = self.embedding_model,
                .input = text,
            });
        defer allocator.free(request_body);

        const authorization = if (self.embedding_api_key) |api_key|
            try std.fmt.allocPrint(allocator, "Bearer {s}", .{api_key})
        else
            null;
        defer if (authorization) |value| allocator.free(value);

        var client = std.http.Client{ .allocator = allocator, .io = self.io };
        defer client.deinit();
        var response_body: std.Io.Writer.Allocating = .init(allocator);
        defer response_body.deinit();
        const result = try client.fetch(.{
            .location = .{ .url = self.embedding_url },
            .method = .POST,
            .payload = request_body,
            .response_writer = &response_body.writer,
            .headers = .{
                .authorization = if (authorization) |value| .{ .override = value } else .omit,
                .content_type = .{ .override = "application/json" },
                .user_agent = .{ .override = "quipu/0.1.0" },
            },
        });
        if (result.status.class() != .success) return error.EmbeddingProviderRequestFailed;
        const response = try response_body.toOwnedSlice();
        defer allocator.free(response);
        return parseEmbeddingResponse(allocator, response, self.vector_dimensions);
    }

    fn readStringPropertyInTxn(
        self: *LatticeAdapter,
        allocator: std.mem.Allocator,
        tx: *c.lattice_txn,
        node_id: u64,
        key: [*:0]const u8,
    ) !?[]u8 {
        _ = self;
        var value: c.lattice_value = std.mem.zeroes(c.lattice_value);
        const rc = c.lattice_node_get_property(tx, @intCast(node_id), key, &value);
        if (rc == c.LATTICE_ERROR_NOT_FOUND) return null;
        try check(rc);
        defer c.lattice_value_free(&value);
        if (value.type != c.LATTICE_VALUE_STRING) return error.InvalidLatticeValue;
        const string = value.data.string_val;
        if (string.len == 0) return try allocator.dupe(u8, "");
        if (string.ptr == null) return error.InvalidLatticeValue;
        return try allocator.dupe(u8, string.ptr[0..string.len]);
    }

    fn readIntPropertyInTxn(self: *LatticeAdapter, tx: *c.lattice_txn, node_id: u64, key: [*:0]const u8) !?i64 {
        _ = self;
        var value: c.lattice_value = std.mem.zeroes(c.lattice_value);
        const rc = c.lattice_node_get_property(tx, @intCast(node_id), key, &value);
        if (rc == c.LATTICE_ERROR_NOT_FOUND) return null;
        try check(rc);
        defer c.lattice_value_free(&value);
        if (value.type != c.LATTICE_VALUE_INT) return error.InvalidLatticeValue;
        return value.data.int_val;
    }

    fn indexText(
        self: *LatticeAdapter,
        allocator: std.mem.Allocator,
        marker: []const u8,
        first: []const u8,
        second: []const u8,
        third: []const u8,
    ) ![]u8 {
        _ = self;
        return std.fmt.allocPrint(allocator, "{s} {s} {s} {s}", .{ marker, first, second, third });
    }

    fn verifyDerivedNode(
        self: *LatticeAdapter,
        allocator: std.mem.Allocator,
        issues: *std.ArrayList(storage.VerificationIssue),
        qid: []const u8,
        label: []const u8,
        properties_json: []const u8,
    ) !void {
        if (propertyBool(allocator, properties_json, "deleted")) return;

        const state = try readOptionalString(allocator, properties_json, "state");
        defer if (state) |value| allocator.free(value);
        if (state == null or (!std.mem.eql(u8, state.?, "current") and !std.mem.eql(u8, state.?, "superseded") and !std.mem.eql(u8, state.?, "historical"))) {
            try appendIssue(allocator, issues, "invalid_derived_state", "active derived node has invalid state", qid);
        }

        const slot_key = try readOptionalString(allocator, properties_json, "slotKey");
        defer if (slot_key) |value| allocator.free(value);
        if (slot_key == null) {
            try appendIssue(allocator, issues, "missing_slot_key", "active derived node is missing slotKey", qid);
        } else if (!slotAllowedForLabel(label, slot_key.?)) {
            try appendIssue(allocator, issues, "slot_label_mismatch", "active derived node slotKey does not match label", qid);
        }

        const valid_from = try readOptionalString(allocator, properties_json, "validFrom");
        defer if (valid_from) |value| allocator.free(value);
        const valid_to = try readOptionalString(allocator, properties_json, "validTo");
        defer if (valid_to) |value| allocator.free(value);
        if (state) |value| {
            if (std.mem.eql(u8, value, "current") and valid_to != null) {
                try appendIssue(allocator, issues, "current_derived_has_valid_to", "current derived node must not have validTo", qid);
            }
            if (std.mem.eql(u8, value, "superseded") and valid_to == null) {
                try appendIssue(allocator, issues, "superseded_derived_missing_valid_to", "superseded derived node must have validTo", qid);
            }
        }
        if (valid_from != null and valid_to != null and std.mem.order(u8, valid_to.?, valid_from.?) == .lt) {
            try appendIssue(allocator, issues, "invalid_temporal_window", "derived node validTo is before validFrom", qid);
        }

        const evidence_qid = try readOptionalString(allocator, properties_json, "evidenceQid");
        defer if (evidence_qid) |value| allocator.free(value);
        if (evidence_qid == null) {
            try appendIssue(allocator, issues, "missing_evidence_qid", "active derived node is missing evidenceQid", qid);
            return;
        }
        if (!self.qid_to_node.contains(evidence_qid.?)) {
            try appendIssue(allocator, issues, "missing_evidence_node", "active derived node references missing evidence", qid);
        }
    }

    fn verifyDeletedEvidenceClosure(
        self: *LatticeAdapter,
        allocator: std.mem.Allocator,
        issues: *std.ArrayList(storage.VerificationIssue),
        evidence_qid: []const u8,
        node_hits: []const LatticeHit,
        tx: *c.lattice_txn,
    ) !void {
        for (node_hits) |hit| {
            const qid = (try self.readStringPropertyInTxn(allocator, tx, hit.node_id, "qid")) orelse continue;
            defer allocator.free(qid);
            const label = (try self.readStringPropertyInTxn(allocator, tx, hit.node_id, "quipuLabel")) orelse continue;
            defer allocator.free(label);
            if (!isDerivedLabel(label)) continue;
            const properties_json = (try self.readStringPropertyInTxn(allocator, tx, hit.node_id, "propertiesJson")) orelse continue;
            defer allocator.free(properties_json);
            if (propertyBool(allocator, properties_json, "deleted")) continue;
            const evidence = try readOptionalString(allocator, properties_json, "evidenceQid");
            defer if (evidence) |value| allocator.free(value);
            if (evidence) |derived_evidence_qid| {
                if (std.mem.eql(u8, derived_evidence_qid, evidence_qid)) {
                    try appendIssue(allocator, issues, "active_derived_from_deleted_evidence", "active derived node references deleted evidence", qid);
                }
            }
        }
    }

    fn ctx(context: *anyopaque) *LatticeAdapter {
        return @ptrCast(@alignCast(context));
    }

    const vtable = storage.Adapter.VTable{
        .capabilities = capabilities,
        .put_node = putNode,
        .get_node = getNode,
        .put_edge = putEdge,
        .full_text_search = fullTextSearch,
        .embed_text = embedText,
        .vector_search = vectorSearch,
        .append_stream = appendStream,
        .read_stream = readStream,
        .begin_transaction = beginTransaction,
        .commit_transaction = commitTransaction,
        .rollback_transaction = rollbackTransaction,
        .verify = verify,
    };
};

fn hashEmbed(allocator: std.mem.Allocator, text: []const u8, dimensions: u16) ![]f32 {
    var vector_ptr: [*c]f32 = null;
    var dims: u32 = 0;
    try check(c.lattice_hash_embed(text.ptr, text.len, dimensions, &vector_ptr, &dims));
    defer if (vector_ptr != null) c.lattice_hash_embed_free(vector_ptr, dims);
    if (vector_ptr == null or dims == 0) return allocator.alloc(f32, 0);
    return try allocator.dupe(f32, vector_ptr[0..dims]);
}

fn parseEmbeddingResponse(allocator: std.mem.Allocator, response: []const u8, expected_dimensions: u16) ![]f32 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response, .{});
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |object| object,
        else => return error.InvalidEmbeddingResponse,
    };
    const data_value = root.get("data") orelse return error.InvalidEmbeddingResponse;
    const data = switch (data_value) {
        .array => |array| array,
        else => return error.InvalidEmbeddingResponse,
    };
    if (data.items.len == 0) return error.InvalidEmbeddingResponse;
    const first = switch (data.items[0]) {
        .object => |object| object,
        else => return error.InvalidEmbeddingResponse,
    };
    const embedding_value = first.get("embedding") orelse return error.InvalidEmbeddingResponse;
    const embedding = switch (embedding_value) {
        .array => |array| array,
        else => return error.InvalidEmbeddingResponse,
    };
    if (embedding.items.len != expected_dimensions) return error.InvalidEmbeddingDimensions;
    const vector = try allocator.alloc(f32, embedding.items.len);
    errdefer allocator.free(vector);
    for (embedding.items, 0..) |value, index| {
        vector[index] = switch (value) {
            .float => |float| @floatCast(float),
            .integer => |integer| @floatFromInt(integer),
            else => return error.InvalidEmbeddingResponse,
        };
    }
    return vector;
}

fn stringifyAlloc(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    try std.json.Stringify.value(value, .{}, &writer.writer);
    return writer.toOwnedSlice();
}

test "lattice adapter persists stream records" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/stream.lattice", .{tmp.sub_path[0..]});
    defer std.testing.allocator.free(db_path);

    {
        var adapter_state = try LatticeAdapter.open(std.testing.allocator, db_path, .{ .io = std.testing.io });
        defer adapter_state.deinit();
        const adapter = adapter_state.adapter();
        const entry = try adapter.appendStream("quipu.audit", "{\"method\":\"test\"}");
        try std.testing.expectEqual(@as(u64, 1), entry.sequence);
    }

    {
        var adapter_state = try LatticeAdapter.open(std.testing.allocator, db_path, .{ .io = std.testing.io });
        defer adapter_state.deinit();
        const adapter = adapter_state.adapter();
        const entries = try adapter.readStream(std.testing.allocator, "quipu.audit", 0, 10);
        defer freeStreamEntries(std.testing.allocator, entries);

        try std.testing.expectEqual(@as(usize, 1), entries.len);
        try std.testing.expectEqual(@as(u64, 1), entries[0].sequence);
        try std.testing.expectEqualStrings("quipu.audit", entries[0].stream);
        try std.testing.expectEqualStrings("{\"method\":\"test\"}", entries[0].payload_json);
    }
}

fn stringValue(value: []const u8) c.lattice_value {
    return .{
        .type = c.LATTICE_VALUE_STRING,
        .data = .{ .string_val = .{ .ptr = value.ptr, .len = value.len } },
    };
}

fn intValue(value: i64) c.lattice_value {
    return .{
        .type = c.LATTICE_VALUE_INT,
        .data = .{ .int_val = value },
    };
}

fn indexOfNodeId(hits: []const LatticeHit, node_id: u64) ?usize {
    for (hits, 0..) |hit, index| {
        if (hit.node_id == node_id) return index;
    }
    return null;
}

fn indexOfQid(hits: []const storage.SearchHit, qid: []const u8) ?usize {
    for (hits, 0..) |hit, index| {
        if (std.mem.eql(u8, hit.qid, qid)) return index;
    }
    return null;
}

fn check(rc: c.lattice_error) !void {
    if (rc == c.LATTICE_OK) return;
    return switch (rc) {
        c.LATTICE_ERROR => error.LatticeFailure,
        c.LATTICE_ERROR_IO => error.LatticeIo,
        c.LATTICE_ERROR_CORRUPTION => error.LatticeCorruption,
        c.LATTICE_ERROR_NOT_FOUND => error.NotFound,
        c.LATTICE_ERROR_ALREADY_EXISTS => error.AlreadyExists,
        c.LATTICE_ERROR_INVALID_ARG => error.InvalidRequest,
        c.LATTICE_ERROR_TXN_ABORTED => error.TransactionAborted,
        c.LATTICE_ERROR_LOCK_TIMEOUT => error.LockTimeout,
        c.LATTICE_ERROR_READ_ONLY => error.ReadOnly,
        c.LATTICE_ERROR_FULL => error.LatticeFull,
        c.LATTICE_ERROR_VERSION_MISMATCH => error.VersionMismatch,
        c.LATTICE_ERROR_CHECKSUM => error.ChecksumFailure,
        c.LATTICE_ERROR_OUT_OF_MEMORY => error.OutOfMemory,
        c.LATTICE_ERROR_UNSUPPORTED => error.Unsupported,
        else => error.LatticeFailure,
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

fn freeStreamEntries(allocator: std.mem.Allocator, entries: []const storage.StreamEntry) void {
    for (entries) |entry| {
        allocator.free(entry.stream);
        allocator.free(entry.payload_json);
    }
    allocator.free(entries);
}

fn isDerivedLabel(label: []const u8) bool {
    return std.mem.eql(u8, label, "Fact") or std.mem.eql(u8, label, "Preference") or std.mem.eql(u8, label, "Procedure");
}

fn isInternalLabel(label: []const u8) bool {
    return std.mem.eql(u8, label, "Job") or std.mem.eql(u8, label, "Idempotency") or std.mem.eql(u8, label, "Schema") or std.mem.eql(u8, label, "Migration");
}

fn slotAllowedForLabel(label: []const u8, slot_key: []const u8) bool {
    if (std.mem.eql(u8, label, "Fact")) return std.mem.eql(u8, slot_key, "project.package_manager");
    if (std.mem.eql(u8, label, "Preference")) return std.mem.eql(u8, slot_key, "user.response_style");
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
