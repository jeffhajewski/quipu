//! Answer synthesis for `memory.answer`.
//!
//! There is exactly one answer path and it never routes on question wording:
//!
//! * no retrieved evidence  -> abstain without calling a reader;
//! * a reader (LLM) answered -> validate its JSON and support qids, keep its answer;
//! * no reader configured   -> deterministic fallback: the top current derived
//!   fact's value, else the top raw evidence text.
//!
//! The `strategy` reported in the trace only describes which of these happened.
const std = @import("std");
const query_expansion = @import("query_expansion.zig");

pub const abstain_answer = "[abstain]";

pub const strategy_reader = "llm_reader";
pub const strategy_deterministic = "deterministic_fallback";
pub const strategy_abstain = "abstain";

/// `answerTrace.readerMode`: which reader prompt produced the answer.
pub const reader_mode_none = "none";
pub const reader_mode_direct = "direct";
pub const reader_mode_reasoning = "reasoning";

/// One retrieved context item as seen by the synthesizer. `qid` is the qid the
/// reader saw in the rendered context; `evidenceQids` are the raw evidence it
/// links to (also valid support).
pub const EvidenceItem = struct {
    qid: []const u8,
    type: []const u8,
    text: []const u8,
    state: []const u8 = "current",
    value: ?[]const u8 = null,
    evidenceQids: []const []const u8 = &.{},
};

pub const CandidateAnswer = struct {
    text: []const u8,
    supportQids: []const []const u8 = &.{},
    confidence: f32,
    source: []const u8,
};

pub const Validation = struct {
    status: []const u8,
    warnings: []const []const u8 = &.{},
};

pub const AnswerTrace = struct {
    strategy: []const u8,
    /// `none` when no reader was called, else `direct` or `reasoning`.
    readerMode: []const u8 = reader_mode_none,
    /// Whether temporal hints were rendered (`options.temporalHints` with a
    /// parseable `time.validAt`). Set by the runtime.
    temporalHints: bool = false,
    /// The `Time references:` payload sent to the reader, if any. Set by the
    /// runtime.
    timeReferences: ?[]const u8 = null,
    /// The queries retrieval ran (`options.queryExpansion`). Set by the
    /// runtime; omitted from JSON when the option is off.
    queryExpansion: ?query_expansion.Trace = null,
    answerable: bool,
    supportQids: []const []const u8 = &.{},
    supportValid: bool,
    candidateAnswers: []const CandidateAnswer = &.{},
    /// The reader's evidence review in reasoning mode; never part of `answer`.
    reasoning: ?[]const u8 = null,
    rawProviderAnswer: ?[]const u8 = null,
    normalizedAnswer: []const u8,
    validation: Validation,

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        try jw.beginObject();
        inline for (std.meta.fields(@This())) |field| {
            const value = @field(self, field.name);
            if (comptime std.mem.eql(u8, field.name, "queryExpansion")) {
                if (value) |expansion| {
                    try jw.objectField(field.name);
                    try jw.write(expansion);
                }
            } else {
                try jw.objectField(field.name);
                try jw.write(value);
            }
        }
        try jw.endObject();
    }
};

pub const SynthesisOptions = struct {
    /// Replace weak answers (unanswerable, unsupported, unparseable) with
    /// exactly `[abstain]`. When false the reader's answer is always kept.
    abstain_if_weak: bool = false,
    /// The reader was asked for a `reasoning` field (`options.readerReasoning`).
    /// A missing or non-string reasoning adds a warning; the answer is kept.
    reader_reasoning: bool = false,
};

pub const OwnedSynthesisResult = struct {
    arena: *std.heap.ArenaAllocator,
    answer: []const u8,
    confidence: f32,
    trace: AnswerTrace,

    pub fn deinit(self: *OwnedSynthesisResult) void {
        const allocator = self.arena.child_allocator;
        self.arena.deinit();
        allocator.destroy(self.arena);
    }
};

/// The reader's optional `reasoning` field: absent (or empty or null), a
/// non-string value, or trimmed text.
pub const Reasoning = union(enum) {
    missing,
    invalid,
    text: []const u8,
};

