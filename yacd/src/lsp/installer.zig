const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const config = @import("../config.zig");
const LangConfig = config.LangConfig;
const InstallInfo = config.InstallInfo;
const Notifier = @import("../notifier.zig").Notifier;

/// Wrapper around std.c.getenv that returns a Zig slice.
fn getenv(name: [*:0]const u8) ?[]const u8 {
    const val = std.c.getenv(name) orelse return null;
    return std.mem.sliceTo(val, 0);
}

/// Check if dir/name exists via access(). No allocation.
fn pathExists(dir: []const u8, name: []const u8) bool {
    var buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    const full = std.fmt.bufPrint(buf[0..std.fs.max_path_bytes], "{s}/{s}", .{ dir, name }) catch return false;
    buf[full.len] = 0;
    return std.c.access(@ptrCast(buf[0..full.len :0]), std.c.F_OK) == 0;
}

// ============================================================================
// Installer — LSP server auto-install
//
// Resolves commands (PATH → managed binary fallback), detects missing servers,
// and installs them via npm/pip/go/github_release.
// ============================================================================

pub const Installer = struct {
    allocator: Allocator,
    io: Io,
    notifier: *Notifier,
    installing: std.StringHashMap(void),
    data_dir: []const u8, // ~/.local/share/yac

    pub fn init(allocator: Allocator, io: Io, notifier: *Notifier) Installer {
        // Build data_dir: $XDG_DATA_HOME/yac or ~/.local/share/yac
        const data_dir = blk: {
            if (getenv("XDG_DATA_HOME")) |xdg| {
                break :blk std.fmt.allocPrint(allocator, "{s}/yac", .{xdg}) catch "";
            }
            if (getenv("HOME")) |home| {
                break :blk std.fmt.allocPrint(allocator, "{s}/.local/share/yac", .{home}) catch "";
            }
            break :blk "";
        };

        return .{
            .allocator = allocator,
            .io = io,
            .notifier = notifier,
            .installing = std.StringHashMap(void).init(allocator),
            .data_dir = data_dir,
        };
    }

    pub fn deinit(self: *Installer) void {
        var it = self.installing.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.installing.deinit();
        if (self.data_dir.len > 0) {
            self.allocator.free(self.data_dir);
        }
    }

    // ========================================================================
    // Query (synchronous, no I/O)
    // ========================================================================

    /// Resolve the command to use for a language config.
    /// Priority: PATH lookup → managed binary in data_dir/bin/.
    /// Returns a static/comptime string (no allocation needed).
    pub fn resolveCommand(self: *const Installer, cfg: *const LangConfig) ?[]const u8 {
        if (commandInPath(cfg.command)) return cfg.command;
        if (self.managedBinExists(cfg)) return cfg.command; // binary installed under managed bin/
        return null;
    }

    /// Check if a command exists in $PATH via access().
    pub fn commandInPath(command: []const u8) bool {
        const path_env = getenv("PATH") orelse return false;
        var it = std.mem.splitScalar(u8, path_env, ':');
        while (it.next()) |dir| {
            if (pathExists(dir, command)) return true;
        }
        return false;
    }

    /// Check if the managed binary exists in data_dir/bin/.
    fn managedBinExists(self: *const Installer, cfg: *const LangConfig) bool {
        if (self.data_dir.len == 0) return false;
        const bin_name = if (cfg.install) |info|
            (if (info.bin_name.len > 0) info.bin_name else cfg.command)
        else
            cfg.command;

        var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
        const dir = std.fmt.bufPrint(&dir_buf, "{s}/bin", .{self.data_dir}) catch return false;
        return pathExists(dir, bin_name);
    }

    /// Get the full managed binary path (caller owns the returned string).
    /// Used by registry.spawnProxy to build argv[0].
    pub fn getManagedPath(self: *const Installer, cfg: *const LangConfig) ?[]const u8 {
        if (self.data_dir.len == 0) return null;
        const bin_name = if (cfg.install) |info|
            (if (info.bin_name.len > 0) info.bin_name else cfg.command)
        else
            cfg.command;
        return std.fmt.allocPrint(self.allocator, "{s}/bin/{s}", .{ self.data_dir, bin_name }) catch null;
    }

    /// Check if a language is currently being installed.
    pub fn isInstalling(self: *Installer, language: []const u8) bool {
        return self.installing.get(language) != null;
    }

    // ========================================================================
    // Install (blocking — must be called from a dedicated thread/coroutine)
    // ========================================================================

    /// Install an LSP server for the given language config.
    /// Sends progress notifications to Vim via Notifier.
    pub fn install(self: *Installer, cfg: *const LangConfig) !void {
        const info = cfg.install orelse return error.NoInstallInfo;
        if (info.method == .system) return error.SystemInstallRequired;
        if (self.data_dir.len == 0) return error.NoDataDir;

        const language = cfg.language_id;

        // Mark as installing (prevent duplicates)
        if (self.installing.get(language) != null) return error.AlreadyInstalling;
        const owned_lang = try self.allocator.dupe(u8, language);
        self.installing.put(owned_lang, {}) catch {
            self.allocator.free(owned_lang);
            return error.OutOfMemory;
        };
        // Single cleanup point: finishInstall removes from map + frees key
        defer self.finishInstall(owned_lang);

        // Ensure base directories exist
        try self.ensureDirs();

        const bin_name = if (info.bin_name.len > 0) info.bin_name else cfg.command;

        // Build staging directory
        var staging_buf: [std.fs.max_path_bytes]u8 = undefined;
        const staging = std.fmt.bufPrint(&staging_buf, "{s}/staging/{s}", .{ self.data_dir, language }) catch
            return error.PathTooLong;

        // Clean up any previous staging
        self.rimraf(staging);
        try self.mkdirp(staging);
        defer self.rimraf(staging);

        self.sendProgress(language, "Installing...", 10);

        // Dispatch by method
        switch (info.method) {
            .npm => try self.installNpm(staging, info, language),
            .pip => try self.installPip(staging, info, language),
            .go_install => try self.installGo(staging, info, language),
            .github_release => try self.installGithubRelease(staging, info, language),
            .system => unreachable,
        }

        self.sendProgress(language, "Linking...", 90);

        // Move staging → packages/{language}
        var pkg_buf: [std.fs.max_path_bytes]u8 = undefined;
        const pkg_dir = std.fmt.bufPrint(&pkg_buf, "{s}/packages/{s}", .{ self.data_dir, language }) catch
            return error.PathTooLong;
        self.rimraf(pkg_dir);
        try self.mvPath(staging, pkg_dir);

        // Create symlink: bin/{bin_name} → packages/{language}/...
        try self.createBinLink(language, bin_name, info);

        self.sendProgress(language, "Done", 100);
    }

    // ========================================================================
    // Install methods
    // ========================================================================

    fn installNpm(self: *Installer, staging: []const u8, info: InstallInfo, language: []const u8) !void {
        self.sendProgress(language, "npm init...", 20);
        try self.runChild(&.{ "npm", "init", "-y" }, staging);

        self.sendProgress(language, "npm install...", 40);
        var argv = try self.buildInstallArgv(&.{ "npm", "install" }, info.package);
        defer argv.deinit(self.allocator);
        try self.runChild(argv.items, staging);
    }

    fn installPip(self: *Installer, staging: []const u8, info: InstallInfo, language: []const u8) !void {
        self.sendProgress(language, "Creating venv...", 20);
        try self.runChild(&.{ "python3", "-m", "venv", "venv" }, staging);

        self.sendProgress(language, "pip install...", 40);
        var pip_buf: [std.fs.max_path_bytes]u8 = undefined;
        const pip_path = std.fmt.bufPrint(&pip_buf, "{s}/venv/bin/pip", .{staging}) catch
            return error.PathTooLong;

        var argv = try self.buildInstallArgv(&.{ pip_path, "install" }, info.package);
        defer argv.deinit(self.allocator);
        try self.runChild(argv.items, staging);
    }

    /// Build argv from base args + space-separated package string.
    fn buildInstallArgv(self: *Installer, base: []const []const u8, packages: []const u8) !std.ArrayList([]const u8) {
        var argv: std.ArrayList([]const u8) = .empty;
        errdefer argv.deinit(self.allocator);
        for (base) |arg| try argv.append(self.allocator, arg);
        var it = std.mem.splitScalar(u8, packages, ' ');
        while (it.next()) |pkg| {
            if (pkg.len > 0) try argv.append(self.allocator, pkg);
        }
        return argv;
    }

    fn installGo(self: *Installer, staging: []const u8, info: InstallInfo, language: []const u8) !void {
        self.sendProgress(language, "go install...", 40);

        // Set GOBIN to staging/bin via shell
        var gobin_buf: [std.fs.max_path_bytes]u8 = undefined;
        const gobin = std.fmt.bufPrint(&gobin_buf, "{s}/bin", .{staging}) catch
            return error.PathTooLong;
        self.mkdirp(gobin) catch return error.StagingFailed;

        // Use sh -c to set GOBIN environment variable
        var cmd_buf: [2048]u8 = undefined;
        const shell_cmd = std.fmt.bufPrint(&cmd_buf, "GOBIN={s} go install {s}", .{ gobin, info.package }) catch
            return error.PathTooLong;
        try self.runChild(&.{ "sh", "-c", shell_cmd }, staging);
    }

    fn installGithubRelease(self: *Installer, staging: []const u8, info: InstallInfo, language: []const u8) !void {
        self.sendProgress(language, "Fetching release...", 20);

        // Resolve platform/arch template
        const platform = comptime switch (@import("builtin").os.tag) {
            .linux => "unknown-linux-gnu",
            .macos => "apple-darwin",
            else => "unknown",
        };
        const arch = comptime switch (@import("builtin").cpu.arch) {
            .x86_64 => "x86_64",
            .aarch64 => "aarch64",
            else => "unknown",
        };

        // Substitute {ARCH} and {PLATFORM} in asset template
        var asset_buf: [512]u8 = undefined;
        const asset = self.substituteTemplate(&asset_buf, info.asset, arch, platform) orelse
            return error.InvalidAssetTemplate;

        // Build download URL
        var url_buf: [1024]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf, "https://github.com/{s}/releases/latest/download/{s}", .{ info.repo, asset }) catch
            return error.PathTooLong;

        // Download
        var dl_buf: [std.fs.max_path_bytes]u8 = undefined;
        const dl_path = std.fmt.bufPrint(&dl_buf, "{s}/{s}", .{ staging, asset }) catch
            return error.PathTooLong;

        self.sendProgress(language, "Downloading...", 40);
        try self.runChild(&.{ "curl", "-fSL", "-o", dl_path, url }, staging);

        // Extract based on extension
        self.sendProgress(language, "Extracting...", 70);
        if (std.mem.endsWith(u8, asset, ".tar.xz") or std.mem.endsWith(u8, asset, ".tar.gz")) {
            try self.runChild(&.{ "tar", "xf", dl_path, "-C", staging }, staging);
        } else if (std.mem.endsWith(u8, asset, ".gz")) {
            // Single file gzip (e.g. rust-analyzer)
            try self.runChild(&.{ "gunzip", dl_path }, staging);
            // Make executable
            const ungzipped = dl_path[0 .. dl_path.len - 3]; // strip .gz
            try self.runChild(&.{ "chmod", "+x", ungzipped }, staging);
        } else if (std.mem.endsWith(u8, asset, ".zip")) {
            try self.runChild(&.{ "unzip", "-o", dl_path, "-d", staging }, staging);
        }
    }

    // ========================================================================
    // Helpers
    // ========================================================================

    fn substituteTemplate(_: *Installer, buf: []u8, template: []const u8, arch: []const u8, platform: []const u8) ?[]const u8 {
        var pos: usize = 0;
        var i: usize = 0;
        while (i < template.len) {
            if (i + 6 <= template.len and std.mem.eql(u8, template[i .. i + 6], "{ARCH}")) {
                if (pos + arch.len > buf.len) return null;
                @memcpy(buf[pos .. pos + arch.len], arch);
                pos += arch.len;
                i += 6;
            } else if (i + 10 <= template.len and std.mem.eql(u8, template[i .. i + 10], "{PLATFORM}")) {
                if (pos + platform.len > buf.len) return null;
                @memcpy(buf[pos .. pos + platform.len], platform);
                pos += platform.len;
                i += 10;
            } else {
                if (pos >= buf.len) return null;
                buf[pos] = template[i];
                pos += 1;
                i += 1;
            }
        }
        return buf[0..pos];
    }

    fn createBinLink(self: *Installer, language: []const u8, bin_name: []const u8, info: InstallInfo) !void {
        var link_buf: [std.fs.max_path_bytes]u8 = undefined;
        const link_path = std.fmt.bufPrint(&link_buf, "{s}/bin/{s}", .{ self.data_dir, bin_name }) catch
            return error.PathTooLong;

        // Determine target based on install method
        var target_buf: [std.fs.max_path_bytes]u8 = undefined;
        const target = switch (info.method) {
            .npm => std.fmt.bufPrint(&target_buf, "{s}/packages/{s}/node_modules/.bin/{s}", .{ self.data_dir, language, bin_name }) catch
                return error.PathTooLong,
            .pip => std.fmt.bufPrint(&target_buf, "{s}/packages/{s}/venv/bin/{s}", .{ self.data_dir, language, bin_name }) catch
                return error.PathTooLong,
            .go_install => std.fmt.bufPrint(&target_buf, "{s}/packages/{s}/bin/{s}", .{ self.data_dir, language, bin_name }) catch
                return error.PathTooLong,
            .github_release => std.fmt.bufPrint(&target_buf, "{s}/packages/{s}/{s}", .{ self.data_dir, language, bin_name }) catch
                return error.PathTooLong,
            .system => return error.SystemInstallRequired,
        };

        // Remove existing link
        link_buf[link_path.len] = 0;
        _ = std.c.unlink(@ptrCast(link_buf[0..link_path.len :0]));

        // Create symlink via shell (since Zig's symlink requires sentinel-terminated paths)
        self.runChild(&.{ "ln", "-sf", target, link_path }, self.data_dir) catch
            return error.LinkFailed;
    }

    fn ensureDirs(self: *Installer) !void {
        // Create data_dir itself first, then subdirectories
        self.mkdirpRecursive(self.data_dir) catch return error.MkdirFailed;
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const dirs = [_][]const u8{ "bin", "packages", "staging" };
        for (dirs) |sub| {
            const path = std.fmt.bufPrint(&buf, "{s}/{s}", .{ self.data_dir, sub }) catch continue;
            self.mkdirp(path) catch continue;
        }
    }

    fn sendProgress(self: *Installer, language: []const u8, message: []const u8, percentage: u32) void {
        self.notifier.send("install_progress", .{
            .language = language,
            .message = message,
            .percentage = percentage,
        }) catch {};
    }

    fn finishInstall(self: *Installer, owned_lang: []const u8) void {
        _ = self.installing.fetchRemove(owned_lang);
        self.allocator.free(owned_lang);
    }

    fn runChild(self: *Installer, argv: []const []const u8, cwd: []const u8) !void {
        var child = std.process.spawn(self.io, .{
            .argv = argv,
            .cwd = .{ .path = cwd },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        }) catch return error.SpawnFailed;
        const term = child.wait(self.io) catch return error.WaitFailed;
        switch (term) {
            .exited => |code| if (code != 0) return error.ChildFailed,
            else => return error.ChildFailed,
        }
    }

    fn mkdirpRecursive(self: *Installer, path: []const u8) !void {
        // Walk up to find existing ancestor, then create downwards
        var buf: [std.fs.max_path_bytes + 1]u8 = undefined;
        if (path.len >= buf.len) return error.PathTooLong;
        @memcpy(buf[0..path.len], path);
        buf[path.len] = 0;
        if (std.c.access(@ptrCast(buf[0..path.len :0]), std.c.F_OK) == 0) return;

        // Try creating parent first
        if (std.fs.path.dirname(path)) |parent| {
            if (parent.len > 0) {
                self.mkdirpRecursive(parent) catch {};
            }
        }
        self.mkdirp(path) catch {};
    }

    fn mkdirp(_: *Installer, path: []const u8) !void {
        var buf: [std.fs.max_path_bytes + 1]u8 = undefined;
        if (path.len >= buf.len) return error.PathTooLong;
        @memcpy(buf[0..path.len], path);
        buf[path.len] = 0;
        const rc = std.c.mkdir(@ptrCast(buf[0..path.len :0]), 0o755);
        if (rc != 0) {
            const err = std.c._errno().*;
            if (err != @intFromEnum(std.c.E.EXIST)) return error.MkdirFailed;
        }
    }

    fn rimraf(self: *Installer, path: []const u8) void {
        var child = std.process.spawn(self.io, .{
            .argv = &.{ "rm", "-rf", path },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        }) catch return;
        _ = child.wait(self.io) catch {};
    }

    fn mvPath(self: *Installer, old: []const u8, new: []const u8) !void {
        var child = std.process.spawn(self.io, .{
            .argv = &.{ "mv", old, new },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        }) catch return error.MoveFailed;
        const term = child.wait(self.io) catch return error.MoveFailed;
        switch (term) {
            .exited => |code| if (code != 0) return error.MoveFailed,
            else => return error.MoveFailed,
        }
    }
};

