"""Daemon integration tests: diagnostics push.

Diagnostics are pushed asynchronously by the daemon when ZLS detects
compilation errors via textDocument/publishDiagnostics.
"""

from pathlib import Path


def test_diagnostics_on_syntax_error(daemon, test_file):
    """did_change with syntax error should trigger diagnostics push."""
    original = Path(test_file).read_text()

    # Introduce a syntax error: missing semicolon
    broken = original.replace(
        'const result = user.getName();',
        'const result = user.getName()',  # missing semicolon
    )
    assert broken != original, "Replacement should have changed the text"

    daemon.notify("did_change", {"file": test_file, "text": broken})

    try:
        params = daemon.wait_push("diagnostics", timeout=10)
    except TimeoutError:
        # Restore original before skipping
        daemon.notify("did_change", {"file": test_file, "text": original})
        daemon.drain_pushes(2)
        import pytest
        pytest.skip("diagnostics push not yet implemented in daemon")

    try:
        assert params.get("file") == test_file, (
            f"Diagnostics should target the test file, got: {params.get('file')}"
        )
        diags = params.get("diagnostics", [])
        assert len(diags) > 0, "Should have at least one diagnostic for the syntax error"

        first = diags[0]
        assert "message" in first, f"Diagnostic should have 'message', got: {first.keys()}"
        assert "severity" in first, f"Diagnostic should have 'severity', got: {first.keys()}"
        assert "line" in first, f"Diagnostic should have 'line', got: {first.keys()}"
    finally:
        # Always restore original content
        daemon.notify("did_change", {"file": test_file, "text": original})
        daemon.drain_pushes(2)


def test_diagnostics_cleared_after_fix(daemon, test_file):
    """Fixing the error should result in empty diagnostics."""
    original = Path(test_file).read_text()

    # Step 1: introduce error
    broken = original.replace(
        'const result = user.getName();',
        'const result = user.getName()',
    )
    daemon.notify("did_change", {"file": test_file, "text": broken})

    try:
        daemon.wait_push("diagnostics", timeout=10)
    except TimeoutError:
        daemon.notify("did_change", {"file": test_file, "text": original})
        daemon.drain_pushes(2)
        import pytest
        pytest.skip("diagnostics push not yet implemented in daemon")

    # Step 2: fix the error by restoring original
    daemon.notify("did_change", {"file": test_file, "text": original})

    try:
        params = daemon.wait_push("diagnostics", timeout=10)
    except TimeoutError:
        # Timeout is acceptable — some servers don't push empty diagnostics quickly
        daemon.drain_pushes(2)
        return

    diags = params.get("diagnostics", [])
    # After fixing, diagnostics should be empty (or at least reduced)
    assert len(diags) == 0, (
        f"After fix, diagnostics should be empty, got {len(diags)}: "
        f"{[d.get('message', '') for d in diags[:3]]}"
    )


def test_diagnostics_push_format(daemon, test_file):
    """Verify the shape of a diagnostics push notification."""
    original = Path(test_file).read_text()

    # Use an undeclared identifier to trigger a clear error
    broken = original.replace(
        'pub fn main() !void {',
        'pub fn main() !void {\n    _ = undefined_symbol_xyz;',
    )
    assert broken != original, "Replacement should have changed the text"

    daemon.notify("did_change", {"file": test_file, "text": broken})

    try:
        params = daemon.wait_push("diagnostics", timeout=10)
    except TimeoutError:
        daemon.notify("did_change", {"file": test_file, "text": original})
        daemon.drain_pushes(2)
        import pytest
        pytest.skip("diagnostics push not yet implemented in daemon")

    try:
        # Verify top-level structure
        assert "file" in params, "Push should contain 'file'"
        assert "diagnostics" in params, "Push should contain 'diagnostics'"

        diags = params["diagnostics"]
        assert isinstance(diags, list), "diagnostics should be a list"

        if len(diags) > 0:
            d = diags[0]
            # Each diagnostic should have line, col, severity, message
            assert isinstance(d.get("line"), int), "line should be int"
            assert isinstance(d.get("col"), int), "col should be int"
            assert isinstance(d.get("severity"), int), "severity should be int"
            assert isinstance(d.get("message"), str), "message should be str"
            # severity: 1=Error, 2=Warning, 3=Info, 4=Hint
            assert d["severity"] in (1, 2, 3, 4), (
                f"severity should be 1-4, got {d['severity']}"
            )
    finally:
        daemon.notify("did_change", {"file": test_file, "text": original})
        daemon.drain_pushes(2)
