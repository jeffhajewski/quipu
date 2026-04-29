const std = @import("std");
const build_options = @import("build_options");
const in_memory_storage = @import("in_memory_storage.zig");
const jobs = @import("jobs.zig");
const lattice_storage = if (build_options.enable_lattice) @import("lattice_storage.zig") else struct {};
const protocol = @import("protocol.zig");
const runtime_mod = @import("runtime.zig");
const schema = @import("schema.zig");
const storage = @import("storage.zig");

const LatticeOptions = if (build_options.enable_lattice) lattice_storage.Options else struct {};
const LatticeEmbeddingProviderKind = if (build_options.enable_lattice) lattice_storage.EmbeddingProviderKind else enum {
    hash,
    openai_compatible,
};
const default_openrouter_lattice_dimensions: u16 = 768;

const RuntimeConfig = struct {
    command_index: usize = 1,
    db_path: ?[]const u8 = null,
    page_size: ?u32 = null,
    vector_dimensions: ?u16 = null,
    embedding_provider: ?[]const u8 = null,
    embedding_url: ?[]const u8 = null,
    embedding_model: ?[]const u8 = null,
};

const MaterializeCliArgs = struct {
    options: jobs.MaterializeOptions,
    streams: std.ArrayList([]const u8),

    fn deinit(self: *MaterializeCliArgs, allocator: std.mem.Allocator) void {
        self.streams.deinit(allocator);
    }
};

const FailCliArgs = struct {
    qid: []const u8,
    error_json: []const u8 = "{}",
};

const ScopeCliArgs = struct {
    tenant_id: ?[]const u8 = null,
    user_id: ?[]const u8 = null,
    agent_id: ?[]const u8 = null,
    project_id: ?[]const u8 = null,

    fn json(self: ScopeCliArgs) ScopeJson {
        return .{
            .tenantId = self.tenant_id,
            .userId = self.user_id,
            .agentId = self.agent_id,
            .projectId = self.project_id,
        };
    }
};

const ScopeJson = struct {
    tenantId: ?[]const u8 = null,
    userId: ?[]const u8 = null,
    agentId: ?[]const u8 = null,
    projectId: ?[]const u8 = null,
};

const RememberCliArgs = struct {
    text: ?[]const u8 = null,
    role: []const u8 = "user",
    created_at: ?[]const u8 = null,
    session_id: ?[]const u8 = null,
    privacy_class: []const u8 = "normal",
    extract: bool = true,
    scope: ScopeCliArgs = .{},
};

const RetrieveCliArgs = struct {
    query: ?[]const u8 = null,
    mode: ?[]const u8 = null,
    budget_tokens: i64 = 1200,
    include_debug: bool = false,
    include_evidence: bool = true,
    needs: std.ArrayList([]const u8),
    scope: ScopeCliArgs = .{},

    fn deinit(self: *RetrieveCliArgs, allocator: std.mem.Allocator) void {
        self.needs.deinit(allocator);
    }
};

const InspectCliArgs = struct {
    qid: ?[]const u8 = null,
};

const ForgetCliArgs = struct {
    mode: []const u8 = "hard_delete",
    reason: []const u8 = "cli_request",
    dry_run: bool = true,
    query: ?[]const u8 = null,
    qids: std.ArrayList([]const u8),
    scope: ScopeCliArgs = .{},

    fn deinit(self: *ForgetCliArgs, allocator: std.mem.Allocator) void {
        self.qids.deinit(allocator);
    }
};

const FeedbackCliArgs = struct {
    retrieval_id: ?[]const u8 = null,
    rating: ?[]const u8 = null,
};

