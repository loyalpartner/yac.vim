"""Daemon integration tests: tree-sitter functionality."""

from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parent.parent.parent
LANGUAGES_DIR = str(PROJECT_ROOT / "languages")


def test_ts_highlights_push(daemon, test_file):
    """ts_viewport 应触发 ts_highlights push。"""
    # Ensure zig language is loaded
    daemon.request("load_language", {"lang_dir": LANGUAGES_DIR + "/zig"})
    daemon.drain_pushes(2)

    daemon.notify("ts_viewport", {"file": test_file, "visible_top": 0})
    push = daemon.wait_push("ts_highlights", timeout=5)
    assert push.get("file") == test_file, (
        f"Push should be for test_file, got: {push.get('file')}"
    )
    highlights = push.get("highlights", {})
    assert len(highlights) > 0, "Highlights should not be empty for a Zig file"


def test_ts_highlights_different_viewport(daemon, test_file):
    """不同 viewport 位置应返回对应区域的高亮。"""
    daemon.notify("ts_viewport", {"file": test_file, "visible_top": 30})
    push = daemon.wait_push("ts_highlights", timeout=5)
    assert push.get("file") == test_file
    highlights = push.get("highlights", {})
    assert len(highlights) > 0, "Should have highlights for functions area"


def test_ts_folding(daemon, test_file):
    """ts_folding 应返回折叠范围。"""
    text = Path(test_file).read_text()
    result = daemon.request("ts_folding", {"file": test_file, "text": text})
    assert result is not None, "Folding should return a result"
    ranges = result.get("ranges", [])
    # struct User + init + getName + getEmail + createUserMap + getUserById +
    # processUser + main + 3 tests = at least 5 ranges
    assert len(ranges) >= 5, f"Should have >= 5 fold ranges, got {len(ranges)}"
    # Each range should have start and end
    for r in ranges:
        assert "start" in r or "start_line" in r, f"Fold range missing start: {r}"


def test_ts_navigate_next_function(daemon, test_file):
    """ts_navigate next 应找到下一个函数。"""
    result = daemon.request("ts_navigate", {
        "file": test_file, "target": "function", "direction": "next", "line": 0,
    })
    assert result is not None, "Navigate should return a result"
    line = result.get("line", -1)
    assert line > 0, f"Should jump to first function, got line {line}"


def test_ts_navigate_prev_function(daemon, test_file):
    """ts_navigate prev 应找到上一个函数。"""
    # From line 50 (0-based 49, inside main), prev should go to processUser or earlier
    result = daemon.request("ts_navigate", {
        "file": test_file, "target": "function", "direction": "prev", "line": 49,
    })
    assert result is not None, "Navigate prev should return a result"
    line = result.get("line", -1)
    assert line < 49, f"Should jump to a previous function, got line {line}"


def test_ts_textobjects_function_outer(daemon, test_file):
    """ts_textobjects function.outer 应返回函数完整范围。"""
    # processUser at line 44 (0-based 43), body at line 45 (44)
    result = daemon.request("ts_textobjects", {
        "file": test_file, "target": "function.outer", "line": 44, "column": 5,
    })
    assert result is not None, "Textobjects should return a result"
    start = result.get("start_line", -1)
    end = result.get("end_line", -1)
    assert start >= 0, f"start_line should be >= 0, got {start}"
    assert end > start, f"end_line ({end}) should be > start_line ({start})"


def test_ts_textobjects_function_inner(daemon, test_file):
    """ts_textobjects function.inner 应返回函数体范围。"""
    result = daemon.request("ts_textobjects", {
        "file": test_file, "target": "function.inner", "line": 44, "column": 5,
    })
    if result is not None:
        start = result.get("start_line", -1)
        end = result.get("end_line", -1)
        assert start >= 0
        assert end >= start


def test_ts_symbols(daemon, test_file):
    """ts_symbols 应返回文档符号列表。"""
    result = daemon.request("ts_symbols", {"file": test_file})
    assert result is not None, "Symbols should return a result"
    symbols = result.get("symbols", [])
    assert len(symbols) >= 3, f"Should have >= 3 symbols, got {len(symbols)}"
    # Check symbol structure
    for s in symbols[:3]:
        assert "name" in s, f"Symbol should have 'name', got keys: {s.keys()}"
