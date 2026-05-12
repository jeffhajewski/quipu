const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const enable_lattice = b.option(bool, "enable-lattice", "Enable the LatticeDB-backed storage adapter") orelse true;
    const lattice_include = b.option([]const u8, "lattice-include", "Directory containing lattice.h") orelse
        envPath(b, "LATTICE_INCLUDE") orelse
        envPrefixPath(b, "include") orelse
        "";
    const lattice_lib = b.option([]const u8, "lattice-lib", "Directory containing liblattice") orelse
        envLatticeLibPath(b) orelse
        envPrefixPath(b, "lib") orelse
        "";

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

fn envPath(b: *std.Build, name: []const u8) ?[]const u8 {
    return b.graph.environ_map.get(name);
}

fn envPrefixPath(b: *std.Build, child: []const u8) ?[]const u8 {
    const prefix = envPath(b, "LATTICE_PREFIX") orelse return null;
    return b.pathJoin(&.{ prefix, child });
}

fn envLatticeLibPath(b: *std.Build) ?[]const u8 {
    if (envPath(b, "LATTICE_LIB_DIR")) |path| return path;
    if (envPath(b, "LATTICE_LIB_PATH")) |path| return std.fs.path.dirname(path) orelse path;
    return null;
}
