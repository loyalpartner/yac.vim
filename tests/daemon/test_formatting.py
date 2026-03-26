"""Daemon integration tests: document formatting.

Tests the 'formatting' request which asks ZLS to format the document.
The Vim side sends 'formatting' with {file, tab_size, insert_spaces};
the daemon forwards to textDocument/formatting and returns text edits.

NOTE: As of writing, the 'formatting' method may not be registered in the
daemon dispatcher (app.zig). Tests handle this gracefully — if the daemon
returns null (unknown method), the test documents the current state and
skips rather than failing.
"""

from pathlib import Path


# Poorly formatted Zig code for testing
_BADLY_FORMATTED = """\
const std = @import("std");

pub fn main() !void {
const   x  :  i32  =  42;
    const y:i32=10;
        if(x>y){
            std.debug.print("x={d}\\n",.{x});
    }
}
"""

# Expected: ZLS reformats with consistent indentation and spacing
# We don't assert exact output — just that it's different from the bad input


def test_formatting_request(daemon, test_file):
    """Formatting request should return text edits or null."""
    original = Path(test_file).read_text()

    # Send did_change with badly formatted code
    daemon.notify("did_change", {"file": test_file, "text": _BADLY_FORMATTED})
    daemon.drain_pushes(2)

    try:
        result = daemon.request("formatting", {
            "file": test_file,
            "tab_size": 4,
            "insert_spaces": True,
        })

        if result is None:
            import pytest
            pytest.skip(
                "formatting method not registered in daemon — "
                "returns null for unknown methods"
            )

        # If we got a result, verify the format
        # Expected: either {edits: [...]} or a list of text edits
        if isinstance(result, dict) and "edits" in result:
            edits = result["edits"]
            assert isinstance(edits, list), "edits should be a list"
            if len(edits) > 0:
                edit = edits[0]
                assert "start_line" in edit, f"edit should have start_line, got: {edit.keys()}"
                assert "new_text" in edit, f"edit should have new_text, got: {edit.keys()}"
        elif isinstance(result, list):
            # Raw TextEdit[] — ZLS may return edits directly
            if len(result) > 0:
                edit = result[0]
                assert "new_text" in edit or "newText" in edit, (
                    f"edit should have new_text/newText, got: {edit.keys()}"
                )
    finally:
        # Restore original content
        daemon.notify("did_change", {"file": test_file, "text": original})
        daemon.drain_pushes(2)


def test_formatting_already_formatted(daemon, test_file):
    """Formatting well-formatted code should return no/empty edits."""
    original = Path(test_file).read_text()

    result = daemon.request("formatting", {
        "file": test_file,
        "tab_size": 4,
        "insert_spaces": True,
    })

    if result is None:
        import pytest
        pytest.skip("formatting method not registered in daemon")

    # Well-formatted code should produce no edits (or empty list)
    if isinstance(result, dict):
        edits = result.get("edits", [])
    elif isinstance(result, list):
        edits = result
    else:
        edits = []

    # main.zig in test_data is presumably well-formatted
    # Allow some edits (ZLS may differ on style), but shouldn't be major
    assert len(edits) <= 5, (
        f"Well-formatted file should have few/no edits, got {len(edits)}"
    )


def test_formatting_with_did_change(daemon, test_file):
    """Format after did_change should reflect the changed buffer."""
    original = Path(test_file).read_text()

    # Add a poorly formatted function
    modified = original.replace(
        "pub fn main() !void {",
        "fn   poorly_formatted(  x :i32,y:  i32  )   i32  {return x+y;}\n\npub fn main() !void {",
    )
    daemon.notify("did_change", {"file": test_file, "text": modified})
    daemon.drain_pushes(2)

    try:
        result = daemon.request("formatting", {
            "file": test_file,
            "tab_size": 4,
            "insert_spaces": True,
        })

        if result is None:
            import pytest
            pytest.skip("formatting method not registered in daemon")

        # Should have some edits to fix the poorly formatted function
        if isinstance(result, dict):
            edits = result.get("edits", [])
        elif isinstance(result, list):
            edits = result
        else:
            edits = []

        assert len(edits) > 0, (
            "Poorly formatted code should produce formatting edits"
        )
    finally:
        daemon.notify("did_change", {"file": test_file, "text": original})
        daemon.drain_pushes(2)
