//! Backend-independent forgetting support: provenance closure lookups,
//! tombstone fingerprints of forgotten raw text, and the forgetting and leak
//! checks behind `quipu verify`.
const std = @import("std");
const storage = @import("storage.zig");

/// Edge types that run from a derived node to what it was derived from.
/// Forgetting the target invalidates the source, whatever its label.
pub const provenance_edge_types = [_][]const u8{ "EVIDENCED_BY", "DERIVED_FROM" };
/// Edge type from a compiled core block to each memory it summarizes.
pub const compiled_edge_type = "COMPILED_FROM";
/// Tombstone property holding the forgotten text's fingerprints.
pub const fingerprints_property = "leakFingerprints";

/// Fingerprints hash windows of this many normalized tokens.
pub const window_tokens: usize = 8;
/// A window starts every `window_stride` tokens (plus one ending at the last
/// token), so any copied run of at least window_tokens + window_stride - 1
/// tokens contains a fingerprinted window.
pub const window_stride: usize = 4;
/// Texts shorter than this are not fingerprinted: a three-word message is too
/// common to call a copy of it a leak.
pub const min_tokens: usize = 4;
const hash_seed: u64 = 0x7175_6970_755f_6670; // "quipu_fp"

/// Owned qids without duplicates, in insertion order, with constant-time
/// membership.
pub const QidList = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList([]u8) = .empty,
    /// Borrows the strings in `items`.
    index: std.StringHashMapUnmanaged(void) = .empty,

    pub fn init(allocator: std.mem.Allocator) QidList {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *QidList) void {
        self.index.deinit(self.allocator);
        for (self.items.items) |qid| self.allocator.free(qid);
        self.items.deinit(self.allocator);
    }

    pub fn contains(self: *const QidList, qid: []const u8) bool {
        return self.index.contains(qid);
    }

    /// Returns whether `qid` was added.
    pub fn appendUnique(self: *QidList, qid: []const u8) !bool {
        if (self.contains(qid)) return false;
        const owned = try self.allocator.dupe(u8, qid);
        errdefer self.allocator.free(owned);
        try self.items.ensureUnusedCapacity(self.allocator, 1);
        try self.index.put(self.allocator, owned, {});
        self.items.appendAssumeCapacity(owned);
        return true;
    }
};

/// Nodes derived directly from `qid`: the sources of its incoming
/// EVIDENCED_BY and DERIVED_FROM edges, whatever their label, plus nodes whose
/// `evidenceQid` names it, so a derived node whose edge write was lost is still
/// found. Every match is returned, live or tombstoned.
pub fn dependentQids(allocator: std.mem.Allocator, store: storage.Adapter, qid: []const u8) !QidList {
    var out = QidList.init(allocator);
    errdefer out.deinit();
    for (provenance_edge_types) |edge_type| {
        const edges = try store.findEdges(allocator, .{ .to_qid = qid, .edge_type = edge_type, .limit = storage.unlimited });
        defer store.freeEdges(allocator, edges);
        for (edges) |edge| _ = try out.appendUnique(edge.from_qid);
    }
    const by_evidence = [_]storage.PropertyMatch{.{ .name = "evidenceQid", .value = qid }};
    var by_property = store.iterateNodes(allocator, .{ .where = &by_evidence });
    defer by_property.deinit();
    while (try by_property.next()) |dependent| _ = try out.appendUnique(dependent);
    return out;
}

/// Edge type from a message to an entity it names. An entity is shared by
/// every message that mentions it, so it is forgotten only once all of them
/// are.
pub const mention_edge_type = "MENTIONS";

/// Entities `qid` mentions whose every mention comes from a node that
/// `isForgotten` accepts. They hold names taken only from forgotten text.
pub fn orphanedEntityQids(
    allocator: std.mem.Allocator,
    store: storage.Adapter,
    qid: []const u8,
    context: anytype,
    comptime isForgotten: fn (@TypeOf(context), std.mem.Allocator, storage.Adapter, []const u8) anyerror!bool,
) !QidList {
    var out = QidList.init(allocator);
    errdefer out.deinit();
    const mentions = try store.findEdges(allocator, .{ .from_qid = qid, .edge_type = mention_edge_type, .limit = storage.unlimited });
    defer store.freeEdges(allocator, mentions);
    next_entity: for (mentions) |mention| {
        if (out.contains(mention.to_qid)) continue;
        const sources = try store.findEdges(allocator, .{ .to_qid = mention.to_qid, .edge_type = mention_edge_type, .limit = storage.unlimited });
        defer store.freeEdges(allocator, sources);
        for (sources) |source| {
            if (!try isForgotten(context, allocator, store, source.from_qid)) continue :next_entity;
        }
        _ = try out.appendUnique(mention.to_qid);
    }
    return out;
}

