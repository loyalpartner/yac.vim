const std = @import("std");
const Allocator = std.mem.Allocator;

const max_results = 50;

// ============================================================================
// Fuzzy matching — scoring + filtering + sorting
//
// Ported from src/picker.zig to yacd picker module.
// ============================================================================

pub fn fuzzyScore(text: []const u8, pattern: []const u8) i32 {
    if (pattern.len == 0) return 1000;
    if (pattern.len > text.len) return 0;

    const basename_start = if (std.mem.lastIndexOfScalar(u8, text, '/')) |pos| pos + 1 else 0;
    const basename = text[basename_start..];

    // Exact basename match
    if (std.mem.eql(u8, basename, pattern)) return 10000;

    // Case-sensitive prefix
    if (std.mem.startsWith(u8, basename, pattern))
        return 5000 + @as(i32, @intCast(@min(basename.len, 999)));

    // Case-insensitive prefix
    if (startsWithIgnoreCase(basename, pattern))
        return 2000 + @as(i32, @intCast(@min(basename.len, 999)));

    // Subsequence matching with boundary/camelCase bonuses
    var score: i32 = 100;
    var ti: usize = 0;
    var prev_match: ?usize = null;
    for (pattern) |pc| {
        const plower = std.ascii.toLower(pc);
        while (ti < text.len) : (ti += 1) {
            if (std.ascii.toLower(text[ti]) == plower) {
                if (prev_match) |pm| {
                    if (ti == pm + 1) score += 100; // consecutive
                }
                if (ti > 0 and isBoundary(text[ti - 1])) score += 80;
                if (ti > 0 and std.ascii.isLower(text[ti - 1]) and std.ascii.isUpper(text[ti])) score += 60;
                if (ti == basename_start) score += 150;
                score -= @as(i32, @intCast(@min(ti, 50))); // position penalty
                prev_match = ti;
                ti += 1;
                break;
            }
        } else return 0; // pattern char not found
    }
    return @max(score, 1);
}

const ScoredEntry = struct {
    index: usize,
    score: i32,
};

/// Fuzzy-filter and sort items by score. MRU files in `boost_files` get a
/// +5000 score boost so they rank higher among equal-quality matches.
pub fn filterAndSort(
    allocator: Allocator,
    items: []const []const u8,
    pattern: []const u8,
    boost_files: []const []const u8,
) ![]const usize {
    var scored: std.ArrayList(ScoredEntry) = .empty;
    defer scored.deinit(allocator);

    for (items, 0..) |item, i| {
        const score = fuzzyScore(item, pattern);
        if (score > 0) {
            const boost: i32 = for (boost_files) |rf| {
                if (std.mem.eql(u8, rf, item)) break 5000;
            } else 0;
            try scored.append(allocator, .{ .index = i, .score = score + boost });
        }
    }

    std.mem.sort(ScoredEntry, scored.items, {}, struct {
        fn cmp(_: void, a: ScoredEntry, b: ScoredEntry) bool {
            return a.score > b.score;
        }
    }.cmp);

    const count = @min(scored.items.len, max_results);
    const result = try allocator.alloc(usize, count);
    for (result, 0..) |*r, i| {
        r.* = scored.items[i].index;
    }
    return result;
}

fn startsWithIgnoreCase(text: []const u8, prefix: []const u8) bool {
    if (prefix.len > text.len) return false;
    for (text[0..prefix.len], prefix) |a, b| {
        if (std.ascii.toLower(a) != std.ascii.toLower(b)) return false;
    }
    return true;
}

fn isBoundary(c: u8) bool {
    return c == '/' or c == '_' or c == '-' or c == '.';
}

// ============================================================================
// Tests
// ============================================================================

test "fuzzyScore - exact basename match" {
    try std.testing.expect(fuzzyScore("src/main.zig", "main.zig") == 10000);
}

test "fuzzyScore - prefix match" {
    const score = fuzzyScore("src/main.zig", "main");
    try std.testing.expect(score >= 5000);
}

test "fuzzyScore - subsequence match" {
    const score = fuzzyScore("src/lsp_client.zig", "lc");
    try std.testing.expect(score > 0);
    try std.testing.expect(score < 2000);
}

test "fuzzyScore - no match" {
    try std.testing.expect(fuzzyScore("src/main.zig", "xyz") == 0);
}

test "fuzzyScore - empty pattern matches everything" {
    try std.testing.expect(fuzzyScore("anything", "") == 1000);
}

test "fuzzyScore - case insensitive prefix" {
    const score = fuzzyScore("src/Main.zig", "main");
    try std.testing.expect(score >= 2000);
    try std.testing.expect(score < 5000);
}

test "fuzzyScore - boundary bonus" {
    // '_c' should match at boundary in 'lsp_client.zig'
    const score = fuzzyScore("src/lsp_client.zig", "lc");
    try std.testing.expect(score > 0);
}

test "filterAndSort - results sorted by descending score" {
    const alloc = std.testing.allocator;
    const items: []const []const u8 = &.{ "src/utils.zig", "src/main.zig", "src/picker.zig" };
    const boost_files: []const []const u8 = &.{};
    const indices = try filterAndSort(alloc, items, "main", boost_files);
    defer alloc.free(indices);
    // "main.zig" should be first
    try std.testing.expectEqual(@as(usize, 1), indices[0]);
    for (0..indices.len - 1) |i| {
        const score_a = fuzzyScore(items[indices[i]], "main");
        const score_b = fuzzyScore(items[indices[i + 1]], "main");
        try std.testing.expect(score_a >= score_b);
    }
}

test "filterAndSort - MRU boost ranks boosted items higher" {
    const alloc = std.testing.allocator;
    const items: []const []const u8 = &.{ "src/aaa.zig", "src/bbb.zig", "src/ccc.zig" };
    const boost_files: []const []const u8 = &.{"src/ccc.zig"};
    const indices = try filterAndSort(alloc, items, "zig", boost_files);
    defer alloc.free(indices);
    try std.testing.expect(indices.len >= 3);
    try std.testing.expectEqual(@as(usize, 2), indices[0]);
}

test "filterAndSort - empty pattern returns results" {
    const alloc = std.testing.allocator;
    const items: []const []const u8 = &.{ "src/a.zig", "src/b.zig", "src/c.zig" };
    const boost_files: []const []const u8 = &.{"src/b.zig"};
    const indices = try filterAndSort(alloc, items, "", boost_files);
    defer alloc.free(indices);
    try std.testing.expect(indices.len == 3);
    try std.testing.expectEqual(@as(usize, 1), indices[0]);
}
