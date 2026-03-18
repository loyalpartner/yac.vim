const std = @import("std");
const ts = @import("tree_sitter");

const Allocator = std.mem.Allocator;

pub const Highlight = struct {
    line: i32,
    col: i32,
    end_line: i32,
    end_col: i32,
    kind: i32,
};

pub const Result = struct {
    highlights: []const Highlight,
};

/// Find all occurrences of the identifier under the cursor within the
/// enclosing scope (function/test/class). Falls back to file scope for
/// top-level symbols.
pub fn extractDocumentHighlights(
    alloc: Allocator,
    tree: *const ts.Tree,
    source: []const u8,
    line: u32,
    column: u32,
) !?Result {
    const root = tree.rootNode();
    const point = ts.Point{ .row = line, .column = column };

    // Find the smallest named node at cursor position
    const target_node = root.namedDescendantForPointRange(point, point) orelse
        return null;

    // Get the text of the target node — this is what we'll search for
    const target_text = nodeText(target_node, source) orelse return null;

    // Skip nodes that are too large (not identifiers) or empty
    if (target_text.len == 0 or target_text.len > 200) return null;

    // Skip multi-line nodes — identifiers never span lines.
    // When the cursor lands on an anonymous node (e.g. VimScript `endfunction`
    // keyword), namedDescendantForPointRange returns the parent structural node
    // (e.g. `function_definition`), which spans the entire function body.
    const target_start = target_node.startPoint();
    const target_end = target_node.endPoint();
    if (target_start.row != target_end.row) return null;

    // Find the enclosing scope — search only within it
    const scope = findEnclosingScope(target_node, root);

    // Collect all matching nodes via DFS traversal within scope
    var highlights: std.ArrayList(Highlight) = .empty;
    try collectMatches(alloc, scope, source, target_text, target_node.kindId(), &highlights);

    if (highlights.items.len == 0) return null;

    return .{ .highlights = highlights.items };
}

/// Walk up from node to find the nearest scope-defining ancestor.
/// Scope nodes: function declarations, test blocks, methods, classes, etc.
/// Returns root if no scope ancestor found (file-level symbol).
fn findEnclosingScope(node: ts.Node, root: ts.Node) ts.Node {
    var current = node;
    while (current.parent()) |p| {
        if (p.eql(root)) break;
        if (isScopeNode(p)) return p;
        current = p;
    }
    return root;
}

/// Heuristic: is this node a scope boundary?
/// Covers common patterns across Zig, Python, Go, Rust, JS/TS, C/C++.
fn isScopeNode(node: ts.Node) bool {
    const kind = node.kind();
    // Exact matches for common scope nodes
    const scope_kinds = [_][]const u8{
        "fn_decl", // Zig
        "test_declaration", // Zig
        "function_definition", // Python, C/C++
        "class_definition", // Python
        "function_declaration", // Go, JS/TS
        "method_declaration", // Go
        "func_literal", // Go
        "function_item", // Rust
        "impl_item", // Rust
        "method_definition", // JS/TS
        "arrow_function", // JS/TS
        "class_declaration", // JS/TS
        "class_specifier", // C/C++
    };
    for (scope_kinds) |sk| {
        if (std.mem.eql(u8, kind, sk)) return true;
    }
    return false;
}

/// DFS traversal to find all nodes with matching text and kind.
fn collectMatches(
    alloc: Allocator,
    node: ts.Node,
    source: []const u8,
    target_text: []const u8,
    target_kind_id: u16,
    out: *std.ArrayList(Highlight),
) !void {
    // If this node is smaller than target text, skip subtree
    const node_len = node.endByte() - node.startByte();
    if (node_len < target_text.len) return;

    // Check leaf-ish nodes (same kind as target)
    if (node.kindId() == target_kind_id) {
        if (nodeText(node, source)) |text| {
            if (std.mem.eql(u8, text, target_text)) {
                const start = node.startPoint();
                const end = node.endPoint();
                try out.append(alloc, .{
                    .line = @intCast(start.row),
                    .col = @intCast(start.column),
                    .end_line = @intCast(end.row),
                    .end_col = @intCast(end.column),
                    .kind = 1,
                });
                return; // Don't recurse into matched node's children
            }
        }
    }

    // Recurse into children
    var i: u32 = 0;
    while (i < node.childCount()) : (i += 1) {
        const child = node.child(i) orelse continue;
        try collectMatches(alloc, child, source, target_text, target_kind_id, out);
    }
}

