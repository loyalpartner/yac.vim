const std = @import("std");
const lsp_registry_mod = @import("../lsp/registry.zig");
const lsp_client_mod = @import("../lsp/client.zig");
const lsp_types = @import("../lsp/types.zig");
const path_utils = @import("../lsp/path_utils.zig");

const Allocator = std.mem.Allocator;
const LspRegistry = lsp_registry_mod.LspRegistry;
const LspClient = lsp_client_mod.LspClient;
const log = std.log.scoped(.lsp_context);

// ============================================================================
// LspContext — resolved per-request LSP client context
// ============================================================================

pub const LspContext = struct {
    language: []const u8,
    client_key: []const u8,
    uri: []const u8,
    client: *LspClient,
    real_path: []const u8,

    /// Resolve LSP context for the given file. Returns null if no client available.
    pub fn resolve(registry: *LspRegistry, alloc: Allocator, file: []const u8) !?LspContext {
        const real_path = path_utils.extractRealPath(file);
        const language = LspRegistry.detectLanguage(real_path) orelse return null;

        if (registry.hasSpawnFailed(language)) return null;

        const result = registry.getOrCreateClient(language, real_path) catch |e| {
            log.err("LSP server not available for {s}: {any}", .{ language, e });
            registry.markSpawnFailed(language);
            return null;
        };

        if (registry.isInitializing(result.client_key)) return null;

        const uri = try path_utils.filePathToUri(alloc, real_path);

        return .{
            .language = language,
            .client_key = result.client_key,
            .uri = uri,
            .client = result.client,
            .real_path = real_path,
        };
    }

    /// Send a typed position request. Returns the LSP result type for the given method.
    pub fn sendPositionRequest(
        self: LspContext,
        comptime lsp_method: []const u8,
        alloc: Allocator,
        line: u32,
        column: u32,
    ) !lsp_types.ResultType(lsp_method) {
        return self.client.request(lsp_method, alloc, .{
            .textDocument = .{ .uri = self.uri },
            .position = .{ .line = @intCast(line), .character = @intCast(column) },
        }) catch return null;
    }
};

/// Check if the LSP server for the given client_key supports a capability.
/// Returns true if unsupported (caller should skip the feature).
pub fn serverUnsupported(registry: *LspRegistry, client_key: []const u8, capability: []const u8) bool {
    return !registry.serverSupports(client_key, capability);
}
