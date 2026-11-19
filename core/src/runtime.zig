const std = @import("std");
const answer_synthesis = @import("answer_synthesis.zig");
const build_options = @import("build_options");
const extractor = @import("extractor.zig");
const fact_extraction = @import("fact_extraction.zig");
const fact_updates = @import("fact_updates.zig");
const forgetting = @import("forgetting.zig");
const in_memory_storage = if (build_options.enable_lattice) struct {} else @import("in_memory_storage.zig");
const jobs = @import("jobs.zig");
const lattice_storage = if (build_options.enable_lattice) @import("lattice_storage.zig") else struct {};
const patterns = @import("patterns.zig");
const summaries = @import("summaries.zig");
const protocol = @import("protocol.zig");
const providers = @import("providers.zig");
const query_expansion = @import("query_expansion.zig");
const schema = @import("schema.zig");
const storage = @import("storage.zig");
const streams = @import("streams.zig");
const temporal = @import("temporal.zig");

const ObjectMap = std.json.ObjectMap;
const Value = std.json.Value;

const card_keywords_package_manager = [_][]const u8{ "package-manager", "dependency-tool" };
const card_keywords_test_command = [_][]const u8{ "test-command", "verification" };
const card_keywords_repo_style = [_][]const u8{ "repo-style", "implementation-style" };
const card_keywords_project_constraint = [_][]const u8{ "project-constraint", "invariant" };
const card_keywords_response_style = [_][]const u8{ "response-style", "communication" };
const card_keywords_generic = [_][]const u8{"memory-card"};
const card_tags_fact = [_][]const u8{ "fact", "project" };
const card_tags_preference = [_][]const u8{ "preference", "user" };
const card_tags_procedure = [_][]const u8{ "procedure", "project" };
/// LatticeDB stores large values; 64 KiB round-trips in the adapter tests.
/// Longer message text still survives intact across its Chunk nodes.
const property_text_max_bytes = 64 * 1024;
const property_truncation_marker = "…";
/// Messages longer than this many bytes are split into Chunk nodes.
const message_chunk_max_bytes = 1200;
/// Boundary search looks back this many bytes from the hard chunk limit.
const message_chunk_boundary_window = 200;
const default_budget_tokens: i64 = 4096;
/// Candidate items kept per retrieval; enough chunks to fill the default budget.
const retrieval_candidate_limit: usize = 80;
/// Time anchors: how deep the search goes for items dated inside a
/// window the question names, and how many of them each window may bring in.
const time_anchor_hit_limit: usize = 1000;
const time_anchor_items_per_window: usize = 24;
/// The share of the token budget that anchored items may take.
const time_anchor_budget_percent: usize = 50;
/// Leading candidates sent to a configured reranker (`options.rerankCandidates`).
const default_rerank_candidates: usize = 50;
/// Rerank scores listed in the retrieval trace.
const rerank_trace_top_scores: usize = 10;
/// Extract jobs whose provider calls run at once (`memory.extract.run`).
const default_extract_concurrency: usize = 8;
/// Assertion qids carry this prefix, so search channels can drop assertion
/// hits without loading the node.
const assertion_qid_prefix = "q_asrt_";
const update_qid_prefix = "q_upd_";
/// Consolidation: claims compared per job, earlier facts fetched per claim
/// and sent per job, and search hits scanned to find them (raw hits share
/// the list, so it is several times what is kept).
const max_consolidate_claims: usize = 32;
const max_earlier_per_claim: usize = 3;
const max_consolidate_earlier: usize = 30;
const consolidate_search_limit: usize = 48;
/// Pattern jobs: how many are leased at once (jobs for one scope are settled
/// by one pass), how long a pass may hold them, and the most sentences one
/// pass compares; the newest are kept.
const pattern_lease_limit: usize = 256;
const pattern_lease_ttl_ms: i64 = 30 * 60 * 1000;
const max_pattern_sentences: usize = 20_000;
/// Messages one pass may split and embed. Embedding is a provider call made
/// between requests, so a store with a backlog is indexed over several
/// passes, and nothing is grouped until it all is.
const pattern_index_limit: usize = 64;
/// Summary jobs: how many are leased at once (jobs for one scope are settled
/// by one pass), how long a pass may hold them, and how many claims one pass
/// may embed. Embedding is a provider call made between requests, so a store
/// with a backlog of claims is indexed over several passes, and no topic is
/// formed until it all is.
const summary_lease_limit: usize = 256;
const summary_lease_ttl_ms: i64 = 30 * 60 * 1000;
const summary_index_limit: usize = 2048;
/// Share of the token budget a pattern node may use, out of the raw
/// evidence's share.
const pattern_budget_percent: usize = 40;
/// `options.facts`: share of the token budget the facts section may use,
/// and search hits scanned for claims that match the query.
const facts_budget_percent: usize = 30;
const fact_search_limit: usize = 200;
/// `options.facts`: heads the facts section, so the reader knows what the
/// states mean. Without it GPT-4o-mini answered 54 of 70 development
/// questions at 4K; with it, 57.
const facts_legend = "(What people said about themselves, with the date said. A superseded fact was replaced by a later one; the current fact holds now.)";
/// factKeys: event dates listed on one raw line, earliest first.
const max_event_dates_per_item: usize = 4;
/// With `options.queryExpansion`, each query's leading candidates that lead
/// the fused list (see `fuseQueryItems`).
const expansion_leaders_per_query: usize = 2;
/// Audit events read per stream page by memory.inspect.
const audit_page_size: usize = 1000;
/// Related cards a new memory card links to.
const related_card_limit: usize = 8;

const Scope = struct {
    tenant_id: ?[]const u8 = null,
    user_id: ?[]const u8 = null,
    agent_id: ?[]const u8 = null,
    project_id: ?[]const u8 = null,

    fn json(self: Scope) ScopeJson {
        return .{
            .tenantId = self.tenant_id,
            .userId = self.user_id,
            .agentId = self.agent_id,
            .projectId = self.project_id,
        };
    }

    fn matchesNode(self: Scope, allocator: std.mem.Allocator, node: storage.Node) !bool {
        if (self.tenant_id) |expected| {
            if (!try propertyEquals(allocator, node.properties_json, "tenantId", expected)) return false;
        }
        if (self.user_id) |expected| {
            if (!try propertyEquals(allocator, node.properties_json, "userId", expected)) return false;
        }
        if (self.agent_id) |expected| {
            if (!try propertyEquals(allocator, node.properties_json, "agentId", expected)) return false;
        }
        if (self.project_id) |expected| {
            if (!try propertyEquals(allocator, node.properties_json, "projectId", expected)) return false;
        }
        return true;
    }
};

const ScopeJson = struct {
    tenantId: ?[]const u8 = null,
    userId: ?[]const u8 = null,
    agentId: ?[]const u8 = null,
    projectId: ?[]const u8 = null,
};

const MessageResult = struct {
    qid: []const u8,
    type: []const u8,
    text: []const u8,
    score: f32,
    confidence: f32 = 1.0,
    state: []const u8 = "current",
    validFrom: ?[]const u8 = null,
    validTo: ?[]const u8 = null,
    evidence: []const EvidenceResult = &.{},
    includeDebug: bool = false,
    slotKey: ?[]const u8 = null,
    subject: ?[]const u8 = null,
    attribute: ?[]const u8 = null,
    value: ?[]const u8 = null,
    numericValue: ?i64 = null,
    unit: ?[]const u8 = null,
    aggregationMode: ?[]const u8 = null,
    /// Source metadata for raw evidence items (Message and Chunk nodes).
    /// Not serialized; renderers read it from the item directly.
    raw_source: ?RawSource = null,
    /// factKeys: the item entered the candidates through an Assertion hit.
    /// Not serialized.
    via_assertion: bool = false,
    /// Set on the items of the threads section: how the item is rendered.
    /// Not serialized.
    thread: ?ThreadBlock = null,

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("qid");
        try jw.write(self.qid);
        try jw.objectField("type");
        try jw.write(self.type);
        try jw.objectField("text");
        try jw.write(self.text);
        try jw.objectField("score");
        try jw.write(self.score);
        try jw.objectField("confidence");
        try jw.write(self.confidence);
        try jw.objectField("state");
        try jw.write(self.state);
        try jw.objectField("validFrom");
        try jw.write(self.validFrom);
        try jw.objectField("validTo");
        try jw.write(self.validTo);
        try jw.objectField("evidence");
        try jw.write(self.evidence);
        if (self.includeDebug) {
            if (self.slotKey) |slot_key| {
                try jw.objectField("slotKey");
                try jw.write(slot_key);
            }
            if (self.subject) |subject| {
                try jw.objectField("subject");
                try jw.write(subject);
            }
            if (self.attribute) |attribute| {
                try jw.objectField("attribute");
                try jw.write(attribute);
            }
            if (self.value) |value| {
                try jw.objectField("value");
                try jw.write(value);
            }
            if (self.numericValue) |numeric_value| {
                try jw.objectField("numericValue");
                try jw.write(numeric_value);
            }
            if (self.unit) |unit| {
                try jw.objectField("unit");
                try jw.write(unit);
            }
            if (self.aggregationMode) |aggregation_mode| {
                try jw.objectField("aggregationMode");
                try jw.write(aggregation_mode);
            }
        }
        try jw.endObject();
    }
};

/// Where a raw evidence item came from. All strings are owned by the item.
const RawSource = struct {
    role: ?[]const u8 = null,
    created_at: ?[]const u8 = null,
    /// Caller-provided session id from memory.remember, when present.
    session_id: ?[]const u8 = null,
    session_qid: ?[]const u8 = null,
    turn_qid: ?[]const u8 = null,
    /// Parent message qid; equals the item qid for unchunked messages.
    message_qid: []const u8,
    /// 0-based position of the message in its memory.remember call.
    message_index: ?i64 = null,
    /// 0-based chunk position; null when the item is a whole message.
    chunk_index: ?i64 = null,
    chunk_count: ?i64 = null,
    /// Slot keys of memories evidenced by this message that are stale at
    /// query time (filled only when the packet holds slot memories).
    stale_slot_keys: []const []const u8 = &.{},
    /// factKeys: event dates of the claims evidenced by this item
    /// (`2023-03-03`, `2023-06 planned`), rendered as `[event ...]`.
    event_dates: []const []const u8 = &.{},

    fn deinit(self: RawSource, allocator: std.mem.Allocator) void {
        if (self.role) |value| allocator.free(value);
        if (self.created_at) |value| allocator.free(value);
        if (self.session_id) |value| allocator.free(value);
        if (self.session_qid) |value| allocator.free(value);
        if (self.turn_qid) |value| allocator.free(value);
        allocator.free(self.message_qid);
        for (self.stale_slot_keys) |key| allocator.free(key);
        if (self.stale_slot_keys.len > 0) allocator.free(self.stale_slot_keys);
        for (self.event_dates) |date| allocator.free(date);
        if (self.event_dates.len > 0) allocator.free(self.event_dates);
    }
};

const EvidenceResult = struct {
    qid: []const u8,
    quote: []const u8,
    timestamp: ?[]const u8 = null,
};

const ContextPacket = struct {
    core: []const MessageResult = &.{},
    currentFacts: []const MessageResult = &.{},
    preferences: []const MessageResult = &.{},
    procedural: []const MessageResult = &.{},
    /// At most one: the pattern node that owns the question.
    patterns: []const MessageResult = &.{},
    /// The topics nearest the question, each a summary evidenced by the
    /// messages of its facts, and the facts shown outside a topic.
    threads: []const MessageResult = &.{},
    episodes: []const MessageResult = &.{},
    warnings: []const []const u8 = &.{},
};

const RetrievalTrace = struct {
    query: []const u8,
    requestedNeedsCount: usize,
    budgetTokens: i64,
    candidateSources: CandidateSources = .{},
    candidateCount: usize,
    keptCount: usize,
    droppedForNeeds: usize,
    droppedForBudget: usize,
    tokenEstimate: usize,
    validAt: ?[]const u8 = null,
    scoreBreakdowns: []const ScoreBreakdown = &.{},
    scoringDetails: []const ScoringDetail = &.{},
    droppedItemReasons: []const DroppedItemReason = &.{},
    /// Present only when a reranker is configured.
    rerank: ?RerankTrace = null,
    /// Present only when `options.factKeys` is true.
    factKeys: ?FactKeysTrace = null,
    /// Present only when `options.queryExpansion` is not off.
    queryExpansion: ?query_expansion.Trace = null,
    /// Present only when `options.facts` is true.
    facts: ?FactsTrace = null,
    /// Present only when the question names a time that was searched by.
    timeAnchors: ?TimeAnchorsTrace = null,
    /// Present only when the scope has pattern nodes with a finding.
    patterns: ?PatternsTrace = null,
    /// Present only when the scope has summaries to read.
    threads: ?ThreadsTrace = null,

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        try jw.beginObject();
        inline for (std.meta.fields(@This())) |field| {
            const value = @field(self, field.name);
            if (comptime (std.mem.eql(u8, field.name, "rerank") or std.mem.eql(u8, field.name, "factKeys") or std.mem.eql(u8, field.name, "queryExpansion") or std.mem.eql(u8, field.name, "facts") or std.mem.eql(u8, field.name, "timeAnchors") or std.mem.eql(u8, field.name, "patterns") or std.mem.eql(u8, field.name, "threads"))) {
                if (value) |present| {
                    try jw.objectField(field.name);
                    try jw.write(present);
                }
            } else {
                try jw.objectField(field.name);
                try jw.write(value);
            }
        }
        try jw.endObject();
    }
};

const RerankTrace = struct {
    model: ?[]const u8,
    /// `applied`, `failed` (fused order kept), `disabled` (`options.rerank`
    /// false), or `skipped` (no candidates).
    status: []const u8,
    /// Leading candidates sent to the reranker.
    windowSize: usize = 0,
    /// Candidates the reranker returned a score for.
    rerankedCount: usize = 0,
    latencyMs: f64 = 0,
    /// Best scores first, at most `rerank_trace_top_scores`.
    topScores: []const RerankScore = &.{},
    @"error": ?[]const u8 = null,
};

/// `options.facts`: what the facts section of the context holds.
const FactsTrace = struct {
    /// Claims among the search hits for the query.
    candidates: usize = 0,
    /// Facts in the context, and how many of them are superseded.
    kept: usize = 0,
    superseded: usize = 0,
    /// Facts added because a kept fact replaces them or is replaced by them.
    linked: usize = 0,
    /// Estimated tokens of the section, taken out of the raw evidence budget.
    tokens: usize = 0,
};

/// What the times named in the question brought in.
const TimeAnchorsTrace = struct {
    /// Date windows resolved from the question.
    windows: usize = 0,
    /// Items dated inside a window that were moved ahead of the other
    /// candidates, before the token budget was applied.
    items: usize = 0,
    /// Estimated tokens of those items.
    tokens: usize = 0,
};

/// `options.factKeys`: how assertion search keys shaped the candidates.
const FactKeysTrace = struct {
    /// Assertion hits converted to their source evidence.
    assertionHits: usize = 0,
    /// Raw candidates that entered through an assertion hit (a direct raw hit
    /// ranked higher keeps the item as its own).
    evidenceItems: usize = 0,
    /// Of those, items left after the token budget.
    keptEvidenceItems: usize = 0,
    /// Raw candidates carrying at least one event date.
    datedItems: usize = 0,
};

const RerankScore = struct {
    qid: []const u8,
    score: f64,
};

const CandidateSources = struct {
    fts: usize = 0,
    vector: usize = 0,
    hybrid: usize = 0,
    graph: usize = 0,
    core: usize = 0,
};

const ScoreBreakdown = struct {
    qid: []const u8,
    type: []const u8,
    score: f32,
    lexical: f32,
    temporal: f32,
    scope: f32,
    confidence: f32,
    recency: f32,
};

const ScoringDetail = struct {
    qid: []const u8,
    type: []const u8,
    finalScore: f32,
    lexical: f32,
    temporal: f32,
    scope: f32,
    confidence: f32,
    recency: f32,
    formula: []const u8 = "lexical + temporal + scope + confidence + recency",
};

const DroppedItemReason = struct {
    reason: []const u8,
    count: usize,
};

const MessageMeta = struct {
    scope: Scope,
    role: []const u8,
    created_at: ?[]const u8,
    session_qid: []const u8,
    session_id: ?[]const u8,
    turn_qid: []const u8,
    message_qid: []const u8,
    message_index: usize,
    privacy_class: []const u8,
};

const EventWindow = struct {
    start: ?[]const u8 = null,
    end: ?[]const u8 = null,

    fn active(self: EventWindow) bool {
        return self.start != null or self.end != null;
    }
};

const SearchMode = enum {
    fts,
    vector,
    hybrid,
    graph,
};

const CoreBlockResult = struct {
    qid: []const u8,
    blockKey: []const u8,
    scope: ScopeJson,
    text: []const u8,
    managedBy: []const u8,
    evidenceQids: []const []const u8 = &.{},
};

const NodeRefResult = struct {
    qid: []const u8,
    type: []const u8,
    relation: []const u8,
};

const ForgetReportItem = struct {
    qid: []const u8,
    type: []const u8,
    action: []const u8,
};

const AuditEventResult = struct {
    stream: []const u8,
    sequence: u64,
    rawJson: []const u8,
};

pub const EntityJobRunResult = struct {
    materializedCount: usize,
    leasedCount: usize,
    succeededCount: usize,
    failedCount: usize,
    lastError: ?[]const u8 = null,
};

/// Outcome of one `memory.extract.run` / `quipu jobs run extract` pass.
pub const ExtractJobRunResult = struct {
    materializedCount: usize = 0,
    leasedCount: usize = 0,
    succeededCount: usize = 0,
    failedCount: usize = 0,
    lastError: ?[]const u8 = null,
    /// Provider calls, including E1's bounded retries after malformed JSON.
    calls: usize = 0,
    jsonRetries: usize = 0,
    sourceMessages: usize = 0,
    assertionsWritten: usize = 0,
    /// Messages the first reading drew no claim from, read a second time,
    /// and the claims that reading added (included in `assertionsWritten`).
    recallMessages: usize = 0,
    recallAssertions: usize = 0,
    counts: fact_extraction.Counts = .{},
};

/// Claims one extract job wrote.
const ExtractWritten = struct {
    total: usize = 0,
    /// Of those, from the second reading.
    recalled: usize = 0,
};

/// Outcome of one `memory.consolidate.run` / `quipu jobs run consolidate` pass.
pub const ConsolidateJobRunResult = struct {
    leasedCount: usize = 0,
    succeededCount: usize = 0,
    failedCount: usize = 0,
    lastError: ?[]const u8 = null,
    calls: usize = 0,
    /// Claims compared and earlier facts they were compared with.
    claims: usize = 0,
    earlier: usize = 0,
    updatesWritten: usize = 0,
    counts: fact_updates.Counts = .{},
};

/// What pattern passes did, summed over scopes.
pub const PatternCounts = struct {
    /// Messages whose sentences were embedded.
    messagesIndexed: usize = 0,
    sentences: usize = 0,
    occasions: usize = 0,
    groups: usize = 0,
    /// Groups with enough occasions for a node.
    eligible: usize = 0,
    gated: usize = 0,
    proposed: usize = 0,
    /// Occasion answers the counting calls gave.
    answered: usize = 0,
    /// Replies that could not be read after a retry.
    malformed: usize = 0,
    written: usize = 0,
    unchanged: usize = 0,
    superseded: usize = 0,
    /// Nodes written with a generalisation that held.
    regularities: usize = 0,

    fn add(self: *PatternCounts, other: PatternCounts) void {
        inline for (std.meta.fields(PatternCounts)) |field| {
            @field(self, field.name) += @field(other, field.name);
        }
    }
};

/// Outcome of one `memory.patterns.run` / `quipu jobs run patterns` pass.
pub const PatternJobRunResult = struct {
    leasedCount: usize = 0,
    succeededCount: usize = 0,
    failedCount: usize = 0,
    lastError: ?[]const u8 = null,
    calls: usize = 0,
    /// Scopes rebuilt; the jobs of one scope are settled by one pass.
    scopes: usize = 0,
    counts: PatternCounts = .{},
    /// A pass left part of a backlog for the next one.
    continued: bool = false,
};

/// What summary passes did, summed over scopes.
pub const SummaryCounts = struct {
    /// Sessions with messages, and those whose summary was missing or stale.
    sessions: usize = 0,
    sessionsAsked: usize = 0,
    sessionsWritten: usize = 0,
    /// Claims compared, and claims whose vector this pass stored.
    claims: usize = 0,
    claimsIndexed: usize = 0,
    /// Groups of two or more claims.
    groups: usize = 0,
    topicsAsked: usize = 0,
    topicsWritten: usize = 0,
    /// Groups the model said were not about one thing.
    topicsDeclined: usize = 0,
    /// Summaries that already say what their sources say.
    unchanged: usize = 0,
    /// Nodes that nothing stands behind any more.
    retired: usize = 0,
    /// Summaries no reply could be read for after a retry.
    malformed: usize = 0,

    fn add(self: *SummaryCounts, other: SummaryCounts) void {
        inline for (std.meta.fields(SummaryCounts)) |field| {
            @field(self, field.name) += @field(other, field.name);
        }
    }
};

/// Outcome of one `memory.summaries.run` / `quipu jobs run summaries` pass.
pub const SummaryJobRunResult = struct {
    leasedCount: usize = 0,
    succeededCount: usize = 0,
    failedCount: usize = 0,
    lastError: ?[]const u8 = null,
    calls: usize = 0,
    /// Scopes rebuilt; the jobs of one scope are settled by one pass.
    scopes: usize = 0,
    counts: SummaryCounts = .{},
    /// A pass left part of a backlog for the next one.
    continued: bool = false,
    /// The embedding provider did not answer for a scope's new summaries;
    /// its jobs went back to pending with their attempts intact.
    unembedded: bool = false,
};

/// What a finished background batch did.
pub const BackgroundResult = union(enum) {
    extract: ExtractJobRunResult,
    consolidate: ConsolidateJobRunResult,
    patterns: PatternJobRunResult,
    summaries: SummaryJobRunResult,
};

pub const RuntimeOptions = struct {
    io: ?std.Io = null,
    answer_provider: providers.ProviderEndpoint = .{},
    /// Chat provider for `options.queryExpansion: "llm"`; unset means the
    /// answer provider.
    expansion_provider: providers.ProviderEndpoint = .{},
    entity_provider: providers.ProviderEndpoint = .{},
    /// Chat model for the `extract` job worker (LLM fact extraction).
    extract_provider: providers.ProviderEndpoint = .{},
    /// Chat model for the pattern jobs; unset means the extract provider.
    /// Proposing a generalisation is the step a stronger model is worth.
    pattern_provider: providers.ProviderEndpoint = .{},
    /// Optional cross-encoder stage of memory.retrieve and memory.answer.
    reranker: providers.ProviderEndpoint = .{},
    /// Whether the host drains long-term jobs between requests with
    /// `startBackgroundWork`. Off, jobs run only when a caller asks.
    background_workers: bool = false,
    /// Whether extraction queues a `consolidate` job for the user's new
    /// claims. The job looks for earlier statements a claim replaces, using
    /// the extract provider.
    consolidate_updates: bool = false,
};

/// Called from a worker thread when the last provider call of a background
/// batch returns, so the host can wake and call `finishBackgroundWork`.
pub const BackgroundNotify = struct {
    context: *anyopaque,
    wake: *const fn (context: *anyopaque) void,
};

/// Jobs of one kind whose provider calls run off the request path.
const BackgroundBatch = struct {
    allocator: std.mem.Allocator,
    leases: []jobs.LeaseResult,
    tasks: []ExtractTask = &.{},
    consolidate_tasks: []ConsolidateTask = &.{},
    pattern_tasks: []PatternTask = &.{},
    summary_tasks: []SummaryTask = &.{},
    group: std.Io.Group = .init,
    /// Provider calls that have not returned yet.
    remaining: std.atomic.Value(usize),
    notify: ?BackgroundNotify,

    fn destroy(self: *BackgroundBatch) void {
        const allocator = self.allocator;
        for (self.tasks) |*task| task.deinit(allocator);
        allocator.free(self.tasks);
        for (self.consolidate_tasks) |*task| task.deinit(allocator);
        allocator.free(self.consolidate_tasks);
        freePatternTasks(allocator, self.pattern_tasks);
        freeSummaryTasks(allocator, self.summary_tasks);
        jobs.freeLeaseResults(allocator, self.leases);
        allocator.destroy(self);
    }
};

/// Owner recorded on jobs the daemon leases for itself.
const background_owner = "quipu-daemon";

/// How long the background worker waits after a batch in which no provider
/// call got a reply; doubles on each such batch up to the maximum.
const background_backoff_initial_ms: i64 = 30_000;
const background_backoff_max_ms: i64 = 600_000;

pub const Runtime = struct {
    store: storage.Adapter,
    health: protocol.Health,
    options: RuntimeOptions = .{},
    next_id: u64 = 1,
    /// The batch of long-term jobs in flight, if any.
    background: ?*BackgroundBatch = null,
    background_notify: ?BackgroundNotify = null,
    /// Whether pending jobs may exist. Cleared when a pass finds none, so an
    /// idle daemon does not scan its jobs after every request.
    background_dirty: bool = true,
    /// Whether leases left by an earlier run of this daemon were released.
    background_recovered: bool = false,
    /// The current wait after a batch the provider did not answer; 0 once a
    /// batch gets a reply.
    background_backoff_ms: i64 = 0,
    /// No batch starts before this time.
    background_retry_at_ms: i64 = 0,

    pub fn init(store: storage.Adapter, health: protocol.Health) Runtime {
        return .{ .store = store, .health = health };
    }

    pub fn initWithOptions(store: storage.Adapter, health: protocol.Health, options: RuntimeOptions) Runtime {
        return .{ .store = store, .health = health, .options = options };
    }

    pub fn initWithNextId(store: storage.Adapter, health: protocol.Health, next_id: u64) Runtime {
        return .{
            .store = store,
            .health = health,
            .next_id = @max(next_id, 1),
        };
    }

    pub fn initWithNextIdAndOptions(store: storage.Adapter, health: protocol.Health, next_id: u64, options: RuntimeOptions) Runtime {
        return .{
            .store = store,
            .health = health,
            .options = options,
            .next_id = @max(next_id, 1),
        };
    }

    pub fn deinit(self: *Runtime) void {
        self.cancelBackgroundWork();
    }

    /// Wall-clock milliseconds for job leases; 0 without an Io.
    fn nowMs(self: *const Runtime) i64 {
        const io = self.options.io orelse return 0;
        return std.Io.Timestamp.now(io, .real).toMilliseconds();
    }

    /// Whether `startBackgroundWork` can do anything: the host asked for it,
    /// there is an Io to run calls on, and a chat model to extract with.
    pub fn backgroundEnabled(self: *const Runtime) bool {
        return self.options.background_workers and self.options.io != null and extractProviderUsable(self.options.extract_provider);
    }

    /// Leases the oldest pending extract jobs and starts their provider calls
    /// on other threads, then returns: requests are served while the calls
    /// run. One batch is in flight at a time. Returns whether a batch started.
    ///
    /// Storage is only touched here and in `finishBackgroundWork`, both on
    /// the caller's thread.
    pub fn startBackgroundWork(self: *Runtime, allocator: std.mem.Allocator) !bool {
        if (self.background != null or !self.background_dirty or !self.backgroundEnabled()) return false;
        if (self.nowMs() < self.background_retry_at_ms) return false;
        const io = self.options.io.?;
        const worker_kind = streams.workerKindForStream(streams.extract_requested);
        if (!self.background_recovered) {
            _ = try jobs.releaseOwnedLeases(allocator, self.store, background_owner);
            self.background_recovered = true;
        }
        _ = try jobs.reclaimExpiredLeases(allocator, self.store, self.nowMs());
        const leases = try jobs.leasePendingJobs(allocator, self.store, .{
            .worker_kind = worker_kind,
            .owner = background_owner,
            .now_ms = self.nowMs(),
            .limit = default_extract_concurrency,
        });
        if (leases.len == 0) {
            jobs.freeLeaseResults(allocator, leases);
            // Consolidation follows extraction: its jobs run once no extract
            // job is waiting.
            if (self.options.consolidate_updates and try self.startBackgroundConsolidation(allocator, io)) return true;
            // Summaries are brought up to date once the claims are written.
            if (try self.startBackgroundSummaries(allocator, io)) return true;
            // Pattern nodes are rebuilt last, from everything read so far.
            if (try self.startBackgroundPatterns(allocator, io)) return true;
            self.background_dirty = false;
            return false;
        }
        errdefer {
            for (leases) |lease| jobs.releaseLease(allocator, self.store, lease.qid) catch {};
            jobs.freeLeaseResults(allocator, leases);
        }
        const tasks = try allocator.alloc(ExtractTask, leases.len);
        for (tasks, leases) |*task, lease| task.* = .{ .lease = lease };
        errdefer {
            for (tasks) |*task| task.deinit(allocator);
            allocator.free(tasks);
        }
        try self.prepareExtractTasks(allocator, tasks);

        const batch = try allocator.create(BackgroundBatch);
        batch.* = .{
            .allocator = allocator,
            .leases = leases,
            .tasks = tasks,
            .remaining = .init(tasks.len),
            .notify = self.background_notify,
        };
        self.background = batch;
        const endpoint = self.options.extract_provider;
        for (tasks) |*task| {
            batch.group.concurrent(io, backgroundCall, .{ batch, task, allocator, io, endpoint }) catch
                backgroundCall(batch, task, allocator, io, endpoint);
        }
        return true;
    }

    fn startBackgroundConsolidation(self: *Runtime, allocator: std.mem.Allocator, io: std.Io) !bool {
        const leases = try jobs.leasePendingJobs(allocator, self.store, .{
            .worker_kind = streams.workerKindForStream(streams.consolidate_requested),
            .owner = background_owner,
            .now_ms = self.nowMs(),
            .limit = default_extract_concurrency,
        });
        if (leases.len == 0) {
            jobs.freeLeaseResults(allocator, leases);
            return false;
        }
        errdefer {
            for (leases) |lease| jobs.releaseLease(allocator, self.store, lease.qid) catch {};
            jobs.freeLeaseResults(allocator, leases);
        }
        const tasks = try allocator.alloc(ConsolidateTask, leases.len);
        for (tasks, leases) |*task, lease| task.* = .{ .lease = lease };
        errdefer {
            for (tasks) |*task| task.deinit(allocator);
            allocator.free(tasks);
        }
        try self.prepareConsolidateTasks(allocator, tasks);

        const batch = try allocator.create(BackgroundBatch);
        batch.* = .{
            .allocator = allocator,
            .leases = leases,
            .consolidate_tasks = tasks,
            .remaining = .init(tasks.len),
            .notify = self.background_notify,
        };
        self.background = batch;
        const endpoint = self.options.extract_provider;
        for (tasks) |*task| {
            batch.group.concurrent(io, backgroundConsolidateCall, .{ batch, task, allocator, io, endpoint }) catch
                backgroundConsolidateCall(batch, task, allocator, io, endpoint);
        }
        return true;
    }

    /// Whether a batch is in flight.
    pub fn backgroundActive(self: *const Runtime) bool {
        return self.background != null;
    }

    /// Whether every provider call of the batch in flight has returned, so
    /// `finishBackgroundWork` will not wait.
    pub fn backgroundReady(self: *const Runtime) bool {
        const batch = self.background orelse return false;
        return batch.remaining.load(.acquire) == 0;
    }

    /// Waits for the batch's provider calls, then grounds the replies and
    /// writes the results. Null when no batch is in flight.
    ///
    /// A batch in which every call failed before a reply came back says the
    /// provider is unreachable or misconfigured, not that the jobs are bad:
    /// they return to pending with their attempts intact and the worker
    /// waits before the next batch. One failed call among answered ones is
    /// that job's failure and uses an attempt.
    pub fn finishBackgroundWork(self: *Runtime, allocator: std.mem.Allocator) !?BackgroundResult {
        const batch = self.background orelse return null;
        self.background = null;
        defer batch.destroy();
        if (self.options.io) |io| batch.group.await(io) catch {};
        const consolidating = batch.consolidate_tasks.len > 0;
        const patterning = batch.pattern_tasks.len > 0;
        const summarising = batch.summary_tasks.len > 0;

        var calls: usize = 0;
        var called: usize = 0;
        var unanswered: usize = 0;
        var last_error: ?[]const u8 = null;
        for (batch.tasks) |task| {
            if (task.calls == 0) continue;
            called += 1;
            calls += task.calls;
            if (!task.unanswered) continue;
            unanswered += 1;
            last_error = @errorName(task.failure.?);
        }
        for (batch.consolidate_tasks) |task| {
            if (task.calls == 0) continue;
            called += 1;
            calls += task.calls;
            if (!task.unanswered) continue;
            unanswered += 1;
            last_error = @errorName(task.failure.?);
        }
        for (batch.pattern_tasks) |task| {
            // A pattern task also asks the embedding provider, before any
            // chat call; no answer there is no answer.
            if (task.calls == 0 and !task.unanswered) continue;
            called += 1;
            calls += task.calls;
            if (!task.unanswered) continue;
            unanswered += 1;
            last_error = @errorName(task.failure.?);
        }
        for (batch.summary_tasks) |task| {
            // A summary task also asks the embedding provider, before any
            // chat call; no answer there is no answer.
            if (task.calls == 0 and !task.unanswered) continue;
            called += 1;
            calls += task.calls;
            if (!task.unanswered) continue;
            unanswered += 1;
            last_error = @errorName(task.failure.?);
        }
        if (called > 0 and unanswered == called) {
            for (batch.leases) |lease| try jobs.releaseLease(allocator, self.store, lease.qid);
            self.backOffBackground(self.background_backoff_ms);
            if (consolidating) return .{ .consolidate = .{ .leasedCount = batch.leases.len, .failedCount = unanswered, .calls = calls, .lastError = last_error } };
            if (patterning) return .{ .patterns = .{ .leasedCount = batch.leases.len, .failedCount = unanswered, .calls = calls, .lastError = last_error } };
            if (summarising) return .{ .summaries = .{ .leasedCount = batch.leases.len, .failedCount = unanswered, .calls = calls, .lastError = last_error } };
            return .{ .extract = .{ .leasedCount = batch.leases.len, .failedCount = unanswered, .calls = calls, .lastError = last_error } };
        }
        const waited_ms = self.background_backoff_ms;
        self.background_backoff_ms = 0;
        self.background_retry_at_ms = 0;
        // Jobs the failed write did not settle go back to pending.
        errdefer for (batch.leases) |lease| jobs.releaseLease(allocator, self.store, lease.qid) catch {};
        if (consolidating) {
            var result = ConsolidateJobRunResult{ .leasedCount = batch.leases.len };
            try self.applyConsolidateTasks(allocator, batch.consolidate_tasks, &result);
            return .{ .consolidate = result };
        }
        if (patterning) {
            var result = PatternJobRunResult{ .leasedCount = batch.leases.len };
            try self.applyPatternTasks(allocator, batch.pattern_tasks, &result);
            return .{ .patterns = result };
        }
        if (summarising) {
            var result = SummaryJobRunResult{ .leasedCount = batch.leases.len };
            try self.applySummaryTasks(allocator, batch.summary_tasks, &result);
            // The chat model answered and the embedding provider did not:
            // the worker waits, as after a batch nothing answered.
            if (result.unembedded) self.backOffBackground(waited_ms);
            return .{ .summaries = result };
        }
        var result = ExtractJobRunResult{ .leasedCount = batch.leases.len };
        try self.applyExtractTasks(allocator, batch.tasks, &result);
        return .{ .extract = result };
    }

    /// No batch starts for a while: `waited_ms` doubled, from the initial
    /// wait up to the maximum.
    fn backOffBackground(self: *Runtime, waited_ms: i64) void {
        self.background_backoff_ms = if (waited_ms == 0)
            background_backoff_initial_ms
        else
            @min(waited_ms * 2, background_backoff_max_ms);
        self.background_retry_at_ms = self.nowMs() + self.background_backoff_ms;
    }

    /// Stops the batch in flight and gives its jobs back unrun.
    pub fn cancelBackgroundWork(self: *Runtime) void {
        const batch = self.background orelse return;
        self.background = null;
        if (self.options.io) |io| batch.group.cancel(io);
        for (batch.leases) |lease| jobs.releaseLease(batch.allocator, self.store, lease.qid) catch {};
        batch.destroy();
    }

    pub fn dispatch(self: *Runtime, allocator: std.mem.Allocator, request_json: []const u8) ![]u8 {
        var parsed = std.json.parseFromSlice(Value, allocator, request_json, .{}) catch {
            return errorResponse(allocator, null, "invalid_request", "request body must be valid JSON");
        };
        defer parsed.deinit();

        const root = switch (parsed.value) {
            .object => |object| object,
            else => return errorResponse(allocator, null, "invalid_request", "request must be a JSON object"),
        };

        const id = jsonRpcId(root.get("id"));
        const jsonrpc = stringValue(root.get("jsonrpc")) orelse {
            return errorResponse(allocator, id, "invalid_request", "jsonrpc is required");
        };
        if (!std.mem.eql(u8, jsonrpc, "2.0")) {
            return errorResponse(allocator, id, "invalid_request", "jsonrpc must be 2.0");
        }
        const method = stringValue(root.get("method")) orelse {
            return errorResponse(allocator, id, "invalid_request", "method is required");
        };
        const params = paramsObject(root.get("params")) catch {
            return errorResponse(allocator, id, "invalid_request", "params must be an object");
        };

        if (std.mem.eql(u8, method, "system.health")) return self.systemHealth(allocator, id);
        if (std.mem.eql(u8, method, "memory.remember")) return self.memoryRemember(allocator, id, &params);
        if (std.mem.eql(u8, method, "memory.search")) return self.memorySearch(allocator, id, &params);
        if (std.mem.eql(u8, method, "memory.retrieve")) return self.memoryRetrieve(allocator, id, &params);
        if (std.mem.eql(u8, method, "memory.answer")) return self.memoryAnswer(allocator, id, &params);
        if (std.mem.eql(u8, method, "memory.inspect")) return self.memoryInspect(allocator, id, &params);
        if (std.mem.eql(u8, method, "memory.forget")) return self.memoryForget(allocator, id, &params);
        if (std.mem.eql(u8, method, "memory.feedback")) return self.memoryFeedback(allocator, id, &params);
        if (std.mem.eql(u8, method, "memory.entityResolve.run")) return self.memoryEntityResolveRun(allocator, id, &params);
        if (std.mem.eql(u8, method, "memory.extract.run")) return self.memoryExtractRun(allocator, id, &params);
        if (std.mem.eql(u8, method, "memory.consolidate.run")) return self.memoryConsolidateRun(allocator, id, &params);
        if (std.mem.eql(u8, method, "memory.patterns.run")) return self.memoryPatternsRun(allocator, id, &params);
        if (std.mem.eql(u8, method, "memory.summaries.run")) return self.memorySummariesRun(allocator, id, &params);
        if (std.mem.eql(u8, method, "memory.core.get")) return self.memoryCoreGet(allocator, id, &params);
        if (std.mem.eql(u8, method, "memory.core.update")) return self.memoryCoreUpdate(allocator, id, &params);
        if (std.mem.eql(u8, method, "memory.core.consolidate")) return self.memoryCoreConsolidate(allocator, id, &params);

        return errorResponse(allocator, id, "not_found", "unsupported method");
    }

    fn systemHealth(self: *Runtime, allocator: std.mem.Allocator, id: ?[]const u8) ![]u8 {
        const expansion = self.expansionEndpoint();
        const expansion_llm = expansion.kind == .http or expansion.kind == .callback;
        const response = .{
            .jsonrpc = "2.0",
            .id = id,
            .result = .{
                .status = "ok",
                .version = self.health.version,
                .protocolVersion = self.health.protocol_version,
                .dbPath = self.health.db_path,
                .latticeVersion = self.health.lattice_version,
                .schemaVersion = self.health.schema_version,
                .storage = storageHealth(self.store.capabilities()),
                .workers = .{
                    .extractor = if (self.backgroundEnabled()) "running" else if (extractProviderUsable(self.options.extract_provider)) "stopped" else "unavailable",
                    .consolidator = if (!self.options.consolidate_updates or !extractProviderUsable(self.options.extract_provider)) "unavailable" else if (self.backgroundEnabled()) "running" else "stopped",
                    .summaries = if (!self.store.capabilities().vector or !extractProviderUsable(self.options.extract_provider)) "unavailable" else if (self.backgroundEnabled()) "running" else "stopped",
                    .patterns = if (!self.store.capabilities().vector or !extractProviderUsable(self.patternProvider())) "unavailable" else if (self.backgroundEnabled()) "running" else "stopped",
                    .entityResolver = if (self.options.entity_provider.kind == .none) "unavailable" else "stopped",
                    .answerer = if (self.options.answer_provider.kind == .none) "unavailable" else "running",
                },
                .capabilities = .{
                    .reranker = .{
                        .configured = self.options.reranker.kind != .none,
                        .model = if (self.options.reranker.kind != .none) self.options.reranker.model else null,
                    },
                    .extractor = .{
                        .configured = extractProviderUsable(self.options.extract_provider),
                        .model = if (extractProviderUsable(self.options.extract_provider)) self.options.extract_provider.model else null,
                        .promptVersion = fact_extraction.prompt_version,
                    },
                    .factKeys = true,
                    .facts = true,
                    .timeAnchors = true,
                    // Summary nodes group claims by their vectors and are
                    // found by their own, so they need a store that embeds.
                    .summaries = .{
                        .available = self.store.capabilities().vector,
                        .promptVersion = summaries.prompt_version,
                        .model = if (extractProviderUsable(self.options.extract_provider)) self.options.extract_provider.model else null,
                    },
                    // Pattern nodes compare sentence vectors, so they need
                    // a store that embeds.
                    .patterns = .{
                        .available = self.store.capabilities().vector,
                        .promptVersion = patterns.prompt_version,
                        .model = if (extractProviderUsable(self.patternProvider())) self.patternProvider().model else null,
                    },
                    .queryExpansion = .{
                        .modes = [_][]const u8{ "off", "rules", "llm" },
                        .llmConfigured = expansion_llm,
                        .model = if (expansion_llm) expansion.model else null,
                    },
                },
            },
        };
        return stringifyAlloc(allocator, response);
    }

    fn memoryEntityResolveRun(self: *Runtime, allocator: std.mem.Allocator, id: ?[]const u8, params: *const ObjectMap) ![]u8 {
        const owner = stringField(params, "owner") orelse "eval-runner";
        const requested_limit = integerField(params, "limit") orelse 100000;
        if (requested_limit < 1) {
            return errorResponse(allocator, id, "invalid_request", "limit must be positive");
        }
        const result = try self.runEntityResolveJobs(allocator, owner, @intCast(requested_limit));
        const response = .{
            .jsonrpc = "2.0",
            .id = id,
            .result = .{
                .materializedCount = result.materializedCount,
                .leasedCount = result.leasedCount,
                .succeededCount = result.succeededCount,
                .failedCount = result.failedCount,
                .lastError = result.lastError,
            },
        };
        return stringifyAlloc(allocator, response);
    }

    /// Operational RPC behind `quipu jobs run extract`, for callers that hold
    /// the daemon open (eval runners). Not part of the SDK surface.
    fn memoryExtractRun(self: *Runtime, allocator: std.mem.Allocator, id: ?[]const u8, params: *const ObjectMap) ![]u8 {
        const owner = stringField(params, "owner") orelse "extract-runner";
        const requested_limit = integerField(params, "limit") orelse 100000;
        if (requested_limit < 1) {
            return errorResponse(allocator, id, "invalid_request", "limit must be positive");
        }
        const requested_concurrency = integerField(params, "concurrency") orelse default_extract_concurrency;
        if (requested_concurrency < 1) {
            return errorResponse(allocator, id, "invalid_request", "concurrency must be positive");
        }
        if (!extractProviderUsable(self.options.extract_provider)) {
            return errorResponse(allocator, id, "provider_error", "no extract provider configured; set --extract-provider or --llm-provider");
        }
        const result = try self.runExtractJobs(allocator, owner, @intCast(requested_limit), @intCast(requested_concurrency));
        const response = .{
            .jsonrpc = "2.0",
            .id = id,
            .result = .{
                .materializedCount = result.materializedCount,
                .leasedCount = result.leasedCount,
                .succeededCount = result.succeededCount,
                .failedCount = result.failedCount,
                .lastError = result.lastError,
                .provider = self.options.extract_provider.name,
                .model = self.options.extract_provider.model,
                .promptVersion = fact_extraction.prompt_version,
                .calls = result.calls,
                .jsonRetries = result.jsonRetries,
                .sourceMessages = result.sourceMessages,
                .assertionsWritten = result.assertionsWritten,
                .recallMessages = result.recallMessages,
                .recallAssertions = result.recallAssertions,
                .counts = result.counts,
            },
        };
        return stringifyAlloc(allocator, response);
    }

    /// Operational, like `memory.extract.run`: runs the pending
    /// `consolidate` jobs and returns when they are done.
    fn memoryConsolidateRun(self: *Runtime, allocator: std.mem.Allocator, id: ?[]const u8, params: *const ObjectMap) ![]u8 {
        const owner = stringField(params, "owner") orelse "consolidate-runner";
        const requested_limit = integerField(params, "limit") orelse 100000;
        if (requested_limit < 1) {
            return errorResponse(allocator, id, "invalid_request", "limit must be positive");
        }
        const requested_concurrency = integerField(params, "concurrency") orelse default_extract_concurrency;
        if (requested_concurrency < 1) {
            return errorResponse(allocator, id, "invalid_request", "concurrency must be positive");
        }
        if (!extractProviderUsable(self.options.extract_provider)) {
            return errorResponse(allocator, id, "provider_error", "no extract provider configured; set --extract-provider or --llm-provider");
        }
        const result = try self.runConsolidateJobs(allocator, owner, @intCast(requested_limit), @intCast(requested_concurrency));
        const response = .{
            .jsonrpc = "2.0",
            .id = id,
            .result = .{
                .leasedCount = result.leasedCount,
                .succeededCount = result.succeededCount,
                .failedCount = result.failedCount,
                .lastError = result.lastError,
                .provider = self.options.extract_provider.name,
                .model = self.options.extract_provider.model,
                .promptVersion = fact_updates.prompt_version,
                .calls = result.calls,
                .claims = result.claims,
                .earlier = result.earlier,
                .updatesWritten = result.updatesWritten,
                .counts = result.counts,
            },
        };
        return stringifyAlloc(allocator, response);
    }

    fn memoryRemember(self: *Runtime, allocator: std.mem.Allocator, id: ?[]const u8, params: *const ObjectMap) ![]u8 {
        const messages = arrayValue(params.get("messages")) orelse {
            return errorResponse(allocator, id, "invalid_request", "messages must be a non-empty array");
        };
        if (messages.items.len == 0) {
            return errorResponse(allocator, id, "invalid_request", "messages must be a non-empty array");
        }

        if (stringField(params, "idempotencyKey")) |key| {
            const idem_qid = try idempotencyQid(allocator, key);
            defer allocator.free(idem_qid);
            if (try self.store.getNode(allocator, idem_qid)) |node| {
                defer self.store.freeNode(allocator, node);
                const session_qid = try readPropertyString(allocator, node.properties_json, "sessionQid");
                defer allocator.free(session_qid);
                const turn_qid = try readPropertyString(allocator, node.properties_json, "turnQid");
                defer allocator.free(turn_qid);
                const message_qid = try readPropertyString(allocator, node.properties_json, "messageQid");
                defer allocator.free(message_qid);
                const response = .{
                    .jsonrpc = "2.0",
                    .id = id,
                    .result = .{
                        .sessionQid = session_qid,
                        .turnQid = turn_qid,
                        .messageQids = &[_][]const u8{message_qid},
                        .queuedJobs = &[_][]const u8{},
                        .status = "duplicate",
                    },
                };
                return stringifyAlloc(allocator, response);
            }
        }

        const scope = parseScope(params);
        const session_qid = try self.nextQid(allocator, "sess");
        defer allocator.free(session_qid);
        const turn_qid = try self.nextQid(allocator, "turn");
        defer allocator.free(turn_qid);

        const session_id = stringField(params, "sessionId");
        const session_props = try stringifyAlloc(allocator, .{
            .kind = "session",
            .sessionId = session_id,
            .tenantId = scope.tenant_id,
            .userId = scope.user_id,
            .agentId = scope.agent_id,
            .projectId = scope.project_id,
            .deleted = false,
        });
        defer allocator.free(session_props);
        try self.store.putNode(.{ .qid = session_qid, .label = "Session", .properties_json = session_props });

        const turn_props = try stringifyAlloc(allocator, .{
            .kind = "turn",
            .sessionQid = session_qid,
            .tenantId = scope.tenant_id,
            .userId = scope.user_id,
            .agentId = scope.agent_id,
            .projectId = scope.project_id,
            .deleted = false,
        });
        defer allocator.free(turn_props);
        try self.store.putNode(.{ .qid = turn_qid, .label = "Turn", .properties_json = turn_props });
        try self.putEdge(allocator, session_qid, turn_qid, "HAS_TURN");

        var message_qids = std.ArrayList([]const u8).empty;
        defer {
            for (message_qids.items) |qid| allocator.free(qid);
            message_qids.deinit(allocator);
        }
        var first_message_content: ?[]const u8 = null;
        var first_message_created_at: ?[]const u8 = null;

        const extract_enabled = boolField(params, "extract") orelse true;
        var derived_count: usize = 0;

        try self.prefetchRememberEmbeddings(allocator, messages.items, extract_enabled);
        defer self.store.clearPrefetchedEmbeddings();

        for (messages.items, 0..) |message_value, message_index| {
            const message = objectValue(message_value) orelse {
                return errorResponse(allocator, id, "invalid_request", "each message must be an object");
            };
            const role = stringField(&message, "role") orelse {
                return errorResponse(allocator, id, "invalid_request", "message.role is required");
            };
            const content = stringField(&message, "content") orelse {
                return errorResponse(allocator, id, "invalid_request", "message.content is required");
            };
            if (content.len == 0) {
                return errorResponse(allocator, id, "invalid_request", "message.content is required");
            }
            if (first_message_content == null) {
                first_message_content = content;
                first_message_created_at = stringField(&message, "createdAt");
            }
            const message_qid = try self.nextQid(allocator, "msg");
            try message_qids.append(allocator, message_qid);

            const meta = MessageMeta{
                .scope = scope,
                .role = role,
                .created_at = stringField(&message, "createdAt"),
                .session_qid = session_qid,
                .session_id = session_id,
                .turn_qid = turn_qid,
                .message_qid = message_qid,
                .message_index = message_index,
                .privacy_class = stringField(params, "privacyClass") orelse "normal",
            };
            const chunk_ends = try messageChunkEnds(allocator, content);
            defer allocator.free(chunk_ends);
            const chunked = chunk_ends.len > 1;

            // A chunked message keeps a clamped copy of its content but is
            // searched through its chunks, which together hold the full text.
            const content_for_props = try clampPropertyText(allocator, content);
            defer allocator.free(content_for_props);
            const message_props = try stringifyAlloc(allocator, .{
                .kind = "message",
                .role = role,
                .content = content_for_props,
                .createdAt = meta.created_at,
                .sessionQid = session_qid,
                .sessionId = session_id,
                .turnQid = turn_qid,
                .messageIndex = message_index,
                .searchable = !chunked,
                .chunkCount = if (chunked) chunk_ends.len else 0,
                .tenantId = scope.tenant_id,
                .userId = scope.user_id,
                .agentId = scope.agent_id,
                .projectId = scope.project_id,
                .privacyClass = meta.privacy_class,
                .deleted = false,
            });
            defer allocator.free(message_props);
            // Chunked messages are searched through their chunks, which carry the speaker text.
            const message_node_props = if (chunked)
                try allocator.dupe(u8, message_props)
            else
                try withSpeakerSearchText(allocator, message_props, role, content);
            defer allocator.free(message_node_props);
            try self.store.putNode(.{ .qid = message_qid, .label = "Message", .properties_json = message_node_props });
            try self.putEdge(allocator, turn_qid, message_qid, "HAS_MESSAGE");
            if (chunked) {
                try self.writeMessageChunks(allocator, meta, content, chunk_ends);
            }
            if (extract_enabled) {
                derived_count += try self.extractFromMessage(
                    allocator,
                    scope,
                    message_qid,
                    content,
                    stringField(&message, "createdAt"),
                );
            }
        }

        const episode_qid = if (extract_enabled and message_qids.items.len > 0)
            try self.writeEpisodeForTurn(allocator, scope, session_qid, turn_qid, message_qids.items, first_message_content orelse "", first_message_created_at)
        else
            null;
        defer if (episode_qid) |qid| allocator.free(qid);

        const tool_call_count = try self.writeToolCalls(allocator, params, scope, turn_qid);
        const observation_count = try self.writeObservations(allocator, params, scope, turn_qid);

        if (stringField(params, "idempotencyKey")) |key| {
            const idem_qid = try idempotencyQid(allocator, key);
            defer allocator.free(idem_qid);
            const first_message_qid = if (message_qids.items.len > 0) message_qids.items[0] else "";
            const idem_props = try stringifyAlloc(allocator, .{
                .kind = "idempotency",
                .idempotencyKey = key,
                .sessionQid = session_qid,
                .turnQid = turn_qid,
                .messageQid = first_message_qid,
                .deleted = false,
            });
            defer allocator.free(idem_props);
            try self.store.putNode(.{ .qid = idem_qid, .label = "Idempotency", .properties_json = idem_props });
        }

        var queued_jobs = std.ArrayList([]const u8).empty;
        defer {
            for (queued_jobs.items) |qid| allocator.free(qid);
            queued_jobs.deinit(allocator);
        }
        if (extract_enabled) {
            const extract_payload = try stringifyAlloc(allocator, .{
                .method = "memory.extract.requested",
                .sourceMethod = "memory.remember",
                .sessionQid = session_qid,
                .turnQid = turn_qid,
                .messageQids = message_qids.items,
                .scope = scope.json(),
                .inlineDerivedCount = derived_count,
            });
            defer allocator.free(extract_payload);
            const extract_event = try self.publishEvent(streams.extract_requested, extract_payload);
            const extract_job_qid = try jobs.jobQid(
                allocator,
                streams.extract_requested,
                extract_event.sequence,
                streams.workerKindForStream(streams.extract_requested),
            );
            errdefer allocator.free(extract_job_qid);
            _ = try jobs.materializeStream(allocator, self.store, streams.extract_requested, streams.workerKindForStream(streams.extract_requested), .{
                .after_sequence = if (extract_event.sequence > 0) extract_event.sequence - 1 else 0,
                .limit = 1,
            });
            self.background_dirty = true;
            try queued_jobs.append(allocator, extract_job_qid);
        }
        if (self.options.entity_provider.kind != .none and message_qids.items.len > 0) {
            const entity_payload = try stringifyAlloc(allocator, .{
                .method = "memory.entity.resolve.requested",
                .sourceMethod = "memory.remember",
                .sessionQid = session_qid,
                .turnQid = turn_qid,
                .messageQids = message_qids.items,
                .scope = scope.json(),
                .provider = self.options.entity_provider.name,
            });
            defer allocator.free(entity_payload);
            const entity_event = try self.publishEvent(streams.entity_resolve_requested, entity_payload);
            const entity_job_qid = try jobs.jobQid(
                allocator,
                streams.entity_resolve_requested,
                entity_event.sequence,
                streams.workerKindForStream(streams.entity_resolve_requested),
            );
            errdefer allocator.free(entity_job_qid);
            _ = try jobs.materializeStream(allocator, self.store, streams.entity_resolve_requested, streams.workerKindForStream(streams.entity_resolve_requested), .{
                .after_sequence = if (entity_event.sequence > 0) entity_event.sequence - 1 else 0,
                .limit = 1,
            });
            try queued_jobs.append(allocator, entity_job_qid);
        }

        const event_payload = try stringifyAlloc(allocator, .{
            .method = "memory.remember",
            .status = "stored",
            .sessionQid = session_qid,
            .turnQid = turn_qid,
            .messageQids = message_qids.items,
            .queuedJobs = queued_jobs.items,
            .derivedCount = derived_count,
            .episodeQid = episode_qid,
            .toolCallCount = tool_call_count,
            .observationCount = observation_count,
        });
        defer allocator.free(event_payload);
        _ = try self.publishEvent(streams.raw_event, event_payload);
        _ = try self.publishEvent(streams.audit, event_payload);

        const response = .{
            .jsonrpc = "2.0",
            .id = id,
            .result = .{
                .sessionQid = session_qid,
                .turnQid = turn_qid,
                .messageQids = message_qids.items,
                .queuedJobs = queued_jobs.items,
                .status = "stored",
            },
        };
        return stringifyAlloc(allocator, response);
    }

    fn memorySearch(self: *Runtime, allocator: std.mem.Allocator, id: ?[]const u8, params: *const ObjectMap) ![]u8 {
        const query = stringField(params, "query") orelse {
            return errorResponse(allocator, id, "invalid_request", "query must be a non-empty string");
        };
        if (query.len == 0) {
            return errorResponse(allocator, id, "invalid_request", "query must be a non-empty string");
        }
        const limit = integerField(params, "limit") orelse 20;
        const include_deleted = boolField(params, "includeDeleted") orelse false;
        const scope = parseScope(params);
        const mode = parseSearchMode(stringField(params, "mode")) orelse {
            return errorResponse(allocator, id, "invalid_request", "mode must be fts, vector, hybrid, or graph");
        };

        var results = try self.collectItems(allocator, query, mode, @intCast(limit), scope, include_deleted, params.get("labels"), null, .{}, true, false);
        defer results.deinit();

        const response = .{
            .jsonrpc = "2.0",
            .id = id,
            .result = .{ .results = results.items.items },
        };
        return stringifyAlloc(allocator, response);
    }

    fn memoryRetrieve(self: *Runtime, allocator: std.mem.Allocator, id: ?[]const u8, params: *const ObjectMap) ![]u8 {
        const query = stringField(params, "query") orelse {
            return errorResponse(allocator, id, "invalid_request", "query must be a non-empty string");
        };
        if (query.len == 0) {
            return errorResponse(allocator, id, "invalid_request", "query must be a non-empty string");
        }
        const budget = integerField(params, "budgetTokens") orelse default_budget_tokens;
        if (budget < 1) {
            return errorResponse(allocator, id, "invalid_request", "budgetTokens must be positive");
        }

        const scope = parseScope(params);
        const valid_at = parseValidAt(params);
        const event_window = parseEventWindow(params);
        const needs_value = params.get("needs");
        const options = objectField(params, "options");
        const include_evidence = if (options) |opts| boolField(&opts, "includeEvidence") orelse true else true;
        const include_trace = if (options) |opts| (boolField(&opts, "includeDebug") orelse false) or (boolField(&opts, "logTrace") orelse false) else false;
        const log_retrieval = if (options) |opts| boolField(&opts, "logRetrieval") orelse (boolField(&opts, "logTrace") orelse true) else true;
        const log_audit = if (options) |opts| boolField(&opts, "logAudit") orelse true else true;
        const temporal_hints = if (options) |opts| boolField(&opts, "temporalHints") orelse false else false;
        const fact_keys = if (options) |opts| boolField(&opts, "factKeys") orelse false else false;
        const with_facts = if (options) |opts| boolField(&opts, "facts") orelse false else false;
        const retrieve_mode = parseRetrieveMode(stringField(params, "mode"), self.store.capabilities()) orelse {
            return errorResponse(allocator, id, "invalid_request", "mode must be fts, vector, hybrid, or graph");
        };
        const rerank_settings = parseRerankSettings(options) orelse {
            return errorResponse(allocator, id, "invalid_request", "options.rerankCandidates must be a positive integer");
        };
        const expansion_mode = parseQueryExpansion(options) orelse {
            return errorResponse(allocator, id, "invalid_request", "options.queryExpansion must be off, rules, or llm");
        };

        // The question is embedded once, for the search and for choosing a
        // pattern node.
        if (retrieve_mode == .vector or retrieve_mode == .hybrid) self.store.prefetchEmbeddings(&.{query}) catch {};
        defer self.store.clearPrefetchedEmbeddings();
        var expansion = try self.expandQuery(allocator, query, expansion_mode);
        defer expansion.deinit();
        var results = try self.collectExpandedItems(allocator, &expansion, retrieve_mode, retrieval_candidate_limit, .{
            .scope = scope,
            .valid_at = valid_at,
            .event_window = event_window,
            .include_evidence = include_evidence,
            .include_debug = include_trace,
        }, fact_keys);
        defer results.deinit();
        // A question that names a time is answered from what was said then.
        var time_anchors_trace: ?TimeAnchorsTrace = try self.applyTimeAnchors(allocator, &results, query, retrieve_mode, .{
            .scope = scope,
            .valid_at = valid_at,
            .event_window = event_window,
            .include_evidence = include_evidence,
            .include_debug = include_trace,
        }, fact_keys, @intCast(budget));
        if (time_anchors_trace.?.windows == 0) time_anchors_trace = null;
        if (needsIncludes(needs_value, "core")) {
            try self.appendCoreItems(allocator, &results, scope, include_evidence, include_trace);
        }
        const candidate_count = results.items.items.len;
        const dropped_for_needs = results.filterByNeeds(needs_value);
        results.applyRawEvidencePolicy();
        var rerank = try self.rerankItems(allocator, query, &results, rerank_settings);
        defer if (rerank) |*stage| stage.deinit();
        var facts = try self.collectFactItems(allocator, with_facts, query, retrieve_mode, .{
            .scope = scope,
            .valid_at = valid_at,
            .include_evidence = include_evidence,
            .include_debug = include_trace,
        }, needs_value, @intCast(budget));
        defer facts.items.deinit();
        var owned_pattern = try self.collectPatternItems(allocator, query, .{
            .scope = scope,
            .valid_at = valid_at,
            .include_evidence = include_evidence,
            .include_debug = include_trace,
        }, needs_value, @intCast(budget));
        defer owned_pattern.items.deinit();
        // Memory is read from the top: the topics nearest the question, and
        // raw evidence from the sessions they and the session summaries
        // point at.
        const evidence_budget = @as(usize, @intCast(budget)) - facts.trace.tokens - owned_pattern.trace.tokens;
        var threads = try self.collectThreadItems(allocator, query, .{
            .scope = scope,
            .valid_at = valid_at,
            .include_evidence = include_evidence,
            .include_debug = include_trace,
        }, needs_value, evidence_budget, fact_keys, &results);
        defer threads.deinit();
        const dropped_for_budget = try results.applySessionTokenBudget(
            evidence_budget - threads.trace.tokens,
            &threads,
            evidence_budget * summaries.session_summary_percent / 100,
        );
        try results.adopt(&facts.items);
        try results.adopt(&owned_pattern.items);
        try results.adopt(&threads.items);

        var warnings = std.ArrayList([]const u8).empty;
        defer warnings.deinit(allocator);
        if (dropped_for_budget > 0) {
            try warnings.append(allocator, "token_budget_truncated");
        }
        if (results.items.items.len == 0) {
            try warnings.append(allocator, "no_memory_items");
        }
        if (rerank) |*stage| {
            if (stage.failed()) try warnings.append(allocator, "rerank_failed");
        }
        if (expansion.failed()) try warnings.append(allocator, "query_expansion_failed");
        try appendRetrievalWarnings(allocator, &warnings, results.items.items, include_evidence);

        var context = try OwnedContextPacket.fromItems(allocator, results.items.items, warnings.items);
        defer context.deinit();

        const retrieval_id = try self.nextQid(allocator, "retr");
        defer allocator.free(retrieval_id);
        const hint_date = temporalHintDate(temporal_hints, valid_at);
        const question_date = temporalHintDate(true, valid_at);
        const time_references = try timeReferencesForQuery(allocator, query, question_date);
        defer if (time_references) |text| allocator.free(text);
        const prompt = try promptFromContext(allocator, self.store, context.view(), .{
            .current_date = valid_at,
            .hint_date = hint_date,
            .time_references = time_references,
            .question = query,
            .question_date = question_date,
            .session_titles = &threads.session_titles,
        });
        defer allocator.free(prompt);
        const token_estimate = estimatePromptTokens(prompt);
        const score_breakdowns = try buildScoreBreakdowns(allocator, results.items.items);
        defer allocator.free(score_breakdowns);
        const scoring_details = try buildScoringDetails(allocator, results.items.items);
        defer allocator.free(scoring_details);
        const dropped_item_reasons = try buildDroppedItemReasons(allocator, dropped_for_needs, dropped_for_budget);
        defer allocator.free(dropped_item_reasons);
        const expansion_trace = try expansion.traceView();
        const trace = RetrievalTrace{
            .query = query,
            .requestedNeedsCount = needsCount(needs_value),
            .budgetTokens = budget,
            .candidateSources = retrievalCandidateSources(retrieve_mode, candidate_count, context.core.items.len),
            .candidateCount = candidate_count,
            .keptCount = results.items.items.len,
            .droppedForNeeds = dropped_for_needs,
            .droppedForBudget = dropped_for_budget,
            .tokenEstimate = token_estimate,
            .validAt = valid_at,
            .scoreBreakdowns = score_breakdowns,
            .scoringDetails = scoring_details,
            .droppedItemReasons = dropped_item_reasons,
            .rerank = if (rerank) |*stage| stage.view() else null,
            .factKeys = results.factKeysTrace(),
            .queryExpansion = expansion_trace,
            .facts = if (with_facts) facts.trace else null,
            .patterns = if (owned_pattern.trace.candidates > 0) owned_pattern.trace else null,
            .threads = if (threads.active) threads.trace else null,
            .timeAnchors = time_anchors_trace,
        };

        const item_qids = try allocator.alloc([]const u8, results.items.items.len);
        defer allocator.free(item_qids);
        for (results.items.items, 0..) |item, index| {
            item_qids[index] = item.qid;
        }

        const event_payload = try stringifyAlloc(allocator, .{
            .method = "memory.retrieve",
            .retrievalId = retrieval_id,
            .query = query,
            .itemCount = results.items.items.len,
            .itemQids = item_qids,
            .tokenEstimate = token_estimate,
            .warnings = warnings.items,
            .traceLogged = log_retrieval,
        });
        defer allocator.free(event_payload);
        if (log_retrieval) {
            if (self.publishEvent(streams.retrieval_logged, event_payload)) |_| {} else |_| {
                if (!containsWarning(warnings.items, "retrieval_stream_write_failed")) {
                    try warnings.append(allocator, "retrieval_stream_write_failed");
                }
            }
        }
        if (log_audit) {
            if (self.publishEvent(streams.audit, event_payload)) |_| {} else |_| {
                if (!containsWarning(warnings.items, "retrieval_stream_write_failed")) {
                    try warnings.append(allocator, "retrieval_stream_write_failed");
                }
            }
        }

        const response = .{
            .jsonrpc = "2.0",
            .id = id,
            .result = .{
                .retrievalId = retrieval_id,
                .prompt = prompt,
                .context = context.view(),
                .items = results.items.items,
                .tokenEstimate = token_estimate,
                .confidence = if (results.items.items.len > 0) @as(f32, 0.72) else @as(f32, 0.0),
                .warnings = warnings.items,
                .trace = if (include_trace) trace else null,
            },
        };
        return stringifyAlloc(allocator, response);
    }

    fn memoryAnswer(self: *Runtime, allocator: std.mem.Allocator, id: ?[]const u8, params: *const ObjectMap) ![]u8 {
        const query = stringField(params, "query") orelse {
            return errorResponse(allocator, id, "invalid_request", "query must be a non-empty string");
        };
        if (query.len == 0) {
            return errorResponse(allocator, id, "invalid_request", "query must be a non-empty string");
        }
        const budget = integerField(params, "budgetTokens") orelse default_budget_tokens;
        if (budget < 1) {
            return errorResponse(allocator, id, "invalid_request", "budgetTokens must be positive");
        }

        const scope = parseScope(params);
        const valid_at = parseValidAt(params);
        const event_window = parseEventWindow(params);
        const needs_value = params.get("needs");
        const options = objectField(params, "options");
        const include_evidence = if (options) |opts| boolField(&opts, "includeEvidence") orelse true else true;
        const include_trace = if (options) |opts| (boolField(&opts, "includeDebug") orelse false) or (boolField(&opts, "logTrace") orelse false) else false;
        const abstain_if_weak = if (options) |opts| boolField(&opts, "abstainIfWeak") orelse false else false;
        const reader_reasoning = if (options) |opts| boolField(&opts, "readerReasoning") orelse false else false;
        const temporal_hints = if (options) |opts| boolField(&opts, "temporalHints") orelse false else false;
        const fact_keys = if (options) |opts| boolField(&opts, "factKeys") orelse false else false;
        const with_facts = if (options) |opts| boolField(&opts, "facts") orelse false else false;
        const log_retrieval = if (options) |opts| boolField(&opts, "logRetrieval") orelse (boolField(&opts, "logTrace") orelse true) else true;
        const retrieve_mode = parseRetrieveMode(stringField(params, "mode"), self.store.capabilities()) orelse {
            return errorResponse(allocator, id, "invalid_request", "mode must be fts, vector, hybrid, or graph");
        };
        const rerank_settings = parseRerankSettings(options) orelse {
            return errorResponse(allocator, id, "invalid_request", "options.rerankCandidates must be a positive integer");
        };
        const expansion_mode = parseQueryExpansion(options) orelse {
            return errorResponse(allocator, id, "invalid_request", "options.queryExpansion must be off, rules, or llm");
        };

        // The question is embedded once, for the search and for choosing a
        // pattern node.
        if (retrieve_mode == .vector or retrieve_mode == .hybrid) self.store.prefetchEmbeddings(&.{query}) catch {};
        defer self.store.clearPrefetchedEmbeddings();
        var expansion = try self.expandQuery(allocator, query, expansion_mode);
        defer expansion.deinit();
        var results = try self.collectExpandedItems(allocator, &expansion, retrieve_mode, retrieval_candidate_limit, .{
            .scope = scope,
            .valid_at = valid_at,
            .event_window = event_window,
            .include_evidence = include_evidence,
            .include_debug = include_trace,
        }, fact_keys);
        defer results.deinit();
        // A question that names a time is answered from what was said then.
        var time_anchors_trace: ?TimeAnchorsTrace = try self.applyTimeAnchors(allocator, &results, query, retrieve_mode, .{
            .scope = scope,
            .valid_at = valid_at,
            .event_window = event_window,
            .include_evidence = include_evidence,
            .include_debug = include_trace,
        }, fact_keys, @intCast(budget));
        if (time_anchors_trace.?.windows == 0) time_anchors_trace = null;
        if (needsIncludes(needs_value, "core")) {
            try self.appendCoreItems(allocator, &results, scope, include_evidence, include_trace);
        }
        const candidate_count = results.items.items.len;
        const dropped_for_needs = results.filterByNeeds(needs_value);
        results.applyRawEvidencePolicy();
        var rerank = try self.rerankItems(allocator, query, &results, rerank_settings);
        defer if (rerank) |*stage| stage.deinit();
        var facts = try self.collectFactItems(allocator, with_facts, query, retrieve_mode, .{
            .scope = scope,
            .valid_at = valid_at,
            .include_evidence = include_evidence,
            .include_debug = include_trace,
        }, needs_value, @intCast(budget));
        defer facts.items.deinit();
        var owned_pattern = try self.collectPatternItems(allocator, query, .{
            .scope = scope,
            .valid_at = valid_at,
            .include_evidence = include_evidence,
            .include_debug = include_trace,
        }, needs_value, @intCast(budget));
        defer owned_pattern.items.deinit();
        // Memory is read from the top: the topics nearest the question, and
        // raw evidence from the sessions they and the session summaries
        // point at.
        const evidence_budget = @as(usize, @intCast(budget)) - facts.trace.tokens - owned_pattern.trace.tokens;
        var threads = try self.collectThreadItems(allocator, query, .{
            .scope = scope,
            .valid_at = valid_at,
            .include_evidence = include_evidence,
            .include_debug = include_trace,
        }, needs_value, evidence_budget, fact_keys, &results);
        defer threads.deinit();
        const dropped_for_budget = try results.applySessionTokenBudget(
            evidence_budget - threads.trace.tokens,
            &threads,
            evidence_budget * summaries.session_summary_percent / 100,
        );
        try results.adopt(&facts.items);
        try results.adopt(&owned_pattern.items);
        try results.adopt(&threads.items);

        var warnings = std.ArrayList([]const u8).empty;
        defer warnings.deinit(allocator);
        if (dropped_for_budget > 0) try warnings.append(allocator, "token_budget_truncated");
        if (results.items.items.len == 0) try warnings.append(allocator, "no_memory_items");
        if (rerank) |*stage| {
            if (stage.failed()) try warnings.append(allocator, "rerank_failed");
        }
        if (expansion.failed()) try warnings.append(allocator, "query_expansion_failed");

        try appendRetrievalWarnings(allocator, &warnings, results.items.items, include_evidence);

        // Reserve room for answer warnings so the context packet's view of
        // `warnings.items` is never invalidated by a later append.
        try warnings.ensureUnusedCapacity(allocator, 8);
        var context = try OwnedContextPacket.fromItems(allocator, results.items.items, warnings.items);
        defer context.deinit();

        const retrieval_id = try self.nextQid(allocator, "retr");
        defer allocator.free(retrieval_id);
        // The question date (and the query's resolved
        // time references) travels in the reader's user turn, not inside the
        // untrusted memory block.
        const hint_date = temporalHintDate(temporal_hints, valid_at);
        const question_date = temporalHintDate(true, valid_at);
        const time_references = try timeReferencesForQuery(allocator, query, question_date);
        defer if (time_references) |text| allocator.free(text);
        const prompt = try promptFromContext(allocator, self.store, context.view(), .{
            .hint_date = hint_date,
            .question = query,
            .question_date = question_date,
            .session_titles = &threads.session_titles,
        });
        defer allocator.free(prompt);
        const token_estimate = estimatePromptTokens(prompt);
        const score_breakdowns = try buildScoreBreakdowns(allocator, results.items.items);
        defer allocator.free(score_breakdowns);
        const scoring_details = try buildScoringDetails(allocator, results.items.items);
        defer allocator.free(scoring_details);
        const dropped_item_reasons = try buildDroppedItemReasons(allocator, dropped_for_needs, dropped_for_budget);
        defer allocator.free(dropped_item_reasons);
        const expansion_trace = try expansion.traceView();
        const trace = RetrievalTrace{
            .query = query,
            .requestedNeedsCount = needsCount(needs_value),
            .budgetTokens = budget,
            .candidateSources = retrievalCandidateSources(retrieve_mode, candidate_count, context.core.items.len),
            .candidateCount = candidate_count,
            .keptCount = results.items.items.len,
            .droppedForNeeds = dropped_for_needs,
            .droppedForBudget = dropped_for_budget,
            .tokenEstimate = token_estimate,
            .validAt = valid_at,
            .scoreBreakdowns = score_breakdowns,
            .scoringDetails = scoring_details,
            .droppedItemReasons = dropped_item_reasons,
            .rerank = if (rerank) |*stage| stage.view() else null,
            .factKeys = results.factKeysTrace(),
            .queryExpansion = expansion_trace,
            .facts = if (with_facts) facts.trace else null,
            .patterns = if (owned_pattern.trace.candidates > 0) owned_pattern.trace else null,
            .threads = if (threads.active) threads.trace else null,
            .timeAnchors = time_anchors_trace,
        };

        // One answer path: with a reader configured, every non-empty context
        // goes to it; with no evidence nothing is called and the answer abstains;
        // with no reader the synthesizer uses its deterministic fallback.
        const endpoint = if (self.options.answer_provider.kind == .none)
            providers.ProviderEndpoint{ .kind = .deterministic, .name = "deterministic_prompt" }
        else
            self.options.answer_provider;
        const reader_configured = endpoint.kind != .none and endpoint.kind != .deterministic;
        const current_date = if (valid_at) |timestamp| try formatCurrentDate(allocator, timestamp) else null;
        defer if (current_date) |value| allocator.free(value);
        const raw_provider_answer = if (!reader_configured or results.items.items.len == 0)
            null
        else
            providers.generateAnswer(allocator, self.options.io, endpoint, .{
                .question = query,
                .context = prompt,
                .current_date = current_date,
                .time_references = time_references,
                .reasoning = reader_reasoning,
            }) catch |err| {
                const message = if (err == error.MissingProviderApiKey)
                    try std.fmt.allocPrint(
                        allocator,
                        "answer provider '{s}' is missing an API key; set {s} or QUIPU_LLM_API_KEY",
                        .{ endpoint.name, providers.apiKeyEnvName(endpoint.name) orelse "QUIPU_LLM_API_KEY" },
                    )
                else if (err == error.InvalidProviderConfig)
                    try std.fmt.allocPrint(allocator, "answer provider '{s}' is not fully configured; set --llm-provider, --llm-model, and --llm-base-url as needed", .{endpoint.name})
                else
                    try std.fmt.allocPrint(allocator, "answer provider '{s}' failed: {s}", .{ endpoint.name, @errorName(err) });
                defer allocator.free(message);
                return errorResponse(allocator, id, "provider_error", message);
            };
        defer if (raw_provider_answer) |value| allocator.free(value);

        const evidence_packet = try buildAnswerEvidencePacket(allocator, results.items.items);
        defer freeAnswerEvidencePacket(allocator, evidence_packet);
        var synthesized = try answer_synthesis.synthesize(allocator, evidence_packet, raw_provider_answer, .{
            .abstain_if_weak = abstain_if_weak,
            .reader_reasoning = reader_reasoning,
        });
        defer synthesized.deinit();
        synthesized.trace.temporalHints = hint_date != null;
        synthesized.trace.timeReferences = time_references;
        synthesized.trace.queryExpansion = expansion_trace;
        for (synthesized.trace.validation.warnings) |warning| {
            if (!containsWarning(warnings.items, warning)) try warnings.append(allocator, warning);
        }

        const item_qids = try allocator.alloc([]const u8, results.items.items.len);
        defer allocator.free(item_qids);
        for (results.items.items, 0..) |item, index| {
            item_qids[index] = item.qid;
        }
        if (log_retrieval) {
            const event_payload = try stringifyAlloc(allocator, .{
                .method = "memory.answer",
                .retrievalId = retrieval_id,
                .query = query,
                .itemCount = results.items.items.len,
                .itemQids = item_qids,
                .tokenEstimate = token_estimate,
                .provider = endpoint.name,
                .model = endpoint.model,
                .strategy = synthesized.trace.strategy,
                .answerable = synthesized.trace.answerable,
                .supportValid = synthesized.trace.supportValid,
            });
            defer allocator.free(event_payload);
            if (self.publishEvent(streams.retrieval_logged, event_payload)) |_| {} else |_| {
                if (!containsWarning(warnings.items, "retrieval_stream_write_failed")) {
                    try warnings.append(allocator, "retrieval_stream_write_failed");
                }
            }
        }

        const include_debug = if (options) |opts| boolField(&opts, "includeDebug") orelse false else false;
        const response = .{
            .jsonrpc = "2.0",
            .id = id,
            .result = .{
                .retrievalId = retrieval_id,
                .answer = synthesized.answer,
                .provider = endpoint.name,
                .model = endpoint.model,
                .prompt = if (include_debug) prompt else null,
                .context = context.view(),
                .items = results.items.items,
                .tokenEstimate = token_estimate,
                .confidence = synthesized.confidence,
                .warnings = warnings.items,
                .trace = if (include_trace) trace else null,
                .answerTrace = if (include_trace) synthesized.trace else null,
            },
        };
        return stringifyAlloc(allocator, response);
    }

    fn memoryPatternsRun(self: *Runtime, allocator: std.mem.Allocator, id: ?[]const u8, params: *const ObjectMap) ![]u8 {
        const owner = stringField(params, "owner") orelse "pattern-runner";
        const requested_limit = integerField(params, "limit") orelse 100000;
        if (requested_limit < 1) {
            return errorResponse(allocator, id, "invalid_request", "limit must be positive");
        }
        if (!extractProviderUsable(self.patternProvider())) {
            return errorResponse(allocator, id, "provider_error", "no extract provider configured; set --extract-provider or --llm-provider");
        }
        const result = try self.runPatternJobs(allocator, owner, @intCast(requested_limit));
        const response = .{
            .jsonrpc = "2.0",
            .id = id,
            .result = .{
                .leasedCount = result.leasedCount,
                .succeededCount = result.succeededCount,
                .failedCount = result.failedCount,
                .lastError = result.lastError,
                .provider = self.patternProvider().name,
                .model = self.patternProvider().model,
                .promptVersion = patterns.prompt_version,
                .calls = result.calls,
                .scopes = result.scopes,
                .counts = result.counts,
            },
        };
        return stringifyAlloc(allocator, response);
    }

    fn memorySummariesRun(self: *Runtime, allocator: std.mem.Allocator, id: ?[]const u8, params: *const ObjectMap) ![]u8 {
        const owner = stringField(params, "owner") orelse "summary-runner";
        const requested_limit = integerField(params, "limit") orelse 100000;
        if (requested_limit < 1) {
            return errorResponse(allocator, id, "invalid_request", "limit must be positive");
        }
        if (!extractProviderUsable(self.options.extract_provider)) {
            return errorResponse(allocator, id, "provider_error", "no extract provider configured; set --extract-provider or --llm-provider");
        }
        const result = try self.runSummaryJobs(allocator, owner, @intCast(requested_limit));
        const response = .{
            .jsonrpc = "2.0",
            .id = id,
            .result = .{
                .leasedCount = result.leasedCount,
                .succeededCount = result.succeededCount,
                .failedCount = result.failedCount,
                .lastError = result.lastError,
                .provider = self.options.extract_provider.name,
                .model = self.options.extract_provider.model,
                .promptVersion = summaries.prompt_version,
                .calls = result.calls,
                .scopes = result.scopes,
                .counts = result.counts,
            },
        };
        return stringifyAlloc(allocator, response);
    }

    fn memoryInspect(self: *Runtime, allocator: std.mem.Allocator, id: ?[]const u8, params: *const ObjectMap) ![]u8 {
        const qid = stringField(params, "qid") orelse {
            return errorResponse(allocator, id, "invalid_request", "qid is required");
        };
        const node = (try self.store.getNode(allocator, qid)) orelse {
            return errorResponse(allocator, id, "not_found", "memory not found");
        };
        defer self.store.freeNode(allocator, node);

        var provenance = try self.provenanceRefsForNode(allocator, node);
        defer provenance.deinit();
        var dependents = try self.derivedRefsByEvidence(allocator, qid);
        defer dependents.deinit();
        var audit = try self.auditEventsForQid(allocator, qid);
        defer audit.deinit();

        const response = .{
            .jsonrpc = "2.0",
            .id = id,
            .result = .{
                .node = .{
                    .qid = node.qid,
                    .type = labelType(node.label),
                    .properties = .{ .rawJson = node.properties_json },
                },
                .provenance = provenance.items.items,
                .dependents = dependents.items.items,
                .audit = audit.items.items,
            },
        };
        return stringifyAlloc(allocator, response);
    }

    fn memoryForget(self: *Runtime, allocator: std.mem.Allocator, id: ?[]const u8, params: *const ObjectMap) ![]u8 {
        const selector = objectField(params, "selector") orelse {
            return errorResponse(allocator, id, "invalid_request", "selector is required");
        };
        const mode = stringField(params, "mode") orelse {
            return errorResponse(allocator, id, "invalid_request", "mode is required");
        };
        if (!std.mem.eql(u8, mode, "hard_delete") and !std.mem.eql(u8, mode, "redact") and !std.mem.eql(u8, mode, "expire")) {
            return errorResponse(allocator, id, "invalid_request", "mode must be hard_delete, redact, or expire");
        }
        const dry_run = boolField(params, "dryRun") orelse false;
        const propagate = boolField(params, "propagate") orelse true;
        const reason = stringField(params, "reason") orelse "unspecified";
        const selector_scope = parseScope(&selector);
        const selector_window = parseSelectorTimeWindow(&selector);
        if (arrayValue(selector.get("qids")) == null and stringField(&selector, "query") == null) {
            return errorResponse(allocator, id, "invalid_request", "selector.qids or selector.query is required");
        }

        var selected_qids = OwnedQids{ .allocator = allocator };
        defer selected_qids.deinit();
        try self.collectForgetRoots(allocator, &selector, selector_scope, selector_window, &selected_qids);

        var roots_matched: usize = 0;
        var nodes_deleted: usize = 0;
        var nodes_redacted: usize = 0;
        var facts_invalidated: usize = 0;
        var summaries_contaminated: usize = 0;
        var report = OwnedForgetReport{ .allocator = allocator };
        defer report.deinit();
        var contaminated_core_qids = OwnedQids{ .allocator = allocator };
        defer contaminated_core_qids.deinit();
        // Every node this request forgets, so one reached from several roots
        // is reported and tombstoned once.
        var handled = forgetting.QidList.init(allocator);
        defer handled.deinit();
        for (selected_qids.items.items) |qid| _ = try handled.appendUnique(qid);
        // Scopes that lose a pattern node to this request; each is rebuilt
        // from the messages that remain.
        var pattern_arena_state = std.heap.ArenaAllocator.init(allocator);
        defer pattern_arena_state.deinit();
        const pattern_arena = pattern_arena_state.allocator();
        var pattern_scopes: std.StringArrayHashMapUnmanaged(Scope) = .empty;
        var summary_scopes: std.StringArrayHashMapUnmanaged(Scope) = .empty;

        const root_action: []const u8 = if (dry_run)
            if (std.mem.eql(u8, mode, "redact")) "would_redact" else "would_delete"
        else if (std.mem.eql(u8, mode, "redact"))
            "redacted"
        else
            "deleted";
        const dependent_action: []const u8 = if (dry_run) "would_invalidate" else "invalidated";
        const core_action: []const u8 = if (dry_run) "would_contaminate" else "contaminated";

        for (selected_qids.items.items) |qid| {
            const node = (try self.store.getNode(allocator, qid)) orelse continue;
            defer self.store.freeNode(allocator, node);
            roots_matched += 1;
            try report.append(allocator, qid, labelType(node.label), root_action);

            // The root and its chunks: the evidence the closure starts from.
            var forgotten = forgetting.QidList.init(allocator);
            defer forgotten.deinit();
            _ = try forgotten.appendUnique(qid);
            // Chunks hold the message's raw text, so they are forgotten with
            // it regardless of `propagate`.
            const chunk_count = if (std.mem.eql(u8, node.label, "Message"))
                try self.forgetMessageChunks(allocator, qid, reason, mode, dry_run, &report, root_action, &handled, &forgotten)
            else
                0;

            if (!dry_run) {
                try self.tombstoneNode(allocator, node, reason, mode);
                if (std.mem.eql(u8, mode, "redact")) {
                    nodes_redacted += 1 + chunk_count;
                } else {
                    nodes_deleted += 1 + chunk_count;
                }
            }
            if (!propagate) continue;

            var dependents = try self.dependentClosure(allocator, forgotten.items.items, &handled);
            defer dependents.deinit();
            try self.appendOrphanedEntities(allocator, forgotten.items.items, &handled, &dependents);
            for (dependents.items.items) |dependent| {
                if (isFactLikeType(dependent.type)) facts_invalidated += 1;
                try report.append(allocator, dependent.qid, dependent.type, dependent_action);
            }
            for (forgotten.items.items) |source| {
                try self.appendCoreClosureRefs(allocator, source, &contaminated_core_qids, &handled, &report, core_action);
            }
            for (dependents.items.items) |dependent| {
                try self.appendCoreClosureRefs(allocator, dependent.qid, &contaminated_core_qids, &handled, &report, core_action);
            }
            if (!dry_run) {
                for (dependents.items.items) |dependent| {
                    if (std.mem.eql(u8, dependent.type, "pattern")) {
                        if (try self.store.getNode(pattern_arena, dependent.qid)) |pattern_node| {
                            const pattern_scope = try scopeOfNode(pattern_arena, pattern_node);
                            try pattern_scopes.put(pattern_arena, try scopeKey(pattern_arena, pattern_scope), pattern_scope);
                        }
                    }
                    if (std.mem.eql(u8, dependent.type, "summary")) {
                        if (try self.store.getNode(pattern_arena, dependent.qid)) |summary_node| {
                            const summary_scope = try scopeOfNode(pattern_arena, summary_node);
                            try summary_scopes.put(pattern_arena, try scopeKey(pattern_arena, summary_scope), summary_scope);
                        }
                    }
                    try self.tombstoneQid(allocator, dependent.qid, reason, "hard_delete");
                }
            }
        }
        for (pattern_scopes.values()) |pattern_scope| try self.queuePatternJob(allocator, pattern_scope);
        for (summary_scopes.values()) |summary_scope| try self.queueSummaryJob(allocator, summary_scope);
        summaries_contaminated = contaminated_core_qids.items.items.len;
        if (!dry_run and propagate) {
            for (contaminated_core_qids.items.items) |core_qid| {
                try self.tombstoneQid(allocator, core_qid, reason, mode);
            }
        }

        const deletion_qid = try self.nextQid(allocator, "del");
        defer allocator.free(deletion_qid);
        const status = if (dry_run) "planned" else "completed";
        const event_payload = try stringifyAlloc(allocator, .{
            .method = "memory.forget",
            .deletionRequestQid = deletion_qid,
            .status = status,
            .dryRun = dry_run,
            .rootsMatched = roots_matched,
            .nodesDeleted = nodes_deleted,
            .nodesRedacted = nodes_redacted,
            .factsInvalidated = facts_invalidated,
            .summariesContaminated = summaries_contaminated,
            .reason = reason,
            .report = report.items.items,
        });
        defer allocator.free(event_payload);
        _ = try self.publishEvent(streams.forget_completed, event_payload);
        _ = try self.publishEvent(streams.audit, event_payload);

        const response = .{
            .jsonrpc = "2.0",
            .id = id,
            .result = .{
                .deletionRequestQid = deletion_qid,
                .status = status,
                .dryRun = dry_run,
                .rootsMatched = roots_matched,
                .nodesDeleted = nodes_deleted,
                .nodesRedacted = nodes_redacted,
                .factsInvalidated = facts_invalidated,
                .summariesContaminated = summaries_contaminated,
                .jobsQueued = &[_][]const u8{},
                .report = report.items.items,
            },
        };
        return stringifyAlloc(allocator, response);
    }

    fn collectForgetRoots(
        self: *Runtime,
        allocator: std.mem.Allocator,
        selector: *const ObjectMap,
        scope: Scope,
        window: EventWindow,
        selected_qids: *OwnedQids,
    ) !void {
        if (arrayValue(selector.get("qids"))) |qids| {
            for (qids.items) |qid_value| {
                const qid = stringValue(qid_value) orelse continue;
                try self.selectForgetRoot(allocator, qid, scope, window, selected_qids, false);
            }
        }

        const query = stringField(selector, "query") orelse return;
        if (query.len == 0) return;
        // Every match, not a top-k: a forget selector must not miss evidence
        // because it ranked low.
        const hits = try self.store.fullTextSearch(allocator, .{ .text = query, .limit = storage.unlimited });
        defer freeHits(allocator, hits);
        for (hits) |hit| {
            try self.selectForgetRoot(allocator, hit.qid, scope, window, selected_qids, true);
        }
    }

    /// Adds `qid` as a forget root. A chunk resolves to its parent message so
    /// the whole message and all of its chunks are forgotten together, and a
    /// Session or Turn root also selects the messages it contains.
    fn selectForgetRoot(
        self: *Runtime,
        allocator: std.mem.Allocator,
        qid: []const u8,
        scope: Scope,
        window: EventWindow,
        selected_qids: *OwnedQids,
        from_query: bool,
    ) !void {
        var node = (try self.store.getNode(allocator, qid)) orelse return;
        defer self.store.freeNode(allocator, node);
        if (std.mem.eql(u8, node.label, "Chunk")) {
            const parent_qid = (try readOptionalPropertyString(allocator, node.properties_json, "messageQid")) orelse return;
            defer allocator.free(parent_qid);
            const parent = (try self.store.getNode(allocator, parent_qid)) orelse return;
            self.store.freeNode(allocator, node);
            node = parent;
        }
        if (from_query and isInternalLabel(node.label)) return;
        if (try propertyBool(allocator, node.properties_json, "deleted")) return;
        if (!try scope.matchesNode(allocator, node)) return;
        if (!try nodeWithinEventWindow(allocator, node, window)) return;
        try selected_qids.appendUnique(allocator, node.qid);

        if (std.mem.eql(u8, node.label, "Session")) {
            const turn_edges = try self.store.findEdges(allocator, .{ .from_qid = node.qid, .edge_type = "HAS_TURN", .limit = storage.unlimited });
            defer self.store.freeEdges(allocator, turn_edges);
            for (turn_edges) |edge| {
                try self.selectTurnMessages(allocator, edge.to_qid, selected_qids);
            }
        } else if (std.mem.eql(u8, node.label, "Turn")) {
            try self.selectTurnMessages(allocator, node.qid, selected_qids);
        }
    }

    fn selectTurnMessages(self: *Runtime, allocator: std.mem.Allocator, turn_qid: []const u8, selected_qids: *OwnedQids) !void {
        const message_edges = try self.store.findEdges(allocator, .{ .from_qid = turn_qid, .edge_type = "HAS_MESSAGE", .limit = storage.unlimited });
        defer self.store.freeEdges(allocator, message_edges);
        for (message_edges) |edge| {
            const message = (try self.store.getNode(allocator, edge.to_qid)) orelse continue;
            defer self.store.freeNode(allocator, message);
            if (!std.mem.eql(u8, message.label, "Message")) continue;
            if (try propertyBool(allocator, message.properties_json, "deleted")) continue;
            try selected_qids.appendUnique(allocator, message.qid);
        }
    }

    /// Tombstones (or, on a dry run, only reports) every live chunk of a
    /// message, and adds each to `forgotten`. Uses HAS_CHUNK edges rather
    /// than node enumeration.
    fn forgetMessageChunks(
        self: *Runtime,
        allocator: std.mem.Allocator,
        message_qid: []const u8,
        reason: []const u8,
        mode: []const u8,
        dry_run: bool,
        report: *OwnedForgetReport,
        action: []const u8,
        handled: *forgetting.QidList,
        forgotten: *forgetting.QidList,
    ) !usize {
        const chunk_edges = try self.store.findEdges(allocator, .{ .from_qid = message_qid, .edge_type = "HAS_CHUNK", .limit = storage.unlimited });
        defer self.store.freeEdges(allocator, chunk_edges);
        var count: usize = 0;
        for (chunk_edges) |edge| {
            const chunk = (try self.store.getNode(allocator, edge.to_qid)) orelse continue;
            defer self.store.freeNode(allocator, chunk);
            if (!std.mem.eql(u8, chunk.label, "Chunk")) continue;
            if (try propertyBool(allocator, chunk.properties_json, "deleted")) continue;
            _ = try forgotten.appendUnique(chunk.qid);
            if (!try handled.appendUnique(chunk.qid)) continue;
            try report.append(allocator, chunk.qid, "chunk", action);
            if (!dry_run) try self.tombstoneNode(allocator, chunk, reason, mode);
            count += 1;
        }
        return count;
    }

    /// Live nodes derived from any of `seeds`, transitively and whatever their
    /// label: anything with an EVIDENCED_BY or DERIVED_FROM edge (or an
    /// `evidenceQid`) to forgotten evidence, then anything derived from those.
    /// Chunks are raw parts of their message, forgotten with it, so they are
    /// never dependents. Skips and records nodes in `handled`.
    fn dependentClosure(
        self: *Runtime,
        allocator: std.mem.Allocator,
        seeds: []const []const u8,
        handled: *forgetting.QidList,
    ) !OwnedNodeRefs {
        var refs = OwnedNodeRefs{ .allocator = allocator };
        errdefer refs.deinit();
        var queue = forgetting.QidList.init(allocator);
        defer queue.deinit();
        for (seeds) |seed| _ = try queue.appendUnique(seed);

        var position: usize = 0;
        while (position < queue.items.items.len) : (position += 1) {
            var direct = try forgetting.dependentQids(allocator, self.store, queue.items.items[position]);
            defer direct.deinit();
            for (direct.items.items) |dependent_qid| {
                if (handled.contains(dependent_qid)) continue;
                const node = (try self.store.getNode(allocator, dependent_qid)) orelse continue;
                defer self.store.freeNode(allocator, node);
                if (std.mem.eql(u8, node.label, "Chunk")) continue;
                if (try propertyBool(allocator, node.properties_json, "deleted")) continue;
                _ = try handled.appendUnique(dependent_qid);
                try refs.append(allocator, dependent_qid, labelType(node.label), "derived_from");
                _ = try queue.appendUnique(dependent_qid);
            }
        }
        return refs;
    }

    /// Adds to `dependents` each live entity that `sources` mention and that
    /// no node outside this request mentions: its name came only from
    /// forgotten text.
    fn appendOrphanedEntities(
        self: *Runtime,
        allocator: std.mem.Allocator,
        sources: []const []const u8,
        handled: *forgetting.QidList,
        dependents: *OwnedNodeRefs,
    ) !void {
        const Context = struct {
            handled: *const forgetting.QidList,

            fn isForgotten(context: @This(), inner_allocator: std.mem.Allocator, store: storage.Adapter, qid: []const u8) !bool {
                if (context.handled.contains(qid)) return true;
                const node = (try store.getNode(inner_allocator, qid)) orelse return true;
                defer store.freeNode(inner_allocator, node);
                return propertyBool(inner_allocator, node.properties_json, "deleted");
            }
        };
        for (sources) |source| {
            var entities = try forgetting.orphanedEntityQids(allocator, self.store, source, Context{ .handled = handled }, Context.isForgotten);
            defer entities.deinit();
            for (entities.items.items) |entity_qid| {
                if (handled.contains(entity_qid)) continue;
                const node = (try self.store.getNode(allocator, entity_qid)) orelse continue;
                defer self.store.freeNode(allocator, node);
                if (try propertyBool(allocator, node.properties_json, "deleted")) continue;
                _ = try handled.appendUnique(entity_qid);
                try dependents.append(allocator, entity_qid, labelType(node.label), "mentioned_by");
            }
        }
    }

    /// Adds every live node compiled from `source_qid` (core blocks, through
    /// COMPILED_FROM edges) to the contaminated set.
    fn appendCoreClosureRefs(
        self: *Runtime,
        allocator: std.mem.Allocator,
        source_qid: []const u8,
        contaminated_core_qids: *OwnedQids,
        handled: *const forgetting.QidList,
        report: *OwnedForgetReport,
        action: []const u8,
    ) !void {
        var blocks = try forgetting.compiledFromQids(allocator, self.store, source_qid);
        defer blocks.deinit();
        for (blocks.items.items) |block_qid| {
            if (contaminated_core_qids.contains(block_qid) or handled.contains(block_qid)) continue;
            const node = (try self.store.getNode(allocator, block_qid)) orelse continue;
            defer self.store.freeNode(allocator, node);
            if (try propertyBool(allocator, node.properties_json, "deleted")) continue;
            try contaminated_core_qids.appendUnique(allocator, block_qid);
            try report.append(allocator, block_qid, labelType(node.label), action);
        }
    }

    fn memoryFeedback(self: *Runtime, allocator: std.mem.Allocator, id: ?[]const u8, params: *const ObjectMap) ![]u8 {
        const retrieval_id = stringField(params, "retrievalId") orelse {
            return errorResponse(allocator, id, "invalid_request", "retrievalId is required");
        };
        const rating = stringField(params, "rating") orelse {
            return errorResponse(allocator, id, "invalid_request", "rating is required");
        };
        const feedback_qid = try self.nextQid(allocator, "fb");
        defer allocator.free(feedback_qid);
        const props = try stringifyAlloc(allocator, .{
            .kind = "feedback",
            .retrievalId = retrieval_id,
            .rating = rating,
            .deleted = false,
        });
        defer allocator.free(props);
        try self.store.putNode(.{ .qid = feedback_qid, .label = "Feedback", .properties_json = props });

        const event_payload = try stringifyAlloc(allocator, .{
            .method = "memory.feedback",
            .status = "stored",
            .feedbackQid = feedback_qid,
            .retrievalId = retrieval_id,
            .rating = rating,
        });
        defer allocator.free(event_payload);
        _ = try self.publishEvent(streams.feedback_received, event_payload);
        _ = try self.publishEvent(streams.audit, event_payload);

        const response = .{
            .jsonrpc = "2.0",
            .id = id,
            .result = .{
                .feedbackQid = feedback_qid,
                .queuedJobs = &[_][]const u8{},
                .status = "stored",
            },
        };
        return stringifyAlloc(allocator, response);
    }

    fn memoryCoreUpdate(self: *Runtime, allocator: std.mem.Allocator, id: ?[]const u8, params: *const ObjectMap) ![]u8 {
        const block_key = stringField(params, "blockKey") orelse {
            return errorResponse(allocator, id, "invalid_request", "blockKey is required");
        };
        const text = stringField(params, "text") orelse {
            return errorResponse(allocator, id, "invalid_request", "text is required");
        };
        const mode = stringField(params, "mode") orelse "replace";
        const managed_by = stringField(params, "managedBy") orelse "user";
        const scope = parseScope(params);

        var status: []const u8 = "stored";
        const existing_qid = if (std.mem.eql(u8, mode, "replace")) try self.findCoreBlockQid(allocator, scope, block_key) else null;
        defer if (existing_qid) |qid| allocator.free(qid);

        const block_qid = if (existing_qid) |qid| try allocator.dupe(u8, qid) else try self.nextQid(allocator, "core");
        defer allocator.free(block_qid);
        if (existing_qid != null) status = "updated";

        const props = try stringifyAlloc(allocator, .{
            .kind = "core",
            .blockKey = block_key,
            .text = text,
            .managedBy = managed_by,
            .tenantId = scope.tenant_id,
            .userId = scope.user_id,
            .agentId = scope.agent_id,
            .projectId = scope.project_id,
            .deleted = false,
        });
        defer allocator.free(props);
        try self.store.putNode(.{ .qid = block_qid, .label = "Core", .properties_json = props });

        const event_payload = try stringifyAlloc(allocator, .{
            .method = "memory.core.update",
            .status = status,
            .blockQid = block_qid,
            .blockKey = block_key,
            .managedBy = managed_by,
        });
        defer allocator.free(event_payload);
        _ = try self.publishEvent(streams.audit, event_payload);

        const response = .{
            .jsonrpc = "2.0",
            .id = id,
            .result = .{
                .blockQid = block_qid,
                .status = status,
            },
        };
        return stringifyAlloc(allocator, response);
    }

    fn memoryCoreGet(self: *Runtime, allocator: std.mem.Allocator, id: ?[]const u8, params: *const ObjectMap) ![]u8 {
        const scope = parseScope(params);
        const requested_key = stringField(params, "blockKey");
        const key_match = [_]storage.PropertyMatch{.{ .name = "blockKey", .value = requested_key orelse "" }};
        var core_nodes = self.store.iterateNodes(allocator, .{
            .label = "Core",
            .where = if (requested_key != null) &key_match else &.{},
        });
        defer core_nodes.deinit();

        var blocks = std.ArrayList(CoreBlockResult).empty;
        defer {
            for (blocks.items) |block| {
                allocator.free(block.qid);
                allocator.free(block.blockKey);
                allocator.free(block.text);
                allocator.free(block.managedBy);
                for (block.evidenceQids) |qid| allocator.free(qid);
                allocator.free(block.evidenceQids);
            }
            blocks.deinit(allocator);
        }

        while (try core_nodes.next()) |core_qid| {
            const node = (try self.store.getNode(allocator, core_qid)) orelse continue;
            defer self.store.freeNode(allocator, node);
            if (!std.mem.eql(u8, node.label, "Core")) continue;
            if (try propertyBool(allocator, node.properties_json, "deleted")) continue;
            if (!try scope.matchesNode(allocator, node)) continue;
            const block_key = try readPropertyString(allocator, node.properties_json, "blockKey");
            errdefer allocator.free(block_key);
            if (requested_key) |wanted| {
                if (!std.mem.eql(u8, wanted, block_key)) {
                    allocator.free(block_key);
                    continue;
                }
            }
            const text = try readPropertyString(allocator, node.properties_json, "text");
            errdefer allocator.free(text);
            const managed_by = try readPropertyString(allocator, node.properties_json, "managedBy");
            errdefer allocator.free(managed_by);
            const evidence_qids = try readStringArrayProperty(allocator, node.properties_json, "evidenceQids");
            errdefer {
                for (evidence_qids) |qid| allocator.free(qid);
                allocator.free(evidence_qids);
            }
            try blocks.append(allocator, .{
                .qid = try allocator.dupe(u8, node.qid),
                .blockKey = block_key,
                .scope = scope.json(),
                .text = text,
                .managedBy = managed_by,
                .evidenceQids = evidence_qids,
            });
        }

        const response = .{
            .jsonrpc = "2.0",
            .id = id,
            .result = .{ .blocks = blocks.items },
        };
        return stringifyAlloc(allocator, response);
    }

    fn memoryCoreConsolidate(self: *Runtime, allocator: std.mem.Allocator, id: ?[]const u8, params: *const ObjectMap) ![]u8 {
        const scope = parseScope(params);
        const block_key = stringField(params, "blockKey") orelse "project_summary";
        const requested_limit = integerField(params, "limit") orelse 50;
        if (requested_limit <= 0) {
            return errorResponse(allocator, id, "invalid_request", "limit must be greater than zero");
        }
        const limit = @as(usize, @intCast(requested_limit));

        var summary_writer: std.Io.Writer.Allocating = .init(allocator);
        defer summary_writer.deinit();
        try summary_writer.writer.writeAll("Consolidated memory:");

        var evidence_qids = std.ArrayList([]const u8).empty;
        defer {
            for (evidence_qids.items) |qid| allocator.free(qid);
            evidence_qids.deinit(allocator);
        }

        // Oldest first across the whole store, paged, until `limit` sources.
        var candidates = self.store.iterateNodes(allocator, .{});
        defer candidates.deinit();
        while (try candidates.next()) |candidate_qid| {
            if (evidence_qids.items.len >= limit) break;
            const node = (try self.store.getNode(allocator, candidate_qid)) orelse continue;
            defer self.store.freeNode(allocator, node);
            if (!isConsolidatableLabel(node.label)) continue;
            if (try propertyBool(allocator, node.properties_json, "deleted")) continue;
            if (!try scope.matchesNode(allocator, node)) continue;
            if (isDerivedLabel(node.label) and !try propertyEquals(allocator, node.properties_json, "state", "current")) continue;
            const text = textForNode(allocator, node) catch continue;
            defer allocator.free(text);
            try summary_writer.writer.print("\n- ({s}) {s}", .{ node.qid, text });
            try evidence_qids.append(allocator, try allocator.dupe(u8, node.qid));
        }

        const existing_qid = try self.findCoreBlockQid(allocator, scope, block_key);
        defer if (existing_qid) |qid| allocator.free(qid);
        const block_qid = if (existing_qid) |qid| try allocator.dupe(u8, qid) else try self.nextQid(allocator, "core");
        defer allocator.free(block_qid);
        const status: []const u8 = if (existing_qid == null) "stored" else "updated";

        const summary_text = try summary_writer.toOwnedSlice();
        defer allocator.free(summary_text);
        const props = try stringifyAlloc(allocator, .{
            .kind = "core",
            .qtype = "core",
            .blockKey = block_key,
            .text = summary_text,
            .managedBy = "agent",
            .evidenceQids = evidence_qids.items,
            .tenantId = scope.tenant_id,
            .userId = scope.user_id,
            .agentId = scope.agent_id,
            .projectId = scope.project_id,
            .deleted = false,
        });
        defer allocator.free(props);
        try self.store.putNode(.{ .qid = block_qid, .label = "Core", .properties_json = props });

        for (evidence_qids.items) |source_qid| {
            try self.putDeterministicEdge(allocator, block_qid, source_qid, "COMPILED_FROM");
        }

        const event_payload = try stringifyAlloc(allocator, .{
            .method = "memory.core.consolidate",
            .status = status,
            .blockQid = block_qid,
            .blockKey = block_key,
            .sourceCount = evidence_qids.items.len,
        });
        defer allocator.free(event_payload);
        _ = try self.publishEvent(streams.consolidate_completed, event_payload);
        _ = try self.publishEvent(streams.audit, event_payload);

        const response = .{
            .jsonrpc = "2.0",
            .id = id,
            .result = .{
                .blockQid = block_qid,
                .blockKey = block_key,
                .status = status,
                .sourceCount = evidence_qids.items.len,
            },
        };
        return stringifyAlloc(allocator, response);
    }

    fn putEdge(self: *Runtime, allocator: std.mem.Allocator, from_qid: []const u8, to_qid: []const u8, edge_type: []const u8) !void {
        const edge_qid = try self.nextQid(allocator, "edge");
        defer allocator.free(edge_qid);
        try self.store.putEdge(.{
            .qid = edge_qid,
            .from_qid = from_qid,
            .to_qid = to_qid,
            .edge_type = edge_type,
            .properties_json = "{}",
        });
    }

    fn putDeterministicEdge(self: *Runtime, allocator: std.mem.Allocator, from_qid: []const u8, to_qid: []const u8, edge_type: []const u8) !void {
        const key = try std.fmt.allocPrint(allocator, "{s}:{s}:{s}", .{ from_qid, edge_type, to_qid });
        defer allocator.free(key);
        const edge_qid = try hashQid(allocator, "edge", key);
        defer allocator.free(edge_qid);
        try self.store.putEdge(.{
            .qid = edge_qid,
            .from_qid = from_qid,
            .to_qid = to_qid,
            .edge_type = edge_type,
            .properties_json = "{}",
        });
    }

    fn publishEvent(self: *Runtime, stream: []const u8, payload_json: []const u8) !storage.StreamEntry {
        return self.store.appendStream(stream, payload_json);
    }

    /// Every audit event whose payload names `qid` as a JSON string, read a
    /// page at a time to the end of the stream.
    fn auditEventsForQid(self: *Runtime, allocator: std.mem.Allocator, qid: []const u8) !OwnedAuditEvents {
        const needle = try std.fmt.allocPrint(allocator, "\"{s}\"", .{qid});
        defer allocator.free(needle);

        var audit = OwnedAuditEvents{ .allocator = allocator };
        errdefer audit.deinit();
        var after: u64 = 0;
        while (true) {
            const entries = try self.store.readStream(allocator, streams.audit, after, audit_page_size);
            defer freeStreamEntries(allocator, entries);
            if (entries.len == 0) break;
            for (entries) |entry| {
                after = @max(after, entry.sequence);
                if (std.mem.indexOf(u8, entry.payload_json, needle) == null) continue;
                try audit.append(allocator, entry.stream, entry.sequence, entry.payload_json);
            }
            if (entries.len < audit_page_size) break;
        }
        return audit;
    }

    fn extractFromMessage(
        self: *Runtime,
        allocator: std.mem.Allocator,
        scope: Scope,
        message_qid: []const u8,
        content: []const u8,
        created_at: ?[]const u8,
    ) !usize {
        const plugin = providers.deterministicExtractor();
        const extracted = plugin.extract(content);
        var written: usize = 0;
        for (extracted.items[0..extracted.len]) |candidate| {
            self.writeExtractedMemory(allocator, scope, message_qid, content, created_at, candidate) catch |err| switch (err) {
                error.InvalidExtractionCandidate => continue,
                else => return err,
            };
            written += 1;
        }
        return written;
    }

    fn writeExtractedMemory(
        self: *Runtime,
        allocator: std.mem.Allocator,
        scope: Scope,
        message_qid: []const u8,
        quote: []const u8,
        created_at: ?[]const u8,
        candidate: extractor.Candidate,
    ) !void {
        extractor.validateCandidate(candidate) catch {
            return error.InvalidExtractionCandidate;
        };

        const label = extractor.labelName(candidate.label);
        if (std.mem.eql(u8, candidate.aggregation_mode, "single_value")) {
            try self.supersedeCurrentSlot(allocator, scope, candidate.slot_key, candidate.valid_from orelse created_at);
        }
        const qid = try self.nextQid(allocator, extractor.qidPrefix(candidate.label));
        defer allocator.free(qid);
        const quote_for_props = try clampPropertyText(allocator, quote);
        defer allocator.free(quote_for_props);
        const valid_from = candidate.valid_from orelse created_at;
        const props = try stringifyAlloc(allocator, .{
            .kind = labelType(label),
            .text = candidate.text,
            .slotKey = candidate.slot_key,
            .subject = candidate.subject,
            .attribute = candidate.attribute,
            .value = candidate.value,
            .numericValue = candidate.numeric_value,
            .unit = candidate.unit,
            .aggregationMode = candidate.aggregation_mode,
            .state = "current",
            .validFrom = valid_from,
            .validTo = candidate.valid_to,
            .evidenceQid = message_qid,
            .quote = quote_for_props,
            .tenantId = scope.tenant_id,
            .userId = scope.user_id,
            .agentId = scope.agent_id,
            .projectId = scope.project_id,
            .deleted = false,
        });
        defer allocator.free(props);
        try self.store.putNode(.{ .qid = qid, .label = label, .properties_json = props });
        try self.putEdge(allocator, qid, message_qid, "EVIDENCED_BY");
        try self.writeMemoryCardForCandidate(allocator, scope, message_qid, quote, created_at, candidate);
    }

    fn writeMemoryCardForCandidate(
        self: *Runtime,
        allocator: std.mem.Allocator,
        scope: Scope,
        message_qid: []const u8,
        quote: []const u8,
        created_at: ?[]const u8,
        candidate: extractor.Candidate,
    ) !void {
        const key = try std.fmt.allocPrint(allocator, "{s}:{s}:{s}", .{ message_qid, candidate.slot_key, candidate.value });
        defer allocator.free(key);
        const card_qid = try hashQid(allocator, "card", key);
        defer allocator.free(card_qid);
        const related_card_qids = try self.relatedCardQidsForCandidate(allocator, scope, card_qid, candidate);
        defer {
            for (related_card_qids) |qid| allocator.free(qid);
            allocator.free(related_card_qids);
        }
        const quote_for_props = try clampPropertyText(allocator, quote);
        defer allocator.free(quote_for_props);
        const props = try stringifyAlloc(allocator, .{
            .kind = "memory_card",
            .qtype = "memory_card",
            .cardKind = memoryCardKind(candidate.label),
            .text = candidate.text,
            .contextDescription = "Deterministic extraction from raw message.",
            .contextualDescription = cardContextualDescription(candidate),
            .keywords = cardKeywords(candidate),
            .tags = cardTags(candidate),
            .importance = cardImportance(candidate),
            .utility = @as(f32, 0.5),
            .relatedCardQids = related_card_qids,
            .slotKey = candidate.slot_key,
            .subject = candidate.subject,
            .attribute = candidate.attribute,
            .value = candidate.value,
            .numericValue = candidate.numeric_value,
            .unit = candidate.unit,
            .aggregationMode = candidate.aggregation_mode,
            .state = "current",
            .validFrom = candidate.valid_from orelse created_at,
            .validTo = candidate.valid_to,
            .evidenceQid = message_qid,
            .quote = quote_for_props,
            .tenantId = scope.tenant_id,
            .userId = scope.user_id,
            .agentId = scope.agent_id,
            .projectId = scope.project_id,
            .deleted = false,
        });
        defer allocator.free(props);
        try self.store.putNode(.{ .qid = card_qid, .label = "MemoryCard", .properties_json = props });
        try self.putDeterministicEdge(allocator, card_qid, message_qid, "EVIDENCED_BY");
        for (related_card_qids) |related_qid| {
            try self.putDeterministicEdge(allocator, card_qid, related_qid, "RELATED_TO");
        }
    }

    /// Up to `related_card_limit` live cards in scope that share the
    /// candidate's slot, newest first, then cards of the same kind, newest
    /// first.
    fn relatedCardQidsForCandidate(
        self: *Runtime,
        allocator: std.mem.Allocator,
        scope: Scope,
        card_qid: []const u8,
        candidate: extractor.Candidate,
    ) ![]const []const u8 {
        var related = std.ArrayList([]const u8).empty;
        errdefer {
            for (related.items) |qid| allocator.free(qid);
            related.deinit(allocator);
        }
        const lookups = [_]storage.PropertyMatch{
            .{ .name = "slotKey", .value = candidate.slot_key },
            .{ .name = "cardKind", .value = memoryCardKind(candidate.label) },
        };
        for (lookups) |match| {
            const where = [_]storage.PropertyMatch{match};
            var cards = self.store.iterateNodes(allocator, .{
                .label = "MemoryCard",
                .where = &where,
                .order = .newest_first,
                .limit = 64,
            });
            defer cards.deinit();
            while (try cards.next()) |qid| {
                if (related.items.len >= related_card_limit) break;
                if (std.mem.eql(u8, qid, card_qid) or stringListContains(related.items, qid)) continue;
                const node = (try self.store.getNode(allocator, qid)) orelse continue;
                defer self.store.freeNode(allocator, node);
                if (try propertyBool(allocator, node.properties_json, "deleted")) continue;
                if (!try scope.matchesNode(allocator, node)) continue;
                try related.append(allocator, try allocator.dupe(u8, node.qid));
            }
        }
        return related.toOwnedSlice(allocator);
    }

    /// Embeds, in batched requests, the index text of each vector-indexed node
    /// memory.remember will write for `messages`: unchunked messages, the
    /// chunks of long ones and deterministic extractions. Stops at the first
    /// invalid message, where the write loop stops too. Best effort: putNode
    /// embeds any text the prefetch missed.
    fn prefetchRememberEmbeddings(
        self: *Runtime,
        allocator: std.mem.Allocator,
        messages: []const Value,
        extract_enabled: bool,
    ) !void {
        var texts = std.ArrayList([]const u8).empty;
        defer texts.deinit(allocator);
        // Speaker-prefixed index texts are built here; free them after the prefetch.
        var owned = std.ArrayList([]u8).empty;
        defer {
            for (owned.items) |text| allocator.free(text);
            owned.deinit(allocator);
        }
        for (messages) |message_value| {
            const message = objectValue(message_value) orelse break;
            const role = stringField(&message, "role") orelse break;
            const content = stringField(&message, "content") orelse break;
            if (content.len == 0) break;

            const chunk_ends = try messageChunkEnds(allocator, content);
            defer allocator.free(chunk_ends);
            if (chunk_ends.len > 1) {
                var start: usize = 0;
                for (chunk_ends) |end| {
                    try appendIndexText(allocator, &texts, &owned, role, content[start..end]);
                    start = end;
                }
            } else {
                try appendIndexText(allocator, &texts, &owned, role, content);
            }

            if (extract_enabled) {
                const extracted = providers.deterministicExtractor().extract(content);
                for (extracted.items[0..extracted.len]) |candidate| {
                    extractor.validateCandidate(candidate) catch continue;
                    try texts.append(allocator, candidate.text);
                }
            }
        }
        self.store.prefetchEmbeddings(texts.items) catch {};
    }

    /// Writes one Chunk node per slice of `content`, linked by
    /// Message-[HAS_CHUNK]->Chunk and Chunk-[EVIDENCED_BY]->Message.
    /// Chunk qids and edges are deterministic so they do not consume runtime ids.
    fn writeMessageChunks(
        self: *Runtime,
        allocator: std.mem.Allocator,
        meta: MessageMeta,
        content: []const u8,
        chunk_ends: []const usize,
    ) !void {
        var start: usize = 0;
        for (chunk_ends, 0..) |end, chunk_index| {
            const chunk_qid = try chunkQid(allocator, meta.message_qid, chunk_index);
            defer allocator.free(chunk_qid);
            const props = try stringifyAlloc(allocator, .{
                .kind = "chunk",
                .content = content[start..end],
                .role = meta.role,
                .createdAt = meta.created_at,
                .messageQid = meta.message_qid,
                .chunkIndex = chunk_index,
                .chunkCount = chunk_ends.len,
                .sessionQid = meta.session_qid,
                .sessionId = meta.session_id,
                .turnQid = meta.turn_qid,
                .messageIndex = meta.message_index,
                .tenantId = meta.scope.tenant_id,
                .userId = meta.scope.user_id,
                .agentId = meta.scope.agent_id,
                .projectId = meta.scope.project_id,
                .privacyClass = meta.privacy_class,
                .deleted = false,
            });
            defer allocator.free(props);
            const chunk_node_props = try withSpeakerSearchText(allocator, props, meta.role, content[start..end]);
            defer allocator.free(chunk_node_props);
            try self.store.putNode(.{ .qid = chunk_qid, .label = "Chunk", .properties_json = chunk_node_props });
            try self.putDeterministicEdge(allocator, meta.message_qid, chunk_qid, "HAS_CHUNK");
            try self.putDeterministicEdge(allocator, chunk_qid, meta.message_qid, "EVIDENCED_BY");
            start = end;
        }
    }

    fn writeEpisodeForTurn(
        self: *Runtime,
        allocator: std.mem.Allocator,
        scope: Scope,
        session_qid: []const u8,
        turn_qid: []const u8,
        message_qids: []const []const u8,
        summary: []const u8,
        created_at: ?[]const u8,
    ) ![]u8 {
        const episode_qid = try hashQid(allocator, "ep", turn_qid);
        errdefer allocator.free(episode_qid);
        const episode_summary = summary[0..utf8PrefixLen(summary, 1024)];
        // While the episode only copies the first message it would duplicate
        // raw evidence in search, so it is kept out of the lexical/vector index.
        const props = try stringifyAlloc(allocator, .{
            .kind = "episode",
            .qtype = "episode",
            .episodeType = "conversation",
            .searchable = false,
            .sessionQid = session_qid,
            .turnQid = turn_qid,
            .summary = episode_summary,
            .text = episode_summary,
            .eventTime = created_at,
            .state = "current",
            .evidenceQid = if (message_qids.len > 0) message_qids[0] else null,
            .quote = episode_summary,
            .tenantId = scope.tenant_id,
            .userId = scope.user_id,
            .agentId = scope.agent_id,
            .projectId = scope.project_id,
            .evidenceQids = message_qids,
            .deleted = false,
        });
        defer allocator.free(props);
        try self.store.putNode(.{ .qid = episode_qid, .label = "Episode", .properties_json = props });
        try self.putDeterministicEdge(allocator, episode_qid, turn_qid, "DERIVED_FROM");
        for (message_qids) |message_qid| {
            try self.putDeterministicEdge(allocator, episode_qid, message_qid, "DERIVED_FROM");
        }
        return episode_qid;
    }

    fn writeToolCalls(self: *Runtime, allocator: std.mem.Allocator, params: *const ObjectMap, scope: Scope, turn_qid: []const u8) !usize {
        const calls = arrayValue(params.get("toolCalls")) orelse return 0;
        var written: usize = 0;
        for (calls.items) |call_value| {
            const call = objectValue(call_value) orelse return error.InvalidRequest;
            const tool_name = stringField(&call, "toolName") orelse stringField(&call, "name") orelse return error.InvalidRequest;
            const call_qid = try self.nextQid(allocator, "tool");
            defer allocator.free(call_qid);
            const props = try stringifyAlloc(allocator, .{
                .kind = "tool_call",
                .qtype = "tool_call",
                .toolName = tool_name,
                .inputJson = stringField(&call, "inputJson") orelse "{}",
                .outputJson = stringField(&call, "outputJson") orelse "{}",
                .status = stringField(&call, "status") orelse "success",
                .errorText = stringField(&call, "errorText"),
                .tenantId = scope.tenant_id,
                .userId = scope.user_id,
                .agentId = scope.agent_id,
                .projectId = scope.project_id,
                .deleted = false,
            });
            defer allocator.free(props);
            try self.store.putNode(.{ .qid = call_qid, .label = "ToolCall", .properties_json = props });
            try self.putEdge(allocator, turn_qid, call_qid, "HAS_TOOL_CALL");
            written += 1;
        }
        return written;
    }

    fn writeObservations(self: *Runtime, allocator: std.mem.Allocator, params: *const ObjectMap, scope: Scope, turn_qid: []const u8) !usize {
        const observations = arrayValue(params.get("observations")) orelse return 0;
        var written: usize = 0;
        for (observations.items) |observation_value| {
            const observation = objectValue(observation_value) orelse return error.InvalidRequest;
            const content = stringField(&observation, "content") orelse stringField(&observation, "text") orelse return error.InvalidRequest;
            const observation_qid = try self.nextQid(allocator, "obs");
            defer allocator.free(observation_qid);
            const props = try stringifyAlloc(allocator, .{
                .kind = "observation",
                .qtype = "observation",
                .observationType = stringField(&observation, "type") orelse "generic",
                .content = content,
                .text = content,
                .createdAt = stringField(&observation, "createdAt"),
                .tenantId = scope.tenant_id,
                .userId = scope.user_id,
                .agentId = scope.agent_id,
                .projectId = scope.project_id,
                .deleted = false,
            });
            defer allocator.free(props);
            try self.store.putNode(.{ .qid = observation_qid, .label = "Observation", .properties_json = props });
            try self.putEdge(allocator, turn_qid, observation_qid, "HAS_OBSERVATION");
            written += 1;
        }
        return written;
    }

    /// Marks every current slot memory with `slot_key` in `scope` superseded.
    /// The slot and state indexes find them wherever they sit in the store.
    fn supersedeCurrentSlot(self: *Runtime, allocator: std.mem.Allocator, scope: Scope, slot_key: []const u8, valid_to: ?[]const u8) !void {
        const where = [_]storage.PropertyMatch{
            .{ .name = "slotKey", .value = slot_key },
            .{ .name = "state", .value = "current" },
        };
        var current = self.store.iterateNodes(allocator, .{ .where = &where });
        defer current.deinit();
        while (try current.next()) |qid| {
            const node = (try self.store.getNode(allocator, qid)) orelse continue;
            defer self.store.freeNode(allocator, node);
            if (!isSlotMemoryLabel(node.label)) continue;
            if (!try scope.matchesNode(allocator, node)) continue;
            if (try propertyBool(allocator, node.properties_json, "deleted")) continue;
            if (!try propertyEquals(allocator, node.properties_json, "slotKey", slot_key)) continue;
            if (!try propertyEquals(allocator, node.properties_json, "state", "current")) continue;
            try self.rewriteDerivedState(allocator, node, "superseded", valid_to);
        }
    }

    /// Sets `state` and `validTo` and keeps every other property, so a
    /// superseded card keeps its card fields and any label's extra fields
    /// survive.
    fn rewriteDerivedState(
        self: *Runtime,
        allocator: std.mem.Allocator,
        node: storage.Node,
        state: []const u8,
        valid_to: ?[]const u8,
    ) !void {
        var parsed = try std.json.parseFromSlice(Value, allocator, node.properties_json, .{});
        defer parsed.deinit();
        const arena = parsed.arena.allocator();
        switch (parsed.value) {
            .object => |*object| {
                try object.put(arena, "state", .{ .string = state });
                try object.put(arena, "validTo", if (valid_to) |value| .{ .string = value } else .null);
            },
            else => return error.InvalidRequest,
        }
        const props = try stringifyAlloc(allocator, parsed.value);
        defer allocator.free(props);
        try self.store.putNode(.{ .qid = node.qid, .label = node.label, .properties_json = props });
    }

    /// What `node` was derived or compiled from: the targets of its
    /// EVIDENCED_BY, DERIVED_FROM and COMPILED_FROM edges, plus the node its
    /// `evidenceQid` (or a chunk's `messageQid`) names when no edge records it.
    fn provenanceRefsForNode(self: *Runtime, allocator: std.mem.Allocator, node: storage.Node) !OwnedNodeRefs {
        var refs = OwnedNodeRefs{ .allocator = allocator };
        errdefer refs.deinit();
        var seen = forgetting.QidList.init(allocator);
        defer seen.deinit();

        const relations = [_][2][]const u8{
            .{ "EVIDENCED_BY", "evidenced_by" },
            .{ "DERIVED_FROM", "derived_from" },
            .{ forgetting.compiled_edge_type, "compiled_from" },
        };
        for (relations) |relation| {
            const edges = try self.store.findEdges(allocator, .{ .from_qid = node.qid, .edge_type = relation[0], .limit = storage.unlimited });
            defer self.store.freeEdges(allocator, edges);
            for (edges) |edge| {
                if (seen.contains(edge.to_qid)) continue;
                const target = (try self.store.getNode(allocator, edge.to_qid)) orelse continue;
                defer self.store.freeNode(allocator, target);
                _ = try seen.appendUnique(edge.to_qid);
                try refs.append(allocator, edge.to_qid, labelType(target.label), relation[1]);
            }
        }

        const property_key: []const u8 = if (std.mem.eql(u8, node.label, "Chunk")) "messageQid" else "evidenceQid";
        const evidence_qid = (try readOptionalPropertyString(allocator, node.properties_json, property_key)) orelse return refs;
        defer allocator.free(evidence_qid);
        if (seen.contains(evidence_qid)) return refs;
        const evidence_node = (try self.store.getNode(allocator, evidence_qid)) orelse return refs;
        defer self.store.freeNode(allocator, evidence_node);
        try refs.append(allocator, evidence_qid, labelType(evidence_node.label), "evidenced_by");
        return refs;
    }

    /// Live nodes derived directly from `evidence_qid`, whatever their label.
    /// Chunks are parts of their message, not derived memory.
    fn derivedRefsByEvidence(self: *Runtime, allocator: std.mem.Allocator, evidence_qid: []const u8) !OwnedNodeRefs {
        var direct = try forgetting.dependentQids(allocator, self.store, evidence_qid);
        defer direct.deinit();

        var refs = OwnedNodeRefs{ .allocator = allocator };
        errdefer refs.deinit();
        for (direct.items.items) |dependent_qid| {
            const node = (try self.store.getNode(allocator, dependent_qid)) orelse continue;
            defer self.store.freeNode(allocator, node);
            if (std.mem.eql(u8, node.label, "Chunk")) continue;
            if (try propertyBool(allocator, node.properties_json, "deleted")) continue;
            try refs.append(allocator, node.qid, labelType(node.label), "derived_from");
        }
        return refs;
    }

    fn tombstoneQid(self: *Runtime, allocator: std.mem.Allocator, qid: []const u8, reason: []const u8, mode: []const u8) !void {
        const node = (try self.store.getNode(allocator, qid)) orelse return;
        defer self.store.freeNode(allocator, node);
        try self.tombstoneNode(allocator, node, reason, mode);
    }

    /// Replaces a node's properties with a tombstone, which leaves every
    /// search and vector index. Raw text survives only as fingerprints for
    /// `verify leaks`. An existing tombstone is left as it is.
    fn tombstoneNode(self: *Runtime, allocator: std.mem.Allocator, node: storage.Node, reason: []const u8, mode: []const u8) !void {
        if (try propertyBool(allocator, node.properties_json, "deleted")) return;
        const fingerprints = try forgetting.fingerprintNode(allocator, node.label, node.properties_json);
        defer forgetting.freeFingerprints(allocator, fingerprints);
        const tombstone = try stringifyAlloc(allocator, .{
            .kind = "tombstone",
            .deleted = true,
            .state = if (std.mem.eql(u8, mode, "redact")) "redacted" else "deleted",
            .mode = mode,
            .reason = reason,
            .previousLabel = node.label,
            .leakFingerprints = fingerprints,
        });
        defer allocator.free(tombstone);
        try self.store.putNode(.{ .qid = node.qid, .label = node.label, .properties_json = tombstone });
    }

    fn nextQid(self: *Runtime, allocator: std.mem.Allocator, prefix: []const u8) ![]u8 {
        const id = self.next_id;
        self.next_id += 1;
        return std.fmt.allocPrint(allocator, "q_{s}_{d}", .{ prefix, id });
    }

    /// Optional cross-encoder stage between the raw-evidence policy and budget
    /// packing. The leading `settings.window` items go to the reranker and are
    /// reordered by descending relevance (ties keep fused order); window items
    /// the reranker did not score follow, then the rest in fused order. A
    /// failed call keeps the fused order. Returns null when no reranker is
    /// configured, so the response is unchanged.
    fn rerankItems(
        self: *Runtime,
        allocator: std.mem.Allocator,
        query: []const u8,
        results: *OwnedItems,
        settings: RerankSettings,
    ) !?OwnedRerankTrace {
        const endpoint = self.options.reranker;
        if (endpoint.kind == .none) return null;
        var stage = OwnedRerankTrace{ .allocator = allocator, .trace = .{ .model = endpoint.model, .status = "applied" } };
        errdefer stage.deinit();
        if (!settings.enabled) {
            stage.trace.status = "disabled";
            return stage;
        }
        const window = @min(settings.window, results.items.items.len);
        stage.trace.windowSize = window;
        if (window == 0) {
            stage.trace.status = "skipped";
            return stage;
        }

        const documents = try allocator.alloc([]const u8, window);
        var built: usize = 0;
        defer {
            for (documents[0..built]) |document| allocator.free(document);
            allocator.free(documents);
        }
        for (results.items.items[0..window]) |item| {
            documents[built] = try rerankDocument(allocator, item);
            built += 1;
        }

        const started = if (self.options.io) |io| std.Io.Timestamp.now(io, .awake) else null;
        const reranked = providers.rerank(allocator, self.options.io, endpoint, .{
            .query = query,
            .documents = documents,
            .top_n = window,
        });
        if (started) |timestamp| {
            const elapsed_ns: f64 = @floatFromInt(timestamp.untilNow(self.options.io.?, .awake).toNanoseconds());
            stage.trace.latencyMs = @round(elapsed_ns / 1000) / 1000;
        }
        const scores = reranked catch |err| {
            if (err == error.OutOfMemory) return err;
            stage.trace.status = "failed";
            stage.trace.@"error" = @errorName(err);
            return stage;
        };
        defer allocator.free(scores);
        stage.trace.rerankedCount = scores.len;

        const order = try rerankOrder(allocator, window, scores);
        defer allocator.free(order);
        const score_by_index = try allocator.alloc(f64, window);
        defer allocator.free(score_by_index);
        for (scores) |score| score_by_index[score.index] = score.relevance_score;
        for (order[0..@min(scores.len, rerank_trace_top_scores)]) |index| {
            const qid = try allocator.dupe(u8, results.items.items[index].qid);
            errdefer allocator.free(qid);
            try stage.top_scores.append(allocator, .{ .qid = qid, .score = score_by_index[index] });
        }
        try applyItemOrder(allocator, results.items.items[0..window], order);
        return stage;
    }

    /// The queries one retrieval runs: the original, then the sub-queries of
    /// `mode`. A failed LLM call or invalid reply leaves the original alone
    /// and marks the expansion failed.
    fn expandQuery(self: *Runtime, allocator: std.mem.Allocator, query: []const u8, mode: query_expansion.Mode) !OwnedExpansion {
        var expansion = OwnedExpansion{ .allocator = allocator, .mode = mode };
        errdefer expansion.deinit();
        try expansion.append(query, query_expansion.source_original);
        if (mode == .off) return expansion;

        const started = if (self.options.io) |io| std.Io.Timestamp.now(io, .awake) else null;
        const sub_queries = switch (mode) {
            .off => unreachable,
            .rules => try query_expansion.ruleQueries(allocator, query),
            .llm => blk: {
                const endpoint = self.expansionEndpoint();
                expansion.model = endpoint.model;
                break :blk query_expansion.requestQueries(allocator, self.options.io, endpoint, query) catch |err| {
                    if (err == error.OutOfMemory) return err;
                    expansion.status = query_expansion.status_failed;
                    expansion.error_name = @errorName(err);
                    break :blk try allocator.alloc([]u8, 0);
                };
            },
        };
        defer query_expansion.freeQueries(allocator, sub_queries);
        if (started) |timestamp| {
            const elapsed_ns: f64 = @floatFromInt(timestamp.untilNow(self.options.io.?, .awake).toNanoseconds());
            expansion.latency_ms = @round(elapsed_ns / 1000) / 1000;
        }
        const source = if (mode == .rules) query_expansion.source_rules else query_expansion.source_llm;
        for (sub_queries) |sub_query| try expansion.append(sub_query, source);
        if (sub_queries.len > 0) expansion.status = query_expansion.status_expanded;
        return expansion;
    }

    /// `options.queryExpansion: "llm"` uses the expansion provider when one
    /// is configured, else the reader.
    fn expansionEndpoint(self: *const Runtime) providers.ProviderEndpoint {
        if (self.options.expansion_provider.kind != .none) return self.options.expansion_provider;
        return self.options.answer_provider;
    }

    /// Candidate generation for every query of `expansion`. One query is
    /// exactly `collectItems`; several are fused by `fuseQueryItems`.
    fn collectExpandedItems(
        self: *Runtime,
        allocator: std.mem.Allocator,
        expansion: *OwnedExpansion,
        mode: SearchMode,
        limit: usize,
        filter: ItemFilter,
        fact_keys: bool,
    ) !OwnedItems {
        const queries = expansion.queries.items;
        const lists = try allocator.alloc(OwnedItems, queries.len);
        var built: usize = 0;
        defer {
            for (lists[0..built]) |*list| list.deinit();
            allocator.free(lists);
        }
        for (queries, 0..) |entry, index| {
            lists[index] = try self.collectItemsWithFactKeys(allocator, entry.text, mode, limit, filter, fact_keys);
            built += 1;
            try expansion.recordHits(index, lists[index].items.items);
        }
        if (lists.len == 1) {
            const single = lists[0];
            lists[0] = .{ .allocator = allocator };
            return single;
        }
        var fused = try fuseQueryItems(allocator, lists, limit);
        errdefer fused.deinit();
        if (fact_keys) {
            // Counters sum over the expanded queries; kept items are recounted
            // from `via_assertion` after packing.
            var stats = FactKeysTrace{};
            for (lists) |list| {
                const part = list.fact_keys orelse continue;
                stats.assertionHits += part.assertionHits;
                stats.evidenceItems += part.evidenceItems;
                stats.datedItems += part.datedItems;
            }
            fused.fact_keys = stats;
        }
        // Raw items from a list without slot memories were never checked for
        // stale evidence; the fused list may now hold such memories.
        try self.markStaleRawEvidence(allocator, &fused, filter.valid_at);
        return fused;
    }

    fn collectItems(
        self: *Runtime,
        allocator: std.mem.Allocator,
        query: []const u8,
        mode: SearchMode,
        limit: usize,
        scope: Scope,
        include_deleted: bool,
        labels_value: ?Value,
        valid_at: ?[]const u8,
        event_window: EventWindow,
        include_evidence: bool,
        include_debug: bool,
    ) !OwnedItems {
        return self.collectItemsWithFactKeys(allocator, query, mode, limit, .{
            .scope = scope,
            .include_deleted = include_deleted,
            .labels_value = labels_value,
            .valid_at = valid_at,
            .event_window = event_window,
            .include_evidence = include_evidence,
            .include_debug = include_debug,
        }, false);
    }

    /// Candidate items for a query. Without `fact_keys`, Assertion nodes are
    /// dropped from every search channel before fusion (unless a caller asks
    /// for the label), so they never take a candidate slot or appear as
    /// items. With `fact_keys` (E1's assertion_keys), an Assertion hit stands
    /// in for its source evidence: the chunks its quote lies in, or the whole
    /// message when unchunked, at the assertion's score. Raw items are
    /// deduplicated by qid, so the better-ranked route wins, and each raw item
    /// carries the event dates of the claims evidenced by it.
    fn collectItemsWithFactKeys(
        self: *Runtime,
        allocator: std.mem.Allocator,
        query: []const u8,
        mode: SearchMode,
        limit: usize,
        filter: ItemFilter,
        fact_keys: bool,
    ) !OwnedItems {
        const exclude_assertions = !fact_keys and !labelRequestedExplicitly("Assertion", filter.labels_value);
        const hits = try self.collectSearchHits(allocator, query, mode, @max(limit * 4, limit), exclude_assertions);
        defer freeHits(allocator, hits);

        var owned = OwnedItems{ .allocator = allocator };
        errdefer owned.deinit();
        if (fact_keys) owned.fact_keys = .{};
        for (hits) |hit| {
            const node = (try self.store.getNode(allocator, hit.qid)) orelse continue;
            defer self.store.freeNode(allocator, node);
            if (fact_keys and std.mem.eql(u8, node.label, "Assertion")) {
                try self.appendAssertionEvidence(allocator, &owned, node, hit.score, filter, limit);
            } else if (!fact_keys or !owned.containsQid(node.qid)) {
                _ = try appendNodeItem(allocator, &owned, node, hit.score, filter);
            }
            if (owned.items.items.len >= limit) break;
        }
        sortItemsByScore(&owned);
        try self.markStaleRawEvidence(allocator, &owned, filter.valid_at);
        if (fact_keys) try self.attachEventDates(allocator, &owned);
        return owned;
    }

    /// When the question names a time (`10 days ago`,
    /// `last Saturday`, `in January`), what people said inside that window is
    /// moved ahead of every other candidate, most relevant first. A question
    /// like "what did I buy 10 days ago?" says little about the purchase, so
    /// relevance alone often leaves the message out. An item is inside a
    /// window when its message was written then, or, with fact keys, when a
    /// claim drawn from it has an event date then (the message said
    /// "yesterday"). Only speakers' messages are anchored: the assistant's
    /// replies of that day are long and say nothing about what the person
    /// did. The search goes `time_anchor_hit_limit` hits deep, each window
    /// brings in at most `time_anchor_items_per_window` items, and all of
    /// them together at most `time_anchor_budget_percent` of the budget.
    /// Without a parseable `time.validAt`, or a time in the question, nothing
    /// changes.
    fn applyTimeAnchors(
        self: *Runtime,
        allocator: std.mem.Allocator,
        owned: *OwnedItems,
        query: []const u8,
        mode: SearchMode,
        filter: ItemFilter,
        fact_keys: bool,
        budget: usize,
    ) !TimeAnchorsTrace {
        var trace = TimeAnchorsTrace{};
        const current = parseIsoDate(filter.valid_at orelse return trace) catch return trace;
        const windows = try temporal.resolveWindows(allocator, query, current);
        defer allocator.free(windows);
        if (windows.len == 0) return trace;
        trace.windows = windows.len;

        const hits = try self.collectSearchHits(allocator, query, mode, time_anchor_hit_limit, !fact_keys);
        defer freeHits(allocator, hits);
        var top_score: f32 = 0;
        for (owned.items.items) |item| top_score = @max(top_score, item.score);
        const token_limit = budget * time_anchor_budget_percent / 100;
        var used: usize = 0;

        for (windows) |window| {
            var anchored = OwnedItems{ .allocator = allocator };
            defer anchored.deinit();
            for (hits) |hit| {
                if (anchored.items.items.len >= time_anchor_items_per_window) break;
                const node = (try self.store.getNode(allocator, hit.qid)) orelse continue;
                defer self.store.freeNode(allocator, node);
                const is_claim = std.mem.eql(u8, node.label, "Assertion");
                if (!is_claim and !std.mem.eql(u8, node.label, "Message") and !std.mem.eql(u8, node.label, "Chunk")) continue;
                if (!try nodeDatedWithin(allocator, node, window, is_claim)) continue;
                const before = anchored.items.items.len;
                if (is_claim) {
                    try self.appendAssertionEvidence(allocator, &anchored, node, hit.score, filter, time_anchor_items_per_window);
                } else if (!anchored.containsQid(node.qid)) {
                    _ = try appendNodeItem(allocator, &anchored, node, hit.score, filter);
                }
                // Keep what a speaker said, while it fits the anchors' share.
                var index = before;
                while (index < anchored.items.items.len) {
                    const item = anchored.items.items[index];
                    const role = if (item.raw_source) |source| source.role orelse "user" else "user";
                    const tokens = estimateItemTokens(item);
                    if (!isSpeakerRole(role) or used + tokens > token_limit) {
                        anchored.freeItem(anchored.items.orderedRemove(index));
                        continue;
                    }
                    used += tokens;
                    index += 1;
                }
            }
            if (fact_keys) try self.attachEventDates(allocator, &anchored);

            trace.items += anchored.items.items.len;

            // Above every unanchored candidate, in their own order.
            for (anchored.items.items) |*item| item.score += top_score + 1;
            var index: usize = 0;
            while (index < anchored.items.items.len) {
                const item = anchored.items.items[index];
                const existing = for (owned.items.items) |*candidate| {
                    if (std.mem.eql(u8, candidate.qid, item.qid)) break candidate;
                } else null;
                if (existing) |candidate| {
                    candidate.score = @max(candidate.score, item.score);
                    index += 1;
                    continue;
                }
                try owned.items.append(allocator, item);
                _ = anchored.items.orderedRemove(index);
            }
        }
        sortItemsByScore(owned);
        trace.tokens = used;
        return trace;
    }

    /// The summary layer's part of a context: the threads section, and which
    /// sessions raw evidence is taken from.
    ///
    /// The question is compared with every topic summary, every claim and
    /// every session summary of the scope. Facts dated inside a time the
    /// question names come first, under a heading that says so. Then the
    /// topics, best first, each with its facts in the order they happened:
    /// a topic is as near the question as its summary or its nearest fact,
    /// whichever is nearer, and one that does not fit whole is shown with
    /// the facts nearest the question that do. A fact in no topic competes
    /// on its own and is listed under `summaries.loose_heading`. Nothing
    /// less than `summaries.relevance_floor` as near as the nearest, or with
    /// a cosine under `summaries.relevance_min`, is shown. The section takes at most `summaries.threads_budget_percent`
    /// of `budget`.
    ///
    /// Raw evidence in `results` is then cut back to the sessions this opens:
    /// the ones whose summary is nearest the question, the ones dated inside
    /// a time it names, and the ones the first facts shown were said in. The
    /// messages behind the facts shown are added, alternating with what
    /// search found in those sessions. A session that has no summary yet has
    /// not been through the background jobs, and stays open.
    ///
    /// With no summary in scope nothing is changed.
    fn collectThreadItems(
        self: *Runtime,
        allocator: std.mem.Allocator,
        query: []const u8,
        filter: ItemFilter,
        needs_value: ?Value,
        budget: usize,
        fact_keys: bool,
        results: *OwnedItems,
    ) !ThreadItems {
        var found = ThreadItems{ .items = .{ .allocator = allocator }, .arena_state = std.heap.ArenaAllocator.init(allocator) };
        errdefer found.deinit();
        if (needsCount(needs_value) > 0 and !needsIncludes(needs_value, "current_facts")) return found;
        if (!self.store.capabilities().vector) return found;

        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const embedding_model = self.store.capabilities().embedding_model;

        var topics = std.ArrayList(ShownSummary).empty;
        var sessions = std.ArrayList(ShownSummary).empty;
        {
            var iterator = self.store.iterateNodes(arena, .{
                .label = "Summary",
                .where = try scopeWhere(arena, filter.scope, &.{.{ .name = "state", .value = "current" }}),
            });
            defer iterator.deinit();
            while (try iterator.next()) |qid| {
                const node = (try self.store.getNode(arena, qid)) orelse continue;
                if (!try filter.scope.matchesNode(arena, node)) continue;
                const summary = (try parseShownSummary(arena, node)) orelse continue;
                if (!sameEmbeddingModel(summary.vector_model, embedding_model)) continue;
                // A summary of things said later is not known yet at the
                // time the question asks about.
                if (filter.valid_at) |valid_at| {
                    if (summary.last_said) |last_said| {
                        if (std.mem.order(u8, dateKey(last_said), dateKey(valid_at)) == .gt) continue;
                    }
                }
                switch (summary.kind) {
                    .topic => try topics.append(arena, summary),
                    .session => if (summary.session_qid != null) try sessions.append(arena, summary),
                }
            }
        }
        found.trace.topics = topics.items.len;
        found.trace.sessions = sessions.items.len;
        if (topics.items.len == 0 and sessions.items.len == 0) return found;

        const query_vector = self.store.embedText(allocator, query) catch |err| {
            if (err == error.OutOfMemory) return err;
            return found;
        };
        defer allocator.free(query_vector);
        var query_stored: [patterns.dims]i8 = undefined;
        const dims = patterns.storedDims(query_vector.len);
        patterns.quantize(query_vector, query_stored[0..dims]);
        const question = ThreadQuestion{ .vector = query_stored[0..dims], .norm = patterns.norm(query_stored[0..dims]) };

        const current: ?temporal.CivilDate = if (filter.valid_at) |valid_at| parseIsoDate(valid_at) catch null else null;
        const named: []const temporal.NamedTime = if (current) |date| try temporal.resolveNamedTimes(arena, query, date) else &.{};

        var claims = std.ArrayList(ShownClaim).empty;
        var claim_index: std.StringHashMapUnmanaged(u32) = .empty;
        {
            var iterator = self.store.iterateNodes(arena, .{ .label = "Assertion", .where = try scopeWhere(arena, filter.scope, &.{}) });
            defer iterator.deinit();
            while (try iterator.next()) |qid| {
                const node = (try self.store.getNode(arena, qid)) orelse continue;
                if (!try filter.scope.matchesNode(arena, node)) continue;
                var claim = (try parseShownClaim(arena, node)) orelse continue;
                if (filter.valid_at) |valid_at| {
                    if (timestampBefore(valid_at, claim.created_at)) continue;
                }
                if (sameEmbeddingModel(claim.vector_model, embedding_model)) claim.score = question.cosine(claim.vector);
                for (named, 0..) |time, index| {
                    const window = time.window orelse continue;
                    if (!try nodeDatedWithin(arena, node, window, true)) continue;
                    claim.named = index;
                    break;
                }
                try claim_index.put(arena, claim.qid, @intCast(claims.items.len));
                try claims.append(arena, claim);
            }
        }
        found.trace.claims = claims.items.len;

        // What competes for the section: every topic with a fact to show,
        // and every fact that is in none.
        var candidates = std.ArrayList(ThreadCandidate).empty;
        for (topics.items, 0..) |*topic, topic_index| {
            var best = question.cosine(topic.vector);
            var children = std.ArrayList(u32).empty;
            for (topic.members) |member| {
                const index = claim_index.get(member) orelse continue;
                const claim = &claims.items[index];
                if (claim.topic != null) continue;
                claim.topic = topic_index;
                best = @max(best, claim.score);
                try children.append(arena, index);
            }
            if (children.items.len == 0) continue;
            std.mem.sort(u32, children.items, claims.items, ShownClaim.happenedBefore);
            topic.children = children.items;
            try candidates.append(arena, .{ .score = best, .topic = topic_index });
        }
        for (claims.items, 0..) |claim, index| {
            if (claim.topic == null) try candidates.append(arena, .{ .score = claim.score, .claim = @intCast(index) });
        }
        std.mem.sort(ThreadCandidate, candidates.items, {}, ThreadCandidate.before);

        const limit = (budget *| summaries.threads_budget_percent) / 100;
        var used = estimatePromptTokens(summaries.threads_note) + 8;
        var blocks = std.ArrayList(ThreadBlockPlan).empty;

        // Facts from a time the question names, nearest the question first,
        // in at most their share of the section.
        for (named, 0..) |time, time_index| {
            const window = time.window orelse continue;
            var dated = std.ArrayList(u32).empty;
            for (claims.items, 0..) |claim, index| {
                if (claim.named == time_index) try dated.append(arena, @intCast(index));
            }
            if (dated.items.len == 0) continue;
            std.mem.sort(u32, dated.items, claims.items, ShownClaim.nearerQuestion);
            const heading = try namedTimeHeading(arena, time, window);
            var cost = estimatePromptTokens(heading) + 2;
            var kept = std.ArrayList(u32).empty;
            for (dated.items) |index| {
                const tokens = try claims.items[index].lineTokens(arena, current);
                if (used + cost + tokens > limit * summaries.named_time_percent / 100) break;
                try kept.append(arena, index);
                cost += tokens;
            }
            if (kept.items.len == 0) continue;
            std.mem.sort(u32, kept.items, claims.items, ShownClaim.saidBefore);
            for (kept.items) |index| claims.items[index].shown = true;
            try blocks.append(arena, .{ .heading = heading, .members = kept.items });
            used += cost;
        }

        var loose = std.ArrayList(u32).empty;
        const nearest = if (candidates.items.len > 0) candidates.items[0].score else 0;
        for (candidates.items) |candidate| {
            if (candidate.score < nearest * summaries.relevance_floor or candidate.score < summaries.relevance_min) break;
            if (candidate.topic) |topic_index| {
                const topic = topics.items[topic_index];
                var members = std.ArrayList(u32).empty;
                const heading_tokens = estimatePromptTokens(topic.text) + 8;
                var cost = heading_tokens;
                for (topic.children) |index| {
                    if (claims.items[index].shown) continue;
                    try members.append(arena, index);
                    cost += try claims.items[index].lineTokens(arena, current);
                }
                if (members.items.len == 0) continue;
                var heading = topic.text;
                if (used + cost > limit) {
                    // The topic does not fit whole: its facts nearest the
                    // question, as many as do.
                    const whole = members.items.len;
                    std.mem.sort(u32, members.items, claims.items, ShownClaim.nearerQuestion);
                    cost = heading_tokens;
                    var fits: usize = 0;
                    for (members.items) |index| {
                        const tokens = try claims.items[index].lineTokens(arena, current);
                        if (used + cost + tokens > limit) break;
                        cost += tokens;
                        fits += 1;
                    }
                    if (fits == 0) continue;
                    members.shrinkRetainingCapacity(fits);
                    std.mem.sort(u32, members.items, claims.items, ShownClaim.happenedBefore);
                    heading = try std.fmt.allocPrint(arena, "{s} ({d} of its {d} facts)", .{ topic.text, fits, whole });
                }
                for (members.items) |index| claims.items[index].shown = true;
                try blocks.append(arena, .{ .heading = heading, .topic = topic_index, .score = candidate.score, .members = members.items });
                used += cost;
                found.trace.shown += 1;
            } else {
                const claim = &claims.items[candidate.claim];
                if (claim.shown) continue;
                const tokens = try claim.lineTokens(arena, current);
                if (used + tokens + summaries.loose_reserve_tokens > limit) continue;
                claim.shown = true;
                try loose.append(arena, candidate.claim);
                used += tokens;
            }
            if (used + summaries.closing_tokens > limit) break;
        }
        if (loose.items.len > 0) {
            std.mem.sort(u32, loose.items, claims.items, ShownClaim.saidBefore);
            try blocks.append(arena, .{ .heading = summaries.loose_heading, .members = loose.items });
        }

        for (blocks.items) |block| {
            found.trace.facts += block.members.len;
            if (block.topic) |topic_index| {
                // A topic is one item: its summary node, evidenced by the
                // messages of the facts shown under it.
                const topic = topics.items[topic_index];
                const lines = try arena.alloc([]const u8, block.members.len);
                for (block.members, lines) |index, *line| line.* = claims.items[index].rendered.?;
                try appendThreadItem(allocator, &found.items, .{
                    .qid = topic.qid,
                    .type = "summary",
                    .text = topic.text,
                    .score = block.score,
                    .valid_from = topic.first_said,
                    .heading = block.heading,
                    .lines = lines,
                }, claims.items, block.members, filter);
            } else for (block.members) |index| {
                // A fact outside a topic is an item of its own.
                const claim = claims.items[index];
                try appendThreadItem(allocator, &found.items, .{
                    .qid = claim.qid,
                    .type = "assertion",
                    .text = claim.text,
                    .score = claim.score,
                    .valid_from = claim.created_at,
                    .heading = block.heading,
                    .lines = &.{claim.rendered.?},
                }, claims.items, &.{index}, filter);
            }
        }
        found.trace.tokens = if (blocks.items.len > 0) used else 0;

        // The order raw evidence is taken in: the facts from a named time
        // and the rest, each nearest the question first, in turn.
        var order = std.ArrayList(u32).empty;
        {
            var dated = std.ArrayList(u32).empty;
            var other = std.ArrayList(u32).empty;
            for (claims.items, 0..) |claim, index| {
                if (!claim.shown) continue;
                try (if (claim.named != null) &dated else &other).append(arena, @intCast(index));
            }
            std.mem.sort(u32, dated.items, claims.items, ShownClaim.nearerQuestion);
            std.mem.sort(u32, other.items, claims.items, ShownClaim.nearerQuestion);
            const paired = if (dated.items.len == 0) 0 else @min(dated.items.len, other.items.len);
            for (0..paired) |index| {
                try order.append(arena, dated.items[index]);
                try order.append(arena, other.items[index]);
            }
            try order.appendSlice(arena, dated.items[paired..]);
            try order.appendSlice(arena, other.items[paired..]);
        }

        // Sessions whose raw messages may be shown.
        const kept = found.arena_state.allocator();
        var opened: std.StringHashMapUnmanaged(void) = .empty;
        var summarised: std.StringHashMapUnmanaged(void) = .empty;
        for (sessions.items) |*session| {
            session.score = question.cosine(session.vector);
            try summarised.put(arena, session.session_qid.?, {});
            if (session.text.len > 0) {
                const key = try kept.dupe(u8, session.session_qid.?);
                try found.session_titles.put(kept, key, try kept.dupe(u8, session.text));
                try found.session_names.put(kept, key, try kept.dupe(u8, session.title));
            }
            const said = parseIsoDate(session.first_said orelse continue) catch continue;
            for (named) |time| {
                const window = time.window orelse continue;
                if (temporal.windowContains(window, said)) try opened.put(arena, session.session_qid.?, {});
            }
        }
        std.mem.sort(ShownSummary, sessions.items, {}, ShownSummary.nearerQuestion);
        for (sessions.items[0..@min(sessions.items.len, summaries.opened_by_summary)]) |session| {
            try opened.put(arena, session.session_qid.?, {});
        }
        {
            var sources: std.StringHashMapUnmanaged(void) = .empty;
            for (order.items) |index| {
                if (sources.count() >= summaries.opened_by_facts) break;
                const claim = claims.items[index];
                const slot = try sources.getOrPut(arena, claim.message_qid);
                if (slot.found_existing) continue;
                if (claim.session_qid) |session_qid| try opened.put(arena, session_qid, {});
            }
        }
        found.trace.sessionsOpened = opened.count();

        // The messages the facts shown were drawn from.
        var from_facts = OwnedItems{ .allocator = allocator };
        defer from_facts.deinit();
        var evidence_filter = filter;
        evidence_filter.labels_value = null;
        evidence_filter.event_window = .{};
        for (order.items) |index| {
            const node = (try self.store.getNode(allocator, claims.items[index].qid)) orelse continue;
            defer self.store.freeNode(allocator, node);
            try self.appendAssertionEvidence(allocator, &from_facts, node, claims.items[index].score, evidence_filter, std.math.maxInt(usize));
        }
        if (fact_keys) try self.attachEventDates(allocator, &from_facts);

        // What search found, in the opened sessions only.
        var from_search = std.ArrayList(MessageResult).empty;
        defer from_search.deinit(allocator);
        errdefer for (from_search.items) |item| results.freeItem(item);
        {
            var write_index: usize = 0;
            for (results.items.items) |item| {
                const source = item.raw_source orelse {
                    results.items.items[write_index] = item;
                    write_index += 1;
                    continue;
                };
                const open = if (source.session_qid) |session_qid| opened.contains(session_qid) or !summarised.contains(session_qid) else true;
                if (!open) {
                    results.freeItem(item);
                    found.trace.rawDropped += 1;
                    continue;
                }
                from_search.append(allocator, item) catch |err| {
                    results.freeItem(item);
                    results.items.items.len = write_index;
                    return err;
                };
            }
            results.items.items.len = write_index;
        }

        // In turn, a message search found and a message behind a fact, each
        // once: a message is not shown beside one of its own chunks. Search
        // goes first: its best hit may be a reply, which no fact leads to.
        try results.items.ensureUnusedCapacity(allocator, from_facts.items.items.len + from_search.items.len);
        const raw_start = results.items.items.len;
        const longest = @max(from_facts.items.items.len, from_search.items.len);
        for (0..longest) |index| {
            for ([_][]const MessageResult{ from_search.items, from_facts.items.items }) |list| {
                if (index >= list.len) continue;
                const item = list[index];
                const repeated = for (results.items.items[raw_start..]) |taken| {
                    if (sameRawEvidence(taken, item)) break true;
                } else false;
                if (repeated) {
                    results.freeItem(item);
                } else {
                    results.items.appendAssumeCapacity(item);
                }
            }
        }
        from_facts.items.clearRetainingCapacity();
        from_search.clearRetainingCapacity();
        found.active = true;
        return found;
    }

    /// `options.facts`: the claims matching the query that consolidation
    /// found replaced, or that replaced another, as dated facts for the
    /// context's facts section. A replaced fact is `superseded` and valid
    /// until the day it was replaced, and the fact that replaced it comes
    /// along, so the reader never sees an old value without the current
    /// one. A claim with no replacement on either side is not listed: the
    /// raw evidence already carries it, and nothing has checked that it
    /// still holds. Claims drawn from the assistant's replies (extraction
    /// up to v3) are left out. The section takes at most
    /// `facts_budget_percent` of the budget, out of the raw evidence's share.
    fn collectFactItems(
        self: *Runtime,
        allocator: std.mem.Allocator,
        enabled: bool,
        query: []const u8,
        mode: SearchMode,
        filter: ItemFilter,
        needs_value: ?Value,
        budget: usize,
    ) !FactItems {
        var facts = FactItems{ .items = .{ .allocator = allocator } };
        errdefer facts.items.deinit();
        if (!enabled or (needsCount(needs_value) > 0 and !needsIncludes(needs_value, "current_facts"))) return facts;

        const hits = try self.collectSearchHits(allocator, query, mode, fact_search_limit, false);
        defer freeHits(allocator, hits);
        const limit = (budget *| facts_budget_percent) / 100;
        var used = estimatePromptTokens(facts_legend) + 8;
        for (hits) |hit| {
            if (!std.mem.startsWith(u8, hit.qid, assertion_qid_prefix)) continue;
            facts.trace.candidates += 1;
            if (facts.items.containsQid(hit.qid)) continue;

            // Only claims with a history; see the doc comment.
            var links = try self.updateLinks(allocator, hit.qid, filter.valid_at);
            defer links.deinit(allocator);
            if (links.replaced_by.items.items.len == 0 and links.replaces.items.items.len == 0) continue;
            if (!try self.appendFactItem(allocator, &facts.items, hit.qid, hit.score, filter, &used, limit)) continue;

            // Both sides of a replacement, whichever one matched the query.
            for ([_][]const []const u8{ links.replaced_by.items.items, links.replaces.items.items }) |linked| {
                for (linked) |qid| {
                    if (facts.items.containsQid(qid)) continue;
                    if (try self.appendFactItem(allocator, &facts.items, qid, hit.score, filter, &used, limit)) facts.trace.linked += 1;
                }
            }
        }
        for (facts.items.items.items) |item| {
            if (std.mem.eql(u8, item.state, "superseded")) facts.trace.superseded += 1;
        }
        facts.trace.kept = facts.items.items.items.len;
        facts.trace.tokens = if (facts.trace.kept > 0) used else 0;
        return facts;
    }

    /// Adds one claim to the facts section when it is live, in scope, said
    /// by a person and still fits. Returns whether it was added.
    fn appendFactItem(
        self: *Runtime,
        allocator: std.mem.Allocator,
        owned: *OwnedItems,
        assertion_qid: []const u8,
        score: f32,
        filter: ItemFilter,
        used: *usize,
        limit: usize,
    ) !bool {
        const node = (try self.store.getNode(allocator, assertion_qid)) orelse return false;
        defer self.store.freeNode(allocator, node);
        if (!std.mem.eql(u8, node.label, "Assertion")) return false;
        const role = try readOptionalPropertyString(allocator, node.properties_json, "role");
        defer if (role) |value| allocator.free(value);
        if (!isSpeakerRole(role orelse "user")) return false;

        var fact_filter = filter;
        fact_filter.labels_value = null;
        fact_filter.event_window = .{};
        fact_filter.allow_hidden = true;
        if (!try appendNodeItem(allocator, owned, node, score, fact_filter)) return false;
        const item = &owned.items.items[owned.items.items.len - 1];
        item.type = "fact";

        var links = try self.updateLinks(allocator, assertion_qid, filter.valid_at);
        defer links.deinit(allocator);
        if (links.replaced_at) |replaced_at| {
            const state = try allocator.dupe(u8, "superseded");
            allocator.free(item.state);
            item.state = state;
            const valid_to = try allocator.dupe(u8, replaced_at);
            if (item.validTo) |value| allocator.free(value);
            item.validTo = valid_to;
        }
        const tokens = estimateFactTokens(item.*);
        if (used.* + tokens > limit) {
            owned.freeItem(owned.items.pop().?);
            return false;
        }
        used.* += tokens;
        return true;
    }

    /// The live updates that touch a claim: the claims that replaced it (and
    /// when the latest did), and the claims it replaced. An update dated
    /// after `valid_at` has not happened yet for that question.
    fn updateLinks(self: *Runtime, allocator: std.mem.Allocator, assertion_qid: []const u8, valid_at: ?[]const u8) !UpdateLinks {
        const edges = try self.store.findEdges(allocator, .{ .to_qid = assertion_qid, .edge_type = "DERIVED_FROM", .limit = 4096 });
        defer self.store.freeEdges(allocator, edges);
        var links = UpdateLinks{ .replaced_by = .{ .allocator = allocator }, .replaces = .{ .allocator = allocator } };
        errdefer links.deinit(allocator);
        for (edges) |edge| {
            if (!std.mem.startsWith(u8, edge.from_qid, update_qid_prefix)) continue;
            const node = (try self.store.getNode(allocator, edge.from_qid)) orelse continue;
            defer self.store.freeNode(allocator, node);
            if (!std.mem.eql(u8, node.label, "Update")) continue;
            if (try propertyBool(allocator, node.properties_json, "deleted")) continue;
            const newer = (try readOptionalPropertyString(allocator, node.properties_json, "assertionQid")) orelse continue;
            defer allocator.free(newer);
            const older = (try readOptionalPropertyString(allocator, node.properties_json, "replacedQid")) orelse continue;
            defer allocator.free(older);
            const created_at = try readOptionalPropertyString(allocator, node.properties_json, "createdAt");
            defer if (created_at) |value| allocator.free(value);
            if (valid_at) |timestamp| {
                if (created_at) |value| {
                    if (timestampBefore(timestamp, value)) continue;
                }
            }
            if (std.mem.eql(u8, older, assertion_qid)) {
                try links.replaced_by.appendUnique(allocator, newer);
                if (created_at) |value| {
                    if (links.replaced_at == null or std.mem.order(u8, value, links.replaced_at.?) == .gt) {
                        const copy = try allocator.dupe(u8, value);
                        if (links.replaced_at) |previous| allocator.free(previous);
                        links.replaced_at = copy;
                    }
                }
            } else if (std.mem.eql(u8, newer, assertion_qid)) {
                try links.replaces.appendUnique(allocator, older);
            }
        }
        return links;
    }

    /// factKeys: adds the raw evidence behind one Assertion hit.
    fn appendAssertionEvidence(
        self: *Runtime,
        allocator: std.mem.Allocator,
        owned: *OwnedItems,
        assertion: storage.Node,
        score: f32,
        filter: ItemFilter,
        limit: usize,
    ) !void {
        if (try propertyBool(allocator, assertion.properties_json, "deleted")) return;
        if (!try filter.scope.matchesNode(allocator, assertion)) return;
        var parsed = try std.json.parseFromSlice(Value, allocator, assertion.properties_json, .{});
        defer parsed.deinit();
        const props = objectValue(parsed.value) orelse return;
        if (owned.fact_keys) |*stats| stats.assertionHits += 1;

        const chunk_qids = arrayValue(props.get("chunkQids"));
        const message_qid = stringField(&props, "sourceMessageQid") orelse return;
        const single = [_]Value{.{ .string = message_qid }};
        const targets: []const Value = if (chunk_qids) |array| (if (array.items.len > 0) array.items else &single) else &single;
        for (targets) |target| {
            if (owned.items.items.len >= limit) return;
            const evidence_qid = stringValue(target) orelse continue;
            if (owned.containsQid(evidence_qid)) continue;
            const evidence = (try self.store.getNode(allocator, evidence_qid)) orelse continue;
            defer self.store.freeNode(allocator, evidence);
            if (!std.mem.eql(u8, evidence.label, "Chunk") and !std.mem.eql(u8, evidence.label, "Message")) continue;
            if (try appendNodeItem(allocator, owned, evidence, score, filter)) {
                owned.items.items[owned.items.items.len - 1].via_assertion = true;
                if (owned.fact_keys) |*stats| stats.evidenceItems += 1;
            }
        }
    }

    /// factKeys: each raw item lists the event dates of the live claims
    /// evidenced by it (its chunk, or its message when unchunked). Dates equal
    /// to the item's own date add nothing and are left out.
    fn attachEventDates(self: *Runtime, allocator: std.mem.Allocator, owned: *OwnedItems) !void {
        for (owned.items.items) |*item| {
            const source = if (item.raw_source) |*value| value else continue;
            source.event_dates = try self.eventDatesForEvidence(allocator, item.qid, source.created_at);
            if (source.event_dates.len > 0) {
                if (owned.fact_keys) |*stats| stats.datedItems += 1;
            }
        }
    }

    fn eventDatesForEvidence(self: *Runtime, allocator: std.mem.Allocator, evidence_qid: []const u8, created_at: ?[]const u8) ![]const []const u8 {
        const edges = try self.store.findEdges(allocator, .{ .to_qid = evidence_qid, .edge_type = "EVIDENCED_BY", .limit = 4096 });
        defer self.store.freeEdges(allocator, edges);
        var dates = OwnedQids{ .allocator = allocator };
        defer dates.deinit();
        for (edges) |edge| {
            if (!std.mem.startsWith(u8, edge.from_qid, assertion_qid_prefix)) continue;
            const node = (try self.store.getNode(allocator, edge.from_qid)) orelse continue;
            defer self.store.freeNode(allocator, node);
            if (!std.mem.eql(u8, node.label, "Assertion")) continue;
            if (try propertyBool(allocator, node.properties_json, "deleted")) continue;
            const event_date = (try readOptionalPropertyString(allocator, node.properties_json, "eventDate")) orelse continue;
            defer allocator.free(event_date);
            const planned = try propertyBool(allocator, node.properties_json, "planned");
            if (!planned) {
                if (created_at) |timestamp| {
                    if (std.mem.eql(u8, dateKey(timestamp), event_date)) continue;
                }
            }
            const tag = try std.fmt.allocPrint(allocator, "{s}{s}", .{ event_date, if (planned) " planned" else "" });
            defer allocator.free(tag);
            try dates.appendUnique(allocator, tag);
        }
        std.mem.sort([]const u8, dates.items.items, {}, stringLessThan);
        const kept = @min(dates.items.items.len, max_event_dates_per_item);
        const result = try allocator.alloc([]const u8, kept);
        var moved: usize = 0;
        errdefer {
            for (result[0..moved]) |date| allocator.free(date);
            allocator.free(result);
        }
        for (dates.items.items[0..kept]) |date| {
            result[moved] = try allocator.dupe(u8, date);
            moved += 1;
        }
        return result;
    }

    /// Records, on each raw item, the slot keys of memories evidenced by its
    /// message that are not active at query time. Only runs when the packet
    /// holds slot memories, since the raw-evidence policy needs a current
    /// version of the slot in the same packet before dropping anything.
    fn markStaleRawEvidence(self: *Runtime, allocator: std.mem.Allocator, owned: *OwnedItems, valid_at: ?[]const u8) !void {
        var has_slot_item = false;
        for (owned.items.items) |item| {
            if (item.raw_source == null and item.slotKey != null) {
                has_slot_item = true;
                break;
            }
        }
        if (!has_slot_item) return;
        for (owned.items.items) |*item| {
            if (item.raw_source) |*source| {
                if (source.stale_slot_keys.len > 0) continue; // already marked
                source.stale_slot_keys = try self.staleSlotKeysForMessage(allocator, source.message_qid, valid_at);
            }
        }
    }

    fn staleSlotKeysForMessage(self: *Runtime, allocator: std.mem.Allocator, message_qid: []const u8, valid_at: ?[]const u8) ![]const []const u8 {
        const edges = try self.store.findEdges(allocator, .{ .to_qid = message_qid, .edge_type = "EVIDENCED_BY", .limit = storage.unlimited });
        defer self.store.freeEdges(allocator, edges);

        var stale = OwnedQids{ .allocator = allocator };
        defer stale.deinit();
        var active = OwnedQids{ .allocator = allocator };
        defer active.deinit();
        for (edges) |edge| {
            const node = (try self.store.getNode(allocator, edge.from_qid)) orelse continue;
            defer self.store.freeNode(allocator, node);
            if (!isSlotMemoryLabel(node.label)) continue;
            if (try propertyBool(allocator, node.properties_json, "deleted")) continue;
            const slot_key = (try readOptionalPropertyString(allocator, node.properties_json, "slotKey")) orelse continue;
            defer allocator.free(slot_key);
            const is_active = if (valid_at) |timestamp|
                try derivedActiveAt(allocator, node, timestamp)
            else
                try propertyEquals(allocator, node.properties_json, "state", "current");
            if (is_active) {
                try active.appendUnique(allocator, slot_key);
            } else {
                try stale.appendUnique(allocator, slot_key);
            }
        }

        var keys = std.ArrayList([]const u8).empty;
        errdefer {
            for (keys.items) |key| allocator.free(key);
            keys.deinit(allocator);
        }
        for (stale.items.items) |key| {
            // A message that also evidences the active version stays relevant.
            if (active.contains(key)) continue;
            try keys.append(allocator, try allocator.dupe(u8, key));
        }
        return keys.toOwnedSlice(allocator);
    }

    /// Every mode returns hits sorted by descending score. With
    /// `exclude_assertions`, each channel drops Assertion hits before fusion.
    fn collectSearchHits(self: *Runtime, allocator: std.mem.Allocator, query: []const u8, mode: SearchMode, limit: usize, exclude_assertions: bool) ![]storage.SearchHit {
        const hits = switch (mode) {
            .fts => try self.lexicalSearch(allocator, query, limit, exclude_assertions),
            .graph => try self.graphSearch(allocator, query, limit, exclude_assertions),
            .vector => self.vectorTextSearch(allocator, query, limit, exclude_assertions) catch |err| switch (err) {
                error.Unsupported => try allocator.alloc(storage.SearchHit, 0),
                else => |e| return e,
            },
            .hybrid => try self.hybridSearch(allocator, query, limit, exclude_assertions),
        };
        sortHitsByScore(hits);
        return hits;
    }

    fn lexicalSearch(self: *Runtime, allocator: std.mem.Allocator, query: []const u8, limit: usize, exclude_assertions: bool) ![]storage.SearchHit {
        var request = limit;
        while (true) {
            const hits = try self.store.fullTextSearch(allocator, .{ .text = query, .limit = request });
            if (!exclude_assertions) return hits;
            if (try withoutAssertionHits(allocator, hits, request, limit)) |kept| return kept;
            request *= 2;
        }
    }

    fn vectorTextSearch(self: *Runtime, allocator: std.mem.Allocator, query: []const u8, limit: usize, exclude_assertions: bool) ![]storage.SearchHit {
        const vector = try self.store.embedText(allocator, query);
        defer allocator.free(vector);
        var request = limit;
        while (true) {
            const hits = try self.store.vectorSearch(allocator, .{ .vector = vector, .limit = request });
            if (!exclude_assertions) return hits;
            if (try withoutAssertionHits(allocator, hits, request, limit)) |kept| return kept;
            request *= 2;
        }
    }

    fn hybridSearch(self: *Runtime, allocator: std.mem.Allocator, query: []const u8, limit: usize, exclude_assertions: bool) ![]storage.SearchHit {
        const fts_hits = try self.lexicalSearch(allocator, query, limit, exclude_assertions);
        defer freeHits(allocator, fts_hits);
        const vector_hits = self.vectorTextSearch(allocator, query, limit, exclude_assertions) catch |err| switch (err) {
            error.Unsupported => try allocator.alloc(storage.SearchHit, 0),
            else => |e| return e,
        };
        defer freeHits(allocator, vector_hits);
        return fuseRankedHits(allocator, &.{ fts_hits, vector_hits }, limit);
    }

    fn graphSearch(self: *Runtime, allocator: std.mem.Allocator, query: []const u8, limit: usize, exclude_assertions: bool) ![]storage.SearchHit {
        const base_hits = if (self.store.capabilities().vector)
            try self.hybridSearch(allocator, query, @max(limit * 2, limit), exclude_assertions)
        else
            try self.lexicalSearch(allocator, query, @max(limit * 2, limit), exclude_assertions);
        defer freeHits(allocator, base_hits);
        sortHitsByScore(base_hits);

        var merged = std.ArrayList(storage.SearchHit).empty;
        errdefer {
            for (merged.items) |hit| allocator.free(hit.qid);
            merged.deinit(allocator);
        }
        try appendRrfHits(allocator, &merged, base_hits, 1.0);

        for (base_hits, 0..) |hit, rank| {
            try self.appendGraphNeighborsForHit(allocator, &merged, hit.qid, reciprocalRank(rank) * 0.75);
        }

        const entity_hits = try self.store.fullTextSearch(allocator, .{ .text = query, .limit = @max(limit * 2, limit) });
        defer freeHits(allocator, entity_hits);
        sortHitsByScore(entity_hits);
        for (entity_hits, 0..) |hit, rank| {
            const node = (try self.store.getNode(allocator, hit.qid)) orelse continue;
            defer self.store.freeNode(allocator, node);
            if (!std.mem.eql(u8, node.label, "Entity")) continue;
            try self.appendMemoryHitsForEntity(allocator, &merged, node.qid, reciprocalRank(rank) * 0.9);
        }

        sortHitsByScore(merged.items);
        if (merged.items.len > limit) {
            for (merged.items[limit..]) |hit| allocator.free(hit.qid);
            merged.shrinkRetainingCapacity(limit);
        }
        return merged.toOwnedSlice(allocator);
    }

    fn appendGraphNeighborsForHit(
        self: *Runtime,
        allocator: std.mem.Allocator,
        merged: *std.ArrayList(storage.SearchHit),
        qid: []const u8,
        score: f32,
    ) !void {
        const node = (try self.store.getNode(allocator, qid)) orelse return;
        defer self.store.freeNode(allocator, node);
        if (std.mem.eql(u8, node.label, "Entity")) {
            try self.appendMemoryHitsForEntity(allocator, merged, qid, score);
            return;
        }

        // Entity mentions are recorded on messages, so chunk hits expand
        // through their parent message.
        const parent_qid = if (std.mem.eql(u8, node.label, "Chunk"))
            try readOptionalPropertyString(allocator, node.properties_json, "messageQid")
        else
            null;
        defer if (parent_qid) |value| allocator.free(value);
        const mention_edges = try self.store.findEdges(allocator, .{
            .from_qid = parent_qid orelse qid,
            .edge_type = "MENTIONS",
            .limit = 32,
        });
        defer self.store.freeEdges(allocator, mention_edges);
        for (mention_edges) |edge| {
            try self.appendMemoryHitsForEntity(allocator, merged, edge.to_qid, score * 0.7);
        }
    }

    fn appendMemoryHitsForEntity(
        self: *Runtime,
        allocator: std.mem.Allocator,
        merged: *std.ArrayList(storage.SearchHit),
        entity_qid: []const u8,
        score: f32,
    ) !void {
        const incoming = try self.store.findEdges(allocator, .{
            .to_qid = entity_qid,
            .edge_type = "MENTIONS",
            .limit = 128,
        });
        defer self.store.freeEdges(allocator, incoming);
        for (incoming) |edge| {
            const node = (try self.store.getNode(allocator, edge.from_qid)) orelse continue;
            defer self.store.freeNode(allocator, node);
            if (std.mem.eql(u8, node.label, "Entity")) continue;
            try self.appendNodeHitScore(allocator, merged, node, score);
        }

        const outgoing = try self.store.findEdges(allocator, .{
            .from_qid = entity_qid,
            .edge_type = "MENTIONED_IN",
            .limit = 128,
        });
        defer self.store.freeEdges(allocator, outgoing);
        for (outgoing) |edge| {
            const node = (try self.store.getNode(allocator, edge.to_qid)) orelse continue;
            defer self.store.freeNode(allocator, node);
            if (std.mem.eql(u8, node.label, "Entity")) continue;
            try self.appendNodeHitScore(allocator, merged, node, score);
        }
    }

    /// Adds a graph hit for `node`, or for each of its chunks when the node is
    /// a chunked (unsearchable) message.
    fn appendNodeHitScore(
        self: *Runtime,
        allocator: std.mem.Allocator,
        merged: *std.ArrayList(storage.SearchHit),
        node: storage.Node,
        score: f32,
    ) !void {
        if (std.mem.eql(u8, node.label, "Message") and try propertyIsFalse(allocator, node.properties_json, "searchable")) {
            const chunk_edges = try self.store.findEdges(allocator, .{ .from_qid = node.qid, .edge_type = "HAS_CHUNK", .limit = 100_000 });
            defer self.store.freeEdges(allocator, chunk_edges);
            for (chunk_edges) |edge| {
                try appendHitScore(allocator, merged, edge.to_qid, score);
            }
            return;
        }
        try appendHitScore(allocator, merged, node.qid, score);
    }

    fn appendCoreItems(self: *Runtime, allocator: std.mem.Allocator, owned: *OwnedItems, scope: Scope, include_evidence: bool, include_debug: bool) !void {
        var core_nodes = self.store.iterateNodes(allocator, .{ .label = "Core" });
        defer core_nodes.deinit();

        while (try core_nodes.next()) |core_qid| {
            const node = (try self.store.getNode(allocator, core_qid)) orelse continue;
            defer self.store.freeNode(allocator, node);
            if (!std.mem.eql(u8, node.label, "Core")) continue;
            if (try propertyBool(allocator, node.properties_json, "deleted")) continue;
            if (!try scope.matchesNode(allocator, node)) continue;
            if (owned.containsQid(node.qid)) continue;

            const text = textForNode(allocator, node) catch continue;
            errdefer allocator.free(text);
            const evidence = if (include_evidence) try evidenceForNode(allocator, node) else try allocator.alloc(EvidenceResult, 0);
            errdefer freeEvidence(allocator, evidence);
            const state = try stateForNode(allocator, node);
            errdefer allocator.free(state);
            const result_qid = try allocator.dupe(u8, node.qid);
            errdefer allocator.free(result_qid);
            try owned.items.append(allocator, .{
                .qid = result_qid,
                .type = "core",
                .text = text,
                .score = 1.0,
                .state = state,
                .evidence = evidence,
                .includeDebug = include_debug,
            });
        }
    }

    fn findCoreBlockQid(self: *Runtime, allocator: std.mem.Allocator, scope: Scope, block_key: []const u8) !?[]u8 {
        const where = [_]storage.PropertyMatch{.{ .name = "blockKey", .value = block_key }};
        var blocks = self.store.iterateNodes(allocator, .{ .label = "Core", .where = &where });
        defer blocks.deinit();

        while (try blocks.next()) |block_qid| {
            const node = (try self.store.getNode(allocator, block_qid)) orelse continue;
            defer self.store.freeNode(allocator, node);
            if (!std.mem.eql(u8, node.label, "Core")) continue;
            if (try propertyBool(allocator, node.properties_json, "deleted")) continue;
            if (!try scope.matchesNode(allocator, node)) continue;
            if (try propertyEquals(allocator, node.properties_json, "blockKey", block_key)) {
                const qid = try allocator.dupe(u8, node.qid);
                return qid;
            }
        }
        return null;
    }

    pub fn runEntityResolveJobs(self: *Runtime, allocator: std.mem.Allocator, owner: []const u8, limit: usize) !EntityJobRunResult {
        const materialized = try jobs.materializeStream(
            allocator,
            self.store,
            streams.entity_resolve_requested,
            streams.workerKindForStream(streams.entity_resolve_requested),
            .{ .limit = limit },
        );
        _ = try jobs.reclaimExpiredLeases(allocator, self.store, self.nowMs());
        const leases = try jobs.leasePendingJobs(allocator, self.store, .{
            .worker_kind = streams.workerKindForStream(streams.entity_resolve_requested),
            .owner = owner,
            .now_ms = self.nowMs(),
            .limit = limit,
        });
        defer jobs.freeLeaseResults(allocator, leases);

        var succeeded: usize = 0;
        var failed: usize = 0;
        var last_error: ?[]const u8 = null;
        for (leases) |lease| {
            self.processEntityResolveLease(allocator, lease) catch |err| {
                last_error = @errorName(err);
                const error_json = try std.fmt.allocPrint(allocator, "{{\"error\":\"{s}\"}}", .{@errorName(err)});
                defer allocator.free(error_json);
                _ = jobs.failJob(allocator, self.store, lease.qid, error_json, self.nowMs()) catch {};
                failed += 1;
                continue;
            };
            try jobs.completeJob(allocator, self.store, lease.qid, self.nowMs());
            succeeded += 1;
        }

        return .{
            .materializedCount = materialized.createdCount,
            .leasedCount = leases.len,
            .succeededCount = succeeded,
            .failedCount = failed,
            .lastError = last_error,
        };
    }

    fn processEntityResolveLease(self: *Runtime, allocator: std.mem.Allocator, lease: jobs.LeaseResult) !void {
        if (self.options.entity_provider.kind == .none) return error.ProviderUnavailable;
        const payload_json = try self.payloadJsonForLease(allocator, lease);
        defer allocator.free(payload_json);

        var parsed = try std.json.parseFromSlice(Value, allocator, payload_json, .{});
        defer parsed.deinit();
        const payload = switch (parsed.value) {
            .object => |object| object,
            else => return error.InvalidRequest,
        };
        const scope = parseScope(&payload);
        const message_qids = arrayValue(payload.get("messageQids")) orelse return error.InvalidRequest;
        for (message_qids.items) |qid_value| {
            const message_qid = stringValue(qid_value) orelse continue;
            const node = (try self.store.getNode(allocator, message_qid)) orelse continue;
            defer self.store.freeNode(allocator, node);
            if (!std.mem.eql(u8, node.label, "Message")) continue;
            if (try propertyBool(allocator, node.properties_json, "deleted")) continue;
            const text = textForNode(allocator, node) catch continue;
            defer allocator.free(text);
            var entities = try providers.resolveEntities(allocator, self.options.io, self.options.entity_provider, text);
            defer entities.deinit();
            try self.writeEntityMentions(allocator, scope, message_qid, entities.items.items);
        }
    }

    fn payloadJsonForLease(self: *Runtime, allocator: std.mem.Allocator, lease: jobs.LeaseResult) ![]u8 {
        if (try self.store.getNode(allocator, lease.qid)) |job_node| {
            defer self.store.freeNode(allocator, job_node);
            if (try readOptionalPropertyString(allocator, job_node.properties_json, "payloadJson")) |payload_json| {
                return payload_json;
            }
        }
        const entries = try self.store.readStream(
            allocator,
            lease.stream,
            if (lease.sequence > 0) lease.sequence - 1 else 0,
            1,
        );
        defer freeStreamEntries(allocator, entries);
        if (entries.len == 0 or entries[0].sequence != lease.sequence) return error.NotFound;
        return allocator.dupe(u8, entries[0].payload_json);
    }

    fn writeEntityMentions(self: *Runtime, allocator: std.mem.Allocator, scope: Scope, source_qid: []const u8, entities: []const providers.ResolvedEntity) !void {
        for (entities) |entity| {
            const entity_qid = try entityQid(allocator, scope, entity);
            defer allocator.free(entity_qid);
            // Index text for graph seeding: the canonical name plus aliases.
            const search_text = try entitySearchText(allocator, entity);
            defer allocator.free(search_text);
            const props = try stringifyAlloc(allocator, .{
                .kind = "entity",
                .qtype = "entity",
                .searchText = search_text,
                .canonicalName = entity.name,
                .entityType = entity.entity_type,
                .aliases = entity.aliases,
                .state = "current",
                .tenantId = scope.tenant_id,
                .userId = scope.user_id,
                .agentId = scope.agent_id,
                .projectId = scope.project_id,
                .deleted = false,
            });
            defer allocator.free(props);
            if (try self.store.getNode(allocator, entity_qid)) |existing| {
                self.store.freeNode(allocator, existing);
            } else {
                try self.store.putNode(.{ .qid = entity_qid, .label = "Entity", .properties_json = props });
            }
            try self.putDeterministicEdge(allocator, source_qid, entity_qid, "MENTIONS");
        }
    }

    /// Runs pending `extract` jobs: each job's source messages go to the
    /// extract provider, the reply is grounded (exact quotes, E1's unique
    /// repair), and accepted claims are written as Assertion nodes linked
    /// EVIDENCED_BY to their source message and chunk. Up to `concurrency`
    /// jobs' provider calls run at once when the runtime has an Io; storage
    /// reads and writes stay on the calling thread.
    pub fn runExtractJobs(self: *Runtime, allocator: std.mem.Allocator, owner: []const u8, limit: usize, concurrency: usize) !ExtractJobRunResult {
        if (!extractProviderUsable(self.options.extract_provider)) return error.ProviderUnavailable;
        // Jobs the daemon already started in the background finish first, so
        // this call returns only when every extract job has run.
        var result = ExtractJobRunResult{};
        if (try self.finishBackgroundWork(allocator)) |finished| switch (finished) {
            .extract => |extracted| result = extracted,
            .consolidate, .patterns, .summaries => {},
        };
        const worker_kind = streams.workerKindForStream(streams.extract_requested);
        const materialized = try jobs.materializeStream(allocator, self.store, streams.extract_requested, worker_kind, .{ .limit = limit });
        _ = try jobs.reclaimExpiredLeases(allocator, self.store, self.nowMs());
        const leases = try jobs.leasePendingJobs(allocator, self.store, .{
            .worker_kind = worker_kind,
            .owner = owner,
            .now_ms = self.nowMs(),
            .limit = limit,
        });
        defer jobs.freeLeaseResults(allocator, leases);

        result.materializedCount += materialized.createdCount;
        result.leasedCount += leases.len;
        const batch_size = @max(concurrency, 1);
        var start: usize = 0;
        while (start < leases.len) : (start += batch_size) {
            try self.runExtractBatch(allocator, leases[start..@min(start + batch_size, leases.len)], &result);
        }
        return result;
    }

    fn runExtractBatch(self: *Runtime, allocator: std.mem.Allocator, batch: []const jobs.LeaseResult, result: *ExtractJobRunResult) !void {
        const tasks = try allocator.alloc(ExtractTask, batch.len);
        for (tasks, batch) |*task, lease| task.* = .{ .lease = lease };
        defer {
            for (tasks) |*task| task.deinit(allocator);
            allocator.free(tasks);
        }
        try self.prepareExtractTasks(allocator, tasks);
        self.callExtractTasks(allocator, tasks);
        try self.applyExtractTasks(allocator, tasks, result);
    }

    /// Loads each task's source messages. A task that cannot be prepared
    /// carries its failure and makes no provider call.
    fn prepareExtractTasks(self: *Runtime, allocator: std.mem.Allocator, tasks: []ExtractTask) !void {
        for (tasks) |*task| {
            self.prepareExtractTask(allocator, task) catch |err| {
                if (err == error.OutOfMemory) return err;
                task.failure = err;
            };
        }
    }

    /// The storage half of a batch, after its provider calls: grounds every
    /// reply, writes the accepted claims and settles each job.
    fn applyExtractTasks(self: *Runtime, allocator: std.mem.Allocator, tasks: []ExtractTask, result: *ExtractJobRunResult) !void {
        // Embed all accepted claims in batched requests before the writes
        // (putNode would embed them one by one).
        var texts = std.ArrayList([]const u8).empty;
        defer texts.deinit(allocator);
        for (tasks) |*task| {
            if (task.failure != null) continue;
            for ([_]?fact_extraction.Grounding{ task.grounding, task.recall_grounding }) |reading| {
                const grounding = reading orelse continue;
                for (grounding.claims) |claim| try texts.append(allocator, claim.stated_text orelse claim.text);
            }
        }
        self.store.prefetchEmbeddings(texts.items) catch {};
        defer self.store.clearPrefetchedEmbeddings();

        for (tasks) |*task| {
            result.calls += task.calls;
            result.jsonRetries += task.json_retries;
            if (task.failure) |err| {
                result.failedCount += 1;
                result.lastError = @errorName(err);
                const error_json = try stringifyAlloc(allocator, .{ .@"error" = @errorName(err), .calls = task.calls });
                defer allocator.free(error_json);
                _ = jobs.failJob(allocator, self.store, task.lease.qid, error_json, self.nowMs()) catch {};
                continue;
            }
            const written = try self.writeExtractTask(allocator, task);
            result.succeededCount += 1;
            result.sourceMessages += task.sources.items.len;
            result.assertionsWritten += written.total;
            result.recallMessages += task.recall_messages;
            result.recallAssertions += written.recalled;
            if (task.grounding) |grounding| result.counts.add(grounding.counts);
            if (task.recall_grounding) |grounding| result.counts.add(grounding.counts);
        }
    }

    /// Loads the messages people wrote in the job's turn (full text,
    /// reassembled from chunks) and builds the extraction request. A job
    /// with no such message left, because the turn held only replies or
    /// everything was forgotten, has nothing to extract and makes no call.
    fn prepareExtractTask(self: *Runtime, allocator: std.mem.Allocator, task: *ExtractTask) !void {
        const payload_json = try self.payloadJsonForLease(allocator, task.lease);
        defer allocator.free(payload_json);
        task.payload = try std.json.parseFromSlice(Value, allocator, payload_json, .{ .allocate = .alloc_always });
        const payload = objectValue(task.payload.?.value) orelse return error.InvalidRequest;
        task.scope = parseScope(&payload);
        task.session_qid = stringField(&payload, "sessionQid");
        task.turn_qid = stringField(&payload, "turnQid");
        const message_qids = arrayValue(payload.get("messageQids")) orelse return error.InvalidRequest;
        for (message_qids.items) |qid_value| {
            const message_qid = stringValue(qid_value) orelse continue;
            const source = (try self.loadExtractSource(allocator, message_qid)) orelse continue;
            // Facts come from what people say about themselves, not from
            // the replies they got.
            if (!isSpeakerRole(source.role)) {
                source.deinit(allocator);
                continue;
            }
            task.sources.append(allocator, source) catch |err| {
                source.deinit(allocator);
                return err;
            };
        }
        if (task.sources.items.len == 0) return;
        const messages = try task.sourceMessages(allocator);
        defer allocator.free(messages);
        task.user_content = try fact_extraction.buildUserContent(allocator, task.sources.items[0].created_at, messages);
    }

    fn loadExtractSource(self: *Runtime, allocator: std.mem.Allocator, message_qid: []const u8) !?ExtractSource {
        const node = (try self.store.getNode(allocator, message_qid)) orelse return null;
        defer self.store.freeNode(allocator, node);
        if (!std.mem.eql(u8, node.label, "Message")) return null;
        var parsed = try std.json.parseFromSlice(Value, allocator, node.properties_json, .{});
        defer parsed.deinit();
        const props = objectValue(parsed.value) orelse return null;
        if (boolField(&props, "deleted") orelse false) return null;

        var content = std.ArrayList(u8).empty;
        defer content.deinit(allocator);
        var chunk_ends = std.ArrayList(usize).empty;
        defer chunk_ends.deinit(allocator);
        const chunk_count = integerField(&props, "chunkCount") orelse 0;
        if (chunk_count > 1) {
            // The message keeps a clamped copy; its chunks hold the full text.
            var index: usize = 0;
            while (index < chunk_count) : (index += 1) {
                const chunk_qid = try chunkQid(allocator, message_qid, index);
                defer allocator.free(chunk_qid);
                const chunk = (try self.store.getNode(allocator, chunk_qid)) orelse return null;
                defer self.store.freeNode(allocator, chunk);
                if (try propertyBool(allocator, chunk.properties_json, "deleted")) return null;
                const text = try readPropertyString(allocator, chunk.properties_json, "content");
                defer allocator.free(text);
                try content.appendSlice(allocator, text);
                try chunk_ends.append(allocator, content.items.len);
            }
        } else {
            try content.appendSlice(allocator, stringField(&props, "content") orelse return null);
        }
        if (content.items.len == 0) return null;

        var source = ExtractSource{ .message_qid = try allocator.dupe(u8, message_qid) };
        errdefer source.deinit(allocator);
        source.role = try allocator.dupe(u8, stringField(&props, "role") orelse "user");
        source.created_at = try dupeOptional(allocator, optionalStringField(&props, "createdAt"));
        source.session_id = try dupeOptional(allocator, optionalStringField(&props, "sessionId"));
        source.session_qid = try dupeOptional(allocator, optionalStringField(&props, "sessionQid"));
        source.message_index = integerField(&props, "messageIndex");
        source.content = try content.toOwnedSlice(allocator);
        source.chunk_ends = try chunk_ends.toOwnedSlice(allocator);
        return source;
    }

    fn callExtractTasks(self: *Runtime, allocator: std.mem.Allocator, tasks: []ExtractTask) void {
        const endpoint = self.options.extract_provider;
        const io = self.options.io orelse {
            for (tasks) |*task| callExtractTask(task, allocator, null, endpoint);
            return;
        };
        var group: std.Io.Group = .init;
        for (tasks) |*task| {
            if (tasks.len == 1) {
                callExtractTask(task, allocator, io, endpoint);
                continue;
            }
            group.concurrent(io, callExtractTask, .{ task, allocator, @as(?std.Io, io), endpoint }) catch
                callExtractTask(task, allocator, io, endpoint);
        }
        group.await(io) catch {};
    }

    /// Writes one job's grounded claims, those of the first reading and
    /// those of the second, and completes the job with its counts.
    fn writeExtractTask(self: *Runtime, allocator: std.mem.Allocator, task: *ExtractTask) !ExtractWritten {
        var written = ExtractWritten{};
        var counts = fact_extraction.Counts{};
        if (task.grounding) |grounding| {
            counts.add(grounding.counts);
            for (grounding.claims) |claim| {
                if (try self.writeAssertion(allocator, task, claim, fact_extraction.prompt_version)) written.total += 1;
            }
        }
        if (task.recall_grounding) |grounding| {
            counts.add(grounding.counts);
            for (grounding.claims) |claim| {
                if (!try self.writeAssertion(allocator, task, claim, fact_extraction.recall_prompt_version)) continue;
                written.total += 1;
                written.recalled += 1;
            }
        }
        const summary = .{
            .promptVersion = fact_extraction.prompt_version,
            .provider = self.options.extract_provider.name,
            .model = self.options.extract_provider.model,
            .calls = task.calls,
            .jsonRetries = task.json_retries,
            .sourceMessages = task.sources.items.len,
            .assertionsWritten = written.total,
            .recallMessages = task.recall_messages,
            .recallAssertions = written.recalled,
            .counts = counts,
        };
        const result_json = try stringifyAlloc(allocator, summary);
        defer allocator.free(result_json);
        try jobs.completeJobWithResult(allocator, self.store, task.lease.qid, self.nowMs(), result_json);
        const event_payload = try stringifyAlloc(allocator, .{
            .method = "memory.extract.completed",
            .jobQid = task.lease.qid,
            .sessionQid = task.session_qid,
            .turnQid = task.turn_qid,
            .result = summary,
        });
        defer allocator.free(event_payload);
        _ = try self.publishEvent(streams.extract_completed, event_payload);
        if (self.options.consolidate_updates and task.user_assertions.items.len > 0) {
            try self.queueConsolidateJob(allocator, task);
        }
        // Pattern nodes are built from what was written, not from the claims
        // drawn from it, so new messages are reason enough.
        if (task.sources.items.len > 0) try self.queuePatternJob(allocator, task.scope);
        // Summaries rest on the claims and on the messages themselves: a
        // session with nothing to extract still has something to say.
        if (task.sources.items.len > 0) try self.queueSummaryJob(allocator, task.scope);
        return written;
    }

    /// Writes one claim as an Assertion node: its text is a search key, and
    /// EVIDENCED_BY edges lead to the source message and to every chunk the
    /// quote overlaps. Qids are content-derived, so rerunning a job rewrites
    /// the same nodes. Returns false when the source is gone.
    fn writeAssertion(self: *Runtime, allocator: std.mem.Allocator, task: *ExtractTask, claim: fact_extraction.Claim, prompt_version: []const u8) !bool {
        const source = task.sources.items[claim.message_index];
        // The message may have been forgotten while the provider call ran.
        const message = (try self.store.getNode(allocator, source.message_qid)) orelse return false;
        const forgotten = try propertyBool(allocator, message.properties_json, "deleted");
        self.store.freeNode(allocator, message);
        if (forgotten) return false;

        // Keyed on the fact as the model wrote it, so the qid does not depend
        // on how its times are written out.
        const key = try std.fmt.allocPrint(allocator, "{s}\x1f{s}\x1f{s}", .{ source.message_qid, claim.quote, claim.stated_text orelse claim.text });
        defer allocator.free(key);
        const qid = try hashQid(allocator, "asrt", key);
        defer allocator.free(qid);

        var chunk_qids = std.ArrayList([]const u8).empty;
        defer {
            for (chunk_qids.items) |chunk_qid| allocator.free(chunk_qid);
            chunk_qids.deinit(allocator);
        }
        if (source.chunk_ends.len > 1) {
            if (fact_extraction.quoteChunkRange(source.content, claim.quote, source.chunk_ends)) |range| {
                var index = range.first;
                while (index <= range.last) : (index += 1) {
                    const chunk_qid = try chunkQid(allocator, source.message_qid, index);
                    chunk_qids.append(allocator, chunk_qid) catch |err| {
                        allocator.free(chunk_qid);
                        return err;
                    };
                }
            }
        }

        const text = try clampPropertyText(allocator, claim.text);
        defer allocator.free(text);
        const quote = try clampPropertyText(allocator, claim.quote);
        defer allocator.free(quote);
        const stated_text = if (claim.stated_text) |stated| try clampPropertyText(allocator, stated) else null;
        defer if (stated_text) |stated| allocator.free(stated);
        const props = try stringifyAlloc(allocator, .{
            .kind = "assertion",
            .qtype = "assertion",
            .text = text,
            .statedText = stated_text,
            // Search matches a claim by what it is about, in the words it was
            // said in. When it happened is matched through `eventDate`: with
            // "April 2023" in the search text, a question that names April
            // pulls in everything said that month.
            .searchText = stated_text,
            .quote = quote,
            .eventDate = claim.event_date,
            .eventStart = claim.event_start,
            .eventEnd = claim.event_end,
            .planned = claim.planned,
            .sourceMessageQid = source.message_qid,
            .evidenceQid = source.message_qid,
            .chunkQids = chunk_qids.items,
            .messageIndex = source.message_index,
            .role = source.role,
            .createdAt = source.created_at,
            .sessionQid = task.session_qid,
            .sessionId = source.session_id,
            .turnQid = task.turn_qid,
            .tenantId = task.scope.tenant_id,
            .userId = task.scope.user_id,
            .agentId = task.scope.agent_id,
            .projectId = task.scope.project_id,
            .extractorProvider = self.options.extract_provider.name,
            .extractorModel = self.options.extract_provider.model,
            .promptVersion = prompt_version,
            .groundingRepaired = claim.repaired,
            .jobQid = task.lease.qid,
            .state = "current",
            .deleted = false,
        });
        defer allocator.free(props);
        try self.store.putNode(.{ .qid = qid, .label = "Assertion", .properties_json = props });
        try self.putDeterministicEdge(allocator, qid, source.message_qid, "EVIDENCED_BY");
        for (chunk_qids.items) |chunk_qid| {
            try self.putDeterministicEdge(allocator, qid, chunk_qid, "EVIDENCED_BY");
        }
        const owned_qid = try allocator.dupe(u8, qid);
        task.user_assertions.append(allocator, owned_qid) catch |err| {
            allocator.free(owned_qid);
            return err;
        };
        return true;
    }

    /// Queues the consolidation of an extract job's claims against what was
    /// said before.
    fn queueConsolidateJob(self: *Runtime, allocator: std.mem.Allocator, task: *const ExtractTask) !void {
        const payload = try stringifyAlloc(allocator, .{
            .method = "memory.consolidate.requested",
            .sourceMethod = "memory.extract",
            .sessionQid = task.session_qid,
            .assertionQids = task.user_assertions.items,
            .scope = task.scope.json(),
        });
        defer allocator.free(payload);
        const event = try self.publishEvent(streams.consolidate_requested, payload);
        _ = try jobs.materializeStream(allocator, self.store, streams.consolidate_requested, streams.workerKindForStream(streams.consolidate_requested), .{
            .after_sequence = if (event.sequence > 0) event.sequence - 1 else 0,
            .limit = 1,
        });
        self.background_dirty = true;
    }

    /// Runs pending `consolidate` jobs. Each compares the claims extracted
    /// from one conversation's user messages with what the user said in
    /// earlier conversations, and stores an `Update` node for every claim
    /// that replaces an earlier statement. The node is evidenced by both
    /// messages, so forgetting either removes it. Nothing is rewritten: both
    /// messages and both claims keep their text, and `options.facts` lists
    /// the earlier claim as superseded.
    pub fn runConsolidateJobs(self: *Runtime, allocator: std.mem.Allocator, owner: []const u8, limit: usize, concurrency: usize) !ConsolidateJobRunResult {
        if (!extractProviderUsable(self.options.extract_provider)) return error.ProviderUnavailable;
        var result = ConsolidateJobRunResult{};
        if (try self.finishBackgroundWork(allocator)) |finished| switch (finished) {
            .consolidate => |consolidated| result = consolidated,
            .extract, .patterns, .summaries => {},
        };
        _ = try jobs.reclaimExpiredLeases(allocator, self.store, self.nowMs());
        const leases = try jobs.leasePendingJobs(allocator, self.store, .{
            .worker_kind = streams.workerKindForStream(streams.consolidate_requested),
            .owner = owner,
            .now_ms = self.nowMs(),
            .limit = limit,
        });
        defer jobs.freeLeaseResults(allocator, leases);
        result.leasedCount += leases.len;

        const batch_size = @max(concurrency, 1);
        var start: usize = 0;
        while (start < leases.len) : (start += batch_size) {
            const batch = leases[start..@min(start + batch_size, leases.len)];
            const tasks = try allocator.alloc(ConsolidateTask, batch.len);
            for (tasks, batch) |*task, lease| task.* = .{ .lease = lease };
            defer {
                for (tasks) |*task| task.deinit(allocator);
                allocator.free(tasks);
            }
            try self.prepareConsolidateTasks(allocator, tasks);
            self.callConsolidateTasks(allocator, tasks);
            try self.applyConsolidateTasks(allocator, tasks, &result);
        }
        return result;
    }

    fn prepareConsolidateTasks(self: *Runtime, allocator: std.mem.Allocator, tasks: []ConsolidateTask) !void {
        for (tasks) |*task| {
            self.prepareConsolidateTask(allocator, task) catch |err| {
                if (err == error.OutOfMemory) return err;
                task.failure = err;
            };
        }
    }

    /// Loads the job's live claims and, for each, the same person's earlier
    /// claims that search ranks closest to it. A job with no claim or no
    /// earlier fact makes no call.
    fn prepareConsolidateTask(self: *Runtime, allocator: std.mem.Allocator, task: *ConsolidateTask) !void {
        const payload_json = try self.payloadJsonForLease(allocator, task.lease);
        defer allocator.free(payload_json);
        task.payload = try std.json.parseFromSlice(Value, allocator, payload_json, .{ .allocate = .alloc_always });
        const payload = objectValue(task.payload.?.value) orelse return error.InvalidRequest;
        task.scope = parseScope(&payload);
        task.session_qid = stringField(&payload, "sessionQid");
        const assertion_qids = arrayValue(payload.get("assertionQids")) orelse return error.InvalidRequest;
        var claims = std.ArrayList(ConsolidateClaim).empty;
        defer {
            for (claims.items) |claim| claim.deinit(allocator);
            claims.deinit(allocator);
        }
        for (assertion_qids.items) |qid_value| {
            if (claims.items.len >= max_consolidate_claims) break;
            const assertion_qid = stringValue(qid_value) orelse continue;
            const claim = (try self.loadConsolidateClaim(allocator, assertion_qid, task.scope)) orelse continue;
            claims.append(allocator, claim) catch |err| {
                claim.deinit(allocator);
                return err;
            };
        }
        if (claims.items.len == 0) return;

        // One batched embedding request serves the searches below.
        if (self.store.capabilities().vector) {
            const texts = try allocator.alloc([]const u8, claims.items.len);
            defer allocator.free(texts);
            for (claims.items, texts) |claim, *slot| slot.* = claim.search_text;
            self.store.prefetchEmbeddings(texts) catch {};
        }
        defer self.store.clearPrefetchedEmbeddings();
        // Only a claim with something to compare against is sent.
        for (claims.items) |*claim| {
            if (try self.appendEarlierFacts(allocator, task, claim.*) == 0) continue;
            try task.claims.append(allocator, claim.*);
            claim.* = .{};
        }
        if (task.claims.items.len == 0 or task.earlier.items.len == 0) return;

        const wire_claims = try task.wireClaims(allocator);
        defer allocator.free(wire_claims);
        const wire_earlier = try task.wireEarlier(allocator);
        defer allocator.free(wire_earlier);
        task.user_content = try fact_updates.buildUserContent(allocator, wire_claims, wire_earlier);
    }

    /// A live claim in `scope` that a person stated; null for anything else.
    fn loadConsolidateClaim(self: *Runtime, allocator: std.mem.Allocator, assertion_qid: []const u8, scope: Scope) !?ConsolidateClaim {
        const node = (try self.store.getNode(allocator, assertion_qid)) orelse return null;
        defer self.store.freeNode(allocator, node);
        if (!std.mem.eql(u8, node.label, "Assertion")) return null;
        if (!try scope.matchesNode(allocator, node)) return null;
        var parsed = try std.json.parseFromSlice(Value, allocator, node.properties_json, .{});
        defer parsed.deinit();
        const props = objectValue(parsed.value) orelse return null;
        if (boolField(&props, "deleted") orelse false) return null;
        const text = stringField(&props, "text") orelse return null;
        const message_qid = stringField(&props, "sourceMessageQid") orelse return null;
        const role = stringField(&props, "role") orelse "user";
        if (!isSpeakerRole(role)) return null;

        var claim = ConsolidateClaim{};
        errdefer claim.deinit(allocator);
        claim.assertion_qid = try allocator.dupe(u8, assertion_qid);
        claim.message_qid = try allocator.dupe(u8, message_qid);
        claim.text = try allocator.dupe(u8, text);
        claim.search_text = try allocator.dupe(u8, stringField(&props, "statedText") orelse text);
        claim.quote = try allocator.dupe(u8, stringField(&props, "quote") orelse "");
        claim.role = try allocator.dupe(u8, role);
        claim.created_at = try dupeOptional(allocator, optionalStringField(&props, "createdAt"));
        claim.session_qid = try dupeOptional(allocator, optionalStringField(&props, "sessionQid"));
        return claim;
    }

    /// Adds the earlier claims by the same person that match `claim`: from
    /// another conversation, stated before it. Hybrid search where the store
    /// has vectors, since an update rarely repeats the old wording ("gym at
    /// 7:00 pm" against "before heading to the gym, usually at 6:00 pm").
    /// Returns how many earlier facts the claim has to be compared with.
    fn appendEarlierFacts(self: *Runtime, allocator: std.mem.Allocator, task: *ConsolidateTask, claim: ConsolidateClaim) !usize {
        if (fact_updates.dayOf(claim.created_at) == null) return 0;
        const mode: SearchMode = if (self.store.capabilities().vector) .hybrid else .fts;
        const hits = try self.collectSearchHits(allocator, claim.search_text, mode, consolidate_search_limit, false);
        defer freeHits(allocator, hits);
        var found: usize = 0;
        for (hits) |hit| {
            if (found >= max_earlier_per_claim) break;
            if (!std.mem.startsWith(u8, hit.qid, assertion_qid_prefix)) continue;
            if (std.mem.eql(u8, hit.qid, claim.assertion_qid)) continue;
            if (task.hasEarlier(hit.qid)) {
                found += 1;
                continue;
            }
            if (task.earlier.items.len >= max_consolidate_earlier) break;
            const fact = (try self.loadConsolidateClaim(allocator, hit.qid, task.scope)) orelse continue;
            var keep = fact_updates.isBefore(fact.created_at, claim.created_at) and std.mem.eql(u8, fact.role, claim.role);
            // An earlier conversation, not an earlier line of this one.
            if (claim.session_qid) |session_qid| {
                if (fact.session_qid) |other| {
                    if (std.mem.eql(u8, other, session_qid)) keep = false;
                }
            }
            if (!keep) {
                fact.deinit(allocator);
                continue;
            }
            task.earlier.append(allocator, fact) catch |err| {
                fact.deinit(allocator);
                return err;
            };
            found += 1;
        }
        return found;
    }

    fn callConsolidateTasks(self: *Runtime, allocator: std.mem.Allocator, tasks: []ConsolidateTask) void {
        const endpoint = self.options.extract_provider;
        const io = self.options.io orelse {
            for (tasks) |*task| callConsolidateTask(task, allocator, null, endpoint);
            return;
        };
        var group: std.Io.Group = .init;
        for (tasks) |*task| {
            if (tasks.len == 1) {
                callConsolidateTask(task, allocator, io, endpoint);
                continue;
            }
            group.concurrent(io, callConsolidateTask, .{ task, allocator, @as(?std.Io, io), endpoint }) catch
                callConsolidateTask(task, allocator, io, endpoint);
        }
        group.await(io) catch {};
    }

    /// The storage half of a batch: checks every proposed update against
    /// the stored text, writes the ones that hold and settles each job.
    fn applyConsolidateTasks(self: *Runtime, allocator: std.mem.Allocator, tasks: []ConsolidateTask, result: *ConsolidateJobRunResult) !void {
        for (tasks) |*task| {
            result.calls += task.calls;
            if (task.failure) |err| {
                result.failedCount += 1;
                result.lastError = @errorName(err);
                const error_json = try stringifyAlloc(allocator, .{ .@"error" = @errorName(err), .calls = task.calls });
                defer allocator.free(error_json);
                _ = jobs.failJob(allocator, self.store, task.lease.qid, error_json, self.nowMs()) catch {};
                continue;
            }
            try self.writeConsolidateTask(allocator, task, result);
            result.succeededCount += 1;
        }
    }

    fn writeConsolidateTask(self: *Runtime, allocator: std.mem.Allocator, task: *ConsolidateTask, result: *ConsolidateJobRunResult) !void {
        var written: usize = 0;
        for (task.accepted.items) |update| {
            const claim = task.claims.items[update.claim_index];
            const fact = task.earlier.items[update.earlier_index];
            if (try self.writeUpdate(allocator, task, claim, fact, update)) written += 1;
        }
        const summary = .{
            .promptVersion = fact_updates.prompt_version,
            .provider = self.options.extract_provider.name,
            .model = self.options.extract_provider.model,
            .calls = task.calls,
            .claims = task.claims.items.len,
            .earlier = task.earlier.items.len,
            .updatesWritten = written,
            .counts = task.counts,
        };
        const result_json = try stringifyAlloc(allocator, summary);
        defer allocator.free(result_json);
        try jobs.completeJobWithResult(allocator, self.store, task.lease.qid, self.nowMs(), result_json);
        const event_payload = try stringifyAlloc(allocator, .{
            .method = "memory.consolidate.completed",
            .jobQid = task.lease.qid,
            .sessionQid = task.session_qid,
            .result = summary,
        });
        defer allocator.free(event_payload);
        _ = try self.publishEvent(streams.consolidate_completed, event_payload);
        result.claims += task.claims.items.len;
        result.earlier += task.earlier.items.len;
        result.updatesWritten += written;
        result.counts.add(task.counts);
    }

    /// Stores one update: `claim` replaces the earlier `fact`. The node is
    /// derived from both claims and evidenced by both of their messages, so
    /// forgetting either message tombstones it and the earlier fact reads as
    /// current again. Neither claim is rewritten; `options.facts` reads the
    /// update to mark the earlier one superseded. It is not searchable.
    fn writeUpdate(self: *Runtime, allocator: std.mem.Allocator, task: *const ConsolidateTask, claim: ConsolidateClaim, fact: ConsolidateClaim, update: AcceptedUpdate) !bool {
        // Either side may have been forgotten while the provider calls ran.
        for ([_][]const u8{ claim.assertion_qid, claim.message_qid, fact.assertion_qid, fact.message_qid }) |qid| {
            if (!try self.nodeIsLive(allocator, qid)) return false;
        }

        const key = try std.fmt.allocPrint(allocator, "{s}\x1f{s}", .{ claim.assertion_qid, fact.assertion_qid });
        defer allocator.free(key);
        const qid = try hashQid(allocator, "upd", key);
        defer allocator.free(qid);
        const text = try clampPropertyText(allocator, claim.text);
        defer allocator.free(text);
        const replaced_text = try clampPropertyText(allocator, fact.text);
        defer allocator.free(replaced_text);
        const quote = try clampPropertyText(allocator, claim.quote);
        defer allocator.free(quote);
        const old_value = try clampPropertyText(allocator, update.old_value);
        defer allocator.free(old_value);
        const new_value = try clampPropertyText(allocator, update.new_value);
        defer allocator.free(new_value);
        const props = try stringifyAlloc(allocator, .{
            .kind = "update",
            .qtype = "update",
            .text = text,
            .replacedText = replaced_text,
            .quote = quote,
            .oldValue = old_value,
            .newValue = new_value,
            .createdAt = claim.created_at,
            .replacedAt = fact.created_at,
            .assertionQid = claim.assertion_qid,
            .evidenceQid = claim.message_qid,
            .replacedQid = fact.assertion_qid,
            .replacedMessageQid = fact.message_qid,
            .sessionQid = task.session_qid,
            .tenantId = task.scope.tenant_id,
            .userId = task.scope.user_id,
            .agentId = task.scope.agent_id,
            .projectId = task.scope.project_id,
            .consolidatorProvider = self.options.extract_provider.name,
            .consolidatorModel = self.options.extract_provider.model,
            .promptVersion = fact_updates.prompt_version,
            .jobQid = task.lease.qid,
            .state = "current",
            .searchable = false,
            .deleted = false,
        });
        defer allocator.free(props);
        try self.store.putNode(.{ .qid = qid, .label = "Update", .properties_json = props });
        try self.putDeterministicEdge(allocator, qid, claim.assertion_qid, "DERIVED_FROM");
        try self.putDeterministicEdge(allocator, qid, fact.assertion_qid, "DERIVED_FROM");
        try self.putDeterministicEdge(allocator, qid, claim.message_qid, "EVIDENCED_BY");
        try self.putDeterministicEdge(allocator, qid, fact.message_qid, "EVIDENCED_BY");
        return true;
    }

    /// Queues a rebuild of the pattern nodes of `scope`: after extraction
    /// has read new messages, and after a forget removed some. Jobs for one
    /// scope are settled together, and a rebuild that finds nothing new
    /// makes no provider call. Nothing is queued on a store without
    /// embeddings, which cannot compare sentences.
    fn queuePatternJob(self: *Runtime, allocator: std.mem.Allocator, scope: Scope) !void {
        if (!self.store.capabilities().vector) return;
        const payload = try stringifyAlloc(allocator, .{
            .method = "memory.pattern.requested",
            .scope = scope.json(),
        });
        defer allocator.free(payload);
        const event = try self.publishEvent(streams.pattern_requested, payload);
        _ = try jobs.materializeStream(allocator, self.store, streams.pattern_requested, streams.workerKindForStream(streams.pattern_requested), .{
            .after_sequence = if (event.sequence > 0) event.sequence - 1 else 0,
            .limit = 1,
        });
        self.background_dirty = true;
    }

    /// Runs pending `pattern` jobs. Each rebuilds the pattern nodes of one
    /// scope from the sentences its people wrote (see `patterns.zig`):
    /// sentences not seen before are embedded and stored as a
    /// `SentenceIndex` node per message, alike sentences from different
    /// occasions are grouped, and every group with enough occasions gets a
    /// `Pattern` node. A node keeps the generalisations first proposed for
    /// it; later passes only ask about the occasions that are new and count
    /// again. Every node is evidenced by the messages of its occasions, so
    /// forgetting one of them removes it and queues a rebuild from what is
    /// left.
    fn patternProvider(self: *const Runtime) providers.ProviderEndpoint {
        if (self.options.pattern_provider.kind != .none) return self.options.pattern_provider;
        return self.options.extract_provider;
    }

    pub fn runPatternJobs(self: *Runtime, allocator: std.mem.Allocator, owner: []const u8, limit: usize) !PatternJobRunResult {
        if (!extractProviderUsable(self.patternProvider())) return error.ProviderUnavailable;
        var result = PatternJobRunResult{};
        if (try self.finishBackgroundWork(allocator)) |finished| switch (finished) {
            .patterns => |built| result = built,
            .extract, .consolidate, .summaries => {},
        };
        _ = try jobs.reclaimExpiredLeases(allocator, self.store, self.nowMs());
        // A pass that only indexed part of a backlog queues the next one;
        // the caller asked for the work to be done, so run those too.
        result.continued = true;
        while (result.continued) try self.runPatternPass(allocator, owner, limit, &result);
        return result;
    }

    /// Leases the pending pattern jobs and settles them. `result.continued`
    /// says whether the pass queued another.
    fn runPatternPass(self: *Runtime, allocator: std.mem.Allocator, owner: []const u8, limit: usize, result: *PatternJobRunResult) !void {
        result.continued = false;
        const leases = try jobs.leasePendingJobs(allocator, self.store, .{
            .worker_kind = streams.workerKindForStream(streams.pattern_requested),
            .owner = owner,
            .now_ms = self.nowMs(),
            .ttl_ms = pattern_lease_ttl_ms,
            .limit = limit,
        });
        defer jobs.freeLeaseResults(allocator, leases);
        result.leasedCount += leases.len;
        if (leases.len == 0) return;
        // Jobs a failed write did not settle go back to pending.
        errdefer for (leases) |lease| jobs.releaseLease(allocator, self.store, lease.qid) catch {};

        const tasks = try self.preparePatternTasks(allocator, leases);
        defer freePatternTasks(allocator, tasks);
        for (tasks) |*task| callPatternTask(task, allocator, self.options.io, self.patternProvider());
        try self.applyPatternTasks(allocator, tasks, result);
    }

    fn startBackgroundPatterns(self: *Runtime, allocator: std.mem.Allocator, io: std.Io) !bool {
        const leases = try jobs.leasePendingJobs(allocator, self.store, .{
            .worker_kind = streams.workerKindForStream(streams.pattern_requested),
            .owner = background_owner,
            .now_ms = self.nowMs(),
            .ttl_ms = pattern_lease_ttl_ms,
            .limit = pattern_lease_limit,
        });
        if (leases.len == 0) {
            jobs.freeLeaseResults(allocator, leases);
            return false;
        }
        errdefer {
            for (leases) |lease| jobs.releaseLease(allocator, self.store, lease.qid) catch {};
            jobs.freeLeaseResults(allocator, leases);
        }
        const tasks = try self.preparePatternTasks(allocator, leases);
        errdefer freePatternTasks(allocator, tasks);

        const batch = try allocator.create(BackgroundBatch);
        batch.* = .{
            .allocator = allocator,
            .leases = leases,
            .pattern_tasks = tasks,
            .remaining = .init(tasks.len),
            .notify = self.background_notify,
        };
        self.background = batch;
        const endpoint = self.patternProvider();
        for (tasks) |*task| {
            batch.group.concurrent(io, backgroundPatternCall, .{ batch, task, allocator, io, endpoint }) catch
                backgroundPatternCall(batch, task, allocator, io, endpoint);
        }
        return true;
    }

    /// One task per scope the leased jobs ask for, each loaded with the
    /// scope's messages, their sentence vectors and its stored pattern
    /// nodes. A task that cannot be prepared carries its failure and makes
    /// no provider call.
    fn preparePatternTasks(self: *Runtime, allocator: std.mem.Allocator, leases: []const jobs.LeaseResult) ![]PatternTask {
        var tasks = std.ArrayList(PatternTask).empty;
        errdefer {
            for (tasks.items) |*task| task.deinit();
            tasks.deinit(allocator);
        }
        var scratch_state = std.heap.ArenaAllocator.init(allocator);
        defer scratch_state.deinit();
        const scratch = scratch_state.allocator();
        for (leases) |lease| {
            var failure: ?anyerror = null;
            const scope = self.patternJobScope(scratch, lease) catch |err| blk: {
                if (err == error.OutOfMemory) return err;
                failure = err;
                break :blk Scope{};
            };
            const key = try scopeKey(scratch, scope);
            var existing: ?*PatternTask = null;
            if (failure == null) {
                for (tasks.items) |*task| {
                    if (task.failure == null and std.mem.eql(u8, task.scope_key, key)) existing = task;
                }
            }
            const task = existing orelse blk: {
                try tasks.append(allocator, PatternTask.init(allocator));
                const created = &tasks.items[tasks.items.len - 1];
                const arena = created.arena_state.allocator();
                created.scope_key = try arena.dupe(u8, key);
                created.scope = try dupeScope(arena, scope);
                created.failure = failure;
                break :blk created;
            };
            try task.leases.append(task.arena_state.allocator(), lease);
        }
        const owned = try tasks.toOwnedSlice(allocator);
        errdefer freePatternTasks(allocator, owned);
        for (owned) |*task| {
            if (task.failure != null) continue;
            self.preparePatternTask(task) catch |err| {
                if (err == error.OutOfMemory) return err;
                task.failure = err;
            };
        }
        return owned;
    }

    fn patternJobScope(self: *Runtime, arena: std.mem.Allocator, lease: jobs.LeaseResult) !Scope {
        const payload_json = try self.payloadJsonForLease(arena, lease);
        const payload = objectValue(try std.json.parseFromSliceLeaky(Value, arena, payload_json, .{ .allocate = .alloc_always })) orelse return error.InvalidRequest;
        return parseScope(&payload);
    }

    fn preparePatternTask(self: *Runtime, task: *PatternTask) !void {
        if (!self.store.capabilities().vector) {
            task.skipped = "no_embeddings";
            return;
        }
        const arena = task.arena_state.allocator();
        var messages = std.ArrayList(PatternMessage).empty;
        {
            var iterator = self.store.iterateNodes(arena, .{ .label = "Message", .where = try scopeWhere(arena, task.scope, &.{}) });
            defer iterator.deinit();
            while (try iterator.next()) |qid| {
                const source = (try self.loadExtractSource(arena, qid)) orelse continue;
                // Patterns are about what people say of their own lives.
                if (!isSpeakerRole(source.role)) continue;
                const day = fact_updates.dayOf(source.created_at);
                try messages.append(arena, .{
                    .qid = source.message_qid,
                    .entry_key = try std.fmt.allocPrint(arena, "{s}|{s}", .{ source.session_qid orelse source.message_qid, day orelse "" }),
                    .day = day,
                    .created_at = source.created_at,
                    .content = source.content,
                });
            }
        }
        std.mem.sort(PatternMessage, messages.items, {}, PatternMessage.before);
        task.messages = messages.items;

        var pending = std.ArrayList(usize).empty;
        for (task.messages, 0..) |*message, index| {
            if (!try self.loadSentenceIndex(arena, message)) try pending.append(arena, index);
        }
        if (pending.items.len > 0) {
            const now = pending.items[0..@min(pending.items.len, pattern_index_limit)];
            if (!try self.indexPatternMessages(task, now)) {
                task.skipped = "no_embeddings";
                return;
            }
            if (now.len < pending.items.len) {
                task.unindexed = pending.items.len - now.len;
                task.skipped = "indexing";
                return;
            }
        }

        var nodes = std.ArrayList(PatternNodeState).empty;
        var iterator = self.store.iterateNodes(arena, .{
            .label = "Pattern",
            .where = try scopeWhere(arena, task.scope, &.{.{ .name = "state", .value = "current" }}),
        });
        defer iterator.deinit();
        while (try iterator.next()) |qid| {
            const node = (try self.store.getNode(arena, qid)) orelse continue;
            const state = (try parsePatternNode(arena, node)) orelse continue;
            if (std.mem.eql(u8, state.scope_key, task.scope_key)) try nodes.append(arena, state);
        }
        task.nodes = nodes.items;
    }

    const PatternQuote = struct { quote: []const u8 = "", timestamp: ?[]const u8 = null };

    /// What one message of an occasion said that the pattern node rests on:
    /// its linked sentences, in order. Empty when the message or its
    /// sentence index is gone or no longer fits.
    fn patternEvidenceQuote(self: *Runtime, arena: std.mem.Allocator, message_qid: []const u8, member: PatternMember, slot: u32) !PatternQuote {
        const source = (try self.loadExtractSource(arena, message_qid)) orelse return .{};
        var quoted = PatternQuote{ .timestamp = source.created_at };
        const index_qid = try sentenceIndexQid(arena, message_qid);
        const node = (try self.store.getNode(arena, index_qid)) orelse return quoted;
        const index = (try parseSentenceIndex(arena, node)) orelse return quoted;
        if (index.content_bytes != source.content.len) return quoted;
        var quote = std.ArrayList(u8).empty;
        for (index.spans, 0..) |span, sentence| {
            if (span.start > span.end or span.end > source.content.len) return quoted;
            for (member.units) |unit| {
                if (unit[0] != slot or unit[1] != sentence) continue;
                if (quote.items.len > 0) try quote.append(arena, ' ');
                try quote.appendSlice(arena, source.content[span.start..span.end]);
                break;
            }
        }
        quoted.quote = quote.items;
        return quoted;
    }

    /// Fills `message` from its stored sentence index; false when it has
    /// none that fits its text.
    fn loadSentenceIndex(self: *Runtime, arena: std.mem.Allocator, message: *PatternMessage) !bool {
        const index_qid = try sentenceIndexQid(arena, message.qid);
        const node = (try self.store.getNode(arena, index_qid)) orelse return false;
        const index = (try parseSentenceIndex(arena, node)) orelse return false;
        // Vectors of another embedding model cannot be compared with this
        // one's, whatever their size: the message is indexed again.
        if (!sameEmbeddingModel(index.model, self.store.capabilities().embedding_model)) return false;
        if (index.content_bytes != message.content.len) return false;
        for (index.spans) |span| {
            if (span.start > span.end or span.end > message.content.len) return false;
        }
        message.spans = index.spans;
        message.vectors = index.vectors;
        return true;
    }

    /// Splits the listed messages into sentences, embeds them in batched
    /// requests and stores one `SentenceIndex` node per message: the byte
    /// range and vector of each sentence, never its text. The node is
    /// evidenced by the message, so forgetting the message removes it.
    /// Returns false when the store cannot embed.
    fn indexPatternMessages(self: *Runtime, task: *PatternTask, indexes: []const usize) !bool {
        const arena = task.arena_state.allocator();
        const scratch = task.arena_state.child_allocator;
        var texts = std.ArrayList([]const u8).empty;
        for (indexes) |index| {
            const message = &task.messages[index];
            message.spans = try patterns.splitSentences(arena, message.content);
            for (message.spans) |span| try texts.append(arena, message.content[span.start..span.end]);
        }
        self.store.prefetchEmbeddings(texts.items) catch {};
        defer self.store.clearPrefetchedEmbeddings();
        for (indexes) |index| {
            const message = &task.messages[index];
            var vectors: []i8 = &.{};
            var dims: usize = 0;
            for (message.spans, 0..) |span, position| {
                const vector = self.store.embedText(scratch, message.content[span.start..span.end]) catch |err| switch (err) {
                    error.Unsupported => return false,
                    error.OutOfMemory => return err,
                    else => {
                        task.unanswered = true;
                        return err;
                    },
                };
                defer scratch.free(vector);
                if (position == 0) {
                    dims = patterns.storedDims(vector.len);
                    vectors = try arena.alloc(i8, dims * message.spans.len);
                }
                if (dims == 0 or patterns.storedDims(vector.len) != dims) return error.EmbeddingDimensionMismatch;
                patterns.quantize(vector, vectors[position * dims ..][0..dims]);
            }
            message.vectors = vectors;
            try self.writeSentenceIndex(arena, message.*);
            task.counts.messagesIndexed += 1;
        }
        return true;
    }

    fn writeSentenceIndex(self: *Runtime, arena: std.mem.Allocator, message: PatternMessage) !void {
        const node = (try self.store.getNode(arena, message.qid)) orelse return;
        const props = objectValue(try std.json.parseFromSliceLeaky(Value, arena, node.properties_json, .{})) orelse return;
        if (boolField(&props, "deleted") orelse false) return;
        const spans = try arena.alloc([2]usize, message.spans.len);
        for (message.spans, spans) |span, *slot| slot.* = .{ span.start, span.end };
        const json = try stringifyAlloc(arena, .{
            .kind = "sentence_index",
            .evidenceQid = message.qid,
            .sessionQid = optionalStringField(&props, "sessionQid"),
            .createdAt = message.created_at,
            .contentBytes = message.content.len,
            .model = self.store.capabilities().embedding_model,
            .dims = message.dims(),
            .spans = spans,
            .vectors = try patterns.encodeVectors(arena, message.vectors),
            .tenantId = optionalStringField(&props, "tenantId"),
            .userId = optionalStringField(&props, "userId"),
            .agentId = optionalStringField(&props, "agentId"),
            .projectId = optionalStringField(&props, "projectId"),
            .state = "current",
            .searchable = false,
            .deleted = false,
        });
        const index_qid = try sentenceIndexQid(arena, message.qid);
        try self.store.putNode(.{ .qid = index_qid, .label = "SentenceIndex", .properties_json = json });
        try self.putDeterministicEdge(arena, index_qid, message.qid, "EVIDENCED_BY");
    }

    /// The storage half of a pattern batch: writes every node whose state
    /// changed, retires the nodes whose group is gone, and settles the jobs.
    /// A node is written with whatever its calls got, so a job that failed
    /// part way has less to do when it is tried again.
    fn applyPatternTasks(self: *Runtime, allocator: std.mem.Allocator, tasks: []PatternTask, result: *PatternJobRunResult) !void {
        for (tasks) |*task| {
            const arena = task.arena_state.allocator();
            result.calls += task.calls;
            var failure: ?anyerror = task.failure;
            if (task.failure == null and task.skipped == null) {
                for (task.works) |*work| {
                    if (work.gated) task.counts.gated += 1;
                    if (work.proposed) task.counts.proposed += 1;
                    task.counts.answered += work.answered;
                    task.counts.malformed += work.malformed;
                    if (work.failure) |err| failure = err;
                    if (work.dirty and work.kind != null and try self.writePatternNode(task, work)) {
                        task.counts.written += 1;
                        if (work.conclusion) |conclusion| {
                            if (conclusion.status == .regularity) task.counts.regularities += 1;
                        }
                    } else {
                        task.counts.unchanged += 1;
                    }
                }
                for (task.superseded) |qid| {
                    if (try self.supersedePattern(arena, qid)) task.counts.superseded += 1;
                }
            }

            const summary = .{
                .promptVersion = patterns.prompt_version,
                .provider = self.patternProvider().name,
                .model = self.patternProvider().model,
                .calls = task.calls,
                .skipped = task.skipped,
                .coalescedJobs = task.leases.items.len,
                .counts = task.counts,
            };
            const result_json = try stringifyAlloc(arena, summary);
            for (task.leases.items, 0..) |lease, position| {
                // One job carries a failure back to pending; the others
                // asked for the same rebuild and are done with it.
                if (failure != null and position == 0) {
                    const error_json = try stringifyAlloc(arena, .{ .@"error" = @errorName(failure.?), .calls = task.calls });
                    _ = jobs.failJob(allocator, self.store, lease.qid, error_json, self.nowMs()) catch {};
                    continue;
                }
                try jobs.completeJobWithResult(allocator, self.store, lease.qid, self.nowMs(), result_json);
            }
            if (failure) |err| {
                result.failedCount += 1;
                result.succeededCount += task.leases.items.len - 1;
                result.lastError = @errorName(err);
            } else {
                result.succeededCount += task.leases.items.len;
            }
            // The rest of a backlog is indexed by the next pass.
            if (failure == null and task.unindexed > 0) {
                try self.queuePatternJob(allocator, task.scope);
                result.continued = true;
            }
            const event_payload = try stringifyAlloc(arena, .{
                .method = "memory.pattern.completed",
                .jobQid = task.leases.items[0].qid,
                .scope = task.scope.json(),
                .failed = failure != null,
                .result = summary,
            });
            _ = try self.publishEvent(streams.pattern_completed, event_payload);
            result.scopes += 1;
            result.counts.add(task.counts);
        }
    }

    /// Stores one pattern node and its evidence edges. Returns false, and
    /// writes nothing, when a message it rests on was forgotten while the
    /// provider calls ran: the forget queued a rebuild.
    fn writePatternNode(self: *Runtime, task: *PatternTask, work: *const PatternWork) !bool {
        const arena = task.arena_state.allocator();
        for (work.occasions) |occasion| {
            for (occasion.messages) |message| {
                if (!try self.nodeIsLive(arena, task.messages[message].qid)) return false;
            }
        }
        // The node may have been forgotten while the calls were out. Its
        // tombstone stays; the forget queued the rebuild.
        if (work.node) |node| {
            if (!try self.nodeIsLive(arena, node.qid)) return false;
        }
        const kind = work.kind.?;
        const qid = if (work.node) |node| node.qid else try self.nextQid(arena, "pat");

        const WireMember = struct {
            key: []const u8,
            day: ?[]const u8,
            sig: []const u8,
            messages: []const []const u8,
            units: []const [2]u32,
        };
        const members = try arena.alloc(WireMember, work.occasions.len);
        for (work.occasions, members) |occasion, *member| {
            const message_qids = try arena.alloc([]const u8, occasion.messages.len);
            for (occasion.messages, message_qids) |message, *slot| slot.* = task.messages[message].qid;
            member.* = .{ .key = occasion.key, .day = occasion.day, .sig = occasion.sig, .messages = message_qids, .units = occasion.units };
        }
        const WireClaim = struct {
            claim: []const u8,
            when: []const u8,
            then: []const u8,
            table: patterns.Table,
            testable: bool,
            p: f64,
            gap: f64,
            holds: bool,
            answers: []const []const u8,
        };
        const claims = try arena.alloc(WireClaim, work.claims.len);
        for (work.claims, claims) |claim, *wire| {
            const codes = try arena.alloc([]const u8, claim.answers.len);
            for (claim.answers, codes) |answer, *code| code.* = if (answer) |known| known.code() else "";
            const counted = patternClaimResult(claim.answers);
            wire.* = .{
                .claim = claim.claim.claim,
                .when = claim.claim.when,
                .then = claim.claim.then,
                .table = counted.table,
                .testable = counted.testable,
                .p = counted.p,
                .gap = counted.gap,
                .holds = counted.holds(),
                .answers = codes,
            };
        }
        const informative = kind == .recurring and work.conclusion != null and work.conclusion.?.status.informative();
        const finding: []const u8 = if (work.conclusion) |conclusion| conclusion.finding else "";
        const analysis: []const u8 = if (kind != .recurring)
            @tagName(kind)
        else if (work.conclusion) |conclusion|
            @tagName(conclusion.status)
        else
            "pending";
        const first = task.messages[work.occasions[0].messages[0]];
        const last_occasion = work.occasions[work.occasions.len - 1];
        const last = task.messages[last_occasion.messages[last_occasion.messages.len - 1]];
        const props = try stringifyAlloc(arena, .{
            .kind = "pattern",
            .qtype = "pattern",
            .text = if (informative) try std.fmt.allocPrint(arena, "{s}: {s}", .{ work.about, finding }) else work.about,
            .about = work.about,
            .summary = work.summary,
            .finding = finding,
            .analysis = analysis,
            .informative = informative,
            .occasions = work.occasions.len,
            .gateKind = @tagName(kind),
            .gatedAt = work.gated_at,
            .claimsAt = work.claims_at,
            .claims = claims,
            .members = members,
            .firstSaid = first.created_at,
            .lastSaid = last.created_at,
            .evidenceQid = first.qid,
            .scopeKey = task.scope_key,
            .tenantId = task.scope.tenant_id,
            .userId = task.scope.user_id,
            .agentId = task.scope.agent_id,
            .projectId = task.scope.project_id,
            .consolidatorProvider = self.patternProvider().name,
            .consolidatorModel = self.patternProvider().model,
            .promptVersion = patterns.prompt_version,
            .jobQid = task.leases.items[0].qid,
            .state = "current",
            .searchable = false,
            .deleted = false,
        });
        try self.store.putNode(.{ .qid = qid, .label = "Pattern", .properties_json = props });
        for (members) |member| {
            for (member.messages) |message_qid| try self.putDeterministicEdge(arena, qid, message_qid, "EVIDENCED_BY");
        }
        return true;
    }

    /// Retires a pattern node whose group no longer stands on its own: it
    /// merged into another node's group, or came to cover most occasions.
    fn supersedePattern(self: *Runtime, arena: std.mem.Allocator, qid: []const u8) !bool {
        const node = (try self.store.getNode(arena, qid)) orelse return false;
        var value = try std.json.parseFromSliceLeaky(Value, arena, node.properties_json, .{ .allocate = .alloc_always });
        switch (value) {
            .object => |*object| {
                if (boolField(object, "deleted") orelse false) return false;
                try object.put(arena, "state", .{ .string = "superseded" });
            },
            else => return false,
        }
        try self.store.putNode(.{ .qid = qid, .label = "Pattern", .properties_json = try stringifyAlloc(arena, value) });
        return true;
    }

    /// Queues a rebuild of the summaries of `scope`: after extraction wrote
    /// claims from new messages, and after a forget removed some. Jobs for
    /// one scope are settled together, and a rebuild that finds every summary
    /// up to date makes no provider call. Nothing is queued on a store
    /// without embeddings, which cannot compare claims.
    fn queueSummaryJob(self: *Runtime, allocator: std.mem.Allocator, scope: Scope) !void {
        if (!self.store.capabilities().vector) return;
        const payload = try stringifyAlloc(allocator, .{
            .method = "memory.summary.requested",
            .scope = scope.json(),
        });
        defer allocator.free(payload);
        const event = try self.publishEvent(streams.summary_requested, payload);
        _ = try jobs.materializeStream(allocator, self.store, streams.summary_requested, streams.workerKindForStream(streams.summary_requested), .{
            .after_sequence = if (event.sequence > 0) event.sequence - 1 else 0,
            .limit = 1,
        });
        self.background_dirty = true;
    }

    /// Runs pending `summary` jobs. Each brings the `Summary` nodes of one
    /// scope up to date (see `summaries.zig`): one per session, saying what
    /// the conversation was about, and one per topic, a group of claims
    /// about the same thing with a title and what happened over time.
    /// Retrieval reads these first and descends from them to claims and raw
    /// messages. A summary is asked for only when what it rests on changed.
    /// Every node is evidenced by the messages it was built from, so
    /// forgetting one of them removes it and queues a rebuild from what is
    /// left.
    pub fn runSummaryJobs(self: *Runtime, allocator: std.mem.Allocator, owner: []const u8, limit: usize) !SummaryJobRunResult {
        if (!extractProviderUsable(self.options.extract_provider)) return error.ProviderUnavailable;
        var result = SummaryJobRunResult{};
        if (try self.finishBackgroundWork(allocator)) |finished| switch (finished) {
            .summaries => |built| result = built,
            .extract, .consolidate, .patterns => {},
        };
        _ = try jobs.reclaimExpiredLeases(allocator, self.store, self.nowMs());
        // A pass that only embedded part of a backlog of claims queues the
        // next one; the caller asked for the work to be done, so run those.
        result.continued = true;
        while (result.continued) try self.runSummaryPass(allocator, owner, limit, &result);
        return result;
    }

    /// Leases the pending summary jobs and settles them. `result.continued`
    /// says whether the pass queued another.
    fn runSummaryPass(self: *Runtime, allocator: std.mem.Allocator, owner: []const u8, limit: usize, result: *SummaryJobRunResult) !void {
        result.continued = false;
        const leases = try jobs.leasePendingJobs(allocator, self.store, .{
            .worker_kind = streams.workerKindForStream(streams.summary_requested),
            .owner = owner,
            .now_ms = self.nowMs(),
            .ttl_ms = summary_lease_ttl_ms,
            .limit = limit,
        });
        defer jobs.freeLeaseResults(allocator, leases);
        result.leasedCount += leases.len;
        if (leases.len == 0) return;
        // Jobs a failed write did not settle go back to pending.
        errdefer for (leases) |lease| jobs.releaseLease(allocator, self.store, lease.qid) catch {};

        const tasks = try self.prepareSummaryTasks(allocator, leases);
        defer freeSummaryTasks(allocator, tasks);
        for (tasks) |*task| callSummaryTask(task, self.options.io, self.options.extract_provider);
        try self.applySummaryTasks(allocator, tasks, result);
    }

    fn startBackgroundSummaries(self: *Runtime, allocator: std.mem.Allocator, io: std.Io) !bool {
        const leases = try jobs.leasePendingJobs(allocator, self.store, .{
            .worker_kind = streams.workerKindForStream(streams.summary_requested),
            .owner = background_owner,
            .now_ms = self.nowMs(),
            .ttl_ms = summary_lease_ttl_ms,
            .limit = summary_lease_limit,
        });
        if (leases.len == 0) {
            jobs.freeLeaseResults(allocator, leases);
            return false;
        }
        errdefer {
            for (leases) |lease| jobs.releaseLease(allocator, self.store, lease.qid) catch {};
            jobs.freeLeaseResults(allocator, leases);
        }
        const tasks = try self.prepareSummaryTasks(allocator, leases);
        errdefer freeSummaryTasks(allocator, tasks);

        const batch = try allocator.create(BackgroundBatch);
        batch.* = .{
            .allocator = allocator,
            .leases = leases,
            .summary_tasks = tasks,
            .remaining = .init(tasks.len),
            .notify = self.background_notify,
        };
        self.background = batch;
        const endpoint = self.options.extract_provider;
        for (tasks) |*task| {
            batch.group.concurrent(io, backgroundSummaryCall, .{ batch, task, io, endpoint }) catch
                backgroundSummaryCall(batch, task, io, endpoint);
        }
        return true;
    }

    /// One task per scope the leased jobs ask for, each loaded with what its
    /// stale summaries are asked from. A task that cannot be prepared
    /// carries its failure and makes no provider call.
    fn prepareSummaryTasks(self: *Runtime, allocator: std.mem.Allocator, leases: []const jobs.LeaseResult) ![]SummaryTask {
        var tasks = std.ArrayList(SummaryTask).empty;
        errdefer {
            for (tasks.items) |*task| task.deinit();
            tasks.deinit(allocator);
        }
        var scratch_state = std.heap.ArenaAllocator.init(allocator);
        defer scratch_state.deinit();
        const scratch = scratch_state.allocator();
        for (leases) |lease| {
            var failure: ?anyerror = null;
            const scope = self.patternJobScope(scratch, lease) catch |err| blk: {
                if (err == error.OutOfMemory) return err;
                failure = err;
                break :blk Scope{};
            };
            const key = try scopeKey(scratch, scope);
            var existing: ?*SummaryTask = null;
            if (failure == null) {
                for (tasks.items) |*task| {
                    if (task.failure == null and std.mem.eql(u8, task.scope_key, key)) existing = task;
                }
            }
            const task = existing orelse blk: {
                try tasks.append(allocator, SummaryTask.init(allocator));
                const created = &tasks.items[tasks.items.len - 1];
                const arena = created.arena_state.allocator();
                created.scope_key = try arena.dupe(u8, key);
                created.scope = try dupeScope(arena, scope);
                created.failure = failure;
                break :blk created;
            };
            try task.leases.append(task.arena_state.allocator(), lease);
        }
        const owned = try tasks.toOwnedSlice(allocator);
        errdefer freeSummaryTasks(allocator, owned);
        for (owned) |*task| {
            if (task.failure != null) continue;
            self.prepareSummaryTask(task) catch |err| {
                if (err == error.OutOfMemory) return err;
                task.failure = err;
            };
        }
        return owned;
    }

    fn prepareSummaryTask(self: *Runtime, task: *SummaryTask) !void {
        if (!self.store.capabilities().vector) {
            task.skipped = "no_embeddings";
            return;
        }
        const arena = task.arena_state.allocator();
        var stored = std.ArrayList(SummaryNodeState).empty;
        {
            var iterator = self.store.iterateNodes(arena, .{
                .label = "Summary",
                .where = try scopeWhere(arena, task.scope, &.{.{ .name = "state", .value = "current" }}),
            });
            defer iterator.deinit();
            while (try iterator.next()) |qid| {
                const node = (try self.store.getNode(arena, qid)) orelse continue;
                const state = (try parseSummaryNode(arena, node)) orelse continue;
                if (std.mem.eql(u8, state.scope_key, task.scope_key)) try stored.append(arena, state);
            }
        }
        var works = std.ArrayList(SummaryWork).empty;
        errdefer for (works.items) |*work| work.arena_state.deinit();
        var retired = std.ArrayList([]const u8).empty;
        try self.planSessionSummaries(task, stored.items, &works, &retired);
        try self.planTopicSummaries(task, stored.items, &works, &retired);
        task.works = works.items;
        task.retired = retired.items;
    }

    /// Lines up every session of the scope with its stored summary and asks
    /// for the ones that are missing or rest on other messages than the
    /// session has now.
    fn planSessionSummaries(
        self: *Runtime,
        task: *SummaryTask,
        stored: []SummaryNodeState,
        works: *std.ArrayList(SummaryWork),
        retired: *std.ArrayList([]const u8),
    ) !void {
        const arena = task.arena_state.allocator();
        var sessions: std.StringArrayHashMapUnmanaged(std.ArrayList(SummaryMessage)) = .empty;
        {
            var iterator = self.store.iterateNodes(arena, .{ .label = "Message", .where = try scopeWhere(arena, task.scope, &.{}) });
            defer iterator.deinit();
            while (try iterator.next()) |qid| {
                const source = (try self.loadExtractSource(arena, qid)) orelse continue;
                const session_qid = source.session_qid orelse continue;
                const slot = try sessions.getOrPut(arena, session_qid);
                if (!slot.found_existing) slot.value_ptr.* = .empty;
                try slot.value_ptr.append(arena, .{
                    .qid = source.message_qid,
                    .role = source.role,
                    .content = source.content,
                    .created_at = source.created_at,
                    .index = source.message_index orelse 0,
                    .session_id = source.session_id,
                });
            }
        }
        task.counts.sessions = sessions.count();
        for (sessions.keys(), sessions.values()) |session_qid, *list| {
            const messages = list.items;
            std.mem.sort(SummaryMessage, messages, {}, SummaryMessage.before);
            const qids = try arena.alloc([]const u8, messages.len);
            for (messages, qids) |message, *slot| slot.* = message.qid;
            const source_key = try summaries.memberKey(arena, qids);
            var node: ?*SummaryNodeState = null;
            for (stored) |*state| {
                if (state.kind != .session or state.taken) continue;
                if (std.mem.eql(u8, state.session_qid orelse "", session_qid)) node = state;
            }
            if (node) |found| {
                found.taken = true;
                if (std.mem.eql(u8, found.source_key, source_key)) {
                    task.counts.unchanged += 1;
                    continue;
                }
            }
            const lines = try arena.alloc(summaries.SessionLine, messages.len);
            for (messages, lines) |message, *line| {
                line.* = .{ .role = message.role, .content = message.content, .speaker = isSpeakerRole(message.role) };
            }
            try works.ensureUnusedCapacity(arena, 1);
            works.appendAssumeCapacity(.{
                .arena_state = std.heap.ArenaAllocator.init(task.arena_state.child_allocator),
                .kind = .session,
                .qid = if (node) |found| found.qid else null,
                .content = try summaries.buildSessionContent(arena, lines),
                .source_key = source_key,
                .sources = qids,
                .messages = qids,
                .session_qid = session_qid,
                .session_id = messages[0].session_id,
                .first_said = messages[0].created_at,
                .last_said = messages[messages.len - 1].created_at,
            });
            task.counts.sessionsAsked += 1;
        }
        // A session with no message left has nothing to summarise.
        for (stored) |state| {
            if (state.kind == .session and !state.taken) try retired.append(arena, state.qid);
        }
    }

    /// Groups the scope's claims and asks for a topic summary of every group
    /// that has none saying what it holds now. Claims without a stored
    /// vector are embedded first, `summary_index_limit` a pass; until all
    /// are, nothing is grouped.
    fn planTopicSummaries(
        self: *Runtime,
        task: *SummaryTask,
        stored: []SummaryNodeState,
        works: *std.ArrayList(SummaryWork),
        retired: *std.ArrayList([]const u8),
    ) !void {
        const arena = task.arena_state.allocator();
        const embedding_model = self.store.capabilities().embedding_model;
        var claims = std.ArrayList(SummaryClaim).empty;
        var pending = std.ArrayList(usize).empty;
        {
            var iterator = self.store.iterateNodes(arena, .{ .label = "Assertion", .where = try scopeWhere(arena, task.scope, &.{}) });
            defer iterator.deinit();
            while (try iterator.next()) |qid| {
                const node = (try self.store.getNode(arena, qid)) orelse continue;
                var claim = (try parseSummaryClaim(arena, node)) orelse continue;
                if (claim.vector.len > 0 and !sameEmbeddingModel(claim.vector_model, embedding_model)) claim.vector = &.{};
                if (claim.vector.len == 0) try pending.append(arena, claims.items.len);
                try claims.append(arena, claim);
            }
        }
        if (pending.items.len > 0) {
            const now = pending.items[0..@min(pending.items.len, summary_index_limit)];
            if (!try self.indexSummaryClaims(task, claims.items, now)) return;
            if (now.len < pending.items.len) {
                task.unindexed = pending.items.len - now.len;
                return;
            }
        }
        std.mem.sort(SummaryClaim, claims.items, {}, SummaryClaim.before);
        // With more claims than can be compared, the newest are kept. The
        // newest claim also says which vector size is current.
        const all = claims.items;
        if (all.len == 0) {
            for (stored) |state| {
                if (state.kind == .topic) try retired.append(arena, state.qid);
            }
            return;
        }
        const dims = all[all.len - 1].vector.len;
        var kept = std.ArrayList(SummaryClaim).empty;
        var first: usize = all.len;
        while (first > 0 and kept.items.len < summaries.max_claims) : (first -= 1) {
            if (all[first - 1].vector.len == dims) try kept.append(arena, all[first - 1]);
        }
        std.mem.reverse(SummaryClaim, kept.items);
        const compared = kept.items;
        task.counts.claims = compared.len;
        const vectors = try arena.alloc(i8, dims * compared.len);
        for (compared, 0..) |claim, index| @memcpy(vectors[index * dims ..][0..dims], claim.vector);

        const groups = try summaries.gather(arena, vectors, dims, compared.len, summaries.link_threshold);
        for (groups) |group| {
            if (group.len < summaries.min_topic_claims) continue;
            task.counts.groups += 1;
            const qids = try arena.alloc([]const u8, group.len);
            var message_qids = std.ArrayList([]const u8).empty;
            const lines = try arena.alloc(summaries.TopicLine, group.len);
            for (group, qids, lines) |member, *qid, *line| {
                const claim = compared[member];
                qid.* = claim.qid;
                line.* = .{ .said = fact_updates.dayOf(claim.created_at), .text = claim.text };
                const seen = for (message_qids.items) |message_qid| {
                    if (std.mem.eql(u8, message_qid, claim.message_qid)) break true;
                } else false;
                if (!seen) try message_qids.append(arena, claim.message_qid);
            }
            const source_key = try summaries.memberKey(arena, qids);
            const node = matchTopicNode(stored, qids);
            if (node) |found| {
                found.taken = true;
                if (std.mem.eql(u8, found.source_key, source_key)) {
                    task.counts.unchanged += 1;
                    continue;
                }
            }
            try works.ensureUnusedCapacity(arena, 1);
            works.appendAssumeCapacity(.{
                .arena_state = std.heap.ArenaAllocator.init(task.arena_state.child_allocator),
                .kind = .topic,
                .qid = if (node) |found| found.qid else null,
                .content = try summaries.buildTopicContent(arena, lines),
                .source_key = source_key,
                .sources = qids,
                .messages = message_qids.items,
                .first_said = compared[group[0]].created_at,
                .last_said = compared[group[group.len - 1]].created_at,
            });
            task.counts.topicsAsked += 1;
        }
        for (stored) |state| {
            if (state.kind == .topic and !state.taken) try retired.append(arena, state.qid);
        }
    }

    /// Embeds the listed claims in batched requests and stores each vector
    /// on its `Assertion` node, cut and scaled as sentence vectors are
    /// (`patterns.quantize`). The text embedded is the one the store indexes
    /// the claim by, so rewriting the node costs no second request. Returns
    /// false when the store cannot embed.
    fn indexSummaryClaims(self: *Runtime, task: *SummaryTask, claims: []SummaryClaim, indexes: []const usize) !bool {
        const arena = task.arena_state.allocator();
        const scratch = task.arena_state.child_allocator;
        const texts = try arena.alloc([]const u8, indexes.len);
        for (indexes, texts) |index, *text| text.* = claims[index].index_text;
        self.store.prefetchEmbeddings(texts) catch {};
        defer self.store.clearPrefetchedEmbeddings();
        const model = self.store.capabilities().embedding_model;
        for (indexes) |index| {
            const claim = &claims[index];
            const vector = self.store.embedText(scratch, claim.index_text) catch |err| switch (err) {
                error.Unsupported => {
                    task.skipped = "no_embeddings";
                    return false;
                },
                error.OutOfMemory => return err,
                else => {
                    task.unanswered = true;
                    return err;
                },
            };
            defer scratch.free(vector);
            const dims = patterns.storedDims(vector.len);
            if (dims == 0) return error.EmbeddingDimensionMismatch;
            const quantized = try arena.alloc(i8, dims);
            patterns.quantize(vector, quantized);
            claim.vector = quantized;

            var value = try std.json.parseFromSliceLeaky(Value, arena, claim.properties_json, .{ .allocate = .alloc_always });
            switch (value) {
                .object => |*object| {
                    try object.put(arena, "vector", .{ .string = try patterns.encodeVectors(arena, quantized) });
                    try object.put(arena, "vectorModel", if (model) |name| .{ .string = name } else .null);
                },
                else => continue,
            }
            try self.store.putNode(.{ .qid = claim.qid, .label = "Assertion", .properties_json = try stringifyAlloc(arena, value) });
            task.counts.claimsIndexed += 1;
        }
        return true;
    }

    /// The storage half of a summary batch: writes every summary the model
    /// answered for, retires the topic nodes whose group is gone, and
    /// settles the jobs. A summary whose call failed is asked for again by
    /// the job that carries the failure.
    fn applySummaryTasks(self: *Runtime, allocator: std.mem.Allocator, tasks: []SummaryTask, result: *SummaryJobRunResult) !void {
        for (tasks) |*task| {
            const arena = task.arena_state.allocator();
            result.calls += task.calls;
            var failure: ?anyerror = task.failure;
            if (task.failure == null and task.skipped == null) {
                // A summary is found by its vector, so none is stored
                // without one. When the embedding provider does not answer,
                // the jobs go back unspent and are run again later.
                self.embedSummaryTexts(task) catch |err| {
                    if (err == error.OutOfMemory) return err;
                    for (task.leases.items) |lease| try jobs.releaseLease(allocator, self.store, lease.qid);
                    result.failedCount += 1;
                    result.lastError = @errorName(err);
                    result.unembedded = true;
                    result.scopes += 1;
                    continue;
                };
                for (task.works) |*work| {
                    if (work.failure) |err| failure = err;
                    if (work.malformed) task.counts.malformed += 1;
                    if (work.named == null) continue;
                    if (!try self.writeSummaryNode(task, work)) continue;
                    const declined = work.named.?.title == null;
                    switch (work.kind) {
                        .session => task.counts.sessionsWritten += 1,
                        .topic => if (declined) {
                            task.counts.topicsDeclined += 1;
                        } else {
                            task.counts.topicsWritten += 1;
                        },
                    }
                }
                for (task.retired) |qid| {
                    if (try self.retireSummary(arena, qid)) task.counts.retired += 1;
                }
            }

            const summary = .{
                .promptVersion = summaries.prompt_version,
                .provider = self.options.extract_provider.name,
                .model = self.options.extract_provider.model,
                .calls = task.calls,
                .skipped = task.skipped,
                .coalescedJobs = task.leases.items.len,
                .counts = task.counts,
            };
            const result_json = try stringifyAlloc(arena, summary);
            for (task.leases.items, 0..) |lease, position| {
                // One job carries a failure back to pending; the others
                // asked for the same rebuild and are done with it.
                if (failure != null and position == 0) {
                    const error_json = try stringifyAlloc(arena, .{ .@"error" = @errorName(failure.?), .calls = task.calls });
                    _ = jobs.failJob(allocator, self.store, lease.qid, error_json, self.nowMs()) catch {};
                    continue;
                }
                try jobs.completeJobWithResult(allocator, self.store, lease.qid, self.nowMs(), result_json);
            }
            if (failure) |err| {
                result.failedCount += 1;
                result.succeededCount += task.leases.items.len - 1;
                result.lastError = @errorName(err);
            } else {
                result.succeededCount += task.leases.items.len;
            }
            // The rest of a backlog of claims is embedded by the next pass.
            if (failure == null and task.unindexed > 0) {
                try self.queueSummaryJob(allocator, task.scope);
                result.continued = true;
            }
            const event_payload = try stringifyAlloc(arena, .{
                .method = "memory.summary.completed",
                .jobQid = task.leases.items[0].qid,
                .scope = task.scope.json(),
                .failed = failure != null,
                .result = summary,
            });
            _ = try self.publishEvent(streams.summary_completed, event_payload);
            result.scopes += 1;
            result.counts.add(task.counts);
        }
    }

    /// Embeds what every answered summary of the task says, in one batched
    /// request, and keeps each vector on its work, cut and scaled as
    /// sentence vectors are (`patterns.quantize`).
    fn embedSummaryTexts(self: *Runtime, task: *SummaryTask) !void {
        const arena = task.arena_state.allocator();
        const scratch = task.arena_state.child_allocator;
        var texts = std.ArrayList([]const u8).empty;
        for (task.works) |*work| {
            const named = work.named orelse continue;
            if (named.title == null) continue;
            work.text = try summaries.textOf(arena, named);
            try texts.append(arena, work.text);
        }
        if (texts.items.len == 0) return;
        self.store.prefetchEmbeddings(texts.items) catch {};
        defer self.store.clearPrefetchedEmbeddings();
        for (task.works) |*work| {
            if (work.text.len == 0) continue;
            const embedded = try self.store.embedText(scratch, work.text);
            defer scratch.free(embedded);
            const quantized = try arena.alloc(i8, patterns.storedDims(embedded.len));
            patterns.quantize(embedded, quantized);
            work.vector = quantized;
        }
    }

    /// Stores one summary node and its edges. Returns false, and writes
    /// nothing, when something it rests on was forgotten while the provider
    /// calls ran: the forget queued a rebuild.
    fn writeSummaryNode(self: *Runtime, task: *SummaryTask, work: *const SummaryWork) !bool {
        const arena = task.arena_state.allocator();
        for (work.sources) |qid| {
            if (!try self.nodeIsLive(arena, qid)) return false;
        }
        for (work.messages) |qid| {
            if (!try self.nodeIsLive(arena, qid)) return false;
        }
        // The node may have been forgotten while the calls were out. Its
        // tombstone stays; the forget queued the rebuild.
        if (work.qid) |qid| {
            if (!try self.nodeIsLive(arena, qid)) return false;
        }
        const named = work.named.?;
        const declined = named.title == null;
        const vector: ?[]const u8 = if (work.vector.len > 0) try patterns.encodeVectors(arena, work.vector) else null;
        const qid = work.qid orelse try self.nextQid(arena, "sum");
        const props = try stringifyAlloc(arena, .{
            .kind = "summary",
            .qtype = "summary",
            .summaryType = @tagName(work.kind),
            .text = work.text,
            .title = named.title,
            .summary = named.summary,
            // The model found nothing to name; kept so it is not asked again.
            .declined = declined,
            .sourceKey = work.source_key,
            .sourceCount = work.sources.len,
            .members = if (work.kind == .topic) work.sources else null,
            .sessionQid = work.session_qid,
            .sessionId = work.session_id,
            .firstSaid = work.first_said,
            .lastSaid = work.last_said,
            .createdAt = work.first_said,
            .vector = vector,
            .vectorModel = self.store.capabilities().embedding_model,
            .dims = work.vector.len,
            .evidenceQid = work.messages[0],
            .scopeKey = task.scope_key,
            .tenantId = task.scope.tenant_id,
            .userId = task.scope.user_id,
            .agentId = task.scope.agent_id,
            .projectId = task.scope.project_id,
            .summarizerProvider = self.options.extract_provider.name,
            .summarizerModel = self.options.extract_provider.model,
            .promptVersion = summaries.prompt_version,
            .jobQid = task.leases.items[0].qid,
            .state = "current",
            .searchable = false,
            .deleted = false,
        });
        try self.store.putNode(.{ .qid = qid, .label = "Summary", .properties_json = props });
        switch (work.kind) {
            .session => try self.putDeterministicEdge(arena, qid, work.session_qid.?, "SUMMARIZES"),
            .topic => for (work.sources) |claim_qid| try self.putDeterministicEdge(arena, qid, claim_qid, "DERIVED_FROM"),
        }
        for (work.messages) |message_qid| try self.putDeterministicEdge(arena, qid, message_qid, "EVIDENCED_BY");
        return true;
    }

    /// Retires a summary node that nothing stands behind any more: a topic
    /// whose claims now belong to other groups, or a session left without
    /// messages.
    fn retireSummary(self: *Runtime, arena: std.mem.Allocator, qid: []const u8) !bool {
        const node = (try self.store.getNode(arena, qid)) orelse return false;
        var value = try std.json.parseFromSliceLeaky(Value, arena, node.properties_json, .{ .allocate = .alloc_always });
        switch (value) {
            .object => |*object| {
                if (boolField(object, "deleted") orelse false) return false;
                try object.put(arena, "state", .{ .string = "superseded" });
            },
            else => return false,
        }
        try self.store.putNode(.{ .qid = qid, .label = "Summary", .properties_json = try stringifyAlloc(arena, value) });
        return true;
    }

    /// The pattern node that owns `query`, if one does, as a retrieval
    /// item. The sentences people wrote are ranked against the question;
    /// when more than half of the `patterns.nearest` closest ones are the
    /// evidence of one node, the question is about that node's topic and the
    /// node goes to the reader with the raw evidence. A question about one
    /// thing a person said gathers sentences from everywhere and gets no
    /// node, so derived memory never takes room from a plain lookup. At most
    /// one node, and only if it fits `pattern_budget_percent` of the budget.
    fn collectPatternItems(
        self: *Runtime,
        allocator: std.mem.Allocator,
        query: []const u8,
        filter: ItemFilter,
        needs_value: ?Value,
        budget: usize,
    ) !PatternItems {
        var found = PatternItems{ .items = .{ .allocator = allocator } };
        errdefer found.items.deinit();
        if (needsCount(needs_value) > 0 and !needsIncludes(needs_value, "current_facts")) return found;
        if (!self.store.capabilities().vector) return found;

        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const where = try scopeWhere(arena, filter.scope, &.{.{ .name = "state", .value = "current" }});

        var candidates = std.ArrayList(PatternNodeState).empty;
        {
            var iterator = self.store.iterateNodes(arena, .{ .label = "Pattern", .where = where });
            defer iterator.deinit();
            while (try iterator.next()) |qid| {
                const node = (try self.store.getNode(arena, qid)) orelse continue;
                if (!try filter.scope.matchesNode(arena, node)) continue;
                const state = (try parsePatternNode(arena, node)) orelse continue;
                if (!state.informative or state.members.len == 0) continue;
                // A conclusion drawn from later occasions is not known yet
                // at the time the question asks about.
                if (filter.valid_at) |valid_at| {
                    if (state.last_said) |last_said| {
                        if (std.mem.order(u8, dateKey(last_said), dateKey(valid_at)) == .gt) continue;
                    }
                }
                try candidates.append(arena, state);
            }
        }
        found.trace.candidates = candidates.items.len;
        if (candidates.items.len == 0) return found;

        const query_vector = self.store.embedText(allocator, query) catch |err| {
            if (err == error.OutOfMemory) return err;
            return found;
        };
        defer allocator.free(query_vector);
        var query_stored: [patterns.dims]i8 = undefined;
        const dims = patterns.storedDims(query_vector.len);
        patterns.quantize(query_vector, query_stored[0..dims]);
        const query_norm = patterns.norm(query_stored[0..dims]);

        const embedding_model = self.store.capabilities().embedding_model;
        var top = patterns.Nearest{};
        var message_qids = std.ArrayList([]const u8).empty;
        {
            var node_state = std.heap.ArenaAllocator.init(allocator);
            defer node_state.deinit();
            var iterator = self.store.iterateNodes(arena, .{ .label = "SentenceIndex", .where = where });
            defer iterator.deinit();
            while (try iterator.next()) |qid| {
                _ = node_state.reset(.retain_capacity);
                const node_arena = node_state.allocator();
                const node = (try self.store.getNode(node_arena, qid)) orelse continue;
                if (!try filter.scope.matchesNode(node_arena, node)) continue;
                const index = (try parseSentenceIndex(node_arena, node)) orelse continue;
                if (index.dims != dims or index.spans.len == 0) continue;
                if (!sameEmbeddingModel(index.model, embedding_model)) continue;
                const message: u32 = @intCast(message_qids.items.len);
                try message_qids.append(arena, try arena.dupe(u8, index.message_qid));
                for (0..index.spans.len) |sentence| {
                    const vector = index.vectors[sentence * dims ..][0..dims];
                    top.offer(.{
                        .score = patterns.cosine(query_stored[0..dims], query_norm, vector, patterns.norm(vector)),
                        .message = message,
                        .sentence = @intCast(sentence),
                    });
                    found.trace.sentences += 1;
                }
            }
        }

        const counts = try arena.alloc(usize, candidates.items.len);
        for (candidates.items, counts) |candidate, *count| {
            count.* = 0;
            for (top.items()) |hit| {
                if (candidate.ownsSentence(message_qids.items[hit.message], hit.sentence)) count.* += 1;
            }
            found.trace.ownedMost = @max(found.trace.ownedMost, count.*);
        }
        const chosen_index = patterns.owner(counts) orelse return found;
        const chosen = candidates.items[chosen_index];
        const tokens = (chosen.text.len * 5 + 20) / 21 + 20;
        if (tokens > (budget *| pattern_budget_percent) / 100) return found;

        const item_qid = try allocator.dupe(u8, chosen.qid);
        errdefer allocator.free(item_qid);
        const text = try allocator.dupe(u8, chosen.text);
        errdefer allocator.free(text);
        const state = try allocator.dupe(u8, "current");
        errdefer allocator.free(state);
        const valid_from = try dupeOptional(allocator, chosen.first_said);
        errdefer if (valid_from) |value| allocator.free(value);
        var evidence = std.ArrayList(EvidenceResult).empty;
        errdefer {
            for (evidence.items) |entry| {
                allocator.free(entry.qid);
                allocator.free(entry.quote);
                if (entry.timestamp) |timestamp| allocator.free(timestamp);
            }
            evidence.deinit(allocator);
        }
        if (filter.include_evidence) {
            for (chosen.members) |member| {
                for (member.messages, 0..) |message_qid, slot| {
                    const quoted = try self.patternEvidenceQuote(arena, message_qid, member, @intCast(slot));
                    const evidence_qid = try allocator.dupe(u8, message_qid);
                    errdefer allocator.free(evidence_qid);
                    const quote = try allocator.dupe(u8, quoted.quote);
                    errdefer allocator.free(quote);
                    const timestamp = try dupeOptional(allocator, quoted.timestamp);
                    errdefer if (timestamp) |value| allocator.free(value);
                    try evidence.append(allocator, .{ .qid = evidence_qid, .quote = quote, .timestamp = timestamp });
                }
            }
        }
        const evidence_slice = try evidence.toOwnedSlice(allocator);
        errdefer freeEvidence(allocator, evidence_slice);
        try found.items.items.append(allocator, .{
            .qid = item_qid,
            .type = "pattern",
            .text = text,
            .score = @as(f32, @floatFromInt(counts[chosen_index])) / @as(f32, @floatFromInt(patterns.nearest)),
            .state = state,
            .validFrom = valid_from,
            .evidence = evidence_slice,
            .includeDebug = filter.include_debug,
        });
        found.trace.kept = 1;
        found.trace.tokens = tokens;
        return found;
    }

    fn nodeIsLive(self: *Runtime, allocator: std.mem.Allocator, qid: []const u8) !bool {
        const node = (try self.store.getNode(allocator, qid)) orelse return false;
        defer self.store.freeNode(allocator, node);
        return !try propertyBool(allocator, node.properties_json, "deleted");
    }
};

/// One message of an extract job's source episode. Strings are owned.
const ExtractSource = struct {
    message_qid: []u8,
    role: []u8 = &.{},
    /// Full message text.
    content: []u8 = &.{},
    created_at: ?[]u8 = null,
    session_id: ?[]u8 = null,
    session_qid: ?[]u8 = null,
    message_index: ?i64 = null,
    /// End offset of each chunk in `content`; empty for unchunked messages.
    chunk_ends: []usize = &.{},

    fn deinit(self: ExtractSource, allocator: std.mem.Allocator) void {
        allocator.free(self.message_qid);
        allocator.free(self.role);
        allocator.free(self.content);
        if (self.created_at) |value| allocator.free(value);
        if (self.session_id) |value| allocator.free(value);
        if (self.session_qid) |value| allocator.free(value);
        allocator.free(self.chunk_ends);
    }
};

/// One leased extract job through prepare, call, ground and write.
const ExtractTask = struct {
    lease: jobs.LeaseResult,
    /// The job payload; `scope`, `session_qid` and `turn_qid` borrow from it.
    payload: ?std.json.Parsed(Value) = null,
    scope: Scope = .{},
    session_qid: ?[]const u8 = null,
    turn_qid: ?[]const u8 = null,
    sources: std.ArrayList(ExtractSource) = .empty,
    user_content: ?[]u8 = null,
    parsed: ?std.json.Parsed(Value) = null,
    grounding: ?fact_extraction.Grounding = null,
    /// The second reading: the reply about the messages the first reading
    /// drew no claim from, and its claims, indexed like `grounding`'s.
    recall_parsed: ?std.json.Parsed(Value) = null,
    recall_grounding: ?fact_extraction.Grounding = null,
    /// Messages read a second time.
    recall_messages: usize = 0,
    calls: usize = 0,
    /// Calls made again because a reply was not valid JSON.
    json_retries: usize = 0,
    failure: ?anyerror = null,
    /// The failure came from the provider call itself: no reply to judge.
    unanswered: bool = false,
    /// Qids of the assertions written, for the consolidation job.
    user_assertions: std.ArrayList([]u8) = .empty,

    fn sourceMessages(self: *const ExtractTask, allocator: std.mem.Allocator) ![]fact_extraction.SourceMessage {
        const messages = try allocator.alloc(fact_extraction.SourceMessage, self.sources.items.len);
        for (self.sources.items, messages) |source, *message| {
            message.* = .{ .role = source.role, .content = source.content, .created_at = source.created_at };
        }
        return messages;
    }

    fn deinit(self: *ExtractTask, allocator: std.mem.Allocator) void {
        if (self.recall_grounding) |grounding| grounding.deinit(allocator);
        if (self.recall_parsed) |parsed| parsed.deinit();
        if (self.grounding) |grounding| grounding.deinit(allocator);
        if (self.parsed) |parsed| parsed.deinit();
        if (self.user_content) |content| allocator.free(content);
        for (self.sources.items) |source| source.deinit(allocator);
        self.sources.deinit(allocator);
        for (self.user_assertions.items) |qid| allocator.free(qid);
        self.user_assertions.deinit(allocator);
        if (self.payload) |payload| payload.deinit();
    }
};

/// A claim in a `consolidate` job: one of the conversation's new claims, or
/// an earlier claim it may replace. Strings are owned.
const ConsolidateClaim = struct {
    assertion_qid: []u8 = &.{},
    message_qid: []u8 = &.{},
    text: []u8 = &.{},
    /// The claim as it is indexed: in the words it was said in.
    search_text: []u8 = &.{},
    /// The span of the message the claim was drawn from.
    quote: []u8 = &.{},
    /// Who said it: the role of the source message.
    role: []u8 = &.{},
    created_at: ?[]u8 = null,
    session_qid: ?[]u8 = null,

    fn deinit(self: ConsolidateClaim, allocator: std.mem.Allocator) void {
        allocator.free(self.assertion_qid);
        allocator.free(self.message_qid);
        allocator.free(self.text);
        allocator.free(self.search_text);
        allocator.free(self.quote);
        allocator.free(self.role);
        if (self.created_at) |value| allocator.free(value);
        if (self.session_qid) |value| allocator.free(value);
    }
};

/// A pair that passed every check, with the values the verify call named.
const AcceptedUpdate = struct {
    claim_index: usize,
    earlier_index: usize,
    old_value: []u8,
    new_value: []u8,
};

/// One `consolidate` job: a conversation's new claims and the earlier
/// claims they may replace.
const ConsolidateTask = struct {
    lease: jobs.LeaseResult,
    /// The job payload; `scope` and `session_qid` borrow from it.
    payload: ?std.json.Parsed(Value) = null,
    scope: Scope = .{},
    session_qid: ?[]const u8 = null,
    claims: std.ArrayList(ConsolidateClaim) = .empty,
    earlier: std.ArrayList(ConsolidateClaim) = .empty,
    user_content: ?[]u8 = null,
    accepted: std.ArrayList(AcceptedUpdate) = .empty,
    counts: fact_updates.Counts = .{},
    calls: usize = 0,
    failure: ?anyerror = null,
    /// The failure came from the provider call itself: no reply to judge.
    unanswered: bool = false,

    fn hasEarlier(self: *const ConsolidateTask, qid: []const u8) bool {
        for (self.earlier.items) |fact| {
            if (std.mem.eql(u8, fact.assertion_qid, qid)) return true;
        }
        return false;
    }

    fn wireClaims(self: *const ConsolidateTask, allocator: std.mem.Allocator) ![]fact_updates.NewClaim {
        const wire = try allocator.alloc(fact_updates.NewClaim, self.claims.items.len);
        for (self.claims.items, wire) |claim, *slot| slot.* = .{ .text = claim.text, .date = claim.created_at };
        return wire;
    }

    fn wireEarlier(self: *const ConsolidateTask, allocator: std.mem.Allocator) ![]fact_updates.Earlier {
        const wire = try allocator.alloc(fact_updates.Earlier, self.earlier.items.len);
        for (self.earlier.items, wire) |fact, *slot| slot.* = .{ .text = fact.text, .date = fact.created_at };
        return wire;
    }

    fn deinit(self: *ConsolidateTask, allocator: std.mem.Allocator) void {
        if (self.user_content) |content| allocator.free(content);
        for (self.accepted.items) |update| {
            allocator.free(update.old_value);
            allocator.free(update.new_value);
        }
        self.accepted.deinit(allocator);
        for (self.claims.items) |claim| claim.deinit(allocator);
        self.claims.deinit(allocator);
        for (self.earlier.items) |fact| fact.deinit(allocator);
        self.earlier.deinit(allocator);
        if (self.payload) |payload| payload.deinit();
    }
};

/// One message a person wrote, in a pattern job's scope, with its sentence
/// index. Everything is owned by the task's arena.
const PatternMessage = struct {
    qid: []const u8,
    /// The occasion the message belongs to: its conversation on one day.
    entry_key: []const u8,
    day: ?[]const u8,
    created_at: ?[]const u8,
    content: []const u8,
    spans: []const patterns.Span = &.{},
    /// One quantised vector per span, end to end.
    vectors: []const i8 = &.{},

    fn dims(self: PatternMessage) usize {
        return if (self.spans.len == 0) 0 else self.vectors.len / self.spans.len;
    }

    /// Oldest first; undated messages lead, in the order they were stored.
    fn before(_: void, left: PatternMessage, right: PatternMessage) bool {
        const order = std.mem.order(u8, left.created_at orelse "", right.created_at orelse "");
        if (order != .eq) return order == .lt;
        if (left.qid.len != right.qid.len) return left.qid.len < right.qid.len;
        return std.mem.order(u8, left.qid, right.qid) == .lt;
    }
};

/// A stored `SentenceIndex` node.
const SentenceIndex = struct {
    message_qid: []const u8,
    /// The embedding model the vectors came from, where the store names one.
    model: ?[]const u8,
    content_bytes: usize,
    dims: usize,
    spans: []patterns.Span,
    vectors: []const i8,
};

fn sameEmbeddingModel(left: ?[]const u8, right: ?[]const u8) bool {
    if (left == null or right == null) return left == null and right == null;
    return std.mem.eql(u8, left.?, right.?);
}

/// Reads a live sentence index; null for anything else or a node that does
/// not add up.
fn parseSentenceIndex(arena: std.mem.Allocator, node: storage.Node) !?SentenceIndex {
    if (!std.mem.eql(u8, node.label, "SentenceIndex")) return null;
    const value = std.json.parseFromSliceLeaky(Value, arena, node.properties_json, .{}) catch |err| {
        if (err == error.OutOfMemory) return err;
        return null;
    };
    const props = objectValue(value) orelse return null;
    if (boolField(&props, "deleted") orelse false) return null;
    const message_qid = stringField(&props, "evidenceQid") orelse return null;
    const dims = integerField(&props, "dims") orelse return null;
    const content_bytes = integerField(&props, "contentBytes") orelse return null;
    const wire_spans = arrayValue(props.get("spans")) orelse return null;
    if (dims < 0 or dims > patterns.dims or content_bytes < 0) return null;
    const spans = try arena.alloc(patterns.Span, wire_spans.items.len);
    for (wire_spans.items, spans) |wire, *span| {
        const pair = arrayValue(wire) orelse return null;
        if (pair.items.len != 2 or pair.items[0] != .integer or pair.items[1] != .integer) return null;
        if (pair.items[0].integer < 0 or pair.items[1].integer < pair.items[0].integer) return null;
        span.* = .{ .start = @intCast(pair.items[0].integer), .end = @intCast(pair.items[1].integer) };
    }
    const vectors = patterns.decodeVectors(arena, stringField(&props, "vectors") orelse "") catch |err| {
        if (err == error.OutOfMemory) return err;
        return null;
    };
    if (vectors.len != spans.len * @as(usize, @intCast(dims))) return null;
    return .{
        .message_qid = message_qid,
        .model = optionalStringField(&props, "model"),
        .content_bytes = @intCast(content_bytes),
        .dims = @intCast(dims),
        .spans = spans,
        .vectors = vectors,
    };
}

fn sentenceIndexQid(allocator: std.mem.Allocator, message_qid: []const u8) ![]u8 {
    const suffix = if (std.mem.startsWith(u8, message_qid, "q_msg_")) message_qid["q_msg_".len..] else message_qid;
    return std.fmt.allocPrint(allocator, "q_sidx_{s}", .{suffix});
}

/// One occasion of a stored pattern node.
const PatternMember = struct {
    key: []const u8,
    /// Changes when the text of the occasion or its linked sentences do.
    sig: []const u8,
    messages: []const []const u8 = &.{},
    /// Linked sentences: position in `messages`, sentence within it.
    units: []const [2]u32 = &.{},
};

const PatternClaimState = struct {
    claim: patterns.Claim,
    /// One per member, in member order; null where no answer is stored.
    answers: []const ?patterns.Answer,
};

/// A stored `Pattern` node as a job or a retrieval reads it.
const PatternNodeState = struct {
    qid: []const u8,
    scope_key: []const u8 = "",
    text: []const u8 = "",
    about: []const u8 = "",
    summary: []const u8 = "",
    /// Whether the node has a finding a reader should see.
    informative: bool = false,
    kind: ?patterns.Kind = null,
    gated_at: usize = 0,
    claims_at: ?usize = null,
    claims: []const PatternClaimState = &.{},
    members: []const PatternMember = &.{},
    first_said: ?[]const u8 = null,
    last_said: ?[]const u8 = null,
    /// Matched to a group of the current pass.
    taken: bool = false,

    fn ownsSentence(self: PatternNodeState, message_qid: []const u8, sentence: u32) bool {
        for (self.members) |member| {
            for (member.units) |unit| {
                if (unit[1] != sentence or unit[0] >= member.messages.len) continue;
                if (std.mem.eql(u8, member.messages[unit[0]], message_qid)) return true;
            }
        }
        return false;
    }
};

/// Reads a live, current pattern node; null for anything else.
fn parsePatternNode(arena: std.mem.Allocator, node: storage.Node) !?PatternNodeState {
    if (!std.mem.eql(u8, node.label, "Pattern")) return null;
    const value = std.json.parseFromSliceLeaky(Value, arena, node.properties_json, .{}) catch |err| {
        if (err == error.OutOfMemory) return err;
        return null;
    };
    const props = objectValue(value) orelse return null;
    if (boolField(&props, "deleted") orelse false) return null;
    if (!std.mem.eql(u8, stringField(&props, "state") orelse "", "current")) return null;

    var state = PatternNodeState{ .qid = node.qid };
    state.scope_key = stringField(&props, "scopeKey") orelse "";
    state.text = stringField(&props, "text") orelse "";
    state.about = stringField(&props, "about") orelse "";
    state.summary = stringField(&props, "summary") orelse "";
    state.informative = boolField(&props, "informative") orelse false;
    state.kind = if (stringField(&props, "gateKind")) |kind| patterns.Kind.parse(kind) else null;
    state.gated_at = @intCast(@max(integerField(&props, "gatedAt") orelse 0, 0));
    state.claims_at = if (integerField(&props, "claimsAt")) |count| @intCast(@max(count, 0)) else null;
    state.first_said = optionalStringField(&props, "firstSaid");
    state.last_said = optionalStringField(&props, "lastSaid");

    var members = std.ArrayList(PatternMember).empty;
    if (arrayValue(props.get("members"))) |wire_members| {
        for (wire_members.items) |wire| {
            const fields = objectValue(wire) orelse return null;
            var member = PatternMember{
                .key = stringField(&fields, "key") orelse return null,
                .sig = stringField(&fields, "sig") orelse "",
            };
            var messages = std.ArrayList([]const u8).empty;
            if (arrayValue(fields.get("messages"))) |wire_messages| {
                for (wire_messages.items) |message| try messages.append(arena, stringValue(message) orelse return null);
            }
            var units = std.ArrayList([2]u32).empty;
            if (arrayValue(fields.get("units"))) |wire_units| {
                for (wire_units.items) |unit| {
                    const pair = arrayValue(unit) orelse return null;
                    if (pair.items.len != 2 or pair.items[0] != .integer or pair.items[1] != .integer) return null;
                    if (pair.items[0].integer < 0 or pair.items[1].integer < 0) return null;
                    if (pair.items[0].integer > std.math.maxInt(u32) or pair.items[1].integer > std.math.maxInt(u32)) return null;
                    try units.append(arena, .{ @intCast(pair.items[0].integer), @intCast(pair.items[1].integer) });
                }
            }
            member.messages = messages.items;
            member.units = units.items;
            try members.append(arena, member);
        }
    }
    state.members = members.items;

    var claims = std.ArrayList(PatternClaimState).empty;
    if (arrayValue(props.get("claims"))) |wire_claims| {
        for (wire_claims.items) |wire| {
            const fields = objectValue(wire) orelse return null;
            const answers = try arena.alloc(?patterns.Answer, state.members.len);
            @memset(answers, null);
            if (arrayValue(fields.get("answers"))) |codes| {
                for (codes.items, 0..) |code, position| {
                    if (position >= answers.len) break;
                    answers[position] = patterns.Answer.fromCode(stringValue(code) orelse "");
                }
            }
            try claims.append(arena, .{
                .claim = .{
                    .claim = stringField(&fields, "claim") orelse return null,
                    .when = stringField(&fields, "when") orelse return null,
                    .then = stringField(&fields, "then") orelse return null,
                },
                .answers = answers,
            });
        }
    }
    state.claims = claims.items;
    return state;
}

/// One occasion of a group in the pass under way.
const PatternOccasion = struct {
    key: []const u8,
    day: ?[]const u8,
    sig: []const u8,
    member: patterns.Member,
    /// The occasion's messages, as positions in the task's messages.
    messages: []const u32,
    /// Linked sentences: position in `messages`, sentence within it.
    units: []const [2]u32,
};

const PatternClaimWork = struct {
    claim: patterns.Claim,
    /// One per occasion; null until a counting call answers.
    answers: []?patterns.Answer,
};

fn patternClaimResult(answers: []const ?patterns.Answer) patterns.Result {
    var table = patterns.Table{ 0, 0, 0, 0 };
    for (answers) |answer| switch (answer orelse .unknown) {
        .unknown => {},
        .yes_yes => table[0] += 1,
        .yes_no => table[1] += 1,
        .no_yes => table[2] += 1,
        .no_no => table[3] += 1,
    };
    return patterns.evaluate(table);
}

/// One group with enough occasions for a node: what is stored about it and
/// what this pass adds. Its provider calls run on a thread of their own and
/// allocate from `arena_state`.
const PatternWork = struct {
    arena_state: std.heap.ArenaAllocator,
    node: ?*PatternNodeState,
    occasions: []const PatternOccasion = &.{},
    /// The group's linked sentences, for the model that names its kind.
    sentences: []const []const u8 = &.{},
    about: []const u8 = "",
    summary: []const u8 = "",
    kind: ?patterns.Kind = null,
    gated_at: usize = 0,
    claims_at: ?usize = null,
    claims: []PatternClaimWork = &.{},
    conclusion: ?patterns.Conclusion = null,
    /// The stored node no longer says what this work holds.
    dirty: bool = false,
    gated: bool = false,
    proposed: bool = false,
    calls: usize = 0,
    /// Calls the provider replied to, and occasion answers they gave.
    replies: usize = 0,
    answered: usize = 0,
    malformed: usize = 0,
    failure: ?anyerror = null,
};

/// One pass over the pattern nodes of one scope, through prepare, call and
/// write. `leases` are the jobs that asked for it.
const PatternTask = struct {
    arena_state: std.heap.ArenaAllocator,
    leases: std.ArrayList(jobs.LeaseResult) = .empty,
    scope_key: []const u8 = "",
    scope: Scope = .{},
    messages: []PatternMessage = &.{},
    nodes: []PatternNodeState = &.{},
    works: []PatternWork = &.{},
    /// Qids of stored nodes whose group is gone.
    superseded: []const []const u8 = &.{},
    counts: PatternCounts = .{},
    calls: usize = 0,
    failure: ?anyerror = null,
    /// No provider call of the task got a reply.
    unanswered: bool = false,
    /// Why the pass did nothing, when it could not run at all.
    skipped: ?[]const u8 = null,
    /// Messages still waiting for a sentence index after this pass.
    unindexed: usize = 0,

    fn init(allocator: std.mem.Allocator) PatternTask {
        return .{ .arena_state = std.heap.ArenaAllocator.init(allocator) };
    }

    fn deinit(self: *PatternTask) void {
        for (self.works) |*work| work.arena_state.deinit();
        self.arena_state.deinit();
    }
};

fn freePatternTasks(allocator: std.mem.Allocator, tasks: []PatternTask) void {
    for (tasks) |*task| task.deinit();
    allocator.free(tasks);
}

/// `memory.retrieve`: the pattern item of one retrieval, if any.
const PatternItems = struct {
    items: OwnedItems,
    trace: PatternsTrace = .{},
};

const PatternsTrace = struct {
    /// Pattern nodes with a finding, in scope.
    candidates: usize = 0,
    /// Sentences ranked against the question.
    sentences: usize = 0,
    /// Most of the nearest sentences any one node holds.
    ownedMost: usize = 0,
    kept: usize = 0,
    tokens: usize = 0,
};

/// The scope a node was stored under; strings are owned by `arena`.
fn scopeOfNode(arena: std.mem.Allocator, node: storage.Node) !Scope {
    const value = std.json.parseFromSliceLeaky(Value, arena, node.properties_json, .{ .allocate = .alloc_always }) catch |err| {
        if (err == error.OutOfMemory) return err;
        return .{};
    };
    const props = objectValue(value) orelse return .{};
    return .{
        .tenant_id = optionalStringField(&props, "tenantId"),
        .user_id = optionalStringField(&props, "userId"),
        .agent_id = optionalStringField(&props, "agentId"),
        .project_id = optionalStringField(&props, "projectId"),
    };
}

fn scopeKey(allocator: std.mem.Allocator, scope: Scope) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}\x1f{s}\x1f{s}\x1f{s}", .{
        scope.tenant_id orelse "", scope.user_id orelse "", scope.agent_id orelse "", scope.project_id orelse "",
    });
}

fn dupeScope(allocator: std.mem.Allocator, scope: Scope) !Scope {
    return .{
        .tenant_id = try dupeOptional(allocator, scope.tenant_id),
        .user_id = try dupeOptional(allocator, scope.user_id),
        .agent_id = try dupeOptional(allocator, scope.agent_id),
        .project_id = try dupeOptional(allocator, scope.project_id),
    };
}

/// Property matches that select the nodes of `scope`, after `leading`.
fn scopeWhere(arena: std.mem.Allocator, scope: Scope, leading: []const storage.PropertyMatch) ![]storage.PropertyMatch {
    var where = std.ArrayList(storage.PropertyMatch).empty;
    try where.appendSlice(arena, leading);
    if (scope.tenant_id) |value| try where.append(arena, .{ .name = "tenantId", .value = value });
    if (scope.user_id) |value| try where.append(arena, .{ .name = "userId", .value = value });
    if (scope.agent_id) |value| try where.append(arena, .{ .name = "agentId", .value = value });
    if (scope.project_id) |value| try where.append(arena, .{ .name = "projectId", .value = value });
    return where.items;
}

const PatternEntry = struct {
    key: []const u8,
    day: ?[]const u8,
    /// Positions in the task's messages, and in the pass's sentences.
    messages: std.ArrayList(u32) = .empty,
    sentences: std.ArrayList(u32) = .empty,
};

/// Where a sentence of the pass sits: its message, its place among that
/// message's sentences, and its place among its occasion's.
const PatternSentenceRef = struct { message: u32, index: u32, at: u32 };

const SummaryKind = enum { session, topic };

/// A stored, current summary node: what a pass needs to tell whether it
/// still says what its sources say.
const SummaryNodeState = struct {
    qid: []const u8,
    kind: SummaryKind,
    scope_key: []const u8 = "",
    source_key: []const u8 = "",
    session_qid: ?[]const u8 = null,
    /// A topic's claims.
    members: []const []const u8 = &.{},
    /// A group or session of this pass has claimed the node.
    taken: bool = false,
};

/// Reads a live, current summary node; null for anything else.
fn parseSummaryNode(arena: std.mem.Allocator, node: storage.Node) !?SummaryNodeState {
    if (!std.mem.eql(u8, node.label, "Summary")) return null;
    const value = std.json.parseFromSliceLeaky(Value, arena, node.properties_json, .{}) catch |err| {
        if (err == error.OutOfMemory) return err;
        return null;
    };
    const props = objectValue(value) orelse return null;
    if (boolField(&props, "deleted") orelse false) return null;
    if (!std.mem.eql(u8, stringField(&props, "state") orelse "", "current")) return null;
    const kind = std.meta.stringToEnum(SummaryKind, stringField(&props, "summaryType") orelse "") orelse return null;
    var members = std.ArrayList([]const u8).empty;
    if (arrayValue(props.get("members"))) |wire| {
        for (wire.items) |member| try members.append(arena, stringValue(member) orelse return null);
    }
    return .{
        .qid = node.qid,
        .kind = kind,
        .scope_key = stringField(&props, "scopeKey") orelse "",
        .source_key = stringField(&props, "sourceKey") orelse "",
        .session_qid = optionalStringField(&props, "sessionQid"),
        .members = members.items,
    };
}

/// The stored topic node most of whose claims are in the group, if any is
/// still free: at least half of them, so a node follows its group as the
/// group grows or absorbs another.
fn matchTopicNode(nodes: []SummaryNodeState, group: []const []const u8) ?*SummaryNodeState {
    var best: ?*SummaryNodeState = null;
    var best_common: usize = 0;
    for (nodes) |*node| {
        if (node.kind != .topic or node.taken or node.members.len == 0) continue;
        var common: usize = 0;
        for (node.members) |member| {
            for (group) |qid| {
                if (std.mem.eql(u8, member, qid)) {
                    common += 1;
                    break;
                }
            }
        }
        if (common * 2 < node.members.len or common <= best_common) continue;
        best = node;
        best_common = common;
    }
    return best;
}

/// One message of a session, for its summary.
const SummaryMessage = struct {
    qid: []const u8,
    role: []const u8,
    content: []const u8,
    created_at: ?[]const u8,
    index: i64,
    session_id: ?[]const u8,

    fn before(_: void, left: SummaryMessage, right: SummaryMessage) bool {
        switch (std.mem.order(u8, left.created_at orelse "", right.created_at orelse "")) {
            .lt => return true,
            .gt => return false,
            .eq => {},
        }
        if (left.index != right.index) return left.index < right.index;
        return std.mem.order(u8, left.qid, right.qid) == .lt;
    }
};

/// One claim as the summary job sees it.
const SummaryClaim = struct {
    qid: []const u8,
    text: []const u8,
    /// What the store indexes the claim by: the words it was said in.
    index_text: []const u8,
    created_at: ?[]const u8,
    message_qid: []const u8,
    /// Empty until the claim has been embedded.
    vector: []const i8 = &.{},
    vector_model: ?[]const u8 = null,
    properties_json: []const u8,

    fn before(_: void, left: SummaryClaim, right: SummaryClaim) bool {
        switch (std.mem.order(u8, left.created_at orelse "", right.created_at orelse "")) {
            .lt => return true,
            .gt => return false,
            .eq => {},
        }
        switch (std.mem.order(u8, left.message_qid, right.message_qid)) {
            .lt => return true,
            .gt => return false,
            .eq => {},
        }
        return std.mem.order(u8, left.qid, right.qid) == .lt;
    }
};

/// Reads a live claim; null for anything else or a claim with no text.
fn parseSummaryClaim(arena: std.mem.Allocator, node: storage.Node) !?SummaryClaim {
    if (!std.mem.eql(u8, node.label, "Assertion")) return null;
    const value = std.json.parseFromSliceLeaky(Value, arena, node.properties_json, .{}) catch |err| {
        if (err == error.OutOfMemory) return err;
        return null;
    };
    const props = objectValue(value) orelse return null;
    if (boolField(&props, "deleted") orelse false) return null;
    const text = stringField(&props, "text") orelse return null;
    if (std.mem.trim(u8, text, " \t\r\n").len == 0) return null;
    const message_qid = stringField(&props, "sourceMessageQid") orelse return null;
    const index_text = blk: {
        const search_text = stringField(&props, "searchText") orelse break :blk text;
        break :blk if (std.mem.trim(u8, search_text, " \t\r\n").len == 0) text else search_text;
    };
    var claim = SummaryClaim{
        .qid = node.qid,
        .text = text,
        .index_text = index_text,
        .created_at = optionalStringField(&props, "createdAt"),
        .message_qid = message_qid,
        .vector_model = optionalStringField(&props, "vectorModel"),
        .properties_json = node.properties_json,
    };
    if (stringField(&props, "vector")) |encoded| {
        const vector = patterns.decodeVectors(arena, encoded) catch |err| {
            if (err == error.OutOfMemory) return err;
            return claim;
        };
        if (vector.len > 0 and vector.len <= patterns.dims) claim.vector = vector;
    }
    return claim;
}

/// One summary a pass may write: what the model is asked, then what it
/// said. The provider half allocates from the work's own arena.
const SummaryWork = struct {
    arena_state: std.heap.ArenaAllocator,
    kind: SummaryKind,
    /// The stored node to rewrite; null when there is none yet.
    qid: ?[]const u8,
    content: []const u8,
    /// Names what the summary rests on (`summaries.memberKey`).
    source_key: []const u8,
    /// A session's messages, or a topic's claims.
    sources: []const []const u8,
    /// The messages behind it: a session's own, or those a topic's claims
    /// were drawn from.
    messages: []const []const u8,
    session_qid: ?[]const u8 = null,
    session_id: ?[]const u8 = null,
    first_said: ?[]const u8 = null,
    last_said: ?[]const u8 = null,
    named: ?summaries.Named = null,
    /// `Title: summary` and its vector, set before the node is written.
    text: []const u8 = "",
    vector: []const i8 = &.{},
    calls: usize = 0,
    /// Calls the provider replied to.
    replies: usize = 0,
    /// No reply could be read after a retry.
    malformed: bool = false,
    failure: ?anyerror = null,
};

/// One pass over the summaries of one scope, through prepare, call and
/// write. `leases` are the jobs that asked for it.
const SummaryTask = struct {
    arena_state: std.heap.ArenaAllocator,
    leases: std.ArrayList(jobs.LeaseResult) = .empty,
    scope_key: []const u8 = "",
    scope: Scope = .{},
    works: []SummaryWork = &.{},
    /// Qids of stored nodes that nothing stands behind any more.
    retired: []const []const u8 = &.{},
    counts: SummaryCounts = .{},
    calls: usize = 0,
    failure: ?anyerror = null,
    /// No provider call of the task got a reply.
    unanswered: bool = false,
    /// Why the pass did nothing, when it could not run at all.
    skipped: ?[]const u8 = null,
    /// Claims still waiting for a vector after this pass.
    unindexed: usize = 0,

    fn init(allocator: std.mem.Allocator) SummaryTask {
        return .{ .arena_state = std.heap.ArenaAllocator.init(allocator) };
    }

    fn deinit(self: *SummaryTask) void {
        for (self.works) |*work| work.arena_state.deinit();
        self.arena_state.deinit();
    }
};

fn freeSummaryTasks(allocator: std.mem.Allocator, tasks: []SummaryTask) void {
    for (tasks) |*task| task.deinit();
    allocator.free(tasks);
}

/// The provider half of a summary task; touches no storage, so it may run on
/// another thread. Up to `default_extract_concurrency` summaries are asked
/// for at once.
fn callSummaryTask(task: *SummaryTask, io: ?std.Io, endpoint: providers.ProviderEndpoint) void {
    if (task.failure != null or task.skipped != null) return;
    var start: usize = 0;
    while (start < task.works.len) : (start += default_extract_concurrency) {
        const part = task.works[start..@min(start + default_extract_concurrency, task.works.len)];
        const threads = io orelse {
            for (part) |*work| runSummaryWork(work, null, endpoint);
            continue;
        };
        var group: std.Io.Group = .init;
        for (part) |*work| {
            if (part.len == 1) {
                runSummaryWork(work, io, endpoint);
                continue;
            }
            group.concurrent(threads, runSummaryWork, .{ work, io, endpoint }) catch runSummaryWork(work, io, endpoint);
        }
        group.await(threads) catch {
            group.cancel(threads);
            task.failure = error.Canceled;
            return;
        };
    }
    var replies: usize = 0;
    var failure: ?anyerror = null;
    for (task.works) |work| {
        task.calls += work.calls;
        replies += work.replies;
        if (failure == null) failure = work.failure;
    }
    if (task.calls > 0 and replies == 0) {
        task.unanswered = true;
        task.failure = failure orelse error.ProviderUnavailable;
    }
}

/// Asks for one summary: the prompt, then once more when the reply cannot be
/// read. A call the provider does not answer is kept as the work's failure.
fn runSummaryWork(work: *SummaryWork, io: ?std.Io, endpoint: providers.ProviderEndpoint) void {
    const arena = work.arena_state.allocator();
    const attempts: []const []const u8 = switch (work.kind) {
        .session => &summaries.session_attempts,
        .topic => &summaries.topic_attempts,
    };
    for (attempts) |prompt| {
        work.calls += 1;
        const reply = providers.completeChat(arena, io, endpoint, .{
            .system_prompt = prompt,
            .user_content = work.content,
            .json_mode = true,
        }) catch |err| {
            work.failure = err;
            return;
        };
        work.replies += 1;
        work.named = summaries.parseNamed(arena, reply) catch |err| {
            if (err == error.OutOfMemory) {
                work.failure = err;
                return;
            }
            continue;
        };
        return;
    }
    work.malformed = true;
}

/// One summary task of a background batch; see `backgroundCall`.
fn backgroundSummaryCall(batch: *BackgroundBatch, task: *SummaryTask, io: std.Io, endpoint: providers.ProviderEndpoint) void {
    const notify = batch.notify;
    callSummaryTask(task, io, endpoint);
    if (batch.remaining.fetchSub(1, .acq_rel) == 1) {
        if (notify) |hook| hook.wake(hook.context);
    }
}

/// The provider half of a pattern task; touches no storage, so it may run on
/// another thread. Groups the sentences, then runs the calls of up to
/// `default_extract_concurrency` groups at once.
fn callPatternTask(task: *PatternTask, allocator: std.mem.Allocator, io: ?std.Io, endpoint: providers.ProviderEndpoint) void {
    if (task.failure != null or task.skipped != null) return;
    planPatternTask(task, allocator) catch |err| {
        task.failure = err;
        return;
    };
    var start: usize = 0;
    while (start < task.works.len) : (start += default_extract_concurrency) {
        const part = task.works[start..@min(start + default_extract_concurrency, task.works.len)];
        const threads = io orelse {
            for (part) |*work| runPatternWork(work, null, endpoint);
            continue;
        };
        var group: std.Io.Group = .init;
        for (part) |*work| {
            if (part.len == 1) {
                runPatternWork(work, io, endpoint);
                continue;
            }
            group.concurrent(threads, runPatternWork, .{ work, io, endpoint }) catch runPatternWork(work, io, endpoint);
        }
        group.await(threads) catch {
            group.cancel(threads);
            task.failure = error.Canceled;
            return;
        };
    }
    var replies: usize = 0;
    var failure: ?anyerror = null;
    for (task.works) |work| {
        task.calls += work.calls;
        replies += work.replies;
        if (failure == null) failure = work.failure;
    }
    if (task.calls > 0 and replies == 0) {
        task.unanswered = true;
        task.failure = failure orelse error.ProviderUnavailable;
    }
}

/// Groups the task's sentences and lines up each group worth a node with
/// the node stored for it, if any.
fn planPatternTask(task: *PatternTask, allocator: std.mem.Allocator) !void {
    const arena = task.arena_state.allocator();
    // With more sentences than can be compared, the newest are kept. The
    // newest message also says which vector size is current.
    var first_message: usize = task.messages.len;
    var dims: usize = 0;
    var total: usize = 0;
    while (first_message > 0) : (first_message -= 1) {
        const message = task.messages[first_message - 1];
        if (message.spans.len == 0) continue;
        if (dims == 0) dims = message.dims();
        if (total + message.spans.len > max_pattern_sentences) break;
        total += message.spans.len;
    }

    var entries = std.ArrayList(PatternEntry).empty;
    var entry_of = std.StringHashMap(u32).init(arena);
    var sentences = std.ArrayList(patterns.Sentence).empty;
    var refs = std.ArrayList(PatternSentenceRef).empty;
    for (task.messages[first_message..], first_message..) |message, message_index| {
        if (message.spans.len == 0 or message.dims() != dims) continue;
        const slot = try entry_of.getOrPut(message.entry_key);
        if (!slot.found_existing) {
            slot.value_ptr.* = @intCast(entries.items.len);
            try entries.append(arena, .{ .key = message.entry_key, .day = message.day });
        }
        const entry_index = slot.value_ptr.*;
        try entries.items[entry_index].messages.append(arena, @intCast(message_index));
        for (0..message.spans.len) |index| {
            const vector = message.vectors[index * dims ..][0..dims];
            const entry = &entries.items[entry_index];
            try refs.append(arena, .{ .message = @intCast(message_index), .index = @intCast(index), .at = @intCast(entry.sentences.items.len) });
            try entry.sentences.append(arena, @intCast(sentences.items.len));
            try sentences.append(arena, .{ .entry = entry_index, .vector = vector, .norm = patterns.norm(vector) });
        }
    }
    task.counts.sentences = sentences.items.len;
    task.counts.occasions = entries.items.len;

    const groups = try patterns.gather(arena, sentences.items, entries.items.len);
    task.counts.groups = groups.len;
    var works = std.ArrayList(PatternWork).empty;
    errdefer for (works.items) |*work| work.arena_state.deinit();
    var superseded = std.ArrayList([]const u8).empty;
    for (groups) |group| {
        const node = try matchPatternNode(arena, task.nodes, group.entries, entries.items);
        if (node) |matched| matched.taken = true;
        if (!patterns.worthNode(group.entries.len, entries.items.len)) {
            if (node) |matched| try superseded.append(arena, matched.qid);
            continue;
        }
        try works.ensureUnusedCapacity(arena, 1);
        works.appendAssumeCapacity(try buildPatternWork(arena, allocator, task, group, entries.items, sentences.items, refs.items, node));
    }
    for (task.nodes) |node| {
        if (!node.taken) try superseded.append(arena, node.qid);
    }
    task.counts.eligible = works.items.len;
    task.works = works.items;
    task.superseded = superseded.items;
}

/// The stored node most of whose occasions are in the group, if any is
/// still free: at least half of them, so a node follows its group as the
/// group grows or absorbs another.
fn matchPatternNode(arena: std.mem.Allocator, nodes: []PatternNodeState, group_entries: []const u32, entries: []const PatternEntry) !?*PatternNodeState {
    if (nodes.len == 0) return null;
    var keys = std.StringHashMap(void).init(arena);
    for (group_entries) |entry| try keys.put(entries[entry].key, {});
    var best: ?*PatternNodeState = null;
    var best_common: usize = 0;
    for (nodes) |*node| {
        if (node.taken or node.members.len == 0) continue;
        var common: usize = 0;
        for (node.members) |member| {
            if (keys.contains(member.key)) common += 1;
        }
        if (common * 2 < node.members.len or common <= best_common) continue;
        best = node;
        best_common = common;
    }
    return best;
}

fn patternSentenceText(task: *const PatternTask, ref: PatternSentenceRef) []const u8 {
    const message = task.messages[ref.message];
    const span = message.spans[ref.index];
    return message.content[span.start..span.end];
}

fn buildPatternWork(
    arena: std.mem.Allocator,
    allocator: std.mem.Allocator,
    task: *const PatternTask,
    group: patterns.Group,
    entries: []const PatternEntry,
    sentences: []const patterns.Sentence,
    refs: []const PatternSentenceRef,
    node: ?*PatternNodeState,
) !PatternWork {
    const texts = try arena.alloc([]const u8, group.units.len);
    for (group.units, texts) |unit, *slot| slot.* = patternSentenceText(task, refs[unit]);

    const occasions = try arena.alloc(PatternOccasion, group.entries.len);
    for (group.entries, occasions, 0..) |entry_index, *occasion, position| {
        const entry = entries[entry_index];
        var linked = std.ArrayList(u32).empty;
        var units = std.ArrayList([2]u32).empty;
        for (group.units) |unit| {
            if (sentences[unit].entry != entry_index) continue;
            const ref = refs[unit];
            try linked.append(arena, ref.at);
            const message_slot = std.mem.indexOfScalar(u32, entry.messages.items, ref.message).?;
            try units.append(arena, .{ @intCast(message_slot), ref.index });
        }
        const entry_texts = try arena.alloc([]const u8, entry.sentences.items.len);
        for (entry.sentences.items, entry_texts) |sentence, *slot| slot.* = patternSentenceText(task, refs[sentence]);
        const text = try patterns.passage(arena, entry_texts, linked.items);
        occasion.* = .{
            .key = entry.key,
            .day = entry.day,
            .sig = try std.fmt.allocPrint(arena, "{x}-{d}", .{ std.hash.Wyhash.hash(3, text), units.items.len }),
            .member = .{
                .id = try std.fmt.allocPrint(arena, "M{d}", .{position + 1}),
                .said = entry.day,
                .linked = entry_texts[linked.items[0]],
                .text = text,
            },
            .messages = entry.messages.items,
            .units = units.items,
        };
    }

    var work = PatternWork{ .arena_state = std.heap.ArenaAllocator.init(allocator), .node = node, .occasions = occasions, .sentences = texts };
    const stored = node orelse {
        work.dirty = true;
        return work;
    };
    work.about = stored.about;
    work.summary = stored.summary;
    work.kind = stored.kind;
    work.gated_at = stored.gated_at;
    work.claims_at = stored.claims_at;
    work.dirty = stored.members.len != occasions.len;
    // Answers stay with an occasion as long as its text does.
    const claims = try arena.alloc(PatternClaimWork, stored.claims.len);
    for (claims, stored.claims) |*claim, kept| {
        claim.* = .{ .claim = kept.claim, .answers = try arena.alloc(?patterns.Answer, occasions.len) };
        @memset(claim.answers, null);
    }
    for (occasions, 0..) |occasion, position| {
        const member_index = for (stored.members, 0..) |member, index| {
            if (std.mem.eql(u8, member.key, occasion.key)) break index;
        } else {
            work.dirty = true;
            continue;
        };
        if (!std.mem.eql(u8, stored.members[member_index].sig, occasion.sig)) {
            work.dirty = true;
            continue;
        }
        if (member_index != position) work.dirty = true;
        for (claims, stored.claims) |*claim, kept| {
            if (member_index < kept.answers.len) claim.answers[position] = kept.answers[member_index];
        }
    }
    work.claims = claims;
    return work;
}

/// The provider calls of one group, then what the counts say. A failure is
/// kept on the work; whatever the calls before it got is still concluded
/// and stored.
fn runPatternWork(work: *PatternWork, io: ?std.Io, endpoint: providers.ProviderEndpoint) void {
    const arena = work.arena_state.allocator();
    advancePatternWork(work, arena, io, endpoint) catch |err| {
        work.failure = err;
    };
    concludePatternWork(work, arena) catch |err| {
        if (work.failure == null) work.failure = err;
    };
}

fn askPattern(work: *PatternWork, arena: std.mem.Allocator, io: ?std.Io, endpoint: providers.ProviderEndpoint, prompt: []const u8, content: []const u8) ![]u8 {
    work.calls += 1;
    const reply = try providers.completeChat(arena, io, endpoint, .{
        .system_prompt = prompt,
        .user_content = content,
        .json_mode = true,
    });
    work.replies += 1;
    return reply;
}

/// Asks what the stored state lacks: the kind of group when it has none (or
/// has grown by half since it was called a routine or a story), the
/// generalisations when a recurring group has none, and the two answers for
/// every occasion a generalisation has not been asked about. A reply that
/// cannot be read after a retry is counted and that step left for the next
/// pass.
fn advancePatternWork(work: *PatternWork, arena: std.mem.Allocator, io: ?std.Io, endpoint: providers.ProviderEndpoint) !void {
    const count = work.occasions.len;
    if (work.kind == null or (work.kind.? != .recurring and count * 2 >= work.gated_at * 3)) {
        const content = try patterns.buildGateContent(arena, work.sentences);
        const gate = for (patterns.gate_attempts) |prompt| {
            const reply = try askPattern(work, arena, io, endpoint, prompt, content);
            break patterns.parseGate(arena, reply) catch |err| {
                if (err == error.OutOfMemory) return err;
                continue;
            };
        } else {
            work.malformed += 1;
            return;
        };
        work.kind = gate.kind;
        if (gate.about.len > 0 or work.about.len == 0) work.about = gate.about;
        work.gated_at = count;
        work.gated = true;
        work.dirty = true;
    }
    if (work.kind.? != .recurring) return;

    if (work.claims_at == null or (work.claims.len == 0 and count * 2 >= work.claims_at.? * 3)) {
        const shown = try patterns.shownPositions(arena, count);
        const members = try arena.alloc(patterns.Member, shown.len);
        for (shown, members) |position, *slot| slot.* = work.occasions[position].member;
        const content = try patterns.buildClaimsContent(arena, work.about, members);
        const proposal = for (patterns.claims_attempts) |prompt| {
            const reply = try askPattern(work, arena, io, endpoint, prompt, content);
            break patterns.parseClaims(arena, reply) catch |err| {
                if (err == error.OutOfMemory) return err;
                continue;
            };
        } else {
            work.malformed += 1;
            return;
        };
        const claims = try arena.alloc(PatternClaimWork, proposal.claims.len);
        for (claims, proposal.claims) |*claim, proposed| {
            claim.* = .{ .claim = proposed, .answers = try arena.alloc(?patterns.Answer, count) };
            @memset(claim.answers, null);
        }
        work.claims = claims;
        if (proposal.summary.len > 0) work.summary = proposal.summary;
        work.claims_at = count;
        work.proposed = true;
        work.dirty = true;
    }

    for (work.claims) |*claim| {
        var pending = std.ArrayList(usize).empty;
        for (claim.answers, 0..) |answer, position| {
            if (answer == null) try pending.append(arena, position);
        }
        var start: usize = 0;
        while (start < pending.items.len) : (start += patterns.check_batch) {
            const part = pending.items[start..@min(start + patterns.check_batch, pending.items.len)];
            var members: [patterns.check_batch]patterns.Member = undefined;
            var ids: [patterns.check_batch][]const u8 = undefined;
            for (part, 0..) |position, slot| {
                members[slot] = work.occasions[position].member;
                ids[slot] = members[slot].id;
            }
            const content = try patterns.buildCheckContent(arena, claim.claim.when, claim.claim.then, members[0..part.len]);
            var answers = [_]?patterns.Answer{null} ** patterns.check_batch;
            const read = for (patterns.check_attempts) |prompt| {
                const reply = try askPattern(work, arena, io, endpoint, prompt, content);
                patterns.parseAnswers(arena, reply, ids[0..part.len], answers[0..part.len]) catch |err| {
                    if (err == error.OutOfMemory) return err;
                    continue;
                };
                break true;
            } else false;
            if (!read) {
                work.malformed += 1;
                continue;
            }
            // An occasion the reply left out says nothing either way.
            for (part, answers[0..part.len]) |position, answer| claim.answers[position] = answer orelse .unknown;
            work.answered += part.len;
            work.dirty = true;
        }
    }
}

fn concludePatternWork(work: *PatternWork, arena: std.mem.Allocator) !void {
    if (work.kind == null or work.kind.? != .recurring or work.claims_at == null) return;
    const tested = try arena.alloc(patterns.Tested, work.claims.len);
    for (work.claims, tested) |claim, *slot| {
        slot.* = .{ .claim = claim.claim.claim, .result = patternClaimResult(claim.answers) };
    }
    work.conclusion = try patterns.conclude(arena, tested, work.occasions.len);
}

/// One pattern task of a background batch; see `backgroundCall`.
fn backgroundPatternCall(batch: *BackgroundBatch, task: *PatternTask, allocator: std.mem.Allocator, io: std.Io, endpoint: providers.ProviderEndpoint) void {
    const notify = batch.notify;
    callPatternTask(task, allocator, io, endpoint);
    if (batch.remaining.fetchSub(1, .acq_rel) == 1) {
        if (notify) |hook| hook.wake(hook.context);
    }
}

/// The provider half of a consolidate job; touches no storage, so it may run
/// on another thread. One call proposes pairs (a malformed reply gets one
/// retry), then each pair that holds up against the texts gets its own
/// verify call. A call the provider does not answer fails the whole job, so
/// nothing half-checked is written and the job is tried again.
fn callConsolidateTask(task: *ConsolidateTask, allocator: std.mem.Allocator, io: ?std.Io, endpoint: providers.ProviderEndpoint) void {
    const user_content = task.user_content orelse return;
    if (task.failure != null) return;
    for (fact_updates.attempt_prompts) |prompt| {
        task.calls += 1;
        const reply = providers.completeChat(allocator, io, endpoint, .{
            .system_prompt = prompt,
            .user_content = user_content,
            .json_mode = true,
        }) catch |err| {
            task.failure = err;
            task.unanswered = true;
            return;
        };
        defer allocator.free(reply);
        const parsed = fact_updates.parseReply(allocator, reply) catch |err| {
            if (err == error.OutOfMemory) {
                task.failure = err;
                return;
            }
            continue;
        };
        defer parsed.deinit();
        verifyProposals(task, allocator, io, endpoint, parsed.value) catch |err| {
            task.failure = err;
        };
        return;
    }
    task.failure = error.MalformedUpdates;
}

/// Checks the proposed pairs of one reply and fills `task.accepted`.
fn verifyProposals(task: *ConsolidateTask, allocator: std.mem.Allocator, io: ?std.Io, endpoint: providers.ProviderEndpoint, payload: Value) !void {
    const claims = try task.wireClaims(allocator);
    defer allocator.free(claims);
    const earlier = try task.wireEarlier(allocator);
    defer allocator.free(earlier);
    const proposals = try fact_updates.propose(allocator, payload, claims, earlier);
    defer proposals.deinit(allocator);
    task.counts = proposals.counts;
    for (proposals.items) |proposal| {
        const claim = claims[proposal.claim_index];
        const fact = earlier[proposal.earlier_index];
        const content = try fact_updates.buildVerifyContent(allocator, fact, claim);
        defer allocator.free(content);
        var confirmed = false;
        for (fact_updates.verify_attempt_prompts) |prompt| {
            task.calls += 1;
            const reply = providers.completeChat(allocator, io, endpoint, .{
                .system_prompt = prompt,
                .user_content = content,
                .json_mode = true,
            }) catch |err| {
                task.unanswered = true;
                return err;
            };
            defer allocator.free(reply);
            const parsed = fact_updates.parseVerdict(allocator, reply) catch |err| {
                if (err == error.OutOfMemory) return err;
                continue;
            };
            defer parsed.deinit();
            const verdict = fact_updates.verdictOf(parsed.value);
            if (try fact_updates.confirms(allocator, fact.text, claim.text, verdict)) {
                const old_value = try allocator.dupe(u8, verdict.earlier_value.?);
                errdefer allocator.free(old_value);
                const new_value = try allocator.dupe(u8, verdict.later_value.?);
                errdefer allocator.free(new_value);
                try task.accepted.append(allocator, .{
                    .claim_index = proposal.claim_index,
                    .earlier_index = proposal.earlier_index,
                    .old_value = old_value,
                    .new_value = new_value,
                });
                confirmed = true;
            }
            break;
        }
        if (confirmed) task.counts.accepted += 1 else task.counts.unverified += 1;
    }
}

/// One consolidate call of a background batch; see `backgroundCall`.
fn backgroundConsolidateCall(batch: *BackgroundBatch, task: *ConsolidateTask, allocator: std.mem.Allocator, io: std.Io, endpoint: providers.ProviderEndpoint) void {
    const notify = batch.notify;
    callConsolidateTask(task, allocator, io, endpoint);
    if (batch.remaining.fetchSub(1, .acq_rel) == 1) {
        if (notify) |hook| hook.wake(hook.context);
    }
}

/// The provider half of an extract job; touches no storage, so it may run on
/// another thread. Malformed replies get E1's two bounded retries, each with
/// its own prompt suffix.
/// The provider half of one extract job: the first reading of the turn, its
/// grounding, and a second reading of the messages no claim came from.
/// Touches no storage, so it can run on a worker thread.
fn callExtractTask(task: *ExtractTask, allocator: std.mem.Allocator, io: ?std.Io, endpoint: providers.ProviderEndpoint) void {
    const user_content = task.user_content orelse return;
    if (task.failure != null) return;
    task.parsed = extractReply(task, allocator, io, endpoint, &fact_extraction.attempt_prompts, user_content) orelse return;
    recallExtractTask(task, allocator, io, endpoint) catch |err| {
        task.failure = err;
    };
}

/// One reading: the call, and E1's bounded retries after a reply that is not
/// valid extraction JSON. Null with `task.failure` set when none parses.
fn extractReply(
    task: *ExtractTask,
    allocator: std.mem.Allocator,
    io: ?std.Io,
    endpoint: providers.ProviderEndpoint,
    prompts: []const []const u8,
    user_content: []const u8,
) ?std.json.Parsed(Value) {
    for (prompts, 0..) |prompt, attempt| {
        task.calls += 1;
        if (attempt > 0) task.json_retries += 1;
        const reply = providers.completeChat(allocator, io, endpoint, .{
            .system_prompt = prompt,
            .user_content = user_content,
            .json_mode = true,
        }) catch |err| {
            task.failure = err;
            task.unanswered = true;
            return null;
        };
        defer allocator.free(reply);
        return fact_extraction.parseReply(allocator, reply) catch |err| {
            if (err == error.OutOfMemory) {
                task.failure = err;
                return null;
            }
            continue;
        };
    }
    task.failure = error.MalformedExtraction;
    return null;
}

/// Grounds the first reading and reads again, on their own, the messages it
/// drew no claim from (`fact_extraction.recall_prompt`). A turn is not
/// extracted until both readings have answered: when the second fails, the
/// job fails and is run again.
fn recallExtractTask(task: *ExtractTask, allocator: std.mem.Allocator, io: ?std.Io, endpoint: providers.ProviderEndpoint) !void {
    const messages = try task.sourceMessages(allocator);
    defer allocator.free(messages);
    task.grounding = try fact_extraction.ground(allocator, task.parsed.?.value, messages);

    const again = try fact_extraction.unclaimed(allocator, messages, task.grounding.?.claims);
    defer allocator.free(again);
    if (again.len == 0) return;
    const reread = try allocator.alloc(fact_extraction.SourceMessage, again.len);
    defer allocator.free(reread);
    for (again, reread) |index, *message| {
        message.* = messages[index];
        message.content = fact_extraction.clipForRecall(message.content);
    }
    const user_content = try fact_extraction.buildUserContent(allocator, task.sources.items[0].created_at, reread);
    defer allocator.free(user_content);
    task.recall_messages = again.len;
    task.recall_parsed = extractReply(task, allocator, io, endpoint, &fact_extraction.recall_attempt_prompts, user_content) orelse return;
    const recalled = try fact_extraction.ground(allocator, task.recall_parsed.?.value, reread);
    // The reply numbers the messages it was given; claims are kept by the
    // turn's own numbering.
    for (recalled.claims) |*claim| claim.message_index = again[claim.message_index];
    task.recall_grounding = recalled;
}

/// One provider call of a background batch, on a worker thread. The last
/// call to return wakes the host.
fn backgroundCall(batch: *BackgroundBatch, task: *ExtractTask, allocator: std.mem.Allocator, io: std.Io, endpoint: providers.ProviderEndpoint) void {
    // Read before the count drops: the batch may be finished and freed as
    // soon as it reaches zero and this function returns.
    const notify = batch.notify;
    callExtractTask(task, allocator, io, endpoint);
    if (batch.remaining.fetchSub(1, .acq_rel) == 1) {
        if (notify) |hook| hook.wake(hook.context);
    }
}

/// An extract provider must be a chat model; `deterministic` cannot extract.
fn extractProviderUsable(endpoint: providers.ProviderEndpoint) bool {
    return endpoint.kind == .http or endpoint.kind == .callback;
}

const RerankSettings = struct {
    enabled: bool = true,
    window: usize = default_rerank_candidates,
};

/// `options.rerank` (default true) and `options.rerankCandidates` (default
/// 50). Null when `rerankCandidates` is not a positive integer.
fn parseRerankSettings(options: ?ObjectMap) ?RerankSettings {
    var settings = RerankSettings{};
    const opts = options orelse return settings;
    if (boolField(&opts, "rerank")) |enabled| settings.enabled = enabled;
    if (opts.get("rerankCandidates")) |value| switch (value) {
        .null => {},
        .integer => |count| {
            if (count < 1) return null;
            settings.window = std.math.cast(usize, count) orelse return null;
        },
        else => return null,
    };
    return settings;
}

/// What the reranker scores for one item: raw evidence as
/// `YYYY-MM-DD role: text` from its raw source, so the cross-encoder sees when
/// and who; derived memory as its text.
fn rerankDocument(allocator: std.mem.Allocator, item: MessageResult) ![]u8 {
    const source = item.raw_source orelse return allocator.dupe(u8, item.text);
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    if (source.created_at) |created_at| {
        if (parseIsoDate(created_at)) |_| {
            try writer.writer.print("{s} ", .{created_at[0..10]});
        } else |_| {}
    }
    if (source.role) |role| try writer.writer.print("{s}: ", .{role});
    try writer.writer.writeAll(item.text);
    return writer.toOwnedSlice();
}

/// New order of the first `window` items: scored items by descending score,
/// ties in fused order, then unscored items in fused order. `scores` must be
/// validated (unique indices below `window`).
fn rerankOrder(allocator: std.mem.Allocator, window: usize, scores: []const providers.RerankResult) ![]usize {
    const ranked = try allocator.dupe(providers.RerankResult, scores);
    defer allocator.free(ranked);
    std.mem.sort(providers.RerankResult, ranked, {}, rerankRanksBefore);
    const placed = try allocator.alloc(bool, window);
    defer allocator.free(placed);
    @memset(placed, false);
    const order = try allocator.alloc(usize, window);
    errdefer allocator.free(order);
    var next: usize = 0;
    for (ranked) |result| {
        order[next] = result.index;
        placed[result.index] = true;
        next += 1;
    }
    for (placed, 0..) |was_placed, index| {
        if (was_placed) continue;
        order[next] = index;
        next += 1;
    }
    return order;
}

fn rerankRanksBefore(_: void, left: providers.RerankResult, right: providers.RerankResult) bool {
    if (left.relevance_score != right.relevance_score) return left.relevance_score > right.relevance_score;
    return left.index < right.index;
}

/// Rearranges `items` so position `i` holds the item previously at `order[i]`.
fn applyItemOrder(allocator: std.mem.Allocator, items: []MessageResult, order: []const usize) !void {
    const reordered = try allocator.alloc(MessageResult, order.len);
    defer allocator.free(reordered);
    for (order, 0..) |source, target| reordered[target] = items[source];
    @memcpy(items[0..order.len], reordered);
}

/// The rerank stage's trace; owns the qids in its top scores.
const OwnedRerankTrace = struct {
    allocator: std.mem.Allocator,
    trace: RerankTrace,
    top_scores: std.ArrayList(RerankScore) = .empty,

    fn failed(self: *const OwnedRerankTrace) bool {
        return std.mem.eql(u8, self.trace.status, "failed");
    }

    fn view(self: *const OwnedRerankTrace) RerankTrace {
        var trace = self.trace;
        trace.topScores = self.top_scores.items;
        return trace;
    }

    fn deinit(self: *OwnedRerankTrace) void {
        for (self.top_scores.items) |entry| self.allocator.free(entry.qid);
        self.top_scores.deinit(self.allocator);
    }
};

/// `options.queryExpansion` (default `off`). Null when it is not one of the
/// mode names.
fn parseQueryExpansion(options: ?ObjectMap) ?query_expansion.Mode {
    const opts = options orelse return .off;
    const value = opts.get("queryExpansion") orelse return .off;
    return switch (value) {
        .null => .off,
        .string => |text| query_expansion.parseMode(text),
        else => null,
    };
}

const ExpansionQuery = struct {
    text: []const u8,
    source: []const u8,
    hit_count: usize = 0,
    top_qids: std.ArrayList([]const u8) = .empty,
};

/// The queries of one retrieval, the original first, with what each one
/// retrieved for the trace. Owns the query texts and recorded qids.
const OwnedExpansion = struct {
    allocator: std.mem.Allocator,
    mode: query_expansion.Mode,
    status: []const u8 = query_expansion.status_unchanged,
    model: ?[]const u8 = null,
    latency_ms: f64 = 0,
    error_name: ?[]const u8 = null,
    queries: std.ArrayList(ExpansionQuery) = .empty,
    query_traces: std.ArrayList(query_expansion.QueryTrace) = .empty,

    fn append(self: *OwnedExpansion, text: []const u8, source: []const u8) !void {
        const owned = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(owned);
        try self.queries.append(self.allocator, .{ .text = owned, .source = source });
    }

    fn failed(self: *const OwnedExpansion) bool {
        return std.mem.eql(u8, self.status, query_expansion.status_failed);
    }

    /// Records how many candidates query `index` returned and its leading
    /// qids. Nothing is recorded when expansion is off.
    fn recordHits(self: *OwnedExpansion, index: usize, items: []const MessageResult) !void {
        if (self.mode == .off) return;
        const entry = &self.queries.items[index];
        entry.hit_count = items.len;
        for (items[0..@min(items.len, expansion_leaders_per_query)]) |item| {
            const qid = try self.allocator.dupe(u8, item.qid);
            errdefer self.allocator.free(qid);
            try entry.top_qids.append(self.allocator, qid);
        }
    }

    /// The trace, or null when expansion is off. Borrows from `self`.
    fn traceView(self: *OwnedExpansion) !?query_expansion.Trace {
        if (self.mode == .off) return null;
        self.query_traces.clearRetainingCapacity();
        for (self.queries.items) |entry| {
            try self.query_traces.append(self.allocator, .{
                .query = entry.text,
                .source = entry.source,
                .hitCount = entry.hit_count,
                .topQids = entry.top_qids.items,
            });
        }
        return .{
            .mode = @tagName(self.mode),
            .status = self.status,
            .model = self.model,
            .latencyMs = self.latency_ms,
            .queries = self.query_traces.items,
            .@"error" = self.error_name,
        };
    }

    fn deinit(self: *OwnedExpansion) void {
        for (self.queries.items) |*entry| {
            self.allocator.free(entry.text);
            for (entry.top_qids.items) |qid| self.allocator.free(qid);
            entry.top_qids.deinit(self.allocator);
        }
        self.queries.deinit(self.allocator);
        self.query_traces.deinit(self.allocator);
    }
};

/// Fuses per-query candidate lists (the original query's first) into one,
/// taking ownership of every item and leaving `lists` empty.
///
/// Each item scores the reciprocal-rank sum over the lists that hold it
/// (k = 60, every query weighted alike). Plain RRF favors items that several
/// overlapping queries share: the original query and the sub-query for the
/// side it already finds agree on many items, so the other side's best hit,
/// found by one sub-query alone, scores at most 1/61 and can fall below the
/// budget cut. So each query's first `expansion_leaders_per_query` items lead
/// the list, interleaved by rank (every query's first item, then every
/// query's second); the rest follow by fused score. Two rather than one,
/// because a chunk or an assistant reply often takes rank 1 ahead of the
/// user line that states the fact. At most `limit` items are kept.
fn fuseQueryItems(allocator: std.mem.Allocator, lists: []OwnedItems, limit: usize) !OwnedItems {
    var fused = OwnedItems{ .allocator = allocator };
    errdefer fused.deinit();
    var index_by_qid: std.StringHashMapUnmanaged(usize) = .empty;
    defer index_by_qid.deinit(allocator);
    var leaders = std.ArrayList([]const u8).empty;
    defer leaders.deinit(allocator);
    const leader_slots = try allocator.alloc(?[]const u8, lists.len * expansion_leaders_per_query);
    defer allocator.free(leader_slots);
    @memset(leader_slots, null);

    for (lists, 0..) |*list, list_index| {
        const incoming = list.items.items;
        // Reserve first so that moving items out of `list` cannot fail midway.
        try fused.items.ensureUnusedCapacity(allocator, incoming.len);
        try index_by_qid.ensureUnusedCapacity(allocator, @intCast(incoming.len));
        for (incoming, 0..) |item, rank| {
            const score = reciprocalRank(rank);
            const qid = if (index_by_qid.get(item.qid)) |at| blk: {
                fused.items.items[at].score += score;
                list.freeItem(item);
                break :blk fused.items.items[at].qid;
            } else blk: {
                var moved = item;
                moved.score = score;
                fused.items.appendAssumeCapacity(moved);
                index_by_qid.putAssumeCapacity(moved.qid, fused.items.items.len - 1);
                break :blk moved.qid;
            };
            if (rank < expansion_leaders_per_query) leader_slots[rank * lists.len + list_index] = qid;
        }
        list.items.items.len = 0;
    }

    sortItemsByScore(&fused);
    for (leader_slots) |slot| {
        const qid = slot orelse continue;
        if (!stringListContains(leaders.items, qid)) try leaders.append(allocator, qid);
    }
    var ordered = try std.ArrayList(MessageResult).initCapacity(allocator, fused.items.items.len);
    defer ordered.deinit(allocator);
    for (leaders.items) |qid| {
        for (fused.items.items) |item| {
            if (std.mem.eql(u8, item.qid, qid)) {
                ordered.appendAssumeCapacity(item);
                break;
            }
        }
    }
    for (fused.items.items) |item| {
        if (!stringListContains(leaders.items, item.qid)) ordered.appendAssumeCapacity(item);
    }
    @memcpy(fused.items.items, ordered.items);
    if (fused.items.items.len > limit) {
        for (fused.items.items[limit..]) |item| fused.freeItem(item);
        fused.items.shrinkRetainingCapacity(limit);
    }
    return fused;
}

const OwnedItems = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(MessageResult) = .empty,
    /// Set when the items were collected with `options.factKeys`.
    fact_keys: ?FactKeysTrace = null,

    /// The fact-keys trace with the evidence items still in the packet.
    fn factKeysTrace(self: *const OwnedItems) ?FactKeysTrace {
        var trace = self.fact_keys orelse return null;
        trace.keptEvidenceItems = 0;
        for (self.items.items) |item| {
            if (item.via_assertion) trace.keptEvidenceItems += 1;
        }
        return trace;
    }

    fn deinit(self: *OwnedItems) void {
        for (self.items.items) |item| {
            self.freeItem(item);
        }
        self.items.deinit(self.allocator);
    }

    /// Raw evidence competes by rank alongside derived memory. A raw item is
    /// dropped only when its message evidences a slot memory that is stale at
    /// query time and the packet already holds the active version of that
    /// slot (stale "uses npm" evidence must not sit next to "uses pnpm").
    /// Memory cards that restate a fact/preference/procedure slot already in
    /// the packet are dropped as duplicates.
    fn applyRawEvidencePolicy(self: *OwnedItems) void {
        var write_index: usize = 0;
        for (self.items.items) |item| {
            if (self.isStaleRawEvidence(item) or self.isDuplicateCard(item)) {
                self.freeItem(item);
                continue;
            }
            self.items.items[write_index] = item;
            write_index += 1;
        }
        self.items.items.len = write_index;
    }

    fn isStaleRawEvidence(self: *const OwnedItems, item: MessageResult) bool {
        const source = item.raw_source orelse return false;
        for (source.stale_slot_keys) |slot_key| {
            if (self.containsSlotItem(slot_key, false)) return true;
        }
        return false;
    }

    fn isDuplicateCard(self: *const OwnedItems, item: MessageResult) bool {
        if (!std.mem.eql(u8, item.type, "memory_card")) return false;
        const slot_key = item.slotKey orelse return false;
        return self.containsSlotItem(slot_key, true);
    }

    fn containsSlotItem(self: *const OwnedItems, slot_key: []const u8, derived_only: bool) bool {
        for (self.items.items) |item| {
            if (item.raw_source != null) continue;
            const item_slot = item.slotKey orelse continue;
            if (!std.mem.eql(u8, item_slot, slot_key)) continue;
            if (derived_only and !isFactLikeType(item.type)) continue;
            return true;
        }
        return false;
    }

    fn filterByNeeds(self: *OwnedItems, needs_value: ?Value) usize {
        if (needsCount(needs_value) == 0) return 0;

        var dropped: usize = 0;
        var write_index: usize = 0;
        for (self.items.items) |item| {
            if (!itemAllowedByNeeds(item, needs_value)) {
                self.freeItem(item);
                dropped += 1;
                continue;
            }
            self.items.items[write_index] = item;
            write_index += 1;
        }
        self.items.items.len = write_index;
        return dropped;
    }

    fn applyTokenBudget(self: *OwnedItems, budget: usize) usize {
        var dropped: usize = 0;
        var used: usize = 0;
        var write_index: usize = 0;
        for (self.items.items) |item| {
            const item_tokens = estimateItemTokens(item);
            if (used + item_tokens > budget) {
                self.freeItem(item);
                dropped += 1;
                continue;
            }
            used += item_tokens;
            self.items.items[write_index] = item;
            write_index += 1;
        }
        self.items.items.len = write_index;
        return dropped;
    }

    /// `applyTokenBudget` for a context whose session headers carry the
    /// session's summary: the first item kept from a session pays for it.
    /// The summaries may take `summary_limit` tokens between them, in the
    /// order the sessions are reached; a session past that is headed by its
    /// title alone, and `threads.session_titles` then says so.
    fn applySessionTokenBudget(self: *OwnedItems, budget: usize, threads: *ThreadItems, summary_limit: usize) !usize {
        const titles = &threads.session_titles;
        if (titles.count() == 0) return self.applyTokenBudget(budget);
        var charged: std.StringHashMapUnmanaged(void) = .empty;
        defer charged.deinit(self.allocator);
        var dropped: usize = 0;
        var used: usize = 0;
        var summaries_used: usize = 0;
        var write_index: usize = 0;
        for (self.items.items) |item| {
            var item_tokens = estimateItemTokens(item);
            var session: ?[]const u8 = null;
            var heading: []const u8 = "";
            var summary_tokens: usize = 0;
            if (item.raw_source) |source| {
                if (source.session_qid) |session_qid| {
                    if (!charged.contains(session_qid)) {
                        if (titles.get(session_qid)) |title| {
                            session = session_qid;
                            heading = title;
                            summary_tokens = estimatePromptTokens(title) + 2;
                            if (summaries_used + summary_tokens > summary_limit) {
                                heading = threads.session_names.get(session_qid) orelse "";
                                summary_tokens = 0;
                            }
                            item_tokens += estimatePromptTokens(heading) + 2;
                        }
                    }
                }
            }
            if (used + item_tokens > budget) {
                self.freeItem(item);
                dropped += 1;
                continue;
            }
            // The key belongs to an item that is kept.
            if (session) |session_qid| {
                try charged.put(self.allocator, session_qid, {});
                titles.getPtr(session_qid).?.* = heading;
                summaries_used += summary_tokens;
            }
            used += item_tokens;
            self.items.items[write_index] = item;
            write_index += 1;
        }
        self.items.items.len = write_index;
        return dropped;
    }

    /// Moves every item of `other` to the end of this list.
    fn adopt(self: *OwnedItems, other: *OwnedItems) !void {
        try self.items.appendSlice(self.allocator, other.items.items);
        other.items.clearRetainingCapacity();
    }

    fn containsQid(self: *const OwnedItems, qid: []const u8) bool {
        for (self.items.items) |item| {
            if (std.mem.eql(u8, item.qid, qid)) return true;
        }
        return false;
    }

    fn filterByQids(self: *OwnedItems, kept_qids: []const []const u8) usize {
        var dropped: usize = 0;
        var write_index: usize = 0;
        for (self.items.items) |item| {
            if (!stringListContains(kept_qids, item.qid)) {
                self.freeItem(item);
                dropped += 1;
                continue;
            }
            self.items.items[write_index] = item;
            write_index += 1;
        }
        self.items.items.len = write_index;
        return dropped;
    }

    fn freeItem(self: *OwnedItems, item: MessageResult) void {
        self.allocator.free(item.qid);
        self.allocator.free(item.text);
        self.allocator.free(item.state);
        if (item.validFrom) |value| self.allocator.free(value);
        if (item.validTo) |value| self.allocator.free(value);
        if (item.slotKey) |value| self.allocator.free(value);
        if (item.subject) |value| self.allocator.free(value);
        if (item.attribute) |value| self.allocator.free(value);
        if (item.value) |value| self.allocator.free(value);
        if (item.unit) |value| self.allocator.free(value);
        if (item.aggregationMode) |value| self.allocator.free(value);
        if (item.raw_source) |source| source.deinit(self.allocator);
        if (item.thread) |block| block.deinit(self.allocator);
        freeEvidence(self.allocator, item.evidence);
    }
};

/// What the summary layer gave one retrieval; see `Runtime.collectThreadItems`.
const ThreadItems = struct {
    items: OwnedItems,
    trace: ThreadsTrace = .{},
    /// False when the scope has no summary to read: the context is then
    /// built as it was before there were any.
    active: bool = false,
    /// What the header of each summarised session says, by session qid:
    /// `Title: summary`, or once `applySessionTokenBudget` has run, the
    /// title alone for a session past the summaries' share of the budget.
    session_titles: std.StringHashMapUnmanaged([]const u8) = .empty,
    /// The title alone, for the same sessions.
    session_names: std.StringHashMapUnmanaged([]const u8) = .empty,
    arena_state: std.heap.ArenaAllocator,

    fn deinit(self: *ThreadItems) void {
        self.items.deinit();
        self.arena_state.deinit();
    }
};

const ThreadsTrace = struct {
    /// Topic and session summaries of the scope that could be compared with
    /// the question, and the claims that were.
    topics: usize = 0,
    sessions: usize = 0,
    claims: usize = 0,
    /// Topics shown, and the facts shown in the whole section.
    shown: usize = 0,
    facts: usize = 0,
    /// Sessions raw evidence could come from, and raw candidates left out
    /// because their session was not one of them.
    sessionsOpened: usize = 0,
    rawDropped: usize = 0,
    /// Estimated tokens of the section, taken out of the raw evidence budget.
    tokens: usize = 0,
};

/// How an item of the threads section is rendered: the heading it stands
/// under and its lines, each `[message qid] day said: fact`.
const ThreadBlock = struct {
    heading: []const u8,
    lines: []const []const u8,

    fn init(allocator: std.mem.Allocator, heading: []const u8, lines: []const []const u8) !ThreadBlock {
        const owned_heading = try allocator.dupe(u8, heading);
        errdefer allocator.free(owned_heading);
        const owned_lines = try allocator.alloc([]const u8, lines.len);
        var filled: usize = 0;
        errdefer {
            for (owned_lines[0..filled]) |line| allocator.free(line);
            allocator.free(owned_lines);
        }
        for (lines) |line| {
            owned_lines[filled] = try allocator.dupe(u8, line);
            filled += 1;
        }
        return .{ .heading = owned_heading, .lines = owned_lines };
    }

    fn deinit(self: ThreadBlock, allocator: std.mem.Allocator) void {
        allocator.free(self.heading);
        for (self.lines) |line| allocator.free(line);
        allocator.free(self.lines);
    }
};

/// A block of the threads section while it is being filled.
const ThreadBlockPlan = struct {
    heading: []const u8,
    topic: ?usize = null,
    score: f32 = 0,
    members: []const u32,
};

/// A topic, or a fact in no topic, competing for the threads section.
const ThreadCandidate = struct {
    score: f32,
    topic: ?usize = null,
    claim: u32 = 0,

    fn before(_: void, left: ThreadCandidate, right: ThreadCandidate) bool {
        if (left.score != right.score) return left.score > right.score;
        if ((left.topic == null) != (right.topic == null)) return left.topic != null;
        return if (left.topic) |topic| topic < right.topic.? else left.claim < right.claim;
    }
};

/// The question as a stored vector.
const ThreadQuestion = struct {
    vector: []const i8,
    norm: f32,

    fn cosine(self: ThreadQuestion, vector: []const i8) f32 {
        if (vector.len != self.vector.len) return 0;
        return patterns.cosine(self.vector, self.norm, vector, patterns.norm(vector));
    }
};

/// A summary node as retrieval reads it.
const ShownSummary = struct {
    qid: []const u8,
    kind: SummaryKind,
    /// `Title: summary`.
    text: []const u8,
    title: []const u8 = "",
    vector: []const i8,
    vector_model: ?[]const u8 = null,
    members: []const []const u8 = &.{},
    session_qid: ?[]const u8 = null,
    first_said: ?[]const u8 = null,
    last_said: ?[]const u8 = null,
    /// A topic's facts that can be shown, in the order they happened.
    children: []const u32 = &.{},
    score: f32 = 0,

    fn nearerQuestion(_: void, left: ShownSummary, right: ShownSummary) bool {
        if (left.score != right.score) return left.score > right.score;
        return naturalQidOrder(left.qid, right.qid) == .lt;
    }
};

/// Reads a current summary that has something to show; null for anything
/// else, a summary the model declined among them.
fn parseShownSummary(arena: std.mem.Allocator, node: storage.Node) !?ShownSummary {
    if (!std.mem.eql(u8, node.label, "Summary")) return null;
    const value = std.json.parseFromSliceLeaky(Value, arena, node.properties_json, .{}) catch |err| {
        if (err == error.OutOfMemory) return err;
        return null;
    };
    const props = objectValue(value) orelse return null;
    if (boolField(&props, "deleted") orelse false) return null;
    if (!std.mem.eql(u8, stringField(&props, "state") orelse "", "current")) return null;
    if (boolField(&props, "declined") orelse false) return null;
    const kind = std.meta.stringToEnum(SummaryKind, stringField(&props, "summaryType") orelse "") orelse return null;
    const text = stringField(&props, "text") orelse return null;
    if (std.mem.trim(u8, text, " \t\r\n").len == 0) return null;
    const vector = patterns.decodeVectors(arena, stringField(&props, "vector") orelse return null) catch |err| {
        if (err == error.OutOfMemory) return err;
        return null;
    };
    if (vector.len == 0 or vector.len > patterns.dims) return null;
    var members = std.ArrayList([]const u8).empty;
    if (arrayValue(props.get("members"))) |wire| {
        for (wire.items) |member| try members.append(arena, stringValue(member) orelse return null);
    }
    return .{
        .qid = node.qid,
        .kind = kind,
        .text = text,
        .title = stringField(&props, "title") orelse "",
        .vector = vector,
        .vector_model = optionalStringField(&props, "vectorModel"),
        .members = members.items,
        .session_qid = optionalStringField(&props, "sessionQid"),
        .first_said = optionalStringField(&props, "firstSaid"),
        .last_said = optionalStringField(&props, "lastSaid"),
    };
}

/// A claim as retrieval reads it for the threads section.
const ShownClaim = struct {
    qid: []const u8,
    text: []const u8,
    created_at: []const u8,
    said: temporal.CivilDate,
    message_qid: []const u8,
    session_qid: ?[]const u8 = null,
    event: ?temporal.Window = null,
    planned: bool = false,
    vector: []const i8 = &.{},
    vector_model: ?[]const u8 = null,
    /// Cosine with the question; zero for a claim not embedded yet.
    score: f32 = 0,
    /// The time named in the question that the claim is dated inside.
    named: ?usize = null,
    topic: ?usize = null,
    shown: bool = false,
    rendered: ?[]const u8 = null,

    /// The claim's line of the section, written once.
    fn line(self: *ShownClaim, arena: std.mem.Allocator, current: ?temporal.CivilDate) ![]const u8 {
        if (self.rendered) |text| return text;
        var writer: std.Io.Writer.Allocating = .init(arena);
        try writer.writer.print("[{s}] ", .{self.message_qid});
        try summaries.writeFactLine(&writer.writer, .{ .said = self.said, .text = self.text, .event = self.event, .planned = self.planned }, current);
        self.rendered = writer.written();
        return self.rendered.?;
    }

    fn lineTokens(self: *ShownClaim, arena: std.mem.Allocator, current: ?temporal.CivilDate) !usize {
        return estimatePromptTokens(try self.line(arena, current)) + 1;
    }

    fn placed(self: ShownClaim) i64 {
        return summaries.placedDay(.{ .said = self.said, .text = self.text, .event = self.event });
    }

    fn happenedBefore(claims: []ShownClaim, left: u32, right: u32) bool {
        const left_day = claims[left].placed();
        const right_day = claims[right].placed();
        if (left_day != right_day) return left_day < right_day;
        return saidBefore(claims, left, right);
    }

    fn saidBefore(claims: []ShownClaim, left: u32, right: u32) bool {
        const order = std.mem.order(u8, claims[left].created_at, claims[right].created_at);
        if (order != .eq) return order == .lt;
        return naturalQidOrder(claims[left].qid, claims[right].qid) == .lt;
    }

    fn nearerQuestion(claims: []ShownClaim, left: u32, right: u32) bool {
        if (claims[left].score != claims[right].score) return claims[left].score > claims[right].score;
        return left < right;
    }
};

/// Reads a live claim a person made, with the day it was said; null for
/// anything else.
fn parseShownClaim(arena: std.mem.Allocator, node: storage.Node) !?ShownClaim {
    if (!std.mem.eql(u8, node.label, "Assertion")) return null;
    const value = std.json.parseFromSliceLeaky(Value, arena, node.properties_json, .{}) catch |err| {
        if (err == error.OutOfMemory) return err;
        return null;
    };
    const props = objectValue(value) orelse return null;
    if (boolField(&props, "deleted") orelse false) return null;
    if (!isSpeakerRole(stringField(&props, "role") orelse "user")) return null;
    const text = std.mem.trim(u8, stringField(&props, "text") orelse return null, " \t\r\n");
    if (text.len == 0) return null;
    const created_at = stringField(&props, "createdAt") orelse return null;
    const said = parseIsoDate(created_at) catch return null;
    var claim = ShownClaim{
        .qid = node.qid,
        .text = text,
        .created_at = created_at,
        .said = said,
        .message_qid = stringField(&props, "sourceMessageQid") orelse return null,
        .session_qid = optionalStringField(&props, "sessionQid"),
        .planned = boolField(&props, "planned") orelse false,
        .vector_model = optionalStringField(&props, "vectorModel"),
    };
    if (stringField(&props, "eventStart")) |start_text| {
        if (stringField(&props, "eventEnd")) |end_text| {
            const start: ?temporal.CivilDate = parseIsoDate(start_text) catch null;
            const end: ?temporal.CivilDate = parseIsoDate(end_text) catch null;
            if (start != null and end != null and temporal.daysFromCivil(start.?) <= temporal.daysFromCivil(end.?)) {
                claim.event = .{ .start = start.?, .end = end.? };
            }
        }
    }
    // A claim stored before events had spans has a day at most.
    if (claim.event == null) {
        if (stringField(&props, "eventDate")) |event_date| {
            if (event_date.len == 10) {
                if (parseIsoDate(event_date)) |day| {
                    claim.event = .{ .start = day, .end = day };
                } else |_| {}
            }
        }
    }
    if (stringField(&props, "vector")) |encoded| {
        const vector = patterns.decodeVectors(arena, encoded) catch |err| {
            if (err == error.OutOfMemory) return err;
            return claim;
        };
        if (vector.len > 0 and vector.len <= patterns.dims) claim.vector = vector;
    }
    return claim;
}

/// The heading over the facts dated inside a time the question names:
/// `Said on or about 2023-05-20 (Sat): the question's "last Saturday"`.
fn namedTimeHeading(arena: std.mem.Allocator, time: temporal.NamedTime, window: temporal.Window) ![]const u8 {
    var writer: std.Io.Writer.Allocating = .init(arena);
    const out = &writer.writer;
    try out.writeAll("Said on or about ");
    try summaries.writeDay(out, window.start, null);
    if (!window.start.eql(window.end)) {
        try out.writeAll(" to ");
        try summaries.writeDay(out, window.end, null);
    }
    try out.print(": the question's \"{s}\"", .{time.phrase});
    return writer.written();
}

const ThreadItemSpec = struct {
    qid: []const u8,
    type: []const u8,
    text: []const u8,
    score: f32,
    valid_from: ?[]const u8,
    heading: []const u8,
    lines: []const []const u8,
};

/// Adds one item of the threads section. Its evidence is the message of
/// each fact shown with it, quoting the fact.
fn appendThreadItem(
    allocator: std.mem.Allocator,
    owned: *OwnedItems,
    spec: ThreadItemSpec,
    claims: []const ShownClaim,
    members: []const u32,
    filter: ItemFilter,
) !void {
    const qid = try allocator.dupe(u8, spec.qid);
    errdefer allocator.free(qid);
    const text = try allocator.dupe(u8, spec.text);
    errdefer allocator.free(text);
    const state = try allocator.dupe(u8, "current");
    errdefer allocator.free(state);
    const valid_from = try dupeOptional(allocator, spec.valid_from);
    errdefer if (valid_from) |value| allocator.free(value);
    var evidence = std.ArrayList(EvidenceResult).empty;
    errdefer {
        for (evidence.items) |entry| {
            allocator.free(entry.qid);
            allocator.free(entry.quote);
            if (entry.timestamp) |timestamp| allocator.free(timestamp);
        }
        evidence.deinit(allocator);
    }
    if (filter.include_evidence) {
        try evidence.ensureTotalCapacityPrecise(allocator, members.len);
        for (members) |index| {
            const claim = claims[index];
            const message_qid = try allocator.dupe(u8, claim.message_qid);
            errdefer allocator.free(message_qid);
            const quote = try allocator.dupe(u8, claim.text);
            errdefer allocator.free(quote);
            const timestamp = try allocator.dupe(u8, claim.created_at);
            evidence.appendAssumeCapacity(.{ .qid = message_qid, .quote = quote, .timestamp = timestamp });
        }
    }
    const block = try ThreadBlock.init(allocator, spec.heading, spec.lines);
    errdefer block.deinit(allocator);
    const evidence_slice = try evidence.toOwnedSlice(allocator);
    errdefer freeEvidence(allocator, evidence_slice);
    try owned.items.append(allocator, .{
        .qid = qid,
        .type = spec.type,
        .text = text,
        .score = spec.score,
        .state = state,
        .validFrom = valid_from,
        .evidence = evidence_slice,
        .includeDebug = filter.include_debug,
        .thread = block,
    });
}

/// Whether two raw items show the same text: the same node, or a message
/// and one of its own chunks.
fn sameRawEvidence(left: MessageResult, right: MessageResult) bool {
    if (std.mem.eql(u8, left.qid, right.qid)) return true;
    const left_source = left.raw_source orelse return false;
    const right_source = right.raw_source orelse return false;
    if (!std.mem.eql(u8, left_source.message_qid, right_source.message_qid)) return false;
    return left_source.chunk_index == null or right_source.chunk_index == null;
}

/// `options.facts`: the fact items of one retrieval and what they add up to.
const FactItems = struct {
    items: OwnedItems,
    trace: FactsTrace = .{},
};

/// The updates around one claim; see `Runtime.updateLinks`.
const UpdateLinks = struct {
    /// Claims that replaced it, and when the latest one was stated.
    replaced_by: OwnedQids,
    replaced_at: ?[]u8 = null,
    /// Claims it replaced.
    replaces: OwnedQids,

    fn deinit(self: *UpdateLinks, allocator: std.mem.Allocator) void {
        self.replaced_by.deinit();
        self.replaces.deinit();
        if (self.replaced_at) |value| allocator.free(value);
    }
};

/// Whether a message was written by a person: anything but the assistant's
/// replies, system text and tool output. Only such messages state facts
/// about their author.
fn isSpeakerRole(role: []const u8) bool {
    for ([_][]const u8{ "assistant", "system", "tool", "function", "developer" }) |other| {
        if (std.ascii.eqlIgnoreCase(role, other)) return false;
    }
    return true;
}

/// Which nodes may become retrieval items, and how they are rendered.
const ItemFilter = struct {
    scope: Scope = .{},
    include_deleted: bool = false,
    labels_value: ?Value = null,
    valid_at: ?[]const u8 = null,
    event_window: EventWindow = .{},
    include_evidence: bool = true,
    include_debug: bool = false,
    /// `options.facts`: claims are hidden from search, but they are what
    /// the facts section is made of.
    allow_hidden: bool = false,
};

/// Appends `node` as an item scored `score` when it passes `filter`.
fn appendNodeItem(allocator: std.mem.Allocator, owned: *OwnedItems, node: storage.Node, score: f32, filter: ItemFilter) !bool {
    const include_deleted = filter.include_deleted;
    const labels_value = filter.labels_value;
    const valid_at = filter.valid_at;
    if (!include_deleted and try propertyBool(allocator, node.properties_json, "deleted")) return false;
    if (!try filter.scope.matchesNode(allocator, node)) return false;
    if (isInternalLabel(node.label) and !labelRequestedExplicitly(node.label, labels_value)) return false;
    if (isStructuralLabel(node.label) and !labelRequestedExplicitly(node.label, labels_value)) return false;
    if (isHiddenSearchLabel(node.label) and !filter.allow_hidden and !labelRequestedExplicitly(node.label, labels_value)) return false;
    if (!labelAllowed(node.label, labels_value)) return false;
    // Chunked messages and copy-only episodes are reached through
    // their chunks/messages; never surface them as items themselves.
    if (try propertyIsFalse(allocator, node.properties_json, "searchable")) return false;
    if (!try nodeWithinEventWindow(allocator, node, filter.event_window)) return false;
    if (!include_deleted and valid_at != null) {
        if (!try nodeActiveAt(allocator, node, valid_at.?)) return false;
    }
    if (!include_deleted and valid_at == null and isSlotMemoryLabel(node.label)) {
        if (!try propertyEquals(allocator, node.properties_json, "state", "current")) return false;
    }
    if (!include_deleted and isDerivedLabel(node.label)) {
        if (valid_at) |timestamp| {
            if (!try derivedActiveAt(allocator, node, timestamp)) return false;
        } else {
            if (!try propertyEquals(allocator, node.properties_json, "state", "current")) return false;
        }
    }

    const text = itemTextForNode(allocator, node) catch return false;
    errdefer allocator.free(text);
    const raw_source = try rawSourceForNode(allocator, node);
    errdefer if (raw_source) |source| source.deinit(allocator);
    const evidence = if (!filter.include_evidence)
        try allocator.alloc(EvidenceResult, 0)
    else if (std.mem.eql(u8, node.label, "Chunk"))
        try chunkEvidence(allocator, node, raw_source)
    else
        try evidenceForNode(allocator, node);
    errdefer freeEvidence(allocator, evidence);
    const state = try stateForNode(allocator, node);
    errdefer allocator.free(state);
    const valid_from = try validFromForNode(allocator, node);
    errdefer if (valid_from) |value_to_free| allocator.free(value_to_free);
    const valid_to = try readOptionalPropertyString(allocator, node.properties_json, "validTo");
    errdefer if (valid_to) |value_to_free| allocator.free(value_to_free);
    const slot_metadata = try slotMetadataForNode(allocator, node);
    errdefer slot_metadata.deinit(allocator);
    const result_qid = try allocator.dupe(u8, node.qid);
    errdefer allocator.free(result_qid);
    try owned.items.append(allocator, .{
        .qid = result_qid,
        .type = labelType(node.label),
        .text = text,
        .score = score,
        .state = state,
        .validFrom = valid_from,
        .validTo = valid_to,
        .evidence = evidence,
        .includeDebug = filter.include_debug,
        .slotKey = slot_metadata.slot_key,
        .subject = slot_metadata.subject,
        .attribute = slot_metadata.attribute,
        .value = slot_metadata.value,
        .numericValue = slot_metadata.numeric_value,
        .unit = slot_metadata.unit,
        .aggregationMode = slot_metadata.aggregation_mode,
        .raw_source = raw_source,
    });
    return true;
}

fn stringGreaterThan(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.order(u8, left, right) == .gt;
}

fn stringLessThan(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.order(u8, left, right) == .lt;
}

/// Evidence handed to answer synthesis, in retrieval rank order. Strings are
/// borrowed from `items` and must not outlive them; `evidenceQids` let readers
/// cite either a chunk/derived qid or its parent message.
fn buildAnswerEvidencePacket(allocator: std.mem.Allocator, items: []const MessageResult) ![]answer_synthesis.EvidenceItem {
    const packet = try allocator.alloc(answer_synthesis.EvidenceItem, items.len);
    errdefer allocator.free(packet);
    var written: usize = 0;
    errdefer {
        for (packet[0..written]) |item| allocator.free(item.evidenceQids);
    }
    for (items, 0..) |item, index| {
        const evidence_qids = try allocator.alloc([]const u8, item.evidence.len);
        for (item.evidence, 0..) |evidence, evidence_index| {
            evidence_qids[evidence_index] = evidence.qid;
        }
        packet[index] = .{
            .qid = item.qid,
            .type = item.type,
            .text = std.mem.trim(u8, item.text, " \t\r\n"),
            .state = item.state,
            .value = item.value,
            .evidenceQids = evidence_qids,
        };
        written += 1;
    }
    return packet;
}

fn freeAnswerEvidencePacket(allocator: std.mem.Allocator, packet: []answer_synthesis.EvidenceItem) void {
    for (packet) |item| allocator.free(item.evidenceQids);
    allocator.free(packet);
}

/// Stable sort by descending score; equal scores put newer items first.
fn sortItemsByScore(owned: *OwnedItems) void {
    std.mem.sort(MessageResult, owned.items.items, {}, itemRanksBefore);
}

fn itemRanksBefore(_: void, left: MessageResult, right: MessageResult) bool {
    if (left.score != right.score) return left.score > right.score;
    return std.mem.order(u8, left.validFrom orelse "", right.validFrom orelse "") == .gt;
}

const OwnedContextPacket = struct {
    allocator: std.mem.Allocator,
    core: std.ArrayList(MessageResult) = .empty,
    current_facts: std.ArrayList(MessageResult) = .empty,
    preferences: std.ArrayList(MessageResult) = .empty,
    procedural: std.ArrayList(MessageResult) = .empty,
    patterns: std.ArrayList(MessageResult) = .empty,
    threads: std.ArrayList(MessageResult) = .empty,
    episodes: std.ArrayList(MessageResult) = .empty,
    warnings: []const []const u8 = &.{},

    fn fromItems(allocator: std.mem.Allocator, items: []const MessageResult, warnings: []const []const u8) !OwnedContextPacket {
        var context = OwnedContextPacket{ .allocator = allocator, .warnings = warnings };
        errdefer context.deinit();
        for (items) |item| {
            if (item.thread != null) {
                try context.threads.append(allocator, item);
            } else if (std.mem.eql(u8, item.type, "core")) {
                try context.core.append(allocator, item);
            } else if (std.mem.eql(u8, item.type, "fact")) {
                try context.current_facts.append(allocator, item);
            } else if (std.mem.eql(u8, item.type, "preference")) {
                try context.preferences.append(allocator, item);
            } else if (std.mem.eql(u8, item.type, "procedure")) {
                try context.procedural.append(allocator, item);
            } else if (std.mem.eql(u8, item.type, "pattern")) {
                try context.patterns.append(allocator, item);
            } else {
                try context.episodes.append(allocator, item);
            }
        }
        return context;
    }

    fn view(self: *const OwnedContextPacket) ContextPacket {
        return .{
            .core = self.core.items,
            .currentFacts = self.current_facts.items,
            .preferences = self.preferences.items,
            .procedural = self.procedural.items,
            .patterns = self.patterns.items,
            .threads = self.threads.items,
            .episodes = self.episodes.items,
            .warnings = self.warnings,
        };
    }

    fn deinit(self: *OwnedContextPacket) void {
        self.core.deinit(self.allocator);
        self.current_facts.deinit(self.allocator);
        self.preferences.deinit(self.allocator);
        self.procedural.deinit(self.allocator);
        self.patterns.deinit(self.allocator);
        self.threads.deinit(self.allocator);
        self.episodes.deinit(self.allocator);
    }
};

const OwnedNodeRefs = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(NodeRefResult) = .empty,

    fn append(self: *OwnedNodeRefs, allocator: std.mem.Allocator, qid: []const u8, node_type: []const u8, relation: []const u8) !void {
        const owned_qid = try allocator.dupe(u8, qid);
        errdefer allocator.free(owned_qid);
        try self.items.append(allocator, .{
            .qid = owned_qid,
            .type = node_type,
            .relation = relation,
        });
    }

    fn deinit(self: *OwnedNodeRefs) void {
        for (self.items.items) |item| {
            self.allocator.free(item.qid);
        }
        self.items.deinit(self.allocator);
    }
};

const OwnedForgetReport = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(ForgetReportItem) = .empty,

    fn append(self: *OwnedForgetReport, allocator: std.mem.Allocator, qid: []const u8, node_type: []const u8, action: []const u8) !void {
        const owned_qid = try allocator.dupe(u8, qid);
        errdefer allocator.free(owned_qid);
        try self.items.append(allocator, .{
            .qid = owned_qid,
            .type = node_type,
            .action = action,
        });
    }

    fn deinit(self: *OwnedForgetReport) void {
        for (self.items.items) |item| {
            self.allocator.free(item.qid);
        }
        self.items.deinit(self.allocator);
    }
};

const OwnedQids = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList([]const u8) = .empty,

    fn appendUnique(self: *OwnedQids, allocator: std.mem.Allocator, qid: []const u8) !void {
        if (self.contains(qid)) return;
        const owned_qid = try allocator.dupe(u8, qid);
        errdefer allocator.free(owned_qid);
        try self.items.append(allocator, owned_qid);
    }

    fn contains(self: *const OwnedQids, qid: []const u8) bool {
        for (self.items.items) |existing| {
            if (std.mem.eql(u8, existing, qid)) return true;
        }
        return false;
    }

    fn deinit(self: *OwnedQids) void {
        for (self.items.items) |qid| {
            self.allocator.free(qid);
        }
        self.items.deinit(self.allocator);
    }
};

const OwnedAuditEvents = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(AuditEventResult) = .empty,

    fn append(
        self: *OwnedAuditEvents,
        allocator: std.mem.Allocator,
        stream: []const u8,
        sequence: u64,
        raw_json: []const u8,
    ) !void {
        const owned_stream = try allocator.dupe(u8, stream);
        errdefer allocator.free(owned_stream);
        const owned_json = try allocator.dupe(u8, raw_json);
        errdefer allocator.free(owned_json);
        try self.items.append(allocator, .{
            .stream = owned_stream,
            .sequence = sequence,
            .rawJson = owned_json,
        });
    }

    fn deinit(self: *OwnedAuditEvents) void {
        for (self.items.items) |item| {
            self.allocator.free(item.stream);
            self.allocator.free(item.rawJson);
        }
        self.items.deinit(self.allocator);
    }
};

const SlotMetadata = struct {
    slot_key: ?[]u8 = null,
    subject: ?[]u8 = null,
    attribute: ?[]u8 = null,
    value: ?[]u8 = null,
    numeric_value: ?i64 = null,
    unit: ?[]u8 = null,
    aggregation_mode: ?[]u8 = null,

    fn deinit(self: SlotMetadata, allocator: std.mem.Allocator) void {
        if (self.slot_key) |value| allocator.free(value);
        if (self.subject) |value| allocator.free(value);
        if (self.attribute) |value| allocator.free(value);
        if (self.value) |value| allocator.free(value);
        if (self.unit) |value| allocator.free(value);
        if (self.aggregation_mode) |value| allocator.free(value);
    }
};

fn parseScope(params: *const ObjectMap) Scope {
    const scope_obj = objectField(params, "scope") orelse return .{};
    return .{
        .tenant_id = optionalStringField(&scope_obj, "tenantId"),
        .user_id = optionalStringField(&scope_obj, "userId"),
        .agent_id = optionalStringField(&scope_obj, "agentId"),
        .project_id = optionalStringField(&scope_obj, "projectId"),
    };
}

fn parseValidAt(params: *const ObjectMap) ?[]const u8 {
    const time_obj = objectField(params, "time") orelse return null;
    return optionalStringField(&time_obj, "validAt");
}

fn parseEventWindow(params: *const ObjectMap) EventWindow {
    const time_obj = objectField(params, "time") orelse return .{};
    return .{
        .start = optionalStringField(&time_obj, "eventWindowStart"),
        .end = optionalStringField(&time_obj, "eventWindowEnd"),
    };
}

fn parseSelectorTimeWindow(selector: *const ObjectMap) EventWindow {
    const time_obj = objectField(selector, "timeWindow") orelse return .{};
    return .{
        .start = optionalStringField(&time_obj, "start"),
        .end = optionalStringField(&time_obj, "end"),
    };
}

fn parseSearchMode(value: ?[]const u8) ?SearchMode {
    const mode = value orelse return .fts;
    if (std.mem.eql(u8, mode, "fts")) return .fts;
    if (std.mem.eql(u8, mode, "vector")) return .vector;
    if (std.mem.eql(u8, mode, "hybrid")) return .hybrid;
    if (std.mem.eql(u8, mode, "graph")) return .graph;
    return null;
}

fn parseRetrieveMode(value: ?[]const u8, capabilities: storage.Capabilities) ?SearchMode {
    if (value) |mode| return parseSearchMode(mode);
    if (capabilities.vector and capabilities.embedding_model != null and !std.mem.eql(u8, capabilities.embedding_model.?, "lattice_hash_embed")) {
        return .hybrid;
    }
    return .fts;
}

fn retrievalCandidateSources(mode: SearchMode, candidate_count: usize, core_count: usize) CandidateSources {
    var sources = CandidateSources{ .core = core_count };
    switch (mode) {
        .fts => sources.fts = candidate_count,
        .vector => sources.vector = candidate_count,
        .hybrid => sources.hybrid = candidate_count,
        .graph => sources.graph = candidate_count,
    }
    return sources;
}

fn storageHealth(capabilities: storage.Capabilities) protocol.StorageHealth {
    return .{
        .backend = capabilities.backend,
        .durable = capabilities.durable,
        .fullText = capabilities.full_text,
        .vector = capabilities.vector,
        .streams = capabilities.streams,
        .transactions = capabilities.transactions,
        .verification = capabilities.verification,
        .vectorDimensions = capabilities.vector_dimensions,
        .embeddingModel = capabilities.embedding_model,
    };
}

fn needsCount(needs_value: ?Value) usize {
    const needs = arrayValue(needs_value) orelse return 0;
    var count: usize = 0;
    for (needs.items) |need_value| {
        if (stringValue(need_value) != null) count += 1;
    }
    return count;
}

fn needsIncludes(needs_value: ?Value, expected: []const u8) bool {
    const needs = arrayValue(needs_value) orelse return false;
    for (needs.items) |need_value| {
        const need = stringValue(need_value) orelse continue;
        if (std.mem.eql(u8, need, expected)) return true;
    }
    return false;
}

fn freeStringList(allocator: std.mem.Allocator, tokens: []const []const u8) void {
    for (tokens) |token| {
        allocator.free(token);
    }
    allocator.free(tokens);
}

fn paramsObject(value: ?Value) !ObjectMap {
    const present = value orelse return ObjectMap.empty;
    return switch (present) {
        .object => |object| object,
        else => error.InvalidParams,
    };
}

fn objectField(object: *const ObjectMap, key: []const u8) ?ObjectMap {
    const value = object.get(key) orelse return null;
    return objectValue(value);
}

fn objectValue(value: Value) ?ObjectMap {
    return switch (value) {
        .object => |object| object,
        else => null,
    };
}

fn arrayValue(value: ?Value) ?std.json.Array {
    const present = value orelse return null;
    return switch (present) {
        .array => |array| array,
        else => null,
    };
}

fn stringField(object: *const ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    return stringValue(value);
}

fn optionalStringField(object: *const ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .null => null,
        .string => |string| string,
        else => null,
    };
}

fn boolField(object: *const ObjectMap, key: []const u8) ?bool {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .bool => |boolean| boolean,
        else => null,
    };
}

fn integerField(object: *const ObjectMap, key: []const u8) ?i64 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .integer => |integer| integer,
        else => null,
    };
}

fn stringValue(value: ?Value) ?[]const u8 {
    const present = value orelse return null;
    return switch (present) {
        .string => |string| string,
        else => null,
    };
}

fn jsonRpcId(value: ?Value) ?[]const u8 {
    const present = value orelse return null;
    return switch (present) {
        .string => |string| string,
        else => null,
    };
}

fn readPropertyString(allocator: std.mem.Allocator, properties_json: []const u8, key: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(Value, allocator, properties_json, .{});
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |object| object,
        else => return error.InvalidProperties,
    };
    const value = object.get(key) orelse return error.MissingProperty;
    return switch (value) {
        .string => |string| allocator.dupe(u8, string),
        else => error.InvalidProperties,
    };
}

fn readOptionalPropertyString(allocator: std.mem.Allocator, properties_json: []const u8, key: []const u8) !?[]u8 {
    var parsed = try std.json.parseFromSlice(Value, allocator, properties_json, .{});
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |object| object,
        else => return null,
    };
    const value = object.get(key) orelse return null;
    return switch (value) {
        .null => null,
        .string => |string| try allocator.dupe(u8, string),
        else => null,
    };
}

fn readOptionalPropertyInt(allocator: std.mem.Allocator, properties_json: []const u8, key: []const u8) !?i64 {
    var parsed = try std.json.parseFromSlice(Value, allocator, properties_json, .{});
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |object| object,
        else => return null,
    };
    const value = object.get(key) orelse return null;
    return switch (value) {
        .null => null,
        .integer => |integer| integer,
        else => null,
    };
}

fn slotMetadataForNode(allocator: std.mem.Allocator, node: storage.Node) !SlotMetadata {
    return .{
        .slot_key = try readOptionalPropertyString(allocator, node.properties_json, "slotKey"),
        .subject = try readOptionalPropertyString(allocator, node.properties_json, "subject"),
        .attribute = try readOptionalPropertyString(allocator, node.properties_json, "attribute"),
        .value = try readOptionalPropertyString(allocator, node.properties_json, "value"),
        .numeric_value = try readOptionalPropertyInt(allocator, node.properties_json, "numericValue"),
        .unit = try readOptionalPropertyString(allocator, node.properties_json, "unit"),
        .aggregation_mode = try readOptionalPropertyString(allocator, node.properties_json, "aggregationMode"),
    };
}

fn readStringArrayProperty(allocator: std.mem.Allocator, properties_json: []const u8, key: []const u8) ![][]const u8 {
    var parsed = try std.json.parseFromSlice(Value, allocator, properties_json, .{});
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |object| object,
        else => return allocator.alloc([]const u8, 0),
    };
    const array = arrayValue(object.get(key)) orelse return allocator.alloc([]const u8, 0);
    var values = std.ArrayList([]const u8).empty;
    errdefer {
        for (values.items) |value| allocator.free(value);
        values.deinit(allocator);
    }
    for (array.items) |item| {
        const value = stringValue(item) orelse continue;
        try values.append(allocator, try allocator.dupe(u8, value));
    }
    return values.toOwnedSlice(allocator);
}

fn propertyEquals(allocator: std.mem.Allocator, properties_json: []const u8, key: []const u8, expected: []const u8) !bool {
    var parsed = try std.json.parseFromSlice(Value, allocator, properties_json, .{});
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |object| object,
        else => return false,
    };
    const value = object.get(key) orelse return false;
    return switch (value) {
        .string => |string| std.mem.eql(u8, string, expected),
        else => false,
    };
}

fn propertyBool(allocator: std.mem.Allocator, properties_json: []const u8, key: []const u8) !bool {
    var parsed = try std.json.parseFromSlice(Value, allocator, properties_json, .{});
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |object| object,
        else => return false,
    };
    const value = object.get(key) orelse return false;
    return switch (value) {
        .bool => |boolean| boolean,
        else => false,
    };
}

/// True only when `key` is present and explicitly `false`.
fn propertyIsFalse(allocator: std.mem.Allocator, properties_json: []const u8, key: []const u8) !bool {
    var parsed = try std.json.parseFromSlice(Value, allocator, properties_json, .{});
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |object| object,
        else => return false,
    };
    const value = object.get(key) orelse return false;
    return switch (value) {
        .bool => |boolean| !boolean,
        else => false,
    };
}

fn textForNode(allocator: std.mem.Allocator, node: storage.Node) ![]u8 {
    // Session and Turn nodes are structure, not memory text; callers skip them
    // instead of surfacing "Session"/"Turn" placeholders.
    if (std.mem.eql(u8, node.label, "Session") or std.mem.eql(u8, node.label, "Turn")) {
        return error.NoRenderableText;
    }
    if (std.mem.eql(u8, node.label, "Core")) {
        return readPropertyString(allocator, node.properties_json, "text");
    }
    if (std.mem.eql(u8, node.label, "Episode")) {
        return readPropertyString(allocator, node.properties_json, "summary");
    }
    if (std.mem.eql(u8, node.label, "MemoryCard") or std.mem.eql(u8, node.label, "Assertion")) {
        return readPropertyString(allocator, node.properties_json, "text");
    }
    if (isDerivedLabel(node.label)) {
        return readPropertyString(allocator, node.properties_json, "text");
    }
    if (std.mem.eql(u8, node.label, "Message")) {
        return readPropertyString(allocator, node.properties_json, "content");
    }
    if (std.mem.eql(u8, node.label, "ToolCall")) {
        return readPropertyString(allocator, node.properties_json, "toolName");
    }
    if (std.mem.eql(u8, node.label, "Observation")) {
        return readPropertyString(allocator, node.properties_json, "content");
    }
    if (std.mem.eql(u8, node.label, "Entity")) {
        return readPropertyString(allocator, node.properties_json, "canonicalName");
    }
    if (std.mem.eql(u8, node.label, "Feedback")) {
        return readPropertyString(allocator, node.properties_json, "rating");
    }
    return allocator.dupe(u8, node.label);
}

const parseIsoDate = temporal.parseIsoDate;
const weekdayName = temporal.weekdayName;

/// `YYYY-MM-DD (Weekday)` for a trusted current-date line; unparseable
/// timestamps are passed through unchanged.
fn formatCurrentDate(allocator: std.mem.Allocator, timestamp: []const u8) ![]u8 {
    const date = parseIsoDate(timestamp) catch return allocator.dupe(u8, timestamp);
    return std.fmt.allocPrint(allocator, "{s} ({s})", .{ timestamp[0..10], weekdayName(date) });
}

/// `options.temporalHints`: the trusted question date (`time.validAt`) the
/// hints are computed against, or null when hints are off or the date is
/// missing or unparseable.
fn temporalHintDate(enabled: bool, valid_at: ?[]const u8) ?temporal.CivilDate {
    if (!enabled) return null;
    return parseIsoDate(valid_at orelse return null) catch null;
}

/// Relative time expressions in the query resolved against the hint date, or
/// null when hints are off or nothing matches.
fn timeReferencesForQuery(allocator: std.mem.Allocator, query: []const u8, hint_date: ?temporal.CivilDate) !?[]u8 {
    return temporal.resolveTimeReferences(allocator, query, hint_date orelse return null);
}

fn stateForNode(allocator: std.mem.Allocator, node: storage.Node) ![]u8 {
    if (try readOptionalPropertyString(allocator, node.properties_json, "state")) |state| {
        return state;
    }
    if (try propertyBool(allocator, node.properties_json, "deleted")) return allocator.dupe(u8, "deleted");
    return allocator.dupe(u8, "current");
}

fn labelType(label: []const u8) []const u8 {
    if (std.mem.eql(u8, label, "Message")) return "message";
    if (std.mem.eql(u8, label, "Chunk")) return "message";
    if (std.mem.eql(u8, label, "Fact")) return "fact";
    if (std.mem.eql(u8, label, "Preference")) return "preference";
    if (std.mem.eql(u8, label, "Procedure")) return "procedure";
    if (std.mem.eql(u8, label, "Episode")) return "episode";
    if (std.mem.eql(u8, label, "MemoryCard")) return "memory_card";
    if (std.mem.eql(u8, label, "Session")) return "raw";
    if (std.mem.eql(u8, label, "Turn")) return "raw";
    if (std.mem.eql(u8, label, "ToolCall")) return "raw";
    if (std.mem.eql(u8, label, "Observation")) return "raw";
    if (std.mem.eql(u8, label, "Entity")) return "entity";
    if (std.mem.eql(u8, label, "Core")) return "core";
    if (std.mem.eql(u8, label, "Assertion")) return "assertion";
    if (std.mem.eql(u8, label, "Update")) return "update";
    if (std.mem.eql(u8, label, "Pattern")) return "pattern";
    if (std.mem.eql(u8, label, "Summary")) return "summary";
    if (std.mem.eql(u8, label, "Feedback")) return "raw";
    return "raw";
}

fn isDerivedLabel(label: []const u8) bool {
    return std.mem.eql(u8, label, "Fact") or std.mem.eql(u8, label, "Preference") or std.mem.eql(u8, label, "Procedure");
}

fn isSlotMemoryLabel(label: []const u8) bool {
    return isDerivedLabel(label) or std.mem.eql(u8, label, "MemoryCard");
}

fn isEvidenceLinkedLabel(label: []const u8) bool {
    return isDerivedLabel(label) or std.mem.eql(u8, label, "MemoryCard") or std.mem.eql(u8, label, "Episode") or
        std.mem.eql(u8, label, "Assertion") or std.mem.eql(u8, label, "Update");
}

fn isConsolidatableLabel(label: []const u8) bool {
    return isDerivedLabel(label) or std.mem.eql(u8, label, "MemoryCard") or std.mem.eql(u8, label, "Episode");
}

fn isFactLikeType(node_type: []const u8) bool {
    return std.mem.eql(u8, node_type, "fact") or std.mem.eql(u8, node_type, "preference") or std.mem.eql(u8, node_type, "procedure");
}

fn isInternalLabel(label: []const u8) bool {
    return std.mem.eql(u8, label, "Job") or std.mem.eql(u8, label, "Idempotency") or std.mem.eql(u8, label, "Schema") or std.mem.eql(u8, label, "Migration");
}

/// Session and Turn are containers with no text; they are never retrieval
/// items unless a caller explicitly asks for the label.
fn isStructuralLabel(label: []const u8) bool {
    return std.mem.eql(u8, label, "Session") or std.mem.eql(u8, label, "Turn");
}

/// Search keys that are never items themselves unless a caller asks for the
/// label: entities seed graph search, and assertions stand in for their
/// source evidence under `options.factKeys`.
fn isHiddenSearchLabel(label: []const u8) bool {
    return std.mem.eql(u8, label, "Entity") or std.mem.eql(u8, label, "Assertion") or std.mem.eql(u8, label, "Update");
}

fn labelRequestedExplicitly(label: []const u8, labels_value: ?Value) bool {
    const labels = arrayValue(labels_value) orelse return false;
    for (labels.items) |label_value| {
        const wanted = stringValue(label_value) orelse continue;
        if (std.mem.eql(u8, wanted, label)) return true;
    }
    return false;
}

fn labelAllowed(label: []const u8, labels_value: ?Value) bool {
    const labels = arrayValue(labels_value) orelse return true;
    for (labels.items) |label_value| {
        const wanted = stringValue(label_value) orelse continue;
        if (std.mem.eql(u8, wanted, label) or std.mem.eql(u8, wanted, labelType(label))) return true;
        // Long messages are searched through their chunks.
        if (std.mem.eql(u8, label, "Chunk") and std.mem.eql(u8, wanted, "Message")) return true;
    }
    return false;
}

fn itemAllowedByNeeds(item: MessageResult, needs_value: ?Value) bool {
    if (needsCount(needs_value) == 0) return true;
    if (std.mem.eql(u8, item.type, "core")) return needsIncludes(needs_value, "core");
    if (std.mem.eql(u8, item.type, "fact")) return needsIncludes(needs_value, "current_facts");
    if (std.mem.eql(u8, item.type, "preference")) return needsIncludes(needs_value, "preferences");
    if (std.mem.eql(u8, item.type, "procedure")) return needsIncludes(needs_value, "procedural");
    if (std.mem.eql(u8, item.type, "memory_card")) {
        return needsIncludes(needs_value, "recent_episodes") or needsIncludes(needs_value, "raw");
    }
    if (std.mem.eql(u8, item.type, "message") or std.mem.eql(u8, item.type, "episode")) {
        return needsIncludes(needs_value, "recent_episodes") or needsIncludes(needs_value, "raw");
    }
    if (std.mem.eql(u8, item.type, "raw")) return needsIncludes(needs_value, "raw");
    return true;
}

/// Whether a node's date falls inside a window the question names: the day a
/// message or chunk was written, or for a claim the days of its event when it
/// has them and otherwise the day it was said. An event span counts when it
/// overlaps the window and is no longer than the window or a week, whichever
/// is longer: "in April 2023" says too little to answer "two weeks ago" by.
/// A claim written before spans were stored is matched by its event date
/// (`YYYY-MM-DD` only).
fn nodeDatedWithin(allocator: std.mem.Allocator, node: storage.Node, window: temporal.Window, is_claim: bool) !bool {
    if (is_claim) {
        if (try readEventSpan(allocator, node.properties_json)) |span| {
            if (try propertyBool(allocator, node.properties_json, "planned")) return false;
            const window_days = temporal.daysFromCivil(window.end) - temporal.daysFromCivil(window.start) + 1;
            const span_days = temporal.daysFromCivil(span.end) - temporal.daysFromCivil(span.start) + 1;
            if (span_days > @max(window_days, 7)) return false;
            return temporal.daysFromCivil(span.start) <= temporal.daysFromCivil(window.end) and
                temporal.daysFromCivil(span.end) >= temporal.daysFromCivil(window.start);
        }
        if (try readOptionalPropertyString(allocator, node.properties_json, "eventDate")) |event_date| {
            defer allocator.free(event_date);
            if (try propertyBool(allocator, node.properties_json, "planned")) return false;
            const date = parseIsoDate(event_date) catch return false;
            return temporal.windowContains(window, date);
        }
    }
    const created_at = (try readOptionalPropertyString(allocator, node.properties_json, "createdAt")) orelse return false;
    defer allocator.free(created_at);
    const date = parseIsoDate(created_at) catch return false;
    return temporal.windowContains(window, date);
}

/// A claim's `eventStart` and `eventEnd`, when both are stored and in order.
fn readEventSpan(allocator: std.mem.Allocator, properties_json: []const u8) !?temporal.Window {
    const start_text = (try readOptionalPropertyString(allocator, properties_json, "eventStart")) orelse return null;
    defer allocator.free(start_text);
    const end_text = (try readOptionalPropertyString(allocator, properties_json, "eventEnd")) orelse return null;
    defer allocator.free(end_text);
    const start = parseIsoDate(start_text) catch return null;
    const end = parseIsoDate(end_text) catch return null;
    if (temporal.daysFromCivil(end) < temporal.daysFromCivil(start)) return null;
    return .{ .start = start, .end = end };
}

fn nodeWithinEventWindow(allocator: std.mem.Allocator, node: storage.Node, window: EventWindow) !bool {
    if (!window.active()) return true;
    const timestamp = try eventTimestampForNode(allocator, node);
    defer if (timestamp) |value_to_free| allocator.free(value_to_free);
    const present = timestamp orelse return false;
    if (window.start) |start| {
        if (timestampBefore(present, start)) return false;
    }
    if (window.end) |end| {
        if (timestampAtOrAfter(present, end)) return false;
    }
    return true;
}

fn eventTimestampForNode(allocator: std.mem.Allocator, node: storage.Node) !?[]u8 {
    if (std.mem.eql(u8, node.label, "Message") or std.mem.eql(u8, node.label, "Chunk") or std.mem.eql(u8, node.label, "Assertion")) {
        return readOptionalPropertyString(allocator, node.properties_json, "createdAt");
    }
    if (std.mem.eql(u8, node.label, "Episode")) {
        return readOptionalPropertyString(allocator, node.properties_json, "eventTime");
    }
    if (std.mem.eql(u8, node.label, "Observation")) {
        return readOptionalPropertyString(allocator, node.properties_json, "createdAt");
    }
    if (isSlotMemoryLabel(node.label)) {
        return readOptionalPropertyString(allocator, node.properties_json, "validFrom");
    }
    return null;
}

fn validFromForNode(allocator: std.mem.Allocator, node: storage.Node) !?[]u8 {
    if (std.mem.eql(u8, node.label, "Message") or std.mem.eql(u8, node.label, "Chunk") or std.mem.eql(u8, node.label, "Assertion")) {
        return readOptionalPropertyString(allocator, node.properties_json, "createdAt");
    }
    if (std.mem.eql(u8, node.label, "Episode")) {
        return readOptionalPropertyString(allocator, node.properties_json, "eventTime");
    }
    if (std.mem.eql(u8, node.label, "Observation")) {
        return readOptionalPropertyString(allocator, node.properties_json, "createdAt");
    }
    if (isSlotMemoryLabel(node.label)) {
        return readOptionalPropertyString(allocator, node.properties_json, "validFrom");
    }
    return null;
}

fn nodeActiveAt(allocator: std.mem.Allocator, node: storage.Node, valid_at: []const u8) !bool {
    if (isSlotMemoryLabel(node.label)) {
        return derivedActiveAt(allocator, node, valid_at);
    }
    const timestamp = try eventTimestampForNode(allocator, node);
    defer if (timestamp) |value_to_free| allocator.free(value_to_free);
    if (timestamp) |value| {
        return !timestampBefore(valid_at, value);
    }
    return true;
}

fn derivedActiveAt(allocator: std.mem.Allocator, node: storage.Node, valid_at: []const u8) !bool {
    const valid_from = try readOptionalPropertyString(allocator, node.properties_json, "validFrom");
    defer if (valid_from) |value_to_free| allocator.free(value_to_free);
    const valid_to = try readOptionalPropertyString(allocator, node.properties_json, "validTo");
    defer if (valid_to) |value_to_free| allocator.free(value_to_free);

    if (valid_from) |timestamp| {
        if (timestampBefore(valid_at, timestamp)) return false;
    }
    if (valid_to) |timestamp| {
        if (timestampAtOrAfter(valid_at, timestamp)) return false;
    }
    return true;
}

fn timestampBefore(left: []const u8, right: []const u8) bool {
    return std.mem.order(u8, left, right) == .lt;
}

fn timestampAtOrAfter(left: []const u8, right: []const u8) bool {
    const order = std.mem.order(u8, left, right);
    return order == .eq or order == .gt;
}

/// Item text for retrieval; chunks carry their slice of the message content.
fn itemTextForNode(allocator: std.mem.Allocator, node: storage.Node) ![]u8 {
    if (std.mem.eql(u8, node.label, "Chunk")) {
        return readPropertyString(allocator, node.properties_json, "content");
    }
    return textForNode(allocator, node);
}

/// Raw-source metadata for Message and Chunk nodes; null for anything else.
fn rawSourceForNode(allocator: std.mem.Allocator, node: storage.Node) !?RawSource {
    const is_chunk = std.mem.eql(u8, node.label, "Chunk");
    if (!is_chunk and !std.mem.eql(u8, node.label, "Message")) return null;

    var parsed = try std.json.parseFromSlice(Value, allocator, node.properties_json, .{});
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |object| object,
        else => return null,
    };

    const message_qid = try allocator.dupe(u8, if (is_chunk) optionalStringField(&object, "messageQid") orelse node.qid else node.qid);
    errdefer allocator.free(message_qid);
    const role = try dupeOptional(allocator, optionalStringField(&object, "role"));
    errdefer if (role) |value| allocator.free(value);
    const created_at = try dupeOptional(allocator, optionalStringField(&object, "createdAt"));
    errdefer if (created_at) |value| allocator.free(value);
    const session_id = try dupeOptional(allocator, optionalStringField(&object, "sessionId"));
    errdefer if (session_id) |value| allocator.free(value);
    const session_qid = try dupeOptional(allocator, optionalStringField(&object, "sessionQid"));
    errdefer if (session_qid) |value| allocator.free(value);
    const turn_qid = try dupeOptional(allocator, optionalStringField(&object, "turnQid"));
    return .{
        .role = role,
        .created_at = created_at,
        .session_id = session_id,
        .session_qid = session_qid,
        .turn_qid = turn_qid,
        .message_qid = message_qid,
        .message_index = integerField(&object, "messageIndex"),
        .chunk_index = if (is_chunk) integerField(&object, "chunkIndex") else null,
        .chunk_count = if (is_chunk) integerField(&object, "chunkCount") else null,
    };
}

/// A chunk's evidence is its parent message; the quote is the chunk text.
fn chunkEvidence(allocator: std.mem.Allocator, node: storage.Node, raw_source: ?RawSource) ![]EvidenceResult {
    const source = raw_source orelse return allocator.alloc(EvidenceResult, 0);
    const evidence_qid = try allocator.dupe(u8, source.message_qid);
    errdefer allocator.free(evidence_qid);
    const quote = try readPropertyString(allocator, node.properties_json, "content");
    errdefer allocator.free(quote);
    const timestamp = try dupeOptional(allocator, source.created_at);
    errdefer if (timestamp) |value| allocator.free(value);
    const evidence = try allocator.alloc(EvidenceResult, 1);
    evidence[0] = .{ .qid = evidence_qid, .quote = quote, .timestamp = timestamp };
    return evidence;
}

fn dupeOptional(allocator: std.mem.Allocator, value: ?[]const u8) !?[]u8 {
    const present = value orelse return null;
    return try allocator.dupe(u8, present);
}

fn evidenceForNode(allocator: std.mem.Allocator, node: storage.Node) ![]EvidenceResult {
    if (!isEvidenceLinkedLabel(node.label)) {
        return allocator.alloc(EvidenceResult, 0);
    }
    const evidence_qid = readPropertyString(allocator, node.properties_json, "evidenceQid") catch {
        return allocator.alloc(EvidenceResult, 0);
    };
    errdefer allocator.free(evidence_qid);
    const quote = readPropertyString(allocator, node.properties_json, "quote") catch {
        allocator.free(evidence_qid);
        return allocator.alloc(EvidenceResult, 0);
    };
    errdefer allocator.free(quote);
    const timestamp = try readOptionalPropertyString(allocator, node.properties_json, "validFrom");
    errdefer if (timestamp) |value_to_free| allocator.free(value_to_free);
    const evidence = try allocator.alloc(EvidenceResult, 1);
    evidence[0] = .{
        .qid = evidence_qid,
        .quote = quote,
        .timestamp = timestamp,
    };
    return evidence;
}

fn freeEvidence(allocator: std.mem.Allocator, evidence: []const EvidenceResult) void {
    for (evidence) |item| {
        allocator.free(item.qid);
        allocator.free(item.quote);
        if (item.timestamp) |timestamp| allocator.free(timestamp);
    }
    allocator.free(evidence);
}

fn appendRetrievalWarnings(
    allocator: std.mem.Allocator,
    warnings: *std.ArrayList([]const u8),
    items: []const MessageResult,
    include_evidence: bool,
) !void {
    var weak_evidence = false;
    var historical = false;
    for (items) |item| {
        if (include_evidence and evidenceExpected(item.type) and item.evidence.len == 0) {
            weak_evidence = true;
        }
        if (item.validTo != null or std.mem.eql(u8, item.state, "superseded") or std.mem.eql(u8, item.state, "historical")) {
            historical = true;
        }
    }
    if (weak_evidence and !containsWarning(warnings.items, "weak_evidence")) {
        try warnings.append(allocator, "weak_evidence");
    }
    if (historical and !containsWarning(warnings.items, "historical_memory")) {
        try warnings.append(allocator, "historical_memory");
    }
}

fn buildScoreBreakdowns(allocator: std.mem.Allocator, items: []const MessageResult) ![]ScoreBreakdown {
    const breakdowns = try allocator.alloc(ScoreBreakdown, items.len);
    for (items, 0..) |item, index| {
        breakdowns[index] = .{
            .qid = item.qid,
            .type = item.type,
            .score = item.score,
            .lexical = normalizeScore(item.score),
            .temporal = temporalScore(item),
            .scope = 1.0,
            .confidence = item.confidence,
            .recency = recencyScore(item),
        };
    }
    return breakdowns;
}

fn buildScoringDetails(allocator: std.mem.Allocator, items: []const MessageResult) ![]ScoringDetail {
    const details = try allocator.alloc(ScoringDetail, items.len);
    for (items, 0..) |item, index| {
        details[index] = .{
            .qid = item.qid,
            .type = item.type,
            .finalScore = item.score,
            .lexical = normalizeScore(item.score),
            .temporal = temporalScore(item),
            .scope = 1.0,
            .confidence = item.confidence,
            .recency = recencyScore(item),
        };
    }
    return details;
}

fn buildDroppedItemReasons(allocator: std.mem.Allocator, dropped_for_needs: usize, dropped_for_budget: usize) ![]DroppedItemReason {
    var reasons = std.ArrayList(DroppedItemReason).empty;
    errdefer reasons.deinit(allocator);
    if (dropped_for_needs > 0) {
        try reasons.append(allocator, .{ .reason = "filtered_by_requested_needs", .count = dropped_for_needs });
    }
    if (dropped_for_budget > 0) {
        try reasons.append(allocator, .{ .reason = "dropped_for_token_budget", .count = dropped_for_budget });
    }
    return reasons.toOwnedSlice(allocator);
}

fn evidenceExpected(item_type: []const u8) bool {
    return std.mem.eql(u8, item_type, "fact") or
        std.mem.eql(u8, item_type, "preference") or
        std.mem.eql(u8, item_type, "procedure") or
        std.mem.eql(u8, item_type, "memory_card");
}

fn containsWarning(warnings: []const []const u8, expected: []const u8) bool {
    for (warnings) |warning| {
        if (std.mem.eql(u8, warning, expected)) return true;
    }
    return false;
}

fn stringListContains(values: []const []const u8, expected: []const u8) bool {
    for (values) |value| {
        if (std.mem.eql(u8, value, expected)) return true;
    }
    return false;
}

fn normalizeScore(score: f32) f32 {
    if (score <= 0) return 0;
    return score / (score + 1.0);
}

fn temporalScore(item: MessageResult) f32 {
    if (std.mem.eql(u8, item.state, "current")) return 1.0;
    if (std.mem.eql(u8, item.state, "superseded") or std.mem.eql(u8, item.state, "historical")) return 0.5;
    return 0.0;
}

fn recencyScore(item: MessageResult) f32 {
    return if (item.validFrom != null) 0.75 else 0.5;
}

/// ceil(text_bytes / 4.2) plus 16 tokens for the rendered line prefix, date
/// and speaker tags, and amortized session headers. Conversational English
/// averages about 4.5 bytes per o200k token on LongMemEval-S; 3.5 left a 4K
/// budget about a quarter empty.
fn estimateItemTokens(item: MessageResult) usize {
    return (item.text.len * 5 + 20) / 21 + 16 + eventTagTokens(item);
}

/// A line of the facts section: `[qid] (superseded, 2023-02-11 to 2023-05-30) text`.
/// The prefix is about 20 tokens; the text counts at the item estimator's rate.
fn estimateFactTokens(item: MessageResult) usize {
    return (item.text.len * 5 + 20) / 21 + 20;
}

/// factKeys: the ` [event 2023-03-03, ...]` tag on a raw line. Dates
/// tokenize at about 3 bytes per token. Zero for items without event dates.
fn eventTagTokens(item: MessageResult) usize {
    const source = item.raw_source orelse return 0;
    if (source.event_dates.len == 0) return 0;
    var bytes: usize = " [event ]".len;
    for (source.event_dates) |date| bytes += date.len + 2;
    return (bytes + 2) / 3;
}

/// ceil(prompt_bytes / 4.2): the item estimator's rate applied to the rendered
/// prompt, whose bytes already include line prefixes and session headers.
fn estimatePromptTokens(prompt: []const u8) usize {
    return @max(@as(usize, 1), (prompt.len * 5 + 20) / 21);
}

const PromptOptions = struct {
    /// Trusted question date (`time.validAt`). When set, a `Current date:` line
    /// is rendered above the untrusted memory block.
    current_date: ?[]const u8 = null,
    /// Temporal hints: each dated session header gains its offset from this
    /// date (`## session s07 2023-05-20 (Sat), 10 days ago`).
    hint_date: ?temporal.CivilDate = null,
    /// Resolved time references from the query, rendered as a
    /// `Time references:` line after `Current date:` (retrieve only; the
    /// answer path puts them in the reader's user turn).
    time_references: ?[]const u8 = null,
    /// The question and its trusted date. A session dated inside a time the
    /// question names says so in its header (`## session s07 2023-05-20
    /// (Sat): the question's "last Saturday"`), so the reader does not have
    /// to do the date arithmetic to find it.
    question: ?[]const u8 = null,
    question_date: ?temporal.CivilDate = null,
    /// `Title: summary` of summarised sessions, by session qid. A session
    /// header ends with its session's (`## session s07 2023-05-20 (Sat) |
    /// Trip planning: ...`).
    session_titles: ?*const std.StringHashMapUnmanaged([]const u8) = null,
};

/// Per-item rendering metadata read from the item's node. Every field is
/// optional so older nodes (no session or index properties) still render.
const RenderMeta = struct {
    role: ?[]const u8 = null,
    created_at: ?[]const u8 = null,
    session_qid: ?[]const u8 = null,
    session_id: ?[]const u8 = null,
    message_index: ?i64 = null,
    chunk_index: ?i64 = null,
    chunk_count: ?i64 = null,
};

const RenderEntry = struct {
    item: MessageResult,
    rank: usize,
    meta: RenderMeta = .{},
};

const RenderGroup = struct {
    key: ?[]const u8,
    members: std.ArrayList(usize) = .empty,
    date: ?[]const u8 = null,
    first_session_qid: ?[]const u8 = null,
    first_rank: usize,
};

/// Renders the reader-facing memory context. Derived memory (core, facts,
/// preferences, procedures) gets its own sections with state and validity
/// dates; raw evidence is grouped by session, sessions in chronological order,
/// items by message index then chunk index. Output is deterministic for a
/// given context. `store` supplies session/role/index metadata; without it the
/// renderer falls back to what the items carry.
fn promptFromContext(allocator: std.mem.Allocator, store: ?storage.Adapter, context: ContextPacket, options: PromptOptions) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const entries = try arena.alloc(RenderEntry, context.episodes.len);
    var session_ids = std.StringHashMap(?[]const u8).init(arena);
    for (context.episodes, 0..) |item, rank| {
        entries[rank] = .{
            .item = item,
            .rank = rank,
            .meta = if (store) |adapter| try loadRenderMeta(arena, adapter, item, &session_ids) else .{ .created_at = item.validFrom },
        };
    }
    return renderPrompt(allocator, arena, context, entries, options);
}

fn renderPrompt(
    allocator: std.mem.Allocator,
    arena: std.mem.Allocator,
    context: ContextPacket,
    entries: []const RenderEntry,
    options: PromptOptions,
) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    const out = &writer.writer;
    if (options.current_date) |timestamp| {
        const formatted = try formatCurrentDate(arena, timestamp);
        try out.print("Current date: {s}\n", .{formatted});
        if (options.time_references) |references| try out.print("Time references: {s}\n", .{references});
    }
    try out.writeAll("<memory>");
    try writePromptSection(arena, out, "core", context.core);
    try writePromptSection(arena, out, "facts", context.currentFacts);
    try writePromptSection(arena, out, "preferences", context.preferences);
    try writePromptSection(arena, out, "procedures", context.procedural);
    try writePromptSection(arena, out, "patterns", context.patterns);
    try writeThreadSection(out, context.threads);
    const named_times: []const temporal.NamedTime = if (options.question_date) |date|
        try temporal.resolveNamedTimes(arena, options.question orelse "", date)
    else
        &.{};
    try writeSessionSection(arena, out, entries, options.hint_date, named_times, options.session_titles);
    try out.writeAll("\n</memory>");
    return writer.toOwnedSlice();
}

/// Derived items: `[qid] (state, from A to B) text`, oldest validity first.
/// A claim (`options.facts`) is listed under the qid of the message it was
/// drawn from, which is shorter and is what a reader should cite, and a
/// section holding claims opens with `facts_legend`.
fn writePromptSection(arena: std.mem.Allocator, out: *std.Io.Writer, name: []const u8, items: []const MessageResult) !void {
    if (items.len == 0) return;
    const order = try arena.alloc(usize, items.len);
    for (order, 0..) |*slot, index| slot.* = index;
    std.mem.sort(usize, order, items, derivedRendersBefore);

    try out.print("\n<{s}>", .{name});
    for (items) |item| {
        if (!std.mem.startsWith(u8, item.qid, assertion_qid_prefix)) continue;
        try out.writeAll("\n" ++ facts_legend);
        break;
    }
    for (order) |index| {
        const item = items[index];
        const shown_qid = if (std.mem.startsWith(u8, item.qid, assertion_qid_prefix) and item.evidence.len > 0) item.evidence[0].qid else item.qid;
        try out.print("\n[{s}] ({s}", .{ shown_qid, item.state });
        if (item.validFrom) |from| {
            if (item.validTo) |to| {
                try out.print(", {s} to {s}", .{ dateKey(from), dateKey(to) });
            } else {
                try out.print(", from {s}", .{dateKey(from)});
            }
        } else if (item.validTo) |to| {
            try out.print(", until {s}", .{dateKey(to)});
        }
        try out.writeAll(") ");
        try writeItemText(out, item.text);
    }
    try out.print("\n</{s}>", .{name});
}

/// The threads section: a note on how to read it, then each topic as
/// `## Title: summary` over its facts, and the facts outside a topic under
/// the heading they were collected with. Items are written in the order
/// given.
fn writeThreadSection(out: *std.Io.Writer, items: []const MessageResult) !void {
    if (items.len == 0) return;
    try out.writeAll("\n<threads>\n" ++ summaries.threads_note);
    var heading: ?[]const u8 = null;
    for (items) |item| {
        const block = item.thread orelse continue;
        const is_topic = std.mem.eql(u8, item.type, "summary");
        const continues = !is_topic and heading != null and std.mem.eql(u8, heading.?, block.heading);
        if (!continues) {
            try out.writeAll("\n## ");
            try writeItemText(out, block.heading);
        }
        heading = if (is_topic) null else block.heading;
        for (block.lines) |line| {
            try out.writeByte('\n');
            try writeItemText(out, line);
        }
    }
    try out.writeAll("\n</threads>");
}

fn derivedRendersBefore(items: []const MessageResult, left: usize, right: usize) bool {
    const left_from = items[left].validFrom;
    const right_from = items[right].validFrom;
    if (left_from == null and right_from != null) return true;
    if (left_from != null and right_from == null) return false;
    if (left_from != null and right_from != null and !std.mem.eql(u8, left_from.?, right_from.?)) {
        return std.mem.order(u8, left_from.?, right_from.?) == .lt;
    }
    return left < right;
}

/// Raw evidence grouped by session:
/// `## session <id> YYYY-MM-DD (Ddd)` then `[qid] speaker: text` lines. A line
/// repeats its date only when it differs from the session date. Items without
/// a session go last under `## other`. With a `hint_date`, a dated header ends
/// with its offset from that date (`, 10 days ago`).
fn writeSessionSection(
    arena: std.mem.Allocator,
    out: *std.Io.Writer,
    entries: []const RenderEntry,
    hint_date: ?temporal.CivilDate,
    named_times: []const temporal.NamedTime,
    session_titles: ?*const std.StringHashMapUnmanaged([]const u8),
) !void {
    if (entries.len == 0) return;
    var groups = std.ArrayList(RenderGroup).empty;
    for (entries, 0..) |entry, index| {
        const key = entry.meta.session_id orelse entry.meta.session_qid;
        const group = for (groups.items) |*existing| {
            if (optionalStringsEqual(existing.key, key)) break existing;
        } else blk: {
            try groups.append(arena, .{ .key = key, .first_rank = entry.rank });
            break :blk &groups.items[groups.items.len - 1];
        };
        try group.members.append(arena, index);
        group.first_rank = @min(group.first_rank, entry.rank);
        if (entry.meta.created_at) |created_at| {
            if (group.date == null or std.mem.order(u8, created_at, group.date.?) == .lt) group.date = created_at;
        }
        if (entry.meta.session_qid) |session_qid| {
            if (group.first_session_qid == null or naturalQidOrder(session_qid, group.first_session_qid.?) == .lt) {
                group.first_session_qid = session_qid;
            }
        }
    }
    for (groups.items) |group| {
        std.mem.sort(usize, group.members.items, entries, entryRendersBefore);
    }
    std.mem.sort(RenderGroup, groups.items, {}, groupRendersBefore);

    try out.writeAll("\n<sessions>");
    for (groups.items) |group| {
        const header_date: ?[]const u8 = if (group.date) |date| dateKey(date) else null;
        if (group.key) |key| {
            try out.print("\n## session {s}", .{key});
            if (group.date) |date| {
                if (parseIsoDate(date)) |civil| {
                    try out.print(" {s} ({s})", .{ dateKey(date), weekdayName(civil)[0..3] });
                    if (hint_date) |current| {
                        try out.writeAll(", ");
                        try temporal.writeOffset(out, civil, current);
                    }
                    for (named_times) |time| {
                        const window = time.window orelse continue;
                        if (!temporal.windowContains(window, civil)) continue;
                        try out.print(": {s} the question's \"{s}\"", .{ switch (time.relation(civil)) {
                            .is => "this is",
                            .near => "near",
                            .within => "within",
                        }, time.phrase });
                        break;
                    }
                } else |_| {
                    try out.print(" {s}", .{date});
                }
            }
            if (session_titles) |titles| {
                if (group.first_session_qid) |session_qid| {
                    if (titles.get(session_qid)) |title| {
                        if (title.len > 0) {
                            try out.writeAll(" | ");
                            try writeItemText(out, title);
                        }
                    }
                }
            }
        } else {
            try out.writeAll("\n## other");
        }
        for (group.members.items) |index| {
            const entry = entries[index];
            try out.print("\n[{s}]", .{entry.item.qid});
            var labelled = false;
            if (entry.meta.created_at) |created_at| {
                const line_date = dateKey(created_at);
                if (group.key == null or header_date == null or !std.mem.eql(u8, line_date, header_date.?)) {
                    try out.print(" {s}", .{line_date});
                    labelled = true;
                }
            }
            if (entry.meta.role) |role| {
                try out.print(" {s}", .{role});
                labelled = true;
            }
            if (entry.meta.chunk_count) |count| {
                if (count > 1) {
                    if (entry.meta.chunk_index) |chunk_index| {
                        try out.print(" ({d}/{d})", .{ chunk_index + 1, count });
                        labelled = true;
                    }
                }
            }
            if (entry.item.raw_source) |source| {
                if (source.event_dates.len > 0) {
                    try out.writeAll(" [event ");
                    for (source.event_dates, 0..) |date, date_index| {
                        if (date_index > 0) try out.writeAll(", ");
                        try out.writeAll(date);
                    }
                    try out.writeByte(']');
                    labelled = true;
                }
            }
            try out.writeAll(if (labelled) ": " else " ");
            try writeItemText(out, entry.item.text);
        }
    }
    try out.writeAll("\n</sessions>");
}

fn entryRendersBefore(entries: []const RenderEntry, left_index: usize, right_index: usize) bool {
    const left = entries[left_index];
    const right = entries[right_index];
    if (orderOptionalQid(left.meta.session_qid, right.meta.session_qid)) |order| return order == .lt;
    if (orderOptionalInt(left.meta.message_index, right.meta.message_index)) |order| return order == .lt;
    if (orderOptionalInt(left.meta.chunk_index, right.meta.chunk_index)) |order| return order == .lt;
    if (orderOptionalString(left.meta.created_at, right.meta.created_at)) |order| return order == .lt;
    const qid_order = naturalQidOrder(left.item.qid, right.item.qid);
    if (qid_order != .eq) return qid_order == .lt;
    return left.rank < right.rank;
}

fn groupRendersBefore(_: void, left: RenderGroup, right: RenderGroup) bool {
    if ((left.key == null) != (right.key == null)) return right.key == null;
    if (orderOptionalString(left.date, right.date)) |order| return order == .lt;
    if (orderOptionalQid(left.first_session_qid, right.first_session_qid)) |order| return order == .lt;
    if (orderOptionalString(left.key, right.key)) |order| return order == .lt;
    return left.first_rank < right.first_rank;
}

/// Present values sort before missing ones; null means "tied".
fn orderOptionalString(left: ?[]const u8, right: ?[]const u8) ?std.math.Order {
    if (left == null and right == null) return null;
    if (left == null) return .gt;
    if (right == null) return .lt;
    const order = std.mem.order(u8, left.?, right.?);
    return if (order == .eq) null else order;
}

fn orderOptionalQid(left: ?[]const u8, right: ?[]const u8) ?std.math.Order {
    if (left == null and right == null) return null;
    if (left == null) return .gt;
    if (right == null) return .lt;
    const order = naturalQidOrder(left.?, right.?);
    return if (order == .eq) null else order;
}

fn orderOptionalInt(left: ?i64, right: ?i64) ?std.math.Order {
    if (left == null and right == null) return null;
    if (left == null) return .gt;
    if (right == null) return .lt;
    const order = std.math.order(left.?, right.?);
    return if (order == .eq) null else order;
}

/// Natural order: digit runs compare numerically, so `q_msg_9` sorts before
/// `q_msg_10` and `q_chunk_9_1` before `q_chunk_10_0`.
fn naturalQidOrder(left: []const u8, right: []const u8) std.math.Order {
    var i: usize = 0;
    var j: usize = 0;
    while (i < left.len and j < right.len) {
        if (std.ascii.isDigit(left[i]) and std.ascii.isDigit(right[j])) {
            const left_end = digitRunEnd(left, i);
            const right_end = digitRunEnd(right, j);
            const left_digits = std.mem.trimStart(u8, left[i..left_end], "0");
            const right_digits = std.mem.trimStart(u8, right[j..right_end], "0");
            if (left_digits.len != right_digits.len) return std.math.order(left_digits.len, right_digits.len);
            const digit_order = std.mem.order(u8, left_digits, right_digits);
            if (digit_order != .eq) return digit_order;
            i = left_end;
            j = right_end;
            continue;
        }
        if (left[i] != right[j]) return std.math.order(left[i], right[j]);
        i += 1;
        j += 1;
    }
    const tail_order = std.math.order(left.len - i, right.len - j);
    if (tail_order != .eq) return tail_order;
    return std.mem.order(u8, left, right);
}

fn digitRunEnd(text: []const u8, start: usize) usize {
    var index = start;
    while (index < text.len and std.ascii.isDigit(text[index])) : (index += 1) {}
    return index;
}

fn optionalStringsEqual(left: ?[]const u8, right: ?[]const u8) bool {
    if (left == null or right == null) return left == null and right == null;
    return std.mem.eql(u8, left.?, right.?);
}

/// `YYYY-MM-DD` when the timestamp starts with a valid ISO date, else as given.
fn dateKey(timestamp: []const u8) []const u8 {
    _ = parseIsoDate(timestamp) catch return timestamp;
    return timestamp[0..10];
}

/// Writes item text on one line: whitespace runs collapse to a single space
/// and context section tags inside memory text are defanged so stored text
/// cannot close or forge a section.
fn writeItemText(out: *std.Io.Writer, raw: []const u8) !void {
    const text = std.mem.trim(u8, raw, " \t\r\n");
    var pending_space = false;
    var index: usize = 0;
    while (index < text.len) {
        const byte = text[index];
        if (byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n') {
            pending_space = true;
            index += 1;
            continue;
        }
        if (pending_space) {
            try out.writeByte(' ');
            pending_space = false;
        }
        if (byte == '<') {
            if (contextTagLength(text[index..])) |tag_len| {
                try out.writeByte('[');
                try out.writeAll(text[index + 1 .. index + tag_len - 1]);
                try out.writeByte(']');
                index += tag_len;
                continue;
            }
        }
        try out.writeByte(byte);
        index += 1;
    }
}

fn contextTagLength(text: []const u8) ?usize {
    const names = [_][]const u8{ "memory", "sessions", "core", "facts", "preferences", "procedures" };
    var cursor: usize = 1;
    if (cursor < text.len and text[cursor] == '/') cursor += 1;
    for (names) |name| {
        const end = cursor + name.len;
        if (end < text.len and std.ascii.eqlIgnoreCase(text[cursor..end], name) and text[end] == '>') return end + 1;
    }
    return null;
}

fn loadRenderMeta(
    arena: std.mem.Allocator,
    store: storage.Adapter,
    item: MessageResult,
    session_ids: *std.StringHashMap(?[]const u8),
) !RenderMeta {
    var meta = RenderMeta{ .created_at = item.validFrom };
    if (item.raw_source) |source| {
        // Message and chunk items carry their source fields; no node lookup.
        meta.role = source.role;
        meta.created_at = source.created_at orelse item.validFrom;
        meta.session_id = source.session_id;
        meta.session_qid = source.session_qid orelse
            sessionQidFromTurn(arena, store, source.turn_qid) orelse
            sessionQidFromEdges(arena, store, source.message_qid);
        meta.message_index = source.message_index;
        meta.chunk_index = source.chunk_index;
        meta.chunk_count = source.chunk_count;
    } else {
        const node = (store.getNode(arena, item.qid) catch null) orelse return meta;
        meta.role = defaultRoleForLabel(node.label);
        const props = parsePropertiesObject(arena, node.properties_json) orelse return meta;
        meta.role = jsonObjectString(props, "role") orelse meta.role;
        meta.created_at = jsonObjectString(props, "createdAt") orelse jsonObjectString(props, "eventTime") orelse item.validFrom;
        meta.session_id = jsonObjectString(props, "sessionId");
        meta.message_index = jsonObjectInt(props, "messageIndex");
        meta.chunk_index = jsonObjectInt(props, "chunkIndex");
        meta.chunk_count = jsonObjectInt(props, "chunkCount");
        meta.session_qid = jsonObjectString(props, "sessionQid") orelse
            sessionQidFromTurn(arena, store, jsonObjectString(props, "turnQid")) orelse
            sessionQidFromEdges(arena, store, node.qid);
    }
    if (meta.session_id == null) {
        if (meta.session_qid) |session_qid| {
            if (session_ids.get(session_qid)) |cached| {
                meta.session_id = cached;
            } else {
                const session_props = nodeProperties(arena, store, session_qid);
                meta.session_id = if (session_props) |session| jsonObjectString(session, "sessionId") else null;
                try session_ids.put(session_qid, meta.session_id);
            }
        }
    }
    return meta;
}

fn sessionQidFromTurn(arena: std.mem.Allocator, store: storage.Adapter, turn_qid: ?[]const u8) ?[]const u8 {
    const qid = turn_qid orelse return null;
    const turn_props = nodeProperties(arena, store, qid) orelse return null;
    return jsonObjectString(turn_props, "sessionQid");
}

/// Nodes written before session properties existed: follow the Turn that owns
/// them through a HAS_* edge.
fn sessionQidFromEdges(arena: std.mem.Allocator, store: storage.Adapter, qid: []const u8) ?[]const u8 {
    const edges = store.findEdges(arena, .{ .to_qid = qid, .limit = 64 }) catch return null;
    for (edges) |edge| {
        if (!std.mem.eql(u8, edge.edge_type, "HAS_MESSAGE") and
            !std.mem.eql(u8, edge.edge_type, "HAS_TOOL_CALL") and
            !std.mem.eql(u8, edge.edge_type, "HAS_OBSERVATION")) continue;
        if (sessionQidFromTurn(arena, store, edge.from_qid)) |session_qid| return session_qid;
    }
    return null;
}

fn nodeProperties(arena: std.mem.Allocator, store: storage.Adapter, qid: []const u8) ?std.json.ObjectMap {
    const node = (store.getNode(arena, qid) catch return null) orelse return null;
    return parsePropertiesObject(arena, node.properties_json);
}

fn parsePropertiesObject(arena: std.mem.Allocator, properties_json: []const u8) ?std.json.ObjectMap {
    const value = std.json.parseFromSliceLeaky(Value, arena, properties_json, .{}) catch return null;
    return switch (value) {
        .object => |object| object,
        else => null,
    };
}

fn jsonObjectString(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    return switch (object.get(key) orelse return null) {
        .string => |string| if (string.len > 0) string else null,
        else => null,
    };
}

fn jsonObjectInt(object: std.json.ObjectMap, key: []const u8) ?i64 {
    return switch (object.get(key) orelse return null) {
        .integer => |integer| integer,
        else => null,
    };
}

fn defaultRoleForLabel(label: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, label, "Episode")) return "summary";
    if (std.mem.eql(u8, label, "MemoryCard")) return "note";
    if (std.mem.eql(u8, label, "ToolCall")) return "tool";
    if (std.mem.eql(u8, label, "Observation")) return "observation";
    if (std.mem.eql(u8, label, "Feedback")) return "feedback";
    return null;
}

fn idempotencyQid(allocator: std.mem.Allocator, key: []const u8) ![]u8 {
    var out = try allocator.alloc(u8, "q_idem_".len + key.len);
    @memcpy(out[0.."q_idem_".len], "q_idem_");
    for (key, 0..) |byte, index| {
        out["q_idem_".len + index] = if (std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-') byte else '_';
    }
    return out;
}

fn hashQid(allocator: std.mem.Allocator, prefix: []const u8, key: []const u8) ![]u8 {
    const hash = std.hash.Wyhash.hash(2, key);
    return std.fmt.allocPrint(allocator, "q_{s}_{x}", .{ prefix, hash });
}

fn entityQid(allocator: std.mem.Allocator, scope: Scope, entity: providers.ResolvedEntity) ![]u8 {
    const normalized_name = try normalizedEntityKey(allocator, entity.name);
    defer allocator.free(normalized_name);
    const normalized_type = try normalizedEntityKey(allocator, entity.entity_type);
    defer allocator.free(normalized_type);
    const key = try std.fmt.allocPrint(
        allocator,
        "tenant={s}|user={s}|agent={s}|project={s}|type={s}|name={s}",
        .{
            scope.tenant_id orelse "",
            scope.user_id orelse "",
            scope.agent_id orelse "",
            scope.project_id orelse "",
            normalized_type,
            normalized_name,
        },
    );
    defer allocator.free(key);
    return hashQid(allocator, "ent", key);
}

fn entitySearchText(allocator: std.mem.Allocator, entity: providers.ResolvedEntity) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    try writer.writer.writeAll(entity.name);
    for (entity.aliases) |alias| {
        try writer.writer.writeByte(' ');
        try writer.writer.writeAll(alias);
    }
    return writer.toOwnedSlice();
}

fn normalizedEntityKey(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    var wrote_any = false;
    var pending_separator = false;
    for (raw) |byte| {
        if (std.ascii.isAlphanumeric(byte)) {
            if (pending_separator and wrote_any) {
                try writer.writer.writeByte('_');
            }
            try writer.writer.writeByte(std.ascii.toLower(byte));
            wrote_any = true;
            pending_separator = false;
        } else {
            pending_separator = true;
        }
    }
    return writer.toOwnedSlice();
}

fn memoryCardKind(label: extractor.Label) []const u8 {
    return switch (label) {
        .fact => "semantic",
        .preference => "preference",
        .procedure => "procedural",
    };
}

fn cardContextualDescription(candidate: extractor.Candidate) []const u8 {
    if (std.mem.eql(u8, candidate.slot_key, "project.package_manager")) {
        return "Repository package manager preference extracted from user-provided project evidence.";
    }
    if (std.mem.eql(u8, candidate.slot_key, "project.test_command")) {
        return "Repository verification command extracted from user-provided project evidence.";
    }
    if (std.mem.eql(u8, candidate.slot_key, "project.repo_style")) {
        return "Repository implementation style extracted from project guidance.";
    }
    if (std.mem.eql(u8, candidate.slot_key, "project.constraint")) {
        return "Project invariant extracted from contributor or user guidance.";
    }
    if (std.mem.eql(u8, candidate.slot_key, "user.response_style")) {
        return "User communication preference extracted from conversation evidence.";
    }
    return "Memory card generated from evidence-linked deterministic extraction.";
}

fn cardKeywords(candidate: extractor.Candidate) []const []const u8 {
    if (std.mem.eql(u8, candidate.slot_key, "project.package_manager")) return &card_keywords_package_manager;
    if (std.mem.eql(u8, candidate.slot_key, "project.test_command")) return &card_keywords_test_command;
    if (std.mem.eql(u8, candidate.slot_key, "project.repo_style")) return &card_keywords_repo_style;
    if (std.mem.eql(u8, candidate.slot_key, "project.constraint")) return &card_keywords_project_constraint;
    if (std.mem.eql(u8, candidate.slot_key, "user.response_style")) return &card_keywords_response_style;
    return &card_keywords_generic;
}

fn cardTags(candidate: extractor.Candidate) []const []const u8 {
    return switch (candidate.label) {
        .fact => &card_tags_fact,
        .preference => &card_tags_preference,
        .procedure => &card_tags_procedure,
    };
}

fn cardImportance(candidate: extractor.Candidate) f32 {
    if (std.mem.eql(u8, candidate.slot_key, "project.constraint")) return 0.9;
    if (std.mem.eql(u8, candidate.slot_key, "project.test_command")) return 0.8;
    if (std.mem.eql(u8, candidate.slot_key, "project.package_manager")) return 0.75;
    if (std.mem.eql(u8, candidate.slot_key, "user.response_style")) return 0.65;
    return 0.6;
}

fn freeHits(allocator: std.mem.Allocator, hits: []storage.SearchHit) void {
    for (hits) |hit| allocator.free(hit.qid);
    allocator.free(hits);
}

fn freeStreamEntries(allocator: std.mem.Allocator, entries: []storage.StreamEntry) void {
    for (entries) |entry| {
        allocator.free(entry.stream);
        allocator.free(entry.payload_json);
    }
    allocator.free(entries);
}

/// Drops Assertion hits from one search channel. Returns the remaining hits
/// (at most `limit`) and frees `hits`, or returns null when assertions left
/// the channel short and it may hold more: the caller then asks for more than
/// `requested`. A channel with no assertion hits comes back unchanged.
fn withoutAssertionHits(allocator: std.mem.Allocator, hits: []storage.SearchHit, requested: usize, limit: usize) !?[]storage.SearchHit {
    var kept: usize = 0;
    for (hits) |hit| {
        if (!std.mem.startsWith(u8, hit.qid, assertion_qid_prefix)) kept += 1;
    }
    if (kept == hits.len and hits.len <= limit) return hits;
    if (kept < limit and hits.len >= requested) {
        freeHits(allocator, hits);
        return null;
    }
    const result = try allocator.alloc(storage.SearchHit, @min(kept, limit));
    var written: usize = 0;
    for (hits) |hit| {
        if (written < result.len and !std.mem.startsWith(u8, hit.qid, assertion_qid_prefix)) {
            result[written] = hit;
            written += 1;
        } else {
            allocator.free(hit.qid);
        }
    }
    allocator.free(hits);
    return result;
}

/// Reciprocal-rank fusion (k = 60) of several channels. RRF is rank based,
/// so each channel is put in descending score order before its ranks count.
/// Returns at most `limit` fused hits, sorted by fused score.
fn fuseRankedHits(allocator: std.mem.Allocator, channels: []const []storage.SearchHit, limit: usize) ![]storage.SearchHit {
    var merged = std.ArrayList(storage.SearchHit).empty;
    errdefer {
        for (merged.items) |hit| allocator.free(hit.qid);
        merged.deinit(allocator);
    }
    for (channels) |channel| {
        sortHitsByScore(channel);
        try appendRrfHits(allocator, &merged, channel, 1.0);
    }
    sortHitsByScore(merged.items);
    if (merged.items.len > limit) {
        for (merged.items[limit..]) |hit| allocator.free(hit.qid);
        merged.shrinkRetainingCapacity(limit);
    }
    return merged.toOwnedSlice(allocator);
}

fn appendRrfHits(allocator: std.mem.Allocator, merged: *std.ArrayList(storage.SearchHit), hits: []const storage.SearchHit, weight: f32) !void {
    for (hits, 0..) |hit, rank| {
        const fused_score = weight * reciprocalRank(rank);
        try appendHitScore(allocator, merged, hit.qid, fused_score);
    }
}

fn appendHitScore(allocator: std.mem.Allocator, merged: *std.ArrayList(storage.SearchHit), qid_value: []const u8, score: f32) !void {
    if (indexOfHit(merged.items, qid_value)) |index| {
        merged.items[index].score += score;
        return;
    }
    const qid = try allocator.dupe(u8, qid_value);
    errdefer allocator.free(qid);
    try merged.append(allocator, .{ .qid = qid, .score = score });
}

fn indexOfHit(hits: []const storage.SearchHit, qid: []const u8) ?usize {
    for (hits, 0..) |hit, index| {
        if (std.mem.eql(u8, hit.qid, qid)) return index;
    }
    return null;
}

fn reciprocalRank(rank: usize) f32 {
    return 1.0 / @as(f32, @floatFromInt(60 + rank + 1));
}

/// Stable sort by descending score, so ties keep their incoming order.
fn sortHitsByScore(hits: []storage.SearchHit) void {
    std.mem.sort(storage.SearchHit, hits, {}, hitRanksBefore);
}

fn hitRanksBefore(_: void, left: storage.SearchHit, right: storage.SearchHit) bool {
    return left.score > right.score;
}

fn stringifyAlloc(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    try std.json.Stringify.value(value, .{}, &writer.writer);
    return writer.toOwnedSlice();
}

/// End offset of each chunk of `content`. Chunks are contiguous, so slicing at
/// these offsets reassembles the original bytes exactly. Content at or under
/// `message_chunk_max_bytes` yields a single end (no chunking).
fn messageChunkEnds(allocator: std.mem.Allocator, content: []const u8) ![]usize {
    var ends = std.ArrayList(usize).empty;
    errdefer ends.deinit(allocator);
    var start: usize = 0;
    while (content.len - start > message_chunk_max_bytes) {
        const end = chunkBoundary(content, start);
        try ends.append(allocator, end);
        start = end;
    }
    try ends.append(allocator, content.len);
    return ends.toOwnedSlice(allocator);
}

/// Picks a chunk end within the last `message_chunk_boundary_window` bytes
/// before the hard limit, preferring a paragraph break, then a sentence or
/// line end, then whitespace. Never splits a UTF-8 codepoint. Requires
/// `content.len - start > message_chunk_max_bytes`.
fn chunkBoundary(content: []const u8, start: usize) usize {
    var hard_end = start + message_chunk_max_bytes;
    var backoff: usize = 0;
    while (backoff < 3 and hard_end > start + 1 and isUtf8Continuation(content[hard_end])) : (backoff += 1) {
        hard_end -= 1;
    }
    const window_start = if (hard_end - start > message_chunk_boundary_window)
        hard_end - message_chunk_boundary_window
    else
        start + 1;
    const window = content[window_start..hard_end];

    if (std.mem.lastIndexOf(u8, window, "\n\n")) |index| return window_start + index + 2;

    var index = window.len;
    while (index > 0) {
        index -= 1;
        const byte = window[index];
        if (byte == '\n') return window_start + index + 1;
        if ((byte == '.' or byte == '!' or byte == '?') and index + 1 < window.len and isAsciiWhitespace(window[index + 1])) {
            return window_start + index + 2;
        }
    }

    index = window.len;
    while (index > 0) {
        index -= 1;
        if (isAsciiWhitespace(window[index])) return window_start + index + 1;
    }
    return hard_end;
}

fn isUtf8Continuation(byte: u8) bool {
    return byte & 0xC0 == 0x80;
}

fn isAsciiWhitespace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r';
}

/// Generic chat roles. Any other role is taken to be a speaker's name, as in
/// multi-party transcripts where each line's role is the person speaking.
const generic_message_roles = [_][]const u8{ "user", "assistant", "system", "tool", "developer", "function" };

fn speakerNamesRole(role: []const u8) bool {
    if (std.mem.trim(u8, role, " \t\r\n").len == 0) return false;
    for (generic_message_roles) |generic| {
        if (std.ascii.eqlIgnoreCase(role, generic)) return false;
    }
    return true;
}

/// `Role: text` when the role names a speaker, so the speaker's own lines
/// match searches for their name; null for generic roles, whose nodes are
/// indexed by `content` as before.
fn speakerSearchText(allocator: std.mem.Allocator, role: []const u8, text: []const u8) !?[]u8 {
    if (!speakerNamesRole(role)) return null;
    return try std.fmt.allocPrint(allocator, "{s}: {s}", .{ role, text });
}

/// Returns `props_json` with a leading `searchText` field when the role names
/// a speaker, otherwise an unchanged copy.
fn withSpeakerSearchText(allocator: std.mem.Allocator, props_json: []const u8, role: []const u8, text: []const u8) ![]u8 {
    const search_text = (try speakerSearchText(allocator, role, text)) orelse return allocator.dupe(u8, props_json);
    defer allocator.free(search_text);
    std.debug.assert(props_json.len >= 2 and props_json[0] == '{');
    const encoded = try stringifyAlloc(allocator, search_text);
    defer allocator.free(encoded);
    const separator: []const u8 = if (props_json.len > 2) "," else "";
    return std.fmt.allocPrint(allocator, "{{\"searchText\":{s}{s}{s}", .{ encoded, separator, props_json[1..] });
}

fn appendIndexText(
    allocator: std.mem.Allocator,
    texts: *std.ArrayList([]const u8),
    owned: *std.ArrayList([]u8),
    role: []const u8,
    text: []const u8,
) !void {
    if (try speakerSearchText(allocator, role, text)) |search_text| {
        errdefer allocator.free(search_text);
        try owned.append(allocator, search_text);
        try texts.append(allocator, search_text);
    } else {
        try texts.append(allocator, text);
    }
}

fn chunkQid(allocator: std.mem.Allocator, message_qid: []const u8, chunk_index: usize) ![]u8 {
    const suffix = if (std.mem.startsWith(u8, message_qid, "q_msg_")) message_qid["q_msg_".len..] else message_qid;
    return std.fmt.allocPrint(allocator, "q_chunk_{s}_{d}", .{ suffix, chunk_index });
}

fn clampPropertyText(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    if (value.len <= property_text_max_bytes) return allocator.dupe(u8, value);

    const prefix_limit = property_text_max_bytes - property_truncation_marker.len;
    const prefix_len = utf8PrefixLen(value, prefix_limit);
    const clamped = try allocator.alloc(u8, prefix_len + property_truncation_marker.len);
    @memcpy(clamped[0..prefix_len], value[0..prefix_len]);
    @memcpy(clamped[prefix_len..], property_truncation_marker);
    return clamped;
}

fn utf8PrefixLen(value: []const u8, max_bytes: usize) usize {
    var index: usize = 0;
    while (index < value.len and index < max_bytes) {
        const codepoint_len = std.unicode.utf8ByteSequenceLength(value[index]) catch return index;
        if (index + codepoint_len > max_bytes or index + codepoint_len > value.len) break;
        index += codepoint_len;
    }
    return index;
}

fn errorResponse(allocator: std.mem.Allocator, id: ?[]const u8, code: []const u8, message: []const u8) ![]u8 {
    const response = .{
        .jsonrpc = "2.0",
        .id = id,
        .@"error" = .{
            .code = code,
            .message = message,
            .details = .{},
        },
    };
    return stringifyAlloc(allocator, response);
}

var runtime_test_db_counter = std.atomic.Value(u64).init(0);

const RuntimeTestHarness = if (build_options.enable_lattice) struct {
    allocator: std.mem.Allocator,
    tmp_dir: std.testing.TmpDir,
    db_path: []u8,
    adapter_state: lattice_storage.LatticeAdapter,
    health_value: protocol.Health,

    fn init(allocator: std.mem.Allocator) !RuntimeTestHarness {
        var tmp_dir = std.testing.tmpDir(.{});
        errdefer tmp_dir.cleanup();
        const id = runtime_test_db_counter.fetchAdd(1, .monotonic);
        const db_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/quipu-runtime-test-{d}.lattice", .{ tmp_dir.sub_path[0..], id });
        errdefer allocator.free(db_path);

        var adapter_state = try lattice_storage.LatticeAdapter.open(allocator, db_path, .{ .io = std.testing.io });
        errdefer adapter_state.deinit();
        try schema.ensure(allocator, adapter_state.adapter());

        var health_value = protocol.Health.default();
        health_value.db_path = db_path;
        health_value.lattice_version = lattice_storage.LatticeAdapter.latticeVersion();
        return .{
            .allocator = allocator,
            .tmp_dir = tmp_dir,
            .db_path = db_path,
            .adapter_state = adapter_state,
            .health_value = health_value,
        };
    }

    fn deinit(self: *RuntimeTestHarness) void {
        self.adapter_state.deinit();
        self.tmp_dir.cleanup();
        self.allocator.free(self.db_path);
    }

    fn adapter(self: *RuntimeTestHarness) storage.Adapter {
        return self.adapter_state.adapter();
    }

    fn health(self: *RuntimeTestHarness) protocol.Health {
        return self.health_value;
    }
} else struct {
    adapter_state: in_memory_storage.InMemoryAdapter,

    fn init(allocator: std.mem.Allocator) !RuntimeTestHarness {
        return .{ .adapter_state = in_memory_storage.InMemoryAdapter.init(allocator) };
    }

    fn deinit(self: *RuntimeTestHarness) void {
        self.adapter_state.deinit();
    }

    fn adapter(self: *RuntimeTestHarness) storage.Adapter {
        return self.adapter_state.adapter();
    }

    fn health(_: *RuntimeTestHarness) protocol.Health {
        return protocol.Health.default();
    }
};

test "runtime remembers and searches scoped raw messages" {
    var harness = try RuntimeTestHarness.init(std.testing.allocator);
    defer harness.deinit();
    var runtime = Runtime.init(harness.adapter(), harness.health());
    defer runtime.deinit();

    const remember = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"r1\",\"method\":\"memory.remember\",\"params\":{\"scope\":{\"projectId\":\"repo:test\"},\"messages\":[{\"role\":\"user\",\"content\":\"Use pnpm for this repo.\"}],\"extract\":false}}",
    );
    defer std.testing.allocator.free(remember);
    try std.testing.expect(std.mem.indexOf(u8, remember, "\"status\":\"stored\"") != null);

    const search = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"s1\",\"method\":\"memory.search\",\"params\":{\"query\":\"pnpm\",\"scope\":{\"projectId\":\"repo:test\"}}}",
    );
    defer std.testing.allocator.free(search);
    try std.testing.expect(std.mem.indexOf(u8, search, "Use pnpm for this repo.") != null);
}

test "runtime health includes storage capabilities" {
    var harness = try RuntimeTestHarness.init(std.testing.allocator);
    defer harness.deinit();
    var runtime = Runtime.init(harness.adapter(), harness.health());
    defer runtime.deinit();

    const health = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"h1\",\"method\":\"system.health\",\"params\":{}}",
    );
    defer std.testing.allocator.free(health);

    try std.testing.expect(std.mem.indexOf(u8, health, "\"storage\"") != null);
    if (build_options.enable_lattice) {
        try std.testing.expect(std.mem.indexOf(u8, health, "\"backend\":\"lattice\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, health, "\"durable\":true") != null);
        try std.testing.expect(std.mem.indexOf(u8, health, "\"vector\":true") != null);
    } else {
        try std.testing.expect(std.mem.indexOf(u8, health, "\"backend\":\"memory\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, health, "\"vector\":false") != null);
    }
}

test "runtime publishes audit stream entries for mutations" {
    var harness = try RuntimeTestHarness.init(std.testing.allocator);
    defer harness.deinit();
    const adapter = harness.adapter();
    var runtime = Runtime.init(adapter, harness.health());
    defer runtime.deinit();

    const remember = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"r1\",\"method\":\"memory.remember\",\"params\":{\"scope\":{\"projectId\":\"repo:test\"},\"messages\":[{\"role\":\"user\",\"content\":\"Audit this memory.\"}],\"extract\":false}}",
    );
    defer std.testing.allocator.free(remember);

    const feedback = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"f1\",\"method\":\"memory.feedback\",\"params\":{\"retrievalId\":\"q_retr_1\",\"rating\":\"useful\"}}",
    );
    defer std.testing.allocator.free(feedback);

    const entries = try adapter.readStream(std.testing.allocator, streams.audit, 0, 10);
    defer freeStreamEntries(std.testing.allocator, entries);

    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expect(std.mem.indexOf(u8, entries[0].payload_json, "\"method\":\"memory.remember\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, entries[1].payload_json, "\"method\":\"memory.feedback\"") != null);
}

test "runtime stores tool calls observations episodes and memory cards" {
    var harness = try RuntimeTestHarness.init(std.testing.allocator);
    defer harness.deinit();
    var runtime = Runtime.init(harness.adapter(), harness.health());
    defer runtime.deinit();

    const remember = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"r1\",\"method\":\"memory.remember\",\"params\":{\"scope\":{\"projectId\":\"repo:test\"},\"messages\":[{\"role\":\"user\",\"content\":\"This repo uses pnpm.\",\"createdAt\":\"2026-04-01T10:00:00Z\"}],\"toolCalls\":[{\"toolName\":\"shell\",\"inputJson\":\"{\\\"cmd\\\":\\\"pnpm test\\\"}\",\"outputJson\":\"{\\\"status\\\":\\\"ok\\\"}\",\"status\":\"success\"}],\"observations\":[{\"type\":\"tool_result\",\"content\":\"pnpm test passed\",\"createdAt\":\"2026-04-01T10:01:00Z\"}]}}",
    );
    defer std.testing.allocator.free(remember);

    const cards = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"s1\",\"method\":\"memory.search\",\"params\":{\"query\":\"package manager\",\"scope\":{\"projectId\":\"repo:test\"},\"labels\":[\"MemoryCard\"],\"limit\":5}}",
    );
    defer std.testing.allocator.free(cards);
    try std.testing.expect(std.mem.indexOf(u8, cards, "\"type\":\"memory_card\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, cards, "The repo uses pnpm as its package manager.") != null);

    const episodes = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"s2\",\"method\":\"memory.retrieve\",\"params\":{\"query\":\"repo uses pnpm\",\"scope\":{\"projectId\":\"repo:test\"},\"needs\":[\"recent_episodes\"]}}",
    );
    defer std.testing.allocator.free(episodes);
    // The episode only copies the first message, so it is unsearchable and
    // recent_episodes is served by the raw message itself.
    try std.testing.expect(std.mem.indexOf(u8, episodes, "\"type\":\"episode\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, episodes, "\"type\":\"message\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, episodes, "This repo uses pnpm.") != null);

    const episode_qid = try hashQid(std.testing.allocator, "ep", "q_turn_2");
    defer std.testing.allocator.free(episode_qid);
    const inspect_request = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":\"i1\",\"method\":\"memory.inspect\",\"params\":{{\"qid\":\"{s}\"}}}}",
        .{episode_qid},
    );
    defer std.testing.allocator.free(inspect_request);
    const episode = try runtime.dispatch(std.testing.allocator, inspect_request);
    defer std.testing.allocator.free(episode);
    try std.testing.expect(std.mem.indexOf(u8, episode, "\"type\":\"episode\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, episode, "\\\"searchable\\\":false") != null);

    const observations = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"s3\",\"method\":\"memory.search\",\"params\":{\"query\":\"pnpm test passed\",\"scope\":{\"projectId\":\"repo:test\"},\"labels\":[\"Observation\"],\"limit\":5}}",
    );
    defer std.testing.allocator.free(observations);
    try std.testing.expect(std.mem.indexOf(u8, observations, "pnpm test passed") != null);
}

test "runtime queues extract jobs from durable stream events" {
    var harness = try RuntimeTestHarness.init(std.testing.allocator);
    defer harness.deinit();
    const adapter = harness.adapter();
    var runtime = Runtime.init(adapter, harness.health());
    defer runtime.deinit();

    const remember = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"r1\",\"method\":\"memory.remember\",\"params\":{\"scope\":{\"projectId\":\"repo:test\"},\"messages\":[{\"role\":\"user\",\"content\":\"This repo uses pnpm.\"}]}}",
    );
    defer std.testing.allocator.free(remember);

    try std.testing.expect(std.mem.indexOf(u8, remember, "\"queuedJobs\":[\"q_job_") != null);

    const entries = try adapter.readStream(std.testing.allocator, streams.extract_requested, 0, 10);
    defer freeStreamEntries(std.testing.allocator, entries);
    try std.testing.expectEqual(@as(usize, 1), entries.len);

    const job_qid = try jobs.jobQid(std.testing.allocator, streams.extract_requested, entries[0].sequence, streams.workerKindForStream(streams.extract_requested));
    defer std.testing.allocator.free(job_qid);
    const job = (try adapter.getNode(std.testing.allocator, job_qid)) orelse return error.TestUnexpectedResult;
    defer adapter.freeNode(std.testing.allocator, job);
    try std.testing.expectEqualStrings("Job", job.label);
    try std.testing.expect(std.mem.indexOf(u8, job.properties_json, "\"status\":\"pending\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, job.properties_json, "\"streamName\":\"quipu.extract.requested\"") != null);
}

test "runtime logs retrievals and returns inspect audit events" {
    var harness = try RuntimeTestHarness.init(std.testing.allocator);
    defer harness.deinit();
    var runtime = Runtime.init(harness.adapter(), harness.health());
    defer runtime.deinit();

    const remember = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"r1\",\"method\":\"memory.remember\",\"params\":{\"scope\":{\"projectId\":\"repo:test\"},\"messages\":[{\"role\":\"user\",\"content\":\"Inspect audit target.\"}],\"extract\":false}}",
    );
    defer std.testing.allocator.free(remember);

    const retrieve = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"ret1\",\"method\":\"memory.retrieve\",\"params\":{\"query\":\"audit target\",\"scope\":{\"projectId\":\"repo:test\"}}}",
    );
    defer std.testing.allocator.free(retrieve);

    const inspect = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"i1\",\"method\":\"memory.inspect\",\"params\":{\"qid\":\"q_msg_4\"}}",
    );
    defer std.testing.allocator.free(inspect);

    try std.testing.expect(std.mem.indexOf(u8, inspect, "\"audit\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, inspect, "memory.remember") != null);
    try std.testing.expect(std.mem.indexOf(u8, inspect, "memory.retrieve") != null);
}

test "runtime forget suppresses retrieval" {
    var harness = try RuntimeTestHarness.init(std.testing.allocator);
    defer harness.deinit();
    var runtime = Runtime.init(harness.adapter(), harness.health());
    defer runtime.deinit();

    const remember = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"r1\",\"method\":\"memory.remember\",\"params\":{\"scope\":{\"projectId\":\"repo:test\"},\"messages\":[{\"role\":\"user\",\"content\":\"Delete this exact string.\"}]}}",
    );
    defer std.testing.allocator.free(remember);

    const forget = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"f1\",\"method\":\"memory.forget\",\"params\":{\"mode\":\"hard_delete\",\"selector\":{\"qids\":[\"q_msg_4\"]},\"dryRun\":false,\"reason\":\"test\"}}",
    );
    defer std.testing.allocator.free(forget);
    try std.testing.expect(std.mem.indexOf(u8, forget, "\"nodesDeleted\":1") != null);

    const retrieve = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"q1\",\"method\":\"memory.retrieve\",\"params\":{\"query\":\"exact string\",\"scope\":{\"projectId\":\"repo:test\"}}}",
    );
    defer std.testing.allocator.free(retrieve);
    try std.testing.expect(std.mem.indexOf(u8, retrieve, "Delete this exact string.") == null);
}

test "runtime forget supports query selectors with scope filters" {
    var harness = try RuntimeTestHarness.init(std.testing.allocator);
    defer harness.deinit();
    var runtime = Runtime.init(harness.adapter(), harness.health());
    defer runtime.deinit();

    const alpha = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"r1\",\"method\":\"memory.remember\",\"params\":{\"scope\":{\"projectId\":\"repo:alpha\"},\"messages\":[{\"role\":\"user\",\"content\":\"Scoped deletion token belongs to alpha.\"}],\"extract\":false}}",
    );
    defer std.testing.allocator.free(alpha);
    const beta = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"r2\",\"method\":\"memory.remember\",\"params\":{\"scope\":{\"projectId\":\"repo:beta\"},\"messages\":[{\"role\":\"user\",\"content\":\"Scoped deletion token belongs to beta.\"}],\"extract\":false}}",
    );
    defer std.testing.allocator.free(beta);

    const forget = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"f1\",\"method\":\"memory.forget\",\"params\":{\"mode\":\"hard_delete\",\"selector\":{\"query\":\"Scoped deletion token\",\"scope\":{\"projectId\":\"repo:alpha\"}},\"dryRun\":false,\"reason\":\"test\"}}",
    );
    defer std.testing.allocator.free(forget);
    try std.testing.expect(std.mem.indexOf(u8, forget, "\"rootsMatched\":1") != null);

    const alpha_retrieve = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"q1\",\"method\":\"memory.retrieve\",\"params\":{\"query\":\"Scoped deletion token\",\"scope\":{\"projectId\":\"repo:alpha\"},\"needs\":[\"raw\"]}}",
    );
    defer std.testing.allocator.free(alpha_retrieve);
    try std.testing.expect(std.mem.indexOf(u8, alpha_retrieve, "belongs to alpha") == null);

    const beta_retrieve = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"q2\",\"method\":\"memory.retrieve\",\"params\":{\"query\":\"Scoped deletion token\",\"scope\":{\"projectId\":\"repo:beta\"},\"needs\":[\"raw\"]}}",
    );
    defer std.testing.allocator.free(beta_retrieve);
    try std.testing.expect(std.mem.indexOf(u8, beta_retrieve, "belongs to beta") != null);
}

test "runtime forget contaminates compiled core summaries" {
    var harness = try RuntimeTestHarness.init(std.testing.allocator);
    defer harness.deinit();
    var runtime = Runtime.init(harness.adapter(), harness.health());
    defer runtime.deinit();

    const remember = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"r1\",\"method\":\"memory.remember\",\"params\":{\"scope\":{\"projectId\":\"repo:test\"},\"messages\":[{\"role\":\"user\",\"content\":\"This repo uses pnpm. Run just test before committing.\",\"createdAt\":\"2026-04-01T10:00:00Z\"}]}}",
    );
    defer std.testing.allocator.free(remember);

    const consolidate = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"c1\",\"method\":\"memory.core.consolidate\",\"params\":{\"scope\":{\"projectId\":\"repo:test\"},\"blockKey\":\"project_summary\"}}",
    );
    defer std.testing.allocator.free(consolidate);

    const forget = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"f1\",\"method\":\"memory.forget\",\"params\":{\"mode\":\"hard_delete\",\"selector\":{\"qids\":[\"q_msg_4\"]},\"dryRun\":false,\"reason\":\"test\"}}",
    );
    defer std.testing.allocator.free(forget);
    try std.testing.expect(std.mem.indexOf(u8, forget, "\"summariesContaminated\":1") != null);

    const retrieve = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"q1\",\"method\":\"memory.retrieve\",\"params\":{\"query\":\"pnpm\",\"scope\":{\"projectId\":\"repo:test\"},\"needs\":[\"core\"]}}",
    );
    defer std.testing.allocator.free(retrieve);
    try std.testing.expect(std.mem.indexOf(u8, retrieve, "Consolidated memory:") == null);
    try std.testing.expect(std.mem.indexOf(u8, retrieve, "The repo uses pnpm as its package manager.") == null);
}

test "runtime stores and replaces core blocks" {
    var harness = try RuntimeTestHarness.init(std.testing.allocator);
    defer harness.deinit();
    var runtime = Runtime.init(harness.adapter(), harness.health());
    defer runtime.deinit();

    const update = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"c1\",\"method\":\"memory.core.update\",\"params\":{\"blockKey\":\"project_state\",\"scope\":{\"projectId\":\"repo:test\"},\"text\":\"Use Zig 0.16.\",\"mode\":\"replace\",\"managedBy\":\"user\"}}",
    );
    defer std.testing.allocator.free(update);
    try std.testing.expect(std.mem.indexOf(u8, update, "\"status\":\"stored\"") != null);

    const replace = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"c2\",\"method\":\"memory.core.update\",\"params\":{\"blockKey\":\"project_state\",\"scope\":{\"projectId\":\"repo:test\"},\"text\":\"Use Zig 0.16 and run zig build test.\",\"mode\":\"replace\",\"managedBy\":\"user\"}}",
    );
    defer std.testing.allocator.free(replace);
    try std.testing.expect(std.mem.indexOf(u8, replace, "\"status\":\"updated\"") != null);

    const get = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"c3\",\"method\":\"memory.core.get\",\"params\":{\"scope\":{\"projectId\":\"repo:test\"},\"blockKey\":\"project_state\"}}",
    );
    defer std.testing.allocator.free(get);
    try std.testing.expect(std.mem.indexOf(u8, get, "run zig build test") != null);
}

test "runtime consolidates derived memory into a core block" {
    var harness = try RuntimeTestHarness.init(std.testing.allocator);
    defer harness.deinit();
    var runtime = Runtime.init(harness.adapter(), harness.health());
    defer runtime.deinit();

    const remember = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"r1\",\"method\":\"memory.remember\",\"params\":{\"scope\":{\"projectId\":\"repo:test\"},\"messages\":[{\"role\":\"user\",\"content\":\"This repo uses pnpm. Run just test before committing.\",\"createdAt\":\"2026-04-01T10:00:00Z\"}]}}",
    );
    defer std.testing.allocator.free(remember);

    const consolidate = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"c1\",\"method\":\"memory.core.consolidate\",\"params\":{\"scope\":{\"projectId\":\"repo:test\"},\"blockKey\":\"project_summary\"}}",
    );
    defer std.testing.allocator.free(consolidate);
    try std.testing.expect(std.mem.indexOf(u8, consolidate, "\"sourceCount\"") != null);

    const retrieve = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"q1\",\"method\":\"memory.retrieve\",\"params\":{\"query\":\"Consolidated pnpm\",\"scope\":{\"projectId\":\"repo:test\"},\"needs\":[\"core\"]}}",
    );
    defer std.testing.allocator.free(retrieve);
    try std.testing.expect(std.mem.indexOf(u8, retrieve, "Consolidated memory:") != null);
    try std.testing.expect(std.mem.indexOf(u8, retrieve, "The repo uses pnpm as its package manager.") != null);
}

test "runtime extracts current package manager facts" {
    var harness = try RuntimeTestHarness.init(std.testing.allocator);
    defer harness.deinit();
    var runtime = Runtime.init(harness.adapter(), harness.health());
    defer runtime.deinit();

    const first = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"r1\",\"method\":\"memory.remember\",\"params\":{\"scope\":{\"projectId\":\"repo:test\"},\"messages\":[{\"role\":\"user\",\"content\":\"This repo uses npm.\",\"createdAt\":\"2026-01-01T10:00:00Z\"}]}}",
    );
    defer std.testing.allocator.free(first);

    const second = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"r2\",\"method\":\"memory.remember\",\"params\":{\"scope\":{\"projectId\":\"repo:test\"},\"messages\":[{\"role\":\"user\",\"content\":\"We migrated this repo to pnpm. Use pnpm now.\",\"createdAt\":\"2026-02-01T10:00:00Z\"}]}}",
    );
    defer std.testing.allocator.free(second);

    const retrieve = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"q1\",\"method\":\"memory.retrieve\",\"params\":{\"query\":\"package manager\",\"scope\":{\"projectId\":\"repo:test\"}}}",
    );
    defer std.testing.allocator.free(retrieve);

    try std.testing.expect(std.mem.indexOf(u8, retrieve, "The repo uses pnpm as its package manager.") != null);
    try std.testing.expect(std.mem.indexOf(u8, retrieve, "The repo uses npm as its package manager.") == null);

    const historical = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"q2\",\"method\":\"memory.retrieve\",\"params\":{\"query\":\"package manager\",\"scope\":{\"projectId\":\"repo:test\"},\"time\":{\"validAt\":\"2026-01-15T10:00:00Z\"}}}",
    );
    defer std.testing.allocator.free(historical);
    try std.testing.expect(std.mem.indexOf(u8, historical, "The repo uses npm as its package manager.") != null);
    try std.testing.expect(std.mem.indexOf(u8, historical, "The repo uses pnpm as its package manager.") == null);
}

test "runtime answer deterministic fallback returns the current derived fact" {
    var harness = try RuntimeTestHarness.init(std.testing.allocator);
    defer harness.deinit();
    var runtime = Runtime.init(harness.adapter(), harness.health());
    defer runtime.deinit();

    const first = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"r1\",\"method\":\"memory.remember\",\"params\":{\"scope\":{\"projectId\":\"repo:test\"},\"messages\":[{\"role\":\"user\",\"content\":\"This repo uses npm.\",\"createdAt\":\"2026-01-01T10:00:00Z\"}]}}",
    );
    defer std.testing.allocator.free(first);
    const second = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"r2\",\"method\":\"memory.remember\",\"params\":{\"scope\":{\"projectId\":\"repo:test\"},\"messages\":[{\"role\":\"user\",\"content\":\"We migrated this repo to pnpm. Use pnpm now.\",\"createdAt\":\"2026-02-01T10:00:00Z\"}]}}",
    );
    defer std.testing.allocator.free(second);

    const answer = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"a1\",\"method\":\"memory.answer\",\"params\":{\"query\":\"Which package manager does this repo use?\",\"scope\":{\"projectId\":\"repo:test\"},\"options\":{\"includeDebug\":true,\"logRetrieval\":false}}}",
    );
    defer std.testing.allocator.free(answer);
    try std.testing.expect(std.mem.indexOf(u8, answer, "\"answer\":\"pnpm\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, answer, "\"strategy\":\"deterministic_fallback\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, answer, "\"supportValid\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, answer, "\"confidence\":0.5") != null);
}

const TestReader = struct {
    calls: usize = 0,
    last_user: ?[]u8 = null,
    last_system: []const u8 = "",
    last_min_output_tokens: ?u32 = null,
    cite_invalid: bool = false,
    /// Reply with a leading `reasoning` field, as reasoning mode asks.
    with_reasoning: bool = false,

    fn endpoint(self: *TestReader) providers.ProviderEndpoint {
        return .{
            .kind = .callback,
            .name = "test-reader",
            .model = "test-model",
            .callback = .{ .context = self, .respond = respond },
        };
    }

    fn respond(context: ?*anyopaque, allocator: std.mem.Allocator, turn: providers.ChatTurn) anyerror![]u8 {
        const self: *TestReader = @ptrCast(@alignCast(context.?));
        self.calls += 1;
        if (self.last_user) |previous| std.testing.allocator.free(previous);
        self.last_user = try std.testing.allocator.dupe(u8, turn.user_content);
        self.last_system = turn.system_prompt;
        self.last_min_output_tokens = turn.min_output_tokens;
        const qid = if (self.cite_invalid) "q_msg_999" else lineQid(turn.user_content, "I adopted a cat") orelse "q_missing";
        return std.fmt.allocPrint(
            allocator,
            "{{{s}\"answer\":\"Miso\",\"answerable\":true,\"supportQids\":[\"{s}\"],\"confidence\":0.75}}",
            .{ if (self.with_reasoning) "\"reasoning\":\"[cat line] 2023-05-22 user adopted a cat named Miso.\"," else "", qid },
        );
    }

    fn deinit(self: *TestReader) void {
        if (self.last_user) |previous| std.testing.allocator.free(previous);
    }
};

/// The bracketed qid at the start of the line that contains `needle`.
fn lineQid(text: []const u8, needle: []const u8) ?[]const u8 {
    const at = std.mem.indexOf(u8, text, needle) orelse return null;
    const line_start = std.mem.lastIndexOfScalar(u8, text[0..at], '\n') orelse 0;
    const open = std.mem.indexOfScalarPos(u8, text, line_start, '[') orelse return null;
    const close = std.mem.indexOfScalarPos(u8, text, open, ']') orelse return null;
    return text[open + 1 .. close];
}

fn rememberPetSessions(runtime: *Runtime) !void {
    const late = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"r1\",\"method\":\"memory.remember\",\"params\":{\"scope\":{\"userId\":\"u1\"},\"sessionId\":\"s-late\",\"extract\":false,\"messages\":[{\"role\":\"user\",\"content\":\"I adopted a cat named Miso.\",\"createdAt\":\"2023-05-22T10:00:00Z\"},{\"role\":\"assistant\",\"content\":\"Miso is a lovely name for a cat.\",\"createdAt\":\"2023-05-22T10:00:00Z\"}]}}",
    );
    defer std.testing.allocator.free(late);
    const early = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"r2\",\"method\":\"memory.remember\",\"params\":{\"scope\":{\"userId\":\"u1\"},\"sessionId\":\"s-early\",\"extract\":false,\"messages\":[{\"role\":\"user\",\"content\":\"My dog Rex likes the park.\",\"createdAt\":\"2023-05-20T09:00:00Z\"},{\"role\":\"assistant\",\"content\":\"Parks are great for dogs like Rex.\",\"createdAt\":\"2023-05-20T09:00:00Z\"}]}}",
    );
    defer std.testing.allocator.free(early);
}

fn resultStringField(allocator: std.mem.Allocator, response: []const u8, key: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(Value, allocator, response, .{});
    defer parsed.deinit();
    const result = parsed.value.object.get("result").?.object;
    return allocator.dupe(u8, result.get(key).?.string);
}

fn expectInOrder(text: []const u8, needles: []const []const u8) !void {
    var cursor: usize = 0;
    for (needles) |needle| {
        const index = std.mem.indexOfPos(u8, text, cursor, needle) orelse {
            std.debug.print("missing in order: {s}\n--- text ---\n{s}\n", .{ needle, text });
            return error.TestUnexpectedResult;
        };
        cursor = index + needle.len;
    }
}

test "runtime retrieve prompt groups sessions chronologically with dates and speakers" {
    var harness = try RuntimeTestHarness.init(std.testing.allocator);
    defer harness.deinit();
    var runtime = Runtime.init(harness.adapter(), harness.health());
    defer runtime.deinit();
    try rememberPetSessions(&runtime);

    const retrieve = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"q1\",\"method\":\"memory.retrieve\",\"params\":{\"query\":\"cat dog Miso Rex\",\"scope\":{\"userId\":\"u1\"},\"needs\":[\"raw\"],\"time\":{\"validAt\":\"2023-05-30T23:40:00Z\"},\"options\":{\"logRetrieval\":false,\"logAudit\":false}}}",
    );
    defer std.testing.allocator.free(retrieve);
    const prompt = try resultStringField(std.testing.allocator, retrieve, "prompt");
    defer std.testing.allocator.free(prompt);

    try std.testing.expect(std.mem.startsWith(u8, prompt, "Current date: 2023-05-30 (Tuesday)\n<memory>\n<sessions>\n## session s-early 2023-05-20 (Sat)\n[q_msg_"));
    try expectInOrder(prompt, &.{
        "## session s-early 2023-05-20 (Sat)\n",
        "] user: My dog Rex likes the park.\n",
        "] assistant: Parks are great for dogs like Rex.\n",
        "## session s-late 2023-05-22 (Mon)\n",
        "] user: I adopted a cat named Miso.\n",
        "] assistant: Miso is a lovely name for a cat.\n",
        "</sessions>\n</memory>",
    });

    // Structural Session/Turn nodes never surface as placeholder items.
    const structural = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"q2\",\"method\":\"memory.retrieve\",\"params\":{\"query\":\"session turn Miso\",\"scope\":{\"userId\":\"u1\"},\"options\":{\"logRetrieval\":false,\"logAudit\":false}}}",
    );
    defer std.testing.allocator.free(structural);
    try std.testing.expect(std.mem.indexOf(u8, structural, "\"text\":\"Session\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, structural, "\"text\":\"Turn\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, structural, "I adopted a cat named Miso.") != null);
}

test "runtime answer sends the rendered context and question date to the reader" {
    var harness = try RuntimeTestHarness.init(std.testing.allocator);
    defer harness.deinit();
    var reader = TestReader{};
    defer reader.deinit();
    var runtime = Runtime.initWithOptions(harness.adapter(), harness.health(), .{ .answer_provider = reader.endpoint() });
    defer runtime.deinit();
    try rememberPetSessions(&runtime);

    const answer = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"a1\",\"method\":\"memory.answer\",\"params\":{\"query\":\"What are my cat and dog called?\",\"scope\":{\"userId\":\"u1\"},\"needs\":[\"raw\"],\"time\":{\"validAt\":\"2023-05-30T23:40:00Z\"},\"options\":{\"includeDebug\":true,\"logRetrieval\":false}}}",
    );
    defer std.testing.allocator.free(answer);

    try std.testing.expectEqual(@as(usize, 1), reader.calls);
    try std.testing.expect(std.mem.indexOf(u8, answer, "\"answer\":\"Miso\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, answer, "\"provider\":\"test-reader\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, answer, "\"strategy\":\"llm_reader\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, answer, "\"supportValid\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, answer, "\"confidence\":0.75") != null);

    const prompt = try resultStringField(std.testing.allocator, answer, "prompt");
    defer std.testing.allocator.free(prompt);
    try std.testing.expect(std.mem.startsWith(u8, prompt, "<memory>\n<sessions>\n## session s-early 2023-05-20 (Sat)\n"));
    try expectInOrder(prompt, &.{ "## session s-late 2023-05-22 (Mon)\n", "] user: I adopted a cat named Miso.\n" });
    const user_turn = reader.last_user.?;
    try std.testing.expect(std.mem.startsWith(u8, user_turn, "Current date: 2023-05-30 (Tuesday)\n\nQuestion:\nWhat are my cat and dog called?\n\nMemory context:\n"));
    // `prompt` is exactly the memory context the reader received.
    try std.testing.expect(std.mem.endsWith(u8, user_turn, prompt));
    // Defaults: the direct prompt, no output floor, no temporal hints.
    try std.testing.expectEqualStrings(providers.answer_system_prompt, reader.last_system);
    try std.testing.expect(reader.last_min_output_tokens == null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, " ago") == null);
    try std.testing.expect(std.mem.indexOf(u8, answer, "\"readerMode\":\"direct\",\"temporalHints\":false,\"timeReferences\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, answer, "\"reasoning\":null") != null);

    const quiet = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"a2\",\"method\":\"memory.answer\",\"params\":{\"query\":\"What are my cat and dog called?\",\"scope\":{\"userId\":\"u1\"},\"needs\":[\"raw\"],\"options\":{\"logRetrieval\":false}}}",
    );
    defer std.testing.allocator.free(quiet);
    try std.testing.expect(std.mem.indexOf(u8, quiet, "\"prompt\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, reader.last_user.?, "Current date:") == null);
}

test "runtime answer reasoning and temporal hints reach the reader and the trace" {
    var harness = try RuntimeTestHarness.init(std.testing.allocator);
    defer harness.deinit();
    var reader = TestReader{ .with_reasoning = true };
    defer reader.deinit();
    var runtime = Runtime.initWithOptions(harness.adapter(), harness.health(), .{ .answer_provider = reader.endpoint() });
    defer runtime.deinit();
    try rememberPetSessions(&runtime);

    const answer = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"a1\",\"method\":\"memory.answer\",\"params\":{\"query\":\"What cat and dog did I mention last week?\",\"scope\":{\"userId\":\"u1\"},\"needs\":[\"raw\"],\"time\":{\"validAt\":\"2023-05-30T23:40:00Z\"},\"options\":{\"includeDebug\":true,\"logRetrieval\":false,\"readerReasoning\":true,\"temporalHints\":true}}}",
    );
    defer std.testing.allocator.free(answer);

    try std.testing.expectEqualStrings(providers.answer_reasoning_system_prompt, reader.last_system);
    try std.testing.expectEqual(@as(?u32, providers.reasoning_min_output_tokens), reader.last_min_output_tokens);
    const prompt = try resultStringField(std.testing.allocator, answer, "prompt");
    defer std.testing.allocator.free(prompt);
    try std.testing.expect(std.mem.startsWith(u8, prompt, "<memory>\n<sessions>\n## session s-early 2023-05-20 (Sat), 10 days ago\n"));
    // The session inside the week the question names says so.
    try expectInOrder(prompt, &.{ "## session s-late 2023-05-22 (Mon), 8 days ago: within the question's \"last week\"\n", "] user: I adopted a cat named Miso.\n" });
    try std.testing.expect(std.mem.startsWith(
        u8,
        reader.last_user.?,
        "Current date: 2023-05-30 (Tuesday)\nTime references: \"last week\" = 2023-05-22 to 2023-05-28\n\nQuestion:\nWhat cat and dog did I mention last week?\n\nMemory context:\n<memory>",
    ));
    try std.testing.expect(std.mem.endsWith(u8, reader.last_user.?, prompt));

    var parsed = try std.json.parseFromSlice(Value, std.testing.allocator, answer, .{});
    defer parsed.deinit();
    const result = parsed.value.object.get("result").?.object;
    try std.testing.expectEqualStrings("Miso", result.get("answer").?.string);
    const trace = result.get("answerTrace").?.object;
    try std.testing.expectEqualStrings("reasoning", trace.get("readerMode").?.string);
    try std.testing.expect(trace.get("temporalHints").?.bool);
    try std.testing.expectEqualStrings("\"last week\" = 2023-05-22 to 2023-05-28", trace.get("timeReferences").?.string);
    try std.testing.expectEqualStrings("[cat line] 2023-05-22 user adopted a cat named Miso.", trace.get("reasoning").?.string);
    try std.testing.expect(trace.get("supportValid").?.bool);
    try std.testing.expectEqual(@as(usize, 0), result.get("warnings").?.array.items.len);

    // A reader that skips the reasoning keeps its answer and adds a warning.
    reader.with_reasoning = false;
    const bare = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"a2\",\"method\":\"memory.answer\",\"params\":{\"query\":\"What is my cat called?\",\"scope\":{\"userId\":\"u1\"},\"needs\":[\"raw\"],\"options\":{\"includeDebug\":true,\"logRetrieval\":false,\"readerReasoning\":true,\"temporalHints\":true}}}",
    );
    defer std.testing.allocator.free(bare);
    try std.testing.expect(std.mem.indexOf(u8, bare, "\"answer\":\"Miso\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bare, "\"warnings\":[\"missing_reasoning\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, bare, "\"readerMode\":\"reasoning\"") != null);
    // Without time.validAt there is no date to hint against.
    try std.testing.expect(std.mem.indexOf(u8, bare, "\"temporalHints\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, bare, " ago") == null);
    try std.testing.expect(std.mem.indexOf(u8, reader.last_user.?, "Time references:") == null);
}

test "runtime retrieve renders temporal hints only when requested" {
    var harness = try RuntimeTestHarness.init(std.testing.allocator);
    defer harness.deinit();
    var runtime = Runtime.init(harness.adapter(), harness.health());
    defer runtime.deinit();
    try rememberPetSessions(&runtime);

    const hinted = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"q1\",\"method\":\"memory.retrieve\",\"params\":{\"query\":\"cat dog Miso Rex since the start of the year\",\"scope\":{\"userId\":\"u1\"},\"needs\":[\"raw\"],\"time\":{\"validAt\":\"2023-08-28T10:00:00Z\"},\"options\":{\"logRetrieval\":false,\"logAudit\":false,\"temporalHints\":true}}}",
    );
    defer std.testing.allocator.free(hinted);
    const prompt = try resultStringField(std.testing.allocator, hinted, "prompt");
    defer std.testing.allocator.free(prompt);
    try std.testing.expect(std.mem.startsWith(
        u8,
        prompt,
        "Current date: 2023-08-28 (Monday)\nTime references: \"since the start of the year\" = 2023-01-01 to 2023-08-28\n<memory>\n<sessions>\n## session s-early 2023-05-20 (Sat), ~3 months (100 days) ago\n",
    ));
    try expectInOrder(prompt, &.{"## session s-late 2023-05-22 (Mon), ~3 months (98 days) ago\n"});

    const plain = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"q2\",\"method\":\"memory.retrieve\",\"params\":{\"query\":\"cat dog Miso Rex since the start of the year\",\"scope\":{\"userId\":\"u1\"},\"needs\":[\"raw\"],\"time\":{\"validAt\":\"2023-08-28T10:00:00Z\"},\"options\":{\"logRetrieval\":false,\"logAudit\":false}}}",
    );
    defer std.testing.allocator.free(plain);
    const plain_prompt = try resultStringField(std.testing.allocator, plain, "prompt");
    defer std.testing.allocator.free(plain_prompt);
    // Without the option the question's own time is still resolved; only
    // the per-session offsets are left out.
    try std.testing.expect(std.mem.startsWith(u8, plain_prompt, "Current date: 2023-08-28 (Monday)\nTime references: \"since the start of the year\" = 2023-01-01 to 2023-08-28\n<memory>\n<sessions>\n## session s-early 2023-05-20 (Sat)\n"));
}

test "runtime answer abstains without calling the reader when nothing is retrieved" {
    var harness = try RuntimeTestHarness.init(std.testing.allocator);
    defer harness.deinit();
    var reader = TestReader{};
    defer reader.deinit();
    var runtime = Runtime.initWithOptions(harness.adapter(), harness.health(), .{ .answer_provider = reader.endpoint() });
    defer runtime.deinit();
    try rememberPetSessions(&runtime);

    const answer = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"a1\",\"method\":\"memory.answer\",\"params\":{\"query\":\"zebra quantum\",\"scope\":{\"userId\":\"u1\"},\"needs\":[\"raw\"],\"options\":{\"includeDebug\":true,\"logRetrieval\":false}}}",
    );
    defer std.testing.allocator.free(answer);
    try std.testing.expectEqual(@as(usize, 0), reader.calls);
    try std.testing.expect(std.mem.indexOf(u8, answer, "\"answer\":\"[abstain]\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, answer, "\"strategy\":\"abstain\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, answer, "\"confidence\":0") != null);
}

test "runtime answer keeps reader answers with invalid support unless abstainIfWeak" {
    var harness = try RuntimeTestHarness.init(std.testing.allocator);
    defer harness.deinit();
    var reader = TestReader{ .cite_invalid = true };
    defer reader.deinit();
    var runtime = Runtime.initWithOptions(harness.adapter(), harness.health(), .{ .answer_provider = reader.endpoint() });
    defer runtime.deinit();
    try rememberPetSessions(&runtime);

    const kept = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"a1\",\"method\":\"memory.answer\",\"params\":{\"query\":\"What is my cat's name?\",\"scope\":{\"userId\":\"u1\"},\"needs\":[\"raw\"],\"options\":{\"includeDebug\":true,\"logRetrieval\":false}}}",
    );
    defer std.testing.allocator.free(kept);
    try std.testing.expect(std.mem.indexOf(u8, kept, "\"answer\":\"Miso\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, kept, "\"supportValid\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, kept, "\"invalid_support\"") != null);
    // The invented qid stays only in the raw reader output, never in support.
    try std.testing.expect(std.mem.indexOf(u8, kept, "\"supportQids\":[]") != null);

    const abstained = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"a2\",\"method\":\"memory.answer\",\"params\":{\"query\":\"What is my cat's name?\",\"scope\":{\"userId\":\"u1\"},\"needs\":[\"raw\"],\"options\":{\"includeDebug\":true,\"abstainIfWeak\":true,\"logRetrieval\":false}}}",
    );
    defer std.testing.allocator.free(abstained);
    try std.testing.expect(std.mem.indexOf(u8, abstained, "\"answer\":\"[abstain]\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, abstained, "\"status\":\"abstained\"") != null);
}

/// In-process cross-encoder for rerank tests. Scores rise with fused
/// position, so a fully reranked window comes back reversed.
const TestReranker = struct {
    calls: usize = 0,
    fail: bool = false,
    last_top_n: usize = 0,
    documents: std.ArrayList([]u8) = .empty,

    fn endpoint(self: *TestReranker) providers.ProviderEndpoint {
        return .{
            .kind = .callback,
            .name = "test-reranker",
            .model = "test-cross-encoder",
            .rerank_callback = .{ .context = self, .rerank = rerank },
        };
    }

    fn rerank(context: ?*anyopaque, allocator: std.mem.Allocator, request: providers.RerankRequest) anyerror![]providers.RerankResult {
        const self: *TestReranker = @ptrCast(@alignCast(context.?));
        self.calls += 1;
        self.clearDocuments();
        for (request.documents) |document| {
            try self.documents.append(std.testing.allocator, try std.testing.allocator.dupe(u8, document));
        }
        self.last_top_n = request.top_n;
        if (self.fail) return error.ProviderRequestFailed;
        const results = try allocator.alloc(providers.RerankResult, request.documents.len);
        for (results, 0..) |*result, index| result.* = .{ .index = index, .relevance_score = @floatFromInt(index) };
        return results;
    }

    fn clearDocuments(self: *TestReranker) void {
        for (self.documents.items) |document| std.testing.allocator.free(document);
        self.documents.clearRetainingCapacity();
    }

    fn deinit(self: *TestReranker) void {
        self.clearDocuments();
        self.documents.deinit(std.testing.allocator);
    }
};

const ResponseQids = struct {
    parsed: std.json.Parsed(Value),
    qids: [][]const u8,

    fn deinit(self: *ResponseQids) void {
        std.testing.allocator.free(self.qids);
        self.parsed.deinit();
    }
};

/// Item qids of a retrieve/answer response, in rank order.
fn responseItemQids(response: []const u8) !ResponseQids {
    var parsed = try std.json.parseFromSlice(Value, std.testing.allocator, response, .{});
    errdefer parsed.deinit();
    const items = parsed.value.object.get("result").?.object.get("items").?.array.items;
    const qids = try std.testing.allocator.alloc([]const u8, items.len);
    for (items, 0..) |item, index| qids[index] = item.object.get("qid").?.string;
    return .{ .parsed = parsed, .qids = qids };
}

fn retrievePets(runtime: *Runtime, options_json: []const u8) ![]u8 {
    const request = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":\"q\",\"method\":\"memory.retrieve\",\"params\":{{\"query\":\"cat dog Miso Rex\",\"scope\":{{\"userId\":\"u1\"}},\"needs\":[\"raw\"],\"options\":{{\"includeDebug\":true,\"logRetrieval\":false,\"logAudit\":false{s}}}}}}}",
        .{options_json},
    );
    defer std.testing.allocator.free(request);
    return runtime.dispatch(std.testing.allocator, request);
}

test "rerank order sorts scored items by score with ties in fused order" {
    const scores = [_]providers.RerankResult{
        .{ .index = 3, .relevance_score = 0.2 },
        .{ .index = 1, .relevance_score = 0.9 },
        .{ .index = 0, .relevance_score = 0.2 },
    };
    // Index 2 was not scored: it follows the scored items.
    const order = try rerankOrder(std.testing.allocator, 4, &scores);
    defer std.testing.allocator.free(order);
    try std.testing.expectEqualSlices(usize, &.{ 1, 0, 3, 2 }, order);
}

test "runtime rerank reorders the candidate window before budget packing" {
    var harness = try RuntimeTestHarness.init(std.testing.allocator);
    defer harness.deinit();
    var reranker = TestReranker{};
    defer reranker.deinit();
    var runtime = Runtime.initWithOptions(harness.adapter(), harness.health(), .{ .io = std.testing.io, .reranker = reranker.endpoint() });
    defer runtime.deinit();
    try rememberPetSessions(&runtime);

    const bypass = try retrievePets(&runtime, ",\"rerank\":false");
    defer std.testing.allocator.free(bypass);
    try std.testing.expectEqual(@as(usize, 0), reranker.calls);
    try std.testing.expect(std.mem.indexOf(u8, bypass, "\"rerank\":{\"model\":\"test-cross-encoder\",\"status\":\"disabled\",\"windowSize\":0,\"rerankedCount\":0") != null);
    var fused = try responseItemQids(bypass);
    defer fused.deinit();
    const count = fused.qids.len;
    try std.testing.expect(count >= 3);

    const full = try retrievePets(&runtime, "");
    defer std.testing.allocator.free(full);
    try std.testing.expectEqual(@as(usize, 1), reranker.calls);
    try std.testing.expectEqual(count, reranker.last_top_n);
    try std.testing.expectEqual(count, reranker.documents.items.len);
    var reranked = try responseItemQids(full);
    defer reranked.deinit();
    try std.testing.expectEqual(count, reranked.qids.len);
    for (reranked.qids, 0..) |qid, index| try std.testing.expectEqualStrings(fused.qids[count - 1 - index], qid);
    try std.testing.expect(std.mem.indexOf(u8, full, "\"warnings\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, full, "\"status\":\"applied\"") != null);
    const top = try std.fmt.allocPrint(std.testing.allocator, "\"topScores\":[{{\"qid\":\"{s}\",\"score\":{d}}}", .{ fused.qids[count - 1], count - 1 });
    defer std.testing.allocator.free(top);
    try std.testing.expect(std.mem.indexOf(u8, full, top) != null);

    // Raw evidence is scored as `YYYY-MM-DD role: text`.
    var saw_document = false;
    for (reranker.documents.items) |document| {
        if (std.mem.eql(u8, document, "2023-05-22 user: I adopted a cat named Miso.")) saw_document = true;
    }
    try std.testing.expect(saw_document);

    // Only the window is reordered; later items keep fused order.
    const windowed = try retrievePets(&runtime, ",\"rerankCandidates\":2");
    defer std.testing.allocator.free(windowed);
    try std.testing.expectEqual(@as(usize, 2), reranker.last_top_n);
    var window_qids = try responseItemQids(windowed);
    defer window_qids.deinit();
    try std.testing.expectEqualStrings(fused.qids[1], window_qids.qids[0]);
    try std.testing.expectEqualStrings(fused.qids[0], window_qids.qids[1]);
    for (2..count) |index| try std.testing.expectEqualStrings(fused.qids[index], window_qids.qids[index]);
    try std.testing.expect(std.mem.indexOf(u8, windowed, "\"windowSize\":2,\"rerankedCount\":2") != null);

    const invalid = try retrievePets(&runtime, ",\"rerankCandidates\":0");
    defer std.testing.allocator.free(invalid);
    try std.testing.expect(std.mem.indexOf(u8, invalid, "\"code\":\"invalid_request\"") != null);
}

test "runtime rerank failure keeps fused order and warns" {
    var harness = try RuntimeTestHarness.init(std.testing.allocator);
    defer harness.deinit();
    var reranker = TestReranker{ .fail = true };
    defer reranker.deinit();
    var reader = TestReader{};
    defer reader.deinit();
    var runtime = Runtime.initWithOptions(harness.adapter(), harness.health(), .{
        .answer_provider = reader.endpoint(),
        .reranker = reranker.endpoint(),
    });
    defer runtime.deinit();
    try rememberPetSessions(&runtime);

    const bypass = try retrievePets(&runtime, ",\"rerank\":false");
    defer std.testing.allocator.free(bypass);
    var fused = try responseItemQids(bypass);
    defer fused.deinit();

    const failed = try retrievePets(&runtime, "");
    defer std.testing.allocator.free(failed);
    try std.testing.expectEqual(@as(usize, 1), reranker.calls);
    var kept = try responseItemQids(failed);
    defer kept.deinit();
    try std.testing.expectEqual(fused.qids.len, kept.qids.len);
    for (fused.qids, kept.qids) |expected, actual| try std.testing.expectEqualStrings(expected, actual);
    try std.testing.expect(std.mem.indexOf(u8, failed, "\"warnings\":[\"rerank_failed\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, failed, "\"status\":\"failed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, failed, "\"error\":\"ProviderRequestFailed\"") != null);

    // memory.answer reranks too, and a failed rerank never fails the answer.
    const answer = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"a1\",\"method\":\"memory.answer\",\"params\":{\"query\":\"What is my cat called?\",\"scope\":{\"userId\":\"u1\"},\"needs\":[\"raw\"],\"options\":{\"includeDebug\":true,\"logRetrieval\":false}}}",
    );
    defer std.testing.allocator.free(answer);
    try std.testing.expectEqual(@as(usize, 2), reranker.calls);
    try std.testing.expectEqual(@as(usize, 1), reader.calls);
    try std.testing.expect(std.mem.indexOf(u8, answer, "\"answer\":\"Miso\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, answer, "\"rerank_failed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, answer, "\"status\":\"failed\"") != null);

    reranker.fail = false;
    const reranked_answer = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"a2\",\"method\":\"memory.answer\",\"params\":{\"query\":\"What is my cat called?\",\"scope\":{\"userId\":\"u1\"},\"needs\":[\"raw\"],\"options\":{\"includeDebug\":true,\"logRetrieval\":false,\"rerankCandidates\":1}}}",
    );
    defer std.testing.allocator.free(reranked_answer);
    try std.testing.expectEqual(@as(usize, 3), reranker.calls);
    try std.testing.expect(std.mem.indexOf(u8, reranked_answer, "\"rerank_failed\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, reranked_answer, "\"status\":\"applied\",\"windowSize\":1,\"rerankedCount\":1") != null);
}

test "runtime without a reranker leaves retrieval unchanged" {
    var harness = try RuntimeTestHarness.init(std.testing.allocator);
    defer harness.deinit();
    var runtime = Runtime.init(harness.adapter(), harness.health());
    defer runtime.deinit();
    try rememberPetSessions(&runtime);

    const plain = try retrievePets(&runtime, "");
    defer std.testing.allocator.free(plain);
    try std.testing.expect(std.mem.indexOf(u8, plain, "rerank") == null);
    var plain_qids = try responseItemQids(plain);
    defer plain_qids.deinit();

    // Rerank options are accepted and ignored when nothing is configured.
    const requested = try retrievePets(&runtime, ",\"rerank\":true,\"rerankCandidates\":2");
    defer std.testing.allocator.free(requested);
    try std.testing.expect(std.mem.indexOf(u8, requested, "rerank") == null);
    var requested_qids = try responseItemQids(requested);
    defer requested_qids.deinit();
    try std.testing.expectEqual(plain_qids.qids.len, requested_qids.qids.len);
    for (plain_qids.qids, requested_qids.qids) |expected, actual| try std.testing.expectEqualStrings(expected, actual);

    const health = try runtime.dispatch(std.testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":\"h\",\"method\":\"system.health\",\"params\":{}}");
    defer std.testing.allocator.free(health);
    try std.testing.expect(std.mem.indexOf(u8, health, "\"capabilities\":{\"reranker\":{\"configured\":false,\"model\":null},") != null);
    try std.testing.expect(std.mem.indexOf(u8, health, "\"queryExpansion\":{\"modes\":[\"off\",\"rules\",\"llm\"],\"llmConfigured\":false,\"model\":null}") != null);

    var reranker = TestReranker{};
    defer reranker.deinit();
    var configured = Runtime.initWithOptions(harness.adapter(), harness.health(), .{ .reranker = reranker.endpoint() });
    defer configured.deinit();
    const configured_health = try configured.dispatch(std.testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":\"h\",\"method\":\"system.health\",\"params\":{}}");
    defer std.testing.allocator.free(configured_health);
    try std.testing.expect(std.mem.indexOf(u8, configured_health, "\"reranker\":{\"configured\":true,\"model\":\"test-cross-encoder\"}") != null);
}

/// An owned candidate list with one item per qid, best first.
fn testCandidates(qids: []const []const u8) !OwnedItems {
    const allocator = std.testing.allocator;
    var owned = OwnedItems{ .allocator = allocator };
    errdefer owned.deinit();
    for (qids, 0..) |qid, rank| {
        const owned_qid = try allocator.dupe(u8, qid);
        errdefer allocator.free(owned_qid);
        const text = try std.fmt.allocPrint(allocator, "text of {s}", .{qid});
        errdefer allocator.free(text);
        const state = try allocator.dupe(u8, "current");
        errdefer allocator.free(state);
        try owned.items.append(allocator, .{
            .qid = owned_qid,
            .type = "message",
            .text = text,
            .state = state,
            .score = 1.0 / @as(f32, @floatFromInt(rank + 1)),
            .evidence = &.{},
        });
    }
    return owned;
}

test "query fusion leads with each query's top items, then fused rank" {
    var lists = [_]OwnedItems{
        // The original query and the necklace sub-query agree on the
        // necklace items; only the album sub-query finds the album.
        try testCandidates(&.{ "n1", "n2", "n3", "n4", "n5", "n6", "n7", "n8" }),
        try testCandidates(&.{ "n1", "n2", "n3", "n4", "n5", "n6", "n7", "n8" }),
        try testCandidates(&.{ "a1", "x1", "n9" }),
    };
    defer for (&lists) |*list| list.deinit();

    var fused = try fuseQueryItems(std.testing.allocator, &lists, retrieval_candidate_limit);
    defer fused.deinit();
    for (lists) |list| try std.testing.expectEqual(@as(usize, 0), list.items.items.len);
    const expected = [_][]const u8{ "n1", "a1", "n2", "x1", "n3", "n4", "n5", "n6", "n7", "n8", "n9" };
    try std.testing.expectEqual(expected.len, fused.items.items.len);
    for (expected, fused.items.items) |qid, item| try std.testing.expectEqualStrings(qid, item.qid);
    // Scores are reciprocal-rank sums: plain RRF would put the album last
    // among the necklace items.
    try std.testing.expectEqual(2 * reciprocalRank(0), fused.items.items[0].score);
    try std.testing.expectEqual(reciprocalRank(0), fused.items.items[1].score);
    try std.testing.expect(fused.items.items[1].score < fused.items.items[9].score);

    var short_lists = [_]OwnedItems{
        try testCandidates(&.{ "n1", "n2", "n3" }),
        try testCandidates(&.{ "a1", "n1" }),
    };
    defer for (&short_lists) |*list| list.deinit();
    var limited = try fuseQueryItems(std.testing.allocator, &short_lists, 3);
    defer limited.deinit();
    const kept = [_][]const u8{ "n1", "a1", "n2" };
    try std.testing.expectEqual(kept.len, limited.items.items.len);
    for (kept, limited.items.items) |qid, item| try std.testing.expectEqualStrings(qid, item.qid);
}

const gift_question = "Which gift did I buy first, the necklace for my sister or the photo album for my mom?";

/// Six necklace messages that share most of the question's words, one album
/// message that shares a single word with it, and unrelated filler.
fn rememberGiftSessions(runtime: *Runtime) !void {
    const requests = [_][]const u8{
        "{\"jsonrpc\":\"2.0\",\"id\":\"r1\",\"method\":\"memory.remember\",\"params\":{\"scope\":{\"userId\":\"u1\"},\"sessionId\":\"s-necklace\",\"extract\":false,\"messages\":[" ++
            "{\"role\":\"user\",\"content\":\"I bought a silver necklace as a gift for my sister.\",\"createdAt\":\"2023-05-10T10:00:00Z\"}," ++
            "{\"role\":\"user\",\"content\":\"The necklace for my sister was the first gift I picked.\",\"createdAt\":\"2023-05-10T10:01:00Z\"}," ++
            "{\"role\":\"user\",\"content\":\"My sister loved the necklace gift so much.\",\"createdAt\":\"2023-05-10T10:02:00Z\"}," ++
            "{\"role\":\"user\",\"content\":\"I wrapped the necklace gift for my sister.\",\"createdAt\":\"2023-05-10T10:03:00Z\"}," ++
            "{\"role\":\"user\",\"content\":\"My sister wears the necklace gift every day.\",\"createdAt\":\"2023-05-10T10:04:00Z\"}," ++
            "{\"role\":\"user\",\"content\":\"The necklace gift came in a box for my sister.\",\"createdAt\":\"2023-05-10T10:05:00Z\"}]}}",
        "{\"jsonrpc\":\"2.0\",\"id\":\"r2\",\"method\":\"memory.remember\",\"params\":{\"scope\":{\"userId\":\"u1\"},\"sessionId\":\"s-album\",\"extract\":false,\"messages\":[" ++
            "{\"role\":\"user\",\"content\":\"I ordered an album of old pictures for her birthday.\",\"createdAt\":\"2023-05-02T09:00:00Z\"}]}}",
        "{\"jsonrpc\":\"2.0\",\"id\":\"r3\",\"method\":\"memory.remember\",\"params\":{\"scope\":{\"userId\":\"u1\"},\"sessionId\":\"s-other\",\"extract\":false,\"messages\":[" ++
            "{\"role\":\"user\",\"content\":\"The weather was rainy on Tuesday.\",\"createdAt\":\"2023-05-03T09:00:00Z\"}," ++
            "{\"role\":\"user\",\"content\":\"Our team shipped the quarterly report.\",\"createdAt\":\"2023-05-03T09:01:00Z\"}," ++
            "{\"role\":\"user\",\"content\":\"Lunch was a bowl of ramen downtown.\",\"createdAt\":\"2023-05-03T09:02:00Z\"}," ++
            "{\"role\":\"user\",\"content\":\"The train was late again this morning.\",\"createdAt\":\"2023-05-03T09:03:00Z\"}," ++
            "{\"role\":\"user\",\"content\":\"We planted tomatoes in the garden.\",\"createdAt\":\"2023-05-03T09:04:00Z\"}," ++
            "{\"role\":\"user\",\"content\":\"The concert tickets sold out quickly.\",\"createdAt\":\"2023-05-03T09:05:00Z\"}]}}",
    };
    for (requests) |request| {
        const response = try runtime.dispatch(std.testing.allocator, request);
        defer std.testing.allocator.free(response);
        try std.testing.expect(std.mem.indexOf(u8, response, "\"status\":\"stored\"") != null);
    }
}

fn retrieveGifts(runtime: *Runtime, options_json: []const u8) ![]u8 {
    const request = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":\"g\",\"method\":\"memory.retrieve\",\"params\":{{\"query\":\"{s}\",\"scope\":{{\"userId\":\"u1\"}},\"needs\":[\"raw\"],\"budgetTokens\":120,\"options\":{{\"includeDebug\":true,\"logRetrieval\":false,\"logAudit\":false{s}}}}}}}",
        .{ gift_question, options_json },
    );
    defer std.testing.allocator.free(request);
    return runtime.dispatch(std.testing.allocator, request);
}

/// The result's `trace.queryExpansion` (or `answerTrace.queryExpansion`).
fn expansionTrace(parsed: *const std.json.Parsed(Value), trace_key: []const u8) ?ObjectMap {
    const result = parsed.value.object.get("result").?.object;
    const trace = result.get(trace_key) orelse return null;
    if (trace != .object) return null;
    const expansion = trace.object.get("queryExpansion") orelse return null;
    return expansion.object;
}

/// A chat provider that answers query expansion calls with `reply` and acts
/// as a reader otherwise.
const TestExpander = struct {
    calls: usize = 0,
    reader_calls: usize = 0,
    reply: []const u8 = "{\"queries\":[\"photo album for my mom\",\"necklace for my sister\"]}",
    fail: bool = false,
    last_question: ?[]u8 = null,
    json_mode: bool = false,

    fn endpoint(self: *TestExpander) providers.ProviderEndpoint {
        return .{
            .kind = .callback,
            .name = "test-expander",
            .model = "test-expansion-model",
            .callback = .{ .context = self, .respond = respond },
        };
    }

    fn respond(context: ?*anyopaque, allocator: std.mem.Allocator, turn: providers.ChatTurn) anyerror![]u8 {
        const self: *TestExpander = @ptrCast(@alignCast(context.?));
        if (!std.mem.eql(u8, turn.system_prompt, query_expansion.llm_system_prompt)) {
            self.reader_calls += 1;
            const qid = lineQid(turn.user_content, "album of old pictures") orelse "q_missing";
            return std.fmt.allocPrint(allocator, "{{\"answer\":\"the photo album\",\"answerable\":true,\"supportQids\":[\"{s}\"],\"confidence\":0.8}}", .{qid});
        }
        self.calls += 1;
        if (self.last_question) |previous| std.testing.allocator.free(previous);
        self.last_question = try std.testing.allocator.dupe(u8, turn.user_content);
        self.json_mode = turn.json_mode;
        if (self.fail) return error.ProviderRequestFailed;
        return allocator.dupe(u8, self.reply);
    }

    fn deinit(self: *TestExpander) void {
        if (self.last_question) |previous| std.testing.allocator.free(previous);
    }
};

test "runtime rules expansion surfaces both sides of a comparison within the budget" {
    var harness = try RuntimeTestHarness.init(std.testing.allocator);
    defer harness.deinit();
    var runtime = Runtime.init(harness.adapter(), harness.health());
    defer runtime.deinit();
    try rememberGiftSessions(&runtime);

    // One query ranks every necklace message above the album message, so the
    // budget fills before the album is reached.
    const single = try retrieveGifts(&runtime, "");
    defer std.testing.allocator.free(single);
    const single_prompt = try resultStringField(std.testing.allocator, single, "prompt");
    defer std.testing.allocator.free(single_prompt);
    try std.testing.expect(std.mem.indexOf(u8, single_prompt, "necklace") != null);
    try std.testing.expect(std.mem.indexOf(u8, single_prompt, "album of old pictures") == null);
    try std.testing.expect(std.mem.indexOf(u8, single, "queryExpansion") == null);

    const expanded = try retrieveGifts(&runtime, ",\"queryExpansion\":\"rules\"");
    defer std.testing.allocator.free(expanded);
    const prompt = try resultStringField(std.testing.allocator, expanded, "prompt");
    defer std.testing.allocator.free(prompt);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "necklace") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "album of old pictures") != null);
    try std.testing.expect(std.mem.indexOf(u8, expanded, "\"warnings\":[\"token_budget_truncated\"]") != null);

    var parsed = try std.json.parseFromSlice(Value, std.testing.allocator, expanded, .{});
    defer parsed.deinit();
    const trace = expansionTrace(&parsed, "trace").?;
    try std.testing.expectEqualStrings("rules", trace.get("mode").?.string);
    try std.testing.expectEqualStrings("expanded", trace.get("status").?.string);
    try std.testing.expect(trace.get("model").? == .null);
    try std.testing.expect(trace.get("error").? == .null);
    const queries = trace.get("queries").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), queries.len);
    const expected = [_][2][]const u8{
        .{ gift_question, "original" },
        .{ "the necklace for my sister", "rules" },
        .{ "the photo album for my mom", "rules" },
    };
    for (expected, queries) |want, query| {
        try std.testing.expectEqualStrings(want[0], query.object.get("query").?.string);
        try std.testing.expectEqualStrings(want[1], query.object.get("source").?.string);
        try std.testing.expect(query.object.get("hitCount").?.integer > 0);
        try std.testing.expect(query.object.get("topQids").?.array.items.len > 0);
    }
    // The album sub-query's best hit is the album message, and it is packed.
    const album_qid = queries[2].object.get("topQids").?.array.items[0].string;
    var item_qids = try responseItemQids(expanded);
    defer item_qids.deinit();
    try std.testing.expect(stringListContains(item_qids.qids, album_qid));
}

test "runtime query expansion off and unsplittable rules leave retrieval unchanged" {
    var harness = try RuntimeTestHarness.init(std.testing.allocator);
    defer harness.deinit();
    var reader = TestReader{};
    defer reader.deinit();
    var runtime = Runtime.initWithOptions(harness.adapter(), harness.health(), .{ .answer_provider = reader.endpoint() });
    defer runtime.deinit();
    try rememberPetSessions(&runtime);

    const plain = try retrievePets(&runtime, "");
    defer std.testing.allocator.free(plain);
    const off = try retrievePets(&runtime, ",\"queryExpansion\":\"off\"");
    defer std.testing.allocator.free(off);
    const null_option = try retrievePets(&runtime, ",\"queryExpansion\":null");
    defer std.testing.allocator.free(null_option);
    // Byte-identical apart from the retrieval id.
    const plain_id = try resultStringField(std.testing.allocator, plain, "retrievalId");
    defer std.testing.allocator.free(plain_id);
    for ([_][]const u8{ off, null_option }) |response| {
        const retrieval_id = try resultStringField(std.testing.allocator, response, "retrievalId");
        defer std.testing.allocator.free(retrieval_id);
        const normalized = try std.mem.replaceOwned(u8, std.testing.allocator, response, retrieval_id, plain_id);
        defer std.testing.allocator.free(normalized);
        try std.testing.expectEqualStrings(plain, normalized);
    }
    try std.testing.expect(std.mem.indexOf(u8, plain, "queryExpansion") == null);

    // "rules" with nothing to split runs the original query alone.
    const rules = try retrievePets(&runtime, ",\"queryExpansion\":\"rules\"");
    defer std.testing.allocator.free(rules);
    var plain_qids = try responseItemQids(plain);
    defer plain_qids.deinit();
    var rules_qids = try responseItemQids(rules);
    defer rules_qids.deinit();
    try std.testing.expectEqual(plain_qids.qids.len, rules_qids.qids.len);
    for (plain_qids.qids, rules_qids.qids) |expected, actual| try std.testing.expectEqualStrings(expected, actual);
    const plain_prompt = try resultStringField(std.testing.allocator, plain, "prompt");
    defer std.testing.allocator.free(plain_prompt);
    const rules_prompt = try resultStringField(std.testing.allocator, rules, "prompt");
    defer std.testing.allocator.free(rules_prompt);
    try std.testing.expectEqualStrings(plain_prompt, rules_prompt);
    try std.testing.expect(std.mem.indexOf(u8, rules, "\"queryExpansion\":{\"mode\":\"rules\",\"status\":\"unchanged\"") != null);

    // memory.answer: no queryExpansion key in either trace when off.
    const answer = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"a1\",\"method\":\"memory.answer\",\"params\":{\"query\":\"What is my cat called?\",\"scope\":{\"userId\":\"u1\"},\"needs\":[\"raw\"],\"options\":{\"includeDebug\":true,\"logRetrieval\":false,\"queryExpansion\":\"off\"}}}",
    );
    defer std.testing.allocator.free(answer);
    try std.testing.expect(std.mem.indexOf(u8, answer, "\"answer\":\"Miso\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, answer, "queryExpansion") == null);
    try std.testing.expectEqual(@as(usize, 1), reader.calls);

    for ([_][]const u8{ ",\"queryExpansion\":\"LLM\"", ",\"queryExpansion\":true", ",\"queryExpansion\":\"\"" }) |bad| {
        const invalid = try retrievePets(&runtime, bad);
        defer std.testing.allocator.free(invalid);
        try std.testing.expect(std.mem.indexOf(u8, invalid, "\"code\":\"invalid_request\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, invalid, "options.queryExpansion must be off, rules, or llm") != null);
    }
}

test "runtime llm expansion sends only the question and fuses the reply" {
    var harness = try RuntimeTestHarness.init(std.testing.allocator);
    defer harness.deinit();
    var expander = TestExpander{};
    defer expander.deinit();
    // No expansion provider: the reader's provider expands too.
    var runtime = Runtime.initWithOptions(harness.adapter(), harness.health(), .{ .answer_provider = expander.endpoint() });
    defer runtime.deinit();
    try rememberGiftSessions(&runtime);

    const health = try runtime.dispatch(std.testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":\"h\",\"method\":\"system.health\",\"params\":{}}");
    defer std.testing.allocator.free(health);
    try std.testing.expect(std.mem.indexOf(u8, health, "\"queryExpansion\":{\"modes\":[\"off\",\"rules\",\"llm\"],\"llmConfigured\":true,\"model\":\"test-expansion-model\"}") != null);

    const request = "{\"jsonrpc\":\"2.0\",\"id\":\"a1\",\"method\":\"memory.answer\",\"params\":{\"query\":\"" ++ gift_question ++ "\",\"scope\":{\"userId\":\"u1\"},\"needs\":[\"raw\"],\"budgetTokens\":120,\"options\":{\"includeDebug\":true,\"logRetrieval\":false,\"queryExpansion\":\"llm\"}}}";
    const answer = try runtime.dispatch(std.testing.allocator, request);
    defer std.testing.allocator.free(answer);
    try std.testing.expectEqual(@as(usize, 1), expander.calls);
    try std.testing.expectEqual(@as(usize, 1), expander.reader_calls);
    try std.testing.expectEqualStrings(gift_question, expander.last_question.?);
    try std.testing.expect(expander.json_mode);
    try std.testing.expect(std.mem.indexOf(u8, answer, "\"answer\":\"the photo album\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, answer, "query_expansion_failed") == null);
    const prompt = try resultStringField(std.testing.allocator, answer, "prompt");
    defer std.testing.allocator.free(prompt);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "album of old pictures") != null);

    var parsed = try std.json.parseFromSlice(Value, std.testing.allocator, answer, .{});
    defer parsed.deinit();
    // Reported in both traces, identically.
    const trace = expansionTrace(&parsed, "answerTrace").?;
    try std.testing.expectEqualStrings("llm", trace.get("mode").?.string);
    try std.testing.expectEqualStrings("expanded", trace.get("status").?.string);
    try std.testing.expectEqualStrings("test-expansion-model", trace.get("model").?.string);
    const queries = trace.get("queries").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), queries.len);
    try std.testing.expectEqualStrings("original", queries[0].object.get("source").?.string);
    try std.testing.expectEqualStrings("photo album for my mom", queries[1].object.get("query").?.string);
    try std.testing.expectEqualStrings("llm", queries[1].object.get("source").?.string);
    try std.testing.expectEqualStrings("necklace for my sister", queries[2].object.get("query").?.string);
    const retrieval_trace = expansionTrace(&parsed, "trace").?;
    try std.testing.expectEqual(queries.len, retrieval_trace.get("queries").?.array.items.len);

    // A configured expansion provider takes precedence over the reader.
    var dedicated = TestExpander{ .reply = "{\"queries\":[\"album of old pictures\"]}" };
    defer dedicated.deinit();
    var split_runtime = Runtime.initWithOptions(harness.adapter(), harness.health(), .{
        .answer_provider = expander.endpoint(),
        .expansion_provider = dedicated.endpoint(),
    });
    defer split_runtime.deinit();
    const split = try split_runtime.dispatch(std.testing.allocator, request);
    defer std.testing.allocator.free(split);
    try std.testing.expectEqual(@as(usize, 1), dedicated.calls);
    try std.testing.expectEqual(@as(usize, 0), dedicated.reader_calls);
    try std.testing.expectEqual(@as(usize, 1), expander.calls);
    try std.testing.expectEqual(@as(usize, 2), expander.reader_calls);
    try std.testing.expect(std.mem.indexOf(u8, split, "\"query\":\"album of old pictures\",\"source\":\"llm\"") != null);
}

test "runtime llm expansion failures fall back to the original query with a warning" {
    var harness = try RuntimeTestHarness.init(std.testing.allocator);
    defer harness.deinit();
    var expander = TestExpander{};
    defer expander.deinit();
    var runtime = Runtime.initWithOptions(harness.adapter(), harness.health(), .{ .expansion_provider = expander.endpoint() });
    defer runtime.deinit();
    try rememberGiftSessions(&runtime);

    const baseline = try retrieveGifts(&runtime, "");
    defer std.testing.allocator.free(baseline);
    var baseline_qids = try responseItemQids(baseline);
    defer baseline_qids.deinit();

    const cases = [_]struct { reply: []const u8, fail: bool, @"error": []const u8 }{
        .{ .reply = "", .fail = true, .@"error" = "ProviderRequestFailed" },
        .{ .reply = "not json", .fail = false, .@"error" = "InvalidExpansionResponse" },
        .{ .reply = "{\"queries\":[\"a\",\"b\",\"c\",\"d\",\"e\"]}", .fail = false, .@"error" = "InvalidExpansionResponse" },
        .{ .reply = "{\"queries\":[\"\"]}", .fail = false, .@"error" = "InvalidExpansionResponse" },
    };
    for (cases, 1..) |case, call_count| {
        expander.reply = case.reply;
        expander.fail = case.fail;
        const response = try retrieveGifts(&runtime, ",\"queryExpansion\":\"llm\"");
        defer std.testing.allocator.free(response);
        try std.testing.expectEqual(call_count, expander.calls);
        try std.testing.expect(std.mem.indexOf(u8, response, "\"query_expansion_failed\"") != null);
        var parsed = try std.json.parseFromSlice(Value, std.testing.allocator, response, .{});
        defer parsed.deinit();
        const trace = expansionTrace(&parsed, "trace").?;
        try std.testing.expectEqualStrings("failed", trace.get("status").?.string);
        try std.testing.expectEqualStrings(case.@"error", trace.get("error").?.string);
        try std.testing.expectEqual(@as(usize, 1), trace.get("queries").?.array.items.len);
        var qids = try responseItemQids(response);
        defer qids.deinit();
        try std.testing.expectEqual(baseline_qids.qids.len, qids.qids.len);
        for (baseline_qids.qids, qids.qids) |expected, actual| try std.testing.expectEqualStrings(expected, actual);
    }

    // No chat provider at all: nothing to call, same fallback.
    var bare = Runtime.init(harness.adapter(), harness.health());
    defer bare.deinit();
    const unavailable = try retrieveGifts(&bare, ",\"queryExpansion\":\"llm\"");
    defer std.testing.allocator.free(unavailable);
    try std.testing.expect(std.mem.indexOf(u8, unavailable, "\"query_expansion_failed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, unavailable, "\"error\":\"ProviderUnavailable\"") != null);
}

test "prompt renderer orders sessions, items and derived memory deterministically" {
    const items = [_]MessageResult{
        .{ .qid = "q_chunk_12", .type = "message", .text = "second half\n\nof the   long reply", .score = 3 },
        .{ .qid = "q_msg_3", .type = "message", .text = "Early question about </memory> tags", .score = 2 },
        .{ .qid = "q_chunk_11", .type = "message", .text = "first half", .score = 1 },
        .{ .qid = "q_msg_10", .type = "message", .text = "Late question", .score = 1 },
        .{ .qid = "q_obs_7", .type = "raw", .text = "Observed build failure", .score = 1 },
        .{ .qid = "q_msg_4", .type = "message", .text = "Next-day follow up", .score = 1 },
    };
    const late = RenderMeta{ .created_at = "2023-05-22T10:00:00Z", .session_qid = "q_sess_8", .session_id = "s-late" };
    var entries = [_]RenderEntry{
        .{ .item = items[0], .rank = 0, .meta = withMeta(late, "assistant", 1, 1, 2) },
        .{ .item = items[1], .rank = 1, .meta = .{ .role = "user", .created_at = "2023-05-20T09:00:00Z", .session_qid = "q_sess_1", .message_index = 0 } },
        .{ .item = items[2], .rank = 2, .meta = withMeta(late, "assistant", 1, 0, 2) },
        .{ .item = items[3], .rank = 3, .meta = withMeta(late, "user", 0, null, null) },
        .{ .item = items[4], .rank = 4, .meta = .{ .role = "observation", .created_at = "2023-05-21T08:00:00Z" } },
        .{ .item = items[5], .rank = 5, .meta = .{ .role = "user", .created_at = "2023-05-21T09:00:00Z", .session_qid = "q_sess_1", .message_index = 1 } },
    };
    const facts = [_]MessageResult{
        .{ .qid = "q_fact_9", .type = "fact", .text = "The repo uses pnpm.", .score = 1, .validFrom = "2023-05-22T10:00:00Z" },
        .{ .qid = "q_fact_2", .type = "fact", .text = "The repo uses npm.", .score = 1, .state = "superseded", .validFrom = "2023-05-01T00:00:00Z", .validTo = "2023-05-22T10:00:00Z" },
    };
    const context = ContextPacket{ .currentFacts = &facts, .episodes = &items };
    const expected =
        \\Current date: 2023-05-30 (Tuesday)
        \\<memory>
        \\<facts>
        \\[q_fact_2] (superseded, 2023-05-01 to 2023-05-22) The repo uses npm.
        \\[q_fact_9] (current, from 2023-05-22) The repo uses pnpm.
        \\</facts>
        \\<sessions>
        \\## session q_sess_1 2023-05-20 (Sat)
        \\[q_msg_3] user: Early question about [/memory] tags
        \\[q_msg_4] 2023-05-21 user: Next-day follow up
        \\## session s-late 2023-05-22 (Mon)
        \\[q_msg_10] user: Late question
        \\[q_chunk_11] assistant (1/2): first half
        \\[q_chunk_12] assistant (2/2): second half of the long reply
        \\## other
        \\[q_obs_7] 2023-05-21 observation: Observed build failure
        \\</sessions>
        \\</memory>
    ;

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const prompt = try renderPrompt(std.testing.allocator, arena_state.allocator(), context, &entries, .{ .current_date = "2023-05-30T23:40:00Z" });
    defer std.testing.allocator.free(prompt);
    try std.testing.expectEqualStrings(expected, prompt);

    // Retrieval rank order does not change the rendering.
    std.mem.reverse(RenderEntry, &entries);
    for (&entries, 0..) |*entry, rank| entry.rank = rank;
    const reversed = try renderPrompt(std.testing.allocator, arena_state.allocator(), context, &entries, .{ .current_date = "2023-05-30T23:40:00Z" });
    defer std.testing.allocator.free(reversed);
    try std.testing.expectEqualStrings(expected, reversed);
}

test "prompt renderer appends session offsets from the hint date" {
    const items = [_]MessageResult{
        .{ .qid = "q_msg_1", .type = "message", .text = "Old trip.", .score = 1 },
        .{ .qid = "q_msg_2", .type = "message", .text = "Recent run.", .score = 1 },
        .{ .qid = "q_obs_3", .type = "raw", .text = "Loose note.", .score = 1 },
        .{ .qid = "q_msg_4", .type = "message", .text = "Same-day plan.", .score = 1 },
    };
    const entries = [_]RenderEntry{
        .{ .item = items[0], .rank = 0, .meta = .{ .role = "user", .created_at = "2021-02-28T09:00:00Z", .session_id = "s-old" } },
        .{ .item = items[1], .rank = 1, .meta = .{ .role = "user", .created_at = "2024-02-28T09:00:00Z", .session_id = "s-feb" } },
        .{ .item = items[2], .rank = 2, .meta = .{ .role = "observation", .created_at = "2024-02-01T08:00:00Z" } },
        .{ .item = items[3], .rank = 3, .meta = .{ .role = "user", .created_at = "2024-03-01T07:00:00Z", .session_id = "s-today" } },
    };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const prompt = try renderPrompt(std.testing.allocator, arena_state.allocator(), .{ .episodes = &items }, &entries, .{
        .current_date = "2024-03-01T12:00:00Z",
        .hint_date = try parseIsoDate("2024-03-01"),
        .time_references = "\"yesterday\" = 2024-02-29 (Thu)",
    });
    defer std.testing.allocator.free(prompt);
    try std.testing.expectEqualStrings(
        \\Current date: 2024-03-01 (Friday)
        \\Time references: "yesterday" = 2024-02-29 (Thu)
        \\<memory>
        \\<sessions>
        \\## session s-old 2021-02-28 (Sun), ~3 years (1097 days) ago
        \\[q_msg_1] user: Old trip.
        \\## session s-feb 2024-02-28 (Wed), 2 days ago
        \\[q_msg_2] user: Recent run.
        \\## session s-today 2024-03-01 (Fri), today
        \\[q_msg_4] user: Same-day plan.
        \\## other
        \\[q_obs_3] 2024-02-01 observation: Loose note.
        \\</sessions>
        \\</memory>
    ,
        prompt,
    );
}

fn withMeta(base: RenderMeta, role: []const u8, message_index: ?i64, chunk_index: ?i64, chunk_count: ?i64) RenderMeta {
    var meta = base;
    meta.role = role;
    meta.message_index = message_index;
    meta.chunk_index = chunk_index;
    meta.chunk_count = chunk_count;
    return meta;
}

test "prompt renderer resolves sessions from raw sources and legacy nodes" {
    var harness = try RuntimeTestHarness.init(std.testing.allocator);
    defer harness.deinit();
    const store = harness.adapter();
    try store.putNode(.{ .qid = "q_sess_1", .label = "Session", .properties_json = "{\"kind\":\"session\",\"sessionId\":\"lme-7\",\"deleted\":false}" });
    try store.putNode(.{ .qid = "q_turn_2", .label = "Turn", .properties_json = "{\"kind\":\"turn\",\"sessionQid\":\"q_sess_1\",\"deleted\":false}" });
    try store.putNode(.{ .qid = "q_msg_3", .label = "Message", .properties_json = "{\"kind\":\"message\",\"role\":\"user\",\"content\":\"Legacy note.\",\"createdAt\":\"2024-02-28T08:00:00Z\",\"deleted\":false}" });
    try store.putEdge(.{ .qid = "q_edge_1", .from_qid = "q_turn_2", .to_qid = "q_msg_3", .edge_type = "HAS_MESSAGE", .properties_json = "{}" });
    try store.putNode(.{ .qid = "q_sess_5", .label = "Session", .properties_json = "{\"kind\":\"session\",\"sessionId\":\"s-2\",\"deleted\":false}" });

    try std.testing.expectError(error.NoRenderableText, textForNode(std.testing.allocator, .{ .qid = "q_sess_1", .label = "Session", .properties_json = "{}" }));

    const items = [_]MessageResult{
        // Chunk item: raw source names the session qid; the caller id comes from the Session node.
        .{ .qid = "q_chunk_6_1", .type = "message", .text = "tail part", .score = 2, .raw_source = .{
            .role = "assistant",
            .created_at = "2024-02-29T08:00:00Z",
            .session_qid = "q_sess_5",
            .message_qid = "q_msg_6",
            .message_index = 0,
            .chunk_index = 1,
            .chunk_count = 2,
        } },
        // Legacy message without session fields: resolved through its Turn edge.
        .{ .qid = "q_msg_3", .type = "message", .text = "Legacy note.", .score = 1, .raw_source = .{
            .role = "user",
            .created_at = "2024-02-28T08:00:00Z",
            .message_qid = "q_msg_3",
        } },
        .{ .qid = "q_unknown_9", .type = "message", .text = "No node behind this item.", .score = 1, .validFrom = "2024-03-01T00:00:00Z" },
    };
    const prompt = try promptFromContext(std.testing.allocator, store, .{ .episodes = &items }, .{});
    defer std.testing.allocator.free(prompt);
    try std.testing.expectEqualStrings(
        "<memory>\n<sessions>\n## session lme-7 2024-02-28 (Wed)\n[q_msg_3] user: Legacy note.\n## session s-2 2024-02-29 (Thu)\n[q_chunk_6_1] assistant (2/2): tail part\n## other\n[q_unknown_9] 2024-03-01: No node behind this item.\n</sessions>\n</memory>",
        prompt,
    );
    try std.testing.expectEqual(std.math.Order.lt, naturalQidOrder("q_chunk_9_1", "q_chunk_10_0"));
    try std.testing.expectEqual(std.math.Order.lt, naturalQidOrder("q_msg_9", "q_msg_10"));
}

test "runtime retrieve assembles categorized context and trace" {
    var harness = try RuntimeTestHarness.init(std.testing.allocator);
    defer harness.deinit();
    var runtime = Runtime.init(harness.adapter(), harness.health());
    defer runtime.deinit();

    const remember = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"r1\",\"method\":\"memory.remember\",\"params\":{\"scope\":{\"projectId\":\"repo:test\"},\"messages\":[{\"role\":\"user\",\"content\":\"This repo uses pnpm. Run just test before committing.\",\"createdAt\":\"2026-04-01T10:00:00Z\"}]}}",
    );
    defer std.testing.allocator.free(remember);

    const core = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"c1\",\"method\":\"memory.core.update\",\"params\":{\"blockKey\":\"project_state\",\"scope\":{\"projectId\":\"repo:test\"},\"text\":\"Prefer small focused patches.\",\"mode\":\"replace\",\"managedBy\":\"user\"}}",
    );
    defer std.testing.allocator.free(core);

    const retrieve = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"q1\",\"method\":\"memory.retrieve\",\"params\":{\"query\":\"package manager test command\",\"scope\":{\"projectId\":\"repo:test\"},\"needs\":[\"core\",\"current_facts\",\"procedural\"],\"options\":{\"includeDebug\":true}}}",
    );
    defer std.testing.allocator.free(retrieve);

    try std.testing.expect(std.mem.indexOf(u8, retrieve, "\"core\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, retrieve, "\"currentFacts\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, retrieve, "\"procedural\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, retrieve, "Prefer small focused patches.") != null);
    try std.testing.expect(std.mem.indexOf(u8, retrieve, "The repo uses pnpm as its package manager.") != null);
    try std.testing.expect(std.mem.indexOf(u8, retrieve, "Run just test before committing.") != null);
    try std.testing.expect(std.mem.indexOf(u8, retrieve, "\"trace\":{") != null);
    try std.testing.expect(std.mem.indexOf(u8, retrieve, "\"requestedNeedsCount\":3") != null);
    try std.testing.expect(std.mem.indexOf(u8, retrieve, "\"candidateSources\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, retrieve, "\"scoreBreakdowns\"") != null);

    const no_evidence = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"q2\",\"method\":\"memory.retrieve\",\"params\":{\"query\":\"package manager\",\"scope\":{\"projectId\":\"repo:test\"},\"needs\":[\"current_facts\"],\"options\":{\"includeEvidence\":false}}}",
    );
    defer std.testing.allocator.free(no_evidence);
    try std.testing.expect(std.mem.indexOf(u8, no_evidence, "\"evidence\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, no_evidence, "\"quote\"") == null);
}

test "runtime retrieve filters event windows and token budgets" {
    var harness = try RuntimeTestHarness.init(std.testing.allocator);
    defer harness.deinit();
    var runtime = Runtime.init(harness.adapter(), harness.health());
    defer runtime.deinit();

    const old = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"r1\",\"method\":\"memory.remember\",\"params\":{\"scope\":{\"projectId\":\"repo:test\"},\"messages\":[{\"role\":\"user\",\"content\":\"Window marker old note.\",\"createdAt\":\"2026-01-01T10:00:00Z\"}],\"extract\":false}}",
    );
    defer std.testing.allocator.free(old);
    const fresh = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"r2\",\"method\":\"memory.remember\",\"params\":{\"scope\":{\"projectId\":\"repo:test\"},\"messages\":[{\"role\":\"user\",\"content\":\"Window marker fresh note.\",\"createdAt\":\"2026-02-01T10:00:00Z\"}],\"extract\":false}}",
    );
    defer std.testing.allocator.free(fresh);

    const windowed = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"q1\",\"method\":\"memory.retrieve\",\"params\":{\"query\":\"window marker\",\"scope\":{\"projectId\":\"repo:test\"},\"needs\":[\"raw\"],\"time\":{\"eventWindowStart\":\"2026-01-15T00:00:00Z\"}}}",
    );
    defer std.testing.allocator.free(windowed);
    try std.testing.expect(std.mem.indexOf(u8, windowed, "Window marker fresh note.") != null);
    try std.testing.expect(std.mem.indexOf(u8, windowed, "Window marker old note.") == null);

    const budgeted = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"q2\",\"method\":\"memory.retrieve\",\"params\":{\"query\":\"window marker\",\"scope\":{\"projectId\":\"repo:test\"},\"needs\":[\"raw\"],\"budgetTokens\":1,\"options\":{\"includeDebug\":true}}}",
    );
    defer std.testing.allocator.free(budgeted);
    try std.testing.expect(std.mem.indexOf(u8, budgeted, "\"token_budget_truncated\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, budgeted, "\"no_memory_items\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, budgeted, "\"droppedForBudget\":2") != null);
}

test "runtime validAt excludes future raw messages" {
    var harness = try RuntimeTestHarness.init(std.testing.allocator);
    defer harness.deinit();
    var runtime = Runtime.init(harness.adapter(), harness.health());
    defer runtime.deinit();

    const old = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"r1\",\"method\":\"memory.remember\",\"params\":{\"scope\":{\"projectId\":\"repo:test\"},\"messages\":[{\"role\":\"user\",\"content\":\"Temporal raw old marker.\",\"createdAt\":\"2026-01-01T10:00:00Z\"}],\"extract\":false}}",
    );
    defer std.testing.allocator.free(old);
    const future = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"r2\",\"method\":\"memory.remember\",\"params\":{\"scope\":{\"projectId\":\"repo:test\"},\"messages\":[{\"role\":\"user\",\"content\":\"Temporal raw future marker.\",\"createdAt\":\"2026-03-01T10:00:00Z\"}],\"extract\":false}}",
    );
    defer std.testing.allocator.free(future);

    const retrieve = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"q1\",\"method\":\"memory.retrieve\",\"params\":{\"query\":\"Temporal raw marker\",\"scope\":{\"projectId\":\"repo:test\"},\"needs\":[\"raw\"],\"time\":{\"validAt\":\"2026-02-01T00:00:00Z\"}}}",
    );
    defer std.testing.allocator.free(retrieve);
    try std.testing.expect(std.mem.indexOf(u8, retrieve, "Temporal raw old marker.") != null);
    try std.testing.expect(std.mem.indexOf(u8, retrieve, "Temporal raw future marker.") == null);
}

test "runtime graph retrieve expands through resolved entities" {
    var harness = try RuntimeTestHarness.init(std.testing.allocator);
    defer harness.deinit();
    var runtime = Runtime.init(harness.adapter(), harness.health());
    defer runtime.deinit();

    const first = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"r1\",\"method\":\"memory.remember\",\"params\":{\"scope\":{\"userId\":\"locomo-user\"},\"messages\":[{\"role\":\"user\",\"content\":\"Alice likes ramen.\"}],\"extract\":false}}",
    );
    defer std.testing.allocator.free(first);
    const second = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"r2\",\"method\":\"memory.remember\",\"params\":{\"scope\":{\"userId\":\"locomo-user\"},\"messages\":[{\"role\":\"user\",\"content\":\"She moved to Lisbon.\"}],\"extract\":false}}",
    );
    defer std.testing.allocator.free(second);

    const aliases = [_][]const u8{"Alice"};
    const entity = providers.ResolvedEntity{
        .name = "Alice Smith",
        .entity_type = "person",
        .aliases = &aliases,
    };
    const entities = [_]providers.ResolvedEntity{entity};
    try runtime.writeEntityMentions(std.testing.allocator, .{ .user_id = "locomo-user" }, "q_msg_4", &entities);
    try runtime.writeEntityMentions(std.testing.allocator, .{ .user_id = "locomo-user" }, "q_msg_9", &entities);

    const graph = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"q1\",\"method\":\"memory.retrieve\",\"params\":{\"query\":\"Alice Smith\",\"mode\":\"graph\",\"scope\":{\"userId\":\"locomo-user\"},\"needs\":[\"raw\"]}}",
    );
    defer std.testing.allocator.free(graph);

    try std.testing.expect(std.mem.indexOf(u8, graph, "Alice likes ramen.") != null);
    try std.testing.expect(std.mem.indexOf(u8, graph, "She moved to Lisbon.") != null);
}

test "runtime answer uses retrieved context with deterministic provider fallback" {
    var harness = try RuntimeTestHarness.init(std.testing.allocator);
    defer harness.deinit();
    var runtime = Runtime.init(harness.adapter(), harness.health());
    defer runtime.deinit();

    const remember = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"r1\",\"method\":\"memory.remember\",\"params\":{\"scope\":{\"projectId\":\"repo:test\"},\"messages\":[{\"role\":\"user\",\"content\":\"Run just test before committing.\"}],\"extract\":false}}",
    );
    defer std.testing.allocator.free(remember);

    const answer = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"a1\",\"method\":\"memory.answer\",\"params\":{\"query\":\"What should I run before committing?\",\"scope\":{\"projectId\":\"repo:test\"},\"needs\":[\"raw\"],\"options\":{\"includeDebug\":true,\"logRetrieval\":false}}}",
    );
    defer std.testing.allocator.free(answer);

    try std.testing.expect(std.mem.indexOf(u8, answer, "\"answer\":\"Run just test before committing.\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, answer, "\"provider\":\"deterministic_prompt\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, answer, "\"strategy\":\"deterministic_fallback\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, answer, "\"trace\":{") != null);
}

test "runtime raw retrieve exposes message source metadata" {
    var harness = try RuntimeTestHarness.init(std.testing.allocator);
    defer harness.deinit();
    var runtime = Runtime.init(harness.adapter(), harness.health());
    defer runtime.deinit();

    const remember = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"r1\",\"method\":\"memory.remember\",\"params\":{\"scope\":{\"projectId\":\"repo:test\"},\"sessionId\":\"sess-a\",\"messages\":[{\"role\":\"user\",\"content\":\"Hello there.\",\"createdAt\":\"2026-02-01T10:00:00Z\"},{\"role\":\"assistant\",\"content\":\"Today I rescheduled the dentist appointment.\",\"createdAt\":\"2026-02-01T10:00:00Z\"}],\"extract\":false}}",
    );
    defer std.testing.allocator.free(remember);

    const retrieve = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"q1\",\"method\":\"memory.retrieve\",\"params\":{\"query\":\"dentist appointment\",\"scope\":{\"projectId\":\"repo:test\"},\"needs\":[\"raw\"],\"options\":{\"includeDebug\":true,\"logTrace\":false,\"logAudit\":false}}}",
    );
    defer std.testing.allocator.free(retrieve);
    try std.testing.expect(std.mem.indexOf(u8, retrieve, "Today I rescheduled the dentist appointment.") != null);
    try std.testing.expect(std.mem.indexOf(u8, retrieve, "\"validFrom\":\"2026-02-01T10:00:00Z\"") != null);

    var items = try runtime.collectItems(std.testing.allocator, "dentist appointment", .fts, 10, .{ .project_id = "repo:test" }, false, null, null, .{}, true, false);
    defer items.deinit();
    try std.testing.expectEqual(@as(usize, 1), items.items.items.len);
    const source = items.items.items[0].raw_source orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("assistant", source.role.?);
    try std.testing.expectEqualStrings("2026-02-01T10:00:00Z", source.created_at.?);
    try std.testing.expectEqualStrings("sess-a", source.session_id.?);
    try std.testing.expectEqualStrings("q_sess_1", source.session_qid.?);
    try std.testing.expectEqualStrings("q_turn_2", source.turn_qid.?);
    try std.testing.expectEqualStrings(items.items.items[0].qid, source.message_qid);
    try std.testing.expectEqual(@as(?i64, 1), source.message_index);
    try std.testing.expectEqual(@as(?i64, null), source.chunk_index);
}

test "runtime extracts preference memories with temporal supersession" {
    var harness = try RuntimeTestHarness.init(std.testing.allocator);
    defer harness.deinit();
    var runtime = Runtime.init(harness.adapter(), harness.health());
    defer runtime.deinit();

    const concise = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"r1\",\"method\":\"memory.remember\",\"params\":{\"scope\":{\"userId\":\"user-local\"},\"messages\":[{\"role\":\"user\",\"content\":\"Please be concise in future responses.\",\"createdAt\":\"2026-01-01T10:00:00Z\"}]}}",
    );
    defer std.testing.allocator.free(concise);

    const detailed = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"r2\",\"method\":\"memory.remember\",\"params\":{\"scope\":{\"userId\":\"user-local\"},\"messages\":[{\"role\":\"user\",\"content\":\"I prefer detailed responses now.\",\"createdAt\":\"2026-02-01T10:00:00Z\"}]}}",
    );
    defer std.testing.allocator.free(detailed);

    const current = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"q1\",\"method\":\"memory.retrieve\",\"params\":{\"query\":\"response style\",\"scope\":{\"userId\":\"user-local\"},\"needs\":[\"preferences\"]}}",
    );
    defer std.testing.allocator.free(current);
    try std.testing.expect(std.mem.indexOf(u8, current, "\"preferences\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, current, "The user prefers detailed responses.") != null);
    try std.testing.expect(std.mem.indexOf(u8, current, "The user prefers concise responses.") == null);

    const historical = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"q2\",\"method\":\"memory.retrieve\",\"params\":{\"query\":\"response style\",\"scope\":{\"userId\":\"user-local\"},\"needs\":[\"preferences\"],\"time\":{\"validAt\":\"2026-01-15T10:00:00Z\"}}}",
    );
    defer std.testing.allocator.free(historical);
    try std.testing.expect(std.mem.indexOf(u8, historical, "The user prefers concise responses.") != null);
    try std.testing.expect(std.mem.indexOf(u8, historical, "The user prefers detailed responses.") == null);

    const inspect = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"i1\",\"method\":\"memory.inspect\",\"params\":{\"qid\":\"q_pref_6\",\"includeProvenance\":true}}",
    );
    defer std.testing.allocator.free(inspect);
    try std.testing.expect(std.mem.indexOf(u8, inspect, "\"relation\":\"evidenced_by\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, inspect, "\"qid\":\"q_msg_4\"") != null);
}

test "runtime rejects invalid extractor candidates before writes" {
    var harness = try RuntimeTestHarness.init(std.testing.allocator);
    defer harness.deinit();
    var runtime = Runtime.init(harness.adapter(), harness.health());
    defer runtime.deinit();

    const invalid = extractor.Candidate{
        .label = .fact,
        .slot_key = "user.response_style",
        .value = "concise",
        .text = "The user prefers concise responses.",
    };
    try std.testing.expectError(
        error.InvalidExtractionCandidate,
        runtime.writeExtractedMemory(std.testing.allocator, .{}, "q_msg_missing", "bad candidate", "2026-01-01T10:00:00Z", invalid),
    );

    const search = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"s1\",\"method\":\"memory.search\",\"params\":{\"query\":\"concise\",\"scope\":{}}}",
    );
    defer std.testing.allocator.free(search);
    try std.testing.expect(std.mem.indexOf(u8, search, "The user prefers concise responses.") == null);
}

test "runtime forgetting raw evidence invalidates derived facts" {
    var harness = try RuntimeTestHarness.init(std.testing.allocator);
    defer harness.deinit();
    var runtime = Runtime.init(harness.adapter(), harness.health());
    defer runtime.deinit();

    const remember = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"r1\",\"method\":\"memory.remember\",\"params\":{\"scope\":{\"projectId\":\"repo:test\"},\"messages\":[{\"role\":\"user\",\"content\":\"This repo uses pnpm.\"}]}}",
    );
    defer std.testing.allocator.free(remember);

    const inspect_message = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"i1\",\"method\":\"memory.inspect\",\"params\":{\"qid\":\"q_msg_4\",\"includeDependents\":true}}",
    );
    defer std.testing.allocator.free(inspect_message);
    try std.testing.expect(std.mem.indexOf(u8, inspect_message, "\"relation\":\"derived_from\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, inspect_message, "\"qid\":\"q_fact_6\"") != null);

    const inspect_fact = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"i2\",\"method\":\"memory.inspect\",\"params\":{\"qid\":\"q_fact_6\",\"includeProvenance\":true}}",
    );
    defer std.testing.allocator.free(inspect_fact);
    try std.testing.expect(std.mem.indexOf(u8, inspect_fact, "\"relation\":\"evidenced_by\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, inspect_fact, "\"qid\":\"q_msg_4\"") != null);

    const dry_run = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"f0\",\"method\":\"memory.forget\",\"params\":{\"mode\":\"hard_delete\",\"selector\":{\"qids\":[\"q_msg_4\"]},\"dryRun\":true,\"reason\":\"test\"}}",
    );
    defer std.testing.allocator.free(dry_run);
    try std.testing.expect(std.mem.indexOf(u8, dry_run, "\"status\":\"planned\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, dry_run, "\"nodesDeleted\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, dry_run, "\"factsInvalidated\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, dry_run, "\"action\":\"would_invalidate\"") != null);

    const forget = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"f1\",\"method\":\"memory.forget\",\"params\":{\"mode\":\"hard_delete\",\"selector\":{\"qids\":[\"q_msg_4\"]},\"dryRun\":false,\"reason\":\"test\"}}",
    );
    defer std.testing.allocator.free(forget);
    try std.testing.expect(std.mem.indexOf(u8, forget, "\"factsInvalidated\":1") != null);

    const retrieve = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"q1\",\"method\":\"memory.retrieve\",\"params\":{\"query\":\"package manager\",\"scope\":{\"projectId\":\"repo:test\"}}}",
    );
    defer std.testing.allocator.free(retrieve);
    try std.testing.expect(std.mem.indexOf(u8, retrieve, "The repo uses pnpm as its package manager.") == null);

    const issues = try harness.adapter().verify(std.testing.allocator);
    defer freeVerificationIssues(std.testing.allocator, issues);
    try std.testing.expectEqual(@as(usize, 0), issues.len);
}

test "runtime forget supports redaction state" {
    var harness = try RuntimeTestHarness.init(std.testing.allocator);
    defer harness.deinit();
    var runtime = Runtime.init(harness.adapter(), harness.health());
    defer runtime.deinit();

    const remember = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"r1\",\"method\":\"memory.remember\",\"params\":{\"scope\":{\"projectId\":\"repo:test\"},\"messages\":[{\"role\":\"user\",\"content\":\"Redact this private note.\"}],\"extract\":false}}",
    );
    defer std.testing.allocator.free(remember);

    const forget = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"f1\",\"method\":\"memory.forget\",\"params\":{\"mode\":\"redact\",\"selector\":{\"qids\":[\"q_msg_4\"]},\"dryRun\":false,\"reason\":\"test\"}}",
    );
    defer std.testing.allocator.free(forget);
    try std.testing.expect(std.mem.indexOf(u8, forget, "\"nodesDeleted\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, forget, "\"nodesRedacted\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, forget, "\"action\":\"redacted\"") != null);

    const inspect = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"i1\",\"method\":\"memory.inspect\",\"params\":{\"qid\":\"q_msg_4\"}}",
    );
    defer std.testing.allocator.free(inspect);
    try std.testing.expect(std.mem.indexOf(u8, inspect, "\\\"state\\\":\\\"redacted\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, inspect, "Redact this private note.") == null);

    const issues = try harness.adapter().verify(std.testing.allocator);
    defer freeVerificationIssues(std.testing.allocator, issues);
    try std.testing.expectEqual(@as(usize, 0), issues.len);
}

test "message chunk boundaries reassemble exactly and prefer natural breaks" {
    const allocator = std.testing.allocator;

    const short = "short message";
    const short_ends = try messageChunkEnds(allocator, short);
    defer allocator.free(short_ends);
    try std.testing.expectEqual(@as(usize, 1), short_ends.len);
    try std.testing.expectEqual(short.len, short_ends[0]);

    const exact = "x" ** message_chunk_max_bytes;
    const exact_ends = try messageChunkEnds(allocator, exact);
    defer allocator.free(exact_ends);
    try std.testing.expectEqual(@as(usize, 1), exact_ends.len);

    const Case = struct { content: []const u8, first_end: usize };
    const cases = [_]Case{
        // Paragraph break wins over the later sentence end.
        .{ .content = "a" ** 1000 ++ "\n\n" ++ "b" ** 100 ++ ". " ++ "c" ** 400, .first_end = 1002 },
        // Sentence end wins over later whitespace.
        .{ .content = "a" ** 1100 ++ ". " ++ "b" ** 50 ++ " " ++ "c" ** 400, .first_end = 1102 },
        // Whitespace when there is no sentence or paragraph break.
        .{ .content = "a" ** 1150 ++ " " ++ "b" ** 400, .first_end = 1151 },
        // A break before the boundary window is ignored: hard cut at the limit.
        .{ .content = "a" ** 900 ++ " " ++ "b" ** 900, .first_end = 1200 },
    };
    for (cases) |case| {
        const ends = try messageChunkEnds(allocator, case.content);
        defer allocator.free(ends);
        try std.testing.expect(ends.len >= 2);
        try std.testing.expectEqual(case.first_end, ends[0]);
        try expectChunksReassemble(allocator, case.content, ends);
    }
}

test "message chunk boundaries never split a UTF-8 codepoint" {
    const allocator = std.testing.allocator;
    const contents = [_][]const u8{
        "a" ++ "€" ** 1000, // 3-byte codepoints straddling the limit
        "ab" ++ "😀" ** 800, // 4-byte codepoints straddling the limit
        "é" ** 1500,
    };
    for (contents) |content| {
        const ends = try messageChunkEnds(allocator, content);
        defer allocator.free(ends);
        try std.testing.expect(ends.len >= 2);
        var start: usize = 0;
        for (ends) |end| {
            try std.testing.expect(end - start <= message_chunk_max_bytes);
            try std.testing.expect(std.unicode.utf8ValidateSlice(content[start..end]));
            start = end;
        }
        try expectChunksReassemble(allocator, content, ends);
    }
}

fn expectChunksReassemble(allocator: std.mem.Allocator, content: []const u8, ends: []const usize) !void {
    var rebuilt = std.ArrayList(u8).empty;
    defer rebuilt.deinit(allocator);
    var start: usize = 0;
    for (ends) |end| {
        try std.testing.expect(end > start);
        try rebuilt.appendSlice(allocator, content[start..end]);
        start = end;
    }
    try std.testing.expectEqualStrings(content, rebuilt.items);
}

test "rrf fuses channels by rank after sorting each by score" {
    const allocator = std.testing.allocator;
    // Channels arrive out of score order; fusion must rank by score, not position.
    var lexical = [_]storage.SearchHit{
        .{ .qid = "b", .score = 1.0 },
        .{ .qid = "a", .score = 9.0 },
        .{ .qid = "c", .score = 4.0 },
    };
    var semantic = [_]storage.SearchHit{
        .{ .qid = "c", .score = 0.4 },
        .{ .qid = "a", .score = 0.9 },
    };
    const fused = try fuseRankedHits(allocator, &.{ &lexical, &semantic }, 10);
    defer freeHits(allocator, fused);
    try std.testing.expectEqual(@as(usize, 3), fused.len);
    try std.testing.expectEqualStrings("a", fused[0].qid);
    try std.testing.expectEqualStrings("c", fused[1].qid);
    try std.testing.expectEqualStrings("b", fused[2].qid);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0 / 61.0), fused[0].score, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0 / 62.0), fused[1].score, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0 / 63.0), fused[2].score, 1e-6);

    const top = try fuseRankedHits(allocator, &.{ &lexical, &semantic }, 1);
    defer freeHits(allocator, top);
    try std.testing.expectEqual(@as(usize, 1), top.len);
    try std.testing.expectEqualStrings("a", top[0].qid);
}

test "estimate item tokens uses bytes over 4.2 plus line overhead" {
    try std.testing.expectEqual(@as(usize, 16), estimateItemTokens(.{ .qid = "q", .type = "message", .text = "", .score = 1 }));
    try std.testing.expectEqual(@as(usize, 17), estimateItemTokens(.{ .qid = "q", .type = "message", .text = "abc", .score = 1 }));
    try std.testing.expectEqual(@as(usize, 18), estimateItemTokens(.{ .qid = "q", .type = "message", .text = "abcdefg", .score = 1 }));
    try std.testing.expectEqual(@as(usize, 1016), estimateItemTokens(.{ .qid = "q", .type = "message", .text = "a" ** 4200, .score = 1 }));
}

/// About 3 KB of sentences: "quokka" opens the first chunk and "zanzibar"
/// closes the last one.
fn testLongContent(allocator: std.mem.Allocator) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    try writer.writer.writeAll("The quokka sanctuary visit was lovely. ");
    var index: usize = 0;
    while (index < 60) : (index += 1) {
        try writer.writer.print("Filler sentence number {d} talks about the weather. ", .{index});
    }
    try writer.writer.writeAll("We finally booked the zanzibar ferry for June.");
    return writer.toOwnedSlice();
}

fn rememberLongMessage(runtime: *Runtime, allocator: std.mem.Allocator, content: []const u8) !void {
    const request = try std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":\"r1\",\"method\":\"memory.remember\",\"params\":{{\"scope\":{{\"projectId\":\"repo:test\"}},\"sessionId\":\"sess-long\",\"messages\":[{{\"role\":\"user\",\"content\":\"{s}\",\"createdAt\":\"2026-03-01T10:00:00Z\"}},{{\"role\":\"assistant\",\"content\":\"Noted the short reply.\",\"createdAt\":\"2026-03-01T10:00:05Z\"}}],\"extract\":false}}}}",
        .{content},
    );
    defer allocator.free(request);
    const response = try runtime.dispatch(allocator, request);
    defer allocator.free(response);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"messageQids\":[\"q_msg_4\",\"q_msg_6\"]") != null);
}

fn testChunkCount(store: storage.Adapter, allocator: std.mem.Allocator, message_qid: []const u8) !usize {
    const node = (try store.getNode(allocator, message_qid)) orelse return error.TestUnexpectedResult;
    defer store.freeNode(allocator, node);
    const count = (try readOptionalPropertyInt(allocator, node.properties_json, "chunkCount")) orelse return error.TestUnexpectedResult;
    return @intCast(count);
}

test "speaker roles add a searchText prefix and generic roles do not" {
    const allocator = std.testing.allocator;
    try std.testing.expect(speakerNamesRole("Caroline"));
    try std.testing.expect(!speakerNamesRole("user"));
    try std.testing.expect(!speakerNamesRole("Assistant"));
    try std.testing.expect(!speakerNamesRole(" "));

    const named = try withSpeakerSearchText(allocator, "{\"kind\":\"message\"}", "Caroline", "I went to a \"pride\" parade.");
    defer allocator.free(named);
    try std.testing.expectEqualStrings("{\"searchText\":\"Caroline: I went to a \\\"pride\\\" parade.\",\"kind\":\"message\"}", named);
    const generic = try withSpeakerSearchText(allocator, "{\"kind\":\"message\"}", "user", "hello");
    defer allocator.free(generic);
    try std.testing.expectEqualStrings("{\"kind\":\"message\"}", generic);
}

test "runtime finds a speaker's own lines by name" {
    const allocator = std.testing.allocator;
    var harness = try RuntimeTestHarness.init(allocator);
    defer harness.deinit();
    const store = harness.adapter();
    var runtime = Runtime.init(store, harness.health());
    defer runtime.deinit();

    const remembered = try runtime.dispatch(
        allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"r1\",\"method\":\"memory.remember\",\"params\":{\"scope\":{\"userId\":\"u1\"},\"sessionId\":\"s1\",\"extract\":false,\"messages\":[{\"role\":\"Caroline\",\"content\":\"I signed up for the pottery workshop.\",\"createdAt\":\"2023-05-08T13:56:00Z\"},{\"role\":\"Melanie\",\"content\":\"Sounds fun, enjoy the clay!\",\"createdAt\":\"2023-05-08T13:56:01Z\"},{\"role\":\"user\",\"content\":\"A generic line about pottery.\",\"createdAt\":\"2023-05-08T13:56:02Z\"}]}}",
    );
    defer allocator.free(remembered);

    const hits = try store.fullTextSearch(allocator, .{ .text = "Caroline", .limit = 10 });
    defer {
        for (hits) |hit| allocator.free(hit.qid);
        allocator.free(hits);
    }
    try std.testing.expectEqual(@as(usize, 1), hits.len);
    const caroline = (try store.getNode(allocator, hits[0].qid)) orelse return error.TestUnexpectedResult;
    defer store.freeNode(allocator, caroline);
    try std.testing.expect(try propertyEquals(allocator, caroline.properties_json, "role", "Caroline"));
    try std.testing.expect(try propertyEquals(allocator, caroline.properties_json, "content", "I signed up for the pottery workshop."));

    // Generic roles keep content-only indexing.
    const generic_hits = try store.fullTextSearch(allocator, .{ .text = "generic", .limit = 10 });
    defer {
        for (generic_hits) |hit| allocator.free(hit.qid);
        allocator.free(generic_hits);
    }
    try std.testing.expectEqual(@as(usize, 1), generic_hits.len);
    const generic = (try store.getNode(allocator, generic_hits[0].qid)) orelse return error.TestUnexpectedResult;
    defer store.freeNode(allocator, generic);
    try std.testing.expect(std.mem.indexOf(u8, generic.properties_json, "searchText") == null);
}

test "runtime chunks long messages and maps chunk hits to the parent message" {
    const allocator = std.testing.allocator;
    var harness = try RuntimeTestHarness.init(allocator);
    defer harness.deinit();
    const store = harness.adapter();
    var runtime = Runtime.init(store, harness.health());
    defer runtime.deinit();

    const content = try testLongContent(allocator);
    defer allocator.free(content);
    try rememberLongMessage(&runtime, allocator, content);

    const message = (try store.getNode(allocator, "q_msg_4")) orelse return error.TestUnexpectedResult;
    defer store.freeNode(allocator, message);
    try std.testing.expect(try propertyIsFalse(allocator, message.properties_json, "searchable"));
    try std.testing.expect(try propertyEquals(allocator, message.properties_json, "sessionId", "sess-long"));
    try std.testing.expectEqual(@as(?i64, 0), try readOptionalPropertyInt(allocator, message.properties_json, "messageIndex"));
    const short = (try store.getNode(allocator, "q_msg_6")) orelse return error.TestUnexpectedResult;
    defer store.freeNode(allocator, short);
    try std.testing.expect(!try propertyIsFalse(allocator, short.properties_json, "searchable"));
    try std.testing.expectEqual(@as(?i64, 1), try readOptionalPropertyInt(allocator, short.properties_json, "messageIndex"));

    // Chunks hold the full raw text, linked both ways to the message.
    const chunk_count = try testChunkCount(store, allocator, "q_msg_4");
    try std.testing.expectEqual(@as(usize, 3), chunk_count);
    var rebuilt = std.ArrayList(u8).empty;
    defer rebuilt.deinit(allocator);
    for (0..chunk_count) |index| {
        const qid = try chunkQid(allocator, "q_msg_4", index);
        defer allocator.free(qid);
        const chunk = (try store.getNode(allocator, qid)) orelse return error.TestUnexpectedResult;
        defer store.freeNode(allocator, chunk);
        try std.testing.expectEqualStrings("Chunk", chunk.label);
        try std.testing.expect(try propertyEquals(allocator, chunk.properties_json, "messageQid", "q_msg_4"));
        try std.testing.expect(try propertyEquals(allocator, chunk.properties_json, "turnQid", "q_turn_2"));
        const text = try readPropertyString(allocator, chunk.properties_json, "content");
        defer allocator.free(text);
        try rebuilt.appendSlice(allocator, text);
    }
    try std.testing.expectEqualStrings(content, rebuilt.items);
    const has_chunk = try store.findEdges(allocator, .{ .from_qid = "q_msg_4", .edge_type = "HAS_CHUNK" });
    defer store.freeEdges(allocator, has_chunk);
    try std.testing.expectEqual(chunk_count, has_chunk.len);
    const evidenced_by = try store.findEdges(allocator, .{ .to_qid = "q_msg_4", .edge_type = "EVIDENCED_BY" });
    defer store.freeEdges(allocator, evidenced_by);
    try std.testing.expectEqual(chunk_count, evidenced_by.len);

    // A hit in the last chunk is a raw message item whose evidence is the parent.
    const search = try runtime.dispatch(
        allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"s1\",\"method\":\"memory.search\",\"params\":{\"query\":\"zanzibar ferry\",\"scope\":{\"projectId\":\"repo:test\"}}}",
    );
    defer allocator.free(search);
    try std.testing.expect(std.mem.indexOf(u8, search, "\"qid\":\"q_chunk_4_2\",\"type\":\"message\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, search, "\"evidence\":[{\"qid\":\"q_msg_4\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, search, "\"qid\":\"q_msg_4\",\"type\"") == null);

    var items = try runtime.collectItems(allocator, "zanzibar ferry", .fts, 10, .{ .project_id = "repo:test" }, false, null, null, .{}, true, false);
    defer items.deinit();
    try std.testing.expectEqual(@as(usize, 1), items.items.items.len);
    const source = items.items.items[0].raw_source orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("q_msg_4", source.message_qid);
    try std.testing.expectEqual(@as(?i64, 2), source.chunk_index);
    try std.testing.expectEqual(@as(?i64, 3), source.chunk_count);
    try std.testing.expectEqual(@as(?i64, 0), source.message_index);
    try std.testing.expectEqualStrings("user", source.role.?);
    try std.testing.expectEqualStrings("sess-long", source.session_id.?);

    // Session and Turn containers never surface as items.
    const retrieve = try runtime.dispatch(
        allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"q1\",\"method\":\"memory.retrieve\",\"params\":{\"query\":\"quokka sanctuary short reply\",\"scope\":{\"projectId\":\"repo:test\"},\"options\":{\"logRetrieval\":false,\"logAudit\":false}}}",
    );
    defer allocator.free(retrieve);
    try std.testing.expect(std.mem.indexOf(u8, retrieve, "\"qid\":\"q_chunk_4_0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, retrieve, "Noted the short reply.") != null);
    try std.testing.expect(std.mem.indexOf(u8, retrieve, "\"text\":\"Session\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, retrieve, "\"text\":\"Turn\"") == null);

    // Graph expansion through an entity mentioned by a chunked message lands on its chunks.
    const entity = providers.ResolvedEntity{ .name = "Quokka Sanctuary", .entity_type = "place", .aliases = &.{} };
    try runtime.writeEntityMentions(allocator, .{ .project_id = "repo:test" }, "q_msg_4", &[_]providers.ResolvedEntity{entity});
    var graph_items = try runtime.collectItems(allocator, "Quokka Sanctuary", .graph, 10, .{ .project_id = "repo:test" }, false, null, null, .{}, true, false);
    defer graph_items.deinit();
    var graph_chunks: usize = 0;
    for (graph_items.items.items) |item| {
        try std.testing.expect(!std.mem.eql(u8, item.qid, "q_msg_4"));
        if (std.mem.startsWith(u8, item.qid, "q_chunk_4_")) graph_chunks += 1;
    }
    try std.testing.expectEqual(chunk_count, graph_chunks);
}

test "runtime retrieve sorts lexical candidates by BM25 score" {
    var harness = try RuntimeTestHarness.init(std.testing.allocator);
    defer harness.deinit();
    var runtime = Runtime.init(harness.adapter(), harness.health());
    defer runtime.deinit();

    const remember = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"r1\",\"method\":\"memory.remember\",\"params\":{\"scope\":{\"projectId\":\"repo:rank\"},\"messages\":[{\"role\":\"user\",\"content\":\"I baked an apple pie with grandma on Sunday.\"},{\"role\":\"user\",\"content\":\"The apple tart was too sweet.\"},{\"role\":\"user\",\"content\":\"A zebra apple is a rare heirloom variety.\"}],\"extract\":false}}",
    );
    defer std.testing.allocator.free(remember);

    var items = try runtime.collectItems(std.testing.allocator, "zebra apple", .fts, 10, .{ .project_id = "repo:rank" }, false, null, null, .{}, true, false);
    defer items.deinit();
    try std.testing.expectEqual(@as(usize, 3), items.items.items.len);
    try std.testing.expectEqualStrings("A zebra apple is a rare heirloom variety.", items.items.items[0].text);
    for (items.items.items[1..], 1..) |item, index| {
        try std.testing.expect(item.score <= items.items.items[index - 1].score);
    }
}

test "runtime raw evidence competes with derived memory and only stale evidence is dropped" {
    var harness = try RuntimeTestHarness.init(std.testing.allocator);
    defer harness.deinit();
    var runtime = Runtime.init(harness.adapter(), harness.health());
    defer runtime.deinit();

    const requests = [_][]const u8{
        "{\"jsonrpc\":\"2.0\",\"id\":\"r1\",\"method\":\"memory.remember\",\"params\":{\"scope\":{\"projectId\":\"repo:test\"},\"messages\":[{\"role\":\"user\",\"content\":\"This repo uses npm.\",\"createdAt\":\"2026-01-01T10:00:00Z\"}]}}",
        "{\"jsonrpc\":\"2.0\",\"id\":\"r2\",\"method\":\"memory.remember\",\"params\":{\"scope\":{\"projectId\":\"repo:test\"},\"messages\":[{\"role\":\"user\",\"content\":\"We migrated this repo to pnpm. Use pnpm now.\",\"createdAt\":\"2026-02-01T10:00:00Z\"}]}}",
        "{\"jsonrpc\":\"2.0\",\"id\":\"r3\",\"method\":\"memory.remember\",\"params\":{\"scope\":{\"projectId\":\"repo:test\"},\"messages\":[{\"role\":\"user\",\"content\":\"My cat is named Biscuit.\",\"createdAt\":\"2026-02-02T10:00:00Z\"}]}}",
    };
    for (requests) |request| {
        const response = try runtime.dispatch(std.testing.allocator, request);
        std.testing.allocator.free(response);
    }

    // Raw evidence stays next to the current fact; the superseded npm
    // evidence is dropped because the current slot version is present.
    const current = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"q1\",\"method\":\"memory.retrieve\",\"params\":{\"query\":\"Which package manager does this repo use: npm or pnpm?\",\"scope\":{\"projectId\":\"repo:test\"},\"options\":{\"logRetrieval\":false,\"logAudit\":false}}}",
    );
    defer std.testing.allocator.free(current);
    try std.testing.expect(std.mem.indexOf(u8, current, "The repo uses pnpm as its package manager.") != null);
    try std.testing.expect(std.mem.indexOf(u8, current, "We migrated this repo to pnpm. Use pnpm now.") != null);
    try std.testing.expect(std.mem.indexOf(u8, current, "This repo uses npm.") == null);
    try std.testing.expect(std.mem.indexOf(u8, current, "\"type\":\"memory_card\"") == null);

    // An unrelated derived item no longer suppresses raw evidence.
    const unrelated = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"q2\",\"method\":\"memory.retrieve\",\"params\":{\"query\":\"package manager cat Biscuit\",\"scope\":{\"projectId\":\"repo:test\"},\"options\":{\"logRetrieval\":false,\"logAudit\":false}}}",
    );
    defer std.testing.allocator.free(unrelated);
    try std.testing.expect(std.mem.indexOf(u8, unrelated, "The repo uses pnpm as its package manager.") != null);
    try std.testing.expect(std.mem.indexOf(u8, unrelated, "My cat is named Biscuit.") != null);

    // At a time when npm was current, its evidence is not stale.
    const historical = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"q3\",\"method\":\"memory.retrieve\",\"params\":{\"query\":\"Which package manager does this repo use: npm or pnpm?\",\"scope\":{\"projectId\":\"repo:test\"},\"time\":{\"validAt\":\"2026-01-15T10:00:00Z\"},\"options\":{\"logRetrieval\":false,\"logAudit\":false}}}",
    );
    defer std.testing.allocator.free(historical);
    try std.testing.expect(std.mem.indexOf(u8, historical, "The repo uses npm as its package manager.") != null);
    try std.testing.expect(std.mem.indexOf(u8, historical, "This repo uses npm.") != null);
    try std.testing.expect(std.mem.indexOf(u8, historical, "pnpm") == null);
}

test "runtime retrieve defaults to a 4096 token budget" {
    var harness = try RuntimeTestHarness.init(std.testing.allocator);
    defer harness.deinit();
    var runtime = Runtime.init(harness.adapter(), harness.health());
    defer runtime.deinit();

    const remember = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"r1\",\"method\":\"memory.remember\",\"params\":{\"messages\":[{\"role\":\"user\",\"content\":\"Budget marker note.\"}],\"extract\":false}}",
    );
    defer std.testing.allocator.free(remember);
    const retrieve = try runtime.dispatch(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"q1\",\"method\":\"memory.retrieve\",\"params\":{\"query\":\"budget marker\",\"options\":{\"includeDebug\":true,\"logRetrieval\":false,\"logAudit\":false}}}",
    );
    defer std.testing.allocator.free(retrieve);
    try std.testing.expect(std.mem.indexOf(u8, retrieve, "\"budgetTokens\":4096") != null);
    try std.testing.expect(std.mem.indexOf(u8, retrieve, "Budget marker note.") != null);
}

const forgotten_sentence = "We finally booked the zanzibar ferry for June.";

fn expectLongMessageForgotten(runtime: *Runtime, store: storage.Adapter, allocator: std.mem.Allocator, chunk_count: usize) !void {
    for (0..chunk_count) |index| {
        const qid = try chunkQid(allocator, "q_msg_4", index);
        defer allocator.free(qid);
        const chunk = (try store.getNode(allocator, qid)) orelse return error.TestUnexpectedResult;
        defer store.freeNode(allocator, chunk);
        try std.testing.expect(try propertyBool(allocator, chunk.properties_json, "deleted"));
        try std.testing.expect(std.mem.indexOf(u8, chunk.properties_json, "content") == null);
    }
    const message = (try store.getNode(allocator, "q_msg_4")) orelse return error.TestUnexpectedResult;
    defer store.freeNode(allocator, message);
    try std.testing.expect(try propertyBool(allocator, message.properties_json, "deleted"));

    const requests = [_][]const u8{
        "{\"jsonrpc\":\"2.0\",\"id\":\"s1\",\"method\":\"memory.search\",\"params\":{\"query\":\"zanzibar ferry quokka\",\"scope\":{\"projectId\":\"repo:test\"}}}",
        "{\"jsonrpc\":\"2.0\",\"id\":\"q1\",\"method\":\"memory.retrieve\",\"params\":{\"query\":\"zanzibar ferry quokka\",\"scope\":{\"projectId\":\"repo:test\"},\"options\":{\"logRetrieval\":false,\"logAudit\":false}}}",
        "{\"jsonrpc\":\"2.0\",\"id\":\"q2\",\"method\":\"memory.retrieve\",\"params\":{\"query\":\"zanzibar ferry quokka\",\"scope\":{\"projectId\":\"repo:test\"},\"needs\":[\"raw\"],\"mode\":\"graph\",\"options\":{\"logRetrieval\":false,\"logAudit\":false}}}",
        "{\"jsonrpc\":\"2.0\",\"id\":\"a1\",\"method\":\"memory.answer\",\"params\":{\"query\":\"When is the zanzibar ferry booked?\",\"scope\":{\"projectId\":\"repo:test\"},\"options\":{\"logRetrieval\":false}}}",
    };
    for (requests) |request| {
        const response = try runtime.dispatch(allocator, request);
        defer allocator.free(response);
        try std.testing.expect(std.mem.indexOf(u8, response, "\"error\"") == null);
        try std.testing.expect(std.mem.indexOf(u8, response, forgotten_sentence) == null);
        try std.testing.expect(std.mem.indexOf(u8, response, "quokka sanctuary") == null);
        try std.testing.expect(std.mem.indexOf(u8, response, "Filler sentence") == null);
    }
}

test "runtime forgetting a message by qid forgets all of its chunks" {
    const allocator = std.testing.allocator;
    var harness = try RuntimeTestHarness.init(allocator);
    defer harness.deinit();
    const store = harness.adapter();
    var runtime = Runtime.init(store, harness.health());
    defer runtime.deinit();

    const content = try testLongContent(allocator);
    defer allocator.free(content);
    try rememberLongMessage(&runtime, allocator, content);
    const chunk_count = try testChunkCount(store, allocator, "q_msg_4");

    const dry_run = try runtime.dispatch(
        allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"f0\",\"method\":\"memory.forget\",\"params\":{\"mode\":\"hard_delete\",\"selector\":{\"qids\":[\"q_msg_4\"]},\"dryRun\":true,\"reason\":\"test\"}}",
    );
    defer allocator.free(dry_run);
    try std.testing.expect(std.mem.indexOf(u8, dry_run, "{\"qid\":\"q_chunk_4_2\",\"type\":\"chunk\",\"action\":\"would_delete\"}") != null);

    const forget = try runtime.dispatch(
        allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"f1\",\"method\":\"memory.forget\",\"params\":{\"mode\":\"hard_delete\",\"selector\":{\"qids\":[\"q_msg_4\"]},\"dryRun\":false,\"reason\":\"test\"}}",
    );
    defer allocator.free(forget);
    try std.testing.expect(std.mem.indexOf(u8, forget, "\"rootsMatched\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, forget, "\"nodesDeleted\":4") != null);
    try std.testing.expect(std.mem.indexOf(u8, forget, "{\"qid\":\"q_chunk_4_0\",\"type\":\"chunk\",\"action\":\"deleted\"}") != null);
    try expectLongMessageForgotten(&runtime, store, allocator, chunk_count);

    // The sibling message in the same turn is untouched.
    const sibling = try runtime.dispatch(
        allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"s2\",\"method\":\"memory.search\",\"params\":{\"query\":\"short reply\",\"scope\":{\"projectId\":\"repo:test\"}}}",
    );
    defer allocator.free(sibling);
    try std.testing.expect(std.mem.indexOf(u8, sibling, "Noted the short reply.") != null);

    const issues = try store.verify(allocator);
    defer freeVerificationIssues(allocator, issues);
    try std.testing.expectEqual(@as(usize, 0), issues.len);
}

test "runtime forget query hitting a chunk forgets the whole parent message" {
    const allocator = std.testing.allocator;
    var harness = try RuntimeTestHarness.init(allocator);
    defer harness.deinit();
    const store = harness.adapter();
    var runtime = Runtime.init(store, harness.health());
    defer runtime.deinit();

    const content = try testLongContent(allocator);
    defer allocator.free(content);
    try rememberLongMessage(&runtime, allocator, content);
    const chunk_count = try testChunkCount(store, allocator, "q_msg_4");

    const forget = try runtime.dispatch(
        allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"f1\",\"method\":\"memory.forget\",\"params\":{\"mode\":\"redact\",\"selector\":{\"query\":\"zanzibar ferry\",\"scope\":{\"projectId\":\"repo:test\"}},\"dryRun\":false,\"reason\":\"test\"}}",
    );
    defer allocator.free(forget);
    try std.testing.expect(std.mem.indexOf(u8, forget, "\"rootsMatched\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, forget, "\"nodesRedacted\":4") != null);
    try std.testing.expect(std.mem.indexOf(u8, forget, "{\"qid\":\"q_msg_4\",\"type\":\"message\",\"action\":\"redacted\"}") != null);
    try expectLongMessageForgotten(&runtime, store, allocator, chunk_count);
}

test "runtime forgetting a session forgets its messages and their chunks" {
    const allocator = std.testing.allocator;
    var harness = try RuntimeTestHarness.init(allocator);
    defer harness.deinit();
    const store = harness.adapter();
    var runtime = Runtime.init(store, harness.health());
    defer runtime.deinit();

    const content = try testLongContent(allocator);
    defer allocator.free(content);
    try rememberLongMessage(&runtime, allocator, content);
    const chunk_count = try testChunkCount(store, allocator, "q_msg_4");

    const forget = try runtime.dispatch(
        allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"f1\",\"method\":\"memory.forget\",\"params\":{\"mode\":\"hard_delete\",\"selector\":{\"qids\":[\"q_sess_1\"]},\"dryRun\":false,\"reason\":\"test\"}}",
    );
    defer allocator.free(forget);
    try std.testing.expect(std.mem.indexOf(u8, forget, "\"rootsMatched\":3") != null);
    try expectLongMessageForgotten(&runtime, store, allocator, chunk_count);

    const sibling = try runtime.dispatch(
        allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"s2\",\"method\":\"memory.search\",\"params\":{\"query\":\"short reply\",\"scope\":{\"projectId\":\"repo:test\"}}}",
    );
    defer allocator.free(sibling);
    try std.testing.expect(std.mem.indexOf(u8, sibling, "Noted the short reply.") == null);
}

fn freeVerificationIssues(allocator: std.mem.Allocator, issues: []const storage.VerificationIssue) void {
    for (issues) |issue| {
        if (issue.qid) |qid| allocator.free(qid);
    }
    allocator.free(issues);
}

/// In-process extraction model for the extract worker tests: replies by
/// needle in the user turn, optionally malformed for the first calls.
const TestExtractor = struct {
    calls: usize = 0,
    replies: []const [2][]const u8 = &.{},
    malformed_first: usize = 0,
    /// The second reading never returns valid JSON.
    malformed_recall: bool = false,
    last_system: ?[]u8 = null,
    /// Every user turn, in call order.
    users: std.ArrayList([]u8) = .empty,
    last_json_mode: bool = false,

    fn endpoint(self: *TestExtractor) providers.ProviderEndpoint {
        return .{
            .kind = .callback,
            .name = "test-extractor",
            .model = "test-extract-model",
            .callback = .{ .context = self, .respond = respond },
        };
    }

    fn respond(context: ?*anyopaque, allocator: std.mem.Allocator, turn: providers.ChatTurn) anyerror![]u8 {
        const self: *TestExtractor = @ptrCast(@alignCast(context.?));
        self.calls += 1;
        if (self.last_system) |previous| std.testing.allocator.free(previous);
        self.last_system = try std.testing.allocator.dupe(u8, turn.system_prompt);
        try self.users.append(std.testing.allocator, try std.testing.allocator.dupe(u8, turn.user_content));
        self.last_json_mode = turn.json_mode;
        if (self.calls <= self.malformed_first) return allocator.dupe(u8, "{\"assertions\":[{\"text\":");
        if (self.malformed_recall and std.mem.startsWith(u8, turn.system_prompt, fact_extraction.recall_prompt)) {
            return allocator.dupe(u8, "{\"assertions\":[{\"text\":");
        }
        for (self.replies) |pair| {
            if (std.mem.indexOf(u8, turn.user_content, pair[0]) != null) return allocator.dupe(u8, pair[1]);
        }
        return allocator.dupe(u8, "{\"assertions\":[]}");
    }

    fn deinit(self: *TestExtractor) void {
        if (self.last_system) |value| std.testing.allocator.free(value);
        for (self.users.items) |value| std.testing.allocator.free(value);
        self.users.deinit(std.testing.allocator);
    }

    fn userContaining(self: *const TestExtractor, needle: []const u8) ?[]const u8 {
        for (self.users.items) |user| {
            if (std.mem.indexOf(u8, user, needle) != null) return user;
        }
        return null;
    }
};

const flat_reply =
    \\{"assertions":[
    \\{"text":"The user received the keys to a new apartment.","messageIndex":0,"quote":"Got the keys to the new flat","eventDate":"2023-03-03"},
    \\{"text":"The landlord left the user a bottle of wine.","messageIndex":1,"quote":"The landlord left a bottle of wine"},
    \\{"text":"The user was given a case of wine.","messageIndex":5,"quote":"a case of wine"},
    \\{"text":"The user moved in on March 9.","messageIndex":0,"quote":"Got the keys","eventDate":"2023-03-09"}
    \\]}
;
const kyoto_reply =
    \\{"assertions":[{"text":"The user plans a trip to Japan to see sakura.","messageIndex":0,"quote":"flying to Kyoto for the cherry blossoms","eventDate":"2023-04","planned":true}]}
;
const fact_test_replies = [_][2][]const u8{
    .{ "new flat", flat_reply },
    .{ "Kyoto", kyoto_reply },
};

const FactSessions = struct {
    flat_message: []u8,
    flat_job: []u8,
    kyoto_message: []u8,

    fn deinit(self: FactSessions) void {
        std.testing.allocator.free(self.flat_message);
        std.testing.allocator.free(self.flat_job);
        std.testing.allocator.free(self.kyoto_message);
    }
};

fn resultArrayFirst(allocator: std.mem.Allocator, response: []const u8, key: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(Value, allocator, response, .{});
    defer parsed.deinit();
    const array = parsed.value.object.get("result").?.object.get(key).?.array.items;
    return allocator.dupe(u8, array[0].string);
}

/// Two sessions: a short one about a new flat and one whose long user message
/// is chunked, with the Kyoto plan in its second chunk.
fn rememberFactSessions(runtime: *Runtime) !FactSessions {
    const allocator = std.testing.allocator;
    const flat = try runtime.dispatch(
        allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"r1\",\"method\":\"memory.remember\",\"params\":{\"scope\":{\"projectId\":\"repo:facts\"},\"sessionId\":\"s-flat\",\"messages\":[{\"role\":\"user\",\"content\":\"Got the keys to the new flat yesterday! The landlord left a bottle of wine.\",\"createdAt\":\"2023-03-04T09:00:00Z\"},{\"role\":\"assistant\",\"content\":\"Congratulations on the new flat! Enjoy the wine.\",\"createdAt\":\"2023-03-04T09:00:00Z\"}]}}",
    );
    defer allocator.free(flat);
    var filler: std.Io.Writer.Allocating = .init(allocator);
    defer filler.deinit();
    for (0..20) |_| try filler.writer.writeAll("We walked along the river and talked about nothing in particular. ");
    try filler.writer.writeAll("Next month I am flying to Kyoto for the cherry blossoms.");
    const request = try stringifyAlloc(allocator, .{
        .jsonrpc = "2.0",
        .id = "r2",
        .method = "memory.remember",
        .params = .{
            .scope = .{ .projectId = "repo:facts" },
            .sessionId = "s-trip",
            .messages = &[_]struct { role: []const u8, content: []const u8, createdAt: []const u8 }{
                .{ .role = "user", .content = filler.written(), .createdAt = "2023-03-10T09:00:00Z" },
            },
        },
    });
    defer allocator.free(request);
    const trip = try runtime.dispatch(allocator, request);
    defer allocator.free(trip);

    const flat_message = try resultArrayFirst(allocator, flat, "messageQids");
    errdefer allocator.free(flat_message);
    const flat_job = try resultArrayFirst(allocator, flat, "queuedJobs");
    errdefer allocator.free(flat_job);
    return .{
        .flat_message = flat_message,
        .flat_job = flat_job,
        .kyoto_message = try resultArrayFirst(allocator, trip, "messageQids"),
    };
}

fn retrieveFacts(runtime: *Runtime, query: []const u8, options_json: []const u8) ![]u8 {
    const request = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":\"q\",\"method\":\"memory.retrieve\",\"params\":{{\"query\":\"{s}\",\"scope\":{{\"projectId\":\"repo:facts\"}},\"time\":{{\"validAt\":\"2023-03-20T09:00:00Z\"}},\"options\":{{\"includeDebug\":true,\"logRetrieval\":false,\"logAudit\":false{s}}}}}}}",
        .{ query, options_json },
    );
    defer std.testing.allocator.free(request);
    return runtime.dispatch(std.testing.allocator, request);
}

fn searchAssertions(runtime: *Runtime, query: []const u8, mode: []const u8) ![]u8 {
    const request = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":\"s\",\"method\":\"memory.search\",\"params\":{{\"query\":\"{s}\",\"mode\":\"{s}\",\"scope\":{{\"projectId\":\"repo:facts\"}},\"labels\":[\"Assertion\"],\"limit\":20}}}}",
        .{ query, mode },
    );
    defer std.testing.allocator.free(request);
    return runtime.dispatch(std.testing.allocator, request);
}

fn firstResultQid(allocator: std.mem.Allocator, response: []const u8) !?[]u8 {
    var parsed = try std.json.parseFromSlice(Value, allocator, response, .{});
    defer parsed.deinit();
    const results = parsed.value.object.get("result").?.object.get("results").?.array.items;
    if (results.len == 0) return null;
    return try allocator.dupe(u8, results[0].object.get("qid").?.string);
}

test "extract worker sends the speaker-facts prompt and grounds claims into assertions" {
    const allocator = std.testing.allocator;
    var harness = try RuntimeTestHarness.init(allocator);
    defer harness.deinit();
    const store = harness.adapter();
    var extractor_model = TestExtractor{ .replies = &fact_test_replies };
    defer extractor_model.deinit();
    var runtime = Runtime.initWithOptions(store, harness.health(), .{ .extract_provider = extractor_model.endpoint() });
    defer runtime.deinit();
    const sessions = try rememberFactSessions(&runtime);
    defer sessions.deinit();

    const run = try runtime.dispatch(allocator, "{\"jsonrpc\":\"2.0\",\"id\":\"x1\",\"method\":\"memory.extract.run\",\"params\":{\"owner\":\"test\"}}");
    defer allocator.free(run);
    try std.testing.expect(std.mem.indexOf(u8, run, "\"leasedCount\":2,\"succeededCount\":2,\"failedCount\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, run, "\"model\":\"test-extract-model\",\"promptVersion\":\"quipu.extract.speaker-facts.v4\",\"calls\":2,\"jsonRetries\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, run, "\"assertionsWritten\":4") != null);
    try std.testing.expect(std.mem.indexOf(u8, run, "\"candidates\":5,\"accepted\":4,\"repaired\":1,\"duplicates\":0,\"quarantined\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, run, "\"quoteNotFound\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, run, "\"eventDates\":2,\"eventDatesRejected\":1,\"planned\":1") != null);

    // The turn: the extraction prompt in JSON mode; the user content is the
    // session date and the full text of what the speaker wrote, reassembled
    // from its chunks. The assistant's reply is not sent.
    try std.testing.expectEqualStrings(fact_extraction.system_prompt, extractor_model.last_system.?);
    try std.testing.expect(extractor_model.last_json_mode);
    const user = extractor_model.userContaining("Kyoto") orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.startsWith(u8, user, "{\"conversationTime\":\"2023-03-10T09:00:00Z\",\"messages\":[{\"role\":\"user\",\"content\":\"We walked"));
    try std.testing.expect(std.mem.endsWith(u8, user, "Next month I am flying to Kyoto for the cherry blossoms.\"}]}"));
    try std.testing.expect(std.mem.indexOf(u8, user, "repo:facts") == null);
    const flat_user = extractor_model.userContaining("new flat") orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, flat_user, "Congratulations") == null);
    const body = try providers.buildChatRequestBody(allocator, .{
        .kind = .http,
        .name = "openrouter",
        .url = "http://127.0.0.1/v1/chat/completions",
        .capabilities = .{ .supports_json_mode = true },
    }, "openai/gpt-4o-mini-2024-07-18", .{ .system_prompt = fact_extraction.system_prompt, .user_content = user, .json_mode = true });
    defer allocator.free(body);
    try std.testing.expect(std.mem.startsWith(u8, body, "{\"model\":\"openai/gpt-4o-mini-2024-07-18\",\"messages\":[{\"role\":\"system\",\"content\":\"You keep long-term memory about the people in a conversation."));
    try std.testing.expect(std.mem.indexOf(u8, body, "\"temperature\":0") != null);
    try std.testing.expect(std.mem.endsWith(u8, body, "\"response_format\":{\"type\":\"json_object\"}}"));

    // Assertion nodes carry the claim, quote, date and provenance, and link
    // EVIDENCED_BY to their message (and chunk, for the long message).
    const flat_search = try searchAssertions(&runtime, "apartment", "fts");
    defer allocator.free(flat_search);
    try std.testing.expect(std.mem.indexOf(u8, flat_search, "\"type\":\"assertion\"") != null);
    const flat_qid = (try firstResultQid(allocator, flat_search)) orelse return error.TestUnexpectedResult;
    defer allocator.free(flat_qid);
    try std.testing.expect(std.mem.startsWith(u8, flat_qid, assertion_qid_prefix));
    const flat_node = (try store.getNode(allocator, flat_qid)) orelse return error.TestUnexpectedResult;
    defer store.freeNode(allocator, flat_node);
    try std.testing.expectEqualStrings("Assertion", flat_node.label);
    for ([_][]const u8{
        "\"text\":\"The user received the keys to a new apartment.\"",
        "\"quote\":\"Got the keys to the new flat\"",
        "\"eventDate\":\"2023-03-03\"",
        "\"planned\":false",
        "\"chunkQids\":[]",
        "\"role\":\"user\"",
        "\"createdAt\":\"2023-03-04T09:00:00Z\"",
        "\"sessionId\":\"s-flat\"",
        "\"projectId\":\"repo:facts\"",
        "\"extractorModel\":\"test-extract-model\"",
        "\"promptVersion\":\"quipu.extract.speaker-facts.v4\"",
    }) |needle| {
        if (std.mem.indexOf(u8, flat_node.properties_json, needle) == null) {
            std.debug.print("missing {s} in {s}\n", .{ needle, flat_node.properties_json });
            return error.TestUnexpectedResult;
        }
    }
    const source_needle = try std.fmt.allocPrint(allocator, "\"sourceMessageQid\":\"{s}\"", .{sessions.flat_message});
    defer allocator.free(source_needle);
    try std.testing.expect(std.mem.indexOf(u8, flat_node.properties_json, source_needle) != null);
    const flat_edges = try store.findEdges(allocator, .{ .from_qid = flat_qid, .edge_type = "EVIDENCED_BY", .limit = 10 });
    defer store.freeEdges(allocator, flat_edges);
    try std.testing.expectEqual(@as(usize, 1), flat_edges.len);
    try std.testing.expectEqualStrings(sessions.flat_message, flat_edges[0].to_qid);

    const kyoto_search = try searchAssertions(&runtime, "Japan sakura", "fts");
    defer allocator.free(kyoto_search);
    const kyoto_qid = (try firstResultQid(allocator, kyoto_search)) orelse return error.TestUnexpectedResult;
    defer allocator.free(kyoto_qid);
    const second_chunk = try chunkQid(allocator, sessions.kyoto_message, 1);
    defer allocator.free(second_chunk);
    const kyoto_edges = try store.findEdges(allocator, .{ .from_qid = kyoto_qid, .edge_type = "EVIDENCED_BY", .limit = 10 });
    defer store.freeEdges(allocator, kyoto_edges);
    try std.testing.expectEqual(@as(usize, 2), kyoto_edges.len);
    var linked_message = false;
    var linked_chunk = false;
    for (kyoto_edges) |edge| {
        if (std.mem.eql(u8, edge.to_qid, sessions.kyoto_message)) linked_message = true;
        if (std.mem.eql(u8, edge.to_qid, second_chunk)) linked_chunk = true;
    }
    try std.testing.expect(linked_message and linked_chunk);

    // The job records its counts; rerunning finds nothing pending.
    const job = (try store.getNode(allocator, sessions.flat_job)) orelse return error.TestUnexpectedResult;
    defer store.freeNode(allocator, job);
    try std.testing.expect(std.mem.indexOf(u8, job.properties_json, "\"status\":\"succeeded\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, job.properties_json, "\\\"accepted\\\":3,\\\"repaired\\\":1,\\\"duplicates\\\":0,\\\"quarantined\\\":1") != null);
    const rerun = try runtime.dispatch(allocator, "{\"jsonrpc\":\"2.0\",\"id\":\"x2\",\"method\":\"memory.extract.run\",\"params\":{}}");
    defer allocator.free(rerun);
    try std.testing.expect(std.mem.indexOf(u8, rerun, "\"leasedCount\":0") != null);
    try std.testing.expectEqual(@as(usize, 2), extractor_model.calls);
}

test "extract worker stores a claim's relative time as a date and searches it as said" {
    const allocator = std.testing.allocator;
    var harness = try RuntimeTestHarness.init(allocator);
    defer harness.deinit();
    const store = harness.adapter();
    const replies = [_][2][]const u8{.{ "beagle",
        \\{"assertions":[{"text":"The user adopted a beagle named Biscuit yesterday.","messageIndex":0,"quote":"I adopted a beagle named Biscuit yesterday"}]}
    }};
    var extractor_model = TestExtractor{ .replies = &replies };
    defer extractor_model.deinit();
    var runtime = Runtime.initWithOptions(store, harness.health(), .{ .extract_provider = extractor_model.endpoint() });
    defer runtime.deinit();
    // 2023-05-09 is a Tuesday.
    const remembered = try runtime.dispatch(
        allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"r1\",\"method\":\"memory.remember\",\"params\":{\"scope\":{\"projectId\":\"repo:facts\"},\"sessionId\":\"s-dog\",\"messages\":[{\"role\":\"user\",\"content\":\"I adopted a beagle named Biscuit yesterday.\",\"createdAt\":\"2023-05-09T09:00:00Z\"}]}}",
    );
    defer allocator.free(remembered);
    const run = try runtime.dispatch(allocator, "{\"jsonrpc\":\"2.0\",\"id\":\"x1\",\"method\":\"memory.extract.run\",\"params\":{\"owner\":\"test\"}}");
    defer allocator.free(run);
    try std.testing.expect(std.mem.indexOf(u8, run, "\"assertionsWritten\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, run, "\"eventDates\":1,\"eventDatesRejected\":0,\"planned\":0,\"timesResolved\":1,\"eventDatesDerived\":1,\"eventDatesCorrected\":0") != null);

    // Found by the words it was said in, not by the date written into it.
    const said = try searchAssertions(&runtime, "yesterday", "fts");
    defer allocator.free(said);
    const qid = (try firstResultQid(allocator, said)) orelse return error.TestUnexpectedResult;
    defer allocator.free(qid);
    const by_month = try searchAssertions(&runtime, "May", "fts");
    defer allocator.free(by_month);
    try std.testing.expectEqual(@as(?[]u8, null), try firstResultQid(allocator, by_month));

    const node = (try store.getNode(allocator, qid)) orelse return error.TestUnexpectedResult;
    defer store.freeNode(allocator, node);
    for ([_][]const u8{
        "\"text\":\"The user adopted a beagle named Biscuit on Monday, May 8, 2023.\"",
        "\"statedText\":\"The user adopted a beagle named Biscuit yesterday.\"",
        "\"searchText\":\"The user adopted a beagle named Biscuit yesterday.\"",
        "\"eventDate\":\"2023-05-08\"",
        "\"eventStart\":\"2023-05-08\"",
        "\"eventEnd\":\"2023-05-08\"",
        "\"planned\":false",
    }) |needle| {
        if (std.mem.indexOf(u8, node.properties_json, needle) == null) {
            std.debug.print("missing {s} in {s}\n", .{ needle, node.properties_json });
            return error.TestUnexpectedResult;
        }
    }
}

test "a claim is from a time the question names when its event span overlaps it" {
    const claim = struct {
        fn within(properties: []const u8, start: []const u8, end: []const u8) !bool {
            const node = storage.Node{ .qid = "q_asrt_test", .label = "Assertion", .properties_json = properties };
            return nodeDatedWithin(std.testing.allocator, node, .{ .start = parseIsoDate(start) catch unreachable, .end = parseIsoDate(end) catch unreachable }, true);
        }
    }.within;

    // "the weekend of May 6 to May 7", said on the 9th.
    const weekend = "{\"createdAt\":\"2023-05-09T10:00:00Z\",\"eventStart\":\"2023-05-06\",\"eventEnd\":\"2023-05-07\",\"planned\":false}";
    try std.testing.expect(try claim(weekend, "2023-05-06", "2023-05-06"));
    try std.testing.expect(try claim(weekend, "2023-05-07", "2023-05-12"));
    // The day it was said is not when it happened.
    try std.testing.expect(!try claim(weekend, "2023-05-09", "2023-05-09"));
    // A month says too little for a day, and enough for that month.
    const month = "{\"createdAt\":\"2023-05-09T10:00:00Z\",\"eventDate\":\"2023-04\",\"eventStart\":\"2023-04-01\",\"eventEnd\":\"2023-04-30\",\"planned\":false}";
    try std.testing.expect(!try claim(month, "2023-04-10", "2023-04-10"));
    try std.testing.expect(try claim(month, "2023-04-01", "2023-04-30"));
    // A plan has not happened.
    const plan = "{\"createdAt\":\"2023-05-09T10:00:00Z\",\"eventStart\":\"2023-05-13\",\"eventEnd\":\"2023-05-14\",\"planned\":true}";
    try std.testing.expect(!try claim(plan, "2023-05-13", "2023-05-13"));
    // Claims stored before spans: the event day, else the day said.
    const dated = "{\"createdAt\":\"2023-05-09T10:00:00Z\",\"eventDate\":\"2023-05-08\",\"planned\":false}";
    try std.testing.expect(try claim(dated, "2023-05-08", "2023-05-08"));
    const undated = "{\"createdAt\":\"2023-05-09T10:00:00Z\",\"planned\":false}";
    try std.testing.expect(try claim(undated, "2023-05-09", "2023-05-09"));
}

/// The Assertion nodes whose source is `message_qid`, as (text, prompt version) pairs.
fn assertionsFrom(store: storage.Adapter, message_qid: []const u8) ![][2][]u8 {
    const allocator = std.testing.allocator;
    var found = std.ArrayList([2][]u8).empty;
    errdefer {
        for (found.items) |pair| for (pair) |string| allocator.free(string);
        found.deinit(allocator);
    }
    var iterator = store.iterateNodes(allocator, .{ .label = "Assertion", .where = &.{.{ .name = "sourceMessageQid", .value = message_qid }} });
    defer iterator.deinit();
    while (try iterator.next()) |qid| {
        const node = (try store.getNode(allocator, qid)).?;
        defer store.freeNode(allocator, node);
        const claim_text = try readPropertyString(allocator, node.properties_json, "text");
        errdefer allocator.free(claim_text);
        const version = try readPropertyString(allocator, node.properties_json, "promptVersion");
        errdefer allocator.free(version);
        try std.testing.expect(try edgeExists(store, qid, message_qid, "EVIDENCED_BY"));
        try found.append(allocator, .{ claim_text, version });
    }
    return found.toOwnedSlice(allocator);
}

fn freeAssertionsFrom(found: [][2][]u8) void {
    for (found) |pair| for (pair) |string| std.testing.allocator.free(string);
    std.testing.allocator.free(found);
}

test "the extract job reads again the messages its first reading drew no claim from" {
    const allocator = std.testing.allocator;
    var harness = try RuntimeTestHarness.init(allocator);
    defer harness.deinit();
    const store = harness.adapter();

    // The first reading attends to the cat and returns nothing for the
    // tandem, which is said inside a request.
    const tandem = "I picked up the tandem from the workshop yesterday, can you suggest a route along the coast for Sunday?";
    const replies = [_][2][]const u8{
        .{ "Miso", "{\"assertions\":[{\"text\":\"The user adopted a cat named Miso.\",\"messageIndex\":0,\"quote\":\"I adopted a cat named Miso\"}]}" },
        .{ "tandem", "{\"assertions\":[{\"text\":\"The user picked up the tandem from the workshop yesterday.\",\"messageIndex\":0,\"quote\":\"I picked up the tandem from the workshop yesterday\"}]}" },
    };
    var failing = TestExtractor{ .replies = &replies, .malformed_recall = true };
    defer failing.deinit();
    var runtime = Runtime.initWithOptions(store, harness.health(), .{ .extract_provider = failing.endpoint() });
    defer runtime.deinit();

    const request = try stringifyAlloc(allocator, .{
        .jsonrpc = "2.0",
        .id = "r1",
        .method = "memory.remember",
        .params = .{
            .scope = .{ .userId = "rider" },
            .sessionId = "s-ride",
            .messages = &[_]struct { role: []const u8, content: []const u8, createdAt: []const u8 }{
                .{ .role = "user", .content = "I adopted a cat named Miso last month and she already sleeps on the radiator.", .createdAt = "2023-05-22T10:00:00Z" },
                .{ .role = "assistant", .content = "Radiators are a favourite. Does she have a bed of her own nearby, somewhere warm and out of the way?", .createdAt = "2023-05-22T10:00:10Z" },
                .{ .role = "user", .content = "Not yet.", .createdAt = "2023-05-22T10:01:00Z" },
                .{ .role = "user", .content = tandem, .createdAt = "2023-05-22T10:02:00Z" },
            },
        },
    });
    defer allocator.free(request);
    const remembered = try runtime.dispatch(allocator, request);
    defer allocator.free(remembered);
    var parsed = try std.json.parseFromSlice(Value, allocator, remembered, .{});
    defer parsed.deinit();
    const message_qids = parsed.value.object.get("result").?.object.get("messageQids").?.array.items;
    const cat_message = message_qids[0].string;
    const tandem_message = message_qids[3].string;

    // A second reading that does not answer fails the job: the turn is not
    // extracted, and nothing of it is written.
    const failed = try runtime.runExtractJobs(allocator, "test", 10, 1);
    try std.testing.expectEqual(@as(usize, 1), failed.failedCount);
    try std.testing.expectEqual(@as(usize, 0), failed.succeededCount);
    try std.testing.expectEqualStrings("MalformedExtraction", failed.lastError.?);
    try std.testing.expectEqual(@as(usize, 4), failed.calls);
    try std.testing.expectEqual(@as(usize, 2), failed.jsonRetries);
    try std.testing.expectEqual(@as(usize, 0), failed.assertionsWritten);
    {
        const none = try assertionsFrom(store, cat_message);
        defer freeAssertionsFrom(none);
        try std.testing.expectEqual(@as(usize, 0), none.len);
    }

    var model = TestExtractor{ .replies = &replies };
    defer model.deinit();
    runtime.options.extract_provider = model.endpoint();
    const run = try runtime.runExtractJobs(allocator, "test", 10, 1);
    try std.testing.expectEqual(@as(usize, 1), run.succeededCount);
    try std.testing.expectEqual(@as(usize, 2), run.calls);
    try std.testing.expectEqual(@as(usize, 0), run.jsonRetries);
    try std.testing.expectEqual(@as(usize, 3), run.sourceMessages);
    try std.testing.expectEqual(@as(usize, 2), run.assertionsWritten);
    try std.testing.expectEqual(@as(usize, 1), run.recallMessages);
    try std.testing.expectEqual(@as(usize, 1), run.recallAssertions);
    try std.testing.expectEqual(@as(usize, 2), run.counts.accepted);

    // The second call: the recall prompt, and only the message that is long
    // enough to state something and has no claim. "Not yet." is not sent,
    // nor the message about the cat, nor the reply.
    try std.testing.expectEqualStrings(fact_extraction.recall_prompt, model.last_system.?);
    try std.testing.expectEqual(@as(usize, 2), model.users.items.len);
    const expected_user = try std.fmt.allocPrint(
        allocator,
        "{{\"conversationTime\":\"2023-05-22T10:00:00Z\",\"messages\":[{{\"role\":\"user\",\"content\":\"{s}\"}}]}}",
        .{tandem},
    );
    defer allocator.free(expected_user);
    try std.testing.expectEqualStrings(expected_user, model.users.items[1]);

    // Its claim is evidenced by the message it was drawn from, which is the
    // turn's third and the second reading's first, and says which reading
    // wrote it. Its time is written out like any claim's.
    const recalled = try assertionsFrom(store, tandem_message);
    defer freeAssertionsFrom(recalled);
    try std.testing.expectEqual(@as(usize, 1), recalled.len);
    try std.testing.expectEqualStrings("The user picked up the tandem from the workshop on Sunday, May 21, 2023.", recalled[0][0]);
    try std.testing.expectEqualStrings("quipu.extract.recall.v1", recalled[0][1]);
    const first = try assertionsFrom(store, cat_message);
    defer freeAssertionsFrom(first);
    try std.testing.expectEqual(@as(usize, 1), first.len);
    try std.testing.expectEqualStrings(fact_extraction.prompt_version, first[0][1]);

    // A turn whose every long message has a claim is read once.
    const again = try runtime.dispatch(
        allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"r2\",\"method\":\"memory.remember\",\"params\":{\"scope\":{\"userId\":\"rider\"},\"sessionId\":\"s-cat\",\"messages\":[{\"role\":\"user\",\"content\":\"I adopted a cat named Miso from the shelter on Elm Street, and this morning she knocked the fern off the shelf.\"}]}}",
    );
    defer allocator.free(again);
    const once = try runtime.runExtractJobs(allocator, "test", 10, 1);
    try std.testing.expectEqual(@as(usize, 1), once.succeededCount);
    try std.testing.expectEqual(@as(usize, 1), once.calls);
    try std.testing.expectEqual(@as(usize, 0), once.recallMessages);
}

test "extract worker retries malformed JSON a bounded number of times" {
    const allocator = std.testing.allocator;
    var harness = try RuntimeTestHarness.init(allocator);
    defer harness.deinit();
    const store = harness.adapter();

    // One malformed reply: E1's Unicode retry prompt recovers it.
    var recovering = TestExtractor{ .replies = &fact_test_replies, .malformed_first = 1 };
    defer recovering.deinit();
    var runtime = Runtime.initWithOptions(store, harness.health(), .{ .extract_provider = recovering.endpoint() });
    defer runtime.deinit();
    const sessions = try rememberFactSessions(&runtime);
    defer sessions.deinit();
    const first = try runtime.runExtractJobs(allocator, "test", 1, 1);
    try std.testing.expectEqual(@as(usize, 1), first.succeededCount);
    try std.testing.expectEqual(@as(usize, 2), first.calls);
    try std.testing.expectEqual(@as(usize, 1), first.jsonRetries);
    try std.testing.expectEqualStrings(fact_extraction.unicode_retry_prompt, recovering.last_system.?);

    // Always malformed: three calls, then the job fails and stays retryable.
    var broken = TestExtractor{ .malformed_first = 100 };
    defer broken.deinit();
    runtime.options.extract_provider = broken.endpoint();
    const second = try runtime.runExtractJobs(allocator, "test", 1, 1);
    try std.testing.expectEqual(@as(usize, 1), second.failedCount);
    try std.testing.expectEqual(@as(usize, 3), second.calls);
    try std.testing.expectEqualStrings("MalformedExtraction", second.lastError.?);
    try std.testing.expectEqualStrings(fact_extraction.syntax_retry_prompt, broken.last_system.?);
    try std.testing.expectEqual(@as(usize, 0), second.counts.accepted);

    var unconfigured = Runtime.init(store, harness.health());
    const refused = try unconfigured.dispatch(allocator, "{\"jsonrpc\":\"2.0\",\"id\":\"x\",\"method\":\"memory.extract.run\",\"params\":{}}");
    defer allocator.free(refused);
    try std.testing.expect(std.mem.indexOf(u8, refused, "\"code\":\"provider_error\"") != null);
}

test "factKeys off leaves retrieval unchanged and never returns assertions" {
    const allocator = std.testing.allocator;
    var harness = try RuntimeTestHarness.init(allocator);
    defer harness.deinit();
    var extractor_model = TestExtractor{ .replies = &fact_test_replies };
    defer extractor_model.deinit();
    var runtime = Runtime.initWithOptions(harness.adapter(), harness.health(), .{ .extract_provider = extractor_model.endpoint() });
    defer runtime.deinit();
    const sessions = try rememberFactSessions(&runtime);
    defer sessions.deinit();

    const queries = [_][]const u8{ "keys flat wine", "apartment keys", "Kyoto cherry blossoms Japan" };
    var before: [queries.len][]u8 = undefined;
    var before_qids: [queries.len]ResponseQids = undefined;
    for (queries, 0..) |query, index| {
        const response = try retrieveFacts(&runtime, query, "");
        defer allocator.free(response);
        before[index] = try resultStringField(allocator, response, "prompt");
        before_qids[index] = try responseItemQids(response);
    }
    defer for (&before, &before_qids) |prompt, *qids| {
        allocator.free(prompt);
        qids.deinit();
    };

    const run = try runtime.runExtractJobs(allocator, "test", 100, 1);
    try std.testing.expectEqual(@as(usize, 4), run.assertionsWritten);

    for (queries, 0..) |query, index| {
        for ([_][]const u8{ "", ",\"factKeys\":false" }) |option| {
            const response = try retrieveFacts(&runtime, query, option);
            defer allocator.free(response);
            const prompt = try resultStringField(allocator, response, "prompt");
            defer allocator.free(prompt);
            try std.testing.expectEqualStrings(before[index], prompt);
            var qids = try responseItemQids(response);
            defer qids.deinit();
            try std.testing.expectEqual(before_qids[index].qids.len, qids.qids.len);
            for (before_qids[index].qids, qids.qids) |expected, actual| try std.testing.expectEqualStrings(expected, actual);
            try std.testing.expect(std.mem.indexOf(u8, response, assertion_qid_prefix) == null);
            try std.testing.expect(std.mem.indexOf(u8, response, "\"factKeys\"") == null);
        }
    }
    // A default search does not surface assertions either.
    const search = try runtime.dispatch(allocator, "{\"jsonrpc\":\"2.0\",\"id\":\"s\",\"method\":\"memory.search\",\"params\":{\"query\":\"apartment\",\"scope\":{\"projectId\":\"repo:facts\"}}}");
    defer allocator.free(search);
    try std.testing.expect(std.mem.indexOf(u8, search, assertion_qid_prefix) == null);
}

test "query expansion runs each sub-query through fact keys" {
    const allocator = std.testing.allocator;
    var harness = try RuntimeTestHarness.init(allocator);
    defer harness.deinit();
    var extractor_model = TestExtractor{ .replies = &fact_test_replies };
    defer extractor_model.deinit();
    var runtime = Runtime.initWithOptions(harness.adapter(), harness.health(), .{ .extract_provider = extractor_model.endpoint() });
    defer runtime.deinit();
    const sessions = try rememberFactSessions(&runtime);
    defer sessions.deinit();
    _ = try runtime.runExtractJobs(allocator, "test", 100, 1);

    // The rules split hands each side to the fact-key collector; the Kyoto
    // plan is reached through the chunk its claim quotes.
    const query = "Which came first, the new apartment or the sakura trip to Japan?";
    const combined = try retrieveFacts(&runtime, query, ",\"factKeys\":true,\"queryExpansion\":\"rules\"");
    defer allocator.free(combined);
    var qids = try responseItemQids(combined);
    defer qids.deinit();
    const second_chunk = try chunkQid(allocator, sessions.kyoto_message, 1);
    defer allocator.free(second_chunk);
    try std.testing.expect(stringListContains(qids.qids, sessions.flat_message));
    try std.testing.expect(stringListContains(qids.qids, second_chunk));
    try std.testing.expect(std.mem.indexOf(u8, combined, assertion_qid_prefix) == null);
    try std.testing.expect(std.mem.indexOf(u8, combined, "\"queryExpansion\":{\"mode\":\"rules\",\"status\":\"expanded\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, combined, "\"factKeys\":{\"assertionHits\":") != null);

    // Without fact keys, expansion still runs but assertions take no part.
    const plain = try retrieveFacts(&runtime, query, ",\"queryExpansion\":\"rules\"");
    defer allocator.free(plain);
    try std.testing.expect(std.mem.indexOf(u8, plain, "\"queryExpansion\":{\"mode\":\"rules\",\"status\":\"expanded\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, plain, "\"factKeys\":") == null);
    try std.testing.expect(std.mem.indexOf(u8, plain, assertion_qid_prefix) == null);
}

test "factKeys turns assertion hits into their raw evidence with event dates" {
    const allocator = std.testing.allocator;
    var harness = try RuntimeTestHarness.init(allocator);
    defer harness.deinit();
    var extractor_model = TestExtractor{ .replies = &fact_test_replies };
    defer extractor_model.deinit();
    var runtime = Runtime.initWithOptions(harness.adapter(), harness.health(), .{ .extract_provider = extractor_model.endpoint() });
    defer runtime.deinit();
    const sessions = try rememberFactSessions(&runtime);
    defer sessions.deinit();
    _ = try runtime.runExtractJobs(allocator, "test", 100, 1);

    // "apartment" occurs only in a claim: off finds nothing, on finds the
    // source message, never the assertion itself.
    const off = try retrieveFacts(&runtime, "apartment", "");
    defer allocator.free(off);
    try std.testing.expect(std.mem.indexOf(u8, off, sessions.flat_message) == null);
    const on = try retrieveFacts(&runtime, "apartment", ",\"factKeys\":true");
    defer allocator.free(on);
    var on_qids = try responseItemQids(on);
    defer on_qids.deinit();
    try std.testing.expectEqual(@as(usize, 1), on_qids.qids.len);
    try std.testing.expectEqualStrings(sessions.flat_message, on_qids.qids[0]);
    try std.testing.expect(std.mem.indexOf(u8, on, assertion_qid_prefix) == null);
    try std.testing.expect(std.mem.indexOf(u8, on, "\"type\":\"message\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, on, "\"factKeys\":{\"assertionHits\":1,\"evidenceItems\":1,\"keptEvidenceItems\":1,\"datedItems\":1}") != null);
    const prompt = try resultStringField(allocator, on, "prompt");
    defer allocator.free(prompt);
    // The rejected 2023-03-09 date is gone; the line's own date is implied.
    const line = try std.fmt.allocPrint(allocator, "[{s}] user [event 2023-03-03]: Got the keys to the new flat yesterday!", .{sessions.flat_message});
    defer allocator.free(line);
    try std.testing.expect(std.mem.indexOf(u8, prompt, line) != null);

    // A long message is reached through the chunk holding the quote.
    const plan = try retrieveFacts(&runtime, "Japan sakura", ",\"factKeys\":true");
    defer allocator.free(plan);
    var plan_qids = try responseItemQids(plan);
    defer plan_qids.deinit();
    const second_chunk = try chunkQid(allocator, sessions.kyoto_message, 1);
    defer allocator.free(second_chunk);
    try std.testing.expectEqual(@as(usize, 1), plan_qids.qids.len);
    try std.testing.expectEqualStrings(second_chunk, plan_qids.qids[0]);
    const plan_prompt = try resultStringField(allocator, plan, "prompt");
    defer allocator.free(plan_prompt);
    try std.testing.expect(std.mem.indexOf(u8, plan_prompt, "(2/2) [event 2023-04 planned]: ") != null);

    // A raw hit and an assertion hit on the same message yield one item.
    const both = try retrieveFacts(&runtime, "keys flat apartment", ",\"factKeys\":true");
    defer allocator.free(both);
    var both_qids = try responseItemQids(both);
    defer both_qids.deinit();
    var flat_items: usize = 0;
    for (both_qids.qids) |qid| {
        if (std.mem.eql(u8, qid, sessions.flat_message)) flat_items += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), flat_items);
}

test "forgetting a message tombstones its assertions" {
    const allocator = std.testing.allocator;
    var harness = try RuntimeTestHarness.init(allocator);
    defer harness.deinit();
    const store = harness.adapter();
    var extractor_model = TestExtractor{ .replies = &fact_test_replies };
    defer extractor_model.deinit();
    var runtime = Runtime.initWithOptions(store, harness.health(), .{ .extract_provider = extractor_model.endpoint() });
    defer runtime.deinit();
    const sessions = try rememberFactSessions(&runtime);
    defer sessions.deinit();
    _ = try runtime.runExtractJobs(allocator, "test", 100, 1);

    const found = try searchAssertions(&runtime, "apartment", "fts");
    defer allocator.free(found);
    const flat_qid = (try firstResultQid(allocator, found)) orelse return error.TestUnexpectedResult;
    defer allocator.free(flat_qid);

    const request = try std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":\"f\",\"method\":\"memory.forget\",\"params\":{{\"mode\":\"hard_delete\",\"selector\":{{\"qids\":[\"{s}\"]}},\"dryRun\":false,\"reason\":\"test\"}}}}",
        .{sessions.flat_message},
    );
    defer allocator.free(request);
    const forget = try runtime.dispatch(allocator, request);
    defer allocator.free(forget);
    const reported = try std.fmt.allocPrint(allocator, "{{\"qid\":\"{s}\",\"type\":\"assertion\",\"action\":\"invalidated\"}}", .{flat_qid});
    defer allocator.free(reported);
    try std.testing.expect(std.mem.indexOf(u8, forget, reported) != null);

    // Tombstoned: no text left, out of search and retrieval.
    const node = (try store.getNode(allocator, flat_qid)) orelse return error.TestUnexpectedResult;
    defer store.freeNode(allocator, node);
    try std.testing.expect(std.mem.indexOf(u8, node.properties_json, "\"deleted\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, node.properties_json, "apartment") == null);
    for ([_][]const u8{ "apartment", "wine landlord" }) |query| {
        const search = try searchAssertions(&runtime, query, "fts");
        defer allocator.free(search);
        try std.testing.expect(std.mem.indexOf(u8, search, "\"results\":[]") != null);
        const retrieve = try retrieveFacts(&runtime, query, ",\"factKeys\":true");
        defer allocator.free(retrieve);
        try std.testing.expect(std.mem.indexOf(u8, retrieve, sessions.flat_message) == null);
        try std.testing.expect(std.mem.indexOf(u8, retrieve, "Got the keys") == null);
    }
    if (build_options.enable_lattice) {
        const vector = try searchAssertions(&runtime, "The user received the keys to a new apartment.", "vector");
        defer allocator.free(vector);
        try std.testing.expect(std.mem.indexOf(u8, vector, flat_qid) == null);
    }

    // Claims from other messages survive.
    const kept = try searchAssertions(&runtime, "Japan sakura", "fts");
    defer allocator.free(kept);
    try std.testing.expect(std.mem.indexOf(u8, kept, "\"type\":\"assertion\"") != null);
}

/// Extraction model for the background worker tests. Its calls arrive on
/// worker threads, and each waits until `open` is set.
const BackgroundTestExtractor = struct {
    calls: std.atomic.Value(usize) = .init(0),
    open: std.atomic.Value(bool) = .init(true),
    wakes: std.atomic.Value(usize) = .init(0),
    /// Fail every call before a reply, as an unreachable provider does.
    down: bool = false,

    fn endpoint(self: *BackgroundTestExtractor) providers.ProviderEndpoint {
        return .{
            .kind = .callback,
            .name = "test-extractor",
            .model = "test-extract-model",
            .callback = .{ .context = self, .respond = respond },
        };
    }

    fn respond(context: ?*anyopaque, allocator: std.mem.Allocator, turn: providers.ChatTurn) anyerror![]u8 {
        const self: *BackgroundTestExtractor = @ptrCast(@alignCast(context.?));
        if (!self.down) {
            if (try testSummaryReply(allocator, turn)) |reply| return reply;
        }
        _ = self.calls.fetchAdd(1, .monotonic);
        while (!self.open.load(.acquire)) std.atomic.spinLoopHint();
        if (self.down) return error.ProviderHttpError;
        for (fact_test_replies) |pair| {
            if (std.mem.indexOf(u8, turn.user_content, pair[0]) != null) return allocator.dupe(u8, pair[1]);
        }
        return allocator.dupe(u8, "{\"assertions\":[]}");
    }

    fn notify(self: *BackgroundTestExtractor) BackgroundNotify {
        return .{ .context = self, .wake = wake };
    }

    fn wake(context: *anyopaque) void {
        const self: *BackgroundTestExtractor = @ptrCast(@alignCast(context));
        _ = self.wakes.fetchAdd(1, .monotonic);
    }
};

/// Extract and consolidate jobs in `status`. Pattern jobs, which a store
/// that embeds queues after every extraction, are counted by
/// `countPatternJobs`.
/// Jobs other than the rebuilds of derived nodes (pattern and summary jobs),
/// which a store that embeds queues after every extraction.
fn countJobs(store: storage.Adapter, status: []const u8) !usize {
    return (try countJobsByKind(store, status, .other));
}

fn countPatternJobs(store: storage.Adapter, status: []const u8) !usize {
    return (try countJobsByKind(store, status, .pattern));
}

fn countSummaryJobs(store: storage.Adapter, status: []const u8) !usize {
    return (try countJobsByKind(store, status, .summary));
}

const TestJobKind = enum { other, pattern, summary };

fn countJobsByKind(store: storage.Adapter, status: []const u8, wanted: TestJobKind) !usize {
    const allocator = std.testing.allocator;
    var iterator = store.iterateNodes(allocator, .{ .label = "Job", .where = &.{.{ .name = "status", .value = status }} });
    defer iterator.deinit();
    var count: usize = 0;
    while (try iterator.next()) |qid| {
        const node = (try store.getNode(allocator, qid)).?;
        defer store.freeNode(allocator, node);
        const kind: TestJobKind = if (try propertyEquals(allocator, node.properties_json, "jobType", streams.workerKindForStream(streams.pattern_requested)))
            .pattern
        else if (try propertyEquals(allocator, node.properties_json, "jobType", streams.workerKindForStream(streams.summary_requested)))
            .summary
        else
            .other;
        if (kind == wanted) count += 1;
    }
    return count;
}

/// What the test models say to the summary job: a title and summary for a
/// session or a topic, null for any other prompt.
fn testSummaryReply(allocator: std.mem.Allocator, turn: providers.ChatTurn) !?[]u8 {
    if (std.mem.startsWith(u8, turn.system_prompt, summaries.session_prompt)) {
        return try allocator.dupe(u8, "{\"title\":\"A conversation\",\"summary\":\"The user told the assistant about their life.\"}");
    }
    if (std.mem.startsWith(u8, turn.system_prompt, summaries.topic_prompt)) {
        return try allocator.dupe(u8, "{\"title\":\"One subject\",\"summary\":\"Facts the user stated about one subject.\"}");
    }
    return null;
}

fn expectExtractorState(runtime: *Runtime, state: []const u8) !void {
    const allocator = std.testing.allocator;
    const health = try runtime.dispatch(allocator, "{\"jsonrpc\":\"2.0\",\"id\":\"h\",\"method\":\"system.health\",\"params\":{}}");
    defer allocator.free(health);
    const expected = try std.fmt.allocPrint(allocator, "\"extractor\":\"{s}\"", .{state});
    defer allocator.free(expected);
    try std.testing.expect(std.mem.indexOf(u8, health, expected) != null);
}

test "background work extracts between requests and memory.extract.run flushes it" {
    const allocator = std.testing.allocator;
    var harness = try RuntimeTestHarness.init(allocator);
    defer harness.deinit();
    const store = harness.adapter();
    var model = BackgroundTestExtractor{};
    var runtime = Runtime.initWithOptions(store, harness.health(), .{
        .io = std.testing.io,
        .extract_provider = model.endpoint(),
        .background_workers = true,
    });
    defer runtime.deinit();
    runtime.background_notify = model.notify();
    try expectExtractorState(&runtime, "running");
    const sessions = try rememberFactSessions(&runtime);
    defer sessions.deinit();

    // The model has not answered: the batch is in flight, its jobs are
    // leased, and requests are served from what is already stored.
    model.open.store(false, .release);
    try std.testing.expect(try runtime.startBackgroundWork(allocator));
    try std.testing.expect(runtime.backgroundActive());
    try std.testing.expect(!runtime.backgroundReady());
    try std.testing.expect(!try runtime.startBackgroundWork(allocator));
    try std.testing.expectEqual(@as(usize, 2), try countJobs(store, "leased"));
    const during = try searchAssertions(&runtime, "apartment", "fts");
    defer allocator.free(during);
    try std.testing.expect(std.mem.indexOf(u8, during, "\"type\":\"assertion\"") == null);

    model.open.store(true, .release);
    const finished = (try runtime.finishBackgroundWork(allocator)).?.extract;
    try std.testing.expectEqual(@as(usize, 2), finished.leasedCount);
    try std.testing.expectEqual(@as(usize, 2), finished.succeededCount);
    try std.testing.expectEqual(@as(usize, 2), finished.calls);
    try std.testing.expectEqual(@as(usize, 4), finished.assertionsWritten);
    try std.testing.expectEqual(@as(usize, 1), model.wakes.load(.monotonic));
    try std.testing.expect(!runtime.backgroundActive());
    try std.testing.expectEqual(@as(usize, 0), try countJobs(store, "leased"));
    try std.testing.expectEqual(@as(usize, 0), try countJobs(store, "pending"));
    const after = try searchAssertions(&runtime, "apartment", "fts");
    defer allocator.free(after);
    try std.testing.expect(std.mem.indexOf(u8, after, "\"type\":\"assertion\"") != null);

    // A store that embeds brings the scope's summaries up to date next, one
    // per conversation, and then rebuilds its pattern nodes. Two
    // conversations are too few for a group, so that pass makes no call.
    if (store.capabilities().vector) {
        try std.testing.expect(try runtime.startBackgroundWork(allocator));
        const summarised = (try runtime.finishBackgroundWork(allocator)).?.summaries;
        try std.testing.expectEqual(@as(usize, 2), summarised.succeededCount);
        try std.testing.expectEqual(@as(usize, 1), summarised.scopes);
        try std.testing.expectEqual(@as(usize, 2), summarised.counts.sessionsWritten);
        try std.testing.expect(try runtime.startBackgroundWork(allocator));
        const built = (try runtime.finishBackgroundWork(allocator)).?.patterns;
        try std.testing.expectEqual(@as(usize, 2), built.succeededCount);
        try std.testing.expectEqual(@as(usize, 0), built.calls);
    }

    // Nothing is pending, so the next pass starts nothing and stops looking
    // until a memory arrives.
    try std.testing.expect(!try runtime.startBackgroundWork(allocator));
    try std.testing.expect(!runtime.background_dirty);
    const more = try runtime.dispatch(
        allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"r3\",\"method\":\"memory.remember\",\"params\":{\"scope\":{\"projectId\":\"repo:facts\"},\"sessionId\":\"s-cat\",\"messages\":[{\"role\":\"user\",\"content\":\"I adopted a cat named Miso last week.\",\"createdAt\":\"2023-03-12T09:00:00Z\"}]}}",
    );
    defer allocator.free(more);
    try std.testing.expect(runtime.background_dirty);

    // memory.extract.run waits for the batch in flight and reports its jobs.
    try std.testing.expect(try runtime.startBackgroundWork(allocator));
    const run = try runtime.dispatch(allocator, "{\"jsonrpc\":\"2.0\",\"id\":\"x1\",\"method\":\"memory.extract.run\",\"params\":{\"owner\":\"test\"}}");
    defer allocator.free(run);
    try std.testing.expect(std.mem.indexOf(u8, run, "\"leasedCount\":1,\"succeededCount\":1,\"failedCount\":0") != null);
    try std.testing.expect(!runtime.backgroundActive());
    try std.testing.expectEqual(@as(usize, 3), model.calls.load(.monotonic));

    // Without the background switch the same provider waits to be asked.
    var manual = Runtime.initWithOptions(store, harness.health(), .{ .io = std.testing.io, .extract_provider = model.endpoint() });
    defer manual.deinit();
    try expectExtractorState(&manual, "stopped");
    try std.testing.expect(!try manual.startBackgroundWork(allocator));
    var unconfigured = Runtime.init(store, harness.health());
    try expectExtractorState(&unconfigured, "unavailable");
}

test "background work keeps jobs retryable when the provider is down or the daemon stops" {
    const allocator = std.testing.allocator;
    var harness = try RuntimeTestHarness.init(allocator);
    defer harness.deinit();
    const store = harness.adapter();
    var model = BackgroundTestExtractor{ .down = true };
    const options = RuntimeOptions{
        .io = std.testing.io,
        .extract_provider = model.endpoint(),
        .background_workers = true,
    };
    var runtime = Runtime.initWithOptions(store, harness.health(), options);
    defer runtime.deinit();
    const sessions = try rememberFactSessions(&runtime);
    defer sessions.deinit();

    // No call got a reply: the jobs go back unspent and the worker waits.
    try std.testing.expect(try runtime.startBackgroundWork(allocator));
    const failed = (try runtime.finishBackgroundWork(allocator)).?.extract;
    try std.testing.expectEqual(@as(usize, 2), failed.failedCount);
    try std.testing.expectEqual(@as(usize, 0), failed.succeededCount);
    try std.testing.expectEqualStrings("ProviderHttpError", failed.lastError.?);
    try std.testing.expectEqual(@as(usize, 2), try countJobs(store, "pending"));
    const job = (try store.getNode(allocator, sessions.flat_job)) orelse return error.TestUnexpectedResult;
    defer store.freeNode(allocator, job);
    try std.testing.expect(std.mem.indexOf(u8, job.properties_json, "\"attempts\":0") != null);
    try std.testing.expect(!try runtime.startBackgroundWork(allocator));
    try std.testing.expectEqual(background_backoff_initial_ms, runtime.background_backoff_ms);

    // The wait is over and the provider answers, but the daemon stops before
    // the batch is written: nothing is stored and the jobs stay pending.
    runtime.background_retry_at_ms = 0;
    model.down = false;
    try std.testing.expect(try runtime.startBackgroundWork(allocator));
    while (!runtime.backgroundReady()) std.atomic.spinLoopHint();
    runtime.cancelBackgroundWork();
    try std.testing.expect(!runtime.backgroundActive());
    try std.testing.expectEqual(@as(usize, 2), try countJobs(store, "pending"));
    const none = try searchAssertions(&runtime, "apartment", "fts");
    defer allocator.free(none);
    try std.testing.expect(std.mem.indexOf(u8, none, "\"type\":\"assertion\"") == null);

    // A daemon killed mid-batch leaves its leases behind. The next one
    // releases them at startup and runs the jobs.
    const orphaned = try jobs.leasePendingJobs(allocator, store, .{
        .worker_kind = streams.workerKindForStream(streams.extract_requested),
        .owner = background_owner,
        .now_ms = runtime.nowMs(),
    });
    jobs.freeLeaseResults(allocator, orphaned);
    try std.testing.expectEqual(@as(usize, 2), try countJobs(store, "leased"));
    var restarted = Runtime.initWithOptions(store, harness.health(), options);
    defer restarted.deinit();
    try std.testing.expect(try restarted.startBackgroundWork(allocator));
    const recovered = (try restarted.finishBackgroundWork(allocator)).?.extract;
    try std.testing.expectEqual(@as(usize, 2), recovered.succeededCount);
    try std.testing.expectEqual(@as(usize, 4), recovered.assertionsWritten);
    try std.testing.expectEqual(@as(usize, 0), try countJobs(store, "leased"));
}

/// Chat model for the consolidation tests: extracts one claim per follower
/// count; asked to compare claims, says the first new claim replaces the
/// earlier fact that holds `old_value`; asked to verify a pair, confirms it
/// unless `replaced` is off. Its counters are safe to read from worker
/// threads.
const UpdateTestModel = struct {
    extract_calls: std.atomic.Value(usize) = .init(0),
    consolidate_calls: std.atomic.Value(usize) = .init(0),
    verify_calls: std.atomic.Value(usize) = .init(0),
    /// The last comparison request; only kept when `record` is set, for
    /// tests that call from one thread.
    record: bool = false,
    last_comparison: ?[]u8 = null,
    /// The value the model says was replaced, and its verdict on the pair.
    old_value: []const u8 = "1250",
    replaced: bool = true,

    const extract_replies = [_][2][]const u8{
        .{ "1250", "{\"assertions\":[{\"text\":\"The user has 1250 followers on Instagram.\",\"messageIndex\":0,\"quote\":\"I've got 1250 followers on Instagram now\"}]}" },
        .{ "1300", "{\"assertions\":[{\"text\":\"The user is close to 1300 followers on Instagram.\",\"messageIndex\":0,\"quote\":\"close to 1300 followers on Instagram\"}]}" },
    };

    fn endpoint(self: *UpdateTestModel) providers.ProviderEndpoint {
        return .{
            .kind = .callback,
            .name = "test-extractor",
            .model = "test-extract-model",
            .callback = .{ .context = self, .respond = respond },
        };
    }

    fn respond(context: ?*anyopaque, allocator: std.mem.Allocator, turn: providers.ChatTurn) anyerror![]u8 {
        const self: *UpdateTestModel = @ptrCast(@alignCast(context.?));
        if (try testSummaryReply(allocator, turn)) |reply| return reply;
        if (std.mem.startsWith(u8, turn.system_prompt, fact_updates.verify_prompt)) {
            _ = self.verify_calls.fetchAdd(1, .monotonic);
            return std.fmt.allocPrint(
                allocator,
                "{{\"earlierThing\":\"Instagram follower count\",\"laterThing\":\"Instagram follower count\",\"sameThing\":true,\"earlierValue\":\"{s}\",\"laterValue\":\"1300\",\"replaced\":{}}}",
                .{ self.old_value, self.replaced },
            );
        }
        if (std.mem.startsWith(u8, turn.system_prompt, fact_updates.system_prompt)) {
            _ = self.consolidate_calls.fetchAdd(1, .monotonic);
            if (self.record) {
                if (self.last_comparison) |previous| std.testing.allocator.free(previous);
                self.last_comparison = try std.testing.allocator.dupe(u8, turn.user_content);
            }
            // Point at the earlier fact that holds the old value, or at the
            // first one when none does.
            var earlier_index: usize = 0;
            if (std.mem.indexOf(u8, turn.user_content, "\"earlier\":")) |list_start| {
                if (std.mem.indexOfPos(u8, turn.user_content, list_start, self.old_value)) |value_at| {
                    earlier_index = std.mem.count(u8, turn.user_content[list_start..value_at], "{\"id\":\"E") - 1;
                }
            }
            return std.fmt.allocPrint(allocator, "{{\"updates\":[{{\"new\":\"N0\",\"old\":\"E{d}\",\"oldValue\":\"{s}\",\"newValue\":\"1300\"}}]}}", .{ earlier_index, self.old_value });
        }
        _ = self.extract_calls.fetchAdd(1, .monotonic);
        for (extract_replies) |pair| {
            if (std.mem.indexOf(u8, turn.user_content, pair[0]) != null) return allocator.dupe(u8, pair[1]);
        }
        return allocator.dupe(u8, "{\"assertions\":[]}");
    }

    fn deinit(self: *UpdateTestModel) void {
        if (self.last_comparison) |value| std.testing.allocator.free(value);
    }
};

const FollowerSessions = struct {
    may_message: []u8,
    june_message: []u8,

    fn deinit(self: FollowerSessions) void {
        std.testing.allocator.free(self.may_message);
        std.testing.allocator.free(self.june_message);
    }
};

/// Two conversations: 1250 followers in May, close to 1300 in June.
fn rememberFollowerSessions(runtime: *Runtime) !FollowerSessions {
    const allocator = std.testing.allocator;
    const may = try runtime.dispatch(
        allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"r1\",\"method\":\"memory.remember\",\"params\":{\"scope\":{\"projectId\":\"repo:facts\"},\"sessionId\":\"s-may\",\"messages\":[{\"role\":\"user\",\"content\":\"By the way, I've got 1250 followers on Instagram now, so tips are welcome.\",\"createdAt\":\"2023-05-25T10:00:00Z\"}]}}",
    );
    defer allocator.free(may);
    const june = try runtime.dispatch(
        allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"r2\",\"method\":\"memory.remember\",\"params\":{\"scope\":{\"projectId\":\"repo:facts\"},\"sessionId\":\"s-june\",\"messages\":[{\"role\":\"user\",\"content\":\"I think I'm close to 1300 followers on Instagram at this point.\",\"createdAt\":\"2023-06-10T09:00:00Z\"}]}}",
    );
    defer allocator.free(june);
    const may_message = try resultArrayFirst(allocator, may, "messageQids");
    errdefer allocator.free(may_message);
    return .{ .may_message = may_message, .june_message = try resultArrayFirst(allocator, june, "messageQids") };
}

fn followerPrompt(runtime: *Runtime, options_json: []const u8) ![]u8 {
    return followerPromptAt(runtime, options_json, "2023-07-01T09:00:00Z");
}

fn followerPromptAt(runtime: *Runtime, options_json: []const u8, valid_at: []const u8) ![]u8 {
    const allocator = std.testing.allocator;
    const request = try std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":\"q\",\"method\":\"memory.retrieve\",\"params\":{{\"query\":\"How many followers do I have on Instagram now?\",\"scope\":{{\"projectId\":\"repo:facts\"}},\"time\":{{\"validAt\":\"{s}\"}},\"options\":{{\"logRetrieval\":false,\"logAudit\":false{s}}}}}}}",
        .{ valid_at, options_json },
    );
    defer allocator.free(request);
    const response = try runtime.dispatch(allocator, request);
    defer allocator.free(response);
    return resultStringField(allocator, response, "prompt");
}

fn countLiveUpdates(store: storage.Adapter, evidence_qid: []const u8) !usize {
    const allocator = std.testing.allocator;
    const edges = try store.findEdges(allocator, .{ .to_qid = evidence_qid, .edge_type = "EVIDENCED_BY", .limit = storage.unlimited });
    defer store.freeEdges(allocator, edges);
    var count: usize = 0;
    for (edges) |edge| {
        if (!std.mem.startsWith(u8, edge.from_qid, update_qid_prefix)) continue;
        const node = (try store.getNode(allocator, edge.from_qid)) orelse continue;
        defer store.freeNode(allocator, node);
        if (!try propertyBool(allocator, node.properties_json, "deleted")) count += 1;
    }
    return count;
}

const superseded_fact = "(superseded, 2023-05-25 to 2023-06-10) The user has 1250 followers on Instagram.";
const current_fact = "(current, from 2023-06-10) The user is close to 1300 followers on Instagram.";

test "consolidation records the fact a new claim replaces and options.facts shows both" {
    const allocator = std.testing.allocator;
    var harness = try RuntimeTestHarness.init(allocator);
    defer harness.deinit();
    const store = harness.adapter();
    var model = UpdateTestModel{ .record = true };
    defer model.deinit();
    var runtime = Runtime.initWithOptions(store, harness.health(), .{ .extract_provider = model.endpoint(), .consolidate_updates = true });
    defer runtime.deinit();
    const health = try runtime.dispatch(allocator, "{\"jsonrpc\":\"2.0\",\"id\":\"h\",\"method\":\"system.health\",\"params\":{}}");
    defer allocator.free(health);
    try std.testing.expect(std.mem.indexOf(u8, health, "\"consolidator\":\"stopped\"") != null);
    const sessions = try rememberFollowerSessions(&runtime);
    defer sessions.deinit();

    // Extraction queues one consolidate job per conversation with a claim.
    const extracted = try runtime.runExtractJobs(allocator, "test", 10, 1);
    try std.testing.expectEqual(@as(usize, 2), extracted.assertionsWritten);
    try std.testing.expectEqual(@as(usize, 2), try countJobs(store, "pending"));

    // May has nothing before it, so only June's job asks the model: once to
    // propose and once to verify the pair.
    const run = try runtime.dispatch(allocator, "{\"jsonrpc\":\"2.0\",\"id\":\"c1\",\"method\":\"memory.consolidate.run\",\"params\":{\"owner\":\"test\"}}");
    defer allocator.free(run);
    try std.testing.expect(std.mem.indexOf(u8, run, "\"leasedCount\":2,\"succeededCount\":2,\"failedCount\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, run, "\"promptVersion\":\"quipu.updates.v2\",\"calls\":2,\"claims\":1,\"earlier\":1,\"updatesWritten\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, run, "\"proposed\":1,\"accepted\":1") != null);
    try std.testing.expectEqual(@as(usize, 1), model.consolidate_calls.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 1), model.verify_calls.load(.monotonic));
    try std.testing.expectEqualStrings(
        "{\"new\":[{\"id\":\"N0\",\"date\":\"2023-06-10\",\"fact\":\"The user is close to 1300 followers on Instagram.\"}]," ++
            "\"earlier\":[{\"id\":\"E0\",\"date\":\"2023-05-25\",\"fact\":\"The user has 1250 followers on Instagram.\"}]}",
        model.last_comparison.?,
    );
    try std.testing.expectEqual(@as(usize, 1), try countLiveUpdates(store, sessions.may_message));

    // The facts appear only when asked for. Each is listed under the message
    // it was drawn from, the May one as superseded on the day June replaced
    // it. The raw text of both messages is untouched.
    const plain = try followerPrompt(&runtime, "");
    defer allocator.free(plain);
    try std.testing.expect(std.mem.indexOf(u8, plain, "<facts>") == null);
    try std.testing.expect(std.mem.indexOf(u8, plain, "I've got 1250 followers on Instagram now") != null);
    const with_facts = try followerPrompt(&runtime, ",\"facts\":true");
    defer allocator.free(with_facts);
    const section = try std.fmt.allocPrint(
        allocator,
        "<memory>\n<facts>\n" ++ facts_legend ++ "\n[{s}] " ++ superseded_fact ++ "\n[{s}] " ++ current_fact ++ "\n</facts>\n<sessions>",
        .{ sessions.may_message, sessions.june_message },
    );
    defer allocator.free(section);
    try std.testing.expect(std.mem.indexOf(u8, with_facts, section) != null);
    try std.testing.expect(std.mem.indexOf(u8, with_facts, "I've got 1250 followers on Instagram now") != null);
    try std.testing.expect(std.mem.indexOf(u8, with_facts, "I think I'm close to 1300 followers") != null);
    try std.testing.expect(std.mem.indexOf(u8, with_facts, assertion_qid_prefix) == null);

    // Asked as of a day before June, nothing has replaced the May fact yet,
    // so there is no fact with a history to list.
    const earlier = try followerPromptAt(&runtime, ",\"facts\":true", "2023-06-01T09:00:00Z");
    defer allocator.free(earlier);
    try std.testing.expect(std.mem.indexOf(u8, earlier, "<facts>") == null);
    try std.testing.expect(std.mem.indexOf(u8, earlier, "I've got 1250 followers on Instagram now") != null);
    try std.testing.expect(std.mem.indexOf(u8, earlier, "1300") == null);

    // The update is not a search result of its own.
    const search = try runtime.dispatch(allocator, "{\"jsonrpc\":\"2.0\",\"id\":\"s\",\"method\":\"memory.search\",\"params\":{\"query\":\"close to 1300 followers Instagram\",\"mode\":\"fts\",\"scope\":{\"projectId\":\"repo:facts\"},\"limit\":20}}");
    defer allocator.free(search);
    try std.testing.expect(std.mem.indexOf(u8, search, update_qid_prefix) == null);

    // Forgetting the newer message removes the update and its claim, so
    // the May fact has no history left and the section goes with it.
    const forget_request = try std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":\"f1\",\"method\":\"memory.forget\",\"params\":{{\"mode\":\"hard_delete\",\"selector\":{{\"qids\":[\"{s}\"]}},\"dryRun\":false,\"reason\":\"test\"}}}}",
        .{sessions.june_message},
    );
    defer allocator.free(forget_request);
    const forgotten = try runtime.dispatch(allocator, forget_request);
    defer allocator.free(forgotten);
    try std.testing.expectEqual(@as(usize, 0), try countLiveUpdates(store, sessions.may_message));
    const after = try followerPrompt(&runtime, ",\"facts\":true");
    defer allocator.free(after);
    try std.testing.expect(std.mem.indexOf(u8, after, "<facts>") == null);
    try std.testing.expect(std.mem.indexOf(u8, after, "I've got 1250 followers on Instagram now") != null);
    try std.testing.expect(std.mem.indexOf(u8, after, "1300") == null);
}

test "consolidation stores nothing the verify call rejects and forgets with the replaced message" {
    const allocator = std.testing.allocator;
    var harness = try RuntimeTestHarness.init(allocator);
    defer harness.deinit();
    const store = harness.adapter();

    // The second look says the earlier value still holds: nothing is stored.
    var doubting = UpdateTestModel{ .replaced = false };
    defer doubting.deinit();
    var runtime = Runtime.initWithOptions(store, harness.health(), .{ .extract_provider = doubting.endpoint(), .consolidate_updates = true });
    defer runtime.deinit();
    const sessions = try rememberFollowerSessions(&runtime);
    defer sessions.deinit();
    _ = try runtime.runExtractJobs(allocator, "test", 10, 1);
    const rejected = try runtime.runConsolidateJobs(allocator, "test", 10, 1);
    try std.testing.expectEqual(@as(usize, 2), rejected.succeededCount);
    try std.testing.expectEqual(@as(usize, 0), rejected.updatesWritten);
    try std.testing.expectEqual(@as(usize, 1), rejected.counts.proposed);
    try std.testing.expectEqual(@as(usize, 1), rejected.counts.unverified);
    try std.testing.expectEqual(@as(usize, 0), try countLiveUpdates(store, sessions.may_message));
    const unmarked = try followerPrompt(&runtime, ",\"facts\":true");
    defer allocator.free(unmarked);
    try std.testing.expect(std.mem.indexOf(u8, unmarked, "<facts>") == null);
    try std.testing.expect(std.mem.indexOf(u8, unmarked, "I've got 1250 followers on Instagram now") != null);

    // A value the earlier fact does not state never reaches the verify call.
    var inventing_harness = try RuntimeTestHarness.init(allocator);
    defer inventing_harness.deinit();
    var inventing = UpdateTestModel{ .old_value = "1200" };
    defer inventing.deinit();
    var invented = Runtime.initWithOptions(inventing_harness.adapter(), inventing_harness.health(), .{ .extract_provider = inventing.endpoint(), .consolidate_updates = true });
    defer invented.deinit();
    const invented_sessions = try rememberFollowerSessions(&invented);
    defer invented_sessions.deinit();
    _ = try invented.runExtractJobs(allocator, "test", 10, 1);
    const mismatched = try invented.runConsolidateJobs(allocator, "test", 10, 1);
    try std.testing.expectEqual(@as(usize, 0), mismatched.updatesWritten);
    try std.testing.expectEqual(@as(usize, 1), mismatched.counts.valueMismatch);
    try std.testing.expectEqual(@as(usize, 0), inventing.verify_calls.load(.monotonic));

    // Without the switch, extraction queues no consolidation at all.
    var plain_harness = try RuntimeTestHarness.init(allocator);
    defer plain_harness.deinit();
    var honest = UpdateTestModel{};
    defer honest.deinit();
    var plain = Runtime.initWithOptions(plain_harness.adapter(), plain_harness.health(), .{ .extract_provider = honest.endpoint() });
    defer plain.deinit();
    const plain_sessions = try rememberFollowerSessions(&plain);
    defer plain_sessions.deinit();
    _ = try plain.runExtractJobs(allocator, "test", 10, 1);
    try std.testing.expectEqual(@as(usize, 0), try countJobs(plain_harness.adapter(), "pending"));
    const none = try plain.runConsolidateJobs(allocator, "test", 10, 1);
    try std.testing.expectEqual(@as(usize, 0), none.leasedCount);

    // Turned on, the same store consolidates what comes next against the
    // claims it already holds, and forgetting the replaced message takes
    // the update along.
    plain.options.consolidate_updates = true;
    const later = try plain.dispatch(
        allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"r3\",\"method\":\"memory.remember\",\"params\":{\"scope\":{\"projectId\":\"repo:facts\"},\"sessionId\":\"s-july\",\"messages\":[{\"role\":\"user\",\"content\":\"Quick update: close to 1300 followers on Instagram became real this week.\",\"createdAt\":\"2023-07-02T09:00:00Z\"}]}}",
    );
    defer allocator.free(later);
    _ = try plain.runExtractJobs(allocator, "test", 10, 1);
    const written = try plain.runConsolidateJobs(allocator, "test", 10, 1);
    try std.testing.expectEqual(@as(usize, 1), written.updatesWritten);
    try std.testing.expectEqual(@as(usize, 1), try countLiveUpdates(plain_harness.adapter(), plain_sessions.may_message));
    const forget_request = try std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":\"f1\",\"method\":\"memory.forget\",\"params\":{{\"mode\":\"hard_delete\",\"selector\":{{\"qids\":[\"{s}\"]}},\"dryRun\":false,\"reason\":\"test\"}}}}",
        .{plain_sessions.may_message},
    );
    defer allocator.free(forget_request);
    const forgotten = try plain.dispatch(allocator, forget_request);
    defer allocator.free(forgotten);
    try std.testing.expectEqual(@as(usize, 0), try countLiveUpdates(plain_harness.adapter(), plain_sessions.may_message));
    const dump = try plain.dispatch(allocator, "{\"jsonrpc\":\"2.0\",\"id\":\"s\",\"method\":\"memory.search\",\"params\":{\"query\":\"1250 followers\",\"mode\":\"fts\",\"scope\":{\"projectId\":\"repo:facts\"},\"limit\":20}}");
    defer allocator.free(dump);
    try std.testing.expect(std.mem.indexOf(u8, dump, "1250") == null);
}

test "background work consolidates once extraction has caught up" {
    const allocator = std.testing.allocator;
    var harness = try RuntimeTestHarness.init(allocator);
    defer harness.deinit();
    const store = harness.adapter();
    var model = UpdateTestModel{};
    defer model.deinit();
    var runtime = Runtime.initWithOptions(store, harness.health(), .{
        .io = std.testing.io,
        .extract_provider = model.endpoint(),
        .background_workers = true,
        .consolidate_updates = true,
    });
    defer runtime.deinit();
    const health = try runtime.dispatch(allocator, "{\"jsonrpc\":\"2.0\",\"id\":\"h\",\"method\":\"system.health\",\"params\":{}}");
    defer allocator.free(health);
    try std.testing.expect(std.mem.indexOf(u8, health, "\"consolidator\":\"running\"") != null);
    const sessions = try rememberFollowerSessions(&runtime);
    defer sessions.deinit();

    try std.testing.expect(try runtime.startBackgroundWork(allocator));
    const extracted = (try runtime.finishBackgroundWork(allocator)).?.extract;
    try std.testing.expectEqual(@as(usize, 2), extracted.assertionsWritten);
    try std.testing.expectEqual(@as(usize, 0), try countLiveUpdates(store, sessions.may_message));

    try std.testing.expect(try runtime.startBackgroundWork(allocator));
    const consolidated = (try runtime.finishBackgroundWork(allocator)).?.consolidate;
    try std.testing.expectEqual(@as(usize, 2), consolidated.leasedCount);
    try std.testing.expectEqual(@as(usize, 2), consolidated.succeededCount);
    try std.testing.expectEqual(@as(usize, 1), consolidated.updatesWritten);
    try std.testing.expectEqual(@as(usize, 1), try countLiveUpdates(store, sessions.may_message));

    // Summary jobs and then pattern jobs run last, on a store that embeds.
    // Two conversations are too few for a pattern group, so that pass makes
    // no call.
    if (store.capabilities().vector) {
        try std.testing.expectEqual(@as(usize, 2), try countSummaryJobs(store, "pending"));
        try std.testing.expect(try runtime.startBackgroundWork(allocator));
        const summarised = (try runtime.finishBackgroundWork(allocator)).?.summaries;
        try std.testing.expectEqual(@as(usize, 2), summarised.leasedCount);
        try std.testing.expectEqual(@as(usize, 2), summarised.counts.sessionsWritten);
        try std.testing.expectEqual(@as(usize, 2), try countPatternJobs(store, "pending"));
        try std.testing.expect(try runtime.startBackgroundWork(allocator));
        const built = (try runtime.finishBackgroundWork(allocator)).?.patterns;
        try std.testing.expectEqual(@as(usize, 2), built.leasedCount);
        try std.testing.expectEqual(@as(usize, 2), built.succeededCount);
        try std.testing.expectEqual(@as(usize, 1), built.scopes);
        try std.testing.expectEqual(@as(usize, 2), built.counts.messagesIndexed);
        try std.testing.expectEqual(@as(usize, 0), built.calls);
    }
    try std.testing.expect(!try runtime.startBackgroundWork(allocator));
    try std.testing.expectEqual(@as(usize, 0), try countJobs(store, "pending"));
    try std.testing.expectEqual(@as(usize, 0), try countPatternJobs(store, "pending"));
    try std.testing.expectEqual(@as(usize, 0), try countSummaryJobs(store, "pending"));
    const with_facts = try followerPrompt(&runtime, ",\"facts\":true");
    defer allocator.free(with_facts);
    try std.testing.expect(std.mem.indexOf(u8, with_facts, superseded_fact) != null);
    try std.testing.expect(std.mem.indexOf(u8, with_facts, current_fact) != null);
}

fn rememberDated(runtime: *Runtime, session: []const u8, created_at: []const u8, content: []const u8) ![]u8 {
    const allocator = std.testing.allocator;
    const request = try std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":\"r\",\"method\":\"memory.remember\",\"params\":{{\"scope\":{{\"projectId\":\"repo:anchors\"}},\"sessionId\":\"{s}\",\"messages\":[{{\"role\":\"user\",\"content\":\"{s}\",\"createdAt\":\"{s}\"}}]}}}}",
        .{ session, content, created_at },
    );
    defer allocator.free(request);
    const response = try runtime.dispatch(allocator, request);
    defer allocator.free(response);
    return resultArrayFirst(allocator, response, "messageQids");
}

fn anchorPrompt(runtime: *Runtime, query: []const u8, options_json: []const u8) ![]u8 {
    const allocator = std.testing.allocator;
    const request = try std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":\"q\",\"method\":\"memory.retrieve\",\"params\":{{\"query\":\"{s}\",\"mode\":\"fts\",\"budgetTokens\":90,\"scope\":{{\"projectId\":\"repo:anchors\"}},\"time\":{{\"validAt\":\"2023-03-25T09:00:00Z\"}},\"options\":{{\"logRetrieval\":false,\"logAudit\":false{s}}}}}}}",
        .{ query, options_json },
    );
    defer allocator.free(request);
    const response = try runtime.dispatch(allocator, request);
    defer allocator.free(response);
    return resultStringField(allocator, response, "prompt");
}

test "time anchors bring in what was said on the day the question names" {
    const allocator = std.testing.allocator;
    var harness = try RuntimeTestHarness.init(allocator);
    defer harness.deinit();
    var runtime = Runtime.init(harness.adapter(), harness.health());
    defer runtime.deinit();

    // Three messages that match "kitchen appliance" better than the one
    // written ten days before the question.
    const blender = try rememberDated(&runtime, "s-blender", "2023-02-02T10:00:00Z", "My favorite kitchen appliance is the blender I did buy as a kitchen appliance for smoothies.");
    defer allocator.free(blender);
    const toaster = try rememberDated(&runtime, "s-toaster", "2023-02-20T10:00:00Z", "Which kitchen appliance should I buy next, a toaster or another kitchen appliance?");
    defer allocator.free(toaster);
    const kettle = try rememberDated(&runtime, "s-kettle", "2023-03-01T10:00:00Z", "I did buy a kettle, a small kitchen appliance, and I use this kitchen appliance daily.");
    defer allocator.free(kettle);
    const smoker = try rememberDated(&runtime, "s-smoker", "2023-03-15T10:00:00Z", "Just got a smoker today for the kitchen patio, brisket soon.");
    defer allocator.free(smoker);
    const reply = try runtime.dispatch(
        allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"r\",\"method\":\"memory.remember\",\"params\":{\"scope\":{\"projectId\":\"repo:anchors\"},\"sessionId\":\"s-smoker\",\"messages\":[{\"role\":\"assistant\",\"content\":\"Among kitchen appliance options, pellet grills are easy.\",\"createdAt\":\"2023-03-15T10:01:00Z\"}]}}",
    );
    defer allocator.free(reply);

    const question = "What kitchen appliance did I buy 10 days ago?";
    const anchored = try anchorPrompt(&runtime, question, "");
    defer allocator.free(anchored);
    try std.testing.expect(std.mem.indexOf(u8, anchored, "Just got a smoker today") != null);
    // The reader is told which day that is and which session is from it.
    try std.testing.expect(std.mem.indexOf(u8, anchored, "Time references: \"10 days ago\" = 2023-03-15 (Wed)\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, anchored, "## session s-smoker 2023-03-15 (Wed): this is the question's \"10 days ago\"\n") != null);
    // The assistant's reply of that day is not what the person did.
    try std.testing.expect(std.mem.indexOf(u8, anchored, "pellet grills") == null);

    // The trace says what the anchors brought in.
    const traced = try runtime.dispatch(
        allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"t\",\"method\":\"memory.retrieve\",\"params\":{\"query\":\"What kitchen appliance did I buy 10 days ago?\",\"mode\":\"fts\",\"budgetTokens\":90,\"scope\":{\"projectId\":\"repo:anchors\"},\"time\":{\"validAt\":\"2023-03-25T09:00:00Z\"},\"options\":{\"logRetrieval\":false,\"logAudit\":false,\"includeDebug\":true}}}",
    );
    defer allocator.free(traced);
    var parsed = try std.json.parseFromSlice(Value, allocator, traced, .{});
    defer parsed.deinit();
    const anchors_trace = parsed.value.object.get("result").?.object.get("trace").?.object.get("timeAnchors").?.object;
    try std.testing.expectEqual(@as(i64, 1), anchors_trace.get("windows").?.integer);
    try std.testing.expectEqual(@as(i64, 1), anchors_trace.get("items").?.integer);
    try std.testing.expect(anchors_trace.get("tokens").?.integer > 0);

    // A question that names no time gets none of it.
    const untimed = try anchorPrompt(&runtime, "What kitchen appliance did I buy?", "");
    defer allocator.free(untimed);
    try std.testing.expect(std.mem.indexOf(u8, untimed, "smoker") == null);
    try std.testing.expect(std.mem.indexOf(u8, untimed, "Time references") == null);
    try std.testing.expect(std.mem.indexOf(u8, untimed, "the question's") == null);
    try std.testing.expect(std.mem.indexOf(u8, untimed, "\"timeAnchors\"") == null);
}

/// A store that embeds for the pattern tests whatever the build's store
/// does: a sentence becomes counts of its longer words, so sentences that
/// share most of their words are alike and unrelated ones are not at all.
const PatternTestStore = struct {
    vtable: storage.Adapter.VTable,
    inner: storage.Adapter,

    fn init(inner: storage.Adapter) PatternTestStore {
        var vtable = inner.vtable.*;
        vtable.capabilities = capabilities;
        vtable.embed_text = embedText;
        return .{ .vtable = vtable, .inner = inner };
    }

    fn adapter(self: *PatternTestStore) storage.Adapter {
        return .{ .context = self.inner.context, .vtable = &self.vtable };
    }

    /// What the tests turn to play an embedding outage and a changed model.
    var down: bool = false;
    var model: ?[]const u8 = null;

    fn capabilities(_: *anyopaque) storage.Capabilities {
        return .{ .vector = true, .embedding_model = model };
    }

    fn embedText(_: *anyopaque, allocator: std.mem.Allocator, text: []const u8) anyerror![]f32 {
        if (down) return error.ProviderRequestFailed;
        const vector = try allocator.alloc(f32, patterns.dims);
        @memset(vector, 0);
        var words = std.mem.tokenizeAny(u8, text, " .,?!'\"\n");
        while (words.next()) |word| {
            if (word.len <= 3) continue;
            var lower: [64]u8 = undefined;
            const key = std.ascii.lowerString(&lower, word[0..@min(word.len, lower.len)]);
            vector[std.hash.Wyhash.hash(11, key) % patterns.dims] += 1;
        }
        return vector;
    }
};

/// Plays the chat model for the pattern tests: calls a group of loaves
/// recurring, proposes that fridge-proved loaves come out flat, and answers
/// the two questions from each occasion's own text.
const PatternTestModel = struct {
    gate_calls: std.atomic.Value(usize) = .init(0),
    claims_calls: std.atomic.Value(usize) = .init(0),
    check_calls: std.atomic.Value(usize) = .init(0),
    model: []const u8 = "test-extract-model",

    fn endpoint(self: *PatternTestModel) providers.ProviderEndpoint {
        return .{
            .kind = .callback,
            .name = "test-extractor",
            .model = self.model,
            .callback = .{ .context = self, .respond = respond },
        };
    }

    fn respond(context: ?*anyopaque, allocator: std.mem.Allocator, turn: providers.ChatTurn) anyerror![]u8 {
        const self: *PatternTestModel = @ptrCast(@alignCast(context.?));
        if (try testSummaryReply(allocator, turn)) |reply| return reply;
        if (std.mem.startsWith(u8, turn.system_prompt, patterns.gate_prompt)) {
            _ = self.gate_calls.fetchAdd(1, .monotonic);
            return allocator.dupe(u8, "{\"about\":\"Sourdough loaves\",\"type\":\"recurring\"}");
        }
        if (std.mem.startsWith(u8, turn.system_prompt, patterns.claims_prompt)) {
            _ = self.claims_calls.fetchAdd(1, .monotonic);
            return allocator.dupe(u8, "{\"claims\":[{\"claim\":\"The user's loaves proved in the fridge come out flat.\",\"when\":\"Was the dough proved in the fridge?\",\"then\":\"Did the loaf come out flat?\"}],\"summary\":\"Loaves of sourdough baked at home.\"}");
        }
        if (std.mem.startsWith(u8, turn.system_prompt, patterns.check_prompt)) {
            _ = self.check_calls.fetchAdd(1, .monotonic);
            var parsed = try std.json.parseFromSlice(Value, allocator, turn.user_content, .{});
            defer parsed.deinit();
            var reply = std.ArrayList(u8).empty;
            errdefer reply.deinit(allocator);
            try reply.appendSlice(allocator, "{\"answers\":[");
            for (parsed.value.object.get("members").?.array.items, 0..) |member, index| {
                const text = member.object.get("text").?.string;
                try reply.print(allocator, "{s}{{\"id\":\"{s}\",\"when\":\"{s}\",\"then\":\"{s}\"}}", .{
                    if (index > 0) "," else "",
                    member.object.get("id").?.string,
                    if (std.mem.indexOf(u8, text, "fridge") != null) "yes" else "no",
                    if (std.mem.indexOf(u8, text, "flat") != null) "yes" else "no",
                });
            }
            try reply.appendSlice(allocator, "]}");
            return reply.toOwnedSlice(allocator);
        }
        return allocator.dupe(u8, "{\"assertions\":[]}");
    }
};

const pattern_test_fillers = [_][]const u8{
    "The plumber replaced the leaking kitchen tap washer.",
    "Wendell moved house towards Whitby last weekend.",
    "Hadley's garage booked the annual inspection.",
    "Ingrid borrowed the gardening encyclopedia again.",
    "Oswin announced leaving drinks next Thursday.",
    "Pottery classes begin Tuesday evening downtown.",
    "Quarterly invoices finally reached accounting.",
    "Marigold seedlings sprouted beside the greenhouse.",
    "Violin practice lasted ninety minutes.",
    "Neighbours repainted their fence bright yellow.",
};

/// Stores one conversation of one message on day `day` of January 2025 and
/// returns the message qid.
fn rememberPatternDay(runtime: *Runtime, day: usize, content: []const u8) ![]u8 {
    const allocator = std.testing.allocator;
    const request = try std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":\"r\",\"method\":\"memory.remember\",\"params\":{{\"scope\":{{\"userId\":\"baker\"}},\"sessionId\":\"day-{d}\",\"messages\":[{{\"role\":\"user\",\"content\":\"{s}\",\"createdAt\":\"2025-01-{d:0>2}T19:00:00Z\"}}]}}}}",
        .{ day, content, day },
    );
    defer allocator.free(request);
    const response = try runtime.dispatch(allocator, request);
    defer allocator.free(response);
    return resultArrayFirst(allocator, response, "messageQids");
}

/// Runs the pending extract jobs, then the pattern jobs they queued, and
/// returns the pattern run's response.
fn runPatternPass(runtime: *Runtime) ![]u8 {
    const allocator = std.testing.allocator;
    const extracted = try runtime.dispatch(allocator, "{\"jsonrpc\":\"2.0\",\"id\":\"x\",\"method\":\"memory.extract.run\",\"params\":{}}");
    allocator.free(extracted);
    return runtime.dispatch(allocator, "{\"jsonrpc\":\"2.0\",\"id\":\"p\",\"method\":\"memory.patterns.run\",\"params\":{}}");
}

fn patternRetrieve(runtime: *Runtime, query: []const u8) ![]u8 {
    const allocator = std.testing.allocator;
    const request = try std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":\"q\",\"method\":\"memory.retrieve\",\"params\":{{\"query\":\"{s}\",\"scope\":{{\"userId\":\"baker\"}},\"mode\":\"fts\",\"budgetTokens\":2000,\"options\":{{\"includeDebug\":true,\"logRetrieval\":false}}}}}}",
        .{query},
    );
    defer allocator.free(request);
    return runtime.dispatch(allocator, request);
}

/// Eight loaves on alternate days, fridge-proved ones flat and counter-proved
/// ones tall, among days about other things.
fn rememberLoaves(runtime: *Runtime) ![]u8 {
    const allocator = std.testing.allocator;
    var first_loaf: ?[]u8 = null;
    errdefer if (first_loaf) |qid| allocator.free(qid);
    for (0..18) |index| {
        const day = index + 1;
        if (index % 2 == 1 and index / 2 < pattern_test_fillers.len) {
            allocator.free(try rememberPatternDay(runtime, day, pattern_test_fillers[index / 2]));
            continue;
        }
        if (index >= 16) {
            allocator.free(try rememberPatternDay(runtime, day, pattern_test_fillers[index - 8]));
            continue;
        }
        const fridge = (index / 2) % 2 == 0;
        const qid = try rememberPatternDay(runtime, day, if (fridge)
            "I baked a sourdough loaf and proved the dough in the fridge overnight. That sourdough loaf came out flat and dense."
        else
            "I baked a sourdough loaf and proved the dough on the counter today. That sourdough loaf came out tall and airy.");
        if (first_loaf == null) first_loaf = qid else allocator.free(qid);
    }
    return first_loaf.?;
}

test "pattern jobs build a node from occasions and retrieval gives it to the question it owns" {
    const allocator = std.testing.allocator;
    var harness = try RuntimeTestHarness.init(allocator);
    defer harness.deinit();
    var store = PatternTestStore.init(harness.adapter());
    var model = PatternTestModel{};
    var runtime = Runtime.initWithOptions(store.adapter(), harness.health(), .{ .extract_provider = model.endpoint() });
    defer runtime.deinit();

    const health = try runtime.dispatch(allocator, "{\"jsonrpc\":\"2.0\",\"id\":\"h\",\"method\":\"system.health\",\"params\":{}}");
    defer allocator.free(health);
    try std.testing.expect(std.mem.indexOf(u8, health, "\"patterns\":\"stopped\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, health, "\"summaries\":\"stopped\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, health, "\"summaries\":{\"available\":true,\"promptVersion\":\"quipu.summaries.v1\",\"model\":\"test-extract-model\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, health, "\"patterns\":{\"available\":true,\"promptVersion\":\"quipu.patterns.v1\",\"model\":\"test-extract-model\"}") != null);

    const first_loaf = try rememberLoaves(&runtime);
    defer allocator.free(first_loaf);
    const built = try runPatternPass(&runtime);
    defer allocator.free(built);
    // Eighteen conversations asked for one rebuild of one scope.
    try std.testing.expect(std.mem.indexOf(u8, built, "\"leasedCount\":18,\"succeededCount\":18,\"failedCount\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, built, "\"scopes\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, built, "\"messagesIndexed\":18") != null);
    try std.testing.expect(std.mem.indexOf(u8, built, "\"occasions\":18") != null);
    try std.testing.expect(std.mem.indexOf(u8, built, "\"eligible\":1,\"gated\":1,\"proposed\":1,\"answered\":8,\"malformed\":0,\"written\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, built, "\"regularities\":1") != null);
    try std.testing.expectEqual(@as(usize, 1), model.gate_calls.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 1), model.claims_calls.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 3), model.check_calls.load(.monotonic));

    // The question about loaves is owned by the node; a lookup is not.
    const owned = try patternRetrieve(&runtime, "Why do some of my sourdough loaves come out flat?");
    defer allocator.free(owned);
    try std.testing.expect(std.mem.indexOf(u8, owned, "<patterns>") != null);
    try std.testing.expect(std.mem.indexOf(u8, owned, "Sourdough loaves: Worked out by the memory from 8 occasions, never stated by the person: The user's loaves proved in the fridge come out flat (so on 4 of the 4 occasions where that applied, against 0 of the 4 where it did not).") != null);
    try std.testing.expect(std.mem.indexOf(u8, owned, "\"type\":\"pattern\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, owned, "\"patterns\":{\"candidates\":1,\"sentences\":26,\"ownedMost\":10,\"kept\":1,") != null);
    // Its evidence is what each occasion said.
    try std.testing.expect(std.mem.indexOf(u8, owned, "\"quote\":\"I baked a sourdough loaf and proved the dough in the fridge overnight. That sourdough loaf came out flat and dense.\",\"timestamp\":\"2025-01-01T19:00:00Z\"") != null);
    const lookup = try patternRetrieve(&runtime, "Which washer did the plumber replace?");
    defer allocator.free(lookup);
    try std.testing.expect(std.mem.indexOf(u8, lookup, "<patterns>") == null);
    try std.testing.expect(std.mem.indexOf(u8, lookup, "\"patterns\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, lookup, "\"patterns\":{\"candidates\":1,\"sentences\":26,\"ownedMost\":0,\"kept\":0,\"tokens\":0}") != null);
    try std.testing.expect(std.mem.indexOf(u8, lookup, "plumber replaced the leaking kitchen tap") != null);

    // One more loaf: the generalisation is kept, and only the new occasion
    // is asked about.
    allocator.free(try rememberPatternDay(&runtime, 19, "I baked a sourdough loaf and proved the dough in the fridge overnight. That sourdough loaf came out flat and dense."));
    allocator.free(try rememberPatternDay(&runtime, 20, "Lighthouse keepers welcomed visiting schoolchildren."));
    const grown = try runPatternPass(&runtime);
    defer allocator.free(grown);
    try std.testing.expect(std.mem.indexOf(u8, grown, "\"eligible\":1,\"gated\":0,\"proposed\":0,\"answered\":1,\"malformed\":0,\"written\":1") != null);
    try std.testing.expectEqual(@as(usize, 1), model.gate_calls.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 1), model.claims_calls.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 4), model.check_calls.load(.monotonic));
    const regrown = try patternRetrieve(&runtime, "Why do some of my sourdough loaves come out flat?");
    defer allocator.free(regrown);
    try std.testing.expect(std.mem.indexOf(u8, regrown, "from 9 occasions") != null);
    try std.testing.expect(std.mem.indexOf(u8, regrown, "(so on 5 of the 5 occasions where that applied, against 0 of the 4 where it did not)") != null);

    // Nothing new: no job, no call.
    const idle = try runtime.dispatch(allocator, "{\"jsonrpc\":\"2.0\",\"id\":\"p\",\"method\":\"memory.patterns.run\",\"params\":{}}");
    defer allocator.free(idle);
    try std.testing.expect(std.mem.indexOf(u8, idle, "\"leasedCount\":0") != null);
    try std.testing.expectEqual(@as(usize, 4), model.check_calls.load(.monotonic));
}

test "forgetting an occasion removes its pattern node and rebuilds from the rest" {
    const allocator = std.testing.allocator;
    var harness = try RuntimeTestHarness.init(allocator);
    defer harness.deinit();
    var store = PatternTestStore.init(harness.adapter());
    var model = PatternTestModel{};
    var runtime = Runtime.initWithOptions(store.adapter(), harness.health(), .{ .extract_provider = model.endpoint() });
    defer runtime.deinit();

    const first_loaf = try rememberLoaves(&runtime);
    defer allocator.free(first_loaf);
    allocator.free(try rememberPatternDay(&runtime, 19, "I baked a sourdough loaf and proved the dough in the fridge overnight. That sourdough loaf came out flat and dense."));
    allocator.free(try rememberPatternDay(&runtime, 20, "Lighthouse keepers welcomed visiting schoolchildren."));
    allocator.free(try runPatternPass(&runtime));
    const before = try patternRetrieve(&runtime, "Why do some of my sourdough loaves come out flat?");
    defer allocator.free(before);
    try std.testing.expect(std.mem.indexOf(u8, before, "from 9 occasions") != null);
    const calls_before = model.gate_calls.load(.monotonic) + model.claims_calls.load(.monotonic);

    const forget_request = try std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":\"f\",\"method\":\"memory.forget\",\"params\":{{\"selector\":{{\"qids\":[\"{s}\"]}},\"mode\":\"hard_delete\",\"reason\":\"test\"}}}}",
        .{first_loaf},
    );
    defer allocator.free(forget_request);
    const forgotten = try runtime.dispatch(allocator, forget_request);
    defer allocator.free(forgotten);
    // The node and the message's sentence index go with the message.
    try std.testing.expect(std.mem.indexOf(u8, forgotten, "\"type\":\"pattern\",\"action\":\"invalidated\"") != null);
    const index_qid = try sentenceIndexQid(allocator, first_loaf);
    defer allocator.free(index_qid);
    try std.testing.expect(!try runtime.nodeIsLive(allocator, index_qid));
    const gone = try patternRetrieve(&runtime, "Why do some of my sourdough loaves come out flat?");
    defer allocator.free(gone);
    try std.testing.expect(std.mem.indexOf(u8, gone, "<patterns>") == null);

    // The forget queued a rebuild: a new node, proposed and counted afresh
    // from the eight loaves that remain.
    const rebuilt = try runtime.dispatch(allocator, "{\"jsonrpc\":\"2.0\",\"id\":\"p\",\"method\":\"memory.patterns.run\",\"params\":{}}");
    defer allocator.free(rebuilt);
    try std.testing.expect(std.mem.indexOf(u8, rebuilt, "\"leasedCount\":1,\"succeededCount\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, rebuilt, "\"gated\":1,\"proposed\":1,\"answered\":8") != null);
    try std.testing.expectEqual(calls_before + 2, model.gate_calls.load(.monotonic) + model.claims_calls.load(.monotonic));
    const after = try patternRetrieve(&runtime, "Why do some of my sourdough loaves come out flat?");
    defer allocator.free(after);
    try std.testing.expect(std.mem.indexOf(u8, after, "from 8 occasions") != null);
    try std.testing.expect(std.mem.indexOf(u8, after, "(so on 4 of the 4 occasions where that applied, against 0 of the 4 where it did not)") != null);
    const forgotten_evidence = try std.fmt.allocPrint(allocator, "\"qid\":\"{s}\"", .{first_loaf});
    defer allocator.free(forgotten_evidence);
    try std.testing.expect(std.mem.indexOf(u8, after, forgotten_evidence) == null);
}

test "a backlog of messages is indexed over several pattern passes before anything is grouped" {
    const allocator = std.testing.allocator;
    var harness = try RuntimeTestHarness.init(allocator);
    defer harness.deinit();
    var store = PatternTestStore.init(harness.adapter());
    var model = PatternTestModel{};
    var runtime = Runtime.initWithOptions(store.adapter(), harness.health(), .{ .extract_provider = model.endpoint() });
    defer runtime.deinit();

    // Ten loaves among seventy messages, more than one pass may embed.
    const total = pattern_index_limit + 6;
    for (0..total) |index| {
        const content = if (index % 7 == 0)
            try allocator.dupe(u8, if ((index / 7) % 2 == 0)
                "I baked a sourdough loaf and proved the dough in the fridge overnight. That sourdough loaf came out flat and dense."
            else
                "I baked a sourdough loaf and proved the dough on the counter today. That sourdough loaf came out tall and airy.")
        else
            try std.fmt.allocPrint(allocator, "Errand number {d} involved parcel {d}x{d} downtown.", .{ index, index * 37, index * 101 });
        defer allocator.free(content);
        const request = try std.fmt.allocPrint(
            allocator,
            "{{\"jsonrpc\":\"2.0\",\"id\":\"r\",\"method\":\"memory.remember\",\"params\":{{\"scope\":{{\"userId\":\"baker\"}},\"sessionId\":\"n-{d}\",\"messages\":[{{\"role\":\"user\",\"content\":\"{s}\",\"createdAt\":\"2025-{d:0>2}-{d:0>2}T19:00:00Z\"}}]}}}}",
            .{ index, content, index / 28 + 1, index % 28 + 1 },
        );
        defer allocator.free(request);
        allocator.free(try runtime.dispatch(allocator, request));
    }
    const extracted = try runtime.dispatch(allocator, "{\"jsonrpc\":\"2.0\",\"id\":\"x\",\"method\":\"memory.extract.run\",\"params\":{}}");
    allocator.free(extracted);

    // Between requests one pass embeds its share and asks nothing.
    var first = PatternJobRunResult{};
    try runtime.runPatternPass(allocator, "test", pattern_lease_limit, &first);
    try std.testing.expectEqual(pattern_index_limit, first.counts.messagesIndexed);
    try std.testing.expectEqual(@as(usize, 0), first.counts.occasions);
    try std.testing.expectEqual(@as(usize, 0), first.calls);
    try std.testing.expect(first.continued);
    try std.testing.expectEqual(@as(usize, 0), model.gate_calls.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 1), try countPatternJobs(store.adapter(), "pending"));

    // Asked to run the jobs, the daemon finishes the backlog and then groups.
    const rest = try runtime.dispatch(allocator, "{\"jsonrpc\":\"2.0\",\"id\":\"p\",\"method\":\"memory.patterns.run\",\"params\":{}}");
    defer allocator.free(rest);
    try std.testing.expect(std.mem.indexOf(u8, rest, "\"messagesIndexed\":6,") != null);
    try std.testing.expect(std.mem.indexOf(u8, rest, "\"occasions\":70,") != null);
    try std.testing.expect(std.mem.indexOf(u8, rest, "\"regularities\":1") != null);
    try std.testing.expectEqual(@as(usize, 1), model.gate_calls.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 0), try countPatternJobs(store.adapter(), "pending"));
}

test "a pattern node forgotten while its calls are out is not written back" {
    const allocator = std.testing.allocator;
    var harness = try RuntimeTestHarness.init(allocator);
    defer harness.deinit();
    var store = PatternTestStore.init(harness.adapter());
    var model = PatternTestModel{};
    var runtime = Runtime.initWithOptions(store.adapter(), harness.health(), .{ .extract_provider = model.endpoint() });
    defer runtime.deinit();

    allocator.free(try rememberLoaves(&runtime));
    allocator.free(try runPatternPass(&runtime));
    const before = try patternRetrieve(&runtime, "Why do some of my sourdough loaves come out flat?");
    defer allocator.free(before);
    const marker = "\"qid\":\"q_pat_";
    const at = (std.mem.indexOf(u8, before, marker) orelse return error.TestUnexpectedResult) + "\"qid\":\"".len;
    const node_qid = before[at .. at + (std.mem.indexOfScalar(u8, before[at..], '"') orelse return error.TestUnexpectedResult)];

    // A ninth loaf: the next pass has new answers to write to the node.
    allocator.free(try rememberPatternDay(&runtime, 19, "I baked a sourdough loaf and proved the dough in the fridge overnight. That sourdough loaf came out flat and dense."));
    const extracted = try runtime.dispatch(allocator, "{\"jsonrpc\":\"2.0\",\"id\":\"x\",\"method\":\"memory.extract.run\",\"params\":{}}");
    allocator.free(extracted);
    const leases = try jobs.leasePendingJobs(allocator, runtime.store, .{
        .worker_kind = streams.workerKindForStream(streams.pattern_requested),
        .owner = "test",
        .now_ms = runtime.nowMs(),
        .ttl_ms = pattern_lease_ttl_ms,
    });
    defer jobs.freeLeaseResults(allocator, leases);
    const tasks = try runtime.preparePatternTasks(allocator, leases);
    defer freePatternTasks(allocator, tasks);
    for (tasks) |*task| callPatternTask(task, allocator, null, runtime.options.extract_provider);

    // The node is forgotten between the calls and the write.
    const forget_request = try std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":\"f\",\"method\":\"memory.forget\",\"params\":{{\"selector\":{{\"qids\":[\"{s}\"]}},\"mode\":\"hard_delete\",\"reason\":\"test\"}}}}",
        .{node_qid},
    );
    defer allocator.free(forget_request);
    allocator.free(try runtime.dispatch(allocator, forget_request));
    try std.testing.expect(!try runtime.nodeIsLive(allocator, node_qid));

    var result = PatternJobRunResult{};
    try runtime.applyPatternTasks(allocator, tasks, &result);
    try std.testing.expect(!try runtime.nodeIsLive(allocator, node_qid));
    const gone = try patternRetrieve(&runtime, "Why do some of my sourdough loaves come out flat?");
    defer allocator.free(gone);
    try std.testing.expect(std.mem.indexOf(u8, gone, "<patterns>") == null);

    // The loaves themselves were not forgotten, so the next pass over the
    // scope works the pattern out again, as a node of its own.
    allocator.free(try rememberPatternDay(&runtime, 20, "Lighthouse keepers welcomed visiting schoolchildren."));
    allocator.free(try runPatternPass(&runtime));
    const after = try patternRetrieve(&runtime, "Why do some of my sourdough loaves come out flat?");
    defer allocator.free(after);
    try std.testing.expect(std.mem.indexOf(u8, after, "from 9 occasions") != null);
    try std.testing.expect(std.mem.indexOf(u8, after, node_qid) == null);
    try std.testing.expect(!try runtime.nodeIsLive(allocator, node_qid));
}

test "an embedding provider that is down leaves summary and pattern jobs unspent and the worker waiting" {
    const allocator = std.testing.allocator;
    var harness = try RuntimeTestHarness.init(allocator);
    defer harness.deinit();
    var store = PatternTestStore.init(harness.adapter());
    var model = PatternTestModel{};
    var runtime = Runtime.initWithOptions(store.adapter(), harness.health(), .{
        .io = std.testing.io,
        .extract_provider = model.endpoint(),
        .background_workers = true,
    });
    defer runtime.deinit();

    allocator.free(try rememberLoaves(&runtime));
    const extracted = try runtime.dispatch(allocator, "{\"jsonrpc\":\"2.0\",\"id\":\"x\",\"method\":\"memory.extract.run\",\"params\":{}}");
    allocator.free(extracted);
    const queued = try countPatternJobs(runtime.store, "pending");
    try std.testing.expect(queued > 0);

    const queued_summaries = try countSummaryJobs(runtime.store, "pending");
    try std.testing.expect(queued_summaries > 0);

    // Summaries go first. The chat model answers, but a summary is not
    // stored without its vector: the jobs go back with their attempts.
    PatternTestStore.down = true;
    defer PatternTestStore.down = false;
    try std.testing.expect(try runtime.startBackgroundWork(allocator));
    const unembedded = (try runtime.finishBackgroundWork(allocator)).?.summaries;
    try std.testing.expectEqual(@as(usize, 1), unembedded.failedCount);
    try std.testing.expectEqualStrings("ProviderRequestFailed", unembedded.lastError.?);
    try std.testing.expectEqual(queued_summaries, try countSummaryJobs(runtime.store, "pending"));
    try std.testing.expectEqual(@as(usize, 0), try countSummaryJobs(runtime.store, "deadlettered"));
    try std.testing.expectEqual(background_backoff_initial_ms, runtime.background_backoff_ms);
    try std.testing.expect(!try runtime.startBackgroundWork(allocator));

    // The wait over and the provider still down, the pattern jobs fare the
    // same once the summaries are out of the way.
    allocator.free(try runtime.dispatch(allocator, "{\"jsonrpc\":\"2.0\",\"id\":\"s\",\"method\":\"memory.summaries.run\",\"params\":{}}"));
    try std.testing.expectEqual(queued_summaries, try countSummaryJobs(runtime.store, "pending"));
    PatternTestStore.down = false;
    allocator.free(try runtime.dispatch(allocator, "{\"jsonrpc\":\"2.0\",\"id\":\"s\",\"method\":\"memory.summaries.run\",\"params\":{}}"));
    try std.testing.expectEqual(@as(usize, 0), try countSummaryJobs(runtime.store, "pending"));
    PatternTestStore.down = true;
    runtime.background_retry_at_ms = 0;
    runtime.background_backoff_ms = 0;
    try std.testing.expect(try runtime.startBackgroundWork(allocator));
    const failed = (try runtime.finishBackgroundWork(allocator)).?.patterns;
    try std.testing.expectEqual(@as(usize, 1), failed.failedCount);
    try std.testing.expectEqualStrings("ProviderRequestFailed", failed.lastError.?);
    try std.testing.expectEqual(queued, try countPatternJobs(runtime.store, "pending"));
    try std.testing.expectEqual(@as(usize, 0), try countPatternJobs(runtime.store, "failed"));
    try std.testing.expectEqual(background_backoff_initial_ms, runtime.background_backoff_ms);
    try std.testing.expect(!try runtime.startBackgroundWork(allocator));

    // The provider is back: the same jobs build the node.
    PatternTestStore.down = false;
    runtime.background_retry_at_ms = 0;
    allocator.free(try runtime.dispatch(allocator, "{\"jsonrpc\":\"2.0\",\"id\":\"p\",\"method\":\"memory.patterns.run\",\"params\":{}}"));
    const after = try patternRetrieve(&runtime, "Why do some of my sourdough loaves come out flat?");
    defer allocator.free(after);
    try std.testing.expect(std.mem.indexOf(u8, after, "from 8 occasions") != null);
}

test "sentence indexes made by another embedding model are made again" {
    const allocator = std.testing.allocator;
    var harness = try RuntimeTestHarness.init(allocator);
    defer harness.deinit();
    var store = PatternTestStore.init(harness.adapter());
    var model = PatternTestModel{};
    var runtime = Runtime.initWithOptions(store.adapter(), harness.health(), .{ .extract_provider = model.endpoint() });
    defer runtime.deinit();

    PatternTestStore.model = "embed-a";
    defer PatternTestStore.model = null;
    allocator.free(try rememberLoaves(&runtime));
    const first = try runPatternPass(&runtime);
    defer allocator.free(first);
    try std.testing.expect(std.mem.indexOf(u8, first, "\"messagesIndexed\":18") != null);

    // Under another model the stored vectors mean nothing: no node is shown
    // from them, and the next pass indexes every message again.
    PatternTestStore.model = "embed-b";
    const stale = try patternRetrieve(&runtime, "Why do some of my sourdough loaves come out flat?");
    defer allocator.free(stale);
    try std.testing.expect(std.mem.indexOf(u8, stale, "<patterns>") == null);
    allocator.free(try rememberPatternDay(&runtime, 19, "Lighthouse keepers welcomed visiting schoolchildren."));
    const second = try runPatternPass(&runtime);
    defer allocator.free(second);
    try std.testing.expect(std.mem.indexOf(u8, second, "\"messagesIndexed\":19") != null);
    const fresh = try patternRetrieve(&runtime, "Why do some of my sourdough loaves come out flat?");
    defer allocator.free(fresh);
    try std.testing.expect(std.mem.indexOf(u8, fresh, "from 8 occasions") != null);
}

/// Extracts one claim from each of the summary tests' messages and answers
/// the summary job. The claims about the starter share most of their words,
/// so `PatternTestStore` puts their vectors close together.
const SummaryTestModel = struct {
    session_calls: usize = 0,
    topic_calls: usize = 0,
    /// The last topic request, and whether the model says its facts do not
    /// belong together.
    last_topic: ?[]u8 = null,
    decline: bool = false,
    /// Summarise a session that mentions the starter as being about it.
    name_starter_sessions: bool = false,

    const extract_replies = [_][2][]const u8{
        .{ "I keep a sourdough starter", "{\"assertions\":[{\"text\":\"The user keeps a sourdough starter named Bubbles.\",\"messageIndex\":0,\"quote\":\"I keep a sourdough starter named Bubbles\"}]}" },
        .{ "I feed", "{\"assertions\":[{\"text\":\"The user feeds the sourdough starter named Bubbles daily.\",\"messageIndex\":0,\"quote\":\"I feed Bubbles\"}]}" },
        .{ "ferry", "{\"assertions\":[{\"text\":\"The user booked a ferry to Zanzibar for August.\",\"messageIndex\":0,\"quote\":\"I booked a ferry to Zanzibar\"}]}" },
        .{ "I gave half", "{\"assertions\":[{\"text\":\"The user gave half of the sourdough starter named Bubbles away.\",\"messageIndex\":0,\"quote\":\"I gave half of Bubbles\"}]}" },
    };

    fn endpoint(self: *SummaryTestModel) providers.ProviderEndpoint {
        return .{
            .kind = .callback,
            .name = "test-extractor",
            .model = "test-extract-model",
            .callback = .{ .context = self, .respond = respond },
        };
    }

    fn respond(context: ?*anyopaque, allocator: std.mem.Allocator, turn: providers.ChatTurn) anyerror![]u8 {
        const self: *SummaryTestModel = @ptrCast(@alignCast(context.?));
        if (std.mem.startsWith(u8, turn.system_prompt, summaries.session_prompt)) {
            self.session_calls += 1;
            if (self.name_starter_sessions and std.mem.indexOf(u8, turn.user_content, "Bubbles") != null) {
                return allocator.dupe(u8, "{\"title\":\"Looking after Bubbles\",\"summary\":\"The user talked about the sourdough starter Bubbles.\"}");
            }
            return allocator.dupe(u8, "{\"title\":\"A chat about the user's day\",\"summary\":\"The user mentioned something they did.\"}");
        }
        if (std.mem.startsWith(u8, turn.system_prompt, summaries.topic_prompt)) {
            self.topic_calls += 1;
            if (self.last_topic) |previous| std.testing.allocator.free(previous);
            self.last_topic = try std.testing.allocator.dupe(u8, turn.user_content);
            if (self.decline) return allocator.dupe(u8, "{\"title\":null,\"summary\":null}");
            return allocator.dupe(u8, "{\"title\":\"Sourdough starter Bubbles\",\"summary\":\"The user keeps a starter named Bubbles and looks after it.\"}");
        }
        for (extract_replies) |pair| {
            if (std.mem.indexOf(u8, turn.user_content, pair[0]) != null) return allocator.dupe(u8, pair[1]);
        }
        return allocator.dupe(u8, "{\"assertions\":[]}");
    }

    fn deinit(self: *SummaryTestModel) void {
        if (self.last_topic) |value| std.testing.allocator.free(value);
    }
};

/// A current summary node of the tests' scope, owned by the test allocator.
const TestSummary = struct {
    qid: []u8,
    properties: std.json.Parsed(Value),

    fn deinit(self: TestSummary) void {
        std.testing.allocator.free(self.qid);
        self.properties.deinit();
    }

    fn string(self: TestSummary, key: []const u8) []const u8 {
        return stringValue(self.properties.value.object.get(key)) orelse "";
    }
};

/// The current summaries of one kind, in qid order.
fn currentSummaries(store: storage.Adapter, kind: []const u8) ![]TestSummary {
    const allocator = std.testing.allocator;
    var found = std.ArrayList(TestSummary).empty;
    errdefer {
        for (found.items) |summary| summary.deinit();
        found.deinit(allocator);
    }
    var iterator = store.iterateNodes(allocator, .{ .label = "Summary", .where = &.{.{ .name = "state", .value = "current" }} });
    defer iterator.deinit();
    while (try iterator.next()) |qid| {
        const node = (try store.getNode(allocator, qid)).?;
        defer store.freeNode(allocator, node);
        var properties = try std.json.parseFromSlice(Value, allocator, node.properties_json, .{ .allocate = .alloc_always });
        errdefer properties.deinit();
        if (!std.mem.eql(u8, stringValue(properties.value.object.get("summaryType")) orelse "", kind)) {
            properties.deinit();
            continue;
        }
        try found.append(allocator, .{ .qid = try allocator.dupe(u8, qid), .properties = properties });
    }
    std.mem.sort(TestSummary, found.items, {}, struct {
        fn before(_: void, left: TestSummary, right: TestSummary) bool {
            return std.mem.order(u8, left.qid, right.qid) == .lt;
        }
    }.before);
    return found.toOwnedSlice(allocator);
}

fn freeSummaries(summaries_found: []TestSummary) void {
    for (summaries_found) |summary| summary.deinit();
    std.testing.allocator.free(summaries_found);
}

fn rememberStarterDay(runtime: *Runtime, day: usize, content: []const u8) ![]u8 {
    const allocator = std.testing.allocator;
    const request = try std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":\"r\",\"method\":\"memory.remember\",\"params\":{{\"scope\":{{\"userId\":\"baker\"}},\"sessionId\":\"day-{d}\",\"messages\":[{{\"role\":\"user\",\"content\":\"{s}\",\"createdAt\":\"2023-05-{d:0>2}T19:00:00Z\"}},{{\"role\":\"assistant\",\"content\":\"Noted.\",\"createdAt\":\"2023-05-{d:0>2}T19:00:05Z\"}}]}}}}",
        .{ day, content, day, day },
    );
    defer allocator.free(request);
    const response = try runtime.dispatch(allocator, request);
    defer allocator.free(response);
    return resultArrayFirst(allocator, response, "messageQids");
}

fn edgeExists(store: storage.Adapter, from_qid: []const u8, to_qid: []const u8, edge_type: []const u8) !bool {
    const allocator = std.testing.allocator;
    const edges = try store.findEdges(allocator, .{ .from_qid = from_qid, .to_qid = to_qid, .edge_type = edge_type, .limit = 4 });
    defer store.freeEdges(allocator, edges);
    return edges.len > 0;
}

test "summary jobs write a summary per session and per topic and ask again only for what changed" {
    const allocator = std.testing.allocator;
    var harness = try RuntimeTestHarness.init(allocator);
    defer harness.deinit();
    var store = PatternTestStore.init(harness.adapter());
    var model = SummaryTestModel{};
    defer model.deinit();
    var runtime = Runtime.initWithOptions(store.adapter(), harness.health(), .{ .extract_provider = model.endpoint() });
    defer runtime.deinit();

    const keep = try rememberStarterDay(&runtime, 1, "I keep a sourdough starter named Bubbles.");
    defer allocator.free(keep);
    const feed = try rememberStarterDay(&runtime, 8, "I feed Bubbles every morning.");
    defer allocator.free(feed);
    allocator.free(try rememberStarterDay(&runtime, 10, "I booked a ferry to Zanzibar for August."));
    _ = try runtime.runExtractJobs(allocator, "test", 10, 1);
    try std.testing.expectEqual(@as(usize, 3), try countSummaryJobs(runtime.store, "pending"));

    // Three sessions, and one topic: the two claims about the starter. The
    // ferry stands alone.
    const first = try runtime.runSummaryJobs(allocator, "test", 100);
    try std.testing.expectEqual(@as(usize, 3), first.succeededCount);
    try std.testing.expectEqual(@as(usize, 1), first.scopes);
    try std.testing.expectEqual(@as(usize, 4), first.calls);
    try std.testing.expectEqual(@as(usize, 3), first.counts.sessions);
    try std.testing.expectEqual(@as(usize, 3), first.counts.sessionsWritten);
    try std.testing.expectEqual(@as(usize, 3), first.counts.claims);
    try std.testing.expectEqual(@as(usize, 3), first.counts.claimsIndexed);
    try std.testing.expectEqual(@as(usize, 1), first.counts.groups);
    try std.testing.expectEqual(@as(usize, 1), first.counts.topicsWritten);
    try std.testing.expectEqualStrings(
        "- said 2023-05-01: The user keeps a sourdough starter named Bubbles.\n- said 2023-05-08: The user feeds the sourdough starter named Bubbles daily.\n",
        model.last_topic.?,
    );

    const sessions = try currentSummaries(runtime.store, "session");
    defer freeSummaries(sessions);
    try std.testing.expectEqual(@as(usize, 3), sessions.len);
    try std.testing.expectEqualStrings("A chat about the user's day: The user mentioned something they did.", sessions[0].string("text"));
    try std.testing.expect(sessions[0].string("vector").len > 0);
    try std.testing.expectEqual(@as(i64, 2), sessions[0].properties.value.object.get("sourceCount").?.integer);
    try std.testing.expect(try edgeExists(runtime.store, sessions[0].qid, sessions[0].string("sessionQid"), "SUMMARIZES"));
    try std.testing.expect(try edgeExists(runtime.store, sessions[0].qid, sessions[0].string("evidenceQid"), "EVIDENCED_BY"));

    const topics = try currentSummaries(runtime.store, "topic");
    defer freeSummaries(topics);
    try std.testing.expectEqual(@as(usize, 1), topics.len);
    const topic_qid = try allocator.dupe(u8, topics[0].qid);
    defer allocator.free(topic_qid);
    try std.testing.expectEqualStrings("Sourdough starter Bubbles", topics[0].string("title"));
    try std.testing.expectEqualStrings("2023-05-01T19:00:00Z", topics[0].string("firstSaid"));
    try std.testing.expectEqualStrings("2023-05-08T19:00:00Z", topics[0].string("lastSaid"));
    try std.testing.expect(topics[0].string("vector").len > 0);
    const members = topics[0].properties.value.object.get("members").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), members.len);
    for (members) |member| try std.testing.expect(try edgeExists(runtime.store, topic_qid, member.string, "DERIVED_FROM"));
    try std.testing.expect(try edgeExists(runtime.store, topic_qid, keep, "EVIDENCED_BY"));
    try std.testing.expect(try edgeExists(runtime.store, topic_qid, feed, "EVIDENCED_BY"));
    // A summary is found through its own vector, not by search.
    try std.testing.expectEqual(false, topics[0].properties.value.object.get("searchable").?.bool);

    // Nothing changed: a pass asks nothing and writes nothing.
    try runtime.queueSummaryJob(allocator, .{ .user_id = "baker" });
    const idle = try runtime.runSummaryJobs(allocator, "test", 100);
    try std.testing.expectEqual(@as(usize, 0), idle.calls);
    try std.testing.expectEqual(@as(usize, 4), idle.counts.unchanged);
    try std.testing.expectEqual(@as(usize, 0), idle.counts.claimsIndexed);

    // A third claim about the starter: its session and the topic are asked
    // about, and the topic keeps its node.
    allocator.free(try rememberStarterDay(&runtime, 12, "I gave half of Bubbles to my neighbour."));
    _ = try runtime.runExtractJobs(allocator, "test", 10, 1);
    const grown = try runtime.runSummaryJobs(allocator, "test", 100);
    try std.testing.expectEqual(@as(usize, 2), grown.calls);
    try std.testing.expectEqual(@as(usize, 1), grown.counts.sessionsWritten);
    try std.testing.expectEqual(@as(usize, 1), grown.counts.topicsWritten);
    try std.testing.expectEqual(@as(usize, 1), grown.counts.claimsIndexed);
    try std.testing.expectEqual(@as(usize, 3), grown.counts.unchanged);
    const after = try currentSummaries(runtime.store, "topic");
    defer freeSummaries(after);
    try std.testing.expectEqual(@as(usize, 1), after.len);
    try std.testing.expectEqualStrings(topic_qid, after[0].qid);
    try std.testing.expectEqual(@as(usize, 3), after[0].properties.value.object.get("members").?.array.items.len);
    try std.testing.expectEqualStrings("2023-05-12T19:00:00Z", after[0].string("lastSaid"));
}

test "forgetting a message removes the summaries that rest on it and rebuilds them from the rest" {
    const allocator = std.testing.allocator;
    var harness = try RuntimeTestHarness.init(allocator);
    defer harness.deinit();
    var store = PatternTestStore.init(harness.adapter());
    var model = SummaryTestModel{};
    defer model.deinit();
    var runtime = Runtime.initWithOptions(store.adapter(), harness.health(), .{ .extract_provider = model.endpoint() });
    defer runtime.deinit();

    allocator.free(try rememberStarterDay(&runtime, 1, "I keep a sourdough starter named Bubbles."));
    const feed = try rememberStarterDay(&runtime, 8, "I feed Bubbles every morning.");
    defer allocator.free(feed);
    allocator.free(try rememberStarterDay(&runtime, 12, "I gave half of Bubbles to my neighbour."));
    _ = try runtime.runExtractJobs(allocator, "test", 10, 1);
    _ = try runtime.runSummaryJobs(allocator, "test", 100);
    const before = try currentSummaries(runtime.store, "topic");
    defer freeSummaries(before);
    try std.testing.expectEqual(@as(usize, 1), before.len);
    try std.testing.expectEqual(@as(usize, 3), before[0].properties.value.object.get("members").?.array.items.len);

    const forget = try std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":\"f\",\"method\":\"memory.forget\",\"params\":{{\"selector\":{{\"qids\":[\"{s}\"]}},\"mode\":\"hard_delete\",\"reason\":\"test\"}}}}",
        .{feed},
    );
    defer allocator.free(forget);
    const forgotten = try runtime.dispatch(allocator, forget);
    defer allocator.free(forgotten);
    try std.testing.expect(std.mem.indexOf(u8, forgotten, before[0].qid) != null);

    // The topic and the session's summary went with the message, and
    // nothing of them can be read back.
    const gone = (try runtime.store.getNode(allocator, before[0].qid)).?;
    defer runtime.store.freeNode(allocator, gone);
    try std.testing.expect(std.mem.indexOf(u8, gone.properties_json, "\"kind\":\"tombstone\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, gone.properties_json, "Bubbles") == null);
    const left = try currentSummaries(runtime.store, "topic");
    defer freeSummaries(left);
    try std.testing.expectEqual(@as(usize, 0), left.len);
    const sessions_left = try currentSummaries(runtime.store, "session");
    defer freeSummaries(sessions_left);
    try std.testing.expectEqual(@as(usize, 2), sessions_left.len);

    // The forget queued a rebuild: the two claims that remain form the topic
    // again, under a new node, and the session is summarised from the
    // message it still has.
    try std.testing.expectEqual(@as(usize, 1), try countSummaryJobs(runtime.store, "pending"));
    const rebuilt = try runtime.runSummaryJobs(allocator, "test", 100);
    try std.testing.expectEqual(@as(usize, 2), rebuilt.calls);
    try std.testing.expectEqual(@as(usize, 1), rebuilt.counts.topicsWritten);
    try std.testing.expectEqual(@as(usize, 3), rebuilt.counts.sessions);
    try std.testing.expectEqual(@as(usize, 1), rebuilt.counts.sessionsWritten);
    const again = try currentSummaries(runtime.store, "topic");
    defer freeSummaries(again);
    try std.testing.expectEqual(@as(usize, 1), again.len);
    try std.testing.expect(!std.mem.eql(u8, before[0].qid, again[0].qid));
    try std.testing.expectEqual(@as(usize, 2), again[0].properties.value.object.get("members").?.array.items.len);
    try std.testing.expect(std.mem.indexOf(u8, model.last_topic.?, "feeds") == null);
}

test "a group the model declines is remembered and not asked about again" {
    const allocator = std.testing.allocator;
    var harness = try RuntimeTestHarness.init(allocator);
    defer harness.deinit();
    var store = PatternTestStore.init(harness.adapter());
    var model = SummaryTestModel{ .decline = true };
    defer model.deinit();
    var runtime = Runtime.initWithOptions(store.adapter(), harness.health(), .{ .extract_provider = model.endpoint() });
    defer runtime.deinit();

    allocator.free(try rememberStarterDay(&runtime, 1, "I keep a sourdough starter named Bubbles."));
    allocator.free(try rememberStarterDay(&runtime, 8, "I feed Bubbles every morning."));
    _ = try runtime.runExtractJobs(allocator, "test", 10, 1);
    const first = try runtime.runSummaryJobs(allocator, "test", 100);
    try std.testing.expectEqual(@as(usize, 1), first.counts.topicsDeclined);
    try std.testing.expectEqual(@as(usize, 0), first.counts.topicsWritten);
    const topics = try currentSummaries(runtime.store, "topic");
    defer freeSummaries(topics);
    try std.testing.expectEqual(@as(usize, 1), topics.len);
    try std.testing.expectEqual(true, topics[0].properties.value.object.get("declined").?.bool);
    try std.testing.expectEqualStrings("", topics[0].string("text"));
    try std.testing.expectEqualStrings("", topics[0].string("vector"));

    try runtime.queueSummaryJob(allocator, .{ .user_id = "baker" });
    const second = try runtime.runSummaryJobs(allocator, "test", 100);
    try std.testing.expectEqual(@as(usize, 0), second.calls);
    try std.testing.expectEqual(@as(usize, 1), model.topic_calls);

    // Without a model there is nothing to run.
    var unconfigured = Runtime.init(store.adapter(), harness.health());
    try std.testing.expectError(error.ProviderUnavailable, unconfigured.runSummaryJobs(allocator, "test", 100));
    const refused = try unconfigured.dispatch(allocator, "{\"jsonrpc\":\"2.0\",\"id\":\"x\",\"method\":\"memory.summaries.run\",\"params\":{}}");
    defer allocator.free(refused);
    try std.testing.expect(std.mem.indexOf(u8, refused, "\"code\":\"provider_error\"") != null);
}

fn threadRetrieve(runtime: *Runtime, query: []const u8, budget: usize) ![]u8 {
    const allocator = std.testing.allocator;
    const request = try std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":\"q\",\"method\":\"memory.retrieve\",\"params\":{{\"query\":\"{s}\",\"scope\":{{\"userId\":\"baker\"}},\"mode\":\"fts\",\"budgetTokens\":{d},\"time\":{{\"validAt\":\"2023-05-30T12:00:00Z\"}},\"options\":{{\"includeDebug\":true,\"logRetrieval\":false,\"logAudit\":false}}}}}}",
        .{ query, budget },
    );
    defer allocator.free(request);
    return runtime.dispatch(allocator, request);
}

test "retrieval shows the topics nearest the question and opens sessions through the summaries" {
    const allocator = std.testing.allocator;
    var harness = try RuntimeTestHarness.init(allocator);
    defer harness.deinit();
    var store = PatternTestStore.init(harness.adapter());
    var model = SummaryTestModel{ .name_starter_sessions = true };
    defer model.deinit();
    var runtime = Runtime.initWithOptions(store.adapter(), harness.health(), .{ .extract_provider = model.endpoint() });
    defer runtime.deinit();

    const keep = try rememberStarterDay(&runtime, 1, "I keep a sourdough starter named Bubbles.");
    defer allocator.free(keep);
    const feed = try rememberStarterDay(&runtime, 8, "I feed Bubbles every morning.");
    defer allocator.free(feed);
    allocator.free(try rememberStarterDay(&runtime, 10, "I booked a ferry to Zanzibar for August."));
    const gave = try rememberStarterDay(&runtime, 12, "I gave half of Bubbles to my neighbour.");
    defer allocator.free(gave);
    for (20..26) |day| allocator.free(try rememberStarterDay(&runtime, day, "The weather was fine and I walked along the river."));
    _ = try runtime.runExtractJobs(allocator, "test", 20, 1);
    _ = try runtime.runSummaryJobs(allocator, "test", 100);

    // Before any summary exists a context has no threads section; that is
    // every other test. With them, the topic about the starter leads, its
    // facts in the order they happened, each under the message it came
    // from, and the fact in no topic follows.
    const response = try threadRetrieve(&runtime, "How is my sourdough starter Bubbles doing?", 2000);
    defer allocator.free(response);
    const prompt = try resultStringField(allocator, response, "prompt");
    defer allocator.free(prompt);
    const expected = try std.fmt.allocPrint(
        allocator,
        "<memory>\n<threads>\n" ++ summaries.threads_note ++ "\n" ++
            "## Sourdough starter Bubbles: The user keeps a starter named Bubbles and looks after it.\n" ++
            "[{s}] 2023-05-01 (Mon), 29 days ago: The user keeps a sourdough starter named Bubbles.\n" ++
            "[{s}] 2023-05-08 (Mon), 22 days ago: The user feeds the sourdough starter named Bubbles daily.\n" ++
            "[{s}] 2023-05-12 (Fri), 18 days ago: The user gave half of the sourdough starter named Bubbles away.\n" ++
            "</threads>\n",
        .{ keep, feed, gave },
    );
    defer allocator.free(expected);
    try std.testing.expect(std.mem.indexOf(u8, prompt, expected) != null);
    // The ferry has nothing to do with the question.
    try std.testing.expect(std.mem.indexOf(u8, prompt, "ferry") == null);
    // A session's header carries its summary, and the messages behind the
    // facts are shown as raw evidence.
    try std.testing.expect(std.mem.indexOf(u8, prompt, "## session day-1 2023-05-01 (Mon) | Looking after Bubbles: The user talked about the sourdough starter Bubbles.\n") != null);
    const keep_line = try std.fmt.allocPrint(allocator, "[{s}] user: I keep a sourdough starter named Bubbles.", .{keep});
    defer allocator.free(keep_line);
    try std.testing.expect(std.mem.indexOf(u8, prompt, keep_line) != null);

    // The topic is one item, its summary node, evidenced by the messages of
    // its facts; the trace says what was read.
    var parsed = try std.json.parseFromSlice(Value, allocator, response, .{});
    defer parsed.deinit();
    const result = parsed.value.object.get("result").?.object;
    const threads = result.get("context").?.object.get("threads").?.array.items;
    try std.testing.expectEqualStrings("summary", threads[0].object.get("type").?.string);
    try std.testing.expectEqualStrings("Sourdough starter Bubbles: The user keeps a starter named Bubbles and looks after it.", threads[0].object.get("text").?.string);
    const evidence = threads[0].object.get("evidence").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), evidence.len);
    try std.testing.expectEqualStrings(keep, evidence[0].object.get("qid").?.string);
    try std.testing.expectEqual(@as(usize, 1), threads.len);
    const trace = result.get("trace").?.object.get("threads").?.object;
    try std.testing.expectEqual(@as(i64, 1), trace.get("topics").?.integer);
    try std.testing.expectEqual(@as(i64, 10), trace.get("sessions").?.integer);
    try std.testing.expectEqual(@as(i64, 4), trace.get("claims").?.integer);
    try std.testing.expectEqual(@as(i64, 1), trace.get("shown").?.integer);
    try std.testing.expectEqual(@as(i64, 3), trace.get("facts").?.integer);
    try std.testing.expectEqual(@as(i64, 0), trace.get("rawDropped").?.integer);

    // A fact in no topic is shown on its own when it is what was asked
    // about, and the topic that is not is left out.
    const ferry = try threadRetrieve(&runtime, "When did I book the ferry to Zanzibar?", 2000);
    defer allocator.free(ferry);
    const ferry_prompt = try resultStringField(allocator, ferry, "prompt");
    defer allocator.free(ferry_prompt);
    try std.testing.expect(std.mem.indexOf(u8, ferry_prompt, "\n## Other facts\n[q_msg_") != null);
    try std.testing.expect(std.mem.indexOf(u8, ferry_prompt, "20 days ago: The user booked a ferry to Zanzibar for August.") != null);
    try std.testing.expect(std.mem.indexOf(u8, ferry_prompt, "## Sourdough starter Bubbles") == null);
    try std.testing.expect(std.mem.indexOf(u8, ferry, "\"type\":\"assertion\"") != null);

    // With less room than the topic needs, it is shown with the facts
    // nearest the question, and says how many it has.
    const tight = try threadRetrieve(&runtime, "How is my sourdough starter Bubbles doing?", 380);
    defer allocator.free(tight);
    const tight_prompt = try resultStringField(allocator, tight, "prompt");
    defer allocator.free(tight_prompt);
    try std.testing.expect(std.mem.indexOf(u8, tight_prompt, "## Sourdough starter Bubbles: The user keeps a starter named Bubbles and looks after it. (2 of its 3 facts)\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, tight_prompt, "The user keeps a sourdough starter named Bubbles.\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, tight_prompt, "The user feeds the sourdough starter named Bubbles daily.\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, tight_prompt, "gave half of the sourdough starter") == null);
    // The summaries on session headers have their share of the budget too,
    // taken in the order the evidence ranks: the session reached past it is
    // headed by its title alone.
    try std.testing.expect(std.mem.indexOf(u8, tight_prompt, "## session day-12 2023-05-12 (Fri) | Looking after Bubbles: The user talked about the sourdough starter Bubbles.\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, tight_prompt, "## session day-8 2023-05-08 (Mon) | Looking after Bubbles\n") != null);

    // A later conversation that only mentions a starter in passing: its
    // summary is about something else and none of its messages is behind a
    // fact, so search finding the message does not put it in the context.
    allocator.free(try rememberStarterDay(&runtime, 26, "At the bakery someone asked how a sourdough starter is doing."));
    _ = try runtime.runExtractJobs(allocator, "test", 20, 1);
    _ = try runtime.runSummaryJobs(allocator, "test", 100);
    // A conversation the background jobs have not reached is read as before.
    allocator.free(try rememberStarterDay(&runtime, 27, "My sourdough starter Bubbles overflowed its jar."));
    const later = try threadRetrieve(&runtime, "How is my sourdough starter Bubbles doing?", 2000);
    defer allocator.free(later);
    const later_prompt = try resultStringField(allocator, later, "prompt");
    defer allocator.free(later_prompt);
    try std.testing.expect(std.mem.indexOf(u8, later_prompt, "bakery") == null);
    try std.testing.expect(std.mem.indexOf(u8, later, "\"rawDropped\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, later_prompt, "My sourdough starter Bubbles overflowed its jar.") != null);

    // A question about an earlier time is not told what was said after it.
    const early = try runtime.dispatch(allocator, "{\"jsonrpc\":\"2.0\",\"id\":\"q\",\"method\":\"memory.retrieve\",\"params\":{\"query\":\"How is my sourdough starter Bubbles doing?\",\"scope\":{\"userId\":\"baker\"},\"mode\":\"fts\",\"budgetTokens\":2000,\"time\":{\"validAt\":\"2023-05-09T12:00:00Z\"},\"options\":{\"logRetrieval\":false,\"logAudit\":false}}}");
    defer allocator.free(early);
    try std.testing.expect(std.mem.indexOf(u8, early, "gave half") == null);
    try std.testing.expect(std.mem.indexOf(u8, early, "## Sourdough starter Bubbles") == null);
    try std.testing.expect(std.mem.indexOf(u8, early, "8 days ago: The user keeps a sourdough starter named Bubbles.") != null);
}

test "pattern jobs call the pattern model when one is configured" {
    const allocator = std.testing.allocator;
    var harness = try RuntimeTestHarness.init(allocator);
    defer harness.deinit();
    var store = PatternTestStore.init(harness.adapter());
    var small = PatternTestModel{};
    var strong = PatternTestModel{ .model = "test-pattern-model" };
    var runtime = Runtime.initWithOptions(store.adapter(), harness.health(), .{
        .extract_provider = small.endpoint(),
        .pattern_provider = strong.endpoint(),
    });
    defer runtime.deinit();

    const health = try runtime.dispatch(allocator, "{\"jsonrpc\":\"2.0\",\"id\":\"h\",\"method\":\"system.health\",\"params\":{}}");
    defer allocator.free(health);
    try std.testing.expect(std.mem.indexOf(u8, health, "\"patterns\":{\"available\":true,\"promptVersion\":\"quipu.patterns.v1\",\"model\":\"test-pattern-model\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, health, "\"extractor\":{\"configured\":true,\"model\":\"test-extract-model\"") != null);

    allocator.free(try rememberLoaves(&runtime));
    const built = try runPatternPass(&runtime);
    defer allocator.free(built);
    try std.testing.expect(std.mem.indexOf(u8, built, "\"model\":\"test-pattern-model\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, built, "\"regularities\":1") != null);
    try std.testing.expectEqual(@as(usize, 1), strong.gate_calls.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 1), strong.claims_calls.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 3), strong.check_calls.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 0), small.gate_calls.load(.monotonic) + small.claims_calls.load(.monotonic) + small.check_calls.load(.monotonic));
}
