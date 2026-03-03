const std = @import("std");
const ts = @import("tree_sitter");
const json = @import("../json_utils.zig");

const Allocator = std.mem.Allocator;
const Value = json.Value;
const ObjectMap = json.ObjectMap;

pub fn extractSymbols(
    allocator: Allocator,
    query: *const ts.Query,
    tree: *const ts.Tree,
    source: []const u8,
    file_path: []const u8,
) !Value {
    const cursor = ts.QueryCursor.create();
    defer cursor.destroy();

    cursor.exec(query, tree.rootNode());

    var symbols = std.json.Array.init(allocator);

    while (cursor.nextMatch()) |match| {
        var name_text: ?[]const u8 = null;
        var kind: ?[]const u8 = null;
        var outer_node: ?ts.Node = null;

        for (match.captures) |cap| {
            const cap_name = query.captureNameForId(cap.index) orelse continue;

            if (std.mem.eql(u8, cap_name, "name")) {
                name_text = nodeText(cap.node, source);
            } else if (captureToKind(cap_name)) |k| {
                kind = k;
                outer_node = cap.node;
            }
        }

        const name = name_text orelse continue;
        const k = kind orelse continue;
        const node = outer_node orelse continue;

        const start = node.startPoint();
        var sym = ObjectMap.init(allocator);
        try sym.put("name", json.jsonString(name));
        try sym.put("kind", json.jsonString(k));
        try sym.put("file", json.jsonString(file_path));
        try sym.put("selection_line", json.jsonInteger(@intCast(start.row)));
        try sym.put("selection_column", json.jsonInteger(@intCast(start.column)));
        try sym.put("end_line", json.jsonInteger(@intCast(node.endPoint().row)));
        try symbols.append(.{ .object = sym });
    }

    var result = ObjectMap.init(allocator);
    try result.put("symbols", .{ .array = symbols });
    return .{ .object = result };
}

/// Map tree-sitter capture name to LSP-style symbol kind.
fn captureToKind(cap_name: []const u8) ?[]const u8 {
    const map = .{
        .{ "function", "Function" },
        .{ "struct", "Struct" },
        .{ "class", "Class" },
        .{ "enum", "Enum" },
        .{ "union", "Union" },
        .{ "test", "Test" },
        .{ "method", "Method" },
        .{ "trait", "Interface" },
        .{ "interface", "Interface" },
        .{ "module", "Module" },
        .{ "macro", "Macro" },
        .{ "type", "Type" },
        .{ "type_alias", "Type" },
        .{ "variable", "Variable" },
        .{ "constant", "Constant" },
    };
    inline for (map) |entry| {
        if (std.mem.eql(u8, cap_name, entry[0])) return entry[1];
    }
    return null;
}

