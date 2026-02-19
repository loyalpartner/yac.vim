# YacPicker Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a Ctrl+P style picker panel with file search, workspace symbol search (#), and document symbol search (@) in a centered floating popup.

**Architecture:** Vim handles UI (two popups: input + results list). Zig daemon handles data: file indexing via fd/find subprocess, fuzzy matching, and LSP workspace/symbol forwarding. Communication uses existing JSON-RPC over Unix socket with three new methods: picker_open, picker_query, picker_close.

**Tech Stack:** VimScript (popup_create, job_start), Zig (std.process.Child, fuzzy matching), LSP workspace/symbol + textDocument/documentSymbol.

**Design doc:** `docs/plans/2026-02-19-picker-design.md`

---

### Task 1: Picker module — fuzzy match + file index

**Files:**
- Create: `src/picker.zig`

**Step 1: Write the fuzzy match scoring function**

Create `src/picker.zig` with a fuzzy match scorer and a `filterAndSort` function. The scorer uses these tiers:
- Exact basename match: 10000
- Case-sensitive prefix on basename: 5000
- Case-insensitive prefix on basename: 2000
- Subsequence with bonuses for word boundaries, CamelCase, consecutive chars

```zig
const std = @import("std");
const Allocator = std.mem.Allocator;

const max_results = 50;
const max_files = 50000;

const ScoredEntry = struct {
    index: usize,
    score: i32,
};

/// Score how well `pattern` matches `text` (higher = better, 0 = no match).
pub fn fuzzyScore(text: []const u8, pattern: []const u8) i32 {
    if (pattern.len == 0) return 1000;
    if (pattern.len > text.len) return 0;

    // Find basename (after last '/')
    const basename_start = if (std.mem.lastIndexOfScalar(u8, text, '/')) |pos| pos + 1 else 0;
    const basename = text[basename_start..];

    // Case-sensitive exact basename match
    if (std.mem.eql(u8, basename, pattern)) return 10000;

    // Case-sensitive basename prefix
    if (std.mem.startsWith(u8, basename, pattern))
        return 5000 + @as(i32, @intCast(@min(basename.len, 999)));

    // Case-insensitive basename prefix
    if (startsWithIgnoreCase(basename, pattern))
        return 2000 + @as(i32, @intCast(@min(basename.len, 999)));

    // Subsequence match on full path (case-insensitive)
    var score: i32 = 100;
    var ti: usize = 0;
    var prev_match: ?usize = null;
    for (pattern) |pc| {
        const plower = std.ascii.toLower(pc);
        while (ti < text.len) : (ti += 1) {
            if (std.ascii.toLower(text[ti]) == plower) {
                // Consecutive bonus
                if (prev_match) |pm| {
                    if (ti == pm + 1) score += 100;
                }
                // Word boundary bonus (after /, _, -, .)
                if (ti > 0 and isBoundary(text[ti - 1])) score += 80;
                // CamelCase bonus
                if (ti > 0 and std.ascii.isLower(text[ti - 1]) and std.ascii.isUpper(text[ti])) score += 60;
                // First char bonus
                if (ti == basename_start) score += 150;
                // Penalize late matches
                score -= @as(i32, @intCast(@min(ti, 50)));
                prev_match = ti;
                ti += 1;
                break;
            }
        } else return 0; // pattern char not found
    }
    return @max(score, 1);
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

/// Filter `items` by `pattern`, return top `max_results` sorted by score desc.
/// Returns slices into `items` (no allocation for the strings themselves).
pub fn filterAndSort(
    allocator: Allocator,
    items: []const []const u8,
    pattern: []const u8,
) ![]const usize {
    var scored = std.ArrayList(ScoredEntry).init(allocator);
    defer scored.deinit();

    for (items, 0..) |item, i| {
        const score = fuzzyScore(item, pattern);
        if (score > 0) {
            try scored.append(.{ .index = i, .score = score });
        }
    }

    // Sort by score descending
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
```

**Step 2: Write the FileIndex struct**

Append to `src/picker.zig`:

