const std = @import("std");
const storage = @import("storage.zig");

const c = @cImport({
    @cInclude("lattice.h");
});

/// Every Quipu node carries this Lattice label in addition to its Quipu label,
/// so a label scan enumerates the whole store.
const node_label = "QuipuNode";
/// Nodes that full-text search may return carry this label. One FTS index is
/// declared over (search_label, search_property), so BM25 statistics are shared
/// and scores are comparable across Quipu labels.
const search_label = "QuipuSearchable";
const search_property = "searchText";
const vector_key = "embedding";
/// Fields that hold a node's searchable text, in priority order.
const search_text_fields = [_][]const u8{ "searchText", "content", "text", "name" };
/// Lattice's tokenizer ignores tokens outside this length range.
const min_term_len: usize = 2;
const max_term_len: usize = 64;

const default_page_size: u32 = 4096;
const default_vector_dimensions: u16 = 128;
const default_embedding_model = "lattice_hash_embed";
const default_openrouter_embedding_url = "https://openrouter.ai/api/v1/embeddings";
const default_openrouter_embedding_model = "openai/text-embedding-3-small";
/// Most inputs one batched embedding request carries. OpenAI accepts 2048.
const embedding_batch_max_inputs: usize = 128;
/// Most text bytes one batched embedding request carries. Every token covers at
/// least one byte, so a batch stays far under OpenAI's 300K-token request limit.
const embedding_batch_max_bytes: usize = 128 * 1024;

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
    skip_close: bool = false,
};

const NodeIndex = struct {
    node_id: u64,
    label: []u8,
    /// Carries `search_label`, so full-text search can return it.
    searchable: bool,
    /// Has a vector in the HNSW index.
    has_vector: bool,

    fn deinit(self: NodeIndex, allocator: std.mem.Allocator) void {
        allocator.free(self.label);
    }
};

const LatticeHit = struct {
    node_id: u64,
    score: f32,

    fn byScoreDescending(_: void, left: LatticeHit, right: LatticeHit) bool {
        if (left.score != right.score) return left.score > right.score;
        return left.node_id < right.node_id;
    }
};

/// What a node write puts into the search indexes. Computed before the write
/// transaction opens, so a provider embedding call never holds the writer.
const IndexPlan = struct {
    /// Text for `search_property`; null when the node is not searchable.
    text: ?[]u8 = null,
    vector: ?[]f32 = null,
    /// Values for the native property indexes; see `storage.indexed_properties`.
    indexed: storage.IndexedValues = @splat(null),

    fn deinit(self: IndexPlan, allocator: std.mem.Allocator) void {
        if (self.text) |text| allocator.free(text);
        if (self.vector) |vector| allocator.free(vector);
        storage.freeIndexedValues(allocator, self.indexed);
    }
};

fn freeEdge(allocator: std.mem.Allocator, edge: storage.Edge) void {
    allocator.free(edge.qid);
    allocator.free(edge.from_qid);
    allocator.free(edge.to_qid);
    allocator.free(edge.edge_type);
    allocator.free(edge.properties_json);
}

