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
    api_key: ?[]const u8 = null,
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
    answerer: ProviderEndpoint = .{},
    entity_resolver: ProviderEndpoint = .{},

    pub fn validate(self: ProviderConfig) !void {
        try validateEndpoint(self.extractor);
        try validateEndpoint(self.embeddings);
        try validateEndpoint(self.reranker);
        try validateEndpoint(self.answerer);
        try validateEndpoint(self.entity_resolver);
    }
};

pub const ResolvedEntity = struct {
    name: []const u8,
    entity_type: []const u8,
    aliases: []const []const u8 = &.{},
};

pub const EntityList = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(ResolvedEntity) = .empty,

    pub fn append(
        self: *EntityList,
        name: []const u8,
        entity_type: []const u8,
        aliases: []const []const u8,
    ) !void {
        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        const owned_type = try self.allocator.dupe(u8, entity_type);
        errdefer self.allocator.free(owned_type);
        const owned_aliases = try self.allocator.alloc([]const u8, aliases.len);
        errdefer self.allocator.free(owned_aliases);
        var written: usize = 0;
        errdefer {
            for (owned_aliases[0..written]) |alias| self.allocator.free(alias);
        }
        for (aliases, 0..) |alias, index| {
            owned_aliases[index] = try self.allocator.dupe(u8, alias);
            written += 1;
        }
        try self.items.append(self.allocator, .{
            .name = owned_name,
            .entity_type = owned_type,
            .aliases = owned_aliases,
        });
    }

    pub fn deinit(self: *EntityList) void {
        for (self.items.items) |entity| {
            self.allocator.free(entity.name);
            self.allocator.free(entity.entity_type);
            for (entity.aliases) |alias| self.allocator.free(alias);
            self.allocator.free(entity.aliases);
        }
        self.items.deinit(self.allocator);
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

pub fn generateAnswer(
    allocator: std.mem.Allocator,
    io: ?std.Io,
    endpoint: ProviderEndpoint,
    question: []const u8,
    context_prompt: []const u8,
) ![]u8 {
    switch (endpoint.kind) {
        .none => return error.ProviderUnavailable,
        .deterministic => return deterministicAnswer(allocator, context_prompt),
        .http => return chatCompletion(allocator, io orelse return error.ProviderUnavailable, endpoint, answerSystemPrompt, question, context_prompt),
        .command => return error.UnsupportedProviderKind,
    }
}

pub fn resolveEntities(
    allocator: std.mem.Allocator,
    io: ?std.Io,
    endpoint: ProviderEndpoint,
    text: []const u8,
) !EntityList {
    switch (endpoint.kind) {
        .none => return EntityList{ .allocator = allocator },
        .deterministic => return deterministicEntities(allocator, text),
        .http => {
            const response = try chatCompletion(allocator, io orelse return error.ProviderUnavailable, endpoint, entitySystemPrompt, text, "");
            defer allocator.free(response);
            return parseEntityResponse(allocator, response);
        },
        .command => return error.UnsupportedProviderKind,
    }
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

const answerSystemPrompt =
    \\You answer memory benchmark questions using only the supplied memory context.
    \\Return a concise answer. If the context does not contain the answer, return exactly: I don't know.
;

const entitySystemPrompt =
    \\Extract canonical entities from the user text for a memory graph.
    \\Return only JSON shaped as {"entities":[{"name":"...","type":"person|organization|place|project|artifact|event|other","aliases":["..."]}]}.
    \\Use stable canonical names and include aliases only when explicitly present.
;

fn chatCompletion(
    allocator: std.mem.Allocator,
    io: std.Io,
    endpoint: ProviderEndpoint,
    system_prompt: []const u8,
    user_text: []const u8,
    context_prompt: []const u8,
) ![]u8 {
    const url = endpoint.url orelse return error.InvalidProviderConfig;
    const model = endpoint.model orelse return error.InvalidProviderConfig;
    const user_content = if (context_prompt.len == 0)
        try allocator.dupe(u8, user_text)
    else
        try std.fmt.allocPrint(allocator, "Question:\n{s}\n\nMemory context:\n{s}", .{ user_text, context_prompt });
    defer allocator.free(user_content);

    const request_body = try stringifyAlloc(allocator, .{
        .model = model,
        .messages = &[_]struct {
            role: []const u8,
            content: []const u8,
        }{
            .{ .role = "system", .content = system_prompt },
            .{ .role = "user", .content = user_content },
        },
        .temperature = 0,
    });
    defer allocator.free(request_body);

    const authorization = if (endpoint.api_key) |api_key|
        try std.fmt.allocPrint(allocator, "Bearer {s}", .{api_key})
    else
        null;
    defer if (authorization) |value| allocator.free(value);

    var client = std.http.Client{ .allocator = allocator, .io = io };
    defer client.deinit();
    var response_body: std.Io.Writer.Allocating = .init(allocator);
    defer response_body.deinit();
    const result = try client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = request_body,
        .response_writer = &response_body.writer,
        .headers = .{
            .authorization = if (authorization) |value| .{ .override = value } else .omit,
            .content_type = .{ .override = "application/json" },
            .user_agent = .{ .override = "quipu/0.1.0" },
        },
    });
    if (result.status.class() != .success) return error.ProviderRequestFailed;
    const response = try response_body.toOwnedSlice();
    defer allocator.free(response);
    return parseChatContent(allocator, response);
}

