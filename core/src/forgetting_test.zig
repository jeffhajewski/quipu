//! Forgetting closures, leak verification and supersession through the
//! public JSON-RPC surface, including stores far past the old 1,000-node
//! enumeration cap. Runs against the Lattice adapter when it is built in,
//! else the in-memory adapter. The largest Lattice variant needs
//! QUIPU_LATTICE_SLOW_TESTS=1.
const std = @import("std");
const build_options = @import("build_options");
const forgetting = @import("forgetting.zig");
const in_memory_storage = @import("in_memory_storage.zig");
const lattice_storage = if (build_options.enable_lattice) @import("lattice_storage.zig") else struct {};
const protocol = @import("protocol.zig");
const runtime_mod = @import("runtime.zig");
const schema = @import("schema.zig");
const storage = @import("storage.zig");

const Value = std.json.Value;

var scale_db_counter = std.atomic.Value(u64).init(0);

const Harness = if (build_options.enable_lattice) struct {
    tmp_dir: std.testing.TmpDir,
    db_path: []u8,
    state: lattice_storage.LatticeAdapter,

    fn init(allocator: std.mem.Allocator) !@This() {
        var tmp_dir = std.testing.tmpDir(.{});
        errdefer tmp_dir.cleanup();
        const id = scale_db_counter.fetchAdd(1, .monotonic);
        const db_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/quipu-forget-scale-{d}.lattice", .{ tmp_dir.sub_path[0..], id });
        errdefer allocator.free(db_path);
        var state = try lattice_storage.LatticeAdapter.open(allocator, db_path, .{ .io = std.testing.io });
        errdefer state.deinit();
        try schema.ensure(allocator, state.adapter());
        return .{ .tmp_dir = tmp_dir, .db_path = db_path, .state = state };
    }

    fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        self.state.deinit();
        self.tmp_dir.cleanup();
        allocator.free(self.db_path);
    }

    fn adapter(self: *@This()) storage.Adapter {
        return self.state.adapter();
    }
} else struct {
    state: in_memory_storage.InMemoryAdapter,

    fn init(allocator: std.mem.Allocator) !@This() {
        var state = in_memory_storage.InMemoryAdapter.init(allocator);
        errdefer state.deinit();
        try schema.ensure(allocator, state.adapter());
        return .{ .state = state };
    }

    fn deinit(self: *@This(), _: std.mem.Allocator) void {
        self.state.deinit();
    }

    fn adapter(self: *@This()) storage.Adapter {
        return self.state.adapter();
    }
};

fn slowTestsEnabled() !bool {
    return std.testing.environ.containsUnempty(std.testing.allocator, "QUIPU_LATTICE_SLOW_TESTS");
}

/// One remember call: a user message whose shape cycles through the
/// deterministic extractor's generic rules, plus an assistant reply.
const Remembered = struct {
    index: usize,
    project: []const u8,
    kind: Kind,
    /// Package manager the user message states, for `.package_manager`.
    package_manager: ?[]const u8 = null,
    session_qid: []u8,
    user_qid: []u8,
    reply_qid: []u8,

    const Kind = enum { package_manager, test_command, response_style, long, plain };

    fn deinit(self: Remembered, allocator: std.mem.Allocator) void {
        allocator.free(self.session_qid);
        allocator.free(self.user_qid);
        allocator.free(self.reply_qid);
    }
};

const filler_sentence = "The tide chart lists depth soundings for each buoy along the outer channel. ";

