const std = @import("std");

pub const Label = enum {
    fact,
    preference,
    procedure,
};

pub const Candidate = struct {
    label: Label,
    slot_key: []const u8,
    value: []const u8,
    text: []const u8,
};

pub const CandidateList = struct {
    items: [8]Candidate = undefined,
    len: usize = 0,

    pub fn append(self: *CandidateList, candidate: Candidate) void {
        if (self.len >= self.items.len) return;
        self.items[self.len] = candidate;
        self.len += 1;
    }
};

pub const ValidationError = error{
    EmptySlot,
    EmptyValue,
    EmptyText,
    SlotLabelMismatch,
};

pub const DeterministicExtractor = struct {
    pub fn extract(content: []const u8) CandidateList {
        var candidates = CandidateList{};

        if (extractPackageManager(content)) |package_manager| {
            candidates.append(.{
                .label = .fact,
                .slot_key = "project.package_manager",
                .value = package_manager,
                .text = if (std.mem.eql(u8, package_manager, "pnpm"))
                    "The repo uses pnpm as its package manager."
                else
                    "The repo uses npm as its package manager.",
            });
        }

        if (extractTestCommand(content)) |test_command| {
            candidates.append(.{
                .label = .procedure,
                .slot_key = "project.test_command",
                .value = test_command,
                .text = if (std.mem.eql(u8, test_command, "just test"))
                    "Run just test before committing."
                else if (std.mem.eql(u8, test_command, "pnpm test"))
                    "Run pnpm test before committing."
                else
                    "Run npm test before committing.",
            });
        }

        if (extractRepoStyle(content)) |repo_style| {
            candidates.append(.{
                .label = .fact,
                .slot_key = "project.repo_style",
                .value = repo_style,
                .text = if (std.mem.eql(u8, repo_style, "local_first"))
                    "The repo style emphasizes local-first runtime behavior."
                else if (std.mem.eql(u8, repo_style, "thin_sdks"))
                    "The repo style keeps SDKs thin and daemon-backed."
                else
                    "The repo style favors small public APIs.",
            });
        }

        if (extractProjectConstraint(content)) |constraint| {
            candidates.append(.{
                .label = .fact,
                .slot_key = "project.constraint",
                .value = constraint,
                .text = if (std.mem.eql(u8, constraint, "evidence_backed"))
                    "Derived memory must stay evidence-backed."
                else if (std.mem.eql(u8, constraint, "forgetting_propagates"))
                    "Forgetting must propagate to derived memory."
                else
                    "SDKs must not duplicate daemon memory semantics.",
            });
        }

        if (extractResponseStyle(content)) |style| {
            candidates.append(.{
                .label = .preference,
                .slot_key = "user.response_style",
                .value = style,
                .text = if (std.mem.eql(u8, style, "concise"))
                    "The user prefers concise responses."
                else
                    "The user prefers detailed responses.",
            });
        }

        return candidates;
    }
};

pub fn validateCandidate(candidate: Candidate) ValidationError!void {
    if (candidate.slot_key.len == 0) return error.EmptySlot;
    if (candidate.value.len == 0) return error.EmptyValue;
    if (candidate.text.len == 0) return error.EmptyText;
    if (!slotAllowedForLabel(candidate.label, candidate.slot_key)) return error.SlotLabelMismatch;
}

pub fn labelName(label: Label) []const u8 {
    return switch (label) {
        .fact => "Fact",
        .preference => "Preference",
        .procedure => "Procedure",
    };
}

pub fn qidPrefix(label: Label) []const u8 {
    return switch (label) {
        .fact => "fact",
        .preference => "pref",
        .procedure => "proc",
    };
}

fn slotAllowedForLabel(label: Label, slot_key: []const u8) bool {
    return switch (label) {
        .fact => std.mem.eql(u8, slot_key, "project.package_manager") or
            std.mem.eql(u8, slot_key, "project.repo_style") or
            std.mem.eql(u8, slot_key, "project.constraint"),
        .preference => std.mem.eql(u8, slot_key, "user.response_style"),
        .procedure => std.mem.eql(u8, slot_key, "project.test_command"),
    };
}

