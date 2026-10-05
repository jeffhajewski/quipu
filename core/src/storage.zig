const std = @import("std");

pub const StorageError = error{
    NotFound,
    Unsupported,
    InvalidRequest,
    VerificationFailed,
};

pub const Node = struct {
    qid: []const u8,
    label: []const u8,
    properties_json: []const u8,
};

pub const Edge = struct {
    qid: []const u8,
    from_qid: []const u8,
    to_qid: []const u8,
    edge_type: []const u8,
    properties_json: []const u8,
};

pub const EdgeQuery = struct {
    from_qid: ?[]const u8 = null,
    to_qid: ?[]const u8 = null,
    edge_type: ?[]const u8 = null,
    limit: usize = 100,
};

/// A query limit meaning "every result". `EdgeQuery`, `FullTextQuery` and
/// `NodeQuery` accept it.
pub const unlimited: usize = std.math.maxInt(usize);

pub const FullTextQuery = struct {
    text: []const u8,
    limit: usize = 20,
};

/// Top-level string properties every adapter indexes for `findNodes`: a
/// lookup on one of these costs about the size of its result, not the store.
/// A lookup on any other property is answered by a scan.
pub const indexed_properties = [_][]const u8{ "slotKey", "state", "evidenceQid", "blockKey", "cardKind", "status" };

pub fn indexedPropertyIndex(name: []const u8) ?usize {
    for (indexed_properties, 0..) |indexed, index| {
        if (std.mem.eql(u8, indexed, name)) return index;
    }
    return null;
}

pub const IndexedValues = [indexed_properties.len]?[]u8;

/// The non-empty top-level string value of each indexed property in
/// `properties_json`, owned by the caller; null where absent. JSON that is not
/// an object indexes nothing.
pub fn indexedValues(allocator: std.mem.Allocator, properties_json: []const u8) !IndexedValues {
    var values: IndexedValues = @splat(null);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, properties_json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return values,
    };
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |object| object,
        else => return values,
    };
    errdefer freeIndexedValues(allocator, values);
    for (indexed_properties, 0..) |name, index| {
        const value = switch (object.get(name) orelse continue) {
            .string => |string| string,
            else => continue,
        };
        if (value.len == 0) continue;
        values[index] = try allocator.dupe(u8, value);
    }
    return values;
}

pub fn freeIndexedValues(allocator: std.mem.Allocator, values: IndexedValues) void {
    for (values) |value| if (value) |owned| allocator.free(owned);
}

/// Whether `properties_json` has `name` as a top-level, non-empty string equal
/// to `value`. The scan path of `findNodes` for unindexed properties.
pub fn propertyStringEquals(allocator: std.mem.Allocator, properties_json: []const u8, name: []const u8, value: []const u8) !bool {
    if (value.len == 0) return false;
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, properties_json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return false,
    };
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |object| object,
        else => return false,
    };
    return switch (object.get(name) orelse return false) {
        .string => |string| std.mem.eql(u8, string, value),
        else => false,
    };
}

pub const PropertyMatch = struct {
    name: []const u8,
    value: []const u8,
};

/// Selects nodes by label and exact top-level property values, in node
/// creation order, one page at a time. Every adapter returns every match
/// across pages: nothing is dropped for being old or new.
pub const NodeQuery = struct {
    /// Only nodes with this label. Null matches every label.
    label: ?[]const u8 = null,
    /// Only nodes whose properties JSON has each `name` as a top-level string
    /// equal to `value` (all must hold). An empty `value` matches nothing.
    where: []const PropertyMatch = &.{},
    /// Resume after this cursor, a previous page's `next`. Null starts at the
    /// first node in `order`.
    after: ?u64 = null,
    order: Order = .oldest_first,
    /// Most qids one page holds. Zero returns an empty page.
    limit: usize = 512,

    pub const Order = enum { oldest_first, newest_first };
};

pub const NodePage = struct {
    qids: [][]u8,
    /// Pass as `after` to read the next page; null once the matches are
    /// exhausted. A page that ends exactly at the last match may still carry
    /// a cursor, whose page is then empty.
    next: ?u64 = null,
};

