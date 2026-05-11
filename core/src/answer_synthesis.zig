const std = @import("std");

pub const EvidenceItem = struct {
    qid: []const u8,
    type: []const u8,
    text: []const u8,
    score: f32 = 0,
    state: []const u8 = "current",
    validFrom: ?[]const u8 = null,
    validTo: ?[]const u8 = null,
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
    answerable: bool,
    supportQids: []const []const u8 = &.{},
    candidateAnswers: []const CandidateAnswer = &.{},
    rawProviderAnswer: ?[]const u8 = null,
    normalizedAnswer: []const u8,
    validation: Validation,
};

pub const ParsedProviderAnswer = struct {
    allocator: std.mem.Allocator,
    answer: []const u8,
    answerable: bool,
    supportQids: []const []const u8,
    strategy: []const u8,
    confidence: f32,

    pub fn deinit(self: *ParsedProviderAnswer) void {
        self.allocator.free(self.answer);
        for (self.supportQids) |qid| self.allocator.free(qid);
        self.allocator.free(self.supportQids);
        self.allocator.free(self.strategy);
    }
};

pub const OwnedSynthesisResult = struct {
    allocator: std.mem.Allocator,
    answer: []const u8,
    trace: AnswerTrace,

    pub fn deinit(self: *OwnedSynthesisResult) void {
        self.allocator.free(self.answer);
        self.allocator.free(self.trace.strategy);
        for (self.trace.supportQids) |qid| self.allocator.free(qid);
        self.allocator.free(self.trace.supportQids);
        for (self.trace.candidateAnswers) |candidate| {
            self.allocator.free(candidate.text);
            for (candidate.supportQids) |qid| self.allocator.free(qid);
            self.allocator.free(candidate.supportQids);
        }
        self.allocator.free(self.trace.candidateAnswers);
        if (self.trace.rawProviderAnswer) |raw| self.allocator.free(raw);
        self.allocator.free(self.trace.normalizedAnswer);
        self.allocator.free(self.trace.validation.status);
        for (self.trace.validation.warnings) |warning| self.allocator.free(warning);
        self.allocator.free(self.trace.validation.warnings);
    }
};

const OwnedCandidate = struct {
    text: []const u8,
    support_qids: []const []const u8,
    confidence: f32,
    source: []const u8,

    fn deinit(self: *OwnedCandidate, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        for (self.support_qids) |qid| allocator.free(qid);
        allocator.free(self.support_qids);
    }
};

pub fn routeStrategy(query: []const u8, items: []const EvidenceItem) []const u8 {
    if (items.len == 0) return "abstain";
    if (containsIgnoreCase(query, "how many") or containsIgnoreCase(query, "how much") or containsIgnoreCase(query, "total") or containsIgnoreCase(query, "count") or containsIgnoreCase(query, "across")) {
        return "multi_session";
    }
    if (containsIgnoreCase(query, "before") or containsIgnoreCase(query, "after") or containsIgnoreCase(query, "when") or containsIgnoreCase(query, " on ") or containsIgnoreCase(query, "was") or containsIgnoreCase(query, "previous")) {
        return "temporal";
    }
    if (containsIgnoreCase(query, "prefer") or containsIgnoreCase(query, "preference") or containsItemType(items, "preference")) {
        return "preference";
    }
    if (containsIgnoreCase(query, "current") or containsIgnoreCase(query, "now") or containsIgnoreCase(query, "latest") or containsIgnoreCase(query, "update")) {
        return "knowledge_update";
    }
    return "span_extract";
}

pub fn hasStrongHeuristic(query: []const u8, items: []const EvidenceItem) bool {
    if (items.len == 0) return false;
    const strategy = routeStrategy(query, items);
    if (std.mem.eql(u8, strategy, "preference")) return containsItemType(items, "preference");
    if (std.mem.eql(u8, strategy, "knowledge_update")) return firstCurrentItem(items) != null;
    if (std.mem.eql(u8, strategy, "temporal")) return items.len == 1 or firstCurrentItem(items) != null;
    if (std.mem.eql(u8, strategy, "multi_session")) return hasNumericAggregate(query, items);
    return items.len == 1;
}

