const std = @import("std");

fn addTreeSitterDeps(b: *std.Build, mod: *std.Build.Module, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    const ts_dep = b.dependency("tree_sitter", .{
        .target = target,
        .optimize = optimize,
        .@"enable-wasm" = true,
    });
    mod.addImport("tree_sitter", ts_dep.module("tree_sitter"));

    // Wasmtime (Rust) requires libunwind for exception handling
    mod.linkSystemLibrary("unwind", .{ .use_pkg_config = .no });
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    addTreeSitterDeps(b, mod, target, optimize);

    const exe = b.addExecutable(.{
        .name = "yacd",
        .root_module = mod,
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run yacd");
    run_step.dependOn(&run_cmd.step);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    addTreeSitterDeps(b, test_mod, target, optimize);

    const tests = b.addTest(.{
        .root_module = test_mod,
    });

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
