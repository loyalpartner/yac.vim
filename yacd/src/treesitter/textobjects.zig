const std = @import("std");
const ts = @import("tree_sitter");

const log = std.log.scoped(.ts_textobjects);

pub const TextObjectResult = struct {
    start_line: u32,
    start_col: u32,
    end_line: u32,
    end_col: u32,
};

pub const NavigateResult = struct {
    line: u32,
    col: u32,
};

/// Find the enclosing text object (function/class) at cursor position.
pub fn findTextObject(tree: *ts.Tree, target: []const u8, line: u32, col: u32) ?TextObjectResult {
    const root = tree.rootNode();
    const point: ts.Point = .{ .row = line, .column = col };

    var node = root.namedDescendantForPointRange(point, point) orelse return null;

    // Parse target: "function.outer" → kind="function", scope="outer"
    var kind_needle: []const u8 = target;
    var inner = false;
    if (std.mem.indexOfScalar(u8, target, '.')) |dot| {
        kind_needle = target[0..dot];
        inner = std.mem.eql(u8, target[dot + 1 ..], "inner");
    }

    while (true) {
        if (matchesKind(node.kind(), kind_needle)) {
            if (inner) {
                const body = node.childByFieldName("body") orelse
                    node.childByFieldName("block") orelse
                    node.childByFieldName("consequence");
                if (body) |b| {
                    const sp = b.startPoint();
                    const ep = b.endPoint();
                    const inner_start = sp.row + 1;
                    const inner_end = if (ep.row > sp.row + 1) ep.row - 1 else inner_start;
                    return .{ .start_line = inner_start, .start_col = 0, .end_line = inner_end, .end_col = 999 };
                }
                // No body child — fall through to outer
            }
            const sp = node.startPoint();
            const ep = node.endPoint();
            return .{ .start_line = sp.row, .start_col = sp.column, .end_line = ep.row, .end_col = ep.column };
        }
        node = node.parent() orelse return null;
    }
}

/// Find next/prev function or struct from cursor line.
pub fn findNavigationTarget(tree: *ts.Tree, target: []const u8, direction: []const u8, cursor_line: u32) ?NavigateResult {
    const root = tree.rootNode();
    const is_next = std.mem.eql(u8, direction, "next");

    var best_line: ?u32 = null;
    var best_col: u32 = 0;
    collectTargets(root, target, cursor_line, is_next, &best_line, &best_col);

    if (best_line) |l| return .{ .line = l, .col = best_col };
    return null;
}

fn collectTargets(node: ts.Node, target: []const u8, cursor_line: u32, is_next: bool, best_line: *?u32, best_col: *u32) void {
    const count = node.namedChildCount();
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const child = node.namedChild(i) orelse continue;
        if (matchesKind(child.kind(), target)) {
            const line = child.startPoint().row;
            const col = child.startPoint().column;
            if (is_next and line > cursor_line) {
                if (best_line.* == null or line < best_line.*.?) {
                    best_line.* = line;
                    best_col.* = col;
                }
            } else if (!is_next and line < cursor_line) {
                if (best_line.* == null or line > best_line.*.?) {
                    best_line.* = line;
                    best_col.* = col;
                }
            }
        }
        // Recurse into children (for nested functions/structs)
        collectTargets(child, target, cursor_line, is_next, best_line, best_col);
    }
}

/// Match a tree-sitter node kind against a text object target kind.
/// Maps abstract targets ("function", "class") to concrete node kinds
/// across multiple languages.
pub fn matchesKind(node_kind: []const u8, target: []const u8) bool {
    if (std.mem.eql(u8, target, "function")) {
        return isAnyOf(node_kind, &.{
            "function_declaration",   "function_definition", "function_item",
            "method_declaration",     "method_definition",   "arrow_function",
            "lambda_expression",      "fn_proto",            "test_declaration",
            "TopLevelDecl",
        }) or
            std.mem.indexOf(u8, node_kind, "fn") != null or
            std.mem.indexOf(u8, node_kind, "Fn") != null;
    }
    if (std.mem.eql(u8, target, "class") or std.mem.eql(u8, target, "struct")) {
        return isAnyOf(node_kind, &.{
            "struct_declaration",    "class_declaration",    "class_definition",
            "interface_declaration", "enum_declaration",     "union_declaration",
            "impl_item",            "trait_item",           "type_declaration",
            "ContainerDecl",        "ContainerDeclAuto",
        }) or
            std.mem.indexOf(u8, node_kind, "struct") != null or
            std.mem.indexOf(u8, node_kind, "class") != null or
            std.mem.indexOf(u8, node_kind, "enum") != null;
    }
    return false;
}

fn isAnyOf(s: []const u8, list: []const []const u8) bool {
    for (list) |item| {
        if (std.mem.eql(u8, s, item)) return true;
    }
    return false;
}