/// Nodes compiled from `qid` (sources of incoming COMPILED_FROM edges) that
/// still cite it. A block rebuilt in place keeps its old edges, so one whose
/// `evidenceQids` no longer lists `qid` is skipped.
pub fn compiledFromQids(allocator: std.mem.Allocator, store: storage.Adapter, qid: []const u8) !QidList {
    var out = QidList.init(allocator);
    errdefer out.deinit();
    const edges = try store.findEdges(allocator, .{ .to_qid = qid, .edge_type = compiled_edge_type, .limit = storage.unlimited });
    defer store.freeEdges(allocator, edges);
    for (edges) |edge| {
        const node = (try store.getNode(allocator, edge.from_qid)) orelse continue;
        defer store.freeNode(allocator, node);
        if (!try citesEvidence(allocator, node.properties_json, qid)) continue;
        _ = try out.appendUnique(edge.from_qid);
    }
    return out;
}

/// True when `evidenceQids` lists `qid`, or when the node has no
/// `evidenceQids` and the edge alone records the dependency.
fn citesEvidence(allocator: std.mem.Allocator, properties_json: []const u8, qid: []const u8) !bool {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, properties_json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return true,
    };
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |object| object,
        else => return true,
    };
    const list = switch (object.get("evidenceQids") orelse return true) {
        .array => |array| array,
        else => return true,
    };
    for (list.items) |item| switch (item) {
        .string => |string| if (std.mem.eql(u8, string, qid)) return true,
        else => {},
    };
    return false;
}

/// Labels whose text is raw user or tool content. Forgetting one records
/// fingerprints of that text in its tombstone; derived labels carry generated
/// text or copies of raw text, which the raw fingerprints already cover.
pub fn isRawTextLabel(label: []const u8) bool {
    const raw = [_][]const u8{ "Message", "Chunk", "Observation", "ToolCall" };
    for (raw) |name| {
        if (std.mem.eql(u8, label, name)) return true;
    }
    return false;
}

const raw_text_fields = [_][]const u8{ "content", "text", "inputJson", "outputJson", "errorText" };

/// Fingerprints of a raw node's text fields, as "<window>:<hash>" strings;
/// empty for other labels. They let `verify` find copies of forgotten text
/// without the tombstone keeping the text. Anyone holding the store can still
/// test whether a guessed phrase of eight or more words was forgotten.
pub fn fingerprintNode(allocator: std.mem.Allocator, label: []const u8, properties_json: []const u8) ![][]u8 {
    var out = std.ArrayList([]u8).empty;
    errdefer {
        for (out.items) |item| allocator.free(item);
        out.deinit(allocator);
    }
    if (!isRawTextLabel(label)) return out.toOwnedSlice(allocator);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, properties_json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return out.toOwnedSlice(allocator),
    };
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |object| object,
        else => return out.toOwnedSlice(allocator),
    };
    var seen = std.AutoHashMapUnmanaged(Key, void).empty;
    defer seen.deinit(allocator);
    for (raw_text_fields) |field| {
        const text = switch (object.get(field) orelse continue) {
            .string => |string| string,
            else => continue,
        };
        try appendTextFingerprints(allocator, text, &seen, &out);
    }
    return out.toOwnedSlice(allocator);
}

pub fn freeFingerprints(allocator: std.mem.Allocator, fingerprints: []const []u8) void {
    for (fingerprints) |item| allocator.free(item);
    allocator.free(fingerprints);
}

const Key = struct { window: u8, hash: u64 };

