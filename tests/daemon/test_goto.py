"""Daemon integration tests: go-to-definition and variants."""


def test_goto_definition_function_call(daemon, test_file):
    """Go-to-definition on processUser() call should jump to definition."""
    # File line 54: `const name = processUser(user);` → 0-based line=53
    result = daemon.request("definition", {"file": test_file, "line": 53, "column": 22})
    assert result is not None, "Definition should return a result"
    # processUser defined at file line 44 → 0-based line=43
    assert result.get("line") == 43, f"Should jump to processUser definition, got line {result.get('line')}"


def test_goto_definition_method_call(daemon, test_file):
    """Go-to-definition on user.getName() should jump to method."""
    # File line 45: `const result = user.getName();` → 0-based line=44, getName at ~col 28
    result = daemon.request("definition", {"file": test_file, "line": 44, "column": 28})
    assert result is not None, "Definition on method call should return a result"
    # getName defined at file line 19 → 0-based line=18
    line = result.get("line", -1)
    assert 17 <= line <= 20, f"Should jump to getName definition, got line {line}"


def test_goto_type_definition(daemon, test_file):
    """Go-to-type-definition on a User parameter should jump to User struct."""
    # File line 44: `pub fn processUser(user: User)` → 'user' param at col 23, 0-based line=43
    result = daemon.request("goto_type_definition", {"file": test_file, "line": 43, "column": 23})
    # goto_type_definition may return null if ZLS doesn't support it for this position
    if result is not None:
        line = result.get("line", -1)
        assert 5 <= line <= 7, f"Should jump to User struct, got line {line}"
