const std = @import("std");
const json = @import("../json_utils.zig");
const session_mod = @import("session.zig");

const Allocator = std.mem.Allocator;
const Value = json.Value;
const DapSession = session_mod.DapSession;
const CachedVariable = session_mod.CachedVariable;
const ChainStage = session_mod.ChainStage;
const VarList = session_mod.VarList;

// ============================================================================
// Mock builders
// ============================================================================

fn mockStackTraceBody(alloc: Allocator) !Value {
    var frames = std.json.Array.init(alloc);
    try frames.append(try json.buildObject(alloc, .{
        .{ "id", json.jsonInteger(1) },
        .{ "name", json.jsonString("main") },
        .{ "source", try json.buildObject(alloc, .{
            .{ "path", json.jsonString("/tmp/app.py") },
            .{ "name", json.jsonString("app.py") },
        }) },
        .{ "line", json.jsonInteger(10) },
        .{ "column", json.jsonInteger(1) },
    }));
    try frames.append(try json.buildObject(alloc, .{
        .{ "id", json.jsonInteger(2) },
        .{ "name", json.jsonString("helper") },
        .{ "source", try json.buildObject(alloc, .{
            .{ "path", json.jsonString("/tmp/util.py") },
            .{ "name", json.jsonString("util.py") },
        }) },
        .{ "line", json.jsonInteger(25) },
        .{ "column", json.jsonInteger(1) },
    }));
    return json.buildObject(alloc, .{
        .{ "stackFrames", .{ .array = frames } },
    });
}

fn mockScopesBody(alloc: Allocator, locals_ref: u32) !Value {
    var scopes = std.json.Array.init(alloc);
    try scopes.append(try json.buildObject(alloc, .{
        .{ "name", json.jsonString("Locals") },
        .{ "presentationHint", json.jsonString("locals") },
        .{ "variablesReference", json.jsonInteger(@intCast(locals_ref)) },
        .{ "expensive", .{ .bool = false } },
    }));
    try scopes.append(try json.buildObject(alloc, .{
        .{ "name", json.jsonString("Globals") },
        .{ "presentationHint", json.jsonString("globals") },
        .{ "variablesReference", json.jsonInteger(99) },
        .{ "expensive", .{ .bool = true } },
    }));
    return json.buildObject(alloc, .{
        .{ "scopes", .{ .array = scopes } },
    });
}

fn mockVariablesBody(alloc: Allocator) !Value {
    var vars = std.json.Array.init(alloc);
    try vars.append(try json.buildObject(alloc, .{
        .{ "name", json.jsonString("x") },
        .{ "value", json.jsonString("42") },
        .{ "type", json.jsonString("int") },
        .{ "variablesReference", json.jsonInteger(0) },
    }));
    try vars.append(try json.buildObject(alloc, .{
        .{ "name", json.jsonString("items") },
        .{ "value", json.jsonString("[1, 2, 3]") },
        .{ "type", json.jsonString("list") },
        .{ "variablesReference", json.jsonInteger(5) },
    }));
    try vars.append(try json.buildObject(alloc, .{
        .{ "name", json.jsonString("name") },
        .{ "value", json.jsonString("\"hello\"") },
        .{ "type", json.jsonString("str") },
        .{ "variablesReference", json.jsonInteger(0) },
    }));
    return json.buildObject(alloc, .{
        .{ "variables", .{ .array = vars } },
    });
}

fn testVar(name: []const u8, value: []const u8, var_type: []const u8, ref: u32) CachedVariable {
    return .{
        .name = std.testing.allocator.dupe(u8, name) catch "",
        .value = std.testing.allocator.dupe(u8, value) catch "",
        .var_type = std.testing.allocator.dupe(u8, var_type) catch "",
        .variables_reference = ref,
    };
}

fn initTestSession() DapSession {
    return .{
        .allocator = std.testing.allocator,
        .client = undefined,
        .var_cache = std.AutoHashMap(u32, VarList).init(std.testing.allocator),
    };
}

// ============================================================================
// Tests
// ============================================================================

test "DapSession: parseStackTrace caches frames" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var session = initTestSession();
    defer session.deinit();

    const body = try mockStackTraceBody(alloc);
    try session.parseStackTrace(body);

    try std.testing.expectEqual(@as(usize, 2), session.cached_frames.items.len);
    try std.testing.expectEqualStrings("main", session.cached_frames.items[0].name);
    try std.testing.expectEqualStrings("helper", session.cached_frames.items[1].name);
    try std.testing.expectEqual(@as(u32, 10), session.cached_frames.items[0].line);
    try std.testing.expectEqualStrings("/tmp/app.py", session.cached_frames.items[0].source_path);
    try std.testing.expectEqual(@as(?u32, 1), session.active_frame_id);
}

test "DapSession: parseScopesForLocals finds locals scope" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var session = initTestSession();
    defer session.deinit();

    const body = try mockScopesBody(alloc, 42);
    const ref = session.parseScopesForLocals(body);
    try std.testing.expectEqual(@as(?u32, 42), ref);
}

