"""YAC E2E tests — all tests share one Vim session + LSP server."""

import pytest

from conftest import PROJECT_ROOT, VimRunner


vim_tests = VimRunner(PROJECT_ROOT).list_tests()


@pytest.mark.parametrize("test_name", vim_tests)
def test_vim_e2e(batch_results, test_name):
    if test_name not in batch_results:
        pytest.fail(f"{test_name}: no result (test may have crashed)")
    result = batch_results[test_name]
    if not result.success:
        pytest.fail(
            f"{test_name}: {result.failed} failures, "
            f"{result.passed} passed\n\n{result.output}"
        )
