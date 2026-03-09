const std = @import("std");
const log = @import("../log.zig");
const lsp_config = @import("config.zig");

const Allocator = std.mem.Allocator;
const LspServerConfig = lsp_config.LspServerConfig;

// ============================================================================
// Path utilities — pure functions for file path / URI manipulation
// ============================================================================

/// Extract real filesystem path from scp:// URLs.
/// scp://user@host//path/file -> /path/file
pub fn extractRealPath(file_path: []const u8) []const u8 {
    const prefix = "scp://";
    if (std.mem.startsWith(u8, file_path, prefix)) {
        const rest = file_path[prefix.len..];
        if (std.mem.indexOf(u8, rest, "//")) |pos| {
            return rest[pos + 1 ..];
        }
    }
    return file_path;
}

/// Extract SSH host from scp:// URL.
pub fn extractSshHost(file_path: []const u8) ?[]const u8 {
    const prefix = "scp://";
    if (std.mem.startsWith(u8, file_path, prefix)) {
        const rest = file_path[prefix.len..];
        if (std.mem.indexOf(u8, rest, "//")) |pos| {
            return rest[0..pos];
        }
    }
    return null;
}

/// Restore SSH path prefix.
pub fn restoreSshPath(allocator: Allocator, path: []const u8, ssh_host: ?[]const u8) ![]const u8 {
    if (ssh_host) |host| {
        return std.fmt.allocPrint(allocator, "scp://{s}/{s}", .{ host, path });
    }
    return allocator.dupe(u8, path);
}

/// Convert file path to file:// URI.
pub fn filePathToUri(allocator: Allocator, file_path: []const u8) ![]const u8 {
    const real_path = extractRealPath(file_path);
    return std.fmt.allocPrint(allocator, "file://{s}", .{real_path});
}

/// Convert file:// URI to file path, decoding percent-encoded characters.
/// Returns an allocated string (caller must free with the same allocator).
pub fn uriToFilePathAlloc(allocator: Allocator, uri: []const u8) ?[]const u8 {
    const prefix = "file://";
    if (!std.mem.startsWith(u8, uri, prefix)) return null;
    const raw = uri[prefix.len..];

    // Fast path: no percent encoding
    if (std.mem.indexOfScalar(u8, raw, '%') == null) return raw;

    // Decode percent-encoded characters (e.g., %40 → @, %20 → space)
    var buf = allocator.alloc(u8, raw.len) catch return null;
    var out: usize = 0;
    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] == '%' and i + 2 < raw.len) {
            const hi = hexDigit(raw[i + 1]) orelse {
                buf[out] = raw[i];
                out += 1;
                i += 1;
                continue;
            };
            const lo = hexDigit(raw[i + 2]) orelse {
                buf[out] = raw[i];
                out += 1;
                i += 1;
                continue;
            };
            buf[out] = (@as(u8, hi) << 4) | lo;
            out += 1;
            i += 3;
        } else {
            buf[out] = raw[i];
            out += 1;
            i += 1;
        }
    }
    // Allocate exact-size result and free the oversized work buffer
    const result = allocator.dupe(u8, buf[0..out]) catch {
        allocator.free(buf);
        return null;
    };
    allocator.free(buf);
    return result;
}

fn hexDigit(c: u8) ?u4 {
    return switch (c) {
        '0'...'9' => @intCast(c - '0'),
        'a'...'f' => @intCast(c - 'a' + 10),
        'A'...'F' => @intCast(c - 'A' + 10),
        else => null,
    };
}

/// Convert file:// URI to file path (non-allocating, no percent decoding).
/// Only use when percent-encoded paths are impossible.
pub fn uriToFilePath(uri: []const u8) ?[]const u8 {
    const prefix = "file://";
    if (std.mem.startsWith(u8, uri, prefix)) {
        return uri[prefix.len..];
    }
    return null;
}

