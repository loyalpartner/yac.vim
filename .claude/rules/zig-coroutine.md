---
description: Zig 0.16 Io coroutine model gotchas
globs: yacd/src/**/*.zig
---

# Zig 0.16 Io & Coroutine

- **`main` 必须接收 `init: std.process.Init.Minimal`**，传 `init.environ` 给 `Io.Threaded.init`。
- **协程中禁止 spin-wait (`tryLock` + `spinLoopHint`)**：必须用 `Io.Mutex.lockUncancelable(io)` / `.unlock(io)`。
- **`std.atomic.Mutex`（非 `Io.Mutex`）用于全局变量**：不持 `Io` 引用的代码无法用 `Io.Mutex`，用 `std.atomic.Mutex` + `tryLock` spin-lock。
- **`Child.kill(io)` 已含 wait**：kill 后不要再调 `wait()`。
- **阻塞 LSP 请求必须在独立协程中执行**：`sendRequest` 阻塞协程，用 `Group.concurrent` 派发。
- **shutdown 顺序**：发 LSP shutdown/exit → cancel readLoop group → free 资源。
- **`DebugAllocator` 在 `Io.Threaded` 多线程下 heap corruption**：用 `std.heap.c_allocator` 代替。
- **TreeSitter 需要 Io.Mutex**：所有 public mutable 方法必须加 `Io.Mutex`。
- **`ProxyRegistry.resolve()` 并发安全**：用 `spawning` 集合防止并发 spawn。
- **`Io.File` 异步写入用 `writeStreamingAll(io, data)`**，无 `writeAll`。
- **`Reader.readAlloc(n)` 读恰好 n 字节**；读管道用 `Reader.allocRemaining(allocator, limit)`。
