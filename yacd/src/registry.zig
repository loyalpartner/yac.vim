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

        const workspace_uri = config.findWorkspaceUri(self.allocator, lang_config, file_path);
        defer if (workspace_uri) |uri| self.allocator.free(uri);

        // Build lookup key: "language\0workspace_uri" or just "language"
        var key_buf: [std.fs.max_path_bytes + 128]u8 = undefined;
        const lookup_key = if (workspace_uri) |uri|
            std.fmt.bufPrint(&key_buf, "{s}\x00{s}", .{ language, uri }) catch return error.KeyTooLong
        else
            std.fmt.bufPrint(&key_buf, "{s}", .{language}) catch return error.KeyTooLong;

        // Check existing under lock
        {
            self.lock.lockUncancelable(self.io);
            defer self.lock.unlock(self.io);
            if (self.proxies.get(lookup_key)) |proxy| {
                return proxy;
            }
        }

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
        errdefer proxy.deinit();

        // Store under lock
        const owned_key = try self.allocator.dupe(u8, lookup_key);
        errdefer self.allocator.free(owned_key);

        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);

        // Double-check: another coroutine may have created it while we were spawning
        if (self.proxies.get(lookup_key)) |existing| {
            self.allocator.free(owned_key);
            proxy.deinit();
            return existing;
        }

        try self.proxies.put(owned_key, proxy);
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
