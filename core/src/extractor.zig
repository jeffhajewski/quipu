const std = @import("std");

pub const Label = enum {
    fact,
    preference,
    procedure,
};

pub const Candidate = struct {
    label: Label,
    slot_key: []const u8,
    subject: []const u8 = "",
    attribute: []const u8 = "",
    value: []const u8,
    numeric_value: ?i64 = null,
    unit: ?[]const u8 = null,
    aggregation_mode: []const u8 = "single_value",
    valid_from: ?[]const u8 = null,
    valid_to: ?[]const u8 = null,
    text: []const u8,
};

pub const CandidateList = struct {
    items: [32]Candidate = undefined,
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
                .subject = "project",
                .attribute = "package_manager",
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
                .subject = "project",
                .attribute = "test_command",
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
                .subject = "project",
                .attribute = "repo_style",
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
                .subject = "project",
                .attribute = "constraint",
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
                .subject = "user",
                .attribute = "response_style",
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

// Generic rules. Every match is case-insensitive and word-bounded, so "npm" no
// longer fires inside "pnpm" or "npmjs" and "just test" no longer fires inside
// "adjust test". Tool and command rules also require a usage cue.

const usage_cues = [_][]const u8{ "use", "uses", "using", "prefer", "prefers", "to" };
const command_cues = [_][]const u8{ "run", "runs", "running", "use", "execute" };
const preference_verbs = [_][]const u8{ "prefer", "prefers", "want", "like" };

fn extractPackageManager(content: []const u8) ?[]const u8 {
    if (toolUsed(content, "pnpm")) return "pnpm";
    if (toolUsed(content, "npm")) return "npm";
    return null;
}

/// A package manager counts when it directly follows a usage cue ("uses npm",
/// "switched to pnpm") or the text explicitly talks about a package manager.
fn toolUsed(content: []const u8, tool: []const u8) bool {
    var start: usize = 0;
    while (findWordPhrase(content, tool, start)) |index| {
        start = index + tool.len;
        if (precedingWord(content, index)) |word| {
            if (eqlAnyIgnoreCase(word, &usage_cues)) return true;
        }
    }
    return containsWordPhrase(content, tool) and containsWordPhrase(content, "package manager");
}

fn extractTestCommand(content: []const u8) ?[]const u8 {
    const commands = [_][]const u8{ "just test", "pnpm test", "npm test" };
    for (commands) |command| {
        if (commandInvoked(content, command)) return command;
    }
    return null;
}

/// A test command counts when it is quoted in backticks or follows an
/// imperative cue ("Run just test"), not when "just test" is ordinary prose.
fn commandInvoked(content: []const u8, command: []const u8) bool {
    var start: usize = 0;
    while (findWordPhrase(content, command, start)) |index| {
        start = index + command.len;
        if (index > 0 and content[index - 1] == '`') return true;
        if (precedingWord(content, index)) |word| {
            if (eqlAnyIgnoreCase(word, &command_cues)) return true;
        }
    }
    return false;
}

fn extractRepoStyle(content: []const u8) ?[]const u8 {
    if (containsAnyWordPhrase(content, &.{ "local-first", "local first" })) return "local_first";
    if (containsAnyWordPhrase(content, &.{ "thin SDK", "thin SDKs", "thin TypeScript", "thin Python" })) return "thin_sdks";
    if (containsAnyWordPhrase(content, &.{ "small public API", "small public APIs" })) return "small_public_api";
    return null;
}

fn extractProjectConstraint(content: []const u8) ?[]const u8 {
    if (containsAnyWordPhrase(content, &.{ "evidence-backed", "links to evidence" })) return "evidence_backed";
    if (containsAnyWordPhrase(content, &.{ "forgetting propagates", "forgetting must propagate" })) return "forgetting_propagates";
    if (containsAnyWordPhrase(content, &.{ "SDKs do not duplicate", "SDKs must not duplicate" })) return "daemon_semantics";
    return null;
}

fn extractResponseStyle(content: []const u8) ?[]const u8 {
    if (styleRequested(content, &.{ "concise", "brief" })) return "concise";
    if (styleRequested(content, &.{"detailed"})) return "detailed";
    return null;
}

/// Response style needs an explicit request: "prefer concise", "please be
/// brief", "response style: detailed", or a sentence that starts with
/// "Be concise". Descriptive prose such as "to be concise" or "tips for concise
/// responses" does not count.
fn styleRequested(content: []const u8, adjectives: []const []const u8) bool {
    var buffer: [64]u8 = undefined;
    for (adjectives) |adjective| {
        for (preference_verbs) |verb| {
            if (containsWordPhrase(content, joinPhrase(&buffer, &.{ verb, " ", adjective }))) return true;
        }
        if (containsWordPhrase(content, joinPhrase(&buffer, &.{ "please be ", adjective }))) return true;
        if (containsWordPhrase(content, joinPhrase(&buffer, &.{ "response style: ", adjective }))) return true;
        if (containsWordPhrase(content, joinPhrase(&buffer, &.{ "response-style: ", adjective }))) return true;
        if (phraseStartsSentence(content, joinPhrase(&buffer, &.{ "be ", adjective }))) return true;
    }
    return false;
}

fn joinPhrase(buffer: []u8, parts: []const []const u8) []const u8 {
    var len: usize = 0;
    for (parts) |part| {
        @memcpy(buffer[len .. len + part.len], part);
        len += part.len;
    }
    return buffer[0..len];
}

fn containsAnyWordPhrase(haystack: []const u8, phrases: []const []const u8) bool {
    for (phrases) |phrase| {
        if (containsWordPhrase(haystack, phrase)) return true;
    }
    return false;
}

fn containsWordPhrase(haystack: []const u8, phrase: []const u8) bool {
    return findWordPhrase(haystack, phrase, 0) != null;
}

/// Case-insensitive search for `phrase` starting at `start` whose first and
/// last characters sit on word boundaries.
fn findWordPhrase(haystack: []const u8, phrase: []const u8, start: usize) ?usize {
    if (phrase.len == 0 or phrase.len > haystack.len) return null;
    var index = start;
    while (index + phrase.len <= haystack.len) : (index += 1) {
        if (!std.ascii.eqlIgnoreCase(haystack[index .. index + phrase.len], phrase)) continue;
        const starts_on_boundary = index == 0 or !isWordChar(haystack[index - 1]);
        const end = index + phrase.len;
        const ends_on_boundary = end == haystack.len or !isWordChar(haystack[end]);
        if (starts_on_boundary and ends_on_boundary) return index;
    }
    return null;
}

fn phraseStartsSentence(haystack: []const u8, phrase: []const u8) bool {
    var start: usize = 0;
    while (findWordPhrase(haystack, phrase, start)) |index| {
        start = index + phrase.len;
        var cursor = index;
        while (cursor > 0 and (haystack[cursor - 1] == ' ' or haystack[cursor - 1] == '\t')) : (cursor -= 1) {}
        if (cursor == 0) return true;
        switch (haystack[cursor - 1]) {
            '.', '!', '?', '\n', '\r', ':', ';' => return true,
            else => {},
        }
    }
    return false;
}

/// The word immediately before `index`, skipping spaces and backticks.
fn precedingWord(haystack: []const u8, index: usize) ?[]const u8 {
    var end = index;
    while (end > 0 and (haystack[end - 1] == ' ' or haystack[end - 1] == '\t' or haystack[end - 1] == '`')) : (end -= 1) {}
    var begin = end;
    while (begin > 0 and isWordChar(haystack[begin - 1])) : (begin -= 1) {}
    if (begin == end) return null;
    return haystack[begin..end];
}

fn eqlAnyIgnoreCase(word: []const u8, candidates: []const []const u8) bool {
    for (candidates) |candidate| {
        if (std.ascii.eqlIgnoreCase(word, candidate)) return true;
    }
    return false;
}

fn isWordChar(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
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

test "deterministic extractor has no benchmark fixture rules" {
    const sentences = [_][]const u8{
        "I bought 2 train tickets for the retreat.",
        "For the Denver conference trip, the hotel is Harbor Inn.",
        "Orion's launch venue is Pier 3.",
        "The Alpha sprint has 4 tasks completed.",
        "My gym membership is active from January 1 through March 31.",
    };
    for (sentences) |sentence| {
        try std.testing.expectEqual(@as(usize, 0), DeterministicExtractor.extract(sentence).len);
    }
}

test "deterministic extractor package manager rule is word bounded and cue gated" {
    try std.testing.expectEqualStrings("npm", extractPackageManager("This repo uses npm.").?);
    try std.testing.expectEqualStrings("pnpm", extractPackageManager("We migrated this repo to pnpm.").?);
    try std.testing.expectEqualStrings("npm", extractPackageManager("Our package manager is npm.").?);
    try std.testing.expect(extractPackageManager("I ran npm install to fix the build.") == null);
    try std.testing.expect(extractPackageManager("Search npmjs.com for a date library.") == null);
    try std.testing.expect(extractPackageManager("The pnpm-lock file changed.") == null);
}

test "deterministic extractor test command rule is word bounded and cue gated" {
    try std.testing.expectEqualStrings("just test", extractTestCommand("Run just test before committing.").?);
    try std.testing.expectEqualStrings("pnpm test", extractTestCommand("Always run `pnpm test` first.").?);
    try std.testing.expectEqualStrings("npm test", extractTestCommand("Please run npm test.").?);
    try std.testing.expect(extractTestCommand("Adjust test timeouts for CI.") == null);
    try std.testing.expect(extractTestCommand("I just test recipes by tasting them.") == null);
}

test "deterministic extractor response style needs an explicit request" {
    try std.testing.expectEqualStrings("concise", extractResponseStyle("Please be concise in future responses.").?);
    try std.testing.expectEqualStrings("concise", extractResponseStyle("Be brief.").?);
    try std.testing.expectEqualStrings("detailed", extractResponseStyle("I prefer detailed responses now.").?);
    try std.testing.expect(extractResponseStyle("To be concise, the answer is no.") == null);
    try std.testing.expect(extractResponseStyle("Here are tips for writing concise responses.") == null);
    try std.testing.expect(extractResponseStyle("I'll keep this concise.") == null);
    try std.testing.expect(extractRepoStyle("We keep thin SDKs.") != null);
    try std.testing.expect(extractRepoStyle("A local-firstish idea.") == null);
}

test "candidate validation rejects label slot mismatch" {
    const invalid = Candidate{
        .label = .fact,
        .slot_key = "user.response_style",
        .value = "concise",
        .text = "The user prefers concise responses.",
    };

    try std.testing.expectError(error.SlotLabelMismatch, validateCandidate(invalid));
    const fixture_slot = Candidate{
        .label = .fact,
        .slot_key = "trip.denver.hotel",
        .value = "Harbor Inn",
        .text = "Denver conference trip hotel: Harbor Inn.",
    };
    try std.testing.expectError(error.SlotLabelMismatch, validateCandidate(fixture_slot));
}