```zig
pub const FileIndex = struct {
    allocator: Allocator,
    files: std.ArrayList([]const u8),
    recent_files: std.ArrayList([]const u8),
    child: ?std.process.Child,
    stdout_buf: std.ArrayList(u8),
    ready: bool,

    pub fn init(allocator: Allocator) FileIndex {
        return .{
            .allocator = allocator,
            .files = std.ArrayList([]const u8).init(allocator),
            .recent_files = std.ArrayList([]const u8).init(allocator),
            .child = null,
            .stdout_buf = std.ArrayList(u8).init(allocator),
            .ready = false,
        };
    }

    pub fn deinit(self: *FileIndex) void {
        for (self.files.items) |f| self.allocator.free(f);
        self.files.deinit();
        for (self.recent_files.items) |f| self.allocator.free(f);
        self.recent_files.deinit();
        self.stdout_buf.deinit();
        if (self.child) |*c| {
            _ = c.kill() catch {};
            _ = c.wait() catch {};
        }
    }

    /// Start fd/find subprocess to scan `cwd`.
    pub fn startScan(self: *FileIndex, cwd: []const u8) !void {
        // Try fd first, fallback to find
        const argv: []const []const u8 = if (findExecutable("fd"))
            &.{ "fd", "--type", "f", "--color", "never" }
        else
            &.{ "find", ".", "-type", "f", "-not", "-path", "*/.git/*" };

        var child = std.process.Child.init(argv, self.allocator);
        child.cwd = .{ .unowned = @ptrCast(cwd) };
        child.stdout_behavior = .pipe;
        child.stderr_behavior = .ignore;
        try child.spawn();
        self.child = child;
    }

    /// Non-blocking read of fd/find output. Call from event loop poll.
    /// Returns true when scan is complete.
    pub fn pollScan(self: *FileIndex) bool {
        const child = &(self.child orelse return true);
        const stdout = child.stdout orelse return true;

        var buf: [8192]u8 = undefined;
        const n = std.posix.read(stdout.handle, &buf) catch return true;
        if (n == 0) {
            // EOF — process remaining buffer
            self.processBuffer();
            self.ready = true;
            _ = child.wait() catch {};
            self.child = null;
            return true;
        }
        self.stdout_buf.appendSlice(self.allocator, buf[0..n]) catch return true;
        self.processBuffer();
        return false;
    }

    fn processBuffer(self: *FileIndex) void {
        while (std.mem.indexOf(u8, self.stdout_buf.items, "\n")) |pos| {
            const line = self.stdout_buf.items[0..pos];
            if (line.len > 0 and self.files.items.len < max_files) {
                const duped = self.allocator.dupe(u8, line) catch break;
                self.files.append(self.allocator, duped) catch {
                    self.allocator.free(duped);
                    break;
                };
            }
            const remaining = self.stdout_buf.items.len - pos - 1;
            if (remaining > 0) {
                std.mem.copyForwards(u8, self.stdout_buf.items[0..remaining], self.stdout_buf.items[pos + 1 ..]);
            }
            self.stdout_buf.shrinkRetainingCapacity(remaining);
        }
    }

    /// Set recent files (dupes the strings).
    pub fn setRecentFiles(self: *FileIndex, files: []const []const u8) !void {
        for (self.recent_files.items) |f| self.allocator.free(f);
        self.recent_files.shrinkRetainingCapacity(0);
        for (files) |f| {
            const duped = try self.allocator.dupe(u8, f);
            try self.recent_files.append(self.allocator, duped);
        }
    }

    /// Get the stdout fd for polling (returns null if no scan active).
    pub fn getStdoutFd(self: *FileIndex) ?std.posix.fd_t {
        const child = self.child orelse return null;
        const stdout = child.stdout orelse return null;
        return stdout.handle;
    }
};

fn findExecutable(name: []const u8) bool {
    const path_env = std.posix.getenv("PATH") orelse return false;
    var it = std.mem.splitScalar(u8, path_env, ':');
    while (it.next()) |dir| {
        var buf: [512]u8 = undefined;
        const full = std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir, name }) catch continue;
        std.fs.accessAbsolute(full, .{}) catch continue;
        return true;
    }
    return false;
}
```

**Step 3: Add unit tests for fuzzyScore**

Append to `src/picker.zig`:

```zig
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
```

**Step 4: Import in main.zig and run tests**

Add to `src/main.zig` test block (around line 1103):
```zig
_ = @import("picker.zig");
```

Run: `zig build test`
Expected: All tests pass

**Step 5: Commit**

```bash
git add src/picker.zig src/main.zig
git commit -m "feat(picker): add fuzzy match scorer and FileIndex"
```

---

### Task 2: Handler wiring — picker_open, picker_query, picker_close

**Files:**
- Modify: `src/handlers.zig:48-69` (dispatch table)
- Modify: `src/handlers.zig` (add handler functions)
- Modify: `src/main.zig` (add FileIndex to EventLoop, poll its fd)

**Step 1: Add FileIndex to EventLoop**

In `src/main.zig`, add field to `EventLoop` struct (around line 94):
```zig
    /// Picker file index (active while picker is open)
    file_index: ?*picker_mod.FileIndex,
```

Add import at top of main.zig:
```zig
const picker_mod = @import("picker.zig");
```

Initialize in `init()`:
```zig
    .file_index = null,
```

Deinit in `deinit()`:
```zig
    if (self.file_index) |fi| {
        fi.deinit();
        self.allocator.destroy(fi);
    }
```

**Step 2: Add picker handlers to dispatch table**

In `src/handlers.zig`, add to the `handlers` array (after the `execute_command` entry, around line 68):
```zig
    .{ .name = "picker_open", .handleFn = handlePickerOpen },
    .{ .name = "picker_query", .handleFn = handlePickerQuery },
    .{ .name = "picker_close", .handleFn = handlePickerClose },
```

