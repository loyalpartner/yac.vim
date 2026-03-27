const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const lsp = @import("lsp");
const config = @import("config.zig");
const LspProxy = @import("lsp/root.zig").LspProxy;
const Installer = @import("lsp/root.zig").Installer;

const log = std.log.scoped(.registry);

// ============================================================================
// ProxyRegistry — file_path → LspProxy resolver
//
// Manages a pool of LspProxy instances keyed by (language, workspace_uri).
// Given a file path, detects language, finds workspace root, and returns
// (or creates) the appropriate LspProxy.
//
// Integrates with Installer for auto-install on spawn failure.
// ============================================================================

pub const ProxyRegistry = struct {
    allocator: Allocator,
    io: Io,
    group: ?*Io.Group = null,
    proxies: std.StringHashMap(*LspProxy),
    failed_spawns: std.StringHashMap(void),
    spawning: std.StringHashMap(void),
    installer: ?*Installer = null,
    on_notification: ?*const LspProxy.OnNotification = null,
    notify_ctx: ?*anyopaque = null,
    lock: Io.Mutex = .init,

    pub fn init(allocator: Allocator, io: Io) ProxyRegistry {
        return .{
            .allocator = allocator,
            .io = io,
            .proxies = std.StringHashMap(*LspProxy).init(allocator),
            .failed_spawns = std.StringHashMap(void).init(allocator),
            .spawning = std.StringHashMap(void).init(allocator),
        };
    }

    pub fn deinit(self: *ProxyRegistry) void {
        var it = self.proxies.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.deinit();
        }
        self.proxies.deinit();

        var fit = self.failed_spawns.iterator();
        while (fit.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.failed_spawns.deinit();

        var sit = self.spawning.iterator();
        while (sit.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.spawning.deinit();
    }

    /// Resolve a file path to an LspProxy.
    /// Detects language, finds workspace, creates proxy if needed.
    /// On spawn failure, triggers auto-install if InstallInfo is available.
    pub fn resolve(self: *ProxyRegistry, file_path: []const u8, group_override: ?*Io.Group) !*LspProxy {
        const lang_config = config.detectConfig(file_path) orelse return error.UnknownLanguage;
        const language = lang_config.language_id;

        // Early checks under lock
        {
            self.lock.lockUncancelable(self.io);
            defer self.lock.unlock(self.io);

            // Already known to be uninstallable
            if (self.failed_spawns.get(language) != null) return error.CommandNotFound;
        }

        // Currently being installed — tell caller to wait
        if (self.installer) |inst| {
            if (inst.isInstalling(language)) return error.Installing;
        }

        // Library path detection: reuse existing proxy for dependency/stdlib files.
        // This prevents spawning new LSP servers when jumping to /usr/lib/zig/std/,
        // ~/.cargo/registry/, node_modules/, etc.
        if (config.isLibraryPath(lang_config, file_path)) {
            self.lock.lockUncancelable(self.io);
            defer self.lock.unlock(self.io);
            var it = self.proxies.iterator();
            while (it.next()) |entry| {
                if (std.mem.startsWith(u8, entry.key_ptr.*, language) and
                    (entry.key_ptr.*.len == language.len or entry.key_ptr.*[language.len] == 0))
                {
                    return entry.value_ptr.*;
                }
            }
            // No existing proxy for this language — can't serve a library file alone
            return error.NoWorkspace;
        }

        var workspace_uri = config.findWorkspaceUri(self.allocator, lang_config, file_path);
        defer if (workspace_uri) |uri| self.allocator.free(uri);

        // For Rust: resolve Cargo workspace root via `cargo metadata`.
        // Sub-crates in a workspace share one rust-analyzer instance.
        if (workspace_uri != null and std.mem.eql(u8, language, "rust")) {
            if (self.resolveCargoWorkspace(workspace_uri.?)) |ws_uri| {
                self.allocator.free(workspace_uri.?);
                workspace_uri = ws_uri;
            }
        }

        // Build lookup key: "language\0workspace_uri" or just "language"
        var key_buf: [std.fs.max_path_bytes + 128]u8 = undefined;
        const lookup_key = if (workspace_uri) |uri|
            std.fmt.bufPrint(&key_buf, "{s}\x00{s}", .{ language, uri }) catch return error.KeyTooLong
        else
            std.fmt.bufPrint(&key_buf, "{s}", .{language}) catch return error.KeyTooLong;

        // Check existing + mark as spawning (atomic under lock)
        {
            self.lock.lockUncancelable(self.io);
            defer self.lock.unlock(self.io);
            if (self.proxies.get(lookup_key)) |proxy| return proxy;

            // Another coroutine is already spawning this — caller should retry later
            if (self.spawning.get(lookup_key) != null) return error.Spawning;
            // Mark as spawning to prevent concurrent duplicates
            const spawning_key = self.allocator.dupe(u8, lookup_key) catch return error.OutOfMemory;
            self.spawning.put(spawning_key, {}) catch {
                self.allocator.free(spawning_key);
                return error.OutOfMemory;
            };
        }
        // Ensure spawning marker is cleared on all exit paths
        defer self.clearSpawning(lookup_key);

        // Create new proxy (outside lock — may block on LSP initialize)
        log.info("spawning LSP for {s}", .{language});
        const g = group_override orelse self.group orelse return error.CommandNotFound;
        const proxy = self.spawnProxy(lang_config, workspace_uri, g) catch |err| {
            log.warn("spawn failed for {s}: {s}", .{ language, @errorName(err) });
            // Spawn failed — try auto-install
            if (self.installer) |inst| {
                if (lang_config.install) |info| {
                    if (info.method != .system) {
                        const ctx = AutoInstallCtx{
                            .installer = inst,
                            .lang_config = lang_config,
                            .registry = self,
                        };
                        g.concurrent(self.io, autoInstall, .{ctx}) catch {};
                        return error.Installing;
                    }
                }
            }
            // No install info or system-only — mark permanently failed
            self.markFailed(language);
            return err;
        };

        // Store under lock
        const owned_key = self.allocator.dupe(u8, lookup_key) catch {
            proxy.deinit();
            return error.OutOfMemory;
        };

        {
            self.lock.lockUncancelable(self.io);
            defer self.lock.unlock(self.io);
            self.proxies.put(owned_key, proxy) catch {
                self.allocator.free(owned_key);
                proxy.deinit();
                return error.OutOfMemory;
            };
        }

        log.info("LSP ready: {s}", .{owned_key});
        return proxy;
    }

    /// Spawn a child LSP server process and create a connected LspProxy.
    fn spawnProxy(
        self: *ProxyRegistry,
        lang_config: *const config.LangConfig,
        workspace_uri: ?[]const u8,
        group: *Io.Group,
    ) !*LspProxy {
        // Resolve command: try PATH first, then managed path
        var managed_path: ?[]const u8 = null;
        defer if (managed_path) |p| self.allocator.free(p);

        const command = blk: {
            if (self.installer) |inst| {
                if (Installer.commandInPath(lang_config.command)) break :blk lang_config.command;
                managed_path = inst.getManagedPath(lang_config);
                break :blk managed_path orelse return error.CommandNotFound;
            }
            break :blk lang_config.command;
        };

        // Build argv: [command] ++ args
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(self.allocator);
        try argv.append(self.allocator, command);
        for (lang_config.args) |arg| {
            try argv.append(self.allocator, arg);
        }

        const child = std.process.spawn(self.io, .{
            .argv = argv.items,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .pipe,
        }) catch return error.CommandNotFound;

        // Build initialize params
        const root_uri: ?[]const u8 = workspace_uri;
        const init_params: lsp.ParamsType("initialize") = .{
            .processId = @intCast(std.c.getpid()),
            .rootUri = root_uri,
            .capabilities = .{
                .window = .{ .workDoneProgress = true },
                .textDocument = .{
                    .hover = .{
                        .contentFormat = &.{ .markdown, .plaintext },
                    },
                    .completion = .{
                        .completionItem = .{
                            .documentationFormat = &.{ .markdown, .plaintext },
                        },
                    },
                    .signatureHelp = .{
                        .signatureInformation = .{
                            .documentationFormat = &.{ .markdown, .plaintext },
                        },
                    },
                },
            },
        };

        const notify_cb: ?LspProxy.NotifyCallback = if (self.on_notification) |func|
            .{ .func = func, .ctx = self.notify_ctx.? }
        else
            null;
        return LspProxy.init(self.allocator, self.io, child, group, init_params, notify_cb);
    }

    /// Clear spawning marker for a lookup key. Thread-safe.
    fn clearSpawning(self: *ProxyRegistry, key: []const u8) void {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        if (self.spawning.fetchRemove(key)) |kv| {
            self.allocator.free(kv.key);
        }
    }

    /// Mark a language as permanently failed (until reset). Thread-safe.
    fn markFailed(self: *ProxyRegistry, language: []const u8) void {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);

        if (self.failed_spawns.get(language) != null) return;
        const owned = self.allocator.dupe(u8, language) catch return;
        self.failed_spawns.put(owned, {}) catch {
            self.allocator.free(owned);
        };
    }

    /// Clear failed spawn marker for a language. Thread-safe.
    pub fn clearFailed(self: *ProxyRegistry, language: []const u8) void {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);

        if (self.failed_spawns.fetchRemove(language)) |kv| {
            self.allocator.free(kv.key);
        }
    }

    /// Resolve Cargo workspace root via `cargo metadata --no-deps`.
    /// Extracts workspace_root from JSON output, returns file:// URI.
    /// Results cached to avoid repeated subprocess calls.
    fn resolveCargoWorkspace(self: *ProxyRegistry, workspace_uri: []const u8) ?[]const u8 {
        // Extract file path from file:// URI to build manifest path
        const prefix = "file://";
        const dir = if (std.mem.startsWith(u8, workspace_uri, prefix)) workspace_uri[prefix.len..] else return null;
        const manifest = std.fmt.allocPrint(self.allocator, "{s}/Cargo.toml", .{dir}) catch return null;
        defer self.allocator.free(manifest);

        // Check cache
        {
            cargo_cache_lock();
            defer cargo_cache_mutex.unlock();
            for (cargo_cache_keys[0..cargo_cache_len], cargo_cache_vals[0..cargo_cache_len]) |k, v| {
                if (std.mem.eql(u8, k, manifest)) return self.allocator.dupe(u8, v) catch null;
            }
        }

        // Run cargo metadata (blocking — acceptable, resolve already blocks on LSP init)
        var child = std.process.spawn(self.io, .{
            .argv = &.{ "cargo", "metadata", "--no-deps", "--format-version", "1", "--manifest-path", manifest },
            .stdout = .pipe,
            .stderr = .close,
            .stdin = .close,
        }) catch return null;
        defer child.kill(self.io); // ensure cleanup on all paths (kill includes wait)

        const stdout = child.stdout orelse return null;
        var read_buf: [8192]u8 = undefined;
        var reader = stdout.readerStreaming(self.io, &read_buf);
        const output = reader.interface.allocRemaining(self.allocator, Io.Limit.limited(1024 * 1024)) catch return null;
        defer self.allocator.free(output);

        // Parse workspace_root from JSON
        var json_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer json_arena.deinit();
        const value = std.json.parseFromSliceLeaky(std.json.Value, json_arena.allocator(), output, .{}) catch return null;
        const ws_root = switch (value) {
            .object => |obj| switch (obj.get("workspace_root") orelse return null) {
                .string => |s| s,
                else => return null,
            },
            else => return null,
        };

        const uri = std.fmt.allocPrint(self.allocator, "file://{s}", .{ws_root}) catch return null;

        // Cache result
        {
            cargo_cache_lock();
            defer cargo_cache_mutex.unlock();
            if (cargo_cache_len < CARGO_CACHE_MAX) {
                const key = self.allocator.dupe(u8, manifest) catch return uri;
                const val = self.allocator.dupe(u8, uri) catch {
                    self.allocator.free(key);
                    return uri;
                };
                cargo_cache_keys[cargo_cache_len] = key;
                cargo_cache_vals[cargo_cache_len] = val;
                cargo_cache_len += 1;
            }
        }

        // If same as input, no workspace nesting → return null (don't override)
        if (std.mem.eql(u8, uri, workspace_uri)) {
            self.allocator.free(uri);
            return null;
        }

        log.info("cargo workspace: {s} → {s}", .{ workspace_uri, uri });
        return uri;
    }

    const CARGO_CACHE_MAX = 16;
    var cargo_cache_keys: [CARGO_CACHE_MAX][]const u8 = .{&.{}} ** CARGO_CACHE_MAX;
    var cargo_cache_vals: [CARGO_CACHE_MAX][]const u8 = .{&.{}} ** CARGO_CACHE_MAX;
    var cargo_cache_len: usize = 0;
    // std.atomic.Mutex (non-Io) for global state — tryLock + spinLoopHint is the
    // only option in Zig 0.16 for code without Io access (same pattern as predicates.zig).
    var cargo_cache_mutex: std.atomic.Mutex = .unlocked;

    fn cargo_cache_lock() void {
        while (!cargo_cache_mutex.tryLock()) std.atomic.spinLoopHint();
    }

    /// Get all active proxies (for status reporting).
    pub fn getActiveProxies(self: *ProxyRegistry) []const ProxyInfo {
        _ = self;
        // TODO: implement status reporting
        return &.{};
    }

    pub const ProxyInfo = struct {
        language: []const u8,
        workspace_uri: ?[]const u8,
        state: []const u8,
    };
};

const AutoInstallCtx = struct {
    installer: *Installer,
    lang_config: *const config.LangConfig,
    registry: *ProxyRegistry,
};

fn autoInstall(ctx: AutoInstallCtx) Io.Cancelable!void {
    log.info("auto-install starting for {s}", .{ctx.lang_config.language_id});
    ctx.installer.install(ctx.lang_config) catch |err| {
        log.err("auto-install failed for {s}: {s}", .{ ctx.lang_config.language_id, @errorName(err) });
        ctx.registry.markFailed(ctx.lang_config.language_id);

        ctx.installer.notifier.send("install_complete", .{
            .language = ctx.lang_config.language_id,
            .success = false,
            .message = @errorName(err),
        }) catch {};
        return;
    };

    ctx.installer.notifier.send("install_complete", .{
        .language = ctx.lang_config.language_id,
        .success = true,
        .message = "Installed successfully",
    }) catch {};
}