pub const ParsedProviderAnswer = struct {
    answer: []const u8,
    answerable: bool,
    supportQids: []const []const u8,
    confidence: ?f32,
    reasoning: Reasoning = .missing,
};

const Draft = struct {
    answer: []const u8,
    strategy: []const u8,
    answerable: bool,
    support_qids: []const []const u8 = &.{},
    support_valid: bool,
    confidence: f32,
    status: []const u8,
    candidate: ?CandidateAnswer = null,
    reasoning: ?[]const u8 = null,
};

/// Builds the public answer and trace. `raw_provider_answer` is the reader's raw
/// output, or null when no reader is configured. Never invents support qids:
/// trace support is always a subset of the qids present in `items`.
pub fn synthesize(
    allocator: std.mem.Allocator,
    items: []const EvidenceItem,
    raw_provider_answer: ?[]const u8,
    options: SynthesisOptions,
) !OwnedSynthesisResult {
    const arena = try allocator.create(std.heap.ArenaAllocator);
    errdefer allocator.destroy(arena);
    arena.* = .init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    var warnings = std.ArrayList([]const u8).empty;
    var draft = if (items.len == 0) blk: {
        try warnings.append(a, "no_evidence");
        break :blk abstainDraft();
    } else if (raw_provider_answer) |raw|
        try readerDraft(a, items, raw, options.reader_reasoning, &warnings)
    else
        try deterministicDraft(a, items);

    const weak = !draft.answerable or !draft.support_valid;
    if (options.abstain_if_weak and weak and !std.mem.eql(u8, draft.answer, abstain_answer)) {
        draft.answer = abstain_answer;
        draft.strategy = strategy_abstain;
        draft.answerable = false;
        draft.support_qids = &.{};
        draft.confidence = 0;
        draft.status = "abstained";
    }

    const candidates: []const CandidateAnswer = if (draft.candidate) |candidate|
        try a.dupe(CandidateAnswer, &.{candidate})
    else
        &.{};

    const reader_called = items.len > 0 and raw_provider_answer != null;
    return .{
        .arena = arena,
        .answer = draft.answer,
        .confidence = draft.confidence,
        .trace = .{
            .strategy = draft.strategy,
            .readerMode = if (!reader_called)
                reader_mode_none
            else if (options.reader_reasoning)
                reader_mode_reasoning
            else
                reader_mode_direct,
            .answerable = draft.answerable,
            .supportQids = draft.support_qids,
            .supportValid = draft.support_valid,
            .candidateAnswers = candidates,
            .reasoning = draft.reasoning,
            .rawProviderAnswer = if (raw_provider_answer) |raw| try a.dupe(u8, raw) else null,
            .normalizedAnswer = draft.answer,
            .validation = .{
                .status = draft.status,
                .warnings = try warnings.toOwnedSlice(a),
            },
        },
    };
}

fn abstainDraft() Draft {
    return .{
        .answer = abstain_answer,
        .strategy = strategy_abstain,
        .answerable = false,
        .support_valid = true,
        .confidence = 0,
        .status = "abstained",
    };
}

