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

pub const FullTextQuery = struct {
    text: []const u8,
    limit: usize = 20,
};

pub const VectorQuery = struct {
    vector: []const f32,
    limit: usize = 20,
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
};

pub const Adapter = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        put_node: *const fn (*anyopaque, Node) anyerror!void,
        get_node: *const fn (*anyopaque, std.mem.Allocator, []const u8) anyerror!?Node,
        put_edge: *const fn (*anyopaque, Edge) anyerror!void,
        full_text_search: *const fn (*anyopaque, std.mem.Allocator, FullTextQuery) anyerror![]SearchHit,
        vector_search: *const fn (*anyopaque, std.mem.Allocator, VectorQuery) anyerror![]SearchHit,
        append_stream: *const fn (*anyopaque, []const u8, []const u8) anyerror!StreamEntry,
        read_stream: *const fn (*anyopaque, std.mem.Allocator, []const u8, u64, usize) anyerror![]StreamEntry,
        begin_transaction: *const fn (*anyopaque) anyerror!Transaction,
        commit_transaction: *const fn (*anyopaque, Transaction) anyerror!void,
        rollback_transaction: *const fn (*anyopaque, Transaction) anyerror!void,
        verify: *const fn (*anyopaque, std.mem.Allocator) anyerror![]VerificationIssue,
    };

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

    pub fn fullTextSearch(self: Adapter, allocator: std.mem.Allocator, query: FullTextQuery) ![]SearchHit {
        return self.vtable.full_text_search(self.context, allocator, query);
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