fn appendTextFingerprints(
    allocator: std.mem.Allocator,
    text: []const u8,
    seen: *std.AutoHashMapUnmanaged(Key, void),
    out: *std.ArrayList([]u8),
) !void {
    var tokens = try Tokens.init(allocator, text);
    defer tokens.deinit(allocator);
    const terms = tokens.terms.items;
    if (terms.len < min_tokens) return;
    const window = @min(terms.len, window_tokens);
    var start: usize = 0;
    while (true) {
        const key = Key{ .window = @intCast(window), .hash = windowHash(terms[start .. start + window]) };
        if (!(try seen.getOrPut(allocator, key)).found_existing) {
            const item = try std.fmt.allocPrint(allocator, "{d}:{x:0>16}", .{ key.window, key.hash });
            errdefer allocator.free(item);
            try out.append(allocator, item);
        }
        const last = terms.len - window;
        if (start == last) break;
        start = @min(start + window_stride, last);
    }
}

/// Lowercased runs of ASCII letters and digits; bytes from 0x80 stay inside
/// tokens so UTF-8 words are kept whole.
const Tokens = struct {
    buffer: []u8,
    terms: std.ArrayList([]const u8) = .empty,

    fn init(allocator: std.mem.Allocator, text: []const u8) !Tokens {
        const buffer = try allocator.alloc(u8, text.len);
        errdefer allocator.free(buffer);
        for (text, buffer) |byte, *slot| slot.* = std.ascii.toLower(byte);
        var tokens = Tokens{ .buffer = buffer };
        errdefer tokens.terms.deinit(allocator);
        var start: ?usize = null;
        for (buffer, 0..) |byte, index| {
            const in_token = std.ascii.isAlphanumeric(byte) or byte >= 0x80;
            if (in_token) {
                if (start == null) start = index;
            } else if (start) |token_start| {
                try tokens.terms.append(allocator, buffer[token_start..index]);
                start = null;
            }
        }
        if (start) |token_start| try tokens.terms.append(allocator, buffer[token_start..]);
        return tokens;
    }

    fn deinit(self: *Tokens, allocator: std.mem.Allocator) void {
        self.terms.deinit(allocator);
        allocator.free(self.buffer);
    }
};

fn windowHash(terms: []const []const u8) u64 {
    var hasher = std.hash.Wyhash.init(hash_seed);
    for (terms) |term| {
        hasher.update(term);
        hasher.update(&.{0});
    }
    return hasher.final();
}

/// Fingerprints of every tombstone, for scanning live text.
pub const LeakIndex = struct {
    allocator: std.mem.Allocator,
    /// Owns the tombstone qids the map values borrow.
    arena: std.heap.ArenaAllocator,
    map: std.AutoHashMapUnmanaged(Key, []const u8) = .empty,
    windows: [window_tokens + 1]bool = @splat(false),

    pub fn init(allocator: std.mem.Allocator) LeakIndex {
        return .{ .allocator = allocator, .arena = std.heap.ArenaAllocator.init(allocator) };
    }

    pub fn deinit(self: *LeakIndex) void {
        self.map.deinit(self.allocator);
        self.arena.deinit();
    }

    pub fn count(self: *const LeakIndex) usize {
        return self.map.count();
    }

    /// Adds the fingerprints a tombstone's properties carry.
    pub fn addTombstone(self: *LeakIndex, qid: []const u8, properties_json: []const u8) !void {
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, properties_json, .{}) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return,
        };
        defer parsed.deinit();
        const object = switch (parsed.value) {
            .object => |object| object,
            else => return,
        };
        const list = switch (object.get(fingerprints_property) orelse return) {
            .array => |array| array,
            else => return,
        };
        var owned_qid: ?[]const u8 = null;
        for (list.items) |item| {
            const text = switch (item) {
                .string => |string| string,
                else => continue,
            };
            const key = parseFingerprint(text) orelse continue;
            const entry = try self.map.getOrPut(self.allocator, key);
            if (entry.found_existing) continue;
            if (owned_qid == null) owned_qid = try self.arena.allocator().dupe(u8, qid);
            entry.value_ptr.* = owned_qid.?;
            self.windows[key.window] = true;
        }
    }

    /// The tombstone whose forgotten text `text` contains a fingerprinted
    /// window of, if any.
    pub fn find(self: *const LeakIndex, allocator: std.mem.Allocator, text: []const u8) !?[]const u8 {
        var matches = Matches.empty;
        defer matches.deinit(allocator);
        try self.collect(allocator, text, &matches, null);
        if (matches.count() == 0) return null;
        return matches.values()[0];
    }

    /// Adds each fingerprinted window `text` contains to `matches`, keyed by
    /// window with the tombstone it came from. With `only`, collects just the
    /// windows `only` already holds, into `matches`.
    fn collect(self: *const LeakIndex, allocator: std.mem.Allocator, text: []const u8, matches: *Matches, only: ?*const Matches) !void {
        if (self.map.count() == 0) return;
        var tokens = try Tokens.init(allocator, text);
        defer tokens.deinit(allocator);
        const terms = tokens.terms.items;
        for (self.windows, 0..) |present, window| {
            if (!present or window == 0 or window > terms.len) continue;
            var start: usize = 0;
            while (start + window <= terms.len) : (start += 1) {
                const key = Key{ .window = @intCast(window), .hash = windowHash(terms[start .. start + window]) };
                if (only) |wanted| {
                    const tombstone = wanted.get(key) orelse continue;
                    try matches.put(allocator, key, tombstone);
                } else if (self.map.get(key)) |tombstone| {
                    try matches.put(allocator, key, tombstone);
                }
            }
        }
    }

    /// Every string in a properties value, nested ones included.
    fn collectValue(self: *const LeakIndex, allocator: std.mem.Allocator, value: std.json.Value, matches: *Matches, only: ?*const Matches) !void {
        switch (value) {
            .string => |string| try self.collect(allocator, string, matches, only),
            .array => |array| for (array.items) |item| try self.collectValue(allocator, item, matches, only),
            .object => |object| {
                var it = object.iterator();
                while (it.next()) |entry| try self.collectValue(allocator, entry.value_ptr.*, matches, only);
            },
            else => {},
        }
    }
};

