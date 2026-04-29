test {
    const build_options = @import("build_options");
    _ = @import("protocol.zig");
    _ = @import("storage.zig");
    _ = @import("in_memory_storage.zig");
    _ = @import("streams.zig");
    _ = @import("jobs.zig");
    _ = @import("extractor.zig");
    _ = @import("runtime.zig");
    if (build_options.enable_lattice) {
        _ = @import("lattice_storage.zig");
    }
}