const Scenario = struct {
    allocator: std.mem.Allocator,
    runtime: runtime_mod.Runtime,
    store: storage.Adapter,
    remembered: std.ArrayList(Remembered) = .empty,
    /// Markers of forgotten text; none may be reachable afterwards.
    forgotten_markers: forgetting.QidList,
    /// The forgotten markers searched for one by one; a sample of large
    /// forgets keeps the run short. Borrows from `forgotten_markers`.
    query_markers: std.ArrayList([]const u8) = .empty,
    /// Every qid a forget reported, with its action.
    forgotten_qids: forgetting.QidList,

    fn init(allocator: std.mem.Allocator, store: storage.Adapter) Scenario {
        return .{
            .allocator = allocator,
            .runtime = runtime_mod.Runtime.init(store, protocol.Health.default()),
            .store = store,
            .forgotten_qids = forgetting.QidList.init(allocator),
            .forgotten_markers = forgetting.QidList.init(allocator),
        };
    }

    fn deinit(self: *Scenario) void {
        for (self.remembered.items) |item| item.deinit(self.allocator);
        self.remembered.deinit(self.allocator);
        self.query_markers.deinit(self.allocator);
        self.forgotten_markers.deinit();
        self.forgotten_qids.deinit();
    }

    /// Dispatches one request and fails on a JSON-RPC error.
    fn call(self: *Scenario, comptime format: []const u8, args: anytype) ![]u8 {
        const request = try std.fmt.allocPrint(self.allocator, format, args);
        defer self.allocator.free(request);
        const response = try self.runtime.dispatch(self.allocator, request);
        errdefer self.allocator.free(response);
        if (std.mem.indexOf(u8, response, "\"error\":{") != null) {
            std.debug.print("request failed: {s}\n{s}\n", .{ request, response });
            return error.TestUnexpectedResult;
        }
        return response;
    }

    fn rememberAll(self: *Scenario, count: usize) !void {
        var package_manager_count: usize = 0;
        var content = std.ArrayList(u8).empty;
        defer content.deinit(self.allocator);
        for (0..count) |index| {
            const project: []const u8 = if (index < count / 2) "repo:scale-a" else "repo:scale-b";
            const kind: Remembered.Kind = @enumFromInt(index % 5);
            var package_manager: ?[]const u8 = null;
            content.clearRetainingCapacity();
            switch (kind) {
                .package_manager => {
                    package_manager = if (package_manager_count % 2 == 0) "pnpm" else "npm";
                    package_manager_count += 1;
                    try content.print(self.allocator, "We use {s} for the orca{d:0>4}zz harbor service.", .{ package_manager.?, index });
                },
                .test_command => try content.print(self.allocator, "Please run `just test` before merging orca{d:0>4}zz harbor changes.", .{index}),
                .response_style => try content.print(self.allocator, "I prefer concise responses when we discuss orca{d:0>4}zz harbor plans.", .{index}),
                .long => {
                    try content.print(self.allocator, "Long log orca{d:0>4}zz harbor: ", .{index});
                    for (0..40) |_| try content.appendSlice(self.allocator, filler_sentence);
                    try content.print(self.allocator, "Closing note tail{d:0>4}zz.", .{index});
                },
                .plain => try content.print(self.allocator, "Notes on orca{d:0>4}zz harbor: the weather was mild and the meeting ran long.", .{index}),
            }
            const created_at = try std.fmt.allocPrint(self.allocator, "2026-01-{d:0>2}T{d:0>2}:{d:0>2}:00Z", .{ 1 + index / 1440, (index / 60) % 24, index % 60 });
            defer self.allocator.free(created_at);
            const response = try self.call(
                "{{\"jsonrpc\":\"2.0\",\"id\":\"r{d}\",\"method\":\"memory.remember\",\"params\":{{\"scope\":{{\"projectId\":\"{s}\"}},\"messages\":[{{\"role\":\"user\",\"content\":\"{s}\",\"createdAt\":\"{s}\"}},{{\"role\":\"assistant\",\"content\":\"Noted reply{d:0>4}zz for the harbor log.\",\"createdAt\":\"{s}\"}}]}}}}",
                .{ index, project, content.items, created_at, index, created_at },
            );
            defer self.allocator.free(response);
            var parsed = try std.json.parseFromSlice(Value, self.allocator, response, .{});
            defer parsed.deinit();
            const result = parsed.value.object.get("result").?.object;
            const message_qids = result.get("messageQids").?.array.items;
            const session_qid = try self.allocator.dupe(u8, result.get("sessionQid").?.string);
            errdefer self.allocator.free(session_qid);
            const user_qid = try self.allocator.dupe(u8, message_qids[0].string);
            errdefer self.allocator.free(user_qid);
            const reply_qid = try self.allocator.dupe(u8, message_qids[1].string);
            errdefer self.allocator.free(reply_qid);
            try self.remembered.append(self.allocator, .{
                .index = index,
                .project = project,
                .kind = kind,
                .package_manager = package_manager,
                .session_qid = session_qid,
                .user_qid = user_qid,
                .reply_qid = reply_qid,
            });
        }
    }

    fn countNodes(self: *Scenario) !usize {
        var nodes = self.store.iterateNodes(self.allocator, .{});
        defer nodes.deinit();
        var total: usize = 0;
        while (try nodes.next()) |_| total += 1;
        return total;
    }

    /// The latest package-manager message of `project` is the one current
    /// fact for the slot, though every earlier version sits deep in the store.
    fn expectLatestPackageManager(self: *Scenario, project: []const u8) !void {
        var latest: ?Remembered = null;
        var previous: ?Remembered = null;
        for (self.remembered.items) |item| {
            if (item.kind != .package_manager or !std.mem.eql(u8, item.project, project)) continue;
            previous = latest;
            latest = item;
        }
        const expected = latest.?;
        // The value flipped, so supersession had something to do.
        try std.testing.expect(!std.mem.eql(u8, expected.package_manager.?, previous.?.package_manager.?));

        const where = [_]storage.PropertyMatch{
            .{ .name = "slotKey", .value = "project.package_manager" },
            .{ .name = "state", .value = "current" },
        };
        var current = self.store.iterateNodes(self.allocator, .{ .label = "Fact", .where = &where });
        defer current.deinit();
        var matches: usize = 0;
        while (try current.next()) |qid| {
            const node = (try self.store.getNode(self.allocator, qid)).?;
            defer self.store.freeNode(self.allocator, node);
            if (!try storage.propertyStringEquals(self.allocator, node.properties_json, "projectId", project)) continue;
            matches += 1;
            try std.testing.expect(try storage.propertyStringEquals(self.allocator, node.properties_json, "evidenceQid", expected.user_qid));
            try std.testing.expect(try storage.propertyStringEquals(self.allocator, node.properties_json, "value", expected.package_manager.?));
        }
        try std.testing.expectEqual(@as(usize, 1), matches);

        const answer = try self.call(
            "{{\"jsonrpc\":\"2.0\",\"id\":\"a\",\"method\":\"memory.answer\",\"params\":{{\"query\":\"Which package manager does this repo use?\",\"scope\":{{\"projectId\":\"{s}\"}},\"options\":{{\"logRetrieval\":false}}}}}}",
            .{project},
        );
        defer self.allocator.free(answer);
        const needle = try std.fmt.allocPrint(self.allocator, "\"answer\":\"{s}\"", .{expected.package_manager.?});
        defer self.allocator.free(needle);
        try std.testing.expect(std.mem.indexOf(u8, answer, needle) != null);
    }

    fn consolidate(self: *Scenario, project: []const u8) !void {
        const response = try self.call(
            "{{\"jsonrpc\":\"2.0\",\"id\":\"c\",\"method\":\"memory.core.consolidate\",\"params\":{{\"scope\":{{\"projectId\":\"{s}\"}},\"blockKey\":\"project_summary\",\"limit\":100000}}}}",
            .{project},
        );
        self.allocator.free(response);
    }

    /// Forgets and records what must no longer be reachable: the marker of
    /// every forgotten message and every qid the report names.
    fn forget(self: *Scenario, selector_json: []const u8, forgotten: []const ForgottenText) !std.json.Parsed(Value) {
        const response = try self.call(
            "{{\"jsonrpc\":\"2.0\",\"id\":\"f\",\"method\":\"memory.forget\",\"params\":{{\"mode\":\"hard_delete\",\"selector\":{s},\"reason\":\"scale_test\"}}}}",
            .{selector_json},
        );
        defer self.allocator.free(response);
        var parsed = try std.json.parseFromSlice(Value, self.allocator, response, .{});
        errdefer parsed.deinit();
        const result = parsed.value.object.get("result").?.object;
        for (result.get("report").?.array.items) |item| {
            _ = try self.forgotten_qids.appendUnique(item.object.get("qid").?.string);
        }
        for (forgotten) |text| try self.addForgottenMarkers(text);
        return parsed;
    }

    fn addForgottenMarkers(self: *Scenario, text: ForgottenText) !void {
        const item = self.remembered.items[text.index];
        if (text.user) {
            try self.addMarker("orca", item.index, text.query);
            if (item.kind == .long) try self.addMarker("tail", item.index, text.query);
        }
        if (text.reply) try self.addMarker("reply", item.index, text.query);
    }

    fn addMarker(self: *Scenario, prefix: []const u8, index: usize, query: bool) !void {
        var buffer: [32]u8 = undefined;
        const marker = try std.fmt.bufPrint(&buffer, "{s}{d:0>4}zz", .{ prefix, index });
        if (!try self.forgotten_markers.appendUnique(marker)) return;
        const items = self.forgotten_markers.items.items;
        if (query) try self.query_markers.append(self.allocator, items[items.len - 1]);
    }

    /// No forgotten marker is reachable through search, vector search,
    /// retrieve, answer, inspect or core get, and verify finds no leak.
    fn expectNothingReachable(self: *Scenario) !void {
        const allocator = self.allocator;
        for (self.query_markers.items) |marker| {
            const methods = [_][]const u8{
                "{{\"jsonrpc\":\"2.0\",\"id\":\"s\",\"method\":\"memory.search\",\"params\":{{\"query\":\"{s}\",\"limit\":50}}}}",
                "{{\"jsonrpc\":\"2.0\",\"id\":\"s\",\"method\":\"memory.search\",\"params\":{{\"query\":\"{s}\",\"mode\":\"hybrid\",\"limit\":50}}}}",
                "{{\"jsonrpc\":\"2.0\",\"id\":\"r\",\"method\":\"memory.retrieve\",\"params\":{{\"query\":\"{s}\",\"options\":{{\"logRetrieval\":false,\"logAudit\":false}}}}}}",
                "{{\"jsonrpc\":\"2.0\",\"id\":\"a\",\"method\":\"memory.answer\",\"params\":{{\"query\":\"{s}\",\"options\":{{\"logRetrieval\":false}}}}}}",
            };
            inline for (methods) |format| {
                const response = try self.call(format, .{marker});
                defer allocator.free(response);
                try self.expectNoForgottenMarker(response);
                try self.expectNoForgottenQid(response);
            }
            try self.expectVectorSearchClean(marker);
        }

        for (self.forgotten_qids.items.items) |qid| {
            const response = try self.call("{{\"jsonrpc\":\"2.0\",\"id\":\"i\",\"method\":\"memory.inspect\",\"params\":{{\"qid\":\"{s}\"}}}}", .{qid});
            defer allocator.free(response);
            try self.expectNoForgottenMarker(response);
            try std.testing.expect(std.mem.indexOf(u8, response, "\\\"deleted\\\":true") != null);
        }

        const core = try self.call("{{\"jsonrpc\":\"2.0\",\"id\":\"g\",\"method\":\"memory.core.get\",\"params\":{{}}}}", .{});
        defer allocator.free(core);
        try self.expectNoForgottenMarker(core);

        const issues = try forgetting.verify(allocator, self.store, .{ .leaks = true });
        defer forgetting.freeIssues(allocator, issues);
        try expectNoIssues(issues);
        const storage_issues = try self.store.verify(allocator);
        defer {
            for (storage_issues) |issue| if (issue.qid) |qid| allocator.free(qid);
            allocator.free(storage_issues);
        }
        try expectNoIssues(storage_issues);
    }

    /// Lattice only: the forgotten text's own embedding finds no tombstone.
    fn expectVectorSearchClean(self: *Scenario, marker: []const u8) !void {
        if (!self.store.capabilities().vector) return;
        const vector = try self.store.embedText(self.allocator, marker);
        defer self.allocator.free(vector);
        const hits = try self.store.vectorSearch(self.allocator, .{ .vector = vector, .limit = 50 });
        defer {
            for (hits) |hit| self.allocator.free(hit.qid);
            self.allocator.free(hits);
        }
        for (hits) |hit| {
            if (self.forgotten_qids.contains(hit.qid)) {
                std.debug.print("vector search for {s} returned forgotten {s}\n", .{ marker, hit.qid });
                return error.TestUnexpectedResult;
            }
        }
    }

    /// Fails when `response` holds any forgotten marker. Markers are
    /// `orca`, `tail` or `reply`, four digits and `zz`.
    fn expectNoForgottenMarker(self: *Scenario, response: []const u8) !void {
        for ([_][]const u8{ "orca", "tail", "reply" }) |prefix| {
            var start: usize = 0;
            while (std.mem.indexOfPos(u8, response, start, prefix)) |at| {
                start = at + prefix.len;
                const end = at + prefix.len + 6;
                if (end > response.len) break;
                const marker = response[at..end];
                if (!self.forgotten_markers.contains(marker)) continue;
                std.debug.print("forgotten {s} is reachable: ...{s}...\n", .{ marker, response[at -| 200..@min(response.len, at + 200)] });
                return error.TestUnexpectedResult;
            }
        }
    }

    /// Fails when `response` names a forgotten node.
    fn expectNoForgottenQid(self: *Scenario, response: []const u8) !void {
        var start: usize = 0;
        while (std.mem.indexOfPos(u8, response, start, "\"q_")) |at| {
            const qid_start = at + 1;
            const qid_end = std.mem.indexOfScalarPos(u8, response, qid_start, '"') orelse break;
            start = qid_end + 1;
            const qid = response[qid_start..qid_end];
            if (!self.forgotten_qids.contains(qid)) continue;
            std.debug.print("response names forgotten {s}: {s}\n", .{ qid, response[0..@min(response.len, 600)] });
            return error.TestUnexpectedResult;
        }
    }

    fn expectFindable(self: *Scenario, marker: []const u8) !void {
        const response = try self.call("{{\"jsonrpc\":\"2.0\",\"id\":\"s\",\"method\":\"memory.search\",\"params\":{{\"query\":\"{s}\",\"limit\":5}}}}", .{marker});
        defer self.allocator.free(response);
        try std.testing.expect(std.mem.indexOf(u8, response, marker) != null);
    }
};

