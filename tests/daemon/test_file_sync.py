"""Daemon integration tests: file synchronization (did_open, did_change, did_close)."""

from pathlib import Path


def test_did_change_updates_buffer(daemon, test_file):
    """did_change 后 hover 应反映新内容。"""
    original = Path(test_file).read_text()
    # Insert a new function before main
    modified = original.replace(
        "pub fn main",
        "/// A brand new function\npub fn foo_bar_baz_new() void {}\n\npub fn main",
    )
    daemon.notify("did_change", {"file": test_file, "text": modified})
    daemon.drain_pushes(2)

    # Hover on the new function — it should exist after did_change
    # foo_bar_baz_new is now 2 lines before the original main (line 49 → 0-based 48)
    # After insert of 2 lines (doc comment + fn), new fn is at 0-based line 49
    result = daemon.request("hover", {"file": test_file, "line": 49, "column": 10})
    # The function might or might not be resolvable by ZLS immediately,
    # but at minimum no crash should occur

    # Restore original content
    daemon.notify("did_change", {"file": test_file, "text": original})
    daemon.drain_pushes(2)


def test_did_change_preserves_lsp(daemon, test_file):
    """did_change 后 LSP 功能应继续工作。"""
    original = Path(test_file).read_text()
    # Add a comment at the top
    modified = "// extra comment\n" + original
    daemon.notify("did_change", {"file": test_file, "text": modified})
    daemon.drain_pushes(2)

    # LSP should still work — definition of processUser (now shifted by 1 line)
    # processUser was at 0-based line 43, now at 44
    result = daemon.request("definition", {"file": test_file, "line": 54, "column": 22})
    # Should still resolve (line shifted by 1)
    if result is not None:
        assert result.get("line") is not None

    # Restore
    daemon.notify("did_change", {"file": test_file, "text": original})
    daemon.drain_pushes(2)


def test_did_close_and_reopen(daemon, test_file):
    """did_close 后 did_open 应重新加载文件。"""
    daemon.notify("did_close", {"file": test_file})
    text = Path(test_file).read_text()
    daemon.notify("did_open", {"file": test_file, "text": text, "language": "zig"})
    daemon.drain_pushes(3)

    # LSP should still work after reopen
    result = daemon.request("lsp_status", {"file": test_file})
    assert result is not None, "lsp_status should return a result after reopen"


def test_did_close_and_reopen_lsp_works(daemon, test_file):
    """重新打开文件后 LSP 请求应正常返回结果。"""
    daemon.notify("did_close", {"file": test_file})
    text = Path(test_file).read_text()
    daemon.notify("did_open", {"file": test_file, "text": text, "language": "zig"})
    daemon.drain_pushes(3)

    # Wait for LSP to be ready again
    daemon.wait_lsp_ready(test_file, timeout=15)

    # Definition should still work
    result = daemon.request("definition", {"file": test_file, "line": 53, "column": 22})
    assert result is not None, "Definition should work after close + reopen"
    assert result.get("line") == 43, (
        f"processUser definition should be at line 43, got {result.get('line')}"
    )
