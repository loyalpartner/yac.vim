const std = @import("std");
const ts = @import("tree_sitter");
const picker_source = @import("../picker/source.zig");

const Allocator = std.mem.Allocator;
const PickerItem = picker_source.PickerItem;
const PickerHighlight = picker_source.PickerHighlight;

// ============================================================================
// Outline — extract document symbols from a parsed tree using outline.scm
//
// Captures: @name, @function/@struct/@enum/... (kind), @detail, @impl_type.
// ============================================================================

/// Extract symbols for the picker document_symbol mode.
pub fn extractOutline(
    allocator: Allocator,
    query: *const ts.Query,
    tree: *const ts.Tree,
    source: []const u8,
    file_path: []const u8,
) ![]const PickerItem {
    var b = OutlineBuilder.init(allocator, source, file_path);
    defer b.deinit();

    const cursor = ts.QueryCursor.create();
    defer cursor.destroy();
    cursor.setMatchLimit(256);
    cursor.exec(query, tree.rootNode());

    while (cursor.nextMatch()) |match| {
        var name_text: ?[]const u8 = null;
        var name_node: ?ts.Node = null;
        var detail_text: ?[]const u8 = null;
        var kind: ?[]const u8 = null;
        var outer_node: ?ts.Node = null;
        var impl_type_text: ?[]const u8 = null;
        var impl_type_node: ?ts.Node = null;

        for (match.captures) |cap| {
            const cap_name = query.captureNameForId(cap.index) orelse continue;
            if (std.mem.eql(u8, cap_name, "name")) {
                name_text = nodeText(cap.node, source);
                name_node = cap.node;
            } else if (std.mem.eql(u8, cap_name, "detail")) {
                detail_text = nodeText(cap.node, source);
            } else if (std.mem.eql(u8, cap_name, "impl_type")) {
                impl_type_node = cap.node;
                impl_type_text = nodeText(cap.node, source);
            } else if (captureToKind(cap_name)) |k| {
                kind = k;
                outer_node = cap.node;
            }
        }

        const name = name_text orelse continue;
        const k = kind orelse continue;
        const node = outer_node orelse continue;

        var depth: i32 = 0;

        // Methods: emit container header on first encounter, indent at depth=1
        if (std.mem.eql(u8, k, "Method")) {
            if (impl_type_node) |inode| {
                try b.emitContainerHeader(inode, impl_type_text orelse "");
            }
            depth = 1;
        }

        // Markdown heading depth: H1→0, H2→1, …
        if (std.mem.eql(u8, node.kind(), "atx_heading")) {
            if (node.namedChild(0)) |marker| {
                const mk = marker.kind();
                if (mk.len > 5 and mk[4] == 'h') {
                    depth = @intCast(mk[5] - '1');
                }
            }
        }

        const pos = (name_node orelse node).startPoint();
        const prefix = symbolPrefix(k, node);
        const detail = symbolDetail(k, node, detail_text, b.alloc) catch "";

        try b.addSymbol(name, k, pos, depth, prefix, detail);

        // Expand container fields at depth=1 and record container row
        // so emitContainerHeader (from @method matches) won't duplicate it.
        if (std.mem.eql(u8, k, "Struct") or
            std.mem.eql(u8, k, "Enum") or
            std.mem.eql(u8, k, "Union"))
        {
            try b.seen_containers.put(node.startPoint().row, {});
            try b.addContainerFields(node);
        }
    }

    return b.finish();
}

// ============================================================================
// OutlineBuilder — accumulates picker items with shared context
// ============================================================================