fn extractPackageManager(content: []const u8) ?[]const u8 {
    if (containsIgnoreCase(content, "pnpm")) return "pnpm";
    if (containsIgnoreCase(content, "npm")) return "npm";
    return null;
}

fn extractTestCommand(content: []const u8) ?[]const u8 {
    if (containsIgnoreCase(content, "just test")) return "just test";
    if (containsIgnoreCase(content, "pnpm test")) return "pnpm test";
    if (containsIgnoreCase(content, "npm test")) return "npm test";
    return null;
}

fn extractRepoStyle(content: []const u8) ?[]const u8 {
    if (containsIgnoreCase(content, "local-first") or containsIgnoreCase(content, "local first")) return "local_first";
    if (containsIgnoreCase(content, "thin SDK") or containsIgnoreCase(content, "thin TypeScript") or containsIgnoreCase(content, "thin Python")) return "thin_sdks";
    if (containsIgnoreCase(content, "small public API") or containsIgnoreCase(content, "small public APIs")) return "small_public_api";
    return null;
}

fn extractProjectConstraint(content: []const u8) ?[]const u8 {
    if (containsIgnoreCase(content, "evidence-backed") or containsIgnoreCase(content, "links to evidence")) return "evidence_backed";
    if (containsIgnoreCase(content, "forgetting propagates") or containsIgnoreCase(content, "forgetting must propagate")) return "forgetting_propagates";
    if (containsIgnoreCase(content, "SDKs do not duplicate") or containsIgnoreCase(content, "SDKs must not duplicate")) return "daemon_semantics";
    return null;
}

fn extractResponseStyle(content: []const u8) ?[]const u8 {
    if (containsIgnoreCase(content, "prefer concise") or
        containsIgnoreCase(content, "be concise") or
        containsIgnoreCase(content, "concise responses") or
        containsIgnoreCase(content, "response style: concise") or
        containsIgnoreCase(content, "response-style: concise") or
        containsIgnoreCase(content, "brief responses"))
    {
        return "concise";
    }
    if (containsIgnoreCase(content, "prefer detailed") or
        containsIgnoreCase(content, "be detailed") or
        containsIgnoreCase(content, "detailed responses") or
        containsIgnoreCase(content, "response style: detailed") or
        containsIgnoreCase(content, "response-style: detailed"))
    {
        return "detailed";
    }
    return null;
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

test "deterministic extractor emits facts procedures and preferences" {
    const candidates = DeterministicExtractor.extract("This repo uses pnpm. Run just test before committing. Repo style is local-first and evidence-backed. Please be concise.");

    try std.testing.expectEqual(@as(usize, 5), candidates.len);
    try std.testing.expectEqual(Label.fact, candidates.items[0].label);
    try std.testing.expectEqualStrings("project.package_manager", candidates.items[0].slot_key);
    try std.testing.expectEqual(Label.procedure, candidates.items[1].label);
    try std.testing.expectEqualStrings("project.test_command", candidates.items[1].slot_key);
    try std.testing.expectEqual(Label.fact, candidates.items[2].label);
    try std.testing.expectEqualStrings("project.repo_style", candidates.items[2].slot_key);
    try std.testing.expectEqual(Label.fact, candidates.items[3].label);
    try std.testing.expectEqualStrings("project.constraint", candidates.items[3].slot_key);
    try std.testing.expectEqual(Label.preference, candidates.items[4].label);
    try std.testing.expectEqualStrings("user.response_style", candidates.items[4].slot_key);
}

test "candidate validation rejects label slot mismatch" {
    const invalid = Candidate{
        .label = .fact,
        .slot_key = "user.response_style",
        .value = "concise",
        .text = "The user prefers concise responses.",
    };

    try std.testing.expectError(error.SlotLabelMismatch, validateCandidate(invalid));
}
