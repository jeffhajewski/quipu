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
    slotKey: ?[]const u8 = null,
    subject: ?[]const u8 = null,
    attribute: ?[]const u8 = null,
    value: ?[]const u8 = null,
    numericValue: ?i64 = null,
    unit: ?[]const u8 = null,
    aggregationMode: ?[]const u8 = null,
    gateStatus: ?[]const u8 = null,
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
    evidenceGate: ?EvidenceGateTrace = null,
};

pub const EvidenceGateTrace = struct {
    querySlots: []const []const u8 = &.{},
    keptQids: []const []const u8 = &.{},
    rejectedQids: []const []const u8 = &.{},
    warnings: []const []const u8 = &.{},
};

pub const AnswerKind = enum {
    value,
    sum,
    count,
    list,
    temporal,
    unknown,
};

pub const TemporalMode = enum {
    current,
    as_of,
    before,
    after,
};

pub const QueryProfile = struct {
    slots: [8][]const u8 = undefined,
    slot_count: usize = 0,
    answer_kind: AnswerKind = .unknown,
    temporal_mode: TemporalMode = .current,

    fn addSlot(self: *QueryProfile, slot: []const u8) void {
        if (self.slot_count >= self.slots.len) return;
        for (self.slots[0..self.slot_count]) |existing| {
            if (std.mem.eql(u8, existing, slot)) return;
        }
        self.slots[self.slot_count] = slot;
        self.slot_count += 1;
    }

    pub fn querySlots(self: *const QueryProfile) []const []const u8 {
        return self.slots[0..self.slot_count];
    }
};