const OutlineBuilder = struct {
    alloc: Allocator,
    items: std.ArrayList(PickerItem),
    source: []const u8,
    file: []const u8,
    seen_containers: std.AutoHashMap(u32, void),

    fn init(allocator: Allocator, source: []const u8, file: []const u8) OutlineBuilder {
        return .{
            .alloc = allocator,
            .items = .empty,
            .source = source,
            .file = file,
            .seen_containers = std.AutoHashMap(u32, void).init(allocator),
        };
    }

    fn deinit(self: *OutlineBuilder) void {
        self.seen_containers.deinit();
    }

    fn addSymbol(self: *OutlineBuilder, name: []const u8, kind: []const u8, pos: ts.Point, depth: i32, prefix: []const u8, detail: []const u8) !void {
        try self.items.append(self.alloc, .{
            .label = try buildLabel(self.alloc, prefix, name, detail),
            .file = self.file,
            .line = @intCast(pos.row),
            .column = @intCast(pos.column),
            .depth = depth,
            .kind = kind,
            .highlights = try buildHighlights(self.alloc, kind, prefix, name, detail),
        });
    }

    fn emitContainerHeader(self: *OutlineBuilder, impl_type_node: ts.Node, type_name: []const u8) !void {
        const container = impl_type_node.parent() orelse impl_type_node;
        const row = container.startPoint().row;
        if (self.seen_containers.contains(row)) return;
        try self.seen_containers.put(row, {});

        const prefix = containerPrefix(container.kind());
        const pos = container.startPoint();
        try self.addSymbol(type_name, "Interface", pos, 0, prefix, "");
    }

    fn addContainerFields(self: *OutlineBuilder, decl_node: ts.Node) !void {
        var ci: u32 = 0;
        while (ci < decl_node.namedChildCount()) : (ci += 1) {
            const body = decl_node.namedChild(ci) orelse continue;
            const bk = body.kind();
            if (!std.mem.eql(u8, bk, "struct_declaration") and
                !std.mem.eql(u8, bk, "enum_declaration") and
                !std.mem.eql(u8, bk, "union_declaration")) continue;

            var fi: u32 = 0;
            while (fi < body.namedChildCount()) : (fi += 1) {
                const field = body.namedChild(fi) orelse continue;
                if (!std.mem.eql(u8, field.kind(), "container_field")) continue;
                const fname_node = field.childByFieldName("name") orelse
                    field.namedChild(0) orelse continue;
                const fname = nodeText(fname_node, self.source) orelse continue;
                const fstart = fname_node.startPoint();
                try self.addSymbol(fname, "Field", fstart, 1, "", "");
            }
            break;
        }
    }

    fn finish(self: *OutlineBuilder) []const PickerItem {
        return self.items.items;
    }
};

// ============================================================================
// Symbol metadata — prefix/detail from AST structure
// ============================================================================

fn symbolPrefix(kind: []const u8, node: ts.Node) []const u8 {
    if (std.mem.eql(u8, kind, "Test")) return "test";
    if (std.mem.eql(u8, kind, "Class")) return "class";
    if (std.mem.eql(u8, kind, "Function") or std.mem.eql(u8, kind, "Method")) {
        // Collect modifiers before "fn": pub, inline, extern, etc.
        // Allocates — but caller uses arena so it's fine.
        return collectFunctionPrefix(node);
    }
    return "";
}

fn symbolDetail(kind: []const u8, node: ts.Node, detail_text: ?[]const u8, alloc: Allocator) ![]const u8 {
    if (std.mem.eql(u8, kind, "Struct")) return try containerDetail(alloc, node, "struct");
    if (std.mem.eql(u8, kind, "Enum")) return try containerDetail(alloc, node, "enum");
    if (std.mem.eql(u8, kind, "Union")) return try containerDetail(alloc, node, "union");
    return detail_text orelse "";
}

/// "fn", "pub fn", "pub inline fn", etc.
fn collectFunctionPrefix(decl_node: ts.Node) []const u8 {
    // Fast path: check first few children for known keywords.
    // Returns a static string for common cases to avoid allocation.
    var has_pub = false;
    var ci: u32 = 0;
    while (ci < decl_node.childCount()) : (ci += 1) {
        const child = decl_node.child(ci) orelse continue;
        const ck = child.kind();
        if (std.mem.eql(u8, ck, "pub")) {
            has_pub = true;
        } else if (std.mem.eql(u8, ck, "fn")) {
            return if (has_pub) "pub fn" else "fn";
        } else if (std.mem.eql(u8, ck, "inline") or
            std.mem.eql(u8, ck, "noinline") or
            std.mem.eql(u8, ck, "extern") or
            std.mem.eql(u8, ck, "export"))
        {
            // Rare modifiers — fall back to simple prefix
            return if (has_pub) "pub fn" else "fn";
        }
    }
    return "fn";
}

/// "struct {", "pub struct {", etc.
fn containerDetail(alloc: Allocator, decl_node: ts.Node, type_kw: []const u8) ![]const u8 {
    var ci: u32 = 0;
    while (ci < decl_node.childCount()) : (ci += 1) {
        const child = decl_node.child(ci) orelse continue;
        if (std.mem.eql(u8, child.kind(), "pub")) {
            return std.fmt.allocPrint(alloc, "pub {s} {{", .{type_kw});
        }
        if (child.isNamed()) break;
    }
    return std.fmt.allocPrint(alloc, "{s} {{", .{type_kw});
}