/// Every qid a `NodeQuery` matches, fetched page by page. A qid returned by
/// `next` stays valid until the following call to `next` or `deinit`.
pub const NodeIterator = struct {
    store: Adapter,
    allocator: std.mem.Allocator,
    query: NodeQuery,
    page: ?NodePage = null,
    position: usize = 0,
    exhausted: bool = false,

    pub fn next(self: *NodeIterator) !?[]const u8 {
        while (true) {
            if (self.page) |page| {
                if (self.position < page.qids.len) {
                    self.position += 1;
                    return page.qids[self.position - 1];
                }
                self.query.after = page.next;
                self.exhausted = page.next == null;
                self.store.freeNodePage(self.allocator, page);
                self.page = null;
            }
            if (self.exhausted) return null;
            self.page = try self.store.findNodes(self.allocator, self.query);
            self.position = 0;
        }
    }

    pub fn deinit(self: *NodeIterator) void {
        if (self.page) |page| self.store.freeNodePage(self.allocator, page);
        self.page = null;
        self.exhausted = true;
    }
};

pub const VectorQuery = struct {
    vector: []const f32,
    limit: usize = 20,
};

pub const Capabilities = struct {
    backend: []const u8 = "memory",
    durable: bool = false,
    full_text: bool = true,
    vector: bool = false,
    streams: bool = true,
    transactions: bool = true,
    verification: bool = true,
    vector_dimensions: ?u16 = null,
    embedding_model: ?[]const u8 = null,
};

pub const SearchHit = struct {
    qid: []const u8,
    score: f32,
};

pub const StreamEntry = struct {
    stream: []const u8,
    sequence: u64,
    payload_json: []const u8,
};

pub const Transaction = struct {
    id: u64,
};

pub const VerificationIssue = struct {
    code: []const u8,
    message: []const u8,
    qid: ?[]const u8 = null,
    /// A second node the issue involves, such as the tombstone a leak copies.
    relatedQid: ?[]const u8 = null,
};

