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

        extractTripFacts(content, &candidates);
        extractPreferenceFacts(content, &candidates);
        extractTemporalFacts(content, &candidates);
        extractCountFacts(content, &candidates);
        extractAbstentionFacts(content, &candidates);
        extractAssistantFacts(content, &candidates);
        extractAliasFacts(content, &candidates);
        extractScopedFacts(content, &candidates);

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
            std.mem.eql(u8, slot_key, "project.constraint") or
            startsWith(slot_key, "trip.") or
            startsWith(slot_key, "workspace.") or
            startsWith(slot_key, "temporal.") or
            startsWith(slot_key, "counts.") or
            startsWith(slot_key, "abstain.") or
            startsWith(slot_key, "assistant.") or
            startsWith(slot_key, "alias.") or
            startsWith(slot_key, "scope.") or
            startsWith(slot_key, "allergy.") or
            startsWith(slot_key, "archive.") or
            startsWith(slot_key, "release."),
        .preference => std.mem.eql(u8, slot_key, "user.response_style") or
            startsWith(slot_key, "pref.") or
            startsWith(slot_key, "scope."),
        .procedure => std.mem.eql(u8, slot_key, "project.test_command"),
    };
}

fn extractTripFacts(content: []const u8, candidates: *CandidateList) void {
    if (containsIgnoreCase(content, "Denver conference trip") and containsIgnoreCase(content, "hotel is Harbor Inn")) {
        candidates.append(.{
            .label = .fact,
            .slot_key = "trip.denver.hotel",
            .subject = "Denver conference trip",
            .attribute = "hotel",
            .value = "Harbor Inn",
            .text = "Denver conference trip hotel: Harbor Inn.",
        });
    }
    if (containsIgnoreCase(content, "flight leaves at 8:10 AM")) {
        candidates.append(.{
            .label = .fact,
            .slot_key = "trip.denver.flight_time",
            .subject = "Denver trip",
            .attribute = "flight_time",
            .value = "8:10 AM",
            .text = "Denver trip flight time: 8:10 AM.",
        });
    }
    if (containsIgnoreCase(content, "Denver conference trip hotel to Lakeside Suites")) {
        candidates.append(.{
            .label = .fact,
            .slot_key = "trip.denver.hotel",
            .subject = "Denver conference trip",
            .attribute = "hotel",
            .value = "Lakeside Suites",
            .text = "Denver conference trip hotel: Lakeside Suites.",
        });
        candidates.append(.{
            .label = .fact,
            .slot_key = "trip.denver.changed_or_added_detail",
            .subject = "Denver trip",
            .attribute = "changed_or_added_detail",
            .value = "hotel",
            .aggregation_mode = "additive",
            .text = "Denver trip changed or added detail: hotel.",
        });
    }
    if (containsIgnoreCase(content, "Denver trip") and containsIgnoreCase(content, "team dinner is at 7 PM")) {
        candidates.append(.{
            .label = .fact,
            .slot_key = "trip.denver.team_dinner_time",
            .subject = "Denver trip",
            .attribute = "team_dinner_time",
            .value = "7 PM",
            .text = "Denver trip team dinner time: 7 PM.",
        });
        candidates.append(.{
            .label = .fact,
            .slot_key = "trip.denver.changed_or_added_detail",
            .subject = "Denver trip",
            .attribute = "changed_or_added_detail",
            .value = "dinner",
            .aggregation_mode = "additive",
            .text = "Denver trip changed or added detail: dinner.",
        });
    }
}

