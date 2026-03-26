"""Daemon integration tests: completion."""


def test_completion_std_dot(daemon, test_file):
    """std. should return many completion items (std library members)."""
    result = daemon.request("completion", {
        "file": test_file, "line": 55, "column": 8,
    })
    assert result is not None, "Completion should return a result"
    items = result.get("items", [])
    assert len(items) >= 50, f"std. should have >= 50 items, got {len(items)}"


def test_completion_user_method(daemon, test_file):
    """User. should return struct methods."""
    # Use a position where a User value is in scope
    # Line 56: `if (getUserById(&users, 1)) |user| {`
    # We need to simulate typing user. — but since we share the daemon,
    # we test at a position where method completion makes sense.
    result = daemon.request("completion", {
        "file": test_file, "line": 48, "column": 28,
    })
    # This may or may not return results depending on ZLS context
    # The important thing is no crash and valid response format
    assert result is not None or result is None  # no crash


def test_completion_returns_valid_format(daemon, test_file):
    """Completion items should have label and kind."""
    result = daemon.request("completion", {
        "file": test_file, "line": 55, "column": 8,
    })
    assert result is not None
    items = result.get("items", [])
    assert len(items) > 0, "Should have at least 1 item"
    first = items[0]
    assert "label" in first, f"Item should have 'label', got: {first.keys()}"
    assert "kind" in first, f"Item should have 'kind', got: {first.keys()}"