const ForgottenText = struct {
    index: usize,
    user: bool = true,
    reply: bool = false,
    /// Search for its markers one by one; inspect, core get and verify
    /// cover every forgotten marker regardless.
    query: bool = true,
};

fn expectNoMarker(response: []const u8, marker: []const u8) !void {
    // A query is never echoed back; any occurrence is forgotten text.
    if (std.mem.indexOf(u8, response, marker)) |at| {
        std.debug.print("forgotten {s} is reachable: ...{s}...\n", .{ marker, response[at -| 200..@min(response.len, at + 200)] });
        return error.TestUnexpectedResult;
    }
}

fn expectNoIssues(issues: []const storage.VerificationIssue) !void {
    if (issues.len == 0) return;
    for (issues[0..@min(issues.len, 10)]) |issue| {
        std.debug.print("issue {s} {s} (related {s})\n", .{ issue.code, issue.qid orelse "-", issue.relatedQid orelse "-" });
    }
    return error.TestUnexpectedResult;
}

fn elapsedMs(io: std.Io, since: std.Io.Timestamp) i64 {
    return since.untilNow(io, .awake).toMilliseconds();
}

/// Builds `count` remembers, checks supersession, consolidates, then forgets
/// early and late evidence by qid, by query and by session, and checks that
/// nothing forgotten stays reachable.
fn runForgetScale(count: usize, min_nodes: usize, report_timings: bool) !void {
    // The testing allocator records a stack trace per allocation, which
    // dominates a run this size; this one still fails the test on a leak.
    var debug_allocator = std.heap.DebugAllocator(.{ .stack_trace_frames = 0 }).init;
    defer if (debug_allocator.deinit() == .leak) @panic("forget scale test leaked memory");
    const allocator = debug_allocator.allocator();
    const io = std.testing.io;
    var harness = try Harness.init(allocator);
    defer harness.deinit(allocator);
    var scenario = Scenario.init(allocator, harness.adapter());
    defer scenario.deinit();

    var started = std.Io.Timestamp.now(io, .awake);
    try scenario.rememberAll(count);
    const remember_ms = elapsedMs(io, started);
    const node_count = try scenario.countNodes();
    try std.testing.expect(node_count > min_nodes);

    started = std.Io.Timestamp.now(io, .awake);
    try scenario.expectLatestPackageManager("repo:scale-a");
    try scenario.expectLatestPackageManager("repo:scale-b");
    try scenario.consolidate("repo:scale-a");
    try scenario.consolidate("repo:scale-b");
    const consolidate_ms = elapsedMs(io, started);

    started = std.Io.Timestamp.now(io, .awake);
    var verify_issues = try forgetting.verify(allocator, scenario.store, .{ .leaks = true });
    try expectNoIssues(verify_issues);
    forgetting.freeIssues(allocator, verify_issues);
    const verify_ms = elapsedMs(io, started);

    const items = scenario.remembered.items;
    started = std.Io.Timestamp.now(io, .awake);
    // Early evidence by qid: a package-manager fact, a procedure and a
    // chunked message, all among the first nodes written.
    {
        const selector = try std.fmt.allocPrint(allocator, "{{\"qids\":[\"{s}\",\"{s}\",\"{s}\"]}}", .{ items[0].user_qid, items[1].user_qid, items[3].user_qid });
        defer allocator.free(selector);
        var parsed = try scenario.forget(selector, &.{ .{ .index = 0 }, .{ .index = 1 }, .{ .index = 3 } });
        defer parsed.deinit();
        const result = parsed.value.object.get("result").?.object;
        try std.testing.expectEqual(@as(i64, 3), result.get("rootsMatched").?.integer);
        try std.testing.expectEqual(@as(i64, 2), result.get("factsInvalidated").?.integer);
        // The early core block summarized those memories.
        try std.testing.expectEqual(@as(i64, 1), result.get("summariesContaminated").?.integer);
    }
    // Late evidence by qid, written thousands of nodes after the cap.
    {
        const selector = try std.fmt.allocPrint(allocator, "{{\"qids\":[\"{s}\",\"{s}\",\"{s}\"]}}", .{ items[count - 1].user_qid, items[count - 2].user_qid, items[count - 3].user_qid });
        defer allocator.free(selector);
        var parsed = try scenario.forget(selector, &.{ .{ .index = count - 1 }, .{ .index = count - 2 }, .{ .index = count - 3 } });
        defer parsed.deinit();
        const result = parsed.value.object.get("result").?.object;
        try std.testing.expectEqual(@as(i64, 3), result.get("rootsMatched").?.integer);
        try std.testing.expectEqual(@as(i64, 1), result.get("summariesContaminated").?.integer);
    }
    // Evidence spread across the whole store, in one request: whatever order
    // a backend enumerates in, a capped scan would miss some of it.
    const query_index = count - 12;
    const session_index = count / 2 - 4;
    {
        const reserved = [_]usize{ 0, 1, 2, 3, 4, count - 1, count - 2, count - 3, count - 4, query_index, count - 13, session_index };
        var selector = std.ArrayList(u8).empty;
        defer selector.deinit(allocator);
        var spread = std.ArrayList(ForgottenText).empty;
        defer spread.deinit(allocator);
        try selector.appendSlice(allocator, "{\"qids\":[");
        var index: usize = 6;
        while (index < count) : (index += 7) {
            if (std.mem.indexOfScalar(usize, &reserved, index) != null) continue;
            if (spread.items.len > 0) try selector.append(allocator, ',');
            try selector.print(allocator, "\"{s}\"", .{items[index].user_qid});
            try spread.append(allocator, .{ .index = index, .query = spread.items.len % 4 == 0 });
        }
        try selector.appendSlice(allocator, "]}");
        var parsed = try scenario.forget(selector.items, spread.items);
        defer parsed.deinit();
        try std.testing.expectEqual(@as(i64, @intCast(spread.items.len)), parsed.value.object.get("result").?.object.get("rootsMatched").?.integer);
    }
    // By query: one late marker.
    {
        const selector = try std.fmt.allocPrint(allocator, "{{\"query\":\"orca{d:0>4}zz\"}}", .{query_index});
        defer allocator.free(selector);
        var parsed = try scenario.forget(selector, &.{.{ .index = query_index }});
        defer parsed.deinit();
        try std.testing.expectEqual(@as(i64, 1), parsed.value.object.get("result").?.object.get("rootsMatched").?.integer);
    }
    // By session: a mid-store session forgets both of its messages.
    {
        const selector = try std.fmt.allocPrint(allocator, "{{\"qids\":[\"{s}\"]}}", .{items[session_index].session_qid});
        defer allocator.free(selector);
        var parsed = try scenario.forget(selector, &.{.{ .index = session_index, .reply = true }});
        defer parsed.deinit();
        try std.testing.expectEqual(@as(i64, 3), parsed.value.object.get("result").?.object.get("rootsMatched").?.integer);
    }
    const forget_ms = elapsedMs(io, started);

    // A query shared by every message selects all of them on a dry run, not
    // the top 1,000 by score.
    started = std.Io.Timestamp.now(io, .awake);
    {
        var live_messages: usize = 0;
        var messages = scenario.store.iterateNodes(allocator, .{ .label = "Message" });
        defer messages.deinit();
        while (try messages.next()) |qid| {
            if (!scenario.forgotten_qids.contains(qid)) live_messages += 1;
        }
        const response = try scenario.call("{{\"jsonrpc\":\"2.0\",\"id\":\"f\",\"method\":\"memory.forget\",\"params\":{{\"mode\":\"hard_delete\",\"selector\":{{\"query\":\"harbor\"}},\"dryRun\":true}}}}", .{});
        defer allocator.free(response);
        var parsed = try std.json.parseFromSlice(Value, allocator, response, .{});
        defer parsed.deinit();
        const roots: usize = @intCast(parsed.value.object.get("result").?.object.get("rootsMatched").?.integer);
        // Every live message, and nothing else: both core blocks that quoted
        // "harbor" are already forgotten.
        try std.testing.expectEqual(live_messages, roots);
        if (count >= 600) try std.testing.expect(roots > 1000);
    }
    const dry_run_ms = elapsedMs(io, started);

    started = std.Io.Timestamp.now(io, .awake);
    try scenario.expectNothingReachable();
    // Unforgotten neighbours stay findable.
    for ([_]usize{ 2, 4, count - 4, count - 13 }) |index| {
        var buffer: [32]u8 = undefined;
        try scenario.expectFindable(try std.fmt.bufPrint(&buffer, "orca{d:0>4}zz", .{index}));
    }
    const check_ms = elapsedMs(io, started);

    started = std.Io.Timestamp.now(io, .awake);
    verify_issues = try forgetting.verify(allocator, scenario.store, .{ .leaks = true });
    try expectNoIssues(verify_issues);
    forgetting.freeIssues(allocator, verify_issues);
    const verify_after_ms = elapsedMs(io, started);

    if (report_timings) {
        std.debug.print(
            "\nforget scale ({s}, {d} remembers, {d} nodes): remember {d} ms, supersede+consolidate {d} ms, verify {d} ms, forgets {d} ms, dry-run query {d} ms, reachability {d} ms, verify after {d} ms\n",
            .{ harness.adapter().capabilities().backend, count, node_count, remember_ms, consolidate_ms, verify_ms, forget_ms, dry_run_ms, check_ms, verify_after_ms },
        );
    }
}