const Matches = std.AutoArrayHashMapUnmanaged(Key, []const u8);

fn parseFingerprint(text: []const u8) ?Key {
    const colon = std.mem.indexOfScalar(u8, text, ':') orelse return null;
    const window = std.fmt.parseInt(u8, text[0..colon], 10) catch return null;
    if (window == 0 or window > window_tokens) return null;
    const hash = std.fmt.parseInt(u64, text[colon + 1 ..], 16) catch return null;
    return .{ .window = window, .hash = hash };
}

pub const VerifyOptions = struct {
    /// Also scan every live node's text for fingerprints of forgotten text.
    leaks: bool = false,
    /// Nodes read per page while enumerating the store.
    page_size: usize = 512,
};

/// Forgetting and temporal checks over the whole store, through the adapter
/// interface so every backend gets the same checks:
///
/// - `tombstone_retains_text`: a tombstone still carries content properties.
/// - `active_derived_from_deleted_evidence`: a live node has a provenance edge
///   (or `evidenceQid`) to a tombstone. Chunks of a forgotten message count.
/// - `core_compiled_from_deleted_evidence`: a live core block still cites a
///   tombstone.
/// - `entity_only_from_deleted_evidence`: a live entity whose every mention
///   comes from a tombstone.
/// - `duplicate_current_slot`: more than one current single-value memory per
///   label, scope and slot.
/// - `forgotten_text_leak` (with `leaks`): a live node holds a fingerprinted
///   window of forgotten text that none of its live sources holds.
///
/// `relatedQid` names the tombstone, or for a duplicate slot the other
/// current memory.
pub fn verify(allocator: std.mem.Allocator, store: storage.Adapter, options: VerifyOptions) ![]storage.VerificationIssue {
    var issues = std.ArrayList(storage.VerificationIssue).empty;
    errdefer {
        freeIssueItems(allocator, issues.items);
        issues.deinit(allocator);
    }
    var tombstones = QidList.init(allocator);
    defer tombstones.deinit();
    var leak_index = LeakIndex.init(allocator);
    defer leak_index.deinit();
    var current_slots = std.StringHashMapUnmanaged([]u8).empty;
    defer {
        var it = current_slots.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        current_slots.deinit(allocator);
    }

    {
        var nodes = store.iterateNodes(allocator, .{ .limit = options.page_size });
        defer nodes.deinit();
        while (try nodes.next()) |qid| {
            const node = (try store.getNode(allocator, qid)) orelse continue;
            defer store.freeNode(allocator, node);
            var parsed = std.json.parseFromSlice(std.json.Value, allocator, node.properties_json, .{}) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => continue,
            };
            defer parsed.deinit();
            const object = switch (parsed.value) {
                .object => |object| object,
                else => continue,
            };
            if (jsonBool(object.get("deleted")) == true) {
                _ = try tombstones.appendUnique(node.qid);
                if (tombstoneRetainsText(object)) {
                    try appendIssue(allocator, &issues, "tombstone_retains_text", "tombstoned node still carries content properties", node.qid, null);
                }
                if (options.leaks) try leak_index.addTombstone(node.qid, node.properties_json);
                continue;
            }
            try checkCurrentSlot(allocator, &issues, &current_slots, node, object);
        }
    }

    for (tombstones.items.items) |tombstone| {
        var dependents = try dependentQids(allocator, store, tombstone);
        defer dependents.deinit();
        for (dependents.items.items) |dependent| {
            const node = (try store.getNode(allocator, dependent)) orelse continue;
            defer store.freeNode(allocator, node);
            if (try isDeleted(allocator, node.properties_json)) continue;
            try appendIssue(allocator, &issues, "active_derived_from_deleted_evidence", "live node is derived from forgotten evidence", dependent, tombstone);
        }
        var entities = try orphanedEntityQids(allocator, store, tombstone, {}, isDeletedQid);
        defer entities.deinit();
        for (entities.items.items) |entity| {
            const node = (try store.getNode(allocator, entity)) orelse continue;
            defer store.freeNode(allocator, node);
            if (try isDeleted(allocator, node.properties_json)) continue;
            try appendIssue(allocator, &issues, "entity_only_from_deleted_evidence", "live entity is mentioned only by forgotten nodes", entity, tombstone);
        }
        var compiled = try compiledFromQids(allocator, store, tombstone);
        defer compiled.deinit();
        for (compiled.items.items) |block| {
            const node = (try store.getNode(allocator, block)) orelse continue;
            defer store.freeNode(allocator, node);
            if (try isDeleted(allocator, node.properties_json)) continue;
            try appendIssue(allocator, &issues, "core_compiled_from_deleted_evidence", "live core block is compiled from forgotten evidence", block, tombstone);
        }
    }

    if (options.leaks and leak_index.count() > 0) {
        var nodes = store.iterateNodes(allocator, .{ .limit = options.page_size });
        defer nodes.deinit();
        while (try nodes.next()) |qid| {
            const node = (try store.getNode(allocator, qid)) orelse continue;
            defer store.freeNode(allocator, node);
            var parsed = std.json.parseFromSlice(std.json.Value, allocator, node.properties_json, .{}) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => continue,
            };
            defer parsed.deinit();
            if (jsonBool(switch (parsed.value) {
                .object => |object| object.get("deleted"),
                else => null,
            }) == true) continue;
            if (try unexplainedLeak(allocator, store, &leak_index, node, parsed.value)) |tombstone| {
                try appendIssue(allocator, &issues, "forgotten_text_leak", "live node holds forgotten text that none of its live sources holds", node.qid, tombstone);
            }
        }
    }

    return issues.toOwnedSlice(allocator);
}