const ConsolidateCliArgs = struct {
    block_key: []const u8 = "project_summary",
    limit: i64 = 50,
    scope: ScopeCliArgs = .{},
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var config = parseRuntimeConfig(args);

    if (config.db_path == null and build_options.enable_lattice) {
        config.db_path = init.environ_map.get("QUIPU_DB_PATH");
        if (config.db_path == null and commandUsesDefaultDb(args, config.command_index)) {
            config.db_path = try defaultDbPath(init.arena.allocator(), init.environ_map.get("HOME"));
        }
    }

    if (config.db_path) |path| {
        try ensureParentDir(init.io, path);
    }

    if (build_options.enable_lattice and config.db_path != null) {
        const lattice_options = try latticeOptionsFromConfig(init.io, init.environ_map, config);
        var adapter_state = try lattice_storage.LatticeAdapter.open(allocator, config.db_path.?, lattice_options);
        defer adapter_state.deinit();
        try schema.ensure(allocator, adapter_state.adapter());
        var health = protocol.Health.default();
        health.db_path = config.db_path;
        health.lattice_version = lattice_storage.LatticeAdapter.latticeVersion();
        var runtime = runtime_mod.Runtime.initWithNextId(adapter_state.adapter(), health, adapter_state.nextRuntimeId());
        defer runtime.deinit();
        try runCommand(init.io, allocator, args, config.command_index, &runtime, adapter_state.adapter());
        return;
    }

    var adapter_state = in_memory_storage.InMemoryAdapter.init(allocator);
    defer adapter_state.deinit();
    var runtime = runtime_mod.Runtime.init(adapter_state.adapter(), protocol.Health.default());
    defer runtime.deinit();
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
        if (std.mem.eql(u8, arg, "--vector-dimensions")) {
            if (config.command_index + 1 < args.len) {
                config.vector_dimensions = std.fmt.parseInt(u16, args[config.command_index + 1], 10) catch null;
                config.command_index += 2;
                continue;
            }
            config.command_index += 1;
            break;
        }
        if (std.mem.eql(u8, arg, "--page-size")) {
            if (config.command_index + 1 < args.len) {
                config.page_size = std.fmt.parseInt(u32, args[config.command_index + 1], 10) catch null;
                config.command_index += 2;
                continue;
            }
            config.command_index += 1;
            break;
        }
        if (std.mem.eql(u8, arg, "--embedding-provider")) {
            if (config.command_index + 1 < args.len) {
                config.embedding_provider = args[config.command_index + 1];
                config.command_index += 2;
                continue;
            }
            config.command_index += 1;
            break;
        }
        if (std.mem.eql(u8, arg, "--embedding-url")) {
            if (config.command_index + 1 < args.len) {
                config.embedding_url = args[config.command_index + 1];
                config.command_index += 2;
                continue;
            }
            config.command_index += 1;
            break;
        }
        if (std.mem.eql(u8, arg, "--embedding-model")) {
            if (config.command_index + 1 < args.len) {
                config.embedding_model = args[config.command_index + 1];
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

fn latticeOptionsFromConfig(io: std.Io, environ_map: *std.process.Environ.Map, config: RuntimeConfig) !LatticeOptions {
    if (comptime !build_options.enable_lattice) {
        return .{};
    }
    const provider_name = config.embedding_provider orelse environ_map.get("QUIPU_EMBEDDING_PROVIDER") orelse "hash";
    const provider = try parseEmbeddingProvider(provider_name);
    const vector_dimensions = config.vector_dimensions orelse
        envU16(environ_map, "QUIPU_VECTOR_DIMENSIONS") orelse
        envU16(environ_map, "OPENROUTER_EMBEDDING_DIMENSIONS") orelse
        if (provider == .openai_compatible and isProviderName(provider_name, "openrouter")) default_openrouter_lattice_dimensions else @as(u16, 128);
    const requested_page_size = config.page_size orelse
        envU32(environ_map, "QUIPU_LATTICE_PAGE_SIZE") orelse
        @as(u32, 4096);
    const page_size = normalizePageSize(@max(requested_page_size, pageSizeForVectorDimensions(vector_dimensions)));
    const embedding_model = config.embedding_model orelse
        environ_map.get("QUIPU_EMBEDDING_MODEL") orelse
        environ_map.get("OPENROUTER_EMBEDDING_MODEL") orelse
        if (provider == .openai_compatible and isProviderName(provider_name, "openrouter"))
            "openai/text-embedding-3-small"
        else
            "lattice_hash_embed";
    const embedding_url = config.embedding_url orelse
        environ_map.get("QUIPU_EMBEDDING_URL") orelse
        environ_map.get("OPENROUTER_EMBEDDING_URL") orelse
        "https://openrouter.ai/api/v1/embeddings";
    const embedding_api_key = environ_map.get("QUIPU_EMBEDDING_API_KEY") orelse environ_map.get("OPENROUTER_API_KEY");
    if (provider == .openai_compatible and isProviderName(provider_name, "openrouter") and embedding_api_key == null) {
        return error.MissingOpenRouterApiKey;
    }
    return .{
        .io = io,
        .page_size = page_size,
        .vector_dimensions = vector_dimensions,
        .embedding_provider = provider,
        .embedding_url = embedding_url,
        .embedding_model = embedding_model,
        .embedding_api_key = embedding_api_key,
        .embedding_request_dimensions = provider == .openai_compatible and
            (isProviderName(provider_name, "openrouter") or isProviderName(provider_name, "openai")),
    };
}

fn parseEmbeddingProvider(provider: []const u8) !LatticeEmbeddingProviderKind {
    if (isProviderName(provider, "hash") or isProviderName(provider, "lattice_hash_embed")) return .hash;
    if (isProviderName(provider, "openrouter") or
        isProviderName(provider, "openai") or
        isProviderName(provider, "openai-compatible") or
        isProviderName(provider, "http"))
    {
        return .openai_compatible;
    }
    return error.InvalidEmbeddingProvider;
}

fn isProviderName(actual: []const u8, expected: []const u8) bool {
    return std.ascii.eqlIgnoreCase(actual, expected);
}

fn envU16(environ_map: *std.process.Environ.Map, key: []const u8) ?u16 {
    const value = environ_map.get(key) orelse return null;
    return std.fmt.parseInt(u16, value, 10) catch null;
}

fn envU32(environ_map: *std.process.Environ.Map, key: []const u8) ?u32 {
    const value = environ_map.get(key) orelse return null;
    return std.fmt.parseInt(u32, value, 10) catch null;
}

fn pageSizeForVectorDimensions(dimensions: u16) u32 {
    const vector_bytes = @as(u32, dimensions) * @sizeOf(f32);
    return normalizePageSize(vector_bytes + 1024);
}

fn normalizePageSize(minimum: u32) u32 {
    var page_size: u32 = 4096;
    while (page_size < minimum) {
        page_size *= 2;
    }
    return page_size;
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

    if (args.len > command_index and std.mem.eql(u8, args[command_index], "init")) {
        try schema.ensure(allocator, store);
        const response = try stringifyAlloc(allocator, .{
            .status = "ok",
            .dbPath = runtime.health.db_path,
            .schemaVersion = schema.current_version,
        });
        defer allocator.free(response);
        try stdout.print("{s}\n", .{response});
        return;
    }

    if (args.len > command_index and std.mem.eql(u8, args[command_index], "health")) {
        const response = try runtime.dispatch(
            allocator,
            "{\"jsonrpc\":\"2.0\",\"id\":\"cli_health\",\"method\":\"system.health\",\"params\":{}}",
        );
        defer allocator.free(response);
        try stdout.print("{s}\n", .{response});
        return;
    }

    if (args.len > command_index and std.mem.eql(u8, args[command_index], "status")) {
        const response = try runtime.dispatch(
            allocator,
            "{\"jsonrpc\":\"2.0\",\"id\":\"cli_status\",\"method\":\"system.health\",\"params\":{}}",
        );
        defer allocator.free(response);
        try stdout.print("{s}\n", .{response});
        return;
    }

    if (args.len > command_index and std.mem.eql(u8, args[command_index], "verify")) {
        const schema_issues = try schema.verify(allocator, store);
        defer freeVerificationIssues(allocator, schema_issues);
        const storage_issues = try store.verify(allocator);
        defer freeVerificationIssues(allocator, storage_issues);
        const issues = try mergeVerificationIssues(allocator, schema_issues, storage_issues);
        defer allocator.free(issues);
        const default_checks = [_][]const u8{ "schema", "provenance", "temporal", "forgetting", "streams" };
        var checks: []const []const u8 = &default_checks;
        if (args.len > command_index + 1) {
            const requested = args[command_index + 1 ..];
            checks = if (requested.len == 1 and std.mem.eql(u8, requested[0], "all")) &default_checks else requested;
        }
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
        if (args.len <= command_index + 1) {
            const response = try stringifyAlloc(allocator, .{
                .status = "error",
                .message = "usage: quipu [--db PATH] jobs materialize|lease|complete|fail ...",
            });
            defer allocator.free(response);
            try stdout.print("{s}\n", .{response});
            return;
        }
        if (std.mem.eql(u8, args[command_index + 1], "lease")) {
            const parsed = parseLeaseArgs(args[command_index + 2 ..]) catch {
                return printCliError(stdout, allocator, "invalid jobs lease arguments");
            };
            const leases = try jobs.leasePendingJobs(allocator, store, parsed);
            defer jobs.freeLeaseResults(allocator, leases);
            const response = try stringifyAlloc(allocator, .{
                .status = "ok",
                .leasedCount = leases.len,
                .leases = leases,
            });
            defer allocator.free(response);
            try stdout.print("{s}\n", .{response});
            return;
        }
        if (std.mem.eql(u8, args[command_index + 1], "complete")) {
            const qid = parseJobQid(args[command_index + 2 ..]) catch {
                return printCliError(stdout, allocator, "invalid jobs complete arguments");
            };
            try jobs.completeJob(allocator, store, qid, 0);
            const response = try stringifyAlloc(allocator, .{ .status = "ok", .jobQid = qid });
            defer allocator.free(response);
            try stdout.print("{s}\n", .{response});
            return;
        }
        if (std.mem.eql(u8, args[command_index + 1], "fail")) {
            const parsed = parseFailArgs(args[command_index + 2 ..]) catch {
                return printCliError(stdout, allocator, "invalid jobs fail arguments");
            };
            const status = try jobs.failJob(allocator, store, parsed.qid, parsed.error_json, 0);
            const response = try stringifyAlloc(allocator, .{ .status = status, .jobQid = parsed.qid });
            defer allocator.free(response);
            try stdout.print("{s}\n", .{response});
            return;
        }
        if (!std.mem.eql(u8, args[command_index + 1], "materialize")) {
            return printCliError(stdout, allocator, "unsupported jobs subcommand");
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

    if (args.len > command_index and std.mem.eql(u8, args[command_index], "remember")) {
        const request = buildRememberRequest(allocator, args[command_index + 1 ..]) catch {
            return printCliError(stdout, allocator, "invalid remember arguments");
        };
        defer allocator.free(request);
        try dispatchAndPrint(stdout, allocator, runtime, request);
        return;
    }

    if (args.len > command_index and std.mem.eql(u8, args[command_index], "retrieve")) {
        const request = buildRetrieveRequest(allocator, args[command_index + 1 ..]) catch {
            return printCliError(stdout, allocator, "invalid retrieve arguments");
        };
        defer allocator.free(request);
        try dispatchAndPrint(stdout, allocator, runtime, request);
        return;
    }

    if (args.len > command_index and std.mem.eql(u8, args[command_index], "inspect")) {
        const request = buildInspectRequest(allocator, args[command_index + 1 ..]) catch {
            return printCliError(stdout, allocator, "invalid inspect arguments");
        };
        defer allocator.free(request);
        try dispatchAndPrint(stdout, allocator, runtime, request);
        return;
    }

    if (args.len > command_index and std.mem.eql(u8, args[command_index], "forget")) {
        const request = buildForgetRequest(allocator, args[command_index + 1 ..]) catch {
            return printCliError(stdout, allocator, "invalid forget arguments");
        };
        defer allocator.free(request);
        try dispatchAndPrint(stdout, allocator, runtime, request);
        return;
    }

    if (args.len > command_index and std.mem.eql(u8, args[command_index], "feedback")) {
        const request = buildFeedbackRequest(allocator, args[command_index + 1 ..]) catch {
            return printCliError(stdout, allocator, "invalid feedback arguments");
        };
        defer allocator.free(request);
        try dispatchAndPrint(stdout, allocator, runtime, request);
        return;
    }

    if (args.len > command_index and std.mem.eql(u8, args[command_index], "consolidate")) {
        const request = buildConsolidateRequest(allocator, args[command_index + 1 ..]) catch {
            return printCliError(stdout, allocator, "invalid consolidate arguments");
        };
        defer allocator.free(request);
        try dispatchAndPrint(stdout, allocator, runtime, request);
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

    if (args.len > command_index and (std.mem.eql(u8, args[command_index], "serve-stdio") or std.mem.eql(u8, args[command_index], "serve"))) {
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

    try stdout.print("quipu core scaffold\nusage: quipu [--db PATH] [--vector-dimensions N] [--page-size BYTES] [--embedding-provider hash|openrouter] [--embedding-url URL] [--embedding-model MODEL] init | status | health | remember --text TEXT [--project ID] | retrieve --query TEXT [--mode fts|vector|hybrid|graph] [--need NEED] | inspect ID | forget --id ID|--query TEXT [--yes] | feedback --retrieval ID --rating RATING | consolidate [--project ID] | verify [all|schema|provenance|temporal|forgetting|streams]... | jobs materialize|lease|complete|fail ... | rpc-stdin | serve\n", .{});
}

fn commandUsesDefaultDb(args: []const [:0]const u8, command_index: usize) bool {
    if (args.len <= command_index) return false;
    const command = args[command_index];
    return std.mem.eql(u8, command, "init") or
        std.mem.eql(u8, command, "serve") or
        std.mem.eql(u8, command, "status") or
        std.mem.eql(u8, command, "remember") or
        std.mem.eql(u8, command, "retrieve") or
        std.mem.eql(u8, command, "inspect") or
        std.mem.eql(u8, command, "forget") or
        std.mem.eql(u8, command, "feedback") or
        std.mem.eql(u8, command, "consolidate") or
        std.mem.eql(u8, command, "verify") or
        std.mem.eql(u8, command, "jobs");
}

fn defaultDbPath(allocator: std.mem.Allocator, home: ?[]const u8) !?[]const u8 {
    const root = home orelse return null;
    const path = try std.fmt.allocPrint(allocator, "{s}/.quipu/default/quipu.lattice", .{root});
    return @as(?[]const u8, path);
}

fn ensureParentDir(io: std.Io, path: []const u8) !void {
    const parent = std.fs.path.dirname(path) orelse return;
    if (std.fs.path.isAbsolute(parent)) {
        var existing = std.Io.Dir.openDirAbsolute(io, parent, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                if (std.mem.eql(u8, parent, std.fs.path.sep_str)) return;
                var root = try std.Io.Dir.openDirAbsolute(io, std.fs.path.sep_str, .{});
                defer root.close(io);
                const relative = std.mem.trimStart(u8, parent, std.fs.path.sep_str);
                try root.createDirPath(io, relative);
                return;
            },
            else => return err,
        };
        existing.close(io);
        return;
    }
    try std.Io.Dir.cwd().createDirPath(io, parent);
}

fn dispatchAndPrint(stdout: *std.Io.Writer, allocator: std.mem.Allocator, runtime: *runtime_mod.Runtime, request: []const u8) !void {
    const response = try runtime.dispatch(allocator, request);
    defer allocator.free(response);
    try stdout.print("{s}\n", .{response});
}

fn printCliError(stdout: *std.Io.Writer, allocator: std.mem.Allocator, message: []const u8) !void {
    const response = try stringifyAlloc(allocator, .{
        .status = "error",
        .message = message,
    });
    defer allocator.free(response);
    try stdout.print("{s}\n", .{response});
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

fn parseLeaseArgs(args: []const [:0]const u8) !jobs.LeaseOptions {
    var parsed = jobs.LeaseOptions{
        .worker_kind = "",
        .owner = "cli",
    };
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--worker")) {
            parsed.worker_kind = try nextArg(args, &index);
        } else if (std.mem.eql(u8, arg, "--owner")) {
            parsed.owner = try nextArg(args, &index);
        } else if (std.mem.eql(u8, arg, "--limit")) {
            parsed.limit = try std.fmt.parseInt(usize, try nextArg(args, &index), 10);
        } else if (std.mem.eql(u8, arg, "--ttl-ms")) {
            parsed.ttl_ms = try std.fmt.parseInt(i64, try nextArg(args, &index), 10);
        } else {
            return error.InvalidArgs;
        }
    }
    if (parsed.worker_kind.len == 0) return error.InvalidArgs;
    return parsed;
}

fn parseJobQid(args: []const [:0]const u8) ![]const u8 {
    if (args.len == 1 and !std.mem.startsWith(u8, args[0], "--")) return args[0];
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        if (std.mem.eql(u8, args[index], "--id")) return try nextArg(args, &index);
    }
    return error.InvalidArgs;
}

fn parseFailArgs(args: []const [:0]const u8) !FailCliArgs {
    var qid: ?[]const u8 = null;
    var error_json: []const u8 = "{}";
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--id")) {
            qid = try nextArg(args, &index);
        } else if (std.mem.eql(u8, arg, "--error")) {
            error_json = try nextArg(args, &index);
        } else if (qid == null and !std.mem.startsWith(u8, arg, "--")) {
            qid = arg;
        } else {
            return error.InvalidArgs;
        }
    }
    return .{ .qid = qid orelse return error.InvalidArgs, .error_json = error_json };
}

fn buildRememberRequest(allocator: std.mem.Allocator, args: []const [:0]const u8) ![]u8 {
    const parsed = try parseRememberArgs(args);
    const text = parsed.text orelse return error.InvalidArgs;
    const message = .{
        .role = parsed.role,
        .content = text,
        .createdAt = parsed.created_at,
    };
    const messages = [_]@TypeOf(message){message};
    return stringifyAlloc(allocator, .{
        .jsonrpc = "2.0",
        .id = "cli_remember",
        .method = "memory.remember",
        .params = .{
            .sessionId = parsed.session_id,
            .scope = parsed.scope.json(),
            .messages = &messages,
            .extract = parsed.extract,
            .privacyClass = parsed.privacy_class,
        },
    });
}

fn buildRetrieveRequest(allocator: std.mem.Allocator, args: []const [:0]const u8) ![]u8 {
    var parsed = try parseRetrieveArgs(allocator, args);
    defer parsed.deinit(allocator);
    const query = parsed.query orelse return error.InvalidArgs;
    return stringifyAlloc(allocator, .{
        .jsonrpc = "2.0",
        .id = "cli_retrieve",
        .method = "memory.retrieve",
            .params = .{
                .query = query,
                .mode = parsed.mode,
                .scope = parsed.scope.json(),
                .budgetTokens = parsed.budget_tokens,
                .needs = parsed.needs.items,
                .options = .{
                .includeEvidence = parsed.include_evidence,
                .includeDebug = parsed.include_debug,
                .logTrace = parsed.include_debug,
            },
        },
    });
}

fn buildInspectRequest(allocator: std.mem.Allocator, args: []const [:0]const u8) ![]u8 {
    const parsed = try parseInspectArgs(args);
    const qid = parsed.qid orelse return error.InvalidArgs;
    return stringifyAlloc(allocator, .{
        .jsonrpc = "2.0",
        .id = "cli_inspect",
        .method = "memory.inspect",
        .params = .{
            .qid = qid,
            .includeProvenance = true,
            .includeDependents = true,
            .includeRaw = true,
        },
    });
}

fn buildForgetRequest(allocator: std.mem.Allocator, args: []const [:0]const u8) ![]u8 {
    var parsed = try parseForgetArgs(allocator, args);
    defer parsed.deinit(allocator);
    if (parsed.qids.items.len == 0 and parsed.query == null) return error.InvalidArgs;
    return stringifyAlloc(allocator, .{
        .jsonrpc = "2.0",
        .id = "cli_forget",
        .method = "memory.forget",
        .params = .{
            .mode = parsed.mode,
            .selector = .{
                .qids = parsed.qids.items,
                .query = parsed.query,
                .scope = parsed.scope.json(),
            },
            .propagate = true,
            .dryRun = parsed.dry_run,
            .reason = parsed.reason,
        },
    });
}

fn buildFeedbackRequest(allocator: std.mem.Allocator, args: []const [:0]const u8) ![]u8 {
    const parsed = try parseFeedbackArgs(args);
    const retrieval_id = parsed.retrieval_id orelse return error.InvalidArgs;
    const rating = parsed.rating orelse return error.InvalidArgs;
    return stringifyAlloc(allocator, .{
        .jsonrpc = "2.0",
        .id = "cli_feedback",
        .method = "memory.feedback",
        .params = .{
            .retrievalId = retrieval_id,
            .rating = rating,
        },
    });
}

fn buildConsolidateRequest(allocator: std.mem.Allocator, args: []const [:0]const u8) ![]u8 {
    const parsed = try parseConsolidateArgs(args);
    return stringifyAlloc(allocator, .{
        .jsonrpc = "2.0",
        .id = "cli_consolidate",
        .method = "memory.core.consolidate",
        .params = .{
            .blockKey = parsed.block_key,
            .scope = parsed.scope.json(),
            .limit = parsed.limit,
        },
    });
}

fn parseRememberArgs(args: []const [:0]const u8) !RememberCliArgs {
    var parsed = RememberCliArgs{};
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--text")) {
            parsed.text = try nextArg(args, &index);
        } else if (std.mem.eql(u8, arg, "--role")) {
            parsed.role = try nextArg(args, &index);
        } else if (std.mem.eql(u8, arg, "--created-at")) {
            parsed.created_at = try nextArg(args, &index);
        } else if (std.mem.eql(u8, arg, "--session")) {
            parsed.session_id = try nextArg(args, &index);
        } else if (std.mem.eql(u8, arg, "--privacy")) {
            parsed.privacy_class = try nextArg(args, &index);
        } else if (std.mem.eql(u8, arg, "--extract")) {
            parsed.extract = try parseBool(try nextArg(args, &index));
        } else if (std.mem.eql(u8, arg, "--no-extract")) {
            parsed.extract = false;
        } else if (try parseScopeArg(arg, args, &index, &parsed.scope)) {
            continue;
        } else {
            return error.InvalidArgs;
        }
    }
    return parsed;
}