test "forgetting propagates past 1,000 nodes and supersession finds the latest slot value" {
    // Lattice writes cost milliseconds each, so its default run stays small
    // but still holds well over 1,000 nodes.
    if (build_options.enable_lattice) {
        try runForgetScale(150, 1000, false);
    } else {
        try runForgetScale(700, 5000, false);
    }
}

test "forgetting and supersession hold on a store past 5,000 nodes" {
    if (!build_options.enable_lattice) return error.SkipZigTest;
    if (!try slowTestsEnabled()) return error.SkipZigTest;
    try runForgetScale(700, 5000, true);
}

fn putTestNode(store: storage.Adapter, qid: []const u8, label: []const u8, properties_json: []const u8) !void {
    try store.putNode(.{ .qid = qid, .label = label, .properties_json = properties_json });
}

fn putTestEdge(store: storage.Adapter, qid: []const u8, from_qid: []const u8, to_qid: []const u8, edge_type: []const u8) !void {
    try store.putEdge(.{ .qid = qid, .from_qid = from_qid, .to_qid = to_qid, .edge_type = edge_type, .properties_json = "{}" });
}

fn firstMessageQid(allocator: std.mem.Allocator, response: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(Value, allocator, response, .{});
    defer parsed.deinit();
    return allocator.dupe(u8, parsed.value.object.get("result").?.object.get("messageQids").?.array.items[0].string);
}

