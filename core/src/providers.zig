const std = @import("std");
const extractor = @import("extractor.zig");

pub const ProviderKind = enum {
    none,
    deterministic,
    command,
    http,
};

pub const ProviderEndpoint = struct {
    kind: ProviderKind = .none,
    name: []const u8 = "none",
    command: ?[]const u8 = null,
    url: ?[]const u8 = null,
    model: ?[]const u8 = null,
};

pub const ProviderConfig = struct {
    extractor: ProviderEndpoint = .{
        .kind = .deterministic,
        .name = "deterministic",
    },
    embeddings: ProviderEndpoint = .{
        .kind = .deterministic,
        .name = "lattice_hash_embed",
        .model = "lattice_hash_embed",
    },
    reranker: ProviderEndpoint = .{},

    pub fn validate(self: ProviderConfig) !void {
        try validateEndpoint(self.extractor);
        try validateEndpoint(self.embeddings);
        try validateEndpoint(self.reranker);
    }
};

pub const ExtractorPlugin = struct {
    context: ?*const anyopaque = null,
    vtable: *const VTable,

    pub const VTable = struct {
        name: *const fn (?*const anyopaque) []const u8,
        extract: *const fn (?*const anyopaque, []const u8) extractor.CandidateList,
    };

    pub fn name(self: ExtractorPlugin) []const u8 {
        return self.vtable.name(self.context);
    }

    pub fn extract(self: ExtractorPlugin, content: []const u8) extractor.CandidateList {
        return self.vtable.extract(self.context, content);
    }
};

pub fn deterministicExtractor() ExtractorPlugin {
    return .{ .vtable = &deterministic_extractor_vtable };
}

fn validateEndpoint(endpoint: ProviderEndpoint) !void {
    switch (endpoint.kind) {
        .none, .deterministic => {},
        .command => {
            if (endpoint.command == null or endpoint.command.?.len == 0) return error.InvalidProviderConfig;
        },
        .http => {
            if (endpoint.url == null or endpoint.url.?.len == 0) return error.InvalidProviderConfig;
        },
    }
}

fn deterministicName(_: ?*const anyopaque) []const u8 {
    return "deterministic";
}

fn deterministicExtract(_: ?*const anyopaque, content: []const u8) extractor.CandidateList {
    return extractor.DeterministicExtractor.extract(content);
}

const deterministic_extractor_vtable = ExtractorPlugin.VTable{
    .name = deterministicName,
    .extract = deterministicExtract,
};

test "deterministic extractor plugin delegates to fixture extractor" {
    const plugin = deterministicExtractor();
    try std.testing.expectEqualStrings("deterministic", plugin.name());
    const candidates = plugin.extract("This repo uses pnpm. Run just test before committing.");
    try std.testing.expectEqual(@as(usize, 2), candidates.len);
}

test "provider config validates command and http endpoints" {
    const config = ProviderConfig{};
    try config.validate();
    try std.testing.expectError(error.InvalidProviderConfig, validateEndpoint(.{ .kind = .command, .name = "bad" }));
    try std.testing.expectError(error.InvalidProviderConfig, validateEndpoint(.{ .kind = .http, .name = "bad" }));
    try validateEndpoint(.{ .kind = .command, .name = "cmd", .command = "quipu-extract" });
    try validateEndpoint(.{ .kind = .http, .name = "http", .url = "http://127.0.0.1:9999" });
}