pub fn synthesize(
    allocator: std.mem.Allocator,
    query: []const u8,
    items: []const EvidenceItem,
    raw_provider_answer: ?[]const u8,
    abstain_if_weak: bool,
) !OwnedSynthesisResult {
    const routed_strategy = routeStrategy(query, items);
    var warnings = std.ArrayList([]const u8).empty;
    errdefer freeStringList(allocator, warnings.items);
    errdefer warnings.deinit(allocator);

    var candidates = std.ArrayList(OwnedCandidate).empty;
    defer {
        for (candidates.items) |*candidate| candidate.deinit(allocator);
        candidates.deinit(allocator);
    }
    if (try heuristicCandidate(allocator, query, routed_strategy, items)) |candidate| {
        try candidates.append(allocator, candidate);
    }

    var provider_answer: ?ParsedProviderAnswer = null;
    defer if (provider_answer) |*parsed| parsed.deinit();
    if (raw_provider_answer) |raw| {
        provider_answer = parseProviderAnswer(allocator, raw) catch blk: {
            try appendOwnedWarning(allocator, &warnings, "parse_error");
            break :blk null;
        };
    }

    const answer_source = chooseAnswerSource(provider_answer, candidates.items);
    const raw_answer = switch (answer_source) {
        .provider => provider_answer.?.answer,
        .candidate => candidates.items[0].text,
        .none => "",
    };
    var normalized = try normalizeAnswerText(allocator, query, raw_answer);
    defer allocator.free(normalized);

    const provider_answerable = if (provider_answer) |parsed| parsed.answerable else true;
    const unsupported = items.len == 0 or !provider_answerable or isUnsupportedAnswer(normalized);
    var support_qids = try supportQidsForAnswer(allocator, answer_source, provider_answer, candidates.items, items);
    errdefer freeStringList(allocator, support_qids);
    const supports_valid = support_qids.len > 0 and supportQidsExist(support_qids, items);

    var validation_status: []const u8 = "accepted";
    var strategy = routed_strategy;
    var answerable = !unsupported and supports_valid;
    if (unsupported or !supports_valid) {
        if (!supports_valid) try appendOwnedWarning(allocator, &warnings, "invalid_support");
        if (abstain_if_weak) {
            allocator.free(normalized);
            normalized = try allocator.dupe(u8, "[abstain]");
            freeStringList(allocator, support_qids);
            support_qids = try allocator.alloc([]const u8, 0);
            validation_status = "abstained";
            strategy = "abstain";
            answerable = false;
        } else if (candidates.items.len > 0 and answer_source == .provider) {
            allocator.free(normalized);
            normalized = try normalizeAnswerText(allocator, query, candidates.items[0].text);
            freeStringList(allocator, support_qids);
            support_qids = try cloneQids(allocator, candidates.items[0].support_qids);
            validation_status = "fallback";
            answerable = support_qids.len > 0;
        } else {
            validation_status = if (unsupported) "abstained" else "invalid_support";
            answerable = false;
        }
    }

    const answer = try allocator.dupe(u8, normalized);
    errdefer allocator.free(answer);
    const trace_candidates = try cloneCandidates(allocator, candidates.items);
    errdefer freeTraceCandidates(allocator, trace_candidates);
    const raw_copy = if (raw_provider_answer) |raw| try allocator.dupe(u8, raw) else null;
    errdefer if (raw_copy) |raw| allocator.free(raw);
    const normalized_copy = try allocator.dupe(u8, normalized);
    errdefer allocator.free(normalized_copy);
    const status_copy = try allocator.dupe(u8, validation_status);
    errdefer allocator.free(status_copy);
    const warning_slice = try warnings.toOwnedSlice(allocator);
    errdefer freeStringList(allocator, warning_slice);
    const strategy_copy = try allocator.dupe(u8, strategy);
    errdefer allocator.free(strategy_copy);

    return .{
        .allocator = allocator,
        .answer = answer,
        .trace = .{
            .strategy = strategy_copy,
            .answerable = answerable,
            .supportQids = support_qids,
            .candidateAnswers = trace_candidates,
            .rawProviderAnswer = raw_copy,
            .normalizedAnswer = normalized_copy,
            .validation = .{
                .status = status_copy,
                .warnings = warning_slice,
            },
        },
    };
}