pub const Adapter = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        capabilities: *const fn (*anyopaque) Capabilities,
        put_node: *const fn (*anyopaque, Node) anyerror!void,
        get_node: *const fn (*anyopaque, std.mem.Allocator, []const u8) anyerror!?Node,
        put_edge: *const fn (*anyopaque, Edge) anyerror!void,
        find_edges: *const fn (*anyopaque, std.mem.Allocator, EdgeQuery) anyerror![]Edge,
        find_nodes: *const fn (*anyopaque, std.mem.Allocator, NodeQuery) anyerror!NodePage,
        full_text_search: *const fn (*anyopaque, std.mem.Allocator, FullTextQuery) anyerror![]SearchHit,
        embed_text: *const fn (*anyopaque, std.mem.Allocator, []const u8) anyerror![]f32,
        prefetch_embeddings: *const fn (*anyopaque, []const []const u8) anyerror!void,
        clear_prefetched_embeddings: *const fn (*anyopaque) void,
        vector_search: *const fn (*anyopaque, std.mem.Allocator, VectorQuery) anyerror![]SearchHit,
        append_stream: *const fn (*anyopaque, []const u8, []const u8) anyerror!StreamEntry,
        read_stream: *const fn (*anyopaque, std.mem.Allocator, []const u8, u64, usize) anyerror![]StreamEntry,
        begin_transaction: *const fn (*anyopaque) anyerror!Transaction,
        commit_transaction: *const fn (*anyopaque, Transaction) anyerror!void,
        rollback_transaction: *const fn (*anyopaque, Transaction) anyerror!void,
        verify: *const fn (*anyopaque, std.mem.Allocator) anyerror![]VerificationIssue,
    };

    pub fn capabilities(self: Adapter) Capabilities {
        return self.vtable.capabilities(self.context);
    }

    pub fn putNode(self: Adapter, node: Node) !void {
        try self.vtable.put_node(self.context, node);
    }

    pub fn getNode(self: Adapter, allocator: std.mem.Allocator, qid: []const u8) !?Node {
        return self.vtable.get_node(self.context, allocator, qid);
    }

    pub fn freeNode(_: Adapter, allocator: std.mem.Allocator, node: Node) void {
        allocator.free(node.qid);
        allocator.free(node.label);
        allocator.free(node.properties_json);
    }

    pub fn putEdge(self: Adapter, edge: Edge) !void {
        try self.vtable.put_edge(self.context, edge);
    }

    pub fn findEdges(self: Adapter, allocator: std.mem.Allocator, query: EdgeQuery) ![]Edge {
        return self.vtable.find_edges(self.context, allocator, query);
    }

    pub fn freeEdges(_: Adapter, allocator: std.mem.Allocator, edges: []const Edge) void {
        for (edges) |edge| {
            allocator.free(edge.qid);
            allocator.free(edge.from_qid);
            allocator.free(edge.to_qid);
            allocator.free(edge.edge_type);
            allocator.free(edge.properties_json);
        }
        allocator.free(edges);
    }

    /// One page of the nodes `query` selects. See `NodeQuery`.
    pub fn findNodes(self: Adapter, allocator: std.mem.Allocator, query: NodeQuery) !NodePage {
        return self.vtable.find_nodes(self.context, allocator, query);
    }

    pub fn freeNodePage(_: Adapter, allocator: std.mem.Allocator, page: NodePage) void {
        for (page.qids) |qid| allocator.free(qid);
        allocator.free(page.qids);
    }

    /// Pages through every node `query` selects; `query.limit` is the page
    /// size.
    pub fn iterateNodes(self: Adapter, allocator: std.mem.Allocator, query: NodeQuery) NodeIterator {
        return .{ .store = self, .allocator = allocator, .query = query };
    }

    /// Empty `query.text` enumerates nodes; maintenance paths should use
    /// `findNodes`, which pages and filters by label and property.
    pub fn fullTextSearch(self: Adapter, allocator: std.mem.Allocator, query: FullTextQuery) ![]SearchHit {
        return self.vtable.full_text_search(self.context, allocator, query);
    }

    pub fn embedText(self: Adapter, allocator: std.mem.Allocator, text: []const u8) ![]f32 {
        return self.vtable.embed_text(self.context, allocator, text);
    }

    /// Embeds `texts` in batched requests ahead of the putNode calls that will
    /// index them; a putNode whose index text exactly matches a prefetched text
    /// reuses that vector instead of making its own request. Best effort: a
    /// text left unembedded by an error is embedded by putNode as before.
    /// Vectors stay cached until `clearPrefetchedEmbeddings`.
    pub fn prefetchEmbeddings(self: Adapter, texts: []const []const u8) !void {
        return self.vtable.prefetch_embeddings(self.context, texts);
    }

    pub fn clearPrefetchedEmbeddings(self: Adapter) void {
        self.vtable.clear_prefetched_embeddings(self.context);
    }

    pub fn vectorSearch(self: Adapter, allocator: std.mem.Allocator, query: VectorQuery) ![]SearchHit {
        return self.vtable.vector_search(self.context, allocator, query);
    }

    pub fn appendStream(self: Adapter, stream: []const u8, payload_json: []const u8) !StreamEntry {
        return self.vtable.append_stream(self.context, stream, payload_json);
    }

    pub fn readStream(
        self: Adapter,
        allocator: std.mem.Allocator,
        stream: []const u8,
        after_sequence: u64,
        limit: usize,
    ) ![]StreamEntry {
        return self.vtable.read_stream(self.context, allocator, stream, after_sequence, limit);
    }

    pub fn beginTransaction(self: Adapter) !Transaction {
        return self.vtable.begin_transaction(self.context);
    }

    pub fn commitTransaction(self: Adapter, tx: Transaction) !void {
        try self.vtable.commit_transaction(self.context, tx);
    }

    pub fn rollbackTransaction(self: Adapter, tx: Transaction) !void {
        try self.vtable.rollback_transaction(self.context, tx);
    }

    pub fn verify(self: Adapter, allocator: std.mem.Allocator) ![]VerificationIssue {
        return self.vtable.verify(self.context, allocator);
    }
};

