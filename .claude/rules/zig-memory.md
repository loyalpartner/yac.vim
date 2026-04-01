---
description: Zig memory safety rules for yacd daemon code
globs: yacd/src/**/*.zig
---

# Zig Memory Safety

- **禁止 `parseFromSlice` 生产代码**：返回 `Parsed(T)` 含隐藏 `ArenaAllocator`，只取 `.value` 丢弃 `Parsed` = 必泄漏。统一用 `parseFromSliceLeaky`，中间 json buffer 被 free 时必须加 `.allocate = .alloc_always`。
- **Channel/Queue 禁止传 `std.json.Value`**：Value 含内部指针，跨协程传递后 sender 释放 arena = UAF。outbound 统一传 `[]const u8`（预编码字节），inbound 传 `OwnedMessage{msg, arena}`。
- **Per-message arena 所有权转移**：reader 创建 arena → Queue 传递 → dispatch loop 转给 consumer → consumer defer deinit。所有权链上有且仅有一个持有者。Queue 中的 `OwnedNotification` 不存 `?std.json.Value`，存预编码的 `params_json: ?[]const u8`。
- **禁止通过 ArrayList/Queue 值拷贝含 `?std.json.Value` 的 struct**：LLVM ReleaseFast 对大型 tagged union 值拷贝会生成错误的字段偏移代码。改为预编码 `[]const u8` 或传指针。`group.concurrent` 捕获的参数同理。
- **大型函数加 `noinline`**：含 C FFI + HashMap + arena + 多层循环的函数（如 `getHighlights`、`extractHighlights`）必须 `noinline`，防止 LLVM 内联后生成 8000+ 字节巨型函数触发 codegen bug。
- **`serveStdio`/`serveTcpOnce` 的 VimChannel 必须堆分配**：栈局部 `var ch` 的 `&ch` 被并发任务持有，函数返回后 UAF。
- **长生命周期 `StringHashMap` 的 key 必须 dupe**：`put` 前 `getPtr` 检查已存在则更新 value，否则 `allocator.dupe(key)` 后 put。`remove` 必须用 `fetchRemove` + `allocator.free(kv.key)`。`deinit` 时遍历释放所有 key。
- **LSP request 结果的 allocator 穿透**：`connection.request(result_allocator, method, params)` — handler arena 一路传到 `requestAs` → `fromValue`。`LspProxy.init_result` 例外：用 `self.init_arena` 持有。
- **`ResponseWaiter` cancel 竞态**：`waiter.event.wait(io)` 返回 Canceled 时，`handleResponse` 可能已设置 `waiter.arena`。必须检查并释放。
- **`&.{...}` 含运行时值时是 dangling pointer**：栈上临时数组，函数返回后悬空。用调用者提供的 buffer。
- Zig `HashMap.get()` 返回值拷贝；需要稳定指针时用 `getPtr()`。
- `std.ArrayList` 优先于 `ArrayListUnmanaged`。初始化用 `.empty`。
- 修复 UAF 时，`grep` 全部 `defer.*deinit` 路径一次性修完。
- **`@errorName(err)` 在 treesitter handler 中必须用 `log_mod.safeErrorName(err)`**：C FFI 路径上 LLVM 可能产生垃圾 error 值，`@errorName` 会越界 SIGSEGV。`safeErrorName` 有 noinline + bounds check。
