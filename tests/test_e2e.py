"""YAC E2E tests — each suite runs in its own Vim+LSP process."""

import pytest

from conftest import PROJECT_ROOT, VimRunner

vim_tests = VimRunner(PROJECT_ROOT).list_tests()


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

        pytest.fail(
            f"{test_name}: {result.failed} failures, "
            f"{result.passed} passed\n\n{''.join(sections)}"
        )