fn parseChatContent(allocator: std.mem.Allocator, response_json: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response_json, .{});
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |object| object,
        else => return error.InvalidProviderResponse,
    };
    const choices = switch (root.get("choices") orelse return error.InvalidProviderResponse) {
        .array => |array| array,
        else => return error.InvalidProviderResponse,
    };
    if (choices.items.len == 0) return error.InvalidProviderResponse;
    const first = switch (choices.items[0]) {
        .object => |object| object,
        else => return error.InvalidProviderResponse,
    };
    const message = switch (first.get("message") orelse return error.InvalidProviderResponse) {
        .object => |object| object,
        else => return error.InvalidProviderResponse,
    };
    const content = switch (message.get("content") orelse return error.InvalidProviderResponse) {
        .string => |string| string,
        else => return error.InvalidProviderResponse,
    };
    return allocator.dupe(u8, std.mem.trim(u8, content, " \t\r\n"));
}

fn deterministicAnswer(allocator: std.mem.Allocator, context_prompt: []const u8) ![]u8 {
    var lines = std.mem.splitScalar(u8, context_prompt, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (!std.mem.startsWith(u8, trimmed, "- (")) continue;
        const close = std.mem.indexOf(u8, trimmed, ") ") orelse continue;
        const answer = std.mem.trim(u8, trimmed[close + 2 ..], " \t\r\n");
        if (answer.len > 0) return allocator.dupe(u8, answer);
    }
    return allocator.dupe(u8, "I don't know.");
}

fn deterministicEntities(allocator: std.mem.Allocator, text: []const u8) !EntityList {
    var list = EntityList{ .allocator = allocator };
    errdefer list.deinit();

    var index: usize = 0;
    while (index < text.len) {
        while (index < text.len and !std.ascii.isAlphabetic(text[index])) : (index += 1) {}
        if (index >= text.len) break;
        const start = index;
        while (index < text.len and (std.ascii.isAlphabetic(text[index]) or text[index] == '\'' or text[index] == '-')) : (index += 1) {}
        const token = text[start..index];
        if (token.len < 2 or !std.ascii.isUpper(token[0]) or deterministicEntityStopWord(token)) continue;

        var phrase_end = index;
        var cursor = index;
        var words: usize = 1;
        while (words < 4) {
            var spaces = cursor;
            while (spaces < text.len and text[spaces] == ' ') : (spaces += 1) {}
            if (spaces == cursor or spaces >= text.len or !std.ascii.isUpper(text[spaces])) break;
            var next_end = spaces;
            while (next_end < text.len and (std.ascii.isAlphabetic(text[next_end]) or text[next_end] == '\'' or text[next_end] == '-')) : (next_end += 1) {}
            const next_token = text[spaces..next_end];
            if (deterministicEntityStopWord(next_token)) break;
            phrase_end = next_end;
            cursor = next_end;
            words += 1;
        }

        const name = std.mem.trim(u8, text[start..phrase_end], " \t\r\n.,;:!?()[]{}\"");
        if (name.len >= 2 and !entityListContains(list.items.items, name)) {
            try list.append(name, "other", &.{});
        }
        index = phrase_end;
        if (list.items.items.len >= 24) break;
    }

    return list;
}

