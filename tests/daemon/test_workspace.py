"""Daemon integration tests: workspace resolution and library path handling."""

import os
import subprocess
import json
from pathlib import Path


def test_lsp_reuses_proxy_for_std_lib(daemon, test_file, workspace):
    """Opening a Zig std library file should NOT spawn a second ZLS."""
    result1 = daemon.request("lsp_status", {"file": test_file})
    assert result1 is not None and result1.get("ready")

    zig_std_path = _find_zig_std_file()
    if zig_std_path is None:
        import pytest
        pytest.skip("No Zig std library found on this system")

    daemon.notify("did_open", {"file": zig_std_path, "text": Path(zig_std_path).read_text()})
    result2 = daemon.request("lsp_status", {"file": zig_std_path})
    assert result2 is not None
    daemon.notify("did_close", {"file": zig_std_path})

    log_path = workspace / "run" / "yacd-daemon-test.log"
    if log_path.exists():
        log_text = log_path.read_text(errors="replace")
        spawn_count = log_text.count("spawning LSP for zig")
        assert spawn_count == 1, (
            f"ZLS should be spawned only once, but was spawned {spawn_count} times"
        )


def test_goto_definition_into_std(daemon, test_file):
    """Goto definition into std should not crash."""
    daemon.request("definition", {"file": test_file, "line": 0, "column": 18})


def _find_zig_std_file() -> str | None:
    candidates = ["/usr/lib/zig/std/mem.zig", "/usr/local/lib/zig/std/mem.zig"]
    try:
        result = subprocess.run(["zig", "env"], capture_output=True, text=True, timeout=5)
        if result.returncode == 0:
            env = json.loads(result.stdout)
            lib_dir = env.get("lib_dir", "")
            if lib_dir:
                candidates.insert(0, os.path.join(lib_dir, "std", "mem.zig"))
    except (subprocess.SubprocessError, json.JSONDecodeError):
        pass
    for path in candidates:
        if os.path.exists(path):
            return path
    return None