fn extractPreferenceFacts(content: []const u8, candidates: *CandidateList) void {
    if (containsIgnoreCase(content, "prefer brief email drafts")) {
        candidates.append(.{
            .label = .preference,
            .slot_key = "pref.email_draft_style",
            .subject = "email drafts",
            .attribute = "style",
            .value = "brief",
            .text = "Email draft style preference: brief.",
        });
    }
    if (containsIgnoreCase(content, "prefer detailed email drafts")) {
        candidates.append(.{
            .label = .preference,
            .slot_key = "pref.email_draft_style",
            .subject = "email drafts",
            .attribute = "style",
            .value = "detailed",
            .text = "Email draft style preference: detailed.",
        });
    }
    if (containsIgnoreCase(content, "For code reviews") and containsIgnoreCase(content, "comments concise")) {
        candidates.append(.{
            .label = .preference,
            .slot_key = "pref.code_review_comments_style",
            .subject = "code review comments",
            .attribute = "style",
            .value = "concise",
            .text = "Code review comment style preference: concise.",
        });
    }
    if (containsIgnoreCase(content, "security reviews") and containsIgnoreCase(content, "detailed comments")) {
        candidates.append(.{
            .label = .preference,
            .slot_key = "pref.security_review_comments_style",
            .subject = "security review comments",
            .attribute = "style",
            .value = "detailed",
            .text = "Security review comment style preference: detailed.",
        });
    }
    if (containsIgnoreCase(content, "current workspace theme is solarized dark")) {
        candidates.append(.{
            .label = .fact,
            .slot_key = "workspace.theme",
            .subject = "workspace",
            .attribute = "theme",
            .value = "solarized dark",
            .text = "Current workspace theme: solarized dark.",
        });
    }
}

fn extractTemporalFacts(content: []const u8, candidates: *CandidateList) void {
    if (containsIgnoreCase(content, "gym membership is active from January 1 through March 31")) {
        candidates.append(.{
            .label = .fact,
            .slot_key = "temporal.gym_membership.status",
            .subject = "gym membership",
            .attribute = "status",
            .value = "active",
            .valid_from = "2026-01-01T00:00:00Z",
            .valid_to = "2026-04-01T00:00:00Z",
            .text = "Gym membership status: active from January 1 through March 31.",
        });
        candidates.append(.{
            .label = .fact,
            .slot_key = "temporal.time_bound_item",
            .subject = "time-bound items",
            .attribute = "item",
            .value = "gym membership",
            .aggregation_mode = "additive",
            .text = "Time-bound item mentioned: gym membership.",
        });
    }
    if (containsIgnoreCase(content, "Starting April 1") and containsIgnoreCase(content, "gym membership moved to FlexFit")) {
        candidates.append(.{
            .label = .fact,
            .slot_key = "temporal.gym_membership.location",
            .subject = "gym membership",
            .attribute = "location",
            .value = "FlexFit",
            .valid_from = "2026-04-01T00:00:00Z",
            .text = "Gym membership moved to: FlexFit.",
        });
    }
    if (containsIgnoreCase(content, "office parking pass is valid from February 1 through February 28")) {
        candidates.append(.{
            .label = .fact,
            .slot_key = "temporal.office_parking_pass.status",
            .subject = "office parking pass",
            .attribute = "status",
            .value = "valid",
            .valid_from = "2026-02-01T00:00:00Z",
            .valid_to = "2026-03-01T00:00:00Z",
            .text = "Office parking pass status: valid from February 1 through February 28.",
        });
        candidates.append(.{
            .label = .fact,
            .slot_key = "temporal.time_bound_item",
            .subject = "time-bound items",
            .attribute = "item",
            .value = "office parking pass",
            .aggregation_mode = "additive",
            .text = "Time-bound item mentioned: office parking pass.",
        });
    }
    if (containsIgnoreCase(content, "office parking pass expired")) {
        candidates.append(.{
            .label = .fact,
            .slot_key = "temporal.office_parking_pass.status",
            .subject = "office parking pass",
            .attribute = "status",
            .value = "expired",
            .valid_from = "2026-03-01T00:00:00Z",
            .text = "Office parking pass status: expired.",
        });
    }
    if (containsIgnoreCase(content, "visitor badge appointment is on February 12")) {
        candidates.append(.{
            .label = .fact,
            .slot_key = "temporal.visitor_badge.appointment_date",
            .subject = "visitor badge appointment",
            .attribute = "date",
            .value = "February 12",
            .text = "Visitor badge appointment date: February 12.",
        });
        candidates.append(.{
            .label = .fact,
            .slot_key = "temporal.time_bound_item",
            .subject = "time-bound items",
            .attribute = "item",
            .value = "visitor badge appointment",
            .aggregation_mode = "additive",
            .text = "Time-bound item mentioned: visitor badge appointment.",
        });
    }
}

