"""Tests for VimRunner in conftest.py — specifically the TimeoutExpired bug fix.

Strategy: load conftest as a standalone module (avoiding pytest's conftest magic),
register it in sys.modules under a stable name, then use patch() with that name.
"""

import importlib.util
import subprocess
import sys
from contextlib import ExitStack
from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest


# ---------------------------------------------------------------------------
# Load conftest as a normal module so we can patch its globals reliably.
# ---------------------------------------------------------------------------
_CONFTEST_PATH = Path(__file__).parent / "conftest.py"
_MOD_NAME = "yac_conftest_under_test"

_spec = importlib.util.spec_from_file_location(_MOD_NAME, str(_CONFTEST_PATH))
_conftest_mod = importlib.util.module_from_spec(_spec)
sys.modules[_MOD_NAME] = _conftest_mod
_spec.loader.exec_module(_conftest_mod)

VimRunner = _conftest_mod.VimRunner
SuiteResult = _conftest_mod.SuiteResult
PROJECT_ROOT = _conftest_mod.PROJECT_ROOT

_M = _MOD_NAME  # shorthand for patch() target prefix


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _make_runner(test_dir: Path | None = None) -> VimRunner:
    """Return a VimRunner with _find_vim patched to skip shell-out.

    If test_dir is given, runner.test_dir is overridden so that test file
    existence checks can be controlled by the caller.
    """
    with patch.object(VimRunner, "_find_vim", return_value="/usr/bin/vim"):
        runner = VimRunner(PROJECT_ROOT)
    if test_dir is not None:
        runner.test_dir = test_dir
    return runner


def _make_timeout_proc() -> MagicMock:
    """Return a Popen mock whose first .wait() call raises TimeoutExpired.

    The cleanup call inside the except block calls proc.wait() a second time
    (without a timeout argument).  We use side_effect as a sequence so that:
      - 1st call (proc.wait(timeout=...)) -> raises TimeoutExpired
      - 2nd call (proc.wait() in cleanup) -> returns 0 (simulates killed process)
    """
    mock_proc = MagicMock()
    mock_proc.wait.side_effect = [
        subprocess.TimeoutExpired(cmd="vim", timeout=75),
        0,  # cleanup call after proc.kill()
    ]
    return mock_proc


def _base_patches(runner, tmp_path, mock_proc, extra=None):
    """
    Build the standard patch list for a timeout scenario.

    We do NOT patch Path.exists globally (that breaks f.unlink() in the
    stale-file cleanup block). Instead we:
      - Patch pty.openpty so no real fd is allocated.
      - Patch os.close so fake fds 10/11 are not closed.
      - Patch shutil.rmtree / copytree to avoid real filesystem ops.
      - Replace _make_workspace so we get a real tmp dir (tests can write to it).
      - Replace _reset_test_data so no copytree is needed.
    """
    return [
        patch(f"{_M}.pty.openpty", return_value=(10, 11)),
        patch(f"{_M}.os.close"),
        patch(f"{_M}.shutil.rmtree"),
        patch(f"{_M}.shutil.copytree"),
        patch(f"{_M}.subprocess.Popen", return_value=mock_proc),
        patch.object(runner, "_make_workspace", return_value=tmp_path),
        patch.object(runner, "_reset_test_data"),
        *(extra or []),
    ]


# ---------------------------------------------------------------------------
# TimeoutExpired branch — the core regression tests
# ---------------------------------------------------------------------------


_TEST_VIM_NAME = "dummy_timeout_test"