pub const LatticeAdapter = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    db: ?*c.lattice_database,
    path: []u8,
    qid_to_node: std.StringHashMap(NodeIndex),
    /// Lattice node id to qid. Values borrow the keys of `qid_to_node`, which
    /// are never removed.
    node_to_qid: std.AutoHashMap(u64, []const u8),
    page_size: u32,
    vector_dimensions: u16,
    embedding_provider: EmbeddingProviderKind,
    embedding_url: [:0]u8,
    embedding_model: [:0]u8,
    embedding_api_key: ?[:0]u8,
    embedding_request_dimensions: bool,
    skip_close: bool,
    next_tx_id: u64 = 1,
    next_runtime_id: u64 = 1,
    /// Vectors from `prefetchEmbeddings`, keyed by the exact text embedded.
    /// Keys and values are owned and live until `clearPrefetched`.
    prefetched: std.StringHashMapUnmanaged([]f32) = .empty,

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

        var opts = c.lattice_open_options_v4{
            .struct_size = @sizeOf(c.lattice_open_options_v4),
            .create = true,
            .read_only = false,
            .cache_size_mb = 100,
            .page_size = options.page_size,
            .enable_vector = true,
            .vector_dimensions = options.vector_dimensions,
            .enable_wal = true,
            .enable_adjacency_cache = false,
            .lock = true,
        };
        var db: ?*c.lattice_database = null;
        try check(c.lattice_open_v4(path_z.ptr, &opts, &db));

        var self = LatticeAdapter{
            .allocator = allocator,
            .io = options.io,
            .db = db,
            .path = owned_path,
            .qid_to_node = std.StringHashMap(NodeIndex).init(allocator),
            .node_to_qid = std.AutoHashMap(u64, []const u8).init(allocator),
            .page_size = options.page_size,
            .vector_dimensions = options.vector_dimensions,
            .embedding_provider = options.embedding_provider,
            .embedding_url = owned_embedding_url,
            .embedding_model = owned_embedding_model,
            .embedding_api_key = owned_embedding_api_key,
            .embedding_request_dimensions = options.embedding_request_dimensions,
            .skip_close = options.skip_close,
        };
        owned_path_transferred = true;
        owned_embedding_url_transferred = true;
        owned_embedding_model_transferred = true;
        owned_embedding_api_key_transferred = true;
        errdefer self.deinit();
        try self.ensureSchema();
        try self.loadIndexes();
        return self;
    }

    pub fn deinit(self: *LatticeAdapter) void {
        self.clearPrefetched();
        self.prefetched.deinit(self.allocator);
        self.node_to_qid.deinit();
        var it = self.qid_to_node.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.qid_to_node.deinit();
        if (self.db) |db| {
            if (self.skip_close) {
                self.db = null;
            } else {
                _ = c.lattice_close(db);
                self.db = null;
            }
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

    /// Declares the full-text index and the equality indexes behind
    /// `findNodes`. Schema operations cannot run while a write transaction is
    /// open, so this happens once, at open.
    fn ensureSchema(self: *LatticeAdapter) !void {
        var exists = false;
        try check(c.lattice_node_fts_index_exists(self.db, search_label, search_property, &exists));
        if (!exists) try check(c.lattice_node_fts_index_create(self.db, search_label, search_property));

        var missing: [storage.indexed_properties.len]bool = @splat(false);
        var any_missing = false;
        for (storage.indexed_properties, 0..) |name, index| {
            missing[index] = !try self.propertyIndexExists(name);
            any_missing = any_missing or missing[index];
        }
        if (!any_missing) return;
        // Copy the values into native properties first: index creation reads
        // them, and an interrupted backfill is redone because the index is
        // still missing at the next open.
        try self.backfillIndexedProperties();
        for (storage.indexed_properties, 0..) |name, index| {
            if (!missing[index]) continue;
            const name_z = try self.allocator.dupeZ(u8, name);
            defer self.allocator.free(name_z);
            try check(c.lattice_node_property_index_create(self.db, node_label, name_z.ptr));
        }
    }

    /// Lattice reports a lookup on an undeclared index as unsupported.
    fn propertyIndexExists(self: *LatticeAdapter, name: []const u8) !bool {
        const name_z = try self.allocator.dupeZ(u8, name);
        defer self.allocator.free(name_z);
        const tx = try self.beginRead();
        defer self.rollbackQuiet(tx);
        var probe = stringValue("\x00");
        var ids: [*c]c.lattice_node_id = null;
        var count: usize = 0;
        const rc = c.lattice_nodes_find_by_label_property(tx, node_label, name_z.ptr, &probe, 1, &ids, &count);
        if (ids != null) c.lattice_free_node_ids(ids, count);
        if (rc == c.LATTICE_ERROR_UNSUPPORTED) return false;
        try check(rc);
        return true;
    }

    /// Writes the native copy of every indexed property for nodes stored before
    /// the indexes existed.
    fn backfillIndexedProperties(self: *LatticeAdapter) !void {
        const tx = try self.beginWrite();
        errdefer self.rollbackQuiet(tx);
        const node_ids = try nodesWithLabel(self.allocator, tx, node_label);
        defer self.allocator.free(node_ids);
        for (node_ids) |node_id| {
            const properties_json = (try readNodeString(self.allocator, tx, node_id, "propertiesJson")) orelse continue;
            defer self.allocator.free(properties_json);
            const indexed = try storage.indexedValues(self.allocator, properties_json);
            defer storage.freeIndexedValues(self.allocator, indexed);
            try writeIndexedProperties(self.allocator, tx, node_id, indexed, true);
        }
        try check(c.lattice_commit(tx));
    }

    fn loadIndexes(self: *LatticeAdapter) !void {
        const tx = try self.beginRead();
        defer self.rollbackQuiet(tx);

        const searchable_ids = try nodesWithLabel(self.allocator, tx, search_label);
        defer self.allocator.free(searchable_ids);
        var searchable = std.AutoHashMap(u64, void).init(self.allocator);
        defer searchable.deinit();
        for (searchable_ids) |node_id| try searchable.put(node_id, {});

        const node_ids = try nodesWithLabel(self.allocator, tx, node_label);
        defer self.allocator.free(node_ids);
        for (node_ids) |node_id| {
            const qid = (try readNodeString(self.allocator, tx, node_id, "qid")) orelse continue;
            defer self.allocator.free(qid);
            const label = (try readNodeString(self.allocator, tx, node_id, "quipuLabel")) orelse continue;
            defer self.allocator.free(label);
            const is_searchable = searchable.contains(node_id);
            // Vectors are written only for searchable nodes with vector-indexed
            // labels and dropped when either stops holding.
            try self.indexNode(qid, node_id, label, is_searchable, is_searchable and isVectorIndexedLabel(label));
            self.trackRuntimeId(qid);
        }

        // Edge qids consume runtime ids too.
        var result: ?*c.lattice_edge_result = null;
        try check(c.lattice_edge_scan(tx, null, 0, &result));
        defer if (result) |ptr| c.lattice_edge_result_free(ptr);
        const count = c.lattice_edge_result_count(result);
        var index: u32 = 0;
        while (index < count) : (index += 1) {
            var edge_id: c.lattice_edge_id = 0;
            try check(c.lattice_edge_result_get_id(result, index, &edge_id));
            const qid = (try readEdgeString(self.allocator, tx, edge_id, "qid")) orelse continue;
            defer self.allocator.free(qid);
            self.trackRuntimeId(qid);
        }
    }

    fn putNode(context: *anyopaque, node: storage.Node) !void {
        const self = ctx(context);
        if (isReservedLabel(node.label) or node.label.len == 0) return error.InvalidRequest;

        const plan = try self.planIndexes(node);
        defer plan.deinit(self.allocator);
        const is_searchable = plan.text != null;
        const has_vector = plan.vector != null;

        const label_z = try self.allocator.dupeZ(u8, node.label);
        defer self.allocator.free(label_z);

        const tx = try self.beginWrite();
        errdefer self.rollbackQuiet(tx);

        var was_searchable = false;
        var had_vector = false;
        const existed = self.qid_to_node.contains(node.qid);
        const node_id: u64 = if (self.qid_to_node.get(node.qid)) |entry| blk: {
            was_searchable = entry.searchable;
            had_vector = entry.has_vector;
            if (!std.mem.eql(u8, entry.label, node.label)) {
                const old_label_z = try self.allocator.dupeZ(u8, entry.label);
                defer self.allocator.free(old_label_z);
                try check(c.lattice_node_remove_label(tx, entry.node_id, old_label_z.ptr));
                try check(c.lattice_node_add_label(tx, entry.node_id, label_z.ptr));
                try setNodeString(tx, entry.node_id, "quipuLabel", node.label);
            }
            break :blk entry.node_id;
        } else blk: {
            var created: c.lattice_node_id = 0;
            try check(c.lattice_node_create(tx, label_z.ptr, &created));
            try check(c.lattice_node_add_label(tx, created, node_label));
            try setNodeString(tx, created, "qid", node.qid);
            try setNodeString(tx, created, "quipuLabel", node.label);
            break :blk @intCast(created);
        };

        try setNodeString(tx, node_id, "propertiesJson", node.properties_json);
        try writeIndexedProperties(self.allocator, tx, node_id, plan.indexed, existed);
        if (plan.text) |text| {
            try setNodeString(tx, node_id, search_property, text);
            if (!was_searchable) try check(c.lattice_node_add_label(tx, node_id, search_label));
        } else if (was_searchable) {
            // Dropping the label removes the node from the index at commit;
            // clearing the text keeps forgotten content out of the record.
            try check(c.lattice_node_remove_label(tx, node_id, search_label));
            try setNodeString(tx, node_id, search_property, "");
        }

        if (plan.vector) |vector| {
            try check(c.lattice_node_set_vector(tx, node_id, vector_key, vector.ptr, @intCast(vector.len)));
        } else if (had_vector) {
            try dropNodeVector(tx, node_id, label_z, is_searchable);
        }
        try check(c.lattice_commit(tx));

        try self.indexNode(node.qid, node_id, node.label, is_searchable, has_vector);
        self.trackRuntimeId(node.qid);
    }

    fn planIndexes(self: *LatticeAdapter, node: storage.Node) !IndexPlan {
        var plan = IndexPlan{};
        errdefer plan.deinit(self.allocator);
        plan.indexed = try storage.indexedValues(self.allocator, node.properties_json);
        plan.text = try searchTextFor(self.allocator, node.label, node.properties_json);
        if (plan.text) |text| {
            if (isVectorIndexedLabel(node.label)) {
                // A prefetched vector embeds this exact text with the same
                // model and dimensions, so it is the vector embed would return.
                const vector = if (self.prefetched.get(text)) |prefetched|
                    try self.allocator.dupe(f32, prefetched)
                else
                    try self.embed(self.allocator, text);
                if (vector.len == 0) {
                    self.allocator.free(vector);
                } else {
                    plan.vector = vector;
                }
            }
        }
        return plan;
    }

    fn getNode(context: *anyopaque, allocator: std.mem.Allocator, qid: []const u8) !?storage.Node {
        const self = ctx(context);
        const index = self.qid_to_node.get(qid) orelse return null;
        const tx = try self.beginRead();
        defer self.rollbackQuiet(tx);

        const properties_json = (try readNodeString(allocator, tx, index.node_id, "propertiesJson")) orelse return null;
        errdefer allocator.free(properties_json);
        const label = try allocator.dupe(u8, index.label);
        errdefer allocator.free(label);
        return .{
            .qid = try allocator.dupe(u8, qid),
            .label = label,
            .properties_json = properties_json,
        };
    }

    /// Stores the edge as a native Lattice edge between the endpoint nodes, with
    /// its qid and properties as edge properties. Both endpoints must exist.
    /// Putting an edge whose qid already joins the same endpoints updates it.
    fn putEdge(context: *anyopaque, edge: storage.Edge) !void {
        const self = ctx(context);
        const from = self.qid_to_node.get(edge.from_qid) orelse return error.NotFound;
        const to = self.qid_to_node.get(edge.to_qid) orelse return error.NotFound;
        const type_z = try self.allocator.dupeZ(u8, edge.edge_type);
        defer self.allocator.free(type_z);

        const tx = try self.beginWrite();
        errdefer self.rollbackQuiet(tx);

        const edge_id = (try self.findEdgeId(tx, from.node_id, to.node_id, type_z, edge.qid)) orelse blk: {
            var created: c.lattice_edge_id = 0;
            try check(c.lattice_edge_create(tx, from.node_id, to.node_id, type_z.ptr, &created));
            try setEdgeString(tx, created, "qid", edge.qid);
            try setEdgeString(tx, created, "fromQid", edge.from_qid);
            try setEdgeString(tx, created, "toQid", edge.to_qid);
            break :blk created;
        };
        try setEdgeString(tx, edge_id, "propertiesJson", edge.properties_json);
        try check(c.lattice_commit(tx));
        self.trackRuntimeId(edge.qid);
    }

    fn findEdgeId(
        self: *LatticeAdapter,
        tx: *c.lattice_txn,
        from_node: u64,
        to_node: u64,
        edge_type_z: [:0]const u8,
        qid: []const u8,
    ) !?c.lattice_edge_id {
        var result: ?*c.lattice_edge_result = null;
        try check(c.lattice_edge_get_outgoing_by_type(tx, from_node, edge_type_z.ptr, 0, &result));
        defer if (result) |ptr| c.lattice_edge_result_free(ptr);
        const count = c.lattice_edge_result_count(result);
        var index: u32 = 0;
        while (index < count) : (index += 1) {
            var source: c.lattice_node_id = 0;
            var target: c.lattice_node_id = 0;
            var type_ptr: [*c]const u8 = null;
            var type_len: c_uint = 0;
            try check(c.lattice_edge_result_get(result, index, &source, &target, &type_ptr, &type_len));
            if (target != to_node) continue;
            var edge_id: c.lattice_edge_id = 0;
            try check(c.lattice_edge_result_get_id(result, index, &edge_id));
            const existing_qid = (try readEdgeString(self.allocator, tx, edge_id, "qid")) orelse continue;
            defer self.allocator.free(existing_qid);
            if (std.mem.eql(u8, existing_qid, qid)) return edge_id;
        }
        return null;
    }

    fn findEdges(context: *anyopaque, allocator: std.mem.Allocator, query: storage.EdgeQuery) ![]storage.Edge {
        const self = ctx(context);
        if (query.limit == 0) return allocator.alloc(storage.Edge, 0);

        const from_node: ?u64 = if (query.from_qid) |qid| (self.qid_to_node.get(qid) orelse return allocator.alloc(storage.Edge, 0)).node_id else null;
        const to_node: ?u64 = if (query.to_qid) |qid| (self.qid_to_node.get(qid) orelse return allocator.alloc(storage.Edge, 0)).node_id else null;
        const type_z: ?[:0]u8 = if (query.edge_type) |edge_type| try allocator.dupeZ(u8, edge_type) else null;
        defer if (type_z) |value| allocator.free(value);
        const type_ptr: [*c]const u8 = if (type_z) |value| value.ptr else null;
        // Ask Lattice for at most `limit` only when it applies every filter;
        // its 0 means unlimited.
        const native_limit: usize = if ((from_node != null and to_node != null) or query.limit == storage.unlimited) 0 else query.limit;

        const tx = try self.beginRead();
        defer self.rollbackQuiet(tx);

        var result: ?*c.lattice_edge_result = null;
        if (from_node) |node_id| {
            if (type_z != null) {
                try check(c.lattice_edge_get_outgoing_by_type(tx, node_id, type_ptr, native_limit, &result));
            } else {
                try check(c.lattice_edge_get_outgoing(tx, node_id, &result));
            }
        } else if (to_node) |node_id| {
            if (type_z != null) {
                try check(c.lattice_edge_get_incoming_by_type(tx, node_id, type_ptr, native_limit, &result));
            } else {
                try check(c.lattice_edge_get_incoming(tx, node_id, &result));
            }
        } else {
            try check(c.lattice_edge_scan(tx, type_ptr, native_limit, &result));
        }
        defer if (result) |ptr| c.lattice_edge_result_free(ptr);

        var edges = std.ArrayList(storage.Edge).empty;
        errdefer {
            for (edges.items) |edge| freeEdge(allocator, edge);
            edges.deinit(allocator);
        }

        const count = c.lattice_edge_result_count(result);
        var index: u32 = 0;
        while (index < count and edges.items.len < query.limit) : (index += 1) {
            var source: c.lattice_node_id = 0;
            var target: c.lattice_node_id = 0;
            var edge_type_ptr: [*c]const u8 = null;
            var edge_type_len: c_uint = 0;
            try check(c.lattice_edge_result_get(result, index, &source, &target, &edge_type_ptr, &edge_type_len));
            if (from_node) |expected| if (source != expected) continue;
            if (to_node) |expected| if (target != expected) continue;
            const edge_type: []const u8 = if (edge_type_len == 0) "" else edge_type_ptr[0..edge_type_len];
            if (query.edge_type) |expected| if (!std.mem.eql(u8, edge_type, expected)) continue;
            const from_qid = self.node_to_qid.get(source) orelse continue;
            const to_qid = self.node_to_qid.get(target) orelse continue;

            var edge_id: c.lattice_edge_id = 0;
            try check(c.lattice_edge_result_get_id(result, index, &edge_id));
            const qid = (try readEdgeString(allocator, tx, edge_id, "qid")) orelse continue;
            errdefer allocator.free(qid);
            const properties_json = (try readEdgeString(allocator, tx, edge_id, "propertiesJson")) orelse try allocator.dupe(u8, "{}");
            errdefer allocator.free(properties_json);
            const owned_from = try allocator.dupe(u8, from_qid);
            errdefer allocator.free(owned_from);
            const owned_to = try allocator.dupe(u8, to_qid);
            errdefer allocator.free(owned_to);
            const owned_type = try allocator.dupe(u8, edge_type);
            errdefer allocator.free(owned_type);
            try edges.append(allocator, .{
                .qid = qid,
                .from_qid = owned_from,
                .to_qid = owned_to,
                .edge_type = owned_type,
                .properties_json = properties_json,
            });
        }
        return edges.toOwnedSlice(allocator);
    }

    /// Candidates come from the native equality index of each indexed property
    /// in `where` (intersected), or else from a label scan. Lattice node ids
    /// grow with creation, so they order the result and serve as the cursor.
    /// Unindexed properties are checked against each candidate's JSON.
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

        const tx = try self.beginRead();
        defer self.rollbackQuiet(tx);

        var candidates: ?[]u64 = null;
        defer if (candidates) |ids| allocator.free(ids);
        for (query.where) |match| {
            if (storage.indexedPropertyIndex(match.name) == null) continue;
            const ids = try findIdsByProperty(allocator, tx, match.name, match.value);
            if (candidates) |previous| {
                defer allocator.free(ids);
                const kept = intersectSorted(previous, ids);
                candidates = try allocator.realloc(previous, kept);
            } else {
                candidates = ids;
            }
        }
        if (candidates == null) {
            const ids = try nodesWithLabel(allocator, tx, query.label orelse node_label);
            std.mem.sort(u64, ids, {}, std.sort.asc(u64));
            candidates = ids;
        }
        const ids = candidates.?;

        var next: ?u64 = null;
        var position: usize = switch (query.order) {
            .oldest_first => if (query.after) |after| std.sort.upperBound(u64, ids, after, orderU64) else 0,
            .newest_first => if (query.after) |after| std.sort.lowerBound(u64, ids, after, orderU64) else ids.len,
        };
        while (true) {
            const node_id = switch (query.order) {
                .oldest_first => blk: {
                    if (position >= ids.len) break;
                    position += 1;
                    break :blk ids[position - 1];
                },
                .newest_first => blk: {
                    if (position == 0) break;
                    position -= 1;
                    break :blk ids[position];
                },
            };
            const qid = self.node_to_qid.get(node_id) orelse continue;
            if (query.label) |label| {
                const entry = self.qid_to_node.get(qid) orelse continue;
                if (!std.mem.eql(u8, entry.label, label)) continue;
            }
            if (!try self.matchesUnindexed(allocator, tx, node_id, query.where)) continue;
            try qids.ensureUnusedCapacity(allocator, 1);
            qids.appendAssumeCapacity(try allocator.dupe(u8, qid));
            if (qids.items.len >= query.limit) {
                next = node_id;
                break;
            }
        }
        return .{ .qids = try qids.toOwnedSlice(allocator), .next = next };
    }

    fn matchesUnindexed(self: *LatticeAdapter, allocator: std.mem.Allocator, tx: *c.lattice_txn, node_id: u64, where: []const storage.PropertyMatch) !bool {
        _ = self;
        var properties_json: ?[]u8 = null;
        defer if (properties_json) |json| allocator.free(json);
        for (where) |match| {
            if (storage.indexedPropertyIndex(match.name) != null) continue;
            if (properties_json == null) {
                properties_json = (try readNodeString(allocator, tx, node_id, "propertiesJson")) orelse return false;
            }
            if (!try storage.propertyStringEquals(allocator, properties_json.?, match.name, match.value)) return false;
        }
        return true;
    }

    /// Empty text enumerates every node, searchable or not, in creation order.
    /// Other text is ranked by BM25 over the searchable nodes' `searchText`,
    /// matching any query term, best first.
    fn fullTextSearch(context: *anyopaque, allocator: std.mem.Allocator, query: storage.FullTextQuery) ![]storage.SearchHit {
        const self = ctx(context);
        if (query.limit == 0) return allocator.alloc(storage.SearchHit, 0);
        if (query.text.len == 0) return self.enumerateLabel(allocator, node_label, query.limit);

        const ranked = try self.rankNodeIds(allocator, query.text);
        defer allocator.free(ranked);

        var hits = std.ArrayList(storage.SearchHit).empty;
        errdefer {
            for (hits.items) |hit| allocator.free(hit.qid);
            hits.deinit(allocator);
        }
        for (ranked) |hit| {
            if (hits.items.len >= query.limit) break;
            const qid = self.node_to_qid.get(hit.node_id) orelse continue;
            const entry = self.qid_to_node.get(qid) orelse continue;
            if (!entry.searchable) continue;
            try hits.append(allocator, .{ .qid = try allocator.dupe(u8, qid), .score = hit.score });
        }
        return hits.toOwnedSlice(allocator);
    }

    fn enumerateLabel(self: *LatticeAdapter, allocator: std.mem.Allocator, label: []const u8, limit: usize) ![]storage.SearchHit {
        const tx = try self.beginRead();
        defer self.rollbackQuiet(tx);
        const node_ids = try nodesWithLabel(allocator, tx, label);
        defer allocator.free(node_ids);
        // A label scan returns ids in no particular order; ids grow with
        // creation.
        std.mem.sort(u64, node_ids, {}, std.sort.asc(u64));

        var hits = std.ArrayList(storage.SearchHit).empty;
        errdefer {
            for (hits.items) |hit| allocator.free(hit.qid);
            hits.deinit(allocator);
        }
        for (node_ids) |node_id| {
            if (hits.items.len >= limit) break;
            const qid = self.node_to_qid.get(node_id) orelse continue;
            try hits.append(allocator, .{ .qid = try allocator.dupe(u8, qid), .score = 1.0 });
        }
        return hits.toOwnedSlice(allocator);
    }

    /// BM25 with OR semantics. Lattice's multi-term search requires every term
    /// (AND), so each distinct query term is searched alone and the per-term
    /// scores are summed: BM25 is additive over query terms, so the sum is the
    /// document's BM25 score for the whole query. Sorted best first.
    ///
    /// Lattice does not stem, so a term also matches its plural or singular
    /// ("response" and "responses"); a document scores the better of the two.
    fn rankNodeIds(self: *LatticeAdapter, allocator: std.mem.Allocator, text: []const u8) ![]LatticeHit {
        const terms = try queryTerms(allocator, text);
        defer freeTerms(allocator, terms);

        var scores: std.AutoArrayHashMapUnmanaged(u64, f32) = .empty;
        defer scores.deinit(allocator);
        var term_scores: std.AutoArrayHashMapUnmanaged(u64, f32) = .empty;
        defer term_scores.deinit(allocator);
        var plural_buffer: [max_term_len + 1]u8 = undefined;
        for (terms) |term| {
            term_scores.clearRetainingCapacity();
            try self.collectTermScores(allocator, &term_scores, term);
            if (term.len < max_term_len) {
                @memcpy(plural_buffer[0..term.len], term);
                plural_buffer[term.len] = 's';
                try self.collectTermScores(allocator, &term_scores, plural_buffer[0 .. term.len + 1]);
            }
            for (term_scores.keys(), term_scores.values()) |node_id, score| {
                const entry = try scores.getOrPut(allocator, node_id);
                if (!entry.found_existing) entry.value_ptr.* = 0;
                entry.value_ptr.* += score;
            }
        }

        const hits = try allocator.alloc(LatticeHit, scores.count());
        for (scores.keys(), scores.values(), 0..) |node_id, score, index| {
            hits[index] = .{ .node_id = node_id, .score = score };
        }
        std.mem.sort(LatticeHit, hits, {}, LatticeHit.byScoreDescending);
        return hits;
    }

    /// Keeps each document's best BM25 score for `term` in `scores`.
    fn collectTermScores(self: *LatticeAdapter, allocator: std.mem.Allocator, scores: *std.AutoArrayHashMapUnmanaged(u64, f32), term: []const u8) !void {
        var result: ?*c.lattice_fts_result = null;
        try check(c.lattice_fts_search(self.db, search_label, search_property, term.ptr, term.len, std.math.maxInt(u32), &result));
        defer if (result) |ptr| c.lattice_fts_result_free(ptr);
        const count = c.lattice_fts_result_count(result);
        var index: u32 = 0;
        while (index < count) : (index += 1) {
            var node_id: c.lattice_node_id = 0;
            var score: f32 = 0;
            try check(c.lattice_fts_result_get(result, index, &node_id, &score));
            const entry = try scores.getOrPut(allocator, @intCast(node_id));
            if (!entry.found_existing or score > entry.value_ptr.*) entry.value_ptr.* = score;
        }
    }

    fn vectorSearch(context: *anyopaque, allocator: std.mem.Allocator, query: storage.VectorQuery) ![]storage.SearchHit {
        const self = ctx(context);
        if (query.vector.len == 0 or query.limit == 0) return allocator.alloc(storage.SearchHit, 0);

        var hits = std.ArrayList(storage.SearchHit).empty;
        errdefer {
            for (hits.items) |hit| allocator.free(hit.qid);
            hits.deinit(allocator);
        }

        // Every vector belongs to a node that should be found, but filter anyway
        // and widen k if that leaves the page short.
        const max_k: usize = @max(query.limit, self.qid_to_node.count());
        var k: usize = query.limit;
        while (true) {
            for (hits.items) |hit| allocator.free(hit.qid);
            hits.clearRetainingCapacity();

            var result: ?*c.lattice_vector_result = null;
            try check(c.lattice_vector_search(self.db, query.vector.ptr, @intCast(query.vector.len), @intCast(@min(k, std.math.maxInt(u32))), 0, &result));
            defer if (result) |ptr| c.lattice_vector_result_free(ptr);

            const count = c.lattice_vector_result_count(result);
            var index: u32 = 0;
            while (index < count and hits.items.len < query.limit) : (index += 1) {
                var node_id: c.lattice_node_id = 0;
                var distance: f32 = 0;
                try check(c.lattice_vector_result_get(result, index, &node_id, &distance));
                const qid = self.node_to_qid.get(node_id) orelse continue;
                const entry = self.qid_to_node.get(qid) orelse continue;
                if (!entry.has_vector) continue;
                try hits.append(allocator, .{ .qid = try allocator.dupe(u8, qid), .score = 1.0 / (1.0 + distance) });
            }
            if (hits.items.len >= query.limit or count < k or k >= max_k) break;
            k = @min(k * 2, max_k);
        }
        return hits.toOwnedSlice(allocator);
    }

    fn embedText(context: *anyopaque, allocator: std.mem.Allocator, text: []const u8) ![]f32 {
        const self = ctx(context);
        return self.embed(allocator, text);
    }

    /// Embeds the distinct texts in batched provider requests and caches the
    /// vectors by text for putNode. Hash embeddings are local and cheap, so
    /// they are not prefetched. A failed batch is skipped: putNode embeds its
    /// texts one request at a time, as it would without a prefetch.
    fn prefetchEmbeddings(context: *anyopaque, texts: []const []const u8) !void {
        const self = ctx(context);
        if (self.embedding_provider != .openai_compatible) return;

        var pending = std.ArrayList([]const u8).empty;
        defer pending.deinit(self.allocator);
        var seen = std.StringHashMapUnmanaged(void).empty;
        defer seen.deinit(self.allocator);
        for (texts) |text| {
            // putNode never embeds blank text.
            if (isBlank(text) or self.prefetched.contains(text)) continue;
            if ((try seen.getOrPut(self.allocator, text)).found_existing) continue;
            try pending.append(self.allocator, text);
        }

        var start: usize = 0;
        while (start < pending.items.len) {
            const end = embeddingBatchEnd(pending.items, start);
            self.prefetchBatch(pending.items[start..end]) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => {},
            };
            start = end;
        }
    }

    fn prefetchBatch(self: *LatticeAdapter, texts: []const []const u8) !void {
        const vectors = try self.openAiCompatibleEmbedBatch(self.allocator, texts);
        defer self.allocator.free(vectors);
        var stored: usize = 0;
        defer for (vectors[stored..]) |vector| self.allocator.free(vector);
        try self.prefetched.ensureUnusedCapacity(self.allocator, @intCast(texts.len));
        for (texts, vectors) |text, vector| {
            const key = try self.allocator.dupe(u8, text);
            self.prefetched.putAssumeCapacityNoClobber(key, vector);
            stored += 1;
        }
    }

    fn clearPrefetchedEmbeddings(context: *anyopaque) void {
        ctx(context).clearPrefetched();
    }

    fn clearPrefetched(self: *LatticeAdapter) void {
        var it = self.prefetched.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.prefetched.clearRetainingCapacity();
    }

    fn appendStream(context: *anyopaque, stream: []const u8, payload_json: []const u8) !storage.StreamEntry {
        const self = ctx(context);
        const tx = try self.beginWrite();
        errdefer self.rollbackQuiet(tx);
        var payload = stringValue(payload_json);
        var sequence: u64 = 0;
        try check(c.lattice_stream_publish_get_sequence(tx, stream.ptr, stream.len, "message", "message".len, &payload, &sequence));
        try check(c.lattice_commit(tx));
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
            const owned_stream = try allocator.dupe(u8, stream);
            errdefer allocator.free(owned_stream);
            try entries.append(allocator, .{
                .stream = owned_stream,
                .sequence = sequence,
                .payload_json = payload,
            });
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

        const tx = try self.beginRead();
        defer self.rollbackQuiet(tx);

        try self.verifyEdges(allocator, tx, &issues);

        const searchable_ids = try nodesWithLabel(allocator, tx, search_label);
        defer allocator.free(searchable_ids);
        var searchable = std.AutoHashMap(u64, void).init(allocator);
        defer searchable.deinit();
        for (searchable_ids) |node_id| try searchable.put(node_id, {});

        var seen_qids = std.StringHashMap(void).init(allocator);
        defer {
            var it = seen_qids.keyIterator();
            while (it.next()) |key| allocator.free(key.*);
            seen_qids.deinit();
        }
        var deleted_qids = std.StringHashMap(void).init(allocator);
        defer {
            var it = deleted_qids.keyIterator();
            while (it.next()) |key| allocator.free(key.*);
            deleted_qids.deinit();
        }
        // (derived qid, evidence qid) for active derived nodes.
        var active_evidence = std.ArrayList([2][]u8).empty;
        defer {
            for (active_evidence.items) |pair| {
                allocator.free(pair[0]);
                allocator.free(pair[1]);
            }
            active_evidence.deinit(allocator);
        }

        const node_ids = try nodesWithLabel(allocator, tx, node_label);
        defer allocator.free(node_ids);
        for (node_ids) |node_id| {
            const qid = (try readNodeString(allocator, tx, node_id, "qid")) orelse {
                try appendIssueFmt(allocator, &issues, "missing_node_qid", "lattice node carries QuipuNode but has no qid", "lattice:{d}", .{node_id});
                continue;
            };
            defer allocator.free(qid);
            if (seen_qids.contains(qid)) {
                try appendIssue(allocator, &issues, "duplicate_qid", "more than one lattice node carries this qid", qid);
                continue;
            }
            try putOwnedKey(allocator, &seen_qids, qid);

            const index = self.qid_to_node.get(qid);
            if (index == null or index.?.node_id != node_id) {
                try appendIssue(allocator, &issues, "node_index_mismatch", "in-memory qid index does not point at the stored node", qid);
                continue;
            }
            const label = index.?.label;
            const properties_json = (try readNodeString(allocator, tx, node_id, "propertiesJson")) orelse {
                try appendIssue(allocator, &issues, "missing_node_properties", "node has no propertiesJson", qid);
                continue;
            };
            defer allocator.free(properties_json);

            try self.verifySearchIndex(allocator, tx, &issues, node_id, qid, label, properties_json, searchable.contains(node_id));

            if (propertyBool(allocator, properties_json, "deleted")) {
                try putOwnedKey(allocator, &deleted_qids, qid);
                continue;
            }
            if (isDerivedLabel(label)) {
                try verifyDerivedNode(self, allocator, &issues, qid, label, properties_json);
                if (try readOptionalString(allocator, properties_json, "evidenceQid")) |evidence_qid| {
                    errdefer allocator.free(evidence_qid);
                    const derived_qid = try allocator.dupe(u8, qid);
                    errdefer allocator.free(derived_qid);
                    try active_evidence.append(allocator, .{ derived_qid, evidence_qid });
                }
            }
        }

        for (searchable_ids) |node_id| {
            if (!self.node_to_qid.contains(node_id)) {
                try appendIssueFmt(allocator, &issues, "search_index_orphan", "searchable lattice node is not a Quipu node", "lattice:{d}", .{node_id});
            }
        }
        for (active_evidence.items) |pair| {
            if (deleted_qids.contains(pair[1])) {
                try appendIssue(allocator, &issues, "active_derived_from_deleted_evidence", "active derived node references deleted evidence", pair[0]);
            }
        }

        return issues.toOwnedSlice(allocator);
    }

    fn verifyEdges(self: *LatticeAdapter, allocator: std.mem.Allocator, tx: *c.lattice_txn, issues: *std.ArrayList(storage.VerificationIssue)) !void {
        var result: ?*c.lattice_edge_result = null;
        try check(c.lattice_edge_scan(tx, null, 0, &result));
        defer if (result) |ptr| c.lattice_edge_result_free(ptr);
        const count = c.lattice_edge_result_count(result);
        var index: u32 = 0;
        while (index < count) : (index += 1) {
            var source: c.lattice_node_id = 0;
            var target: c.lattice_node_id = 0;
            var type_ptr: [*c]const u8 = null;
            var type_len: c_uint = 0;
            try check(c.lattice_edge_result_get(result, index, &source, &target, &type_ptr, &type_len));
            var edge_id: c.lattice_edge_id = 0;
            try check(c.lattice_edge_result_get_id(result, index, &edge_id));
            const edge_qid = (try readEdgeString(allocator, tx, edge_id, "qid")) orelse {
                try appendIssueFmt(allocator, issues, "missing_edge_qid", "lattice edge has no qid", "lattice-edge:{d}", .{edge_id});
                continue;
            };
            defer allocator.free(edge_qid);
            try verifyEdgeEndpoint(self, allocator, tx, issues, edge_id, edge_qid, source, "fromQid", "missing_edge_source", "edge source node is missing");
            try verifyEdgeEndpoint(self, allocator, tx, issues, edge_id, edge_qid, target, "toQid", "missing_edge_target", "edge target node is missing");
        }
    }

    fn verifyEdgeEndpoint(
        self: *LatticeAdapter,
        allocator: std.mem.Allocator,
        tx: *c.lattice_txn,
        issues: *std.ArrayList(storage.VerificationIssue),
        edge_id: c.lattice_edge_id,
        edge_qid: []const u8,
        node_id: u64,
        recorded_key: [*:0]const u8,
        missing_code: []const u8,
        missing_message: []const u8,
    ) !void {
        const endpoint_qid = self.node_to_qid.get(node_id) orelse {
            try appendIssue(allocator, issues, missing_code, missing_message, edge_qid);
            return;
        };
        const recorded = (try readEdgeString(allocator, tx, edge_id, recorded_key)) orelse return;
        defer allocator.free(recorded);
        if (!std.mem.eql(u8, recorded, endpoint_qid)) {
            try appendIssue(allocator, issues, "edge_endpoint_mismatch", "edge endpoint does not match its recorded qid", edge_qid);
        }
    }

    fn verifySearchIndex(
        self: *LatticeAdapter,
        allocator: std.mem.Allocator,
        tx: *c.lattice_txn,
        issues: *std.ArrayList(storage.VerificationIssue),
        node_id: u64,
        qid: []const u8,
        label: []const u8,
        properties_json: []const u8,
        indexed: bool,
    ) !void {
        _ = self;
        const expected = try searchTextFor(allocator, label, properties_json);
        defer if (expected) |text| allocator.free(text);
        if (expected == null and indexed) {
            try appendIssue(allocator, issues, "search_index_stale", "unsearchable node is still in the full-text index", qid);
            return;
        }
        if (expected != null and !indexed) {
            try appendIssue(allocator, issues, "search_index_missing", "searchable node is missing from the full-text index", qid);
            return;
        }
        const stored = (try readNodeString(allocator, tx, node_id, search_property)) orelse {
            if (expected != null) try appendIssue(allocator, issues, "search_text_mismatch", "indexed searchText does not match the node", qid);
            return;
        };
        defer allocator.free(stored);
        const matches = if (expected) |text| std.mem.eql(u8, stored, text) else stored.len == 0;
        if (!matches) {
            try appendIssue(allocator, issues, "search_text_mismatch", "indexed searchText does not match the node", qid);
        }
    }

    fn indexNode(self: *LatticeAdapter, qid: []const u8, node_id: u64, label: []const u8, searchable: bool, has_vector: bool) !void {
        const key = try self.allocator.dupe(u8, qid);
        errdefer self.allocator.free(key);
        const label_copy = try self.allocator.dupe(u8, label);
        errdefer self.allocator.free(label_copy);

        try self.node_to_qid.ensureUnusedCapacity(1);
        const entry = try self.qid_to_node.getOrPut(key);
        if (entry.found_existing) {
            self.allocator.free(key);
            entry.value_ptr.deinit(self.allocator);
        }
        entry.value_ptr.* = .{ .node_id = node_id, .label = label_copy, .searchable = searchable, .has_vector = has_vector };
        self.node_to_qid.putAssumeCapacity(node_id, entry.key_ptr.*);
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

    fn embed(self: *LatticeAdapter, allocator: std.mem.Allocator, text: []const u8) ![]f32 {
        return switch (self.embedding_provider) {
            .hash => hashEmbed(allocator, text, self.vector_dimensions),
            .openai_compatible => try self.openAiCompatibleEmbed(allocator, text),
        };
    }

    fn openAiCompatibleEmbed(self: *LatticeAdapter, allocator: std.mem.Allocator, text: []const u8) ![]f32 {
        const response = try self.postEmbeddings(allocator, text);
        defer allocator.free(response);
        return parseEmbeddingResponse(allocator, response, self.vector_dimensions);
    }

    /// One request for all of `texts`; the vectors come back in input order.
    fn openAiCompatibleEmbedBatch(self: *LatticeAdapter, allocator: std.mem.Allocator, texts: []const []const u8) ![][]f32 {
        const response = try self.postEmbeddings(allocator, texts);
        defer allocator.free(response);
        return parseBatchEmbeddingResponse(allocator, response, texts.len, self.vector_dimensions);
    }

    /// POSTs an embeddings request whose `input` is one string or an array of
    /// strings, and returns the response body.
    fn postEmbeddings(self: *LatticeAdapter, allocator: std.mem.Allocator, input: anytype) ![]u8 {
        const request_body = if (self.embedding_request_dimensions)
            try stringifyAlloc(allocator, .{
                .model = self.embedding_model,
                .input = input,
                .dimensions = self.vector_dimensions,
            })
        else
            try stringifyAlloc(allocator, .{
                .model = self.embedding_model,
                .input = input,
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
        return response_body.toOwnedSlice();
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

    fn ctx(context: *anyopaque) *LatticeAdapter {
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

/// LatticeDB 0.15 has no call that clears a node's vector, but a node left with
/// no labels inside a transaction loses its vector at commit. Strip the labels
/// and put them back.
fn dropNodeVector(tx: *c.lattice_txn, node_id: u64, label_z: [:0]const u8, searchable: bool) !void {
    if (searchable) try check(c.lattice_node_remove_label(tx, node_id, search_label));
    try check(c.lattice_node_remove_label(tx, node_id, node_label));
    try check(c.lattice_node_remove_label(tx, node_id, label_z.ptr));
    try check(c.lattice_node_add_label(tx, node_id, label_z.ptr));
    try check(c.lattice_node_add_label(tx, node_id, node_label));
    if (searchable) try check(c.lattice_node_add_label(tx, node_id, search_label));
}

/// The text full-text search and vectors index for a node, or null when the node
/// must not be a search hit: internal, Session and Turn labels, nodes marked
/// `searchable:false` or `deleted:true`, and nodes with no text.
///
/// The text is the first non-blank of `searchText`, `content`, `text` and
/// `name`. Entities carry none of those, so they fall back to their canonical
/// name and aliases.
fn searchTextFor(allocator: std.mem.Allocator, label: []const u8, properties_json: []const u8) !?[]u8 {
    if (!isSearchableLabel(label)) return null;
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, properties_json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return null,
    };
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |object| object,
        else => return null,
    };
    if (jsonBool(object.get("searchable")) == false) return null;
    if (jsonBool(object.get("deleted")) == true) return null;

    for (search_text_fields) |field| {
        const value = jsonString(object.get(field)) orelse continue;
        if (isBlank(value)) continue;
        return try allocator.dupe(u8, value);
    }

    const canonical_name = jsonString(object.get("canonicalName")) orelse return null;
    if (isBlank(canonical_name)) return null;
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    try writer.writer.writeAll(canonical_name);
    try appendStringArrayField(&writer.writer, object.get("aliases"));
    return try writer.toOwnedSlice();
}

/// Distinct query terms as Lattice's tokenizer splits them: runs of ASCII
/// letters, digits and underscores, lowercased, 2 to 64 bytes long. A plural
/// becomes its singular ("responses" -> "response"), so the two count once.
fn queryTerms(allocator: std.mem.Allocator, text: []const u8) ![][]u8 {
    var terms = std.ArrayList([]u8).empty;
    errdefer {
        for (terms.items) |term| allocator.free(term);
        terms.deinit(allocator);
    }
    var start: ?usize = null;
    var index: usize = 0;
    while (index <= text.len) : (index += 1) {
        const in_word = index < text.len and isWordChar(text[index]);
        if (in_word) {
            if (start == null) start = index;
            continue;
        }
        const word_start = start orelse continue;
        start = null;
        const word = text[word_start..index];
        if (word.len < min_term_len or word.len > max_term_len) continue;
        const term = try std.ascii.allocLowerString(allocator, singular(word));
        var duplicate = false;
        for (terms.items) |existing| {
            if (std.mem.eql(u8, existing, term)) {
                duplicate = true;
                break;
            }
        }
        if (duplicate) {
            allocator.free(term);
            continue;
        }
        terms.append(allocator, term) catch |err| {
            allocator.free(term);
            return err;
        };
    }
    return terms.toOwnedSlice(allocator);
}

/// Drops a plural "s" from words of four or more letters, but not "ss".
fn singular(word: []const u8) []const u8 {
    if (word.len < 4) return word;
    const last = std.ascii.toLower(word[word.len - 1]);
    const before = std.ascii.toLower(word[word.len - 2]);
    if (last != 's' or before == 's') return word;
    return word[0 .. word.len - 1];
}

fn freeTerms(allocator: std.mem.Allocator, terms: []const []u8) void {
    for (terms) |term| allocator.free(term);
    allocator.free(terms);
}

fn isWordChar(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}

fn isBlank(text: []const u8) bool {
    return std.mem.trim(u8, text, " \t\r\n").len == 0;
}

fn nodesWithLabel(allocator: std.mem.Allocator, tx: *c.lattice_txn, label: []const u8) ![]u64 {
    var ids: [*c]c.lattice_node_id = null;
    var count: usize = 0;
    try check(c.lattice_get_nodes_by_label_txn(tx, label.ptr, label.len, &ids, &count));
    defer if (ids != null) c.lattice_free_node_ids(ids, count);
    const out = try allocator.alloc(u64, count);
    for (out, 0..) |*slot, index| slot.* = @intCast(ids[index]);
    return out;
}

/// Sorted ids of the nodes whose native `name` property equals `value`.
fn findIdsByProperty(allocator: std.mem.Allocator, tx: *c.lattice_txn, name: []const u8, value: []const u8) ![]u64 {
    const name_z = try allocator.dupeZ(u8, name);
    defer allocator.free(name_z);
    var property = stringValue(value);
    var ids: [*c]c.lattice_node_id = null;
    var count: usize = 0;
    try check(c.lattice_nodes_find_by_label_property(tx, node_label, name_z.ptr, &property, std.math.maxInt(usize), &ids, &count));
    defer if (ids != null) c.lattice_free_node_ids(ids, count);
    const out = try allocator.alloc(u64, count);
    for (out, 0..) |*slot, index| slot.* = @intCast(ids[index]);
    std.mem.sort(u64, out, {}, std.sort.asc(u64));
    return out;
}

/// Keeps the ids of sorted `left` that sorted `right` also holds, in place,
/// and returns how many remain.
fn intersectSorted(left: []u64, right: []const u64) usize {
    var kept: usize = 0;
    var r: usize = 0;
    for (left) |id| {
        while (r < right.len and right[r] < id) r += 1;
        if (r < right.len and right[r] == id) {
            left[kept] = id;
            kept += 1;
        }
    }
    return kept;
}

fn orderU64(context: u64, item: u64) std.math.Order {
    return std.math.order(context, item);
}

/// Mirrors each indexed property into a native node property, which the
/// equality indexes read. Lattice cannot remove a property, so a value the
/// node no longer has becomes "", which `findNodes` never matches. A new node
/// only writes the values it has; an existing one rewrites what changed.
fn writeIndexedProperties(allocator: std.mem.Allocator, tx: *c.lattice_txn, node_id: u64, indexed: storage.IndexedValues, existed: bool) !void {
    for (storage.indexed_properties, indexed) |name, value| {
        const name_z = try allocator.dupeZ(u8, name);
        defer allocator.free(name_z);
        if (!existed) {
            if (value) |present| try setNodeString(tx, node_id, name_z.ptr, present);
            continue;
        }
        const current = try readNodeString(allocator, tx, node_id, name_z.ptr);
        defer if (current) |text| allocator.free(text);
        const wanted = value orelse "";
        if (std.mem.eql(u8, current orelse "", wanted)) continue;
        try setNodeString(tx, node_id, name_z.ptr, wanted);
    }
}

fn setNodeString(tx: *c.lattice_txn, node_id: u64, key: [*:0]const u8, value: []const u8) !void {
    var property = stringValue(value);
    try check(c.lattice_node_set_property(tx, @intCast(node_id), key, &property));
}

fn setEdgeString(tx: *c.lattice_txn, edge_id: c.lattice_edge_id, key: [*:0]const u8, value: []const u8) !void {
    var property = stringValue(value);
    try check(c.lattice_edge_set_property(tx, edge_id, key, &property));
}

fn readNodeString(allocator: std.mem.Allocator, tx: *c.lattice_txn, node_id: u64, key: [*:0]const u8) !?[]u8 {
    var value: c.lattice_value = std.mem.zeroes(c.lattice_value);
    const rc = c.lattice_node_get_property(tx, @intCast(node_id), key, &value);
    if (rc == c.LATTICE_ERROR_NOT_FOUND) return null;
    try check(rc);
    defer c.lattice_value_free(&value);
    return try ownedString(allocator, value);
}

fn readEdgeString(allocator: std.mem.Allocator, tx: *c.lattice_txn, edge_id: c.lattice_edge_id, key: [*:0]const u8) !?[]u8 {
    var value: c.lattice_value = std.mem.zeroes(c.lattice_value);
    const rc = c.lattice_edge_get_property(tx, edge_id, key, &value);
    if (rc == c.LATTICE_ERROR_NOT_FOUND) return null;
    try check(rc);
    defer c.lattice_value_free(&value);
    return try ownedString(allocator, value);
}

fn ownedString(allocator: std.mem.Allocator, value: c.lattice_value) ![]u8 {
    if (value.type != c.LATTICE_VALUE_STRING) return error.InvalidLatticeValue;
    const string = value.data.string_val;
    if (string.len == 0) return try allocator.dupe(u8, "");
    if (string.ptr == null) return error.InvalidLatticeValue;
    return try allocator.dupe(u8, string.ptr[0..string.len]);
}

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
    return parseEmbeddingItem(allocator, data.items[0], expected_dimensions);
}

/// The vectors of a batched embeddings response, in input order. Items are
/// placed by their `index` (their position when it is absent), so a provider
/// may return them in any order, but every input must get exactly one vector.
fn parseBatchEmbeddingResponse(allocator: std.mem.Allocator, response: []const u8, count: usize, expected_dimensions: u16) ![][]f32 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response, .{});
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |object| object,
        else => return error.InvalidEmbeddingResponse,
    };
    const data = switch (root.get("data") orelse return error.InvalidEmbeddingResponse) {
        .array => |array| array,
        else => return error.InvalidEmbeddingResponse,
    };
    if (data.items.len != count) return error.InvalidEmbeddingResponse;

    const slots = try allocator.alloc(?[]f32, count);
    defer allocator.free(slots);
    @memset(slots, null);
    errdefer for (slots) |slot| if (slot) |vector| allocator.free(vector);
    for (data.items, 0..) |item, position| {
        const index: usize = switch (item) {
            .object => |object| if (object.get("index")) |value| switch (value) {
                .integer => |integer| std.math.cast(usize, integer) orelse return error.InvalidEmbeddingResponse,
                else => return error.InvalidEmbeddingResponse,
            } else position,
            else => return error.InvalidEmbeddingResponse,
        };
        if (index >= count or slots[index] != null) return error.InvalidEmbeddingResponse;
        slots[index] = try parseEmbeddingItem(allocator, item, expected_dimensions);
    }

    const vectors = try allocator.alloc([]f32, count);
    for (vectors, slots) |*vector, slot| vector.* = slot.?;
    return vectors;
}

