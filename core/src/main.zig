const std = @import("std");
const protocol = @import("protocol.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const stdout = std.io.getStdOut().writer();
    if (args.len > 1 and std.mem.eql(u8, args[1], "health")) {
        const response = try protocol.dispatch(
            allocator,
            "{\"jsonrpc\":\"2.0\",\"id\":\"cli_health\",\"method\":\"system.health\",\"params\":{}}",
            protocol.Health.default(),
        );
        defer allocator.free(response);
        try stdout.print("{s}\n", .{response});
        return;
    }

    if (args.len > 1 and std.mem.eql(u8, args[1], "rpc-stdin")) {
        const stdin = std.io.getStdIn().reader();
        const request = try stdin.readAllAlloc(allocator, 1024 * 1024);
        defer allocator.free(request);
        const response = try protocol.dispatch(allocator, request, protocol.Health.default());
        defer allocator.free(response);
        try stdout.print("{s}\n", .{response});
        return;
    }

    try stdout.print("quipu core scaffold\nusage: quipu health | quipu rpc-stdin\n", .{});
}