fn parseRetrieveArgs(allocator: std.mem.Allocator, args: []const [:0]const u8) !RetrieveCliArgs {
    var parsed = RetrieveCliArgs{ .needs = std.ArrayList([]const u8).empty };
    errdefer parsed.deinit(allocator);
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--query")) {
            parsed.query = try nextArg(args, &index);
        } else if (std.mem.eql(u8, arg, "--mode")) {
            parsed.mode = try nextArg(args, &index);
        } else if (std.mem.eql(u8, arg, "--budget-tokens")) {
            parsed.budget_tokens = try std.fmt.parseInt(i64, try nextArg(args, &index), 10);
        } else if (std.mem.eql(u8, arg, "--need")) {
            try parsed.needs.append(allocator, try nextArg(args, &index));
        } else if (std.mem.eql(u8, arg, "--debug")) {
            parsed.include_debug = true;
        } else if (std.mem.eql(u8, arg, "--no-evidence")) {
            parsed.include_evidence = false;
        } else if (try parseScopeArg(arg, args, &index, &parsed.scope)) {
            continue;
        } else {
            return error.InvalidArgs;
        }
    }
    return parsed;
}

fn parseInspectArgs(args: []const [:0]const u8) !InspectCliArgs {
    var parsed = InspectCliArgs{};
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--id")) {
            parsed.qid = try nextArg(args, &index);
        } else if (parsed.qid == null and !std.mem.startsWith(u8, arg, "--")) {
            parsed.qid = arg;
        } else {
            return error.InvalidArgs;
        }
    }
    return parsed;
}