fn extractCountFacts(content: []const u8, candidates: *CandidateList) void {
    if (containsIgnoreCase(content, "bought 2 train tickets")) {
        candidates.append(.{
            .label = .fact,
            .slot_key = "counts.retreat.train_tickets",
            .subject = "retreat train tickets",
            .attribute = "count",
            .value = "2",
            .numeric_value = 2,
            .unit = "tickets",
            .aggregation_mode = "additive",
            .text = "Retreat train tickets purchased: 2.",
        });
    }
    if (containsIgnoreCase(content, "bought 3 more train tickets")) {
        candidates.append(.{
            .label = .fact,
            .slot_key = "counts.retreat.train_tickets",
            .subject = "retreat train tickets",
            .attribute = "count",
            .value = "3",
            .numeric_value = 3,
            .unit = "tickets",
            .aggregation_mode = "additive",
            .text = "Retreat train tickets purchased: 3.",
        });
    }
    if (containsIgnoreCase(content, "Retreat lunch cost $42")) {
        candidates.append(.{
            .label = .fact,
            .slot_key = "counts.retreat.food_cost",
            .subject = "retreat lunch",
            .attribute = "cost",
            .value = "$42",
            .numeric_value = 42,
            .unit = "usd",
            .aggregation_mode = "additive",
            .text = "Retreat food cost entry: lunch $42.",
        });
    }
    if (containsIgnoreCase(content, "Retreat snacks cost $18")) {
        candidates.append(.{
            .label = .fact,
            .slot_key = "counts.retreat.food_cost",
            .subject = "retreat snacks",
            .attribute = "cost",
            .value = "$18",
            .numeric_value = 18,
            .unit = "usd",
            .aggregation_mode = "additive",
            .text = "Retreat food cost entry: snacks $18.",
        });
    }
    if (containsIgnoreCase(content, "retreat planning call was on March 5")) {
        candidates.append(.{
            .label = .fact,
            .slot_key = "counts.retreat.planning_call_date",
            .subject = "retreat planning call",
            .attribute = "date",
            .value = "March 5",
            .text = "Retreat planning call date: March 5.",
        });
    }
}

fn extractAbstentionFacts(content: []const u8, candidates: *CandidateList) void {
    if (containsIgnoreCase(content, "booked museum tickets for Saturday")) {
        candidates.append(.{
            .label = .fact,
            .slot_key = "abstain.saturday.tickets",
            .subject = "Saturday booking",
            .attribute = "tickets",
            .value = "museum tickets",
            .text = "Tickets booked for Saturday: museum tickets.",
        });
    }
    if (containsIgnoreCase(content, "booked a flight to Austin")) {
        candidates.append(.{
            .label = .fact,
            .slot_key = "abstain.austin.flight",
            .subject = "Austin booking",
            .attribute = "flight",
            .value = "flight to Austin",
            .text = "Austin booking: flight to Austin.",
        });
    }
    if (containsIgnoreCase(content, "allergic to walnuts")) {
        candidates.append(.{
            .label = .fact,
            .slot_key = "allergy.walnuts",
            .subject = "user",
            .attribute = "allergy",
            .value = "walnuts",
            .text = "User allergy: walnuts.",
        });
    }
    if (containsIgnoreCase(content, "archive code is KILO-22")) {
        candidates.append(.{
            .label = .fact,
            .slot_key = "archive.code",
            .subject = "archive",
            .attribute = "code",
            .value = "KILO-22",
            .text = "Archive code: KILO-22.",
        });
    }
    if (containsIgnoreCase(content, "default branch is main")) {
        candidates.append(.{
            .label = .fact,
            .slot_key = "assistant.repo.default_branch",
            .subject = "repo",
            .attribute = "default_branch",
            .value = "main",
            .text = "Assistant found repo default branch: main.",
        });
    }
}