**Step 3: Implement handler functions**

Add to `src/handlers.zig`:

```zig
fn handlePickerOpen(ctx: *HandlerContext, params: Value) !DispatchResult {
    const obj = switch (params) {
        .object => |o| o,
        else => return .{ .empty = {} },
    };
    const cwd = json.getString(obj, "cwd") orelse return .{ .empty = {} };

    // Create or reset file index
    // Note: the EventLoop manages the FileIndex lifecycle.
    // We pass cwd and recent_files back via a special response that EventLoop handles.
    var result = ObjectMap.init(ctx.allocator);
    try result.put("action", json.jsonString("picker_init"));
    try result.put("cwd", json.jsonString(cwd));

    // Forward recent_files array
    if (obj.get("recent_files")) |rf| {
        try result.put("recent_files", rf);
    }

    return .{ .data = .{ .object = result } };
}

fn handlePickerQuery(ctx: *HandlerContext, params: Value) !DispatchResult {
    const obj = switch (params) {
        .object => |o| o,
        else => return .{ .empty = {} },
    };
    const query = json.getString(obj, "query") orelse "";
    const mode = json.getString(obj, "mode") orelse "file";

    if (std.mem.eql(u8, mode, "workspace_symbol")) {
        // Forward to LSP workspace/symbol
        const file = json.getString(obj, "file") orelse return .{ .empty = {} };
        const lsp_ctx = switch (try getLspContext(ctx, params)) {
            .ready => |c| c,
            .initializing => return .{ .initializing = {} },
            .not_available => return .{ .empty = {} },
        };
        _ = file;

        var ws_params = ObjectMap.init(ctx.allocator);
        try ws_params.put("query", json.jsonString(query));
        const request_id = try lsp_ctx.client.sendRequest("workspace/symbol", .{ .object = ws_params });
        return .{ .pending_lsp = .{ .lsp_request_id = request_id } };
    } else if (std.mem.eql(u8, mode, "document_symbol")) {
        // Forward to LSP textDocument/documentSymbol
        const lsp_ctx = switch (try getLspContext(ctx, params)) {
            .ready => |c| c,
            .initializing => return .{ .initializing = {} },
            .not_available => return .{ .empty = {} },
        };
        const lsp_params = try buildTextDocumentIdentifier(ctx.allocator, lsp_ctx.uri);
        const request_id = try lsp_ctx.client.sendRequest("textDocument/documentSymbol", lsp_params);
        return .{ .pending_lsp = .{ .lsp_request_id = request_id } };
    } else {
        // File mode — handled by EventLoop using FileIndex
        var result = ObjectMap.init(ctx.allocator);
        try result.put("action", json.jsonString("picker_file_query"));
        try result.put("query", json.jsonString(query));
        return .{ .data = .{ .object = result } };
    }
}

fn handlePickerClose(ctx: *HandlerContext, params: Value) !DispatchResult {
    _ = params;
    var result = ObjectMap.init(ctx.allocator);
    try result.put("action", json.jsonString("picker_close"));
    return .{ .data = .{ .object = result } };
}
```

**Step 4: Handle picker actions in EventLoop**

In `src/main.zig`, modify `handleVimRequest` to intercept picker actions. After the `switch (result)` block that handles `.data`, add special handling:

In the `.data => |data|` arm, before `self.sendVimResponseTo(...)`, add:
```zig
    .data => |data| {
        // Check for picker internal actions
        if (self.handlePickerAction(cid, alloc, vim_id, data)) return;
        self.sendVimResponseTo(cid, alloc, vim_id, data);
    },
```