test "DapSession: parseScopesForLocals fallback to first scope" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var scopes = std.json.Array.init(alloc);
    try scopes.append(try json.buildObject(alloc, .{
        .{ "name", json.jsonString("Module") },
        .{ "variablesReference", json.jsonInteger(77) },
    }));
    const body = try json.buildObject(alloc, .{
        .{ "scopes", .{ .array = scopes } },
    });

    var session = initTestSession();
    defer session.deinit();

    const ref = session.parseScopesForLocals(body);
    try std.testing.expectEqual(@as(?u32, 77), ref);
}

test "DapSession: parseVariables and var_cache" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var session = initTestSession();
    defer session.deinit();

    session.locals_ref = 42;
    const body = try mockVariablesBody(alloc);
    try session.parseVariables(body);

    const cached = session.var_cache.get(42).?;
    try std.testing.expectEqual(@as(usize, 3), cached.items.len);
    try std.testing.expectEqualStrings("x", cached.items[0].name);
    try std.testing.expectEqualStrings("42", cached.items[0].value);
    try std.testing.expectEqual(@as(u32, 0), cached.items[0].variables_reference);
    try std.testing.expectEqualStrings("items", cached.items[1].name);
    try std.testing.expectEqual(@as(u32, 5), cached.items[1].variables_reference);
}

test "DapSession: clearCache resets all state" {
    var session = initTestSession();
    defer session.deinit();

    try session.cached_frames.append(std.testing.allocator, .{
        .id = 1,
        .name = try std.testing.allocator.dupe(u8, "test"),
        .source_path = "",
        .source_name = "",
        .line = 1,
        .column = 1,
    });
    session.active_frame_id = 1;
    session.locals_ref = 42;
    session.chain_stage = .awaiting_variables;

    session.clearCache();

    try std.testing.expectEqual(@as(usize, 0), session.cached_frames.items.len);
    try std.testing.expectEqual(@as(?u32, null), session.active_frame_id);
    try std.testing.expectEqual(@as(?u32, null), session.locals_ref);
    try std.testing.expectEqual(ChainStage.idle, session.chain_stage);
}

test "DapSession: resolvePathToRef" {
    var session = initTestSession();
    defer session.deinit();

    session.locals_ref = 42;

    var top_vars: VarList = .empty;
    try top_vars.append(std.testing.allocator, testVar("x", "42", "int", 0));
    try top_vars.append(std.testing.allocator, testVar("items", "[1,2,3]", "list", 5));
    try session.var_cache.put(42, top_vars);

    try std.testing.expectEqual(@as(?u32, 0), session.resolvePathToRef(&[_]u32{0}));
    try std.testing.expectEqual(@as(?u32, 5), session.resolvePathToRef(&[_]u32{1}));
    try std.testing.expectEqual(@as(?u32, null), session.resolvePathToRef(&[_]u32{2}));
    try std.testing.expectEqual(@as(?u32, null), session.resolvePathToRef(&[_]u32{}));
}

test "DapSession: watch add/remove" {
    var session = initTestSession();
    defer session.deinit();

    try session.addWatch("self.name");
    try session.addWatch("len(items)");
    try std.testing.expectEqual(@as(usize, 2), session.watch_expressions.items.len);
    try std.testing.expectEqualStrings("self.name", session.watch_expressions.items[0]);

    // Duplicate should not add
    try session.addWatch("self.name");
    try std.testing.expectEqual(@as(usize, 2), session.watch_expressions.items.len);

    // Remove first
    session.removeWatch(0);
    try std.testing.expectEqual(@as(usize, 1), session.watch_expressions.items.len);
    try std.testing.expectEqualStrings("len(items)", session.watch_expressions.items[0]);
}

test "DapSession: buildPanelData produces valid JSON structure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var session = initTestSession();
    defer session.deinit();

    try session.cached_frames.append(std.testing.allocator, .{
        .id = 1,
        .name = try std.testing.allocator.dupe(u8, "main"),
        .source_path = try std.testing.allocator.dupe(u8, "/tmp/app.py"),
        .source_name = try std.testing.allocator.dupe(u8, "app.py"),
        .line = 10,
        .column = 1,
    });
    session.active_frame_id = 1;
    session.locals_ref = 42;
    session.stopped_reason = "breakpoint";

    var top_vars: VarList = .empty;
    try top_vars.append(std.testing.allocator, testVar("x", "42", "int", 0));
    try session.var_cache.put(42, top_vars);

    const panel_data = try session.buildPanelData(alloc);
    const obj = switch (panel_data) {
        .object => |o| o,
        else => return error.NotObject,
    };

    const status = json.getObject(obj, "status").?;
    try std.testing.expectEqualStrings("app.py", json.getString(status, "file").?);
    try std.testing.expectEqual(@as(i64, 10), json.getInteger(status, "line").?);
    try std.testing.expectEqualStrings("breakpoint", json.getString(status, "reason").?);

    const frames = json.getArray(obj, "frames").?;
    try std.testing.expectEqual(@as(usize, 1), frames.len);

    try std.testing.expectEqual(@as(i64, 0), json.getInteger(obj, "selected_frame").?);

    const vars = json.getArray(obj, "variables").?;
    try std.testing.expectEqual(@as(usize, 1), vars.len);
    const v0 = switch (vars[0]) {
        .object => |o| o,
        else => return error.NotObject,
    };
    try std.testing.expectEqualStrings("x", json.getString(v0, "name").?);

    const watches = json.getArray(obj, "watches").?;
    try std.testing.expectEqual(@as(usize, 0), watches.len);
}

