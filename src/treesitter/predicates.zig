const std = @import("std");
const ts = @import("tree_sitter");
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

    // Parse predicates separated by .done sentinels
    var i: usize = 0;
    while (i < steps.len) {
        // Find the end of this predicate (next .done)
        const pred_start = i;
        while (i < steps.len and steps[i].type != .done) : (i += 1) {}
        const pred_end = i;
        if (i < steps.len) i += 1; // skip .done

        if (pred_end == pred_start) continue; // empty predicate

        // First step should be a string (the predicate name)
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
            // Metadata-only, skip
            continue;
        }
        // Unknown predicates are ignored (permissive)
    }

    return true;
}

/// #lua-match? @capture "pattern"
/// Only supports the 3 patterns from highlights.scm:
///   ^[A-Z_][a-zA-Z0-9_]*   — type names
///   ^[A-Z][A-Z_0-9]+$      — UPPER_CASE constants
///   ^//!                    — doc comments
fn evalLuaMatch(
    query: *const ts.Query,
    match: ts.Query.Match,
    steps: []const ts.Query.PredicateStep,
    source: []const u8,
) bool {
    // steps: [pred_name, capture, pattern_string]
    if (steps.len < 3) return true;
    if (steps[1].type != .capture or steps[2].type != .string) return true;

    const capture_index = steps[1].value_id;
    const pattern = query.stringValueForId(steps[2].value_id) orelse return true;

    const text = getCaptureText(match, capture_index, source) orelse return false;
    return simplePatternMatch(pattern, text);
}

/// #eq? @capture "string"
fn evalEq(
    query: *const ts.Query,
    match: ts.Query.Match,
    steps: []const ts.Query.PredicateStep,
    source: []const u8,
) bool {
    // steps: [pred_name, capture, string]
    if (steps.len < 3) return true;
    if (steps[1].type != .capture or steps[2].type != .string) return true;

    const capture_index = steps[1].value_id;
    const expected = query.stringValueForId(steps[2].value_id) orelse return true;

    const text = getCaptureText(match, capture_index, source) orelse return false;
    return std.mem.eql(u8, text, expected);
}

