pub const raw_event = "quipu.raw_event";
pub const extract_requested = "quipu.extract.requested";
pub const extract_completed = "quipu.extract.completed";
pub const entity_resolve_requested = "quipu.entity.resolve.requested";
pub const fact_upserted = "quipu.fact.upserted";
pub const card_created = "quipu.card.created";
pub const consolidate_requested = "quipu.consolidate.requested";
pub const consolidate_completed = "quipu.consolidate.completed";
pub const forget_requested = "quipu.forget.requested";
pub const forget_completed = "quipu.forget.completed";
pub const retrieval_logged = "quipu.retrieval.logged";
pub const feedback_received = "quipu.feedback.received";
pub const audit = "quipu.audit";
pub const deadletter = "quipu.deadletter";

pub const StreamSpec = struct {
    name: []const u8,
    worker_kind: []const u8,
};

pub const materialized_streams = [_]StreamSpec{
    .{ .name = raw_event, .worker_kind = "raw_event" },
    .{ .name = extract_requested, .worker_kind = "extract" },
    .{ .name = extract_completed, .worker_kind = "extract_completed" },
    .{ .name = entity_resolve_requested, .worker_kind = "entity_resolve" },
    .{ .name = fact_upserted, .worker_kind = "fact_upserted" },
    .{ .name = card_created, .worker_kind = "card_created" },
    .{ .name = consolidate_requested, .worker_kind = "consolidate" },
    .{ .name = consolidate_completed, .worker_kind = "consolidate_completed" },
    .{ .name = forget_requested, .worker_kind = "forget" },
    .{ .name = forget_completed, .worker_kind = "forget_completed" },
    .{ .name = retrieval_logged, .worker_kind = "retrieval_log" },
    .{ .name = feedback_received, .worker_kind = "feedback" },
    .{ .name = audit, .worker_kind = "audit" },
    .{ .name = deadletter, .worker_kind = "deadletter" },
};

pub fn workerKindForStream(stream: []const u8) []const u8 {
    for (materialized_streams) |spec| {
        if (equal(stream, spec.name)) return spec.worker_kind;
    }
    return "generic";
}

fn equal(left: []const u8, right: []const u8) bool {
    if (left.len != right.len) return false;
    for (left, right) |a, b| {
        if (a != b) return false;
    }
    return true;
}