test "DapSession: buildPanelData with empty state" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var session = initTestSession();
    defer session.deinit();

    const panel_data = try session.buildPanelData(alloc);
    const obj = switch (panel_data) {
        .object => |o| o,
        else => return error.NotObject,
    };

    try std.testing.expect(obj.get("status") != null);
    try std.testing.expect(obj.get("frames") != null);
    try std.testing.expect(obj.get("variables") != null);
    try std.testing.expect(obj.get("watches") != null);
}

test "DapSession: collapseVariable removes from cache" {
    var session = initTestSession();
    defer session.deinit();

    session.locals_ref = 42;

    var top_vars: VarList = .empty;
    try top_vars.append(std.testing.allocator, testVar("items", "[1,2,3]", "list", 5));
    try session.var_cache.put(42, top_vars);

    var children: VarList = .empty;
    try children.append(std.testing.allocator, testVar("0", "1", "int", 0));
    try session.var_cache.put(5, children);

    try std.testing.expect(session.var_cache.contains(5));

    session.collapseVariable(&[_]u32{0});

    try std.testing.expect(!session.var_cache.contains(5));
}

test "DapSession: nested resolvePathToRef" {
    var session = initTestSession();
    defer session.deinit();

    session.locals_ref = 42;

    var top_vars: VarList = .empty;
    try top_vars.append(std.testing.allocator, testVar("self", "MyClass", "MyClass", 10));
    try session.var_cache.put(42, top_vars);

    var self_children: VarList = .empty;
    try self_children.append(std.testing.allocator, testVar("x", "1", "int", 0));
    try self_children.append(std.testing.allocator, testVar("items", "[]", "list", 20));
    try session.var_cache.put(10, self_children);

    // Path [0] → self (ref=10)
    try std.testing.expectEqual(@as(?u32, 10), session.resolvePathToRef(&[_]u32{0}));
    // Path [0, 0] → self.x (ref=0)
    try std.testing.expectEqual(@as(?u32, 0), session.resolvePathToRef(&[_]u32{ 0, 0 }));
    // Path [0, 1] → self.items (ref=20)
    try std.testing.expectEqual(@as(?u32, 20), session.resolvePathToRef(&[_]u32{ 0, 1 }));
    // Path [0, 2] → out of bounds
    try std.testing.expectEqual(@as(?u32, null), session.resolvePathToRef(&[_]u32{ 0, 2 }));
}

test "DapSession: buildPanelData with expanded variables" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var session = initTestSession();
    defer session.deinit();

    session.locals_ref = 42;

    var top_vars: VarList = .empty;
    try top_vars.append(std.testing.allocator, testVar("x", "1", "int", 0));
    try top_vars.append(std.testing.allocator, testVar("self", "Obj", "Obj", 10));
    try session.var_cache.put(42, top_vars);

    // self is expanded with children
    var children: VarList = .empty;
    try children.append(std.testing.allocator, testVar("a", "2", "int", 0));
    try session.var_cache.put(10, children);

    const panel_data = try session.buildPanelData(alloc);
    const obj = switch (panel_data) {
        .object => |o| o,
        else => return error.NotObject,
    };

    const vars = json.getArray(obj, "variables").?;
    // Should be: x (depth=0), self (depth=0, expanded), a (depth=1)
    try std.testing.expectEqual(@as(usize, 3), vars.len);

    const v0 = switch (vars[0]) {
        .object => |o| o,
        else => return error.NotObject,
    };
    try std.testing.expectEqualStrings("x", json.getString(v0, "name").?);
    try std.testing.expectEqual(@as(i64, 0), json.getInteger(v0, "depth").?);

    const v1 = switch (vars[1]) {
        .object => |o| o,
        else => return error.NotObject,
    };
    try std.testing.expectEqualStrings("self", json.getString(v1, "name").?);
    try std.testing.expectEqual(@as(i64, 0), json.getInteger(v1, "depth").?);

    const v2 = switch (vars[2]) {
        .object => |o| o,
        else => return error.NotObject,
    };
    try std.testing.expectEqualStrings("a", json.getString(v2, "name").?);
    try std.testing.expectEqual(@as(i64, 1), json.getInteger(v2, "depth").?);
}