/// The tombstone whose forgotten text `node` holds and that none of its live
/// sources explains. Every string in its properties counts: that is what
/// readers, the full-text index and vectors see. A window is explained when
/// a live node `node` was derived or compiled from, at any depth, holds it
/// too: a fact quoting a live message, or a chunk of one. A raw node with no
/// sources (a message, an observation) is its own evidence, so text the user
/// wrote again elsewhere is not reported; forget it by query instead.
fn unexplainedLeak(
    allocator: std.mem.Allocator,
    store: storage.Adapter,
    index: *const LeakIndex,
    node: storage.Node,
    value: std.json.Value,
) !?[]const u8 {
    var pending = Matches.empty;
    defer pending.deinit(allocator);
    try index.collectValue(allocator, value, &pending, null);
    if (pending.count() == 0) return null;

    var queue = QidList.init(allocator);
    defer queue.deinit();
    _ = try queue.appendUnique(node.qid);
    try appendSourceQids(allocator, store, node, &queue);
    if (queue.items.items.len == 1 and isRawTextLabel(node.label)) return null;

    var position: usize = 1;
    while (position < queue.items.items.len and pending.count() > 0) : (position += 1) {
        const source = (try store.getNode(allocator, queue.items.items[position])) orelse continue;
        defer store.freeNode(allocator, source);
        try appendSourceQids(allocator, store, source, &queue);
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, source.properties_json, .{}) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => continue,
        };
        defer parsed.deinit();
        const object = switch (parsed.value) {
            .object => |object| object,
            else => continue,
        };
        if (jsonBool(object.get("deleted")) == true) continue;
        var explained = Matches.empty;
        defer explained.deinit(allocator);
        try index.collectValue(allocator, parsed.value, &explained, &pending);
        for (explained.keys()) |key| _ = pending.swapRemove(key);
    }
    if (pending.count() == 0) return null;
    return pending.values()[0];
}