fn readerDraft(
    a: std.mem.Allocator,
    items: []const EvidenceItem,
    raw: []const u8,
    reasoning_mode: bool,
    warnings: *std.ArrayList([]const u8),
) !Draft {
    const parsed = parseProviderAnswer(a, raw) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            // Keep the reader's text, but nothing about it was validated.
            try warnings.append(a, "parse_error");
            if (reasoning_mode) try warnings.append(a, "missing_reasoning");
            const text = try normalizeAnswerText(a, stripJsonFence(raw));
            const answerable = text.len > 0;
            return .{
                .answer = if (answerable) text else abstain_answer,
                .strategy = strategy_reader,
                .answerable = answerable,
                .support_valid = false,
                .confidence = 0,
                .status = "parse_error",
                .candidate = .{ .text = text, .confidence = 0, .source = "provider" },
            };
        },
    };

    // Reasoning is trace-only: its absence never discards the answer.
    var reasoning: ?[]const u8 = null;
    if (reasoning_mode) switch (parsed.reasoning) {
        .missing => try warnings.append(a, "missing_reasoning"),
        .invalid => try warnings.append(a, "invalid_reasoning"),
        .text => |review| reasoning = review,
    };

    const text = try normalizeAnswerText(a, parsed.answer);
    const answerable = parsed.answerable and text.len > 0;

    var valid = std.ArrayList([]const u8).empty;
    var invalid_count: usize = 0;
    for (parsed.supportQids) |qid| {
        if (!qidInContext(items, qid)) {
            invalid_count += 1;
            continue;
        }
        if (!stringListContains(valid.items, qid)) try valid.append(a, qid);
    }
    if (invalid_count > 0) try warnings.append(a, "invalid_support");
    if (answerable and parsed.supportQids.len == 0) try warnings.append(a, "missing_support");
    const support_valid = invalid_count == 0 and (!answerable or valid.items.len > 0);

    const default_confidence: f32 = if (answerable) 0.5 else 0.0;
    const confidence = clampConfidence(parsed.confidence orelse default_confidence);
    const support_qids = try valid.toOwnedSlice(a);
    const status = if (!answerable) "abstained" else if (!support_valid) "invalid_support" else "accepted";
    return .{
        .answer = if (text.len > 0) text else abstain_answer,
        .strategy = strategy_reader,
        .answerable = answerable,
        .support_qids = support_qids,
        .support_valid = support_valid,
        .confidence = confidence,
        .status = status,
        .candidate = .{ .text = text, .supportQids = support_qids, .confidence = confidence, .source = "provider" },
        .reasoning = reasoning,
    };
}

/// No reader configured: return the top current derived fact's value, else the
/// top raw evidence text. Items arrive in retrieval rank order.
fn deterministicDraft(a: std.mem.Allocator, items: []const EvidenceItem) !Draft {
    var chosen: ?EvidenceItem = null;
    var confidence: f32 = 0.25;
    for (items) |item| {
        if (isDerivedFactType(item.type) and std.mem.eql(u8, item.state, "current")) {
            chosen = item;
            confidence = 0.5;
            break;
        }
    }
    if (chosen == null) {
        for (items) |item| {
            if (!isDerivedFactType(item.type) and !std.mem.eql(u8, item.type, "core")) {
                chosen = item;
                break;
            }
        }
    }
    const item = chosen orelse items[0];
    const text = try normalizeAnswerText(a, if (isDerivedFactType(item.type)) item.value orelse item.text else item.text);
    const support_qids = try supportQidsForItem(a, item);
    return .{
        .answer = if (text.len > 0) text else abstain_answer,
        .strategy = strategy_deterministic,
        .answerable = text.len > 0,
        .support_qids = support_qids,
        .support_valid = true,
        .confidence = if (text.len > 0) confidence else 0,
        .status = if (text.len > 0) "accepted" else "abstained",
        .candidate = .{ .text = text, .supportQids = support_qids, .confidence = confidence, .source = "heuristic" },
    };
}

