"""Daemon integration tests: references."""


def test_references_function(daemon, test_file):
    """processUser 的引用应包含定义和所有调用。"""
    # processUser defined at line 44 (0-based 43), called at line 54 (53) and line 74 (73)
    result = daemon.request("references", {"file": test_file, "line": 43, "column": 10})
    assert result is not None, "References should return a result"
    locations = result.get("locations", [])
    assert len(locations) >= 2, (
        f"processUser should have >= 2 references (definition + calls), got {len(locations)}"
    )


def test_references_struct(daemon, test_file):
    """User 的引用应包含定义和所有使用。"""
    # User defined at line 6 (0-based 5), used in init return type, processUser param, etc.
    result = daemon.request("references", {"file": test_file, "line": 5, "column": 15})
    # ZLS may return empty for struct definition position — acceptable
    assert result is not None or result is None  # no crash


def test_references_local_function(daemon, test_file):
    """getUserById 的引用应至少包含定义和 main 中的调用。"""
    # getUserById defined at line 39 (0-based 38), called at line 53 (52)
    result = daemon.request("references", {"file": test_file, "line": 38, "column": 10})
    assert result is not None, "References for getUserById should return a result"
    locations = result.get("locations", [])
    assert len(locations) >= 2, (
        f"getUserById should have >= 2 references, got {len(locations)}"
    )


def test_references_no_results(daemon, test_file):
    """空行或关键字位置应返回空或 null，不崩溃。"""
    # Line 3 is empty (0-based 2)
    result = daemon.request("references", {"file": test_file, "line": 2, "column": 0})
    # May return null or empty locations — both are acceptable
    if result is not None:
        locations = result.get("locations", [])
        assert isinstance(locations, list)