fn parseEmbeddingItem(allocator: std.mem.Allocator, item: std.json.Value, expected_dimensions: u16) ![]f32 {
    const object = switch (item) {
        .object => |object| object,
        else => return error.InvalidEmbeddingResponse,
    };
    const embedding_value = object.get("embedding") orelse return error.InvalidEmbeddingResponse;
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

/// End of the embedding batch that starts at `start`: at most
/// `embedding_batch_max_inputs` texts and `embedding_batch_max_bytes` bytes,
/// but always at least one text.
fn embeddingBatchEnd(texts: []const []const u8, start: usize) usize {
    var end = start;
    var bytes: usize = 0;
    while (end < texts.len and end - start < embedding_batch_max_inputs) : (end += 1) {
        if (end > start and bytes + texts[end].len > embedding_batch_max_bytes) break;
        bytes += texts[end].len;
    }
    return end;
}

fn stringifyAlloc(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    try std.json.Stringify.value(value, .{}, &writer.writer);
    return writer.toOwnedSlice();
}

fn stringValue(value: []const u8) c.lattice_value {
    return .{
        .type = c.LATTICE_VALUE_STRING,
        .data = .{ .string_val = .{ .ptr = value.ptr, .len = value.len } },
    };
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
        c.LATTICE_ERROR_VALUE_TOO_LARGE => error.ValueTooLarge,
        c.LATTICE_ERROR_DATABASE_LOCKED => error.DatabaseLocked,
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

fn appendIssueFmt(
    allocator: std.mem.Allocator,
    issues: *std.ArrayList(storage.VerificationIssue),
    code: []const u8,
    message: []const u8,
    comptime ref_format: []const u8,
    ref_args: anytype,
) !void {
    const issue_ref = try std.fmt.allocPrint(allocator, ref_format, ref_args);
    errdefer allocator.free(issue_ref);
    try issues.append(allocator, .{
        .code = code,
        .message = message,
        .qid = issue_ref,
    });
}

fn putOwnedKey(allocator: std.mem.Allocator, set: *std.StringHashMap(void), key: []const u8) !void {
    const owned = try allocator.dupe(u8, key);
    errdefer allocator.free(owned);
    try set.put(owned, {});
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

fn isReservedLabel(label: []const u8) bool {
    return std.mem.eql(u8, label, node_label) or std.mem.eql(u8, label, search_label);
}

fn isSearchableLabel(label: []const u8) bool {
    return !isInternalLabel(label) and !std.mem.eql(u8, label, "Session") and !std.mem.eql(u8, label, "Turn");
}

fn isVectorIndexedLabel(label: []const u8) bool {
    return std.mem.eql(u8, label, "Message") or
        std.mem.eql(u8, label, "Chunk") or
        std.mem.eql(u8, label, "MemoryCard") or
        std.mem.eql(u8, label, "Fact") or
        std.mem.eql(u8, label, "Preference") or
        std.mem.eql(u8, label, "Procedure") or
        std.mem.eql(u8, label, "Assertion") or
        std.mem.eql(u8, label, "Core");
}

fn jsonString(value: ?std.json.Value) ?[]const u8 {
    const present = value orelse return null;
    return switch (present) {
        .string => |string| string,
        else => null,
    };
}

fn jsonBool(value: ?std.json.Value) ?bool {
    const present = value orelse return null;
    return switch (present) {
        .bool => |boolean| boolean,
        else => null,
    };
}

fn appendStringArrayField(writer: *std.Io.Writer, value: ?std.json.Value) !void {
    const present = value orelse return;
    switch (present) {
        .array => |array| for (array.items) |item| {
            const string = jsonString(item) orelse continue;
            if (isBlank(string)) continue;
            try writer.print("\n{s}", .{string});
        },
        .string => |string| if (!isBlank(string)) try writer.print("\n{s}", .{string}),
        else => {},
    }
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

const TestStore = struct {
    tmp: std.testing.TmpDir,
    path: []u8,

    fn init(name: []const u8) !TestStore {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/{s}", .{ tmp.sub_path[0..], name });
        return .{ .tmp = tmp, .path = path };
    }

    fn deinit(self: *TestStore) void {
        std.testing.allocator.free(self.path);
        self.tmp.cleanup();
    }

    fn open(self: *TestStore) !LatticeAdapter {
        return LatticeAdapter.open(std.testing.allocator, self.path, .{ .io = std.testing.io });
    }
};

fn testPut(store: storage.Adapter, qid: []const u8, label: []const u8, properties_json: []const u8) !void {
    try store.putNode(.{ .qid = qid, .label = label, .properties_json = properties_json });
}

fn testEdge(store: storage.Adapter, qid: []const u8, from_qid: []const u8, to_qid: []const u8, edge_type: []const u8, properties_json: []const u8) !void {
    try store.putEdge(.{ .qid = qid, .from_qid = from_qid, .to_qid = to_qid, .edge_type = edge_type, .properties_json = properties_json });
}

fn freeTestHits(hits: []const storage.SearchHit) void {
    for (hits) |hit| std.testing.allocator.free(hit.qid);
    std.testing.allocator.free(hits);
}

fn freeTestIssues(issues: []const storage.VerificationIssue) void {
    freeIssues(std.testing.allocator, issues);
    std.testing.allocator.free(issues);
}

fn expectSearch(store: storage.Adapter, text: []const u8, limit: usize, expected: []const []const u8) !void {
    const hits = try store.fullTextSearch(std.testing.allocator, .{ .text = text, .limit = limit });
    defer freeTestHits(hits);
    if (hits.len != expected.len) {
        std.debug.print("search \"{s}\": expected {d} hits, got {d}\n", .{ text, expected.len, hits.len });
        for (hits) |hit| std.debug.print("  {s} {d}\n", .{ hit.qid, hit.score });
        return error.TestUnexpectedResult;
    }
    for (expected, hits) |qid, hit| try std.testing.expectEqualStrings(qid, hit.qid);
}

fn hitsContain(hits: []const storage.SearchHit, qid: []const u8) bool {
    for (hits) |hit| {
        if (std.mem.eql(u8, hit.qid, qid)) return true;
    }
    return false;
}

test "lattice adapter persists stream records with native sequences" {
    var store = try TestStore.init("stream.lattice");
    defer store.deinit();

    {
        var state = try store.open();
        defer state.deinit();
        const adapter = state.adapter();
        try std.testing.expectEqual(@as(u64, 1), (try adapter.appendStream("quipu.audit", "{\"n\":1}")).sequence);
        try std.testing.expectEqual(@as(u64, 2), (try adapter.appendStream("quipu.audit", "{\"n\":2}")).sequence);
        try std.testing.expectEqual(@as(u64, 1), (try adapter.appendStream("quipu.other", "{\"n\":1}")).sequence);
        try std.testing.expectEqual(@as(u64, 3), (try adapter.appendStream("quipu.audit", "{\"n\":3}")).sequence);
    }

    var state = try store.open();
    defer state.deinit();
    const adapter = state.adapter();
    try std.testing.expectEqual(@as(u64, 4), (try adapter.appendStream("quipu.audit", "{\"n\":4}")).sequence);

    const all = try adapter.readStream(std.testing.allocator, "quipu.audit", 0, 10);
    defer freeStreamEntries(std.testing.allocator, all);
    try std.testing.expectEqual(@as(usize, 4), all.len);
    for (all, 1..) |entry, sequence| {
        try std.testing.expectEqual(@as(u64, sequence), entry.sequence);
        try std.testing.expectEqualStrings("quipu.audit", entry.stream);
    }
    try std.testing.expectEqualStrings("{\"n\":1}", all[0].payload_json);

    const page = try adapter.readStream(std.testing.allocator, "quipu.audit", 2, 1);
    defer freeStreamEntries(std.testing.allocator, page);
    try std.testing.expectEqual(@as(usize, 1), page.len);
    try std.testing.expectEqual(@as(u64, 3), page[0].sequence);
    try std.testing.expectEqualStrings("{\"n\":3}", page[0].payload_json);
}

test "lattice adapter ranks full-text hits by BM25 over any query term" {
    var store = try TestStore.init("rank.lattice");
    defer store.deinit();
    var state = try store.open();
    defer state.deinit();
    const adapter = state.adapter();

    // Weak matches first, so insertion order disagrees with rank order.
    var qid_buffer: [32]u8 = undefined;
    for (0..20) |index| {
        const qid = try std.fmt.bufPrint(&qid_buffer, "q_msg_{d}", .{index + 1});
        try testPut(adapter, qid, "Message", "{\"content\":\"an apple a day keeps the doctor away, says the orchard sign\",\"projectId\":\"alpha\"}");
    }
    try testPut(adapter, "q_msg_100", "Message", "{\"content\":\"apple banana smoothie\",\"projectId\":\"alpha\"}");
    try testPut(adapter, "q_msg_101", "Message", "{\"content\":\"durian\",\"projectId\":\"alpha\"}");

    // Best first, truncated after ranking.
    try expectSearch(adapter, "apple banana", 1, &.{"q_msg_100"});
    // Any term matches: zebra is absent everywhere.
    try expectSearch(adapter, "banana zebra", 10, &.{"q_msg_100"});
    // Plurals and singulars match each other.
    try expectSearch(adapter, "bananas", 10, &.{"q_msg_100"});

    const hits = try adapter.fullTextSearch(std.testing.allocator, .{ .text = "apple banana", .limit = 100 });
    defer freeTestHits(hits);
    try std.testing.expectEqual(@as(usize, 21), hits.len);
    try std.testing.expectEqualStrings("q_msg_100", hits[0].qid);
    for (hits[1..], hits[0 .. hits.len - 1]) |hit, previous| try std.testing.expect(hit.score <= previous.score);

    // Only the node's text is indexed: property names and other values are not.
    try expectSearch(adapter, "projectId", 10, &.{});
    try expectSearch(adapter, "alpha", 10, &.{});
    try expectSearch(adapter, "content", 10, &.{});
    // Stopwords and punctuation alone find nothing.
    try expectSearch(adapter, "the", 10, &.{});
    try expectSearch(adapter, "  ?! ", 10, &.{});
}

test "lattice adapter indexes text far past the old 2KB cutoff" {
    var store = try TestStore.init("long.lattice");
    defer store.deinit();
    var state = try store.open();
    defer state.deinit();
    const adapter = state.adapter();

    var content = std.ArrayList(u8).empty;
    defer content.deinit(std.testing.allocator);
    try content.appendSlice(std.testing.allocator, "{\"content\":\"");
    for (0..1000) |_| try content.appendSlice(std.testing.allocator, "filler ");
    try content.appendSlice(std.testing.allocator, "quetzalcoatl\"}");
    try testPut(adapter, "q_msg_1", "Message", content.items);
    try expectSearch(adapter, "quetzalcoatl", 10, &.{"q_msg_1"});
}

test "lattice adapter keeps unsearchable nodes out of search but enumerates them" {
    var store = try TestStore.init("visibility.lattice");
    defer store.deinit();

    {
        var state = try store.open();
        defer state.deinit();
        const adapter = state.adapter();
        try testPut(adapter, "q_sess_1", "Session", "{\"kind\":\"session\",\"content\":\"walrus\"}");
        try testPut(adapter, "q_turn_2", "Turn", "{\"kind\":\"turn\",\"content\":\"walrus\"}");
        try testPut(adapter, "q_job_3", "Job", "{\"status\":\"pending\",\"content\":\"walrus\"}");
        try testPut(adapter, "q_msg_4", "Message", "{\"content\":\"walrus long message\",\"searchable\":false}");
        try testPut(adapter, "q_chunk_5", "Chunk", "{\"kind\":\"chunk\",\"content\":\"walrus chunk\",\"messageQid\":\"q_msg_4\"}");
        try testPut(adapter, "q_msg_6", "Message", "{\"content\":\"walrus short message\"}");
        try testPut(adapter, "q_fb_7", "Feedback", "{\"rating\":\"walrus\"}");

        try expectSearch(adapter, "walrus", 10, &.{ "q_chunk_5", "q_msg_6" });
        try expectSearch(adapter, "", 100, &.{ "q_sess_1", "q_turn_2", "q_job_3", "q_msg_4", "q_chunk_5", "q_msg_6", "q_fb_7" });
        try expectSearch(adapter, "", 2, &.{ "q_sess_1", "q_turn_2" });
        // A label name is an ordinary query term, not an enumeration.
        try expectSearch(adapter, "Job", 10, &.{});
        try expectSearch(adapter, "Message", 10, &.{"q_msg_6"});

        // Forgetting drops a node from search; so does becoming unsearchable.
        try testPut(adapter, "q_chunk_5", "Chunk", "{\"kind\":\"tombstone\",\"deleted\":true,\"state\":\"deleted\"}");
        try testPut(adapter, "q_msg_6", "Message", "{\"content\":\"walrus short message\",\"searchable\":false}");
        try expectSearch(adapter, "walrus", 10, &.{});
        // And coming back makes it searchable again.
        try testPut(adapter, "q_msg_4", "Message", "{\"content\":\"walrus long message\"}");
        try expectSearch(adapter, "walrus", 10, &.{"q_msg_4"});
    }

    var state = try store.open();
    defer state.deinit();
    const adapter = state.adapter();
    try expectSearch(adapter, "walrus", 10, &.{"q_msg_4"});
    try expectSearch(adapter, "", 100, &.{ "q_sess_1", "q_turn_2", "q_job_3", "q_msg_4", "q_chunk_5", "q_msg_6", "q_fb_7" });
    try std.testing.expectEqual(@as(u64, 8), state.nextRuntimeId());

    const tombstone = (try adapter.getNode(std.testing.allocator, "q_chunk_5")).?;
    defer adapter.freeNode(std.testing.allocator, tombstone);
    try std.testing.expectEqualStrings("Chunk", tombstone.label);
    try std.testing.expect(std.mem.indexOf(u8, tombstone.properties_json, "walrus") == null);

    const issues = try adapter.verify(std.testing.allocator);
    defer freeTestIssues(issues);
    try std.testing.expectEqual(@as(usize, 0), issues.len);
}

test "lattice adapter finds entities by canonical name and aliases" {
    var store = try TestStore.init("entity.lattice");
    defer store.deinit();
    var state = try store.open();
    defer state.deinit();
    const adapter = state.adapter();

    try testPut(adapter, "q_ent_1", "Entity", "{\"kind\":\"entity\",\"canonicalName\":\"Margaret Hamilton\",\"entityType\":\"person\",\"aliases\":[\"Maggie\",\"M. Hamilton\"]}");
    try testPut(adapter, "q_msg_2", "Message", "{\"content\":\"lunch plans\"}");
    try expectSearch(adapter, "hamilton", 10, &.{"q_ent_1"});
    try expectSearch(adapter, "who is maggie", 10, &.{"q_ent_1"});
    try expectSearch(adapter, "person", 10, &.{});
}

test "lattice adapter finds nodes by label and property in creation order" {
    var store = try TestStore.init("find-nodes.lattice");
    defer store.deinit();
    {
        var state = try store.open();
        defer state.deinit();
        try storage.expectFindNodesContract(state.adapter());
    }
    // Indexes and creation order survive a reopen.
    var state = try store.open();
    defer state.deinit();
    const page = try state.adapter().findNodes(std.testing.allocator, .{ .where = &.{.{ .name = "slotKey", .value = "project.package_manager" }} });
    defer state.adapter().freeNodePage(std.testing.allocator, page);
    try std.testing.expectEqual(@as(usize, 2), page.qids.len);
    try std.testing.expectEqualStrings("q_fact_1", page.qids[0]);
    try std.testing.expectEqualStrings("q_card_4", page.qids[1]);
}

test "lattice adapter backfills property indexes for stores written without them" {
    var store = try TestStore.init("find-nodes-backfill.lattice");
    defer store.deinit();
    {
        var state = try store.open();
        defer state.deinit();
        try testPut(state.adapter(), "q_fact_1", "Fact", "{\"slotKey\":\"project.test_command\",\"state\":\"current\"}");
        try testPut(state.adapter(), "q_core_2", "Core", "{\"blockKey\":\"project_summary\"}");
        // Simulate a store from before the indexes: no native copies, no index.
        const tx = try state.beginWrite();
        for ([_][]const u8{ "q_fact_1", "q_core_2" }) |qid| {
            const node_id = state.qid_to_node.get(qid).?.node_id;
            try setNodeString(tx, node_id, "slotKey", "");
            try setNodeString(tx, node_id, "state", "");
            try setNodeString(tx, node_id, "blockKey", "");
        }
        try check(c.lattice_commit(tx));
        try check(c.lattice_node_property_index_drop(state.db, node_label, "slotKey"));
        try check(c.lattice_node_property_index_drop(state.db, node_label, "blockKey"));
    }
    var state = try store.open();
    defer state.deinit();
    const adapter = state.adapter();
    for ([_]storage.PropertyMatch{
        .{ .name = "slotKey", .value = "project.test_command" },
        .{ .name = "state", .value = "current" },
        .{ .name = "blockKey", .value = "project_summary" },
    }) |match| {
        const where = [_]storage.PropertyMatch{match};
        const page = try adapter.findNodes(std.testing.allocator, .{ .where = &where });
        defer adapter.freeNodePage(std.testing.allocator, page);
        try std.testing.expectEqual(@as(usize, 1), page.qids.len);
    }
}

test "lattice adapter stores edges as native lattice edges" {
    var store = try TestStore.init("edges.lattice");
    defer store.deinit();

    {
        var state = try store.open();
        defer state.deinit();
        const adapter = state.adapter();
        try testPut(adapter, "q_turn_1", "Turn", "{}");
        try testPut(adapter, "q_msg_2", "Message", "{\"content\":\"one\"}");
        try testPut(adapter, "q_msg_3", "Message", "{\"content\":\"two\"}");
        try testPut(adapter, "q_ent_4", "Entity", "{\"canonicalName\":\"Ada\"}");
        try testEdge(adapter, "q_edge_10", "q_turn_1", "q_msg_2", "HAS_MESSAGE", "{}");
        try testEdge(adapter, "q_edge_11", "q_turn_1", "q_msg_3", "HAS_MESSAGE", "{}");
        try testEdge(adapter, "q_edge_42", "q_msg_3", "q_ent_4", "MENTIONS", "{}");
        // Same qid again updates rather than duplicates.
        try testEdge(adapter, "q_edge_42", "q_msg_3", "q_ent_4", "MENTIONS", "{\"weight\":2}");
        try std.testing.expectError(error.NotFound, testEdge(adapter, "q_edge_50", "q_turn_1", "q_missing_9", "HAS_MESSAGE", "{}"));
    }

    var state = try store.open();
    defer state.deinit();
    const adapter = state.adapter();
    try std.testing.expectEqual(@as(u64, 43), state.nextRuntimeId());

    const from_turn = try adapter.findEdges(std.testing.allocator, .{ .from_qid = "q_turn_1" });
    defer adapter.freeEdges(std.testing.allocator, from_turn);
    try std.testing.expectEqual(@as(usize, 2), from_turn.len);
    for (from_turn) |edge| {
        try std.testing.expectEqualStrings("q_turn_1", edge.from_qid);
        try std.testing.expectEqualStrings("HAS_MESSAGE", edge.edge_type);
        try std.testing.expectEqualStrings("{}", edge.properties_json);
    }

    const limited = try adapter.findEdges(std.testing.allocator, .{ .from_qid = "q_turn_1", .edge_type = "HAS_MESSAGE", .limit = 1 });
    defer adapter.freeEdges(std.testing.allocator, limited);
    try std.testing.expectEqual(@as(usize, 1), limited.len);

    const mentions = try adapter.findEdges(std.testing.allocator, .{ .to_qid = "q_ent_4", .edge_type = "MENTIONS" });
    defer adapter.freeEdges(std.testing.allocator, mentions);
    try std.testing.expectEqual(@as(usize, 1), mentions.len);
    try std.testing.expectEqualStrings("q_edge_42", mentions[0].qid);
    try std.testing.expectEqualStrings("q_msg_3", mentions[0].from_qid);
    try std.testing.expectEqualStrings("{\"weight\":2}", mentions[0].properties_json);

    const into_msg = try adapter.findEdges(std.testing.allocator, .{ .to_qid = "q_msg_3" });
    defer adapter.freeEdges(std.testing.allocator, into_msg);
    try std.testing.expectEqual(@as(usize, 1), into_msg.len);
    try std.testing.expectEqualStrings("q_edge_11", into_msg[0].qid);

    const pair = try adapter.findEdges(std.testing.allocator, .{ .from_qid = "q_turn_1", .to_qid = "q_msg_2" });
    defer adapter.freeEdges(std.testing.allocator, pair);
    try std.testing.expectEqual(@as(usize, 1), pair.len);
    try std.testing.expectEqualStrings("q_edge_10", pair[0].qid);

    const wrong_type = try adapter.findEdges(std.testing.allocator, .{ .from_qid = "q_turn_1", .edge_type = "MENTIONS" });
    defer adapter.freeEdges(std.testing.allocator, wrong_type);
    try std.testing.expectEqual(@as(usize, 0), wrong_type.len);

    const all = try adapter.findEdges(std.testing.allocator, .{});
    defer adapter.freeEdges(std.testing.allocator, all);
    try std.testing.expectEqual(@as(usize, 3), all.len);

    const by_type = try adapter.findEdges(std.testing.allocator, .{ .edge_type = "MENTIONS" });
    defer adapter.freeEdges(std.testing.allocator, by_type);
    try std.testing.expectEqual(@as(usize, 1), by_type.len);

    const issues = try adapter.verify(std.testing.allocator);
    defer freeTestIssues(issues);
    try std.testing.expectEqual(@as(usize, 0), issues.len);
}

fn rawVectorSearchHas(state: *LatticeAdapter, vector: []const f32, node_id: u64) !bool {
    var result: ?*c.lattice_vector_result = null;
    try check(c.lattice_vector_search(state.db, vector.ptr, @intCast(vector.len), 50, 0, &result));
    defer if (result) |ptr| c.lattice_vector_result_free(ptr);
    const count = c.lattice_vector_result_count(result);
    var index: u32 = 0;
    while (index < count) : (index += 1) {
        var found: c.lattice_node_id = 0;
        var distance: f32 = 0;
        try check(c.lattice_vector_result_get(result, index, &found, &distance));
        if (found == node_id) return true;
    }
    return false;
}

test "lattice adapter vectors searchable chunks and drops forgotten vectors" {
    var store = try TestStore.init("vectors.lattice");
    defer store.deinit();
    var state = try store.open();
    defer state.deinit();
    const adapter = state.adapter();

    try testPut(adapter, "q_msg_1", "Message", "{\"content\":\"the whole long message\",\"searchable\":false}");
    try testPut(adapter, "q_chunk_2", "Chunk", "{\"kind\":\"chunk\",\"content\":\"we adopted a beagle named Biscuit\"}");
    try testPut(adapter, "q_chunk_3", "Chunk", "{\"kind\":\"chunk\",\"content\":\"the quarterly budget review\"}");
    try testPut(adapter, "q_sess_4", "Session", "{\"content\":\"we adopted a beagle named Biscuit\"}");

    const query = try adapter.embedText(std.testing.allocator, "we adopted a beagle named Biscuit");
    defer std.testing.allocator.free(query);
    {
        const hits = try adapter.vectorSearch(std.testing.allocator, .{ .vector = query, .limit = 10 });
        defer freeTestHits(hits);
        try std.testing.expectEqual(@as(usize, 2), hits.len);
        try std.testing.expectEqualStrings("q_chunk_2", hits[0].qid);
        try std.testing.expect(!hitsContain(hits, "q_msg_1"));
        try std.testing.expect(!hitsContain(hits, "q_sess_4"));
    }

    const chunk_node = state.qid_to_node.get("q_chunk_2").?.node_id;
    try std.testing.expect(try rawVectorSearchHas(&state, query, chunk_node));
    try testPut(adapter, "q_chunk_2", "Chunk", "{\"kind\":\"tombstone\",\"deleted\":true}");
    {
        const hits = try adapter.vectorSearch(std.testing.allocator, .{ .vector = query, .limit = 10 });
        defer freeTestHits(hits);
        try std.testing.expectEqual(@as(usize, 1), hits.len);
        try std.testing.expectEqualStrings("q_chunk_3", hits[0].qid);
    }
    // The vector itself is gone, not just filtered out.
    try std.testing.expect(!(try rawVectorSearchHas(&state, query, chunk_node)));
    // The node keeps its labels.
    const chunks = try state.enumerateLabel(std.testing.allocator, "Chunk", 10);
    defer freeTestHits(chunks);
    try std.testing.expectEqual(@as(usize, 2), chunks.len);
}

test "lattice adapter round-trips 64KB string properties" {
    var store = try TestStore.init("large.lattice");
    defer store.deinit();

    const allocator = std.testing.allocator;
    var content = std.ArrayList(u8).empty;
    defer content.deinit(allocator);
    var word: usize = 0;
    while (content.items.len < 64 * 1024) : (word += 1) {
        try content.print(allocator, "w{d} ", .{word});
    }
    try content.appendSlice(allocator, "axolotl");
    const properties_json = try stringifyAlloc(allocator, .{ .kind = "message", .content = content.items });
    defer allocator.free(properties_json);
    const edge_properties = try stringifyAlloc(allocator, .{ .note = content.items });
    defer allocator.free(edge_properties);

    {
        var state = try store.open();
        defer state.deinit();
        const adapter = state.adapter();
        try testPut(adapter, "q_msg_1", "Message", properties_json);
        try testPut(adapter, "q_msg_2", "Message", "{\"content\":\"short\"}");
        try testEdge(adapter, "q_edge_3", "q_msg_1", "q_msg_2", "NEXT", edge_properties);
    }

    var state = try store.open();
    defer state.deinit();
    const adapter = state.adapter();
    const node = (try adapter.getNode(allocator, "q_msg_1")).?;
    defer adapter.freeNode(allocator, node);
    try std.testing.expect(properties_json.len > 64 * 1024);
    try std.testing.expectEqualStrings(properties_json, node.properties_json);
    try expectSearch(adapter, "axolotl", 10, &.{"q_msg_1"});

    const edges = try adapter.findEdges(allocator, .{ .from_qid = "q_msg_1" });
    defer adapter.freeEdges(allocator, edges);
    try std.testing.expectEqual(@as(usize, 1), edges.len);
    try std.testing.expectEqualStrings(edge_properties, edges[0].properties_json);
}

fn slowTestsEnabled() !bool {
    return std.testing.environ.containsUnempty(std.testing.allocator, "QUIPU_LATTICE_SLOW_TESTS");
}

/// Writes `count` vector-indexed messages with `dimensions`-wide hash vectors,
/// reopens the store, and checks every 50th message is its own nearest
/// neighbour.
fn checkVectorPersistence(name: []const u8, dimensions: u16, page_size: u32, count: usize) !void {
    const allocator = std.testing.allocator;
    var store = try TestStore.init(name);
    defer store.deinit();
    const options = Options{ .io = std.testing.io, .vector_dimensions = dimensions, .page_size = page_size };

    var text_buffer: [512]u8 = undefined;
    var content_buffer: [600]u8 = undefined;
    var qid_buffer: [32]u8 = undefined;
    var before = std.ArrayList(u8).empty;
    defer before.deinit(allocator);
    {
        var state = try LatticeAdapter.open(allocator, store.path, options);
        defer state.deinit();
        const adapter = state.adapter();
        for (0..count) |index| {
            const content = try std.fmt.bufPrint(&content_buffer, "{{\"content\":\"{s}\"}}", .{try fixtureText(&text_buffer, index)});
            const qid = try std.fmt.bufPrint(&qid_buffer, "q_msg_{d}", .{index + 1});
            try testPut(adapter, qid, "Message", content);
        }
        try sampleNearestNeighbours(&state, dimensions, count, &before);
    }

    var state = try LatticeAdapter.open(allocator, store.path, options);
    defer state.deinit();
    try std.testing.expectEqual(@as(u64, count + 1), state.nextRuntimeId());
    var after = std.ArrayList(u8).empty;
    defer after.deinit(allocator);
    try sampleNearestNeighbours(&state, dimensions, count, &after);
    // The reopened index answers exactly as the one that wrote it.
    try std.testing.expectEqualStrings(before.items, after.items);
}

/// 48 words from a shared 400-word vocabulary, so hash embeddings overlap the
/// way text embeddings do instead of being nearly orthogonal.
fn fixtureText(buffer: []u8, index: usize) ![]const u8 {
    var writer = std.Io.Writer.fixed(buffer);
    var seed: u64 = index *% 0x9E3779B97F4A7C15 +% 1;
    for (0..48) |word| {
        seed = seed *% 6364136223846793005 +% 1442695040888963407;
        if (word > 0) try writer.writeByte(' ');
        try writer.print("w{d}", .{(seed >> 33) % 400});
    }
    return writer.buffered();
}

/// Records the top five qids for every 50th fixture into `out`, and requires
/// nearly every fixture to find itself first.
fn sampleNearestNeighbours(state: *LatticeAdapter, dimensions: u16, count: usize, out: *std.ArrayList(u8)) !void {
    const allocator = std.testing.allocator;
    const adapter = state.adapter();
    var text_buffer: [512]u8 = undefined;
    var qid_buffer: [32]u8 = undefined;
    var samples: usize = 0;
    var found_self: usize = 0;
    var index: usize = 0;
    while (index < count) : (index += 50) {
        const vector = try adapter.embedText(allocator, try fixtureText(&text_buffer, index));
        defer allocator.free(vector);
        try std.testing.expectEqual(@as(usize, dimensions), vector.len);
        const hits = try adapter.vectorSearch(allocator, .{ .vector = vector, .limit = 5 });
        defer freeTestHits(hits);
        try std.testing.expectEqual(@as(usize, 5), hits.len);
        for (hits) |hit| try out.print(allocator, "{s} ", .{hit.qid});
        try out.append(allocator, '\n');
        samples += 1;
        if (std.mem.eql(u8, try std.fmt.bufPrint(&qid_buffer, "q_msg_{d}", .{index + 1}), hits[0].qid)) found_self += 1;
    }
    if (found_self * 10 < samples * 9) {
        std.debug.print("only {d} of {d} fixtures were their own nearest neighbour\n", .{ found_self, samples });
        return error.TestUnexpectedResult;
    }
}

test "lattice adapter persists 1536-dimension vectors across reopen on 8KB pages" {
    if (!try slowTestsEnabled()) return error.SkipZigTest;
    // The page size main.zig picks for 1536 dimensions.
    try checkVectorPersistence("vectors-1536-8k.lattice", 1536, 8192, 2000);
}

test "lattice adapter persists 1536-dimension vectors across reopen on 4KB pages" {
    if (!try slowTestsEnabled()) return error.SkipZigTest;
    // A 6KB vector does not fit in a 4KB page.
    try checkVectorPersistence("vectors-1536-4k.lattice", 1536, 4096, 2000);
}

/// Writes `count` nodes and prints the mean write time of each tenth, so a
/// write cost that grows with the store shows up as rising numbers.
fn timeNodeWrites(name: []const u8, label: []const u8, count: usize) !void {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var store = try TestStore.init(name);
    defer store.deinit();
    var state = try store.open();
    defer state.deinit();
    const adapter = state.adapter();

    var text_buffer: [512]u8 = undefined;
    var content_buffer: [600]u8 = undefined;
    var qid_buffer: [32]u8 = undefined;
    var line = std.ArrayList(u8).empty;
    defer line.deinit(allocator);
    const tenth = count / 10;
    const started = std.Io.Timestamp.now(io, .awake);
    var bucket_start = started;
    for (0..count) |index| {
        const content = try std.fmt.bufPrint(&content_buffer, "{{\"content\":\"{s}\"}}", .{try fixtureText(&text_buffer, index)});
        const qid = try std.fmt.bufPrint(&qid_buffer, "q_n_{d}", .{index + 1});
        try testPut(adapter, qid, label, content);
        if ((index + 1) % tenth == 0) {
            const elapsed = bucket_start.untilNow(io, .awake);
            try line.print(allocator, " {d:.2}", .{@as(f64, @floatFromInt(elapsed.toNanoseconds())) / @as(f64, @floatFromInt(tenth)) / 1e6});
            bucket_start = std.Io.Timestamp.now(io, .awake);
        }
    }
    const total = started.untilNow(io, .awake);
    std.debug.print("\n{s} x{d}: total {d} ms; ms/node by tenth:{s}\n", .{ label, count, total.toMilliseconds(), line.items });
}

test "lattice adapter node write timing" {
    if (!try slowTestsEnabled()) return error.SkipZigTest;
    // Not searchable: node and properties only.
    try timeNodeWrites("timing-session.lattice", "Session", 5000);
    // Searchable, no vector.
    try timeNodeWrites("timing-observation.lattice", "Observation", 5000);
    // Searchable with a vector.
    try timeNodeWrites("timing-message.lattice", "Message", 5000);
}

test "lattice adapter verify flags derived nodes without live evidence" {
    var store = try TestStore.init("verify.lattice");
    defer store.deinit();
    var state = try store.open();
    defer state.deinit();
    const adapter = state.adapter();

    try testPut(adapter, "q_msg_1", "Message", "{\"content\":\"We use pnpm.\"}");
    try testPut(adapter, "q_fact_2", "Fact", "{\"text\":\"The repo uses pnpm.\",\"state\":\"current\",\"slotKey\":\"project.package_manager\",\"evidenceQid\":\"q_msg_1\"}");
    try testEdge(adapter, "q_edge_3", "q_fact_2", "q_msg_1", "EVIDENCED_BY", "{}");
    {
        const issues = try adapter.verify(std.testing.allocator);
        defer freeTestIssues(issues);
        try std.testing.expectEqual(@as(usize, 0), issues.len);
    }

    try testPut(adapter, "q_msg_1", "Message", "{\"kind\":\"tombstone\",\"deleted\":true}");
    try testPut(adapter, "q_fact_4", "Fact", "{\"text\":\"Dangling.\",\"state\":\"current\",\"slotKey\":\"project.package_manager\",\"evidenceQid\":\"q_msg_404\"}");
    const issues = try adapter.verify(std.testing.allocator);
    defer freeTestIssues(issues);
    try std.testing.expectEqual(@as(usize, 2), issues.len);
    var saw_deleted = false;
    var saw_missing = false;
    for (issues) |issue| {
        if (std.mem.eql(u8, issue.code, "active_derived_from_deleted_evidence")) {
            saw_deleted = true;
            try std.testing.expectEqualStrings("q_fact_2", issue.qid.?);
        }
        if (std.mem.eql(u8, issue.code, "missing_evidence_node")) {
            saw_missing = true;
            try std.testing.expectEqualStrings("q_fact_4", issue.qid.?);
        }
    }
    try std.testing.expect(saw_deleted and saw_missing);
}

/// A local OpenAI-compatible embeddings endpoint. Each text embeds to a
/// pseudo-random vector derived from its hash, with components in eighths so
/// they survive the JSON round trip exactly. Batched responses list their items
/// in reverse order, so a client must place them by `index`.
const FakeEmbeddingServer = struct {
    server: std.Io.net.Server,
    url: []u8,
    thread: std.Thread,
    /// Answer batched requests with HTTP 500, as a failing provider would.
    fail_batches: bool,
    stopping: std.atomic.Value(bool) = .init(false),
    single_requests: std.atomic.Value(usize) = .init(0),
    batch_requests: std.atomic.Value(usize) = .init(0),
    batch_inputs: std.atomic.Value(usize) = .init(0),

    const dimensions: u16 = 8;

    fn start(self: *FakeEmbeddingServer, fail_batches: bool) !void {
        const io = std.testing.io;
        const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
        var server = try address.listen(io, .{ .reuse_address = true });
        errdefer server.deinit(io);
        const url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}/v1/embeddings", .{server.socket.address.getPort()});
        errdefer std.testing.allocator.free(url);
        self.* = .{ .server = server, .url = url, .thread = undefined, .fail_batches = fail_batches };
        self.thread = try std.Thread.spawn(.{}, serve, .{self});
    }

    fn stop(self: *FakeEmbeddingServer) void {
        const io = std.testing.io;
        self.stopping.store(true, .release);
        // Wake the accept the server thread is blocked in.
        if (self.server.socket.address.connect(io, .{ .mode = .stream })) |stream| {
            stream.close(io);
        } else |_| {}
        self.thread.join();
        self.server.deinit(io);
        std.testing.allocator.free(self.url);
    }

    fn options(self: *const FakeEmbeddingServer) Options {
        return .{
            .io = std.testing.io,
            .vector_dimensions = dimensions,
            .embedding_provider = .openai_compatible,
            .embedding_url = self.url,
            .embedding_model = "fake-embedding",
        };
    }

    fn requests(self: *const FakeEmbeddingServer) usize {
        return self.single_requests.load(.acquire) + self.batch_requests.load(.acquire);
    }

    fn embedding(text: []const u8) [dimensions]f32 {
        var prng = std.Random.DefaultPrng.init(std.hash.Wyhash.hash(0, text));
        const random = prng.random();
        var vector: [dimensions]f32 = undefined;
        for (&vector) |*value| {
            const magnitude: f32 = @floatFromInt(random.intRangeAtMost(i32, 1, 64));
            value.* = if (random.boolean()) magnitude / 8 else -magnitude / 8;
        }
        return vector;
    }

    fn serve(self: *FakeEmbeddingServer) void {
        const io = std.testing.io;
        while (true) {
            const stream = self.server.accept(io) catch return;
            defer stream.close(io);
            if (self.stopping.load(.acquire)) return;
            self.handle(stream) catch {};
        }
    }

    const Item = struct { object: []const u8 = "embedding", index: usize, embedding: []const f32 };

    fn handle(self: *FakeEmbeddingServer, stream: std.Io.net.Stream) !void {
        const io = std.testing.io;
        const allocator = std.testing.allocator;
        var recv_buffer: [16 * 1024]u8 = undefined;
        var send_buffer: [4 * 1024]u8 = undefined;
        var connection_reader = stream.reader(io, &recv_buffer);
        var connection_writer = stream.writer(io, &send_buffer);
        var server = std.http.Server.init(&connection_reader.interface, &connection_writer.interface);
        var request = try server.receiveHead();
        var body_buffer: [4 * 1024]u8 = undefined;
        const body_reader = try request.readerExpectContinue(&body_buffer);
        const body = try body_reader.allocRemaining(allocator, .unlimited);
        defer allocator.free(body);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
        defer parsed.deinit();

        const input = parsed.value.object.get("input").?;
        const inputs: []const std.json.Value = switch (input) {
            .string => (&input)[0..1],
            .array => |array| array.items,
            else => return error.TestUnexpectedResult,
        };
        const json_headers = [_]std.http.Header{.{ .name = "content-type", .value = "application/json" }};
        if (input == .string) {
            _ = self.single_requests.fetchAdd(1, .acq_rel);
        } else {
            _ = self.batch_requests.fetchAdd(1, .acq_rel);
            _ = self.batch_inputs.fetchAdd(inputs.len, .acq_rel);
            if (self.fail_batches) {
                try request.respond("{\"error\":{\"message\":\"batch rejected\"}}", .{
                    .status = .internal_server_error,
                    .keep_alive = false,
                    .extra_headers = &json_headers,
                });
                return;
            }
        }

        const vectors = try allocator.alloc([dimensions]f32, inputs.len);
        defer allocator.free(vectors);
        const items = try allocator.alloc(Item, inputs.len);
        defer allocator.free(items);
        for (inputs, 0..) |text, index| {
            vectors[index] = embedding(text.string);
            items[inputs.len - 1 - index] = .{ .index = index, .embedding = &vectors[index] };
        }
        const response = try stringifyAlloc(allocator, .{ .object = "list", .data = items });
        defer allocator.free(response);
        try request.respond(response, .{ .keep_alive = false, .extra_headers = &json_headers });
    }
};

/// Asserts that a vector search for the fake embedding of `text` finds exactly
/// `expected`, each at distance zero.
fn expectFakeVectorHits(store: storage.Adapter, text: []const u8, expected: []const []const u8) !void {
    const vector = FakeEmbeddingServer.embedding(text);
    const hits = try store.vectorSearch(std.testing.allocator, .{ .vector = &vector, .limit = expected.len + 1 });
    defer freeTestHits(hits);
    for (expected) |qid| {
        var found = false;
        for (hits) |hit| {
            if (!std.mem.eql(u8, hit.qid, qid)) continue;
            found = true;
            try std.testing.expectApproxEqAbs(@as(f32, 1.0), hit.score, 1e-4);
        }
        if (!found) {
            std.debug.print("vector search \"{s}\" did not find {s}\n", .{ text, qid });
            return error.TestUnexpectedResult;
        }
    }
    // Nothing else is an exact match.
    for (hits) |hit| {
        var is_expected = false;
        for (expected) |qid| is_expected = is_expected or std.mem.eql(u8, hit.qid, qid);
        if (!is_expected) try std.testing.expect(hit.score < 0.999);
    }
}

test "lattice adapter prefetches provider embeddings in one batched request" {
    var fake: FakeEmbeddingServer = undefined;
    try fake.start(false);
    defer fake.stop();
    var store = try TestStore.init("prefetch.lattice");
    defer store.deinit();
    var state = try LatticeAdapter.open(std.testing.allocator, store.path, fake.options());
    defer state.deinit();
    const adapter = state.adapter();

    // Duplicates and blank text are not sent.
    try adapter.prefetchEmbeddings(&.{ "we adopted a beagle", "the quarterly budget", "we adopted a beagle", " \n", "a ferry to zanzibar" });
    try std.testing.expectEqual(@as(usize, 1), fake.batch_requests.load(.acquire));
    try std.testing.expectEqual(@as(usize, 3), fake.batch_inputs.load(.acquire));

    try testPut(adapter, "q_msg_1", "Message", "{\"content\":\"we adopted a beagle\"}");
    try testPut(adapter, "q_msg_2", "Message", "{\"content\":\"the quarterly budget\"}");
    try testPut(adapter, "q_chunk_3", "Chunk", "{\"kind\":\"chunk\",\"content\":\"a ferry to zanzibar\"}");
    // A second node with the same text reuses the vector.
    try testPut(adapter, "q_msg_4", "Message", "{\"content\":\"we adopted a beagle\"}");
    try std.testing.expectEqual(@as(usize, 0), fake.single_requests.load(.acquire));
    // Text that was not prefetched is embedded on its own.
    try testPut(adapter, "q_msg_5", "Message", "{\"content\":\"a new espresso machine\"}");
    try std.testing.expectEqual(@as(usize, 1), fake.single_requests.load(.acquire));

    try expectFakeVectorHits(adapter, "we adopted a beagle", &.{ "q_msg_1", "q_msg_4" });
    try expectFakeVectorHits(adapter, "the quarterly budget", &.{"q_msg_2"});
    try expectFakeVectorHits(adapter, "a ferry to zanzibar", &.{"q_chunk_3"});
    try expectFakeVectorHits(adapter, "a new espresso machine", &.{"q_msg_5"});

    // Once cleared, the cache serves nothing.
    adapter.clearPrefetchedEmbeddings();
    try testPut(adapter, "q_msg_6", "Message", "{\"content\":\"the quarterly budget\"}");
    try std.testing.expectEqual(@as(usize, 2), fake.single_requests.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), fake.batch_requests.load(.acquire));

    // Forgetting drops a prefetched vector like any other.
    const beagle = FakeEmbeddingServer.embedding("we adopted a beagle");
    const forgotten = state.qid_to_node.get("q_msg_1").?.node_id;
    try std.testing.expect(try rawVectorSearchHas(&state, &beagle, forgotten));
    try testPut(adapter, "q_msg_1", "Message", "{\"kind\":\"tombstone\",\"deleted\":true}");
    try std.testing.expect(!(try rawVectorSearchHas(&state, &beagle, forgotten)));
    try expectFakeVectorHits(adapter, "we adopted a beagle", &.{"q_msg_4"});
}

test "lattice adapter embeds node by node when a batched request fails" {
    var fake: FakeEmbeddingServer = undefined;
    try fake.start(true);
    defer fake.stop();
    var store = try TestStore.init("prefetch-fallback.lattice");
    defer store.deinit();
    var state = try LatticeAdapter.open(std.testing.allocator, store.path, fake.options());
    defer state.deinit();
    const adapter = state.adapter();

    try adapter.prefetchEmbeddings(&.{ "we adopted a beagle", "the quarterly budget" });
    try std.testing.expectEqual(@as(usize, 1), fake.batch_requests.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), state.prefetched.count());

    try testPut(adapter, "q_msg_1", "Message", "{\"content\":\"we adopted a beagle\"}");
    try testPut(adapter, "q_msg_2", "Message", "{\"content\":\"the quarterly budget\"}");
    try std.testing.expectEqual(@as(usize, 2), fake.single_requests.load(.acquire));
    try expectFakeVectorHits(adapter, "we adopted a beagle", &.{"q_msg_1"});
    try expectFakeVectorHits(adapter, "the quarterly budget", &.{"q_msg_2"});
}

test "lattice adapter hash embeddings skip the prefetch" {
    var store = try TestStore.init("prefetch-hash.lattice");
    defer store.deinit();
    var state = try store.open();
    defer state.deinit();
    try state.adapter().prefetchEmbeddings(&.{"we adopted a beagle"});
    try std.testing.expectEqual(@as(usize, 0), state.prefetched.count());
}

test "embedding batches split by input count and bytes" {
    var texts: [300][]const u8 = undefined;
    for (&texts) |*text| text.* = "short";
    try std.testing.expectEqual(@as(usize, 128), embeddingBatchEnd(&texts, 0));
    try std.testing.expectEqual(@as(usize, 256), embeddingBatchEnd(&texts, 128));
    try std.testing.expectEqual(@as(usize, 300), embeddingBatchEnd(&texts, 256));

    const large = "x" ** (50 * 1024);
    const oversized = "y" ** (embedding_batch_max_bytes + 1);
    const mixed = [_][]const u8{ large, large, large, oversized, "short" };
    try std.testing.expectEqual(@as(usize, 2), embeddingBatchEnd(&mixed, 0));
    try std.testing.expectEqual(@as(usize, 3), embeddingBatchEnd(&mixed, 2));
    // A text over the byte budget still goes, alone.
    try std.testing.expectEqual(@as(usize, 4), embeddingBatchEnd(&mixed, 3));
    try std.testing.expectEqual(@as(usize, 5), embeddingBatchEnd(&mixed, 4));
}

test "batched embedding responses are placed by index and validated" {
    const allocator = std.testing.allocator;
    {
        const vectors = try parseBatchEmbeddingResponse(allocator,
            \\{"data":[{"index":1,"embedding":[3,4]},{"index":0,"embedding":[1.5,2]}]}
        , 2, 2);
        defer {
            for (vectors) |vector| allocator.free(vector);
            allocator.free(vectors);
        }
        try std.testing.expectEqualSlices(f32, &.{ 1.5, 2 }, vectors[0]);
        try std.testing.expectEqualSlices(f32, &.{ 3, 4 }, vectors[1]);
    }
    const invalid = [_][]const u8{
        // Too few items, a repeated index, an index out of range, wrong dimensions.
        \\{"data":[{"index":0,"embedding":[1,2]}]}
        ,
        \\{"data":[{"index":0,"embedding":[1,2]},{"index":0,"embedding":[3,4]}]}
        ,
        \\{"data":[{"index":0,"embedding":[1,2]},{"index":2,"embedding":[3,4]}]}
        ,
        \\{"data":[{"index":0,"embedding":[1,2]},{"index":1,"embedding":[3]}]}
        ,
    };
    for (invalid) |response| {
        if (parseBatchEmbeddingResponse(allocator, response, 2, 2)) |vectors| {
            for (vectors) |vector| allocator.free(vector);
            allocator.free(vectors);
            return error.TestUnexpectedResult;
        } else |_| {}
    }
}

fn testChunkQid(buffer: []u8, message_qid: []const u8, index: usize) ![]const u8 {
    return std.fmt.bufPrint(buffer, "q_chunk_{s}_{d}", .{ message_qid["q_msg_".len..], index });
}

test "memory.remember embeds its messages, chunks and extractions in one request" {
    const runtime_module = @import("runtime.zig");
    const schema = @import("schema.zig");
    const protocol = @import("protocol.zig");
    const allocator = std.testing.allocator;

    var fake: FakeEmbeddingServer = undefined;
    try fake.start(false);
    defer fake.stop();
    var store = try TestStore.init("remember-batch.lattice");
    defer store.deinit();
    var state = try LatticeAdapter.open(allocator, store.path, fake.options());
    defer state.deinit();
    const adapter = state.adapter();
    try schema.ensure(allocator, adapter);
    var runtime = runtime_module.Runtime.init(adapter, protocol.Health.default());
    defer runtime.deinit();

    // 1734 bytes in three paragraphs, so the message is split into chunks.
    const paragraph = "We walked the dog along the river trail today. " ** 12 ++ "End of part.\n\n";
    const long = paragraph ++ paragraph ++ paragraph;
    const request =
        \\{"jsonrpc":"2.0","id":"r1","method":"memory.remember","params":{"scope":{"projectId":"repo:test"},"sessionId":"s1","messages":[
    ++
        \\{"role":"user","content":"We adopted a beagle named Biscuit."},
    ++
        \\{"role":"assistant","content":"
    ++ long ++
        \\"},
    ++
        \\{"role":"user","content":"I prefer concise responses."},
    ++
        \\{"role":"user","content":"We adopted a beagle named Biscuit."}]}}
    ;
    const escaped = try std.mem.replaceOwned(u8, allocator, request, "\n", "\\n");
    defer allocator.free(escaped);
    const response = try runtime.dispatch(allocator, escaped);
    defer allocator.free(response);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"status\":\"stored\"") != null);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response, .{});
    defer parsed.deinit();
    const qids = parsed.value.object.get("result").?.object.get("messageQids").?.array.items;
    try std.testing.expectEqual(@as(usize, 4), qids.len);
    const long_qid = qids[1].string;

    var buffer: [64]u8 = undefined;
    var chunk_count: usize = 0;
    while (state.qid_to_node.contains(try testChunkQid(&buffer, long_qid, chunk_count))) chunk_count += 1;
    try std.testing.expect(chunk_count >= 2);

    // One request carries the distinct texts: the short message once though it
    // was sent twice, each chunk, the other message, and the extracted
    // preference text that its Preference and MemoryCard share.
    try std.testing.expectEqual(@as(usize, 1), fake.requests());
    try std.testing.expectEqual(@as(usize, 1), fake.batch_requests.load(.acquire));
    try std.testing.expectEqual(@as(usize, 3 + chunk_count), fake.batch_inputs.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), state.prefetched.count());

    try expectFakeVectorHits(adapter, "We adopted a beagle named Biscuit.", &.{ qids[0].string, qids[3].string });
    try expectFakeVectorHits(adapter, "I prefer concise responses.", &.{qids[2].string});
    const preference = FakeEmbeddingServer.embedding("The user prefers concise responses.");
    const preference_hits = try adapter.vectorSearch(allocator, .{ .vector = &preference, .limit = 3 });
    defer freeTestHits(preference_hits);
    var exact_preference_hits: usize = 0;
    for (preference_hits) |hit| {
        if (hit.score > 0.9999) exact_preference_hits += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), exact_preference_hits);

    var first_chunk_vector: [FakeEmbeddingServer.dimensions]f32 = undefined;
    var offset: usize = 0;
    for (0..chunk_count) |index| {
        const chunk_qid = try testChunkQid(&buffer, long_qid, index);
        const chunk = (try adapter.getNode(allocator, chunk_qid)).?;
        defer adapter.freeNode(allocator, chunk);
        const content = (try readOptionalString(allocator, chunk.properties_json, "content")).?;
        defer allocator.free(content);
        try std.testing.expectEqualStrings(long[offset .. offset + content.len], content);
        offset += content.len;
        try expectFakeVectorHits(adapter, content, &.{chunk_qid});
        if (index == 0) first_chunk_vector = FakeEmbeddingServer.embedding(content);
    }
    try std.testing.expectEqual(long.len, offset);

    // Forgetting the long message drops its chunks' vectors.
    const first_chunk_node = state.qid_to_node.get(try testChunkQid(&buffer, long_qid, 0)).?.node_id;
    try std.testing.expect(try rawVectorSearchHas(&state, &first_chunk_vector, first_chunk_node));
    const forget = try std.fmt.allocPrint(allocator,
        \\{{"jsonrpc":"2.0","id":"f1","method":"memory.forget","params":{{"mode":"hard_delete","selector":{{"qids":["{s}"]}},"dryRun":false,"reason":"test"}}}}
    , .{long_qid});
    defer allocator.free(forget);
    const forget_response = try runtime.dispatch(allocator, forget);
    defer allocator.free(forget_response);
    try std.testing.expect(std.mem.indexOf(u8, forget_response, "\"error\"") == null);
    try std.testing.expect(!(try rawVectorSearchHas(&state, &first_chunk_vector, first_chunk_node)));
    try std.testing.expectEqual(@as(usize, 1), fake.requests());
}