/// Shared `findNodes` checks that every adapter's tests run against an empty
/// store, so both backends honor one contract.
pub fn expectFindNodesContract(store: Adapter) !void {
    const allocator = std.testing.allocator;
    try store.putNode(.{ .qid = "q_fact_1", .label = "Fact", .properties_json = "{\"slotKey\":\"project.package_manager\",\"state\":\"current\",\"kind\":\"fact\"}" });
    try store.putNode(.{ .qid = "q_msg_2", .label = "Message", .properties_json = "{\"content\":\"we use pnpm\",\"kind\":\"message\"}" });
    try store.putNode(.{ .qid = "q_fact_3", .label = "Fact", .properties_json = "{\"slotKey\":\"project.package_manager\",\"state\":\"superseded\",\"kind\":\"fact\"}" });
    try store.putNode(.{ .qid = "q_card_4", .label = "MemoryCard", .properties_json = "{\"slotKey\":\"project.package_manager\",\"state\":\"current\",\"cardKind\":\"fact\"}" });
    try store.putNode(.{ .qid = "q_core_5", .label = "Core", .properties_json = "{\"blockKey\":\"project_summary\",\"slotKey\":\"\"}" });

    const slot = PropertyMatch{ .name = "slotKey", .value = "project.package_manager" };
    const current = PropertyMatch{ .name = "state", .value = "current" };
    try expectPage(store, .{ .where = &.{slot} }, &.{ "q_fact_1", "q_fact_3", "q_card_4" });
    try expectPage(store, .{ .where = &.{ slot, current } }, &.{ "q_fact_1", "q_card_4" });
    try expectPage(store, .{ .where = &.{ current, slot } }, &.{ "q_fact_1", "q_card_4" });
    try expectPage(store, .{ .label = "Fact", .where = &.{slot} }, &.{ "q_fact_1", "q_fact_3" });
    try expectPage(store, .{ .where = &.{slot}, .order = .newest_first }, &.{ "q_card_4", "q_fact_3", "q_fact_1" });
    try expectPage(store, .{ .label = "Core" }, &.{"q_core_5"});
    try expectPage(store, .{}, &.{ "q_fact_1", "q_msg_2", "q_fact_3", "q_card_4", "q_core_5" });
    // Unindexed properties are matched by a scan.
    try expectPage(store, .{ .where = &.{.{ .name = "kind", .value = "fact" }} }, &.{ "q_fact_1", "q_fact_3" });
    // Empty values and empty properties never match.
    try expectPage(store, .{ .where = &.{.{ .name = "slotKey", .value = "" }} }, &.{});
    try expectPage(store, .{ .where = &.{.{ .name = "slotKey", .value = "missing" }} }, &.{});
    try expectPage(store, .{ .where = &.{slot}, .limit = 0 }, &.{});

    // Paging walks every match, forwards and backwards.
    for ([_]Query.Order{ .oldest_first, .newest_first }) |order| {
        var seen = std.ArrayList([]const u8).empty;
        defer {
            for (seen.items) |qid| allocator.free(qid);
            seen.deinit(allocator);
        }
        var query = Query{ .where = &.{slot}, .limit = 1, .order = order };
        var pages: usize = 0;
        while (true) {
            const page = try store.findNodes(allocator, query);
            defer store.freeNodePage(allocator, page);
            pages += 1;
            try std.testing.expect(page.qids.len <= 1);
            for (page.qids) |qid| try seen.append(allocator, try allocator.dupe(u8, qid));
            query.after = page.next orelse break;
        }
        try std.testing.expectEqual(@as(usize, 3), seen.items.len);
        try std.testing.expect(pages >= 3);
        const first: []const u8 = if (order == .oldest_first) "q_fact_1" else "q_card_4";
        try std.testing.expectEqualStrings(first, seen.items[0]);
    }

    // The iterator pages to the end.
    var iterator = store.iterateNodes(allocator, .{ .where = &.{slot}, .limit = 2 });
    defer iterator.deinit();
    var count: usize = 0;
    while (try iterator.next()) |_| count += 1;
    try std.testing.expectEqual(@as(usize, 3), count);

    // Rewrites move nodes between values but keep their creation position.
    try store.putNode(.{ .qid = "q_fact_1", .label = "Fact", .properties_json = "{\"slotKey\":\"project.package_manager\",\"state\":\"superseded\"}" });
    try expectPage(store, .{ .where = &.{ slot, current } }, &.{"q_card_4"});
    try expectPage(store, .{ .label = "Fact", .where = &.{slot} }, &.{ "q_fact_1", "q_fact_3" });
    // A tombstone carries no slot, so it leaves the slot's results.
    try store.putNode(.{ .qid = "q_fact_3", .label = "Fact", .properties_json = "{\"kind\":\"tombstone\",\"deleted\":true,\"state\":\"deleted\"}" });
    try expectPage(store, .{ .where = &.{slot} }, &.{ "q_fact_1", "q_card_4" });
    try expectPage(store, .{ .where = &.{.{ .name = "state", .value = "deleted" }} }, &.{"q_fact_3"});
}

const Query = NodeQuery;

fn expectPage(store: Adapter, query: NodeQuery, expected: []const []const u8) !void {
    const page = try store.findNodes(std.testing.allocator, query);
    defer store.freeNodePage(std.testing.allocator, page);
    errdefer {
        std.debug.print("expected:", .{});
        for (expected) |qid| std.debug.print(" {s}", .{qid});
        std.debug.print("\nactual:  ", .{});
        for (page.qids) |qid| std.debug.print(" {s}", .{qid});
        std.debug.print("\n", .{});
    }
    try std.testing.expectEqual(expected.len, page.qids.len);
    for (expected, page.qids) |want, got| try std.testing.expectEqualStrings(want, got);
}