fn parseForgetArgs(allocator: std.mem.Allocator, args: []const [:0]const u8) !ForgetCliArgs {
    var parsed = ForgetCliArgs{ .qids = std.ArrayList([]const u8).empty };
    errdefer parsed.deinit(allocator);
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--id")) {
            try parsed.qids.append(allocator, try nextArg(args, &index));
        } else if (std.mem.eql(u8, arg, "--query")) {
            parsed.query = try nextArg(args, &index);
        } else if (std.mem.eql(u8, arg, "--mode")) {
            parsed.mode = try nextArg(args, &index);
        } else if (std.mem.eql(u8, arg, "--reason")) {
            parsed.reason = try nextArg(args, &index);
        } else if (std.mem.eql(u8, arg, "--dry-run")) {
            parsed.dry_run = true;
        } else if (std.mem.eql(u8, arg, "--yes")) {
            parsed.dry_run = false;
        } else if (try parseScopeArg(arg, args, &index, &parsed.scope)) {
            continue;
        } else {
            return error.InvalidArgs;
        }
    }
    return parsed;
}

fn parseFeedbackArgs(args: []const [:0]const u8) !FeedbackCliArgs {
    var parsed = FeedbackCliArgs{};
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--retrieval")) {
            parsed.retrieval_id = try nextArg(args, &index);
        } else if (std.mem.eql(u8, arg, "--rating")) {
            parsed.rating = try nextArg(args, &index);
        } else {
            return error.InvalidArgs;
        }
    }
    return parsed;
}

