---
description: Cross-platform and debugging gotchas
globs: yacd/src/**/*.zig
---

# Platform & Debugging

- **Never use `std.os.linux.*` on macOS**: 用 `std.c.getpid()` 等跨平台替代。
- **wasmtime mach ports crash on macOS 26**: 用 `wasmtime_config_macos_use_mach_ports_set(config, false)`。
- **macOS `/tmp` ↔ `/private/tmp`**: `glob()` 失败，用 `readdir()` + regex。
- **`std.Uri.Component.toRawMaybeAlloc` 不总是分配内存**：无 percent 编码时返回原始 slice，需检查并 `dupe`。
- **Fix platform bug → grep for similar patterns**: 修一处后搜全 codebase。

## Debugging Crashes

- **For crashes, use debugger FIRST** — `lldb -- ./zig-out/bin/yacd` then `run`。
- **Linux coredump**: `coredumpctl list | grep yacd`，`coredumpctl debug <PID> -A "-batch -ex 'bt full'"`。`0xAAAAAAAAAAAAAAAA` = Zig debug freed memory。
- **macOS crash reports**: `ls -lt ~/Library/Logs/DiagnosticReports/yacd*`。
- **Daemon logs**: `ls -lt /tmp/yacd-$USER-*.log` — 日志突然中断 = crash。

## Daemon Lifecycle

- **Graceful shutdown**: `yac#stop()` → JSON-RPC `exit` → `shutdown_requested = true`。
- **Restart**: `stop()` + `sleep 200m` + `start()`。