/// #any-of? @capture "str1" "str2" ...
fn evalAnyOf(
    query: *const ts.Query,
    match: ts.Query.Match,
    steps: []const ts.Query.PredicateStep,
    source: []const u8,
) bool {
    // steps: [pred_name, capture, str1, str2, ...]
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

/// #has-ancestor? @capture "node_type1" "node_type2" ...
/// Returns true if any ancestor of the captured node matches one of the given types.
fn evalHasAncestor(
    query: *const ts.Query,
    match: ts.Query.Match,
    steps: []const ts.Query.PredicateStep,
) bool {
    // steps: [pred_name, capture, type1, type2, ...]
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

/// Get the node for a capture within a match.
fn getCaptureNode(match: ts.Query.Match, capture_index: u32) ?ts.Node {
    for (match.captures) |cap| {
        if (cap.index == capture_index) return cap.node;
    }
    return null;
}

/// Get the source text for a capture within a match.
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

/// Hardcoded pattern matcher for patterns used in highlights.scm files.
pub fn simplePatternMatch(pattern: []const u8, text: []const u8) bool {
    if (std.mem.eql(u8, pattern, "^[A-Z_][a-zA-Z0-9_]*")) {
        // Type names: starts with A-Z or _, rest alphanumeric/underscore
        if (text.len == 0) return false;
        return (isUpper(text[0]) or text[0] == '_') and allAlnumUnderscore(text[1..]);
    } else if (std.mem.eql(u8, pattern, "^[A-Z][A-Z_0-9]+$") or
        std.mem.eql(u8, pattern, "^[A-Z][A-Z\\d_]+$'"))
    {
        // UPPER_CASE constants (Zig and Rust variants use same semantics)
        return isUpperSnakeCase(text);
    } else if (std.mem.eql(u8, pattern, "^//!")) {
        return std.mem.startsWith(u8, text, "//!");
    } else if (std.mem.eql(u8, pattern, "^[A-Z]")) {
        return text.len > 0 and isUpper(text[0]);
    } else if (std.mem.eql(u8, pattern, "^_*[A-Z][A-Z\\d_]*$")) {
        // C/C++ constants: optional leading underscores, then UPPER_CASE
        return isLeadingUnderscoreUpperCase(text);
    } else if (std.mem.eql(u8, pattern, "^(append|cap|close|complex|copy|delete|imag|len|make|new|panic|print|println|real|recover)$")) {
        return isGoBuiltin(text);
    } else if (std.mem.eql(u8, pattern, "^-")) {
        // Bash flags: -f, --verbose, -Doptimize=ReleaseFast
        return std.mem.startsWith(u8, text, "-");
    } else if (std.mem.eql(u8, pattern, "^#![ \\t]*/")) {
        // Shebang: #!/bin/bash, #! /usr/bin/env bash
        if (!std.mem.startsWith(u8, text, "#!")) return false;
        for (text[2..]) |c| {
            if (c == '/') return true;
            if (c != ' ' and c != '\t') return false;
        }
        return false;
    }
    // Unknown pattern — conservative: reject to prevent silent priority override.
    // A permissive `return true` here caused @constant.builtin to override @function
    // for ALL identifiers in C++, breaking highlighting for entire languages.
    log.warn("simplePatternMatch: unknown regex pattern, rejecting: {s}", .{pattern});
    return false;
}

fn isUpperSnakeCase(text: []const u8) bool {
    if (text.len < 2 or !isUpper(text[0])) return false;
    for (text[1..]) |c| {
        if (!isUpper(c) and !std.ascii.isDigit(c) and c != '_') return false;
    }
    return true;
}

/// Matches `^_*[A-Z][A-Z\d_]*$` — optional leading underscores then UPPER_CASE
fn isLeadingUnderscoreUpperCase(text: []const u8) bool {
    if (text.len == 0) return false;
    var i: usize = 0;
    // Skip leading underscores
    while (i < text.len and text[i] == '_') : (i += 1) {}
    // Must have at least one uppercase letter
    if (i >= text.len or !isUpper(text[i])) return false;
    i += 1;
    // Rest must be uppercase, digit, or underscore
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (!isUpper(c) and !std.ascii.isDigit(c) and c != '_') return false;
    }
    return true;
}

fn isGoBuiltin(text: []const u8) bool {
    const builtins = [_][]const u8{
        "append", "cap",   "close",   "complex", "copy",
        "delete", "imag",  "len",     "make",    "new",
        "panic",  "print", "println", "real",    "recover",
    };
    for (builtins) |b| {
        if (std.mem.eql(u8, text, b)) return true;
    }
    return false;
}

const isUpper = std.ascii.isUpper;

fn allAlnumUnderscore(s: []const u8) bool {
    for (s) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    }
    return true;
}

// ============================================================================
// Tests
// ============================================================================

test "simplePatternMatch — type names" {
    const pat = "^[A-Z_][a-zA-Z0-9_]*";
    try std.testing.expect(simplePatternMatch(pat, "Allocator"));
    try std.testing.expect(simplePatternMatch(pat, "HashMap"));
    try std.testing.expect(simplePatternMatch(pat, "_Foo"));
    try std.testing.expect(!simplePatternMatch(pat, "allocator"));
    try std.testing.expect(!simplePatternMatch(pat, "123"));
    try std.testing.expect(!simplePatternMatch(pat, ""));
}

test "simplePatternMatch — UPPER_CASE constants" {
    const pat = "^[A-Z][A-Z_0-9]+$";
    try std.testing.expect(simplePatternMatch(pat, "MAX_SIZE"));
    try std.testing.expect(simplePatternMatch(pat, "FOO"));
    try std.testing.expect(simplePatternMatch(pat, "A1"));
    try std.testing.expect(!simplePatternMatch(pat, "A")); // too short
    try std.testing.expect(!simplePatternMatch(pat, "Foo")); // lowercase
    try std.testing.expect(!simplePatternMatch(pat, "fOO")); // starts lowercase
}

test "simplePatternMatch — doc comments" {
    const pat = "^//!";
    try std.testing.expect(simplePatternMatch(pat, "//! This is a doc comment"));
    try std.testing.expect(simplePatternMatch(pat, "//!"));
    try std.testing.expect(!simplePatternMatch(pat, "// regular comment"));
    try std.testing.expect(!simplePatternMatch(pat, "//"));
}