/// What `node` was derived or compiled from: targets of its EVIDENCED_BY,
/// DERIVED_FROM and COMPILED_FROM edges, and its `evidenceQid` or, for a
/// chunk, `messageQid`.
fn appendSourceQids(allocator: std.mem.Allocator, store: storage.Adapter, node: storage.Node, out: *QidList) !void {
    const edge_types = provenance_edge_types ++ [_][]const u8{compiled_edge_type};
    for (edge_types) |edge_type| {
        const edges = try store.findEdges(allocator, .{ .from_qid = node.qid, .edge_type = edge_type, .limit = storage.unlimited });
        defer store.freeEdges(allocator, edges);
        for (edges) |edge| _ = try out.appendUnique(edge.to_qid);
    }
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, node.properties_json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return,
    };
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |object| object,
        else => return,
    };
    for ([_][]const u8{ "evidenceQid", "messageQid" }) |key| {
        if (jsonString(object.get(key))) |qid| {
            if (qid.len > 0) _ = try out.appendUnique(qid);
        }
    }
}

const tombstone_fields = [_][]const u8{ "kind", "deleted", "state", "mode", "reason", "previousLabel", fingerprints_property };

fn tombstoneRetainsText(object: std.json.ObjectMap) bool {
    var it = object.iterator();
    outer: while (it.next()) |entry| {
        for (tombstone_fields) |allowed| {
            if (std.mem.eql(u8, entry.key_ptr.*, allowed)) continue :outer;
        }
        switch (entry.value_ptr.*) {
            .string => |string| if (string.len > 0) return true,
            .array => |array| if (array.items.len > 0) return true,
            .object => |nested| if (nested.count() > 0) return true,
            else => {},
        }
    }
    return false;
}

/// Records the current single-value memory of each (label, scope, slot) and
/// reports any second one.
fn checkCurrentSlot(
    allocator: std.mem.Allocator,
    issues: *std.ArrayList(storage.VerificationIssue),
    current_slots: *std.StringHashMapUnmanaged([]u8),
    node: storage.Node,
    object: std.json.ObjectMap,
) !void {
    const slot_key = jsonString(object.get("slotKey")) orelse return;
    if (slot_key.len == 0) return;
    if (!std.mem.eql(u8, jsonString(object.get("state")) orelse "", "current")) return;
    if (!std.mem.eql(u8, jsonString(object.get("aggregationMode")) orelse "", "single_value")) return;
    const key = try std.fmt.allocPrint(allocator, "{s}\x1f{s}\x1f{s}\x1f{s}\x1f{s}\x1f{s}", .{
        node.label,
        jsonString(object.get("tenantId")) orelse "",
        jsonString(object.get("userId")) orelse "",
        jsonString(object.get("agentId")) orelse "",
        jsonString(object.get("projectId")) orelse "",
        slot_key,
    });
    const entry = current_slots.getOrPut(allocator, key) catch |err| {
        allocator.free(key);
        return err;
    };
    if (entry.found_existing) {
        allocator.free(key);
        try appendIssue(allocator, issues, "duplicate_current_slot", "more than one current single-value memory holds this slot", node.qid, entry.value_ptr.*);
        return;
    }
    entry.value_ptr.* = allocator.dupe(u8, node.qid) catch |err| {
        _ = current_slots.remove(key);
        allocator.free(key);
        return err;
    };
}

fn isDeletedQid(_: void, allocator: std.mem.Allocator, store: storage.Adapter, qid: []const u8) !bool {
    const node = (try store.getNode(allocator, qid)) orelse return true;
    defer store.freeNode(allocator, node);
    return isDeleted(allocator, node.properties_json);
}