fn nodeText(node: ts.Node, source: []const u8) ?[]const u8 {
    const start = node.startByte();
    const end = node.endByte();
    if (start >= source.len or end > source.len) return null;
    return source[start..end];
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "document highlight: cursor on identifier returns matches" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const treesitter_mod = @import("treesitter.zig");
    var ts_state = treesitter_mod.TreeSitter.init(std.testing.allocator);
    defer ts_state.deinit();

    ts_state.loadFromDir("languages/zig");
    const lang = ts_state.findLangStateByName("zig") orelse return error.ZigNotLoaded;

    const source = "fn add(a: i32, b: i32) i32 {\n    return a + b;\n}\n";
    const tree = lang.parser.parseString(source, null) orelse return error.ParseFailed;
    defer tree.destroy();

    // Cursor on 'a' parameter (line 0, col 7) — should find 2 occurrences
    const result = try extractDocumentHighlights(alloc, tree, source, 0, 7);
    const r = result orelse return error.ExpectedHighlights;
    // 'a' appears in parameter and return expression
    try std.testing.expect(r.highlights.len >= 2);
}

test "document highlight: multi-line node should NOT produce highlights" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const treesitter_mod = @import("treesitter.zig");
    var ts_state = treesitter_mod.TreeSitter.init(std.testing.allocator);
    defer ts_state.deinit();

    ts_state.loadFromDir("languages/zig");
    const lang = ts_state.findLangStateByName("zig") orelse return error.ZigNotLoaded;

    // Small function (< 200 chars) — cursor on '}' closing brace
    const source = "fn tiny() void {\n    return;\n}\n";
    const tree = lang.parser.parseString(source, null) orelse return error.ParseFailed;
    defer tree.destroy();

    // Cursor on '}' (line 2, col 0) — namedDescendant returns a multi-line node
    // Should return null, NOT highlight the entire function body
    const result = try extractDocumentHighlights(alloc, tree, source, 2, 0);
    try std.testing.expect(result == null);
}

test "document highlight: VimScript function should NOT highlight entire body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const treesitter_mod = @import("treesitter.zig");
    var ts_state = treesitter_mod.TreeSitter.init(std.testing.allocator);
    defer ts_state.deinit();

    ts_state.loadFromDir("languages/vim");
    const lang = ts_state.findLangStateByName("vim") orelse return error.VimNotLoaded;

    // Small VimScript function (< 200 chars total)
    const source = "function! s:foo() abort\n  let x = 1\n  return x\nendfunction\n";
    const tree = lang.parser.parseString(source, null) orelse return error.ParseFailed;
    defer tree.destroy();

    // Cursor on 'endfunction' keyword (line 3, col 0)
    // namedDescendant should NOT produce a highlight spanning the entire function
    const result = try extractDocumentHighlights(alloc, tree, source, 3, 0);
    if (result) |r| {
        // No highlight should span from line 0 to line 3 (entire function)
        for (r.highlights) |hl| {
            // Each highlight must be single-line (identifiers don't span lines)
            try std.testing.expectEqual(hl.line, hl.end_line);
        }
    }

    // Also test cursor on 'function' keyword (line 0, col 0)
    const result2 = try extractDocumentHighlights(alloc, tree, source, 0, 0);
    if (result2) |r2| {
        for (r2.highlights) |hl| {
            try std.testing.expectEqual(hl.line, hl.end_line);
        }
    }
}

test "document highlight: scope node as target should NOT produce highlights" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const treesitter_mod = @import("treesitter.zig");
    var ts_state = treesitter_mod.TreeSitter.init(std.testing.allocator);
    defer ts_state.deinit();

    ts_state.loadFromDir("languages/zig");
    const lang = ts_state.findLangStateByName("zig") orelse return error.ZigNotLoaded;

    // Very short function: cursor at start where named descendant = fn_decl
    const source = "fn f() void {}\n";
    const tree = lang.parser.parseString(source, null) orelse return error.ParseFailed;
    defer tree.destroy();

    // Try cursor positions that might resolve to the fn_decl node itself
    // Even if they don't, this test documents the expected behavior
    const result = try extractDocumentHighlights(alloc, tree, source, 0, 0);
    // Should either return null (fn keyword) or only single-line identifier matches
    if (result) |r| {
        // Every highlight must be single-line
        for (r.highlights) |hl| {
            try std.testing.expectEqual(hl.line, hl.end_line);
        }
    }
}