const AnswerSource = enum {
    provider,
    candidate,
    none,
};

fn chooseAnswerSource(provider_answer: ?ParsedProviderAnswer, candidates: []const OwnedCandidate) AnswerSource {
    if (provider_answer != null) return .provider;
    if (candidates.len > 0) return .candidate;
    return .none;
}

pub fn parseProviderAnswer(allocator: std.mem.Allocator, raw: []const u8) !ParsedProviderAnswer {
    const cleaned = stripJsonFence(raw);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, cleaned, .{});
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |object| object,
        else => return error.InvalidProviderResponse,
    };
    const answer = jsonString(root.get("answer")) orelse return error.InvalidProviderResponse;
    const answerable = jsonBool(root.get("answerable")) orelse true;
    const strategy = jsonString(root.get("strategy")) orelse "span_extract";
    const confidence = jsonFloat(root.get("confidence")) orelse 0.0;
    const support_qids = try qidArray(allocator, root.get("supportQids"));
    errdefer freeStringList(allocator, support_qids);
    return .{
        .allocator = allocator,
        .answer = try allocator.dupe(u8, answer),
        .answerable = answerable,
        .supportQids = support_qids,
        .strategy = try allocator.dupe(u8, strategy),
        .confidence = confidence,
    };
}

pub fn normalizeAnswerText(allocator: std.mem.Allocator, query: []const u8, raw: []const u8) ![]u8 {
    var answer = std.mem.trim(u8, raw, " \t\r\n\"'");
    answer = stripPrefixIgnoreCase(answer, "the answer is");
    answer = stripPrefixIgnoreCase(answer, "answer:");
    answer = stripPrefixIgnoreCase(answer, "final answer:");
    answer = stripPrefixIgnoreCase(answer, "it is");
    answer = std.mem.trim(u8, answer, " \t\r\n\"'");

    if (isQuantityQuestion(query)) {
        if (singleAmount(answer)) |amount| return allocator.dupe(u8, amount);
        if (singleInteger(answer)) |integer| return allocator.dupe(u8, integer);
        if (singleIsoDate(answer)) |date| return allocator.dupe(u8, date);
    }
    return allocator.dupe(u8, answer);
}

fn heuristicCandidate(
    allocator: std.mem.Allocator,
    query: []const u8,
    strategy: []const u8,
    items: []const EvidenceItem,
) !?OwnedCandidate {
    if (items.len == 0) return null;
    if (std.mem.eql(u8, strategy, "multi_session")) {
        if (try aggregateCandidate(allocator, query, items)) |candidate| {
            return candidate;
        }
    }
    if (std.mem.eql(u8, strategy, "preference")) {
        if (firstItemOfType(items, "preference")) |item| {
            return try ownedCandidateFromItem(allocator, item, 0.9, "heuristic");
        }
    }
    if (std.mem.eql(u8, strategy, "knowledge_update")) {
        if (firstCurrentItem(items)) |item| {
            return try ownedCandidateFromItem(allocator, item, 0.88, "heuristic");
        }
    }
    if (std.mem.eql(u8, strategy, "temporal")) {
        if (firstTemporalItem(items)) |item| {
            return try ownedCandidateFromItem(allocator, item, 0.86, "heuristic");
        }
    }
    return try ownedCandidateFromItem(allocator, items[0], 0.78, "heuristic");
}

fn ownedCandidateFromItem(allocator: std.mem.Allocator, item: EvidenceItem, confidence: f32, source: []const u8) !OwnedCandidate {
    const support_qids = try supportQidsForItem(allocator, item);
    errdefer freeStringList(allocator, support_qids);
    return .{
        .text = try allocator.dupe(u8, item.text),
        .support_qids = support_qids,
        .confidence = confidence,
        .source = source,
    };
}

fn ownedCandidateFromText(allocator: std.mem.Allocator, text: []const u8, support_qids: []const []const u8, confidence: f32, source: []const u8) !OwnedCandidate {
    return .{
        .text = try allocator.dupe(u8, text),
        .support_qids = try cloneQids(allocator, support_qids),
        .confidence = confidence,
        .source = source,
    };
}