fn deterministicEntityStopWord(token: []const u8) bool {
    const stop_words = [_][]const u8{
        "A", "An", "And", "As", "At", "But", "By", "For", "From", "He", "I", "In", "It", "On", "Or", "She", "The", "They", "This", "To", "We", "You",
        "Today", "Tomorrow", "Yesterday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday",
    };
    for (stop_words) |word| {
        if (std.mem.eql(u8, token, word)) return true;
    }
    return false;
}

fn entityListContains(items: []const ResolvedEntity, name: []const u8) bool {
    for (items) |item| {
        if (std.ascii.eqlIgnoreCase(item.name, name)) return true;
    }
    return false;
}

fn parseEntityResponse(allocator: std.mem.Allocator, response: []const u8) !EntityList {
    const cleaned = stripJsonFence(response);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, cleaned, .{});
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |object| object,
        else => return error.InvalidProviderResponse,
    };
    const entities = switch (root.get("entities") orelse return error.InvalidProviderResponse) {
        .array => |array| array,
        else => return error.InvalidProviderResponse,
    };

    var list = EntityList{ .allocator = allocator };
    errdefer list.deinit();
    for (entities.items) |entity_value| {
        const object = switch (entity_value) {
            .object => |object| object,
            else => continue,
        };
        const name = jsonString(object.get("name")) orelse continue;
        if (name.len == 0) continue;
        const entity_type = jsonString(object.get("type")) orelse "other";
        var aliases = std.ArrayList([]const u8).empty;
        defer aliases.deinit(allocator);
        if (object.get("aliases")) |aliases_value| {
            switch (aliases_value) {
                .array => |array| {
                    for (array.items) |alias_value| {
                        const alias = jsonStringValue(alias_value) orelse continue;
                        if (alias.len > 0) try aliases.append(allocator, alias);
                    }
                },
                else => {},
            }
        }
        if (!entityListContains(list.items.items, name)) {
            try list.append(name, entity_type, aliases.items);
        }
    }
    return list;
}

fn stripJsonFence(response: []const u8) []const u8 {
    var trimmed = std.mem.trim(u8, response, " \t\r\n");
    if (std.mem.startsWith(u8, trimmed, "```")) {
        const first_newline = std.mem.indexOfScalar(u8, trimmed, '\n') orelse return trimmed;
        trimmed = std.mem.trim(u8, trimmed[first_newline + 1 ..], " \t\r\n");
        if (std.mem.endsWith(u8, trimmed, "```")) {
            trimmed = std.mem.trim(u8, trimmed[0 .. trimmed.len - 3], " \t\r\n");
        }
    }
    return trimmed;
}

fn jsonString(value: ?std.json.Value) ?[]const u8 {
    const present = value orelse return null;
    return jsonStringValue(present);
}

fn jsonStringValue(value: std.json.Value) ?[]const u8 {
    return switch (value) {
        .string => |string| string,
        else => null,
    };
}

fn stringifyAlloc(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    try std.json.Stringify.value(value, .{}, &writer.writer);
    return writer.toOwnedSlice();
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

test "deterministic entity resolver extracts capitalized entities" {
    var entities = try deterministicEntities(std.testing.allocator, "Alice met Bob at Central Park. Alice likes jazz.");
    defer entities.deinit();

    try std.testing.expectEqual(@as(usize, 3), entities.items.items.len);
    try std.testing.expectEqualStrings("Alice", entities.items.items[0].name);
    try std.testing.expectEqualStrings("Bob", entities.items.items[1].name);
    try std.testing.expectEqualStrings("Central Park", entities.items.items[2].name);
}

test "entity provider response parser accepts JSON object" {
    var entities = try parseEntityResponse(
        std.testing.allocator,
        "{\"entities\":[{\"name\":\"Alice Smith\",\"type\":\"person\",\"aliases\":[\"Alice\"]}]}",
    );
    defer entities.deinit();

    try std.testing.expectEqual(@as(usize, 1), entities.items.items.len);
    try std.testing.expectEqualStrings("Alice Smith", entities.items.items[0].name);
    try std.testing.expectEqualStrings("person", entities.items.items[0].entity_type);
    try std.testing.expectEqualStrings("Alice", entities.items.items[0].aliases[0]);
}