Add the helper method to EventLoop:
```zig
    /// Handle picker-specific actions returned by handlers.
    /// Returns true if the action was handled (caller should not send response).
    fn handlePickerAction(self: *EventLoop, cid: ClientId, alloc: Allocator, vim_id: ?u64, data: Value) bool {
        const obj = switch (data) {
            .object => |o| o,
            else => return false,
        };
        const action = json_utils.getString(obj, "action") orelse return false;

        if (std.mem.eql(u8, action, "picker_init")) {
            const cwd = json_utils.getString(obj, "cwd") orelse return true;
            // Clean up old index
            if (self.file_index) |fi| {
                fi.deinit();
                self.allocator.destroy(fi);
            }
            const fi = self.allocator.create(picker_mod.FileIndex) catch return true;
            fi.* = picker_mod.FileIndex.init(self.allocator);
            fi.startScan(cwd) catch {
                fi.deinit();
                self.allocator.destroy(fi);
                return true;
            };
            // Set recent files
            if (obj.get("recent_files")) |rf_val| {
                if (rf_val == .array) {
                    var recent = std.ArrayList([]const u8).init(alloc);
                    defer recent.deinit();
                    for (rf_val.array.items) |item| {
                        if (json_utils.asString(item)) |s| {
                            recent.append(alloc, s) catch {};
                        }
                    }
                    fi.setRecentFiles(recent.items) catch {};
                }
            }
            self.file_index = fi;
            // Send initial recent files as response
            self.sendPickerResults(cid, alloc, vim_id, fi.recent_files.items, "file");
            return true;
        } else if (std.mem.eql(u8, action, "picker_file_query")) {
            const query = json_utils.getString(obj, "query") orelse "";
            const fi = self.file_index orelse {
                self.sendVimResponseTo(cid, alloc, vim_id, .null);
                return true;
            };
            // Poll to progress scan if still running
            _ = fi.pollScan();
            if (query.len == 0) {
                // Empty query → recent files
                self.sendPickerResults(cid, alloc, vim_id, fi.recent_files.items, "file");
            } else {
                // Fuzzy filter
                const indices = picker_mod.filterAndSort(alloc, fi.files.items, query) catch {
                    self.sendVimResponseTo(cid, alloc, vim_id, .null);
                    return true;
                };
                var items = std.ArrayList([]const u8).init(alloc);
                for (indices) |idx| {
                    items.append(alloc, fi.files.items[idx]) catch {};
                }
                self.sendPickerResults(cid, alloc, vim_id, items.items, "file");
            }
            return true;
        } else if (std.mem.eql(u8, action, "picker_close")) {
            if (self.file_index) |fi| {
                fi.deinit();
                self.allocator.destroy(fi);
                self.file_index = null;
            }
            self.sendVimResponseTo(cid, alloc, vim_id, .null);
            return true;
        }
        return false;
    }

    /// Send picker results in the standard format.
    fn sendPickerResults(self: *EventLoop, cid: ClientId, alloc: Allocator, vim_id: ?u64, paths: []const []const u8, mode: []const u8) void {
        var items = std.json.Array.init(alloc);
        for (paths) |path| {
            var item = ObjectMap.init(alloc);
            item.put("label", json_utils.jsonString(path)) catch continue;
            item.put("detail", json_utils.jsonString("")) catch continue;
            item.put("file", json_utils.jsonString(path)) catch continue;
            item.put("line", json_utils.jsonInteger(0)) catch continue;
            item.put("column", json_utils.jsonInteger(0)) catch continue;
            items.append(.{ .object = item }) catch continue;
        }
        var result = ObjectMap.init(alloc);
        result.put("items", .{ .array = items }) catch {};
        result.put("mode", json_utils.jsonString(mode)) catch {};
        self.sendVimResponseTo(cid, alloc, vim_id, .{ .object = result });
    }
```

**Step 5: Add fd stdout to poll loop**

In `EventLoop.run()`, after collecting LSP fds (around line 196), add the picker fd:

```zig
    // fd[N+M+1] = picker fd/find stdout (if active)
    const picker_fd_index: ?usize = blk: {
        if (self.file_index) |fi| {
            if (fi.getStdoutFd()) |fd| {
                const idx = poll_fds.items.len;
                try poll_fds.append(self.allocator, .{
                    .fd = fd,
                    .events = std.posix.POLL.IN,
                    .revents = 0,
                });
                break :blk idx;
            }
        }
        break :blk null;
    };
```

After the LSP stdout check loop (around line 270), add:
```zig
    // Check picker fd
    if (picker_fd_index) |pfi| {
        if (poll_fds.items[pfi].revents & (std.posix.POLL.IN | std.posix.POLL.HUP) != 0) {
            if (self.file_index) |fi| {
                _ = fi.pollScan();
            }
        }
    }
```

**Step 6: Add workspace symbol capability to LSP initialize**

In `src/lsp_client.zig`, after `try workspace.put("applyEdit", ...)` (line 284), add:
```zig
    // workspace/symbol support
    var ws_symbol = ObjectMap.init(self.allocator);
    try ws_symbol.put("dynamicRegistration", json.jsonBool(false));
    try workspace.put("symbol", .{ .object = ws_symbol });
```

**Step 7: Build and test**

Run: `zig build && zig build test`
Expected: Compiles and all tests pass

**Step 8: Commit**

```bash
git add src/main.zig src/handlers.zig src/lsp_client.zig
git commit -m "feat(picker): wire picker handlers and FileIndex into event loop"
```

---

### Task 3: LSP response transformation for picker symbol modes

**Files:**
- Modify: `src/main.zig` (transformLspResult for picker methods)

**Step 1: Handle workspace/symbol and document/symbol responses in transformLspResult**

In `src/main.zig`, modify `transformLspResult` (around line 674):

```zig
    fn transformLspResult(alloc: Allocator, method: []const u8, result: Value, ssh_host: ?[]const u8) Value {
        if (std.mem.startsWith(u8, method, "goto_")) {
            return transformGotoResult(alloc, result, ssh_host) catch .null;
        }
        if (std.mem.eql(u8, method, "picker_query")) {
            // This is handled specially — workspace/symbol and document/symbol
            // results are transformed into picker format
            return transformPickerSymbolResult(alloc, result, ssh_host) catch .null;
        }
        return result;
    }
```

