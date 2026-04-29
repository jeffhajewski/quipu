const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const enable_lattice = b.option(bool, "enable-lattice", "Enable the LatticeDB-backed storage adapter") orelse false;
    const lattice_include = b.option([]const u8, "lattice-include", "Directory containing lattice.h") orelse "";
    const lattice_lib = b.option([]const u8, "lattice-lib", "Directory containing liblattice") orelse "";

    const build_options = b.addOptions();
    build_options.addOption(bool, "enable_lattice", enable_lattice);

    const exe_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_module.addOptions("build_options", build_options);
    const exe = b.addExecutable(.{
        .name = "quipu",
        .root_module = exe_module,
    });
    if (enable_lattice) {
        if (lattice_include.len != 0) exe_module.addIncludePath(.{ .cwd_relative = lattice_include });
        if (lattice_lib.len != 0) {
            exe_module.addLibraryPath(.{ .cwd_relative = lattice_lib });
            exe_module.addRPath(.{ .cwd_relative = lattice_lib });
        }
        exe_module.linkSystemLibrary("lattice", .{ .use_pkg_config = .no });
        exe_module.link_libc = true;
    }

    b.installArtifact(exe);

    const test_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_module.addOptions("build_options", build_options);
    if (enable_lattice) {
        if (lattice_include.len != 0) test_module.addIncludePath(.{ .cwd_relative = lattice_include });
        if (lattice_lib.len != 0) {
            test_module.addLibraryPath(.{ .cwd_relative = lattice_lib });
            test_module.addRPath(.{ .cwd_relative = lattice_lib });
        }
        test_module.linkSystemLibrary("lattice", .{ .use_pkg_config = .no });
        test_module.link_libc = true;
    }
    const unit_tests = b.addTest(.{
        .root_module = test_module,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run core unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
