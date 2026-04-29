const std = @import("std");
const build_options = @import("build_options");
const in_memory_storage = @import("in_memory_storage.zig");
const jobs = @import("jobs.zig");
const lattice_storage = if (build_options.enable_lattice) @import("lattice_storage.zig") else struct {};
const protocol = @import("protocol.zig");
const runtime_mod = @import("runtime.zig");
const storage = @import("storage.zig");

const RuntimeConfig = struct {
    command_index: usize = 1,
    db_path: ?[]const u8 = null,
};

const MaterializeCliArgs = struct {
    options: jobs.MaterializeOptions,
    streams: std.ArrayList([]const u8),

    fn deinit(self: *MaterializeCliArgs, allocator: std.mem.Allocator) void {
        self.streams.deinit(allocator);
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var config = parseRuntimeConfig(args);

    if (config.db_path == null and build_options.enable_lattice) {
        config.db_path = init.environ_map.get("QUIPU_DB_PATH");
    }

    if (build_options.enable_lattice and config.db_path != null) {
        var adapter_state = try lattice_storage.LatticeAdapter.open(allocator, config.db_path.?);
        defer adapter_state.deinit();
        var health = protocol.Health.default();
        health.db_path = config.db_path;
        health.lattice_version = lattice_storage.LatticeAdapter.latticeVersion();
        var runtime = runtime_mod.Runtime.initWithNextId(adapter_state.adapter(), health, adapter_state.nextRuntimeId());
        try runCommand(init.io, allocator, args, config.command_index, &runtime, adapter_state.adapter());
        return;
    }

    var adapter_state = in_memory_storage.InMemoryAdapter.init(allocator);
    defer adapter_state.deinit();
    var runtime = runtime_mod.Runtime.init(adapter_state.adapter(), protocol.Health.default());
    try runCommand(init.io, allocator, args, config.command_index, &runtime, adapter_state.adapter());
}

fn parseRuntimeConfig(args: []const [:0]const u8) RuntimeConfig {
    var config = RuntimeConfig{};
    while (config.command_index < args.len) {
        const arg = args[config.command_index];
        if (std.mem.eql(u8, arg, "--db")) {
            if (config.command_index + 1 < args.len) {
                config.db_path = args[config.command_index + 1];
                config.command_index += 2;
                continue;
            }
            config.command_index += 1;
            break;
        }
        break;
    }
    return config;
}

fn runCommand(
    io: std.Io,
    allocator: std.mem.Allocator,
    args: []const [:0]const u8,
    command_index: usize,
    runtime: *runtime_mod.Runtime,
    store: storage.Adapter,
) !void {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;
    defer stdout.flush() catch {};

    if (args.len > command_index and std.mem.eql(u8, args[command_index], "health")) {
        const response = try runtime.dispatch(
            allocator,
            "{\"jsonrpc\":\"2.0\",\"id\":\"cli_health\",\"method\":\"system.health\",\"params\":{}}",
        );
        defer allocator.free(response);
        try stdout.print("{s}\n", .{response});
        return;
    }

    if (args.len > command_index and std.mem.eql(u8, args[command_index], "verify")) {
        const issues = try store.verify(allocator);
        defer freeVerificationIssues(allocator, issues);
        const default_checks = [_][]const u8{ "schema", "provenance", "temporal", "forgetting" };
        const checks: []const []const u8 = if (args.len > command_index + 1) args[command_index + 1 ..] else &default_checks;
        const response = try stringifyAlloc(allocator, .{
            .status = if (issues.len == 0) "ok" else "failed",
            .checks = checks,
            .issueCount = issues.len,
            .issues = issues,
        });
        defer allocator.free(response);
        try stdout.print("{s}\n", .{response});
        return;
    }

    if (args.len > command_index and std.mem.eql(u8, args[command_index], "jobs")) {
        if (args.len <= command_index + 1 or !std.mem.eql(u8, args[command_index + 1], "materialize")) {
            const response = try stringifyAlloc(allocator, .{
                .status = "error",
                .message = "usage: quipu [--db PATH] jobs materialize [--after SEQ] [--limit N] [--max-attempts N] [STREAM...]",
            });
            defer allocator.free(response);
            try stdout.print("{s}\n", .{response});
            return;
        }
        var parsed = parseMaterializeArgs(allocator, args[command_index + 2 ..]) catch {
            const response = try stringifyAlloc(allocator, .{
                .status = "error",
                .message = "invalid jobs materialize arguments",
            });
            defer allocator.free(response);
            try stdout.print("{s}\n", .{response});
            return;
        };
        defer parsed.deinit(allocator);

        const summaries = if (parsed.streams.items.len == 0)
            try jobs.materializeDefaultStreams(allocator, store, parsed.options)
        else
            try jobs.materializeNamedStreams(allocator, store, parsed.streams.items, parsed.options);
        defer allocator.free(summaries);

        var read_count: usize = 0;
        var created_count: usize = 0;
        var existing_count: usize = 0;
        for (summaries) |summary| {
            read_count += summary.readCount;
            created_count += summary.createdCount;
            existing_count += summary.existingCount;
        }
        const response = try stringifyAlloc(allocator, .{
            .status = "ok",
            .streamCount = summaries.len,
            .readCount = read_count,
            .createdCount = created_count,
            .existingCount = existing_count,
            .summaries = summaries,
        });
        defer allocator.free(response);
        try stdout.print("{s}\n", .{response});
        return;
    }

    if (args.len > command_index and std.mem.eql(u8, args[command_index], "rpc-stdin")) {
        var stdin_buffer: [4096]u8 = undefined;
        var stdin_file_reader: std.Io.File.Reader = .init(.stdin(), io, &stdin_buffer);
        const request = try stdin_file_reader.interface.allocRemaining(allocator, .limited(1024 * 1024));
        defer allocator.free(request);
        const response = try runtime.dispatch(allocator, request);
        defer allocator.free(response);
        try stdout.print("{s}\n", .{response});
        return;
    }

    if (args.len > command_index and std.mem.eql(u8, args[command_index], "serve-stdio")) {
        var stdin_buffer: [4096]u8 = undefined;
        var stdin_file_reader: std.Io.File.Reader = .init(.stdin(), io, &stdin_buffer);
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

    try stdout.print("quipu core scaffold\nusage: quipu [--db PATH] health | quipu [--db PATH] verify [schema|provenance|temporal|forgetting]... | quipu [--db PATH] jobs materialize [--after SEQ] [--limit N] [--max-attempts N] [STREAM...] | quipu [--db PATH] rpc-stdin | quipu [--db PATH] serve-stdio\n", .{});
}

fn parseMaterializeArgs(allocator: std.mem.Allocator, args: []const [:0]const u8) !MaterializeCliArgs {
    var parsed = MaterializeCliArgs{
        .options = .{},
        .streams = std.ArrayList([]const u8).empty,
    };
    errdefer parsed.deinit(allocator);

    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--after")) {
            index += 1;
            if (index >= args.len) return error.InvalidArgs;
            parsed.options.after_sequence = try std.fmt.parseInt(u64, args[index], 10);
        } else if (std.mem.eql(u8, arg, "--limit")) {
            index += 1;
            if (index >= args.len) return error.InvalidArgs;
            parsed.options.limit = try std.fmt.parseInt(usize, args[index], 10);
        } else if (std.mem.eql(u8, arg, "--max-attempts")) {
            index += 1;
            if (index >= args.len) return error.InvalidArgs;
            parsed.options.max_attempts = try std.fmt.parseInt(u32, args[index], 10);
        } else if (std.mem.startsWith(u8, arg, "--")) {
            return error.InvalidArgs;
        } else {
            try parsed.streams.append(allocator, arg);
        }
    }
    return parsed;
}

fn freeVerificationIssues(allocator: std.mem.Allocator, issues: []const @import("storage.zig").VerificationIssue) void {
    for (issues) |issue| {
        if (issue.qid) |qid| allocator.free(qid);
    }
    allocator.free(issues);
}

fn stringifyAlloc(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    try std.json.Stringify.value(value, .{}, &writer.writer);
    return writer.toOwnedSlice();
}
