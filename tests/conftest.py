"""YAC E2E test fixtures."""

import json
import os
import pty
import re
import shutil
import subprocess
import tempfile
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
    formatted_failures: str = ""
    yacd_log: str = ""
    vim_log: str = ""
    screen_dump: str = ""


class VimRunner:
    """Headless Vim runner for E2E tests."""

    def __init__(self, project_root: Path):
        self.project_root = project_root
        self.vim_cmd = self._find_vim()
        self.test_dir = project_root / "tests" / "vim"
        self.shared_workspace = None  # Set by fixture if YAC_SHARED_DAEMON=1

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

    def _make_workspace(self) -> Path:
        """Copy test data template into a temp workspace."""
        tmpdir = Path(tempfile.mkdtemp(prefix="yac_test_"))

        # Copy template directory as test_data/ (path referenced by Vim scripts)
        shutil.copytree(
            self.project_root / "tests" / "data_tmpl",
            tmpdir / "test_data",
            ignore=shutil.ignore_patterns(".zig-cache"),
        )

        # Symlink read-only directories needed by the plugin at runtime
        (tmpdir / "vim").symlink_to(self.project_root / "vim")
        (tmpdir / "vimrc").symlink_to(self.project_root / "vimrc")
        (tmpdir / "zig-out").symlink_to(self.project_root / "zig-out")
        (tmpdir / "tests").symlink_to(self.project_root / "tests")

        return tmpdir

    def _reset_test_data(self, workspace: Path) -> None:
        """Reset test_data/ to a clean copy of the template."""
        test_data = workspace / "test_data"
        if test_data.exists():
            shutil.rmtree(test_data)
        shutil.copytree(
            self.project_root / "tests" / "data_tmpl",
            test_data,
            ignore=shutil.ignore_patterns(".zig-cache"),
        )

    def run_test(self, test_name: str, timeout: int = 60) -> SuiteResult:
        test_file = self.test_dir / f"{test_name}.vim"
        if not test_file.exists():
            return SuiteResult(
                suite=test_name,
                failed=1,
                output=f"Test file not found: {test_file}",
            )

        shared = self.shared_workspace
        if shared is not None:
            workspace, runtime_dir = shared
            self._reset_test_data(workspace)
        else:
            workspace = self._make_workspace()
            # Per-test runtime dir so each yacd writes its own log
            runtime_dir = workspace / "run"
            runtime_dir.mkdir()

        start_time = time.time()
        pid = os.getpid()
        safe_name = test_name.replace("/", "_")
        output_file = Path(f"/tmp/yac_test_{safe_name}_{pid}.txt")
        signal_file = Path(f"/tmp/yac_test_{safe_name}_{pid}.signal")
        screen_dump_file = Path(f"/tmp/yac_test_{safe_name}_{pid}.screen")
        driver_vim = self.test_dir / "driver.vim"

        vimrc = workspace / "vimrc"

        env = os.environ.copy()
        env["YAC_TEST_OUTPUT"] = str(output_file)
        env["YAC_TEST_SIGNAL"] = str(signal_file)
        env["YAC_TEST_SCREEN"] = str(screen_dump_file)
        env["YAC_TEST_FILE"] = str(test_file)
        env["YAC_DRIVER_TIMEOUT"] = str(timeout * 1000)
        env["YAC_DRIVER_VIMRC"] = str(vimrc)
        env["YAC_DRIVER_CWD"] = str(workspace)
        env["XDG_RUNTIME_DIR"] = str(runtime_dir)

        # Per-test vim debug log
        vim_debug_log = workspace / "yac-vim-debug.log"
        env["YAC_DEBUG_LOG"] = str(vim_debug_log)

        # Clean up stale files
        for f in [output_file, signal_file, screen_dump_file]:
            if f.exists():
                f.unlink()

        # Use PTY so outer Vim runs in a real terminal
        master_fd, slave_fd = pty.openpty()

        proc = None
        try:
            proc = subprocess.Popen(
                [self.vim_cmd, "-N", "-u", "NONE", "-S", str(driver_vim)],
                stdin=slave_fd,
                stdout=slave_fd,
                stderr=slave_fd,
                cwd=workspace,
                env=env,
            )
            os.close(slave_fd)
            slave_fd = -1

            # Driver has its own timeout; give it extra margin
            proc.wait(timeout=timeout + 15)
        except subprocess.TimeoutExpired:
            if proc is not None:
                proc.kill()
                proc.wait()
        except Exception as e:
            if slave_fd >= 0:
                os.close(slave_fd)
            os.close(master_fd)
            if proc is not None:
                proc.kill()
                proc.wait()
            for f in [output_file, signal_file, screen_dump_file]:
                if f.exists():
                    f.unlink()
            if shared is None:
                shutil.rmtree(workspace, ignore_errors=True)
            return SuiteResult(
                suite=test_name,
                failed=1,
                duration=time.time() - start_time,
                output=str(e),
            )
        finally:
            try:
                os.close(master_fd)
            except OSError:
                pass

        # Read results
        output = ""
        if output_file.exists():
            output = output_file.read_text()
            output_file.unlink()

        # Clean up signal file
        if signal_file.exists():
            signal_file.unlink()

        duration = time.time() - start_time
        suite_result = self._parse_output(test_name, output, duration)

        # Attach screen dump
        if screen_dump_file.exists():
            suite_result.screen_dump = screen_dump_file.read_text()
            screen_dump_file.unlink()

        if not suite_result.success:
            if shared is None:
                print(f"\n  [debug] workspace preserved: {workspace}")
            else:
                print(f"\n  [debug] shared workspace: {workspace}")
            suite_result.formatted_failures = self._format_failures(
                suite_result.tests
            )
            suite_result.yacd_log = self._collect_log(runtime_dir / "yacd.log")
            suite_result.vim_log = self._collect_log(vim_debug_log)
        else:
            if shared is None:
                shutil.rmtree(workspace, ignore_errors=True)
        return suite_result

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

    def _format_failures(self, tests: list) -> str:
        """Extract a structured report of failed tests."""
        lines = []
        for t in tests:
            if t.get("status") == "fail":
                lines.append(f"  FAIL: {t['name']}")
                lines.append(f"        {t.get('reason', '')}")
        return "\n".join(lines)

    @staticmethod
    def _collect_log(path: Path, tail: int = 80) -> str:
        """Read last `tail` lines from a log file, return empty string if missing."""
        if not path.exists():
            return ""
        try:
            lines = path.read_text().splitlines()
            return "\n".join(lines[-tail:])
        except Exception:
            return ""

    def list_tests(self) -> list[str]:
        test_files = sorted(self.test_dir.glob("**/test_*.vim"))
        return [
            str(f.relative_to(self.test_dir)).removesuffix('.vim')
            for f in test_files
        ]


