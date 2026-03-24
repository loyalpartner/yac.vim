const std = @import("std");
const ts = @import("tree_sitter");
const mvzr = @import("mvzr");
const log = std.log.scoped(.ts_predicates);

/// Evaluate all predicates for a match. Returns true if all predicates pass.
/// `#set!` predicates are skipped (metadata only, don't affect filtering).
pub fn evaluatePredicates(
    query: *const ts.Query,
    match: ts.Query.Match,
    source: []const u8,
) bool {
    const steps = query.predicatesForPattern(match.pattern_index);
    if (steps.len == 0) return true;

    var i: usize = 0;
    while (i < steps.len) {
        const pred_start = i;
        while (i < steps.len and steps[i].type != .done) : (i += 1) {}
        const pred_end = i;
        if (i < steps.len) i += 1;

        if (pred_end == pred_start) continue;
        if (steps[pred_start].type != .string) continue;
        const pred_name = query.stringValueForId(steps[pred_start].value_id) orelse continue;

        if (std.mem.eql(u8, pred_name, "lua-match?") or std.mem.eql(u8, pred_name, "match?")) {
            if (!evalLuaMatch(query, match, steps[pred_start..pred_end], source)) return false;
        } else if (std.mem.eql(u8, pred_name, "eq?")) {
            if (!evalEq(query, match, steps[pred_start..pred_end], source)) return false;
        } else if (std.mem.eql(u8, pred_name, "any-of?")) {
            if (!evalAnyOf(query, match, steps[pred_start..pred_end], source)) return false;
        } else if (std.mem.eql(u8, pred_name, "has-ancestor?")) {
            if (!evalHasAncestor(query, match, steps[pred_start..pred_end])) return false;
        } else if (std.mem.eql(u8, pred_name, "set!")) {
            continue;
        }
    }

    return true;
}

fn evalLuaMatch(
    query: *const ts.Query,
    match: ts.Query.Match,
    steps: []const ts.Query.PredicateStep,
    source: []const u8,
) bool {
    if (steps.len < 3) return true;
    if (steps[1].type != .capture or steps[2].type != .string) return true;
    const capture_index = steps[1].value_id;
    const pattern = query.stringValueForId(steps[2].value_id) orelse return true;
    const text = getCaptureText(match, capture_index, source) orelse return false;
    return regexMatch(pattern, text);
}

fn evalEq(
    query: *const ts.Query,
    match: ts.Query.Match,
    steps: []const ts.Query.PredicateStep,
    source: []const u8,
) bool {
    if (steps.len < 3) return true;
    if (steps[1].type != .capture or steps[2].type != .string) return true;
    const capture_index = steps[1].value_id;
    const expected = query.stringValueForId(steps[2].value_id) orelse return true;
    const text = getCaptureText(match, capture_index, source) orelse return false;
    return std.mem.eql(u8, text, expected);
}

fn evalAnyOf(
    query: *const ts.Query,
    match: ts.Query.Match,
    steps: []const ts.Query.PredicateStep,
    source: []const u8,
) bool {
    if (steps.len < 3) return true;
    if (steps[1].type != .capture) return true;
    const capture_index = steps[1].value_id;
    const text = getCaptureText(match, capture_index, source) orelse return false;
    for (steps[2..]) |step| {
        if (step.type != .string) continue;
        const candidate = query.stringValueForId(step.value_id) orelse continue;
        if (std.mem.eql(u8, text, candidate)) return true;
    }
    return false;
}

fn evalHasAncestor(
    query: *const ts.Query,
    match: ts.Query.Match,
    steps: []const ts.Query.PredicateStep,
) bool {
    if (steps.len < 3) return true;
    if (steps[1].type != .capture) return true;
    const capture_index = steps[1].value_id;
    const node = getCaptureNode(match, capture_index) orelse return false;
    var current = node.parent();
    while (current) |cur| {
        const kind = cur.kind();
        for (steps[2..]) |step| {
            if (step.type != .string) continue;
            const ancestor_type = query.stringValueForId(step.value_id) orelse continue;
            if (std.mem.eql(u8, kind, ancestor_type)) return true;
        }
        current = cur.parent();
    }
    return false;
}

