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
    items: [4]Candidate = undefined,
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
        .fact => std.mem.eql(u8, slot_key, "project.package_manager"),
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

fn extractResponseStyle(content: []const u8) ?[]const u8 {
    if (containsIgnoreCase(content, "prefer concise") or
        containsIgnoreCase(content, "be concise") or
        containsIgnoreCase(content, "concise responses"))
    {
        return "concise";
    }
    if (containsIgnoreCase(content, "prefer detailed") or
        containsIgnoreCase(content, "be detailed") or
        containsIgnoreCase(content, "detailed responses"))
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
    const candidates = DeterministicExtractor.extract("This repo uses pnpm. Run just test before committing. Please be concise.");

    try std.testing.expectEqual(@as(usize, 3), candidates.len);
    try std.testing.expectEqual(Label.fact, candidates.items[0].label);
    try std.testing.expectEqualStrings("project.package_manager", candidates.items[0].slot_key);
    try std.testing.expectEqual(Label.procedure, candidates.items[1].label);
    try std.testing.expectEqualStrings("project.test_command", candidates.items[1].slot_key);
    try std.testing.expectEqual(Label.preference, candidates.items[2].label);
    try std.testing.expectEqualStrings("user.response_style", candidates.items[2].slot_key);
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