// ============================================================================
// Label + highlights construction
// ============================================================================

fn buildLabel(alloc: Allocator, prefix: []const u8, name: []const u8, detail: []const u8) ![]const u8 {
    if (prefix.len > 0) return std.fmt.allocPrint(alloc, "{s} {s}", .{ prefix, name });
    if (detail.len > 0) return std.fmt.allocPrint(alloc, "{s}  {s}", .{ name, detail });
    return alloc.dupe(u8, name);
}

fn buildHighlights(alloc: Allocator, kind: []const u8, prefix: []const u8, name: []const u8, detail: []const u8) ![]const PickerHighlight {
    var hl: std.ArrayList(PickerHighlight) = .empty;
    if (prefix.len > 0) {
        try hl.append(alloc, .{ .col = 0, .len = @intCast(prefix.len), .hl = "YacTsKeywordFunction" });
        const g = kindToHlGroup(kind);
        if (g.len > 0) try hl.append(alloc, .{ .col = @intCast(prefix.len + 1), .len = @intCast(name.len), .hl = g });
    } else {
        const g = kindToHlGroup(kind);
        if (g.len > 0) try hl.append(alloc, .{ .col = 0, .len = @intCast(name.len), .hl = g });
        if (detail.len > 0) try hl.append(alloc, .{ .col = @intCast(name.len + 2), .len = @intCast(detail.len), .hl = "YacPickerDetail" });
    }
    return hl.items;
}

// ============================================================================
// Mappings
// ============================================================================

fn nodeText(node: ts.Node, source: []const u8) ?[]const u8 {
    const start = node.startByte();
    const end = node.endByte();
    if (start >= source.len or end > source.len) return null;
    return source[start..end];
}

fn captureToKind(cap_name: []const u8) ?[]const u8 {
    const map = .{
        .{ "function", "Function" },   .{ "struct", "Struct" },
        .{ "class", "Class" },         .{ "enum", "Enum" },
        .{ "union", "Union" },         .{ "test", "Test" },
        .{ "method", "Method" },       .{ "trait", "Interface" },
        .{ "interface", "Interface" }, .{ "module", "Module" },
        .{ "namespace", "Namespace" }, .{ "macro", "Macro" },
        .{ "typedef", "Type" },        .{ "type", "Type" },
        .{ "type_alias", "Type" },     .{ "variable", "Variable" },
        .{ "field", "Field" },         .{ "constant", "Constant" },
    };
    inline for (map) |entry| {
        if (std.mem.eql(u8, cap_name, entry[0])) return entry[1];
    }
    return null;
}

fn kindToHlGroup(k: []const u8) []const u8 {
    if (std.mem.eql(u8, k, "Function")) return "YacTsFunction";
    if (std.mem.eql(u8, k, "Method")) return "YacTsFunctionMethod";
    if (std.mem.eql(u8, k, "Struct") or std.mem.eql(u8, k, "Class") or
        std.mem.eql(u8, k, "Interface") or std.mem.eql(u8, k, "Enum") or
        std.mem.eql(u8, k, "Union") or std.mem.eql(u8, k, "Type")) return "YacTsType";
    if (std.mem.eql(u8, k, "Variable")) return "YacTsVariable";
    if (std.mem.eql(u8, k, "Constant")) return "YacTsConstant";
    if (std.mem.eql(u8, k, "Field") or std.mem.eql(u8, k, "Property")) return "YacTsVariableMember";
    if (std.mem.eql(u8, k, "Module") or std.mem.eql(u8, k, "Namespace")) return "YacTsModule";
    if (std.mem.eql(u8, k, "Macro")) return "YacTsFunctionMacro";
    if (std.mem.eql(u8, k, "Test")) return "YacTsString";
    return "";
}

fn containerPrefix(node_kind: []const u8) []const u8 {
    if (std.mem.eql(u8, node_kind, "impl_item")) return "impl";
    if (std.mem.eql(u8, node_kind, "class_definition")) return "class";
    if (std.mem.eql(u8, node_kind, "class_specifier")) return "class";
    if (std.mem.eql(u8, node_kind, "namespace_definition")) return "namespace";
    return "";
}