class TestRunTestTimeoutExpired:
    """Regression tests for the missing `return` in the TimeoutExpired branch."""

    # Each test uses tmp_path as runner.test_dir and creates a stub .vim file
    # so that the early "test file not found" guard does NOT trigger — we want
    # to exercise the Popen / TimeoutExpired code path.

    def _make_runner_with_stub(self, tmp_path) -> VimRunner:
        """Runner whose test_dir is tmp_path, with a stub .vim file present."""
        (tmp_path / f"{_TEST_VIM_NAME}.vim").write_text('" stub test file\n')
        return _make_runner(test_dir=tmp_path)

    def _run_with_timeout(self, runner, tmp_path, extra=None):
        """Run run_test with a simulated timeout; return (result, mock_proc)."""
        mock_proc = _make_timeout_proc()
        patches = _base_patches(runner, tmp_path, mock_proc, extra=extra)
        with ExitStack() as stack:
            for p in patches:
                stack.enter_context(p)
            result = runner.run_test(_TEST_VIM_NAME)
        return result, mock_proc

    def test_timeout_returns_suite_result(self, tmp_path):
        """TimeoutExpired must return a SuiteResult, not fall through to _parse_output."""
        runner = self._make_runner_with_stub(tmp_path)
        result, _ = self._run_with_timeout(runner, tmp_path)
        assert isinstance(result, SuiteResult)

    def test_timeout_result_is_failure(self, tmp_path):
        """A timed-out test must have failed >= 1 and success=False."""
        runner = self._make_runner_with_stub(tmp_path)
        result, _ = self._run_with_timeout(runner, tmp_path)
        assert result.failed >= 1, f"expected failed>=1, got {result.failed}"
        assert result.success is False

    def test_timeout_result_contains_timeout_message(self, tmp_path):
        """output must mention the timeout so callers can diagnose the failure."""
        runner = self._make_runner_with_stub(tmp_path)
        timeout_seconds = 60

        mock_proc = MagicMock()
        mock_proc.wait.side_effect = [
            subprocess.TimeoutExpired(cmd="vim", timeout=timeout_seconds + 15),
            0,  # cleanup call
        ]
        patches = _base_patches(runner, tmp_path, mock_proc)
        with ExitStack() as stack:
            for p in patches:
                stack.enter_context(p)
            result = runner.run_test(_TEST_VIM_NAME, timeout=timeout_seconds)

        assert "timed out" in result.output.lower() or str(timeout_seconds) in result.output, (
            f"output should mention timeout; got: {result.output!r}"
        )

    def test_timeout_result_suite_name_preserved(self, tmp_path):
        """suite field must equal the test name passed to run_test."""
        runner = self._make_runner_with_stub(tmp_path)
        mock_proc = _make_timeout_proc()  # side_effect is a sequence
        patches = _base_patches(runner, tmp_path, mock_proc)
        with ExitStack() as stack:
            for p in patches:
                stack.enter_context(p)
            result = runner.run_test(_TEST_VIM_NAME)
        assert result.suite == _TEST_VIM_NAME

    def test_timeout_kills_process(self, tmp_path):
        """On TimeoutExpired the child process must be killed."""
        runner = self._make_runner_with_stub(tmp_path)
        _, mock_proc = self._run_with_timeout(runner, tmp_path)
        mock_proc.kill.assert_called_once()

    def test_timeout_does_not_call_parse_output(self, tmp_path):
        """After a timeout, _parse_output must NOT be called (the pre-fix bug)."""
        runner = self._make_runner_with_stub(tmp_path)
        parse_mock = MagicMock()
        extra = [patch.object(runner, "_parse_output", parse_mock)]
        self._run_with_timeout(runner, tmp_path, extra=extra)
        parse_mock.assert_not_called()

    def test_timeout_duration_is_non_negative_float(self, tmp_path):
        """duration field must be a non-negative float."""
        runner = self._make_runner_with_stub(tmp_path)
        result, _ = self._run_with_timeout(runner, tmp_path)
        assert isinstance(result.duration, float)
        assert result.duration >= 0.0


# ---------------------------------------------------------------------------
# Sanity: non-timeout paths are unaffected
# ---------------------------------------------------------------------------


class TestRunTestHappyPath:
    def test_missing_test_file_returns_failure(self):
        """A missing test file returns SuiteResult with failed=1 and no subprocess call."""
        runner = _make_runner()
        result = runner.run_test("nonexistent_test_xyz_does_not_exist")
        assert isinstance(result, SuiteResult)
        assert result.failed >= 1
        assert result.success is False
        assert "not found" in result.output.lower()


# ---------------------------------------------------------------------------
# SuiteResult dataclass sanity
# ---------------------------------------------------------------------------


class TestSuiteResult:
    def test_default_success_is_false(self):
        assert SuiteResult(suite="x").success is False

    def test_default_failed_is_zero(self):
        assert SuiteResult(suite="x").failed == 0

    def test_custom_fields(self):
        r = SuiteResult(suite="s", failed=2, output="boom", duration=1.5)
        assert r.suite == "s"
        assert r.failed == 2
        assert r.output == "boom"
        assert r.duration == 1.5

    def test_output_default_is_empty_string(self):
        assert SuiteResult(suite="x").output == ""