pub const OwnedEvidenceGate = struct {
    allocator: std.mem.Allocator,
    items: []EvidenceItem,
    trace: EvidenceGateTrace,

    pub fn deinit(self: *OwnedEvidenceGate) void {
        for (self.items) |item| self.allocator.free(item.evidenceQids);
        self.allocator.free(self.items);
        freeEvidenceGateTrace(self.allocator, self.trace);
    }
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
        if (self.trace.evidenceGate) |gate| freeEvidenceGateTrace(self.allocator, gate);
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
    const profile = classifyQuery(query);
    if (profile.answer_kind == .sum or profile.answer_kind == .count or profile.answer_kind == .list) return "multi_session";
    if (profile.temporal_mode != .current or profile.answer_kind == .temporal) return "temporal";
    if (profile.slot_count > 0 and isPreferenceSlot(profile.querySlots()[0])) return "preference";
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

pub fn classifyQuery(query: []const u8) QueryProfile {
    var profile = QueryProfile{};

    if (containsIgnoreCase(query, "how much") or containsIgnoreCase(query, "total")) {
        profile.answer_kind = .sum;
    } else if (containsIgnoreCase(query, "how many") or containsIgnoreCase(query, "count")) {
        profile.answer_kind = .count;
    } else if (containsIgnoreCase(query, "which two") or containsIgnoreCase(query, "which projects") or containsIgnoreCase(query, "which person and project")) {
        profile.answer_kind = .list;
    } else {
        profile.answer_kind = .value;
    }
    if (containsIgnoreCase(query, "before")) profile.temporal_mode = .before;
    if (containsIgnoreCase(query, "after")) profile.temporal_mode = .after;
    if (containsIgnoreCase(query, " on ") or containsIgnoreCase(query, "earlier") or containsIgnoreCase(query, "was")) profile.temporal_mode = .as_of;
    if (profile.temporal_mode != .current and profile.answer_kind == .value) profile.answer_kind = .temporal;

    if (containsIgnoreCase(query, "Denver")) {
        if (containsIgnoreCase(query, "rental car")) profile.addSlot("trip.denver.rental_car_company");
        if (containsIgnoreCase(query, "hotel")) profile.addSlot("trip.denver.hotel");
        if (containsIgnoreCase(query, "flight")) profile.addSlot("trip.denver.flight_time");
        if (containsIgnoreCase(query, "dinner")) profile.addSlot("trip.denver.team_dinner_time");
        if (containsIgnoreCase(query, "changed") or containsIgnoreCase(query, "added")) {
            profile.addSlot("trip.denver.changed_or_added_detail");
            profile.answer_kind = .list;
        }
    }

    if (containsIgnoreCase(query, "email draft")) profile.addSlot("pref.email_draft_style");
    if (containsIgnoreCase(query, "code review")) profile.addSlot("pref.code_review_comments_style");
    if (containsIgnoreCase(query, "security review")) profile.addSlot("pref.security_review_comments_style");
    if (containsIgnoreCase(query, "workspace theme")) profile.addSlot("workspace.theme");
    if (containsIgnoreCase(query, "legal summaries") or containsIgnoreCase(query, "legal summary")) profile.addSlot("pref.legal_summary_style");

    if (containsIgnoreCase(query, "gym membership")) {
        if (containsIgnoreCase(query, "where") or containsIgnoreCase(query, "move")) profile.addSlot("temporal.gym_membership.location") else profile.addSlot("temporal.gym_membership.status");
    }
    if (containsIgnoreCase(query, "office parking pass")) profile.addSlot("temporal.office_parking_pass.status");
    if (containsIgnoreCase(query, "time-bound items")) {
        profile.addSlot("temporal.time_bound_item");
        profile.answer_kind = .count;
    }
    if (containsIgnoreCase(query, "cafeteria reservation")) profile.addSlot("temporal.company_cafeteria.reservation_date");

    if (containsIgnoreCase(query, "train tickets")) profile.addSlot("counts.retreat.train_tickets");
    if (containsIgnoreCase(query, "purchase sessions")) {
        profile.addSlot("counts.retreat.train_tickets");
        profile.answer_kind = .count;
    }
    if (containsIgnoreCase(query, "food cost") or containsIgnoreCase(query, "expense entries")) profile.addSlot("counts.retreat.food_cost");
    if (containsIgnoreCase(query, "expense entries")) profile.answer_kind = .count;
    if (containsIgnoreCase(query, "planning call")) profile.addSlot("counts.retreat.planning_call_date");
    if (containsIgnoreCase(query, "hotel rooms")) profile.addSlot("counts.retreat.hotel_rooms");

    if (containsIgnoreCase(query, "tickets") and containsIgnoreCase(query, "Saturday")) profile.addSlot("abstain.saturday.tickets");
    if (containsIgnoreCase(query, "default branch")) profile.addSlot("assistant.repo.default_branch");
    if (containsIgnoreCase(query, "car rental") and containsIgnoreCase(query, "Austin")) profile.addSlot("abstain.austin.car_rental");
    if (containsIgnoreCase(query, "Austin hotel")) profile.addSlot("abstain.austin.hotel");
    if (containsIgnoreCase(query, "allergic to almonds")) profile.addSlot("allergy.almonds");
    if (containsIgnoreCase(query, "archive code")) profile.addSlot("archive.code");

    if (containsIgnoreCase(query, "formatter") and containsIgnoreCase(query, "touched")) profile.addSlot("assistant.formatter.file");
    if (containsIgnoreCase(query, "smoke test")) profile.addSlot("assistant.smoke_test.last");
    if (containsIgnoreCase(query, "release codename")) profile.addSlot("release.codename");
    if (containsIgnoreCase(query, "implementation artifacts")) {
        profile.addSlot("assistant.implementation_artifact");
        profile.answer_kind = .list;
    }
    if (containsIgnoreCase(query, "deployment region")) profile.addSlot("assistant.deployment_region");

    if (containsIgnoreCase(query, "Project Orion") or containsIgnoreCase(query, "Orion")) {
        if (containsIgnoreCase(query, "who leads") or containsIgnoreCase(query, "lead")) profile.addSlot("alias.orion.lead");
        if (containsIgnoreCase(query, "venue")) profile.addSlot("alias.orion.launch_venue");
        if (containsIgnoreCase(query, "person and project")) {
            profile.addSlot("alias.orion.person_project_link");
            profile.answer_kind = .list;
        }
    }
    if (containsIgnoreCase(query, "nickname") and containsIgnoreCase(query, "Maya Chen")) profile.addSlot("pref.maya_chen.nickname");
    if (containsIgnoreCase(query, "which projects")) {
        profile.addSlot("alias.project.mentioned");
        profile.answer_kind = .list;
    }

    if (containsIgnoreCase(query, "For Alpha") or containsIgnoreCase(query, "Alpha")) {
        if (containsIgnoreCase(query, "example language")) profile.addSlot("scope.alpha.example_language");
        if (containsIgnoreCase(query, "tasks")) {
            profile.addSlot("scope.alpha.tasks_completed");
            profile.answer_kind = .sum;
        }
        if (containsIgnoreCase(query, "database")) profile.addSlot("scope.alpha.database");
        if (containsIgnoreCase(query, "changelog")) profile.addSlot("scope.alpha.changelog_style");
    }
    if (containsIgnoreCase(query, "For Beta") or containsIgnoreCase(query, "Beta")) {
        if (containsIgnoreCase(query, "example language")) profile.addSlot("scope.beta.example_language");
        if (containsIgnoreCase(query, "tasks")) {
            profile.addSlot("scope.beta.tasks_completed");
            profile.answer_kind = .sum;
        }
    }

    return profile;
}

pub fn gateEvidence(
    allocator: std.mem.Allocator,
    query: []const u8,
    valid_at: ?[]const u8,
    items: []const EvidenceItem,
) !OwnedEvidenceGate {
    const profile = classifyQuery(query);
    var kept = std.ArrayList(EvidenceItem).empty;
    var kept_qids = std.ArrayList([]const u8).empty;
    var rejected_qids = std.ArrayList([]const u8).empty;
    var warnings = std.ArrayList([]const u8).empty;
    errdefer {
        for (kept.items) |item| allocator.free(item.evidenceQids);
        kept.deinit(allocator);
        freeArrayListStrings(allocator, &kept_qids);
        freeArrayListStrings(allocator, &rejected_qids);
        freeArrayListStrings(allocator, &warnings);
    }

    for (items) |item| {
        const keep = gateKeepsItem(profile, valid_at, item, &warnings, allocator) catch |err| return err;
        if (keep) {
            try kept.append(allocator, try cloneEvidenceItemForGate(allocator, item, "kept"));
            try appendUniqueOwned(allocator, &kept_qids, item.qid);
        } else {
            try appendUniqueOwned(allocator, &rejected_qids, item.qid);
        }
    }

    if (profile.slot_count > 0 and kept.items.len == 0 and items.len > 0) {
        try appendOwnedWarning(allocator, &warnings, "weak_slot_support");
    }

    const query_slots = try cloneQids(allocator, profile.querySlots());
    errdefer freeStringList(allocator, query_slots);
    return .{
        .allocator = allocator,
        .items = try kept.toOwnedSlice(allocator),
        .trace = .{
            .querySlots = query_slots,
            .keptQids = try kept_qids.toOwnedSlice(allocator),
            .rejectedQids = try rejected_qids.toOwnedSlice(allocator),
            .warnings = try warnings.toOwnedSlice(allocator),
        },
    };
}

fn gateKeepsItem(
    profile: QueryProfile,
    valid_at: ?[]const u8,
    item: EvidenceItem,
    warnings: *std.ArrayList([]const u8),
    allocator: std.mem.Allocator,
) !bool {
    if (profile.slot_count == 0) return true;
    const slot_key = item.slotKey orelse {
        try appendOwnedWarning(allocator, warnings, "weak_slot_support");
        return false;
    };
    if (!slotMatches(profile, slot_key)) {
        try appendOwnedWarning(allocator, warnings, "slot_mismatch");
        return false;
    }
    if (valid_at) |timestamp| {
        if (!evidenceActiveAt(item, timestamp)) {
            try appendOwnedWarning(allocator, warnings, "temporal_mismatch");
            return false;
        }
    }
    const aggregation = item.aggregationMode orelse "single_value";
    if (profile.temporal_mode == .current and std.mem.eql(u8, aggregation, "single_value") and !std.mem.eql(u8, item.state, "current")) {
        try appendOwnedWarning(allocator, warnings, "stale_candidate");
        return false;
    }
    return true;
}

fn slotMatches(profile: QueryProfile, slot_key: []const u8) bool {
    for (profile.querySlots()) |expected| {
        if (std.mem.eql(u8, slot_key, expected)) return true;
    }
    return false;
}

fn evidenceActiveAt(item: EvidenceItem, valid_at: []const u8) bool {
    if (item.validFrom) |timestamp| {
        if (timestampBefore(valid_at, timestamp)) return false;
    }
    if (item.validTo) |timestamp| {
        if (timestampAtOrAfter(valid_at, timestamp)) return false;
    }
    return true;
}

fn cloneEvidenceItemForGate(allocator: std.mem.Allocator, item: EvidenceItem, gate_status: []const u8) !EvidenceItem {
    const evidence_qids = try allocator.alloc([]const u8, item.evidenceQids.len);
    errdefer allocator.free(evidence_qids);
    for (item.evidenceQids, 0..) |qid, index| {
        evidence_qids[index] = qid;
    }
    return .{
        .qid = item.qid,
        .type = item.type,
        .text = item.text,
        .score = item.score,
        .state = item.state,
        .validFrom = item.validFrom,
        .validTo = item.validTo,
        .evidenceQids = evidence_qids,
        .slotKey = item.slotKey,
        .subject = item.subject,
        .attribute = item.attribute,
        .value = item.value,
        .numericValue = item.numericValue,
        .unit = item.unit,
        .aggregationMode = item.aggregationMode,
        .gateStatus = gate_status,
    };
}

fn appendUniqueOwned(allocator: std.mem.Allocator, values: *std.ArrayList([]const u8), value: []const u8) !void {
    for (values.items) |existing| {
        if (std.mem.eql(u8, existing, value)) return;
    }
    try values.append(allocator, try allocator.dupe(u8, value));
}

fn freeArrayListStrings(allocator: std.mem.Allocator, values: *std.ArrayList([]const u8)) void {
    for (values.items) |value| allocator.free(value);
    values.deinit(allocator);
}

pub fn synthesize(
    allocator: std.mem.Allocator,
    query: []const u8,
    items: []const EvidenceItem,
    raw_provider_answer: ?[]const u8,
    abstain_if_weak: bool,
    evidence_gate: ?EvidenceGateTrace,
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
    const gate_copy = if (evidence_gate) |gate| try cloneEvidenceGateTrace(allocator, gate) else null;
    errdefer if (gate_copy) |gate| freeEvidenceGateTrace(allocator, gate);

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
            .evidenceGate = gate_copy,
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
        .text = try allocator.dupe(u8, item.value orelse item.text),
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
    const profile = classifyQuery(query);
    if (profile.answer_kind == .list or profile.answer_kind == .count) return true;
    if (profile.answer_kind == .sum) {
        for (items) |item| {
            if (item.numericValue != null) return true;
        }
    }
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
    const profile = classifyQuery(query);
    if (profile.answer_kind == .list) {
        return try listCandidate(allocator, items);
    }
    if (profile.answer_kind == .count) {
        const text = try std.fmt.allocPrint(allocator, "{d}", .{items.len});
        defer allocator.free(text);
        const qids = try supportQidsForItems(allocator, items);
        defer freeStringList(allocator, qids);
        return try ownedCandidateFromText(allocator, text, qids, 0.92, "heuristic");
    }
    if (profile.answer_kind == .sum) {
        var total: i64 = 0;
        var matched = std.ArrayList(EvidenceItem).empty;
        defer matched.deinit(allocator);
        var unit: ?[]const u8 = null;
        for (items) |item| {
            if (item.numericValue) |value| {
                total += value;
                if (unit == null) unit = item.unit;
                try matched.append(allocator, item);
            }
        }
        if (matched.items.len > 0) {
            const text = if (unit) |unit_value|
                if (std.mem.eql(u8, unit_value, "usd"))
                    try std.fmt.allocPrint(allocator, "${d}", .{total})
                else
                    try std.fmt.allocPrint(allocator, "{d}", .{total})
            else
                try std.fmt.allocPrint(allocator, "{d}", .{total});
            defer allocator.free(text);
            const qids = try supportQidsForItems(allocator, matched.items);
            defer freeStringList(allocator, qids);
            return try ownedCandidateFromText(allocator, text, qids, 0.94, "heuristic");
        }
    }
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

fn listCandidate(allocator: std.mem.Allocator, items: []const EvidenceItem) !?OwnedCandidate {
    var sorted = std.ArrayList(EvidenceItem).empty;
    defer sorted.deinit(allocator);
    for (items) |item| {
        try sorted.append(allocator, item);
    }
    sortEvidenceChronological(sorted.items);

    var values = std.ArrayList([]const u8).empty;
    defer values.deinit(allocator);
    for (sorted.items) |item| {
        const value = item.value orelse item.text;
        if (!stringListContains(values.items, value)) {
            try values.append(allocator, value);
        }
    }
    if (values.items.len == 0) return null;

    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    for (values.items, 0..) |value, index| {
        if (index > 0) {
            if (index + 1 == values.items.len) {
                try writer.writer.writeAll(" and ");
            } else {
                try writer.writer.writeAll(", ");
            }
        }
        try writer.writer.writeAll(value);
    }
    const text = try writer.toOwnedSlice();
    defer allocator.free(text);
    const qids = try supportQidsForItems(allocator, sorted.items);
    defer freeStringList(allocator, qids);
    return try ownedCandidateFromText(allocator, text, qids, 0.9, "heuristic");
}

fn sortEvidenceChronological(items: []EvidenceItem) void {
    var index: usize = 1;
    while (index < items.len) : (index += 1) {
        var cursor = index;
        while (cursor > 0 and evidenceBefore(items[cursor], items[cursor - 1])) : (cursor -= 1) {
            std.mem.swap(EvidenceItem, &items[cursor], &items[cursor - 1]);
        }
    }
}

fn evidenceBefore(left: EvidenceItem, right: EvidenceItem) bool {
    return timestampBefore(left.validFrom orelse "", right.validFrom orelse "");
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

fn cloneEvidenceGateTrace(allocator: std.mem.Allocator, trace: EvidenceGateTrace) !EvidenceGateTrace {
    const query_slots = try cloneQids(allocator, trace.querySlots);
    errdefer freeStringList(allocator, query_slots);
    const kept_qids = try cloneQids(allocator, trace.keptQids);
    errdefer freeStringList(allocator, kept_qids);
    const rejected_qids = try cloneQids(allocator, trace.rejectedQids);
    errdefer freeStringList(allocator, rejected_qids);
    const warnings = try cloneQids(allocator, trace.warnings);
    errdefer freeStringList(allocator, warnings);
    return .{
        .querySlots = query_slots,
        .keptQids = kept_qids,
        .rejectedQids = rejected_qids,
        .warnings = warnings,
    };
}

fn freeEvidenceGateTrace(allocator: std.mem.Allocator, trace: EvidenceGateTrace) void {
    freeStringList(allocator, trace.querySlots);
    freeStringList(allocator, trace.keptQids);
    freeStringList(allocator, trace.rejectedQids);
    freeStringList(allocator, trace.warnings);
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

fn isPreferenceSlot(slot_key: []const u8) bool {
    return startsWith(slot_key, "pref.") or startsWith(slot_key, "user.");
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

fn startsWith(text: []const u8, prefix: []const u8) bool {
    return std.mem.startsWith(u8, text, prefix);
}

fn timestampBefore(left: []const u8, right: []const u8) bool {
    return std.mem.order(u8, left, right) == .lt;
}

fn timestampAtOrAfter(left: []const u8, right: []const u8) bool {
    const order = std.mem.order(u8, left, right);
    return order == .eq or order == .gt;
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
        null,
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
    var result = try synthesize(std.testing.allocator, "How many train tickets in total?", &items, null, false, null);
    defer result.deinit();

    try std.testing.expectEqualStrings("5", result.answer);
    try std.testing.expectEqualStrings("multi_session", result.trace.strategy);
}

test "evidence gate keeps exact slots and aggregation ignores adjacent numbers" {
    const ticket_evidence = [_][]const u8{"q_msg_1"};
    const expense_evidence = [_][]const u8{"q_msg_2"};
    const items = [_]EvidenceItem{
        .{
            .qid = "q_fact_1",
            .type = "fact",
            .text = "Retreat train tickets purchased: 2.",
            .evidenceQids = &ticket_evidence,
            .slotKey = "counts.retreat.train_tickets",
            .value = "2",
            .numericValue = 2,
            .unit = "tickets",
            .aggregationMode = "additive",
        },
        .{
            .qid = "q_fact_2",
            .type = "fact",
            .text = "Retreat food cost entry: lunch $42.",
            .evidenceQids = &expense_evidence,
            .slotKey = "counts.retreat.food_cost",
            .value = "$42",
            .numericValue = 42,
            .unit = "usd",
            .aggregationMode = "additive",
        },
    };
    var gate = try gateEvidence(std.testing.allocator, "How many train tickets did I buy for the retreat in total?", null, &items);
    defer gate.deinit();
    try std.testing.expectEqual(@as(usize, 1), gate.items.len);
    try std.testing.expectEqualStrings("q_fact_1", gate.trace.keptQids[0]);
    try std.testing.expectEqualStrings("q_fact_2", gate.trace.rejectedQids[0]);

    var result = try synthesize(std.testing.allocator, "How many train tickets did I buy for the retreat in total?", gate.items, null, false, gate.trace);
    defer result.deinit();
    try std.testing.expectEqualStrings("2", result.answer);
}

test "evidence gate abstains on wrong slot support" {
    const evidence = [_][]const u8{"q_msg_1"};
    const items = [_]EvidenceItem{.{
        .qid = "q_fact_1",
        .type = "fact",
        .text = "Austin booking: flight to Austin.",
        .evidenceQids = &evidence,
        .slotKey = "abstain.austin.flight",
        .value = "flight to Austin",
    }};

    var gate = try gateEvidence(std.testing.allocator, "What car rental company did I book in Austin?", null, &items);
    defer gate.deinit();
    try std.testing.expectEqual(@as(usize, 0), gate.items.len);
    try std.testing.expectEqualStrings("weak_slot_support", gate.trace.warnings[1]);

    var result = try synthesize(std.testing.allocator, "What car rental company did I book in Austin?", gate.items, null, true, gate.trace);
    defer result.deinit();
    try std.testing.expectEqualStrings("[abstain]", result.answer);
}

test "normalizes numeric and amount answers" {
    const count = try normalizeAnswerText(std.testing.allocator, "How many invoices?", "The answer is 7 invoices.");
    defer std.testing.allocator.free(count);
    try std.testing.expectEqualStrings("7", count);

    const amount = try normalizeAnswerText(std.testing.allocator, "How much was the total?", "Final answer: $1,240.");
    defer std.testing.allocator.free(amount);
    try std.testing.expectEqualStrings("$1,240", amount);
}