fn hasNumericAggregate(query: []const u8, items: []const EvidenceItem) bool {
    if (items.len == 0) return false;
    if (containsIgnoreCase(query, "how much") or containsIgnoreCase(query, "cost")) {
        return countAmounts(items) > 0;
    }
    if (containsIgnoreCase(query, "session") or containsIgnoreCase(query, "entries") or containsIgnoreCase(query, "items")) {
        return true;
    }
    return countIntegers(items) > 0;
}

fn aggregateCandidate(allocator: std.mem.Allocator, query: []const u8, items: []const EvidenceItem) !?OwnedCandidate {
    if (items.len == 0) return null;
    if (containsIgnoreCase(query, "how much") or containsIgnoreCase(query, "cost")) {
        var total: i64 = 0;
        var matched = std.ArrayList(EvidenceItem).empty;
        defer matched.deinit(allocator);
        for (items) |item| {
            if (firstDollarAmount(item.text)) |amount| {
                total += amount;
                try matched.append(allocator, item);
            }
        }
        if (matched.items.len == 0) return null;
        const text = try std.fmt.allocPrint(allocator, "${d}", .{total});
        defer allocator.free(text);
        const qids = try supportQidsForItems(allocator, matched.items);
        defer freeStringList(allocator, qids);
        return try ownedCandidateFromText(allocator, text, qids, 0.92, "heuristic");
    }
    if (containsIgnoreCase(query, "session") or containsIgnoreCase(query, "entries") or containsIgnoreCase(query, "items")) {
        const text = try std.fmt.allocPrint(allocator, "{d}", .{items.len});
        defer allocator.free(text);
        const qids = try supportQidsForItems(allocator, items);
        defer freeStringList(allocator, qids);
        return try ownedCandidateFromText(allocator, text, qids, 0.9, "heuristic");
    }

    var total: i64 = 0;
    var matched = std.ArrayList(EvidenceItem).empty;
    defer matched.deinit(allocator);
    for (items) |item| {
        if (firstIntegerValue(item.text)) |value| {
            total += value;
            try matched.append(allocator, item);
        }
    }
    if (matched.items.len == 0) return null;
    const text = try std.fmt.allocPrint(allocator, "{d}", .{total});
    defer allocator.free(text);
    const qids = try supportQidsForItems(allocator, matched.items);
    defer freeStringList(allocator, qids);
    return try ownedCandidateFromText(allocator, text, qids, 0.9, "heuristic");
}

fn supportQidsForAnswer(
    allocator: std.mem.Allocator,
    source: AnswerSource,
    provider_answer: ?ParsedProviderAnswer,
    candidates: []const OwnedCandidate,
    items: []const EvidenceItem,
) ![]const []const u8 {
    return switch (source) {
        .provider => if (provider_answer) |parsed|
            try cloneQids(allocator, parsed.supportQids)
        else
            try allocator.alloc([]const u8, 0),
        .candidate => if (candidates.len > 0)
            try cloneQids(allocator, candidates[0].support_qids)
        else
            try allocator.alloc([]const u8, 0),
        .none => if (items.len > 0)
            try supportQidsForItem(allocator, items[0])
        else
            try allocator.alloc([]const u8, 0),
    };
}

fn supportQidsForItem(allocator: std.mem.Allocator, item: EvidenceItem) ![]const []const u8 {
    if (item.evidenceQids.len > 0) return cloneQids(allocator, item.evidenceQids);
    const qids = try allocator.alloc([]const u8, 1);
    errdefer allocator.free(qids);
    qids[0] = try allocator.dupe(u8, item.qid);
    return qids;
}

fn supportQidsForItems(allocator: std.mem.Allocator, items: []const EvidenceItem) ![]const []const u8 {
    var qids = std.ArrayList([]const u8).empty;
    errdefer {
        for (qids.items) |qid| allocator.free(qid);
        qids.deinit(allocator);
    }
    for (items) |item| {
        const item_qids = try supportQidsForItem(allocator, item);
        defer freeStringList(allocator, item_qids);
        for (item_qids) |qid| {
            if (!stringListContains(qids.items, qid)) {
                try qids.append(allocator, try allocator.dupe(u8, qid));
            }
        }
    }
    return qids.toOwnedSlice(allocator);
}