/// Parses the reader's JSON contract
/// `{"answer":"...","answerable":true,"supportQids":[...],"confidence":0..1}`,
/// with an optional leading `"reasoning":"..."` in reasoning mode.
/// Tolerates code fences, surrounding prose, an E1-style `abstained` flag and
/// legacy extra keys such as `strategy`. All strings live in `a`.
pub fn parseProviderAnswer(a: std.mem.Allocator, raw: []const u8) !ParsedProviderAnswer {
    const root = try parseJsonObject(a, raw);
    const answer_value = root.get("answer") orelse return error.InvalidProviderResponse;
    const answer = switch (answer_value) {
        .string => |string| string,
        .integer => |integer| try std.fmt.allocPrint(a, "{d}", .{integer}),
        .float => |float| try std.fmt.allocPrint(a, "{d}", .{float}),
        .number_string => |string| string,
        .bool => |boolean| if (boolean) "yes" else "no",
        .null => "",
        else => return error.InvalidProviderResponse,
    };
    const answerable = if (jsonBool(root.get("answerable"))) |value|
        value
    else if (jsonBool(root.get("abstained"))) |abstained|
        !abstained
    else
        true;

    var qids = std.ArrayList([]const u8).empty;
    if (jsonArray(root.get("supportQids"))) |array| {
        for (array.items) |entry| {
            const qid = switch (entry) {
                .string => |string| string,
                else => continue,
            };
            if (qid.len > 0) try qids.append(a, qid);
        }
    }

    const reasoning: Reasoning = if (root.get("reasoning")) |value| switch (value) {
        .string => |string| blk: {
            const trimmed = std.mem.trim(u8, string, " \t\r\n");
            break :blk if (trimmed.len == 0) .missing else .{ .text = trimmed };
        },
        .null => .missing,
        else => .invalid,
    } else .missing;

    return .{
        .answer = answer,
        .answerable = answerable,
        .supportQids = try qids.toOwnedSlice(a),
        .confidence = jsonFloat(root.get("confidence")),
        .reasoning = reasoning,
    };
}

fn parseJsonObject(a: std.mem.Allocator, raw: []const u8) !std.json.ObjectMap {
    const cleaned = stripJsonFence(raw);
    if (parseObjectSlice(a, cleaned)) |object| return object else |err| switch (err) {
        error.OutOfMemory => return err,
        else => {},
    }
    // Some readers wrap the object in prose; fall back to the outermost braces.
    const start = std.mem.indexOfScalar(u8, cleaned, '{') orelse return error.InvalidProviderResponse;
    const end = std.mem.lastIndexOfScalar(u8, cleaned, '}') orelse return error.InvalidProviderResponse;
    if (end <= start) return error.InvalidProviderResponse;
    return parseObjectSlice(a, cleaned[start .. end + 1]);
}

fn parseObjectSlice(a: std.mem.Allocator, text: []const u8) !std.json.ObjectMap {
    const value = std.json.parseFromSliceLeaky(std.json.Value, a, text, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidProviderResponse,
    };
    return switch (value) {
        .object => |object| object,
        else => error.InvalidProviderResponse,
    };
}

/// Light, question-independent cleanup: trims whitespace and wrapping quotes
/// and drops a leading "Answer:" / "Final answer:" label.
pub fn normalizeAnswerText(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var answer = std.mem.trim(u8, raw, " \t\r\n");
    answer = stripPrefixIgnoreCase(answer, "final answer:");
    answer = stripPrefixIgnoreCase(answer, "answer:");
    answer = std.mem.trim(u8, answer, " \t\r\n");
    if (answer.len >= 2 and answer[0] == '"' and answer[answer.len - 1] == '"') {
        answer = std.mem.trim(u8, answer[1 .. answer.len - 1], " \t\r\n");
    }
    return allocator.dupe(u8, answer);
}

fn supportQidsForItem(a: std.mem.Allocator, item: EvidenceItem) ![]const []const u8 {
    var qids = std.ArrayList([]const u8).empty;
    try qids.append(a, item.qid);
    for (item.evidenceQids) |qid| {
        if (!stringListContains(qids.items, qid)) try qids.append(a, qid);
    }
    return qids.toOwnedSlice(a);
}

fn qidInContext(items: []const EvidenceItem, qid: []const u8) bool {
    for (items) |item| {
        if (std.mem.eql(u8, item.qid, qid)) return true;
        if (stringListContains(item.evidenceQids, qid)) return true;
    }
    return false;
}

fn isDerivedFactType(item_type: []const u8) bool {
    return std.mem.eql(u8, item_type, "fact") or
        std.mem.eql(u8, item_type, "preference") or
        std.mem.eql(u8, item_type, "procedure");
}

fn clampConfidence(value: f32) f32 {
    if (std.math.isNan(value)) return 0;
    return std.math.clamp(value, 0, 1);
}

fn stringListContains(items: []const []const u8, expected: []const u8) bool {
    for (items) |item| {
        if (std.mem.eql(u8, item, expected)) return true;
    }
    return false;
}