@pytest.fixture(scope="session")
def shared_workspace():
    """Session-scoped shared workspace: one daemon + one LSP instance for all tests."""
    if not os.environ.get("YAC_SHARED_DAEMON"):
        yield None
        return

    tmpdir = Path(tempfile.mkdtemp(prefix="yac_shared_"))
    runtime_dir = tmpdir / "run"
    runtime_dir.mkdir()

    # Initial test_data
    shutil.copytree(
        PROJECT_ROOT / "tests" / "data_tmpl",
        tmpdir / "test_data",
        ignore=shutil.ignore_patterns(".zig-cache"),
    )

    # Symlinks for plugin runtime
    for name in ["vim", "vimrc", "zig-out", "tests"]:
        (tmpdir / name).symlink_to(PROJECT_ROOT / name)

    yield tmpdir, runtime_dir

    # Kill daemon that used this runtime dir
    sock = runtime_dir / "yacd.sock"
    if sock.exists():
        subprocess.run(
            ["pkill", "-f", f"yacd.*{runtime_dir}"],
            capture_output=True,
            timeout=5,
        )
    shutil.rmtree(tmpdir, ignore_errors=True)


@pytest.fixture(scope="function")
def vim_runner(shared_workspace):
    runner = VimRunner(PROJECT_ROOT)
    runner.shared_workspace = shared_workspace
    return runner


@pytest.fixture(scope="session")
def check_bridge():
    bridge = PROJECT_ROOT / "zig-out" / "bin" / "yacd"
    if not bridge.exists():
        pytest.skip("yacd not built, run 'zig build' first")