test "simplePatternMatch — Rust UPPER_CASE constants" {
    const pat = "^[A-Z][A-Z\\d_]+$'";
    try std.testing.expect(simplePatternMatch(pat, "MAX_SIZE"));
    try std.testing.expect(simplePatternMatch(pat, "FOO"));
    try std.testing.expect(!simplePatternMatch(pat, "Foo"));
    try std.testing.expect(!simplePatternMatch(pat, "a"));
}

test "simplePatternMatch — starts with uppercase" {
    const pat = "^[A-Z]";
    try std.testing.expect(simplePatternMatch(pat, "HashMap"));
    try std.testing.expect(simplePatternMatch(pat, "A"));
    try std.testing.expect(!simplePatternMatch(pat, "foo"));
    try std.testing.expect(!simplePatternMatch(pat, ""));
}

test "simplePatternMatch — C/C++ constants with leading underscores" {
    const pat = "^_*[A-Z][A-Z\\d_]*$";
    try std.testing.expect(simplePatternMatch(pat, "MAX_USERS"));
    try std.testing.expect(simplePatternMatch(pat, "_FOO"));
    try std.testing.expect(simplePatternMatch(pat, "__BAR"));
    try std.testing.expect(simplePatternMatch(pat, "A"));
    try std.testing.expect(simplePatternMatch(pat, "_A"));
    try std.testing.expect(simplePatternMatch(pat, "HELLO123"));
    try std.testing.expect(!simplePatternMatch(pat, "getWindowGroup")); // lowercase
    try std.testing.expect(!simplePatternMatch(pat, "window"));
    try std.testing.expect(!simplePatternMatch(pat, "Foo")); // mixed case
    try std.testing.expect(!simplePatternMatch(pat, ""));
    try std.testing.expect(!simplePatternMatch(pat, "_")); // only underscore, no uppercase
    try std.testing.expect(!simplePatternMatch(pat, "_foo")); // lowercase after underscore
}

test "simplePatternMatch — Go builtins" {
    const pat = "^(append|cap|close|complex|copy|delete|imag|len|make|new|panic|print|println|real|recover)$";
    try std.testing.expect(simplePatternMatch(pat, "append"));
    try std.testing.expect(simplePatternMatch(pat, "len"));
    try std.testing.expect(simplePatternMatch(pat, "recover"));
    try std.testing.expect(!simplePatternMatch(pat, "foo"));
    try std.testing.expect(!simplePatternMatch(pat, "appendx"));
}

test "simplePatternMatch — bash flags (^-)" {
    const pat = "^-";
    try std.testing.expect(simplePatternMatch(pat, "-f"));
    try std.testing.expect(simplePatternMatch(pat, "--verbose"));
    try std.testing.expect(simplePatternMatch(pat, "-Doptimize=ReleaseFast"));
    try std.testing.expect(!simplePatternMatch(pat, "build"));
    try std.testing.expect(!simplePatternMatch(pat, "test"));
    try std.testing.expect(!simplePatternMatch(pat, ""));
}

test "simplePatternMatch — shebang (^#!)" {
    const pat = "^#![ \\t]*/";
    try std.testing.expect(simplePatternMatch(pat, "#!/bin/bash"));
    try std.testing.expect(simplePatternMatch(pat, "#! /usr/bin/env bash"));
    try std.testing.expect(!simplePatternMatch(pat, "# regular comment"));
    try std.testing.expect(!simplePatternMatch(pat, "#!not-a-path"));
    try std.testing.expect(!simplePatternMatch(pat, ""));
}

test "simplePatternMatch — unknown patterns return false (conservative)" {
    // Unknown patterns must NOT match — permissive `return true` causes
    // later captures (e.g. @constant.builtin) to silently override earlier
    // ones (e.g. @function), breaking highlighting for entire languages.
    try std.testing.expect(!simplePatternMatch("^some_unknown_regex$", "anything"));
    try std.testing.expect(!simplePatternMatch("^[a-z]+_[a-z]+$", "foo_bar"));
    try std.testing.expect(!simplePatternMatch("^\\w+$", "hello"));
}
