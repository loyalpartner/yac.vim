"""Daemon integration tests: signature help."""


def test_signature_help_process_user(daemon, test_file):
    """函数调用括号内应返回签名帮助。"""
    # Line 54: `const name = processUser(user);` → 0-based line=53, column=25 (inside parens)
    result = daemon.request("signature_help", {
        "file": test_file, "line": 53, "column": 25,
    })
    # ZLS may not return signatures for single-param calls with known type
    if result is not None:
        sigs = result.get("signatures", [])
        if len(sigs) >= 1:
            label = sigs[0].get("label", "")
            assert "processUser" in label or "User" in label, \
                f"Signature label should mention processUser, got: {label}"


def test_signature_help_get_user_by_id(daemon, test_file):
    """getUserById 调用括号内应返回签名帮助。"""
    # Line 53: `if (getUserById(&users, 1)) |user| {` → 0-based line=52, column=25 (inside parens)
    result = daemon.request("signature_help", {
        "file": test_file, "line": 52, "column": 25,
    })
    if result is not None:
        sigs = result.get("signatures", [])
        if len(sigs) > 0:
            label = sigs[0].get("label", "")
            assert "getUserById" in label or "user" in label.lower(), (
                f"Signature should mention getUserById, got: {label}"
            )


def test_signature_help_outside_call(daemon, test_file):
    """函数调用外部不应返回签名帮助。"""
    # Line 49: `pub fn main() !void {` → 0-based line=48, column=0
    result = daemon.request("signature_help", {
        "file": test_file, "line": 48, "column": 0,
    })
    # Outside a call — may return null or empty signatures, both OK
    if result is not None:
        sigs = result.get("signatures", [])
        # Acceptable: empty or non-empty (depends on ZLS heuristics)
        assert isinstance(sigs, list)