fn expectTombstone(store: storage.Adapter, qid: []const u8) !void {
    const node = (try store.getNode(std.testing.allocator, qid)).?;
    defer store.freeNode(std.testing.allocator, node);
    try std.testing.expect(std.mem.indexOf(u8, node.properties_json, "\"deleted\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, node.properties_json, "flowerpot") == null);
}

fn hasIssue(issues: []const storage.VerificationIssue, code: []const u8, qid: ?[]const u8) bool {
    for (issues) |issue| {
        if (!std.mem.eql(u8, issue.code, code)) continue;
        if (qid) |expected| {
            if (issue.qid == null or !std.mem.eql(u8, issue.qid.?, expected)) continue;
        }
        return true;
    }
    return false;
}

test "forgetting tombstones every node derived from the evidence, whatever its label" {
    const allocator = std.testing.allocator;
    var harness = try Harness.init(allocator);
    defer harness.deinit(allocator);
    const store = harness.adapter();
    var scenario = Scenario.init(allocator, store);
    defer scenario.deinit();

    const remembered = try scenario.call("{{\"jsonrpc\":\"2.0\",\"id\":\"r\",\"method\":\"memory.remember\",\"params\":{{\"messages\":[{{\"role\":\"user\",\"content\":\"My locker code is 4417 and the spare key lives under the blue flowerpot.\"}}]}}}}", .{});
    defer allocator.free(remembered);
    const message_qid = try firstMessageQid(allocator, remembered);
    defer allocator.free(message_qid);

    // Labels the runtime has never heard of, linked only by provenance.
    try putTestNode(store, "q_assert_901", "Assertion", "{\"text\":\"The spare key lives under the blue flowerpot.\",\"state\":\"current\",\"deleted\":false}");
    try putTestEdge(store, "q_edge_902", "q_assert_901", message_qid, "EVIDENCED_BY");
    // Linked by `evidenceQid` alone, as if its edge write had been lost.
    const orphan = try std.fmt.allocPrint(allocator, "{{\"text\":\"Locker code 4417 near the blue flowerpot.\",\"evidenceQid\":\"{s}\",\"deleted\":false}}", .{message_qid});
    defer allocator.free(orphan);
    try putTestNode(store, "q_assert_903", "Assertion", orphan);
    // Derived from a derived node.
    try putTestNode(store, "q_insight_904", "Insight", "{\"text\":\"Keys hide under the blue flowerpot.\",\"deleted\":false}");
    try putTestEdge(store, "q_edge_905", "q_insight_904", "q_assert_901", "DERIVED_FROM");
    // Unrelated memory stays.
    try putTestNode(store, "q_assert_906", "Assertion", "{\"text\":\"The garage door sticks in winter.\",\"deleted\":false}");

    const selector = try std.fmt.allocPrint(allocator, "{{\"qids\":[\"{s}\"]}}", .{message_qid});
    defer allocator.free(selector);
    var parsed = try scenario.forget(selector, &.{});
    defer parsed.deinit();
    for ([_][]const u8{ message_qid, "q_assert_901", "q_assert_903", "q_insight_904" }) |qid| {
        try std.testing.expect(scenario.forgotten_qids.contains(qid));
        try expectTombstone(store, qid);
    }
    try std.testing.expect(!scenario.forgotten_qids.contains("q_assert_906"));

    const search = try scenario.call("{{\"jsonrpc\":\"2.0\",\"id\":\"s\",\"method\":\"memory.search\",\"params\":{{\"query\":\"flowerpot\"}}}}", .{});
    defer allocator.free(search);
    try expectNoMarker(search, "flowerpot");
    const issues = try forgetting.verify(allocator, store, .{ .leaks = true });
    defer forgetting.freeIssues(allocator, issues);
    try expectNoIssues(issues);
}

test "verify reports derived memory and copied text a forget without propagation leaves" {
    const allocator = std.testing.allocator;
    var harness = try Harness.init(allocator);
    defer harness.deinit(allocator);
    const store = harness.adapter();
    var scenario = Scenario.init(allocator, store);
    defer scenario.deinit();

    const remembered = try scenario.call("{{\"jsonrpc\":\"2.0\",\"id\":\"r\",\"method\":\"memory.remember\",\"params\":{{\"messages\":[{{\"role\":\"user\",\"content\":\"Please run `just test` first. My locker code is 4417 and the spare key lives under the blue flowerpot.\",\"createdAt\":\"2026-01-01T00:00:00Z\"}}]}}}}", .{});
    defer allocator.free(remembered);
    const message_qid = try firstMessageQid(allocator, remembered);
    defer allocator.free(message_qid);
    // An unlinked copy: no edge or evidenceQid explains its text.
    try putTestNode(store, "q_note_901", "Note", "{\"text\":\"Copied: the spare key lives under the blue flowerpot by the door.\",\"deleted\":false}");

    const forget = try scenario.call("{{\"jsonrpc\":\"2.0\",\"id\":\"f\",\"method\":\"memory.forget\",\"params\":{{\"mode\":\"redact\",\"propagate\":false,\"selector\":{{\"qids\":[\"{s}\"]}}}}}}", .{message_qid});
    defer allocator.free(forget);

    const structural = try forgetting.verify(allocator, store, .{});
    defer forgetting.freeIssues(allocator, structural);
    try std.testing.expect(hasIssue(structural, "active_derived_from_deleted_evidence", null));
    try std.testing.expect(!hasIssue(structural, "forgotten_text_leak", null));

    const leaks = try forgetting.verify(allocator, store, .{ .leaks = true });
    defer forgetting.freeIssues(allocator, leaks);
    // The procedure and its card quote the message; the note copies it.
    try std.testing.expect(hasIssue(leaks, "forgotten_text_leak", "q_note_901"));
    var procedure_leaks: usize = 0;
    for (leaks) |issue| {
        if (!std.mem.eql(u8, issue.code, "forgotten_text_leak")) continue;
        try std.testing.expectEqualStrings(message_qid, issue.relatedQid.?);
        procedure_leaks += 1;
    }
    try std.testing.expect(procedure_leaks >= 3);
}

test "a core block rebuilt without a source survives forgetting that source" {
    const allocator = std.testing.allocator;
    var harness = try Harness.init(allocator);
    defer harness.deinit(allocator);
    const store = harness.adapter();
    var scenario = Scenario.init(allocator, store);
    defer scenario.deinit();

    var message_qids: [2][]u8 = undefined;
    for (&message_qids, [_][]const u8{ "We use pnpm for the harbor service.", "Please run `just test` before merging." }) |*qid, content| {
        const remembered = try scenario.call("{{\"jsonrpc\":\"2.0\",\"id\":\"r\",\"method\":\"memory.remember\",\"params\":{{\"scope\":{{\"projectId\":\"p\"}},\"messages\":[{{\"role\":\"user\",\"content\":\"{s}\",\"createdAt\":\"2026-01-01T00:00:00Z\"}}]}}}}", .{content});
        defer allocator.free(remembered);
        qid.* = try firstMessageQid(allocator, remembered);
    }
    defer for (message_qids) |qid| allocator.free(qid);

    // Built from both remembers, then rebuilt in place from the first only:
    // its COMPILED_FROM edges to the second remain.
    for ([_]usize{ 50, 3 }) |limit| {
        const consolidated = try scenario.call("{{\"jsonrpc\":\"2.0\",\"id\":\"c\",\"method\":\"memory.core.consolidate\",\"params\":{{\"scope\":{{\"projectId\":\"p\"}},\"limit\":{d}}}}}", .{limit});
        allocator.free(consolidated);
    }
    const second = try scenario.call("{{\"jsonrpc\":\"2.0\",\"id\":\"f\",\"method\":\"memory.forget\",\"params\":{{\"mode\":\"hard_delete\",\"selector\":{{\"qids\":[\"{s}\"]}}}}}}", .{message_qids[1]});
    defer allocator.free(second);
    try std.testing.expect(std.mem.indexOf(u8, second, "\"summariesContaminated\":0") != null);
    const core = try scenario.call("{{\"jsonrpc\":\"2.0\",\"id\":\"g\",\"method\":\"memory.core.get\",\"params\":{{\"scope\":{{\"projectId\":\"p\"}}}}}}", .{});
    defer allocator.free(core);
    try std.testing.expect(std.mem.indexOf(u8, core, "pnpm") != null);

    // The block does cite the first remember.
    const first = try scenario.call("{{\"jsonrpc\":\"2.0\",\"id\":\"f\",\"method\":\"memory.forget\",\"params\":{{\"mode\":\"hard_delete\",\"selector\":{{\"qids\":[\"{s}\"]}}}}}}", .{message_qids[0]});
    defer allocator.free(first);
    try std.testing.expect(std.mem.indexOf(u8, first, "\"summariesContaminated\":1") != null);
    const issues = try forgetting.verify(allocator, store, .{ .leaks = true });
    defer forgetting.freeIssues(allocator, issues);
    try expectNoIssues(issues);
}

test "inspect reads audit events past the first thousand" {
    const allocator = std.testing.allocator;
    var harness = try Harness.init(allocator);
    defer harness.deinit(allocator);
    var scenario = Scenario.init(allocator, harness.adapter());
    defer scenario.deinit();

    for (0..1005) |index| {
        const feedback = try scenario.call("{{\"jsonrpc\":\"2.0\",\"id\":\"fb\",\"method\":\"memory.feedback\",\"params\":{{\"retrievalId\":\"q_retr_{d}\",\"rating\":\"useful\"}}}}", .{index});
        allocator.free(feedback);
    }
    const remembered = try scenario.call("{{\"jsonrpc\":\"2.0\",\"id\":\"r\",\"method\":\"memory.remember\",\"params\":{{\"messages\":[{{\"role\":\"user\",\"content\":\"Late audit entry.\"}}],\"extract\":false}}}}", .{});
    defer allocator.free(remembered);
    const message_qid = try firstMessageQid(allocator, remembered);
    defer allocator.free(message_qid);
    const inspect = try scenario.call("{{\"jsonrpc\":\"2.0\",\"id\":\"i\",\"method\":\"memory.inspect\",\"params\":{{\"qid\":\"{s}\"}}}}", .{message_qid});
    defer allocator.free(inspect);
    try std.testing.expect(std.mem.indexOf(u8, inspect, "\\\"method\\\":\\\"memory.remember\\\"") != null);
}

test "superseding keeps a memory card's own fields" {
    const allocator = std.testing.allocator;
    var harness = try Harness.init(allocator);
    defer harness.deinit(allocator);
    const store = harness.adapter();
    var scenario = Scenario.init(allocator, store);
    defer scenario.deinit();

    for ([_][]const u8{ "We use npm here.", "We use pnpm here now." }) |content| {
        const remembered = try scenario.call("{{\"jsonrpc\":\"2.0\",\"id\":\"r\",\"method\":\"memory.remember\",\"params\":{{\"messages\":[{{\"role\":\"user\",\"content\":\"{s}\",\"createdAt\":\"2026-01-01T00:00:00Z\"}}]}}}}", .{content});
        allocator.free(remembered);
    }
    const page = try store.findNodes(allocator, .{ .label = "MemoryCard", .where = &.{.{ .name = "state", .value = "superseded" }} });
    defer store.freeNodePage(allocator, page);
    try std.testing.expectEqual(@as(usize, 1), page.qids.len);
    const card = (try store.getNode(allocator, page.qids[0])).?;
    defer store.freeNode(allocator, card);
    for ([_][]const u8{ "\"cardKind\":\"semantic\"", "\"keywords\"", "\"value\":\"npm\"", "\"validTo\":\"2026-01-01T00:00:00Z\"" }) |needle| {
        if (std.mem.indexOf(u8, card.properties_json, needle) == null) {
            std.debug.print("missing {s} in {s}\n", .{ needle, card.properties_json });
            return error.TestUnexpectedResult;
        }
    }
}

test "forgetting the last message that mentions an entity forgets the entity" {
    const allocator = std.testing.allocator;
    var harness = try Harness.init(allocator);
    defer harness.deinit(allocator);
    const store = harness.adapter();
    var scenario = Scenario.init(allocator, store);
    defer scenario.deinit();

    var message_qids: [2][]u8 = undefined;
    for (&message_qids, [_][]const u8{ "Biscuit the beagle chewed the blue flowerpot.", "Rex and Biscuit met at the park." }) |*qid, content| {
        const remembered = try scenario.call("{{\"jsonrpc\":\"2.0\",\"id\":\"r\",\"method\":\"memory.remember\",\"params\":{{\"messages\":[{{\"role\":\"user\",\"content\":\"{s}\"}}],\"extract\":false}}}}", .{content});
        defer allocator.free(remembered);
        qid.* = try firstMessageQid(allocator, remembered);
    }
    defer for (message_qids) |qid| allocator.free(qid);
    try putTestNode(store, "q_entity_flowerpot", "Entity", "{\"canonicalName\":\"Blue Flowerpot\",\"searchText\":\"Blue Flowerpot\",\"deleted\":false}");
    try putTestNode(store, "q_entity_biscuit", "Entity", "{\"canonicalName\":\"Biscuit\",\"searchText\":\"Biscuit\",\"deleted\":false}");
    try putTestEdge(store, "q_edge_m1", message_qids[0], "q_entity_flowerpot", "MENTIONS");
    try putTestEdge(store, "q_edge_m2", message_qids[0], "q_entity_biscuit", "MENTIONS");
    try putTestEdge(store, "q_edge_m3", message_qids[1], "q_entity_biscuit", "MENTIONS");

    const selector = try std.fmt.allocPrint(allocator, "{{\"qids\":[\"{s}\"]}}", .{message_qids[0]});
    defer allocator.free(selector);
    var first = try scenario.forget(selector, &.{});
    first.deinit();
    // Only the forgotten message named the flowerpot; Biscuit is still
    // mentioned by a live message.
    try expectTombstone(store, "q_entity_flowerpot");
    try std.testing.expect(!scenario.forgotten_qids.contains("q_entity_biscuit"));
    var issues = try forgetting.verify(allocator, store, .{ .leaks = true });
    try expectNoIssues(issues);
    forgetting.freeIssues(allocator, issues);

    // Without propagation the last mention leaves Biscuit behind, and verify
    // says so.
    const second = try scenario.call("{{\"jsonrpc\":\"2.0\",\"id\":\"f\",\"method\":\"memory.forget\",\"params\":{{\"mode\":\"hard_delete\",\"propagate\":false,\"selector\":{{\"qids\":[\"{s}\"]}}}}}}", .{message_qids[1]});
    allocator.free(second);
    issues = try forgetting.verify(allocator, store, .{});
    defer forgetting.freeIssues(allocator, issues);
    try std.testing.expect(hasIssue(issues, "entity_only_from_deleted_evidence", "q_entity_biscuit"));
}