Add new transform function:
```zig
    fn transformPickerSymbolResult(alloc: Allocator, result: Value, ssh_host: ?[]const u8) !Value {
        const arr = switch (result) {
            .array => |a| a.items,
            else => return .null,
        };

        var items = std.json.Array.init(alloc);
        for (arr) |sym_val| {
            const sym = switch (sym_val) {
                .object => |o| o,
                else => continue,
            };
            const name = json_utils.getString(sym, "name") orelse continue;
            const kind_int = json_utils.getInteger(sym, "kind");
            const container = json_utils.getString(sym, "containerName");
            const detail = if (container) |c|
                std.fmt.allocPrint(alloc, "{s} ({s})", .{ symbolKindName(kind_int), c }) catch ""
            else
                symbolKindName(kind_int);

            // Extract location
            var file: []const u8 = "";
            var line: i64 = 0;
            var column: i64 = 0;
            if (json_utils.getObject(sym, "location")) |loc| {
                if (json_utils.getString(loc, "uri")) |uri| {
                    file = lsp_registry_mod.uriToFilePath(uri) orelse "";
                    if (ssh_host) |host| {
                        file = std.fmt.allocPrint(alloc, "scp://{s}/{s}", .{ host, file }) catch file;
                    }
                }
                if (json_utils.getObject(loc, "range")) |range| {
                    if (json_utils.getObject(range, "start")) |start| {
                        line = json_utils.getInteger(start, "line") orelse 0;
                        column = json_utils.getInteger(start, "character") orelse 0;
                    }
                }
            }

            var item = ObjectMap.init(alloc);
            try item.put("label", json_utils.jsonString(name));
            try item.put("detail", json_utils.jsonString(detail));
            try item.put("file", json_utils.jsonString(file));
            try item.put("line", json_utils.jsonInteger(line));
            try item.put("column", json_utils.jsonInteger(column));
            try items.append(.{ .object = item });
        }

        var result_obj = ObjectMap.init(alloc);
        try result_obj.put("items", .{ .array = items });
        try result_obj.put("mode", json_utils.jsonString("symbol"));
        return .{ .object = result_obj };
    }

    fn symbolKindName(kind: ?i64) []const u8 {
        const k = kind orelse return "Symbol";
        return switch (k) {
            1 => "File", 2 => "Module", 3 => "Namespace", 4 => "Package",
            5 => "Class", 6 => "Method", 7 => "Property", 8 => "Field",
            9 => "Constructor", 10 => "Enum", 11 => "Interface", 12 => "Function",
            13 => "Variable", 14 => "Constant", 15 => "String", 16 => "Number",
            17 => "Boolean", 18 => "Array", 19 => "Object", 20 => "Key",
            21 => "Null", 22 => "EnumMember", 23 => "Struct", 24 => "Event",
            25 => "Operator", 26 => "TypeParameter",
            else => "Symbol",
        };
    }
```

**Step 2: Fix picker_query pending_lsp method tracking**

The `trackPendingRequest` uses `method` to decide how to transform results. For picker_query requests that go to LSP, the method stored is the Vim method (`picker_query`), not the LSP method. We need to make sure `transformLspResult` receives `"picker_query"` so it can apply `transformPickerSymbolResult`.

This already works because `trackPendingRequest` stores the Vim method name.

**Step 3: Build and test**

Run: `zig build && zig build test`
Expected: Compiles and tests pass

**Step 4: Commit**

```bash
git add src/main.zig
git commit -m "feat(picker): transform workspace/document symbol LSP responses for picker"
```

---

### Task 4: Vim UI — picker popup and input handling

**Files:**
- Modify: `vim/autoload/yac.vim` (add picker functions)
- Modify: `vim/plugin/yac.vim` (add command and keybinding)

**Step 1: Add picker state and history variables**

Add to `vim/autoload/yac.vim`, after the diagnostic virtual text state block (around line 93):
```vim
" Picker 状态
let s:picker = {
  \ 'input_popup': -1,
  \ 'results_popup': -1,
  \ 'items': [],
  \ 'selected': 0,
  \ 'timer_id': -1,
  \ 'last_query': '',
  \ }
let s:picker_history = []
let s:picker_history_idx = -1
```

**Step 2: Implement picker_open**