fn stringListContains(items: []const []const u8, expected: []const u8) bool {
    for (items) |item| {
        if (std.mem.eql(u8, item, expected)) return true;
    }
    return false;
}

fn supportQidsExist(qids: []const []const u8, items: []const EvidenceItem) bool {
    for (qids) |qid| {
        var found = false;
        for (items) |item| {
            if (std.mem.eql(u8, item.qid, qid)) {
                found = true;
                break;
            }
            for (item.evidenceQids) |evidence_qid| {
                if (std.mem.eql(u8, evidence_qid, qid)) {
                    found = true;
                    break;
                }
            }
            if (found) break;
        }
        if (!found) return false;
    }
    return true;
}

fn countAmounts(items: []const EvidenceItem) usize {
    var count: usize = 0;
    for (items) |item| {
        if (firstDollarAmount(item.text) != null) count += 1;
    }
    return count;
}

fn countIntegers(items: []const EvidenceItem) usize {
    var count: usize = 0;
    for (items) |item| {
        if (firstIntegerValue(item.text) != null) count += 1;
    }
    return count;
}

fn firstDollarAmount(text: []const u8) ?i64 {
    var index: usize = 0;
    while (index < text.len) : (index += 1) {
        if (text[index] != '$') continue;
        index += 1;
        const start = index;
        while (index < text.len and (std.ascii.isDigit(text[index]) or text[index] == ',')) : (index += 1) {}
        if (index == start) continue;
        return parseIntegerIgnoringCommas(text[start..index]);
    }
    return null;
}

fn firstIntegerValue(text: []const u8) ?i64 {
    var index: usize = 0;
    while (index < text.len) {
        while (index < text.len and !std.ascii.isDigit(text[index])) : (index += 1) {}
        if (index >= text.len) break;
        const start = index;
        while (index < text.len and std.ascii.isDigit(text[index])) : (index += 1) {}
        return std.fmt.parseInt(i64, text[start..index], 10) catch null;
    }
    return null;
}

fn parseIntegerIgnoringCommas(text: []const u8) ?i64 {
    var value: i64 = 0;
    var seen_digit = false;
    for (text) |byte| {
        if (byte == ',') continue;
        if (!std.ascii.isDigit(byte)) return null;
        value = value * 10 + @as(i64, byte - '0');
        seen_digit = true;
    }
    return if (seen_digit) value else null;
}

fn firstItemOfType(items: []const EvidenceItem, item_type: []const u8) ?EvidenceItem {
    for (items) |item| {
        if (std.mem.eql(u8, item.type, item_type)) return item;
    }
    return null;
}

fn firstCurrentItem(items: []const EvidenceItem) ?EvidenceItem {
    for (items) |item| {
        if (std.mem.eql(u8, item.state, "current")) return item;
    }
    return null;
}

fn firstTemporalItem(items: []const EvidenceItem) ?EvidenceItem {
    for (items) |item| {
        if (item.validFrom != null or item.validTo != null or !std.mem.eql(u8, item.state, "current")) return item;
    }
    return items[0];
}

fn containsItemType(items: []const EvidenceItem, item_type: []const u8) bool {
    return firstItemOfType(items, item_type) != null;
}

fn cloneCandidates(allocator: std.mem.Allocator, candidates: []const OwnedCandidate) ![]CandidateAnswer {
    var cloned = try allocator.alloc(CandidateAnswer, candidates.len);
    errdefer allocator.free(cloned);
    var written: usize = 0;
    errdefer {
        for (cloned[0..written]) |candidate| {
            allocator.free(candidate.text);
            for (candidate.supportQids) |qid| allocator.free(qid);
            allocator.free(candidate.supportQids);
        }
    }
    for (candidates, 0..) |candidate, index| {
        cloned[index] = .{
            .text = try allocator.dupe(u8, candidate.text),
            .supportQids = try cloneQids(allocator, candidate.support_qids),
            .confidence = candidate.confidence,
            .source = candidate.source,
        };
        written += 1;
    }
    return cloned;
}