/// Check if a file is in a Rust library path (toolchains, registry, git checkouts).
/// These files should reuse an existing client rather than spawning a new LSP instance.
fn isLibraryPath(path: []const u8) bool {
    const home = std.posix.getenv("HOME");
    const rustup = std.posix.getenv("RUSTUP_HOME");
    const cargo = std.posix.getenv("CARGO_HOME");

    // $RUSTUP_HOME/toolchains (defaults to ~/.rustup/toolchains)
    if (isDescendantOf(path, rustup orelse home, .{if (rustup != null) "" else "/.rustup/toolchains"}))
        return true;

    // $CARGO_HOME/registry/src and $CARGO_HOME/git/checkouts (defaults to ~/.cargo)
    const prefix: []const u8 = if (cargo != null) "" else "/.cargo";
    for ([_][]const u8{ "/registry/src", "/git/checkouts" }) |suffix| {
        if (isDescendantOf(path, cargo orelse home, .{ prefix, suffix }))
            return true;
    }

    return false;
}

fn isDescendant(path: []const u8, prefix: []const u8) bool {
    if (path.len <= prefix.len) return false;
    return std.mem.startsWith(u8, path, prefix) and path[prefix.len] == '/';
}

/// Check if `path` is a descendant of `base ++ suffixes...`, using a stack buffer.
/// Returns false if base is null or the concatenated path doesn't fit.
fn isDescendantOf(path: []const u8, maybe_base: ?[]const u8, suffixes: anytype) bool {
    const base = maybe_base orelse return false;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    if (base.len > buf.len) return false;
    @memcpy(buf[0..base.len], base);
    var pos: usize = base.len;
    inline for (suffixes) |s| {
        if (pos + s.len > buf.len) return false;
        @memcpy(buf[pos..][0..s.len], s);
        pos += s.len;
    }
    return isDescendant(path, buf[0..pos]);
}

/// Find workspace root for a file based on workspace markers.
/// For Rust, runs `cargo metadata` to get the true workspace root (like nvim-lspconfig).
pub fn findWorkspaceUri(allocator: Allocator, config: *const LspServerConfig, file_path: []const u8) ?[]const u8 {
    const real_path = extractRealPath(file_path);

    // Library files (stdlib, registry, git deps) → return null to reuse existing client.
    // Same approach as nvim-lspconfig's is_library().
    if (isLibraryPath(real_path)) return null;

    // Walk up directory tree looking for the nearest marker
    var dir_path = std.fs.path.dirname(real_path) orelse return null;
    while (true) {
        for (config.workspace_markers) |marker| {
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            const marker_path = std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir_path, marker }) catch continue;
            // Check if marker file exists
            std.fs.cwd().access(marker_path, .{}) catch continue;

            // For Cargo.toml: use `cargo metadata` to resolve the real workspace root,
            // same approach as nvim-lspconfig. This handles Cargo workspaces correctly
            // so sub-crates don't each spawn a separate rust-analyzer instance.
            if (std.mem.eql(u8, marker, "Cargo.toml")) {
                if (cargoWorkspaceRoot(allocator, marker_path)) |root| {
                    return root;
                }
                // cargo metadata failed — fall back to this directory
            }

            return std.fmt.allocPrint(allocator, "file://{s}", .{dir_path}) catch null;
        }

        dir_path = std.fs.path.dirname(dir_path) orelse break;
    }

    // No workspace marker found — return null so the file is handled by
    // an existing client for this language (keyed by language alone).
    // This prevents spawning new LSP instances for stdlib / toolchain files.
    return null;
}

/// Simple cache for cargo workspace roots: manifest_path → workspace URI.
/// Avoids re-running `cargo metadata` on every request.
const CargoCache = struct {
    const MAX_ENTRIES = 16;
    keys: [MAX_ENTRIES]?[]const u8 = .{null} ** MAX_ENTRIES,
    vals: [MAX_ENTRIES]?[]const u8 = .{null} ** MAX_ENTRIES,
    len: usize = 0,

    fn get(self: *const CargoCache, key: []const u8) ?[]const u8 {
        for (self.keys[0..self.len], self.vals[0..self.len]) |k, v| {
            if (std.mem.eql(u8, k.?, key)) return v.?;
        }
        return null;
    }

    fn put(self: *CargoCache, allocator: Allocator, key: []const u8, val: []const u8) void {
        if (self.len >= MAX_ENTRIES) return;
        const key_owned = allocator.dupe(u8, key) catch return;
        const val_owned = allocator.dupe(u8, val) catch {
            allocator.free(key_owned);
            return;
        };
        self.keys[self.len] = key_owned;
        self.vals[self.len] = val_owned;
        self.len += 1;
    }
};

