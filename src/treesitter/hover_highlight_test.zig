const std = @import("std");
const md_parser = @import("markdown_parser.zig");

// Note: extractHoverHighlights integration tests require TreeSitter with std.Io
// and are not included here as they depend on the async runtime (pre-existing
// API mismatch with TreeSitter.init which now requires std.Io parameter).

test "normalizeLang" {
    try std.testing.expectEqualStrings("rust", md_parser.normalizeLang("rs"));
    try std.testing.expectEqualStrings("python", md_parser.normalizeLang("py"));
    try std.testing.expectEqualStrings("typescript", md_parser.normalizeLang("ts"));
    try std.testing.expectEqualStrings("javascript", md_parser.normalizeLang("js"));
    try std.testing.expectEqualStrings("cpp", md_parser.normalizeLang("c++"));
    try std.testing.expectEqualStrings("zig", md_parser.normalizeLang("zig"));
    try std.testing.expectEqualStrings("go", md_parser.normalizeLang("go"));
    try std.testing.expectEqualStrings("", md_parser.normalizeLang(""));
}

test "parseMarkdown basic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const md =
        \\# Hello
        \\
        \\Some text here.
        \\
        \\```zig
        \\const x = 5;
        \\```
        \\
        \\More text.
    ;
    const result = try md_parser.parseMarkdown(arena.allocator(), md);

    try std.testing.expectEqual(@as(usize, 1), result.blocks.items.len);
    try std.testing.expectEqualStrings("zig", result.blocks.items[0].lang);
    try std.testing.expectEqualStrings("const x = 5;", result.blocks.items[0].content);

    var found_hello = false;
    for (result.lines.items) |line| {
        if (std.mem.eql(u8, line, "Hello")) found_hello = true;
    }
    try std.testing.expect(found_hello);
}

test "parseMarkdown multiple blocks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const md =
        \\```rs
        \\fn main() {}
        \\```
        \\
        \\```py
        \\def foo():
        \\    pass
        \\```
    ;
    const result = try md_parser.parseMarkdown(arena.allocator(), md);

    try std.testing.expectEqual(@as(usize, 2), result.blocks.items.len);
    try std.testing.expectEqualStrings("rust", result.blocks.items[0].lang);
    try std.testing.expectEqualStrings("fn main() {}", result.blocks.items[0].content);
    try std.testing.expectEqualStrings("python", result.blocks.items[1].lang);
    try std.testing.expectEqualStrings("def foo():\n    pass", result.blocks.items[1].content);
}

test "parseMarkdown no language" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const md =
        \\```
        \\some code
        \\```
    ;
    const result = try md_parser.parseMarkdown(arena.allocator(), md);

    try std.testing.expectEqual(@as(usize, 1), result.blocks.items.len);
    try std.testing.expectEqualStrings("", result.blocks.items[0].lang);
}

test "parseMarkdown trailing text after blocks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const md =
        \\```zig
        \\const x = 1;
        \\```
        \\
        \\More text.
    ;
    const result = try md_parser.parseMarkdown(arena.allocator(), md);

    try std.testing.expectEqual(@as(usize, 1), result.blocks.items.len);
    try std.testing.expectEqualStrings("const x = 1;", result.blocks.items[0].content);

    var found_more = false;
    for (result.lines.items) |line| {
        if (std.mem.eql(u8, line, "More text.")) found_more = true;
    }
    try std.testing.expect(found_more);
}

test "parseMarkdown tilde fence" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const md =
        \\~~~python
        \\print("hello")
        \\~~~
    ;
    const result = try md_parser.parseMarkdown(arena.allocator(), md);

    try std.testing.expectEqual(@as(usize, 1), result.blocks.items.len);
    try std.testing.expectEqualStrings("python", result.blocks.items[0].lang);
    try std.testing.expectEqualStrings("print(\"hello\")", result.blocks.items[0].content);
}

test "parseMarkdown indented code block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const md =
        \\Some text.
        \\
        \\    indented code
        \\    more code
        \\
        \\After.
    ;
    const result = try md_parser.parseMarkdown(arena.allocator(), md);

    try std.testing.expectEqual(@as(usize, 1), result.blocks.items.len);
    try std.testing.expectEqualStrings("", result.blocks.items[0].lang);
}

test "parseMarkdown horizontal rule" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const md =
        \\Before
        \\
        \\---
        \\
        \\After
    ;
    const result = try md_parser.parseMarkdown(arena.allocator(), md);

    var found_before = false;
    var found_after = false;
    var found_empty = false;
    for (result.lines.items) |line| {
        if (std.mem.eql(u8, line, "Before")) found_before = true;
        if (std.mem.eql(u8, line, "After")) found_after = true;
        if (line.len == 0) found_empty = true;
    }
    try std.testing.expect(found_before);
    try std.testing.expect(found_after);
    try std.testing.expect(found_empty);
}

test "parseMarkdown blank line between code block and doc text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const md =
        \\```zig
        \\fn foo() void
        \\```
        \\
        \\Documentation text.
    ;
    const result = try md_parser.parseMarkdown(arena.allocator(), md);

    try std.testing.expectEqual(@as(usize, 3), result.lines.items.len);
    try std.testing.expectEqualStrings("fn foo() void", result.lines.items[0]);
    try std.testing.expectEqualStrings("", result.lines.items[1]);
    try std.testing.expectEqualStrings("Documentation text.", result.lines.items[2]);
}

test "parseMarkdown pytest.fixture hover crash" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const md =
        \\```python
        \\    fixture_function: None = ...,
        \\    *,
        \\    scope: _ScopeName | ((str, Config) -> _ScopeName) = ...,
        \\    params: Iterable[object] | None = ...,
        \\    autouse: bool = ...,
        \\    ids: Sequence[object | None] | ((Any) -> (object | None)) | None = ...,
        \\    name: str | None = None
        \\) -> FixtureFunctionMarker
        \\```
        \\
        \\Decorator to mark a fixture factory function.
        \\
        \\``pytest.mark.usefixtures(fixturename)`` marker.
        \\
        \\:param scope:
        \\    one of ``"function"`` (default), ``"class"``, ``"module"``.
        \\
        \\:param name:
        \\    The name of the fixture.
    ;
    const result = try md_parser.parseMarkdown(arena.allocator(), md);

    try std.testing.expect(result.lines.items.len > 0);
    try std.testing.expect(result.blocks.items.len > 0);
}