/// Extract document symbols for the picker outline view.
/// Returns `{items: [{label, detail, kind, depth, line, column}], mode: "symbol"}`.
/// Unlike `extractSymbols`, this function:
///   - Includes `@variable` captures (import declarations, type aliases) with detail text
///   - Expands struct/enum/union body as depth-1 container fields
pub fn extractPickerSymbols(
    allocator: Allocator,
    query: *const ts.Query,
    tree: *const ts.Tree,
    source: []const u8,
) !Value {
    const cursor = ts.QueryCursor.create();
    defer cursor.destroy();

    cursor.exec(query, tree.rootNode());

    var items = std.json.Array.init(allocator);
    // Track which impl blocks (by start row) have already been emitted as headers.
    var seen_impl_rows = std.AutoHashMap(u32, void).init(allocator);
    defer seen_impl_rows.deinit();

    while (cursor.nextMatch()) |match| {
        var name_text: ?[]const u8 = null;
        var detail_text: ?[]const u8 = null;
        var kind: ?[]const u8 = null;
        var outer_node: ?ts.Node = null;
        var name_node: ?ts.Node = null;
        var impl_type_node: ?ts.Node = null;
        var impl_type_text: ?[]const u8 = null;

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

        // For methods: emit a container header on first encounter, then indent at depth=1.
        var depth: i64 = 0;
        if (std.mem.eql(u8, k, "Method")) {
            if (impl_type_node) |inode| {
                const impl_node = inode.parent() orelse inode;
                const impl_row = impl_node.startPoint().row;
                if (!seen_impl_rows.contains(impl_row)) {
                    try seen_impl_rows.put(impl_row, {});
                    const itype_name = impl_type_text orelse "";
                    const prefix = containerPrefix(impl_node.kind());
                    const impl_hl = try buildItemHighlights(allocator, "Interface", prefix, itype_name, "");
                    const impl_start = impl_node.startPoint();
                    var hdr = ObjectMap.init(allocator);
                    try hdr.put("label", json.jsonString(itype_name));
                    try hdr.put("prefix", json.jsonString(prefix));
                    try hdr.put("detail", json.jsonString(""));
                    try hdr.put("kind", json.jsonString("Interface"));
                    try hdr.put("depth", json.jsonInteger(0));
                    try hdr.put("line", json.jsonInteger(@intCast(impl_start.row)));
                    try hdr.put("column", json.jsonInteger(@intCast(impl_start.column)));
                    try hdr.put("highlights", .{ .array = impl_hl });
                    try items.append(.{ .object = hdr });
                }
            }
            depth = 1;
        }

        const pos_node = name_node orelse node;
        const start = pos_node.startPoint();

        // Functions/Methods: prefix = "fn" / "pub fn" / … shown BEFORE the name.
        // Containers: detail = "struct {" / "pub enum {" shown after the name.
        // Variables/modules: detail = captured @detail text.
        var prefix_str: []const u8 = "";
        var effective_detail: []const u8 = "";
        if (std.mem.eql(u8, k, "Function") or std.mem.eql(u8, k, "Method")) {
            prefix_str = try buildFunctionDetail(allocator, node);
        } else if (std.mem.eql(u8, k, "Test")) {
            prefix_str = "test";
        } else if (std.mem.eql(u8, k, "Class")) {
            prefix_str = "class";
        } else if (std.mem.eql(u8, k, "Struct")) {
            effective_detail = try buildContainerDetail(allocator, node, "struct");
        } else if (std.mem.eql(u8, k, "Enum")) {
            effective_detail = try buildContainerDetail(allocator, node, "enum");
        } else if (std.mem.eql(u8, k, "Union")) {
            effective_detail = try buildContainerDetail(allocator, node, "union");
        } else {
            effective_detail = detail_text orelse "";
        }

        const highlights = try buildItemHighlights(allocator, k, prefix_str, name, effective_detail);

        var item = ObjectMap.init(allocator);
        try item.put("label", json.jsonString(name));
        try item.put("prefix", json.jsonString(prefix_str));
        try item.put("detail", json.jsonString(effective_detail));
        try item.put("kind", json.jsonString(k));
        try item.put("depth", json.jsonInteger(depth));
        try item.put("line", json.jsonInteger(@intCast(start.row)));
        try item.put("column", json.jsonInteger(@intCast(start.column)));
        try item.put("highlights", .{ .array = highlights });
        try items.append(.{ .object = item });

        // Expand container fields (depth=1) for struct/enum/union.
        if (std.mem.eql(u8, k, "Struct") or
            std.mem.eql(u8, k, "Enum") or
            std.mem.eql(u8, k, "Union"))
        {
            try appendContainerFields(allocator, node, source, &items);
        }
    }

    var result = ObjectMap.init(allocator);
    try result.put("items", .{ .array = items });
    try result.put("mode", json.jsonString("symbol"));
    return .{ .object = result };
}