fn stripJsonFence(raw: []const u8) []const u8 {
    var text = std.mem.trim(u8, raw, " \t\r\n");
    if (std.mem.startsWith(u8, text, "```")) {
        if (std.mem.indexOfScalar(u8, text, '\n')) |line_end| {
            text = text[line_end + 1 ..];
        }
        if (std.mem.lastIndexOf(u8, text, "```")) |fence_start| {
            text = text[0..fence_start];
        }
    }
    return std.mem.trim(u8, text, " \t\r\n");
}

fn jsonArray(value: ?std.json.Value) ?std.json.Array {
    const present = value orelse return null;
    return switch (present) {
        .array => |array| array,
        else => null,
    };
}

fn jsonBool(value: ?std.json.Value) ?bool {
    const present = value orelse return null;
    return switch (present) {
        .bool => |boolean| boolean,
        else => null,
    };
}

fn jsonFloat(value: ?std.json.Value) ?f32 {
    const present = value orelse return null;
    return switch (present) {
        .float => |float| @as(f32, @floatCast(float)),
        .integer => |integer| @as(f32, @floatFromInt(integer)),
        .number_string, .string => |string| std.fmt.parseFloat(f32, string) catch null,
        else => null,
    };
}

fn stripPrefixIgnoreCase(text: []const u8, prefix: []const u8) []const u8 {
    if (text.len < prefix.len or !std.ascii.eqlIgnoreCase(text[0..prefix.len], prefix)) return text;
    return std.mem.trim(u8, text[prefix.len..], " \t\r\n");
}

const test_evidence = [_][]const u8{"q_msg_2"};
const test_items = [_]EvidenceItem{
    .{ .qid = "q_msg_1", .type = "message", .text = "I booked the Harbor Inn for March." },
    .{ .qid = "q_fact_1", .type = "fact", .text = "Hotel: Lakeside Suites.", .value = "Lakeside Suites", .evidenceQids = &test_evidence },
};

test "reader answer keeps valid support and clamps model confidence" {
    var result = try synthesize(
        std.testing.allocator,
        &test_items,
        "{\"answer\":\"Lakeside Suites\",\"answerable\":true,\"supportQids\":[\"q_fact_1\",\"q_msg_2\",\"q_fact_1\"],\"confidence\":1.7}",
        .{},
    );
    defer result.deinit();

    try std.testing.expectEqualStrings("Lakeside Suites", result.answer);
    try std.testing.expectEqualStrings(strategy_reader, result.trace.strategy);
    try std.testing.expect(result.trace.answerable);
    try std.testing.expect(result.trace.supportValid);
    try std.testing.expectEqual(@as(usize, 2), result.trace.supportQids.len);
    try std.testing.expectEqualStrings("accepted", result.trace.validation.status);
    try std.testing.expectEqual(@as(f32, 1.0), result.confidence);
    try std.testing.expectEqualStrings("provider", result.trace.candidateAnswers[0].source);
}

test "reader answer with invalid support is kept and flagged" {
    const raw = "{\"answer\":\"Avis\",\"answerable\":true,\"supportQids\":[\"q_msg_missing\",\"q_msg_1\"],\"confidence\":0.7}";
    var kept = try synthesize(std.testing.allocator, &test_items, raw, .{});
    defer kept.deinit();
    try std.testing.expectEqualStrings("Avis", kept.answer);
    try std.testing.expect(!kept.trace.supportValid);
    try std.testing.expectEqualStrings("invalid_support", kept.trace.validation.status);
    try std.testing.expectEqualStrings("invalid_support", kept.trace.validation.warnings[0]);
    // The invented qid never reaches the trace.
    try std.testing.expectEqual(@as(usize, 1), kept.trace.supportQids.len);
    try std.testing.expectEqualStrings("q_msg_1", kept.trace.supportQids[0]);
    try std.testing.expectApproxEqAbs(@as(f32, 0.7), kept.confidence, 0.0001);

    var abstained = try synthesize(std.testing.allocator, &test_items, raw, .{ .abstain_if_weak = true });
    defer abstained.deinit();
    try std.testing.expectEqualStrings(abstain_answer, abstained.answer);
    try std.testing.expectEqualStrings("abstained", abstained.trace.validation.status);
    try std.testing.expectEqualStrings(strategy_abstain, abstained.trace.strategy);
    try std.testing.expectEqual(@as(usize, 0), abstained.trace.supportQids.len);
    try std.testing.expectEqual(@as(f32, 0), abstained.confidence);
}