fn parseConsolidateArgs(args: []const [:0]const u8) !ConsolidateCliArgs {
    var parsed = ConsolidateCliArgs{};
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--block-key")) {
            parsed.block_key = try nextArg(args, &index);
        } else if (std.mem.eql(u8, arg, "--limit")) {
            parsed.limit = try std.fmt.parseInt(i64, try nextArg(args, &index), 10);
        } else if (try parseScopeArg(arg, args, &index, &parsed.scope)) {
            continue;
        } else {
            return error.InvalidArgs;
        }
    }
    return parsed;
}

fn parseScopeArg(arg: []const u8, args: []const [:0]const u8, index: *usize, scope: *ScopeCliArgs) !bool {
    if (std.mem.eql(u8, arg, "--tenant")) {
        scope.tenant_id = try nextArg(args, index);
        return true;
    }
    if (std.mem.eql(u8, arg, "--user")) {
        scope.user_id = try nextArg(args, index);
        return true;
    }
    if (std.mem.eql(u8, arg, "--agent")) {
        scope.agent_id = try nextArg(args, index);
        return true;
    }
    if (std.mem.eql(u8, arg, "--project")) {
        scope.project_id = try nextArg(args, index);
        return true;
    }
    return false;
}

fn nextArg(args: []const [:0]const u8, index: *usize) ![]const u8 {
    index.* += 1;
    if (index.* >= args.len) return error.InvalidArgs;
    return args[index.*];
}

fn parseBool(value: []const u8) !bool {
    if (std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "1") or std.mem.eql(u8, value, "yes")) return true;
    if (std.mem.eql(u8, value, "false") or std.mem.eql(u8, value, "0") or std.mem.eql(u8, value, "no")) return false;
    return error.InvalidArgs;
}

fn freeVerificationIssues(allocator: std.mem.Allocator, issues: []const @import("storage.zig").VerificationIssue) void {
    for (issues) |issue| {
        if (issue.qid) |qid| allocator.free(qid);
    }
    allocator.free(issues);
}

fn mergeVerificationIssues(
    allocator: std.mem.Allocator,
    schema_issues: []const storage.VerificationIssue,
    storage_issues: []const storage.VerificationIssue,
) ![]storage.VerificationIssue {
    const merged = try allocator.alloc(storage.VerificationIssue, schema_issues.len + storage_issues.len);
    @memcpy(merged[0..schema_issues.len], schema_issues);
    @memcpy(merged[schema_issues.len..], storage_issues);
    return merged;
}

fn stringifyAlloc(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    try std.json.Stringify.value(value, .{}, &writer.writer);
    return writer.toOwnedSlice();
}
