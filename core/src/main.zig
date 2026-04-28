const std = @import("std");
const in_memory_storage = @import("in_memory_storage.zig");
const protocol = @import("protocol.zig");
const runtime_mod = @import("runtime.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var adapter_state = in_memory_storage.InMemoryAdapter.init(allocator);
    defer adapter_state.deinit();
    var runtime = runtime_mod.Runtime.init(adapter_state.adapter(), protocol.Health.default());

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;
    defer stdout.flush() catch {};

    if (args.len > 1 and std.mem.eql(u8, args[1], "health")) {
        const response = try runtime.dispatch(
            allocator,
            "{\"jsonrpc\":\"2.0\",\"id\":\"cli_health\",\"method\":\"system.health\",\"params\":{}}",
        );
        defer allocator.free(response);
        try stdout.print("{s}\n", .{response});
        return;
    }

    if (args.len > 1 and std.mem.eql(u8, args[1], "rpc-stdin")) {
        var stdin_buffer: [4096]u8 = undefined;
        var stdin_file_reader: std.Io.File.Reader = .init(.stdin(), init.io, &stdin_buffer);
        const request = try stdin_file_reader.interface.allocRemaining(allocator, .limited(1024 * 1024));
        defer allocator.free(request);
        const response = try runtime.dispatch(allocator, request);
        defer allocator.free(response);
        try stdout.print("{s}\n", .{response});
        return;
    }

    if (args.len > 1 and std.mem.eql(u8, args[1], "serve-stdio")) {
        var stdin_buffer: [4096]u8 = undefined;
        var stdin_file_reader: std.Io.File.Reader = .init(.stdin(), init.io, &stdin_buffer);
        while (true) {
            const line = stdin_file_reader.interface.takeDelimiter('\n') catch |err| switch (err) {
                error.StreamTooLong => {
                    const response = try runtime.dispatch(
                        allocator,
                        "{\"jsonrpc\":\"2.0\",\"id\":null,\"method\":\"system.invalid\",\"params\":{}}",
                    );
                    defer allocator.free(response);
                    try stdout.print("{s}\n", .{response});
                    try stdout.flush();
                    return;
                },
                else => |e| return e,
            };
            const raw = line orelse break;
            const request = std.mem.trim(u8, raw, " \t\r");
            if (request.len == 0) continue;
            const response = try runtime.dispatch(allocator, request);
            defer allocator.free(response);
            try stdout.print("{s}\n", .{response});
            try stdout.flush();
        }
        return;
    }

    try stdout.print("quipu core scaffold\nusage: quipu health | quipu rpc-stdin | quipu serve-stdio\n", .{});
}
