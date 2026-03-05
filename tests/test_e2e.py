"""YAC E2E tests — each suite runs in its own Vim+LSP process."""

import subprocess

import pytest

from conftest import PROJECT_ROOT, VimRunner

vim_tests = VimRunner(PROJECT_ROOT).list_tests()


def test_autoload_cold_source():
    """Cold-source every autoload file in a fresh Vim — catches load-order bugs.

    Autoload files are sourced individually in an isolated Vim process with no
    prior plugin state.  This detects problems like function('s:foo') references
    that precede the function definition, which batch-mode E2E tests miss because
    they share a session where files are already loaded.
    """
    autoload_dir = PROJECT_ROOT / "vim" / "autoload"
    autoload_files = sorted(autoload_dir.glob("*.vim"))
    assert autoload_files, "no autoload files found"

    vim_dir = PROJECT_ROOT / "vim"
    for vimfile in autoload_files:
        # Source with rtp set so cross-autoload references resolve
        script = (
            f"set rtp+={vim_dir}\n"
            "try\n"
            f"  source {vimfile}\n"
            "catch\n"
            "  call writefile([v:exception . ' at ' . v:throwpoint], '/dev/stderr')\n"
            "  cquit\n"
            "endtry\n"
            "qa!\n"
        )
        result = subprocess.run(
            ["vim", "-N", "-u", "NONE", "-U", "NONE", "-es", "-c", script],
            capture_output=True,
            text=True,
            timeout=10,
        )
        assert result.returncode == 0, (
            f"cold source {vimfile.name} failed:\n{result.stderr}"
        )


@pytest.mark.parametrize("test_name", vim_tests)
def test_vim_e2e(vim_runner, check_bridge, test_name):
    result = vim_runner.run_test(test_name, timeout=120)
    if not result.success:
        sections = []

        detail = result.formatted_failures or result.output
        sections.append(detail)

        if result.yacd_log:
            sections.append(
                f"\n{'=' * 60}\n"
                f"yacd daemon log (last 80 lines):\n"
                f"{'=' * 60}\n"
                f"{result.yacd_log}"
            )

        if result.vim_log:
            sections.append(
                f"\n{'=' * 60}\n"
                f"vim debug log (last 80 lines):\n"
                f"{'=' * 60}\n"
                f"{result.vim_log}"
            )

        if result.screen_dump:
            sections.append(
                f"\n{'=' * 60}\n"
                f"Screen at failure:\n"
                f"{'=' * 60}\n"
                f"{result.screen_dump}"
            )

        pytest.fail(
            f"{test_name}: {result.failed} failures, "
            f"{result.passed} passed\n\n{''.join(sections)}"
        )