fn isDeleted(allocator: std.mem.Allocator, properties_json: []const u8) !bool {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, properties_json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return false,
    };
    defer parsed.deinit();
    return switch (parsed.value) {
        .object => |object| jsonBool(object.get("deleted")) == true,
        else => false,
    };
}

fn jsonBool(value: ?std.json.Value) ?bool {
    return switch (value orelse return null) {
        .bool => |boolean| boolean,
        else => null,
    };
}

fn jsonString(value: ?std.json.Value) ?[]const u8 {
    return switch (value orelse return null) {
        .string => |string| string,
        else => null,
    };
}

fn appendIssue(
    allocator: std.mem.Allocator,
    issues: *std.ArrayList(storage.VerificationIssue),
    code: []const u8,
    message: []const u8,
    qid: []const u8,
    related_qid: ?[]const u8,
) !void {
    const owned_qid = try allocator.dupe(u8, qid);
    errdefer allocator.free(owned_qid);
    const owned_related = if (related_qid) |value| try allocator.dupe(u8, value) else null;
    errdefer if (owned_related) |value| allocator.free(value);
    try issues.append(allocator, .{ .code = code, .message = message, .qid = owned_qid, .relatedQid = owned_related });
}

fn freeIssueItems(allocator: std.mem.Allocator, issues: []const storage.VerificationIssue) void {
    for (issues) |issue| {
        if (issue.qid) |qid| allocator.free(qid);
        if (issue.relatedQid) |qid| allocator.free(qid);
    }
}

pub fn freeIssues(allocator: std.mem.Allocator, issues: []const storage.VerificationIssue) void {
    freeIssueItems(allocator, issues);
    allocator.free(issues);
}

test "fingerprints cover sampled windows and find copied runs" {
    const allocator = std.testing.allocator;
    const text = "My locker code is 4417 and the spare key lives under the blue flowerpot by the shed door.";
    const message_props = try std.fmt.allocPrint(allocator, "{{\"content\":\"{s}\"}}", .{text});
    defer allocator.free(message_props);
    const fingerprints = try fingerprintNode(allocator, "Message", message_props);
    defer freeFingerprints(allocator, fingerprints);
    // 18 tokens: windows start at 0, 4, 8 and the last one at 10.
    try std.testing.expectEqual(@as(usize, 4), fingerprints.len);
    for (fingerprints) |fingerprint| try std.testing.expect(std.mem.startsWith(u8, fingerprint, "8:"));

    var props = std.ArrayList(u8).empty;
    defer props.deinit(allocator);
    try props.appendSlice(allocator, "{\"deleted\":true,\"leakFingerprints\":[");
    for (fingerprints, 0..) |fingerprint, i| {
        if (i > 0) try props.append(allocator, ',');
        try props.print(allocator, "\"{s}\"", .{fingerprint});
    }
    try props.appendSlice(allocator, "]}");
    var index = LeakIndex.init(allocator);
    defer index.deinit();
    try index.addTombstone("q_msg_1", props.items);

    // Case and punctuation do not hide a copy; a run of 11 tokens is enough.
    try std.testing.expect((try index.find(allocator, "Summary: the SPARE key lives under the blue flowerpot, by the shed!")) != null);
    try std.testing.expectEqualStrings("q_msg_1", (try index.find(allocator, "quote: My locker code is 4417 and the spare key")).?);
    try std.testing.expect((try index.find(allocator, "The spare key lives somewhere else entirely.")) == null);

    // Short texts hash whole; derived labels are not fingerprinted.
    const short = try fingerprintNode(allocator, "Message", "{\"content\":\"door code 4417 please\"}");
    defer freeFingerprints(allocator, short);
    try std.testing.expectEqual(@as(usize, 1), short.len);
    try std.testing.expect(std.mem.startsWith(u8, short[0], "4:"));
    const tiny = try fingerprintNode(allocator, "Message", "{\"content\":\"use pnpm\"}");
    defer freeFingerprints(allocator, tiny);
    try std.testing.expectEqual(@as(usize, 0), tiny.len);
    const derived = try fingerprintNode(allocator, "Fact", "{\"text\":\"The repo uses pnpm as its package manager.\"}");
    defer freeFingerprints(allocator, derived);
    try std.testing.expectEqual(@as(usize, 0), derived.len);
}
