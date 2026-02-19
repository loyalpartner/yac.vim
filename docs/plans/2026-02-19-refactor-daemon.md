# Daemon Refactoring Plan

**Goal:** Split the 1352-line `src/main.zig` and 704-line `src/handlers.zig` into focused, single-responsibility modules without changing observable behavior.

**Principles:**
- Keep signatures and data shapes identical during extraction.
- Each step must build and pass tests independently.
- Prefer small, mechanical moves over semantic changes.

**End-state architecture:** Each stateful subsystem becomes an owned struct with `init`/`deinit` and a clean method API. Pure utilities remain as free functions namespaced by module. `EventLoop` becomes a thin compositor owning `Clients`, `Lsp`, `Picker`, `Progress`, and `Requests`.

**Target EventLoop shape:**
```zig
const EventLoop = struct {
    allocator:     Allocator,
    listener:      std.net.Server,
    clients:       Clients,
    lsp:           Lsp,
    picker:        Picker,
    progress:      Progress,
    requests:      Requests,
    idle_deadline: ?i128,
};
```

**Build/test:** `zig build && zig build test` (unit), `python3 -m pytest tests/` (E2E).

---

## Dependency order and risk map

```
Task 1  lsp_transform.zig   pure functions, no state            LOW
Task 2  lsp_config.zig      static data, no behavior            LOW
Task 3  vim.zig              I/O helpers unified                 MEDIUM
Task 4  handlers/ split      domain separation                   MEDIUM
Task 5  Clients              connection + buffer management      MEDIUM
Task 6  Requests             in-flight maps                      LOW
Task 7  Picker               file index + picker actions         MEDIUM
Task 8  Lsp                  registry + deferred + health        MEDIUM
Task 9  Progress             $/progress title tracking           MEDIUM
Task 10 EventLoop cleanup    run() skeleton                      MEDIUM
```

Tasks 1-2 are independent. Tasks 3-10 follow the numbered sequence.

---

## Task 1: Extract `src/lsp_transform.zig`

Move five pure, stateless functions out of `src/main.zig` with identical signatures.

**Functions:** `escapeVimString`, `formatProgressEcho`, `symbolKindName`, `transformGotoResult`, `transformPickerSymbolResult`

**Create:** `src/lsp_transform.zig` | **Modify:** `src/main.zig`

**Notes:**
- Use `json_utils.Value` and `json_utils.ObjectMap` (not `std.json`).
- Keep `?[]const u8` / `?i64` signatures as-is.

---

## Task 2: Extract `src/lsp_config.zig`

Move `LspServerConfig` and `builtin_configs` out of `src/lsp_registry.zig` verbatim.

**Create:** `src/lsp_config.zig` | **Modify:** `src/lsp_registry.zig`

**Notes:**
- Do not add or remove fields from `LspServerConfig`.
- Copy `builtin_configs` exactly.

---

## Task 3: Create `src/vim.zig`

Unify Vim message encoding currently spread across `src/main.zig`: `writeMessage`, `sendVimResponseTo`, `sendVimExTo`, `sendVimErrorTo`.

**Create:** `src/vim.zig` | **Modify:** `src/main.zig`

**Notes:**
- Keep newline behavior identical (`writeAll` + `"\n"`).
- Do not change error-handling semantics.

---

## Task 4: Split `src/handlers.zig`

Move handler implementations into `src/handlers/*.zig`. The root `handlers.zig` keeps only the `handlers` dispatch table and `dispatch` function.

**Create:** `src/handlers/*.zig` | **Modify:** `src/handlers.zig`

**Notes:**
- No signature or behavior changes.
- Keep dispatch table ordering unchanged.

---

## Task 5: Extract `Clients`

Move client accept/remove/buffer/broadcast logic out of `EventLoop` into a new struct exposing `accept`, `remove`, `broadcast`, `get`, `iter`.

**Create:** `src/clients.zig` | **Modify:** `src/main.zig`

**Notes:**
- `EventLoop` remains owner of `std.net.Server`.

---

## Task 6: Extract `Requests`

Move in-flight request maps (`pending_requests`, `pending_vim_exprs`) into a dedicated struct.

**Create:** `src/requests.zig` | **Modify:** `src/main.zig`

**Notes:**
- Preserve cleanup order and deinit behavior.

---

## Task 7: Extract `Picker`

Move file indexing lifecycle and picker action handling into a new struct.

**Create:** `src/picker.zig` | **Modify:** `src/main.zig`

**Notes:**
- `FileIndex` ownership and lifetime must remain unchanged.

---

## Task 8: Extract `Lsp`

Move LSP output processing, deferred queues, and LSP client lifecycle into a new struct.

**Create:** `src/lsp.zig` | **Modify:** `src/main.zig`

**Notes:**
- Keep error handling and logging paths unchanged.

---

## Task 9: Extract `Progress`

Move `$/progress` title tracking into a dedicated struct.

**Create:** `src/progress.zig` | **Modify:** `src/main.zig`

---

## Task 10: EventLoop cleanup

Reduce `EventLoop.run()` to a thin poll loop that delegates all work to the extracted subsystems.

**Modify:** `src/main.zig`