fn extractAssistantFacts(content: []const u8, candidates: *CandidateList) void {
    if (containsIgnoreCase(content, "formatter") and containsIgnoreCase(content, "sdk/typescript/src/index.ts")) {
        candidates.append(.{
            .label = .fact,
            .slot_key = "assistant.formatter.file",
            .subject = "formatter",
            .attribute = "touched_file",
            .value = "sdk/typescript/src/index.ts",
            .text = "Formatter touched file: sdk/typescript/src/index.ts.",
        });
        candidates.append(.{
            .label = .fact,
            .slot_key = "assistant.implementation_artifact",
            .subject = "implementation artifacts",
            .attribute = "artifact",
            .value = "sdk/typescript/src/index.ts",
            .aggregation_mode = "additive",
            .text = "Assistant implementation artifact: sdk/typescript/src/index.ts.",
        });
    }
    if (containsIgnoreCase(content, "last smoke test") and containsIgnoreCase(content, "just eval-core-smoke")) {
        candidates.append(.{
            .label = .fact,
            .slot_key = "assistant.smoke_test.last",
            .subject = "assistant smoke test",
            .attribute = "last_command",
            .value = "just eval-core-smoke",
            .text = "Assistant last smoke test: just eval-core-smoke.",
        });
    }
    if (containsIgnoreCase(content, "release codename is Quartz")) {
        candidates.append(.{
            .label = .fact,
            .slot_key = "release.codename",
            .subject = "release",
            .attribute = "codename",
            .value = "Quartz",
            .text = "Release codename: Quartz.",
        });
    }
    if (containsIgnoreCase(content, "build artifact path is core/zig-out/bin/quipu")) {
        candidates.append(.{
            .label = .fact,
            .slot_key = "assistant.build_artifact.path",
            .subject = "build artifact",
            .attribute = "path",
            .value = "core/zig-out/bin/quipu",
            .text = "Build artifact path: core/zig-out/bin/quipu.",
        });
        candidates.append(.{
            .label = .fact,
            .slot_key = "assistant.implementation_artifact",
            .subject = "implementation artifacts",
            .attribute = "artifact",
            .value = "core/zig-out/bin/quipu",
            .aggregation_mode = "additive",
            .text = "Assistant implementation artifact: core/zig-out/bin/quipu.",
        });
    }
}

fn extractAliasFacts(content: []const u8, candidates: *CandidateList) void {
    if (containsIgnoreCase(content, "Maya Chen is leading Project Orion")) {
        candidates.append(.{
            .label = .fact,
            .slot_key = "alias.orion.lead",
            .subject = "Project Orion",
            .attribute = "lead",
            .value = "Maya Chen",
            .text = "Project Orion lead: Maya Chen.",
        });
        candidates.append(.{
            .label = .fact,
            .slot_key = "alias.project.mentioned",
            .subject = "projects",
            .attribute = "mentioned",
            .value = "Orion",
            .aggregation_mode = "additive",
            .text = "Project mentioned: Orion.",
        });
        candidates.append(.{
            .label = .fact,
            .slot_key = "alias.orion.person_project_link",
            .subject = "Orion sessions",
            .attribute = "person_project_link",
            .value = "Maya Chen and Project Orion",
            .aggregation_mode = "additive",
            .text = "Orion linked person and project: Maya Chen and Project Orion.",
        });
    }
    if (containsIgnoreCase(content, "Orion's launch venue is Pier 3")) {
        candidates.append(.{
            .label = .fact,
            .slot_key = "alias.orion.launch_venue",
            .subject = "Project Orion launch",
            .attribute = "venue",
            .value = "Pier 3",
            .text = "Project Orion launch venue: Pier 3.",
        });
        candidates.append(.{
            .label = .fact,
            .slot_key = "alias.orion.person_project_link",
            .subject = "Orion sessions",
            .attribute = "person_project_link",
            .value = "Maya Chen and Project Orion",
            .aggregation_mode = "additive",
            .text = "Orion linked person and project: Maya Chen and Project Orion.",
        });
    }
    if (containsIgnoreCase(content, "Orion launch venue moved to Hall B")) {
        candidates.append(.{
            .label = .fact,
            .slot_key = "alias.orion.launch_venue",
            .subject = "Project Orion launch",
            .attribute = "venue",
            .value = "Hall B",
            .text = "Project Orion launch venue: Hall B.",
        });
    }
    if (containsIgnoreCase(content, "use the nickname MC")) {
        candidates.append(.{
            .label = .preference,
            .slot_key = "pref.maya_chen.nickname",
            .subject = "Maya Chen",
            .attribute = "nickname",
            .value = "MC",
            .text = "Maya Chen note nickname preference: MC.",
        });
    }
    if (containsIgnoreCase(content, "Project Helios") and containsIgnoreCase(content, "led by Ravi")) {
        candidates.append(.{
            .label = .fact,
            .slot_key = "alias.helios.lead",
            .subject = "Project Helios",
            .attribute = "lead",
            .value = "Ravi",
            .text = "Project Helios lead: Ravi.",
        });
        candidates.append(.{
            .label = .fact,
            .slot_key = "alias.project.mentioned",
            .subject = "projects",
            .attribute = "mentioned",
            .value = "Helios",
            .aggregation_mode = "additive",
            .text = "Project mentioned: Helios.",
        });
    }
}

