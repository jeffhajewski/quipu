const std = @import("std");
const storage = @import("storage.zig");

pub const current_version: u32 = 1;
pub const metadata_qid = "q_schema_current";

pub fn ensure(allocator: std.mem.Allocator, store: storage.Adapter) !void {
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
}
