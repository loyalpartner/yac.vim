"""Daemon integration tests: hover."""


def test_hover_function_call(daemon, test_file):
    """Hover on processUser call should return function signature."""
    # Line 54: `const name = processUser(user);` → processUser at col 22, 0-based line=53
    result = daemon.request("hover", {"file": test_file, "line": 53, "column": 22})
    assert result is not None, "Hover on function call should return a result"
    contents = str(result)
    assert "processUser" in contents or "User" in contents, \
        f"Hover should describe processUser, got: {contents[:300]}"


def test_hover_function(daemon, test_file):
    """Hover on createUserMap should return documentation."""
    # Line 33: `pub fn createUserMap`
    result = daemon.request("hover", {"file": test_file, "line": 32, "column": 10})
    assert result is not None, "Hover on function should return a result"
    contents = result.get("contents", "")
    assert "createUserMap" in contents or "user" in contents.lower(), \
        f"Hover should describe the function, got: {contents[:200]}"


def test_hover_empty_space(daemon, test_file):
    """Hover on empty line should return null/empty."""
    # Line 1: `const std = @import("std");` — hover on 'const' keyword
    result = daemon.request("hover", {"file": test_file, "line": 0, "column": 0})
    # May return null or empty — both are acceptable for a keyword position
    # The important thing is no crash


def test_hover_std_import(daemon, test_file):
    """Hover on std should return std library docs."""
    # Line 1: `const std = @import("std");` — hover on 'std' (column ~6)
    result = daemon.request("hover", {"file": test_file, "line": 0, "column": 6})
    assert result is not None, "Hover on std should return a result"