test "reader answer without support qids is flagged missing_support" {
    var result = try synthesize(std.testing.allocator, &test_items, "{\"answer\":\"Harbor Inn\",\"answerable\":true}", .{});
    defer result.deinit();
    try std.testing.expectEqualStrings("Harbor Inn", result.answer);
    try std.testing.expect(!result.trace.supportValid);
    try std.testing.expectEqualStrings("missing_support", result.trace.validation.warnings[0]);
    try std.testing.expectEqual(@as(f32, 0.5), result.confidence);
}

test "unanswerable reader explanation is kept unless abstainIfWeak" {
    const raw = "```json\n{\"answer\":\"You never mentioned a car rental in Austin.\",\"answerable\":false,\"supportQids\":[],\"confidence\":0.8}\n```";
    var kept = try synthesize(std.testing.allocator, &test_items, raw, .{});
    defer kept.deinit();
    try std.testing.expectEqualStrings("You never mentioned a car rental in Austin.", kept.answer);
    try std.testing.expect(!kept.trace.answerable);
    try std.testing.expect(kept.trace.supportValid);
    try std.testing.expectEqualStrings("abstained", kept.trace.validation.status);

    var abstained = try synthesize(std.testing.allocator, &test_items, raw, .{ .abstain_if_weak = true });
    defer abstained.deinit();
    try std.testing.expectEqualStrings(abstain_answer, abstained.answer);
}

test "unparseable reader output keeps its text with parse_error" {
    var result = try synthesize(std.testing.allocator, &test_items, "Answer: Lakeside Suites", .{});
    defer result.deinit();
    try std.testing.expectEqualStrings("Lakeside Suites", result.answer);
    try std.testing.expectEqualStrings("parse_error", result.trace.validation.status);
    try std.testing.expect(!result.trace.supportValid);

    var wrapped = try synthesize(
        std.testing.allocator,
        &test_items,
        "Here you go: {\"answer\":\"Harbor Inn\",\"abstained\":false,\"supportQids\":[\"q_msg_1\"]} Hope that helps.",
        .{},
    );
    defer wrapped.deinit();
    try std.testing.expectEqualStrings("Harbor Inn", wrapped.answer);
    try std.testing.expectEqualStrings("accepted", wrapped.trace.validation.status);
}

test "reasoning mode keeps the answer and reports reasoning only in the trace" {
    const raw = "{\"reasoning\":\"[q_msg_1] 2023-03-01 user booked Harbor Inn; later [q_fact_1] says Lakeside Suites, which is newer.\",\"answer\":\"Lakeside Suites\",\"answerable\":true,\"supportQids\":[\"q_fact_1\"],\"confidence\":0.8}";
    var result = try synthesize(std.testing.allocator, &test_items, raw, .{ .reader_reasoning = true });
    defer result.deinit();
    try std.testing.expectEqualStrings("Lakeside Suites", result.answer);
    try std.testing.expectEqualStrings(reader_mode_reasoning, result.trace.readerMode);
    try std.testing.expect(std.mem.startsWith(u8, result.trace.reasoning.?, "[q_msg_1] 2023-03-01 user booked"));
    try std.testing.expectEqualStrings("accepted", result.trace.validation.status);
    try std.testing.expectEqual(@as(usize, 0), result.trace.validation.warnings.len);

    // Direct mode ignores a reasoning field the reader volunteered.
    var direct = try synthesize(std.testing.allocator, &test_items, raw, .{});
    defer direct.deinit();
    try std.testing.expectEqualStrings(reader_mode_direct, direct.trace.readerMode);
    try std.testing.expect(direct.trace.reasoning == null);
}