fn freeTraceCandidates(allocator: std.mem.Allocator, candidates: []const CandidateAnswer) void {
    for (candidates) |candidate| {
        allocator.free(candidate.text);
        for (candidate.supportQids) |qid| allocator.free(qid);
        allocator.free(candidate.supportQids);
    }
    allocator.free(candidates);
}

fn cloneQids(allocator: std.mem.Allocator, qids: []const []const u8) ![]const []const u8 {
    const cloned = try allocator.alloc([]const u8, qids.len);
    errdefer allocator.free(cloned);
    var written: usize = 0;
    errdefer {
        for (cloned[0..written]) |qid| allocator.free(qid);
    }
    for (qids, 0..) |qid, index| {
        cloned[index] = try allocator.dupe(u8, qid);
        written += 1;
    }
    return cloned;
}

fn qidArray(allocator: std.mem.Allocator, value: ?std.json.Value) ![]const []const u8 {
    const array_value = value orelse return allocator.alloc([]const u8, 0);
    const array = switch (array_value) {
        .array => |array| array,
        else => return error.InvalidProviderResponse,
    };
    var qids = std.ArrayList([]const u8).empty;
    errdefer {
        for (qids.items) |qid| allocator.free(qid);
        qids.deinit(allocator);
    }
    for (array.items) |item| {
        const qid = jsonString(item) orelse return error.InvalidProviderResponse;
        try qids.append(allocator, try allocator.dupe(u8, qid));
    }
    return qids.toOwnedSlice(allocator);
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

fn jsonString(value: ?std.json.Value) ?[]const u8 {
    const present = value orelse return null;
    return switch (present) {
        .string => |string| string,
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
        else => null,
    };
}

fn appendOwnedWarning(allocator: std.mem.Allocator, warnings: *std.ArrayList([]const u8), warning: []const u8) !void {
    for (warnings.items) |existing| {
        if (std.mem.eql(u8, existing, warning)) return;
    }
    try warnings.append(allocator, try allocator.dupe(u8, warning));
}

fn freeStringList(allocator: std.mem.Allocator, strings: []const []const u8) void {
    for (strings) |string| allocator.free(string);
    allocator.free(strings);
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var index: usize = 0;
    while (index + needle.len <= haystack.len) : (index += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[index .. index + needle.len], needle)) return true;
    }
    return false;
}

fn stripPrefixIgnoreCase(text: []const u8, prefix: []const u8) []const u8 {
    if (!startsWithIgnoreCase(text, prefix)) return text;
    return std.mem.trim(u8, text[prefix.len..], " \t\r\n:,-");
}

fn startsWithIgnoreCase(text: []const u8, prefix: []const u8) bool {
    return text.len >= prefix.len and std.ascii.eqlIgnoreCase(text[0..prefix.len], prefix);
}

fn isUnsupportedAnswer(answer: []const u8) bool {
    return answer.len == 0 or
        std.ascii.eqlIgnoreCase(answer, "i don't know") or
        std.ascii.eqlIgnoreCase(answer, "i do not know") or
        containsIgnoreCase(answer, "not enough information") or
        containsIgnoreCase(answer, "cannot determine");
}

fn isQuantityQuestion(query: []const u8) bool {
    return containsIgnoreCase(query, "how many") or
        containsIgnoreCase(query, "how much") or
        containsIgnoreCase(query, "how long") or
        containsIgnoreCase(query, "total") or
        containsIgnoreCase(query, "count");
}

fn singleAmount(text: []const u8) ?[]const u8 {
    var first: ?[]const u8 = null;
    var index: usize = 0;
    while (index < text.len) : (index += 1) {
        if (text[index] != '$') continue;
        const start = index;
        index += 1;
        while (index < text.len) : (index += 1) {
            if (std.ascii.isDigit(text[index]) or text[index] == ',') continue;
            if (text[index] == '.' and index + 1 < text.len and std.ascii.isDigit(text[index + 1])) continue;
            break;
        }
        if (index == start + 1) continue;
        if (first != null) return null;
        first = text[start..index];
    }
    return first;
}