/// Build the detail string for a function declaration.
/// Collects keyword modifiers (pub, inline, noinline, extern, export) that
/// appear before "fn" as direct (anonymous) children of `decl_node`.
/// Examples: "fn", "pub fn", "pub inline fn".
fn buildFunctionDetail(alloc: Allocator, decl_node: ts.Node) ![]const u8 {
    var parts = std.ArrayListUnmanaged([]const u8){};
    defer parts.deinit(alloc);

    var ci: u32 = 0;
    while (ci < decl_node.childCount()) : (ci += 1) {
        const child = decl_node.child(ci) orelse continue;
        const ck = child.kind();
        if (std.mem.eql(u8, ck, "pub") or
            std.mem.eql(u8, ck, "inline") or
            std.mem.eql(u8, ck, "noinline") or
            std.mem.eql(u8, ck, "extern") or
            std.mem.eql(u8, ck, "export"))
        {
            try parts.append(alloc, ck);
        } else if (std.mem.eql(u8, ck, "fn")) {
            try parts.append(alloc, "fn");
            break;
        }
    }
    return std.mem.join(alloc, " ", parts.items);
}

/// Build "struct {" / "pub struct {" etc. for a variable_declaration node.
/// Checks whether the declaration has a "pub" anonymous child before the name.
fn buildContainerDetail(alloc: Allocator, decl_node: ts.Node, type_kw: []const u8) ![]const u8 {
    var ci: u32 = 0;
    while (ci < decl_node.childCount()) : (ci += 1) {
        const child = decl_node.child(ci) orelse continue;
        if (std.mem.eql(u8, child.kind(), "pub")) {
            return std.fmt.allocPrint(alloc, "pub {s} {{", .{type_kw});
        }
        // The first named child is the identifier (name); stop scanning after it.
        if (child.isNamed()) break;
    }
    return std.fmt.allocPrint(alloc, "{s} {{", .{type_kw});
}

/// Append depth-1 container_field entries from a struct/enum/union declaration.
/// `decl_node` is the `variable_declaration` wrapping the body.
fn appendContainerFields(
    allocator: Allocator,
    decl_node: ts.Node,
    source: []const u8,
    items: *std.json.Array,
) !void {
    // Find the struct/enum/union_declaration child of variable_declaration.
    var ci: u32 = 0;
    while (ci < decl_node.namedChildCount()) : (ci += 1) {
        const body = decl_node.namedChild(ci) orelse continue;
        const bk = body.kind();
        const is_container =
            std.mem.eql(u8, bk, "struct_declaration") or
            std.mem.eql(u8, bk, "enum_declaration") or
            std.mem.eql(u8, bk, "union_declaration");
        if (!is_container) continue;

        var fi: u32 = 0;
        while (fi < body.namedChildCount()) : (fi += 1) {
            const field = body.namedChild(fi) orelse continue;
            if (!std.mem.eql(u8, field.kind(), "container_field")) continue;

            // `name:` is the named field in tree-sitter-zig grammar.
            const fname_node = field.childByFieldName("name") orelse
                field.namedChild(0) orelse
                continue;
            const fname = nodeText(fname_node, source) orelse continue;
            const fstart = fname_node.startPoint();

            const field_highlights = try buildItemHighlights(allocator, "Field", "", fname, "");
            var fitem = ObjectMap.init(allocator);
            try fitem.put("label", json.jsonString(fname));
            try fitem.put("prefix", json.jsonString(""));
            try fitem.put("detail", json.jsonString(""));
            try fitem.put("kind", json.jsonString("Field"));
            try fitem.put("depth", json.jsonInteger(1));
            try fitem.put("line", json.jsonInteger(@intCast(fstart.row)));
            try fitem.put("column", json.jsonInteger(@intCast(fstart.column)));
            try fitem.put("highlights", .{ .array = field_highlights });
            try items.append(.{ .object = fitem });
        }
        break; // Only one body declaration expected per variable_declaration.
    }
}

/// Return the keyword prefix for a container node (impl block, class, etc.).
fn containerPrefix(node_kind: []const u8) []const u8 {
    if (std.mem.eql(u8, node_kind, "impl_item")) return "impl";
    if (std.mem.eql(u8, node_kind, "class_definition")) return "class";
    return "";
}