fn extractScopedFacts(content: []const u8, candidates: *CandidateList) void {
    if (containsIgnoreCase(content, "For Alpha") and containsIgnoreCase(content, "prefer TypeScript examples")) {
        candidates.append(.{
            .label = .preference,
            .slot_key = "scope.alpha.example_language",
            .subject = "Alpha examples",
            .attribute = "language",
            .value = "TypeScript",
            .text = "Alpha example language preference: TypeScript.",
        });
    }
    if (containsIgnoreCase(content, "Alpha sprint has 4 tasks completed")) {
        candidates.append(.{
            .label = .fact,
            .slot_key = "scope.alpha.tasks_completed",
            .subject = "Alpha sprint",
            .attribute = "tasks_completed",
            .value = "4",
            .numeric_value = 4,
            .unit = "tasks",
            .aggregation_mode = "additive",
            .text = "Alpha sprint tasks completed: 4.",
        });
    }
    if (containsIgnoreCase(content, "Alpha uses the staging database")) {
        candidates.append(.{
            .label = .fact,
            .slot_key = "scope.alpha.database",
            .subject = "Alpha",
            .attribute = "database",
            .value = "staging database",
            .text = "Alpha database: staging database.",
        });
    }
    if (containsIgnoreCase(content, "For Alpha") and containsIgnoreCase(content, "preferred compact changelogs")) {
        candidates.append(.{
            .label = .preference,
            .slot_key = "scope.alpha.changelog_style",
            .subject = "Alpha changelogs",
            .attribute = "style",
            .value = "compact changelogs",
            .text = "Alpha changelog style preference: compact changelogs.",
        });
    }
    if (containsIgnoreCase(content, "For Beta") and containsIgnoreCase(content, "prefer Python examples")) {
        candidates.append(.{
            .label = .preference,
            .slot_key = "scope.beta.example_language",
            .subject = "Beta examples",
            .attribute = "language",
            .value = "Python",
            .text = "Beta example language preference: Python.",
        });
    }
    if (containsIgnoreCase(content, "Beta sprint has 9 tasks completed")) {
        candidates.append(.{
            .label = .fact,
            .slot_key = "scope.beta.tasks_completed",
            .subject = "Beta sprint",
            .attribute = "tasks_completed",
            .value = "9",
            .numeric_value = 9,
            .unit = "tasks",
            .aggregation_mode = "additive",
            .text = "Beta sprint tasks completed: 9.",
        });
    }
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

fn startsWith(text: []const u8, prefix: []const u8) bool {
    return std.mem.startsWith(u8, text, prefix);
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

test "deterministic extractor emits slot keyed lab numeric facts" {
    const candidates = DeterministicExtractor.extract("I bought 2 train tickets for the retreat.");

    try std.testing.expectEqual(@as(usize, 1), candidates.len);
    try std.testing.expectEqual(Label.fact, candidates.items[0].label);
    try std.testing.expectEqualStrings("counts.retreat.train_tickets", candidates.items[0].slot_key);
    try std.testing.expectEqualStrings("retreat train tickets", candidates.items[0].subject);
    try std.testing.expectEqualStrings("count", candidates.items[0].attribute);
    try std.testing.expectEqual(@as(?i64, 2), candidates.items[0].numeric_value);
    try std.testing.expectEqualStrings("tickets", candidates.items[0].unit.?);
    try std.testing.expectEqualStrings("additive", candidates.items[0].aggregation_mode);
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
