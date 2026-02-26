const std = @import("std");

/// Compile a tree-sitter grammar from C source and create a Zig binding module.
/// For grammars that don't ship their own build.zig (e.g. rust, go, vim).
fn addGrammarLib(
    b: *std.Build,
    dep: *std.Build.Dependency,
    comptime name: []const u8,
    comptime has_scanner: bool,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    const lib = b.addLibrary(.{
        .name = "tree-sitter-" ++ name,
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    lib.root_module.addCSourceFile(.{
        .file = dep.path("src/parser.c"),
        .flags = &.{"-std=c11"},
    });
    if (has_scanner) {
        lib.root_module.addCSourceFile(.{
            .file = dep.path("src/scanner.c"),
            .flags = &.{"-std=c11"},
        });
    }
    lib.root_module.addIncludePath(dep.path("src"));

    const mod = b.createModule(.{
        .root_source_file = b.path("src/treesitter/bindings/" ++ name ++ ".zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.linkLibrary(lib);
    return mod;
}

fn addTreeSitterDeps(b: *std.Build, mod: *std.Build.Module, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    const ts_dep = b.dependency("tree_sitter", .{ .target = target, .optimize = optimize });
    const ts_zig_dep = b.dependency("tree_sitter_zig", .{ .target = target, .optimize = optimize });
    mod.addImport("tree_sitter", ts_dep.module("tree_sitter"));
    mod.addImport("tree_sitter_zig", ts_zig_dep.module("tree-sitter-zig"));

    // Rust grammar (parser.c + scanner.c)
    const ts_rust_dep = b.dependency("tree_sitter_rust", .{});
    const rust_mod = addGrammarLib(b, ts_rust_dep, "rust", true, target, optimize);
    mod.addImport("tree_sitter_rust", rust_mod);

    // Go grammar (parser.c only)
    const ts_go_dep = b.dependency("tree_sitter_go", .{});
    const go_mod = addGrammarLib(b, ts_go_dep, "go", false, target, optimize);
    mod.addImport("tree_sitter_go", go_mod);

    // VimScript grammar (parser.c + scanner.c)
    const ts_vim_dep = b.dependency("tree_sitter_vim", .{});
    const vim_mod = addGrammarLib(b, ts_vim_dep, "vim", true, target, optimize);
    mod.addImport("tree_sitter_vim", vim_mod);
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
        .name = "lsp-bridge",
        .root_module = mod,
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run lsp-bridge");
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