// ============================================================================
// Tests
// ============================================================================

test "commandInPath: known commands" {
    // These should exist on any system with a shell
    try std.testing.expect(Installer.commandInPath("ls"));
    try std.testing.expect(Installer.commandInPath("sh"));
}

test "commandInPath: unknown command" {
    try std.testing.expect(!Installer.commandInPath("__nonexistent_command_xyz__"));
}

test "resolveCommand: falls back to PATH" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const notifier_io = blk: {
        const S = struct {
            var threaded: std.Io.Threaded = .init_single_threaded;
        };
        break :blk S.threaded.io();
    };

    var notifier = Notifier.init(allocator, notifier_io);
    defer notifier.deinit();

    var installer = Installer.init(allocator, notifier_io, &notifier);
    defer installer.deinit();

    // "ls" should be found in PATH
    const cfg = config.LangConfig{
        .language_id = "test",
        .command = "ls",
        .args = &.{},
        .file_extensions = &.{},
        .workspace_markers = &.{},
    };
    try std.testing.expect(installer.resolveCommand(&cfg) != null);
}

test "resolveCommand: unknown command returns null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const notifier_io = blk: {
        const S = struct {
            var threaded: std.Io.Threaded = .init_single_threaded;
        };
        break :blk S.threaded.io();
    };

    var notifier = Notifier.init(allocator, notifier_io);
    defer notifier.deinit();

    var installer = Installer.init(allocator, notifier_io, &notifier);
    defer installer.deinit();

    const cfg = config.LangConfig{
        .language_id = "test",
        .command = "__nonexistent_lsp_server__",
        .args = &.{},
        .file_extensions = &.{},
        .workspace_markers = &.{},
    };
    try std.testing.expect(installer.resolveCommand(&cfg) == null);
}

test "isInstalling: default false" {
    const allocator = std.testing.allocator;

    const notifier_io = blk: {
        const S = struct {
            var threaded: std.Io.Threaded = .init_single_threaded;
        };
        break :blk S.threaded.io();
    };

    var notifier = Notifier.init(allocator, notifier_io);
    defer notifier.deinit();

    var installer = Installer.init(allocator, notifier_io, &notifier);
    defer installer.deinit();

    try std.testing.expect(!installer.isInstalling("rust"));
}

test "substituteTemplate: arch and platform" {
    const allocator = std.testing.allocator;

    const notifier_io = blk: {
        const S = struct {
            var threaded: std.Io.Threaded = .init_single_threaded;
        };
        break :blk S.threaded.io();
    };

    var notifier = Notifier.init(allocator, notifier_io);
    defer notifier.deinit();

    var installer = Installer.init(allocator, notifier_io, &notifier);
    defer installer.deinit();

    var buf: [512]u8 = undefined;
    const result = installer.substituteTemplate(&buf, "zls-{ARCH}-{PLATFORM}.tar.xz", "x86_64", "linux");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("zls-x86_64-linux.tar.xz", result.?);
}
