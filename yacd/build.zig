const std = @import("std");

fn addMd4cDeps(b: *std.Build, mod: *std.Build.Module) void {
    const md4c_root = b.path("../vendor/md4c");
    mod.addIncludePath(md4c_root);
    mod.addCSourceFile(.{ .file = md4c_root.path(b, "md4c.c") });
}

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

    const lsp_dep = b.dependency("lsp_kit", .{
        .target = target,
        .optimize = optimize,
    });

    const mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mod.addImport("lsp", lsp_dep.module("lsp"));
    addTreeSitterDeps(b, mod, target, optimize);
    addMd4cDeps(b, mod);

    // Executable
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    exe_mod.addImport("lsp", lsp_dep.module("lsp"));
    addTreeSitterDeps(b, exe_mod, target, optimize);
    addMd4cDeps(b, exe_mod);

    const exe = b.addExecutable(.{
        .name = "yacd",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    // Tests
    const tests = b.addTest(.{
        .root_module = mod,
    });

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
