const std = @import("std");
const storage = @import("storage.zig");

pub const current_version: u32 = 1;
pub const metadata_qid = "q_schema_current";
pub const initial_migration_qid = "q_migration_0001_initial";

pub fn ensure(allocator: std.mem.Allocator, store: storage.Adapter) !void {
    try ensureMetadata(allocator, store);
    try ensureInitialMigration(allocator, store);
}

pub fn verify(allocator: std.mem.Allocator, store: storage.Adapter) ![]storage.VerificationIssue {
    var issues = std.ArrayList(storage.VerificationIssue).empty;
    errdefer freeIssues(allocator, issues.items);
    errdefer issues.deinit(allocator);

    if (try store.getNode(allocator, metadata_qid)) |node| {
        defer store.freeNode(allocator, node);
        if (!std.mem.eql(u8, node.label, "Schema")) {
            try appendIssue(allocator, &issues, "schema_metadata_label", "schema metadata node has the wrong label", metadata_qid);
        }
        if (!try propertyIntegerEquals(allocator, node.properties_json, "schemaVersion", current_version)) {
            try appendIssue(allocator, &issues, "schema_version_mismatch", "schema metadata version does not match the runtime", metadata_qid);
        }
        if (!try propertyStringEquals(allocator, node.properties_json, "state", "active")) {
            try appendIssue(allocator, &issues, "schema_state_invalid", "schema metadata state must be active", metadata_qid);
        }
    } else {
        try appendIssue(allocator, &issues, "schema_metadata_missing", "schema metadata node is missing", null);
    }

    if (try store.getNode(allocator, initial_migration_qid)) |node| {
        defer store.freeNode(allocator, node);
        if (!std.mem.eql(u8, node.label, "Migration")) {
            try appendIssue(allocator, &issues, "migration_label_invalid", "initial migration node has the wrong label", initial_migration_qid);
        }
        if (!try propertyStringEquals(allocator, node.properties_json, "status", "applied")) {
            try appendIssue(allocator, &issues, "migration_not_applied", "initial migration is not marked applied", initial_migration_qid);
        }
    } else {
        try appendIssue(allocator, &issues, "migration_initial_missing", "initial migration record is missing", null);
    }

    return issues.toOwnedSlice(allocator);
}

fn ensureMetadata(allocator: std.mem.Allocator, store: storage.Adapter) !void {
    if (try store.getNode(allocator, metadata_qid)) |node| {
        store.freeNode(allocator, node);
        return;
    }

    const now_ms: i64 = 0;
    const props = try stringifyAlloc(allocator, .{
        .kind = "schema",
        .qtype = "schema",
        .schemaVersion = current_version,
        .schema_version = current_version,
        .state = "active",
        .createdAtMs = now_ms,
        .created_at_ms = now_ms,
        .updatedAtMs = now_ms,
        .updated_at_ms = now_ms,
        .migration = "initial",
        .deleted = false,
    });
    defer allocator.free(props);
    try store.putNode(.{
        .qid = metadata_qid,
        .label = "Schema",
        .properties_json = props,
    });
}

fn ensureInitialMigration(allocator: std.mem.Allocator, store: storage.Adapter) !void {
    if (try store.getNode(allocator, initial_migration_qid)) |node| {
        store.freeNode(allocator, node);
        return;
    }

    const now_ms: i64 = 0;
    const props = try stringifyAlloc(allocator, .{
        .kind = "migration",
        .qtype = "migration",
        .name = "initial",
        .schemaVersion = current_version,
        .schema_version = current_version,
        .status = "applied",
        .appliedAtMs = now_ms,
        .applied_at_ms = now_ms,
        .deleted = false,
    });
    defer allocator.free(props);
    try store.putNode(.{
        .qid = initial_migration_qid,
        .label = "Migration",
        .properties_json = props,
    });
}

fn appendIssue(
    allocator: std.mem.Allocator,
    issues: *std.ArrayList(storage.VerificationIssue),
    code: []const u8,
    message: []const u8,
    qid: ?[]const u8,
) !void {
    const owned_qid = if (qid) |value| try allocator.dupe(u8, value) else null;
    errdefer if (owned_qid) |value| allocator.free(value);
    try issues.append(allocator, .{
        .code = code,
        .message = message,
        .qid = owned_qid,
    });
}

fn freeIssues(allocator: std.mem.Allocator, issues: []const storage.VerificationIssue) void {
    for (issues) |issue| {
        if (issue.qid) |qid| allocator.free(qid);
    }
}

fn propertyStringEquals(allocator: std.mem.Allocator, properties_json: []const u8, key: []const u8, expected: []const u8) !bool {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, properties_json, .{});
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |object| object,
        else => return false,
    };
    const value = object.get(key) orelse return false;
    return switch (value) {
        .string => |string| std.mem.eql(u8, string, expected),
        else => false,
    };
}

fn propertyIntegerEquals(allocator: std.mem.Allocator, properties_json: []const u8, key: []const u8, expected: i64) !bool {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, properties_json, .{});
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |object| object,
        else => return false,
    };
    const value = object.get(key) orelse return false;
    return switch (value) {
        .integer => |integer| integer == expected,
        else => false,
    };
}

fn stringifyAlloc(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    try std.json.Stringify.value(value, .{}, &writer.writer);
    return writer.toOwnedSlice();
}

test "schema ensure creates metadata node idempotently" {
    const in_memory = @import("in_memory_storage.zig");
    var adapter_state = in_memory.InMemoryAdapter.init(std.testing.allocator);
    defer adapter_state.deinit();
    const adapter = adapter_state.adapter();

    try ensure(std.testing.allocator, adapter);
    try ensure(std.testing.allocator, adapter);

    const node = (try adapter.getNode(std.testing.allocator, metadata_qid)) orelse return error.TestUnexpectedResult;
    defer adapter.freeNode(std.testing.allocator, node);
    try std.testing.expectEqualStrings("Schema", node.label);
    try std.testing.expect(std.mem.indexOf(u8, node.properties_json, "\"schemaVersion\":1") != null);

    const migration = (try adapter.getNode(std.testing.allocator, initial_migration_qid)) orelse return error.TestUnexpectedResult;
    defer adapter.freeNode(std.testing.allocator, migration);
    try std.testing.expectEqualStrings("Migration", migration.label);
    try std.testing.expect(std.mem.indexOf(u8, migration.properties_json, "\"status\":\"applied\"") != null);
}

test "schema verify reports missing metadata" {
    const in_memory = @import("in_memory_storage.zig");
    var adapter_state = in_memory.InMemoryAdapter.init(std.testing.allocator);
    defer adapter_state.deinit();
    const adapter = adapter_state.adapter();

    const issues = try verify(std.testing.allocator, adapter);
    defer {
        freeIssues(std.testing.allocator, issues);
        std.testing.allocator.free(issues);
    }

    try std.testing.expectEqual(@as(usize, 2), issues.len);
    try std.testing.expectEqualStrings("schema_metadata_missing", issues[0].code);
    try std.testing.expectEqualStrings("migration_initial_missing", issues[1].code);
}