fn getCaptureNode(match: ts.Query.Match, capture_index: u32) ?ts.Node {
    for (match.captures) |cap| {
        if (cap.index == capture_index) return cap.node;
    }
    return null;
}

fn getCaptureText(match: ts.Query.Match, capture_index: u32, source: []const u8) ?[]const u8 {
    for (match.captures) |cap| {
        if (cap.index == capture_index) {
            const start = cap.node.startByte();
            const end = cap.node.endByte();
            if (start >= source.len or end > source.len) return null;
            return source[start..end];
        }
    }
    return null;
}

// ============================================================================
// Regex matching with compiled-pattern cache
// ============================================================================

// Default Regex (64 ops) is too small for long alternations like Go builtins.
const Regex = mvzr.SizedRegex(256, 16);
const CacheEntry = union(enum) { compiled: Regex, failed: void };
var regex_cache: std.StringHashMapUnmanaged(CacheEntry) = .empty;

fn regexMatch(pattern: []const u8, text: []const u8) bool {
    const entry = regex_cache.get(pattern) orelse blk: {
        const new = if (Regex.compile(pattern)) |r|
            CacheEntry{ .compiled = r }
        else
            CacheEntry{ .failed = {} };
        if (new == .failed) {
            log.warn("regexMatch: failed to compile pattern: {s}", .{pattern});
        }
        // pattern strings come from tree-sitter query data and are stable for the
        // lifetime of the query, so we can use them as HashMap keys without duping.
        regex_cache.put(std.heap.c_allocator, pattern, new) catch {};
        break :blk new;
    };
    return switch (entry) {
        .compiled => |r| r.match(text) != null,
        .failed => false,
    };
}

// ============================================================================
// Tests
// ============================================================================

test "regexMatch — type names" {
    try std.testing.expect(regexMatch("^[A-Z_][a-zA-Z0-9_]*", "Allocator"));
    try std.testing.expect(regexMatch("^[A-Z_][a-zA-Z0-9_]*", "_Foo"));
    try std.testing.expect(!regexMatch("^[A-Z_][a-zA-Z0-9_]*", "allocator"));
    try std.testing.expect(!regexMatch("^[A-Z_][a-zA-Z0-9_]*", ""));
}

test "regexMatch — UPPER_CASE constants" {
    try std.testing.expect(regexMatch("^[A-Z][A-Z_0-9]+$", "MAX_SIZE"));
    try std.testing.expect(regexMatch("^[A-Z][A-Z_0-9]+$", "FOO"));
    try std.testing.expect(!regexMatch("^[A-Z][A-Z_0-9]+$", "A"));
    try std.testing.expect(!regexMatch("^[A-Z][A-Z_0-9]+$", "Foo"));
}

test "regexMatch — leading underscore constants" {
    try std.testing.expect(regexMatch("^_*[A-Z][A-Z\\d_]*$", "_FOO"));
    try std.testing.expect(regexMatch("^_*[A-Z][A-Z\\d_]*$", "__BAR"));
    try std.testing.expect(regexMatch("^_*[A-Z_][A-Z\\d_]*$", "_FOO"));
    try std.testing.expect(!regexMatch("^_*[A-Z][A-Z\\d_]*$", "foo"));
}

test "regexMatch — Go builtins" {
    try std.testing.expect(regexMatch("^(append|cap|close|complex|copy|delete|imag|len|make|new|panic|print|println|real|recover)$", "append"));
    try std.testing.expect(regexMatch("^(append|cap|close|complex|copy|delete|imag|len|make|new|panic|print|println|real|recover)$", "recover"));
    try std.testing.expect(!regexMatch("^(append|cap|close|complex|copy|delete|imag|len|make|new|panic|print|println|real|recover)$", "foo"));
}

test "regexMatch — doc comments" {
    try std.testing.expect(regexMatch("^//(/|!)", "///"));
    try std.testing.expect(regexMatch("^//(/|!)", "//!"));
    try std.testing.expect(!regexMatch("^//(/|!)", "// comment"));
}

test "regexMatch — unknown patterns return false" {
    // Invalid regex should compile-fail gracefully and return false
    try std.testing.expect(!regexMatch("^[invalid", "anything"));
}