```vim
" 打开 Picker 面板
function! yac#picker_open() abort
  " 已打开则关闭
  if s:picker.input_popup != -1
    call s:picker_close()
    return
  endif

  " 收集最近打开的文件（按最近访问排序）
  let recent = []
  for buf in getbufinfo({'buflisted': 1})
    if !empty(buf.name) && filereadable(buf.name)
      call add(recent, buf.name)
    endif
  endfor

  " 发送 picker_open 通知 + 打开 UI
  call s:request('picker_open', {
    \ 'cwd': getcwd(),
    \ 'recent_files': recent,
    \ 'file': expand('%:p'),
    \ }, 's:handle_picker_open_response')
endfunction

function! s:handle_picker_open_response(channel, response) abort
  call s:debug_log(printf('[RECV]: picker_open response: %s', string(a:response)))

  " 创建 UI
  call s:picker_create_ui()

  " 显示初始结果（最近文件）
  if type(a:response) == v:t_dict && has_key(a:response, 'items')
    call s:picker_update_results(a:response.items)
  endif
endfunction
```

**Step 3: Implement popup creation**

```vim
function! s:picker_create_ui() abort
  let width = float2nr(&columns * 0.6)
  let height = 16  " 1 input + 15 results
  let col = float2nr((&columns - width) / 2)
  let row = float2nr(&lines * 0.2)

  " 输入框 popup（可编辑 buffer）
  let input_buf = bufadd('')
  call bufload(input_buf)
  call setbufvar(input_buf, '&buftype', 'nofile')
  call setbufvar(input_buf, '&bufhidden', 'wipe')
  call setbufvar(input_buf, '&swapfile', 0)
  call setbufline(input_buf, 1, '> ')

  let s:picker.input_popup = popup_create(input_buf, {
    \ 'line': row,
    \ 'col': col,
    \ 'minwidth': width,
    \ 'maxwidth': width,
    \ 'minheight': 1,
    \ 'maxheight': 1,
    \ 'border': [1, 1, 0, 1],
    \ 'borderchars': ['─', '│', '─', '│', '╭', '╮', '┤', '├'],
    \ 'borderhighlight': ['YacPickerBorder'],
    \ 'highlight': 'YacPickerInput',
    \ 'title': ' YacPicker ',
    \ 'filter': function('s:picker_input_filter'),
    \ 'mapping': 0,
    \ 'zindex': 100,
    \ })

  " 结果列表 popup
  let s:picker.results_popup = popup_create([], {
    \ 'line': row + 2,
    \ 'col': col,
    \ 'minwidth': width,
    \ 'maxwidth': width,
    \ 'minheight': 15,
    \ 'maxheight': 15,
    \ 'border': [0, 1, 1, 1],
    \ 'borderchars': ['─', '│', '─', '│', '├', '┤', '╯', '╰'],
    \ 'borderhighlight': ['YacPickerBorder'],
    \ 'highlight': 'YacPickerNormal',
    \ 'scrollbar': 0,
    \ 'zindex': 100,
    \ })

  " 高亮组
  highlight default YacPickerBorder guifg=#555555
  highlight default YacPickerInput guibg=#1e1e2e guifg=#cdd6f4
  highlight default YacPickerNormal guibg=#1e1e2e guifg=#cdd6f4
  highlight default YacPickerSelected guibg=#45475a guifg=#cdd6f4
endfunction
```

**Step 4: Implement input filter (key handling)**

```vim
function! s:picker_input_filter(winid, key) abort
  if a:key == "\<Esc>"
    call s:picker_close()
    return 1
  endif

  if a:key == "\<CR>"
    call s:picker_accept()
    return 1
  endif

  " 结果导航
  if a:key == "\<C-j>" || a:key == "\<C-n>" || a:key == "\<Tab>"
    call s:picker_select_next()
    return 1
  endif
  if a:key == "\<C-k>" || a:key == "\<C-p>" || a:key == "\<S-Tab>"
    call s:picker_select_prev()
    return 1
  endif

  " 编辑快捷键
  if a:key == "\<C-a>"
    let buf = winbufnr(a:winid)
    call setbufline(buf, 1, '> ' . getbufline(buf, 1)[0][2:])
    call win_execute(a:winid, 'call cursor(1, 3)')
    return 1
  endif
  if a:key == "\<C-e>"
    call win_execute(a:winid, 'call cursor(1, col("$"))')
    return 1
  endif
  if a:key == "\<C-u>"
    let buf = winbufnr(a:winid)
    call setbufline(buf, 1, '> ')
    call win_execute(a:winid, 'call cursor(1, 3)')
    call s:picker_on_input_changed()
    return 1
  endif
  if a:key == "\<C-w>"
    let buf = winbufnr(a:winid)
    let line = getbufline(buf, 1)[0]
    let text = line[2:]
    " Delete last word
    let text = substitute(text, '\S*\s*$', '', '')
    call setbufline(buf, 1, '> ' . text)
    call win_execute(a:winid, 'call cursor(1, col("$"))')
    call s:picker_on_input_changed()
    return 1
  endif

  " History browsing with Up/Down (when input is empty)
  if a:key == "\<Up>" || a:key == "\<Down>"
    let buf = winbufnr(a:winid)
    let text = getbufline(buf, 1)[0][2:]
    if empty(text) && !empty(s:picker_history)
      if a:key == "\<Up>"
        let s:picker_history_idx = min([s:picker_history_idx + 1, len(s:picker_history) - 1])
      else
        let s:picker_history_idx = max([s:picker_history_idx - 1, -1])
      endif
      if s:picker_history_idx >= 0
        call setbufline(buf, 1, '> ' . s:picker_history[s:picker_history_idx])
      else
        call setbufline(buf, 1, '> ')
      endif
      call win_execute(a:winid, 'call cursor(1, col("$"))')
      call s:picker_on_input_changed()
      return 1
    endif
  endif

  " Backspace
  if a:key == "\<BS>"
    let buf = winbufnr(a:winid)
    let line = getbufline(buf, 1)[0]
    if len(line) <= 2
      return 1  " Don't delete the "> " prefix
    endif
    " Get cursor position in the popup window
    let cur_col = 0
    call win_execute(a:winid, 'let cur_col = col(".")')
    if cur_col <= 3
      return 1  " Don't delete before prefix
    endif
    let before = line[:cur_col - 3]
    let after = line[cur_col - 1:]
    call setbufline(buf, 1, before . after)
    call win_execute(a:winid, 'call cursor(1, ' . (cur_col - 1) . ')')
    call s:picker_on_input_changed()
    return 1
  endif

  " Regular character input
  if a:key =~ '^\p$' && len(a:key) == 1
    let buf = winbufnr(a:winid)
    let line = getbufline(buf, 1)[0]
    let cur_col = 0
    call win_execute(a:winid, 'let cur_col = col(".")')
    let before = line[:cur_col - 2]
    let after = line[cur_col - 1:]
    call setbufline(buf, 1, before . a:key . after)
    call win_execute(a:winid, 'call cursor(1, ' . (cur_col + 1) . ')')
    call s:picker_on_input_changed()
    return 1
  endif

  return 1  " consume all keys
endfunction
```