var cargo_cache: CargoCache = .{};

/// Run `cargo metadata --no-deps --format-version 1 --manifest-path <path>`
/// and extract the `workspace_root` field. Returns a `file://` URI.
/// Results are cached so cargo metadata is only called once per manifest path.
fn cargoWorkspaceRoot(allocator: Allocator, manifest_path: []const u8) ?[]const u8 {
    // Check cache first
    if (cargo_cache.get(manifest_path)) |cached_uri| {
        return allocator.dupe(u8, cached_uri) catch null;
    }

    const argv = &[_][]const u8{
        "cargo", "metadata", "--no-deps", "--format-version", "1", "--manifest-path", manifest_path,
    };
    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = .Close;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Close;
    child.spawn() catch {
        log.warn("Failed to spawn cargo metadata", .{});
        return null;
    };

    // Read all stdout before wait() (wait cleans up streams)
    const stdout_fd = (child.stdout orelse return null).handle;
    var output_buf: std.ArrayList(u8) = .{};
    defer output_buf.deinit(allocator);
    while (true) {
        var buf: [4096]u8 = undefined;
        const n = std.posix.read(stdout_fd, &buf) catch break;
        if (n == 0) break;
        output_buf.appendSlice(allocator, buf[0..n]) catch break;
    }

    const term = child.wait() catch return null;
    switch (term) {
        .Exited => |code| if (code != 0) return null,
        else => return null,
    }

    // Parse JSON and extract workspace_root
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, output_buf.items, .{
        .ignore_unknown_fields = true,
    }) catch {
        log.warn("Failed to parse cargo metadata JSON", .{});
        return null;
    };
    defer parsed.deinit();
    const workspace_root = switch (parsed.value.object.get("workspace_root") orelse return null) {
        .string => |s| s,
        else => return null,
    };

    log.info("cargo metadata workspace_root: {s}", .{workspace_root});
    const uri = std.fmt.allocPrint(allocator, "file://{s}", .{workspace_root}) catch return null;

    // Cache for future lookups
    cargo_cache.put(allocator, manifest_path, uri);

    return uri;
}

// ============================================================================
// Tests
// ============================================================================

test "extract real path from scp URL" {
    try std.testing.expectEqualStrings(
        "/home/user/file.rs",
        extractRealPath("scp://user@host//home/user/file.rs"),
    );
    try std.testing.expectEqualStrings("test.rs", extractRealPath("test.rs"));
}

test "extract SSH host" {
    try std.testing.expectEqualStrings(
        "user@host",
        extractSshHost("scp://user@host//path/file").?,
    );
    try std.testing.expect(extractSshHost("test.rs") == null);
}

test "uri to file path" {
    try std.testing.expectEqualStrings(
        "/home/user/test.rs",
        uriToFilePath("file:///home/user/test.rs").?,
    );
    try std.testing.expect(uriToFilePath("http://example.com") == null);
}

test "uri to file path — percent decoding" {
    const alloc = std.testing.allocator;

    // No encoding — returns slice into original (no alloc)
    const plain = uriToFilePathAlloc(alloc, "file:///home/user/test.rs").?;
    try std.testing.expectEqualStrings("/home/user/test.rs", plain);

    // %40 → @  (pnpm directory pattern)
    const at = uriToFilePathAlloc(alloc, "file:///node_modules/.pnpm/pkg%401.0/types.d.ts").?;
    defer alloc.free(at);
    try std.testing.expectEqualStrings("/node_modules/.pnpm/pkg@1.0/types.d.ts", at);

    // %20 → space
    const space = uriToFilePathAlloc(alloc, "file:///my%20project/file.ts").?;
    defer alloc.free(space);
    try std.testing.expectEqualStrings("/my project/file.ts", space);

    // Multiple encodings
    const multi = uriToFilePathAlloc(alloc, "file:///a%20b%2Fc%40d").?;
    defer alloc.free(multi);
    try std.testing.expectEqualStrings("/a b/c@d", multi);

    // Non file:// URI
    try std.testing.expect(uriToFilePathAlloc(alloc, "http://example.com") == null);
}
