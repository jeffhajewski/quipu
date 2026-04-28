const std = @import("std");

pub const ProtocolError = error{
    InvalidRequest,
};

pub const Health = struct {
    version: []const u8 = "0.1.0",
    protocol_version: []const u8 = "2026-04-quipu-v1",
    db_path: ?[]const u8 = null,
    lattice_version: ?[]const u8 = null,
    schema_version: u32 = 1,

    pub fn default() Health {
        return .{};
    }
};

pub fn dispatch(allocator: std.mem.Allocator, request_json: []const u8, health: Health) ![]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, request_json, .{}) catch {
        return errorResponse(allocator, null, "invalid_request", "request body must be valid JSON");
    };
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |object| object,
        else => return errorResponse(allocator, null, "invalid_request", "request must be a JSON object"),
    };

    const id = jsonRpcId(root.get("id"));
    const jsonrpc = stringValue(root.get("jsonrpc")) orelse {
        return errorResponse(allocator, id, "invalid_request", "jsonrpc is required");
    };
    if (!std.mem.eql(u8, jsonrpc, "2.0")) {
        return errorResponse(allocator, id, "invalid_request", "jsonrpc must be 2.0");
    }

    const method = stringValue(root.get("method")) orelse {
        return errorResponse(allocator, id, "invalid_request", "method is required");
    };
    if (std.mem.eql(u8, method, "system.health")) {
        return healthResponse(allocator, id, health);
    }

    return errorResponse(allocator, id, "not_found", "unsupported method");
}

fn healthResponse(allocator: std.mem.Allocator, id: ?[]const u8, health: Health) ![]u8 {
    const response = .{
        .jsonrpc = "2.0",
        .id = id,
        .result = .{
            .status = "ok",
            .version = health.version,
            .protocolVersion = health.protocol_version,
            .dbPath = health.db_path,
            .latticeVersion = health.lattice_version,
            .schemaVersion = health.schema_version,
            .workers = .{
                .extractor = "unavailable",
                .consolidator = "unavailable",
            },
        },
    };
    return std.json.stringifyAlloc(allocator, response, .{});
}

fn errorResponse(allocator: std.mem.Allocator, id: ?[]const u8, code: []const u8, message: []const u8) ![]u8 {
    const response = .{
        .jsonrpc = "2.0",
        .id = id,
        .error = .{
            .code = code,
            .message = message,
            .details = .{},
        },
    };
    return std.json.stringifyAlloc(allocator, response, .{});
}

fn stringValue(value: ?std.json.Value) ?[]const u8 {
    const present = value orelse return null;
    return switch (present) {
        .string => |string| string,
        else => null,
    };
}

fn jsonRpcId(value: ?std.json.Value) ?[]const u8 {
    const present = value orelse return null;
    return switch (present) {
        .string => |string| string,
        else => null,
    };
}

test "dispatches system.health" {
    const response = try dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"req_1\",\"method\":\"system.health\",\"params\":{}}",
        Health.default(),
    );
    defer std.testing.allocator.free(response);

    try std.testing.expect(std.mem.indexOf(u8, response, "\"status\":\"ok\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"protocolVersion\":\"2026-04-quipu-v1\"") != null);
}

test "returns JSON-RPC error for unsupported method" {
    const response = try dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"req_1\",\"method\":\"memory.retrieve\",\"params\":{}}",
        Health.default(),
    );
    defer std.testing.allocator.free(response);

    try std.testing.expect(std.mem.indexOf(u8, response, "\"code\":\"not_found\"") != null);
}