**Step 5: Implement query dispatch and debounce**

```vim
function! s:picker_on_input_changed() abort
  " Debounce
  if s:picker.timer_id != -1
    call timer_stop(s:picker.timer_id)
  endif
  let s:picker.timer_id = timer_start(50, function('s:picker_send_query'))
endfunction

function! s:picker_send_query(timer_id) abort
  let s:picker.timer_id = -1
  if s:picker.input_popup == -1
    return
  endif

  let buf = winbufnr(s:picker.input_popup)
  let line = getbufline(buf, 1)[0]
  let text = line[2:]  " Remove '> ' prefix

  " Determine mode from prefix
  let mode = 'file'
  let query = text
  if text =~# '^#'
    let mode = 'workspace_symbol'
    let query = text[1:]
  elseif text =~# '^@'
    let mode = 'document_symbol'
    let query = text[1:]
  endif

  let s:picker.last_query = text

  call s:request('picker_query', {
    \ 'query': query,
    \ 'mode': mode,
    \ 'file': expand('%:p'),
    \ }, 's:handle_picker_query_response')
endfunction

function! s:handle_picker_query_response(channel, response) abort
  call s:debug_log(printf('[RECV]: picker_query response: %s', string(a:response)))
  if s:picker.results_popup == -1
    return
  endif
  if type(a:response) == v:t_dict && has_key(a:response, 'items')
    call s:picker_update_results(a:response.items)
  endif
endfunction
```

**Step 6: Implement results display and selection**

```vim
function! s:picker_update_results(items) abort
  let s:picker.items = a:items
  let s:picker.selected = 0

  let lines = []
  for item in a:items
    let label = get(item, 'label', '')
    let detail = get(item, 'detail', '')
    if !empty(detail)
      call add(lines, '  ' . label . '  ' . detail)
    else
      call add(lines, '  ' . label)
    endif
  endfor

  if empty(lines)
    let lines = ['  (no results)']
  endif

  call popup_settext(s:picker.results_popup, lines)
  call s:picker_highlight_selected()
endfunction

function! s:picker_highlight_selected() abort
  if s:picker.results_popup == -1 || empty(s:picker.items)
    return
  endif
  call win_execute(s:picker.results_popup, 'call clearmatches()')
  call win_execute(s:picker.results_popup,
    \ printf('call matchaddpos("YacPickerSelected", [%d])', s:picker.selected + 1))
endfunction

function! s:picker_select_next() abort
  if !empty(s:picker.items)
    let s:picker.selected = (s:picker.selected + 1) % len(s:picker.items)
    call s:picker_highlight_selected()
  endif
endfunction

function! s:picker_select_prev() abort
  if !empty(s:picker.items)
    let s:picker.selected = (s:picker.selected - 1 + len(s:picker.items)) % len(s:picker.items)
    call s:picker_highlight_selected()
  endif
endfunction
```

**Step 7: Implement accept and close**