test "missing or invalid reasoning warns without discarding the answer" {
    const missing = "{\"answer\":\"Harbor Inn\",\"answerable\":true,\"supportQids\":[\"q_msg_1\"],\"confidence\":0.6}";
    var without = try synthesize(std.testing.allocator, &test_items, missing, .{ .reader_reasoning = true });
    defer without.deinit();
    try std.testing.expectEqualStrings("Harbor Inn", without.answer);
    try std.testing.expect(without.trace.reasoning == null);
    try std.testing.expectEqualStrings("accepted", without.trace.validation.status);
    try std.testing.expectEqualStrings("missing_reasoning", without.trace.validation.warnings[0]);

    const blank = "{\"reasoning\":\"  \",\"answer\":\"Harbor Inn\",\"answerable\":true,\"supportQids\":[\"q_msg_1\"]}";
    var empty = try synthesize(std.testing.allocator, &test_items, blank, .{ .reader_reasoning = true });
    defer empty.deinit();
    try std.testing.expectEqualStrings("missing_reasoning", empty.trace.validation.warnings[0]);

    const listed = "{\"reasoning\":[\"q_msg_1 says Harbor Inn\"],\"answer\":\"Harbor Inn\",\"answerable\":true,\"supportQids\":[\"q_msg_1\"]}";
    var invalid = try synthesize(std.testing.allocator, &test_items, listed, .{ .reader_reasoning = true });
    defer invalid.deinit();
    try std.testing.expectEqualStrings("Harbor Inn", invalid.answer);
    try std.testing.expect(invalid.trace.reasoning == null);
    try std.testing.expect(invalid.trace.supportValid);
    try std.testing.expectEqualStrings("invalid_reasoning", invalid.trace.validation.warnings[0]);

    var unparseable = try synthesize(std.testing.allocator, &test_items, "{\"reasoning\":\"cut off mid", .{ .reader_reasoning = true });
    defer unparseable.deinit();
    try std.testing.expectEqualStrings("parse_error", unparseable.trace.validation.status);
    try std.testing.expectEqualStrings("missing_reasoning", unparseable.trace.validation.warnings[1]);
}

test "deterministic fallback prefers the top current derived fact value" {
    var result = try synthesize(std.testing.allocator, &test_items, null, .{});
    defer result.deinit();
    try std.testing.expectEqualStrings("Lakeside Suites", result.answer);
    try std.testing.expectEqualStrings(strategy_deterministic, result.trace.strategy);
    try std.testing.expectEqualStrings(reader_mode_none, result.trace.readerMode);
    try std.testing.expectEqualStrings("q_fact_1", result.trace.supportQids[0]);
    try std.testing.expectEqualStrings("q_msg_2", result.trace.supportQids[1]);

    const raw_only = [_]EvidenceItem{
        .{ .qid = "q_core_1", .type = "core", .text = "Project summary." },
        .{ .qid = "q_msg_9", .type = "message", .text = "Run just test before committing." },
        .{ .qid = "q_fact_2", .type = "fact", .state = "superseded", .text = "Old fact.", .value = "old" },
    };
    var fallback = try synthesize(std.testing.allocator, &raw_only, null, .{});
    defer fallback.deinit();
    try std.testing.expectEqualStrings("Run just test before committing.", fallback.answer);
    try std.testing.expectEqual(@as(f32, 0.25), fallback.confidence);
}

test "no evidence abstains without a reader" {
    var result = try synthesize(std.testing.allocator, &.{}, null, .{});
    defer result.deinit();
    try std.testing.expectEqualStrings(abstain_answer, result.answer);
    try std.testing.expectEqualStrings(strategy_abstain, result.trace.strategy);
    try std.testing.expect(!result.trace.answerable);
    try std.testing.expectEqual(@as(f32, 0), result.confidence);
}

test "normalization is independent of question wording" {
    const answer = try normalizeAnswerText(std.testing.allocator, "  Final answer: \"I visited Japan in 2023.\" ");
    defer std.testing.allocator.free(answer);
    try std.testing.expectEqualStrings("I visited Japan in 2023.", answer);
}
