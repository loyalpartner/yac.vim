"""YAC E2E test fixtures."""

import json
import os
import re
import subprocess
import time
from dataclasses import dataclass, field
from pathlib import Path

import pytest


PROJECT_ROOT = Path(__file__).parent.parent


@dataclass
class SuiteResult:
    suite: str
    tests: list = field(default_factory=list)
    passed: int = 0
    failed: int = 0
    skipped: int = 0
    duration: float = 0.0
    success: bool = False
    output: str = ""


class VimRunner:
    """Headless Vim runner for E2E tests."""

    def __init__(self, project_root: Path):
        self.project_root = project_root
        self.vim_cmd = self._find_vim()
        self.test_dir = project_root / "tests" / "vim"

    def _find_vim(self) -> str:
        for cmd in ["vim", "/usr/bin/vim", "/usr/local/bin/vim"]:
            try:
                result = subprocess.run(
                    [cmd, "--version"],
                    capture_output=True,
                    timeout=5,
                )
                if result.returncode == 0:
                    return cmd
            except (subprocess.SubprocessError, FileNotFoundError):
                continue
        pytest.skip("vim not found")

    def run_test(self, test_name: str, timeout: int = 60) -> SuiteResult:
        test_file = self.test_dir / f"{test_name}.vim"
        if not test_file.exists():
            return SuiteResult(
                suite=test_name,
                failed=1,
                output=f"Test file not found: {test_file}",
            )

        start_time = time.time()
        output_file = Path(f"/tmp/yac_test_{test_name}_{os.getpid()}.txt")

        vimrc = self.project_root / "vimrc"
        cmd = [
            self.vim_cmd,
            "-N",
            "-u", str(vimrc),
            "-U", "NONE",
            "-es",
            "-c", "set noswapfile",
            "-c", "set nobackup",
            "-c", f"source {test_file}",
            "-c", "qa!",
        ]

        env = os.environ.copy()
        env["YAC_TEST_OUTPUT"] = str(output_file)

        try:
            result = subprocess.run(
                cmd,
                cwd=self.project_root,
                capture_output=True,
                text=True,
                timeout=timeout,
                env=env,
            )
            if output_file.exists():
                output = output_file.read_text()
                output_file.unlink()
            else:
                output = result.stdout + result.stderr
        except subprocess.TimeoutExpired:
            if output_file.exists():
                output_file.unlink()
            return SuiteResult(
                suite=test_name,
                failed=1,
                duration=timeout,
                output=f"Test timed out after {timeout}s",
            )
        except Exception as e:
            if output_file.exists():
                output_file.unlink()
            return SuiteResult(
                suite=test_name,
                failed=1,
                duration=time.time() - start_time,
                output=str(e),
            )

        duration = time.time() - start_time
        return self._parse_output(test_name, output, duration)

    def _parse_output(self, suite: str, output: str, duration: float) -> SuiteResult:
        match = re.search(r"::YAC_TEST_RESULT::(.+)$", output, re.MULTILINE)
        if match:
            try:
                data = json.loads(match.group(1))
                return SuiteResult(
                    suite=data.get("suite", suite),
                    tests=data.get("tests", []),
                    passed=data.get("passed", 0),
                    failed=data.get("failed", 0),
                    duration=data.get("duration", duration),
                    success=data.get("success", False),
                    output=output,
                )
            except json.JSONDecodeError:
                pass

        passed = len(re.findall(r"\[PASS\]", output))
        failed = len(re.findall(r"\[FAIL\]", output))

        return SuiteResult(
            suite=suite,
            passed=passed,
            failed=failed,
            duration=duration,
            success=failed == 0 and passed > 0,
            output=output,
        )

    def list_tests(self) -> list[str]:
        return sorted(f.stem for f in self.test_dir.glob("test_*.vim"))


@pytest.fixture(scope="session")
def vim_runner():
    return VimRunner(PROJECT_ROOT)


@pytest.fixture(scope="session")
def check_bridge():
    bridge = PROJECT_ROOT / "zig-out" / "bin" / "lsp-bridge"
    if not bridge.exists():
        pytest.skip("lsp-bridge not built, run 'zig build' first")