fn nodeText(node: ts.Node, source: []const u8) ?[]const u8 {
    const start = node.startByte();
    const end = node.endByte();
    if (start >= source.len or end > source.len) return null;
    return source[start..end];
}

/// Map symbol kind to the Vim highlight group used for the symbol name.
fn kindToNameHlGroup(k: []const u8) []const u8 {
    if (std.mem.eql(u8, k, "Function")) return "YacTsFunction";
    if (std.mem.eql(u8, k, "Method")) return "YacTsFunctionMethod";
    if (std.mem.eql(u8, k, "Struct") or
        std.mem.eql(u8, k, "Class") or
        std.mem.eql(u8, k, "Interface") or
        std.mem.eql(u8, k, "Enum") or
        std.mem.eql(u8, k, "Union") or
        std.mem.eql(u8, k, "Type") or
        std.mem.eql(u8, k, "TypeParameter")) return "YacTsType";
    if (std.mem.eql(u8, k, "Variable")) return "YacTsVariable";
    if (std.mem.eql(u8, k, "Constant")) return "YacTsConstant";
    if (std.mem.eql(u8, k, "Field") or
        std.mem.eql(u8, k, "Property") or
        std.mem.eql(u8, k, "EnumMember")) return "YacTsVariableMember";
    if (std.mem.eql(u8, k, "Module") or std.mem.eql(u8, k, "Namespace")) return "YacTsModule";
    if (std.mem.eql(u8, k, "Test")) return "YacTsString";
    return "";
}

/// Build the highlights array for one picker item.
/// `col` values are 0-based byte offsets from the start of rendered content
/// (i.e. after the indent prefix added by Vim).
/// Rendered content layout:
///   - if prefix non-empty:  prefix + " " + name
///   - else if detail non-empty: name + " " + detail
///   - else: name
fn buildItemHighlights(
    alloc: Allocator,
    k: []const u8,
    prefix: []const u8,
    name: []const u8,
    detail: []const u8,
) !std.json.Array {
    var highlights = std.json.Array.init(alloc);

    if (prefix.len > 0) {
        // Prefix (fn / pub fn / …) gets keyword-function color.
        var h = ObjectMap.init(alloc);
        try h.put("col", json.jsonInteger(0));
        try h.put("len", json.jsonInteger(@intCast(prefix.len)));
        try h.put("hl", json.jsonString("YacTsKeywordFunction"));
        try highlights.append(.{ .object = h });

        // Name comes after prefix + space.
        const name_hl = kindToNameHlGroup(k);
        if (name_hl.len > 0) {
            const name_col: i64 = @intCast(prefix.len + 1);
            var h2 = ObjectMap.init(alloc);
            try h2.put("col", json.jsonInteger(name_col));
            try h2.put("len", json.jsonInteger(@intCast(name.len)));
            try h2.put("hl", json.jsonString(name_hl));
            try highlights.append(.{ .object = h2 });
        }
    } else {
        // Name at position 0.
        const name_hl = kindToNameHlGroup(k);
        if (name_hl.len > 0) {
            var h = ObjectMap.init(alloc);
            try h.put("col", json.jsonInteger(0));
            try h.put("len", json.jsonInteger(@intCast(name.len)));
            try h.put("hl", json.jsonString(name_hl));
            try highlights.append(.{ .object = h });
        }

        // Detail (e.g. "struct {", "@import(…)") comes after name + space, dimmed.
        if (detail.len > 0) {
            const detail_col: i64 = @intCast(name.len + 1);
            var h = ObjectMap.init(alloc);
            try h.put("col", json.jsonInteger(detail_col));
            try h.put("len", json.jsonInteger(@intCast(detail.len)));
            try h.put("hl", json.jsonString("YacPickerDetail"));
            try highlights.append(.{ .object = h });
        }
    }

    return highlights;
}
