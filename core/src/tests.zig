test {
    const build_options = @import("build_options");
    _ = @import("protocol.zig");
    _ = @import("storage.zig");
    _ = @import("in_memory_storage.zig");
    _ = @import("schema.zig");
    _ = @import("streams.zig");
    _ = @import("jobs.zig");
    _ = @import("extractor.zig");
    _ = @import("fact_extraction.zig");
    _ = @import("fact_updates.zig");
    _ = @import("answer_synthesis.zig");
    _ = @import("providers.zig");
    _ = @import("temporal.zig");
    _ = @import("query_expansion.zig");
    _ = @import("forgetting.zig");
    _ = @import("forgetting_test.zig");
    _ = @import("runtime.zig");
    if (build_options.enable_lattice) {
        _ = @import("lattice_storage.zig");
    }
}