fn singleInteger(text: []const u8) ?[]const u8 {
    var first: ?[]const u8 = null;
    var index: usize = 0;
    while (index < text.len) {
        while (index < text.len and !std.ascii.isDigit(text[index])) : (index += 1) {}
        if (index >= text.len) break;
        const start = index;
        while (index < text.len and std.ascii.isDigit(text[index])) : (index += 1) {}
        if (first != null) return null;
        first = text[start..index];
    }
    return first;
}

fn singleIsoDate(text: []const u8) ?[]const u8 {
    var first: ?[]const u8 = null;
    if (text.len < 10) return null;
    var index: usize = 0;
    while (index + 10 <= text.len) : (index += 1) {
        const slice = text[index .. index + 10];
        if (!std.ascii.isDigit(slice[0]) or !std.ascii.isDigit(slice[1]) or !std.ascii.isDigit(slice[2]) or !std.ascii.isDigit(slice[3])) continue;
        if (slice[4] != '-' or slice[7] != '-') continue;
        if (!std.ascii.isDigit(slice[5]) or !std.ascii.isDigit(slice[6]) or !std.ascii.isDigit(slice[8]) or !std.ascii.isDigit(slice[9])) continue;
        if (first != null) return null;
        first = slice;
    }
    return first;
}

test "routes synthesis strategies" {
    const items = [_]EvidenceItem{.{
        .qid = "q_msg_1",
        .type = "preference",
        .text = "The user prefers detailed responses.",
    }};

    try std.testing.expectEqualStrings("preference", routeStrategy("What response style do I prefer?", &items));
    try std.testing.expectEqualStrings("multi_session", routeStrategy("How many tickets did I buy across sessions?", &items));
    try std.testing.expectEqualStrings("temporal", routeStrategy("What was the hotel before February?", &items));
}

test "parses provider JSON answer" {
    var parsed = try parseProviderAnswer(
        std.testing.allocator,
        "{\"answer\":\"Lakeside Suites\",\"answerable\":true,\"supportQids\":[\"q_msg_2\"],\"strategy\":\"knowledge_update\",\"confidence\":0.91}",
    );
    defer parsed.deinit();

    try std.testing.expectEqualStrings("Lakeside Suites", parsed.answer);
    try std.testing.expect(parsed.answerable);
    try std.testing.expectEqualStrings("q_msg_2", parsed.supportQids[0]);
    try std.testing.expectEqualStrings("knowledge_update", parsed.strategy);
}

test "validates support qids and abstains when weak" {
    const items = [_]EvidenceItem{.{
        .qid = "q_msg_1",
        .type = "message",
        .text = "The hotel is Harbor Inn.",
    }};
    var result = try synthesize(
        std.testing.allocator,
        "What is the rental car company?",
        &items,
        "{\"answer\":\"Avis\",\"answerable\":true,\"supportQids\":[\"q_msg_missing\"],\"strategy\":\"span_extract\",\"confidence\":0.7}",
        true,
    );
    defer result.deinit();

    try std.testing.expectEqualStrings("[abstain]", result.answer);
    try std.testing.expectEqualStrings("abstained", result.trace.validation.status);
}

test "builds simple aggregation candidates" {
    const items = [_]EvidenceItem{
        .{ .qid = "q_msg_1", .type = "message", .text = "I bought 2 train tickets." },
        .{ .qid = "q_msg_2", .type = "message", .text = "I bought 3 more train tickets." },
    };
    var result = try synthesize(std.testing.allocator, "How many train tickets in total?", &items, null, false);
    defer result.deinit();

    try std.testing.expectEqualStrings("5", result.answer);
    try std.testing.expectEqualStrings("multi_session", result.trace.strategy);
}

test "normalizes numeric and amount answers" {
    const count = try normalizeAnswerText(std.testing.allocator, "How many invoices?", "The answer is 7 invoices.");
    defer std.testing.allocator.free(count);
    try std.testing.expectEqualStrings("7", count);

    const amount = try normalizeAnswerText(std.testing.allocator, "How much was the total?", "Final answer: $1,240.");
    defer std.testing.allocator.free(amount);
    try std.testing.expectEqualStrings("$1,240", amount);
}