```vim
function! s:picker_accept() abort
  if empty(s:picker.items)
    call s:picker_close()
    return
  endif

  let item = s:picker.items[s:picker.selected]
  let file = get(item, 'file', '')
  let line = get(item, 'line', 0)
  let column = get(item, 'column', 0)

  " Save to history
  let query = s:picker.last_query
  if !empty(query)
    " Remove if already in history, then prepend
    call filter(s:picker_history, 'v:val !=# query')
    call insert(s:picker_history, query, 0)
    if len(s:picker_history) > 20
      call remove(s:picker_history, 20, -1)
    endif
  endif

  call s:picker_close()

  " Navigate to file/symbol
  if !empty(file)
    if file !=# expand('%:p')
      execute 'edit ' . fnameescape(file)
    endif
    if line > 0
      call cursor(line + 1, column + 1)
      normal! zz
    endif
  endif
endfunction

function! s:picker_close() abort
  if s:picker.timer_id != -1
    call timer_stop(s:picker.timer_id)
    let s:picker.timer_id = -1
  endif
  if s:picker.input_popup != -1
    call popup_close(s:picker.input_popup)
    let s:picker.input_popup = -1
  endif
  if s:picker.results_popup != -1
    call popup_close(s:picker.results_popup)
    let s:picker.results_popup = -1
  endif
  let s:picker.items = []
  let s:picker.selected = 0
  let s:picker_history_idx = -1

  " Notify daemon to release file index
  call s:notify('picker_close', {})
endfunction
```

**Step 8: Add command and keybinding**

In `vim/plugin/yac.vim`, add after the existing commands:
```vim
command! YacPicker      call yac#picker_open()
```

Add after the existing keybindings:
```vim
nnoremap <silent> <C-p> :YacPicker<CR>
```

**Step 9: Build and manual test**

Run: `zig build && zig build test`
Expected: Compiles and tests pass

Manual test:
1. Open Vim with a project
2. Press `Ctrl+P`
3. Verify floating popup appears with recent files
4. Type a filename — verify fuzzy filtering works
5. Press `<CR>` — verify file opens
6. Press `Ctrl+P`, type `#func` — verify workspace symbols appear
7. Press `Ctrl+P`, type `@` — verify document symbols appear
8. Press `<Esc>` — verify popup closes cleanly

**Step 10: Commit**

```bash
git add vim/autoload/yac.vim vim/plugin/yac.vim
git commit -m "feat(picker): add Ctrl+P picker UI with file/symbol search"
```

---

### Task 5: E2E test for picker

**Files:**
- Create: `tests/test_picker.py`

**Step 1: Write E2E test**

```python
"""E2E tests for the YacPicker feature."""
import pytest


def test_picker_open_returns_results(yac_client):
    """picker_open should return recent files list."""
    resp = yac_client.request("picker_open", {
        "cwd": yac_client.project_dir,
        "recent_files": ["/tmp/test_file.py"],
        "file": "/tmp/test_file.py",
    })
    assert resp is not None
    assert "items" in resp
    assert resp["mode"] == "file"


def test_picker_file_query(yac_client):
    """picker_query in file mode should return fuzzy-matched files."""
    # First open to start indexing
    yac_client.request("picker_open", {
        "cwd": yac_client.project_dir,
        "recent_files": [],
        "file": "/tmp/test_file.py",
    })

    import time
    time.sleep(1)  # Wait for fd/find to complete

    resp = yac_client.request("picker_query", {
        "query": "main",
        "mode": "file",
        "file": "/tmp/test_file.py",
    })
    assert resp is not None
    assert "items" in resp

    # Cleanup
    yac_client.notify("picker_close", {})


def test_picker_close(yac_client):
    """picker_close should not error."""
    yac_client.notify("picker_close", {})
```

**Step 2: Run tests**

Run: `uv run pytest tests/test_picker.py -v`
Expected: Tests pass

**Step 3: Commit**

```bash
git add tests/test_picker.py
git commit -m "test(picker): add E2E tests for picker open/query/close"
```

---

### Task 6: Final integration and polish

**Files:**
- Modify: `vim/autoload/yac.vim` (error handling refinements)

**Step 1: Add error handling for picker responses**

In `s:handle_picker_query_response`, add error key check:
```vim
function! s:handle_picker_query_response(channel, response) abort
  call s:debug_log(printf('[RECV]: picker_query response: %s', string(a:response)))
  if s:picker.results_popup == -1
    return
  endif
  if type(a:response) == v:t_dict && has_key(a:response, 'error')
    call s:debug_log('[yac] Picker error: ' . string(a:response.error))
    return
  endif
  if type(a:response) == v:t_dict && has_key(a:response, 'items')
    call s:picker_update_results(a:response.items)
  endif
endfunction
```

**Step 2: Run full test suite**

Run: `zig build && zig build test && uv run pytest tests/ -v`
Expected: All tests pass (existing + new picker tests)

**Step 3: Commit**

```bash
git add vim/autoload/yac.vim
git commit -m "feat(picker): add error handling for picker responses"
```
